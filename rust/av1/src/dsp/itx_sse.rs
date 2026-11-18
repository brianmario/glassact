//! SSE4.1 inverse transforms: the same 4-lane scheme as itx_neon.rs (see itx.rs for why it is exact).
//! The lane methods are inlined into `inv_txfm2d_sse41`, which enables SSE4.1.
use super::itx::*;
use crate::tables::*;
use core::arch::x86_64::*;

pub(super) fn available() -> bool {
    std::arch::is_x86_feature_detected!("sse4.1")
}

#[derive(Clone, Copy)]
pub(crate) struct V(__m128i);

pub(crate) struct E {
    a16: __m128i,
    any: __m128i,
}

// SAFETY (every `unsafe` block in this file's lane methods): the SSE4.1 intrinsics only run inlined
// into `inv_txfm2d_sse41`, which is only called once `available()` said SSE4.1 is there.
impl Lane for V {
    type Wide = V;
    type Err = E;
    #[inline(always)]
    fn zero() -> V {
        // SAFETY: SSE2 is x86_64 baseline; SSE4.1 is enabled by the caller (see above).
        unsafe { V(_mm_setzero_si128()) }
    }
    #[inline(always)]
    fn bfly(a: V, b: V, c: i32, s: i32, r: i32, e: &mut E) -> (V, V) {
        debug_assert!(r == 16);
        // SAFETY: see above.
        unsafe {
            let (cv, sv) = (_mm_set1_epi32(c), _mm_set1_epi32(s));
            let x = _mm_sub_epi32(_mm_mullo_epi32(a.0, cv), _mm_mullo_epi32(b.0, sv));
            let y = _mm_add_epi32(_mm_mullo_epi32(a.0, sv), _mm_mullo_epi32(b.0, cv));
            let rnd = _mm_set1_epi32(1 << 11);
            let xa = _mm_srai_epi32::<12>(_mm_add_epi32(x, rnd));
            let yb = _mm_srai_epi32::<12>(_mm_add_epi32(y, rnd));
            let k = _mm_set1_epi32(1 << 15);
            e.a16 = _mm_or_si128(e.a16, _mm_or_si128(_mm_add_epi32(xa, k), _mm_add_epi32(yb, k)));
            (V(xa), V(yb))
        }
    }
    #[inline(always)]
    fn hadd(x: V, y: V, r: i32) -> (V, V) {
        // SAFETY: see above.
        unsafe {
            let (lo, hi) = (_mm_set1_epi32(-(1 << (r - 1))), _mm_set1_epi32((1 << (r - 1)) - 1));
            let s = _mm_min_epi32(_mm_max_epi32(_mm_add_epi32(x.0, y.0), lo), hi);
            let d = _mm_min_epi32(_mm_max_epi32(_mm_sub_epi32(x.0, y.0), lo), hi);
            (V(s), V(d))
        }
    }
    #[inline(always)]
    fn neg(x: V) -> V {
        // SAFETY: SSE2 is x86_64 baseline; SSE4.1 is enabled by the caller (see above).
        unsafe { V(_mm_sub_epi32(_mm_setzero_si128(), x.0)) }
    }
    #[inline(always)]
    fn identity<const N: u32>(x: V) -> V {
        // SAFETY: see above.
        unsafe {
            let rnd = _mm_set1_epi32(1 << 11);
            V(match N {
                2 => _mm_srai_epi32::<12>(_mm_add_epi32(_mm_mullo_epi32(x.0, _mm_set1_epi32(5793)), rnd)),
                3 => _mm_slli_epi32::<1>(x.0),
                4 => _mm_srai_epi32::<12>(_mm_add_epi32(_mm_mullo_epi32(x.0, _mm_set1_epi32(11586)), rnd)),
                _ => _mm_slli_epi32::<2>(x.0),
            })
        }
    }
    #[inline(always)]
    fn wide(x: V) -> V {
        x
    }
    #[inline(always)]
    fn wmul(x: V, c: i32) -> V {
        // SAFETY: see above.
        unsafe { V(_mm_mullo_epi32(x.0, _mm_set1_epi32(c))) }
    }
    #[inline(always)]
    fn wadd(x: V, y: V) -> V {
        // SAFETY: SSE2 is x86_64 baseline; SSE4.1 is enabled by the caller (see above).
        unsafe { V(_mm_add_epi32(x.0, y.0)) }
    }
    #[inline(always)]
    fn wsub(x: V, y: V) -> V {
        // SAFETY: SSE2 is x86_64 baseline; SSE4.1 is enabled by the caller (see above).
        unsafe { V(_mm_sub_epi32(x.0, y.0)) }
    }
    #[inline(always)]
    fn wchk(x: V, bits: i32, _flag: u32, e: &mut E) {
        // SAFETY: SSE2 is x86_64 baseline; SSE4.1 is enabled by the caller (see above).
        unsafe {
            let v = _mm_sra_epi32(
                _mm_add_epi32(x.0, _mm_set1_epi32(1 << (bits - 1))),
                _mm_cvtsi32_si128(bits),
            );
            e.any = _mm_or_si128(e.any, v);
        }
    }
    #[inline(always)]
    fn wround12(x: V) -> V {
        // SAFETY: SSE2 is x86_64 baseline; SSE4.1 is enabled by the caller (see above).
        unsafe { V(_mm_srai_epi32::<12>(_mm_add_epi32(x.0, _mm_set1_epi32(1 << 11)))) }
    }
}

#[inline(always)]
fn transpose4(a: __m128i, b: __m128i, c: __m128i, d: __m128i) -> [__m128i; 4] {
    // SAFETY: SSE2 is x86_64 baseline; SSE4.1 is enabled by the caller (see above).
    unsafe {
        let t0 = _mm_unpacklo_epi32(a, b); // a0 b0 a1 b1
        let t1 = _mm_unpackhi_epi32(a, b); // a2 b2 a3 b3
        let t2 = _mm_unpacklo_epi32(c, d);
        let t3 = _mm_unpackhi_epi32(c, d);
        [
            _mm_unpacklo_epi64(t0, t2),
            _mm_unpackhi_epi64(t0, t2),
            _mm_unpacklo_epi64(t1, t3),
            _mm_unpackhi_epi64(t1, t3),
        ]
    }
}
#[inline(always)]
fn ld(s: &[i32]) -> __m128i {
    let s = &s[..4];
    // SAFETY: s has 4 elements; unaligned load.
    unsafe { _mm_loadu_si128(s.as_ptr() as *const __m128i) }
}
#[inline(always)]
fn st(d: &mut [i32], v: __m128i) {
    let d = &mut d[..4];
    // SAFETY: d has 4 elements; unaligned store.
    unsafe { _mm_storeu_si128(d.as_mut_ptr() as *mut __m128i, v) }
}
#[inline(always)]
fn is_zero(v: __m128i) -> bool {
    // SAFETY: SSE2 is x86_64 baseline; SSE4.1 is enabled by the caller (see above).
    unsafe { _mm_movemask_epi8(_mm_cmpeq_epi32(v, _mm_setzero_si128())) == 0xFFFF }
}

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
    // SAFETY: SSE2 is x86_64 baseline; SSE4.1 is enabled by the caller (see above).
    unsafe {
        let w = 1usize << N;
        let mut t = [V::zero(); M];
        let cnt = _mm_cvtsi32_si128(shift);
        let rnd = _mm_set1_epi32((1 << shift) >> 1);
        for i0 in (0..h).step_by(4) {
            let out = &mut res[i0 * w..(i0 + 4) * w];
            if i0 >= th {
                out.fill(0);
                continue;
            }
            let inp = &dq[i0 * tw..(i0 + 4) * tw];
            let mut nz = _mm_setzero_si128();
            for k in (0..tw).step_by(4) {
                let r = [
                    ld(&inp[k..]),
                    ld(&inp[tw + k..]),
                    ld(&inp[2 * tw + k..]),
                    ld(&inp[3 * tw + k..]),
                ];
                nz = _mm_or_si128(nz, _mm_or_si128(_mm_or_si128(r[0], r[1]), _mm_or_si128(r[2], r[3])));
                let c = transpose4(r[0], r[1], r[2], r[3]);
                for m in 0..4 {
                    t[k + m] = if rect {
                        V::wround12(V::wmul(V(c[m]), 2896))
                    } else {
                        V(c[m])
                    };
                }
            }
            if is_zero(nz) {
                out.fill(0);
                continue;
            }
            for v in &mut t[tw..w] {
                *v = V::zero();
            }
            inv_1d_n::<V, N, M>(&mut t, kind, 16, e);
            for k in (0..w).step_by(4) {
                let f = |v: V| {
                    let x = _mm_sra_epi32(_mm_add_epi32(v.0, rnd), cnt);
                    let p = _mm_packs_epi32(x, x);
                    _mm_srai_epi32::<16>(_mm_unpacklo_epi16(p, p))
                };
                let c = transpose4(f(t[k]), f(t[k + 1]), f(t[k + 2]), f(t[k + 3]));
                for (m, &v) in c.iter().enumerate() {
                    st(&mut out[m * w + k..], v);
                }
            }
        }
    }
}

#[inline(always)]
fn cols<const N: u32, const M: usize>(w: usize, kind: i32, res: &mut [i32], e: &mut E) {
    // SAFETY: SSE2 is x86_64 baseline; SSE4.1 is enabled by the caller (see above).
    unsafe {
        let h = 1usize << N;
        let mut t = [V::zero(); M];
        for j0 in (0..w).step_by(4) {
            for i in 0..h {
                t[i] = V(ld(&res[i * w + j0..]));
            }
            inv_1d_n::<V, N, M>(&mut t, kind, 16, e);
            for i in 0..h {
                st(
                    &mut res[i * w + j0..],
                    _mm_srai_epi32::<4>(_mm_add_epi32(t[i].0, _mm_set1_epi32(8))),
                );
            }
        }
    }
}

#[target_feature(enable = "sse4.1")]
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
#[target_feature(enable = "sse4.1")]
fn cols_n<const N: u32, const M: usize>(w: usize, kind: i32, res: &mut [i32], e: &mut E) {
    match kind {
        K_DCT => cols::<N, M>(w, K_DCT, res, e),
        K_ADST => cols::<N, M>(w, K_ADST, res, e),
        _ => cols::<N, M>(w, K_IDT, res, e),
    }
}

#[target_feature(enable = "sse4.1")]
fn inv_txfm2d_sse41(dq: &[i32], tx_sz: i32, tx_type: i32, res: &mut [i32]) -> bool {
    let log2w = Tx_Width_Log2[tx_sz as usize] as u32;
    let log2h = Tx_Height_Log2[tx_sz as usize] as u32;
    let (w, h) = (1usize << log2w, 1usize << log2h);
    let (tw, th) = (w.min(32), h.min(32));
    let dq = &dq[..tw * th];
    let res = &mut res[..w * h];
    let (mut lo, mut hi) = (_mm_setzero_si128(), _mm_setzero_si128());
    for c in dq.as_chunks::<4>().0 {
        let v = ld(c);
        lo = _mm_min_epi32(lo, v);
        hi = _mm_max_epi32(hi, v);
    }
    let out = _mm_or_si128(
        _mm_cmplt_epi32(lo, _mm_set1_epi32(-(1 << 15))),
        _mm_cmpgt_epi32(hi, _mm_set1_epi32((1 << 15) - 1)),
    );
    if !is_zero(out) {
        return false;
    }
    let rect = log2w.abs_diff(log2h) == 1;
    let shift = Transform_Row_Shift[tx_sz as usize] as i32;
    let (rk, ck) = (row_kind(tx_type), col_kind(tx_type));
    let mut e = E {
        a16: _mm_setzero_si128(),
        any: _mm_setzero_si128(),
    };
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
    is_zero(_mm_or_si128(_mm_srai_epi32::<16>(e.a16), e.any))
}

/// [`super::inv_txfm2d`] in SSE4.1; as itx_neon's. Call only when [`available`].
pub(super) fn inv_txfm2d(dq: &[i32], tx_sz: i32, tx_type: i32, res: &mut [i32]) -> bool {
    // SAFETY: the caller checked available() (SSE4.1).
    unsafe { inv_txfm2d_sse41(dq, tx_sz, tx_type, res) }
}
