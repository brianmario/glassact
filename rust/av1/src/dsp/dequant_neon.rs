//! NEON dequantization (spec 7.12.3 step 1), as dsp.rs's `dequant`.
use core::arch::aarch64::*;

/// Every coefficient with the AC quantizer (the caller redoes the DC), 8 at a time; n = quant.len()
/// is a multiple of 16; k = log2(dqDenom). q * level fits 32 bits (q <= 14567 with a matrix), and the
/// 16-bit clamp is a saturating narrow.
pub(super) fn dequant(quant: &[i16], out: &mut [i32], ac_q: i32, qm: Option<&[u8]>, k: u32) {
    // SAFETY: NEON is part of the aarch64 baseline; every load / store is of a whole 8-element chunk.
    unsafe {
        let mask = vdupq_n_s32(0xFFFFFF);
        let sh = vdupq_n_s32(-(k as i32));
        let half = |x: int32x4_t| {
            let a = vshlq_s32(vandq_s32(vabsq_s32(x), mask), sh);
            vbslq_s32(vcltzq_s32(x), vnegq_s32(a), a)
        };
        let n = quant.len();
        let (quant, out) = (quant.as_chunks::<8>().0, out[..n].as_chunks_mut::<8>().0);
        let qv = vdupq_n_s16(ac_q as i16);
        for (c, (q, o)) in quant.iter().zip(out.iter_mut()).enumerate() {
            let q = vld1q_s16(q.as_ptr());
            let step = match qm {
                None => qv,
                Some(m) => {
                    let m: &[u8; 8] = m[c * 8..c * 8 + 8].try_into().unwrap();
                    let w = vreinterpretq_s16_u16(vmovl_u8(vld1_u8(m.as_ptr())));
                    let lo = vrshrq_n_s32::<5>(vmull_n_s16(vget_low_s16(w), ac_q as i16));
                    let hi = vrshrq_n_s32::<5>(vmull_high_n_s16(w, ac_q as i16));
                    vcombine_s16(vmovn_s32(lo), vmovn_s32(hi))
                }
            };
            let lo = half(vmull_s16(vget_low_s16(q), vget_low_s16(step)));
            let hi = half(vmull_high_s16(q, step));
            vst1q_s32(o.as_mut_ptr(), vmovl_s16(vqmovn_s32(lo)));
            vst1q_s32(o.as_mut_ptr().add(4), vmovl_s16(vqmovn_s32(hi)));
        }
    }
}
