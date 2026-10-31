//! Forward transforms derived from the exact inverse (hybrid.cpp / ref_engine.cpp FwdTx, forward,
//! forward_f): the inverse of each 1-D inverse transform's matrix, applied as two matrix products.
//!
//! [`forward`] is the reference engine's (double); [`forward_f`] the hybrid's (float, flips applied
//! first, axpy loops). Both accumulate every output in the C++'s order with its contractions
//! ([`fmac`] / [`fmacf`]), so they round as the C++ does. forward_f has a NEON path (aarch64) that
//! keeps that order per output; the scalar code is the reference.
use super::{fmac, fmacf};
use crate::dsp::{K_ADST, K_IDT, col_kind, flip_lr, flip_ud, inv_1d, row_kind};
use crate::tables::{Transform_Row_Shift, Tx_Height_Log2, Tx_Width_Log2};
use std::sync::OnceLock;

/// F[kind][log2n]: the inverse of the n x n matrix of the 1-D inverse transform (empty where the
/// kind has no such size); in float, and transposed (`fft[k * n + j] = f[j * n + k]`).
pub(crate) struct FwdTx {
    pub f: [[Vec<f64>; 7]; 3],
    pub ff: [[Vec<f32>; 7]; 3],
    pub fft: [[Vec<f32>; 7]; 3],
}

/// Gauss-Jordan inverse with partial pivoting, as the C++'s (row updates contracted).
fn invert(mut a: Vec<f64>, n: usize) -> Vec<f64> {
    let mut inv = vec![0.0; n * n];
    for i in 0..n {
        inv[i * n + i] = 1.0;
    }
    for c in 0..n {
        let mut p = c;
        for r in c + 1..n {
            if a[r * n + c].abs() > a[p * n + c].abs() {
                p = r;
            }
        }
        if p != c {
            for k in 0..n {
                a.swap(c * n + k, p * n + k);
                inv.swap(c * n + k, p * n + k);
            }
        }
        let d = a[c * n + c];
        for k in 0..n {
            a[c * n + k] /= d;
            inv[c * n + k] /= d;
        }
        for r in 0..n {
            if r != c {
                let f = a[r * n + c];
                if f != 0.0 {
                    for k in 0..n {
                        a[r * n + k] = fmac(-f, a[c * n + k], a[r * n + k]);
                        inv[r * n + k] = fmac(-f, inv[c * n + k], inv[r * n + k]);
                    }
                }
            }
        }
    }
    inv
}

impl FwdTx {
    fn new() -> FwdTx {
        let mut t = FwdTx {
            f: Default::default(),
            ff: Default::default(),
            fft: Default::default(),
        };
        for k in 0..3 {
            for ln in 2..=6usize {
                if (k == K_ADST && ln > 4) || (k == K_IDT && ln > 5) {
                    continue;
                }
                let n = 1usize << ln;
                let mut m = vec![0.0f64; n * n];
                const A: i32 = 1 << 14;
                for j in 0..n {
                    let mut c = [0i32; 64];
                    c[j] = A;
                    let mut err = 0;
                    inv_1d(&mut c, k, ln as i32, 31, &mut err);
                    for i in 0..n {
                        m[i * n + j] = c[i] as f64 / A as f64;
                    }
                }
                let f = invert(m, n);
                let (k, ln) = (k as usize, ln);
                t.ff[k][ln] = f.iter().map(|&v| v as f32).collect();
                t.fft[k][ln] = vec![0.0; n * n];
                for i in 0..n {
                    for j in 0..n {
                        t.fft[k][ln][j * n + i] = f[i * n + j] as f32;
                    }
                }
                t.f[k][ln] = f;
            }
        }
        t
    }
}

/// The matrices (built once).
pub(crate) fn fwd() -> &'static FwdTx {
    static F: OnceLock<FwdTx> = OnceLock::new();
    F.get_or_init(FwdTx::new)
}

/// The geometry of a tx size: (log2 w, log2 h, w, h, tw, th).
#[inline]
fn dims(tx_sz: i32) -> (usize, usize, usize, usize, usize, usize) {
    let (lw, lh) = (
        Tx_Width_Log2[tx_sz as usize] as usize,
        Tx_Height_Log2[tx_sz as usize] as usize,
    );
    let (w, h) = (1usize << lw, 1usize << lh);
    (lw, lh, w, h, w.min(32), h.min(32))
}

/// Scratch of [`forward`].
pub(crate) const FWD_TMP: usize = 64 * 64;

/// The reference engine's forward transform: residual (h x w, row-major) to Dequant-domain
/// coefficients (th x tw). `tmp` has [`FWD_TMP`] entries.
pub(crate) fn forward(f: &FwdTx, res: &[i32], tx_sz: i32, tx_type: i32, out: &mut [f64], tmp: &mut [f64]) {
    let (lw, lh, w, h, tw, th) = dims(tx_sz);
    let (rk, ck) = (row_kind(tx_type) as usize, col_kind(tx_type) as usize);
    let (fr, fc) = (&f.f[rk][lw][..w * w], &f.f[ck][lh][..h * h]);
    let (fud, flr) = (flip_ud(tx_type), flip_lr(tx_type));
    let rect = if lw.abs_diff(lh) == 1 { 2896.0 / 4096.0 } else { 1.0 };
    let scale = (1 << (Transform_Row_Shift[tx_sz as usize] + 4)) as f64 / rect;
    let res = &res[..w * h];
    // tmp = Fc * R (only th rows needed)
    for i in 0..th {
        for j in 0..w {
            let xx = if flr { w - 1 - j } else { j };
            let mut s = 0.0;
            for k in 0..h {
                let yy = if fud { h - 1 - k } else { k };
                s = fmac(fc[i * h + k], res[yy * w + xx] as f64, s);
            }
            tmp[i * w + j] = s;
        }
    }
    for i in 0..th {
        for j in 0..tw {
            let mut s = 0.0;
            for k in 0..w {
                s = fmac(tmp[i * w + k], fr[j * w + k], s);
            }
            out[i * tw + j] = s * scale;
        }
    }
}

/// Scratch of [`forward_f`]: two 64 x 64 float planes.
pub(crate) const FWD_F_TMP: usize = 2 * 64 * 64;

/// The hybrid's forward transform in float (hybrid.cpp forward_f): `res` is the residual (h x w,
/// row-major, unflipped), `out` gets th x tw coefficients. `tmp` has [`FWD_F_TMP`] entries.
pub(crate) fn forward_f(f: &FwdTx, res: &[f32], tx_sz: i32, tx_type: i32, out: &mut [f32], tmp: &mut [f32]) {
    #[cfg(target_arch = "aarch64")]
    {
        super::fwd_neon::forward_f(f, res, tx_sz, tx_type, out, tmp);
    }
    #[cfg(not(target_arch = "aarch64"))]
    forward_f_scalar(f, res, tx_sz, tx_type, out, tmp);
}

/// `res` with the tx type's flips applied, into `r` (or `res` itself when there are none).
pub(crate) fn flipped<'a>(res: &'a [f32], w: usize, h: usize, tx_type: i32, r: &'a mut [f32]) -> &'a [f32] {
    let (fud, flr) = (flip_ud(tx_type), flip_lr(tx_type));
    if !fud && !flr {
        return &res[..w * h];
    }
    for i in 0..h {
        let s = &res[if fud { h - 1 - i } else { i } * w..][..w];
        let d = &mut r[i * w..][..w];
        if flr {
            for (d, &s) in d.iter_mut().zip(s.iter().rev()) {
                *d = s;
            }
        } else {
            d.copy_from_slice(s);
        }
    }
    &r[..w * h]
}

/// The scalar forward_f, loop for loop the C++'s (zero factors skipped as it skips them).
#[cfg_attr(target_arch = "aarch64", allow(dead_code))]
pub(crate) fn forward_f_scalar(f: &FwdTx, res: &[f32], tx_sz: i32, tx_type: i32, out: &mut [f32], tmp: &mut [f32]) {
    let (lw, lh, w, h, tw, th) = dims(tx_sz);
    let (rk, ck) = (row_kind(tx_type) as usize, col_kind(tx_type) as usize);
    let (frt, fc) = (&f.fft[rk][lw][..w * w], &f.ff[ck][lh][..h * h]);
    let rect = if lw.abs_diff(lh) == 1 { 2896.0f32 / 4096.0 } else { 1.0 };
    let scale = (1 << (Transform_Row_Shift[tx_sz as usize] + 4)) as f32 / rect;
    let (rbuf, t) = tmp.split_at_mut(64 * 64);
    let r = flipped(res, w, h, tx_type, rbuf);
    for i in 0..th {
        // tmp = Fc * r (th rows)
        let ti = &mut t[i * w..][..w];
        ti.fill(0.0);
        for k in 0..h {
            let c = fc[i * h + k];
            if c == 0.0 {
                continue;
            }
            for (t, &x) in ti.iter_mut().zip(&r[k * w..][..w]) {
                *t = fmacf(c, x, *t);
            }
        }
    }
    for i in 0..th {
        // out = tmp * Fr^T (tw columns)
        let o = &mut out[i * tw..][..tw];
        o.fill(0.0);
        for k in 0..w {
            let c = t[i * w + k];
            if c == 0.0 {
                continue;
            }
            for (o, &x) in o.iter_mut().zip(&frt[k * w..][..tw]) {
                *o = fmacf(c, x, *o);
            }
        }
        for o in o.iter_mut() {
            *o *= scale;
        }
    }
}
