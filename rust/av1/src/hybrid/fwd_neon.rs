//! NEON forward_f: the same two products as the scalar code, each output accumulated over the same
//! k in the same order with fused multiply-adds (vfmaq_laneq_f32), 4 x 16 outputs at a time. The
//! first product is stored transposed, so the second loads its factors as one vector.
//!
//! The C++ skips zero factors; adding a zero product (±0) to an accumulator that is never -0
//! leaves it unchanged, so these loops don't. Identity kinds (diagonal matrices) are one multiply.
use super::fwd::FwdTx;
use crate::dsp::{K_IDT, col_kind, flip_lr, flip_ud, row_kind};
use crate::tables::{Transform_Row_Shift, Tx_Height_Log2, Tx_Width_Log2};
use core::arch::aarch64::*;

#[inline(always)]
fn ld(s: &[f32]) -> float32x4_t {
    let s = &s[..4];
    // SAFETY: 4 floats.
    unsafe { vld1q_f32(s.as_ptr()) }
}
#[inline(always)]
fn st(d: &mut [f32], v: float32x4_t) {
    let d = &mut d[..4];
    // SAFETY: 4 floats.
    unsafe { vst1q_f32(d.as_mut_ptr(), v) }
}

/// acc[l][v] += a[v] * b[l] (fused), l = 0..4.
#[inline(always)]
fn fma4<const NV: usize>(acc: &mut [[float32x4_t; NV]; 4], a: &[float32x4_t; NV], b: float32x4_t) {
    // SAFETY: NEON is part of the aarch64 baseline; register operations only.
    unsafe {
        for v in 0..NV {
            acc[0][v] = vfmaq_laneq_f32::<0>(acc[0][v], a[v], b);
            acc[1][v] = vfmaq_laneq_f32::<1>(acc[1][v], a[v], b);
            acc[2][v] = vfmaq_laneq_f32::<2>(acc[2][v], a[v], b);
            acc[3][v] = vfmaq_laneq_f32::<3>(acc[3][v], a[v], b);
        }
    }
}

/// tT[(j0 + l) * th + i0 + i] = sum_k Fc[i0 + i][k] * r[k][j0 + l] for l < 4, i < 4 NV.
#[inline(always)]
fn stage1<const NV: usize>(
    fct: &[f32],
    h: usize,
    r: &[f32],
    w: usize,
    j0: usize,
    i0: usize,
    tt: &mut [f32],
    th: usize,
) {
    // SAFETY: NEON is part of the aarch64 baseline.
    let mut acc = [[unsafe { vdupq_n_f32(0.0) }; NV]; 4];
    for k in 0..h {
        let b = ld(&r[k * w + j0..]);
        let f = &fct[k * h + i0..];
        let a: [float32x4_t; NV] = core::array::from_fn(|v| ld(&f[4 * v..]));
        fma4(&mut acc, &a, b);
    }
    for (l, acc) in acc.iter().enumerate() {
        for (v, &x) in acc.iter().enumerate() {
            st(&mut tt[(j0 + l) * th + i0 + 4 * v..], x);
        }
    }
}

/// out[(i0 + l) * tw + j0 + j] = scale * sum_k t[i0 + l][k'] * FrT[k][j0 + j] for l < 4, j < 4 NV,
/// k' = k, or w - 1 - k with FLR (the residual's columns flipped: the first product's are too).
#[inline(always)]
fn stage2<const NV: usize, const FLR: bool>(
    frt: &[f32],
    w: usize,
    tt: &[f32],
    th: usize,
    i0: usize,
    j0: usize,
    out: &mut [f32],
    tw: usize,
    scale: f32,
) {
    // SAFETY: NEON is part of the aarch64 baseline.
    let mut acc = [[unsafe { vdupq_n_f32(0.0) }; NV]; 4];
    for k in 0..w {
        let b = ld(&tt[if FLR { w - 1 - k } else { k } * th + i0..]);
        let f = &frt[k * w + j0..];
        let a: [float32x4_t; NV] = core::array::from_fn(|v| ld(&f[4 * v..]));
        fma4(&mut acc, &a, b);
    }
    for (l, acc) in acc.iter().enumerate() {
        for (v, &x) in acc.iter().enumerate() {
            // SAFETY: as above.
            st(&mut out[(i0 + l) * tw + j0 + 4 * v..], unsafe { vmulq_n_f32(x, scale) });
        }
    }
}

/// The first product, transposed (`tt`, w x th): of the residual with its rows flipped when the
/// type flips them (`fud`), by the column kind `ck`. A flip of its columns permutes this
/// product's rows, so [`stage2_from`] applies it; types sharing (ck, fud) share this.
pub(super) fn stage1_into(f: &FwdTx, res: &[f32], tx_sz: i32, ck: i32, fud: bool, tt: &mut [f32], rbuf: &mut [f32]) {
    let (lw, lh) = (
        Tx_Width_Log2[tx_sz as usize] as usize,
        Tx_Height_Log2[tx_sz as usize] as usize,
    );
    let (w, h) = (1usize << lw, 1usize << lh);
    let th = h.min(32);
    let r = flipped_ud(res, w, h, fud, rbuf);
    let tt = &mut tt[..w * th];
    if ck == K_IDT {
        let fc = &f.ff[ck as usize][lh];
        for i in 0..th {
            let c = fc[i * h + i];
            for j in 0..w {
                tt[j * th + i] = c.mul_add(r[i * w + j], 0.0);
            }
        }
    } else {
        let fct = &f.fft[ck as usize][lh][..h * h];
        for j0 in (0..w).step_by(4) {
            let mut i0 = 0;
            while i0 < th {
                match th - i0 {
                    4 => stage1::<1>(fct, h, r, w, j0, i0, tt, th),
                    8 => stage1::<2>(fct, h, r, w, j0, i0, tt, th),
                    _ => stage1::<4>(fct, h, r, w, j0, i0, tt, th),
                }
                i0 += 16;
            }
        }
    }
}

/// The second product from [`stage1_into`]'s `tt`, by the row kind `rk`, reading its rows in
/// reverse with `flr`: th x tw coefficients into `out`.
pub(super) fn stage2_from(f: &FwdTx, tt: &[f32], tx_sz: i32, rk: i32, flr: bool, out: &mut [f32]) {
    let (lw, lh) = (
        Tx_Width_Log2[tx_sz as usize] as usize,
        Tx_Height_Log2[tx_sz as usize] as usize,
    );
    let (w, h) = (1usize << lw, 1usize << lh);
    let (tw, th) = (w.min(32), h.min(32));
    let rect = if lw.abs_diff(lh) == 1 { 2896.0f32 / 4096.0 } else { 1.0 };
    let scale = (1 << (Transform_Row_Shift[tx_sz as usize] + 4)) as f32 / rect;
    let out = &mut out[..th * tw];
    if rk == K_IDT {
        let fr = &f.ff[rk as usize][lw];
        for j in 0..tw {
            let c = fr[j * w + j];
            let jj = if flr { w - 1 - j } else { j };
            for i in 0..th {
                out[i * tw + j] = tt[jj * th + i].mul_add(c, 0.0) * scale;
            }
        }
    } else {
        let frt = &f.fft[rk as usize][lw][..w * w];
        for i0 in (0..th).step_by(4) {
            let mut j0 = 0;
            while j0 < tw {
                match (tw - j0, flr) {
                    (4, false) => stage2::<1, false>(frt, w, tt, th, i0, j0, out, tw, scale),
                    (8, false) => stage2::<2, false>(frt, w, tt, th, i0, j0, out, tw, scale),
                    (_, false) => stage2::<4, false>(frt, w, tt, th, i0, j0, out, tw, scale),
                    (4, true) => stage2::<1, true>(frt, w, tt, th, i0, j0, out, tw, scale),
                    (8, true) => stage2::<2, true>(frt, w, tt, th, i0, j0, out, tw, scale),
                    (_, true) => stage2::<4, true>(frt, w, tt, th, i0, j0, out, tw, scale),
                }
                j0 += 16;
            }
        }
    }
}

/// `res` with its rows flipped (`fud`), into `r` (or `res` itself).
fn flipped_ud<'a>(res: &'a [f32], w: usize, h: usize, fud: bool, r: &'a mut [f32]) -> &'a [f32] {
    if !fud {
        return &res[..w * h];
    }
    for i in 0..h {
        r[i * w..][..w].copy_from_slice(&res[(h - 1 - i) * w..][..w]);
    }
    &r[..w * h]
}

pub(super) fn forward_f(f: &FwdTx, res: &[f32], tx_sz: i32, tx_type: i32, out: &mut [f32], tmp: &mut [f32]) {
    let (rbuf, tt) = tmp.split_at_mut(64 * 64);
    stage1_into(f, res, tx_sz, col_kind(tx_type), flip_ud(tx_type), tt, rbuf);
    stage2_from(f, tt, tx_sz, row_kind(tx_type), flip_lr(tx_type), out);
}
