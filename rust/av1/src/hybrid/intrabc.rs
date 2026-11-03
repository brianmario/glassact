//! Intra block copy for key frames (fp.allow_intrabc, decisions.h "Intra block copy"): blocks
//! whose source repeats exactly where the decoder has already decoded it (spec is_mv_valid)
//! copy it, the closed loop coding what the copy of the reconstruction leaves.
//!
//! The analysis's blocks are kept but where a block, or a square node it split into several (its
//! partition then becomes NONE: the copies of whole nodes are most of the gain), has an exact
//! copy, luma and chroma, at a whole displacement (4:2:0 chroma is then the decoder's: at an odd
//! component, the average of two samples, which must equal the block's too). A tile's sources are
//! its own (is_mv_valid), so tiles are searched apart, on every thread. A tile's candidates come
//! from a hash of every 8x8 at even positions the search has passed (added row by row, so its
//! chains start at the nearest rows: valid, and the cheapest to code),
//! flat ones left out (intra codes them in a few bits, and they would be most of the table): a
//! block is looked up by its first 8x8 that isn't flat and the three 8x8s one sample right, down,
//! and both of it, which find its odd sources. Of a block's exact copies the tile's previous
//! copy's displacement is taken (the candidate stack's, which codes in the fewest bits), else the
//! nearest. The superblock row's own positions are added as the search moves right, once they are
//! 256 samples behind (is_mv_valid's delay).
//!
//! Where a block, or a node the analysis split, has no exact copy, it copies anyway if a near copy's
//! residual is small (SSE within [`NEAR_SHARE`] of the quantizer step squared per sample: glyphs
//! whose antialiasing or colour differs a little): the closed loop codes the residual. Its
//! candidates are the tile's recent displacements and those of exact matches of its first 8x8s.
//! Only exact copies count toward the frame's decision to copy ([`MIN_BUSY_SHARE`]): lossy ones
//! alone never pay for the filters the frame gives up.
//!
//! Displacements stay under 1024 samples each way, so that a difference to any prediction (another
//! displacement, or the spec's default) fits read_mv's range.
use crate::blockinfo::{bh4, bw4};
use crate::tables::*;
use crate::types::{Block, BlockInter, Tiles};

use super::decide::SrcView;

/// The largest displacement component, in samples.
const MAX_DV: i32 = 1023;
/// Hash chain entries looked at per block.
const MAX_CHAIN: usize = 512;
/// A lossy copy's largest residual: its SSE (luma and chroma) per luma sample, in units of the
/// quantizer step squared times 1.5 (the chroma samples). On the reference traces' key frames
/// (BD-rate against exact copies only): 0.005 and 0.01 within 0.3 % of each other, 0.02 0.5 %
/// worse at 5K; at 0.25 and above, 5K loses.
const NEAR_SHARE: f64 = 0.005;
/// Lossy copies: a block's 8x8s looked up, the chain entries per lookup, the displacements tried
/// per block, and the tile's recent displacements kept.
const NEAR_KEYS: usize = 4;
const NEAR_CHAIN: usize = 32;
const NEAR_CANDS: usize = 48;
const RECENT: usize = 16;
/// [`IntraBc::h8`] of a flat 8x8 (and of positions without one).
const FLAT: u32 = 0;
const NONE: u32 = u32::MAX;

/// The share (%) of a picture's non-flat 8x8s its copies must cover for the frame to copy. A frame
/// with copies has no deblocking or CDEF, which costs more than a few copies save: on the reference
/// traces, at 5K typing, scroll and cursor-drag copy 7.6, 11.4 and 6.5 % (BD-rate -18, -7, -14 %),
/// photos 1.1 % (0); at 720p (glyphs resampled, so few repeat exactly) 0.6-5 % (0 to +1 %).
const MIN_BUSY_SHARE: usize = 6;

/// A tile's mi row start, end, col start, end (ends clamped to the coded area).
type TileArea = (i32, i32, i32, i32);

/// The search's buffers, kept from picture to picture.
#[derive(Default)]
pub(crate) struct IntraBc {
    /// per even position (x / 2, y / 2) of the coded area, the hash of the luma 8x8 there, or
    /// [`FLAT`]
    pub(super) h8: Vec<u32>,
    /// per tile (raster order)
    tiles: Vec<TileSearch>,
    /// the blocks, their inter entries and luma tx types the search gives
    pub blocks: Vec<Block>,
    pub inter: Vec<BlockInter>,
    pub tx: Vec<u8>,
    /// how many blocks copy (exactly or not), and their luma area
    pub copies: usize,
    pub area: usize,
    /// the picture's non-flat 8x8s (8-aligned), and those in copies, and in exact ones
    pub busy: usize,
    pub busy_copied: usize,
    pub busy_exact: usize,
    /// what the last search was given (its geometry, blocks and luma tx types) and what it found
    given_key: [u32; 6],
    given: Vec<Block>,
    given_tx: Vec<u8>,
    copied: bool,
    /// `h8` holds the next search's hashes already, for a picture of this size ([`IntraBc::use_hashes`])
    pre: Option<(u32, u32)>,
}

/// One tile's search: its chains, and the blocks it gives.
#[derive(Default)]
struct TileSearch {
    t: TileArea,
    /// its blocks: the analysis's blocks[b0..b1]
    b0: usize,
    b1: usize,
    /// the chains: bucket heads, and per entry its position (y << 16 | x) and the next entry
    heads: Vec<u32>,
    pos: Vec<u32>,
    next: Vec<u32>,
    /// the rows of positions added so far: those whose 8x8 ends at or above this row; and of the
    /// superblock row from it, the columns before `band_x`
    added: i32,
    band_x: i32,
    /// the tile's last copy's displacement, and its last [`RECENT`] different ones (oldest first)
    last: Option<[i32; 2]>,
    recent: Vec<[i32; 2]>,
    blocks: Vec<Block>,
    inter: Vec<BlockInter>,
    tx: Vec<u8>,
    copies: usize,
    area: usize,
    busy_copied: usize,
    busy_exact: usize,
}

/// A displacement's cost, for choosing among exact copies: its components' magnitude classes.
#[inline]
fn dv_cost(dv: [i32; 2]) -> u32 {
    let c = |v: i32| 32 - (v.unsigned_abs() >> 1).leading_zeros();
    c(dv[0]) + c(dv[1])
}

/// What the search knows of the frame.
struct Frame<'a> {
    src: SrcView<'a>,
    /// the coded area, luma samples
    w: i32,
    h: i32,
    sb128: bool,
    mono: bool,
    /// [`IntraBc::h8`], and its width
    h8: &'a [u32],
    hw: usize,
    /// a lossy copy's residual SSE allowed per luma sample, and the cost of a displacement bit
    /// (one magnitude class of a component: two) as SSE
    near: f64,
    lambda: f64,
}

impl Frame<'_> {
    /// The hash of the 8x8 at (x, y) (even, its whole 8x8 inside the coded area).
    #[inline]
    fn hash_at(&self, x: i32, y: i32) -> u32 {
        self.h8[(y as usize / 2) * self.hw + x as usize / 2]
    }

    /// The non-flat 8x8s (8-aligned) of the area (x, y, w, h), inside the coded area.
    fn busy_in(&self, x: i32, y: i32, w: i32, h: i32) -> usize {
        let mut n = 0;
        for cy in (y..y + h).step_by(8) {
            for cx in (x..x + w).step_by(8) {
                n += (self.hash_at(cx, cy) != FLAT) as usize;
            }
        }
        n
    }

    /// spec is_mv_valid of a block (x, y, bw, bh in luma samples) of tile `t` copying at `dv`
    /// (samples, nonzero), within [`MAX_DV`], and the writer's rule for an odd component: the
    /// source 2 samples larger that way valid too (the bilinear chroma reads them).
    fn valid(&self, t: TileArea, x: i32, y: i32, bw: i32, bh: i32, dv: [i32; 2]) -> bool {
        if dv[0].abs() > MAX_DV || dv[1].abs() > MAX_DV {
            return false;
        }
        let (ey, ex) = if self.mono {
            (0, 0)
        } else {
            (2 * (dv[0] & 1), 2 * (dv[1] & 1))
        };
        self.area_valid(t, x, y, bw, bh, dv) && (ey | ex == 0 || self.area_valid(t, x, y, bw + ex, bh + ey, dv))
    }

    /// is_mv_valid's checks of the source area of the block (x, y, bw, bh) at `dv`.
    #[allow(clippy::too_many_arguments)]
    fn area_valid(&self, t: TileArea, x: i32, y: i32, bw: i32, bh: i32, dv: [i32; 2]) -> bool {
        let (row0, row1, col0, col1) = t;
        let (top, left) = (y + dv[0], x + dv[1]);
        let (bottom, right) = (top + bh, left + bw);
        if top < row0 * 4 || left < col0 * 4 || bottom > row1 * 4 || right > col1 * 4 {
            return false;
        }
        let sb_h = if self.sb128 { 128 } else { 64 };
        let (active_row, active_col) = (y / sb_h, x >> 6);
        let (src_row, src_col) = ((bottom - 1) / sb_h, (right - 1) >> 6);
        let per_row = ((col1 - col0 - 1) >> 4) + 1;
        if src_row * per_row + src_col >= active_row * per_row + active_col - INTRABC_DELAY_SB64 {
            return false;
        }
        let wf = (1 + INTRABC_DELAY_SB64 + self.sb128 as i32) * (active_row - src_row);
        src_row <= active_row && src_col < active_col - INTRABC_DELAY_SB64 + wf
    }

    /// The SSE (luma and chroma) of the block (x, y, bw, bh) against its prediction at `dv`, if
    /// it is at most `cap` (rows stop being added past it).
    fn sse(&self, x: i32, y: i32, bw: i32, bh: i32, dv: [i32; 2], cap: u64) -> Option<u64> {
        let mut e = 0u64;
        for p in 0..if self.mono { 1 } else { 3 } {
            let sub = (p > 0) as i32;
            let (x, y, w, h) = (x >> sub, y >> sub, (bw >> sub) as usize, bh >> sub);
            let (sx, sy) = (x + (dv[1] >> sub), y + (dv[0] >> sub));
            let (hx, hy) = (sub != 0 && dv[1] & 1 != 0, sub != 0 && dv[0] & 1 != 0);
            for i in 0..h {
                let a = &self.src.at(p, x as usize, (y + i) as usize)[..w];
                let b = self.src.at(p, sx as usize, (sy + i) as usize);
                let c = self.src.at(p, sx as usize, (sy + i + hy as i32) as usize);
                let (ox, row) = (hx as usize, a.iter().enumerate());
                e += match (hx, hy) {
                    (false, false) => row.map(|(j, &v)| (v as i32 - b[j] as i32).pow(2) as u64).sum::<u64>(),
                    (_, false) => row
                        .map(|(j, &v)| (v as i32 - ((b[j] as i32 + b[j + ox] as i32 + 1) >> 1)).pow(2) as u64)
                        .sum(),
                    (false, true) => row
                        .map(|(j, &v)| (v as i32 - ((b[j] as i32 + c[j] as i32 + 1) >> 1)).pow(2) as u64)
                        .sum(),
                    (true, true) => row
                        .map(|(j, &v)| {
                            let s = b[j] as i32 + b[j + 1] as i32 + c[j] as i32 + c[j + 1] as i32;
                            (v as i32 - ((s + 2) >> 2)).pow(2) as u64
                        })
                        .sum(),
                };
                if e > cap {
                    return None;
                }
            }
        }
        Some(e)
    }

    /// Whether the block (x, y, bw, bh) equals its prediction at `dv` from the source, luma and
    /// chroma (the decoder's: walk::predict_intrabc_block).
    fn same(&self, x: i32, y: i32, bw: i32, bh: i32, dv: [i32; 2]) -> bool {
        for p in 0..if self.mono { 1 } else { 3 } {
            let sub = (p > 0) as i32;
            let (x, y, w, h) = (x >> sub, y >> sub, (bw >> sub) as usize, bh >> sub);
            let (sx, sy) = (x + (dv[1] >> sub), y + (dv[0] >> sub));
            let (hx, hy) = (sub != 0 && dv[1] & 1 != 0, sub != 0 && dv[0] & 1 != 0);
            for i in 0..h {
                let a = &self.src.at(p, x as usize, (y + i) as usize)[..w];
                let b = self.src.at(p, sx as usize, (sy + i) as usize);
                let ok = match (hx, hy) {
                    (false, false) => *a == b[..w],
                    (true, false) => a
                        .iter()
                        .enumerate()
                        .all(|(j, &v)| v as u32 == (b[j] as u32 + b[j + 1] as u32 + 1) >> 1),
                    (false, true) => {
                        let c = self.src.at(p, sx as usize, (sy + i + 1) as usize);
                        a.iter()
                            .enumerate()
                            .all(|(j, &v)| v as u32 == (b[j] as u32 + c[j] as u32 + 1) >> 1)
                    }
                    (true, true) => {
                        let c = self.src.at(p, sx as usize, (sy + i + 1) as usize);
                        a.iter().enumerate().all(|(j, &v)| {
                            v as u32 == (b[j] as u32 + b[j + 1] as u32 + c[j] as u32 + c[j + 1] as u32 + 2) >> 2
                        })
                    }
                };
                if !ok {
                    return false;
                }
            }
        }
        true
    }
}

/// The 8 luma samples at (x, y) as one word.
#[inline(always)]
fn row8(src: &SrcView, x: usize, y: usize) -> u64 {
    u64::from_le_bytes(src.at(0, x, y)[..8].try_into().unwrap())
}

/// The hash of the luma 8x8 at (x, y), or [`FLAT`].
#[inline]
fn hash8(src: &SrcView, x: usize, y: usize) -> u32 {
    hash_rows(|k| row8(src, x, y + k))
}

/// The hash of an 8x8 from its rows (`row(k)`: row k's 8 samples, little-endian), or [`FLAT`].
#[inline(always)]
fn hash_rows(row: impl Fn(usize) -> u64) -> u32 {
    let r0 = row(0);
    let mut flat = r0 == (r0 & 0xFF).wrapping_mul(0x0101_0101_0101_0101);
    let mut h: u64 = 0x9E37_79B9_7F4A_7C15;
    for k in 0..8 {
        let r = if k == 0 { r0 } else { row(k) };
        flat &= r == r0;
        h = (h ^ r).wrapping_mul(0xFF51_AFD7_ED55_8CCD).rotate_left(29);
    }
    if flat { FLAT } else { ((h >> 32) as u32).max(1) }
}

/// The hashes [`IntraBc::search`] takes of a `width` x `height` picture's luma (`y`, rows `width`
/// apart), from it as the hybrid pads it (edge samples repeated) to its coded area: every even
/// position's 8x8, into `out`, on `threads` threads. A search given them ([`IntraBc::use_hashes`])
/// needn't take them itself, so they can be taken on another thread beforehand.
pub(crate) fn hash_picture(y: &[u8], width: u32, height: u32, out: &mut Vec<u32>, threads: usize) {
    let (pw, ph) = (width as usize, height as usize);
    let (w, h) = (
        crate::blockinfo::mi_cols(width as i32) as usize * 4,
        crate::blockinfo::mi_rows(height as i32) as usize * 4,
    );
    out.clear();
    if w < 8 || h < 8 || y.len() < pw * ph {
        return;
    }
    let (hw, hh) = ((w - 8) / 2 + 1, (h - 8) / 2 + 1);
    out.resize(hw * hh, FLAT);
    let mut rows: Vec<(usize, &mut [u32])> = out.chunks_mut(hw).enumerate().collect();
    super::par_for(threads, &mut rows, || (), |_, (j, o)| {
        let y0 = *j * 2;
        for (i, v) in o.iter_mut().enumerate() {
            let x0 = i * 2;
            *v = if x0 + 8 <= pw && y0 + 8 <= ph {
                hash_rows(|k| u64::from_le_bytes(y[(y0 + k) * pw + x0..][..8].try_into().unwrap()))
            } else {
                // past the picture's edge: its last column and row repeated, as the padding does
                hash_rows(|k| {
                    let r = &y[(y0 + k).min(ph - 1) * pw..][..pw];
                    u64::from_le_bytes(core::array::from_fn(|c| r[(x0 + c).min(pw - 1)]))
                })
            };
        }
    });
}

impl TileSearch {
    /// Adds position (x, y) to the chains.
    #[inline]
    fn add(&mut self, f: &Frame, x: i32, y: i32) {
        let v = f.hash_at(x, y);
        if v != FLAT {
            let b = (v as usize) & (self.heads.len() - 1);
            self.next.push(self.heads[b]);
            self.heads[b] = self.pos.len() as u32;
            self.pos.push(((y as u32) << 16) | x as u32);
        }
    }

    /// Adds the tile's even positions whose 8x8 ends at or above row `to` (luma samples), the
    /// superblock row's then from the next column on.
    fn add_rows(&mut self, f: &Frame, to: i32, sb: i32) {
        let (_, _, col0, col1) = self.t;
        let mut y = self.added;
        while y + 8 <= to {
            let x0 = if y + 8 <= self.added + sb {
                self.band_x
            } else {
                col0 * 4
            };
            for x in (x0..=col1 * 4 - 8).step_by(2) {
                self.add(f, x, y);
            }
            y += 2;
        }
        self.added = y;
        self.band_x = col0 * 4;
    }

    /// Adds the positions of the superblock row from `added` that end 256 samples or more left of
    /// column `sx` (the delay is_mv_valid asks of a source in the block's superblock row).
    fn add_band(&mut self, f: &Frame, sx: i32, sb: i32) {
        let (_, row1, _, col1) = self.t;
        let x1 = (sx - INTRABC_DELAY_PIXELS - 8).min(col1 * 4 - 8);
        if x1 < self.band_x {
            return;
        }
        for y in (self.added..=(self.added + sb).min(row1 * 4) - 8).step_by(2) {
            for x in (self.band_x..=x1).step_by(2) {
                self.add(f, x, y);
            }
        }
        self.band_x = x1 + 2;
    }

    /// The best exact copy of the block (x, y, bw, bh), if any: the tile's last displacement if it
    /// is one, else the cheapest found.
    fn find(&self, f: &Frame, x: i32, y: i32, bw: i32, bh: i32) -> Option<[i32; 2]> {
        let t = self.t;
        if bw < 8 || bh < 8 || x + bw > f.w || y + bh > f.h {
            return None;
        }
        if let Some(dv) = self.last
            && f.valid(t, x, y, bw, bh, dv)
            && f.same(x, y, bw, bh, dv)
        {
            return Some(dv);
        }
        // the block's first 8x8 (8-aligned inside it) that isn't flat
        let (ox, oy) = (0..bh)
            .step_by(8)
            .flat_map(|cy| (0..bw).step_by(8).map(move |cx| (cx, cy)))
            .find(|&(cx, cy)| f.hash_at(x + cx, y + cy) != FLAT)?;
        let mut best: Option<([i32; 2], u32)> = None;
        // it and the 8x8s one sample right, down and both: an even 8x8 that one equals is a source
        // at that parity
        for (py, px) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
            let (kx, ky) = (x + ox + px, y + oy + py);
            if kx + 8 > f.w || ky + 8 > f.h {
                continue;
            }
            let hb = if px | py == 0 {
                f.hash_at(kx, ky)
            } else {
                hash8(&f.src, kx as usize, ky as usize)
            };
            if hb == FLAT {
                continue;
            }
            let mut e = self.heads[hb as usize & (self.heads.len() - 1)];
            let mut looked = 0;
            while e != NONE && looked < MAX_CHAIN {
                looked += 1;
                let p = self.pos[e as usize];
                e = self.next[e as usize];
                let (qx, qy) = ((p & 0xFFFF) as i32, (p >> 16) as i32);
                let (sx, sy) = (qx - ox - px, qy - oy - py);
                if sx < 0 || sy < 0 || f.hash_at(qx, qy) != hb {
                    continue;
                }
                let dv = [sy - y, sx - x];
                let cost = dv_cost(dv);
                if best.is_some_and(|(_, c)| c <= cost) || !f.valid(t, x, y, bw, bh, dv) || !f.same(x, y, bw, bh, dv) {
                    continue;
                }
                best = Some((dv, cost));
            }
        }
        best.map(|(dv, _)| dv)
    }

    /// The block's lossy copy, if any: of the tile's recent displacements and those of exact
    /// matches of the block's first [`NEAR_KEYS`] 8x8s that aren't flat (at each parity), the one
    /// of least cost (residual SSE, and [`Frame::lambda`] per displacement bit) whose residual is
    /// within [`Frame::near`].
    fn lossy(&self, f: &Frame, x: i32, y: i32, bw: i32, bh: i32) -> Option<[i32; 2]> {
        let t = self.t;
        if f.near <= 0.0 || bw < 8 || bh < 8 || x + bw > f.w || y + bh > f.h {
            return None;
        }
        let mut cands = [[0i32; 2]; NEAR_CANDS];
        let mut n = 0;
        let mut push = |dv: [i32; 2], n: &mut usize| {
            if *n < NEAR_CANDS && dv != [0, 0] && !cands[..*n].contains(&dv) {
                cands[*n] = dv;
                *n += 1;
            }
        };
        for &dv in self.recent.iter().rev() {
            push(dv, &mut n);
        }
        let mut keys = 0;
        'keys: for cy in (0..bh).step_by(8) {
            for cx in (0..bw).step_by(8) {
                if f.hash_at(x + cx, y + cy) == FLAT {
                    continue;
                }
                for (py, px) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                    let (kx, ky) = (x + cx + px, y + cy + py);
                    if kx + 8 > f.w || ky + 8 > f.h {
                        continue;
                    }
                    let hb = if px | py == 0 {
                        f.hash_at(kx, ky)
                    } else {
                        hash8(&f.src, kx as usize, ky as usize)
                    };
                    if hb == FLAT {
                        continue;
                    }
                    let mut e = self.heads[hb as usize & (self.heads.len() - 1)];
                    let mut looked = 0;
                    while e != NONE && looked < NEAR_CHAIN {
                        looked += 1;
                        let p = self.pos[e as usize];
                        e = self.next[e as usize];
                        let (qx, qy) = ((p & 0xFFFF) as i32, (p >> 16) as i32);
                        if f.hash_at(qx, qy) == hb {
                            push([qy - ky, qx - kx], &mut n);
                        }
                    }
                }
                keys += 1;
                if keys == NEAR_KEYS {
                    break 'keys;
                }
            }
        }
        let limit = (f.near * (bw * bh) as f64) as u64;
        let mut best: Option<([i32; 2], f64)> = None;
        for &dv in &cands[..n] {
            let bits = f.lambda * 2.0 * dv_cost(dv) as f64;
            let cap = best.map_or(limit, |(_, j)| ((j - bits).max(0.0) as u64).min(limit));
            if !f.valid(t, x, y, bw, bh, dv) {
                continue;
            }
            if let Some(e) = f.sse(x, y, bw, bh, dv, cap) {
                let j = e as f64 + bits;
                if best.is_none_or(|(_, b)| j < b) {
                    best = Some((dv, j));
                }
            }
        }
        best.map(|(dv, _)| dv)
    }

    /// The tile's search over the analysis's blocks (its blocks[b0..b1]), superblock by superblock.
    fn run(&mut self, f: &Frame, blocks: &[Block], luma_tx: Option<&[u8]>) {
        self.blocks.clear();
        self.inter.clear();
        self.tx.clear();
        (self.copies, self.area, self.busy_copied, self.busy_exact, self.last) = (0, 0, 0, 0, None);
        self.recent.clear();
        let (row0, row1, col0, col1) = self.t;
        let positions = (((col1 - col0) * 2) * ((row1 - row0) * 2)).max(1) as usize;
        let nb = positions.next_power_of_two().clamp(1 << 10, 1 << 20);
        self.heads.clear();
        self.heads.resize(nb, NONE);
        self.pos.clear();
        self.next.clear();
        (self.added, self.band_x) = (row0 * 4, col0 * 4);
        let sb = if f.sb128 { 128 } else { 64 };
        let mut i = self.b0;
        while i < self.b1 {
            // the superblock's blocks; the rows above it in the chains
            let b0 = &blocks[i];
            let (sx, sy) = ((b0.mi_col as i32 * 4) & !(sb - 1), (b0.mi_row as i32 * 4) & !(sb - 1));
            let mut j = i;
            while j < self.b1
                && (blocks[j].mi_col as i32 * 4) & !(sb - 1) == sx
                && (blocks[j].mi_row as i32 * 4) & !(sb - 1) == sy
            {
                j += 1;
            }
            if sy > self.added {
                self.add_rows(f, sy, sb);
            }
            self.add_band(f, sx, sb);
            self.node(f, blocks, luma_tx, i, j, sx, sy, sb);
            i = j;
        }
    }

    /// The node (x, y, size) holding blocks[i..j]: one copy for the whole node where it has one
    /// (and the analysis split it: a copy of a 64x64 in place of its blocks, of an 8x8 in place of
    /// its 4x4s), exact, else lossy; else its quadrants (a split), else each block (a copy, exact
    /// or lossy, or the analysis's).
    #[allow(clippy::too_many_arguments)]
    fn node(
        &mut self,
        f: &Frame,
        blocks: &[Block],
        luma_tx: Option<&[u8]>,
        i: usize,
        j: usize,
        x: i32,
        y: i32,
        size: i32,
    ) {
        let one = j == i + 1 && 4 * bw4(blocks[i].bsize as i32) == size && 4 * bh4(blocks[i].bsize as i32) == size;
        if !one && size >= 8 && x + size <= f.w && y + size <= f.h {
            let found = match self.find(f, x, y, size, size) {
                Some(dv) => Some((dv, true)),
                None => self.lossy(f, x, y, size, size).map(|dv| (dv, false)),
            };
            if let Some((dv, exact)) = found {
                let bsize = match size {
                    8 => BLOCK_8X8,
                    16 => BLOCK_16X16,
                    32 => BLOCK_32X32,
                    64 => BLOCK_64X64,
                    _ => BLOCK_128X128,
                };
                self.copy(f, &blocks[i], x, y, bsize, dv, exact);
                return;
            }
        }
        if size > 8 {
            // a split: every block inside one quadrant, the quadrants in order
            let half = size / 2;
            let quad = |b: &Block| {
                let (bx, by) = (b.mi_col as i32 * 4 - x, b.mi_row as i32 * 4 - y);
                let (bw, bh) = (4 * bw4(b.bsize as i32), 4 * bh4(b.bsize as i32));
                (bx + bw <= half || bx >= half) && (by + bh <= half || by >= half)
            };
            if blocks[i..j].iter().all(quad) {
                let mut k = i;
                for (qy, qx) in [(0, 0), (0, half), (half, 0), (half, half)] {
                    let start = k;
                    while k < j {
                        let b = &blocks[k];
                        let (bx, by) = (b.mi_col as i32 * 4 - x, b.mi_row as i32 * 4 - y);
                        if (bx >= half) != (qx > 0) || (by >= half) != (qy > 0) {
                            break;
                        }
                        k += 1;
                    }
                    if k > start {
                        self.node(f, blocks, luma_tx, start, k, x + qx, y + qy, half);
                    }
                }
                // (blocks each inside a quadrant are a split's, in quadrant order)
                debug_assert_eq!(k, j);
                return;
            }
        }
        for k in i..j {
            let b = &blocks[k];
            let (bx, by) = (b.mi_col as i32 * 4, b.mi_row as i32 * 4);
            let (bw, bh) = (4 * bw4(b.bsize as i32), 4 * bh4(b.bsize as i32));
            let found = match self.find(f, bx, by, bw, bh) {
                Some(dv) => Some((dv, true)),
                None => self.lossy(f, bx, by, bw, bh).map(|dv| (dv, false)),
            };
            match found {
                Some((dv, exact)) => self.copy(f, b, bx, by, b.bsize as i32, dv, exact),
                None => {
                    self.blocks.push(*b);
                    self.inter.push(BlockInter::default());
                    self.tx.push(luma_tx.map_or(0, |l| l[k]));
                }
            }
        }
    }

    /// A copy block of `bsize` at (x, y), at displacement `dv` (samples, `exact` or not), with
    /// `like`'s quantizer.
    #[allow(clippy::too_many_arguments)]
    fn copy(&mut self, f: &Frame, like: &Block, x: i32, y: i32, bsize: i32, dv: [i32; 2], exact: bool) {
        self.blocks.push(Block {
            mi_row: (y >> 2) as u16,
            mi_col: (x >> 2) as u16,
            bsize: bsize as u8,
            sb_qindex: like.sb_qindex,
            ..Block::default()
        });
        self.inter.push(BlockInter {
            mv_row: (dv[0] * 8) as i16,
            mv_col: (dv[1] * 8) as i16,
            is_inter: 1,
            reserved: [0; 3],
        });
        self.tx.push(DCT_DCT as u8);
        let busy = f.busy_in(x, y, 4 * bw4(bsize), 4 * bh4(bsize));
        self.busy_copied += busy;
        if exact {
            self.busy_exact += busy;
        }
        self.copies += 1;
        self.area += (16 * bw4(bsize) * bh4(bsize)) as usize;
        self.last = Some(dv);
        if !self.recent.contains(&dv) {
            if self.recent.len() == RECENT {
                self.recent.remove(0);
            }
            self.recent.push(dv);
        }
    }
}

impl IntraBc {
    /// The last search's answer, if it was given these blocks and luma tx types for a picture of
    /// this geometry and quantizer (the caller knows the source is the same): its blocks, inter
    /// entries and luma tx types are still those.
    #[allow(clippy::too_many_arguments)]
    pub fn again(
        &self,
        width: u32,
        height: u32,
        sb128: bool,
        tiles: &Tiles,
        blocks: &[Block],
        luma_tx: Option<&[u8]>,
        qindex: i32,
    ) -> Option<bool> {
        let key = [width, height, sb128 as u32, tiles.cols, tiles.rows, qindex as u32];
        (key == self.given_key && blocks == self.given && luma_tx.unwrap_or(&[]) == self.given_tx)
            .then_some(self.copied)
    }

    /// The next search's hashes, taken beforehand ([`hash_picture`]) of the picture it will search,
    /// `width` x `height`: swapped in, `v` getting the buffer they replace.
    pub fn use_hashes(&mut self, v: &mut Vec<u32>, width: u32, height: u32) {
        core::mem::swap(&mut self.h8, v);
        self.pre = Some((width, height));
    }

    /// Hashes given for a picture are its alone: the next picture's search takes its own.
    pub fn clear_hashes(&mut self) {
        self.pre = None;
    }

    /// No last search to answer from (a picture coded without one came between).
    pub fn forget(&mut self) {
        self.given_key = [0; 6];
    }

    /// The search over a key frame's blocks (tile order, the analysis's: intra, given chroma or
    /// not) on the padded source `src`, `width` x `height`, tiled `tiles`, coded at `qindex`, on
    /// `threads` threads. Sets [`IntraBc::blocks`], [`IntraBc::inter`] and [`IntraBc::tx`] (from
    /// `luma_tx`, a copy's DCT_DCT), and returns whether the frame should copy: its exact copies
    /// cover at least [`MIN_BUSY_SHARE`] of its non-flat 8x8s.
    #[allow(clippy::too_many_arguments)]
    pub fn search(
        &mut self,
        src: SrcView,
        width: u32,
        height: u32,
        sb128: bool,
        mono: bool,
        tiles: &Tiles,
        blocks: &[Block],
        luma_tx: Option<&[u8]>,
        qindex: i32,
        threads: usize,
    ) -> bool {
        let (w, h) = (
            crate::blockinfo::mi_cols(width as i32) * 4,
            crate::blockinfo::mi_rows(height as i32) * 4,
        );
        self.blocks.clear();
        self.inter.clear();
        self.tx.clear();
        (self.copies, self.area, self.busy, self.busy_copied, self.busy_exact) = (0, 0, 0, 0, 0);
        self.given_key = [0; 6];
        if w < 8 || h < 8 {
            return false;
        }
        // every even position's hash (unless given: use_hashes)
        let (hw, hh) = (((w - 8) / 2 + 1) as usize, ((h - 8) / 2 + 1) as usize);
        let given = self.pre.take() == Some((width, height)) && self.h8.len() == hw * hh;
        if !given {
            self.h8.clear();
            self.h8.resize(hw * hh, FLAT);
        }
        if !given {
            let src = &src;
            let mut rows: Vec<(usize, &mut [u32])> = self.h8.chunks_mut(hw).enumerate().collect();
            super::par_for(
                threads,
                &mut rows,
                || (),
                |_, (j, out)| {
                    for (i, o) in out.iter_mut().enumerate() {
                        *o = hash8(src, i * 2, *j * 2);
                    }
                },
            );
        }
        // the quantizer step, and lambda as the closed loop's (quant.rs)
        let step = crate::dsp::ac_q(qindex) as f64 / 8.0;
        let f = Frame {
            src,
            w,
            h,
            sb128,
            mono,
            h8: &self.h8,
            hw,
            near: NEAR_SHARE * 1.5 * step * step,
            lambda: 0.12 * step * step,
        };
        self.busy = f.busy_in(0, 0, w & !7, h & !7);
        // the tiles' blocks (contiguous, in tile order), and their searches on every thread
        let ntiles = (tiles.rows * tiles.cols) as usize;
        self.tiles
            .resize_with(ntiles.max(self.tiles.len()), TileSearch::default);
        let mut k = 0;
        for (i, ts) in self.tiles[..ntiles].iter_mut().enumerate() {
            let (tr, tc) = (i / tiles.cols as usize, i % tiles.cols as usize);
            ts.t = (
                tiles.mi_row_starts[tr] as i32,
                (tiles.mi_row_starts[tr + 1] as i32).min(h >> 2),
                tiles.mi_col_starts[tc] as i32,
                (tiles.mi_col_starts[tc + 1] as i32).min(w >> 2),
            );
            ts.b0 = k;
            let (r0, r1, c0, c1) = ts.t;
            while k < blocks.len()
                && (r0..r1).contains(&(blocks[k].mi_row as i32))
                && (c0..c1).contains(&(blocks[k].mi_col as i32))
            {
                k += 1;
            }
            ts.b1 = k;
        }
        let mut tasks: Vec<&mut TileSearch> = self.tiles[..ntiles].iter_mut().collect();
        super::par_for(threads, &mut tasks, || (), |_, ts| ts.run(&f, blocks, luma_tx));
        for ts in &self.tiles[..ntiles] {
            self.blocks.extend_from_slice(&ts.blocks);
            self.inter.extend_from_slice(&ts.inter);
            self.tx.extend_from_slice(&ts.tx);
            self.copies += ts.copies;
            self.area += ts.area;
            self.busy_copied += ts.busy_copied;
            self.busy_exact += ts.busy_exact;
        }
        // blocks past the last tile's (none, in a valid record) as they are
        for b in &blocks[k..] {
            self.blocks.push(*b);
            self.inter.push(BlockInter::default());
        }
        self.tx.extend((k..blocks.len()).map(|o| luma_tx.map_or(0, |l| l[o])));
        self.copied = self.copies > 0 && self.busy_exact * 100 >= self.busy * MIN_BUSY_SHARE;
        self.given_key = [width, height, sb128 as u32, tiles.cols, tiles.rows, qindex as u32];
        self.given.clear();
        self.given.extend_from_slice(blocks);
        self.given_tx.clear();
        self.given_tx.extend_from_slice(luma_tx.unwrap_or(&[]));
        self.copied
    }
}
