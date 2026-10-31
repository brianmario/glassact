//! av1gpu's CPU reference decision engine (Sources/AV1CoreTestSupport/ref_engine.cpp, and
//! ref_capi.cpp's av1t_ref_encode): valid and reasonable, not good.
//!
//! 1. Pre-pass, per 64x64 superblock, open loop on source pixels (threads over SBs): top-down
//!    partition search (NONE vs SPLIT, square blocks min_block..64) with a Hadamard-domain RD proxy;
//!    luma mode = best of 13 modes, then angle-delta refinement of the best directional mode;
//!    chroma mode = best of 13 modes + CfL (least-squares alpha). tx_depth 0 (TX_MODE_LARGEST).
//! 2. Closed loop through the writer's [`TxbHook`](crate::writer::TxbHook): for every tx block
//!    the exact prediction is available; residual -> forward transform (derived numerically from
//!    the exact inverse 1-D transforms) -> plain rounding quantization. Luma tx type = argmin over
//!    the intra set of exact SSE + lambda * rate proxy.
//! 3. Blocks whose tx blocks are all zero get skip = 1 and the record is re-encoded (the
//!    reconstruction is unchanged; checked).
//!
//! The decisions and the hook are the hybrid encoder's ([`crate::hybrid`]), with the double
//! forward transform and rounding quantizer.
#![allow(clippy::needless_range_loop)]
use crate::blockinfo::{has_chroma, mi_cols, mi_rows};
use crate::dsp::{ac_q, qm_level_allintra};
use crate::hybrid::{DecOpts, Decider, HookOpts, QuantHook, Src, fmac, pad_source};
use crate::postfilter::postfilter;
use crate::tables::UV_CFL_PRED;
use crate::types::*;
use crate::writer::{Error, Extras, Output, Record, Writer, legalize_sb_qindex, tile_layout};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

#[cfg(all(test, feature = "oracle"))]
mod tests;

/// av1t_ref_opts: the reference engine's options in the C API.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RefOpts {
    /// 1..255
    pub qindex: i32,
    /// 4 or 8
    pub min_block: i32,
    /// 8..64
    pub max_block: i32,
    /// deblocking level for every plane, -1 off
    pub lf_level: i32,
    /// 1: one fixed CDEF preset
    pub cdef: i32,
    /// 1: intra edge filter
    pub edge_filter: i32,
}

/// RefEngineOpts: every option of the engine.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RefEngineOpts {
    pub qindex: i32,
    /// smallest block edge used by the partition search (4 or 8)
    pub min_block: i32,
    pub max_block: i32,
    pub angle_deltas: bool,
    pub cfl: bool,
    pub tx_types: bool,
    pub reduced_tx_set: bool,
    /// > 1 favours larger blocks
    pub split_bias: f64,
    /// quantizer matrix level 0..15 for luma (-1: off, -2: libaom's all-intra curve)
    pub qm_level: i32,
    /// chroma level (-1: same as luma)
    pub qm_level_uv: i32,
    /// activity-based per-SB qindex (simple variance boost)
    pub deltaq: bool,
    /// delta_q_res (step 1 << res)
    pub deltaq_res: i32,
    /// qindex per log2 unit of SB activity relative to the frame mean
    pub deltaq_strength: f64,
    /// enable_intra_edge_filter (prediction only; decisions unchanged)
    pub edge_filter: bool,
    /// deblocking level for all planes and directions (-1: off); no search
    pub lf_level: i32,
    pub lf_sharpness: i32,
    /// CDEF with one fixed preset for every 64x64 (cdef_bits 0); no search
    pub cdef: bool,
    pub cdef_y_pri: i32,
    pub cdef_y_sec: i32,
    pub cdef_uv_pri: i32,
    pub cdef_uv_sec: i32,
    pub cdef_damping: i32,
}

impl Default for RefEngineOpts {
    fn default() -> Self {
        RefEngineOpts {
            qindex: 100,
            min_block: 8,
            max_block: 64,
            angle_deltas: true,
            cfl: true,
            tx_types: true,
            reduced_tx_set: false,
            split_bias: 1.0,
            qm_level: -1,
            qm_level_uv: -1,
            deltaq: false,
            deltaq_res: 2,
            deltaq_strength: 6.0,
            edge_filter: false,
            lf_level: -1,
            lf_sharpness: 0,
            cdef: false,
            cdef_y_pri: 4,
            cdef_y_sec: 1,
            cdef_uv_pri: 2,
            cdef_uv_sec: 1,
            cdef_damping: 5,
        }
    }
}

impl From<&RefOpts> for RefEngineOpts {
    /// av1t_ref_encode's options: the C API's fields, the defaults otherwise.
    fn from(o: &RefOpts) -> Self {
        RefEngineOpts {
            qindex: o.qindex,
            min_block: o.min_block,
            max_block: o.max_block,
            lf_level: o.lf_level,
            cdef: o.cdef != 0,
            edge_filter: o.edge_filter != 0,
            ..RefEngineOpts::default()
        }
    }
}

/// A cropped 8-bit source picture: Y w x h, U / V ((w + 1) / 2) x ((h + 1) / 2), tightly packed
/// (U and V unused if `mono`).
#[derive(Clone, Copy, Debug)]
pub struct Image<'a> {
    pub w: u32,
    pub h: u32,
    pub mono: bool,
    pub planes: [&'a [u8]; 3],
}

/// What the engine decided, and how long it took.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RefEngineStats {
    pub seconds_decide: f64,
    pub seconds_encode: f64,
    pub blocks: u32,
    pub skip_blocks: u32,
    pub cfl_blocks: u32,
}

fn error(code: i32, msg: &str) -> Error {
    Error {
        code,
        msg: msg.to_string(),
    }
}

/// av1t_ref_encode: the reference engine on 8-bit 4:2:0 planes (Y w x h, U and V ((w + 1) / 2) x
/// ((h + 1) / 2), tightly packed). The output has the OBUs, the AVIF and the decoder's (filtered,
/// cropped) reconstruction.
pub fn ref_encode(y: &[u8], u: &[u8], v: &[u8], w: u32, h: u32, opts: &RefOpts) -> Result<Output, Error> {
    let img = Image {
        w,
        h,
        mono: false,
        planes: [y, u, v],
    };
    ref_engine_encode(&img, &opts.into(), &mut Record::default(), None)
}

/// ref_engine_encode: the record (in `rec`) and the encoded picture of `img`.
pub fn ref_engine_encode(
    img: &Image,
    o: &RefEngineOpts,
    rec: &mut Record,
    stats: Option<&mut RefEngineStats>,
) -> Result<Output, Error> {
    let (wu, hu) = (img.w as usize, img.h as usize);
    let (cw, ch) = (wu.div_ceil(2), hu.div_ceil(2));
    let nplanes = if img.mono { 1 } else { 3 };
    if img.w < 1
        || img.h < 1
        || img.w > 65535
        || img.h > 65535
        || img.planes[0].len() < wu * hu
        || (nplanes == 3 && (img.planes[1].len() < cw * ch || img.planes[2].len() < cw * ch))
    {
        return Err(error(ERR_INVALID, "bad image"));
    }
    let t0 = Instant::now();
    let mut fp = FrameParams {
        version: DECISIONS_VERSION,
        width: img.w,
        height: img.h,
        monochrome: img.mono as u8,
        base_q_idx: o.qindex as u8,
        tx_mode_select: 0,
        reduced_tx_set: o.reduced_tx_set as u8,
        tile_cols_log2: -1,
        tile_rows_log2: -1,
        ..FrameParams::default()
    };
    if o.qm_level >= 0 || o.qm_level == -2 {
        let lv = if o.qm_level == -2 {
            qm_level_allintra(o.qindex)
        } else {
            o.qm_level
        };
        fp.using_qmatrix = 1;
        fp.qm_y = lv as u8;
        fp.qm_u = if o.qm_level_uv >= 0 { o.qm_level_uv } else { lv } as u8;
        fp.qm_v = fp.qm_u;
    }
    fp.enable_intra_edge_filter = o.edge_filter as u8;
    if o.lf_level > 0 {
        fp.loop_filter_level = [o.lf_level.min(63) as u8; 4];
        fp.loop_filter_sharpness = o.lf_sharpness as u8;
    }
    if o.cdef {
        // cdef_idx stays 0 in every block: one preset
        fp.enable_cdef = 1;
        fp.cdef_damping_minus_3 = (o.cdef_damping - 3) as u8;
        fp.cdef_bits = 0;
        fp.cdef_y_pri[0] = o.cdef_y_pri as u8;
        fp.cdef_y_sec[0] = o.cdef_y_sec as u8;
        fp.cdef_uv_pri[0] = o.cdef_uv_pri as u8;
        fp.cdef_uv_sec[0] = o.cdef_uv_sec as u8;
    }
    let (mc, mr) = (mi_cols(img.w as i32), mi_rows(img.h as i32));
    let (sb_cols, sb_rows) = (((mc + 15) >> 4) as usize, ((mr + 15) >> 4) as usize);
    let mut src = Src::default();
    pad_source(img.planes, wu, hu, sb_cols, sb_rows, nplanes, &mut src, 1, None);
    let tiles = tile_layout(img.w, img.h, -1, -1).map_err(|c| error(c, "tiling"))?;
    // pixel-domain quantizer steps (Ac_Qlookup is 8x the orthonormal step)
    let (step_y, step_c) = (ac_q(o.qindex) as f64 / 8.0, ac_q(o.qindex) as f64 / 8.0);
    let dopts = DecOpts {
        min_block: o.min_block,
        max_block: o.max_block,
        angle_deltas: o.angle_deltas,
        cfl: o.cfl,
        split_bias: o.split_bias,
    };
    let mut dec = Decider::new(&src, dopts, mc, mr, img.mono, step_y, step_c);
    // ---- delta-q: per-SB qindex from luma activity (log2 mean 8x8 variance vs frame mean) ----
    let mut sbq = Vec::new();
    if o.deltaq {
        fp.delta_q_present = 1;
        fp.delta_q_res = o.deltaq_res as u8;
        let mut act = vec![0.0f64; sb_cols * sb_rows];
        let mut mean = 0.0;
        let mut nsb = 0;
        let (cw4, ch4) = (mc as usize * 4, mr as usize * 4);
        for sr in 0..sb_rows {
            for sc in 0..sb_cols {
                let mut v = 0.0f64;
                let mut nb = 0;
                for by in (sr * 64..(sr * 64 + 64).min(ch4)).step_by(8) {
                    for bx in (sc * 64..(sc * 64 + 64).min(cw4)).step_by(8) {
                        let (mut s1, mut s2) = (0.0f64, 0.0f64);
                        for y in 0..8 {
                            for &p in &src.at(0, bx, by + y)[..8] {
                                let p = p as f64;
                                s1 += p;
                                s2 = fmac(p, p, s2);
                            }
                        }
                        v += fmac(-(s1 / 64.0), s1 / 64.0, s2 / 64.0);
                        nb += 1;
                    }
                }
                let a = (1.0 + v / nb.max(1) as f64).log2();
                act[sr * sb_cols + sc] = a;
                mean += a;
                nsb += 1;
            }
        }
        mean /= nsb.max(1) as f64;
        let max_off = 8.max(o.qindex / 3);
        let target: Vec<u8> = act
            .iter()
            .map(|&a| {
                let off = ((o.deltaq_strength * (a - mean)).round_ties_even() as i64 as i32).clamp(-max_off, max_off);
                (o.qindex + off).clamp(1, 255) as u8
            })
            .collect();
        sbq.resize(target.len(), 0);
        legalize_sb_qindex(o.qindex, o.deltaq_res, &target, &mut sbq);
        dec.sbq = Some(&sbq);
        dec.sb_cols = sb_cols;
    }

    // ---- pre-pass: superblocks in decode order, decided in parallel ----
    let mut jobs = Vec::new();
    for tr in 0..tiles.rows as usize {
        for tc in 0..tiles.cols as usize {
            let (tx0, ty0) = (tiles.mi_col_starts[tc] as i32 * 4, tiles.mi_row_starts[tr] as i32 * 4);
            for r in (tiles.mi_row_starts[tr]..tiles.mi_row_starts[tr + 1]).step_by(16) {
                for c in (tiles.mi_col_starts[tc]..tiles.mi_col_starts[tc + 1]).step_by(16) {
                    jobs.push((r as i32, c as i32, tx0, ty0));
                }
            }
        }
    }
    let sb_blocks: Vec<Mutex<Vec<Block>>> = jobs.iter().map(|_| Mutex::new(Vec::new())).collect();
    let next = AtomicUsize::new(0);
    let nthreads = std::thread::available_parallelism().map_or(1, |n| n.get()).min(4);
    let work = || {
        let mut d = dec.clone();
        loop {
            let i = next.fetch_add(1, Ordering::Relaxed);
            let Some(&(r, c, tx0, ty0)) = jobs.get(i) else { break };
            (d.tx0, d.ty0) = (tx0, ty0);
            d.node(r, c, 6, &mut sb_blocks[i].lock().unwrap());
        }
    };
    std::thread::scope(|s| {
        for _ in 1..nthreads {
            s.spawn(work);
        }
        work();
    });
    *rec = Record::new(
        fp,
        sb_blocks.into_iter().flat_map(|b| b.into_inner().unwrap()).collect(),
    );
    if rec.layout().is_err() {
        return Err(error(ERR_INTERNAL, "layout failed"));
    }
    let t1 = Instant::now();

    // ---- closed loop ----
    let hook = QuantHook::new(
        &src,
        HookOpts {
            tx_types: o.tx_types,
            reduced_tx_set: o.reduced_tx_set,
            given_luma_tx: 0,
            rnd: 0.5,
            zbin: 0.0,
            double_fwd: true,
        },
    );
    // pre-filter (padded) recon in both passes: skip flags legitimately change CDEF's output
    let mut opts = EncodeOpts {
        flags: ENC_FIX_RANGE | ENC_PREFILTER_RECON,
        seq_level_idx: -1,
    };
    let mut writer = Writer::new();
    let mut o1 = Output::default();
    writer.encode_with_hook(rec.as_mut(), &opts, Some(&hook), &Extras::default(), &mut o1)?;
    // ---- skip pass ----
    let (mut nskip, mut ncfl) = (0u32, 0u32);
    for b in 0..rec.blocks.len() {
        let (t0, t1) = (rec.block_txb[b] as usize, rec.block_txb[b + 1] as usize);
        if rec.txb[t0..t1].iter().all(|t| t.eob == 0) {
            rec.blocks[b].skip = 1;
            nskip += 1;
        }
        let k = &rec.blocks[b];
        if k.uv_mode as i32 == UV_CFL_PRED && has_chroma(k.bsize as i32, k.mi_row as i32, k.mi_col as i32, img.mono) {
            ncfl += 1;
        }
    }
    opts.flags = ENC_AVIF | ENC_PREFILTER_RECON;
    let mut out = Output::default();
    writer.encode(rec.as_mut(), &opts, &mut out)?;
    if (0..nplanes).any(|p| o1.recon[p] != out.recon[p]) {
        return Err(error(ERR_INTERNAL, "internal: skip pass changed the reconstruction"));
    }
    {
        // decoder output = post-filtered, cropped
        let stride: [usize; 3] = core::array::from_fn(|p| out.recon_w[p] as usize);
        let [p0, p1, p2] = &mut out.recon;
        postfilter(&rec.fp, &rec.blocks, &mut [p0, p1, p2], &stride);
        for p in 0..nplanes {
            let (w, h) = if p > 0 { (cw, ch) } else { (wu, hu) };
            let mut c = Vec::with_capacity(w * h);
            for y in 0..h {
                c.extend_from_slice(&out.recon[p][y * stride[p]..][..w]);
            }
            out.recon[p] = c;
            out.recon_w[p] = w as u32;
            out.recon_h[p] = h as u32;
        }
    }
    let t2 = Instant::now();
    if let Some(s) = stats {
        *s = RefEngineStats {
            seconds_decide: (t1 - t0).as_secs_f64(),
            seconds_encode: (t2 - t1).as_secs_f64(),
            blocks: rec.blocks.len() as u32,
            skip_blocks: nskip,
            cfl_blocks: ncfl,
        };
    }
    Ok(out)
}
