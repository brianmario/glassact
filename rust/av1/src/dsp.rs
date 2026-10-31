//! The decoder-mirroring math of the AV1 spec (Sources/AV1Core/include/av1g/dsp.h), 8-bit only:
//!
//! - [`dequant`]: spec 7.12.3 step 1 (with quantizer matrices, `& 0xFFFFFF`, the clamps);
//! - [`qm`], [`qm_step`], [`qm_level_allintra`]: quantizer-matrix weights (also for forward
//!   quantizers);
//! - [`inv_txfm2d`]: spec 7.13.3 (16 types, 19 sizes) with the conformance range checks (the
//!   returned [`ERR_B_RANGE`] / [`ERR_ADST4_RANGE`] flags);
//! - [`add_residual`]: spec 7.12.3 step 3 (flips, Clip1);
//! - [`build_edges`]: spec 7.11.2 AboveRow / LeftCol;
//! - [`predict_intra`]: DC, directional, smooth*, paeth (edge filter off);
//! - [`predict_intra_ex`]: with the intra edge filter / upsampling, and filter intra;
//! - [`cfl_predict`]: spec 7.11.5;
//! - [`predict_inter`]: spec 7.11.3.3 / 7.11.3.4, block inter prediction from one unscaled
//!   reference (NEON filters; [`predict_inter_ref`] is the spec's loops).
//!
//! Edge arrays are [`Edge`]s: `AboveRow[k]` / `LeftCol[k]` live at index `EDGE_OFF + k` (k >= -2).
//!
//! The inverse transforms, dequantization and the block predictors (directional rows, SMOOTH*,
//! PAETH) have NEON paths (aarch64); the transforms also an SSE4.1 path (x86_64, runtime detection).
//! The scalar code is the reference; `*_scalar` / `*_ref` functions stay public for tests and
//! benchmarks.
#![allow(clippy::too_many_arguments, clippy::needless_range_loop)]

use crate::tables::*;

#[cfg(target_arch = "aarch64")]
mod dequant_neon;
mod itx;
#[cfg(target_arch = "aarch64")]
mod itx_neon;
#[cfg(target_arch = "x86_64")]
mod itx_sse;
mod mc;
mod pred;
#[cfg(target_arch = "aarch64")]
mod pred_neon;
#[cfg(test)]
mod tests;

pub use itx::*;
pub use mc::*;
pub use pred::*;

/// Butterfly output outside r bits (7.13.2.1).
pub const ERR_B_RANGE: u32 = 1;
/// ADST4 intermediates outside their range (7.13.2.6).
pub const ERR_ADST4_RANGE: u32 = 2;

#[inline(always)]
pub fn clip3(lo: i32, hi: i32, x: i32) -> i32 {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}
#[inline(always)]
pub fn clip1(x: i32) -> i32 {
    x.clamp(0, 255)
}
/// Round2 for n >= 0 with arithmetic shift (spec 4.7).
#[inline(always)]
pub fn round2(x: i32, n: i32) -> i32 {
    if n == 0 { x } else { x.wrapping_add(1 << (n - 1)) >> n }
}
#[inline(always)]
pub fn round2_64(x: i64, n: i32) -> i64 {
    if n == 0 {
        x
    } else {
        x.wrapping_add(1i64 << (n - 1)) >> n
    }
}
#[inline(always)]
pub fn round2signed(x: i32, n: i32) -> i32 {
    if x >= 0 {
        round2(x, n)
    } else {
        round2(x.wrapping_neg(), n).wrapping_neg()
    }
}

// ---- transform size helpers ----

#[inline(always)]
pub fn tx_w(tx_sz: i32) -> i32 {
    Tx_Width[tx_sz as usize] as i32
}
#[inline(always)]
pub fn tx_h(tx_sz: i32) -> i32 {
    Tx_Height[tx_sz as usize] as i32
}

/// get_tx_set() for intra blocks (spec 5.11.48).
pub fn get_tx_set_intra(tx_sz: i32, reduced_tx_set: bool) -> i32 {
    let sqr = Tx_Size_Sqr[tx_sz as usize] as i32;
    let sqr_up = Tx_Size_Sqr_Up[tx_sz as usize] as i32;
    if sqr_up >= TX_32X32 {
        return TX_SET_DCTONLY;
    }
    if reduced_tx_set || sqr == TX_16X16 {
        return TX_SET_INTRA_2;
    }
    TX_SET_INTRA_1
}
#[inline]
pub fn tx_type_in_set_intra(set: i32, tx_type: i32) -> bool {
    Tx_Type_In_Set_Intra[set as usize][tx_type as usize] != 0
}

/// get_tx_set() for inter blocks (spec 5.11.48).
pub fn get_tx_set_inter(tx_sz: i32, reduced_tx_set: bool) -> i32 {
    let sqr = Tx_Size_Sqr[tx_sz as usize] as i32;
    let sqr_up = Tx_Size_Sqr_Up[tx_sz as usize] as i32;
    if sqr_up > TX_32X32 {
        return TX_SET_DCTONLY;
    }
    if reduced_tx_set || sqr_up == TX_32X32 {
        return TX_SET_INTER_3;
    }
    if sqr == TX_16X16 {
        return TX_SET_INTER_2;
    }
    TX_SET_INTER_1
}
#[inline]
pub fn tx_type_in_set_inter(set: i32, tx_type: i32) -> bool {
    Tx_Type_In_Set_Inter[set as usize][tx_type as usize] != 0
}

/// compute_tx_type() for an inter chroma tx block (spec 5.11.40, lossless excluded): the luma
/// type `luma_tx_type` at its co-located 4x4 if it is in the chroma size's inter set, else DCT_DCT.
pub fn chroma_tx_type_inter(uv_tx_sz: i32, luma_tx_type: i32, reduced_tx_set: bool) -> i32 {
    if Tx_Size_Sqr_Up[uv_tx_sz as usize] as i32 > TX_32X32 {
        return DCT_DCT;
    }
    let set = get_tx_set_inter(uv_tx_sz, reduced_tx_set);
    if tx_type_in_set_inter(set, luma_tx_type) {
        luma_tx_type
    } else {
        DCT_DCT
    }
}

/// compute_tx_type() for an intra chroma tx block (spec 5.11.40, lossless excluded).
pub fn chroma_tx_type(uv_tx_sz: i32, uv_mode: i32, reduced_tx_set: bool) -> i32 {
    if Tx_Size_Sqr_Up[uv_tx_sz as usize] as i32 > TX_32X32 {
        return DCT_DCT;
    }
    let set = get_tx_set_intra(uv_tx_sz, reduced_tx_set);
    let t = Mode_To_Txfm[uv_mode as usize] as i32;
    if tx_type_in_set_intra(set, t) { t } else { DCT_DCT }
}

/// get_tx_class.
pub fn tx_class(tx_type: i32) -> i32 {
    match tx_type {
        V_DCT | V_ADST | V_FLIPADST => TX_CLASS_VERT,
        H_DCT | H_ADST | H_FLIPADST => TX_CLASS_HORIZ,
        _ => TX_CLASS_2D,
    }
}

/// get_scan() (spec 5.11.41).
pub fn get_scan(tx_sz: i32, tx_type: i32) -> &'static [u16] {
    if tx_sz == TX_16X64 {
        return &Default_Scan_16x32;
    }
    if tx_sz == TX_64X16 {
        return &Default_Scan_32x16;
    }
    if Tx_Size_Sqr_Up[tx_sz as usize] as i32 == TX_64X64 {
        return &Default_Scan_32x32;
    }
    let cls = if tx_type == IDTX {
        TX_CLASS_2D
    } else {
        tx_class(tx_type)
    };
    if cls == TX_CLASS_VERT {
        // preferRow -> mrow
        return match tx_sz {
            TX_4X4 => &Mrow_Scan_4x4,
            TX_4X8 => &Mrow_Scan_4x8,
            TX_8X4 => &Mrow_Scan_8x4,
            TX_8X8 => &Mrow_Scan_8x8,
            TX_8X16 => &Mrow_Scan_8x16,
            TX_16X8 => &Mrow_Scan_16x8,
            TX_16X16 => &Mrow_Scan_16x16,
            TX_4X16 => &Mrow_Scan_4x16,
            _ => &Mrow_Scan_16x4,
        };
    }
    if cls == TX_CLASS_HORIZ {
        // preferCol -> mcol
        return match tx_sz {
            TX_4X4 => &Mcol_Scan_4x4,
            TX_4X8 => &Mcol_Scan_4x8,
            TX_8X4 => &Mcol_Scan_8x4,
            TX_8X8 => &Mcol_Scan_8x8,
            TX_8X16 => &Mcol_Scan_8x16,
            TX_16X8 => &Mcol_Scan_16x8,
            TX_16X16 => &Mcol_Scan_16x16,
            TX_4X16 => &Mcol_Scan_4x16,
            _ => &Mcol_Scan_16x4,
        };
    }
    match tx_sz {
        TX_4X4 => &Default_Scan_4x4,
        TX_4X8 => &Default_Scan_4x8,
        TX_8X4 => &Default_Scan_8x4,
        TX_8X8 => &Default_Scan_8x8,
        TX_8X16 => &Default_Scan_8x16,
        TX_16X8 => &Default_Scan_16x8,
        TX_16X16 => &Default_Scan_16x16,
        TX_16X32 => &Default_Scan_16x32,
        TX_32X16 => &Default_Scan_32x16,
        TX_4X16 => &Default_Scan_4x16,
        TX_16X4 => &Default_Scan_16x4,
        TX_8X32 => &Default_Scan_8x32,
        TX_32X8 => &Default_Scan_32x8,
        _ => &Default_Scan_32x32,
    }
}

// ---- quantizer (spec 7.12.2) ----

#[inline]
pub fn dc_q(b: i32) -> i32 {
    Dc_Qlookup[0][clip3(0, 255, b) as usize] as i32
}
#[inline]
pub fn ac_q(b: i32) -> i32 {
    Ac_Qlookup[0][clip3(0, 255, b) as usize] as i32
}

pub fn dq_denom(tx_sz: i32) -> i32 {
    match tx_sz {
        TX_32X32 | TX_16X32 | TX_32X16 | TX_16X64 | TX_64X16 => 2,
        TX_64X64 | TX_32X64 | TX_64X32 => 4,
        _ => 1,
    }
}

/// Dequantizes one coefficient (spec 7.12.3 step 1 c..f, no quantizer matrix).
#[inline(always)]
pub fn dequant_coef(quant: i32, q: i32, dq_denom: i32) -> i32 {
    let dq = quant.wrapping_mul(q);
    let a = dq.wrapping_abs() & 0xFFFFFF;
    let mut dq2 = a / dq_denom;
    if dq < 0 {
        dq2 = -dq2;
    }
    clip3(-(1 << 15), (1 << 15) - 1, dq2)
}

/// The weight matrix of a tx block (spec 7.12.3 step 1b), `tw x th` row-major (tw = min(32, w),
/// th = min(32, h)), or `None` when no matrix applies: `using_qmatrix` off, level 15 (flat), or a
/// tx type >= IDTX (IDTX, V_*, H_* are never weighted). `level` is qm_y for plane 0, qm_u / qm_v
/// for planes 1 / 2. Weights are in 1/32 units (32 = flat).
pub fn qm(using_qmatrix: bool, level: i32, plane: i32, tx_sz: i32, tx_type: i32) -> Option<&'static [u8]> {
    if !using_qmatrix || level >= 15 || tx_type >= IDTX {
        return None;
    }
    let off = Qm_Offset[tx_sz as usize] as usize;
    Some(&Quantizer_Matrix[level as usize][(plane > 0) as usize][off..off + tx_coeffs(tx_sz)])
}
/// q2 of one coefficient: the effective (pre-dqDenom) quantizer step at position `pos`.
#[inline(always)]
pub fn qm_step(q: i32, qm: Option<&[u8]>, pos: usize) -> i32 {
    match qm {
        Some(m) => round2(q * m[pos] as i32, 5),
        None => q,
    }
}

/// The QM level libaom uses for all-intra / tune=iq (port of aom_get_qmlevel_allintra,
/// av1/common/quant_common.h, libaom 3.13): 10 at qindex <= 40 down to 4 above 240. libaom applies
/// it to base_q_idx for luma and base_q_idx + DeltaQUAc for chroma.
pub fn qm_level_allintra(qindex: i32) -> i32 {
    const STEPS: [(i32, i32); 6] = [(40, 10), (100, 9), (160, 8), (200, 7), (220, 6), (240, 5)];
    STEPS.iter().find(|&&(q, _)| qindex <= q).map_or(4, |&(_, l)| l)
}

/// Number of coefficients stored for a tx size (tw * th, at most 32 x 32).
#[inline]
pub fn tx_coeffs(tx_sz: i32) -> usize {
    (tx_w(tx_sz).min(32) * tx_h(tx_sz).min(32)) as usize
}

/// Dequantizes a whole tx block: `quant` / `out` are th x tw row-major (tw, th <= 32).
/// `qm`: [`qm`] of the tx block, or `None`.
pub fn dequant(quant: &[i16], out: &mut [i32], tx_sz: i32, dc_q: i32, ac_q: i32, qm: Option<&[u8]>) {
    let n = tx_coeffs(tx_sz);
    let k = dq_denom(tx_sz).trailing_zeros(); // dqDenom is 1, 2 or 4
    let (quant, out) = (&quant[..n], &mut out[..n]);
    // dequant_coef without the division (|dq| >= 0, so / dqDenom is >> k) and without the
    // per-coefficient branch (a zero level dequantizes to 0 either way): the same values, and the
    // loops vectorize
    #[inline(always)]
    fn coef(quant: i16, q: i32, k: u32) -> i32 {
        let dq = (quant as i32).wrapping_mul(q);
        let a = (dq.wrapping_abs() & 0xFFFFFF) >> k;
        (if dq < 0 { -a } else { a }).clamp(-(1 << 15), (1 << 15) - 1)
    }
    #[cfg(target_arch = "aarch64")]
    if n >= 16 {
        dequant_neon::dequant(quant, out, ac_q, qm, k);
        out[0] = coef(quant[0], qm_step(dc_q, qm, 0), k);
        return;
    }
    match qm {
        None => {
            for (o, &q) in out.iter_mut().zip(quant) {
                *o = coef(q, ac_q, k);
            }
        }
        Some(m) => {
            for ((o, &q), &w) in out.iter_mut().zip(quant).zip(&m[..n]) {
                *o = coef(q, round2(ac_q * w as i32, 5), k);
            }
        }
    }
    out[0] = coef(quant[0], qm_step(dc_q, qm, 0), k);
}

/// A small xorshift generator for the tests and benchmarks (fixed seeds).
#[cfg(test)]
#[derive(Clone)]
pub(crate) struct Rng(pub u64);
#[cfg(test)]
impl Rng {
    pub fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 16) as u32
    }
    /// uniform in 0..n
    pub fn below(&mut self, n: u32) -> u32 {
        self.next() % n
    }
    pub fn range(&mut self, lo: i32, hi: i32) -> i32 {
        lo + (self.next() % ((hi - lo + 1) as u32)) as i32
    }
}
