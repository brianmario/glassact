//! Parsing: OBUs -> DecisionRecord (the intra toolset the writer produces: one key frame of a
//! still picture, 64x64 superblocks, uniform tiles), the walk with the spec's symbol decoder.
use super::sink::DecSink;
use super::walk::{Frame, ParseRec, Rec, TileBufs, TileState, Walk};
use super::*;
use crate::blockinfo::{mi_cols, mi_rows};
use crate::dsp::clip3;

/// av1g_parsed: the record with all decisions and quantized coefficients, and where the tiles were.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Parsed {
    pub rec: Record,
    pub seq_level_idx: u32,
    /// per tile: payload size in the parsed stream
    pub tile_bytes: Vec<u32>,
    /// per tile: payload offset in the parsed buffer
    pub tile_offsets: Vec<u64>,
}

struct BitReader<'a> {
    d: &'a [u8],
    pos: usize,
}

macro_rules! need {
    ($c:expr, $($a:tt)*) => {
        if !($c) {
            fail!(ERR_INVALID, $($a)*);
        }
    };
}

impl BitReader<'_> {
    fn f(&mut self, k: i32) -> Res<u32> {
        let mut v = 0u32;
        for _ in 0..k {
            if self.pos >> 3 >= self.d.len() {
                fail!(ERR_INVALID, "header truncated");
            }
            v = (v << 1) | ((self.d[self.pos >> 3] >> (7 - (self.pos & 7))) & 1) as u32;
            self.pos += 1;
        }
        Ok(v)
    }
    fn b(&mut self) -> Res<bool> {
        Ok(self.f(1)? != 0)
    }
    fn su(&mut self, k: i32) -> Res<i32> {
        let v = self.f(k)? as i32;
        let m = 1 << (k - 1);
        Ok(if v & m != 0 { v - 2 * m } else { v })
    }
    fn byte_align(&mut self) {
        self.pos = (self.pos + 7) & !7;
    }
}

#[derive(Default)]
struct Seq {
    seen: bool,
    reduced: bool,
    level: i32,
    wbits: i32,
    hbits: i32,
    max_w: u32,
    max_h: u32,
    filter_intra: u8,
    edge_filter: u8,
    superres: bool,
    cdef: bool,
    restoration: bool,
    mono: bool,
    separate_uv: bool,
    force_sct: u32,
    force_int_mv: u32,
    order_hint_bits: i32,
    film_grain: bool,
}

/// av1g_parse: an AV1 OBU stream (sequence header + one intra OBU_FRAME) back into a
/// DecisionRecord.
pub fn parse(obus: &[u8]) -> Result<Parsed, Error> {
    let mut out = Parsed::default();
    parse_into(obus, &mut out).map_err(|e| *e)?;
    Ok(out)
}

fn parse_seq(br: &mut BitReader, sq: &mut Seq) -> Res<()> {
    let profile = br.f(3)?;
    br.f(1)?; // still_picture
    sq.reduced = br.b()?;
    need!(profile == 0, "only Main profile (got {profile})");
    if sq.reduced {
        sq.level = br.f(5)? as i32;
    } else {
        if br.b()? {
            // timing_info
            br.f(32)?;
            br.f(32)?;
            if br.b()? {
                // equal_picture_interval: uvlc
                let mut lz = 0;
                while !br.b()? {
                    lz += 1;
                }
                if lz < 32 {
                    br.f(lz)?;
                }
            }
            let decoder_model = br.b()?;
            need!(!decoder_model, "decoder model info not supported");
        }
        let idd = br.b()?;
        let nops = br.f(5)? + 1;
        for i in 0..nops {
            br.f(12)?;
            let lv = br.f(5)? as i32;
            if i == 0 {
                sq.level = lv;
            }
            if lv > 7 {
                br.f(1)?;
            }
            if idd && br.b()? {
                br.f(4)?;
            }
        }
    }
    sq.wbits = br.f(4)? as i32 + 1;
    sq.hbits = br.f(4)? as i32 + 1;
    sq.max_w = br.f(sq.wbits)? + 1;
    sq.max_h = br.f(sq.hbits)? + 1;
    if !sq.reduced {
        let frame_ids = br.b()?;
        need!(!frame_ids, "frame ids not supported");
    }
    need!(br.f(1)? == 0, "128x128 superblocks not supported");
    sq.filter_intra = br.f(1)? as u8;
    sq.edge_filter = br.f(1)? as u8;
    if !sq.reduced {
        for _ in 0..4 {
            br.f(1)?; // interintra, masked, warped, dual filter
        }
        let oh = br.b()?;
        if oh {
            br.f(1)?;
            br.f(1)?;
        }
        sq.force_sct = if br.b()? { 2 } else { br.f(1)? };
        sq.force_int_mv = if sq.force_sct > 0 {
            if br.b()? { 2 } else { br.f(1)? }
        } else {
            2
        };
        if oh {
            sq.order_hint_bits = br.f(3)? as i32 + 1;
        }
    }
    sq.superres = br.b()?;
    sq.cdef = br.b()?;
    sq.restoration = br.b()?;
    need!(br.f(1)? == 0, "only 8-bit supported");
    sq.mono = br.b()?;
    let (mut cp, mut tc, mut mc) = (2, 2, 2);
    if br.b()? {
        cp = br.f(8)?;
        tc = br.f(8)?;
        mc = br.f(8)?;
    }
    if sq.mono {
        br.f(1)?;
    } else {
        need!(!(cp == 1 && tc == 13 && mc == 0), "4:4:4 identity matrix not supported");
        br.f(1)?; // color_range
        br.f(2)?; // chroma_sample_position
        sq.separate_uv = br.b()?;
    }
    sq.film_grain = br.b()?;
    sq.seen = true;
    Ok(())
}

fn parse_into(obus: &[u8], out: &mut Parsed) -> Res<()> {
    let n = obus.len();
    let mut sq = Seq {
        force_sct: 2,
        force_int_mv: 2,
        ..Default::default()
    };
    let mut fp = FrameParams {
        version: DECISIONS_VERSION,
        ..Default::default()
    };
    let mut pos = 0usize;
    let mut done = false;
    while pos < n && !done {
        let h = obus[pos];
        pos += 1;
        let (ty, ext, has_size) = ((h >> 3) & 15, (h >> 2) & 1, (h >> 1) & 1);
        if ext != 0 {
            pos += 1;
        }
        let mut sz = n.saturating_sub(pos) as u64;
        if has_size != 0 {
            sz = 0;
            for i in 0..8 {
                need!(pos < n, "OBU truncated");
                let b = obus[pos];
                pos += 1;
                sz |= ((b & 0x7f) as u64) << (7 * i);
                if b & 0x80 == 0 {
                    break;
                }
            }
        }
        need!(pos as u64 + sz <= n as u64, "OBU size beyond buffer");
        let p = &obus[pos..pos + sz as usize];
        if ty == 1 {
            parse_seq(&mut BitReader { d: p, pos: 0 }, &mut sq)?;
        } else if ty == 6 || ty == 3 {
            need!(sq.seen, "frame before sequence header");
            need!(ty == 6, "separate frame header + tile group OBUs not supported");
            parse_frame(
                &sq,
                p,
                (p.as_ptr() as usize - obus.as_ptr() as usize) as u64,
                &mut fp,
                out,
            )?;
            done = true;
        }
        pos += sz as usize;
    }
    need!(done, "no frame found");
    out.seq_level_idx = sq.level as u32;
    Ok(())
}

fn parse_frame(sq: &Seq, p: &[u8], p_off: u64, fp: &mut FrameParams, out: &mut Parsed) -> Res<()> {
    let sz = p.len();
    fp.enable_intra_edge_filter = sq.edge_filter;
    fp.enable_filter_intra = sq.filter_intra;
    need!(!sq.superres && !sq.film_grain, "superres / film grain not supported");
    let mut br = BitReader { d: p, pos: 0 };
    if !sq.reduced {
        need!(br.f(1)? == 0, "show_existing_frame");
        need!(br.f(2)? == 0, "only KEY_FRAME supported");
        need!(br.f(1)? == 1, "show_frame must be 1");
    }
    need!(br.f(1)? == 0, "disable_cdf_update=1 not supported");
    let sct = if sq.force_sct == 2 { br.f(1)? } else { sq.force_sct };
    fp.allow_screen_content_tools = (sct != 0) as u8;
    if sct != 0 && sq.force_int_mv == 2 {
        br.f(1)?; // force_integer_mv
    }
    let override_ = if !sq.reduced { br.b()? } else { false };
    if sq.order_hint_bits != 0 {
        br.f(sq.order_hint_bits)?;
    }
    let (mut fw, mut fh) = (sq.max_w, sq.max_h);
    if override_ {
        fw = br.f(sq.wbits)? + 1;
        fh = br.f(sq.hbits)? + 1;
    }
    if br.b()? {
        // render size
        br.f(16)?;
        br.f(16)?;
    }
    if sct != 0 {
        need!(br.f(1)? == 0, "allow_intrabc=1 not supported");
    }
    if !sq.reduced {
        br.f(1)?; // disable_frame_end_update_cdf
    }
    fp.width = fw;
    fp.height = fh;
    fp.monochrome = sq.mono as u8;
    let mut tile_size_bytes = 4;
    // tile_info
    {
        let mut t = TileInfo::default();
        compute_tiles(fw, fh, -1, -1, &mut t);
        need!(br.f(1)? == 1, "non-uniform tile spacing not supported");
        let mut cl = t.min_log2_tile_cols;
        while cl < t.max_log2_tile_cols {
            if br.b()? {
                cl += 1;
            } else {
                break;
            }
        }
        let mut t2 = TileInfo::default();
        compute_tiles(fw, fh, cl, -1, &mut t2);
        let mut rl = t2.min_log2_tile_rows;
        while rl < t2.max_log2_tile_rows {
            if br.b()? {
                rl += 1;
            } else {
                break;
            }
        }
        fp.tile_cols_log2 = cl as i8;
        fp.tile_rows_log2 = rl as i8;
        if cl > 0 || rl > 0 {
            br.f(cl + rl)?; // context_update_tile_id (irrelevant: no frame-end CDF update)
            tile_size_bytes = br.f(2)? as i32 + 1;
        }
    }
    // quantization_params
    fp.base_q_idx = br.f(8)? as u8;
    let rdq = |br: &mut BitReader| -> Res<i8> { Ok(if br.b()? { br.su(7)? as i8 } else { 0 }) };
    fp.delta_q_y_dc = rdq(&mut br)?;
    if !sq.mono {
        let diff = if sq.separate_uv { br.b()? } else { false };
        fp.delta_q_u_dc = rdq(&mut br)?;
        fp.delta_q_u_ac = rdq(&mut br)?;
        if diff {
            fp.delta_q_v_dc = rdq(&mut br)?;
            fp.delta_q_v_ac = rdq(&mut br)?;
        } else {
            fp.delta_q_v_dc = fp.delta_q_u_dc;
            fp.delta_q_v_ac = fp.delta_q_u_ac;
        }
    }
    fp.using_qmatrix = br.f(1)? as u8;
    if fp.using_qmatrix != 0 {
        fp.qm_y = br.f(4)? as u8;
        fp.qm_u = br.f(4)? as u8;
        fp.qm_v = if sq.separate_uv { br.f(4)? as u8 } else { fp.qm_u };
    }
    need!(br.f(1)? == 0, "segmentation not supported");
    need!(fp.base_q_idx > 0, "lossless not supported");
    fp.delta_q_present = br.f(1)? as u8;
    if fp.delta_q_present != 0 {
        fp.delta_q_res = br.f(2)? as u8;
        need!(br.f(1)? == 0, "delta_lf_present (M5) not supported");
    }
    // loop_filter_params -> effective levels (intra frame: only the INTRA ref delta applies)
    let mut lvl = [0i32; 4];
    lvl[0] = br.f(6)? as i32;
    lvl[1] = br.f(6)? as i32;
    if !sq.mono && (lvl[0] != 0 || lvl[1] != 0) {
        lvl[2] = br.f(6)? as i32;
        lvl[3] = br.f(6)? as i32;
    }
    fp.loop_filter_sharpness = br.f(3)? as u8;
    let mut ref_delta_intra = 1; // setup_past_independence default
    let delta_enabled = br.b()?;
    if delta_enabled && br.b()? {
        for i in 0..8 {
            if br.b()? {
                let v = br.su(7)?;
                if i == 0 {
                    ref_delta_intra = v;
                }
            }
        }
        for _ in 0..2 {
            if br.b()? {
                br.su(7)?;
            }
        }
    }
    if lvl[0] != 0 || lvl[1] != 0 {
        for i in 0..4 {
            if i >= 2 && lvl[i] == 0 {
                continue; // chroma plane not filtered at all
            }
            let mut e = lvl[i];
            if delta_enabled {
                e = clip3(0, 63, e + ref_delta_intra * (1 << (e >> 5)));
            }
            fp.loop_filter_level[i] = e as u8;
        }
        let l = fp.loop_filter_level;
        need!(
            l[0] != 0 || l[1] != 0 || (l[2] == 0 && l[3] == 0),
            "loop filter delta combination not representable"
        );
    }
    if sq.cdef {
        fp.enable_cdef = 1;
        fp.cdef_damping_minus_3 = br.f(2)? as u8;
        fp.cdef_bits = br.f(2)? as u8;
        let sec = |v: u32| if v == 3 { 4 } else { v as u8 };
        for i in 0..(1usize << fp.cdef_bits) {
            fp.cdef_y_pri[i] = br.f(4)? as u8;
            fp.cdef_y_sec[i] = sec(br.f(2)?);
            if !sq.mono {
                fp.cdef_uv_pri[i] = br.f(4)? as u8;
                fp.cdef_uv_sec[i] = sec(br.f(2)?);
            }
        }
    }
    if sq.restoration {
        for _ in 0..if sq.mono { 1 } else { 3 } {
            need!(br.f(2)? == 0, "loop restoration not supported");
        }
    }
    fp.tx_mode_select = br.f(1)? as u8;
    fp.reduced_tx_set = br.f(1)? as u8;
    br.byte_align();

    // setup_frame
    let (mi_cols, mi_rows) = (mi_cols(fw as i32), mi_rows(fh as i32));
    let mut tiles = TileInfo::default();
    if !compute_tiles(fw, fh, fp.tile_cols_log2 as i32, fp.tile_rows_log2 as i32, &mut tiles) {
        fail!(
            ERR_INVALID,
            "illegal tiling {}/{} for {fw}x{fh}",
            fp.tile_cols_log2,
            fp.tile_rows_log2
        );
    }
    tiles.tile_size_bytes = tile_size_bytes;
    let mono = fp.monochrome != 0;
    let ordmap: [Vec<u32>; 3] = Default::default();
    let f = Frame {
        fp: *fp,
        mi_cols,
        mi_rows,
        mono,
        sb_cols: (mi_cols + 15) >> 4,
        sb_rows: (mi_rows + 15) >> 4,
        tiles,
        qm_level: [
            fp.qm_y as i32,
            fp.qm_u as i32,
            if !mono && fp.using_qmatrix != 0 {
                fp.qm_v
            } else {
                fp.qm_u
            } as i32,
        ],
        do_recon: false,
        fix_range: false,
        check_edges: false,
        ordmap: &ordmap,
    };
    // tile group
    let ntiles = (tiles.cols * tiles.rows) as usize;
    if ntiles > 1 {
        need!(br.f(1)? == 0, "tile_start_and_end_present_flag not supported");
        br.byte_align();
    }
    let mut st = Box::<TileState>::default();
    st.setup(mi_cols, mi_rows);
    let mut bufs = TileBufs::default();
    let mut pr = ParseRec::default();
    let mut tpos = br.pos >> 3;
    let tsb = tiles.tile_size_bytes as usize;
    for tn in 0..ntiles {
        let tsz = if tn == ntiles - 1 {
            sz.wrapping_sub(tpos)
        } else {
            need!(tpos + tsb <= sz, "tile beyond OBU");
            let mut v = 0usize;
            for k in 0..tsb {
                v |= (p[tpos + k] as usize) << (8 * k);
            }
            tpos += tsb;
            v + 1
        };
        need!(tpos <= sz && tsz <= sz - tpos, "tile beyond OBU");
        let (tr, tc) = (tn / tiles.cols as usize, tn % tiles.cols as usize);
        bufs.setup(&f, tr, tc, false);
        let mut hs = ();
        let mut walk = Walk::<DecSink, NoHook> {
            st: &mut st,
            sk: DecSink::new(&p[tpos..tpos + tsz]),
            f: &f,
            bufs: &mut bufs,
            hook: None,
            hs: &mut hs,
        };
        walk.tile(&mut Rec::Parse(&mut pr), tr, tc)?;
        out.tile_bytes.push(tsz as u32);
        out.tile_offsets.push(p_off + tpos as u64);
        tpos += tsz;
    }
    pr.block_txb.push(pr.txb.len() as u32);
    out.rec = Record {
        fp: *fp,
        blocks: pr.blocks,
        block_txb: pr.block_txb,
        txb: pr.txb,
        coeffs: pr.coeffs,
    };
    Ok(())
}
