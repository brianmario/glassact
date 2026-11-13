//! NEON post-filters: CDEF on 8x8 / 4x4 blocks whose taps stay inside the frame (the border ring
//! takes the scalar per-sample path), the CDEF direction search, and deblocking of whole edge
//! columns / rows. Same arithmetic as the scalar reference, 8 lanes of i16.
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
/// 4 bytes at `a` and 4 at `b` as one vector.
#[inline(always)]
fn ld4x2(s: &[u8], a: usize, b: usize) -> uint8x8_t {
    let lo = u32::from_le_bytes(s[a..a + 4].try_into().unwrap()) as u64;
    let hi = u32::from_le_bytes(s[b..b + 4].try_into().unwrap()) as u64;
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe { vcreate_u8(lo | hi << 32) }
}
#[inline(always)]
fn st4x2(d: &mut [u8], a: usize, b: usize, v: uint8x8_t) {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    let x = unsafe { vget_lane_u64::<0>(vreinterpret_u64_u8(v)) };
    d[a..a + 4].copy_from_slice(&(x as u32).to_le_bytes());
    d[b..b + 4].copy_from_slice(&((x >> 32) as u32).to_le_bytes());
}

// ---------------- CDEF ----------------

/// The CDEF direction process (7.15.2), as [`cdef_direction`].
pub(super) fn cdef_direction_neon(src: &[u8], stride: usize) -> (i32, i32) {
    // SAFETY: NEON is part of the aarch64 baseline; memory goes through the checked ld8.
    unsafe {
        let z = vdupq_n_s16(0);
        let x: [int16x8_t; 8] = core::array::from_fn(|i| {
            vreinterpretq_s16_u16(vsubq_u16(vmovl_u8(ld8(&src[i * stride..])), vdupq_n_u16(128)))
        });
        // (lo, hi) = partial[0..8], partial[8..16]; adds v shifted up by s lanes
        macro_rules! acc {
            ($lo:ident, $hi:ident, $v:expr, $s:literal) => {{
                let v = $v;
                if $s == 0 {
                    $lo = vaddq_s16($lo, v);
                } else {
                    $lo = vaddq_s16($lo, vextq_s16::<{ (8 - $s) & 7 }>(z, v));
                    $hi = vaddq_s16($hi, vextq_s16::<{ (8 - $s) & 7 }>(v, z));
                }
            }};
        }
        let rev = |v: int16x8_t| {
            let r = vrev64q_s16(v);
            vextq_s16::<4>(r, r)
        };
        let pairs = |v: int16x8_t| vpaddq_s16(v, z); // [x0+x1, x2+x3, x4+x5, x6+x7, 0, 0, 0, 0]
        let (mut p0l, mut p0h, mut p4l, mut p4h) = (z, z, z, z);
        let (mut p1l, mut p1h, mut p3l, mut p3h) = (z, z, z, z);
        let (mut p5l, mut p5h, mut p7l, mut p7h) = (z, z, z, z);
        macro_rules! row {
            ($i:literal) => {{
                acc!(p0l, p0h, x[$i], $i); // partial[0][i + j]
                acc!(p4l, p4h, rev(x[$i]), $i); // partial[4][7 + i - j]
                acc!(p1l, p1h, pairs(x[$i]), $i); // partial[1][i + j / 2]
                // partial[3][3 + i - j / 2]: the pair sums reversed (vrev64 reverses the low half)
                acc!(p3l, p3h, vrev64q_s16(pairs(x[$i])), $i);
            }};
        }
        row!(0);
        row!(1);
        row!(2);
        row!(3);
        row!(4);
        row!(5);
        row!(6);
        row!(7);
        let y: [int16x8_t; 4] = core::array::from_fn(|a| vaddq_s16(x[2 * a], x[2 * a + 1]));
        acc!(p5l, p5h, y[0], 3); // partial[5][3 - i / 2 + j]
        acc!(p5l, p5h, y[1], 2);
        acc!(p5l, p5h, y[2], 1);
        acc!(p5l, p5h, y[3], 0);
        acc!(p7l, p7h, y[0], 0); // partial[7][i / 2 + j]
        acc!(p7l, p7h, y[1], 1);
        acc!(p7l, p7h, y[2], 2);
        acc!(p7l, p7h, y[3], 3);
        let p6 = x.iter().fold(z, |a, &v| vaddq_s16(a, v)); // partial[6][j]
        let p2: [i32; 8] = core::array::from_fn(|i| vaddlvq_s16(x[i])); // partial[2][i]
        // weighted sums of squares
        let sq = |v: int16x8_t, wl: &[i32; 4], wh: &[i32; 4]| -> i32 {
            let lo = vmulq_s32(vmull_s16(vget_low_s16(v), vget_low_s16(v)), vld1q_s32(wl.as_ptr()));
            let hi = vmulq_s32(vmull_high_s16(v, v), vld1q_s32(wh.as_ptr()));
            vaddvq_s32(vaddq_s32(lo, hi))
        };
        let d = &CDEF_DIV;
        // cost[0] / cost[4]: partial[k] weighted Div[k + 1] for k < 8, Div[15 - k] above
        let wa = ([d[1], d[2], d[3], d[4]], [d[5], d[6], d[7], d[8]]);
        let wb = ([d[7], d[6], d[5], d[4]], [d[3], d[2], d[1], 0]);
        // odd costs: 11 entries, Div[2], Div[4], Div[6], then Div[8] x 5, then Div[6], Div[4], Div[2]
        let wc = ([d[2], d[4], d[6], d[8]], [d[8], d[8], d[8], d[8]]);
        let wd = ([d[6], d[4], d[2], 0], [0, 0, 0, 0]);
        let w8 = [d[8]; 4];
        let mut cost = [0i32; 8];
        cost[0] = sq(p0l, &wa.0, &wa.1) + sq(p0h, &wb.0, &wb.1);
        cost[4] = sq(p4l, &wa.0, &wa.1) + sq(p4h, &wb.0, &wb.1);
        cost[1] = sq(p1l, &wc.0, &wc.1) + sq(p1h, &wd.0, &wd.1);
        cost[3] = sq(p3l, &wc.0, &wc.1) + sq(p3h, &wd.0, &wd.1);
        cost[5] = sq(p5l, &wc.0, &wc.1) + sq(p5h, &wd.0, &wd.1);
        cost[7] = sq(p7l, &wc.0, &wc.1) + sq(p7h, &wd.0, &wd.1);
        cost[6] = sq(p6, &w8, &w8);
        cost[2] = p2.iter().map(|&v| v * v).sum::<i32>() * d[8];
        let (mut best_cost, mut dir) = (0, 0);
        for (i, &c) in cost.iter().enumerate() {
            if c > best_cost {
                best_cost = c;
                dir = i;
            }
        }
        (dir as i32, (best_cost - cost[(dir + 4) & 7]) >> 10)
    }
}

/// constrain(), 8 lanes: `thr` the strength, `nadj` = -dampingAdj (a right shift).
#[inline(always)]
fn constrain(d: int16x8_t, thr: int16x8_t, nadj: int16x8_t) -> int16x8_t {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe {
        let a = vabsq_s16(d);
        let t = vmaxq_s16(vsubq_s16(thr, vshlq_s16(a, nadj)), vdupq_n_s16(0));
        let v = vminq_s16(a, t);
        vbslq_s16(vcltzq_s16(d), vnegq_s16(v), v)
    }
}

/// CDEF of one 8x8 (W = 8) or 4x4 (W = 4) block at (x0, y0) whose taps all lie inside `src`'s
/// filter region: as cdef_pixel for every sample.
#[inline(always)]
fn cdef_filter<const W: usize>(
    src: &[u8],
    ss: usize,
    dst: &mut [u8],
    ds: usize,
    x0: usize,
    y0: usize,
    pri: i32,
    sec: i32,
    damping: i32,
    dir: i32,
) {
    // SAFETY: NEON is part of the aarch64 baseline; memory goes through checked slices.
    unsafe {
        let dirs = |d: i32, k: usize| {
            let v = CDEF_DIRS[(d & 7) as usize][k];
            v[0] as isize * ss as isize + v[1] as isize
        };
        // tap offsets: primary (dir), secondary (dir - 2, dir + 2), for k = 0, 1
        let po = [dirs(dir, 0), dirs(dir, 1)];
        let so = [
            [dirs(dir - 2, 0), dirs(dir + 2, 0)],
            [dirs(dir - 2, 1), dirs(dir + 2, 1)],
        ];
        let pri_taps: [i16; 2] = if pri & 1 != 0 { [3, 3] } else { [4, 2] };
        let sec_taps: [i16; 2] = [2, 1];
        let (pt, st) = (vdupq_n_s16(pri as i16), vdupq_n_s16(sec as i16));
        let pa = vdupq_n_s16(-(cdef_damping_adj(pri, damping) as i16));
        let sa = vdupq_n_s16(-(cdef_damping_adj(sec, damping) as i16));
        // rows: 8 lanes = one row of 8, or two rows of 4
        let rows = if W == 8 { 8 } else { 2 };
        for i in 0..rows {
            let c = ((y0 + if W == 8 { i } else { 2 * i }) * ss + x0) as isize;
            let load = |off: isize| -> int16x8_t {
                let a = (c + off) as usize;
                let v = if W == 8 { ld8(&src[a..]) } else { ld4x2(src, a, a + ss) };
                vreinterpretq_s16_u16(vmovl_u8(v))
            };
            let x = load(0);
            let (mut mx, mut mn) = (x, x);
            let mut sum = vdupq_n_s16(0);
            for k in 0..2 {
                for sign in [1isize, -1] {
                    let p = load(sign * po[k]);
                    sum = vmlaq_n_s16(sum, constrain(vsubq_s16(p, x), pt, pa), pri_taps[k]);
                    mx = vmaxq_s16(mx, p);
                    mn = vminq_s16(mn, p);
                    for &o in &so[k] {
                        let p = load(sign * o);
                        sum = vmlaq_n_s16(sum, constrain(vsubq_s16(p, x), st, sa), sec_taps[k]);
                        mx = vmaxq_s16(mx, p);
                        mn = vminq_s16(mn, p);
                    }
                }
            }
            // x + ((8 + sum - (sum < 0)) >> 4), clamped to [mn, mx]
            let r = vshrq_n_s16::<4>(vaddq_s16(
                vaddq_s16(sum, vdupq_n_s16(8)),
                vreinterpretq_s16_u16(vcltzq_s16(sum)),
            ));
            let v = vminq_s16(vmaxq_s16(vaddq_s16(x, r), mn), mx);
            let v = vmovn_u16(vreinterpretq_u16_s16(v));
            let o = (y0 + if W == 8 { i } else { 2 * i }) * ds + x0;
            if W == 8 {
                st8(&mut dst[o..], v);
            } else {
                st4x2(dst, o, o + ds, v);
            }
        }
    }
}

/// [`cdef_frame`]: interior blocks in NEON, the border ring per sample.
pub(super) fn cdef_frame(
    f: &PfFrame,
    m: &PfMaps,
    src: &[&[u8]; 3],
    sstride: &[usize; 3],
    dst: &mut [&mut [u8]; 3],
    dstride: &[usize; 3],
) {
    for r in (0..f.mi_rows).step_by(2) {
        for c in (0..f.mi_cols).step_by(2) {
            let idx = cdef_active_idx(f, m, r, c);
            let o = if idx < 0 {
                CdefBlk::default()
            } else {
                let (s0, ss0) = (src[0], sstride[0]);
                let (y_dir, var) = cdef_direction_neon(&s0[(r * 4) as usize * ss0 + (c * 4) as usize..], ss0);
                cdef_params(f, idx, y_dir, var)
            };
            #[cfg(test)]
            if o.filtered {
                stat(6);
            }
            for p in 0..f.planes() {
                let sub = (p != 0) as i32;
                let (x0, y0, w) = ((c * 4) >> sub, (r * 4) >> sub, 8 >> sub);
                let (s, ss, ds) = (src[p], sstride[p], dstride[p]);
                let d = &mut *dst[p];
                if !o.filtered {
                    for i in 0..w as usize {
                        let (a, b) = (
                            (y0 as usize + i) * ss + x0 as usize,
                            (y0 as usize + i) * ds + x0 as usize,
                        );
                        d[b..b + w as usize].copy_from_slice(&s[a..a + w as usize]);
                    }
                    continue;
                }
                let (pri, sec, damp, dir) = if p == 0 {
                    (o.y_pri, o.y_sec, f.cdef_damping, o.y_dir)
                } else {
                    (o.uv_pri, o.uv_sec, f.cdef_damping - 1, o.uv_dir)
                };
                // the taps reach 2 samples out; the filter region is MiRows x MiCols luma 4x4s
                let (pw, ph) = ((f.mi_cols * 4) >> sub, (f.mi_rows * 4) >> sub);
                if x0 >= 2 && y0 >= 2 && x0 + w + 2 <= pw && y0 + w + 2 <= ph {
                    let (x0, y0) = (x0 as usize, y0 as usize);
                    if w == 8 {
                        cdef_filter::<8>(s, ss, d, ds, x0, y0, pri, sec, damp, dir);
                    } else {
                        cdef_filter::<4>(s, ss, d, ds, x0, y0, pri, sec, damp, dir);
                    }
                } else {
                    for i in 0..w {
                        for j in 0..w {
                            let (x, y) = (x0 + j, y0 + i);
                            d[y as usize * ds + x as usize] = cdef_pixel(f, s, ss, p, x, y, pri, sec, damp, dir) as u8;
                        }
                    }
                }
            }
        }
    }
}
