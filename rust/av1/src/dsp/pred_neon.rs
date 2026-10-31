//! NEON pieces of the block predictors: the directional interpolation row, the 8x8 byte transpose
//! (pAngle > 180), and SMOOTH* / PAETH. The same math as pred.rs's scalar code, 8 or 16 lanes.
use super::pred::*;
use super::*;
use core::arch::aarch64::*;

#[inline(always)]
fn ld8(s: &[u8]) -> uint8x8_t {
    let s = &s[..8];
    // SAFETY: 8 bytes.
    unsafe { vld1_u8(s.as_ptr()) }
}
#[inline(always)]
fn ld16(s: &[u8]) -> uint8x16_t {
    let s = &s[..16];
    // SAFETY: 16 bytes.
    unsafe { vld1q_u8(s.as_ptr()) }
}
#[inline(always)]
fn st8(d: &mut [u8], v: uint8x8_t) {
    let d = &mut d[..8];
    // SAFETY: 8 bytes.
    unsafe { vst1_u8(d.as_mut_ptr(), v) }
}
#[inline(always)]
fn st16(d: &mut [u8], v: uint8x16_t) {
    let d = &mut d[..16];
    // SAFETY: 16 bytes.
    unsafe { vst1q_u8(d.as_mut_ptr(), v) }
}

/// d[j] = Round2(e[j] * (32 - shift) + e[j + 1] * shift, 5); e has at least d.len() + 1 samples
/// (with 9 or more, short rows still take one vector). Tails reuse an overlapping vector: each lane
/// is computed on its own, so recomputing one gives the same bytes.
#[inline(always)]
pub(super) fn interp_row(d: &mut [u8], e: &[u8], shift: i32) {
    // SAFETY: NEON is part of the aarch64 baseline; memory goes through the checked ld/st helpers.
    unsafe {
        let n = d.len();
        let (a, b) = (vdup_n_u8((32 - shift) as u8), vdup_n_u8(shift as u8));
        let (aq, bq) = (vdupq_n_u8((32 - shift) as u8), vdupq_n_u8(shift as u8));
        let v8 = |j: usize| vrshrn_n_u16::<5>(vmlal_u8(vmull_u8(ld8(&e[j..]), a), ld8(&e[j + 1..]), b));
        if n < 8 {
            if e.len() >= 9 {
                let mut t = [0u8; 8];
                st8(&mut t, v8(0));
                d.copy_from_slice(&t[..n]);
            } else {
                interp_row_scalar(d, e, shift);
            }
            return;
        }
        let mut j = 0;
        while j + 16 <= n {
            let (x, y) = (ld16(&e[j..]), ld16(&e[j + 1..]));
            let lo = vmlal_u8(vmull_u8(vget_low_u8(x), a), vget_low_u8(y), b);
            let hi = vmlal_high_u8(vmull_high_u8(x, aq), y, bq);
            st16(&mut d[j..], vcombine_u8(vrshrn_n_u16::<5>(lo), vrshrn_n_u16::<5>(hi)));
            j += 16;
        }
        while j < n {
            let k = (j + 8).min(n) - 8;
            st8(&mut d[k..], v8(k));
            j = k + 8;
        }
    }
}

/// dst[i][j] = src[j * h + i], w and h multiples of 8.
pub(super) fn transpose8_into(src: &[u8], h: usize, w: usize, dst: &mut [u8], stride: usize) {
    // SAFETY: NEON is part of the aarch64 baseline; memory goes through the checked ld/st helpers.
    unsafe {
        for j0 in (0..w).step_by(8) {
            for i0 in (0..h).step_by(8) {
                let r: [uint8x8_t; 8] = core::array::from_fn(|r| ld8(&src[(j0 + r) * h + i0..]));
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
                let c = [
                    vtrn1_u32(v(b0), v(b4)),
                    vtrn1_u32(v(b1), v(b5)),
                    vtrn1_u32(v(b2), v(b6)),
                    vtrn1_u32(v(b3), v(b7)),
                    vtrn2_u32(v(b0), v(b4)),
                    vtrn2_u32(v(b1), v(b5)),
                    vtrn2_u32(v(b2), v(b6)),
                    vtrn2_u32(v(b3), v(b7)),
                ];
                for (k, &x) in c.iter().enumerate() {
                    st8(&mut dst[(i0 + k) * stride + j0..], vreinterpret_u8_u32(x));
                }
            }
        }
    }
}

/// SMOOTH*, PAETH of a whole block (as pred.rs's nondirectional_scalar).
pub(super) fn nondirectional(
    mode: i32,
    log2w: i32,
    log2h: i32,
    above: &Edge,
    left: &Edge,
    dst: &mut [u8],
    stride: usize,
) {
    // SAFETY: NEON is part of the aarch64 baseline; memory goes through the checked ld/st helpers.
    unsafe {
        let (w, h) = (1usize << log2w, 1usize << log2h);
        if w < 8 {
            nondirectional_scalar(mode, log2w, log2h, above, left, dst, stride);
            return;
        }
        let a = &above[EDGE_OFF..EDGE_OFF + w];
        let l = &left[EDGE_OFF..EDGE_OFF + h];
        match mode {
            SMOOTH_PRED => {
                // Round2(p1 + p2, 9) == Round2((p1 + p2) >> 1, 8) for p1, p2 <= 255 * 256
                let (wx, wy) = (sm_weights(log2w), sm_weights(log2h));
                let (bl, tr) = (vdup_n_u8(l[h - 1]), vdup_n_u8(a[w - 1]));
                let mut colterm = [vdupq_n_u16(0); 8]; // (256 - wx[j]) * TopRight
                let mut wxv = [vdup_n_u8(0); 8];
                for c in 0..w / 8 {
                    wxv[c] = ld8(&wx[c * 8..]);
                    colterm[c] = vmull_u8(vsub_u8(vdup_n_u8(0), wxv[c]), tr);
                }
                for i in 0..h {
                    let wyi = wy[i];
                    let rowterm = vmull_u8(vdup_n_u8(0u8.wrapping_sub(wyi)), bl); // (256 - wy[i]) * BottomLeft
                    let (wyv, li) = (vdup_n_u8(wyi), vdup_n_u8(l[i]));
                    let d = &mut dst[i * stride..i * stride + w];
                    for c in 0..w / 8 {
                        let p1 = vmlal_u8(rowterm, ld8(&a[c * 8..]), wyv);
                        let p2 = vmlal_u8(colterm[c], wxv[c], li);
                        st8(&mut d[c * 8..], vrshrn_n_u16::<8>(vhaddq_u16(p1, p2)));
                    }
                }
            }
            SMOOTH_V_PRED => {
                let wy = sm_weights(log2h);
                let bl = vdup_n_u8(l[h - 1]);
                for i in 0..h {
                    let wyi = wy[i];
                    let rowterm = vmull_u8(vdup_n_u8(0u8.wrapping_sub(wyi)), bl);
                    let wyv = vdup_n_u8(wyi);
                    let d = &mut dst[i * stride..i * stride + w];
                    for c in 0..w / 8 {
                        st8(
                            &mut d[c * 8..],
                            vrshrn_n_u16::<8>(vmlal_u8(rowterm, ld8(&a[c * 8..]), wyv)),
                        );
                    }
                }
            }
            SMOOTH_H_PRED => {
                let wx = sm_weights(log2w);
                let tr = vdup_n_u8(a[w - 1]);
                let mut colterm = [vdupq_n_u16(0); 8];
                let mut wxv = [vdup_n_u8(0); 8];
                for c in 0..w / 8 {
                    wxv[c] = ld8(&wx[c * 8..]);
                    colterm[c] = vmull_u8(vsub_u8(vdup_n_u8(0), wxv[c]), tr);
                }
                for i in 0..h {
                    let li = vdup_n_u8(l[i]);
                    let d = &mut dst[i * stride..i * stride + w];
                    for c in 0..w / 8 {
                        st8(&mut d[c * 8..], vrshrn_n_u16::<8>(vmlal_u8(colterm[c], wxv[c], li)));
                    }
                }
            }
            _ => {
                // PAETH
                let tl = above[EDGE_OFF - 1];
                let tlv = vdupq_n_u8(tl);
                let tl2 = vdupq_n_u16(2 * tl as u16);
                for i in 0..h {
                    let li = vdupq_n_u8(l[i]);
                    let p_top = vabdq_u8(li, tlv); // |L - TL|
                    let d = &mut dst[i * stride..i * stride + w];
                    let mut j = 0;
                    while j < w {
                        // 16 lanes when w >= 16, else the low 8
                        let av = if w >= 16 {
                            ld16(&a[j..])
                        } else {
                            vcombine_u8(ld8(&a[j..]), vdup_n_u8(0))
                        };
                        let p_left = vabdq_u8(av, tlv); // |A - TL|
                        let s_lo = vabdq_u16(vaddl_u8(vget_low_u8(av), vget_low_u8(li)), tl2);
                        let s_hi = vabdq_u16(vaddl_high_u8(av, li), tl2);
                        let p_tl = vcombine_u8(vqmovn_u16(s_lo), vqmovn_u16(s_hi)); // |A + L - 2 TL|, saturated
                        // p_tl saturates at 255 only where it is > 255 > p_left, p_top: the comparisons hold
                        let use_l = vandq_u8(vcleq_u8(p_left, p_top), vcleq_u8(p_left, p_tl));
                        let use_a = vcleq_u8(p_top, p_tl);
                        let r = vbslq_u8(use_l, li, vbslq_u8(use_a, av, tlv));
                        if w >= 16 {
                            st16(&mut d[j..], r);
                            j += 16;
                        } else {
                            st8(&mut d[j..], vget_low_u8(r));
                            j += 8;
                        }
                    }
                }
            }
        }
    }
}
