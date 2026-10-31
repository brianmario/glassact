/* av1f/tuneiq.h - libaom v3.13.1 tune=iq decisions (all-intra, avifenc 1.4 defaults), header-only,
 * host + device.  Every function reproduces the cited libaom function exactly (validated against
 * libaom's own bitstreams).
 *
 *   frame level   av1f_tuneiq_frame_init()  base qindex -> chroma delta-q, QM levels, delta_q_res,
 *                                            deblocking levels + sharpness, CDEF damping/mode, rdmult
 *   SB level      av1f_varboost_qindex()    variance -> SB target qindex (av1_get_sbq_variance_boost)
 *                 av1f_sb_variance()        64 8x8 variances -> octile statistic
 *                 av1f_adjust_q()           delta_q_res dead-zone rounding against the previous SB
 * The GPU kernels in src/varboost.cu use these; engines (tracks B/C/E) only need the frame struct
 * and the per-SB qindex map that the kernel produces.
 *
 * Glass Act: av1gpu's av1f/include/av1f/tuneiq.h (BSD-2, Sources/AV1Core/LICENSE), unchanged; the
 * host uses the frame-level decisions (AV1MetalPostfilter's strength search).
 */
#ifndef AV1F_TUNEIQ_H
#define AV1F_TUNEIQ_H

#include <math.h>
#include <stdint.h>
#include "av1g/hd.h"
#include "av1g/decisions.h"
#include "av1f/aom_tables_gen.h"

#define AV1F_VB_MAX_DELTAQ_RANGE 80   /* VAR_BOOST_MAX_DELTAQ_RANGE */
#define AV1F_VB_MAX_BOOST 8.0         /* VAR_BOOST_MAX_BOOST */
#define AV1F_QM_MIN_IQ 2              /* QM_FIRST_IQ_SSIMULACRA2 */
#define AV1F_QM_MAX_IQ 10             /* QM_LAST_IQ_SSIMULACRA2 */

AV1G_HD int av1f_clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
AV1G_HD int av1f_dc_q(int qindex) { return AV1G_T(Aom_Dc_Qlookup)[av1f_clampi(qindex, 0, 255)]; }
AV1G_HD int av1f_ac_q(int qindex) { return AV1G_T(Aom_Ac_Qlookup)[av1f_clampi(qindex, 0, 255)]; }

/* avifenc 1.4 -q (tune=iq) -> base_q_idx (libavif tuneIqQualityToQuantizer + libaom quantizer_to_qindex) */
AV1G_HD int av1f_qindex_for_quality(int quality) {
    const uint8_t qp[101] = {63, 63, 63, 62, 62, 62, 61, 61, 60, 60, 59, 59, 58, 58, 57, 57, 56, 56, 55, 55, 54, 54, 53, 53, 52, 52,
                             51, 51, 50, 50, 49, 49, 48, 48, 47, 46, 46, 45, 45, 44, 43, 43, 42, 42, 41, 40, 40, 39, 39, 38, 37, 37,
                             36, 36, 35, 34, 33, 33, 32, 31, 30, 30, 29, 28, 27, 27, 26, 25, 24, 24, 23, 22, 21, 21, 20, 19, 18, 18,
                             17, 16, 15, 15, 14, 13, 12, 12, 11, 10, 9, 9, 8, 7, 6, 6, 5, 4, 3, 3, 2, 1, 0};
    const int p = qp[av1f_clampi(quality, 0, 100)];
    return p == 63 ? 255 : p == 62 ? 249 : 4 * p;
}

/* av1_set_quantizer(): tune=iq chroma delta-q.  out = {u_dc, u_ac, v_dc, v_ac}.
 * ssx/ssy = chroma subsampling (libaom treats monochrome as 1/1). */
AV1G_HD void av1f_chroma_delta_q(int base, int ssx, int ssy, int out[4]) {
    int dc = 0, ac = 0;
    if (base > 0) {
        if (ssx == 1 && ssy == 1) dc = ac = -av1f_clampi(base / 2 - 14, 0, 16);   /* 4:2:0 */
        else if (ssx == 1 && ssy == 0) ac = av1f_clampi(base / 2, 0, 6);           /* 4:2:2 */
        else if (ssx == 0 && ssy == 0) ac = av1f_clampi(base / 2, 0, 24);          /* 4:4:4 */
    }
    out[0] = dc; out[1] = ac; out[2] = dc; out[3] = ac;
}

/* aom_get_qmlevel_allintra / aom_get_qmlevel_444_chroma (quant_common.h) */
AV1G_HD int av1f_qm_level_allintra(int q, int first, int last) {
    const int l = q <= 40 ? 10 : q <= 100 ? 9 : q <= 160 ? 8 : q <= 200 ? 7 : q <= 220 ? 6 : q <= 240 ? 5 : 4;
    return av1f_clampi(l, first, last);
}
AV1G_HD int av1f_qm_level_444_chroma(int q, int first, int last) {
    const int l = q <= 12 ? 10 : q <= 24 ? 9 : q <= 32 ? 8 : q <= 36 ? 7 : q <= 44 ? 6 : q <= 48 ? 5 : q <= 56 ? 4 : q <= 88 ? 3 : 2;
    return av1f_clampi(l, first, last);
}

/* aom_get_variance_boost_delta_q_res (encodeframe.c): the resolution (1, 2, 4, 8) */
AV1G_HD int av1f_delta_q_res(int base) { return base >= 160 ? 8 : base >= 120 ? 4 : base >= 80 ? 2 : 1; }
AV1G_HD int av1f_log2i(int v) { int n = 0; while (v > 1) { v >>= 1; n++; } return n; }

/* av1_adjust_q_from_delta_q_res (rd.c) */
AV1G_HD int av1f_adjust_q(int res, int prev, int cur) {
    cur = av1f_clampi(cur, res, 256 - res);
    const int sign = cur - prev >= 0 ? 1 : -1;
    const int d = cur - prev < 0 ? prev - cur : cur - prev;
    const int a = (d + res / 4) & ~(res - 1);
    const int q = prev + sign * a;
    return q < 1 ? 1 : q;
}

/* av1_get_sbq_variance_boost (allintra_vis.c).  Double arithmetic in libaom's evaluation order;
 * device results are checked against the host for every (base, variance < 1024) pair. */
AV1G_HD int av1f_varboost_qindex(int base, unsigned variance, int deltaq_strength_pct) {
    double strength = (deltaq_strength_pct / 100.0) * 3.0;
    strength = strength < 0.0 ? 0.0 : strength > 6.0 ? 6.0 : strength;
    if (variance == 0) variance = 1;
#if defined(__CUDA_ARCH__)   /* no FMA contraction: libaom's C evaluates mul and add separately */
    double ratio = __dadd_rn(__dmul_rn(__dmul_rn(0.15, strength), __dadd_rn(-log2((double)variance), 10.0)), 1.0);
#else
    double ratio = 0.15 * strength * (-log2((double)variance) + 10.0) + 1.0;
#endif
    ratio = ratio < 1.0 ? 1.0 : ratio > AV1F_VB_MAX_BOOST ? AV1F_VB_MAX_BOOST : ratio;
    const double base_q = av1f_ac_q(base) / 4.0;              /* av1_convert_qindex_to_q, 8-bit */
    const double target_q = base_q / ratio;
    int t = 0;                                                /* av1_convert_q_to_qindex */
    while (t < 255 && av1f_ac_q(t) / 4.0 < target_q) t++;
#if defined(__CUDA_ARCH__)
    int boost = (int)round(__ddiv_rn(__dmul_rn(base + 544.0, (double)(base - t)), 1279.0));
#else
    int boost = (int)round((base + 544.0) * (base - t) / 1279.0);
#endif
    boost = boost < AV1F_VB_MAX_DELTAQ_RANGE ? boost : AV1F_VB_MAX_DELTAQ_RANGE;
    const int q = base - boost;
    return q < 1 ? 1 : q;
}

/* av1_get_variance_boost_block_variance: v[64] = aom_variance8x8(src, zeros) / 64 of the SB's
 * 8x8 blocks (any order).  Sorts in place; returns (v[31] + 2 v[39] + v[47] + 2) / 4. */
AV1G_HD unsigned av1f_sb_variance(unsigned v[64]) {
    for (int i = 1; i < 64; i++) {           /* insertion sort: host reference; the kernel ranks in a warp */
        const unsigned x = v[i];
        int j = i - 1;
        while (j >= 0 && v[j] > x) { v[j + 1] = v[j]; j--; }
        v[j + 1] = x;
    }
    return (v[31] + 2 * v[39] + v[47] + 2) / 4;
}

/* libaom 8x8 variance / 64 from the block's sum and sum of squares (aom_variance8x8_c) */
AV1G_HD unsigned av1f_var8x8_from_sums(int sum, unsigned sse) {
    return (sse - (unsigned)(((int64_t)sum * sum) / 64)) / 64;
}

/* av1_compute_rd_mult_based_on_qindex(KF_UPDATE) with the tune=iq weight: cpi->rd.RDMULT */
AV1G_HD int av1f_frame_rdmult(int base) {
    const int q = av1f_dc_q(base);
    int64_t r = (int64_t)q * q;
    r = (int64_t)((double)r * (3.3 + 0.0015 * q));
    const int w = av1f_clampi(((255 - base) * 3) / 4, 0, 72) + 128;
    r = (int64_t)((double)r * w / 128.0);
    return r > 0 ? (int)r : 1;
}

/* All frame-level tune=iq decisions for a base qindex. */
typedef struct av1f_tuneiq_frame {
    int base_q_idx;
    int dq_u_dc, dq_u_ac, dq_v_dc, dq_v_ac;  /* chroma delta-q (separate_uv_delta_q = 0) */
    int qm_y, qm_u, qm_v;                    /* using_qmatrix = 1 */
    int delta_q_res;                         /* 1/2/4/8 (frame header codes log2) */
    int lf_level;                            /* EFFECTIVE deblocking level, all four the same; 0 = off */
    int lf_sharpness;
    int cdef_damping;                        /* 3 + (base >> 6) */
    int cdef_mode;                           /* 0: CDEF off (cq <= 32, one zero preset), 1: halved strengths
                                                (33..220), 2: full strengths (> 220) */
    int rdmult;                              /* frame RDMULT (CDEF bits RD decision) */
} av1f_tuneiq_frame;

AV1G_HD void av1f_tuneiq_frame_init(int base, int ssx, int ssy, int mono, av1f_tuneiq_frame *f) {
    int dq[4];
    av1f_chroma_delta_q(base, ssx, ssy, dq);
    if (mono) dq[0] = dq[1] = dq[2] = dq[3] = 0;   /* not coded for monochrome */
    f->base_q_idx = base;
    f->dq_u_dc = dq[0]; f->dq_u_ac = dq[1]; f->dq_v_dc = dq[2]; f->dq_v_ac = dq[3];
    f->qm_y = av1f_qm_level_allintra(base, AV1F_QM_MIN_IQ, AV1F_QM_MAX_IQ);
    const int cq = base + dq[1];
    f->qm_u = f->qm_v = (ssx == 0 && ssy == 0) ? av1f_qm_level_444_chroma(cq, AV1F_QM_MIN_IQ, AV1F_QM_MAX_IQ)
                                               : av1f_qm_level_allintra(cq, AV1F_QM_MIN_IQ, AV1F_QM_MAX_IQ);
    f->delta_q_res = av1f_delta_q_res(base);
    /* av1_pick_filter_level(LPF_PICK_FROM_Q), key frame, 8-bit; + INTRA ref delta (+1 << (lvl >> 5)) */
    const int64_t g = (int64_t)av1f_ac_q(base) * 17563 - 421574;
    const int lvl = av1f_clampi((int)((g + (1 << 17)) >> 18), 0, 63);
    f->lf_level = lvl == 0 ? 0 : av1f_clampi(lvl + (1 << (lvl >> 5)), 0, 63);
    f->lf_sharpness = base <= 120 ? 7 : base <= 160 ? 1 : 0;   /* sharpness 7, enable_adaptive_sharpness */
    f->cdef_damping = 3 + (base >> 6);
    f->cdef_mode = base <= 32 ? 0 : base <= 220 ? 1 : 2;
    f->rdmult = av1f_frame_rdmult(base);
}

/* Writes every frame-header decision of libaom tune=iq into fp (4:2:0 or monochrome): base qindex,
 * chroma delta-q, QM levels, deblocking from Q (effective levels) + sharpness, CDEF damping with
 * enable_cdef = 1 (presets / cdef_bits / per-SB cdef_idx come from av1f_lf_search), and
 * delta_q_res; delta_q_present is left to the caller (1 iff some SB qindex != base). */
AV1G_HD void av1f_tuneiq_fill_fp(av1g_frame_params *fp, int base, int mono) {
    av1f_tuneiq_frame t;
    av1f_tuneiq_frame_init(base, 1, 1, mono, &t);
    fp->base_q_idx = (uint8_t)base;
    fp->monochrome = (uint8_t)mono;
    fp->delta_q_y_dc = 0;
    fp->delta_q_u_dc = (int8_t)t.dq_u_dc; fp->delta_q_u_ac = (int8_t)t.dq_u_ac;
    fp->delta_q_v_dc = (int8_t)t.dq_v_dc; fp->delta_q_v_ac = (int8_t)t.dq_v_ac;
    fp->using_qmatrix = 1;
    fp->qm_y = (uint8_t)t.qm_y; fp->qm_u = (uint8_t)t.qm_u; fp->qm_v = (uint8_t)t.qm_v;
    fp->delta_q_res = (uint8_t)av1f_log2i(t.delta_q_res);
    for (int i = 0; i < 4; i++) fp->loop_filter_level[i] = (uint8_t)(mono && i >= 2 ? 0 : t.lf_level);
    fp->loop_filter_sharpness = (uint8_t)t.lf_sharpness;
    fp->enable_cdef = 1;
    fp->cdef_damping_minus_3 = (uint8_t)(t.cdef_damping - 3);
}

#endif
