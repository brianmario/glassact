//! Motion compensation: the spec's block inter prediction (7.11.3.3 motion vector scaling and
//! 7.11.3.4 block inter prediction) for one unscaled reference, single prediction, 8-bit:
//! [`predict_inter`] (fast paths, NEON on aarch64) and [`predict_inter_ref`] (the spec's loops,
//! the reference the tests hold it to).
//!
//! The position of a block of plane position (x, y) with motion `mv` (1/8 luma sample) is
//! `(x << 4) + ((2 * mv) >> sub)` in 1/16 sample: the spec's startX / 64 when the reference has the
//! frame's size. Samples outside the reference clamp to its edges (lastX / lastY). The filtering
//! is two passes, Round2(., InterRound0 = 3) then Round2(., InterRound1 = 11), then Clip1; a pass
//! whose position is whole is the identity tap (128), which the fast paths skip exactly:
//! - whole x and y: a copy;
//! - only x: Clip1(Round2(Round2(sum, 3), 4));
//! - only y: Clip1(Round2(sum, 7)) (the first pass is 16 * sample);
//! - both: the two passes.
use super::clip1;
use crate::tables::*;

#[cfg(target_arch = "aarch64")]
#[path = "mc_neon.rs"]
mod neon;

/// A reference plane: `w` x `h` samples (the reference frame's plane size: lastX + 1, lastY + 1)
/// at `stride`.
#[derive(Clone, Copy, Debug)]
pub struct RefPlane<'a> {
    pub data: &'a [u8],
    pub stride: usize,
    pub w: i32,
    pub h: i32,
}

/// The largest block: 64 x 64 luma.
pub const MC_MAX: usize = 64;
const WIN: usize = MC_MAX + 7;

/// [`predict_inter`]'s scratch: the edge-clamped source window and the first pass.
pub struct McScratch {
    patch: [u8; WIN * WIN],
    inter: [i16; WIN * MC_MAX],
}

impl Default for McScratch {
    fn default() -> Self {
        McScratch {
            patch: [0; WIN * WIN],
            inter: [0; WIN * MC_MAX],
        }
    }
}

/// The Subpel_Filters index of an interpolation filter for a block dimension (spec 7.11.3.4: the
/// 4-tap variants for blocks 4 or fewer samples across).
#[inline]
pub fn subpel_filter(filter: i32, size: usize) -> usize {
    if size <= 4 {
        match filter {
            EIGHTTAP | EIGHTTAP_SHARP => 4,
            EIGHTTAP_SMOOTH => 5,
            f => f as usize,
        }
    } else {
        filter as usize
    }
}

/// The block's position in 1/16 sample of the plane (x, y): the spec's startX >> 6 / startY >> 6
/// for an unscaled reference.
#[inline]
pub fn mc_position(x: i32, y: i32, mv: [i32; 2], sub: i32) -> (i32, i32) {
    ((x << 4) + ((2 * mv[1]) >> sub), (y << 4) + ((2 * mv[0]) >> sub))
}

/// The spec's block inter prediction, literally: predicts the `w` x `h` block at plane position
/// (`x`, `y`) of a plane with subsampling `sub` (0 luma, 1 chroma 4:2:0) from `r` with motion
/// `mv` = [row, col] (1/8 luma sample), into `dst` (Clip1). `filters`: the Subpel_Filters of the
/// horizontal and vertical passes, [`subpel_filter`] of the prediction block's width and height
/// (which a caller writing only part of a block passes for the whole block).
pub fn predict_inter_ref(
    r: &RefPlane,
    sub: i32,
    x: i32,
    y: i32,
    w: usize,
    h: usize,
    mv: [i32; 2],
    filters: [usize; 2],
    dst: &mut [u8],
    dst_stride: usize,
) {
    // 7.11.3.3, with RefUpscaledWidth = FrameWidth and RefFrameHeight = FrameHeight
    let scale = 1i64 << REF_SCALE_SHIFT;
    let half = 1i64 << (SUBPEL_BITS - 1);
    let orig_x = ((x as i64) << SUBPEL_BITS) + (((2 * mv[1]) >> sub) as i64) + half;
    let orig_y = ((y as i64) << SUBPEL_BITS) + (((2 * mv[0]) >> sub) as i64) + half;
    let base_x = orig_x * scale - (half << REF_SCALE_SHIFT);
    let base_y = orig_y * scale - (half << REF_SCALE_SHIFT);
    let off = (1i64 << (SCALE_SUBPEL_BITS - SUBPEL_BITS)) / 2;
    let sh = REF_SCALE_SHIFT + SUBPEL_BITS - SCALE_SUBPEL_BITS;
    let round2signed = |v: i64, n: i32| {
        if v >= 0 {
            (v + (1 << (n - 1))) >> n
        } else {
            -((-v + (1 << (n - 1))) >> n)
        }
    };
    let start_x = round2signed(base_x, sh) + off;
    let start_y = round2signed(base_y, sh) + off;
    let step = round2signed(scale, REF_SCALE_SHIFT - SCALE_SUBPEL_BITS);
    // 7.11.3.4
    let (last_x, last_y) = (r.w as i64 - 1, r.h as i64 - 1);
    let ih = ((((h as i64 - 1) * step + (1 << SCALE_SUBPEL_BITS) - 1) >> SCALE_SUBPEL_BITS) + 8) as usize;
    let fh = &Subpel_Filters[filters[0]];
    let fv = &Subpel_Filters[filters[1]];
    let mut inter = vec![0i32; ih * w];
    for rr in 0..ih {
        for c in 0..w {
            let p = start_x + step * c as i64;
            let mut s = 0i32;
            for t in 0..8 {
                let yy = ((start_y >> 10) + rr as i64 - 3).clamp(0, last_y) as usize;
                let xx = ((p >> 10) + t as i64 - 3).clamp(0, last_x) as usize;
                s += fh[((p >> 6) & SUBPEL_MASK as i64) as usize][t] as i32 * r.data[yy * r.stride + xx] as i32;
            }
            inter[rr * w + c] = (s + 4) >> 3;
        }
    }
    for rr in 0..h {
        for c in 0..w {
            let p = (start_y & 1023) + step * rr as i64;
            let mut s = 0i32;
            for t in 0..8 {
                s += fv[((p >> 6) & SUBPEL_MASK as i64) as usize][t] as i32 * inter[((p >> 10) as usize + t) * w + c];
            }
            dst[rr * dst_stride + c] = clip1((s + 1024) >> 11) as u8;
        }
    }
}

/// [`predict_inter_ref`]'s result, fast: whole-sample positions skip their pass, the source is
/// read in place when the block's window is inside the reference (else from an edge-clamped
/// copy), and the filters run on NEON vectors for blocks 8 or more wide.
pub fn predict_inter(
    r: &RefPlane,
    sub: i32,
    x: i32,
    y: i32,
    w: usize,
    h: usize,
    mv: [i32; 2],
    filters: [usize; 2],
    dst: &mut [u8],
    dst_stride: usize,
    s: &mut McScratch,
) {
    debug_assert!(w <= MC_MAX && h <= MC_MAX);
    let (px, py) = mc_position(x, y, mv, sub);
    let (ix, fx, iy, fy) = (px >> 4, (px & 15) as usize, py >> 4, (py & 15) as usize);
    let (mx, my) = ((fx != 0) as i32 * 3, (fy != 0) as i32 * 3);
    // the source window: the block, with 3 samples before and 4 after along a filtered axis
    let (wx0, wy0) = (ix - mx, iy - my);
    let (ww, wh) = (w + 7 * (fx != 0) as usize, h + 7 * (fy != 0) as usize);
    let inside = wx0 >= 0 && wy0 >= 0 && wx0 + ww as i32 <= r.w && wy0 + wh as i32 <= r.h;
    let (src, ss, base): (&[u8], usize, usize) = if inside {
        (r.data, r.stride, wy0 as usize * r.stride + wx0 as usize)
    } else {
        let p = &mut s.patch[..ww * wh];
        for (k, row) in p.chunks_exact_mut(ww).enumerate() {
            let yy = (wy0 + k as i32).clamp(0, r.h - 1) as usize;
            let line = &r.data[yy * r.stride..yy * r.stride + r.w as usize];
            if wx0 >= 0 && wx0 + ww as i32 <= r.w {
                row.copy_from_slice(&line[wx0 as usize..wx0 as usize + ww]);
            } else {
                for (c, v) in row.iter_mut().enumerate() {
                    *v = line[(wx0 + c as i32).clamp(0, r.w - 1) as usize];
                }
            }
        }
        (&s.patch[..], ww, 0)
    };
    match (fx != 0, fy != 0) {
        (false, false) => {
            for rr in 0..h {
                dst[rr * dst_stride..rr * dst_stride + w].copy_from_slice(&src[base + rr * ss..base + rr * ss + w]);
            }
        }
        (true, false) => {
            let f = &Subpel_Filters[filters[0]][fx];
            h_only(&src[base..], ss, w, h, f, dst, dst_stride);
        }
        (false, true) => {
            let f = &Subpel_Filters[filters[1]][fy];
            v_only(&src[base..], ss, w, h, f, dst, dst_stride);
        }
        (true, true) => {
            let f0 = &Subpel_Filters[filters[0]][fx];
            let f1 = &Subpel_Filters[filters[1]][fy];
            h_pass(&src[base..], ss, w, h + 7, f0, &mut s.inter);
            v_pass(&s.inter, w, h, f1, dst, dst_stride);
        }
    }
}

/// Horizontal only: `src` is the window's top-left (3 samples left of the block).
fn h_only(src: &[u8], ss: usize, w: usize, h: usize, f: &[i16; 8], dst: &mut [u8], ds: usize) {
    #[cfg(target_arch = "aarch64")]
    if w.is_multiple_of(8) {
        return neon::h_only(src, ss, w, h, f, dst, ds);
    }
    h_only_scalar(src, ss, w, h, f, dst, ds)
}

pub(crate) fn h_only_scalar(src: &[u8], ss: usize, w: usize, h: usize, f: &[i16; 8], dst: &mut [u8], ds: usize) {
    for r in 0..h {
        let s = &src[r * ss..];
        for c in 0..w {
            let sum: i32 = (0..8).map(|t| f[t] as i32 * s[c + t] as i32).sum();
            dst[r * ds + c] = clip1((((sum + 4) >> 3) + 8) >> 4) as u8;
        }
    }
}

/// Vertical only: `src` is the window's top-left (3 rows above the block).
fn v_only(src: &[u8], ss: usize, w: usize, h: usize, f: &[i16; 8], dst: &mut [u8], ds: usize) {
    #[cfg(target_arch = "aarch64")]
    if w.is_multiple_of(8) {
        return neon::v_only(src, ss, w, h, f, dst, ds);
    }
    v_only_scalar(src, ss, w, h, f, dst, ds)
}

pub(crate) fn v_only_scalar(src: &[u8], ss: usize, w: usize, h: usize, f: &[i16; 8], dst: &mut [u8], ds: usize) {
    for r in 0..h {
        for c in 0..w {
            let sum: i32 = (0..8).map(|t| f[t] as i32 * src[(r + t) * ss + c] as i32).sum();
            dst[r * ds + c] = clip1((sum + 64) >> 7) as u8;
        }
    }
}

/// The first pass of both: `rows` rows of Round2(sum, 3) into `inter` (stride `w`).
fn h_pass(src: &[u8], ss: usize, w: usize, rows: usize, f: &[i16; 8], inter: &mut [i16]) {
    #[cfg(target_arch = "aarch64")]
    if w.is_multiple_of(8) {
        return neon::h_pass(src, ss, w, rows, f, inter);
    }
    h_pass_scalar(src, ss, w, rows, f, inter)
}

pub(crate) fn h_pass_scalar(src: &[u8], ss: usize, w: usize, rows: usize, f: &[i16; 8], inter: &mut [i16]) {
    for r in 0..rows {
        let s = &src[r * ss..];
        for c in 0..w {
            let sum: i32 = (0..8).map(|t| f[t] as i32 * s[c + t] as i32).sum();
            inter[r * w + c] = ((sum + 4) >> 3) as i16;
        }
    }
}

/// The second pass of both: Clip1(Round2(sum, 11)).
fn v_pass(inter: &[i16], w: usize, h: usize, f: &[i16; 8], dst: &mut [u8], ds: usize) {
    #[cfg(target_arch = "aarch64")]
    if w.is_multiple_of(8) {
        return neon::v_pass(inter, w, h, f, dst, ds);
    }
    v_pass_scalar(inter, w, h, f, dst, ds)
}

pub(crate) fn v_pass_scalar(inter: &[i16], w: usize, h: usize, f: &[i16; 8], dst: &mut [u8], ds: usize) {
    for r in 0..h {
        for c in 0..w {
            let sum: i32 = (0..8).map(|t| f[t] as i32 * inter[(r + t) * w + c] as i32).sum();
            dst[r * ds + c] = clip1((sum + 1024) >> 11) as u8;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dsp::Rng;

    fn plane(r: &mut Rng, w: usize, h: usize, stride: usize, smooth: bool) -> Vec<u8> {
        let mut p = vec![0u8; stride * h];
        let mut v = r.below(256) as i32;
        for (i, x) in p.iter_mut().enumerate() {
            if smooth {
                v = clip1(v + r.range(-9, 9));
                *x = v as u8;
            } else {
                *x = r.next() as u8;
            }
            if i % stride >= w {
                *x = 0xEE; // outside the plane: never read
            }
        }
        p
    }

    /// The fast paths (in place and edge-clamped, every sub-sample position and filter, every
    /// block size from 2 to 64) equal the spec's loops: every 1/16 position a plane gets (luma's
    /// even ones: its MVs are 1/8 sample; chroma's all) along each axis with every filter,
    /// including the 4-tap ones of blocks 4 or fewer samples across.
    #[test]
    fn predict_inter_matches_ref() {
        let mut rng = Rng(0x5eed_1234);
        let mut s = Box::<McScratch>::default();
        let sizes = [2usize, 4, 8, 16, 32, 64];
        let mut n = [0u32; 4];
        // [sub][axis][filter][phase]
        let mut seen = [[[[0u32; 16]; 6]; 2]; 2];
        for it in 0..6000 {
            let (pw, ph) = (1 + rng.below(150) as usize, 1 + rng.below(150) as usize);
            let stride = pw + rng.below(9) as usize;
            let data = plane(&mut rng, pw, ph, stride, it % 3 == 0);
            let r = RefPlane {
                data: &data[..stride * (ph - 1) + pw],
                stride,
                w: pw as i32,
                h: ph as i32,
            };
            let (w, h) = (sizes[rng.below(6) as usize], sizes[rng.below(6) as usize]);
            let sub = rng.below(2) as i32;
            let filter = rng.below(4) as i32;
            let filters = if rng.below(4) == 0 {
                [rng.below(6) as usize, rng.below(6) as usize]
            } else {
                [subpel_filter(filter, w), subpel_filter(filter, h)]
            };
            let (x, y) = (rng.range(-8, pw as i32 + 8), rng.range(-8, ph as i32 + 8));
            let mv = if rng.below(4) == 0 {
                [rng.range(-2000, 2000), rng.range(-2000, 2000)]
            } else {
                [rng.range(-400, 400), rng.range(-400, 400)]
            };
            let mv = if rng.below(3) == 0 { mv.map(|v| v & !7) } else { mv };
            let (px, py) = mc_position(x, y, mv, sub);
            n[((px & 15 != 0) as usize) | (((py & 15 != 0) as usize) << 1)] += 1;
            seen[sub as usize][0][filters[0]][(px & 15) as usize] += 1;
            seen[sub as usize][1][filters[1]][(py & 15) as usize] += 1;
            let mut want = vec![0u8; 64 * 64];
            let mut got = vec![0u8; 64 * 64];
            predict_inter_ref(&r, sub, x, y, w, h, mv, filters, &mut want, 64);
            predict_inter(&r, sub, x, y, w, h, mv, filters, &mut got, 64, &mut s);
            assert!(
                want == got,
                "it {it}: {pw}x{ph} block {w}x{h} at ({x},{y}) mv {mv:?} sub {sub} filters {filters:?}"
            );
        }
        assert!(n.iter().all(|&k| k > 500), "{n:?}");
        for (sub, axes) in seen.iter().enumerate() {
            for (axis, filters) in axes.iter().enumerate() {
                for (f, phases) in filters.iter().enumerate() {
                    for (ph, &k) in phases.iter().enumerate() {
                        let possible = sub == 1 || ph % 2 == 0;
                        assert!(
                            (k > 0) == possible,
                            "sub {sub} axis {axis} filter {f} phase {ph}: {k} predictions"
                        );
                    }
                }
            }
        }
    }

    /// The NEON passes equal the scalar ones on random rows (any filter and position).
    #[test]
    fn mc_passes_simd_match_scalar() {
        let mut rng = Rng(77);
        for _ in 0..2000 {
            let w = 8 * (1 + rng.below(8) as usize);
            let h = 1 + rng.below(64) as usize;
            let ss = w + 7 + rng.below(5) as usize;
            let src: Vec<u8> = (0..ss * (h + 7)).map(|_| rng.next() as u8).collect();
            let f = &Subpel_Filters[rng.below(6) as usize][1 + rng.below(15) as usize];
            let (mut a, mut b) = (vec![0u8; w * h], vec![0u8; w * h]);
            h_only(&src, ss, w, h, f, &mut a, w);
            h_only_scalar(&src, ss, w, h, f, &mut b, w);
            assert_eq!(a, b);
            v_only(&src, ss, w, h, f, &mut a, w);
            v_only_scalar(&src, ss, w, h, f, &mut b, w);
            assert_eq!(a, b);
            let (mut ia, mut ib) = (vec![0i16; w * (h + 7)], vec![0i16; w * (h + 7)]);
            h_pass(&src, ss, w, h + 7, f, &mut ia);
            h_pass_scalar(&src, ss, w, h + 7, f, &mut ib);
            assert_eq!(ia, ib);
            v_pass(&ia, w, h, f, &mut a, w);
            v_pass_scalar(&ia, w, h, f, &mut b, w);
            assert_eq!(a, b);
        }
    }
}
