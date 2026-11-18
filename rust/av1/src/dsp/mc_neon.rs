//! NEON passes of the motion compensation (mc.rs), 8 columns at a time (`w` a multiple of 8). The
//! scalar passes in mc.rs are the reference (`mc_passes_simd_match_scalar`).
use core::arch::aarch64::*;

/// The 8 source vectors of 8 columns starting at `p` (tap t: samples p[t .. t + 8]), widened,
/// from two 8-byte loads that stay inside p[0 .. 15].
///
/// # Safety
/// p[0 .. 15] must be readable.
#[inline(always)]
unsafe fn taps(p: *const u8) -> [int16x8_t; 8] {
    unsafe {
        let a = vld1_u8(p);
        let b = vld1_u8(p.add(7)); // p[7 .. 15]
        let b = vext_u8::<1>(b, b); // p[8 .. 15] in lanes 0..6 (lane 7 unused)
        let w = |v: uint8x8_t| vreinterpretq_s16_u16(vmovl_u8(v));
        [
            w(a),
            w(vext_u8::<1>(a, b)),
            w(vext_u8::<2>(a, b)),
            w(vext_u8::<3>(a, b)),
            w(vext_u8::<4>(a, b)),
            w(vext_u8::<5>(a, b)),
            w(vext_u8::<6>(a, b)),
            w(vext_u8::<7>(a, b)),
        ]
    }
}

/// sum over t of f[t] * v[t], in two i32x4 halves
#[inline(always)]
unsafe fn dot(v: &[int16x8_t; 8], f: &[i16; 8]) -> (int32x4_t, int32x4_t) {
    unsafe {
        let mut lo = vmull_n_s16(vget_low_s16(v[0]), f[0]);
        let mut hi = vmull_high_n_s16(v[0], f[0]);
        for t in 1..8 {
            lo = vmlal_n_s16(lo, vget_low_s16(v[t]), f[t]);
            hi = vmlal_high_n_s16(hi, v[t], f[t]);
        }
        (lo, hi)
    }
}

/// Clip1 of two i32x4 halves into 8 bytes at `d`.
#[inline(always)]
unsafe fn store_u8(d: *mut u8, lo: int32x4_t, hi: int32x4_t) {
    unsafe {
        let n = vcombine_u16(vqmovun_s32(lo), vqmovun_s32(hi));
        vst1_u8(d, vqmovn_u16(n));
    }
}

pub(super) fn h_only(src: &[u8], ss: usize, w: usize, h: usize, f: &[i16; 8], dst: &mut [u8], ds: usize) {
    assert!(h > 0 && src.len() >= (h - 1) * ss + w + 7 && dst.len() >= (h - 1) * ds + w);
    // SAFETY: NEON is baseline on aarch64; row r reads src[r * ss + c .. + 15] for c + 8 <= w
    // (inside the asserted w + 7 per row) and writes dst[r * ds + c .. + 8].
    unsafe {
        for r in 0..h {
            for c in (0..w).step_by(8) {
                let v = taps(src.as_ptr().add(r * ss + c));
                let (lo, hi) = dot(&v, f);
                let (lo, hi) = (
                    vrshrq_n_s32::<4>(vrshrq_n_s32::<3>(lo)),
                    vrshrq_n_s32::<4>(vrshrq_n_s32::<3>(hi)),
                );
                store_u8(dst.as_mut_ptr().add(r * ds + c), lo, hi);
            }
        }
    }
}

pub(super) fn v_only(src: &[u8], ss: usize, w: usize, h: usize, f: &[i16; 8], dst: &mut [u8], ds: usize) {
    assert!(h > 0 && src.len() >= (h + 6) * ss + w && dst.len() >= (h - 1) * ds + w);
    // SAFETY: as h_only: 8 bytes of rows r .. r + 7 at column c (c + 8 <= w), inside the assert.
    unsafe {
        for c in (0..w).step_by(8) {
            let p = src.as_ptr().add(c);
            let row = |k: usize| vreinterpretq_s16_u16(vmovl_u8(vld1_u8(p.add(k * ss))));
            let mut v = [row(0), row(1), row(2), row(3), row(4), row(5), row(6), row(0)];
            for r in 0..h {
                v[7] = row(r + 7);
                let (lo, hi) = dot(&v, f);
                store_u8(
                    dst.as_mut_ptr().add(r * ds + c),
                    vrshrq_n_s32::<7>(lo),
                    vrshrq_n_s32::<7>(hi),
                );
                v.copy_within(1.., 0);
            }
        }
    }
}

pub(super) fn h_pass(src: &[u8], ss: usize, w: usize, rows: usize, f: &[i16; 8], inter: &mut [i16]) {
    assert!(rows > 0 && src.len() >= (rows - 1) * ss + w + 7 && inter.len() >= rows * w);
    // SAFETY: as h_only; writes inter[r * w + c .. + 8].
    unsafe {
        for r in 0..rows {
            for c in (0..w).step_by(8) {
                let v = taps(src.as_ptr().add(r * ss + c));
                let (lo, hi) = dot(&v, f);
                let o = vcombine_s16(vmovn_s32(vrshrq_n_s32::<3>(lo)), vmovn_s32(vrshrq_n_s32::<3>(hi)));
                vst1q_s16(inter.as_mut_ptr().add(r * w + c), o);
            }
        }
    }
}

pub(super) fn v_pass(inter: &[i16], w: usize, h: usize, f: &[i16; 8], dst: &mut [u8], ds: usize) {
    assert!(h > 0 && inter.len() >= (h + 7) * w && dst.len() >= (h - 1) * ds + w);
    // SAFETY: reads inter[(r + t) * w + c .. + 8] for r + t < h + 7, c + 8 <= w.
    unsafe {
        for c in (0..w).step_by(8) {
            let p = inter.as_ptr().add(c);
            let row = |k: usize| vld1q_s16(p.add(k * w));
            let mut v = [row(0), row(1), row(2), row(3), row(4), row(5), row(6), row(0)];
            for r in 0..h {
                v[7] = row(r + 7);
                let (lo, hi) = dot(&v, f);
                store_u8(
                    dst.as_mut_ptr().add(r * ds + c),
                    vrshrq_n_s32::<11>(lo),
                    vrshrq_n_s32::<11>(hi),
                );
                v.copy_within(1.., 0);
            }
        }
    }
}
