//! NEON passes of the motion compensation (mc.rs), 8 columns at a time (`w` a multiple of 8). The
//! scalar passes in mc.rs are the reference (`mc_passes_simd_match_scalar`).
use core::arch::aarch64::*;

// Every Subpel_Filters entry the passes use (positions 1..15) sums to 128 with sum |f| <= 240, so
// with the samples as q = p - 128 (in [-128, 127]) a filtered sum is sum f q + 16384, and
// |sum f q| <= 240 * 128 = 30720: every partial sum fits in i16. The rounding shifts the passes
// take of the sum (3, 3 then 4, 7) divide 16384 exactly, so they take them of sum f q and add the
// quotient back: the same integers as in i32 (`subpel_filters_fit_i16` checks the bound).
// (The i32 sums widened every tap twice and were most of the passes' instructions; the vertical
// passes' window lived on the stack, shifted a row at a time: BENCHMARKS, 2026-11-22.)

/// The 8 source vectors of 8 columns starting at `p` (tap t: samples p[t .. t + 8]) as q = p - 128,
/// widened, from two 8-byte loads that stay inside p[0 .. 15].
///
/// # Safety
/// p[0 .. 15] must be readable.
#[inline(always)]
unsafe fn taps_q(p: *const u8) -> [int16x8_t; 8] {
    unsafe {
        let m = vdup_n_u8(0x80);
        let a = veor_u8(vld1_u8(p), m);
        let b = veor_u8(vld1_u8(p.add(7)), m); // p[7 .. 15]
        let b = vext_u8::<1>(b, b); // p[8 .. 15] in lanes 0..6 (lane 7 unused)
        let w = |v: uint8x8_t| vmovl_s8(vreinterpret_s8_u8(v));
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

/// sum over t of f[t] * v[t] in i16 (q samples: see above)
#[inline(always)]
unsafe fn dot_q(v: [int16x8_t; 8], f: &[i16; 8]) -> int16x8_t {
    unsafe {
        let mut acc = vmulq_n_s16(v[0], f[0]);
        for t in 1..8 {
            acc = vmlaq_n_s16(acc, v[t], f[t]);
        }
        acc
    }
}

/// sum over t of f[t] * v[t], in two i32x4 halves
#[inline(always)]
unsafe fn dot(v: [int16x8_t; 8], f: &[i16; 8]) -> (int32x4_t, int32x4_t) {
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

/// Runs `out(r, window)` for r in 0..h over a column's sliding window of 8 rows (`row(k)`: row k):
/// eight output rows at a time with the window in fixed slots (registers, not a shifted array),
/// the rows left over from 8 rows loaded afresh.
#[inline(always)]
fn v_rows(h: usize, row: impl Fn(usize) -> int16x8_t, mut out: impl FnMut(usize, [int16x8_t; 8])) {
    let mut w = [row(0), row(1), row(2), row(3), row(4), row(5), row(6), row(0)];
    let mut r = 0;
    macro_rules! step {
        ($j:literal) => {{
            w[($j + 7) % 8] = row(r + $j + 7);
            out(
                r + $j,
                [w[$j % 8], w[($j + 1) % 8], w[($j + 2) % 8], w[($j + 3) % 8], w[($j + 4) % 8], w[($j + 5) % 8], w[($j + 6) % 8], w[($j + 7) % 8]],
            );
        }};
    }
    while r + 8 <= h {
        step!(0);
        step!(1);
        step!(2);
        step!(3);
        step!(4);
        step!(5);
        step!(6);
        step!(7);
        r += 8;
    }
    for r in r..h {
        out(r, core::array::from_fn(|t| row(r + t)));
    }
}

pub(super) fn h_only(src: &[u8], ss: usize, w: usize, h: usize, f: &[i16; 8], dst: &mut [u8], ds: usize) {
    assert!(h > 0 && src.len() >= (h - 1) * ss + w + 7 && dst.len() >= (h - 1) * ds + w);
    // SAFETY: NEON is baseline on aarch64; row r reads src[r * ss + c .. + 15] for c + 8 <= w
    // (inside the asserted w + 7 per row) and writes dst[r * ds + c .. + 8].
    unsafe {
        for r in 0..h {
            for c in (0..w).step_by(8) {
                // round(round(sum, 3), 4): of sum f q, plus 16384 / 128
                let t = vrshrq_n_s16::<4>(vrshrq_n_s16::<3>(dot_q(taps_q(src.as_ptr().add(r * ss + c)), f)));
                vst1_u8(dst.as_mut_ptr().add(r * ds + c), vqmovun_s16(vaddq_s16(t, vdupq_n_s16(128))));
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
            let m = vdup_n_u8(0x80);
            let row = |k: usize| vmovl_s8(vreinterpret_s8_u8(veor_u8(vld1_u8(p.add(k * ss)), m)));
            let d = dst.as_mut_ptr().add(c);
            v_rows(h, row, |r, v| {
                // round(sum, 7): of sum f q, plus 16384 / 128
                let t = vrshrq_n_s16::<7>(dot_q(v, f));
                vst1_u8(d.add(r * ds), vqmovun_s16(vaddq_s16(t, vdupq_n_s16(128))));
            });
        }
    }
}

pub(super) fn h_pass(src: &[u8], ss: usize, w: usize, rows: usize, f: &[i16; 8], inter: &mut [i16]) {
    assert!(rows > 0 && src.len() >= (rows - 1) * ss + w + 7 && inter.len() >= rows * w);
    // SAFETY: as h_only; writes inter[r * w + c .. + 8].
    unsafe {
        for r in 0..rows {
            for c in (0..w).step_by(8) {
                // round(sum, 3): of sum f q, plus 16384 / 8
                let o = vaddq_s16(vrshrq_n_s16::<3>(dot_q(taps_q(src.as_ptr().add(r * ss + c)), f)), vdupq_n_s16(2048));
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
            let d = dst.as_mut_ptr().add(c);
            v_rows(h, |k| vld1q_s16(p.add(k * w)), |r, v| {
                let (lo, hi) = dot(v, f);
                store_u8(d.add(r * ds), vrshrq_n_s32::<11>(lo), vrshrq_n_s32::<11>(hi));
            });
        }
    }
}
