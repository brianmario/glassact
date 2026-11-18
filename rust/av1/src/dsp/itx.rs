//! 1-D and 2-D inverse transforms (spec 7.13.2, 7.13.3) and the reconstruction add (7.12.3 step 3).
//!
//! The 1-D transforms are written once, generic over a [`Lane`]: `i32` is the exact scalar
//! reference (64-bit butterflies, the conformance checks as flags); the SIMD lanes (itx_neon.rs,
//! itx_sse.rs) run 4 rows or columns at once in 32-bit arithmetic. That is exact while every
//! butterfly input fits 16 bits, which holds until the first range violation: the SIMD lanes record
//! anything outside the conformant range, and [`inv_txfm2d`] then redoes the block with the scalar
//! reference, so results and flags always equal it.
use super::*;

/// The kind of the row (horizontal) or column (vertical) 1-D pass of a tx type.
pub const K_DCT: i32 = 0;
pub const K_ADST: i32 = 1;
pub const K_IDT: i32 = 2;

pub fn row_kind(t: i32) -> i32 {
    match t {
        DCT_DCT | ADST_DCT | FLIPADST_DCT | H_DCT => K_DCT,
        DCT_ADST | ADST_ADST | DCT_FLIPADST | FLIPADST_FLIPADST | ADST_FLIPADST | FLIPADST_ADST | H_ADST
        | H_FLIPADST => K_ADST,
        _ => K_IDT,
    }
}
pub fn col_kind(t: i32) -> i32 {
    match t {
        DCT_DCT | DCT_ADST | DCT_FLIPADST | V_DCT => K_DCT,
        ADST_DCT | ADST_ADST | FLIPADST_DCT | FLIPADST_FLIPADST | ADST_FLIPADST | FLIPADST_ADST | V_ADST
        | V_FLIPADST => K_ADST,
        _ => K_IDT,
    }
}
pub fn flip_ud(t: i32) -> bool {
    matches!(t, FLIPADST_DCT | FLIPADST_ADST | V_FLIPADST | FLIPADST_FLIPADST)
}
pub fn flip_lr(t: i32) -> bool {
    matches!(t, DCT_FLIPADST | ADST_FLIPADST | H_FLIPADST | FLIPADST_FLIPADST)
}

#[inline(always)]
pub const fn brev(num_bits: u32, x: usize) -> usize {
    let mut t = 0;
    let mut i = 0;
    while i < num_bits {
        t |= ((x >> i) & 1) << (num_bits - 1 - i);
        i += 1;
    }
    t
}
#[inline(always)]
pub const fn cos128(angle: i32) -> i32 {
    let a = (angle & 255) as usize;
    if a <= 64 {
        Cos128_Lookup[a] as i32
    } else if a <= 128 {
        -(Cos128_Lookup[128 - a] as i32)
    } else if a <= 192 {
        -(Cos128_Lookup[a - 128] as i32)
    } else {
        Cos128_Lookup[256 - a] as i32
    }
}
#[inline(always)]
pub const fn sin128(angle: i32) -> i32 {
    cos128(angle - 64)
}

#[inline(always)]
fn chk(v: i64, bits: i32, err: &mut u32, flag: u32) {
    if v < -(1i64 << (bits - 1)) || v > (1i64 << (bits - 1)) - 1 {
        *err |= flag;
    }
}

/// One lane type of the 1-D transforms: the spec's B and H, and the ADST4 / identity arithmetic.
/// `Wide` holds the ADST4's intermediates (64-bit for the scalar reference).
pub(crate) trait Lane: Copy {
    type Wide: Copy;
    type Err;
    fn zero() -> Self;
    /// (Round2(a * c - b * s, 12), Round2(a * s + b * c, 12)), each checked to r bits.
    fn bfly(a: Self, b: Self, c: i32, s: i32, r: i32, e: &mut Self::Err) -> (Self, Self);
    /// (x + y, x - y), each clamped to r bits.
    fn hadd(x: Self, y: Self, r: i32) -> (Self, Self);
    fn neg(x: Self) -> Self;
    fn identity<const N: u32>(x: Self) -> Self;
    fn wide(x: Self) -> Self::Wide;
    fn wmul(x: Self::Wide, c: i32) -> Self::Wide;
    fn wadd(x: Self::Wide, y: Self::Wide) -> Self::Wide;
    fn wsub(x: Self::Wide, y: Self::Wide) -> Self::Wide;
    fn wchk(x: Self::Wide, bits: i32, flag: u32, e: &mut Self::Err);
    fn wround12(x: Self::Wide) -> Self;
}

impl Lane for i32 {
    type Wide = i64;
    type Err = u32;
    #[inline(always)]
    fn zero() -> i32 {
        0
    }
    #[inline(always)]
    fn bfly(a: i32, b: i32, c: i32, s: i32, r: i32, e: &mut u32) -> (i32, i32) {
        let (c, s) = (c as i64, s as i64);
        let x = a as i64 * c - b as i64 * s;
        let y = a as i64 * s + b as i64 * c;
        let (xa, yb) = (round2_64(x, 12), round2_64(y, 12));
        chk(xa, r, e, ERR_B_RANGE);
        chk(yb, r, e, ERR_B_RANGE);
        (xa as i32, yb as i32)
    }
    #[inline(always)]
    fn hadd(x: i32, y: i32, r: i32) -> (i32, i32) {
        let (lo, hi) = (-(1i64 << (r - 1)), (1i64 << (r - 1)) - 1);
        let (x, y) = (x as i64, y as i64);
        ((x + y).clamp(lo, hi) as i32, (x - y).clamp(lo, hi) as i32)
    }
    #[inline(always)]
    fn neg(x: i32) -> i32 {
        x.wrapping_neg()
    }
    #[inline(always)]
    fn identity<const N: u32>(x: i32) -> i32 {
        match N {
            2 => round2_64(x as i64 * 5793, 12) as i32,
            3 => x.wrapping_mul(2),
            4 => round2_64(x as i64 * 11586, 12) as i32,
            _ => x.wrapping_mul(4),
        }
    }
    #[inline(always)]
    fn wide(x: i32) -> i64 {
        x as i64
    }
    #[inline(always)]
    fn wmul(x: i64, c: i32) -> i64 {
        x * c as i64
    }
    #[inline(always)]
    fn wadd(x: i64, y: i64) -> i64 {
        x + y
    }
    #[inline(always)]
    fn wsub(x: i64, y: i64) -> i64 {
        x - y
    }
    #[inline(always)]
    fn wchk(x: i64, bits: i32, flag: u32, e: &mut u32) {
        chk(x, bits, e, flag)
    }
    #[inline(always)]
    fn wround12(x: i64) -> i32 {
        round2_64(x, 12) as i32
    }
}

/// B( a, b, angle, flip, r ) (7.13.2.1)
#[inline(always)]
fn bf<L: Lane, const M: usize>(t: &mut [L; M], a: usize, b: usize, angle: i32, flip: bool, r: i32, e: &mut L::Err) {
    let (x, y) = L::bfly(t[a], t[b], cos128(angle), sin128(angle), r, e);
    if flip {
        t[a] = y;
        t[b] = x;
    } else {
        t[a] = x;
        t[b] = y;
    }
}
/// H( a, b, flip, r )
#[inline(always)]
fn hf<L: Lane, const M: usize>(t: &mut [L; M], a: usize, b: usize, flip: bool, r: i32) {
    let (a, b) = if flip { (b, a) } else { (a, b) };
    let (s, d) = L::hadd(t[a], t[b], r);
    t[a] = s;
    t[b] = d;
}

/// Inverse DCT (7.13.2.3) of 2^N points.
#[inline(always)]
pub(crate) fn idct<L: Lane, const N: u32, const M: usize>(t: &mut [L; M], r: i32, e: &mut L::Err) {
    let n = N;
    let n0 = 1usize << n;
    let copy = *t;
    for i in 0..n0 {
        t[i] = copy[brev(n, i)]; // step 1
    }
    if n == 6 {
        for i in 0..16 {
            bf(t, 32 + i, 63 - i, 63 - 4 * brev(4, i) as i32, false, r, e);
        }
    }
    if n >= 5 {
        for i in 0..8 {
            bf(t, 16 + i, 31 - i, 6 + ((brev(3, 7 - i) as i32) << 3), false, r, e);
        }
    }
    if n == 6 {
        for i in 0..16 {
            hf(t, 32 + i * 2, 33 + i * 2, i & 1 != 0, r);
        }
    }
    if n >= 4 {
        for i in 0..4 {
            bf(t, 8 + i, 15 - i, 12 + ((brev(2, 3 - i) as i32) << 4), false, r, e);
        }
    }
    if n >= 5 {
        for i in 0..8 {
            hf(t, 16 + 2 * i, 17 + 2 * i, i & 1 != 0, r);
        }
    }
    if n == 6 {
        for i in 0..4 {
            for j in 0..2 {
                bf(
                    t,
                    62 - i * 4 - j,
                    33 + i * 4 + j,
                    60 - 16 * brev(2, i) as i32 + 64 * j as i32,
                    true,
                    r,
                    e,
                );
            }
        }
    }
    if n >= 3 {
        for i in 0..2 {
            bf(t, 4 + i, 7 - i, 56 - 32 * i as i32, false, r, e);
        }
    }
    if n >= 4 {
        for i in 0..4 {
            hf(t, 8 + 2 * i, 9 + 2 * i, i & 1 != 0, r);
        }
    }
    if n >= 5 {
        for i in 0..2 {
            for j in 0..2 {
                bf(
                    t,
                    30 - 4 * i - j,
                    17 + 4 * i + j,
                    24 + ((j as i32) << 6) + ((1 - i as i32) << 5),
                    true,
                    r,
                    e,
                );
            }
        }
    }
    if n == 6 {
        for i in 0..8 {
            for j in 0..2 {
                hf(t, 32 + i * 4 + j, 35 + i * 4 - j, i & 1 != 0, r);
            }
        }
    }
    for i in 0..2 {
        bf(t, 2 * i, 2 * i + 1, 32 + 16 * i as i32, i == 0, r, e); // step 12
    }
    if n >= 3 {
        for i in 0..2 {
            hf(t, 4 + 2 * i, 5 + 2 * i, i != 0, r);
        }
    }
    if n >= 4 {
        for i in 0..2 {
            bf(t, 14 - i, 9 + i, 48 + 64 * i as i32, true, r, e);
        }
    }
    if n >= 5 {
        for i in 0..4 {
            for j in 0..2 {
                hf(t, 16 + 4 * i + j, 19 + 4 * i - j, i & 1 != 0, r);
            }
        }
    }
    if n == 6 {
        for i in 0..2 {
            for j in 0..4 {
                bf(
                    t,
                    61 - i * 8 - j,
                    34 + i * 8 + j,
                    56 - i as i32 * 32 + (j as i32 >> 1) * 64,
                    true,
                    r,
                    e,
                );
            }
        }
    }
    for i in 0..2 {
        hf(t, i, 3 - i, false, r); // step 17
    }
    if n >= 3 {
        bf(t, 6, 5, 32, true, r, e);
    }
    if n >= 4 {
        for i in 0..2 {
            for j in 0..2 {
                hf(t, 8 + 4 * i + j, 11 + 4 * i - j, i != 0, r);
            }
        }
    }
    if n >= 5 {
        for i in 0..4 {
            bf(t, 29 - i, 18 + i, 48 + (i as i32 >> 1) * 64, true, r, e);
        }
    }
    if n == 6 {
        for i in 0..4 {
            for j in 0..4 {
                hf(t, 32 + 8 * i + j, 39 + 8 * i - j, i & 1 != 0, r);
            }
        }
    }
    if n >= 3 {
        for i in 0..4 {
            hf(t, i, 7 - i, false, r); // step 22
        }
    }
    if n >= 4 {
        for i in 0..2 {
            bf(t, 13 - i, 10 + i, 32, true, r, e);
        }
    }
    if n >= 5 {
        for i in 0..2 {
            for j in 0..4 {
                hf(t, 16 + i * 8 + j, 23 + i * 8 - j, i != 0, r);
            }
        }
    }
    if n == 6 {
        for i in 0..8 {
            bf(t, 59 - i, 36 + i, if i < 4 { 48 } else { 112 }, true, r, e);
        }
    }
    if n >= 4 {
        for i in 0..8 {
            hf(t, i, 15 - i, false, r); // step 26
        }
    }
    if n >= 5 {
        for i in 0..4 {
            bf(t, 27 - i, 20 + i, 32, true, r, e);
        }
    }
    if n == 6 {
        for i in 0..8 {
            hf(t, 32 + i, 47 - i, false, r);
            hf(t, 48 + i, 63 - i, true, r);
        }
    }
    if n >= 5 {
        for i in 0..16 {
            hf(t, i, 31 - i, false, r);
        }
    }
    if n == 6 {
        for i in 0..8 {
            bf(t, 55 - i, 40 + i, 32, true, r, e);
        }
    }
    if n == 6 {
        for i in 0..32 {
            hf(t, i, 63 - i, false, r); // step 31
        }
    }
}

#[inline(always)]
fn iadst_in_perm<L: Lane, const N: u32, const M: usize>(t: &mut [L; M]) {
    let n0 = 1usize << N;
    let copy = *t;
    for i in 0..n0 {
        t[i] = copy[if i & 1 != 0 { i - 1 } else { n0 - i - 1 }];
    }
}
#[inline(always)]
fn iadst_out_perm<L: Lane, const N: u32, const M: usize>(t: &mut [L; M]) {
    let n0 = 1usize << N;
    let copy = *t;
    for i in 0..n0 {
        let a = (i >> 3) & 1;
        let b = ((i >> 2) & 1) ^ ((i >> 3) & 1);
        let c = ((i >> 1) & 1) ^ ((i >> 2) & 1);
        let d = (i & 1) ^ ((i >> 1) & 1);
        let idx = ((d << 3) | (c << 2) | (b << 1) | a) >> (4 - N);
        t[i] = if i & 1 != 0 { L::neg(copy[idx]) } else { copy[idx] };
    }
}

/// Inverse ADST4 (7.13.2.6).
#[inline(always)]
pub(crate) fn iadst4<L: Lane, const M: usize>(t: &mut [L; M], r: i32, e: &mut L::Err) {
    const SINPI_1_9: i32 = 1321;
    const SINPI_2_9: i32 = 2482;
    const SINPI_3_9: i32 = 3344;
    const SINPI_4_9: i32 = 3803;
    const F: u32 = ERR_ADST4_RANGE;
    let w = |k: usize| L::wide(t[k]);
    let mut s0 = L::wmul(w(0), SINPI_1_9);
    let mut s1 = L::wmul(w(0), SINPI_2_9);
    let mut s2 = L::wmul(w(1), SINPI_3_9);
    let mut s3 = L::wmul(w(2), SINPI_4_9);
    let s4 = L::wmul(w(2), SINPI_1_9);
    let s5 = L::wmul(w(3), SINPI_2_9);
    let s6 = L::wmul(w(3), SINPI_4_9);
    let a7 = L::wsub(w(0), w(2));
    let b7 = L::wadd(a7, w(3));
    L::wchk(a7, r + 1, F, e);
    L::wchk(b7, r, F, e);
    for s in [s0, s1, s2, s3, s4, s5, s6] {
        L::wchk(s, r + 12, F, e);
    }
    s0 = L::wadd(s0, s3);
    s1 = L::wsub(s1, s4);
    s3 = s2;
    s2 = L::wmul(b7, SINPI_3_9);
    L::wchk(s0, r + 12, F, e);
    L::wchk(s1, r + 12, F, e);
    L::wchk(s2, r + 12, F, e);
    s0 = L::wadd(s0, s5);
    s1 = L::wsub(s1, s6);
    L::wchk(s0, r + 12, F, e);
    L::wchk(s1, r + 12, F, e);
    let x0 = L::wadd(s0, s3);
    let x1 = L::wadd(s1, s3);
    let x2 = s2;
    let mut x3 = L::wadd(s0, s1);
    L::wchk(x3, r + 12, F, e);
    x3 = L::wsub(x3, s3);
    for x in [x0, x1, x2, x3] {
        L::wchk(x, r + 12, F, e);
    }
    t[0] = L::wround12(x0);
    t[1] = L::wround12(x1);
    t[2] = L::wround12(x2);
    t[3] = L::wround12(x3);
}

/// Inverse ADST8 (7.13.2.7).
#[inline(always)]
pub(crate) fn iadst8<L: Lane, const M: usize>(t: &mut [L; M], r: i32, e: &mut L::Err) {
    iadst_in_perm::<L, 3, M>(t);
    for i in 0..4 {
        bf(t, 2 * i, 2 * i + 1, 60 - 16 * i as i32, true, r, e);
    }
    for i in 0..4 {
        hf(t, i, 4 + i, false, r);
    }
    for i in 0..2 {
        bf(t, 4 + 3 * i, 5 + i, 48 - 32 * i as i32, true, r, e);
    }
    for i in 0..2 {
        for j in 0..2 {
            hf(t, 4 * j + i, 2 + 4 * j + i, false, r);
        }
    }
    for i in 0..2 {
        bf(t, 2 + 4 * i, 3 + 4 * i, 32, true, r, e);
    }
    iadst_out_perm::<L, 3, M>(t);
}

/// Inverse ADST16 (7.13.2.8).
#[inline(always)]
pub(crate) fn iadst16<L: Lane, const M: usize>(t: &mut [L; M], r: i32, e: &mut L::Err) {
    iadst_in_perm::<L, 4, M>(t);
    for i in 0..8 {
        bf(t, 2 * i, 2 * i + 1, 62 - 8 * i as i32, true, r, e);
    }
    for i in 0..8 {
        hf(t, i, 8 + i, false, r);
    }
    for i in 0..2 {
        bf(t, 8 + 2 * i, 9 + 2 * i, 56 - 32 * i as i32, true, r, e);
        bf(t, 13 + 2 * i, 12 + 2 * i, 8 + 32 * i as i32, true, r, e);
    }
    for i in 0..4 {
        for j in 0..2 {
            hf(t, 8 * j + i, 4 + 8 * j + i, false, r);
        }
    }
    for i in 0..2 {
        for j in 0..2 {
            bf(t, 4 + 8 * j + 3 * i, 5 + 8 * j + i, 48 - 32 * i as i32, true, r, e);
        }
    }
    for i in 0..2 {
        for j in 0..4 {
            hf(t, 4 * j + i, 2 + 4 * j + i, false, r);
        }
    }
    for i in 0..4 {
        bf(t, 2 + 4 * i, 3 + 4 * i, 32, true, r, e);
    }
    iadst_out_perm::<L, 4, M>(t);
}

/// Inverse identity transform (7.13.2.15) of 2^N points.
#[inline(always)]
pub(crate) fn iidentity<L: Lane, const N: u32, const M: usize>(t: &mut [L; M]) {
    for v in t.iter_mut().take(1 << N) {
        *v = L::identity::<N>(*v);
    }
}

/// One 1-D inverse transform of kind `kind` (K_DCT / K_ADST / K_IDT) on 2^N points, monomorphized.
#[inline(always)]
pub(crate) fn inv_1d_n<L: Lane, const N: u32, const M: usize>(t: &mut [L; M], kind: i32, r: i32, e: &mut L::Err) {
    match kind {
        K_DCT => idct::<L, N, M>(t, r, e),
        K_ADST => match N {
            2 => iadst4(t, r, e),
            3 => iadst8(t, r, e),
            _ => iadst16(t, r, e),
        },
        _ => iidentity::<L, N, M>(t),
    }
}

/// One 1-D inverse transform (spec 7.13.2): `kind` of 2^n points (n = 2..6) on `t[..1 << n]`, with
/// the range checks at r bits OR-ed into `err`. r may be up to 31 (forward-matrix builders).
pub fn inv_1d(t: &mut [i32; 64], kind: i32, n: i32, r: i32, err: &mut u32) {
    match n {
        2 => inv_1d_n::<i32, 2, 4>((&mut t[..4]).try_into().unwrap(), kind, r, err),
        3 => inv_1d_n::<i32, 3, 8>((&mut t[..8]).try_into().unwrap(), kind, r, err),
        4 => inv_1d_n::<i32, 4, 16>((&mut t[..16]).try_into().unwrap(), kind, r, err),
        5 => inv_1d_n::<i32, 5, 32>((&mut t[..32]).try_into().unwrap(), kind, r, err),
        _ => inv_1d_n::<i32, 6, 64>((&mut t[..64]).try_into().unwrap(), kind, r, err),
    }
}

/// 2-D inverse transform (spec 7.13.3, Lossless = 0, BitDepth = 8): `dq` is the Dequant array, th x
/// tw row-major (tw = min(32, w), th = min(32, h)); `res` receives the Residual, h x w row-major (up
/// to 64 x 64). Returns the OR-ed ERR_* flags of conformance violations (0 = conformant).
pub fn inv_txfm2d(dq: &[i32], tx_sz: i32, tx_type: i32, res: &mut [i32]) -> u32 {
    #[cfg(target_arch = "aarch64")]
    {
        if super::itx_neon::inv_txfm2d(dq, tx_sz, tx_type, res) {
            return 0;
        }
    }
    #[cfg(target_arch = "x86_64")]
    {
        if super::itx_sse::available() && super::itx_sse::inv_txfm2d(dq, tx_sz, tx_type, res) {
            return 0;
        }
    }
    inv_txfm2d_scalar(dq, tx_sz, tx_type, res)
}

/// The scalar reference of [`inv_txfm2d`], step by step as the spec.
pub fn inv_txfm2d_scalar(dq: &[i32], tx_sz: i32, tx_type: i32, res: &mut [i32]) -> u32 {
    let log2w = Tx_Width_Log2[tx_sz as usize] as i32;
    let log2h = Tx_Height_Log2[tx_sz as usize] as i32;
    let (w, h) = (1usize << log2w, 1usize << log2h);
    let (tw, th) = (w.min(32), h.min(32));
    let row_shift = Transform_Row_Shift[tx_sz as usize] as i32;
    let (row_r, col_r) = (16, 16); // BitDepth + 8, Max(BitDepth + 6, 16)
    let (rk, ck) = (row_kind(tx_type), col_kind(tx_type));
    let rect = (log2w - log2h).abs() == 1;
    let dq = &dq[..tw * th];
    let res = &mut res[..w * h];
    let mut err = 0u32;
    let mut t = [0i32; 64];
    for i in 0..h {
        let row = &mut res[i * w..(i + 1) * w];
        // an all-zero input row gives an all-zero output (every 1-D transform is linear, odd-symmetric)
        if i >= th || dq[i * tw..(i + 1) * tw].iter().all(|&v| v == 0) {
            row.fill(0);
            continue;
        }
        t[..tw].copy_from_slice(&dq[i * tw..(i + 1) * tw]);
        t[tw..w].fill(0);
        if rect {
            for v in &mut t[..w] {
                *v = round2_64(*v as i64 * 2896, 12) as i32;
            }
        }
        inv_1d(&mut t, rk, log2w, row_r, &mut err);
        for j in 0..w {
            let v = round2_64(t[j] as i64, row_shift) as i32;
            row[j] = clip3(-(1 << (col_r - 1)), (1 << (col_r - 1)) - 1, v);
        }
    }
    for j in 0..w {
        for i in 0..h {
            t[i] = res[i * w + j];
        }
        inv_1d(&mut t, ck, log2h, col_r, &mut err);
        for i in 0..h {
            res[i * w + j] = round2_64(t[i] as i64, 4) as i32;
        }
    }
    err
}

/// Reconstruction add (spec 7.12.3 step 3): `dst` at the tx block's top-left sample.
pub fn add_residual(dst: &mut [u8], stride: usize, res: &[i32], tx_sz: i32, tx_type: i32) {
    let (w, h) = (tx_w(tx_sz) as usize, tx_h(tx_sz) as usize);
    let (fud, flr) = (flip_ud(tx_type), flip_lr(tx_type));
    for i in 0..h {
        let yy = if fud { h - i - 1 } else { i };
        let d = &mut dst[yy * stride..yy * stride + w];
        let r = &res[i * w..(i + 1) * w];
        if flr {
            for (p, &v) in d.iter_mut().rev().zip(r) {
                *p = clip1(*p as i32 + v) as u8;
            }
        } else {
            for (p, &v) in d.iter_mut().zip(r) {
                *p = clip1(*p as i32 + v) as u8;
            }
        }
    }
}
