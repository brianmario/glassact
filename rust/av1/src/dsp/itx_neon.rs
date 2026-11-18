//! NEON inverse transforms: the generic 1-D transforms of itx.rs on 4 lanes of i32 (4 rows, then
//! 4 columns, at once). Exact while the block is conformant (see itx.rs); `inv_txfm2d` returns false
//! when the scalar reference must redo the block.
use super::itx::*;
use crate::tables::*;
use core::arch::aarch64::*;

#[derive(Clone, Copy)]
pub(crate) struct V(int32x4_t);

/// Out-of-range accumulators: `a16` ORs (v + 2^15) of the 16-bit-checked values (any bit above 15
/// set = outside), `any` ORs (v + 2^(bits-1)) >> bits of the others (non-zero = outside).
pub(crate) struct E {
    a16: int32x4_t,
    any: int32x4_t,
}
impl E {
    #[inline(always)]
    fn new() -> E {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe {
            E {
                a16: vdupq_n_s32(0),
                any: vdupq_n_s32(0),
            }
        }
    }
    #[inline(always)]
    fn bad(&self) -> bool {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe {
            let v = vorrq_s32(vshrq_n_s32::<16>(self.a16), self.any);
            vmaxvq_u32(vreinterpretq_u32_s32(v)) != 0
        }
    }
}

impl Lane for V {
    type Wide = V;
    type Err = E;
    #[inline(always)]
    fn zero() -> V {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe { V(vdupq_n_s32(0)) }
    }
    #[inline(always)]
    fn bfly(a: V, b: V, c: i32, s: i32, r: i32, e: &mut E) -> (V, V) {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe {
            debug_assert!(r == 16);
            let x = vmlsq_n_s32(vmulq_n_s32(a.0, c), b.0, s);
            let y = vmlaq_n_s32(vmulq_n_s32(a.0, s), b.0, c);
            let (xa, yb) = (vrshrq_n_s32::<12>(x), vrshrq_n_s32::<12>(y));
            let k = vdupq_n_s32(1 << 15);
            e.a16 = vorrq_s32(e.a16, vorrq_s32(vaddq_s32(xa, k), vaddq_s32(yb, k)));
            (V(xa), V(yb))
        }
    }
    #[inline(always)]
    fn hadd(x: V, y: V, r: i32) -> (V, V) {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe {
            let (lo, hi) = (vdupq_n_s32(-(1 << (r - 1))), vdupq_n_s32((1 << (r - 1)) - 1));
            let s = vminq_s32(vmaxq_s32(vaddq_s32(x.0, y.0), lo), hi);
            let d = vminq_s32(vmaxq_s32(vsubq_s32(x.0, y.0), lo), hi);
            (V(s), V(d))
        }
    }
    #[inline(always)]
    fn neg(x: V) -> V {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe { V(vnegq_s32(x.0)) }
    }
    #[inline(always)]
    fn identity<const N: u32>(x: V) -> V {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe {
            V(match N {
                2 => vrshrq_n_s32::<12>(vmulq_n_s32(x.0, 5793)),
                3 => vshlq_n_s32::<1>(x.0),
                4 => vrshrq_n_s32::<12>(vmulq_n_s32(x.0, 11586)),
                _ => vshlq_n_s32::<2>(x.0),
            })
        }
    }
    #[inline(always)]
    fn wide(x: V) -> V {
        x
    }
    #[inline(always)]
    fn wmul(x: V, c: i32) -> V {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe { V(vmulq_n_s32(x.0, c)) }
    }
    #[inline(always)]
    fn wadd(x: V, y: V) -> V {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe { V(vaddq_s32(x.0, y.0)) }
    }
    #[inline(always)]
    fn wsub(x: V, y: V) -> V {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe { V(vsubq_s32(x.0, y.0)) }
    }
    #[inline(always)]
    fn wchk(x: V, bits: i32, _flag: u32, e: &mut E) {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe {
            let v = vshlq_s32(vaddq_s32(x.0, vdupq_n_s32(1 << (bits - 1))), vdupq_n_s32(-bits));
            e.any = vorrq_s32(e.any, v);
        }
    }
    #[inline(always)]
    fn wround12(x: V) -> V {
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        unsafe { V(vrshrq_n_s32::<12>(x.0)) }
    }
}

#[inline(always)]
fn transpose4(a: int32x4_t, b: int32x4_t, c: int32x4_t, d: int32x4_t) -> [int32x4_t; 4] {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe {
        let t0 = vtrn1q_s32(a, b);
        let t1 = vtrn2q_s32(a, b);
        let t2 = vtrn1q_s32(c, d);
        let t3 = vtrn2q_s32(c, d);
        let (t0, t1, t2, t3) = (
            vreinterpretq_s64_s32(t0),
            vreinterpretq_s64_s32(t1),
            vreinterpretq_s64_s32(t2),
            vreinterpretq_s64_s32(t3),
        );
        [
            vreinterpretq_s32_s64(vtrn1q_s64(t0, t2)),
            vreinterpretq_s32_s64(vtrn1q_s64(t1, t3)),
            vreinterpretq_s32_s64(vtrn2q_s64(t0, t2)),
            vreinterpretq_s32_s64(vtrn2q_s64(t1, t3)),
        ]
    }
}

#[inline(always)]
fn ld(s: &[i32]) -> int32x4_t {
    let s = &s[..4];
    // SAFETY: s has 4 elements.
    unsafe { vld1q_s32(s.as_ptr()) }
}
#[inline(always)]
fn st(d: &mut [i32], v: int32x4_t) {
    let d = &mut d[..4];
    // SAFETY: d has 4 elements.
    unsafe { vst1q_s32(d.as_mut_ptr(), v) }
}

/// The row pass, 4 rows at a time: `res` (h x w) from `dq` (th x tw), rounded by the row shift and
/// clamped to 16 bits.
#[inline(always)]
fn rows<const N: u32, const M: usize>(
    dq: &[i32],
    tw: usize,
    th: usize,
    h: usize,
    kind: i32,
    rect: bool,
    shift: i32,
    res: &mut [i32],
    e: &mut E,
) {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe {
        let w = 1usize << N;
        let mut t = [V::zero(); M];
        let sh = vdupq_n_s32(-shift);
        for i0 in (0..h).step_by(4) {
            let out = &mut res[i0 * w..(i0 + 4) * w];
            if i0 >= th {
                out.fill(0);
                continue;
            }
            let inp = &dq[i0 * tw..(i0 + 4) * tw];
            let mut nz = vdupq_n_s32(0);
            for k in (0..tw).step_by(4) {
                let r = [
                    ld(&inp[k..]),
                    ld(&inp[tw + k..]),
                    ld(&inp[2 * tw + k..]),
                    ld(&inp[3 * tw + k..]),
                ];
                nz = vorrq_s32(nz, vorrq_s32(vorrq_s32(r[0], r[1]), vorrq_s32(r[2], r[3])));
                let c = transpose4(r[0], r[1], r[2], r[3]);
                for m in 0..4 {
                    t[k + m] = V(if rect {
                        vrshrq_n_s32::<12>(vmulq_n_s32(c[m], 2896))
                    } else {
                        c[m]
                    });
                }
            }
            if vmaxvq_u32(vreinterpretq_u32_s32(nz)) == 0 {
                out.fill(0);
                continue;
            }
            for v in &mut t[tw..w] {
                *v = V::zero();
            }
            inv_1d_n::<V, N, M>(&mut t, kind, 16, e);
            for k in (0..w).step_by(4) {
                let f = |v: V| vmovl_s16(vqmovn_s32(vrshlq_s32(v.0, sh)));
                let c = transpose4(f(t[k]), f(t[k + 1]), f(t[k + 2]), f(t[k + 3]));
                for (m, &v) in c.iter().enumerate() {
                    st(&mut out[m * w + k..], v);
                }
            }
        }
    }
}

/// The column pass, 4 columns at a time, in place.
#[inline(always)]
fn cols<const N: u32, const M: usize>(w: usize, kind: i32, res: &mut [i32], e: &mut E) {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe {
        let h = 1usize << N;
        let mut t = [V::zero(); M];
        for j0 in (0..w).step_by(4) {
            for i in 0..h {
                t[i] = V(ld(&res[i * w + j0..]));
            }
            inv_1d_n::<V, N, M>(&mut t, kind, 16, e);
            for i in 0..h {
                st(&mut res[i * w + j0..], vrshrq_n_s32::<4>(t[i].0));
            }
        }
    }
}

#[inline(never)]
fn rows_n<const N: u32, const M: usize>(
    dq: &[i32],
    tw: usize,
    th: usize,
    h: usize,
    kind: i32,
    rect: bool,
    shift: i32,
    res: &mut [i32],
    e: &mut E,
) {
    match kind {
        K_DCT => rows::<N, M>(dq, tw, th, h, K_DCT, rect, shift, res, e),
        K_ADST => rows::<N, M>(dq, tw, th, h, K_ADST, rect, shift, res, e),
        _ => rows::<N, M>(dq, tw, th, h, K_IDT, rect, shift, res, e),
    }
}
#[inline(never)]
fn cols_n<const N: u32, const M: usize>(w: usize, kind: i32, res: &mut [i32], e: &mut E) {
    match kind {
        K_DCT => cols::<N, M>(w, K_DCT, res, e),
        K_ADST => cols::<N, M>(w, K_ADST, res, e),
        _ => cols::<N, M>(w, K_IDT, res, e),
    }
}

/// [`super::inv_txfm2d`] in NEON. False when the block is not conformant (or its input is outside
/// 16 bits): `res` is then garbage and the scalar reference must redo it.
pub(super) fn inv_txfm2d(dq: &[i32], tx_sz: i32, tx_type: i32, res: &mut [i32]) -> bool {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe {
        let log2w = Tx_Width_Log2[tx_sz as usize] as u32;
        let log2h = Tx_Height_Log2[tx_sz as usize] as u32;
        let (w, h) = (1usize << log2w, 1usize << log2h);
        let (tw, th) = (w.min(32), h.min(32));
        let dq = &dq[..tw * th];
        let res = &mut res[..w * h];
        // inputs within 16 bits (every dequantized coefficient is)
        let (mut lo, mut hi) = (vdupq_n_s32(0), vdupq_n_s32(0));
        for c in dq.as_chunks::<4>().0 {
            let v = ld(c);
            lo = vminq_s32(lo, v);
            hi = vmaxq_s32(hi, v);
        }
        if vminvq_s32(lo) < -(1 << 15) || vmaxvq_s32(hi) > (1 << 15) - 1 {
            return false;
        }
        let rect = log2w.abs_diff(log2h) == 1;
        let shift = Transform_Row_Shift[tx_sz as usize] as i32;
        let (rk, ck) = (row_kind(tx_type), col_kind(tx_type));
        let mut e = E::new();
        match log2w {
            2 => rows_n::<2, 4>(dq, tw, th, h, rk, rect, shift, res, &mut e),
            3 => rows_n::<3, 8>(dq, tw, th, h, rk, rect, shift, res, &mut e),
            4 => rows_n::<4, 16>(dq, tw, th, h, rk, rect, shift, res, &mut e),
            5 => rows_n::<5, 32>(dq, tw, th, h, rk, rect, shift, res, &mut e),
            _ => rows_n::<6, 64>(dq, tw, th, h, rk, rect, shift, res, &mut e),
        }
        match log2h {
            2 => cols_n::<2, 4>(w, ck, res, &mut e),
            3 => cols_n::<3, 8>(w, ck, res, &mut e),
            4 => cols_n::<4, 16>(w, ck, res, &mut e),
            5 => cols_n::<5, 32>(w, ck, res, &mut e),
            _ => cols_n::<6, 64>(w, ck, res, &mut e),
        }
        !e.bad()
    }
}
