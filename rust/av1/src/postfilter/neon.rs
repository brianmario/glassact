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

/// constrain(), 16 lanes of u8, signed: `p` the taps, `x` the samples, `thr` the strength,
/// `nadj` = -dampingAdj (a right shift). |p - x| and every intermediate fit in u8 (the strength is
/// at most 15 at 8 bits, so the result is too), so this is cdef_constrain's integers exactly;
/// returned as i8 with the sign of p - x.
#[inline(always)]
fn constrain16(p: uint8x16_t, x: uint8x16_t, thr: uint8x16_t, nadj: int8x16_t) -> int8x16_t {
    // SAFETY: NEON is part of the aarch64 baseline; no memory access.
    unsafe {
        let a = vabdq_u8(p, x);
        let v = vminq_u8(a, vqsubq_u8(thr, vshlq_u8(a, nadj)));
        let neg = vreinterpretq_s8_u8(vcltq_u8(p, x)); // -1 where p < x
        vsubq_s8(veorq_s8(vreinterpretq_s8_u8(v), neg), neg)
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
    dy: usize,
    x0: usize,
    y0: usize,
    pri: i32,
    sec: i32,
    damping: i32,
    dir: i32,
) {
    // Every tap is within 2 rows and 2 columns of its sample (CDEF_DIRS), so the block reads
    // rows y0 - 2 ..= y0 + W + 1 and columns x0 - 2 ..= x0 + W + 1 of `src` (x0, y0 >= 2: the
    // caller's interior test), and writes rows y0 - dy .. y0 - dy + W, columns x0 .. x0 + W of
    // `dst`. Checked once here; the loads and stores are then unchecked.
    // (With a slice check per tap, 13 a row, each two compares on an offset reloaded from the
    // stack, the checks were most of the filter's instructions: BENCHMARKS, 2026-11-22.)
    assert!(x0 >= 2 && y0 >= 2 && y0 >= dy);
    assert!((y0 + W + 1) * ss + x0 + W + 2 <= src.len());
    assert!((y0 - dy + W - 1) * ds + x0 + W <= dst.len());
    // SAFETY: the block and its taps are inside `src` and its rows inside `dst` (asserted above).
    unsafe {
        let (c, d) = (
            src.as_ptr().add(y0 * ss + x0),
            dst.as_mut_ptr().add((y0 - dy) * ds + x0),
        );
        let n = core::ptr::null();
        // (the taps of a strength of 0 add nothing: skipped, and with them the clamp)
        match (pri != 0, sec != 0) {
            (true, true) => cdef_filter_raw::<W, false, true, true>(c, ss, n, d, ds, pri, sec, damping, dir),
            (true, false) => cdef_filter_raw::<W, false, true, false>(c, ss, n, d, ds, pri, sec, damping, dir),
            (false, true) => cdef_filter_raw::<W, false, false, true>(c, ss, n, d, ds, pri, sec, damping, dir),
            (false, false) => cdef_filter_raw::<W, false, false, false>(c, ss, n, d, ds, pri, sec, damping, dir),
        }
    }
}

/// [`cdef_filter`] of a block on the border ring: its neighbourhood copied into a padded 16 x 16
/// with a mask of the samples inside the filter region (is_inside_filter_region), and each tap
/// outside it taken as the sample itself, which adds nothing to the sum and leaves the maximum
/// and minimum as they are: as cdef_pixel's skipped taps.
#[inline(always)]
fn cdef_filter_border<const W: usize>(
    src: &[u8],
    ss: usize,
    dst: &mut [u8],
    ds: usize,
    dy: usize,
    (x0, y0): (i32, i32),
    (pw, ph): (i32, i32),
    pri: i32,
    sec: i32,
    damping: i32,
    dir: i32,
) {
    let (mut buf, mut ok) = ([0u8; 256], [0u8; 256]);
    for r in 0..W as i32 + 4 {
        for c in 0..W as i32 + 4 {
            let (y, x) = (y0 - 2 + r, x0 - 2 + c);
            let inside = y >= 0 && x >= 0 && y < ph && x < pw;
            // (the block's own samples are read even past the region, as cdef_pixel reads them)
            let own = (2..W as i32 + 2).contains(&r) && (2..W as i32 + 2).contains(&c);
            if inside || own {
                buf[(r * 16 + c) as usize] = src[y as usize * ss + x as usize];
            }
            ok[(r * 16 + c) as usize] = if inside { 0xFF } else { 0 };
        }
    }
    let mut out = [0u8; 64]; // (W x W)
    // SAFETY: buf and ok hold the block at (2, 2) with 2 samples all round (stride 16, W + 4 <= 16
    // columns and rows read); out holds its W rows of W.
    unsafe {
        cdef_filter_raw::<W, true, true, true>(
            buf.as_ptr().add(34),
            16,
            ok.as_ptr().add(34),
            out.as_mut_ptr(),
            W,
            pri,
            sec,
            damping,
            dir,
        )
    }
    for i in 0..W {
        let o = (y0 as usize + i - dy) * ds + x0 as usize;
        dst[o..o + W].copy_from_slice(&out[i * W..i * W + W]);
    }
}

/// The CDEF filter on 16 lanes of u8 (two rows of 8, or the 4x4's four rows of 4), the weighted
/// sums in two halves of i16. `c` is the block's first sample (stride `ss`), `dst` its first
/// output (stride `ds`); with MASKED, `mask` (stride `ss`, at the block's first sample) is 0xFF
/// where a tap may be read and 0 where cdef_pixel skips it.
///
/// # Safety
/// Rows -2 ..= W + 1 and columns -2 ..= W + 1 around `c` (and `mask`) are readable, and W rows of
/// W at `dst` writable.
#[inline(always)]
unsafe fn cdef_filter_raw<const W: usize, const MASKED: bool, const PRI: bool, const SEC: bool>(
    c: *const u8,
    ss: usize,
    mask: *const u8,
    dst: *mut u8,
    ds: usize,
    pri: i32,
    sec: i32,
    damping: i32,
    dir: i32,
) {
    // SAFETY: NEON is part of the aarch64 baseline; every load is a tap of the block, at most 2
    // rows and 2 columns out (CDEF_DIRS), and every store a row of the block: the caller's
    // promise.
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
        let pri_taps: [i8; 2] = if pri & 1 != 0 { [3, 3] } else { [4, 2] };
        let sec_taps: [i8; 2] = [2, 1];
        let (pt, st) = (vdupq_n_u8(pri as u8), vdupq_n_u8(sec as u8));
        let pa = vdupq_n_s8(-(cdef_damping_adj(pri, damping) as i8));
        let sa = vdupq_n_s8(-(cdef_damping_adj(sec, damping) as i8));
        let ld16 = |a: *const u8| -> uint8x16_t {
            if W == 8 {
                vcombine_u8(vld1_u8(a), vld1_u8(a.add(ss)))
            } else {
                let r = |k: usize| u32::from_le((a.add(k * ss) as *const u32).read_unaligned()) as u64;
                vcombine_u8(vcreate_u8(r(0) | r(1) << 32), vcreate_u8(r(2) | r(3) << 32))
            }
        };
        // 16 lanes: rows 2i and 2i + 1 of 8, or rows 0..4 of 4
        for i in 0..(if W == 8 { 4 } else { 1 }) {
            let row = c.add(2 * i * ss);
            let x = ld16(row);
            let load = |off: isize| -> uint8x16_t {
                let p = ld16(row.offset(off));
                if MASKED { vbslq_u8(ld16(mask.add(2 * i * ss).offset(off)), p, x) } else { p }
            };
            let (mut mx, mut mn) = (x, x);
            let (mut lo, mut hi) = (vdupq_n_s16(0), vdupq_n_s16(0));
            for k in 0..2 {
                for sign in [1isize, -1] {
                    if PRI {
                        let p = load(sign * po[k]);
                        let v = constrain16(p, x, pt, pa);
                        let w = vdup_n_s8(pri_taps[k]);
                        lo = vmlal_s8(lo, vget_low_s8(v), w);
                        hi = vmlal_high_s8(hi, v, vcombine_s8(w, w));
                        if SEC {
                            mx = vmaxq_u8(mx, p);
                            mn = vminq_u8(mn, p);
                        }
                    }
                    if SEC {
                        for &o in &so[k] {
                            let p = load(sign * o);
                            let v = constrain16(p, x, st, sa);
                            let w = vdup_n_s8(sec_taps[k]);
                            lo = vmlal_s8(lo, vget_low_s8(v), w);
                            hi = vmlal_high_s8(hi, v, vcombine_s8(w, w));
                            if PRI {
                                mx = vmaxq_u8(mx, p);
                                mn = vminq_u8(mn, p);
                            }
                        }
                    }
                }
            }
            // x + ((8 + sum - (sum < 0)) >> 4), clamped to [mn, mx] (in [0, 255], so narrowing
            // with saturation first gives the same bytes)
            let r = |sum: int16x8_t, x: uint8x8_t| -> uint8x8_t {
                let d = vshrq_n_s16::<4>(vaddq_s16(vaddq_s16(sum, vdupq_n_s16(8)), vreinterpretq_s16_u16(vcltzq_s16(sum))));
                vqmovun_s16(vaddq_s16(vreinterpretq_s16_u16(vmovl_u8(x)), d))
            };
            let v = vcombine_u8(r(lo, vget_low_u8(x)), r(hi, vget_high_u8(x)));
            // With one of the strengths 0, the taps' weights sum to 12, and the result stays
            // within the taps' range without the clamp: a positive sum is at most 12 D (D: the
            // largest p - x), and (8 + 12 D) >> 4 <= D; a negative one at least -12 D' (D': the
            // largest x - p), and (7 - 12 D') >> 4 >= -D'. dav1d skips the clamp there too.
            let v = if PRI && SEC { vminq_u8(vmaxq_u8(v, mn), mx) } else { v };
            let o = dst.add(2 * i * ds);
            if W == 8 {
                vst1_u8(o, vget_low_u8(v));
                vst1_u8(o.add(ds), vget_high_u8(v));
            } else {
                let q = vreinterpretq_u32_u8(v);
                (o as *mut u32).write_unaligned(vgetq_lane_u32::<0>(q).to_le());
                (o.add(ds) as *mut u32).write_unaligned(vgetq_lane_u32::<1>(q).to_le());
                (o.add(2 * ds) as *mut u32).write_unaligned(vgetq_lane_u32::<2>(q).to_le());
                (o.add(3 * ds) as *mut u32).write_unaligned(vgetq_lane_u32::<3>(q).to_le());
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
    cdef_rect(f, m, src, sstride, dst, dstride, 0, (0, f.mi_rows), (0, f.mi_cols));
}

/// [`super::cdef_rect`] in NEON.
#[allow(clippy::too_many_arguments)]
pub(super) fn cdef_rect(
    f: &PfFrame,
    m: &PfMaps,
    src: &[&[u8]; 3],
    sstride: &[usize; 3],
    dst: &mut [&mut [u8]; 3],
    dstride: &[usize; 3],
    dst_row: i32,
    (r0, r1): (i32, i32),
    (c0, c1): (i32, i32),
) {
    if cdef_rect_copy(f, m, src, sstride, dst, dstride, dst_row, (r0, r1), (c0, c1)) {
        return;
    }
    let (re, ce) = (r1.min(f.mi_rows), c1.min(f.mi_cols));
    for r in (r0..re).step_by(2) {
        for c in (c0..ce).step_by(2) {
            let idx = cdef_active_idx(f, m, r, c);
            let o = if cdef_quiet(f, idx) {
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
                let sub = f.sub(p);
                let (x0, y0, w) = ((c * 4) >> sub, (r * 4) >> sub, 8 >> sub);
                let dy = ((dst_row * 4) >> sub) as usize;
                let (s, ss, ds) = (src[p], sstride[p], dstride[p]);
                let d = &mut *dst[p];
                if !o.filtered {
                    for i in 0..w as usize {
                        let (a, b) = (
                            (y0 as usize + i) * ss + x0 as usize,
                            (y0 as usize - dy + i) * ds + x0 as usize,
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
                        cdef_filter::<8>(s, ss, d, ds, dy, x0, y0, pri, sec, damp, dir);
                    } else {
                        cdef_filter::<4>(s, ss, d, ds, dy, x0, y0, pri, sec, damp, dir);
                    }
                } else if w == 8 {
                    cdef_filter_border::<8>(s, ss, d, ds, dy, (x0, y0), (pw, ph), pri, sec, damp, dir);
                } else {
                    cdef_filter_border::<4>(s, ss, d, ds, dy, (x0, y0), (pw, ph), pri, sec, damp, dir);
                }
            }
        }
    }
}
