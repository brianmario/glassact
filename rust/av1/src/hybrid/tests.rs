//! The hybrid encoder's tests: the SIMD forward transform and quantizer against the scalar code;
//! with the `oracle` feature, the closed loop, the write and the tile reuse against the C++
//! (av1enc_hybrid_*) on random pictures, partitions and sequences; and `#[ignore]` benchmarks.
use super::fwd::{FWD_F_TMP, forward_f, forward_f_scalar, fwd};
use super::quant::quantize_f;
use super::*;
use crate::blockinfo::{bh4, bw4, cfl_allowed, has_chroma, mi_cols, mi_rows};
use crate::dsp::{
    Rng, dq_denom, get_tx_set_intra, is_directional, qm, qm_step, tx_coeffs, tx_h, tx_type_in_set_intra, tx_w,
};
use crate::tables::*;

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
        if self.chroma && has_chroma(bs, r, c, false) {
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

#[cfg_attr(not(feature = "oracle"), allow(dead_code))]
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
    // without the oracle: a sequence with reuse codes what fresh closed loops code
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

// ---------------------------------------------------------------------------------------------
// against the C++
// ---------------------------------------------------------------------------------------------

#[cfg(feature = "oracle")]
mod oracle {
    use super::*;
    use core::ffi::{c_char, c_int, c_void};

    unsafe extern "C" {
        fn av1enc_hybrid_create() -> *mut c_void;
        fn av1enc_hybrid_destroy(h: *mut c_void);
        fn av1enc_hybrid_closed_loop(
            h: *mut c_void,
            y: *const u8,
            u: *const u8,
            v: *const u8,
            w: u32,
            hgt: u32,
            blocks: *const Block,
            n: u32,
            luma_tx: *const u8,
            flags: c_int,
            qindex: c_int,
            tile_cols_log2: c_int,
            tile_rows_log2: c_int,
            err: *mut c_char,
            errlen: usize,
        ) -> c_int;
        fn av1enc_hybrid_record(h: *mut c_void) -> *mut DecisionRecord;
        fn av1enc_hybrid_write(
            h: *mut c_void,
            fp: *const FrameParams,
            sb_cdef: *const i8,
            sb_cols: c_int,
            obu: *mut *mut u8,
            size: *mut usize,
            err: *mut c_char,
            errlen: usize,
        ) -> c_int;
        fn av1enc_hybrid_set_reuse(h: *mut c_void, on: c_int);
        fn av1enc_hybrid_reused_tiles(h: *const c_void) -> u32;
        fn av1enc_hybrid_changed_superblocks(h: *const c_void, out: *mut u8, sb_cols: c_int, sb_rows: c_int) -> c_int;
        fn av1enc_hybrid_recon(h: *const c_void, plane: c_int) -> *const u8;
        fn av1enc_hybrid_source(h: *const c_void, plane: c_int, stride: *mut c_int) -> *const u8;
        fn av1enc_hybrid_seconds(h: *const c_void, which: c_int) -> f64;
        fn free(p: *mut c_void);
    }

    /// The C++ hybrid (av1enc_hybrid_*).
    pub(super) struct CHybrid(*mut c_void);

    impl Drop for CHybrid {
        fn drop(&mut self) {
            // SAFETY: created by av1enc_hybrid_create, destroyed once.
            unsafe { av1enc_hybrid_destroy(self.0) }
        }
    }

    /// SAFETY: `p` points to `n` initialized `T`s (or n is 0).
    unsafe fn sl<'a, T>(p: *const T, n: usize) -> &'a [T] {
        if n == 0 {
            return &[];
        }
        // SAFETY: as the caller promises.
        unsafe { core::slice::from_raw_parts(p, n) }
    }

    impl CHybrid {
        pub fn new() -> CHybrid {
            // SAFETY: plain constructor.
            CHybrid(unsafe { av1enc_hybrid_create() })
        }

        pub fn closed_loop(
            &mut self,
            p: &Pic,
            blocks: &[Block],
            luma_tx: Option<&[u8]>,
            flags: i32,
            q: i32,
            tc: i32,
            tr: i32,
        ) -> i32 {
            let mut err = [0 as c_char; 256];
            // SAFETY: the planes and arrays are as long as the C reads (w x h, half chroma, n blocks).
            unsafe {
                av1enc_hybrid_closed_loop(
                    self.0,
                    p.y.as_ptr(),
                    p.u.as_ptr(),
                    p.v.as_ptr(),
                    p.w as u32,
                    p.h as u32,
                    blocks.as_ptr(),
                    blocks.len() as u32,
                    luma_tx.map_or(core::ptr::null(), |l| l.as_ptr()),
                    flags,
                    q,
                    tc,
                    tr,
                    err.as_mut_ptr(),
                    err.len(),
                )
            }
        }

        /// The C++ record, copied.
        pub fn record(&mut self) -> Record {
            // SAFETY: the handle's record and its arrays (counts from av1g_layout).
            unsafe {
                let r = &*av1enc_hybrid_record(self.0);
                Record {
                    fp: r.fp,
                    blocks: sl(r.blocks, r.n_blocks as usize).to_vec(),
                    block_txb: sl(r.block_txb, r.n_blocks as usize + 1).to_vec(),
                    txb: sl(r.txb, r.n_txb as usize).to_vec(),
                    coeffs: sl(r.coeffs, r.n_coeffs as usize).to_vec(),
                    inter: Vec::new(),
                }
            }
        }

        pub fn write(&mut self, fp: &FrameParams, sb_cdef: Option<&[i8]>, sb_cols: usize) -> Result<Vec<u8>, i32> {
            let (mut obu, mut size) = (core::ptr::null_mut(), 0usize);
            let mut err = [0 as c_char; 256];
            // SAFETY: sb_cdef covers the picture's SBs; the OBUs are malloc'd for us.
            unsafe {
                let rc = av1enc_hybrid_write(
                    self.0,
                    fp,
                    sb_cdef.map_or(core::ptr::null(), |s| s.as_ptr()),
                    sb_cols as c_int,
                    &mut obu,
                    &mut size,
                    err.as_mut_ptr(),
                    err.len(),
                );
                if rc != OK {
                    return Err(rc);
                }
                let v = sl(obu, size).to_vec();
                free(obu as *mut c_void);
                Ok(v)
            }
        }

        pub fn set_reuse(&mut self, on: bool) {
            // SAFETY: a live handle.
            unsafe { av1enc_hybrid_set_reuse(self.0, on as c_int) }
        }
        pub fn reused_tiles(&self) -> u32 {
            // SAFETY: a live handle.
            unsafe { av1enc_hybrid_reused_tiles(self.0) }
        }
        pub fn changed_superblocks(&self, sb_cols: usize, sb_rows: usize) -> Option<Vec<u8>> {
            let mut v = vec![0u8; sb_cols * sb_rows];
            // SAFETY: v has sb_cols * sb_rows bytes.
            let ok = unsafe {
                av1enc_hybrid_changed_superblocks(self.0, v.as_mut_ptr(), sb_cols as c_int, sb_rows as c_int)
            };
            (ok != 0).then_some(v)
        }
        /// Plane p's reconstruction, n samples.
        pub fn recon(&self, p: usize, n: usize) -> Vec<u8> {
            // SAFETY: the reconstruction has MiCols * 4 x MiRows * 4 samples (>> 1 chroma) = n.
            unsafe { sl(av1enc_hybrid_recon(self.0, p as c_int), n).to_vec() }
        }
        /// Plane p's padded source (stride, rows).
        pub fn source(&self, p: usize, rows: usize) -> (Vec<u8>, usize) {
            let mut stride: c_int = 0;
            // SAFETY: the padded plane has stride x rows samples.
            unsafe {
                let s = av1enc_hybrid_source(self.0, p as c_int, &mut stride);
                (sl(s, stride as usize * rows).to_vec(), stride as usize)
            }
        }
        pub fn seconds(&self, which: i32) -> f64 {
            // SAFETY: a live handle.
            unsafe { av1enc_hybrid_seconds(self.0, which) }
        }
    }

    /// One picture through both: the return codes, and on success the record, the reconstruction,
    /// the padded source, the kept tiles and changed superblocks. Err describes the first
    /// difference.
    pub(super) fn closed_loop_both(
        rs: &mut Hybrid,
        cs: &mut CHybrid,
        p: &Pic,
        blocks: &[Block],
        luma_tx: Option<&[u8]>,
        flags: i32,
        q: i32,
        tc: i32,
        tr: i32,
    ) -> Result<bool, String> {
        let crc = cs.closed_loop(p, blocks, luma_tx, flags, q, tc, tr);
        let rrc = rs.closed_loop(
            &p.y, &p.u, &p.v, p.w as u32, p.h as u32, blocks, luma_tx, flags, q, tc, tr,
        );
        match (&rrc, crc) {
            (Ok(()), OK) => {}
            (Err(e), c) if e.code == c => return Ok(false),
            _ => return Err(format!("return codes: rust {rrc:?}, c++ {crc}")),
        }
        let (r, c) = (rs.record(), cs.record());
        if r.fp != c.fp {
            return Err(format!("fp\n rust {:?}\n c++  {:?}", r.fp, c.fp));
        }
        if r.blocks.len() != c.blocks.len() || r.txb.len() != c.txb.len() || r.coeffs.len() != c.coeffs.len() {
            return Err("record counts".into());
        }
        if let Some(i) = (0..r.blocks.len()).find(|&i| r.blocks[i] != c.blocks[i]) {
            return Err(format!("block {i}: rust {:?}, c++ {:?}", r.blocks[i], c.blocks[i]));
        }
        if r.block_txb != c.block_txb {
            return Err("block_txb".into());
        }
        if let Some(i) = (0..r.txb.len()).find(|&i| r.txb[i] != c.txb[i]) {
            return Err(format!("txb {i}: rust {:?}, c++ {:?}", r.txb[i], c.txb[i]));
        }
        if let Some(i) = (0..r.coeffs.len()).find(|&i| r.coeffs[i] != c.coeffs[i]) {
            let t = r.txb.iter().rposition(|t| t.coeff_off as usize <= i).unwrap();
            return Err(format!(
                "coeff {i} (txb {t} {:?}): rust {}, c++ {}",
                r.txb[t], r.coeffs[i], c.coeffs[i]
            ));
        }
        for pl in 0..3 {
            let rr = rs.recon(pl).unwrap();
            if rr.is_empty() || rr != cs.recon(pl, rr.len()) {
                return Err(format!("recon plane {pl}"));
            }
            let (s, stride) = rs.source(pl).unwrap();
            let (cs_, cstride) = cs.source(pl, s.len() / stride);
            if stride != cstride || s != cs_ {
                return Err(format!("source plane {pl}"));
            }
        }
        if rs.reused_tiles() != cs.reused_tiles() {
            return Err(format!(
                "reused tiles: rust {}, c++ {}",
                rs.reused_tiles(),
                cs.reused_tiles()
            ));
        }
        let (mc, mr) = (mi_cols(p.w as i32), mi_rows(p.h as i32));
        let (sc, sr) = (((mc + 15) >> 4) as usize, ((mr + 15) >> 4) as usize);
        let mut ch = vec![0u8; sc * sr];
        let known = rs.changed_superblocks(&mut ch, sc, sr);
        if cs.changed_superblocks(sc, sr) != known.then_some(ch) {
            return Err("changed superblocks".into());
        }
        if !(rs.seconds(0) >= 0.0 && rs.seconds(1) > 0.0 && cs.seconds(1) > 0.0) {
            return Err("seconds".into());
        }
        Ok(true)
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

    pub(super) fn write_both(
        rs: &mut Hybrid,
        cs: &mut CHybrid,
        fp: &FrameParams,
        sb: Option<&[i8]>,
        sb_cols: usize,
    ) -> Result<(), String> {
        let c = cs.write(fp, sb, sb_cols);
        let r = rs.write(fp, sb, sb_cols).map(|o| o.to_vec());
        match (&r, &c) {
            (Ok(a), Ok(b)) if a == b => Ok(()),
            (Err(e), Err(code)) if e.code == *code => Ok(()),
            (Ok(a), Ok(b)) => Err(format!("OBUs differ ({} vs {} bytes)", a.len(), b.len())),
            _ => Err(format!(
                "write: rust {:?}, c++ {:?}",
                r.as_ref().map(|v| v.len()),
                c.as_ref().map(|v| v.len())
            )),
        }
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
    fn closed_loop_and_write_match_cpp() {
        let mut r = Rng(0x00C0_FFEE_1234);
        let (mut rs, mut cs) = (Hybrid::new(), CHybrid::new());
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
                (rs, cs) = (Hybrid::new(), CHybrid::new());
            }
            let flags = if given_chroma { GIVEN_CHROMA } else { 0 };
            let ok =
                closed_loop_both(&mut rs, &mut cs, &p, &blocks, lt.as_deref(), flags, q, tc, tr).unwrap_or_else(|e| {
                    panic!(
                        "case {case} ({w}x{h}, tiles {tc}/{tr}, q {q}, flags {flags}, luma_tx {}): {e}",
                        lt.is_some()
                    )
                });
            assert!(ok, "case {case}: both failed");
            coded += 1;
            let fp = rs.record().fp;
            let sb_cols = ((mi_cols(w as i32) + 15) >> 4) as usize;
            let sbs = sb_cols * ((mi_rows(h as i32) + 15) >> 4) as usize;
            for _ in 0..2 {
                let (f, sb) = random_pf(&fp, sbs, &mut r);
                write_both(&mut rs, &mut cs, &f, sb.as_deref(), sb_cols).unwrap_or_else(|e| panic!("case {case}: {e}"));
            }
        }
        assert_eq!(coded, 240);
    }

    #[test]
    fn sequences_with_reuse_match_cpp() {
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
            let (mut rs, mut cs) = (Hybrid::new(), CHybrid::new());
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
                            cs.set_reuse(on);
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
                let ok = closed_loop_both(&mut rs, &mut cs, &p, &blocks, lt.as_deref(), flags, q, tc, tr)
                    .unwrap_or_else(|e| panic!("sequence {seq} picture {pic} ({w}x{h}, tiles {tc}/{tr}, q {q}): {e}"));
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
                write_both(&mut rs, &mut cs, &f, sb.as_deref(), sb_cols)
                    .unwrap_or_else(|e| panic!("sequence {seq} picture {pic}: {e}"));
            }
        }
        assert!(kept > 100, "only {kept} tiles kept");
    }

    #[test]
    fn errors_match_cpp() {
        let mut r = Rng(99);
        let p = screen_pic(200, 120, 5, false);
        let tiles = tile_layout(200, 120, -1, -1).unwrap();
        let blocks = partition(&p, &tiles, &mut r, Style::Random, false);
        let (mut rs, mut cs) = (Hybrid::new(), CHybrid::new());
        // illegal tiling
        assert_eq!(
            closed_loop_both(&mut rs, &mut cs, &p, &blocks, None, 0, 80, 6, 0),
            Ok(false)
        );
        // blocks out of tile order (two swapped), with and without chroma decisions
        let mut bad = blocks.clone();
        bad.swap(0, 1);
        assert_eq!(
            closed_loop_both(&mut rs, &mut cs, &p, &bad, None, 0, 80, -1, -1),
            Ok(false)
        );
        assert_eq!(
            closed_loop_both(&mut rs, &mut cs, &p, &bad, None, GIVEN_CHROMA, 80, -1, -1),
            Ok(false)
        );
        // a block missing
        assert_eq!(
            closed_loop_both(&mut rs, &mut cs, &p, &blocks[1..], None, 0, 80, -1, -1),
            Ok(false)
        );
        // qindex 0 (lossless)
        assert_eq!(
            closed_loop_both(&mut rs, &mut cs, &p, &blocks, None, 0, 0, -1, -1),
            Ok(false)
        );
        // and fine after
        assert_eq!(
            closed_loop_both(&mut rs, &mut cs, &p, &blocks, None, 0, 80, -1, -1),
            Ok(true)
        );
        assert_eq!(
            closed_loop_both(&mut rs, &mut cs, &p, &blocks, None, 0, 80, -1, -1),
            Ok(true)
        );
        assert!(rs.reused_tiles() > 0);
        // no blocks
        assert_eq!(
            rs.closed_loop(&p.y, &p.u, &p.v, 200, 120, &[], None, 0, 80, -1, -1)
                .unwrap_err()
                .code,
            ERR_INVALID
        );
    }

    // ---- benchmarks ----

    /// The median of f(0..n).
    fn median(n: usize, f: impl Fn(usize) -> f64) -> f64 {
        let mut v: Vec<f64> = (0..n).map(f).collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v[n / 2]
    }

    fn bench(w: usize, h: usize, tl: i32, gpu_decides: bool) {
        let mut r = Rng(4242);
        let a = screen_pic(w, h, 11, false);
        let mut b = a.clone();
        let (mc, mr) = (mi_cols(w as i32), mi_rows(h as i32));
        let sbs = (((mc + 15) >> 4) * ((mr + 15) >> 4)) as usize;
        retype(&mut b, &mut r, sbs / 20); // ~5 % of the superblocks
        let tiles = tile_layout(w as u32, h as u32, tl, tl).unwrap();
        let blocks = partition(&a, &tiles, &mut r, Style::Variance, gpu_decides);
        let lt = gpu_decides.then(|| {
            blocks
                .iter()
                .map(|k| {
                    let v = [DCT_DCT, IDTX, ADST_ADST][r.below(3) as usize];
                    (if Max_Tx_Size_Rect[k.bsize as usize] as i32 >= TX_32X32 {
                        DCT_DCT
                    } else {
                        v
                    }) as u8
                })
                .collect::<Vec<u8>>()
        });
        let flags = if gpu_decides { GIVEN_CHROMA } else { 0 };
        let lt = lt.as_deref();
        let (mut rs, mut cs) = (Hybrid::new(), CHybrid::new());
        // warm up, and check
        for p in [&a, &b] {
            assert_eq!(
                closed_loop_both(&mut rs, &mut cs, p, &blocks, lt, flags, 80, tl, tl),
                Ok(true)
            );
        }
        let t = |f: &mut dyn FnMut()| {
            let t0 = Instant::now();
            f();
            t0.elapsed().as_secs_f64()
        };
        let n = if w * h > 4_000_000 { 15 } else { 41 };
        let (wu, hu) = (w as u32, h as u32);
        // the first picture of a stream, and a second one with ~5 % changed; Rust and C++
        // interleaved, so that both see the same machine
        let mut v = vec![[0.0f64; 4]; n];
        for x in &mut v {
            rs.set_reuse(false);
            rs.set_reuse(true);
            x[0] = t(&mut || {
                rs.closed_loop(&a.y, &a.u, &a.v, wu, hu, &blocks, lt, flags, 80, tl, tl)
                    .unwrap()
            });
            x[1] = t(&mut || {
                rs.closed_loop(&b.y, &b.u, &b.v, wu, hu, &blocks, lt, flags, 80, tl, tl)
                    .unwrap()
            });
            cs.set_reuse(false);
            cs.set_reuse(true);
            x[2] = t(&mut || assert_eq!(cs.closed_loop(&a, &blocks, lt, flags, 80, tl, tl), OK));
            x[3] = t(&mut || assert_eq!(cs.closed_loop(&b, &blocks, lt, flags, 80, tl, tl), OK));
        }
        let med = |k: usize| median(n, |i| v[i][k]);
        let (rust_first, rust_second, cpp_first, cpp_second) = (med(0), med(1), med(2), med(3));
        let res = [[rust_first, rust_second], [cpp_first, cpp_second]];
        for p in [&a, &b] {
            assert_eq!(
                closed_loop_both(&mut rs, &mut cs, p, &blocks, lt, flags, 80, tl, tl),
                Ok(true)
            );
        }
        let kept = rs.reused_tiles();
        println!(
            "{w}x{h}, {tl}x{tl} tiles, {} blocks, {}: first picture rust {:.2} ms, c++ {:.2} ms; \
             ~5 % changed ({kept}/{} tiles kept) rust {:.2} ms, c++ {:.2} ms",
            blocks.len(),
            if gpu_decides {
                "luma tx + chroma given"
            } else {
                "CPU decides chroma, tx search"
            },
            res[0][0] * 1e3,
            res[1][0] * 1e3,
            tiles.rows * tiles.cols,
            res[0][1] * 1e3,
            res[1][1] * 1e3,
        );
        println!(
            "  last call split: rust chroma {:.2} + loop {:.2} ms; c++ chroma {:.2} + loop {:.2} ms",
            rs.seconds(0) * 1e3,
            rs.seconds(1) * 1e3,
            cs.seconds(0) * 1e3,
            cs.seconds(1) * 1e3
        );
    }

    #[test]
    #[ignore]
    fn bench_closed_loop_720p() {
        bench(1280, 720, 3, true);
        bench(1280, 720, 3, false);
    }

    #[test]
    #[ignore]
    fn bench_closed_loop_5k() {
        bench(5120, 2880, 4, true);
        bench(5120, 2880, 4, false);
    }
}
