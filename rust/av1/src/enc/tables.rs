//! The encoder's derived tables as Metal source (Sources/AV1Encoder/src/tables.cpp,
//! av1enc_tables_msl): forward transform matrices, transform energy and scale factors, and symbol
//! costs from the default CDFs.
//!
//! The host half of av1gpu's encoder/src/k_misc.cu gp_init_tables (BSD-2), computed the same way.
//! The kernels are compiled at run time, so the tables become `constant` arrays in their source.
//! Floats are written as C99 hex literals (printf's `%a`), so the GPU sees exactly these values,
//! and the text is the C++'s byte for byte.
use super::fmac;
use crate::entropy::{Cdfs, NCDF};
use crate::tables::*;
use core::fmt::Write;

/// forward transform matrices: DCT 4..64, ADST 4..16, identity 4..32 (n x n each)
pub const GP_FWD_FLOATS: usize = (16 + 64 + 256 + 1024 + 4096) + (16 + 64 + 256) + (16 + 64 + 256 + 1024);

const K_DCT: usize = 0;
const K_ADST: usize = 1;
const K_IDT: usize = 2;

// ---- the 1-D inverse transforms (spec 7.13.2), as av1g/dsp.h's av1g_inv_1d: a private copy for
// the matrices (the conformance flags aren't needed here) ----

fn brev(num_bits: u32, x: usize) -> usize {
    let mut t = 0;
    for i in 0..num_bits {
        t |= ((x >> i) & 1) << (num_bits - 1 - i);
    }
    t
}

fn cos128(angle: i32) -> i64 {
    let a = (angle & 255) as usize;
    (if a <= 64 {
        Cos128_Lookup[a] as i32
    } else if a <= 128 {
        -(Cos128_Lookup[128 - a] as i32)
    } else if a <= 192 {
        -(Cos128_Lookup[a - 128] as i32)
    } else {
        Cos128_Lookup[256 - a] as i32
    }) as i64
}

fn round2_64(x: i64, n: u32) -> i64 {
    if n == 0 { x } else { (x + (1i64 << (n - 1))) >> n }
}

/// B(a, b, angle, flip)
fn bf(t: &mut [i32; 64], a: usize, b: usize, angle: i32, flip: bool) {
    let (c, s) = (cos128(angle), cos128(angle - 64));
    let x = t[a] as i64 * c - t[b] as i64 * s;
    let y = t[a] as i64 * s + t[b] as i64 * c;
    let (xa, yb) = (round2_64(x, 12) as i32, round2_64(y, 12) as i32);
    if flip {
        (t[a], t[b]) = (yb, xa);
    } else {
        (t[a], t[b]) = (xa, yb);
    }
}

/// H(a, b, flip, r)
fn hf(t: &mut [i32; 64], a: usize, b: usize, flip: bool, r: u32) {
    let (a, b) = if flip { (b, a) } else { (a, b) };
    let (x, y) = (t[a] as i64, t[b] as i64);
    let (lo, hi) = (-(1i64 << (r - 1)), (1i64 << (r - 1)) - 1);
    t[a] = (x + y).clamp(lo, hi) as i32;
    t[b] = (x - y).clamp(lo, hi) as i32;
}

fn idct(t: &mut [i32; 64], n: u32, r: u32) {
    let n0 = 1usize << n;
    let copy = *t;
    for i in 0..n0 {
        t[i] = copy[brev(n, i)]; // step 1
    }
    let bi = |n: u32, x: usize| brev(n, x) as i32;
    if n == 6 {
        for i in 0..16 {
            bf(t, 32 + i, 63 - i, 63 - 4 * bi(4, i), false);
        }
    }
    if n >= 5 {
        for i in 0..8 {
            bf(t, 16 + i, 31 - i, 6 + (bi(3, 7 - i) << 3), false);
        }
    }
    if n == 6 {
        for i in 0..16 {
            hf(t, 32 + i * 2, 33 + i * 2, i & 1 != 0, r);
        }
    }
    if n >= 4 {
        for i in 0..4 {
            bf(t, 8 + i, 15 - i, 12 + (bi(2, 3 - i) << 4), false);
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
                    60 - 16 * bi(2, i) + 64 * j as i32,
                    true,
                );
            }
        }
    }
    if n >= 3 {
        for i in 0..2 {
            bf(t, 4 + i, 7 - i, 56 - 32 * i as i32, false);
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
        bf(t, 2 * i, 2 * i + 1, 32 + 16 * i as i32, i == 0); // step 12
    }
    if n >= 3 {
        for i in 0..2 {
            hf(t, 4 + 2 * i, 5 + 2 * i, i != 0, r);
        }
    }
    if n >= 4 {
        for i in 0..2 {
            bf(t, 14 - i, 9 + i, 48 + 64 * i as i32, true);
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
                );
            }
        }
    }
    for i in 0..2 {
        hf(t, i, 3 - i, false, r); // step 17
    }
    if n >= 3 {
        bf(t, 6, 5, 32, true);
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
            bf(t, 29 - i, 18 + i, 48 + (i as i32 >> 1) * 64, true);
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
            bf(t, 13 - i, 10 + i, 32, true);
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
            bf(t, 59 - i, 36 + i, if i < 4 { 48 } else { 112 }, true);
        }
    }
    if n >= 4 {
        for i in 0..8 {
            hf(t, i, 15 - i, false, r); // step 26
        }
    }
    if n >= 5 {
        for i in 0..4 {
            bf(t, 27 - i, 20 + i, 32, true);
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
            bf(t, 55 - i, 40 + i, 32, true);
        }
    }
    if n == 6 {
        for i in 0..32 {
            hf(t, i, 63 - i, false, r); // step 31
        }
    }
}

fn iadst_in_perm(t: &mut [i32; 64], n: u32) {
    let n0 = 1usize << n;
    let copy = *t;
    for i in 0..n0 {
        t[i] = copy[if i & 1 != 0 { i - 1 } else { n0 - i - 1 }];
    }
}

fn iadst_out_perm(t: &mut [i32; 64], n: u32) {
    let n0 = 1usize << n;
    let copy = *t;
    for i in 0..n0 {
        let a = (i >> 3) & 1;
        let b = ((i >> 2) & 1) ^ ((i >> 3) & 1);
        let c = ((i >> 1) & 1) ^ ((i >> 2) & 1);
        let d = (i & 1) ^ ((i >> 1) & 1);
        let idx = ((d << 3) | (c << 2) | (b << 1) | a) >> (4 - n);
        t[i] = if i & 1 != 0 {
            copy[idx].wrapping_neg()
        } else {
            copy[idx]
        };
    }
}

fn iadst4(t: &mut [i32; 64]) {
    const SINPI_1_9: i64 = 1321;
    const SINPI_2_9: i64 = 2482;
    const SINPI_3_9: i64 = 3344;
    const SINPI_4_9: i64 = 3803;
    let (t0, t1, t2, t3) = (t[0] as i64, t[1] as i64, t[2] as i64, t[3] as i64);
    let mut s = [
        SINPI_1_9 * t0,
        SINPI_2_9 * t0,
        SINPI_3_9 * t1,
        SINPI_4_9 * t2,
        SINPI_1_9 * t2,
        SINPI_2_9 * t3,
        SINPI_4_9 * t3,
    ];
    let b7 = t0 - t2 + t3;
    s[0] += s[3];
    s[1] -= s[4];
    s[3] = s[2];
    s[2] = SINPI_3_9 * b7;
    s[0] += s[5];
    s[1] -= s[6];
    let x = [s[0] + s[3], s[1] + s[3], s[2], s[0] + s[1] - s[3]];
    for i in 0..4 {
        t[i] = round2_64(x[i], 12) as i32;
    }
}

fn iadst8(t: &mut [i32; 64], r: u32) {
    iadst_in_perm(t, 3);
    for i in 0..4 {
        bf(t, 2 * i, 2 * i + 1, 60 - 16 * i as i32, true);
    }
    for i in 0..4 {
        hf(t, i, 4 + i, false, r);
    }
    for i in 0..2 {
        bf(t, 4 + 3 * i, 5 + i, 48 - 32 * i as i32, true);
    }
    for i in 0..2 {
        for j in 0..2 {
            hf(t, 4 * j + i, 2 + 4 * j + i, false, r);
        }
    }
    for i in 0..2 {
        bf(t, 2 + 4 * i, 3 + 4 * i, 32, true);
    }
    iadst_out_perm(t, 3);
}

fn iadst16(t: &mut [i32; 64], r: u32) {
    iadst_in_perm(t, 4);
    for i in 0..8 {
        bf(t, 2 * i, 2 * i + 1, 62 - 8 * i as i32, true);
    }
    for i in 0..8 {
        hf(t, i, 8 + i, false, r);
    }
    for i in 0..2 {
        bf(t, 8 + 2 * i, 9 + 2 * i, 56 - 32 * i as i32, true);
        bf(t, 13 + 2 * i, 12 + 2 * i, 8 + 32 * i as i32, true);
    }
    for i in 0..4 {
        for j in 0..2 {
            hf(t, 8 * j + i, 4 + 8 * j + i, false, r);
        }
    }
    for i in 0..2 {
        for j in 0..2 {
            bf(t, 4 + 8 * j + 3 * i, 5 + 8 * j + i, 48 - 32 * i as i32, true);
        }
    }
    for i in 0..2 {
        for j in 0..4 {
            hf(t, 4 * j + i, 2 + 4 * j + i, false, r);
        }
    }
    for i in 0..4 {
        bf(t, 2 + 4 * i, 3 + 4 * i, 32, true);
    }
    iadst_out_perm(t, 4);
}

fn iidentity(t: &mut [i32; 64], n: u32) {
    for v in &mut t[..1 << n] {
        *v = match n {
            2 => round2_64(*v as i64 * 5793, 12) as i32,
            3 => v.wrapping_mul(2),
            4 => round2_64(*v as i64 * 11586, 12) as i32,
            _ => v.wrapping_mul(4),
        };
    }
}

/// av1g_inv_1d: the `kind` (DCT, ADST, identity) inverse transform of 2^n points, range r.
fn inv_1d(t: &mut [i32; 64], kind: usize, n: u32, r: u32) {
    match kind {
        K_DCT => idct(t, n, r),
        K_ADST if n == 2 => iadst4(t),
        K_ADST if n == 3 => iadst8(t, r),
        K_ADST => iadst16(t, r),
        _ => iidentity(t, n),
    }
}

/// av1g_row_kind: the 1-D kind of a tx type's row (horizontal) pass.
fn row_kind(t: i32) -> usize {
    match t {
        DCT_DCT | ADST_DCT | FLIPADST_DCT | H_DCT => K_DCT,
        DCT_ADST | ADST_ADST | DCT_FLIPADST | FLIPADST_FLIPADST | ADST_FLIPADST | FLIPADST_ADST | H_ADST
        | H_FLIPADST => K_ADST,
        _ => K_IDT,
    }
}

/// av1g_col_kind: the column (vertical) pass's.
fn col_kind(t: i32) -> usize {
    match t {
        DCT_DCT | DCT_ADST | DCT_FLIPADST | V_DCT => K_DCT,
        ADST_DCT | ADST_ADST | FLIPADST_DCT | FLIPADST_FLIPADST | ADST_FLIPADST | FLIPADST_ADST | V_ADST
        | V_FLIPADST => K_ADST,
        _ => K_IDT,
    }
}

/// Gauss-Jordan inverse of the n x n matrix `a`, with partial pivoting (the row updates contract
/// as the C++'s do, see [`fmac`]).
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

/// cost_field over every field: -log2 of each symbol's probability, in bits.
fn costs_of(c: &Cdfs, out: &mut [f32]) {
    let w = c.words();
    for (off, l, count) in Cdfs::arrays() {
        for b in (0..l * count).step_by(l) {
            let p = &w[off + b..off + b + l];
            for s in 0..l - 1 {
                let lo = if s > 0 { p[s - 1] as f64 } else { 0.0 };
                let hi = p[s] as f64;
                let pr = ((hi - lo) / 32768.0).max(1.0 / 32768.0);
                out[off + b + s] = -pr.log2() as f32;
            }
        }
    }
}

/// printf's `%a` of a double (macOS libc): `0x1.<hex digits without trailing zeros>p<exponent>`.
pub(super) fn hexf(s: &mut String, v: f64) {
    let bits = v.to_bits();
    if bits >> 63 != 0 {
        s.push('-');
    }
    let e = ((bits >> 52) & 0x7ff) as i32;
    let mut m = bits & ((1u64 << 52) - 1);
    if e == 0 && m == 0 {
        s.push_str("0x0p+0");
        return;
    }
    // floats widened to double are never subnormal or infinite
    debug_assert!(e != 0 && e != 0x7ff);
    s.push_str("0x1");
    if m != 0 {
        s.push('.');
        let mut digits = 13;
        while m & 15 == 0 {
            m >>= 4;
            digits -= 1;
        }
        let _ = write!(s, "{m:0digits$x}");
    }
    let _ = write!(s, "p{:+}", e - 1023);
}

fn floats(s: &mut String, decl: &str, v: &[f32], attr: &str) {
    s.push_str("constant float ");
    s.push_str(decl);
    s.push_str(attr);
    s.push_str(" = {");
    float_list(s, v);
    s.push_str("};\n");
}

fn float_list(s: &mut String, v: &[f32]) {
    for (i, &x) in v.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        hexf(s, x as f64);
        s.push('f');
    }
}

/// av1enc_tables_msl: the encoder's derived tables as Metal source (`constant` arrays the kernels
/// index), byte-identical to the C++'s.
pub fn tables_msl() -> String {
    // forward matrices
    let mut fwd = vec![0f32; GP_FWD_FLOATS];
    let mut fwd_t = vec![0f32; GP_FWD_FLOATS];
    let mut fwd_off = [[0i32; 7]; 3];
    let mut norm2 = [[0f64; 7]; 3];
    let mut at = 0;
    for k in 0..3 {
        for ln in 2..=6u32 {
            if (k == K_ADST && ln > 4) || (k == K_IDT && ln > 5) {
                continue;
            }
            let n = 1usize << ln;
            let mut m = vec![0f64; n * n];
            const A: i32 = 1 << 14;
            let mut nn = 0.0;
            for j in 0..n {
                let mut t = [0i32; 64];
                t[j] = A;
                inv_1d(&mut t, k, ln, 31);
                for i in 0..n {
                    let v = t[i] as f64 / A as f64;
                    m[i * n + j] = v;
                    nn = fmac(v, v, nn);
                }
            }
            norm2[k][ln as usize] = nn / n as f64;
            let f = invert(m, n);
            fwd_off[k][ln as usize] = at as i32;
            for i in 0..n * n {
                fwd[at + i] = f[i] as f32;
            }
            for i in 0..n {
                for j in 0..n {
                    fwd_t[at + j * n + i] = fwd[at + i * n + j];
                }
            }
            at += n * n;
        }
    }
    assert_eq!(at, GP_FWD_FLOATS);
    let mut txg = [[0f32; 16]; 19];
    let mut tx_scale = [0f32; 19];
    for t in 0..19 {
        let (lw, lh) = (Tx_Width_Log2[t] as usize, Tx_Height_Log2[t] as usize);
        let rect = if lw.abs_diff(lh) == 1 { 2896.0 / 4096.0 } else { 1.0 };
        let s = (1u32 << (Transform_Row_Shift[t] + 4)) as f64;
        tx_scale[t] = (s / rect) as f32;
        for ty in 0..16 {
            let (nr, nc) = (norm2[row_kind(ty)][lw], norm2[col_kind(ty)][lh]);
            txg[t][ty as usize] = if nr == 0.0 || nc == 0.0 {
                0.0 // illegal combination (e.g. ADST64)
            } else {
                (rect * rect * nr * nc / (s * s)) as f32
            };
        }
    }
    // symbol costs per coefficient q context
    let mut costs = vec![0f32; 4 * NCDF];
    let qrep = [20, 60, 120, 255];
    let mut avg_y = [0f32; 13];
    let mut avg_part = [[20f32; 10]; 5];
    let mut avg_skip0 = 0f32;
    for (qc, &q) in qrep.iter().enumerate() {
        let c = Cdfs::new(q);
        costs_of(&c, &mut costs[qc * NCDF..][..NCDF]);
        if qc == 0 {
            let prob =
                |cd: &[u16], m: usize| (cd[m] as i32 - if m > 0 { cd[m - 1] as i32 } else { 0 }) as f64 / 32768.0;
            for (m, y) in avg_y.iter_mut().enumerate() {
                let mut p = 0.0;
                for cd in c.y_mode.as_flattened() {
                    p += prob(cd, m);
                }
                *y = -(p / 25.0).max(1e-6).log2() as f32;
            }
            for bsl in 1..=4 {
                let n = if bsl == 1 { 4 } else { 10 };
                for p in 0..n {
                    let mut pr = 0.0;
                    for ctx in 0..4 {
                        let cd: &[u16] = match bsl {
                            1 => &c.partition_w8[ctx],
                            2 => &c.partition_w16[ctx],
                            3 => &c.partition_w32[ctx],
                            _ => &c.partition_w64[ctx],
                        };
                        pr += prob(cd, p);
                    }
                    avg_part[bsl][p] = -(pr / 4.0).max(1e-6).log2() as f32;
                }
            }
            let mut ps = 0.0;
            for ctx in 0..3 {
                ps += c.skip[ctx][0] as f64 / 32768.0;
            }
            avg_skip0 = -(ps / 3.0).log2() as f32;
        }
    }
    let mut s = String::with_capacity(1 << 20);
    s.push_str("// av1enc_tables_msl: the encoder's derived tables (AV1Encoder/src/tables.cpp)\n");
    let _ = writeln!(s, "#define GP_FWD_FLOATS {GP_FWD_FLOATS}");
    floats(&mut s, "g_fwd[GP_FWD_FLOATS]", &fwd, "");
    floats(&mut s, "g_fwdT[GP_FWD_FLOATS]", &fwd_t, " __attribute__((aligned(16)))"); // float4 loads
    s.push_str("constant int g_fwdOff[3][7] = {");
    for (i, v) in fwd_off.as_flattened().iter().enumerate() {
        let _ = write!(s, "{}{v}", if i > 0 { "," } else { "" });
    }
    s.push_str("};\n");
    floats(&mut s, "g_txg[19][16]", txg.as_flattened(), "");
    floats(&mut s, "g_txScale[19]", &tx_scale, "");
    let _ = write!(s, "constant float g_cost[4][{NCDF}] = {{");
    float_list(&mut s, &costs);
    s.push_str("};\n");
    floats(&mut s, "g_avgYMode[13]", &avg_y, "");
    floats(&mut s, "g_avgPart[5][10]", avg_part.as_flattened(), "");
    s.push_str("constant float g_avgSkip0 = ");
    hexf(&mut s, avg_skip0 as f64);
    s.push_str("f;\n");
    s
}
