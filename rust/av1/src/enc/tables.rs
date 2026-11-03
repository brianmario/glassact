//! The encoder's derived tables as Metal source (Sources/AV1Encoder/src/tables.cpp,
//! av1enc_tables_msl): forward transform matrices, transform energy and scale factors, and symbol
//! costs from the default CDFs.
//!
//! The host half of av1gpu's encoder/src/k_misc.cu gp_init_tables (BSD-2), computed the same way.
//! The kernels are compiled at run time, so the tables become `constant` arrays in their source.
//! Floats are written as C99 hex literals (printf's `%a`), so the GPU sees exactly these values,
//! and the text is the C++'s byte for byte.
use super::fmac;
use crate::dsp::{K_ADST, K_IDT, col_kind, inv_1d, row_kind};
use crate::entropy::{Cdfs, NCDF};
use crate::tables::*;
use core::fmt::Write;

/// forward transform matrices: DCT 4..64, ADST 4..16, identity 4..32 (n x n each)
pub const GP_FWD_FLOATS: usize = (16 + 64 + 256 + 1024 + 4096) + (16 + 64 + 256) + (16 + 64 + 256 + 1024);

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
            if (k == K_ADST as usize && ln > 4) || (k == K_IDT as usize && ln > 5) {
                continue;
            }
            let n = 1usize << ln;
            let mut m = vec![0f64; n * n];
            const A: i32 = 1 << 14;
            let mut nn = 0.0;
            for j in 0..n {
                let mut t = [0i32; 64];
                t[j] = A;
                inv_1d(&mut t, k as i32, ln as i32, 31, &mut 0);
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
            let (nr, nc) = (norm2[row_kind(ty) as usize][lw], norm2[col_kind(ty) as usize][lh]);
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
