//! Palette decisions by cost ([`super::Hybrid::set_palette`]): before the closed loop, at the
//! analysis's partition, each intra block AV1 lets have a luma palette (8 to 64 samples each way,
//! and 4x16 and 16x4; not a copy or an inter block) and that passes a cheap gate (not flat; most of
//! its samples near at most 8 values) is priced both ways, open loop on the source:
//! - as decided: its luma mode predicted from the source's edges, the residual through the closed
//!   loop's own tx type search and quantizer ([`QuantHook::intra_luma_j`]), and its mode's bits;
//! - as a palette of 2..8 colours (k-means of its luma values): each sample's colour as the
//!   prediction, the residual the same way, and palette_mode_info's and the colour index map's
//!   bits as the writer would code them (the colour cache, literals and deltas; every index with
//!   its colour context), from the default CDFs.
//!
//! The lower J (SSE + λ bits, the hook's λ) wins; a palette block gets y_mode DC_PRED, its colours
//! and its map. Luma only (size_uv 0).
//!
//! Work is per tile and superblock row (blocks in decode order inside it), on the closed loop's
//! threads: the contexts a block reads from its neighbours (the colour cache, has_palette_y's
//! context, a key frame's y_mode context) come from blocks of the same unit; across a superblock
//! row they're taken as no palette and DC_PRED, so the decisions don't depend on scheduling.
#![allow(clippy::too_many_arguments)]

use super::decide::SrcView;
use super::quant::{QuantHook, Scratch};
use super::rdoq::sym_bits;
use crate::blockinfo::{bh4, bw4, cfl_allowed, has_chroma};
use crate::dsp::{EDGE_LEN, Edge, build_edges, is_directional, predict_intra};
use crate::entropy::{Cdfs, InterCdfs};
use crate::tables::*;
use crate::types::{Block, BlockInter, BlockPalette};
use crate::writer::map_dims;

const NONE: u32 = u32::MAX;

/// The share of a block's samples within ±2 of its 8 likeliest values below which it isn't tried
/// (photographic content).
const GATE_COVER: u32 = 50;

/// The bits of the symbols the decision prices, from the default CDFs.
pub(crate) struct PalCosts {
    kf_y: [[[f32; 13]; 5]; 5],
    if_y: [[f32; 13]; 4],
    angle: [[f32; 7]; 8],
    uv_cfl: [[f32; 14]; 13],
    uv_nocfl: [[f32; 13]; 13],
    has_y: [[[f32; 2]; 3]; 7],
    has_uv: [[f32; 2]; 2],
    size_y: [[f32; 7]; 7],
    /// [colours - 2][colour context][rank]
    color: [[[f32; 8]; 5]; 7],
}

impl PalCosts {
    pub(crate) fn new() -> Box<PalCosts> {
        let c = Cdfs::new(0);
        let ic = InterCdfs::default();
        let mut p = Box::new(PalCosts {
            kf_y: [[[0.0; 13]; 5]; 5],
            if_y: [[0.0; 13]; 4],
            angle: [[0.0; 7]; 8],
            uv_cfl: [[0.0; 14]; 13],
            uv_nocfl: [[0.0; 13]; 13],
            has_y: [[[0.0; 2]; 3]; 7],
            has_uv: [[0.0; 2]; 2],
            size_y: [[0.0; 7]; 7],
            color: [[[0.0; 8]; 5]; 7],
        });
        for a in 0..5 {
            for l in 0..5 {
                for m in 0..13 {
                    p.kf_y[a][l][m] = sym_bits(&c.y_mode[a][l], m);
                }
            }
        }
        for g in 0..4 {
            for m in 0..13 {
                p.if_y[g][m] = sym_bits(&ic.y_mode[g], m);
            }
        }
        for m in 0..8 {
            for d in 0..7 {
                p.angle[m][d] = sym_bits(&c.angle_delta[m], d);
            }
        }
        for y in 0..13 {
            for u in 0..14 {
                p.uv_cfl[y][u] = sym_bits(&c.uv_mode_cfl_allowed[y], u);
            }
            for u in 0..13 {
                p.uv_nocfl[y][u] = sym_bits(&c.uv_mode_cfl_not_allowed[y], u);
            }
        }
        for b in 0..7 {
            for k in 0..3 {
                for s in 0..2 {
                    p.has_y[b][k][s] = sym_bits(&c.palette_y_mode[b][k], s);
                }
            }
            for s in 0..7 {
                p.size_y[b][s] = sym_bits(&ic.palette_y_size[b], s);
            }
        }
        for k in 0..2 {
            for s in 0..2 {
                p.has_uv[k][s] = sym_bits(&c.palette_uv_mode[k], s);
            }
        }
        let cc = &ic.palette_y_color;
        for ctx in 0..5 {
            for r in 0..8 {
                let at = |n: usize, cdf: &[u16]| if r < n { sym_bits(cdf, r) } else { 0.0 };
                p.color[0][ctx][r] = at(2, &cc.c2[ctx]);
                p.color[1][ctx][r] = at(3, &cc.c3[ctx]);
                p.color[2][ctx][r] = at(4, &cc.c4[ctx]);
                p.color[3][ctx][r] = at(5, &cc.c5[ctx]);
                p.color[4][ctx][r] = at(6, &cc.c6[ctx]);
                p.color[5][ctx][r] = at(7, &cc.c7[ctx]);
                p.color[6][ctx][r] = at(8, &cc.c8[ctx]);
            }
        }
        p
    }
}

/// What the decisions found (summed over units and pictures).
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Stats {
    /// intra blocks that may have a palette, and their area
    pub eligible: u64,
    pub eligible_area: u64,
    /// of those, tried (past the gate)
    pub tried: u64,
    /// palette blocks, and their area
    pub chosen: u64,
    pub chosen_area: u64,
    /// palette blocks past the picture's right or bottom edge (its width and height in samples)
    pub at_edge: u64,
}

impl Stats {
    pub(crate) fn add(&mut self, o: &Stats) {
        self.eligible += o.eligible;
        self.eligible_area += o.eligible_area;
        self.tried += o.tried;
        self.chosen += o.chosen;
        self.chosen_area += o.chosen_area;
        self.at_edge += o.at_edge;
    }
}

/// A block's colour index map's size in the record (luma, the whole block), or None where it can't
/// have a palette.
#[inline]
pub(crate) fn slot(b: &Block, inter: bool) -> Option<usize> {
    let bs = b.bsize as i32;
    if inter || !(BLOCK_8X8..BLOCK_SIZES).contains(&bs) || bw4(bs) > 16 || bh4(bs) > 16 {
        return None;
    }
    Some(16 * (bw4(bs) * bh4(bs)) as usize)
}

/// A worker's buffers, kept from picture to picture.
pub(crate) struct PalScratch {
    q: Box<Scratch>,
    /// the unit's blocks (unit-local indices) by 4x4, tile width x superblock height
    grid: Vec<u32>,
    pred: Vec<u8>,
    map: Vec<u8>,
    best_map: Vec<u8>,
}

impl PalScratch {
    pub(crate) fn new() -> PalScratch {
        PalScratch {
            q: Box::new(Scratch::new()),
            grid: Vec::new(),
            pred: vec![0; 64 * 64],
            map: vec![0; 64 * 64],
            best_map: vec![0; 64 * 64],
        }
    }
}

/// What every unit reads.
pub(crate) struct Ctx<'a> {
    pub hook: &'a QuantHook<'a>,
    pub src: SrcView<'a>,
    pub costs: &'a PalCosts,
    pub inter_frame: bool,
    pub mi_rows: i32,
    pub mi_cols: i32,
    /// the picture's size in samples
    pub width: u32,
    pub height: u32,
    /// the superblock's size in 4x4s (16 or 32)
    pub sb_mi: i32,
    /// the frame's qindex, or None where each block's sb_qindex is its own (delta-q)
    pub qindex: Option<i32>,
}

/// One tile's superblock row.
pub(crate) struct Unit<'a> {
    pub blocks: &'a mut [Block],
    /// the blocks' inter entries, or empty (all intra)
    pub inter: &'a [BlockInter],
    pub pal: &'a mut [BlockPalette],
    /// the unit's slots of the record's palette map ([`slot`]'s sizes, in block order), from
    /// `map_base` on
    pub map: &'a mut [u8],
    pub map_base: u32,
    /// the tile's first and end 4x4 columns and its first row
    pub c0: i32,
    pub c1: i32,
    pub tile_r0: i32,
    /// the unit's first 4x4 row
    pub r0: i32,
    pub stats: Stats,
}

/// The colours' bits as palette_colors codes them (the writer's order: cache flags, a literal,
/// then deltas; luma, `colors` strictly increasing).
fn color_bits(cache: &[u8], colors: &[u8]) -> f32 {
    let n = colors.len();
    let mut rest = [0u8; 8];
    let mut nrest = 0;
    for &c in colors {
        if !cache.contains(&c) {
            rest[nrest] = c;
            nrest += 1;
        }
    }
    let (mut bits, mut idx) = (0i32, 0usize);
    for &cv in cache {
        if idx >= n {
            break;
        }
        bits += 1;
        if colors.contains(&cv) {
            idx += 1;
        }
    }
    let mut k = 0;
    if idx < n {
        bits += 8;
        idx += 1;
        k += 1;
    }
    if idx < n {
        let min_bits = 5;
        let max_delta = (1..nrest)
            .map(|i| (rest[i] - rest[i - 1]) as u32 - 1)
            .max()
            .unwrap_or(0);
        let extra = ((32 - max_delta.leading_zeros() as i32) - min_bits).clamp(0, 3);
        bits += 2;
        let mut palette_bits = min_bits + extra;
        while idx < n {
            bits += palette_bits;
            let range = 256 - rest[k] as i32 - 1;
            let cl = if range < 2 {
                0
            } else {
                32 - ((range - 1) as u32).leading_zeros() as i32
            };
            palette_bits = palette_bits.min(cl);
            idx += 1;
            k += 1;
        }
    }
    bits as f32
}

/// [`color_context`]'s context of the index at (r, c) and that index's rank in its order, from
/// the left, above-left and above neighbours alone: those (at most 3) colours by score (ties by
/// index), then the rest by index.
#[inline(always)]
fn ctx_rank(map: &[u8], w: usize, r: usize, c: usize) -> (usize, usize) {
    let (mut cols, mut sc, mut k) = ([0u8; 3], [0u8; 3], 0usize);
    let mut add = |col: u8, s: u8| {
        for i in 0..k {
            if cols[i] == col {
                sc[i] += s;
                return;
            }
        }
        (cols[k], sc[k]) = (col, s);
        k += 1;
    };
    if c > 0 {
        add(map[r * w + c - 1], 2);
    }
    if r > 0 && c > 0 {
        add(map[(r - 1) * w + c - 1], 1);
    }
    if r > 0 {
        add(map[(r - 1) * w + c], 2);
    }
    // by score, ties by colour
    for i in 1..k {
        let mut j = i;
        while j > 0 && (sc[j] > sc[j - 1] || (sc[j] == sc[j - 1] && cols[j] < cols[j - 1])) {
            sc.swap(j, j - 1);
            cols.swap(j, j - 1);
            j -= 1;
        }
    }
    let hash = sc[0] as usize * Palette_Color_Hash_Multipliers[0] as usize
        + sc[1] as usize * Palette_Color_Hash_Multipliers[1] as usize
        + sc[2] as usize * Palette_Color_Hash_Multipliers[2] as usize;
    let v = map[r * w + c];
    let rank = match cols[..k].iter().position(|&x| x == v) {
        Some(i) => i,
        None => k + v as usize - cols[..k].iter().filter(|&&x| x < v).count(),
    };
    (Palette_Color_Context[hash] as usize, rank)
}

/// The colour index map's bits: the first index (NS(n)), then every other on-screen index with its
/// colour context (the order the writer codes them in doesn't change any context).
fn map_bits(costs: &PalCosts, map: &[u8], w: usize, ow: usize, oh: usize, n: usize) -> f32 {
    let wb = 32 - (n as u32).leading_zeros();
    let m = (1u32 << wb) - n as u32;
    let mut bits = if (map[0] as u32) < m { wb - 1 } else { wb } as f32;
    let tab = &costs.color[n - 2];
    for r in 0..oh {
        for c in 0..ow {
            if r == 0 && c == 0 {
                continue;
            }
            let (ctx, rank) = ctx_rank(map, w, r, c);
            bits += tab[ctx][rank];
        }
    }
    bits
}

/// A block's luma values: how many of each, and the values present in increasing order.
pub(crate) struct Hist {
    count: [u32; 256],
    vals: [u8; 256],
    n: usize,
}

/// k-means of the block's values into at most `k` colours (strictly increasing into `out`);
/// returns how many.
fn cluster(h: &Hist, k: usize, out: &mut [u8; 8]) -> usize {
    let vals = &h.vals[..h.n];
    let cnt = |v: u8| h.count[v as usize];
    let mut c = [0f64; 8];
    // seeds: the likeliest value, then each next the value with the most weight times squared
    // distance to the seeds so far
    let mut best = vals[0];
    for &v in vals {
        if cnt(v) > cnt(best) {
            best = v;
        }
    }
    c[0] = best as f64;
    let mut n = 1;
    while n < k {
        let (mut bv, mut bs) = (0u8, 0f64);
        for &v in vals {
            let d = c[..n].iter().map(|&x| (v as f64 - x).abs()).fold(f64::MAX, f64::min);
            let s = cnt(v) as f64 * d * d;
            if s > bs {
                (bv, bs) = (v, s);
            }
        }
        if bs == 0.0 {
            break;
        }
        c[n] = bv as f64;
        n += 1;
    }
    for _ in 0..12 {
        c[..n].sort_by(|a, b| a.total_cmp(b));
        let (mut sum, mut num) = ([0f64; 8], [0f64; 8]);
        let mut j = 0;
        for &v in vals {
            while j + 1 < n && (v as f64 - c[j]).abs() > (v as f64 - c[j + 1]).abs() {
                j += 1;
            }
            sum[j] += cnt(v) as f64 * v as f64;
            num[j] += cnt(v) as f64;
        }
        let mut moved = false;
        for i in 0..n {
            if num[i] > 0.0 {
                let m = (sum[i] / num[i]).round();
                moved |= m != c[i];
                c[i] = m;
            }
        }
        if !moved {
            break;
        }
    }
    c[..n].sort_by(|a, b| a.total_cmp(b));
    let mut m = 0;
    for &x in &c[..n] {
        let v = x.clamp(0.0, 255.0) as u8;
        if m == 0 || out[m - 1] != v {
            out[m] = v;
            m += 1;
        }
    }
    m
}

/// Decides one unit's blocks (in decode order).
pub(crate) fn decide_unit(cx: &Ctx, sc: &mut PalScratch, u: &mut Unit) {
    let (gw, gh) = ((u.c1 - u.c0) as usize, cx.sb_mi as usize);
    sc.grid.clear();
    sc.grid.resize(gw * gh, NONE);
    let mut off = 0usize;
    for k in 0..u.blocks.len() {
        let b = u.blocks[k];
        let is_inter = u.inter.get(k).is_some_and(|i| i.is_inter != 0);
        if let Some(size) = slot(&b, is_inter) {
            u.stats.eligible += 1;
            u.stats.eligible_area += size as u64;
            let (map_off, at) = (u.map_base + off as u32, off);
            off += size;
            decide_block(cx, sc, u, k, map_off, at);
        }
        let (bs, r, c) = (b.bsize as i32, b.mi_row as i32, b.mi_col as i32);
        for y in r.max(u.r0)..(r + bh4(bs)).min(cx.mi_rows).min(u.r0 + gh as i32) {
            for x in c.max(u.c0)..(c + bw4(bs)).min(u.c1) {
                sc.grid[(y - u.r0) as usize * gw + (x - u.c0) as usize] = k as u32;
            }
        }
    }
}

/// A block's luma source past the gate (not flat; most samples near at most 8 values): its
/// values.
fn gate(s: &[u8], ss: usize, w: usize, h: usize) -> Option<Hist> {
    let mut g = Hist {
        count: [0; 256],
        vals: [0; 256],
        n: 0,
    };
    for i in 0..h {
        for &v in &s[i * ss..][..w] {
            g.count[v as usize] += 1;
        }
    }
    for v in 0..256 {
        if g.count[v] != 0 {
            g.vals[g.n] = v as u8;
            g.n += 1;
        }
    }
    if g.n < 2 {
        return None;
    }
    // the 8 likeliest values' ±2 neighbourhoods
    let mut taken = [false; 256];
    let mut covered = 0u32;
    for _ in 0..8 {
        let mut best: Option<(u32, u8)> = None;
        for &v in &g.vals[..g.n] {
            let c = g.count[v as usize];
            if !taken[v as usize] && best.is_none_or(|(bc, _)| c > bc) {
                best = Some((c, v));
            }
        }
        let Some((_, v)) = best else { break };
        let v = v as usize;
        for t in v.saturating_sub(2)..=(v + 2).min(255) {
            if !taken[t] {
                taken[t] = true;
                covered += g.count[t];
            }
        }
    }
    (covered * 100 >= GATE_COVER * (w * h) as u32).then_some(g)
}

/// The neighbours a block's contexts read: above and left (unit-local indices, NONE where outside
/// the unit or unavailable).
#[derive(Clone, Copy)]
struct Nb {
    above: u32,
    left: u32,
    avail_u: bool,
    avail_l: bool,
}

fn neighbours(sc: &PalScratch, u: &Unit, r: i32, c: i32) -> Nb {
    let gw = (u.c1 - u.c0) as usize;
    let at = |yy: i32, xx: i32| -> u32 {
        if yy < u.r0 || xx < u.c0 || xx >= u.c1 {
            NONE
        } else {
            sc.grid[(yy - u.r0) as usize * gw + (xx - u.c0) as usize]
        }
    };
    let (avail_u, avail_l) = (r > u.tile_r0, c > u.c0);
    Nb {
        above: if avail_u { at(r - 1, c) } else { NONE },
        left: if avail_l { at(r, c - 1) } else { NONE },
        avail_u,
        avail_l,
    }
}

/// The colour cache (get_palette_cache): the above (inside the same 64 rows) and left blocks'
/// colours, merged.
fn cache_of(u: &Unit, nb: &Nb, r: i32) -> ([u8; 16], usize) {
    let (mut cache, mut cn) = ([0u8; 16], 0usize);
    let colors = |j: u32| -> &[u8] {
        if j == NONE {
            return &[];
        }
        let p = &u.pal[j as usize];
        &p.colors[0][..p.size_y as usize]
    };
    let a = if (r * 4) % 64 != 0 { colors(nb.above) } else { &[] };
    let l = colors(nb.left);
    let (mut i, mut j) = (0, 0);
    let mut put = |v: u8| {
        if cn == 0 || cache[cn - 1] != v {
            cache[cn] = v;
            cn += 1;
        }
    };
    while i < a.len() && j < l.len() {
        if l[j] < a[i] {
            put(l[j]);
            j += 1;
        } else {
            if l[j] == a[i] {
                j += 1;
            }
            put(a[i]);
            i += 1;
        }
    }
    a[i..].iter().for_each(|&v| put(v));
    l[j..].iter().for_each(|&v| put(v));
    (cache, cn)
}

/// The bits of luma mode `m` (angle delta `d`) and of chroma mode `uv` after it.
fn mode_bits(cx: &Ctx, u: &Unit, nb: &Nb, bs: i32, chroma: bool, m: i32, d: i32, uv: u8) -> f32 {
    let costs = cx.costs;
    let mode_of = |j: u32| {
        if j == NONE || u.inter.get(j as usize).is_some_and(|i| i.is_inter != 0) {
            DC_PRED
        } else {
            u.blocks[j as usize].y_mode as i32
        }
    };
    let mut bits = if cx.inter_frame {
        costs.if_y[Size_Group[bs as usize] as usize][m as usize]
    } else {
        let am = Intra_Mode_Context[mode_of(nb.above) as usize] as usize;
        let lm = Intra_Mode_Context[mode_of(nb.left) as usize] as usize;
        costs.kf_y[am][lm][m as usize]
    };
    if is_directional(m) {
        bits += costs.angle[(m - V_PRED) as usize][(d + MAX_ANGLE_DELTA) as usize];
    }
    if chroma {
        bits += if cfl_allowed(bs) {
            costs.uv_cfl[m as usize][(uv as usize).min(13)]
        } else {
            costs.uv_nocfl[m as usize][(uv as usize).min(12)]
        };
    }
    bits
}

/// The quantizers and λ of a block.
fn quant(cx: &Ctx, b: &Block) -> (i32, i32, f64) {
    let q = cx.qindex.unwrap_or(b.sb_qindex as i32);
    let (dc_q, ac_q) = (crate::dsp::dc_q(q), crate::dsp::ac_q(q));
    (dc_q, ac_q, 0.12 * (ac_q as f64 / 8.0) * (ac_q as f64 / 8.0))
}

/// The best palette of a block (`bs` at 4x4 (r, c)) under `bound`: its J, colours and how many,
/// with its map in `sc.best_map`; None if none is under it. `fixed`: the bits every palette of it
/// codes besides its size, colours and map.
fn best_palette(
    cx: &Ctx,
    sc: &mut PalScratch,
    bs: i32,
    r: i32,
    c: i32,
    g: &Hist,
    fixed: f32,
    cache: &[u8],
    (dc_q, ac_q, lambda): (i32, i32, f64),
    bound: f64,
) -> Option<(f64, usize, [u8; 8])> {
    let (w, h) = (4 * bw4(bs) as usize, 4 * bh4(bs) as usize);
    let ss = cx.src.stride[0];
    let s = cx.src.at(0, c as usize * 4, r as usize * 4);
    let tx_sz = Max_Tx_Size_Rect[bs as usize] as i32;
    let bctx = (Mi_Width_Log2[bs as usize] + Mi_Height_Log2[bs as usize] - 2) as usize;
    let d = map_dims(bs, r, c, cx.mi_rows, cx.mi_cols, false);
    let mut best: Option<(f64, usize, [u8; 8])> = None;
    let mut best_j = bound;
    let mut colors = [0u8; 8];
    let mut lut = [0u8; 256];
    let mut last_n = 0;
    let mut prev_j = f64::MAX;
    for kk in 2..=8usize.min(g.n) {
        let n = cluster(g, kk, &mut colors);
        if n < 2 || n == last_n {
            continue;
        }
        last_n = n;
        // each value's nearest colour
        let mut j = 0;
        for &v in &g.vals[..g.n] {
            while j + 1 < n && (v as i32 - colors[j] as i32).abs() > (v as i32 - colors[j + 1] as i32).abs() {
                j += 1;
            }
            lut[v as usize] = j as u8;
        }
        // the map: the on-screen part from the source, repeated past it as the decoder does
        for yy in 0..h {
            let sy = yy.min(d.oh - 1);
            for xx in 0..w {
                let sx = xx.min(d.ow - 1);
                sc.map[yy * w + xx] = lut[s[sy * ss + sx] as usize];
            }
        }
        let side = fixed
            + cx.costs.size_y[bctx][n - 2]
            + color_bits(cache, &colors[..n])
            + map_bits(cx.costs, &sc.map, w, d.ow, d.oh, n);
        // (the side bits grow with the colours: more can't do better)
        if lambda * side as f64 >= best_j {
            break;
        }
        for (p, &m) in sc.pred[..w * h].iter_mut().zip(&sc.map[..w * h]) {
            *p = colors[m as usize];
        }
        let jp = cx.hook.intra_luma_j(&mut sc.q, tx_sz, &sc.pred, w, s, ss, dc_q, ac_q) + lambda * side as f64;
        if jp < best_j {
            best_j = jp;
            best = Some((jp, n, colors));
            sc.best_map[..w * h].copy_from_slice(&sc.map[..w * h]);
        } else if jp > prev_j {
            // worse than with fewer colours: J rises from here on
            break;
        }
        prev_j = jp;
    }
    best
}

/// Decides block `k`: its own mode, or a palette (its map into the unit's map at `at`, which is
/// the record's `map_off`).
fn decide_block(cx: &Ctx, sc: &mut PalScratch, u: &mut Unit, k: usize, map_off: u32, at: usize) {
    let b = u.blocks[k];
    let (bs, r, c) = (b.bsize as i32, b.mi_row as i32, b.mi_col as i32);
    let (w, h) = (4 * bw4(bs) as usize, 4 * bh4(bs) as usize);
    let (x, y) = (c as usize * 4, r as usize * 4);
    let ss = cx.src.stride[0];
    let s = cx.src.at(0, x, y);
    let Some(g) = gate(s, ss, w, h) else { return };
    u.stats.tried += 1;
    let costs = cx.costs;
    let qs = quant(cx, &b);
    let lambda = qs.2;
    let tx_sz = Max_Tx_Size_Rect[bs as usize] as i32;
    let (lw, lh) = (
        Tx_Width_Log2[tx_sz as usize] as i32,
        Tx_Height_Log2[tx_sz as usize] as i32,
    );
    let nb = neighbours(sc, u, r, c);
    let has_pal = |j: u32| j != NONE && u.pal[j as usize].size_y > 0;
    let pctx = has_pal(nb.above) as usize + has_pal(nb.left) as usize;
    let bctx = (Mi_Width_Log2[bs as usize] + Mi_Height_Log2[bs as usize] - 2) as usize;
    let chroma = has_chroma(bs, r, c, false);
    let uv_dc = chroma && b.uv_mode as i32 == DC_PRED;

    // ---- as decided ----
    let mut intra_bits = mode_bits(
        cx,
        u,
        &nb,
        bs,
        chroma,
        b.y_mode as i32,
        b.angle_delta_y as i32,
        b.uv_mode,
    );
    if b.y_mode as i32 == DC_PRED {
        intra_bits += costs.has_y[bctx][pctx][0];
    }
    if uv_dc {
        intra_bits += costs.has_uv[0][0];
    }
    {
        let (mut ea, mut el): (Edge, Edge) = ([0; EDGE_LEN], [0; EDGE_LEN]);
        let (have_left, have_above) = (nb.avail_l, nb.avail_u);
        build_edges(
            cx.src.p[0],
            ss,
            x as i32,
            y as i32,
            lw,
            lh,
            have_left,
            have_above,
            false,
            false,
            cx.mi_cols * 4 - 1,
            cx.mi_rows * 4 - 1,
            &mut ea,
            &mut el,
        );
        predict_intra(
            b.y_mode as i32,
            b.angle_delta_y as i32,
            have_left,
            have_above,
            lw,
            lh,
            &ea,
            &el,
            &mut sc.pred,
            w,
        );
    }
    let j_intra = cx.hook.intra_luma_j(&mut sc.q, tx_sz, &sc.pred, w, s, ss, qs.0, qs.1) + lambda * intra_bits as f64;

    // ---- as palettes ----
    let mut fixed = mode_bits(cx, u, &nb, bs, chroma, DC_PRED, 0, b.uv_mode) + costs.has_y[bctx][pctx][1];
    if uv_dc {
        fixed += costs.has_uv[1][0];
    }
    if lambda * (fixed + costs.size_y[bctx][0] + 2.0) as f64 >= j_intra {
        return;
    }
    let (cache, cn) = cache_of(u, &nb, r);
    let Some((_, n, colors)) = best_palette(cx, sc, bs, r, c, &g, fixed, &cache[..cn], qs, j_intra) else {
        return;
    };
    let bm = &mut u.blocks[k];
    (bm.y_mode, bm.angle_delta_y, bm.filter_intra) = (DC_PRED as u8, 0, 0);
    let p = &mut u.pal[k];
    *p = BlockPalette {
        size_y: n as u8,
        map_off,
        ..BlockPalette::default()
    };
    p.colors[0][..n].copy_from_slice(&colors[..n]);
    u.map[at..at + w * h].copy_from_slice(&sc.best_map[..w * h]);
    u.stats.chosen += 1;
    u.stats.chosen_area += (w * h) as u64;
    u.stats.at_edge += (x + w > cx.width as usize || y + h > cx.height as usize) as u64;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::writer::color_context;

    /// k-means finds a few exact values exactly, and splits a two-level block in two.
    #[test]
    fn cluster_values() {
        let mut h = Hist {
            count: [0; 256],
            vals: [0; 256],
            n: 3,
        };
        (h.count[10], h.count[90], h.count[200]) = (30, 14, 20);
        h.vals[..3].copy_from_slice(&[10, 90, 200]);
        let mut out = [0u8; 8];
        assert_eq!(cluster(&h, 3, &mut out), 3);
        assert_eq!(&out[..3], &[10, 90, 200]);
        assert_eq!(cluster(&h, 8, &mut out), 3);
        assert_eq!(cluster(&h, 2, &mut out), 2);
        assert_eq!(out[1], 200);
    }

    /// The context and rank shortcut gives get_palette_color_context's, on random maps of every
    /// palette size.
    #[test]
    fn ctx_rank_is_color_context() {
        let mut x = 0x2545_f491u32;
        let mut next = || {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            x
        };
        for n in 2..=8usize {
            for _ in 0..50 {
                let (w, h) = (16, 16);
                // runs, as glyph maps have, and noise
                let map: Vec<u8> = (0..w * h).map(|_| (next() % (n as u32 + 3)).min(n as u32 - 1) as u8).collect();
                for r in 0..h {
                    for c in 0..w {
                        if r == 0 && c == 0 {
                            continue;
                        }
                        let (order, ctx) = color_context(&map, w, r, c, n);
                        let rank = order.iter().position(|&o| o == map[r * w + c]).unwrap();
                        assert_eq!(ctx_rank(&map, w, r, c), (ctx, rank), "n {n} at ({r}, {c})");
                    }
                }
            }
        }
    }

    /// The colours' bits: a literal, then deltas; cached colours a bit each.
    #[test]
    fn colour_bits() {
        // two colours: the cache is empty, 8 + 2 + the first delta's 5 bits (a delta below 32)
        assert_eq!(color_bits(&[], &[10, 20]), 15.0);
        // both cached: one flag each
        assert_eq!(color_bits(&[10, 20, 30], &[10, 20]), 2.0);
        // one cached: a flag each for the two cache entries tried, then a literal
        assert_eq!(color_bits(&[10, 30], &[10, 20]), 10.0);
    }
}
