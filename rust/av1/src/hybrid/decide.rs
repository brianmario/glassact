//! Open-loop decisions on source pixels (hybrid.cpp / ref_engine.cpp): the padded source, the
//! Hadamard RD proxy, and the Decider (luma modes and the partition search for the reference engine,
//! chroma modes and CfL for both). Every cost is accumulated in the C++'s order with its
//! contractions ([`fmac`]), so every decision is the C++'s.
use super::fmac;
use crate::blockinfo::{cfl_allowed, has_chroma, uv_tx_size};
use crate::dsp::{EDGE_LEN, Edge, build_edges, is_directional, predict_intra, round2signed};
use crate::tables::*;
use crate::types::{Block, Tiles};

/// The source planes padded to whole superblocks by edge replication (`p[pl]`: `height[pl]` rows,
/// `stride[pl]` apart).
#[derive(Clone, Debug, Default)]
pub(crate) struct Src {
    pub stride: [usize; 3],
    pub height: [usize; 3],
    pub p: [Vec<u8>; 3],
}

impl Src {
    /// Plane `pl` from sample (x, y) on.
    #[inline]
    pub fn at(&self, pl: usize, x: usize, y: usize) -> &[u8] {
        &self.p[pl][y * self.stride[pl] + x..]
    }
}

/// What [`pad_source`] compares while it pads: the tiles, the coded area, and one flag per tile
/// (raster order), set where the tile's coded area of some plane differs from the buffer's.
pub(crate) struct Compare<'a> {
    pub tiles: &'a Tiles,
    pub mi_cols: usize,
    pub mi_rows: usize,
    pub changed: &'a mut [bool],
}

/// The source planes (tight: Y w x h, U / V ((w + 1) / 2) x ((h + 1) / 2)), padded to sb_cols x
/// sb_rows superblocks into `s` (which keeps its capacity) on `threads` threads. With `cmp`, `s`
/// must hold a picture of the same geometry, and each tile's coded area is compared with it.
pub(crate) fn pad_source(
    planes: [&[u8]; 3],
    w: usize,
    h: usize,
    sb_cols: usize,
    sb_rows: usize,
    nplanes: usize,
    s: &mut Src,
    threads: usize,
    mut cmp: Option<Compare>,
) {
    for pl in 0..nplanes {
        let sub = (pl > 0) as usize;
        let (stride, height) = ((sb_cols * 64) >> sub, (sb_rows * 64) >> sub);
        debug_assert!(cmp.is_none() || (s.stride[pl] == stride && s.p[pl].len() == stride * height));
        s.stride[pl] = stride;
        s.height[pl] = height;
        s.p[pl].resize(stride * height, 0);
    }
    let threads = threads.max(1);
    // jobs: row ranges of each plane, `threads` per plane
    let mut jobs: Vec<(usize, usize, &mut [u8])> = Vec::with_capacity(3 * threads);
    for (pl, buf) in s.p.iter_mut().enumerate().take(nplanes) {
        let (stride, height) = (s.stride[pl], s.height[pl]);
        let rows = height.div_ceil(threads);
        for (k, c) in buf.chunks_mut(rows * stride).enumerate() {
            jobs.push((pl, k * rows, c));
        }
    }
    let ntiles = cmp.as_ref().map_or(0, |c| c.changed.len());
    let cmpr = cmp.as_ref().map(|c| (c.tiles, c.mi_cols, c.mi_rows));
    let stride = s.stride;
    let run = |jobs: &mut [(usize, usize, &mut [u8])], changed: &mut [bool]| {
        for (pl, y0, buf) in jobs.iter_mut() {
            let pl = *pl;
            let sub = (pl > 0) as usize;
            let (pw, ph) = if pl > 0 { ((w + 1) >> 1, (h + 1) >> 1) } else { (w, h) };
            let st = stride[pl];
            for (r, d) in buf.chunks_mut(st).enumerate() {
                let y = *y0 + r;
                let srow = &planes[pl][y.min(ph - 1) * pw..][..pw];
                let fill = srow[pw - 1];
                if let Some((t, mc, mr)) = cmpr
                    && y < (mr * 4) >> sub
                {
                    let mut tr = 0;
                    while tr + 1 < t.rows as usize && ((t.mi_row_starts[tr + 1] as usize * 4) >> sub) <= y {
                        tr += 1;
                    }
                    for tc in 0..t.cols as usize {
                        let i = tr * t.cols as usize + tc;
                        if changed[i] {
                            continue;
                        }
                        let x0 = (t.mi_col_starts[tc] as usize * 4) >> sub;
                        let x1 = ((t.mi_col_starts[tc + 1] as usize).min(mc) * 4) >> sub;
                        let xa = x1.min(pw);
                        let mut same = x0 >= xa || srow[x0..xa] == d[x0..xa];
                        if same && x1 > pw {
                            same = d[x0.max(pw)..x1].iter().all(|&v| v == fill);
                        }
                        changed[i] = !same;
                    }
                }
                d[..pw].copy_from_slice(srow);
                d[pw..].fill(fill);
            }
        }
    };
    let changed: &mut [bool] = match cmp.as_mut() {
        Some(c) => c.changed,
        None => &mut [],
    };
    if threads == 1 || jobs.len() <= 1 {
        run(&mut jobs, changed);
        return;
    }
    // each thread its own flags, merged after
    let per = jobs.len().div_ceil(threads);
    let mut locals: Vec<Vec<bool>> = vec![vec![false; ntiles]; jobs.len().div_ceil(per) - 1];
    std::thread::scope(|sc| {
        let mut it = jobs.chunks_mut(per);
        let first = it.next().unwrap();
        for (j, l) in it.zip(locals.iter_mut()) {
            let run = &run;
            sc.spawn(move || run(j, l));
        }
        run(first, changed);
    });
    for l in &locals {
        for (c, &l) in changed.iter_mut().zip(l) {
            *c |= l;
        }
    }
}

/// The 4x4 Hadamard transform of `a` (rows `stride` apart), in place.
#[inline(always)]
fn hadamard4(a: &mut [i32], stride: usize) {
    for i in 0..4 {
        let r = &mut a[i * stride..][..4];
        let (s0, s1, s2, s3) = (r[0] + r[1], r[0] - r[1], r[2] + r[3], r[2] - r[3]);
        r[0] = s0 + s2;
        r[1] = s1 + s3;
        r[2] = s0 - s2;
        r[3] = s1 - s3;
    }
    for j in 0..4 {
        let (c0, c1, c2, c3) = (a[j], a[stride + j], a[2 * stride + j], a[3 * stride + j]);
        let (s0, s1, s2, s3) = (c0 + c1, c0 - c1, c2 + c3, c2 - c3);
        a[j] = s0 + s2;
        a[stride + j] = s1 + s3;
        a[2 * stride + j] = s0 - s2;
        a[3 * stride + j] = s1 - s3;
    }
}

/// The Hadamard RD proxy.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Proxy {
    pub step: f64,
    pub lambda: f64,
}

impl Proxy {
    /// RD proxy of a residual block (w x h, multiples of 4, in `t`, transformed in place):
    /// orthonormal 4x4 Hadamard.
    fn cost(&self, t: &mut [i32], w: usize, h: usize) -> f64 {
        let (mut d, mut r) = (0.0f64, 0.0f64);
        let (lo, flat) = (0.6 * self.step, self.step * self.step / 12.0);
        for y in (0..h).step_by(4) {
            for x in (0..w).step_by(4) {
                hadamard4(&mut t[y * w + x..], w);
                for i in 0..4 {
                    for &v in &t[(y + i) * w + x..][..4] {
                        let c = v as f64 * 0.25; // orthonormal
                        let a = c.abs();
                        if a < lo {
                            d = fmac(c, c, d);
                        } else {
                            d += flat;
                            r += fmac(2.0, (a / self.step + 1.0).log2(), 2.0);
                        }
                    }
                }
            }
        }
        fmac(self.lambda, r, d)
    }
}

/// The partition search's and the mode decisions' options.
#[derive(Clone, Copy, Debug)]
pub(crate) struct DecOpts {
    pub min_block: i32,
    pub max_block: i32,
    pub angle_deltas: bool,
    pub cfl: bool,
    pub split_bias: f64,
}

/// The pre-pass: open loop on source pixels, edges from the source within the tile.
#[derive(Clone)]
pub(crate) struct Decider<'a> {
    pub src: &'a Src,
    pub o: DecOpts,
    pub mi_cols: i32,
    pub mi_rows: i32,
    pub mono: bool,
    pub luma: Proxy,
    pub chroma: Proxy,
    /// the tile's origin (luma samples)
    pub tx0: i32,
    pub ty0: i32,
    /// per-SB qindex (delta-q), raster over the SB grid sb_cols wide
    pub sbq: Option<&'a [u8]>,
    pub sb_cols: usize,
    t: Box<[i32; 64 * 64]>,
}

impl<'a> Decider<'a> {
    pub fn new(src: &'a Src, o: DecOpts, mi_cols: i32, mi_rows: i32, mono: bool, step_y: f64, step_c: f64) -> Self {
        Decider {
            src,
            o,
            mi_cols,
            mi_rows,
            mono,
            luma: Proxy {
                step: step_y,
                lambda: 0.12 * step_y * step_y,
            },
            chroma: Proxy {
                step: step_c,
                lambda: 0.12 * step_c * step_c,
            },
            tx0: 0,
            ty0: 0,
            sbq: None,
            sb_cols: 0,
            t: Box::new([0; 64 * 64]),
        }
    }

    /// Open-loop prediction of a (1 << lw) x (1 << lh) region at (x, y) of plane pl.
    fn predict(&self, pl: usize, x: i32, y: i32, lw: i32, lh: i32, mode: i32, delta: i32, dst: &mut [u8]) {
        let sub = (pl > 0) as i32;
        let (mut ea, mut el): (Edge, Edge) = ([0; EDGE_LEN], [0; EDGE_LEN]);
        let have_left = x > (self.tx0 >> sub);
        let have_above = y > (self.ty0 >> sub);
        let max_x = ((self.mi_cols * 4) >> sub) - 1;
        let max_y = ((self.mi_rows * 4) >> sub) - 1;
        let s = &self.src;
        build_edges(
            &s.p[pl],
            s.stride[pl],
            x,
            y,
            lw,
            lh,
            have_left,
            have_above,
            false,
            false,
            max_x,
            max_y,
            &mut ea,
            &mut el,
        );
        predict_intra(mode, delta, have_left, have_above, lw, lh, &ea, &el, dst, 1 << lw);
    }

    fn pred_cost(&mut self, pl: usize, x: i32, y: i32, lw: i32, lh: i32, pred: &[u8], luma: bool) -> f64 {
        let (w, h) = (1usize << lw, 1usize << lh);
        let ss = self.src.stride[pl];
        let s = self.src.at(pl, x as usize, y as usize);
        let t = &mut self.t[..w * h];
        for i in 0..h {
            for ((t, &s), &p) in t[i * w..][..w]
                .iter_mut()
                .zip(&s[i * ss..][..w])
                .zip(&pred[i * w..][..w])
            {
                *t = s as i32 - p as i32;
            }
        }
        let px = if luma { self.luma } else { self.chroma };
        px.cost(t, w, h)
    }

    /// The best luma mode for a block (angle delta refined); returns J.
    pub fn best_luma(&mut self, x: i32, y: i32, bs: i32, b: &mut Block) -> f64 {
        let t = Max_Tx_Size_Rect[bs as usize] as usize;
        let (lw, lh) = (Tx_Width_Log2[t] as i32, Tx_Height_Log2[t] as i32);
        let mut pred = [0u8; 64 * 64];
        let mut best = 1e300;
        let mut best_mode = 0;
        let lambda = self.luma.lambda;
        for m in 0..INTRA_MODES {
            self.predict(0, x, y, lw, lh, m, 0, &mut pred);
            let k = if is_directional(m) { 5.5 } else { 4.0 };
            let j = fmac(lambda, k, self.pred_cost(0, x, y, lw, lh, &pred, true));
            if j < best {
                best = j;
                best_mode = m;
            }
        }
        b.y_mode = best_mode as u8;
        b.angle_delta_y = 0;
        if self.o.angle_deltas && is_directional(best_mode) && bs >= BLOCK_8X8 {
            for d in -3..=3 {
                if d == 0 {
                    continue;
                }
                self.predict(0, x, y, lw, lh, best_mode, d, &mut pred);
                let j = fmac(lambda, 5.5, self.pred_cost(0, x, y, lw, lh, &pred, true));
                if j < best {
                    best = j;
                    b.angle_delta_y = d as i8;
                }
            }
        }
        best
    }

    /// The best chroma mode (and CfL alphas) for a block at luma sample (x, y).
    pub fn best_chroma(&mut self, x: i32, y: i32, bs: i32, b: &mut Block) {
        let tx_sz = uv_tx_size(bs);
        let (lw, lh) = (
            Tx_Width_Log2[tx_sz as usize] as i32,
            Tx_Height_Log2[tx_sz as usize] as i32,
        );
        // chroma block origin: (MiCol >> 1) * 4 (sub-8x8 blocks carry the chroma of the 8x8 area)
        let (cx, cy) = (((x >> 2) >> 1) << 2, ((y >> 2) >> 1) << 2);
        let mut pred = [[0u8; 32 * 32]; 2];
        let mut best = 1e300;
        let mut best_mode = DC_PRED;
        let lambda = self.chroma.lambda;
        for m in 0..INTRA_MODES {
            let mut j = 0.0;
            for pl in 1..=2 {
                self.predict(pl, cx, cy, lw, lh, m, 0, &mut pred[0]);
                j += self.pred_cost(pl, cx, cy, lw, lh, &pred[0], false);
            }
            j = fmac(lambda, if is_directional(m) { 5.0 } else { 3.5 }, j);
            if j < best {
                best = j;
                best_mode = m;
            }
        }
        b.uv_mode = best_mode as u8;
        b.angle_delta_uv = 0;
        b.cfl_alpha_u = 0;
        b.cfl_alpha_v = 0;
        if self.o.cfl && cfl_allowed(bs) {
            // least-squares alpha against source luma (3 fractional bits, as in the spec)
            let (w, h) = (1usize << lw, 1usize << lh);
            let mut l = [0i32; 32 * 32];
            let mut sum = 0i64;
            let s0 = self.src.stride[0];
            for i in 0..h {
                for j in 0..w {
                    let s = self.src.at(0, (cx as usize + j) * 2, (cy as usize + i) * 2);
                    let v = (s[0] as i32 + s[1] as i32 + s[s0] as i32 + s[s0 + 1] as i32) << 1;
                    l[i * w + j] = v;
                    sum += v as i64;
                }
            }
            let n = (w * h) as i64;
            let avg = ((sum + n / 2) / n) as i32;
            let mut alpha = [0i32; 2];
            let mut jc = lambda * 8.0;
            for pl in 1..=2 {
                let p = &mut pred[pl - 1];
                self.predict(pl, cx, cy, lw, lh, DC_PRED, 0, p);
                let (mut num, mut den) = (0.0f64, 0.0f64);
                let ss = self.src.stride[pl];
                let s = self.src.at(pl, cx as usize, cy as usize);
                for i in 0..h {
                    for j in 0..w {
                        let lv = (l[i * w + j] - avg) as f64 / 8.0;
                        num = fmac((s[i * ss + j] as i32 - p[i * w + j] as i32) as f64, lv, num);
                        den = fmac(lv, lv, den);
                    }
                }
                let a = if den > 0.0 {
                    (8.0 * num / den).round_ties_even() as i64 as i32
                } else {
                    0
                };
                alpha[pl - 1] = a.clamp(-16, 16);
                for i in 0..h {
                    for j in 0..w {
                        let v = p[i * w + j] as i32 + round2signed(alpha[pl - 1] * (l[i * w + j] - avg), 6);
                        p[i * w + j] = v.clamp(0, 255) as u8;
                    }
                }
                let p = pred[pl - 1];
                jc += self.pred_cost(pl, cx, cy, lw, lh, &p, false);
            }
            if (alpha[0] != 0 || alpha[1] != 0) && jc < best {
                b.uv_mode = UV_CFL_PRED as u8;
                b.cfl_alpha_u = alpha[0] as i8;
                b.cfl_alpha_v = alpha[1] as i8;
            }
        }
    }

    fn leaf(&mut self, r: i32, c: i32, bs: i32, out: &mut Vec<Block>) {
        let mut b = Block {
            mi_row: r as u16,
            mi_col: c as u16,
            bsize: bs as u8,
            ..Block::default()
        };
        if let Some(q) = self.sbq {
            b.sb_qindex = q[(r as usize >> 4) * self.sb_cols + (c as usize >> 4)];
        }
        self.best_luma(c * 4, r * 4, bs, &mut b);
        if has_chroma(bs, r, c, self.mono) {
            self.best_chroma(c * 4, r * 4, bs, &mut b);
        }
        out.push(b);
    }

    /// The square block size of 4..64 samples.
    fn sq(log2px: i32) -> i32 {
        match log2px {
            2 => BLOCK_4X4,
            3 => BLOCK_8X8,
            4 => BLOCK_16X16,
            5 => BLOCK_32X32,
            _ => BLOCK_64X64,
        }
    }

    /// The partition search below a square node (NONE vs SPLIT), leaves into `out` in decode order.
    pub fn node(&mut self, r: i32, c: i32, log2px: i32, out: &mut Vec<Block>) {
        if r >= self.mi_rows || c >= self.mi_cols {
            return;
        }
        let bs = Self::sq(log2px);
        let half = (1 << log2px) >> 3; // in 4x4 units
        let has_rows = r + half < self.mi_rows;
        let has_cols = c + half < self.mi_cols;
        let size = 1 << log2px;
        let split = if log2px == 2 {
            false
        } else if !has_rows || !has_cols || size > self.o.max_block {
            true
        } else if size <= self.o.min_block {
            false
        } else {
            let mut tmp = Block::default();
            let jn = self.best_luma(c * 4, r * 4, bs, &mut tmp);
            let mut js = 0.0;
            let sbs = Self::sq(log2px - 1);
            for q in 0..4 {
                let (rr, cc) = (r + (q >> 1) * half, c + (q & 1) * half);
                if rr < self.mi_rows && cc < self.mi_cols {
                    js += self.best_luma(cc * 4, rr * 4, sbs, &mut tmp);
                }
            }
            js = fmac(self.luma.lambda, 6.0, js); // partition + extra mode signalling
            js * self.o.split_bias < jn
        };
        if !split {
            self.leaf(r, c, bs, out);
            return;
        }
        if log2px == 3 {
            // 8x8 -> four 4x4 blocks (PARTITION_SPLIT of an 8x8 node)
            for q in 0..4 {
                self.leaf(r + (q >> 1), c + (q & 1), BLOCK_4X4, out);
            }
            return;
        }
        self.node(r, c, log2px - 1, out);
        self.node(r, c + half, log2px - 1, out);
        self.node(r + half, c, log2px - 1, out);
        self.node(r + half, c + half, log2px - 1, out);
    }
}
