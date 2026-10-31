//! The encoder (Encoder::run, av1g::encode_with_hook): frame checks, tiles on parallel threads,
//! the OBUs, the post-filters of the reconstruction and the outputs.
use super::headers::{BitWriter, frame_obus};
use super::sink::{EcSink, TeeSink};
use super::walk::{Frame, Rec, TileBufs, TileState, Walk};
use super::*;
use crate::blockinfo::{mi_cols, mi_rows};
use crate::dsp::{RefPlane, tx_coeffs, tx_h, tx_w};
use crate::entropy::{Ec, FrameCdfs};
use crate::postfilter::{LF_ZERO, PfFrame, PfMaps, cdef_frame, deblock_frame};
use crate::tables::{LAST_FRAME, TX_SIZES_ALL};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

/// Symbol coding only (validation): AV1G_ENC_SKIP_RECON.
pub const ENC_SKIP_RECON: u32 = ENC_BITSTREAM_ONLY;
/// Internal: cross-check [`crate::blockinfo::txb_edges`] against BlockDecoded (AV1G_ENC_CHECK_EDGES).
pub const ENC_CHECK_EDGES: u32 = 0x20000;

/// One tile thread's state. Reused.
#[derive(Default)]
struct Worker {
    st: Box<TileState>,
    ec: Ec,
}

/// The frame-level buffers the post-filters run on when a picture has several tiles (one tile's
/// own buffers are frame-shaped).
#[derive(Default)]
struct FrameBufs {
    plane: [Vec<u8>; 3],
    skip: Vec<u8>,
    /// the post-filters' skip map with fp.lf_inter_off (postfilter::LF_ZERO on inter blocks)
    pf_skip: Vec<u8>,
    tx: Vec<u8>,
    lf_uv: [Vec<u8>; 2],
    sb_cdef: Vec<i8>,
}

/// Optional inputs and outputs of [`Writer::encode_with_hook`].
#[derive(Clone, Copy, Debug, Default)]
pub struct Extras<'a> {
    /// one entry per tile (raster order): tiles the caller already has
    pub tile_skip: Option<&'a [TileSkip<'a>]>,
    /// record every coded tile's packed symbol stream ([`Writer::tile_syms`]; intra frames only:
    /// the GPU entropy coder's symbol streams have no inter syntax)
    pub record_syms: bool,
    /// the reference pictures by slot (video mode): an inter frame predicts from
    /// `refs[fp.ref_slot]`, which must be present unless the reconstruction is skipped
    pub refs: Option<&'a RefSlots<'a>>,
}

/// The DecisionRecord writer with its scratch: per-thread tile state, per-tile reconstruction
/// buffers and payloads, the post-filters' frame. One per stream: once its buffers have grown, a
/// writer encoding same-sized pictures doesn't allocate in the walk.
pub struct Writer {
    workers: Vec<Worker>,
    tiles: Vec<TileBufs>,
    payloads: Vec<Vec<u8>>,
    syms: Vec<Vec<u32>>,
    ordmap: [Vec<u32>; 3],
    tile_first: Vec<u32>,
    ranges: Vec<(usize, usize, usize, usize)>,
    frame: FrameBufs,
    cdef_out: [Vec<u8>; 3],
    seq: BitWriter,
    fh: BitWriter,
    threads: usize,
    /// the context tile's saved CDFs, as its worker leaves them (captured, CDFs)
    saved: Mutex<(bool, Box<FrameCdfs>)>,
    /// tiles by block count, for the context tile
    tile_order: Vec<(u32, usize)>,
}

impl Default for Writer {
    fn default() -> Self {
        Self::new()
    }
}

/// One tile's work for a thread.
struct TileTask<'a> {
    rec: Rec<'a>,
    bufs: &'a mut TileBufs,
    payload: &'a mut Vec<u8>,
    syms: Option<&'a mut Vec<u32>>,
    nsym: u64,
    nfixed: u64,
    err: Option<Box<Error>>,
}

/// Codes tile `i` (raster order) of the frame into `payload`. Returns (symbols, repaired tx blocks).
fn code_tile<H: TxbHook>(
    w: &mut Worker,
    f: &Frame,
    rec: &mut Rec,
    bufs: &mut TileBufs,
    payload: &mut Vec<u8>,
    syms: Option<&mut Vec<u32>>,
    hook: Option<&H>,
    hs: &mut H::Scratch,
    i: usize,
    first: u32,
    end: u32,
) -> Res<(u64, u64)> {
    let cols = f.tiles.cols as usize;
    let (tr, tc) = (i / cols, i % cols);
    bufs.setup(f, tr, tc, f.do_recon);
    w.st.cursor = first;
    w.st.tile_end = end;
    w.st.n_fixed = 0;
    w.ec.reset();
    let nsym = match syms {
        Some(out) => {
            out.clear();
            let base = &w.st.cdf as *const _ as usize;
            let sk = TeeSink {
                ec: EcSink { ec: &mut w.ec, nsym: 0 },
                base,
                out,
            };
            let mut walk = Walk {
                st: &mut w.st,
                sk,
                f,
                bufs,
                hook,
                hs,
            };
            walk.tile(rec, tr, tc)?;
            walk.sk.ec.nsym
        }
        None => {
            let sk = EcSink { ec: &mut w.ec, nsym: 0 };
            let mut walk = Walk {
                st: &mut w.st,
                sk,
                f,
                bufs,
                hook,
                hs,
            };
            walk.tile(rec, tr, tc)?;
            walk.sk.nsym
        }
    };
    payload.clear();
    w.ec.finish(payload);
    if w.st.cursor != w.st.tile_end {
        fail!(
            ERR_INVALID,
            "tile {tr},{tc}: block {} not consumed by the partition walk",
            w.st.cursor
        );
    }
    Ok((nsym, w.st.n_fixed))
}

fn check_frame(fp: &FrameParams) -> Res<()> {
    if fp.version != DECISIONS_VERSION && fp.version != 1 {
        fail!(ERR_INVALID, "record version {} (1 or {DECISIONS_VERSION})", fp.version);
    }
    if fp.width < 1 || fp.height < 1 || fp.width > 65535 || fp.height > 65535 {
        fail!(ERR_INVALID, "bad size {}x{}", fp.width, fp.height);
    }
    if fp.base_q_idx < 1 {
        fail!(ERR_INVALID, "base_q_idx must be >= 1 (lossless unsupported)");
    }
    if fp.monochrome > 1 || fp.tx_mode_select > 1 || fp.reduced_tx_set > 1 {
        fail!(ERR_INVALID, "bad frame flags");
    }
    let dqs = [
        fp.delta_q_y_dc,
        fp.delta_q_u_dc,
        fp.delta_q_u_ac,
        fp.delta_q_v_dc,
        fp.delta_q_v_ac,
    ];
    if dqs.iter().any(|&d| !(-64..=63).contains(&d)) {
        fail!(ERR_INVALID, "delta_q out of range");
    }
    if fp.enable_filter_intra > 1 || fp.enable_intra_edge_filter > 1 {
        fail!(
            ERR_INVALID,
            "enable_filter_intra / enable_intra_edge_filter must be 0/1"
        );
    }
    if fp.loop_filter_level.iter().any(|&l| l > 63) {
        fail!(ERR_INVALID, "loop_filter_level > 63");
    }
    if fp.loop_filter_sharpness > 7 {
        fail!(ERR_INVALID, "loop_filter_sharpness > 7");
    }
    let lf = fp.loop_filter_level;
    if lf[0] == 0 && lf[1] == 0 && (lf[2] != 0 || lf[3] != 0) {
        fail!(
            ERR_INVALID,
            "chroma loop filter levels need a nonzero luma level (spec loop_filter_params)"
        );
    }
    if fp.enable_cdef > 1 || fp.cdef_damping_minus_3 > 3 || fp.cdef_bits > 3 {
        fail!(ERR_INVALID, "bad CDEF parameters");
    }
    let sec_ok = |v: u8| matches!(v, 0 | 1 | 2 | 4);
    for i in 0..8 {
        if fp.cdef_y_pri[i] > 15 || fp.cdef_uv_pri[i] > 15 || !sec_ok(fp.cdef_y_sec[i]) || !sec_ok(fp.cdef_uv_sec[i]) {
            fail!(ERR_INVALID, "CDEF strengths: pri 0..15, sec 0/1/2/4");
        }
    }
    if fp.delta_q_present > 1
        || fp.delta_q_res > 3
        || fp.using_qmatrix > 1
        || fp.qm_y > 15
        || fp.qm_u > 15
        || fp.qm_v > 15
    {
        fail!(ERR_INVALID, "bad delta_q / quantizer matrix parameters");
    }
    if fp.reserved.iter().any(|&r| r != 0) {
        fail!(ERR_INVALID, "reserved frame_params fields must be 0 in interface v1");
    }
    if fp.allow_screen_content_tools > 1 {
        fail!(ERR_INVALID, "allow_screen_content_tools must be 0/1");
    }
    // v2: video mode (in v1 these were reserved bytes, which must be 0)
    let v2 = [
        fp.video,
        fp.frame_type,
        fp.ref_slot,
        fp.refresh_frame_flags,
        fp.error_resilient_mode,
        fp.lf_inter_off,
        fp.cdf_from_ref,
        fp.mv_precision,
    ];
    if fp.version == 1 && v2.iter().any(|&r| r != 0) {
        fail!(ERR_INVALID, "reserved frame_params fields must be 0 in interface v1");
    }
    if fp.video > 1 || fp.frame_type > FRAME_INTER {
        fail!(ERR_INVALID, "video must be 0/1, frame_type key or inter");
    }
    if fp.video == 0 && fp.frame_type != FRAME_KEY {
        fail!(ERR_INVALID, "inter frames need video mode");
    }
    if fp.frame_type == FRAME_KEY {
        if fp.ref_slot != 0
            || fp.refresh_frame_flags != 0
            || fp.error_resilient_mode != 0
            || fp.lf_inter_off != 0
            || fp.cdf_from_ref != 0
        {
            fail!(
                ERR_INVALID,
                "key frames refresh every slot: ref_slot, refresh_frame_flags, error_resilient_mode, lf_inter_off and cdf_from_ref must be 0"
            );
        }
    } else {
        if fp.ref_slot > 7 || fp.error_resilient_mode > 1 || fp.lf_inter_off > 1 || fp.cdf_from_ref > 1 {
            fail!(
                ERR_INVALID,
                "ref_slot must be 0..7, error_resilient_mode, lf_inter_off and cdf_from_ref 0/1"
            );
        }
        if fp.mv_precision != 0 {
            fail!(ERR_INVALID, "mv_precision other than whole samples isn't supported yet");
        }
        if fp.cdf_from_ref != 0 && fp.error_resilient_mode != 0 {
            fail!(
                ERR_INVALID,
                "cdf_from_ref needs error_resilient_mode 0 (which codes primary_ref_frame NONE)"
            );
        }
        if fp.allow_screen_content_tools != 1 {
            fail!(
                ERR_INVALID,
                "inter frames need allow_screen_content_tools = 1 (it carries force_integer_mv)"
            );
        }
    }
    Ok(())
}

/// LAST_FRAME's planes of an inter frame: the slot's planes, checked against the picture size.
fn ref_planes<'a>(fp: &FrameParams, refs: Option<&RefSlots<'a>>) -> Res<[RefPlane<'a>; 3]> {
    let Some(r) = refs.and_then(|r| r[fp.ref_slot as usize]) else {
        fail!(ERR_INVALID, "inter frame: reference slot {} is empty", fp.ref_slot);
    };
    let mut out = [RefPlane {
        data: &[],
        stride: 0,
        w: 0,
        h: 0,
    }; 3];
    for p in 0..if fp.monochrome != 0 { 1 } else { 3 } {
        let sub = (p != 0) as u32;
        let (w, h) = ((fp.width + sub) >> sub, (fp.height + sub) >> sub);
        let (data, stride) = (r.plane[p], r.stride[p]);
        if stride < w as usize || data.len() < (h as usize - 1) * stride + w as usize {
            fail!(
                ERR_INVALID,
                "reference slot {} plane {p}: {} samples at stride {stride} don't hold {w}x{h}",
                fp.ref_slot,
                data.len()
            );
        }
        out[p] = RefPlane {
            data,
            stride,
            w: w as i32,
            h: h as i32,
        };
    }
    Ok(out)
}

/// The tx-block and coefficient ranges of each tile, if they are ordered and disjoint (always so
/// for a layout from [`super::layout`]): then the tiles can own their parts of the record's arrays
/// and run in parallel, exactly as they run one after the other. Per tile: (txb start, txb end,
/// coefficient start, coefficient end).
fn tile_ranges(
    block_txb: &[u32],
    tile_first: &[u32],
    txb: &[Txb],
    n_coeffs: usize,
    coded: impl Fn(usize) -> bool,
    out: &mut Vec<(usize, usize, usize, usize)>,
) -> bool {
    out.clear();
    // every block's tx blocks inside its tile's
    if block_txb.windows(2).any(|w| w[1] < w[0]) || *block_txb.last().unwrap() as usize > txb.len() {
        return false;
    }
    let mut prev_c = 0usize;
    for i in 0..tile_first.len() - 1 {
        let (t0, t1) = (
            block_txb[tile_first[i] as usize] as usize,
            block_txb[tile_first[i + 1] as usize] as usize,
        );
        let (mut lo, mut hi) = (usize::MAX, 0usize);
        if coded(i) {
            for t in &txb[t0..t1] {
                if (t.tx_size as i32) < TX_SIZES_ALL {
                    let o = t.coeff_off as usize;
                    lo = lo.min(o);
                    hi = hi.max(o + tx_coeffs(t.tx_size as i32));
                }
            }
        }
        if lo == usize::MAX {
            (lo, hi) = (prev_c, prev_c);
        }
        if lo < prev_c || hi > n_coeffs {
            return false;
        }
        prev_c = hi;
        out.push((t0, t1, lo, hi));
    }
    true
}

impl Writer {
    pub fn new() -> Writer {
        Self::with_threads(0)
    }

    /// A writer coding tiles on at most `threads` threads (0: the available parallelism).
    pub fn with_threads(threads: usize) -> Writer {
        let threads = if threads == 0 {
            std::thread::available_parallelism().map_or(1, |n| n.get())
        } else {
            threads
        };
        Writer {
            workers: Vec::new(),
            tiles: Vec::new(),
            payloads: Vec::new(),
            syms: Vec::new(),
            ordmap: Default::default(),
            tile_first: Vec::new(),
            ranges: Vec::new(),
            frame: FrameBufs::default(),
            cdef_out: Default::default(),
            saved: Mutex::new((false, Box::new(FrameCdfs::new(0)))),
            tile_order: Vec::new(),
            seq: BitWriter::default(),
            fh: BitWriter::default(),
            threads,
        }
    }

    /// The tile payloads of the last successful encode (raster order; a skipped tile's as given).
    pub fn tile_payloads(&self) -> &[Vec<u8>] {
        &self.payloads
    }

    /// The packed symbol streams (symstream) of the last encode with [`Extras::record_syms`] (raster
    /// order; empty for skipped tiles).
    pub fn tile_syms(&self) -> &[Vec<u32>] {
        &self.syms
    }

    /// av1g_encode: the record must have a valid layout ([`super::layout`]). On success the record's
    /// txb eob and chroma tx_type are written (the luma tx_type of all-zero tx blocks becomes
    /// DCT_DCT, as the spec has it); with [`ENC_FIX_RANGE`] offending coefficients are halved in
    /// place. `out` is overwritten (cleared on error).
    pub fn encode(&mut self, rec: RecordMut, opts: &EncodeOpts, out: &mut Output) -> Result<(), Error> {
        self.encode_with_hook::<NoHook>(rec, opts, None, &Extras::default(), out)
    }

    /// av1g_encode_ex: [`Writer::encode`] with the reference pictures (inter frames).
    pub fn encode_ex(
        &mut self,
        rec: RecordMut,
        opts: &EncodeOpts,
        refs: &RefSlots,
        out: &mut Output,
    ) -> Result<(), Error> {
        let extras = Extras {
            refs: Some(refs),
            ..Extras::default()
        };
        self.encode_with_hook::<NoHook>(rec, opts, None, &extras, out)
    }

    /// av1g::encode_with_hook: [`Writer::encode`] with the closed-loop hook, tile skips and the
    /// per-tile symbol streams.
    pub fn encode_with_hook<H: TxbHook>(
        &mut self,
        mut rec: RecordMut,
        opts: &EncodeOpts,
        hook: Option<&H>,
        extras: &Extras,
        out: &mut Output,
    ) -> Result<(), Error> {
        out.clear();
        let r = self.run(&mut rec, opts, hook, extras, out);
        r.map_err(|e| {
            out.clear();
            *e
        })
    }

    fn run<H: TxbHook>(
        &mut self,
        rec: &mut RecordMut,
        opts: &EncodeOpts,
        hook: Option<&H>,
        extras: &Extras,
        out: &mut Output,
    ) -> Res<()> {
        let fp = rec.fp;
        check_frame(&fp)?;
        let do_recon = opts.flags & ENC_SKIP_RECON == 0;
        let fix_range = opts.flags & ENC_FIX_RANGE != 0;
        let n_blocks = rec.blocks.len();
        if rec.block_txb.len() < n_blocks + 1 {
            fail!(ERR_INVALID, "record arrays missing");
        }
        if rec.block_txb[n_blocks] as usize != rec.txb.len() {
            fail!(ERR_INVALID, "layout stale (call av1g_layout)");
        }
        if !rec.inter.is_empty() && rec.inter.len() != n_blocks {
            fail!(ERR_INVALID, "{} inter entries for {n_blocks} blocks", rec.inter.len());
        }
        let inter = fp.frame_type == FRAME_INTER;
        if inter && extras.record_syms {
            fail!(ERR_INVALID, "symbol streams are for intra frames only");
        }
        let refs = if inter && do_recon {
            Some(ref_planes(&fp, extras.refs)?)
        } else {
            None
        };
        let (w, h) = (fp.width, fp.height);
        let mono = fp.monochrome != 0;
        let (mi_cols, mi_rows) = (mi_cols(w as i32), mi_rows(h as i32));
        let (sb_cols, sb_rows) = ((mi_cols + 15) >> 4, (mi_rows + 15) >> 4);
        let mut tiles = TileInfo::default();
        if !compute_tiles(w, h, fp.tile_cols_log2 as i32, fp.tile_rows_log2 as i32, &mut tiles) {
            fail!(
                ERR_INVALID,
                "illegal tiling {}/{} for {w}x{h}",
                fp.tile_cols_log2,
                fp.tile_rows_log2
            );
        }
        let nplanes = if mono { 1 } else { 3 };
        let check_edges = opts.flags & ENC_CHECK_EDGES != 0;
        if check_edges {
            for p in 0..nplanes {
                let sub = (p != 0) as i32;
                let (stride, rows) = (((sb_cols * 16) >> sub) as usize, ((sb_rows * 16) >> sub) as usize);
                self.ordmap[p].clear();
                self.ordmap[p].resize(stride * rows, u32::MAX);
            }
            for (i, x) in rec.txb.iter().enumerate() {
                if x.plane as usize >= nplanes || x.tx_size as i32 >= TX_SIZES_ALL {
                    continue;
                }
                let sub = (x.plane != 0) as i32;
                let (stride, rows) = (((sb_cols * 16) >> sub) as usize, ((sb_rows * 16) >> sub) as usize);
                let (w4, h4) = (
                    tx_w(x.tx_size as i32) as usize >> 2,
                    tx_h(x.tx_size as i32) as usize >> 2,
                );
                let m = &mut self.ordmap[x.plane as usize];
                for yy in 0..h4 {
                    let y = x.y4 as usize + yy;
                    if y >= rows {
                        break;
                    }
                    for xx in 0..w4 {
                        let xp = x.x4 as usize + xx;
                        if xp >= stride {
                            break;
                        }
                        m[y * stride + xp] = i as u32;
                    }
                }
            }
        }
        let qm_level = [
            fp.qm_y as i32,
            fp.qm_u as i32,
            if !mono && fp.using_qmatrix != 0 {
                fp.qm_v
            } else {
                fp.qm_u
            } as i32,
        ];

        // ---- tiles ----
        // Every tile's blocks: all blocks whose position is inside it, contiguous in tile order.
        let ntiles = (tiles.rows * tiles.cols) as usize;
        self.tile_first.clear();
        let mut cursor = 0usize;
        for tr in 0..tiles.rows as usize {
            for tc in 0..tiles.cols as usize {
                self.tile_first.push(cursor as u32);
                let (r0, r1) = (tiles.mi_row_starts[tr], tiles.mi_row_starts[tr + 1]);
                let (c0, c1) = (tiles.mi_col_starts[tc], tiles.mi_col_starts[tc + 1]);
                while cursor < n_blocks {
                    let b = &rec.blocks[cursor];
                    let (br, bc) = (b.mi_row as u32, b.mi_col as u32);
                    if br < r0 || br >= r1 || bc < c0 || bc >= c1 {
                        break;
                    }
                    cursor += 1;
                }
            }
        }
        self.tile_first.push(cursor as u32);
        if cursor != n_blocks {
            fail!(ERR_INVALID, "block {cursor} is outside the expected tile order");
        }
        let skip = extras.tile_skip;
        if let Some(s) = skip
            && s.len() != ntiles
        {
            fail!(ERR_INVALID, "tile skip list of {} for {ntiles} tiles", s.len());
        }
        let skipped = |i: usize| skip.is_some_and(|s| s[i].skip);
        let ncoded = (0..ntiles).filter(|&i| !skipped(i)).count();
        // the frame's CDFs: its reference's saved ones, or the defaults
        let cdfs_in = if inter && fp.cdf_from_ref != 0 {
            match extras.refs.and_then(|r| r[fp.ref_slot as usize]).and_then(|r| r.cdfs) {
                Some(c) => Some(c),
                None => fail!(
                    ERR_INVALID,
                    "cdf_from_ref: reference slot {} has no saved CDFs",
                    fp.ref_slot
                ),
            }
        } else {
            None
        };
        // In video mode the frame saves the CDFs of its median tile by block count (ties: the lower
        // index), which on screen content is neither an all-skip tile nor the busiest: smaller inter
        // frames than libaom's largest tile, by up to 22 % at 5K (BENCHMARKS). Whether tiles are
        // reused doesn't change it: a reused tile's CDFs aren't known, and none are saved then. A still
        // picture names tile 0.
        let mut context_tile = 0usize;
        if fp.video != 0 {
            let order = &mut self.tile_order;
            order.clear();
            order.extend((0..ntiles).map(|i| (self.tile_first[i + 1] - self.tile_first[i], i)));
            order.sort_unstable();
            context_tile = order[ntiles / 2].1;
        }
        self.saved.get_mut().unwrap().0 = false;
        let f = Frame {
            fp,
            mi_cols,
            mi_rows,
            mono,
            sb_cols,
            sb_rows,
            tiles,
            qm_level,
            do_recon,
            fix_range,
            check_edges,
            ordmap: &self.ordmap,
            inter,
            refs,
            cdfs_in,
            cdfs_out: (fp.video != 0).then_some(&self.saved),
            context_tile,
        };

        if self.tiles.len() < ntiles {
            self.tiles.resize_with(ntiles, TileBufs::default);
        }
        self.payloads.resize_with(ntiles.max(self.payloads.len()), Vec::new);
        self.payloads.truncate(ntiles);
        self.syms.resize_with(ntiles.max(self.syms.len()), Vec::new);
        self.syms.truncate(if extras.record_syms { ntiles } else { 0 });
        for s in &mut self.syms {
            s.clear();
        }
        let need_planes = do_recon && opts.flags & ENC_NO_RECON == 0;
        for i in 0..ntiles {
            if let Some(s) = skip
                && s[i].skip
            {
                // the caller has this tile
                self.payloads[i].clear();
                if let Some(p) = s[i].payload {
                    self.payloads[i].extend_from_slice(p);
                }
                let cols = tiles.cols as usize;
                self.tiles[i].setup(&f, i / cols, i % cols, need_planes);
                self.tiles[i].zero_planes(nplanes);
            }
        }

        let nworkers = if ntiles > 1 { ncoded.min(self.threads).max(1) } else { 1 };
        if self.workers.len() < nworkers {
            self.workers.resize_with(nworkers, Worker::default);
        }
        for w in &mut self.workers[..nworkers] {
            w.st.setup(mi_cols, mi_rows);
        }
        let parallel = nworkers > 1
            && tile_ranges(
                rec.block_txb,
                &self.tile_first,
                rec.txb,
                rec.coeffs.len(),
                |i| !skipped(i),
                &mut self.ranges,
            );
        let (mut nsym, mut nfixed) = (0u64, 0u64);
        let record = extras.record_syms;
        if !parallel {
            let mut r = Rec::Write {
                blocks: rec.blocks,
                inter: rec.inter,
                block_txb: rec.block_txb,
                txb: &mut *rec.txb,
                txb_base: 0,
                coeffs: &mut *rec.coeffs,
                coeff_base: 0,
            };
            let mut hs = H::Scratch::default();
            let w = &mut self.workers[0];
            for i in 0..ntiles {
                if skipped(i) {
                    continue;
                }
                let syms = if record { Some(&mut self.syms[i]) } else { None };
                let (first, end) = (self.tile_first[i], self.tile_first[i + 1]);
                let (s, x) = code_tile(
                    w,
                    &f,
                    &mut r,
                    &mut self.tiles[i],
                    &mut self.payloads[i],
                    syms,
                    hook,
                    &mut hs,
                    i,
                    first,
                    end,
                )?;
                nsym += s;
                nfixed += x;
            }
        } else {
            // the tiles' parts of the record, buffers and outputs
            let mut txb_rest: &mut [Txb] = &mut *rec.txb;
            let mut coeff_rest: &mut [i16] = &mut *rec.coeffs;
            let (mut txb_at, mut coeff_at) = (0usize, 0usize);
            let mut tasks = Vec::with_capacity(ncoded);
            let mut syms_iter = self.syms.iter_mut();
            for (i, ((bufs, payload), &(t0, t1, c0, c1))) in self
                .tiles
                .iter_mut()
                .zip(self.payloads.iter_mut())
                .zip(&self.ranges)
                .enumerate()
            {
                let (_, rest) = core::mem::take(&mut txb_rest).split_at_mut(t0 - txb_at);
                let (tx, rest) = rest.split_at_mut(t1 - t0);
                txb_rest = rest;
                txb_at = t1;
                let (_, rest) = core::mem::take(&mut coeff_rest).split_at_mut(c0 - coeff_at);
                let (co, rest) = rest.split_at_mut(c1 - c0);
                coeff_rest = rest;
                coeff_at = c1;
                let syms = syms_iter.next();
                if skipped(i) {
                    continue;
                }
                tasks.push((
                    i,
                    Mutex::new(TileTask {
                        rec: Rec::Write {
                            blocks: rec.blocks,
                            inter: rec.inter,
                            block_txb: rec.block_txb,
                            txb: tx,
                            txb_base: t0,
                            coeffs: co,
                            coeff_base: c0,
                        },
                        bufs,
                        payload,
                        syms,
                        nsym: 0,
                        nfixed: 0,
                        err: None,
                    }),
                ));
            }
            let next = AtomicUsize::new(0);
            let stop = AtomicBool::new(false);
            let tile_first = &self.tile_first;
            let work = |w: &mut Worker| {
                let mut hs = H::Scratch::default();
                loop {
                    if stop.load(Ordering::Relaxed) {
                        break;
                    }
                    let k = next.fetch_add(1, Ordering::Relaxed);
                    let Some((i, task)) = tasks.get(k) else { break };
                    let mut guard = task.lock().unwrap();
                    let t = &mut *guard;
                    let syms = t.syms.as_deref_mut();
                    match code_tile(
                        w,
                        &f,
                        &mut t.rec,
                        t.bufs,
                        t.payload,
                        syms,
                        hook,
                        &mut hs,
                        *i,
                        tile_first[*i],
                        tile_first[*i + 1],
                    ) {
                        Ok((s, x)) => {
                            t.nsym = s;
                            t.nfixed = x;
                        }
                        Err(e) => {
                            t.err = Some(e);
                            stop.store(true, Ordering::Relaxed);
                        }
                    }
                }
            };
            let work = &work;
            std::thread::scope(|s| launch(s, &mut self.workers[..nworkers], work));
            // the first error in tile order: every tile before an erroneous one was taken (and
            // completed), so it is the one sequential coding reports
            for (_, task) in tasks {
                let t = task.into_inner().unwrap();
                if let Some(e) = t.err {
                    return Err(e);
                }
                nsym += t.nsym;
                nfixed += t.nfixed;
            }
        }

        let level = (opts.seq_level_idx >= 0).then_some(opts.seq_level_idx);
        let mut tiles_hdr = tiles;
        let context_tile = f.context_tile as u32;
        {
            let g = self.saved.lock().unwrap();
            match (g.0, &mut out.saved_cdfs) {
                (true, Some(b)) => b.clone_from(&g.1),
                (true, o) => *o = Some(g.1.clone()),
                (false, o) => *o = None,
            }
        }
        let (tile_bytes, level) = frame_obus(
            &fp,
            &mut tiles_hdr,
            context_tile,
            level,
            &self.payloads,
            opts.flags & ENC_TD != 0,
            &mut self.seq,
            &mut self.fh,
            &mut out.obu,
        );
        out.seq_level_idx = level as u32;
        out.tile_cols = tiles.cols;
        out.tile_rows = tiles.rows;
        out.tile_bytes = tile_bytes;
        out.header_bytes = (out.obu.len() as u64 - tile_bytes) as u32;
        out.n_symbols = nsym;
        out.n_fixed_txb = nfixed as u32;
        if opts.flags & ENC_AVIF != 0 {
            // AVIF item data never carries a temporal delimiter
            let skip = if opts.flags & ENC_TD != 0 { 2 } else { 0 };
            match crate::avif::mux_avif(&out.obu[skip..], w, h) {
                Ok(a) => out.avif = a,
                Err(_) => fail!(ERR_INTERNAL, "AVIF mux failed"),
            }
        }
        if need_planes {
            recon(
                &mut self.tiles,
                &mut self.frame,
                &mut self.cdef_out,
                &f,
                ntiles,
                opts.flags & ENC_PREFILTER_RECON != 0,
                out,
            );
        }
        Ok(())
    }
}

/// Runs `work` on every worker: this thread takes the first, and starts two threads that do the
/// same for the halves of the rest, so the last thread starts after log2(workers) spawns rather than
/// after all of them.
fn launch<'s, 'e: 's, F: Fn(&mut Worker) + Sync>(s: &'s std::thread::Scope<'s, 'e>, ws: &'e mut [Worker], work: &'e F) {
    let (me, rest) = ws.split_first_mut().unwrap();
    let (a, b) = rest.split_at_mut(rest.len() / 2);
    for half in [b, a] {
        if !half.is_empty() {
            s.spawn(move || launch(s, half, work));
        }
    }
    work(me);
}

/// The reconstruction outputs: the padded pre-filter frame, or the post-filtered, cropped one.
fn recon(
    tiles: &mut [TileBufs],
    frame: &mut FrameBufs,
    cdef_out: &mut [Vec<u8>; 3],
    f: &Frame,
    ntiles: usize,
    prefilter: bool,
    out: &mut Output,
) {
    let fp = &f.fp;
    let nplanes = if f.mono { 1 } else { 3 };
    if prefilter {
        // straight from the tiles: the decoded area up to MiCols * 4 x MiRows * 4 (the filters
        // read it)
        for p in 0..nplanes {
            let sub = (p != 0) as usize;
            let (w, h) = ((f.mi_cols as usize * 4) >> sub, (f.mi_rows as usize * 4) >> sub);
            let o = &mut out.recon[p];
            o.resize(w * h, 0);
            for t in &tiles[..ntiles] {
                let (x0, y0) = ((t.c0 as usize * 4) >> sub, (t.r0 as usize * 4) >> sub);
                let (tw, th) = ((t.mw as usize * 4) >> sub, (t.mh as usize * 4) >> sub);
                let s = t.stride[p];
                for y in 0..th {
                    o[(y0 + y) * w + x0..][..tw].copy_from_slice(&t.plane[p][y * s..][..tw]);
                }
            }
            out.recon_w[p] = w as u32;
            out.recon_h[p] = h as u32;
        }
        return;
    }
    let pstride: [usize; 3] = core::array::from_fn(|p| ((f.sb_cols as usize) * 64) >> (p != 0) as usize);
    let pheight: [usize; 3] = core::array::from_fn(|p| ((f.sb_rows as usize) * 64) >> (p != 0) as usize);
    let (mc, mr) = (f.mi_cols as usize, f.mi_rows as usize);
    // with lf_inter_off, inter blocks' level is 0
    let lf_off = f.inter && fp.lf_inter_off != 0;
    let mut pf_skip = core::mem::take(&mut frame.pf_skip);
    if lf_off {
        pf_skip.clear();
        pf_skip.resize(mr * mc, 0);
        for t in &tiles[..ntiles] {
            let (c0, r0, mw, mh) = (t.c0 as usize, t.r0 as usize, t.mw as usize, t.mh as usize);
            for y in 0..mh {
                for (x, d) in pf_skip[(r0 + y) * mc + c0..][..mw].iter_mut().enumerate() {
                    let k = y * mw + x;
                    *d = t.skip[k] | if t.ref0[k] as i32 == LAST_FRAME { LF_ZERO } else { 0 };
                }
            }
        }
    }
    // the frame: one tile's buffers are it; several tiles' are merged
    let (planes, skip, tx, lf_uv, sb_cdef) = if ntiles == 1 {
        let t = &mut tiles[0];
        (&mut t.plane, &t.skip, &t.tx_size, &t.lf_uv, &t.sb_cdef)
    } else {
        let fb = &mut *frame;
        fb.skip.resize(mr * mc, 0);
        fb.tx.resize(mr * mc, 0);
        for m in &mut fb.lf_uv {
            m.resize((mr >> 1) * (mc >> 1), 0);
        }
        fb.sb_cdef.resize((f.sb_cols * f.sb_rows) as usize, -1);
        for p in 0..nplanes {
            fb.plane[p].resize(pstride[p] * pheight[p], 0);
        }
        for t in &tiles[..ntiles] {
            let (c0, r0, mw, mh) = (t.c0 as usize, t.r0 as usize, t.mw as usize, t.mh as usize);
            for y in 0..mh {
                fb.skip[(r0 + y) * mc + c0..][..mw].copy_from_slice(&t.skip[y * mw..][..mw]);
                fb.tx[(r0 + y) * mc + c0..][..mw].copy_from_slice(&t.tx_size[y * mw..][..mw]);
            }
            let (cc, cw) = (mc >> 1, mw >> 1);
            for k in 0..2 {
                for y in 0..mh >> 1 {
                    fb.lf_uv[k][((r0 >> 1) + y) * cc + (c0 >> 1)..][..cw].copy_from_slice(&t.lf_uv[k][y * cw..][..cw]);
                }
            }
            let (sc0, sr0, tsc) = (c0 >> 4, r0 >> 4, t.sb_cols as usize);
            for y in 0..t.sb_rows as usize {
                fb.sb_cdef[(sr0 + y) * f.sb_cols as usize + sc0..][..tsc].copy_from_slice(&t.sb_cdef[y * tsc..][..tsc]);
            }
            for p in 0..nplanes {
                let sub = (p != 0) as usize;
                let (x0, y0) = ((c0 * 4) >> sub, (r0 * 4) >> sub);
                let (tw, th) = ((mw * 4) >> sub, (mh * 4) >> sub);
                let s = t.stride[p];
                for y in 0..th {
                    fb.plane[p][(y0 + y) * pstride[p] + x0..][..tw].copy_from_slice(&t.plane[p][y * s..][..tw]);
                }
            }
        }
        (&mut fb.plane, &fb.skip, &fb.tx, &fb.lf_uv, &fb.sb_cdef)
    };
    let skip: &[u8] = if lf_off { &pf_skip } else { skip };
    // Deblocking (spec 7.14) then CDEF (7.15): the decoder's output frame. The maps come from
    // the walk.
    let pf = PfFrame::new(fp);
    let m = PfMaps {
        skip,
        lf_tx: [tx, &lf_uv[0], &lf_uv[1]],
        cdef_idx: sb_cdef,
    };
    {
        let [p0, p1, p2] = &mut *planes;
        let mut pl: [&mut [u8]; 3] = [p0, p1, p2];
        deblock_frame(&pf, &m, &mut pl, &pstride);
    }
    let result: &[Vec<u8>; 3] = if fp.enable_cdef != 0 {
        for p in 0..nplanes {
            cdef_out[p].resize(planes[p].len(), 0);
        }
        let [d0, d1, d2] = cdef_out;
        let mut dst: [&mut [u8]; 3] = [d0, d1, d2];
        let src: [&[u8]; 3] = [&planes[0], &planes[1], &planes[2]];
        cdef_frame(&pf, &m, &src, &pstride, &mut dst, &pstride);
        cdef_out
    } else {
        planes
    };
    for p in 0..nplanes {
        let sub = (p != 0) as u32;
        let (w, h) = ((fp.width + sub) >> sub, (fp.height + sub) >> sub);
        let o = &mut out.recon[p];
        o.resize((w * h) as usize, 0);
        for y in 0..h as usize {
            o[y * w as usize..][..w as usize].copy_from_slice(&result[p][y * pstride[p]..][..w as usize]);
        }
        out.recon_w[p] = w;
        out.recon_h[p] = h;
    }
    frame.pf_skip = pf_skip;
}

/// av1g_encode with a fresh [`Writer`].
pub fn encode(rec: RecordMut, opts: &EncodeOpts) -> Result<Output, Error> {
    let mut out = Output::default();
    Writer::new().encode(rec, opts, &mut out)?;
    Ok(out)
}

/// av1g_validate: block sequence / partition derivation and field ranges, by coding the symbols
/// without a reconstruction. As av1g_validate, it writes the tx blocks' eob and chroma tx_type.
pub fn validate(rec: RecordMut) -> Result<(), Error> {
    let opts = EncodeOpts {
        flags: ENC_SKIP_RECON | ENC_NO_RECON,
        seq_level_idx: -1,
    };
    Writer::with_threads(1).encode(rec, &opts, &mut Output::default())
}
