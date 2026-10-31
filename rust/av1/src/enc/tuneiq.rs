//! libaom v3.13.1 tune=iq decisions (all-intra, avifenc 1.4 defaults), from
//! Sources/AV1Encoder/include/av1f/tuneiq.h. Every function reproduces the cited libaom function
//! exactly (validated against libaom's own bitstreams).
//!
//! - frame level: [`tuneiq_frame_init`]: base qindex to chroma delta-q, QM levels, delta_q_res,
//!   deblocking levels and sharpness, CDEF damping/mode, rdmult
//! - SB level: [`varboost_qindex`] (variance to SB target qindex, av1_get_sbq_variance_boost),
//!   [`sb_variance`] (64 8x8 variances to the octile statistic), [`adjust_q`] (delta_q_res
//!   dead-zone rounding against the previous SB)
use super::fmac;
use crate::tables::{Aom_Ac_Qlookup, Aom_Dc_Qlookup};
use crate::types::{FrameParams, GaTuneiqFrame};

pub const VB_MAX_DELTAQ_RANGE: i32 = 80; // VAR_BOOST_MAX_DELTAQ_RANGE
pub const VB_MAX_BOOST: f64 = 8.0; // VAR_BOOST_MAX_BOOST
pub const QM_MIN_IQ: i32 = 2; // QM_FIRST_IQ_SSIMULACRA2
pub const QM_MAX_IQ: i32 = 10; // QM_LAST_IQ_SSIMULACRA2

#[inline]
pub fn clampi(v: i32, lo: i32, hi: i32) -> i32 {
    if v < lo {
        lo
    } else if v > hi {
        hi
    } else {
        v
    }
}

/// av1f_dc_q: libaom's 8-bit DC quantizer.
#[inline]
pub fn dc_q(qindex: i32) -> i32 {
    Aom_Dc_Qlookup[clampi(qindex, 0, 255) as usize] as i32
}

/// av1f_ac_q
#[inline]
pub fn ac_q(qindex: i32) -> i32 {
    Aom_Ac_Qlookup[clampi(qindex, 0, 255) as usize] as i32
}

/// avifenc 1.4 -q (tune=iq) to base_q_idx (libavif tuneIqQualityToQuantizer + libaom
/// quantizer_to_qindex).
pub fn qindex_for_quality(quality: i32) -> i32 {
    const QP: [u8; 101] = [
        63, 63, 63, 62, 62, 62, 61, 61, 60, 60, 59, 59, 58, 58, 57, 57, 56, 56, 55, 55, 54, 54, 53, 53, 52, 52, 51, 51,
        50, 50, 49, 49, 48, 48, 47, 46, 46, 45, 45, 44, 43, 43, 42, 42, 41, 40, 40, 39, 39, 38, 37, 37, 36, 36, 35, 34,
        33, 33, 32, 31, 30, 30, 29, 28, 27, 27, 26, 25, 24, 24, 23, 22, 21, 21, 20, 19, 18, 18, 17, 16, 15, 15, 14, 13,
        12, 12, 11, 10, 9, 9, 8, 7, 6, 6, 5, 4, 3, 3, 2, 1, 0,
    ];
    let p = QP[clampi(quality, 0, 100) as usize] as i32;
    if p == 63 {
        255
    } else if p == 62 {
        249
    } else {
        4 * p
    }
}

/// av1_set_quantizer(): tune=iq chroma delta-q, {u_dc, u_ac, v_dc, v_ac}. ssx/ssy = chroma
/// subsampling (libaom treats monochrome as 1/1).
pub fn chroma_delta_q(base: i32, ssx: i32, ssy: i32) -> [i32; 4] {
    let (mut dc, mut ac) = (0, 0);
    if base > 0 {
        if ssx == 1 && ssy == 1 {
            dc = -clampi(base / 2 - 14, 0, 16); // 4:2:0
            ac = dc;
        } else if ssx == 1 && ssy == 0 {
            ac = clampi(base / 2, 0, 6); // 4:2:2
        } else if ssx == 0 && ssy == 0 {
            ac = clampi(base / 2, 0, 24); // 4:4:4
        }
    }
    [dc, ac, dc, ac]
}

/// aom_get_qmlevel_allintra (quant_common.h)
pub fn qm_level_allintra(q: i32, first: i32, last: i32) -> i32 {
    let l = [(40, 10), (100, 9), (160, 8), (200, 7), (220, 6), (240, 5)]
        .iter()
        .find(|t| q <= t.0)
        .map_or(4, |t| t.1);
    clampi(l, first, last)
}

/// aom_get_qmlevel_444_chroma (quant_common.h)
pub fn qm_level_444_chroma(q: i32, first: i32, last: i32) -> i32 {
    let l = [(12, 10), (24, 9), (32, 8), (36, 7), (44, 6), (48, 5), (56, 4), (88, 3)]
        .iter()
        .find(|t| q <= t.0)
        .map_or(2, |t| t.1);
    clampi(l, first, last)
}

/// aom_get_variance_boost_delta_q_res (encodeframe.c): the resolution (1, 2, 4, 8).
pub fn delta_q_res(base: i32) -> i32 {
    if base >= 160 {
        8
    } else if base >= 120 {
        4
    } else if base >= 80 {
        2
    } else {
        1
    }
}

/// av1f_log2i: floor(log2(v)), 0 for v <= 1.
pub fn log2i(mut v: i32) -> i32 {
    let mut n = 0;
    while v > 1 {
        v >>= 1;
        n += 1;
    }
    n
}

/// av1_adjust_q_from_delta_q_res (rd.c)
pub fn adjust_q(res: i32, prev: i32, cur: i32) -> i32 {
    let cur = clampi(cur, res, 256 - res);
    let sign = if cur - prev >= 0 { 1 } else { -1 };
    let d = if cur - prev < 0 { prev - cur } else { cur - prev };
    let a = (d + res / 4) & !(res - 1);
    let q = prev + sign * a;
    if q < 1 { 1 } else { q }
}

/// av1_get_sbq_variance_boost (allintra_vis.c), in libaom's double arithmetic and evaluation
/// order (with the C++'s contraction of the boost ratio, see [`fmac`]).
pub fn varboost_qindex(base: i32, variance: u32, deltaq_strength_pct: i32) -> i32 {
    let strength = (deltaq_strength_pct as f64 / 100.0) * 3.0;
    let strength = strength.clamp(0.0, 6.0);
    let variance = if variance == 0 { 1 } else { variance };
    let ratio = fmac(0.15 * strength, -(variance as f64).log2() + 10.0, 1.0);
    let ratio = ratio.clamp(1.0, VB_MAX_BOOST);
    let base_q = ac_q(base) as f64 / 4.0; // av1_convert_qindex_to_q, 8-bit
    let target_q = base_q / ratio;
    let mut t = 0; // av1_convert_q_to_qindex
    while t < 255 && (ac_q(t) as f64 / 4.0) < target_q {
        t += 1;
    }
    let boost = ((base as f64 + 544.0) * (base - t) as f64 / 1279.0).round() as i32;
    let boost = boost.min(VB_MAX_DELTAQ_RANGE);
    let q = base - boost;
    if q < 1 { 1 } else { q }
}

/// av1_get_variance_boost_block_variance: `v` = aom_variance8x8(src, zeros) / 64 of the SB's 8x8
/// blocks (any order). Sorts in place; returns (v[31] + 2 v[39] + v[47] + 2) / 4.
pub fn sb_variance(v: &mut [u32; 64]) -> u32 {
    v.sort_unstable(); // the C++'s insertion sort; equal elements are indistinguishable
    v[31]
        .wrapping_add(2u32.wrapping_mul(v[39]))
        .wrapping_add(v[47])
        .wrapping_add(2)
        / 4
}

/// libaom 8x8 variance / 64 from the block's sum and sum of squares (aom_variance8x8_c).
pub fn var8x8_from_sums(sum: i32, sse: u32) -> u32 {
    sse.wrapping_sub(((sum as i64 * sum as i64) / 64) as u32) / 64
}

/// av1_compute_rd_mult_based_on_qindex(KF_UPDATE) with the tune=iq weight: cpi->rd.RDMULT.
pub fn frame_rdmult(base: i32) -> i32 {
    let q = dc_q(base);
    let r = q as i64 * q as i64;
    let r = (r as f64 * fmac(0.0015, q as f64, 3.3)) as i64;
    let w = clampi(((255 - base) * 3) / 4, 0, 72) + 128;
    let r = (r as f64 * w as f64 / 128.0) as i64;
    if r > 0 { r as i32 } else { 1 }
}

/// av1f_tuneiq_frame: all frame-level tune=iq decisions for a base qindex.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TuneiqFrame {
    pub base_q_idx: i32,
    /// chroma delta-q (separate_uv_delta_q = 0)
    pub dq_u_dc: i32,
    pub dq_u_ac: i32,
    pub dq_v_dc: i32,
    pub dq_v_ac: i32,
    /// using_qmatrix = 1
    pub qm_y: i32,
    pub qm_u: i32,
    pub qm_v: i32,
    /// 1/2/4/8 (the frame header codes log2)
    pub delta_q_res: i32,
    /// the EFFECTIVE deblocking level, all four the same; 0 = off
    pub lf_level: i32,
    pub lf_sharpness: i32,
    /// 3 + (base >> 6)
    pub cdef_damping: i32,
    /// 0: CDEF off (cq <= 32, one zero preset), 1: halved strengths (33..220), 2: full (> 220)
    pub cdef_mode: i32,
    /// the frame RDMULT (CDEF bits RD decision)
    pub rdmult: i32,
}

/// av1f_tuneiq_frame_init
pub fn tuneiq_frame_init(base: i32, ssx: i32, ssy: i32, mono: bool) -> TuneiqFrame {
    let mut dq = chroma_delta_q(base, ssx, ssy);
    if mono {
        dq = [0; 4]; // not coded for monochrome
    }
    let qm_y = qm_level_allintra(base, QM_MIN_IQ, QM_MAX_IQ);
    let cq = base + dq[1];
    let qm_uv = if ssx == 0 && ssy == 0 {
        qm_level_444_chroma(cq, QM_MIN_IQ, QM_MAX_IQ)
    } else {
        qm_level_allintra(cq, QM_MIN_IQ, QM_MAX_IQ)
    };
    // av1_pick_filter_level(LPF_PICK_FROM_Q), key frame, 8-bit; + INTRA ref delta (+1 << (lvl >> 5))
    let g = ac_q(base) as i64 * 17563 - 421574;
    let lvl = clampi(((g + (1 << 17)) >> 18) as i32, 0, 63);
    TuneiqFrame {
        base_q_idx: base,
        dq_u_dc: dq[0],
        dq_u_ac: dq[1],
        dq_v_dc: dq[2],
        dq_v_ac: dq[3],
        qm_y,
        qm_u: qm_uv,
        qm_v: qm_uv,
        delta_q_res: delta_q_res(base),
        lf_level: if lvl == 0 {
            0
        } else {
            clampi(lvl + (1 << (lvl >> 5)), 0, 63)
        },
        lf_sharpness: if base <= 120 {
            7 // sharpness 7, enable_adaptive_sharpness
        } else if base <= 160 {
            1
        } else {
            0
        },
        cdef_damping: 3 + (base >> 6),
        cdef_mode: if base <= 32 {
            0
        } else if base <= 220 {
            1
        } else {
            2
        },
        rdmult: frame_rdmult(base),
    }
}

/// av1enc_tuneiq_frame: the loop-filter decisions for 4:2:0 or monochrome.
pub fn tuneiq_frame(base_q_idx: i32, mono: bool) -> GaTuneiqFrame {
    let t = tuneiq_frame_init(base_q_idx, 1, 1, mono);
    GaTuneiqFrame {
        lf_level: t.lf_level,
        lf_sharpness: t.lf_sharpness,
        cdef_damping: t.cdef_damping,
        cdef_mode: t.cdef_mode,
        rdmult: t.rdmult,
    }
}

/// av1f_tuneiq_fill_fp: every frame-header decision of libaom tune=iq into `fp` (4:2:0 or
/// monochrome): base qindex, chroma delta-q, QM levels, deblocking from Q (effective levels) and
/// sharpness, CDEF damping with enable_cdef = 1 (presets, cdef_bits and per-SB cdef_idx come from
/// the strength search), and delta_q_res. delta_q_present is left to the caller (1 iff some SB
/// qindex != base).
pub fn tuneiq_fill_fp(fp: &mut FrameParams, base: i32, mono: bool) {
    let t = tuneiq_frame_init(base, 1, 1, mono);
    fp.base_q_idx = base as u8;
    fp.monochrome = mono as u8;
    fp.delta_q_y_dc = 0;
    fp.delta_q_u_dc = t.dq_u_dc as i8;
    fp.delta_q_u_ac = t.dq_u_ac as i8;
    fp.delta_q_v_dc = t.dq_v_dc as i8;
    fp.delta_q_v_ac = t.dq_v_ac as i8;
    fp.using_qmatrix = 1;
    fp.qm_y = t.qm_y as u8;
    fp.qm_u = t.qm_u as u8;
    fp.qm_v = t.qm_v as u8;
    fp.delta_q_res = log2i(t.delta_q_res) as u8;
    for (i, l) in fp.loop_filter_level.iter_mut().enumerate() {
        *l = if mono && i >= 2 { 0 } else { t.lf_level as u8 };
    }
    fp.loop_filter_sharpness = t.lf_sharpness as u8;
    fp.enable_cdef = 1;
    fp.cdef_damping_minus_3 = (t.cdef_damping - 3) as u8;
}
