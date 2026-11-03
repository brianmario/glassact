//! NEON deblocking: 8 lines at a time (two 4-line edge segments, each with its own filter size),
//! every filter computed and blended by the per-lane masks of lf_line's branches. Vertical edges
//! transpose 8 rows; horizontal edges load rows directly. Segments that would reach past the plane
//! (the last chroma row / column of a 4-multiple plane) take the scalar lf_edge.
use super::*;
use core::arch::aarch64::*;

#[inline(always)]
fn ld8(s: &[u8]) -> uint8x8_t {
    let s = &s[..8];
    // SAFETY: 8 bytes.
    unsafe { vld1_u8(s.as_ptr()) }
}
#[inline(always)]
fn st8(d: &mut [u8], v: uint8x8_t) {
    let d = &mut d[..8];
    // SAFETY: 8 bytes.
    unsafe { vst1_u8(d.as_mut_ptr(), v) }
}

/// 8x8 byte transpose: out[c][r] = r[r][c].
#[inline(always)]
fn transpose8(r: [uint8x8_t; 8]) -> [uint8x8_t; 8] {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe {
        let a0 = vtrn1_u8(r[0], r[1]);
        let a1 = vtrn2_u8(r[0], r[1]);
        let a2 = vtrn1_u8(r[2], r[3]);
        let a3 = vtrn2_u8(r[2], r[3]);
        let a4 = vtrn1_u8(r[4], r[5]);
        let a5 = vtrn2_u8(r[4], r[5]);
        let a6 = vtrn1_u8(r[6], r[7]);
        let a7 = vtrn2_u8(r[6], r[7]);
        let u = vreinterpret_u16_u8;
        let b0 = vtrn1_u16(u(a0), u(a2));
        let b2 = vtrn2_u16(u(a0), u(a2));
        let b1 = vtrn1_u16(u(a1), u(a3));
        let b3 = vtrn2_u16(u(a1), u(a3));
        let b4 = vtrn1_u16(u(a4), u(a6));
        let b6 = vtrn2_u16(u(a4), u(a6));
        let b5 = vtrn1_u16(u(a5), u(a7));
        let b7 = vtrn2_u16(u(a5), u(a7));
        let v = vreinterpret_u32_u16;
        let w = vreinterpret_u8_u32;
        [
            w(vtrn1_u32(v(b0), v(b4))),
            w(vtrn1_u32(v(b1), v(b5))),
            w(vtrn1_u32(v(b2), v(b6))),
            w(vtrn1_u32(v(b3), v(b7))),
            w(vtrn2_u32(v(b0), v(b4))),
            w(vtrn2_u32(v(b1), v(b5))),
            w(vtrn2_u32(v(b2), v(b6))),
            w(vtrn2_u32(v(b3), v(b7))),
        ]
    }
}

struct Lim {
    limit: int16x8_t,
    blimit: int16x8_t,
    thresh: int16x8_t,
}

/// The wide filter of 7.14.6.4 with n taps each side (n2: the doubled ones, log2: the rounding):
/// F[i + n] for i = -n .. n-1. `s[8 + k]` is sample k (q0 = s[8], p0 = s[7]).
#[inline(always)]
fn wide<const N: isize, const N2: isize, const LOG2: i32>(s: &[int16x8_t; 16]) -> [int16x8_t; 12] {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe {
        let mut out = [vdupq_n_s16(0); 12];
        for i in -N..N {
            let mut t = vdupq_n_s16(1 << (LOG2 - 1));
            for j in -N..=N {
                let k = (i + j).clamp(-(N + 1), N);
                let v = s[(8 + k) as usize];
                t = vaddq_s16(t, v);
                if j.abs() <= N2 {
                    t = vaddq_s16(t, v);
                }
            }
            out[(i + N) as usize] = vshrq_n_s16::<LOG2>(t);
        }
        out
    }
}

/// lf_line on 8 lines at once: `s` holds p7..p0 (s[0..8]) and q0..q7 (s[8..16]) per lane; `fs` the
/// lane's filter size (0 = none). Only s[4..12] are read unless `any16` (then s[1..15]).
#[inline(always)]
fn filter8(s: &mut [int16x8_t; 16], fs: int16x8_t, chroma: bool, any16: bool, l: &Lim) {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe {
        let (p3, p2, p1, p0, q0, q1, q2, q3) = (s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11]);
        let ad = |a: int16x8_t, b: int16x8_t| vabdq_s16(a, b);
        let gt = |a: int16x8_t, b: int16x8_t| vcgtq_s16(a, b);
        let one = vdupq_n_s16(1);
        let ge8 = vcgeq_s16(fs, vdupq_n_s16(8)); // filterLen >= 6
        let len8 = if chroma { vdupq_n_u16(0) } else { ge8 }; // filterLen >= 8
        let mut bad = vorrq_u16(gt(ad(p1, p0), l.limit), gt(ad(q1, q0), l.limit));
        let e = vaddq_s16(vshlq_n_s16::<1>(ad(p0, q0)), vshrq_n_s16::<1>(ad(p1, q1)));
        bad = vorrq_u16(bad, gt(e, l.blimit));
        bad = vorrq_u16(
            bad,
            vandq_u16(ge8, vorrq_u16(gt(ad(p2, p1), l.limit), gt(ad(q2, q1), l.limit))),
        );
        bad = vorrq_u16(
            bad,
            vandq_u16(len8, vorrq_u16(gt(ad(p3, p2), l.limit), gt(ad(q3, q2), l.limit))),
        );
        bad = vorrq_u16(bad, vceqzq_s16(fs));
        let apply = vmvnq_u16(bad);
        if vmaxvq_u16(apply) == 0 {
            return;
        }
        let hev = vorrq_u16(gt(ad(p1, p0), l.thresh), gt(ad(q1, q0), l.thresh));
        let mut nf = vorrq_u16(
            vorrq_u16(gt(ad(p1, p0), one), gt(ad(q1, q0), one)),
            vorrq_u16(gt(ad(p2, p0), one), gt(ad(q2, q0), one)),
        );
        nf = vorrq_u16(nf, vandq_u16(len8, vorrq_u16(gt(ad(p3, p0), one), gt(ad(q3, q0), one))));
        let flat = vbicq_u16(ge8, nf);
        let mut flat2 = vdupq_n_u16(0);
        if any16 {
            let mut nf2 = vdupq_n_u16(0);
            for k in 1..4 {
                nf2 = vorrq_u16(nf2, vorrq_u16(gt(ad(s[k], p0), one), gt(ad(s[15 - k], q0), one)));
            }
            flat2 = vbicq_u16(vandq_u16(flat, vceqq_s16(fs, vdupq_n_s16(16))), nf2);
        }
        let narrow = vbicq_u16(apply, flat);
        let w16 = vandq_u16(apply, flat2);
        let wsmall = vbicq_u16(vandq_u16(apply, flat), flat2);
        // narrow filter (7.14.6.3)
        let mut r = *s;
        if vmaxvq_u16(narrow) != 0 {
            let c8 = |v: int16x8_t| vmaxq_s16(vminq_s16(v, vdupq_n_s16(127)), vdupq_n_s16(-128));
            let k128 = vdupq_n_s16(128);
            let (ps1, ps0, qs0, qs1) = (
                vsubq_s16(p1, k128),
                vsubq_s16(p0, k128),
                vsubq_s16(q0, k128),
                vsubq_s16(q1, k128),
            );
            let mut filt = vandq_s16(c8(vsubq_s16(ps1, qs1)), vreinterpretq_s16_u16(hev));
            filt = c8(vmlaq_n_s16(filt, vsubq_s16(qs0, ps0), 3));
            let f1 = vshrq_n_s16::<3>(c8(vaddq_s16(filt, vdupq_n_s16(4))));
            let f2 = vshrq_n_s16::<3>(c8(vaddq_s16(filt, vdupq_n_s16(3))));
            r[8] = vbslq_s16(narrow, vaddq_s16(c8(vsubq_s16(qs0, f1)), k128), r[8]);
            r[7] = vbslq_s16(narrow, vaddq_s16(c8(vaddq_s16(ps0, f2)), k128), r[7]);
            let fr = vrshrq_n_s16::<1>(f1);
            let nh = vbicq_u16(narrow, hev);
            r[9] = vbslq_s16(nh, vaddq_s16(c8(vsubq_s16(qs1, fr)), k128), r[9]);
            r[6] = vbslq_s16(nh, vaddq_s16(c8(vaddq_s16(ps1, fr)), k128), r[6]);
        }
        // wide filters (7.14.6.4)
        if vmaxvq_u16(wsmall) != 0 {
            if chroma {
                let o = wide::<2, 1, 3>(s);
                for i in 0..4 {
                    r[6 + i] = vbslq_s16(wsmall, o[i], r[6 + i]);
                }
            } else {
                let o = wide::<3, 0, 3>(s);
                for i in 0..6 {
                    r[5 + i] = vbslq_s16(wsmall, o[i], r[5 + i]);
                }
            }
        }
        if any16 && vmaxvq_u16(w16) != 0 {
            let o = wide::<6, 1, 4>(s);
            for i in 0..12 {
                r[2 + i] = vbslq_s16(w16, o[i], r[2 + i]);
            }
        }
        *s = r;
    }
}

/// The filter size of one segment (0 = none): lf_edge's checks.
#[inline(always)]
fn seg_fs(f: &PfFrame, m: &PfMaps, plane: usize, pass: usize, row: i32, col: i32) -> i32 {
    let (x, y) = (col * 4, row * 4);
    if row >= f.mi_rows || col >= f.mi_cols || x >= f.w || y >= f.h || (pass == 0 && x == 0) || (pass == 1 && y == 0) {
        return 0;
    }
    lf_filter_size(f, m, plane, pass, row, col).unwrap_or(0)
}

#[inline(always)]
fn widen(v: uint8x8_t) -> int16x8_t {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe { vreinterpretq_s16_u16(vmovl_u8(v)) }
}
#[inline(always)]
fn narrow(v: int16x8_t) -> uint8x8_t {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe { vqmovun_s16(v) }
}
#[inline(always)]
fn lanes(fs0: i32, fs1: i32) -> int16x8_t {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe { vcombine_s16(vdup_n_s16(fs0 as i16), vdup_n_s16(fs1 as i16)) }
}

fn deblock_plane(f: &PfFrame, m: &PfMaps, plane: usize, pl: &mut [u8], stride: usize) {
    let sub = (plane != 0) as i32;
    let chroma = plane != 0;
    let step = if chroma { 2 } else { 1 };
    let (pw, ph) = (((f.mi_cols * 4) >> sub) as usize, ((f.mi_rows * 4) >> sub) as usize);
    for pass in 0..2 {
        let Some((limit, blimit, thresh)) = lf_limits(f, plane, pass) else {
            continue;
        };
        // SAFETY: NEON is part of the aarch64 baseline; no memory access.
        let l = unsafe {
            Lim {
                limit: vdupq_n_s16(limit as i16),
                blimit: vdupq_n_s16(blimit as i16),
                thresh: vdupq_n_s16(thresh as i16),
            }
        };
        if pass == 0 {
            // vertical edges: segment rows (row, row + step) = 8 sample rows, transposed
            for row in (0..f.mi_rows).step_by(2 * step) {
                let y = ((row * 4) >> sub) as usize;
                if y + 8 > ph {
                    for col in (0..f.mi_cols).step_by(step) {
                        lf_edge(f, m, plane, 0, row, col, pl, stride);
                    }
                    continue;
                }
                for col in (step as i32..f.mi_cols).step_by(step) {
                    let (fs0, fs1) = (
                        seg_fs(f, m, plane, 0, row, col),
                        seg_fs(f, m, plane, 0, row + step as i32, col),
                    );
                    if fs0 == 0 && fs1 == 0 {
                        continue;
                    }
                    let x = ((col * 4) >> sub) as usize;
                    let any16 = fs0 == 16 || fs1 == 16;
                    let mut s = [unsafe_zero(); 16];
                    if any16 {
                        let lt = transpose8(core::array::from_fn(|i| ld8(&pl[(y + i) * stride + x - 8..])));
                        let rt = transpose8(core::array::from_fn(|i| ld8(&pl[(y + i) * stride + x..])));
                        for k in 0..8 {
                            s[k] = widen(lt[k]);
                            s[8 + k] = widen(rt[k]);
                        }
                    } else {
                        let t = transpose8(core::array::from_fn(|i| ld8(&pl[(y + i) * stride + x - 4..])));
                        for k in 0..8 {
                            s[4 + k] = widen(t[k]);
                        }
                    }
                    filter8(&mut s, lanes(fs0, fs1), chroma, any16, &l);
                    if any16 {
                        let lt = transpose8(core::array::from_fn(|k| narrow(s[k])));
                        let rt = transpose8(core::array::from_fn(|k| narrow(s[8 + k])));
                        for i in 0..8 {
                            st8(&mut pl[(y + i) * stride + x - 8..], lt[i]);
                            st8(&mut pl[(y + i) * stride + x..], rt[i]);
                        }
                    } else {
                        let t = transpose8(core::array::from_fn(|k| narrow(s[4 + k])));
                        for i in 0..8 {
                            st8(&mut pl[(y + i) * stride + x - 4..], t[i]);
                        }
                    }
                }
            }
        } else {
            // horizontal edges: segment columns (col, col + step) = 8 samples, rows as vectors
            for row in (step as i32..f.mi_rows).step_by(step) {
                let y = ((row * 4) >> sub) as usize;
                for col in (0..f.mi_cols).step_by(2 * step) {
                    let x = ((col * 4) >> sub) as usize;
                    if x + 8 > pw {
                        for c in (col..f.mi_cols).step_by(step) {
                            lf_edge(f, m, plane, 1, row, c, pl, stride);
                        }
                        continue;
                    }
                    let (fs0, fs1) = (
                        seg_fs(f, m, plane, 1, row, col),
                        seg_fs(f, m, plane, 1, row, col + step as i32),
                    );
                    if fs0 == 0 && fs1 == 0 {
                        continue;
                    }
                    let any16 = fs0 == 16 || fs1 == 16;
                    let mut s = [unsafe_zero(); 16];
                    let (k0, k1) = if any16 { (0, 16) } else { (4, 12) };
                    for k in k0..k1 {
                        s[k] = widen(ld8(&pl[(y + k - 8) * stride + x..]));
                    }
                    filter8(&mut s, lanes(fs0, fs1), chroma, any16, &l);
                    for k in k0..k1 {
                        st8(&mut pl[(y + k - 8) * stride + x..], narrow(s[k]));
                    }
                }
            }
        }
    }
}

#[inline(always)]
fn unsafe_zero() -> int16x8_t {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe { vdupq_n_s16(0) }
}

/// [`deblock_frame`] in NEON.
pub(super) fn deblock_frame(f: &PfFrame, m: &PfMaps, planes: &mut [&mut [u8]; 3], stride: &[usize; 3]) {
    if f.lf_level[0] == 0 && f.lf_level[1] == 0 {
        return;
    }
    for p in 0..f.planes() {
        if p > 0 && f.lf_level[1 + p] == 0 {
            continue;
        }
        deblock_plane(f, m, p, planes[p], stride[p]);
    }
}
