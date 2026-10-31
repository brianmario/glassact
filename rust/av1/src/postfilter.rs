//! The decoder's post-filters for intra frames (Sources/AV1Core/include/av1g/postfilter.h):
//!
//! - deblocking loop filter (spec 7.14): [`lf_edge`] filters one 4-sample edge segment,
//!   [`deblock_frame`] the frame;
//! - CDEF (spec 7.15): [`cdef_setup`] + [`cdef_pixel`], or [`cdef_block`] / [`cdef_frame`];
//! - [`postfilter`]: both, as the C API `av1g_postfilter` applies them to a record's planes.
//!
//! The frame is a [`PfFrame`] (the frame-level parameters) plus [`PfMaps`], the 4x4-granular maps
//! the filters read (Skips, LoopfilterTxSizes per plane, cdef_idx per 64x64). [`PfMapsBuf`] builds
//! them from a record's blocks.
//!
//! Order (spec 7.14 / 7.15): deblock every plane - pass 0 (vertical edges) of a plane completes
//! before its pass 1 (horizontal edges); within a pass all edges are independent - then CDEF reads
//! the deblocked frame and writes a separate output frame; all 8x8 blocks are independent. 8-bit,
//! 4:2:0 or monochrome, no segmentation / delta-lf / lossless; `lf_level` are the effective levels
//! (Y vertical, Y horizontal, U, V).
//!
//! On aarch64 the frame-level functions run NEON filters (postfilter/neon.rs) for whole edge rows
//! and interior 8x8 blocks; the scalar functions stay the reference.
#![allow(clippy::too_many_arguments, clippy::needless_range_loop)]

use crate::blockinfo::*;
use crate::dsp::{clip3, round2};
use crate::tables::*;
use crate::types::{Block, FrameParams};

#[cfg(target_arch = "aarch64")]
mod lf_neon;
#[cfg(target_arch = "aarch64")]
mod neon;
#[cfg(test)]
mod tests;

/// The frame-level parameters of the post-filters (av1g_pf_frame without its pointers).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PfFrame {
    pub w: i32,
    pub h: i32,
    pub mi_rows: i32,
    pub mi_cols: i32,
    pub mono: bool,
    pub sb_cols: i32,
    pub sb_rows: i32,
    /// effective loop filter levels Y vertical, Y horizontal, U, V (0..63); 0 = off
    pub lf_level: [i32; 4],
    /// 0..7
    pub sharpness: i32,
    pub enable_cdef: bool,
    /// CdefDamping = cdef_damping_minus_3 + 3
    pub cdef_damping: i32,
    /// secondary strengths are 0, 1, 2, 4
    pub cdef_y_pri: [i32; 8],
    pub cdef_y_sec: [i32; 8],
    pub cdef_uv_pri: [i32; 8],
    pub cdef_uv_sec: [i32; 8],
}

impl PfFrame {
    /// av1g_pf_frame_init: the frame-level parameters of a record.
    pub fn new(fp: &FrameParams) -> PfFrame {
        let mi_rows = mi_rows(fp.height as i32);
        let mi_cols = mi_cols(fp.width as i32);
        let mut lf_level = fp.loop_filter_level.map(|v| v as i32);
        if fp.loop_filter_level[0] == 0 && fp.loop_filter_level[1] == 0 {
            lf_level[2] = 0;
            lf_level[3] = 0;
        }
        PfFrame {
            w: fp.width as i32,
            h: fp.height as i32,
            mi_rows,
            mi_cols,
            mono: fp.monochrome != 0,
            sb_cols: (mi_cols + 15) >> 4,
            sb_rows: (mi_rows + 15) >> 4,
            lf_level,
            sharpness: fp.loop_filter_sharpness as i32,
            enable_cdef: fp.enable_cdef != 0,
            cdef_damping: fp.cdef_damping_minus_3 as i32 + 3,
            cdef_y_pri: fp.cdef_y_pri.map(|v| v as i32),
            cdef_y_sec: fp.cdef_y_sec.map(|v| v as i32),
            cdef_uv_pri: fp.cdef_uv_pri.map(|v| v as i32),
            cdef_uv_sec: fp.cdef_uv_sec.map(|v| v as i32),
        }
    }
    fn planes(&self) -> usize {
        if self.mono { 1 } else { 3 }
    }
}

/// The maps the filters read: `skip` (Skips) and `lf_tx[0]` (luma LoopfilterTxSizes) are MiRows x
/// MiCols, stride MiCols; `lf_tx[1..3]` are (MiRows / 2) x (MiCols / 2), stride MiCols / 2;
/// `cdef_idx` is per 64x64, raster, stride sbCols, -1 = no CDEF (no non-skip block in it).
/// [`PfMaps::skip`]'s bit for a block whose loop filter level is 0 (fp.lf_inter_off's inter
/// blocks); bit 0 is the block's skip.
pub const LF_ZERO: u8 = 2;

#[derive(Clone, Copy, Debug)]
pub struct PfMaps<'a> {
    /// per luma 4x4: the block's skip, and [`LF_ZERO`]
    pub skip: &'a [u8],
    pub lf_tx: [&'a [u8]; 3],
    pub cdef_idx: &'a [i8],
}

/// Owned [`PfMaps`], built from a record's blocks.
#[derive(Clone, Debug, Default)]
pub struct PfMapsBuf {
    pub skip: Vec<u8>,
    pub lf_tx: [Vec<u8>; 3],
    pub cdef_idx: Vec<i8>,
}

impl PfMapsBuf {
    /// Zeroed maps with cdef_idx = -1 everywhere.
    pub fn new(f: &PfFrame) -> PfMapsBuf {
        let nmi = (f.mi_rows * f.mi_cols) as usize;
        let nuv = ((f.mi_rows >> 1) * (f.mi_cols >> 1)) as usize;
        PfMapsBuf {
            skip: vec![0; nmi],
            lf_tx: [vec![0; nmi], vec![0; nuv], vec![0; nuv]],
            cdef_idx: vec![-1; (f.sb_cols * f.sb_rows) as usize],
        }
    }
    /// av1g_pf_mark_block: writes one block's entries (Skips / LoopfilterTxSizes / cdef_idx).
    pub fn mark_block(&mut self, f: &PfFrame, b: &Block) {
        self.mark_block_ex(f, b, false);
    }
    /// av1g_pf_mark_block_ex: [`PfMapsBuf::mark_block`] with the block's loop filter level 0 or
    /// not ([`LF_ZERO`]).
    pub fn mark_block_ex(&mut self, f: &PfFrame, b: &Block, lf_zero: bool) {
        let (r0, c0, bs) = (b.mi_row as i32, b.mi_col as i32, b.bsize as i32);
        let (bw, bh) = (bw4(bs), bh4(bs));
        let tx_y = luma_tx_size(bs, b.tx_depth as i32) as u8;
        for y in r0..(r0 + bh).min(f.mi_rows) {
            for x in c0..(c0 + bw).min(f.mi_cols) {
                let k = (y * f.mi_cols + x) as usize;
                self.skip[k] = b.skip | if lf_zero { LF_ZERO } else { 0 };
                self.lf_tx[0][k] = tx_y;
            }
        }
        if has_chroma(bs, r0, c0, f.mono) {
            let (uv_sz, tx_uv) = (uv_bsize(bs), uv_tx_size(bs) as u8);
            let (cr, cc, y0, x0) = (f.mi_rows >> 1, f.mi_cols >> 1, r0 >> 1, c0 >> 1);
            let (w, h) = (bw4(uv_sz), bh4(uv_sz));
            for y in y0..(y0 + h).min(cr) {
                for x in x0..(x0 + w).min(cc) {
                    let k = (y * cc + x) as usize;
                    self.lf_tx[1][k] = tx_uv;
                    self.lf_tx[2][k] = tx_uv;
                }
            }
        }
        if f.enable_cdef && b.skip == 0 {
            self.cdef_idx[((r0 >> 4) * f.sb_cols + (c0 >> 4)) as usize] = b.cdef_idx;
        }
    }
    pub fn maps(&self) -> PfMaps<'_> {
        PfMaps {
            skip: &self.skip,
            lf_tx: [&self.lf_tx[0], &self.lf_tx[1], &self.lf_tx[2]],
            cdef_idx: &self.cdef_idx,
        }
    }
}

/// Filter path counters for the tests (AV1G_PF_STAT): masked, narrow+hev, narrow, wide6, wide8,
/// wide16, CDEF filtered 8x8, CDEF clamped sample.
#[cfg(test)]
pub(crate) static PF_STAT: [std::sync::atomic::AtomicU64; 8] = [const { std::sync::atomic::AtomicU64::new(0) }; 8];
#[inline(always)]
fn stat(_k: usize) {
    #[cfg(test)]
    PF_STAT[_k].fetch_add(1, std::sync::atomic::Ordering::Relaxed);
}

// ---------------- deblocking ----------------

/// The filter levels of a plane / pass: (limit, blimit, thresh) of 7.14.4, or None when its level
/// is 0. Frame-level levels: the re-evaluation at (prevRow, prevCol) when lvl == 0 gives the same.
#[inline]
pub fn lf_limits(f: &PfFrame, plane: usize, pass: usize) -> Option<(i32, i32, i32)> {
    let lvl = f.lf_level[if plane == 0 { pass } else { plane + 1 }];
    if lvl == 0 {
        return None;
    }
    let shift = if f.sharpness > 4 {
        2
    } else if f.sharpness > 0 {
        1
    } else {
        0
    };
    let limit = if f.sharpness > 0 {
        clip3(1, 9 - f.sharpness, lvl >> shift)
    } else {
        (lvl >> shift).max(1)
    };
    Some((limit, 2 * (lvl + 2) + limit, lvl >> 4))
}

/// The sample filtering process (7.14.6) for one line across an edge: `q0` is the index of sample
/// q0 in `p`, `step` the distance between successive samples across the edge (1 or the stride).
pub fn lf_line(
    p: &mut [u8],
    q0: usize,
    step: usize,
    plane: usize,
    filter_size: i32,
    limit: i32,
    blimit: i32,
    thresh: i32,
) {
    let at = |k: isize| (q0 as isize + k * step as isize) as usize;
    let s = |p: &[u8], k: isize| p[at(k)] as i32;
    let (q0v, q1, p0, p1) = (s(p, 0), s(p, 1), s(p, -1), s(p, -2));
    let filter_len = if filter_size == 4 {
        4
    } else if plane != 0 {
        6
    } else if filter_size == 8 {
        8
    } else {
        16
    };
    let mut mask =
        (p1 - p0).abs() > limit || (q1 - q0v).abs() > limit || (p0 - q0v).abs() * 2 + (p1 - q1).abs() / 2 > blimit;
    let (mut q2, mut p2, mut q3, mut p3) = (0, 0, 0, 0);
    if filter_len >= 6 {
        (q2, p2) = (s(p, 2), s(p, -3));
        mask |= (p2 - p1).abs() > limit || (q2 - q1).abs() > limit;
    }
    if filter_len >= 8 {
        (q3, p3) = (s(p, 3), s(p, -4));
        mask |= (p3 - p2).abs() > limit || (q3 - q2).abs() > limit;
    }
    if mask {
        stat(0);
        return; // filterMask == 0
    }
    let hev = (p1 - p0).abs() > thresh || (q1 - q0v).abs() > thresh;
    let mut flat = false;
    let mut flat2 = false;
    if filter_size >= 8 {
        let mut m = (p1 - p0).abs() > 1 || (q1 - q0v).abs() > 1 || (p2 - p0).abs() > 1 || (q2 - q0v).abs() > 1;
        if filter_len >= 8 {
            m |= (p3 - p0).abs() > 1 || (q3 - q0v).abs() > 1;
        }
        flat = !m;
    }
    if filter_size >= 16 && flat {
        let (q4, q5, q6, p4, p5, p6) = (s(p, 4), s(p, 5), s(p, 6), s(p, -5), s(p, -6), s(p, -7));
        flat2 = !((p6 - p0).abs() > 1
            || (q6 - q0v).abs() > 1
            || (p5 - p0).abs() > 1
            || (q5 - q0v).abs() > 1
            || (p4 - p0).abs() > 1
            || (q4 - q0v).abs() > 1);
    }
    if filter_size == 4 || !flat {
        // narrow filter (7.14.6.3)
        stat(if hev { 1 } else { 2 });
        let c4 = |v: i32| clip3(-128, 127, v);
        let (ps1, ps0, qs0, qs1) = (p1 - 128, p0 - 128, q0v - 128, q1 - 128);
        let filter = if hev { c4(ps1 - qs1) } else { 0 };
        let filter = c4(filter + 3 * (qs0 - ps0));
        let (filter1, filter2) = (c4(filter + 4) >> 3, c4(filter + 3) >> 3);
        p[at(0)] = (c4(qs0 - filter1) + 128) as u8;
        p[at(-1)] = (c4(ps0 + filter2) + 128) as u8;
        if !hev {
            let fr = round2(filter1, 1);
            p[at(1)] = (c4(qs1 - fr) + 128) as u8;
            p[at(-2)] = (c4(ps1 + fr) + 128) as u8;
        }
        return;
    }
    // wide filter (7.14.6.4)
    let log2_size = if filter_size == 8 || !flat2 { 3 } else { 4 };
    let n: isize = if log2_size == 4 {
        6
    } else if plane == 0 {
        3
    } else {
        2
    };
    let n2: isize = if log2_size == 3 && plane == 0 { 0 } else { 1 };
    stat(match n {
        2 => 3,
        3 => 4,
        _ => 5,
    });
    let mut v = [0i32; 14]; // v[k + n + 1] = S(k), k = -(n + 1) .. n
    for k in -(n + 1)..=n {
        v[(k + n + 1) as usize] = s(p, k);
    }
    let mut out = [0i32; 12];
    for i in -n..n {
        let mut t = 0;
        for j in -n..=n {
            let k = (i + j).clamp(-(n + 1), n);
            t += v[(k + n + 1) as usize] * if j.abs() <= n2 { 2 } else { 1 };
        }
        out[(i + n) as usize] = round2(t, log2_size);
    }
    for i in -n..n {
        p[at(i)] = out[(i + n) as usize] as u8;
    }
}

/// The filter size of the edge at luma 4x4 (row, col) of a plane / pass (7.14.2, 7.14.3), or None
/// when no tx edge is there.
#[inline(always)]
pub(crate) fn lf_filter_size(f: &PfFrame, m: &PfMaps, plane: usize, pass: usize, row: i32, col: i32) -> Option<i32> {
    let sub = (plane != 0) as i32;
    let (x_p, y_p) = ((col * 4) >> sub, (row * 4) >> sub);
    let (row, col) = (row | sub, col | sub);
    let prev_row = row - (((pass == 1) as i32) << sub);
    let prev_col = col - (((pass == 0) as i32) << sub);
    let s = (f.mi_cols >> sub) as usize;
    let lf = m.lf_tx[plane];
    let tx_sz = lf[(row >> sub) as usize * s + (col >> sub) as usize] as usize;
    let prev_tx_sz = lf[(prev_row >> sub) as usize * s + (prev_col >> sub) as usize] as usize;
    // level 0 on both sides (lf_inter_off's inter blocks): the edge isn't filtered
    let mc = f.mi_cols as usize;
    if m.skip[row as usize * mc + col as usize] & m.skip[prev_row as usize * mc + prev_col as usize] & LF_ZERO != 0 {
        return None;
    }
    // applyFilter = isTxEdge && (isBlockEdge || !skip || isIntra): an intra block's edges are
    // its tx edges; a skipped inter block's only tx edges are its block edges (tx_depth 0, at
    // most 64x64), and a coded one's tx edges are filtered: isTxEdge throughout
    let (cur, prev) = if pass == 0 {
        let cur = Tx_Width[tx_sz] as i32;
        if x_p & (cur - 1) != 0 {
            return None;
        }
        (cur, Tx_Width[prev_tx_sz] as i32)
    } else {
        let cur = Tx_Height[tx_sz] as i32;
        if y_p & (cur - 1) != 0 {
            return None;
        }
        (cur, Tx_Height[prev_tx_sz] as i32)
    };
    Some(prev.min(cur).min(if plane != 0 { 8 } else { 16 }))
}

/// The edge loop filter process (7.14.2): plane, pass, luma 4x4 position (row, col) - the 4 lines
/// of one edge segment. Callers visit row / col in steps of 2 for chroma. `pl` is the plane.
pub fn lf_edge(f: &PfFrame, m: &PfMaps, plane: usize, pass: usize, row: i32, col: i32, pl: &mut [u8], stride: usize) {
    let sub = (plane != 0) as i32;
    let (x, y) = (col * 4, row * 4);
    if x >= f.w || y >= f.h || (pass == 0 && x == 0) || (pass == 1 && y == 0) {
        return;
    }
    let Some(filter_size) = lf_filter_size(f, m, plane, pass, row, col) else {
        return;
    };
    let Some((limit, blimit, thresh)) = lf_limits(f, plane, pass) else {
        return;
    };
    let (x_p, y_p) = ((x >> sub) as usize, (y >> sub) as usize);
    let step = if pass == 0 { 1 } else { stride };
    for i in 0..4 {
        let q0 = if pass == 0 {
            (y_p + i) * stride + x_p
        } else {
            y_p * stride + x_p + i
        };
        lf_line(pl, q0, step, plane, filter_size, limit, blimit, thresh);
    }
}

/// Whole-frame deblocking in the spec's order (the scalar reference).
pub fn deblock_frame_scalar(f: &PfFrame, m: &PfMaps, planes: &mut [&mut [u8]; 3], stride: &[usize; 3]) {
    if f.lf_level[0] == 0 && f.lf_level[1] == 0 {
        return;
    }
    for p in 0..f.planes() {
        if p > 0 && f.lf_level[1 + p] == 0 {
            continue;
        }
        let step = if p != 0 { 2 } else { 1 };
        for pass in 0..2 {
            for row in (0..f.mi_rows).step_by(step) {
                for col in (0..f.mi_cols).step_by(step) {
                    lf_edge(f, m, p, pass, row, col, planes[p], stride[p]);
                }
            }
        }
    }
}

/// Whole-frame deblocking in the spec's order: planes as `f` / `m` describe them, filtered in place.
pub fn deblock_frame(f: &PfFrame, m: &PfMaps, planes: &mut [&mut [u8]; 3], stride: &[usize; 3]) {
    #[cfg(target_arch = "aarch64")]
    {
        lf_neon::deblock_frame(f, m, planes, stride);
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        deblock_frame_scalar(f, m, planes, stride);
    }
}

// ---------------- CDEF ----------------

/// FloorLog2; -1 for 0.
#[inline]
pub fn floor_log2(x: u32) -> i32 {
    if x == 0 { -1 } else { 31 - x.leading_zeros() as i32 }
}

/// The CDEF direction process (7.15.2) for the 8x8 luma block at `src` (row stride): (yDir, var).
pub fn cdef_direction(src: &[u8], stride: usize) -> (i32, i32) {
    let mut cost = [0i32; 8];
    let mut partial = [[0i32; 15]; 8];
    for i in 0..8 {
        let row = &src[i * stride..i * stride + 8];
        for (j, &v) in row.iter().enumerate() {
            let x = v as i32 - 128;
            partial[0][i + j] += x;
            partial[1][i + j / 2] += x;
            partial[2][i] += x;
            partial[3][3 + i - j / 2] += x;
            partial[4][7 + i - j] += x;
            partial[5][3 - i / 2 + j] += x;
            partial[6][j] += x;
            partial[7][i / 2 + j] += x;
        }
    }
    cdef_direction_cost(&partial, &mut cost)
}

pub(crate) const CDEF_DIV: [i32; 9] = [0, 840, 420, 280, 210, 168, 140, 120, 105]; // Div_Table (7.15.2)

#[inline(always)]
pub(crate) fn cdef_direction_cost(partial: &[[i32; 15]; 8], cost: &mut [i32; 8]) -> (i32, i32) {
    let div = &CDEF_DIV;
    for i in 0..8 {
        cost[2] += partial[2][i] * partial[2][i];
        cost[6] += partial[6][i] * partial[6][i];
    }
    cost[2] *= div[8];
    cost[6] *= div[8];
    for i in 0..7 {
        cost[0] += (partial[0][i] * partial[0][i] + partial[0][14 - i] * partial[0][14 - i]) * div[i + 1];
        cost[4] += (partial[4][i] * partial[4][i] + partial[4][14 - i] * partial[4][14 - i]) * div[i + 1];
    }
    cost[0] += partial[0][7] * partial[0][7] * div[8];
    cost[4] += partial[4][7] * partial[4][7] * div[8];
    for i in (1..8).step_by(2) {
        for j in 0..5 {
            cost[i] += partial[i][3 + j] * partial[i][3 + j];
        }
        cost[i] *= div[8];
        for j in 0..3 {
            cost[i] += (partial[i][j] * partial[i][j] + partial[i][10 - j] * partial[i][10 - j]) * div[2 * j + 2];
        }
    }
    let (mut best_cost, mut d) = (0, 0);
    for (i, &c) in cost.iter().enumerate() {
        if c > best_cost {
            best_cost = c;
            d = i;
        }
    }
    (d as i32, (best_cost - cost[(d + 4) & 7]) >> 10)
}

/// constrain() of 7.15.3 with dampingAdj = Max(0, damping - FloorLog2(threshold)) precomputed.
#[inline(always)]
pub fn cdef_constrain_adj(diff: i32, threshold: i32, damping_adj: i32) -> i32 {
    if threshold == 0 {
        return 0;
    }
    let a = diff.abs();
    let v = clip3(0, a, threshold - (a >> damping_adj));
    if diff < 0 { -v } else { v }
}
#[inline(always)]
pub fn cdef_damping_adj(threshold: i32, damping: i32) -> i32 {
    let d = if threshold != 0 {
        damping - floor_log2(threshold as u32)
    } else {
        0
    };
    d.max(0)
}
#[inline]
pub fn cdef_constrain(diff: i32, threshold: i32, damping: i32) -> i32 {
    cdef_constrain_adj(diff, threshold, cdef_damping_adj(threshold, damping))
}

/// Per-8x8 CDEF parameters (7.15.1). `filtered == false`: the block is copied unchanged.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CdefBlk {
    pub filtered: bool,
    pub y_pri: i32,
    pub y_sec: i32,
    pub y_dir: i32,
    pub uv_pri: i32,
    pub uv_sec: i32,
    pub uv_dir: i32,
}

/// The cdef_idx of the 8x8 block at luma 4x4 position (r, c) (even), or -1 when CDEF leaves it
/// unchanged (no CDEF in its 64x64, or all four 4x4s skipped).
pub fn cdef_active_idx(f: &PfFrame, m: &PfMaps, r: i32, c: i32) -> i32 {
    let idx = m.cdef_idx[((r >> 4) * f.sb_cols + (c >> 4)) as usize] as i32;
    if idx < 0 {
        return -1;
    }
    let (sk, mc) = (m.skip, f.mi_cols as usize);
    let (r, c) = (r as usize, c as usize);
    if sk[r * mc + c] & sk[(r + 1) * mc + c] & sk[r * mc + c + 1] & sk[(r + 1) * mc + c + 1] & 1 != 0 {
        return -1;
    }
    idx
}

/// The strengths / directions of an active block from its direction-process outputs (7.15.1).
pub fn cdef_params(f: &PfFrame, idx: i32, y_dir: i32, var: i32) -> CdefBlk {
    let idx = idx as usize;
    let pri = f.cdef_y_pri[idx];
    let var_str = if var >> 6 != 0 {
        floor_log2((var >> 6) as u32).min(12)
    } else {
        0
    };
    let uv_pri = f.cdef_uv_pri[idx];
    CdefBlk {
        filtered: true,
        y_dir: if pri == 0 { 0 } else { y_dir },
        y_pri: if var != 0 { (pri * (4 + var_str) + 8) >> 4 } else { 0 },
        y_sec: f.cdef_y_sec[idx],
        uv_pri,
        uv_sec: f.cdef_uv_sec[idx],
        uv_dir: if uv_pri == 0 { 0 } else { y_dir }, // Cdef_Uv_Dir[1][1] is the identity (4:2:0)
    }
}

/// r, c: the 8x8 block's position in luma 4x4 units (even). `src0`: the deblocked luma plane.
pub fn cdef_setup(f: &PfFrame, m: &PfMaps, src0: &[u8], stride0: usize, r: i32, c: i32) -> CdefBlk {
    let idx = cdef_active_idx(f, m, r, c);
    if idx < 0 {
        return CdefBlk::default();
    }
    let (y_dir, var) = cdef_direction(&src0[(r * 4) as usize * stride0 + (c * 4) as usize..], stride0);
    cdef_params(f, idx, y_dir, var)
}

/// Cdef_Directions
pub(crate) const CDEF_DIRS: [[[i32; 2]; 2]; 8] = [
    [[-1, 1], [-2, 2]],
    [[0, 1], [-1, 2]],
    [[0, 1], [0, 2]],
    [[0, 1], [1, 2]],
    [[1, 1], [2, 2]],
    [[1, 0], [2, 1]],
    [[1, 0], [2, 0]],
    [[1, 0], [2, -1]],
];

/// The CDEF filter process (7.15.3) for the sample at plane coordinates (x, y) of the deblocked
/// plane `src`. `damping`: CdefDamping for luma, CdefDamping - 1 for chroma.
pub fn cdef_pixel(
    f: &PfFrame,
    src: &[u8],
    sstride: usize,
    plane: usize,
    x: i32,
    y: i32,
    pri_str: i32,
    sec_str: i32,
    damping: i32,
    dir: i32,
) -> i32 {
    const PRI_TAPS: [[i32; 2]; 2] = [[4, 2], [3, 3]]; // Cdef_Pri_Taps
    const SEC_TAPS: [i32; 2] = [2, 1]; // Cdef_Sec_Taps
    let sub = (plane != 0) as i32;
    let x0v = src[y as usize * sstride + x as usize] as i32;
    let (pri_adj, sec_adj) = (cdef_damping_adj(pri_str, damping), cdef_damping_adj(sec_str, damping));
    let (mut sum, mut mx, mut mn) = (0, x0v, x0v);
    for k in 0..2 {
        for sign in [-1, 1] {
            for t in 0..3 {
                // t = 0: the primary tap (dir), 1 / 2: secondary (dir - 2, dir + 2)
                let dd = if t == 0 {
                    dir
                } else {
                    (dir + if t == 1 { -2 } else { 2 }) & 7
                } as usize;
                let (yy, xx) = (y + sign * CDEF_DIRS[dd][k][0], x + sign * CDEF_DIRS[dd][k][1]);
                // is_inside_filter_region: the frame (MiRows x MiCols in luma 4x4 units)
                if yy < 0 || xx < 0 || ((yy << sub) >> 2) >= f.mi_rows || ((xx << sub) >> 2) >= f.mi_cols {
                    continue;
                }
                let p = src[yy as usize * sstride + xx as usize] as i32;
                if t == 0 {
                    sum += PRI_TAPS[(pri_str & 1) as usize][k] * cdef_constrain_adj(p - x0v, pri_str, pri_adj);
                } else {
                    sum += SEC_TAPS[k] * cdef_constrain_adj(p - x0v, sec_str, sec_adj);
                }
                mx = mx.max(p);
                mn = mn.min(p);
            }
        }
    }
    let v = x0v + ((8 + sum - (sum < 0) as i32) >> 4);
    if v < mn || v > mx {
        stat(7);
    }
    clip3(mn, mx, v)
}

/// The CDEF block process (7.15.1) for the 8x8 luma block at 4x4 position (r, c), all planes: from
/// the deblocked frame `src` to the CdefFrame `dst`.
pub fn cdef_block(
    f: &PfFrame,
    m: &PfMaps,
    src: &[&[u8]; 3],
    sstride: &[usize; 3],
    dst: &mut [&mut [u8]; 3],
    dstride: &[usize; 3],
    r: i32,
    c: i32,
) {
    let o = cdef_setup(f, m, src[0], sstride[0], r, c);
    if o.filtered {
        stat(6);
    }
    for p in 0..f.planes() {
        let sub = (p != 0) as i32;
        let (x0, y0, w) = ((c * 4) >> sub, (r * 4) >> sub, 8 >> sub);
        let (s, ss, ds) = (src[p], sstride[p], dstride[p]);
        for i in 0..w {
            for j in 0..w {
                let (x, y) = (x0 + j, y0 + i);
                let mut v = s[y as usize * ss + x as usize] as i32;
                if o.filtered {
                    v = if p == 0 {
                        cdef_pixel(f, s, ss, 0, x, y, o.y_pri, o.y_sec, f.cdef_damping, o.y_dir)
                    } else {
                        cdef_pixel(f, s, ss, p, x, y, o.uv_pri, o.uv_sec, f.cdef_damping - 1, o.uv_dir)
                    };
                }
                dst[p][y as usize * ds + x as usize] = v as u8;
            }
        }
    }
}

/// Whole-frame CDEF, the scalar reference: `src` = the deblocked frame, `dst` = the output frame.
pub fn cdef_frame_scalar(
    f: &PfFrame,
    m: &PfMaps,
    src: &[&[u8]; 3],
    sstride: &[usize; 3],
    dst: &mut [&mut [u8]; 3],
    dstride: &[usize; 3],
) {
    for r in (0..f.mi_rows).step_by(2) {
        for c in (0..f.mi_cols).step_by(2) {
            cdef_block(f, m, src, sstride, dst, dstride, r, c);
        }
    }
}

/// Whole-frame CDEF: `src` = the deblocked frame, `dst` = the output frame (MiCols * 4 x MiRows * 4
/// luma samples are written, the chroma planes at half that).
pub fn cdef_frame(
    f: &PfFrame,
    m: &PfMaps,
    src: &[&[u8]; 3],
    sstride: &[usize; 3],
    dst: &mut [&mut [u8]; 3],
    dstride: &[usize; 3],
) {
    #[cfg(target_arch = "aarch64")]
    {
        neon::cdef_frame(f, m, src, sstride, dst, dstride);
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        cdef_frame_scalar(f, m, src, sstride, dst, dstride);
    }
}

/// av1g_postfilter: deblocking then CDEF of a record's reconstruction, in place. The planes cover
/// the coded area (MiCols * 4 x MiRows * 4 luma samples, the chroma planes at half that), with
/// strides `stride`; the chroma planes are unused (and may be empty) for monochrome.
pub fn postfilter(fp: &FrameParams, blocks: &[Block], planes: &mut [&mut [u8]; 3], stride: &[usize; 3]) {
    let f = PfFrame::new(fp);
    let mut maps = PfMapsBuf::new(&f);
    for b in blocks {
        maps.mark_block(&f, b);
    }
    let m = maps.maps();
    deblock_frame(&f, &m, planes, stride);
    if !f.enable_cdef {
        return;
    }
    let mut out: Vec<Vec<u8>> = (0..f.planes())
        .map(|p| {
            let h = ((f.mi_rows * 4) >> (p != 0) as i32) as usize;
            vec![0u8; h * stride[p]]
        })
        .collect();
    out.resize(3, Vec::new());
    {
        let [o0, o1, o2] = &mut out[..] else { unreachable!() };
        let mut dst: [&mut [u8]; 3] = [o0, o1, o2];
        let src: [&[u8]; 3] = [planes[0], planes[1], planes[2]];
        cdef_frame(&f, &m, &src, stride, &mut dst, stride);
    }
    for p in 0..f.planes() {
        let sub = (p != 0) as i32;
        let (h, w) = (((f.mi_rows * 4) >> sub) as usize, ((f.mi_cols * 4) >> sub) as usize);
        for y in 0..h {
            let o = y * stride[p];
            planes[p][o..o + w].copy_from_slice(&out[p][o..o + w]);
        }
    }
}
