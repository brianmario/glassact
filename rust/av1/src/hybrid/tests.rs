//! The hybrid encoder's tests: the SIMD forward transform and quantizer against the scalar code;
//! the closed loop, the write and the tile reuse on random pictures, partitions and sequences,
//! held to snapshots (until 2026-11-17 to the C++ hybrid, av1enc_hybrid_*, which they were
//! recorded against); and `#[ignore]` benchmarks.
use super::fwd::{FWD_F_TMP, Stage1Cache, forward_f, forward_f_cached, forward_f_scalar, fwd};
use super::quant::quantize_f;
use super::*;
use crate::blockinfo::{bh4, bw4, cfl_allowed, has_chroma, mi_cols, mi_rows};
use crate::dsp::{
    Rng, dq_denom, get_tx_set_intra, is_directional, qm, qm_step, tx_coeffs, tx_h, tx_type_in_set_intra, tx_w,
};
use crate::tables::*;
use crate::writer::tile_layout;

// ---------------------------------------------------------------------------------------------
// SIMD against scalar
// ---------------------------------------------------------------------------------------------

/// Every tx size and type the forward matrices cover (ADST up to 16, identity up to 32 points).
fn fwd_cases() -> Vec<(i32, i32)> {
    let mut v = Vec::new();
    for tx_sz in 0..TX_SIZES_ALL {
        for ty in 0..TX_TYPES {
            let (w, h) = (tx_w(tx_sz), tx_h(tx_sz));
            let ok = |kind: i32, n: i32| match kind {
                crate::dsp::K_ADST => n <= 16,
                crate::dsp::K_IDT => n <= 32,
                _ => true,
            };
            if ok(crate::dsp::row_kind(ty), w) && ok(crate::dsp::col_kind(ty), h) {
                v.push((tx_sz, ty));
            }
        }
    }
    v
}

/// A tx type search's forward transforms through the first-pass cache, the types in shuffled
/// orders: bit for bit forward_f's.
#[test]
fn forward_f_cached_matches_uncached() {
    let f = fwd();
    let mut r = Rng(0x0c0f_fee5_eed5_1234);
    let (mut a, mut b) = (vec![0f32; 1024], vec![0f32; 1024]);
    let mut tmp = vec![0f32; FWD_F_TMP];
    let mut cache = Stage1Cache::default();
    let cases = fwd_cases();
    for tx_sz in 0..TX_SIZES_ALL {
        let mut tys: Vec<i32> = cases.iter().filter(|c| c.0 == tx_sz).map(|c| c.1).collect();
        let n = (tx_w(tx_sz) * tx_h(tx_sz)) as usize;
        for k in 0..12 {
            for i in (1..tys.len()).rev() {
                tys.swap(i, r.below(i as u32 + 1) as usize);
            }
            let res: Vec<f32> = (0..n)
                .map(|_| match k % 3 {
                    0 => r.range(-255, 255) as f32,
                    1 => (r.range(-3, 3) * (r.below(8) == 0) as i32) as f32,
                    _ => 0.0,
                })
                .collect();
            cache.reset();
            for &ty in &tys {
                forward_f_cached(f, &res, tx_sz, ty, &mut a, &mut tmp, &mut cache);
                forward_f(f, &res, tx_sz, ty, &mut b, &mut tmp);
                let m = tx_coeffs(tx_sz);
                for i in 0..m {
                    assert_eq!(
                        a[i].to_bits(),
                        b[i].to_bits(),
                        "tx {tx_sz} type {ty} case {k} coeff {i}"
                    );
                }
            }
        }
    }
}

#[test]
fn forward_f_simd_matches_scalar() {
    let f = fwd();
    let mut r = Rng(0x5eed_f0f0_1234_5678);
    let (mut a, mut b) = (vec![0f32; 1024], vec![0f32; 1024]);
    let mut tmp = vec![0f32; FWD_F_TMP];
    for (tx_sz, ty) in fwd_cases() {
        let n = (tx_w(tx_sz) * tx_h(tx_sz)) as usize;
        for k in 0..20 {
            let res: Vec<f32> = (0..n)
                .map(|i| match k % 4 {
                    0 => r.range(-255, 255) as f32,
                    1 => (r.range(-3, 3) * (r.below(8) == 0) as i32) as f32,
                    2 => ((i % 7) as i32 * 30 - 90) as f32,
                    _ => 0.0,
                })
                .collect();
            forward_f(f, &res, tx_sz, ty, &mut a, &mut tmp);
            forward_f_scalar(f, &res, tx_sz, ty, &mut b, &mut tmp);
            let m = tx_coeffs(tx_sz);
            let (ab, bb): (Vec<u32>, Vec<u32>) = (
                a[..m].iter().map(|x| x.to_bits()).collect(),
                b[..m].iter().map(|x| x.to_bits()).collect(),
            );
            // the scalar code skips zero factors: only the sign of a zero may differ
            for i in 0..m {
                assert!(
                    ab[i] == bb[i] || (a[i] == 0.0 && b[i] == 0.0),
                    "tx {tx_sz} type {ty} case {k} coeff {i}: {} vs {}",
                    a[i],
                    b[i]
                );
            }
        }
    }
}

#[test]
fn quantizer_matches_per_coefficient() {
    let mut r = Rng(0x1234_8765_dead_beef);
    let mut q = vec![0i16; 1024];
    for case in 0..4000 {
        let tx_sz = r.below(TX_SIZES_ALL as u32) as i32;
        let n = tx_coeffs(tx_sz);
        let den = dq_denom(tx_sz);
        let (dc_q, ac_q) = (r.range(4, 1336), r.range(4, 1828));
        let m = if case % 3 == 0 {
            qm(true, r.range(0, 14), r.range(0, 2), tx_sz, DCT_DCT)
        } else {
            None
        };
        let (rnd, zbin) = if case % 2 == 0 { (0.375, 0.656) } else { (0.5, 0.0) };
        // values around the zero threshold, and some large ones
        let d: Vec<f32> = (0..n)
            .map(|_| {
                let step = ac_q as f32 / den as f32;
                match r.below(4) {
                    0 => (r.range(-2000, 2000) as f32 / 1000.0) * step * 0.66,
                    1 => r.range(-100_000, 100_000) as f32 / 7.0,
                    2 => (r.range(0, 1) * 2 - 1) as f32 * step * (0.625 + r.range(-100, 100) as f32 * 1e-4),
                    _ => 0.0,
                }
            })
            .collect();
        let nz = quantize_f(&d, &mut q, den, dc_q, ac_q, m, rnd, zbin);
        let mut any = false;
        for i in 0..n {
            let v = d[i] as f64 * den as f64 / qm_step(if i == 0 { dc_q } else { ac_q }, m, i) as f64;
            let a = v.abs();
            let qi = if a < zbin {
                0
            } else {
                ((a + rnd).floor() as i32).min(32767)
            };
            let want = (if v < 0.0 { -qi } else { qi }) as i16;
            assert_eq!(q[i], want, "case {case} coeff {i}: {}", d[i]);
            any |= want != 0;
        }
        assert_eq!(nz, any);
    }
}

// ---------------------------------------------------------------------------------------------
// pictures and partitions
// ---------------------------------------------------------------------------------------------

/// An 8-bit 4:2:0 picture, tightly packed.
#[derive(Clone)]
pub(crate) struct Pic {
    pub w: usize,
    pub h: usize,
    pub y: Vec<u8>,
    pub u: Vec<u8>,
    pub v: Vec<u8>,
}

impl Pic {
    fn cw(&self) -> usize {
        self.w.div_ceil(2)
    }

    /// Text-like strokes in the rectangle (x0, y0, x1, y1) (luma samples), on `bg`.
    fn text(&mut self, r: &mut Rng, x0: usize, y0: usize, x1: usize, y1: usize, bg: u8) {
        let (x1, y1) = (x1.min(self.w), y1.min(self.h));
        for yy in y0..y1 {
            self.y[yy * self.w + x0..yy * self.w + x1].fill(bg);
        }
        let ink = r.range(10, 70) as u8;
        let mut y = y0 + 2;
        while y + 12 <= y1 {
            let mut x = x0 + 2;
            while x + 8 <= x1 {
                if r.below(6) != 0 {
                    // a glyph: a few 1-2 px strokes in an 8 x 12 cell
                    for _ in 0..r.range(2, 4) {
                        let (gx, gy) = (x + r.below(6) as usize, y + r.below(9) as usize);
                        let (sw, sh) = if r.below(2) == 0 {
                            (r.range(1, 2) as usize, r.range(3, 10) as usize)
                        } else {
                            (r.range(3, 6) as usize, r.range(1, 2) as usize)
                        };
                        for yy in gy..(gy + sh).min(y + 12) {
                            for xx in gx..(gx + sw).min(x + 8) {
                                self.y[yy * self.w + xx] = ink;
                            }
                        }
                    }
                } else if r.below(3) == 0 {
                    x += 4; // a space
                }
                x += 8;
            }
            y += r.range(14, 18) as usize;
        }
        // a coloured run of text now and then
        if r.below(3) == 0 {
            let (cu, cv) = (r.range(60, 200) as u8, r.range(60, 200) as u8);
            let cw = self.cw();
            for yy in y0 / 2..y1.div_ceil(2) {
                for xx in x0 / 2..x1.div_ceil(2) {
                    if self.y[(2 * yy).min(self.h - 1) * self.w + (2 * xx).min(self.w - 1)] < 100 {
                        self.u[yy * cw + xx] = cu;
                        self.v[yy * cw + xx] = cv;
                    }
                }
            }
        }
    }

    /// Noise in a rectangle (a photo).
    pub(crate) fn noise(&mut self, r: &mut Rng, x0: usize, y0: usize, x1: usize, y1: usize, amp: i32) {
        let (x1, y1) = (x1.min(self.w), y1.min(self.h));
        let cw = self.cw();
        for yy in y0..y1 {
            for xx in x0..x1 {
                let base = 128 + ((xx as i32 * 37 + yy as i32 * 11) % 90) - 45;
                self.y[yy * self.w + xx] = (base + r.range(-amp, amp)).clamp(0, 255) as u8;
                if xx % 2 == 0 && yy % 2 == 0 {
                    self.u[(yy / 2) * cw + xx / 2] = (128 + r.range(-amp, amp) / 2).clamp(0, 255) as u8;
                    self.v[(yy / 2) * cw + xx / 2] = (100 + r.range(-amp, amp) / 2).clamp(0, 255) as u8;
                }
            }
        }
    }
}

/// A screen-like picture: a smooth gradient region, text panels, UI rectangles, now and then a
/// noisy photo region.
pub(crate) fn screen_pic(w: usize, h: usize, seed: u64, photo: bool) -> Pic {
    let mut r = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    let mut p = Pic {
        w,
        h,
        y: vec![235; w * h],
        u: vec![128; cw * ch],
        v: vec![128; cw * ch],
    };
    // gradient on the left 40 %
    let gw = w * 2 / 5;
    for y in 0..h {
        for x in 0..gw {
            p.y[y * w + x] = (40 + x * 120 / w.max(1) + y * 60 / h.max(1)) as u8;
        }
    }
    for y in 0..ch {
        for x in 0..gw.div_ceil(2).min(cw) {
            p.u[y * cw + x] = (100 + x * 50 / cw.max(1)) as u8;
            p.v[y * cw + x] = (150 - y * 40 / ch.max(1)) as u8;
        }
    }
    // text panels on the right
    let mut y = 0;
    while y < h {
        let ph = r.range(40, 200) as usize;
        let bg = if r.below(4) == 0 { 250 } else { 235 };
        p.text(&mut r, gw, y, w, y + ph, bg);
        y += ph + r.range(0, 12) as usize;
    }
    // UI rectangles
    for _ in 0..r.range(1, 6) {
        let (x0, y0) = (r.below(w as u32) as usize, r.below(h as u32) as usize);
        let (x1, y1) = (
            (x0 + r.range(8, 160) as usize).min(w),
            (y0 + r.range(8, 60) as usize).min(h),
        );
        let c = r.range(0, 255) as u8;
        let (cu, cv) = (r.range(0, 255) as u8, r.range(0, 255) as u8);
        for yy in y0..y1 {
            p.y[yy * w + x0..yy * w + x1].fill(c);
        }
        for yy in y0 / 2..y1.div_ceil(2) {
            p.u[yy * cw + x0 / 2..yy * cw + x1.div_ceil(2)].fill(cu);
            p.v[yy * cw + x0 / 2..yy * cw + x1.div_ceil(2)].fill(cv);
        }
    }
    if photo {
        let (x0, y0) = (r.below(w as u32) as usize, r.below(h as u32) as usize);
        let amp = r.range(2, 60);
        p.noise(&mut r, x0, y0, x0 + w / 3, y0 + h / 3, amp);
    }
    p
}

/// A random rectangle of the picture re-typed (about `sbs` 64x64 superblocks' worth).
fn retype(p: &mut Pic, r: &mut Rng, sbs: usize) {
    let area = sbs * 64 * 64;
    let rw = (r.range(64, 512) as usize).min(p.w);
    let rh = (area / rw).clamp(8, p.h);
    let (x0, y0) = (
        r.below((p.w - rw + 1) as u32) as usize,
        r.below((p.h - rh + 1) as u32) as usize,
    );
    p.text(r, x0, y0, x0 + rw, y0 + rh, 235);
}

/// How [`Partition`] decides.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Style {
    /// random legal partitions, every type
    Random,
    /// split where the source isn't flat (the benchmarks)
    Variance,
}

/// Blocks in tile order for a picture, with analysis-style decisions: y_mode and angle deltas set,
/// the rest left to the closed loop (random garbage there, which it must overwrite), or chroma too.
struct Partition<'a> {
    r: &'a mut Rng,
    pic: &'a Pic,
    mi_cols: i32,
    mi_rows: i32,
    style: Style,
    chroma: bool,
    blocks: Vec<Block>,
}

impl Partition<'_> {
    fn variance(&self, r: i32, c: i32, n4: i32) -> u64 {
        let (x0, y0) = ((c * 4) as usize, (r * 4) as usize);
        let (x1, y1) = (((c + n4) * 4) as usize, ((r + n4) * 4) as usize);
        let (x1, y1) = (x1.min(self.pic.w), y1.min(self.pic.h));
        if x0 >= x1 || y0 >= y1 {
            return 0;
        }
        let (mut s, mut s2, mut n) = (0u64, 0u64, 0u64);
        for y in y0..y1 {
            for &v in &self.pic.y[y * self.pic.w + x0..y * self.pic.w + x1] {
                s += v as u64;
                s2 += (v as u64) * (v as u64);
                n += 1;
            }
        }
        (s2 - s * s / n) / n
    }

    fn block(&mut self, r: i32, c: i32, bs: i32) {
        let v = if self.style == Style::Variance {
            self.variance(r, c, bw4(bs).max(bh4(bs)))
        } else {
            0
        };
        let rng = &mut *self.r;
        let mut b = Block {
            mi_row: r as u16,
            mi_col: c as u16,
            bsize: bs as u8,
            ..Block::default()
        };
        if self.style == Style::Variance {
            b.y_mode = if v < 4 {
                DC_PRED
            } else if v < 200 {
                SMOOTH_PRED
            } else {
                [V_PRED, H_PRED, PAETH_PRED, DC_PRED][rng.below(4) as usize]
            } as u8;
        } else {
            b.y_mode = rng.range(0, 12) as u8;
            if bs >= BLOCK_8X8 && is_directional(b.y_mode as i32) && rng.below(10) < 7 {
                b.angle_delta_y = rng.range(-3, 3) as i8;
            }
            // left to the closed loop
            b.skip = rng.below(2) as u8;
            b.tx_depth = rng.below(3) as u8;
            b.sb_qindex = rng.below(256) as u8;
        }
        if self.chroma && has_chroma(bs, r, c, false, 1) {
            if self.style == Style::Variance {
                b.uv_mode = if cfl_allowed(bs) && rng.below(4) == 0 {
                    UV_CFL_PRED
                } else {
                    DC_PRED
                } as u8;
            } else {
                b.uv_mode = rng.range(0, if cfl_allowed(bs) { 13 } else { 12 }) as u8;
            }
            if b.uv_mode as i32 == UV_CFL_PRED {
                while b.cfl_alpha_u == 0 && b.cfl_alpha_v == 0 {
                    b.cfl_alpha_u = rng.range(-16, 16) as i8;
                    b.cfl_alpha_v = rng.range(-16, 16) as i8;
                }
            }
            if bs >= BLOCK_8X8 && is_directional(b.uv_mode as i32) && rng.below(10) < 7 {
                b.angle_delta_uv = rng.range(-3, 3) as i8;
            }
        } else if !self.chroma && self.style == Style::Random {
            b.uv_mode = rng.range(0, 13) as u8;
            b.cfl_alpha_u = rng.range(-16, 16) as i8;
        }
        self.blocks.push(b);
    }

    fn pick(&mut self, r: i32, c: i32, bs: i32, has_rows: bool, has_cols: bool) -> i32 {
        if self.style == Style::Variance {
            let split = bs > BLOCK_8X8 && self.variance(r, c, bw4(bs)) > 30;
            return if split || !has_rows || !has_cols {
                PARTITION_SPLIT
            } else {
                PARTITION_NONE
            };
        }
        let rng = &mut *self.r;
        if has_rows && has_cols {
            if bs == BLOCK_8X8 {
                return rng.range(0, 3);
            }
            if rng.below(100) < if bs == BLOCK_64X64 { 50 } else { 30 } {
                return PARTITION_SPLIT;
            }
            return rng.range(0, 9);
        }
        if has_cols {
            return if rng.below(2) == 0 {
                PARTITION_HORZ
            } else {
                PARTITION_SPLIT
            };
        }
        if has_rows {
            return if rng.below(2) == 0 {
                PARTITION_VERT
            } else {
                PARTITION_SPLIT
            };
        }
        PARTITION_SPLIT
    }

    fn node(&mut self, r: i32, c: i32, bs: i32) {
        if r >= self.mi_rows || c >= self.mi_cols {
            return;
        }
        let half = bw4(bs) >> 1;
        let quarter = half >> 1;
        let has_rows = (r + half) < self.mi_rows;
        let has_cols = (c + half) < self.mi_cols;
        let p = if bs < BLOCK_8X8 {
            PARTITION_NONE
        } else {
            self.pick(r, c, bs, has_rows, has_cols)
        };
        let sub = Partition_Subsize[p as usize][bs as usize] as i32;
        let sp = Partition_Subsize[PARTITION_SPLIT as usize][bs as usize] as i32;
        match p {
            PARTITION_NONE => self.block(r, c, sub),
            PARTITION_HORZ => {
                self.block(r, c, sub);
                if has_rows {
                    self.block(r + half, c, sub);
                }
            }
            PARTITION_VERT => {
                self.block(r, c, sub);
                if has_cols {
                    self.block(r, c + half, sub);
                }
            }
            PARTITION_SPLIT => {
                self.node(r, c, sub);
                self.node(r, c + half, sub);
                self.node(r + half, c, sub);
                self.node(r + half, c + half, sub);
            }
            PARTITION_HORZ_A => {
                self.block(r, c, sp);
                self.block(r, c + half, sp);
                self.block(r + half, c, sub);
            }
            PARTITION_HORZ_B => {
                self.block(r, c, sub);
                self.block(r + half, c, sp);
                self.block(r + half, c + half, sp);
            }
            PARTITION_VERT_A => {
                self.block(r, c, sp);
                self.block(r + half, c, sp);
                self.block(r, c + half, sub);
            }
            PARTITION_VERT_B => {
                self.block(r, c, sub);
                self.block(r, c + half, sp);
                self.block(r + half, c + half, sp);
            }
            PARTITION_HORZ_4 => {
                for i in 0..4 {
                    if i < 3 || r + quarter * 3 < self.mi_rows {
                        self.block(r + quarter * i, c, sub);
                    }
                }
            }
            _ => {
                for i in 0..4 {
                    if i < 3 || c + quarter * 3 < self.mi_cols {
                        self.block(r, c + quarter * i, sub);
                    }
                }
            }
        }
    }
}

/// The blocks of `pic` in tile order of the tiling, and luma tx types for them (valid or not).
fn partition(pic: &Pic, tiles: &Tiles, r: &mut Rng, style: Style, chroma: bool) -> Vec<Block> {
    let mut p = Partition {
        r,
        pic,
        mi_cols: mi_cols(pic.w as i32),
        mi_rows: mi_rows(pic.h as i32),
        style,
        chroma,
        blocks: Vec::new(),
    };
    for tr in 0..tiles.rows as usize {
        for tc in 0..tiles.cols as usize {
            for row in (tiles.mi_row_starts[tr]..tiles.mi_row_starts[tr + 1]).step_by(16) {
                for col in (tiles.mi_col_starts[tc]..tiles.mi_col_starts[tc + 1]).step_by(16) {
                    p.node(row as i32, col as i32, BLOCK_64X64);
                }
            }
        }
    }
    p.blocks
}

/// One luma tx type per block: valid for its size mostly, now and then not (the closed loop
/// falls back to DCT_DCT).
fn luma_types(blocks: &[Block], r: &mut Rng, wild: bool) -> Vec<u8> {
    blocks
        .iter()
        .map(|b| {
            let tx = Max_Tx_Size_Rect[b.bsize as usize] as i32;
            if wild && r.below(8) == 0 {
                return r.below(16) as u8; // maybe not in the size's set (the C++ reads past its table above 15)
            }
            let set = get_tx_set_intra(tx, false);
            loop {
                let t = r.below(16) as i32;
                if tx_type_in_set_intra(set, t) {
                    return t as u8;
                }
            }
        })
        .collect()
}

#[test]
fn rust_only_sequence_is_deterministic() {
    // a sequence with reuse codes what fresh closed loops code
    let mut rng = Rng(77);
    let mut pic = screen_pic(300, 200, 3, true);
    let tiles = tile_layout(300, 200, 1, 1).unwrap();
    let blocks = partition(&pic, &tiles, &mut rng, Style::Random, false);
    let mut a = Hybrid::new();
    let mut kept = 0;
    for k in 0..3 {
        if k > 0 {
            retype(&mut pic, &mut rng, 1);
        }
        let mut b = Hybrid::new();
        a.closed_loop(&pic.y, &pic.u, &pic.v, 300, 200, &blocks, None, 0, 80, 1, 1)
            .unwrap();
        b.closed_loop(&pic.y, &pic.u, &pic.v, 300, 200, &blocks, None, 0, 80, 1, 1)
            .unwrap();
        assert_eq!(a.record(), b.record());
        assert_eq!(a.output().recon, b.output().recon);
        kept += a.reused_tiles();
    }
    assert!(kept > 0);
}

/// Key frames with intra block copies: a screen picture with areas repeated (at even and odd
/// offsets), on one tile and on several, random and variance partitions. Blocks copy, the frame
/// has no post-filters, it parses back to its record, it codes the same on one thread as on all,
/// and (with dav1d installed) decodes to exactly the closed loop's reconstruction. A photo codes as
/// without the search (too few copies).
#[test]
fn intrabc_key_frames() {
    use crate::writer::parse_with;
    // (the last `nudged` repeats have a sample in every 16x16 off by 3: lossy copies)
    for (seed, (w, h), (cl, rl), style, repeats, nudged) in [
        (1u64, (600usize, 400usize), (0, 0), Style::Variance, 6, 0),
        (2, (600, 400), (1, 0), Style::Random, 12, 0),
        (3, (333, 517), (0, 1), Style::Variance, 6, 0),
        (4, (600, 400), (0, 0), Style::Variance, 0, 0),
        (5, (600, 400), (0, 0), Style::Variance, 12, 8),
    ] {
        let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
        let mut pic = screen_pic(w, h, seed, seed == 3);
        let mut rng = Rng(seed * 7 + 1);
        if repeats == 0 {
            // a photo: nothing repeats exactly
            pic.noise(&mut rng, 0, 0, w, h, 30);
        }
        // repeats: a source rectangle copied (luma and chroma) to even positions below and right
        let (sx, sy, rw, rh) = (w * 2 / 5 + 8, 8usize, 96usize, 80usize);
        for k in 0..repeats {
            let dx = (rng.below((w - rw) as u32) as usize) & !1;
            let dy = ((80 + rng.below((h - rh - 80) as u32)) as usize) & !1;
            for y in 0..rh {
                for x in 0..rw {
                    let v = pic.y[(sy + y) * w + sx + x];
                    let nudge = k >= repeats - nudged && x % 16 == 5 && y % 16 == 9;
                    pic.y[(dy + y) * w + dx + x] = if nudge { v.wrapping_add(3).max(3) } else { v };
                }
            }
            for y in 0..rh / 2 {
                for x in 0..rw / 2 {
                    let (d, s) = ((dy / 2 + y) * cw + dx / 2 + x, (sy / 2 + y) * cw + sx / 2 + x);
                    (pic.u[d], pic.v[d]) = (pic.u[s], pic.v[s]);
                }
            }
        }
        let tiles = tile_layout(w as u32, h as u32, cl, rl).unwrap();
        let blocks = partition(&pic, &tiles, &mut rng, style, false);
        let run = |threads: usize| {
            let mut hy = Hybrid::new();
            hy.threads = threads;
            hy.set_intrabc(true);
            hy.closed_loop(&pic.y, &pic.u, &pic.v, w as u32, h as u32, &blocks, None, 0, 90, cl, rl)
                .unwrap();
            hy
        };
        let mut hy = run(Hybrid::new().threads);
        let rec = hy.record().clone();
        let copies = rec.inter.iter().filter(|i| i.is_inter != 0).count();
        // the hashes taken ahead of the closed loop (on another thread) are the search's, and a
        // search given them finds what it finds alone
        let mut pre = Vec::new();
        super::intrabc::hash_picture(&pic.y, w as u32, h as u32, &mut pre, 3);
        assert!(pre == hy.ibc.h8, "seed {seed}: the hashes taken ahead");
        let mut given = Hybrid::new();
        given.set_intrabc(true);
        given.use_ibc_hashes(&mut pre, w as u32, h as u32);
        given
            .closed_loop(&pic.y, &pic.u, &pic.v, w as u32, h as u32, &blocks, None, 0, 90, cl, rl)
            .unwrap();
        assert!(given.record() == &rec, "seed {seed}: a search given its hashes");
        if repeats == 0 {
            let mut plain = Hybrid::new();
            plain
                .closed_loop(&pic.y, &pic.u, &pic.v, w as u32, h as u32, &blocks, None, 0, 90, cl, rl)
                .unwrap();
            assert!(
                copies == 0 && rec == *plain.record(),
                "seed {seed}: copies without repeats ({copies}; {} of {} non-flat 8x8s)",
                hy.ibc.busy_copied,
                hy.ibc.busy
            );
            continue;
        }
        assert!(copies > 0 && rec.fp.allow_intrabc == 1, "seed {seed}: no copies");
        assert!(
            nudged == 0 || hy.ibc.busy_copied > hy.ibc.busy_exact,
            "seed {seed}: no lossy copies ({} of {} non-flat 8x8s copied, {} exactly)",
            hy.ibc.busy_copied,
            hy.ibc.busy,
            hy.ibc.busy_exact
        );
        let one = run(1);
        assert!(
            one.record() == &rec && one.output().recon == hy.output().recon,
            "seed {seed}: threads"
        );
        let recon: Vec<Vec<u8>> = (0..3).map(|k| hy.recon(k).unwrap().to_vec()).collect();
        // whatever filters the caller asks for, the frame has none
        let mut wfp = rec.fp;
        (wfp.loop_filter_level, wfp.enable_cdef, wfp.cdef_bits) = ([10, 10, 5, 5], 1, 1);
        let sb_cdef = vec![1i8; w.div_ceil(64) * h.div_ceil(64)];
        let obu = hy.write(&wfp, Some(&sb_cdef), w.div_ceil(64)).unwrap().to_vec();
        let p = parse_with(&obu, None).unwrap();
        assert_eq!(p.rec.fp.allow_intrabc, 1);
        assert_eq!(p.rec.fp.loop_filter_level, [0; 4]);
        assert_eq!(p.rec.blocks.len(), rec.blocks.len(), "seed {seed}");
        for (i, (a, b)) in rec.inter.iter().zip(&p.rec.inter).enumerate() {
            assert_eq!(a, b, "seed {seed}: inter entry {i}");
        }
        eprintln!(
            "seed {seed}: {copies} of {} blocks copy, {} bytes",
            rec.blocks.len(),
            obu.len()
        );
        let dav1d = "/opt/homebrew/bin/dav1d";
        if std::path::Path::new(dav1d).exists() {
            let dir = std::env::temp_dir().join(format!("glassact-intrabc-{}-{seed}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let (inp, out) = (dir.join("f.obu"), dir.join("f.yuv"));
            std::fs::write(&inp, &obu).unwrap();
            let st = std::process::Command::new(dav1d)
                .args(["-q", "--demuxer", "section5", "-i"])
                .arg(&inp)
                .arg("-o")
                .arg(&out)
                .output()
                .unwrap();
            assert!(st.status.success(), "dav1d: {}", String::from_utf8_lossy(&st.stderr));
            let d = std::fs::read(&out).unwrap();
            // the reconstruction cropped to the picture (its planes are MiCols * 4 wide)
            let rw = hy.output().recon_w;
            let mut want = Vec::new();
            for (k, r) in recon.iter().enumerate() {
                let (pw, ph) = if k == 0 { (w, h) } else { (cw, ch) };
                for y in 0..ph {
                    want.extend_from_slice(&r[y * rw[k] as usize..][..pw]);
                }
            }
            assert_eq!(d.len(), want.len(), "seed {seed}: dav1d output size");
            assert!(d == want, "seed {seed}: dav1d decodes another picture");
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
}

/// A 4:4:4 picture of `p`: its chroma at full size (nearest), with per-sample colour on its dark
/// samples (text's subpixel fringes, which 4:2:0 can't carry).
fn to_444(p: &Pic) -> (Vec<u8>, Vec<u8>) {
    let (w, h, cw) = (p.w, p.h, p.cw());
    let (mut u, mut v) = (vec![0u8; w * h], vec![0u8; w * h]);
    for y in 0..h {
        for x in 0..w {
            let k = (y / 2) * cw + x / 2;
            let f = if p.y[y * w + x] < 100 {
                [24i32, 0, -24][x % 3]
            } else {
                0
            };
            u[y * w + x] = (p.u[k] as i32 + f).clamp(0, 255) as u8;
            v[y * w + x] = (p.v[k] as i32 - f).clamp(0, 255) as u8;
        }
    }
    (u, v)
}

/// An IVF file of one frame's OBUs.
fn ivf1(obu: &[u8], w: usize, h: usize) -> Vec<u8> {
    let mut v = b"DKIF".to_vec();
    v.extend_from_slice(&0u16.to_le_bytes());
    v.extend_from_slice(&32u16.to_le_bytes());
    v.extend_from_slice(b"AV01");
    v.extend_from_slice(&(w as u16).to_le_bytes());
    v.extend_from_slice(&(h as u16).to_le_bytes());
    for x in [30u32, 1, 1, 0] {
        v.extend_from_slice(&x.to_le_bytes());
    }
    v.extend_from_slice(&(obu.len() as u32).to_le_bytes());
    v.extend_from_slice(&0u64.to_le_bytes());
    v.extend_from_slice(obu);
    v
}

/// 4:4:4 key frames from the closed loop (Hybrid::set_chroma_444): screen pictures (text with
/// colour fringes, gradients, UI, a photo region), tiny and odd sizes, one tile and several,
/// random and variance partitions, with intra block copies or with deblocking and CDEF. The
/// closed loop decides chroma itself (or keeps the given decisions), codes the same on one thread
/// as on all, its record is 4:4:4 and the write keeps it so; the bitstream parses back to the record,
/// whose writer reconstruction is the closed loop's post-filtered, and (where installed) dav1d
/// and aomdec decode exactly that. (Inter frames: [`chroma444_inter_frames`].)
#[test]
fn chroma444_key_frames() {
    use crate::writer::parse_with;
    let tools: Vec<(&str, Vec<&str>)> = vec![
        ("dav1d", vec!["-q", "-i", "IN", "-o", "OUT"]),
        ("aomdec", vec!["--rawvideo", "-o", "OUT", "IN"]),
    ];
    let (mut decoded, mut stale_checks) = (0, 0);
    let mut palettes = [0usize; 2];
    for (seed, (w, h), (cl, rl), style, abc, pal) in [
        (1u64, (600usize, 400usize), (0, 0), Style::Variance, false, false),
        (2, (600, 400), (1, 0), Style::Random, false, false),
        (3, (333, 517), (0, 1), Style::Variance, false, false),
        (4, (77, 45), (0, 0), Style::Random, false, false),
        (5, (13, 7), (0, 0), Style::Variance, false, false),
        (6, (600, 400), (0, 0), Style::Variance, true, false),
        (7, (333, 517), (1, 1), Style::Random, true, false),
        // palette blocks, luma and chroma (Hybrid::set_palette), past the picture's edges too
        (8, (600, 400), (0, 0), Style::Variance, false, true),
        (9, (333, 517), (1, 1), Style::Random, false, true),
        (10, (77, 45), (0, 0), Style::Variance, false, true),
        (11, (600, 400), (0, 0), Style::Variance, true, true),
    ] {
        let what = format!("seed {seed} {w}x{h}{}", if pal { " palettes" } else { "" });
        let pic = screen_pic(w, h, seed, seed == 3);
        let (mut u, mut v) = to_444(&pic);
        let mut y = pic.y.clone();
        let mut rng = Rng(seed * 13 + 5);
        if abc && w > 200 {
            // a source rectangle repeated (every plane) at even and odd positions below it
            let (sx, sy, rw, rh) = (w * 2 / 5 + 8, 8usize, 96usize, 80usize);
            for _ in 0..10 {
                let dx = rng.below((w - rw) as u32) as usize;
                let dy = (80 + rng.below((h - rh - 80) as u32)) as usize;
                for p in [&mut y, &mut u, &mut v] {
                    for yy in 0..rh {
                        p.copy_within((sy + yy) * w + sx..(sy + yy) * w + sx + rw, (dy + yy) * w + dx);
                    }
                }
            }
        }
        let tiles = tile_layout(w as u32, h as u32, cl, rl).unwrap();
        let blocks = partition(&pic, &tiles, &mut rng, style, true);
        let run = |threads: usize, flags: i32| {
            let mut hy = Hybrid::new();
            hy.threads = threads;
            hy.set_chroma_444(true);
            hy.set_intrabc(abc);
            hy.set_palette(pal);
            hy.closed_loop(&y, &u, &v, w as u32, h as u32, &blocks, None, flags, 90, cl, rl)
                .unwrap_or_else(|e| panic!("{what}: {e}"));
            hy
        };
        let mut hy = run(Hybrid::new().threads, 0);
        let rec = hy.record().clone();
        assert_eq!(rec.fp.chroma_format, CHROMA_444, "{what}");
        // (seed 7's repeats straddle its tiles, which copies can't: it searches and doesn't copy)
        assert_eq!(seed == 6 || seed == 11, rec.fp.allow_intrabc == 1, "{what}: copies");
        if pal {
            palettes[0] += rec.palette.iter().filter(|p| p.size_y != 0).count();
            palettes[1] += rec.palette.iter().filter(|p| p.size_uv != 0).count();
        } else {
            assert!(rec.palette.is_empty(), "{what}: palettes without set_palette");
        }
        let (mc4, mr4) = (mi_cols(w as i32) as usize * 4, mi_rows(h as i32) as usize * 4);
        for k in 0..3 {
            assert_eq!(hy.recon(k).unwrap().len(), mc4 * mr4, "{what}: plane {k}");
        }
        let one = run(1, 0);
        assert!(
            one.record() == &rec && one.output().recon == hy.output().recon,
            "{what}: threads"
        );
        // the analysis's chroma, given: kept, as in 4:2:0 (but where a chroma palette replaces it;
        // a picture with intra block copies has blocks of its own)
        let given = run(Hybrid::new().threads, GIVEN_CHROMA);
        let g = given.record();
        if g.fp.allow_intrabc == 0 {
            assert_eq!(g.blocks.len(), blocks.len(), "{what}: given chroma");
            for (i, (b, gb)) in blocks.iter().zip(&g.blocks).enumerate() {
                assert!(
                    g.palette.get(i).is_some_and(|p| p.size_uv != 0)
                        || (gb.uv_mode, gb.angle_delta_uv, gb.cfl_alpha_u, gb.cfl_alpha_v)
                            == (b.uv_mode, b.angle_delta_uv, b.cfl_alpha_u, b.cfl_alpha_v),
                    "{what}: block {i}'s given chroma"
                );
            }
        }
        assert!(
            w < 200 || rec.blocks.iter().any(|b| b.uv_mode as i32 == UV_CFL_PRED),
            "{what}: no CfL"
        );
        // the write: post-filters chosen (none where it copies), and a caller's fp saying 4:2:0
        let mut wfp = rec.fp;
        (wfp.loop_filter_level, wfp.loop_filter_sharpness) = ([12, 9, 7, 6], 2);
        (wfp.enable_cdef, wfp.cdef_bits, wfp.cdef_damping_minus_3) = (1, 1, 2);
        wfp.cdef_y_pri[..2].copy_from_slice(&[3, 6]);
        wfp.cdef_y_sec[..2].copy_from_slice(&[1, 2]);
        wfp.cdef_uv_pri[..2].copy_from_slice(&[2, 5]);
        wfp.cdef_uv_sec[..2].copy_from_slice(&[0, 4]);
        wfp.chroma_format = CHROMA_420;
        let sbc = w.div_ceil(64);
        let sb_cdef: Vec<i8> = (0..sbc * h.div_ceil(64)).map(|_| rng.below(2) as i8).collect();
        let obu = hy.write(&wfp, Some(&sb_cdef), sbc).unwrap().to_vec();
        let fin = hy.record().clone();
        assert_eq!(fin.fp.chroma_format, CHROMA_444, "{what}: the write keeps 4:4:4");
        // the closed loop's reconstruction, post-filtered as the record says, cropped
        let rw = hy.output().recon_w;
        let mut planes: Vec<Vec<u8>> = (0..3).map(|k| hy.recon(k).unwrap().to_vec()).collect();
        // (a frame with intra block copies has none: postfilter_ex doesn't know that, and would
        // CDEF it with the enable_cdef the write leaves)
        if fin.fp.allow_intrabc == 0 {
            let [a, b, c] = &mut planes[..] else { unreachable!() };
            let mut pl: [&mut [u8]; 3] = [a, b, c];
            crate::postfilter::postfilter_ex(&fin.fp, &fin.blocks, &fin.inter, &mut pl, &rw.map(|x| x as usize));
        }
        let mut want = Vec::new();
        for (k, p) in planes.iter().enumerate() {
            for yy in 0..h {
                want.extend_from_slice(&p[yy * rw[k] as usize..][..w]);
            }
        }
        // it parses back to the record, whose writer reconstruction is that
        let p = parse_with(&obu, None).unwrap_or_else(|e| panic!("{what}: parse: {e}"));
        assert_eq!(p.rec.fp.chroma_format, CHROMA_444);
        assert_eq!(p.rec.blocks.len(), fin.blocks.len(), "{what}");
        let mut again = p.rec.clone();
        let mut o = Output::default();
        Writer::new()
            .encode(
                again.as_mut(),
                &EncodeOpts {
                    flags: 0,
                    seq_level_idx: -1,
                },
                &mut o,
            )
            .unwrap();
        let no_td = |b: &[u8]| {
            if b.starts_with(&[0x12, 0]) {
                b[2..].to_vec()
            } else {
                b.to_vec()
            }
        };
        assert!(
            no_td(&o.obu) == no_td(&obu),
            "{what}: the parsed record codes another stream"
        );
        let wr: Vec<u8> = o.recon.concat();
        assert!(
            wr == want,
            "{what}: the writer's reconstruction isn't the closed loop's post-filtered"
        );
        eprintln!(
            "{what}: {} blocks, {} copy, {} CfL, {} / {} luma / chroma palettes, {} bytes",
            fin.blocks.len(),
            fin.inter.iter().filter(|i| i.is_inter != 0).count(),
            fin.blocks.iter().filter(|b| b.uv_mode as i32 == UV_CFL_PRED).count(),
            fin.palette.iter().filter(|p| p.size_y != 0).count(),
            fin.palette.iter().filter(|p| p.size_uv != 0).count(),
            obu.len()
        );
        let dir = std::env::temp_dir().join(format!("glassact-444-{}-{seed}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let inp = dir.join("f.ivf");
        std::fs::write(&inp, ivf1(&obu, w, h)).unwrap();
        for (tool, args) in &tools {
            let path = format!("/opt/homebrew/bin/{tool}");
            if !std::path::Path::new(&path).exists() {
                continue;
            }
            let out = dir.join(format!("{tool}.yuv"));
            let args: Vec<String> = args
                .iter()
                .map(|a| match *a {
                    "IN" => inp.display().to_string(),
                    "OUT" => out.display().to_string(),
                    a => a.to_string(),
                })
                .collect();
            let st = std::process::Command::new(&path).args(&args).output().unwrap();
            assert!(
                st.status.success(),
                "{what}: {tool}: {}",
                String::from_utf8_lossy(&st.stderr)
            );
            let d = std::fs::read(&out).unwrap();
            assert_eq!(d.len(), want.len(), "{what}: {tool} output size");
            if d != want {
                let i = (0..d.len()).find(|&i| d[i] != want[i]).unwrap();
                panic!(
                    "{what}: {tool} differs first at plane {} ({}, {})",
                    i / (w * h),
                    i % w,
                    (i % (w * h)) / w
                );
            }
            decoded += 1;
        }
        let _ = std::fs::remove_dir_all(&dir);
        // the same picture again: every tile kept, the same record and bytes
        hy.closed_loop(&y, &u, &v, w as u32, h as u32, &blocks, None, 0, 90, cl, rl)
            .unwrap();
        assert_eq!(hy.reused_tiles(), tiles.rows * tiles.cols, "{what}: tiles kept");
        let again = hy.write(&wfp, Some(&sb_cdef), sbc).unwrap().to_vec();
        assert!(
            again == obu && hy.record() == &fin,
            "{what}: kept tiles code another picture"
        );
        let ntiles = tiles.rows * tiles.cols;
        if ntiles > 1 {
            // one chroma sample at an odd position of the last tile changed: that tile alone is
            // coded again, and the picture is what a fresh closed loop makes of it
            let (px, py) = ((w - 2) | 1, (h - 2) | 1);
            let mut u2 = u.clone();
            u2[py * w + px] ^= 0x40;
            hy.closed_loop(&y, &u2, &v, w as u32, h as u32, &blocks, None, 0, 90, cl, rl)
                .unwrap();
            assert_eq!(
                hy.reused_tiles(),
                ntiles - 1,
                "{what}: tiles kept after a chroma change"
            );
            let kept = hy.write(&wfp, Some(&sb_cdef), sbc).unwrap().to_vec();
            let mut fresh = Hybrid::new();
            fresh.set_chroma_444(true);
            fresh.set_intrabc(abc);
            fresh.set_palette(pal);
            fresh
                .closed_loop(&y, &u2, &v, w as u32, h as u32, &blocks, None, 0, 90, cl, rl)
                .unwrap();
            let want = fresh.write(&wfp, Some(&sb_cdef), sbc).unwrap().to_vec();
            assert!(
                kept == want && hy.record() == fresh.record(),
                "{what}: a kept tile went stale"
            );
            stale_checks += 1;
        }
    }
    eprintln!(
        "{decoded} decodes exact, {stale_checks} pictures partly kept, {} luma and {} chroma palettes",
        palettes[0], palettes[1]
    );
    assert!(stale_checks >= 2);
    assert!(palettes[0] > 0 && palettes[1] > 0, "palettes {palettes:?}");
}

/// An IVF file of frames' OBUs.
fn ivf_n(obus: &[Vec<u8>], w: usize, h: usize) -> Vec<u8> {
    let mut v = ivf1(&[], w, h)[..32].to_vec();
    v[24..28].copy_from_slice(&(obus.len() as u32).to_le_bytes());
    for (k, obu) in obus.iter().enumerate() {
        v.extend_from_slice(&(obu.len() as u32).to_le_bytes());
        v.extend_from_slice(&(k as u64).to_le_bytes());
        v.extend_from_slice(obu);
    }
    v
}

/// 4:4:4 inter frames from the closed loop: a key frame, then inter frames with copies
/// (unchanged, and shifted by odd amounts, which 4:4:4 copies exactly:
/// [`crate::motion::Motion::set_chroma_444`]), copies of an older picture (GOLDEN_FRAME), coded
/// inter blocks with sub-sample motion and a residual, and intra blocks (CfL, palettes); 64x64 and
/// 128x128 superblocks, one tile and several. Copies hold their reference's samples in every
/// plane; each frame parses back to its record; our decoder (and dav1d and aomdec, where
/// installed) decode every frame to the closed loop's reconstruction; one thread codes what all do.
#[test]
fn chroma444_inter_frames() {
    use crate::motion::{Motion, Plane};
    use crate::writer::{ParseState, parse_with, tile_layout_ex};
    let tools: Vec<(&str, Vec<&str>)> = vec![
        ("dav1d", vec!["-q", "-i", "IN", "-o", "OUT"]),
        ("aomdec", vec!["--rawvideo", "-o", "OUT", "IN"]),
    ];
    let (mut decoded, mut odd_copies, mut golden_copies, mut coded_inter, mut cfl, mut pal) = (0, 0, 0, 0, 0, 0);
    for (seed, (w, h), sb128, (cl, rl)) in [
        (1u64, (600usize, 400usize), false, (0, 0)),
        (2, (600, 400), true, (1, 0)),
        (3, (333, 517), false, (1, 1)),
        (4, (77, 45), false, (0, 0)),
    ] {
        let what = format!("seed {seed} {w}x{h}{}", if sb128 { " sb128" } else { "" });
        let mut rng = Rng(seed * 31 + 7);
        // the pictures, each plane w x h
        let base = screen_pic(w, h, seed, false);
        let (u0, v0) = to_444(&base);
        let f0 = [base.y.clone(), u0, v0];
        let other = screen_pic(w, h, seed + 100, true);
        let (ou, ov) = to_444(&other);
        let other = [other.y.clone(), ou, ov];
        // 1: below row 128 scrolled up 13 rows (new rows at the bottom), and a new rectangle above
        // 2: below row 128 back to 0's (GOLDEN_FRAME's), and another new rectangle above
        let mut f1 = f0.clone();
        let mut f2 = f0.clone();
        for p in 0..3 {
            for y in 128.min(h)..h {
                for x in 0..w {
                    f1[p][y * w + x] = if y + 13 < h {
                        f0[p][(y + 13) * w + x]
                    } else {
                        rng.below(256) as u8
                    };
                }
            }
            for y in 8..(120.min(h)) {
                for x in w / 4..(w * 3 / 4) {
                    f1[p][y * w + x] = other[p][y * w + x];
                    f2[p][y * w + x] = other[p][((y + 40) % h) * w + (x + 17) % w];
                }
            }
        }
        let frames = [f0, f1, f2];
        fn planes(f: &[Vec<u8>; 3], w: usize, h: usize) -> [Plane<'_>; 3] {
            core::array::from_fn(|p| Plane {
                data: &f[p],
                stride: w,
                width: w,
                height: h,
            })
        }
        fn rp(r: &[Vec<u8>], rw: [u32; 3]) -> RefPicture<'_> {
            RefPicture {
                plane: [&r[0], &r[1], &r[2]],
                stride: rw.map(|x| x as usize),
                cdfs: None,
            }
        }
        let (mc, mr) = (mi_cols(w as i32), mi_rows(h as i32));
        let sb_cols = w.div_ceil(64);
        let tiles = if sb128 {
            tile_layout(w as u32, h as u32, 0, 0).unwrap()
        } else {
            tile_layout(w as u32, h as u32, cl, rl).unwrap()
        };
        let tiles128 = sb128.then(|| tile_layout_ex(w as u32, h as u32, cl, rl, true).unwrap());
        let run = |threads: usize, count: bool, stats: &mut [usize; 6]| -> Vec<Vec<u8>> {
            let mut rng = Rng(seed * 101 + 3);
            let mut m = Motion::new();
            m.set_chroma_444(true);
            let mut hy = Hybrid::new();
            hy.threads = threads;
            hy.set_chroma_444(true);
            hy.set_palette(true);
            let mut ps = ParseState::default();
            let mut recons: Vec<Vec<Vec<u8>>> = Vec::new();
            let mut rws = Vec::new();
            let mut obus = Vec::new();
            for (k, f) in frames.iter().enumerate() {
                let pic = Pic {
                    w,
                    h,
                    y: f[0].clone(),
                    u: vec![128; w.div_ceil(2) * h.div_ceil(2)],
                    v: vec![128; w.div_ceil(2) * h.div_ceil(2)],
                };
                let blocks = partition(&pic, &tiles, &mut rng, Style::Variance, true);
                let mut fp = FrameParams {
                    video: 1,
                    sb128: sb128 as u8,
                    ..Default::default()
                };
                let (mut blocks, mut inter) = (blocks, Vec::new());
                let mut sbs = Vec::new();
                if k > 0 {
                    let (cur, prev, gold) = (planes(f, w, h), planes(&frames[k - 1], w, h), planes(&frames[0], w, h));
                    m.classify_ex(&cur, &prev, (k == 2).then_some(&gold), 3, 4);
                    sbs = m.sbs.clone();
                    m.apply_ex(&sbs, sb_cols, &blocks, None, None, mr, mc, tiles128.as_ref())
                        .unwrap();
                    (blocks, inter) = (m.blocks.clone(), m.inter.clone());
                    // coded inter blocks: every 4th intra block of 8x8 and up predicts from
                    // LAST_FRAME at a quarter-sample motion vector, with a residual
                    for (i, (b, bi)) in blocks.iter_mut().zip(inter.iter_mut()).enumerate() {
                        let bs = b.bsize as i32;
                        if bi.is_inter == 0
                            && i % 4 == 1
                            && bw4(bs) >= 2
                            && bh4(bs) >= 2
                            && bw4(bs) <= 16
                            && bh4(bs) <= 16
                        {
                            *b = Block {
                                mi_row: b.mi_row,
                                mi_col: b.mi_col,
                                bsize: b.bsize,
                                ..Block::default()
                            };
                            (bi.is_inter, bi.mv_row, bi.mv_col) =
                                (1, -26 + 2 * (i % 5) as i16, 14 - 4 * (i % 3) as i16);
                        }
                    }
                    (
                        fp.frame_type,
                        fp.refresh_frame_flags,
                        fp.mv_precision,
                        fp.allow_screen_content_tools,
                    ) = (FRAME_INTER, 1, 1, 1);
                    fp.golden_slot = if k == 2 { 2 } else { 0 };
                } else if let Some(t) = tiles128.as_ref() {
                    m.apply_ex(&[], 0, &blocks, None, None, mr, mc, Some(t)).unwrap();
                    blocks = m.blocks.clone();
                }
                let video = Video {
                    fp,
                    inter: &inter,
                    reference: (k > 0).then(|| rp(&recons[k - 1], rws[k - 1])),
                    golden: (k == 2).then(|| rp(&recons[0], rws[0])),
                    padded: None,
                };
                hy.closed_loop_ex(
                    &f[0],
                    &f[1],
                    &f[2],
                    w as u32,
                    h as u32,
                    &blocks,
                    None,
                    0,
                    90,
                    cl,
                    rl,
                    Some(&video),
                    None,
                )
                .unwrap_or_else(|e| panic!("{what} frame {k}: {e}"));
                let rec = hy.record().clone();
                assert_eq!(rec.fp.chroma_format, CHROMA_444, "{what} frame {k}");
                let rw = hy.output().recon_w;
                let recon: Vec<Vec<u8>> = (0..3).map(|p| hy.recon(p).unwrap().to_vec()).collect();
                // copies are their reference's samples, every plane full size
                for (s, sm) in sbs.iter().enumerate().filter(|(_, sm)| sm.copy) {
                    let (from, frw) = if sm.golden {
                        (&recons[0], rws[0])
                    } else {
                        (&recons[k - 1], rws[k - 1])
                    };
                    let (sx, sy) = (s % sb_cols, s / sb_cols);
                    for p in 0..3 {
                        for y in sy * 64..((sy + 1) * 64).min(h) {
                            for x in sx * 64..((sx + 1) * 64).min(w) {
                                let (qx, qy) = ((x as i32 + sm.shift.dx) as usize, (y as i32 + sm.shift.dy) as usize);
                                assert_eq!(
                                    recon[p][y * rw[p] as usize + x],
                                    from[p][qy * frw[p] as usize + qx],
                                    "{what} frame {k}: 64x64 {s} plane {p} ({x}, {y})"
                                );
                            }
                        }
                    }
                    if count {
                        stats[0] += (sm.shift.dy & 1 != 0 || sm.shift.dx & 1 != 0) as usize;
                        stats[1] += sm.golden as usize;
                    }
                }
                if count {
                    for (i, b) in rec.blocks.iter().enumerate() {
                        let inter_b = rec.inter.get(i).is_some_and(|x| x.is_inter != 0);
                        let coded = (rec.block_txb[i]..rec.block_txb[i + 1]).any(|t| rec.txb[t as usize].eob > 0);
                        stats[2] += (k > 0 && inter_b && coded) as usize;
                        stats[3] += (k > 0 && !inter_b && b.uv_mode as i32 == UV_CFL_PRED) as usize;
                        stats[4] +=
                            (k > 0 && rec.palette.get(i).is_some_and(|p| p.size_y != 0 || p.size_uv != 0)) as usize;
                    }
                }
                let mut wfp = rec.fp;
                (wfp.loop_filter_level, wfp.enable_cdef) = ([0; 4], 0);
                let obu = hy.write(&wfp, None, sb_cols).unwrap().to_vec();
                let p = parse_with(&obu, Some(&mut ps)).unwrap_or_else(|e| panic!("{what} frame {k}: parse: {e}"));
                assert_eq!(p.rec.fp.chroma_format, CHROMA_444);
                assert_eq!(p.rec.blocks.len(), hy.record().blocks.len(), "{what} frame {k}");
                assert_eq!(p.rec.inter, hy.record().inter, "{what} frame {k}");
                obus.push(obu);
                recons.push(recon);
                rws.push(rw);
            }
            // our decoder, then dav1d and aomdec: every frame the closed loop's reconstruction
            let mut want = Vec::new();
            let mut d = crate::decoder::Decoder::new(2);
            for (k, obu) in obus.iter().enumerate() {
                let pic = d
                    .decode(obu)
                    .unwrap_or_else(|e| panic!("{what} frame {k}: our decoder: {e}"));
                for p in 0..3 {
                    for y in 0..h {
                        let row = &recons[k][p][y * rws[k][p] as usize..][..w];
                        assert!(
                            &pic.planes[p][y * pic.stride[p]..][..w] == row,
                            "{what} frame {k}: our decoder differs in plane {p} row {y}"
                        );
                        want.extend_from_slice(row);
                    }
                }
            }
            if count {
                let dir = std::env::temp_dir().join(format!("glassact-444i-{}-{seed}", std::process::id()));
                std::fs::create_dir_all(&dir).unwrap();
                let inp = dir.join("s.ivf");
                std::fs::write(&inp, ivf_n(&obus, w, h)).unwrap();
                for (tool, args) in &tools {
                    let path = format!("/opt/homebrew/bin/{tool}");
                    if !std::path::Path::new(&path).exists() {
                        continue;
                    }
                    let out = dir.join(format!("{tool}.yuv"));
                    let args: Vec<String> = args
                        .iter()
                        .map(|a| match *a {
                            "IN" => inp.display().to_string(),
                            "OUT" => out.display().to_string(),
                            a => a.to_string(),
                        })
                        .collect();
                    let st = std::process::Command::new(&path).args(&args).output().unwrap();
                    assert!(
                        st.status.success(),
                        "{what}: {tool}: {}",
                        String::from_utf8_lossy(&st.stderr)
                    );
                    let got = std::fs::read(&out).unwrap();
                    assert_eq!(got.len(), want.len(), "{what}: {tool} output size");
                    if got != want {
                        let i = (0..got.len()).find(|&i| got[i] != want[i]).unwrap();
                        panic!(
                            "{what}: {tool} differs first in frame {} plane {}",
                            i / (3 * w * h),
                            (i / (w * h)) % 3
                        );
                    }
                    stats[5] += obus.len();
                }
                let _ = std::fs::remove_dir_all(&dir);
            }
            obus
        };
        let mut stats = [0usize; 6];
        let all = run(Hybrid::new().threads, true, &mut stats);
        let one = run(1, false, &mut [0; 6]);
        assert!(one == all, "{what}: threads");
        eprintln!(
            "{what}: {} bytes; odd copies {}, GOLDEN copies {}, coded inter blocks {}, CfL {}, palettes {} (inter frames)",
            all.iter().map(|o| o.len()).sum::<usize>(),
            stats[0],
            stats[1],
            stats[2],
            stats[3],
            stats[4]
        );
        odd_copies += stats[0];
        golden_copies += stats[1];
        coded_inter += stats[2];
        cfl += stats[3];
        pal += stats[4];
        decoded += stats[5];
    }
    eprintln!("{decoded} frames decoded exactly by the installed decoders");
    assert!(odd_copies > 10 && golden_copies > 10 && coded_inter > 20 && cfl > 0 && pal > 0);
}

/// A 4:4:4 stream post-filtered on the CPU ([`Hybrid::postfilter_cpu`]): a key frame and inter
/// frames (an odd-shift scroll, new content), each deblocked and CDEF-filtered at several qindexes
/// (CDEF off at 32 and under), written with the filters chosen and referenced filtered: our
/// decoder decodes every frame to the filtered planes, and CDEF's presets are used. (av1seq
/// --chroma 444 --cpu-filters holds them to libaom's decode.)
#[test]
fn chroma444_cpu_filters_decode_exactly() {
    let (w, h) = (333usize, 270usize);
    let base = screen_pic(w, h, 21, true);
    let (u0, v0) = to_444(&base);
    let f0 = [base.y.clone(), u0, v0];
    let mut f1 = f0.clone();
    for p in 0..3 {
        for y in 0..h {
            for x in 0..w {
                f1[p][y * w + x] = f0[p][((y + 7) % h) * w + x] ^ if x > w / 2 && y < 60 { 0x30 } else { 0 };
            }
        }
    }
    let frames = [f0.clone(), f1.clone(), f0];
    for q in [20, 90, 200] {
        let tiles = tile_layout(w as u32, h as u32, 0, 0).unwrap();
        let mut rng = Rng(q as u64);
        let mut hy = Hybrid::new();
        hy.set_chroma_444(true);
        let mut d = crate::decoder::Decoder::new(2);
        let mut prev: Option<[Vec<u8>; 3]> = None;
        let mut cdef_used = false;
        for (k, f) in frames.iter().enumerate() {
            let pic = Pic {
                w,
                h,
                y: f[0].clone(),
                u: vec![128; w.div_ceil(2) * h.div_ceil(2)],
                v: vec![128; w.div_ceil(2) * h.div_ceil(2)],
            };
            let mut blocks = partition(&pic, &tiles, &mut rng, Style::Variance, true);
            let mut inter = Vec::new();
            let mut fp = FrameParams {
                video: 1,
                ..Default::default()
            };
            if k > 0 {
                // every 3rd block copies the reference 7 rows down, the rest intra
                inter = blocks
                    .iter()
                    .enumerate()
                    .map(|(i, _)| BlockInter {
                        is_inter: (i % 3 == 0) as u8,
                        mv_row: if i % 3 == 0 { 56 } else { 0 },
                        mv_col: 0,
                        ..Default::default()
                    })
                    .collect();
                for (b, bi) in blocks.iter_mut().zip(&inter) {
                    if bi.is_inter != 0 {
                        *b = Block {
                            mi_row: b.mi_row,
                            mi_col: b.mi_col,
                            bsize: b.bsize,
                            ..Block::default()
                        };
                    }
                }
                (fp.frame_type, fp.refresh_frame_flags, fp.allow_screen_content_tools, fp.lf_inter_off) =
                    (FRAME_INTER, 1, 1, (k == 2) as u8);
            }
            let p = prev.as_ref();
            let video = Video {
                fp,
                inter: &inter,
                reference: p.map(|r| RefPicture {
                    plane: [&r[0], &r[1], &r[2]],
                    stride: [w, w, w],
                    cdfs: None,
                }),
                golden: None,
                padded: None,
            };
            hy.closed_loop_ex(&f[0], &f[1], &f[2], w as u32, h as u32, &blocks, None, 0, q, 0, 0, Some(&video), None)
                .unwrap_or_else(|e| panic!("q{q} frame {k}: {e}"));
            let mut out = [vec![0u8; w * h], vec![0u8; w * h], vec![0u8; w * h]];
            let mut sb = Vec::new();
            let pfp = {
                let [a, b, c] = &mut out;
                hy.postfilter_cpu([a, b, c], [w, w, w], &mut sb).unwrap()
            };
            assert!(q < 90 || pfp.loop_filter_level[0] != 0, "q{q}: no deblocking");
            cdef_used |= pfp.cdef_y_pri.iter().chain(&pfp.cdef_uv_pri).any(|&v| v != 0);
            let obu = hy.write(&pfp, Some(&sb), w.div_ceil(64)).unwrap().to_vec();
            let pic = d.decode(&obu).unwrap_or_else(|e| panic!("q{q} frame {k}: {e}"));
            for p in 0..3 {
                for y in 0..h {
                    assert!(
                        pic.planes[p][y * pic.stride[p]..][..w] == out[p][y * w..][..w],
                        "q{q} frame {k}: plane {p} row {y} isn't the filtered picture"
                    );
                }
            }
            prev = Some(out);
        }
        assert!(q <= 32 || cdef_used, "q{q}: no CDEF preset");
    }
}

/// The C API's 4:4:4 (av1enc_hybrid_set_chroma_444): full-size chroma planes read, the record
/// the Rust closed loop's.
#[cfg(feature = "capi")]
#[test]
fn chroma444_capi() {
    use crate::capi::*;
    let (w, h) = (150usize, 90usize);
    let pic = screen_pic(w, h, 21, false);
    let (u, v) = to_444(&pic);
    let tiles = tile_layout(w as u32, h as u32, 0, 0).unwrap();
    let blocks = partition(&pic, &tiles, &mut Rng(8), Style::Variance, false);
    let mut direct = Hybrid::new();
    direct.set_chroma_444(true);
    direct
        .closed_loop(&pic.y, &u, &v, w as u32, h as u32, &blocks, None, 0, 100, 0, 0)
        .unwrap();
    let mut err = [0 as core::ffi::c_char; 256];
    // SAFETY: a handle of av1enc_hybrid_create; full-size planes and the blocks; the record view
    // read before the handle is destroyed.
    unsafe {
        let hh = av1enc_hybrid_create();
        av1enc_hybrid_set_chroma_444(hh, 1);
        let rc = av1enc_hybrid_closed_loop(
            hh,
            pic.y.as_ptr(),
            u.as_ptr(),
            v.as_ptr(),
            w as u32,
            h as u32,
            blocks.as_ptr(),
            blocks.len() as u32,
            core::ptr::null(),
            0,
            100,
            0,
            0,
            err.as_mut_ptr(),
            err.len(),
        );
        assert_eq!(rc, OK);
        let r = &*av1enc_hybrid_record(hh);
        assert_eq!(r.fp.chroma_format, CHROMA_444);
        let want = direct.record();
        assert_eq!(r.n_txb as usize, want.txb.len());
        assert!(core::slice::from_raw_parts(r.coeffs, r.n_coeffs as usize) == &want.coeffs[..]);
        let pl = av1enc_hybrid_recon(hh, 2);
        let n = mi_cols(w as i32) as usize * 4 * mi_rows(h as i32) as usize * 4;
        assert!(core::slice::from_raw_parts(pl, n) == direct.recon(2).unwrap());
        av1enc_hybrid_destroy(hh);
    }
}

/// Still pictures with intra block copies, one after another: a tile whose source, blocks and
/// copies are unchanged keeps its closed loop and its bytes, and every picture codes as a fresh
/// closed loop codes it (record, reconstruction and bytes), the picture unchanged and then partly
/// re-typed (on several tiles).
#[test]
fn intrabc_tiles_kept() {
    let (w, h) = (640usize, 384usize);
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    let mut pic = screen_pic(w, h, 11, false);
    let mut rng = Rng(5);
    // in every tile (2 x 2, 320 x 192), its top-left text repeated below (a copy reads its tile)
    let (rw, rh) = (96usize, 56usize);
    for (tx, ty) in [(0usize, 0usize), (320, 0), (0, 192), (320, 192)] {
        let (sx, sy) = (tx + 8, ty + 4);
        for (dx, dy) in [
            (tx + 8, ty + 70),
            (tx + 120, ty + 70),
            (tx + 200, ty + 130),
            (tx + 40, ty + 130),
        ] {
            for y in 0..rh {
                pic.y
                    .copy_within((sy + y) * w + sx..(sy + y) * w + sx + rw, (dy + y) * w + dx);
            }
            for y in 0..rh / 2 {
                let (d, s) = ((dy / 2 + y) * cw + dx / 2, (sy / 2 + y) * cw + sx / 2);
                pic.u.copy_within(s..s + rw / 2, d);
                pic.v.copy_within(s..s + rw / 2, d);
            }
        }
    }
    let _ = ch;
    let (cl, rl) = (1, 1);
    let tiles = tile_layout(w as u32, h as u32, cl, rl).unwrap();
    let mut kept = 0;
    let mut a = Hybrid::new();
    a.set_intrabc(true);
    for k in 0..3 {
        if k == 2 {
            retype(&mut pic, &mut rng, 1);
        }
        let blocks = partition(&pic, &tiles, &mut Rng(9), Style::Variance, false);
        let mut b = Hybrid::new();
        b.set_intrabc(true);
        for hy in [&mut a, &mut b] {
            hy.closed_loop(&pic.y, &pic.u, &pic.v, w as u32, h as u32, &blocks, None, 0, 80, cl, rl)
                .unwrap();
        }
        assert_eq!(a.record().fp.allow_intrabc, 1, "picture {k}: no copies");
        assert!(a.record() == b.record(), "picture {k}: record");
        assert!(a.output().recon == b.output().recon, "picture {k}: reconstruction");
        let fp = a.record().fp;
        let (wa, wb) = (
            a.write(&fp, None, 0).unwrap().to_vec(),
            b.write(&fp, None, 0).unwrap().to_vec(),
        );
        assert!(wa == wb, "picture {k}: bytes");
        kept += a.reused_tiles();
    }
    assert!(kept >= 4, "{kept} tiles kept");
}

/// 128x128 superblocks through the hybrid encoder: a key frame whose 64x64-superblock partition
/// Motion::apply_ex puts in 128x128 decode order, then an inter frame of the next picture (the top
/// unchanged, the rest scrolled) whose copies apply_ex covers (one 128x128 skip inter block where
/// a 128x128 is all copies at one shift). Both code, write and parse back to their records, and
/// every copied 64x64 of the inter frame reconstructs as the key frame's reconstruction moved.
#[test]
fn sb128_frames_from_motion() {
    use crate::motion::{Motion, Plane, Shift};
    use crate::writer::{ParseState, parse_with, tile_layout_ex};
    let (w, h) = (520usize, 330usize);
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    let pic0 = screen_pic(w, h, 5, false);
    // the next picture: rows 0..128 unchanged, the rest scrolled up 16 rows (new rows at the bottom)
    let mut pic1 = pic0.clone();
    let mut rng = Rng(19);
    for y in 128..h {
        for x in 0..w {
            pic1.y[y * w + x] = if y + 16 < h {
                pic0.y[(y + 16) * w + x]
            } else {
                rng.below(256) as u8
            };
        }
    }
    for y in 64..ch {
        for x in 0..cw {
            let (u, v) = if y + 8 < ch {
                (pic0.u[(y + 8) * cw + x], pic0.v[(y + 8) * cw + x])
            } else {
                (rng.below(256) as u8, rng.below(256) as u8)
            };
            (pic1.u[y * cw + x], pic1.v[y * cw + x]) = (u, v);
        }
    }
    let (mc, mr) = (mi_cols(w as i32), mi_rows(h as i32));
    let sb_cols = w.div_ceil(64);
    let tiles64 = tile_layout(w as u32, h as u32, 0, 0).unwrap();
    let tiles128 = tile_layout_ex(w as u32, h as u32, 1, 0, true).unwrap();
    assert_eq!(tiles128.cols, 2);
    let mut m = Motion::new();
    let mut hy = Hybrid::new();
    let mut ps = ParseState::default();
    let wfp_of = |hy: &Hybrid| {
        // the post-filters off: the decoder's output is the pre-filter reconstruction
        let mut f = hy.record().fp;
        (f.loop_filter_level, f.enable_cdef) = ([0; 4], 0);
        f
    };
    // ---- the key frame ----
    let blocks0 = partition(&pic0, &tiles64, &mut rng, Style::Random, false);
    m.apply_ex(&[], 0, &blocks0, None, None, mr, mc, Some(&tiles128))
        .unwrap();
    assert_eq!(m.blocks.len(), blocks0.len());
    let key_blocks = m.blocks.clone();
    let mut fp = FrameParams {
        video: 1,
        sb128: 1,
        ..Default::default()
    };
    let video = Video {
        fp,
        inter: &[],
        reference: None,
        golden: None,
        padded: None,
    };
    let key_video = video;
    hy.closed_loop_ex(
        &pic0.y,
        &pic0.u,
        &pic0.v,
        w as u32,
        h as u32,
        &key_blocks,
        None,
        0,
        90,
        1,
        0,
        Some(&video),
        None,
    )
    .unwrap();
    let wfp = wfp_of(&hy);
    let obu = hy.write(&wfp, None, sb_cols).unwrap().to_vec();
    let p = parse_with(&obu, Some(&mut ps)).unwrap();
    assert_eq!(p.rec.fp.sb128, 1);
    assert_eq!(p.rec.blocks.len(), hy.record().blocks.len());
    let recon0: Vec<Vec<u8>> = (0..3).map(|k| hy.recon(k).unwrap().to_vec()).collect();
    let rw0 = hy.output().recon_w;
    // ---- the inter frame ----
    fn planes(p: &Pic) -> [Plane<'_>; 3] {
        let (w, h, cw, ch) = (p.w, p.h, p.w.div_ceil(2), p.h.div_ceil(2));
        [
            Plane {
                data: &p.y,
                stride: w,
                width: w,
                height: h,
            },
            Plane {
                data: &p.u,
                stride: cw,
                width: cw,
                height: ch,
            },
            Plane {
                data: &p.v,
                stride: cw,
                width: cw,
                height: ch,
            },
        ]
    }
    let (cur, prev) = (planes(&pic1), planes(&pic0));
    let copies = m.classify(&cur, &prev, 3, 4);
    assert!(copies >= 8, "{copies} copies");
    let sbs = m.sbs.clone();
    assert!(sbs.iter().any(|s| s.copy && s.shift == Shift { dx: 0, dy: 16 }));
    let blocks1 = partition(&pic1, &tiles64, &mut rng, Style::Random, false);
    m.apply_ex(&sbs, sb_cols, &blocks1, None, None, mr, mc, Some(&tiles128))
        .unwrap();
    assert!(
        m.blocks
            .iter()
            .zip(&m.inter)
            .any(|(b, i)| b.bsize as i32 == BLOCK_128X128 && i.is_inter != 0),
        "no 128x128 copy"
    );
    (
        fp.frame_type,
        fp.refresh_frame_flags,
        fp.mv_precision,
        fp.allow_screen_content_tools,
    ) = (FRAME_INTER, 1, 0, 1);
    let (blocks, inter) = (m.blocks.clone(), m.inter.clone());
    let reference = RefPicture {
        plane: [&recon0[0], &recon0[1], &recon0[2]],
        stride: [rw0[0] as usize, rw0[1] as usize, rw0[2] as usize],
        cdfs: None,
    };
    let video = Video {
        fp,
        inter: &inter,
        reference: Some(reference),
        golden: None,
        padded: None,
    };
    hy.closed_loop_ex(
        &pic1.y,
        &pic1.u,
        &pic1.v,
        w as u32,
        h as u32,
        &blocks,
        None,
        0,
        90,
        1,
        0,
        Some(&video),
        None,
    )
    .unwrap();
    let rw1 = hy.output().recon_w;
    for (s, sm) in sbs.iter().enumerate() {
        if !sm.copy {
            continue;
        }
        let (sx, sy) = (s % sb_cols, s / sb_cols);
        for p in 0..3 {
            let sub = (p != 0) as usize;
            let (pw, ph) = if p == 0 { (w, h) } else { (cw, ch) };
            let rec1 = hy.recon(p).unwrap();
            for y in ((sy * 64) >> sub)..(((sy + 1) * 64) >> sub).min(ph) {
                for x in ((sx * 64) >> sub)..(((sx + 1) * 64) >> sub).min(pw) {
                    let (qx, qy) = (x as i32 + (sm.shift.dx >> sub), y as i32 + (sm.shift.dy >> sub));
                    assert_eq!(
                        rec1[y * rw1[p] as usize + x],
                        recon0[p][qy as usize * rw0[p] as usize + qx as usize],
                        "64x64 {s} plane {p} ({x}, {y})"
                    );
                }
            }
        }
    }
    let wfp = wfp_of(&hy);
    assert!(hy.write_ex(&wfp, None, sb_cols, ENC_AVIF).is_err());
    let obu = hy.write_ex(&wfp, None, sb_cols, ENC_NO_SEQ_HEADER).unwrap().to_vec();
    assert_eq!(&obu[..3], &[0x12, 0x00, 0x32], "TD, frame");
    let p = parse_with(&obu, Some(&mut ps)).unwrap();
    assert_eq!((p.rec.fp.sb128, p.rec.fp.frame_type), (1, FRAME_INTER));
    assert_eq!(p.rec.blocks.len(), hy.record().blocks.len());
    assert_eq!(p.rec.inter, inter);

    // ---- both again, the reconstruction into the caller's planes ----
    let recon1: Vec<Vec<u8>> = (0..3).map(|k| hy.recon(k).unwrap().to_vec()).collect();
    let mut store: Vec<Vec<u8>> = recon0.iter().map(|p| vec![7; p.len()]).collect();
    let mut hz = Hybrid::new();
    for (k, (pic, blocks, video, want)) in [
        (&pic0, &key_blocks, &key_video, &recon0),
        (&pic1, &blocks, &video, &recon1),
    ]
    .into_iter()
    .enumerate()
    {
        let [a, b, c] = &mut store[..] else { unreachable!() };
        hz.closed_loop_ex(
            &pic.y,
            &pic.u,
            &pic.v,
            w as u32,
            h as u32,
            blocks,
            None,
            0,
            90,
            1,
            0,
            Some(video),
            Some([&mut a[..], &mut b[..], &mut c[..]]),
        )
        .unwrap();
        assert_eq!(&store, want, "picture {k}");
        // a key frame keeps its own (the next picture's tiles come from it), an inter frame doesn't
        assert_eq!(hz.recon(0).is_some(), k == 0);
        assert_eq!(hz.output().recon_w, hy.output().recon_w);
    }
    assert_eq!(hz.write_ex(&wfp, None, sb_cols, ENC_NO_SEQ_HEADER).unwrap(), &obu[..]);
    // too small a plane
    let mut small = vec![0u8; 16];
    let (mut b, mut c) = (store[1].clone(), store[2].clone());
    assert!(
        hz.closed_loop_ex(
            &pic1.y,
            &pic1.u,
            &pic1.v,
            w as u32,
            h as u32,
            &blocks,
            None,
            0,
            90,
            1,
            0,
            Some(&video),
            Some([&mut small[..], &mut b[..], &mut c[..]]),
        )
        .is_err()
    );
}

// ---------------------------------------------------------------------------------------------
// snapshots
// ---------------------------------------------------------------------------------------------

mod snapshots {
    use super::*;
    use crate::testsupport::snapshot::Snapshot;

    impl Hybrid {
        /// The C++ hybrid's configuration ([`Hybrid::as_cpp`]), which the snapshots were recorded
        /// with.
        fn with_cpp_quant(mut self) -> Hybrid {
            self.as_cpp();
            self
        }
    }

    /// The families [`closed_loop_snap`] and [`write_snap`] feed.
    pub(super) const FAMS: [&str; 7] = ["rc", "record", "recon", "source", "reused", "changed_sb", "write"];

    /// One picture's closed loop, fed to `s`: the return code, and on success the record, the
    /// reconstruction, the padded source, the kept tiles and changed superblocks. Whether it coded.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn closed_loop_snap(
        rs: &mut Hybrid,
        p: &Pic,
        blocks: &[Block],
        luma_tx: Option<&[u8]>,
        flags: i32,
        q: i32,
        tc: i32,
        tr: i32,
        s: &mut Snapshot,
    ) -> bool {
        let rrc = rs.closed_loop(
            &p.y, &p.u, &p.v, p.w as u32, p.h as u32, blocks, luma_tx, flags, q, tc, tr,
        );
        s.put("rc", &rrc.as_ref().map_or_else(|e| e.code, |_| OK));
        if rrc.is_err() {
            return false;
        }
        // (fp, blocks, block_txb, txb, coeffs: what the C++'s record has)
        let r = rs.record();
        s.put("record", &(&r.fp, &r.blocks, &r.block_txb, &r.txb, &r.coeffs));
        for pl in 0..3 {
            let rr = rs.recon(pl).unwrap();
            assert!(!rr.is_empty());
            s.put("recon", rr);
            let (sp, stride) = rs.source(pl).unwrap();
            s.put("source", &(sp, stride));
        }
        s.put("reused", &rs.reused_tiles());
        let (mc, mr) = (mi_cols(p.w as i32), mi_rows(p.h as i32));
        let (sc, sr) = (((mc + 15) >> 4) as usize, ((mr + 15) >> 4) as usize);
        let mut ch = vec![0u8; sc * sr];
        let known = rs.changed_superblocks(&mut ch, sc, sr);
        s.put("changed_sb", &known.then_some(ch));
        true
    }

    /// Random post-filter parameters on the record's frame parameters, and per-SB cdef_idx.
    pub(super) fn random_pf(fp: &FrameParams, sbs: usize, r: &mut Rng) -> (FrameParams, Option<Vec<i8>>) {
        let mut f = *fp;
        if r.below(3) != 0 {
            let l = &mut f.loop_filter_level;
            l[0] = r.range(0, 63) as u8;
            l[1] = r.range(0, 63) as u8;
            if l[0] == 0 && l[1] == 0 {
                l[1] = 1;
            }
            l[2] = r.range(0, 63) as u8;
            l[3] = r.range(0, 63) as u8;
            f.loop_filter_sharpness = r.range(0, 7) as u8;
        }
        let mut sb = None;
        if r.below(3) != 0 {
            f.enable_cdef = 1;
            f.cdef_damping_minus_3 = r.range(0, 3) as u8;
            f.cdef_bits = r.range(0, 3) as u8;
            for i in 0..1usize << f.cdef_bits {
                f.cdef_y_pri[i] = r.range(0, 15) as u8;
                f.cdef_y_sec[i] = [0, 1, 2, 4][r.below(4) as usize];
                f.cdef_uv_pri[i] = r.range(0, 15) as u8;
                f.cdef_uv_sec[i] = [0, 1, 2, 4][r.below(4) as usize];
            }
            if r.below(5) != 0 {
                sb = Some((0..sbs).map(|_| r.range(-1, (1 << f.cdef_bits) - 1) as i8).collect());
            }
        }
        (f, sb)
    }

    /// The picture's write, fed to `s`.
    pub(super) fn write_snap(rs: &mut Hybrid, fp: &FrameParams, sb: Option<&[i8]>, sb_cols: usize, s: &mut Snapshot) {
        let r = rs.write(fp, sb, sb_cols).map(|o| o.to_vec());
        s.put("write", &r.map_err(|e| e.code));
    }

    /// A random size: small and odd ones, moderate ones, now and then a wide one.
    fn random_size(r: &mut Rng) -> (usize, usize) {
        match r.below(10) {
            0 => (
                [1, 2, 7, 8, 13, 63, 64, 65][r.below(8) as usize],
                r.range(1, 70) as usize,
            ),
            1..=6 => (r.range(16, 400) as usize, r.range(16, 300) as usize),
            7 | 8 => (r.range(400, 900) as usize, r.range(64, 400) as usize),
            _ => (r.range(1200, 2000) as usize, r.range(16, 140) as usize),
        }
    }

    /// A tiling for the size: random log2 values where legal, else the minimum.
    fn random_tiling(w: usize, h: usize, r: &mut Rng) -> (i32, i32) {
        for _ in 0..4 {
            let (c, rr) = (r.range(-1, 3), r.range(-1, 3));
            if tile_layout(w as u32, h as u32, c, rr).is_ok() {
                return (c, rr);
            }
        }
        (-1, -1)
    }

    fn picture(w: usize, h: usize, r: &mut Rng) -> Pic {
        let seed = r.next() as u64;
        match r.below(4) {
            0 => {
                // noise everywhere: large coefficients, range repairs at low qindex
                let mut p = screen_pic(w, h, seed, false);
                let mut rr = Rng(seed | 1);
                p.noise(&mut rr, 0, 0, w, h, 127);
                p
            }
            _ => screen_pic(w, h, seed, r.below(2) == 0),
        }
    }

    #[test]
    fn closed_loop_and_write_snapshot() {
        let mut s = Snapshot::new(&FAMS);
        let mut r = Rng(0x00C0_FFEE_1234);
        let mut rs = Hybrid::new().with_cpp_quant();
        let mut coded = 0;
        for case in 0..240 {
            let (w, h) = random_size(&mut r);
            let p = picture(w, h, &mut r);
            let (tc, tr) = random_tiling(w, h, &mut r);
            let tiles = tile_layout(w as u32, h as u32, tc, tr).unwrap();
            let given_chroma = r.below(2) == 0;
            let blocks = partition(&p, &tiles, &mut r, Style::Random, given_chroma);
            let lt = (r.below(2) == 0).then(|| luma_types(&blocks, &mut r, true));
            let q = match r.below(4) {
                0 => r.range(1, 20),
                1 => 80,
                _ => r.range(1, 255),
            };
            // a fresh pair now and then, else one stream of unrelated pictures
            if r.below(4) == 0 {
                rs = Hybrid::new().with_cpp_quant();
            }
            let flags = if given_chroma { GIVEN_CHROMA } else { 0 };
            let ok = closed_loop_snap(&mut rs, &p, &blocks, lt.as_deref(), flags, q, tc, tr, &mut s);
            assert!(ok, "case {case}: failed");
            coded += 1;
            let fp = rs.record().fp;
            let sb_cols = ((mi_cols(w as i32) + 15) >> 4) as usize;
            let sbs = sb_cols * ((mi_rows(h as i32) + 15) >> 4) as usize;
            for _ in 0..2 {
                let (f, sb) = random_pf(&fp, sbs, &mut r);
                write_snap(&mut rs, &f, sb.as_deref(), sb_cols, &mut s);
            }
        }
        assert_eq!(coded, 240);
        s.check_arch(
            &[
                ("rc", 0xc42a06f7e7a28e25),
                ("record", 0x3abbcac7f7d06929),
                ("recon", 0xb7b42c4a4d1fe235),
                ("source", 0x1d1fe00d21cae48f),
                ("reused", 0xc42a06f7e7a28e25),
                ("changed_sb", 0x4675f9918e1cd831),
                ("write", 0x9e245c33a6e64364),
            ],
            &[
                ("rc", 0xc42a06f7e7a28e25),
                ("record", 0x55b3adbe3eca70e3),
                ("recon", 0x4326a91b190a7347),
                ("source", 0x1d1fe00d21cae48f),
                ("reused", 0xc42a06f7e7a28e25),
                ("changed_sb", 0x4675f9918e1cd831),
                ("write", 0xa92309d2b076a012),
            ],
        );
    }

    #[test]
    fn sequences_with_reuse_snapshot() {
        let mut s = Snapshot::new(&FAMS);
        let mut r = Rng(0x0BAD_C0DE_5678);
        let mut kept = 0;
        for seq in 0..40 {
            let (w, h) = match seq % 4 {
                0 => (r.range(64, 300) as usize, r.range(64, 200) as usize),
                1 => (r.range(300, 1000) as usize, r.range(200, 500) as usize),
                2 => (1280, 720),
                _ => (r.range(1, 140) as usize, r.range(1, 140) as usize),
            };
            let (tc, tr) = random_tiling(w, h, &mut r);
            let tiles = tile_layout(w as u32, h as u32, tc, tr).unwrap();
            let mut p = screen_pic(w, h, r.next() as u64, r.below(3) == 0);
            let mut given_chroma = r.below(2) == 0;
            let mut blocks = partition(&p, &tiles, &mut r, Style::Random, given_chroma);
            let mut lt = (r.below(2) == 0).then(|| luma_types(&blocks, &mut r, false));
            let mut q = if r.below(2) == 0 { 80 } else { r.range(1, 255) };
            let mut rs = Hybrid::new().with_cpp_quant();
            let sb_cols = ((mi_cols(w as i32) + 15) >> 4) as usize;
            let sbs = sb_cols * ((mi_rows(h as i32) + 15) >> 4) as usize;
            let (mut f, mut sb) = random_pf(&rs.record().fp, sbs, &mut r);
            for pic in 0..6 {
                if pic > 0 {
                    match r.below(12) {
                        0 => {
                            // a new partition (and modes) somewhere: re-partition from scratch
                            blocks = partition(&p, &tiles, &mut r, Style::Random, given_chroma);
                            if lt.is_some() {
                                lt = Some(luma_types(&blocks, &mut r, false));
                            }
                        }
                        1 => {
                            // one block's mode changed
                            let k = r.below(blocks.len() as u32) as usize;
                            blocks[k].y_mode = r.range(0, 12) as u8;
                            blocks[k].angle_delta_y = 0;
                        }
                        2 => {
                            // (not from None to Some: the C++ then compares the new types with
                            // the empty ones it kept, reading through a null pointer)
                            if let Some(l) = &mut lt {
                                let k = r.below(l.len() as u32) as usize;
                                l[k] = DCT_DCT as u8;
                            }
                        }
                        3 => q = r.range(1, 255),
                        4 => {
                            let on = r.below(2) == 0;
                            rs.set_reuse(on);
                        }
                        5 => {
                            given_chroma = !given_chroma;
                            blocks = partition(&p, &tiles, &mut r, Style::Random, given_chroma);
                            lt = lt.map(|_| luma_types(&blocks, &mut r, false));
                        }
                        6 => {} // the same picture again
                        _ => {
                            let n = r.range(1, 3) as usize;
                            retype(&mut p, &mut r, n);
                        }
                    }
                }
                let flags = if given_chroma { GIVEN_CHROMA } else { 0 };
                let ok = closed_loop_snap(&mut rs, &p, &blocks, lt.as_deref(), flags, q, tc, tr, &mut s);
                assert!(ok);
                kept += rs.reused_tiles();
                if r.below(3) == 0 {
                    (f, sb) = random_pf(&rs.record().fp, sbs, &mut r);
                } else {
                    // the same filters: kept tiles keep their bytes
                    let fp = rs.record().fp;
                    let (fl, cd) = (f, f);
                    f = fp;
                    f.loop_filter_level = fl.loop_filter_level;
                    f.loop_filter_sharpness = fl.loop_filter_sharpness;
                    (f.enable_cdef, f.cdef_bits, f.cdef_damping_minus_3) =
                        (cd.enable_cdef, cd.cdef_bits, cd.cdef_damping_minus_3);
                    (f.cdef_y_pri, f.cdef_y_sec, f.cdef_uv_pri, f.cdef_uv_sec) =
                        (cd.cdef_y_pri, cd.cdef_y_sec, cd.cdef_uv_pri, cd.cdef_uv_sec);
                }
                write_snap(&mut rs, &f, sb.as_deref(), sb_cols, &mut s);
            }
        }
        assert!(kept > 100, "only {kept} tiles kept");
        s.check_arch(
            &[
                ("rc", 0xc42a06f7e7a28e25),
                ("record", 0xafc67a87b09a30bb),
                ("recon", 0x5df8d9fbd8a3a179),
                ("source", 0x95b85cb302ff99b1),
                ("reused", 0x21163b1d503a0e43),
                ("changed_sb", 0x3ccca7c1a94d857e),
                ("write", 0x56b9bedabd1a5f43),
            ],
            &[
                ("rc", 0xc42a06f7e7a28e25),
                ("record", 0x923302eee34a75ec),
                ("recon", 0x193cbb17b7aee04c),
                ("source", 0x95b85cb302ff99b1),
                ("reused", 0x21163b1d503a0e43),
                ("changed_sb", 0x3ccca7c1a94d857e),
                ("write", 0x3c0156cb356115a1),
            ],
        );
    }

    #[test]
    fn errors_snapshot() {
        let mut r = Rng(99);
        let p = screen_pic(200, 120, 5, false);
        let tiles = tile_layout(200, 120, -1, -1).unwrap();
        let blocks = partition(&p, &tiles, &mut r, Style::Random, false);
        let mut rs = Hybrid::new().with_cpp_quant();
        let mut s = Snapshot::new(&FAMS);
        // illegal tiling
        assert!(!closed_loop_snap(&mut rs, &p, &blocks, None, 0, 80, 6, 0, &mut s));
        // blocks out of tile order (two swapped), with and without chroma decisions
        let mut bad = blocks.clone();
        bad.swap(0, 1);
        assert!(!closed_loop_snap(&mut rs, &p, &bad, None, 0, 80, -1, -1, &mut s));
        assert!(!closed_loop_snap(
            &mut rs,
            &p,
            &bad,
            None,
            GIVEN_CHROMA,
            80,
            -1,
            -1,
            &mut s
        ));
        // a block missing
        assert!(!closed_loop_snap(
            &mut rs,
            &p,
            &blocks[1..],
            None,
            0,
            80,
            -1,
            -1,
            &mut s
        ));
        // qindex 0 (lossless)
        assert!(!closed_loop_snap(&mut rs, &p, &blocks, None, 0, 0, -1, -1, &mut s));
        // and fine after
        assert!(closed_loop_snap(&mut rs, &p, &blocks, None, 0, 80, -1, -1, &mut s));
        assert!(closed_loop_snap(&mut rs, &p, &blocks, None, 0, 80, -1, -1, &mut s));
        assert!(rs.reused_tiles() > 0);
        // no blocks
        assert_eq!(
            rs.closed_loop(&p.y, &p.u, &p.v, 200, 120, &[], None, 0, 80, -1, -1)
                .unwrap_err()
                .code,
            ERR_INVALID
        );
        s.check(&[
            ("rc", 0xc24de25670e0c7a1),
            ("record", 0xe7c4fdc9123ff551),
            ("recon", 0xcec3be14652339d1),
            ("source", 0xbf6b957b57b612c9),
            ("reused", 0x08cd4c29d1e47d34),
            ("changed_sb", 0x8a7091e5e39ec98f),
            ("write", 0xcbf29ce484222325),
        ]);
    }

    // ---- benchmarks ----
}

/// How many non-flat blocks of a fixed grid have exact intra block copies (a y4m's first frame):
/// `Y4M=... cargo test --release -- --ignored --nocapture intrabc_grid_matches`.
#[test]
#[ignore]
fn intrabc_grid_matches() {
    let path = std::env::var("Y4M").unwrap();
    let data = std::fs::read(path).unwrap();
    let hdr_end = data.iter().position(|&b| b == b'\n').unwrap();
    let hdr = String::from_utf8_lossy(&data[..hdr_end]).to_string();
    let get = |k: char| -> usize { hdr.split(' ').find(|t| t.starts_with(k)).unwrap()[1..].parse().unwrap() };
    let (w, h) = (get('W'), get('H'));
    let f0 = hdr_end + 1 + data[hdr_end + 1..].iter().position(|&b| b == b'\n').unwrap() + 1;
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    let y = data[f0..f0 + w * h].to_vec();
    let u = data[f0 + w * h..f0 + w * h + cw * ch].to_vec();
    let v = data[f0 + w * h + cw * ch..f0 + w * h + 2 * cw * ch].to_vec();
    // one tile column up to 4096 samples, else two (a tile is at most 4096 wide)
    let cl = (w > 4096) as i32;
    let tiles = tile_layout(w as u32, h as u32, cl, 0).unwrap();
    for size in [8usize, 16, 32, 64] {
        // a uniform grid of size x size blocks (64x64 SBs split down to it)
        let bs = match size {
            8 => BLOCK_8X8,
            16 => BLOCK_16X16,
            32 => BLOCK_32X32,
            _ => BLOCK_64X64,
        };
        let mut blocks = Vec::new();
        let (mc, mr) = (mi_cols(w as i32) as usize, mi_rows(h as i32) as usize);
        let sbs: Vec<(usize, usize)> = (0..tiles.rows as usize)
            .flat_map(|tr| (0..tiles.cols as usize).map(move |tc| (tr, tc)))
            .flat_map(|(tr, tc)| {
                let (r0, r1) = (tiles.mi_row_starts[tr] as usize, tiles.mi_row_starts[tr + 1] as usize);
                let (c0, c1) = (tiles.mi_col_starts[tc] as usize, tiles.mi_col_starts[tc + 1] as usize);
                (r0..r1)
                    .step_by(16)
                    .flat_map(move |r| (c0..c1).step_by(16).map(move |c| (r, c)))
            })
            .collect();
        for &(sr, sc) in &sbs {
            {
                fn rec(
                    blocks: &mut Vec<Block>,
                    r: usize,
                    c: usize,
                    n: usize,
                    size: usize,
                    bs: i32,
                    mr: usize,
                    mc: usize,
                ) {
                    if r >= mr || c >= mc {
                        return;
                    }
                    if n == size / 4 && r + n <= mr && c + n <= mc {
                        blocks.push(Block {
                            mi_row: r as u16,
                            mi_col: c as u16,
                            bsize: bs as u8,
                            ..Default::default()
                        });
                        return;
                    }
                    if n == 2 {
                        for (dr, dc) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                            if r + dr < mr && c + dc < mc {
                                blocks.push(Block {
                                    mi_row: (r + dr) as u16,
                                    mi_col: (c + dc) as u16,
                                    bsize: BLOCK_4X4 as u8,
                                    ..Default::default()
                                });
                            }
                        }
                        return;
                    }
                    let hlf = n / 2;
                    for (dr, dc) in [(0, 0), (0, hlf), (hlf, 0), (hlf, hlf)] {
                        rec(blocks, r + dr, c + dc, hlf, size, bs, mr, mc);
                    }
                }
                rec(&mut blocks, sr, sc, 16, size, bs, mr, mc);
            }
        }
        let mut hy = Hybrid::new();
        hy.set_intrabc(true);
        hy.closed_loop(&y, &u, &v, w as u32, h as u32, &blocks, None, 0, 80, cl, 0)
            .unwrap();
        let src = hy.src.view();
        let flat = blocks
            .iter()
            .filter(|b| b.bsize as i32 == bs)
            .filter(|b| {
                let (x, yy) = (b.mi_col as usize * 4, b.mi_row as usize * 4);
                let v0 = src.at(0, x, yy)[0];
                (0..size).all(|i| src.at(0, x, yy + i)[..size].iter().all(|&s| s == v0))
            })
            .count();
        let n = blocks.iter().filter(|b| b.bsize as i32 == bs).count();
        eprintln!(
            "{size}x{size}: {n} blocks, {flat} flat luma, {} copy ({:.1} % of the non-flat), {:.1} % of the picture",
            hy.ibc.copies,
            hy.ibc.copies as f64 * 100.0 / (n - flat).max(1) as f64,
            hy.ibc.area as f64 * 100.0 / (w * h) as f64
        );
    }
}
