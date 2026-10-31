//! The CPU half of the hybrid encoder (Sources/AV1Encoder/src/hybrid.cpp, av1enc.h's
//! `av1enc_hybrid_*`): the closed loop on blocks the Metal analysis decided (partition and luma
//! modes). Per block, chroma modes and CfL from the source; then the writer with a [`TxbHook`],
//! which gets each tx block's exact prediction and chooses its coefficients (the GPU's dead-zone
//! quantizer, luma tx types by exact reconstruction error), reconstructing as it goes, tiles on
//! parallel threads; then skip flags for all-zero blocks. The caller filters the reconstruction and
//! writes the bitstream ([`Hybrid::write`]).
//!
//! From av1gpu's CPU reference engine (BSD-2): its forward transform (here also in float), padded
//! source, Hadamard cost proxy, chroma decisions and quantization hook, which the reference engine
//! ([`crate::testsupport::ref_engine`]) shares.
//!
//! **Tiles kept across pictures.** Prediction never crosses a tile and its CDFs start afresh, so a
//! tile whose blocks' decisions and source are unchanged codes to the same coefficients and
//! reconstruction; and to the same bytes while its cdef_idx values and cdef_bits are unchanged too.
//! The C++ copies each coded tile's source, coefficients and reconstruction aside; here the previous
//! picture's record and reconstruction are kept whole (two of each, alternating), and the source is
//! compared with the previous one while it is padded. A tile whose source and block positions are
//! unchanged also keeps its chroma decisions (they read nothing else). The results are the C++'s.
//!
//! [`TxbHook`]: crate::writer::TxbHook
#![allow(clippy::too_many_arguments, clippy::needless_range_loop)]

mod decide;
mod fwd;
#[cfg(target_arch = "aarch64")]
mod fwd_neon;
mod quant;
#[cfg(test)]
pub(crate) mod tests;

pub(crate) use decide::{DecOpts, Decider, Src, pad_source};
pub(crate) use quant::{HookOpts, QuantHook};

use crate::blockinfo::{bh4, bw4, for_each_txb_ex, has_chroma, max_tx_depth, mi_cols, mi_rows};
use crate::entropy::FrameCdfs;
use crate::tables::{BLOCK_SIZES, DC_PRED, DCT_DCT};
use crate::types::*;
use crate::writer::{
    Error, Extras, LayoutCounts, NoHook, Output, Record, RefPicture, RefSlots, TileSkip, Writer, layout_counts_ex,
    tile_layout,
};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

pub(crate) use crate::enc::fmac;

/// [`fmac`] in float.
#[cfg_attr(target_arch = "aarch64", allow(dead_code))]
#[inline(always)]
pub(crate) fn fmacf(a: f32, b: f32, c: f32) -> f32 {
    #[cfg(target_arch = "aarch64")]
    {
        a.mul_add(b, c)
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        a * b + c
    }
}

/// [`Hybrid::closed_loop`] flags (AV1ENC_HYBRID_GIVEN_CHROMA): the blocks' uv_mode /
/// angle_delta_uv / cfl_alpha_* are decided already.
pub const GIVEN_CHROMA: i32 = 1;

/// A frame of a stream for [`Hybrid::closed_loop_ex`] (av1enc_hybrid_closed_loop_ex).
#[derive(Clone, Copy, Debug)]
pub struct Video<'a> {
    /// the frame's video fields: video, frame_type, ref_slot, refresh_frame_flags,
    /// error_resilient_mode, lf_inter_off, allow_screen_content_tools (the rest is ignored)
    pub fp: FrameParams,
    /// inter frames: one per block (empty: every block intra). Inter blocks are skip blocks
    /// (tx_depth 0, intra fields 0): they copy LAST_FRAME at their motion vector.
    pub inter: &'a [BlockInter],
    /// inter frames: LAST_FRAME's picture (the decoder's output of the frame in fp.ref_slot)
    pub reference: Option<RefPicture<'a>>,
}

/// The Metal encoder's dead zone (GpParams rnd, zbin).
const QUANT_RND: f64 = 0.375;
const QUANT_ZBIN: f64 = 0.656;

fn error(code: i32, msg: &str) -> Error {
    Error {
        code,
        msg: msg.to_string(),
    }
}

/// What a tile was last coded from and to, beyond the previous picture's record and
/// reconstruction.
#[derive(Clone, Debug)]
struct TileMem {
    valid: bool,
    payload_valid: bool,
    /// its chroma decisions were the closed loop's (not given)
    cpu_chroma: bool,
    luma_tx: Vec<u8>,
    payload: Vec<u8>,
    /// its blocks' cdef_idx when `payload` was written
    cdef: Vec<i8>,
    cdef_bits: i32,
}

impl Default for TileMem {
    fn default() -> Self {
        TileMem {
            valid: false,
            payload_valid: false,
            cpu_chroma: false,
            luma_tx: Vec::new(),
            payload: Vec::new(),
            cdef: Vec::new(),
            cdef_bits: -1,
        }
    }
}

/// The hybrid encoder's CPU state (av1enc_hybrid): one per stream. The record, the reconstruction
/// and the padded source of the last closed loop live here until the next call, at stable
/// addresses while the picture's geometry stays the same.
pub struct Hybrid {
    src: Src,
    /// per-tile reuse, for one geometry and quantizer
    mem: Vec<TileMem>,
    /// this picture's tiles taken from the previous one
    reused: Vec<bool>,
    reused_count: u32,
    /// block ranges, tile raster order (this picture's and the previous one's)
    tile_first: Vec<u32>,
    prev_tile_first: Vec<u32>,
    tiles: Option<Tiles>,
    key: [u64; 4],
    reuse: bool,
    /// the records and reconstructions of this picture (`cur`) and the previous one
    recs: [Record; 2],
    outs: [Output; 2],
    cur: usize,
    /// the last write's
    obu: Output,
    writer: Writer,
    seconds: [f64; 2],
    threads: usize,
    src_changed: Vec<bool>,
    keep_chroma: Vec<bool>,
    /// the last closed loop coded an inter frame (its tiles aren't kept)
    last_inter: bool,
    /// video mode: each reference slot's saved CDFs, from the writes that refreshed it
    slot_cdfs: [Option<Box<FrameCdfs>>; 8],
}

impl Default for Hybrid {
    fn default() -> Self {
        Self::new()
    }
}

/// av1g_block equality but for skip and cdef_idx (the C++ compares its decisions with those
/// zeroed).
#[inline]
fn same_decisions(a: &Block, b: &Block) -> bool {
    let (mut a, mut b) = (*a, *b);
    (a.skip, a.cdef_idx, b.skip, b.cdef_idx) = (0, 0, 0, 0);
    a == b
}

/// A tile's coded area in luma samples: (x0, y0, x1, y1).
fn area(t: &Tiles, i: usize, mi_cols: usize, mi_rows: usize) -> (usize, usize, usize, usize) {
    let (tr, tc) = (i / t.cols as usize, i % t.cols as usize);
    (
        t.mi_col_starts[tc] as usize * 4,
        t.mi_row_starts[tr] as usize * 4,
        (t.mi_col_starts[tc + 1] as usize).min(mi_cols) * 4,
        (t.mi_row_starts[tr + 1] as usize).min(mi_rows) * 4,
    )
}

impl Hybrid {
    /// av1enc_hybrid_create.
    pub fn new() -> Hybrid {
        Hybrid {
            src: Src::default(),
            mem: Vec::new(),
            reused: Vec::new(),
            reused_count: 0,
            tile_first: Vec::new(),
            prev_tile_first: Vec::new(),
            tiles: None,
            key: [0; 4],
            reuse: true,
            recs: Default::default(),
            outs: Default::default(),
            cur: 0,
            obu: Output::default(),
            writer: Writer::new(),
            seconds: [0.0; 2],
            threads: std::thread::available_parallelism().map_or(1, |n| n.get()),
            src_changed: Vec::new(),
            keep_chroma: Vec::new(),
            last_inter: false,
            slot_cdfs: Default::default(),
        }
    }

    /// av1enc_hybrid_closed_loop: the closed loop on blocks the Metal analysis decided (mi_row,
    /// mi_col, bsize, y_mode and angle_delta_y set; the rest is decided here), on 8-bit 4:2:0
    /// planes (tight: Y w x h, U and V ((w + 1) / 2) x ((h + 1) / 2)), with the given tiling.
    /// `luma_tx`: every block's luma tx type, kept instead of searched. `flags`: [`GIVEN_CHROMA`].
    /// On success [`Hybrid::record`] has the record (chroma modes, coefficients, skip flags) and
    /// [`Hybrid::recon`] the exact pre-filter reconstruction.
    pub fn closed_loop(
        &mut self,
        y: &[u8],
        u: &[u8],
        v: &[u8],
        width: u32,
        height: u32,
        blocks: &[Block],
        luma_tx: Option<&[u8]>,
        flags: i32,
        qindex: i32,
        tile_cols_log2: i32,
        tile_rows_log2: i32,
    ) -> Result<(), Error> {
        self.closed_loop_ex(
            y,
            u,
            v,
            width,
            height,
            blocks,
            luma_tx,
            flags,
            qindex,
            tile_cols_log2,
            tile_rows_log2,
            None,
        )
    }

    /// av1enc_hybrid_closed_loop_ex: [`Hybrid::closed_loop`] for a frame of a stream. An inter
    /// frame's tiles are coded afresh, and the next picture's aren't kept from it.
    pub fn closed_loop_ex(
        &mut self,
        y: &[u8],
        u: &[u8],
        v: &[u8],
        width: u32,
        height: u32,
        blocks: &[Block],
        luma_tx: Option<&[u8]>,
        flags: i32,
        qindex: i32,
        tile_cols_log2: i32,
        tile_rows_log2: i32,
        video: Option<&Video>,
    ) -> Result<(), Error> {
        let (w, h) = (width as usize, height as usize);
        let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
        let n = blocks.len();
        if n == 0
            || w < 1
            || h < 1
            || w > 65535
            || h > 65535
            || y.len() < w * h
            || u.len() < cw * ch
            || v.len() < cw * ch
            || luma_tx.is_some_and(|l| l.len() < n)
            || video.is_some_and(|v| !v.inter.is_empty() && v.inter.len() != n)
        {
            return Err(error(ERR_INVALID, "bad arguments"));
        }
        let r = self.run(
            [y, u, v],
            width,
            height,
            blocks,
            luma_tx,
            flags,
            qindex,
            tile_cols_log2,
            tile_rows_log2,
            video,
        );
        if r.is_err() {
            // the source and the records were overwritten: nothing is kept
            for m in &mut self.mem {
                m.valid = false;
                m.payload_valid = false;
            }
        }
        r
    }

    fn run(
        &mut self,
        planes: [&[u8]; 3],
        width: u32,
        height: u32,
        given: &[Block],
        luma_tx: Option<&[u8]>,
        flags: i32,
        qindex: i32,
        tile_cols_log2: i32,
        tile_rows_log2: i32,
        video: Option<&Video>,
    ) -> Result<(), Error> {
        let t0 = Instant::now();
        let given_chroma = flags & GIVEN_CHROMA != 0;
        let inter_frame = video.is_some_and(|v| v.fp.frame_type == FRAME_INTER);
        if inter_frame || self.last_inter {
            // tiles are kept by their decisions and source, which an inter block's reference
            // isn't part of
            for m in &mut self.mem {
                m.valid = false;
                m.payload_valid = false;
            }
        }
        self.last_inter = inter_frame;
        self.cur ^= 1;
        let cur = self.cur;
        let Hybrid {
            src,
            mem,
            reused,
            reused_count,
            tile_first,
            prev_tile_first,
            tiles: tiles_out,
            key: key_out,
            reuse,
            recs,
            outs,
            writer,
            seconds,
            threads,
            src_changed,
            keep_chroma,
            slot_cdfs,
            ..
        } = self;
        let inter: &[BlockInter] = video.map_or(&[], |v| v.inter);
        let is_inter = |b: usize| inter.get(b).is_some_and(|i| i.is_inter != 0);
        let reuse = *reuse;
        let [r0, r1] = recs;
        let (rec, prev) = if cur == 0 { (r0, &*r1) } else { (r1, &*r0) };
        let [o0, o1] = outs;
        let (out, prev_out) = if cur == 0 { (o0, &*o1) } else { (o1, &*o0) };
        out.clear();
        let (w, h) = (width as usize, height as usize);
        rec.fp = FrameParams {
            version: DECISIONS_VERSION,
            width,
            height,
            base_q_idx: qindex as u8,
            tile_cols_log2: tile_cols_log2 as i8,
            tile_rows_log2: tile_rows_log2 as i8,
            ..FrameParams::default()
        };
        if let Some(v) = video {
            let f = &mut rec.fp;
            (f.video, f.frame_type, f.ref_slot) = (v.fp.video, v.fp.frame_type, v.fp.ref_slot);
            (f.refresh_frame_flags, f.error_resilient_mode) = (v.fp.refresh_frame_flags, v.fp.error_resilient_mode);
            (f.lf_inter_off, f.allow_screen_content_tools) = (v.fp.lf_inter_off, v.fp.allow_screen_content_tools);
            // from the reference's saved CDFs, where the slot has them
            f.cdf_from_ref = (v.fp.cdf_from_ref != 0 && slot_cdfs[(v.fp.ref_slot & 7) as usize].is_some()) as u8;
        }
        rec.inter.clear();
        rec.inter.extend_from_slice(inter);
        let (mc, mr) = (mi_cols(width as i32), mi_rows(height as i32));
        let (sb_cols, sb_rows) = (((mc + 15) >> 4) as usize, ((mr + 15) >> 4) as usize);
        let (mcu, mru) = (mc as usize, mr as usize);
        // rows of the source on several threads: a 5K picture is 22 MB
        let pad_threads = ((sb_cols * sb_rows * 6144) >> 20).clamp(1, 8).min(*threads);
        let Ok(tiles) = tile_layout(width, height, tile_cols_log2, tile_rows_log2) else {
            pad_source(planes, w, h, sb_cols, sb_rows, 3, src, pad_threads, None);
            return Err(error(ERR_INVALID, "tiling"));
        };
        let ntiles = (tiles.rows * tiles.cols) as usize;
        let key = [
            width as u64,
            height as u64,
            ((tile_cols_log2 as u32 as u64) << 32) | tile_rows_log2 as u32 as u64,
            qindex as i64 as u64,
        ];
        if key != *key_out || mem.len() != ntiles {
            mem.clear();
            mem.resize(ntiles, TileMem::default());
            *key_out = key;
        }
        let compare = reuse && mem.iter().any(|m| m.valid);
        src_changed.clear();
        src_changed.resize(ntiles, false);
        let cmp = compare.then(|| decide::Compare {
            tiles: &tiles,
            mi_cols: mcu,
            mi_rows: mru,
            changed: &mut src_changed[..],
        });
        pad_source(planes, w, h, sb_cols, sb_rows, 3, src, pad_threads, cmp);

        rec.blocks.clear();
        rec.blocks.extend_from_slice(given);
        let n = given.len();
        // an inter block's skip is given (a copy: no residual); elsewhere it's the closed loop's
        for (i, b) in rec.blocks.iter_mut().enumerate() {
            b.skip = if is_inter(i) { b.skip.min(1) } else { 0 };
        }
        if !given_chroma {
            // the chroma decisions read the blocks' areas: no block outside the padded source
            for b in &rec.blocks {
                let bs = b.bsize as i32;
                if bs >= BLOCK_SIZES
                    || bw4(bs) > 16
                    || bh4(bs) > 16
                    || b.mi_row as i32 >= mr
                    || b.mi_col as i32 >= mc
                    || b.mi_row as usize + bh4(bs) as usize > sb_rows * 16
                    || b.mi_col as usize + bw4(bs) as usize > sb_cols * 16
                {
                    return Err(error(ERR_INVALID, "layout"));
                }
            }
        }
        // every tile's blocks: those inside it, contiguous in tile order
        tile_first.clear();
        let mut c = 0usize;
        for tr in 0..tiles.rows as usize {
            for tc in 0..tiles.cols as usize {
                tile_first.push(c as u32);
                let (r0, r1) = (tiles.mi_row_starts[tr], tiles.mi_row_starts[tr + 1]);
                let (c0, c1) = (tiles.mi_col_starts[tc], tiles.mi_col_starts[tc + 1]);
                while c < n {
                    let b = &rec.blocks[c];
                    if (b.mi_row as u32) < r0
                        || b.mi_row as u32 >= r1
                        || (b.mi_col as u32) < c0
                        || b.mi_col as u32 >= c1
                    {
                        break;
                    }
                    c += 1;
                }
            }
        }
        tile_first.push(c as u32);
        let have_prev = compare && prev_tile_first.len() == ntiles + 1;
        let prange = |i: usize| (prev_tile_first[i] as usize, prev_tile_first[i + 1] as usize);
        let range = |i: usize| (tile_first[i] as usize, tile_first[i + 1] as usize);

        // ---- chroma ----
        let qi = qindex as u8;
        if given_chroma {
            // the GPU decided chroma: only the fields the closed loop sets
            for b in rec.blocks.iter_mut() {
                (b.tx_depth, b.sb_qindex) = (0, qi);
            }
        } else {
            // A tile whose source and block positions are unchanged keeps its chroma decisions:
            // they read only those.
            keep_chroma.clear();
            keep_chroma.resize(ntiles, false);
            if have_prev {
                for i in 0..ntiles {
                    let m = &mem[i];
                    let ((b0, b1), (p0, p1)) = (range(i), prange(i));
                    keep_chroma[i] = m.valid
                        && m.cpu_chroma
                        && !src_changed[i]
                        && b1 - b0 == p1 - p0
                        && rec.blocks[b0..b1]
                            .iter()
                            .zip(&prev.blocks[p0..p1])
                            .all(|(a, b)| (a.mi_row, a.mi_col, a.bsize) == (b.mi_row, b.mi_col, b.bsize));
                    if keep_chroma[i] {
                        for (b, p) in rec.blocks[b0..b1].iter_mut().zip(&prev.blocks[p0..p1]) {
                            (b.skip, b.tx_depth, b.sb_qindex) = (0, 0, qi);
                            (b.uv_mode, b.angle_delta_uv) = (p.uv_mode, p.angle_delta_uv);
                            (b.cfl_alpha_u, b.cfl_alpha_v) = (p.cfl_alpha_u, p.cfl_alpha_v);
                        }
                    }
                }
            }
            // the others from the source, on every core (each block's decision is its own), 64
            // blocks at a time
            // a block's index from its address (inter blocks get no chroma decision)
            let (base, size) = (rec.blocks.as_ptr() as usize, size_of::<Block>());
            let mut chunks: Vec<&mut [Block]> = Vec::new();
            let mut rest: &mut [Block] = &mut rec.blocks;
            let mut at = 0usize;
            for i in 0..ntiles {
                if !keep_chroma[i] {
                    let (b0, b1) = range(i);
                    chunks.extend(take_range(&mut rest, &mut at, b0, b1).chunks_mut(64));
                }
            }
            chunks.extend(take_range(&mut rest, &mut at, tile_first[ntiles] as usize, n).chunks_mut(64));
            let step = crate::dsp::ac_q(qindex) as f64 / 8.0;
            let dec = Decider::new(src, hybrid_dec_opts(), mc, mr, false, step, step);
            par_for(
                *threads,
                &mut chunks,
                || dec.clone(),
                |d, chunk| {
                    for b in chunk.iter_mut() {
                        let (mut tc, mut tr) = (0usize, 0usize); // the block's tile, for edge availability
                        while tc + 1 < tiles.cols as usize && tiles.mi_col_starts[tc + 1] <= b.mi_col as u32 {
                            tc += 1;
                        }
                        while tr + 1 < tiles.rows as usize && tiles.mi_row_starts[tr + 1] <= b.mi_row as u32 {
                            tr += 1;
                        }
                        d.tx0 = tiles.mi_col_starts[tc] as i32 * 4;
                        d.ty0 = tiles.mi_row_starts[tr] as i32 * 4;
                        let inter_block = is_inter((b as *const Block as usize - base) / size);
                        (b.tx_depth, b.sb_qindex) = (0, qi);
                        (b.uv_mode, b.angle_delta_uv, b.cfl_alpha_u, b.cfl_alpha_v) = (DC_PRED as u8, 0, 0, 0);
                        let (bs, r, c) = (b.bsize as i32, b.mi_row as i32, b.mi_col as i32);
                        if !inter_block && has_chroma(bs, r, c, false) {
                            d.best_chroma(c * 4, r * 4, bs, b);
                        }
                    }
                },
            );
        }
        if layout_tiles(rec, tile_first, (n / 2048).clamp(1, *threads)).is_err() {
            return Err(error(ERR_INVALID, "layout"));
        }
        if let Some(l) = luma_tx {
            // one luma tx block per block at tx_depth 0
            for b in 0..n {
                let (t0, t1) = (rec.block_txb[b] as usize, rec.block_txb[b + 1] as usize);
                for t in &mut rec.txb[t0..t1] {
                    if t.plane == 0 {
                        t.tx_type = l[b];
                    }
                }
            }
        }
        let t1 = Instant::now();

        // ---- tiles unchanged since they were last coded keep their closed loop ----
        *tiles_out = Some(tiles);
        reused.clear();
        reused.resize(ntiles, false);
        *reused_count = 0;
        if reuse && have_prev && tile_first[ntiles] as usize == n {
            let pn_txb = prev.txb.len();
            let mut parts = split_tiles(rec, tile_first);
            par_for(
                (n / 2048).clamp(1, *threads),
                &mut parts,
                || (),
                |_, t| {
                    let i = t.i;
                    let m = &mem[i];
                    if !m.valid || src_changed[i] {
                        return;
                    }
                    let (p0, p1) = prange(i);
                    let nb = t.blocks.len();
                    if nb != p1 - p0
                        || !t
                            .blocks
                            .iter()
                            .zip(&prev.blocks[p0..p1])
                            .all(|(a, b)| same_decisions(a, b))
                    {
                        return;
                    }
                    if let Some(l) = luma_tx
                        && (m.luma_tx.len() < nb || l[t.b0..t.b0 + nb] != m.luma_tx[..nb])
                    {
                        return;
                    }
                    // the tile's coefficients, tx types and skip flags as they were
                    let (q0, q1) = (prev.block_txb[p0] as usize, prev.block_txb[p1] as usize);
                    if t.txb.len() != q1 - q0 {
                        return;
                    }
                    let d0 = if q0 < q1 { prev.txb[q0].coeff_off as usize } else { 0 };
                    let d1 = if q1 < pn_txb {
                        prev.txb[q1].coeff_off as usize
                    } else {
                        prev.coeffs.len()
                    };
                    if t.coeffs.len() != d1 - d0 {
                        return;
                    }
                    for (x, p) in t.txb.iter_mut().zip(&prev.txb[q0..q1]) {
                        (x.tx_type, x.eob) = (p.tx_type, p.eob);
                    }
                    t.coeffs.copy_from_slice(&prev.coeffs[d0..d1]);
                    for (b, p) in t.blocks.iter_mut().zip(&prev.blocks[p0..p1]) {
                        b.skip = p.skip;
                    }
                    t.kept = true;
                },
            );
            for t in &parts {
                reused[t.i] = t.kept;
                *reused_count += t.kept as u32;
            }
        }
        let hook = QuantHook::new(
            src,
            HookOpts {
                tx_types: true,
                reduced_tx_set: false,
                given_luma_tx: luma_tx.is_some() as i32,
                rnd: QUANT_RND,
                zbin: QUANT_ZBIN,
                double_fwd: false,
            },
        );
        let skips: Vec<TileSkip> = reused.iter().map(|&skip| TileSkip { skip, payload: None }).collect();
        let opts = EncodeOpts {
            flags: ENC_FIX_RANGE | ENC_PREFILTER_RECON,
            seq_level_idx: -1,
        };
        let mut slots: RefSlots = [None; 8];
        if let Some(v) = video
            && inter_frame
        {
            let s = (v.fp.ref_slot & 7) as usize;
            slots[s] = v.reference.map(|r| RefPicture {
                cdfs: slot_cdfs[s].as_deref(),
                ..r
            });
        }
        let extras = Extras {
            tile_skip: Some(&skips),
            record_syms: false,
            refs: inter_frame.then_some(&slots),
        };
        writer.encode_with_hook(rec.as_mut(), &opts, Some(&hook), &extras, out)?;
        if *reused_count > 0 {
            // kept tiles' reconstruction, into the picture's: by plane and tile row
            let recon_w = out.recon_w;
            let mut rows: Vec<(usize, usize, &mut [u8])> = Vec::new();
            for (p, plane) in out.recon.iter_mut().enumerate() {
                let sub = (p > 0) as usize;
                let stride = recon_w[p] as usize;
                let mut rest: &mut [u8] = plane;
                for tr in 0..tiles.rows as usize {
                    let y0 = (tiles.mi_row_starts[tr] as usize * 4) >> sub;
                    let y1 = ((tiles.mi_row_starts[tr + 1] as usize).min(mru) * 4) >> sub;
                    let (part, r) = core::mem::take(&mut rest).split_at_mut((y1 - y0) * stride);
                    rest = r;
                    rows.push((p, tr, part));
                }
            }
            let nthreads = (*reused_count as usize).min(rows.len()).clamp(1, *threads);
            par_for(
                nthreads,
                &mut rows,
                || (),
                |_, (p, tr, part)| {
                    let (p, tr) = (*p, *tr);
                    let sub = (p > 0) as usize;
                    let stride = recon_w[p] as usize;
                    let y0 = (tiles.mi_row_starts[tr] as usize * 4) >> sub;
                    for tc in 0..tiles.cols as usize {
                        let i = tr * tiles.cols as usize + tc;
                        if !reused[i] {
                            continue;
                        }
                        let (x0, _, x1, _) = area(&tiles, i, mcu, mru);
                        let (px0, pw) = (x0 >> sub, (x1 - x0) >> sub);
                        for (y, row) in part.chunks_mut(stride).enumerate() {
                            let o = (y0 + y) * stride + px0;
                            row[px0..px0 + pw].copy_from_slice(&prev_out.recon[p][o..o + pw]);
                        }
                    }
                },
            );
        }
        for i in 0..ntiles {
            if reused[i] {
                continue;
            }
            let (b0, b1) = range(i);
            for b in b0..b1 {
                // skip flags change no reconstruction before the filters
                let (t0, t1) = (rec.block_txb[b] as usize, rec.block_txb[b + 1] as usize);
                if rec.txb[t0..t1].iter().all(|t| t.eob == 0) {
                    rec.blocks[b].skip = 1;
                }
            }
            // remember it
            let m = &mut mem[i];
            m.luma_tx.clear();
            if let Some(l) = luma_tx {
                m.luma_tx.extend_from_slice(&l[b0..b1]);
            }
            m.valid = true;
            m.payload_valid = false;
            m.cpu_chroma = !given_chroma;
        }
        prev_tile_first.clear();
        prev_tile_first.extend_from_slice(tile_first);
        let t2 = Instant::now();
        *seconds = [(t1 - t0).as_secs_f64(), (t2 - t1).as_secs_f64()];
        Ok(())
    }

    /// av1enc_hybrid_write: the bitstream of the last closed loop's picture with the post-filter
    /// parameters chosen (`fp`) and every 64x64's cdef_idx (`sb_cdef`, raster, `sb_cols` wide; -1
    /// as 0; `None`: all 0): [TD,] sequence header and frame. A tile whose closed loop was kept, and
    /// whose cdef_idx values and cdef_bits are as last written, keeps its bytes. The bytes live
    /// here until the next write.
    pub fn write(&mut self, fp: &FrameParams, sb_cdef: Option<&[i8]>, sb_cols: usize) -> Result<&[u8], Error> {
        let Hybrid {
            mem,
            reused,
            tile_first,
            reuse,
            recs,
            cur,
            obu,
            writer,
            slot_cdfs,
            ..
        } = self;
        let rec = &mut recs[*cur];
        rec.fp = *fp;
        for k in &mut rec.blocks {
            let c = match sb_cdef {
                Some(s) => match s.get((k.mi_row as usize >> 4) * sb_cols + (k.mi_col as usize >> 4)) {
                    Some(&c) => c,
                    None => return Err(error(ERR_INVALID, "sb_cdef doesn't cover the picture")),
                },
                None => 0,
            };
            k.cdef_idx = c.max(0);
        }
        // a reused tile keeps its bytes while its cdef_idx values and cdef_bits are as they were coded
        let ntiles = mem.len();
        let cdef_bits = if fp.enable_cdef != 0 { fp.cdef_bits as i32 } else { -1 };
        let skips: Vec<TileSkip> = (0..ntiles)
            .map(|i| {
                let m = &mem[i];
                let skip = *reuse
                    && reused.get(i).is_some_and(|&r| r)
                    && m.payload_valid
                    && m.cdef_bits == cdef_bits
                    && tile_first.len() > i + 1
                    && {
                        let (b0, b1) = (tile_first[i] as usize, tile_first[i + 1] as usize);
                        m.cdef.len() == b1 - b0 && rec.blocks[b0..b1].iter().zip(&m.cdef).all(|(b, &c)| b.cdef_idx == c)
                    };
                TileSkip {
                    skip,
                    payload: Some(&m.payload),
                }
            })
            .collect();
        let opts = EncodeOpts {
            flags: ENC_TD | ENC_BITSTREAM_ONLY,
            seq_level_idx: -1,
        };
        // an inter frame reads its reference's saved CDFs (no planes: the bitstream only)
        let inter = fp.frame_type == FRAME_INTER;
        let mut slots: RefSlots = [None; 8];
        if inter {
            let s = (fp.ref_slot & 7) as usize;
            slots[s] = Some(RefPicture {
                cdfs: slot_cdfs[s].as_deref(),
                ..Default::default()
            });
        }
        let extras = Extras {
            tile_skip: Some(&skips),
            record_syms: false,
            refs: inter.then_some(&slots),
        };
        writer.encode_with_hook::<NoHook>(rec.as_mut(), &opts, None, &extras, obu)?;
        // the slots it refreshes keep its saved CDFs (none known: a later frame starts afresh)
        if fp.video != 0 {
            let refresh = if inter { fp.refresh_frame_flags } else { 0xFF };
            for (i, s) in slot_cdfs.iter_mut().enumerate() {
                if refresh >> i & 1 != 0 {
                    match (&obu.saved_cdfs, s.as_mut()) {
                        (Some(c), Some(b)) => b.clone_from(c),
                        (Some(c), None) => *s = Some(c.clone()),
                        (None, _) => *s = None,
                    }
                }
            }
        }
        let skipped: Vec<bool> = skips.iter().map(|s| s.skip).collect();
        let payloads = writer.tile_payloads();
        for i in 0..ntiles.min(payloads.len()) {
            let m = &mut mem[i];
            if skipped[i] || !m.valid {
                continue;
            }
            let (b0, b1) = (tile_first[i] as usize, tile_first[i + 1] as usize);
            m.payload.clear();
            m.payload.extend_from_slice(&payloads[i]);
            m.cdef.clear();
            m.cdef.extend(rec.blocks[b0..b1].iter().map(|b| b.cdef_idx));
            m.cdef_bits = cdef_bits;
            m.payload_valid = true;
        }
        Ok(&obu.obu)
    }

    /// av1enc_hybrid_set_reuse: keep unchanged tiles' closed loop and bitstream from picture to
    /// picture (on by default).
    pub fn set_reuse(&mut self, on: bool) {
        self.reuse = on;
        if !on {
            self.mem.clear();
        }
    }

    /// av1enc_hybrid_reused_tiles: tiles the last closed loop kept.
    pub fn reused_tiles(&self) -> u32 {
        self.reused_count
    }

    /// av1enc_hybrid_changed_superblocks: per 64x64 (raster, `sb_cols` x `sb_rows` into `out`),
    /// nonzero where the last closed loop re-coded the tile: elsewhere the reconstruction, blocks
    /// and source are the previous picture's. Returns false if unknown.
    pub fn changed_superblocks(&self, out: &mut [u8], sb_cols: usize, sb_rows: usize) -> bool {
        let Some(t) = &self.tiles else { return false };
        if self.reused.len() != (t.rows * t.cols) as usize || self.reused.is_empty() || out.len() < sb_cols * sb_rows {
            return false;
        }
        for r in 0..sb_rows {
            for c in 0..sb_cols {
                let (mut tc, mut tr) = (0usize, 0usize);
                while tc + 1 < t.cols as usize && t.mi_col_starts[tc + 1] as usize <= c * 16 {
                    tc += 1;
                }
                while tr + 1 < t.rows as usize && t.mi_row_starts[tr + 1] as usize <= r * 16 {
                    tr += 1;
                }
                out[r * sb_cols + c] = !self.reused[tr * t.cols as usize + tc] as u8;
            }
        }
        true
    }

    /// av1enc_hybrid_record: the last closed loop's record.
    pub fn record(&self) -> &Record {
        &self.recs[self.cur]
    }

    /// The record as av1g_decision_record: pointers into this `Hybrid`'s vectors, valid until the
    /// next closed loop or write.
    pub fn record_c(&mut self) -> DecisionRecord {
        self.recs[self.cur].as_c()
    }

    /// av1enc_hybrid_recon: plane `plane`'s pre-filter reconstruction of the last closed loop,
    /// `MiCols * 4 >> sub` wide and `MiRows * 4 >> sub` high (sub = 1 for chroma); empty after a
    /// failure, `None` for a plane > 2.
    pub fn recon(&self, plane: usize) -> Option<&[u8]> {
        self.outs[self.cur].recon.get(plane).map(|p| &p[..])
    }

    /// The last closed loop's output (its reconstruction's sizes, and the stats of its encode).
    pub fn output(&self) -> &Output {
        &self.outs[self.cur]
    }

    /// av1enc_hybrid_source: the source the last call coded, padded by edge replication to whole
    /// superblocks (at least the post-filters' MiCols * 4 x MiRows * 4, chroma half), and its
    /// stride; `None` for a plane > 2.
    pub fn source(&self, plane: usize) -> Option<(&[u8], usize)> {
        (plane < 3).then(|| (&self.src.p[plane][..], self.src.stride[plane]))
    }

    /// av1enc_hybrid_seconds: the last call's seconds: 0 chroma decisions, 1 closed loop.
    pub fn seconds(&self, which: usize) -> f64 {
        self.seconds[(which != 0) as usize]
    }
}

/// Runs `f` on every task on up to `threads` threads (this one included), each thread with its own
/// state from `init`.
fn par_for<T: Send, S>(
    threads: usize,
    tasks: &mut [T],
    init: impl Fn() -> S + Sync,
    f: impl Fn(&mut S, &mut T) + Sync,
) {
    let n = threads.min(tasks.len());
    if n <= 1 {
        let mut s = init();
        for t in tasks {
            f(&mut s, t);
        }
        return;
    }
    let cells: Vec<Mutex<&mut T>> = tasks.iter_mut().map(Mutex::new).collect();
    let next = AtomicUsize::new(0);
    let work = || {
        let mut s = init();
        loop {
            let k = next.fetch_add(1, Ordering::Relaxed);
            let Some(c) = cells.get(k) else { break };
            f(&mut s, &mut c.lock().unwrap());
        }
    };
    std::thread::scope(|sc| {
        for _ in 1..n {
            sc.spawn(work);
        }
        work();
    });
}

/// `rest[b0 - at..b1 - at]`, with `rest` and `at` moved past it (ranges taken in order).
fn take_range<'a, T>(rest: &mut &'a mut [T], at: &mut usize, b0: usize, b1: usize) -> &'a mut [T] {
    let (_, r) = core::mem::take(rest).split_at_mut(b0 - *at);
    let (part, r) = r.split_at_mut(b1 - b0);
    *rest = r;
    *at = b1;
    part
}

/// One tile's part of a laid-out record.
struct TileParts<'a> {
    i: usize,
    b0: usize,
    blocks: &'a mut [Block],
    txb: &'a mut [Txb],
    coeffs: &'a mut [i16],
    kept: bool,
}

/// The tiles' parts of a laid-out record: blocks `tile_first[i]..tile_first[i + 1]`, their tx
/// blocks and coefficients (contiguous and in order in a layout).
fn split_tiles<'a>(rec: &'a mut Record, tile_first: &[u32]) -> Vec<TileParts<'a>> {
    let ntiles = tile_first.len() - 1;
    let ranges: Vec<(usize, usize, usize, usize, usize, usize)> = (0..ntiles)
        .scan(0usize, |c, i| {
            let (b0, b1) = (tile_first[i] as usize, tile_first[i + 1] as usize);
            let (t0, t1) = (rec.block_txb[b0] as usize, rec.block_txb[b1] as usize);
            let c0 = *c;
            if t1 > t0 {
                let last = &rec.txb[t1 - 1];
                *c = last.coeff_off as usize + crate::dsp::tx_coeffs(last.tx_size as i32);
            }
            Some((b0, b1, t0, t1, c0, *c))
        })
        .collect();
    let (mut blocks, mut txb, mut coeffs): (&mut [Block], &mut [Txb], &mut [i16]) =
        (&mut rec.blocks, &mut rec.txb, &mut rec.coeffs);
    let (mut bat, mut tat, mut cat) = (0, 0, 0);
    ranges
        .into_iter()
        .enumerate()
        .map(|(i, (b0, b1, t0, t1, c0, c1))| TileParts {
            i,
            b0,
            blocks: take_range(&mut blocks, &mut bat, b0, b1),
            txb: take_range(&mut txb, &mut tat, t0, t1),
            coeffs: take_range(&mut coeffs, &mut cat, c0, c1),
            kept: false,
        })
        .collect()
}

/// [`Record::layout`] (av1g_layout), tile by tile on `threads` threads: the same layout.
fn layout_tiles(rec: &mut Record, tile_first: &[u32], threads: usize) -> Result<(), i32> {
    let n = rec.blocks.len();
    let ntiles = tile_first.len() - 1;
    if threads <= 1 || ntiles < 2 || tile_first[ntiles] as usize != n {
        return rec.layout().map(drop);
    }
    let fp = rec.fp;
    let inter = &rec.inter;
    let tile_inter = |b0: usize, b1: usize| if inter.is_empty() { &inter[..] } else { &inter[b0..b1] };
    let mut counts: Vec<(usize, usize, Result<LayoutCounts, i32>)> = (0..ntiles)
        .map(|i| {
            (
                tile_first[i] as usize,
                tile_first[i + 1] as usize,
                Ok(LayoutCounts::default()),
            )
        })
        .collect();
    let blocks = &rec.blocks;
    par_for(
        threads,
        &mut counts,
        || (),
        |_, (b0, b1, c)| *c = layout_counts_ex(&fp, &blocks[*b0..*b1], tile_inter(*b0, *b1)),
    );
    let mut base = Vec::with_capacity(ntiles);
    let (mut nt, mut nc) = (0u32, 0u64);
    for (_, _, c) in &counts {
        let c = (*c)?;
        base.push((nt, nc));
        nt += c.n_txb;
        nc += c.n_coeffs;
    }
    rec.block_txb.resize(n + 1, 0);
    rec.txb.resize(nt as usize, Txb::default());
    rec.coeffs.resize(nc as usize, 0);
    rec.block_txb[n] = nt;
    struct Fill<'a> {
        blocks: &'a [Block],
        inter: &'a [BlockInter],
        block_txb: &'a mut [u32],
        txb: &'a mut [Txb],
        t0: u32,
        c0: u64,
    }
    let (mut bt, mut tx): (&mut [u32], &mut [Txb]) = (&mut rec.block_txb[..n], &mut rec.txb);
    let (mut bat, mut tat) = (0, 0);
    let blocks = &rec.blocks;
    let mut fills: Vec<Fill> = (0..ntiles)
        .map(|i| {
            let (b0, b1) = (counts[i].0, counts[i].1);
            let (t0, c0) = base[i];
            let t1 = if i + 1 < ntiles { base[i + 1].0 } else { nt };
            Fill {
                blocks: &blocks[b0..b1],
                inter: tile_inter(b0, b1),
                block_txb: take_range(&mut bt, &mut bat, b0, b1),
                txb: take_range(&mut tx, &mut tat, t0 as usize, t1 as usize),
                t0,
                c0,
            }
        })
        .collect();
    let (mi_c, mi_r, mono) = (mi_cols(fp.width as i32), mi_rows(fp.height as i32), fp.monochrome != 0);
    par_for(
        threads,
        &mut fills,
        || (),
        |_, f| {
            let (mut k, mut c) = (0usize, f.c0);
            for (j, b) in f.blocks.iter().enumerate() {
                f.block_txb[j] = f.t0 + k as u32;
                let bs = b.bsize as i32;
                let depth = (b.tx_depth as i32).min(max_tx_depth(bs));
                for_each_txb_ex(
                    bs,
                    b.mi_row as i32,
                    b.mi_col as i32,
                    depth,
                    f.inter.get(j).is_some_and(|i| i.is_inter != 0),
                    mono,
                    mi_r,
                    mi_c,
                    |plane, tx_sz, x4, y4, _, _| {
                        f.txb[k] = Txb {
                            coeff_off: c as u32,
                            x4: x4 as u16,
                            y4: y4 as u16,
                            plane: plane as u8,
                            tx_size: tx_sz as u8,
                            tx_type: DCT_DCT as u8,
                            flags: 0,
                            eob: 0,
                            reserved: 0,
                        };
                        k += 1;
                        c += crate::dsp::tx_coeffs(tx_sz) as u64;
                    },
                );
            }
        },
    );
    Ok(())
}

// the C API keeps a Hybrid behind a handle Swift may use from any thread
const _: () = {
    const fn send<T: Send>() {}
    send::<Hybrid>();
};

/// The hybrid's decision options (HybridOpts).
fn hybrid_dec_opts() -> DecOpts {
    DecOpts {
        min_block: 8,
        max_block: 64,
        angle_deltas: true,
        cfl: true,
        split_bias: 1.0,
    }
}
