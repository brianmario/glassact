/* av1g/dsp.h - decoder-mirroring math of the AV1 spec, header-only, shared by the
 * CPU writer, the tests and CUDA kernels (__host__ __device__).  8-bit only.
 *
 *   av1g_dequant()            spec 7.12.3 step 1 (incl. quantizer matrices, & 0xFFFFFF, clamps)
 *   av1g_qm(), av1g_qm_step() quantizer-matrix weights (also for engines' forward quantizers)
 *   av1g_inv_txfm2d()         spec 7.13.3 (all 16 types, 19 sizes) + conformance
 *                             range checks (flags in *err, see AV1G_ERR_*)
 *   av1g_add_residual()       spec 7.12.3 step 3 (flips + Clip1)
 *   av1g_build_edges()        spec 7.11.2 AboveRow / LeftCol preparation
 *   av1g_predict_intra()      DC / directional / smooth* / paeth (edge filter off)
 *   av1g_predict_intra_ex()   + intra edge filter / upsampling and filter intra (M5)
 *   av1g_cfl_predict()        spec 7.11.5
 *
 * Every function follows the spec text step by step; see comments for sections.
 */
#ifndef AV1G_DSP_H
#define AV1G_DSP_H

#include <stdint.h>
#include "av1g/hd.h"
#include "av1g/enums_gen.h"
#include "av1g/spec_tables.h"

/* conformance error flags reported by the inverse transform */
#define AV1G_ERR_B_RANGE     1u  /* butterfly output outside r bits (7.13.2.1) */
#define AV1G_ERR_ADST4_RANGE 2u  /* ADST4 intermediates outside range (7.13.2.6) */

AV1G_HD int av1g_clip3(int lo, int hi, int x) { return x < lo ? lo : (x > hi ? hi : x); }
AV1G_HD int av1g_clip1(int x) { return x < 0 ? 0 : (x > 255 ? 255 : x); }
/* Round2 for n >= 0 with arithmetic shift (spec 4.7) */
AV1G_HD int32_t av1g_round2(int32_t x, int n) { return n == 0 ? x : ((x + (1 << (n - 1))) >> n); }
AV1G_HD int64_t av1g_round2_64(int64_t x, int n) { return n == 0 ? x : ((x + ((int64_t)1 << (n - 1))) >> n); }
AV1G_HD int32_t av1g_round2signed(int32_t x, int n) { return x >= 0 ? av1g_round2(x, n) : -av1g_round2(-x, n); }

/* ------------------------------------------------------------------------- */
/* transform size helpers                                                    */
/* ------------------------------------------------------------------------- */
AV1G_HD int av1g_tx_w(int txSz) { return AV1G_T(Tx_Width)[txSz]; }
AV1G_HD int av1g_tx_h(int txSz) { return AV1G_T(Tx_Height)[txSz]; }

/* get_tx_set() for intra blocks (spec 5.11.48) */
AV1G_HD int av1g_get_tx_set_intra(int txSz, int reduced_tx_set) {
    int sqr = AV1G_T(Tx_Size_Sqr)[txSz], sqrUp = AV1G_T(Tx_Size_Sqr_Up)[txSz];
    if (sqrUp > AV1G_TX_32X32) return AV1G_TX_SET_DCTONLY;
    if (sqrUp == AV1G_TX_32X32) return AV1G_TX_SET_DCTONLY;
    if (reduced_tx_set) return AV1G_TX_SET_INTRA_2;
    if (sqr == AV1G_TX_16X16) return AV1G_TX_SET_INTRA_2;
    return AV1G_TX_SET_INTRA_1;
}
AV1G_HD int av1g_tx_type_in_set_intra(int set, int txType) { return AV1G_T(Tx_Type_In_Set_Intra)[set][txType]; }

/* compute_tx_type() for an intra chroma tx block (spec 5.11.40, lossless excluded) */
AV1G_HD int av1g_chroma_tx_type(int uvTxSz, int uv_mode, int reduced_tx_set) {
    if (AV1G_T(Tx_Size_Sqr_Up)[uvTxSz] > AV1G_TX_32X32) return AV1G_DCT_DCT;
    int set = av1g_get_tx_set_intra(uvTxSz, reduced_tx_set);
    int t = AV1G_T(Mode_To_Txfm)[uv_mode];
    return av1g_tx_type_in_set_intra(set, t) ? t : AV1G_DCT_DCT;
}

/* tx class (spec get_tx_class) */
AV1G_HD int av1g_tx_class(int txType) {
    if (txType == AV1G_V_DCT || txType == AV1G_V_ADST || txType == AV1G_V_FLIPADST) return AV1G_TX_CLASS_VERT;
    if (txType == AV1G_H_DCT || txType == AV1G_H_ADST || txType == AV1G_H_FLIPADST) return AV1G_TX_CLASS_HORIZ;
    return AV1G_TX_CLASS_2D;
}

/* get_scan() (spec 5.11.41).  Returns the scan table and writes its length. */
AV1G_HD const uint16_t *av1g_get_scan(int txSz, int txType) {
    if (txSz == AV1G_TX_16X64) return AV1G_T(Default_Scan_16x32);
    if (txSz == AV1G_TX_64X16) return AV1G_T(Default_Scan_32x16);
    if (AV1G_T(Tx_Size_Sqr_Up)[txSz] == AV1G_TX_64X64) return AV1G_T(Default_Scan_32x32);
    int cls = (txType == AV1G_IDTX) ? AV1G_TX_CLASS_2D : av1g_tx_class(txType);
    if (cls == AV1G_TX_CLASS_VERT) { /* preferRow -> mrow */
        switch (txSz) {
        case AV1G_TX_4X4: return AV1G_T(Mrow_Scan_4x4);
        case AV1G_TX_4X8: return AV1G_T(Mrow_Scan_4x8);
        case AV1G_TX_8X4: return AV1G_T(Mrow_Scan_8x4);
        case AV1G_TX_8X8: return AV1G_T(Mrow_Scan_8x8);
        case AV1G_TX_8X16: return AV1G_T(Mrow_Scan_8x16);
        case AV1G_TX_16X8: return AV1G_T(Mrow_Scan_16x8);
        case AV1G_TX_16X16: return AV1G_T(Mrow_Scan_16x16);
        case AV1G_TX_4X16: return AV1G_T(Mrow_Scan_4x16);
        default: return AV1G_T(Mrow_Scan_16x4);
        }
    }
    if (cls == AV1G_TX_CLASS_HORIZ) { /* preferCol -> mcol */
        switch (txSz) {
        case AV1G_TX_4X4: return AV1G_T(Mcol_Scan_4x4);
        case AV1G_TX_4X8: return AV1G_T(Mcol_Scan_4x8);
        case AV1G_TX_8X4: return AV1G_T(Mcol_Scan_8x4);
        case AV1G_TX_8X8: return AV1G_T(Mcol_Scan_8x8);
        case AV1G_TX_8X16: return AV1G_T(Mcol_Scan_8x16);
        case AV1G_TX_16X8: return AV1G_T(Mcol_Scan_16x8);
        case AV1G_TX_16X16: return AV1G_T(Mcol_Scan_16x16);
        case AV1G_TX_4X16: return AV1G_T(Mcol_Scan_4x16);
        default: return AV1G_T(Mcol_Scan_16x4);
        }
    }
    switch (txSz) {
    case AV1G_TX_4X4: return AV1G_T(Default_Scan_4x4);
    case AV1G_TX_4X8: return AV1G_T(Default_Scan_4x8);
    case AV1G_TX_8X4: return AV1G_T(Default_Scan_8x4);
    case AV1G_TX_8X8: return AV1G_T(Default_Scan_8x8);
    case AV1G_TX_8X16: return AV1G_T(Default_Scan_8x16);
    case AV1G_TX_16X8: return AV1G_T(Default_Scan_16x8);
    case AV1G_TX_16X16: return AV1G_T(Default_Scan_16x16);
    case AV1G_TX_16X32: return AV1G_T(Default_Scan_16x32);
    case AV1G_TX_32X16: return AV1G_T(Default_Scan_32x16);
    case AV1G_TX_4X16: return AV1G_T(Default_Scan_4x16);
    case AV1G_TX_16X4: return AV1G_T(Default_Scan_16x4);
    case AV1G_TX_8X32: return AV1G_T(Default_Scan_8x32);
    case AV1G_TX_32X8: return AV1G_T(Default_Scan_32x8);
    default: return AV1G_T(Default_Scan_32x32);
    }
}

/* ------------------------------------------------------------------------- */
/* quantizer (spec 7.12.2)                                                   */
/* ------------------------------------------------------------------------- */
AV1G_HD int av1g_dc_q(int b) { return AV1G_T(Dc_Qlookup)[0][av1g_clip3(0, 255, b)]; }
AV1G_HD int av1g_ac_q(int b) { return AV1G_T(Ac_Qlookup)[0][av1g_clip3(0, 255, b)]; }

AV1G_HD int av1g_dq_denom(int txSz) {
    if (txSz == AV1G_TX_32X32 || txSz == AV1G_TX_16X32 || txSz == AV1G_TX_32X16 ||
        txSz == AV1G_TX_16X64 || txSz == AV1G_TX_64X16) return 2;
    if (txSz == AV1G_TX_64X64 || txSz == AV1G_TX_32X64 || txSz == AV1G_TX_64X32) return 4;
    return 1;
}

/* Dequantize one coefficient (spec 7.12.3 step 1 c..f, no quantizer matrix). */
AV1G_HD int32_t av1g_dequant_coef(int32_t quant, int q, int dqDenom) {
    int32_t dq = quant * q;
    int32_t a = (dq < 0 ? -dq : dq) & 0xFFFFFF;
    int32_t dq2 = a / dqDenom;
    if (dq < 0) dq2 = -dq2;
    return av1g_clip3(-(1 << 15), (1 << 15) - 1, dq2);
}

/* ---- quantizer matrices (spec 7.12.3 step 1b) ----
 * The weight matrix of a tx block (tw x th row-major, tw = min(32,w), th = min(32,h)),
 * or NULL when no matrix applies: using_qmatrix == 0, level 15 (flat), or a tx type
 * >= IDTX (IDTX, V_*, H_* are never weighted).  level = qm_y for plane 0, qm_u / qm_v
 * for planes 1 / 2.  Weights are in 1/32 units (32 = flat). */
AV1G_HD const uint8_t *av1g_qm(int using_qmatrix, int level, int plane, int txSz, int txType) {
    if (!using_qmatrix || level >= 15 || txType >= AV1G_IDTX) return 0;
    return &AV1G_T(Quantizer_Matrix)[level][plane > 0][AV1G_T(Qm_Offset)[txSz]];
}
/* q2 of one coefficient: the effective (pre-dqDenom) quantizer step at position pos */
AV1G_HD int av1g_qm_step(int q, const uint8_t *qm, int pos) {
    return qm ? av1g_round2(q * qm[pos], 5) : q;
}

/* The QM level libaom uses for all-intra / tune=iq (port of aom_get_qmlevel_allintra,
 * av1/common/quant_common.h, libaom 3.13): 10 at qindex <= 40 down to 4 above 240.
 * libaom applies it to base_q_idx for luma and base_q_idx + DeltaQUAc for chroma. */
AV1G_HD int av1g_qm_level_allintra(int qindex) {
    if (qindex <= 40) return 10;
    if (qindex <= 100) return 9;
    if (qindex <= 160) return 8;
    if (qindex <= 200) return 7;
    if (qindex <= 220) return 6;
    if (qindex <= 240) return 5;
    return 4;
}

/* Dequantize a whole tx block: quant/out are th x tw row-major (tw,th <= 32).
 * qm: av1g_qm(...) of the tx block, or NULL. */
AV1G_HD void av1g_dequant(const int16_t *quant, int32_t *out, int txSz, int dcQ, int acQ, const uint8_t *qm) {
    int tw = av1g_tx_w(txSz); if (tw > 32) tw = 32;
    int th = av1g_tx_h(txSz); if (th > 32) th = 32;
    int den = av1g_dq_denom(txSz);
    for (int i = 0; i < th * tw; i++)
        out[i] = quant[i] ? av1g_dequant_coef(quant[i], av1g_qm_step(i == 0 ? dcQ : acQ, qm, i), den) : 0;
}

/* ------------------------------------------------------------------------- */
/* 1-D inverse transforms (spec 7.13.2)                                      */
/* ------------------------------------------------------------------------- */
AV1G_HD int av1g_brev(int numBits, int x) {
    int t = 0;
    for (int i = 0; i < numBits; i++) t |= ((x >> i) & 1) << (numBits - 1 - i);
    return t;
}
AV1G_HD int av1g_cos128(int angle) {
    int a = angle & 255;
    if (a <= 64) return AV1G_T(Cos128_Lookup)[a];
    if (a <= 128) return -AV1G_T(Cos128_Lookup)[128 - a];
    if (a <= 192) return -AV1G_T(Cos128_Lookup)[a - 128];
    return AV1G_T(Cos128_Lookup)[256 - a];
}
AV1G_HD int av1g_sin128(int angle) { return av1g_cos128(angle - 64); }

AV1G_HD void av1g_chk(int64_t v, int bits, uint32_t *err, uint32_t flag) {
    if (v < -((int64_t)1 << (bits - 1)) || v > ((int64_t)1 << (bits - 1)) - 1) *err |= flag;
}

/* B( a, b, angle, flip, r ) */
AV1G_HD void av1g_B(int32_t *T, int a, int b, int angle, int flip, int r, uint32_t *err) {
    int64_t c = av1g_cos128(angle), s = av1g_sin128(angle);
    int64_t x = (int64_t)T[a] * c - (int64_t)T[b] * s;
    int64_t y = (int64_t)T[a] * s + (int64_t)T[b] * c;
    int64_t xa = av1g_round2_64(x, 12), yb = av1g_round2_64(y, 12);
    av1g_chk(xa, r, err, AV1G_ERR_B_RANGE);
    av1g_chk(yb, r, err, AV1G_ERR_B_RANGE);
    if (flip) { T[a] = (int32_t)yb; T[b] = (int32_t)xa; }
    else      { T[a] = (int32_t)xa; T[b] = (int32_t)yb; }
}
/* H( a, b, flip, r ) */
AV1G_HD void av1g_H(int32_t *T, int a, int b, int flip, int r) {
    if (flip) { int t = a; a = b; b = t; }
    int64_t x = T[a], y = T[b];
    int64_t lo = -((int64_t)1 << (r - 1)), hi = ((int64_t)1 << (r - 1)) - 1;
    int64_t s = x + y, d = x - y;
    T[a] = (int32_t)(s < lo ? lo : (s > hi ? hi : s));
    T[b] = (int32_t)(d < lo ? lo : (d > hi ? hi : d));
}

AV1G_HD void av1g_idct(int32_t *T, int n, int r, uint32_t *err) {
    int32_t copyT[64];
    int n0 = 1 << n;
    for (int i = 0; i < n0; i++) copyT[i] = T[i];
    for (int i = 0; i < n0; i++) T[i] = copyT[av1g_brev(n, i)];               /* step 1 */
    if (n == 6) for (int i = 0; i < 16; i++) av1g_B(T, 32 + i, 63 - i, 63 - 4 * av1g_brev(4, i), 0, r, err);
    if (n >= 5) for (int i = 0; i < 8; i++) av1g_B(T, 16 + i, 31 - i, 6 + (av1g_brev(3, 7 - i) << 3), 0, r, err);
    if (n == 6) for (int i = 0; i < 16; i++) av1g_H(T, 32 + i * 2, 33 + i * 2, i & 1, r);
    if (n >= 4) for (int i = 0; i < 4; i++) av1g_B(T, 8 + i, 15 - i, 12 + (av1g_brev(2, 3 - i) << 4), 0, r, err);
    if (n >= 5) for (int i = 0; i < 8; i++) av1g_H(T, 16 + 2 * i, 17 + 2 * i, i & 1, r);
    if (n == 6) for (int i = 0; i < 4; i++) for (int j = 0; j < 2; j++)
        av1g_B(T, 62 - i * 4 - j, 33 + i * 4 + j, 60 - 16 * av1g_brev(2, i) + 64 * j, 1, r, err);
    if (n >= 3) for (int i = 0; i < 2; i++) av1g_B(T, 4 + i, 7 - i, 56 - 32 * i, 0, r, err);
    if (n >= 4) for (int i = 0; i < 4; i++) av1g_H(T, 8 + 2 * i, 9 + 2 * i, i & 1, r);
    if (n >= 5) for (int i = 0; i < 2; i++) for (int j = 0; j < 2; j++)
        av1g_B(T, 30 - 4 * i - j, 17 + 4 * i + j, 24 + (j << 6) + ((1 - i) << 5), 1, r, err);
    if (n == 6) for (int i = 0; i < 8; i++) for (int j = 0; j < 2; j++)
        av1g_H(T, 32 + i * 4 + j, 35 + i * 4 - j, i & 1, r);
    for (int i = 0; i < 2; i++) av1g_B(T, 2 * i, 2 * i + 1, 32 + 16 * i, 1 - i, r, err);     /* step 12 */
    if (n >= 3) for (int i = 0; i < 2; i++) av1g_H(T, 4 + 2 * i, 5 + 2 * i, i, r);
    if (n >= 4) for (int i = 0; i < 2; i++) av1g_B(T, 14 - i, 9 + i, 48 + 64 * i, 1, r, err);
    if (n >= 5) for (int i = 0; i < 4; i++) for (int j = 0; j < 2; j++)
        av1g_H(T, 16 + 4 * i + j, 19 + 4 * i - j, i & 1, r);
    if (n == 6) for (int i = 0; i < 2; i++) for (int j = 0; j < 4; j++)
        av1g_B(T, 61 - i * 8 - j, 34 + i * 8 + j, 56 - i * 32 + (j >> 1) * 64, 1, r, err);
    for (int i = 0; i < 2; i++) av1g_H(T, i, 3 - i, 0, r);                                   /* step 17 */
    if (n >= 3) av1g_B(T, 6, 5, 32, 1, r, err);
    if (n >= 4) for (int i = 0; i < 2; i++) for (int j = 0; j < 2; j++)
        av1g_H(T, 8 + 4 * i + j, 11 + 4 * i - j, i, r);
    if (n >= 5) for (int i = 0; i < 4; i++) av1g_B(T, 29 - i, 18 + i, 48 + (i >> 1) * 64, 1, r, err);
    if (n == 6) for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++)
        av1g_H(T, 32 + 8 * i + j, 39 + 8 * i - j, i & 1, r);
    if (n >= 3) for (int i = 0; i < 4; i++) av1g_H(T, i, 7 - i, 0, r);                      /* step 22 */
    if (n >= 4) for (int i = 0; i < 2; i++) av1g_B(T, 13 - i, 10 + i, 32, 1, r, err);
    if (n >= 5) for (int i = 0; i < 2; i++) for (int j = 0; j < 4; j++)
        av1g_H(T, 16 + i * 8 + j, 23 + i * 8 - j, i, r);
    if (n == 6) for (int i = 0; i < 8; i++) av1g_B(T, 59 - i, 36 + i, i < 4 ? 48 : 112, 1, r, err);
    if (n >= 4) for (int i = 0; i < 8; i++) av1g_H(T, i, 15 - i, 0, r);                     /* step 26 */
    if (n >= 5) for (int i = 0; i < 4; i++) av1g_B(T, 27 - i, 20 + i, 32, 1, r, err);
    if (n == 6) for (int i = 0; i < 8; i++) { av1g_H(T, 32 + i, 47 - i, 0, r); av1g_H(T, 48 + i, 63 - i, 1, r); }
    if (n >= 5) for (int i = 0; i < 16; i++) av1g_H(T, i, 31 - i, 0, r);
    if (n == 6) for (int i = 0; i < 8; i++) av1g_B(T, 55 - i, 40 + i, 32, 1, r, err);
    if (n == 6) for (int i = 0; i < 32; i++) av1g_H(T, i, 63 - i, 0, r);                    /* step 31 */
}

AV1G_HD void av1g_iadst_in_perm(int32_t *T, int n) {
    int32_t copyT[16];
    int n0 = 1 << n;
    for (int i = 0; i < n0; i++) copyT[i] = T[i];
    for (int i = 0; i < n0; i++) T[i] = copyT[(i & 1) ? (i - 1) : (n0 - i - 1)];
}
AV1G_HD void av1g_iadst_out_perm(int32_t *T, int n) {
    int32_t copyT[16];
    int n0 = 1 << n;
    for (int i = 0; i < n0; i++) copyT[i] = T[i];
    for (int i = 0; i < n0; i++) {
        int a = (i >> 3) & 1;
        int b = ((i >> 2) & 1) ^ ((i >> 3) & 1);
        int c = ((i >> 1) & 1) ^ ((i >> 2) & 1);
        int d = (i & 1) ^ ((i >> 1) & 1);
        int idx = ((d << 3) | (c << 2) | (b << 1) | a) >> (4 - n);
        T[i] = (i & 1) ? -copyT[idx] : copyT[idx];
    }
}

AV1G_HD void av1g_iadst4(int32_t *T, int r, uint32_t *err) {
    const int64_t SINPI_1_9 = 1321, SINPI_2_9 = 2482, SINPI_3_9 = 3344, SINPI_4_9 = 3803;
    int64_t s[7], x[4];
    s[0] = SINPI_1_9 * T[0];
    s[1] = SINPI_2_9 * T[0];
    s[2] = SINPI_3_9 * T[1];
    s[3] = SINPI_4_9 * T[2];
    s[4] = SINPI_1_9 * T[2];
    s[5] = SINPI_2_9 * T[3];
    s[6] = SINPI_4_9 * T[3];
    int64_t a7 = (int64_t)T[0] - T[2];
    int64_t b7 = a7 + T[3];
    av1g_chk(a7, r + 1, err, AV1G_ERR_ADST4_RANGE);
    av1g_chk(b7, r, err, AV1G_ERR_ADST4_RANGE);
    for (int i = 0; i < 7; i++) av1g_chk(s[i], r + 12, err, AV1G_ERR_ADST4_RANGE);
    s[0] = s[0] + s[3];
    s[1] = s[1] - s[4];
    s[3] = s[2];
    s[2] = SINPI_3_9 * b7;
    av1g_chk(s[0], r + 12, err, AV1G_ERR_ADST4_RANGE);
    av1g_chk(s[1], r + 12, err, AV1G_ERR_ADST4_RANGE);
    av1g_chk(s[2], r + 12, err, AV1G_ERR_ADST4_RANGE);
    s[0] = s[0] + s[5];
    s[1] = s[1] - s[6];
    av1g_chk(s[0], r + 12, err, AV1G_ERR_ADST4_RANGE);
    av1g_chk(s[1], r + 12, err, AV1G_ERR_ADST4_RANGE);
    x[0] = s[0] + s[3];
    x[1] = s[1] + s[3];
    x[2] = s[2];
    x[3] = s[0] + s[1];
    av1g_chk(x[3], r + 12, err, AV1G_ERR_ADST4_RANGE);
    x[3] = x[3] - s[3];
    for (int i = 0; i < 4; i++) av1g_chk(x[i], r + 12, err, AV1G_ERR_ADST4_RANGE);
    for (int i = 0; i < 4; i++) T[i] = (int32_t)av1g_round2_64(x[i], 12);
}

AV1G_HD void av1g_iadst8(int32_t *T, int r, uint32_t *err) {
    av1g_iadst_in_perm(T, 3);
    for (int i = 0; i < 4; i++) av1g_B(T, 2 * i, 2 * i + 1, 60 - 16 * i, 1, r, err);
    for (int i = 0; i < 4; i++) av1g_H(T, i, 4 + i, 0, r);
    for (int i = 0; i < 2; i++) av1g_B(T, 4 + 3 * i, 5 + i, 48 - 32 * i, 1, r, err);
    for (int i = 0; i < 2; i++) for (int j = 0; j < 2; j++) av1g_H(T, 4 * j + i, 2 + 4 * j + i, 0, r);
    for (int i = 0; i < 2; i++) av1g_B(T, 2 + 4 * i, 3 + 4 * i, 32, 1, r, err);
    av1g_iadst_out_perm(T, 3);
}

AV1G_HD void av1g_iadst16(int32_t *T, int r, uint32_t *err) {
    av1g_iadst_in_perm(T, 4);
    for (int i = 0; i < 8; i++) av1g_B(T, 2 * i, 2 * i + 1, 62 - 8 * i, 1, r, err);
    for (int i = 0; i < 8; i++) av1g_H(T, i, 8 + i, 0, r);
    for (int i = 0; i < 2; i++) {
        av1g_B(T, 8 + 2 * i, 9 + 2 * i, 56 - 32 * i, 1, r, err);
        av1g_B(T, 13 + 2 * i, 12 + 2 * i, 8 + 32 * i, 1, r, err);
    }
    for (int i = 0; i < 4; i++) for (int j = 0; j < 2; j++) av1g_H(T, 8 * j + i, 4 + 8 * j + i, 0, r);
    for (int i = 0; i < 2; i++) for (int j = 0; j < 2; j++)
        av1g_B(T, 4 + 8 * j + 3 * i, 5 + 8 * j + i, 48 - 32 * i, 1, r, err);
    for (int i = 0; i < 2; i++) for (int j = 0; j < 4; j++) av1g_H(T, 4 * j + i, 2 + 4 * j + i, 0, r);
    for (int i = 0; i < 4; i++) av1g_B(T, 2 + 4 * i, 3 + 4 * i, 32, 1, r, err);
    av1g_iadst_out_perm(T, 4);
}

AV1G_HD void av1g_iidentity(int32_t *T, int n) {
    int n0 = 1 << n;
    for (int i = 0; i < n0; i++) {
        if (n == 2) T[i] = (int32_t)av1g_round2_64((int64_t)T[i] * 5793, 12);
        else if (n == 3) T[i] = T[i] * 2;
        else if (n == 4) T[i] = (int32_t)av1g_round2_64((int64_t)T[i] * 11586, 12);
        else T[i] = T[i] * 4;
    }
}

/* 1-D kind for the row (horizontal) and column (vertical) pass of a tx type */
#define AV1G_K_DCT 0
#define AV1G_K_ADST 1
#define AV1G_K_IDT 2
AV1G_HD int av1g_row_kind(int t) {
    switch (t) {
    case AV1G_DCT_DCT: case AV1G_ADST_DCT: case AV1G_FLIPADST_DCT: case AV1G_H_DCT: return AV1G_K_DCT;
    case AV1G_DCT_ADST: case AV1G_ADST_ADST: case AV1G_DCT_FLIPADST: case AV1G_FLIPADST_FLIPADST:
    case AV1G_ADST_FLIPADST: case AV1G_FLIPADST_ADST: case AV1G_H_ADST: case AV1G_H_FLIPADST: return AV1G_K_ADST;
    default: return AV1G_K_IDT;
    }
}
AV1G_HD int av1g_col_kind(int t) {
    switch (t) {
    case AV1G_DCT_DCT: case AV1G_DCT_ADST: case AV1G_DCT_FLIPADST: case AV1G_V_DCT: return AV1G_K_DCT;
    case AV1G_ADST_DCT: case AV1G_ADST_ADST: case AV1G_FLIPADST_DCT: case AV1G_FLIPADST_FLIPADST:
    case AV1G_ADST_FLIPADST: case AV1G_FLIPADST_ADST: case AV1G_V_ADST: case AV1G_V_FLIPADST: return AV1G_K_ADST;
    default: return AV1G_K_IDT;
    }
}
AV1G_HD int av1g_flip_ud(int t) {
    return t == AV1G_FLIPADST_DCT || t == AV1G_FLIPADST_ADST || t == AV1G_V_FLIPADST || t == AV1G_FLIPADST_FLIPADST;
}
AV1G_HD int av1g_flip_lr(int t) {
    return t == AV1G_DCT_FLIPADST || t == AV1G_ADST_FLIPADST || t == AV1G_H_FLIPADST || t == AV1G_FLIPADST_FLIPADST;
}

AV1G_HD void av1g_inv_1d(int32_t *T, int kind, int n, int r, uint32_t *err) {
    if (kind == AV1G_K_DCT) av1g_idct(T, n, r, err);
    else if (kind == AV1G_K_ADST) {
        if (n == 2) av1g_iadst4(T, r, err);
        else if (n == 3) av1g_iadst8(T, r, err);
        else av1g_iadst16(T, r, err);
    } else av1g_iidentity(T, n);
}

/* 2-D inverse transform (spec 7.13.3, Lossless = 0, BitDepth = 8).
 * dq:  Dequant, th x tw row-major (tw = min(32,w), th = min(32,h))
 * res: Residual output, h x w row-major (int32, caller-provided, up to 64*64)
 * err: OR-ed AV1G_ERR_* flags for conformance violations (0 = conformant) */
AV1G_HD void av1g_inv_txfm2d(const int32_t *dq, int txSz, int txType, int32_t *res, uint32_t *err) {
    const int log2W = AV1G_T(Tx_Width_Log2)[txSz], log2H = AV1G_T(Tx_Height_Log2)[txSz];
    const int w = 1 << log2W, h = 1 << log2H;
    const int tw = w > 32 ? 32 : w, th = h > 32 ? 32 : h;
    const int rowShift = AV1G_T(Transform_Row_Shift)[txSz];
    const int rowR = 8 + 8, colR = 16; /* BitDepth + 8, Max(BitDepth + 6, 16) */
    const int rk = av1g_row_kind(txType), ck = av1g_col_kind(txType);
    const int rect = (log2W - log2H == 1 || log2H - log2W == 1);
    int32_t T[64];
    for (int i = 0; i < h; i++) {
        int nz = 0;
        if (i < th) for (int j = 0; j < tw; j++) nz |= dq[i * tw + j];
        if (!nz) { /* all-zero input row -> all-zero output (every 1-D transform is odd-symmetric linear) */
            for (int j = 0; j < w; j++) res[i * w + j] = 0;
            continue;
        }
        for (int j = 0; j < w; j++) T[j] = (j < tw) ? dq[i * tw + j] : 0;
        if (rect) for (int j = 0; j < w; j++) T[j] = (int32_t)av1g_round2_64((int64_t)T[j] * 2896, 12);
        av1g_inv_1d(T, rk, log2W, rowR, err);
        for (int j = 0; j < w; j++) {
            int32_t v = (int32_t)av1g_round2_64(T[j], rowShift);
            res[i * w + j] = av1g_clip3(-(1 << (colR - 1)), (1 << (colR - 1)) - 1, v);
        }
    }
    for (int j = 0; j < w; j++) {
        for (int i = 0; i < h; i++) T[i] = res[i * w + j];
        av1g_inv_1d(T, ck, log2H, colR, err);
        for (int i = 0; i < h; i++) res[i * w + j] = (int32_t)av1g_round2_64(T[i], 4);
    }
}

/* Reconstruction add (spec 7.12.3 step 3). */
AV1G_HD void av1g_add_residual(uint8_t *dst, int stride, const int32_t *res, int txSz, int txType) {
    const int w = av1g_tx_w(txSz), h = av1g_tx_h(txSz);
    const int fud = av1g_flip_ud(txType), flr = av1g_flip_lr(txType);
    for (int i = 0; i < h; i++)
        for (int j = 0; j < w; j++) {
            int xx = flr ? (w - j - 1) : j;
            int yy = fud ? (h - i - 1) : i;
            uint8_t *p = dst + yy * stride + xx;
            *p = (uint8_t)av1g_clip1(*p + res[i * w + j]);
        }
}

/* ------------------------------------------------------------------------- */
/* intra prediction (spec 7.11.2), intra edge filter / upsampling OFF         */
/* ------------------------------------------------------------------------- */
#define AV1G_EDGE_OFF 16   /* AboveRow[-1] lives at index AV1G_EDGE_OFF-1 */
#define AV1G_EDGE_LEN (AV1G_EDGE_OFF + 2 * 64 + 16)

/* Build AboveRow[-1 .. w+h-1] and LeftCol[-1 .. w+h-1].
 * plane points at sample (0,0) of the plane; (x,y) is the tx block top-left.
 * above/left must point at index 0 of arrays with room for index -1. */
AV1G_HD void av1g_build_edges(const uint8_t *plane, int stride, int x, int y, int log2W, int log2H,
                              int haveLeft, int haveAbove, int haveAboveRight, int haveBelowLeft,
                              int maxX, int maxY, uint8_t *above, uint8_t *left) {
    const int w = 1 << log2W, h = 1 << log2H, n = w + h;
    if (!haveAbove && haveLeft) {
        uint8_t v = plane[y * stride + x - 1];
        for (int i = 0; i < n; i++) above[i] = v;
    } else if (!haveAbove && !haveLeft) {
        for (int i = 0; i < n; i++) above[i] = (1 << 7) - 1;
    } else {
        int aboveLimit = x + (haveAboveRight ? 2 * w : w) - 1;
        if (aboveLimit > maxX) aboveLimit = maxX;
        const uint8_t *row = plane + (y - 1) * stride;
        for (int i = 0; i < n; i++) above[i] = row[(x + i) < aboveLimit ? (x + i) : aboveLimit];
    }
    if (!haveLeft && haveAbove) {
        uint8_t v = plane[(y - 1) * stride + x];
        for (int i = 0; i < n; i++) left[i] = v;
    } else if (!haveLeft && !haveAbove) {
        for (int i = 0; i < n; i++) left[i] = (1 << 7) + 1;
    } else {
        int leftLimit = y + (haveBelowLeft ? 2 * h : h) - 1;
        if (leftLimit > maxY) leftLimit = maxY;
        for (int i = 0; i < n; i++) left[i] = plane[((y + i) < leftLimit ? (y + i) : leftLimit) * stride + x - 1];
    }
    uint8_t c;
    if (haveAbove && haveLeft) c = plane[(y - 1) * stride + x - 1];
    else if (haveAbove) c = plane[(y - 1) * stride + x];
    else if (haveLeft) c = plane[y * stride + x - 1];
    else c = 1 << 7;
    above[-1] = c;
    left[-1] = c;
}

AV1G_HD int av1g_is_directional(int mode) { return mode >= AV1G_V_PRED && mode <= AV1G_D67_PRED; }

AV1G_HD const uint8_t *av1g_sm_weights(int log2) {
    switch (log2) {
    case 2: return AV1G_T(Sm_Weights_Tx_4x4);
    case 3: return AV1G_T(Sm_Weights_Tx_8x8);
    case 4: return AV1G_T(Sm_Weights_Tx_16x16);
    case 5: return AV1G_T(Sm_Weights_Tx_32x32);
    default: return AV1G_T(Sm_Weights_Tx_64x64);
    }
}

/* DC value (spec 7.11.2.5) */
AV1G_HD int av1g_dc_value(const uint8_t *above, const uint8_t *left, int haveLeft, int haveAbove, int log2W, int log2H) {
    const int w = 1 << log2W, h = 1 << log2H;
    int sum = 0;
    if (haveLeft && haveAbove) {
        for (int k = 0; k < h; k++) sum += left[k];
        for (int k = 0; k < w; k++) sum += above[k];
        sum += (w + h) >> 1;
        return sum / (w + h);
    }
    if (haveLeft) {
        for (int k = 0; k < h; k++) sum += left[k];
        return av1g_clip1((sum + (h >> 1)) >> log2H);
    }
    if (haveAbove) {
        for (int k = 0; k < w; k++) sum += above[k];
        return av1g_clip1((sum + (w >> 1)) >> log2W);
    }
    return 1 << 7;
}

/* One predicted sample of a non-DC mode (spec 7.11.2.2/4/6), (i,j) = (row,col).
 * pAngle is only used for directional modes; upA/upL are the edge upsampling flags
 * (0 unless the intra edge filter upsampled the arrays, see av1g_edge_prepare). */
AV1G_HD int av1g_pred_pixel_up(int mode, int pAngle, int i, int j, int log2W, int log2H,
                               const uint8_t *above, const uint8_t *left, int upA, int upL) {
    const int w = 1 << log2W, h = 1 << log2H;
    if (av1g_is_directional(mode)) {
        if (pAngle == 90) return above[j];
        if (pAngle == 180) return left[i];
        if (pAngle < 90) {
            int dx = AV1G_T(Dr_Intra_Derivative)[pAngle];
            int idx = (i + 1) * dx;
            int base = (idx >> (6 - upA)) + (j << upA);
            int shift = ((idx << upA) >> 1) & 0x1F;
            int maxBaseX = (w + h - 1) << upA;
            if (base < maxBaseX) return av1g_round2(above[base] * (32 - shift) + above[base + 1] * shift, 5);
            return above[maxBaseX];
        }
        if (pAngle < 180) {
            int dx = AV1G_T(Dr_Intra_Derivative)[180 - pAngle];
            int dy = AV1G_T(Dr_Intra_Derivative)[pAngle - 90];
            int idx = (j << 6) - (i + 1) * dx;
            int base = idx >> (6 - upA);
            if (base >= -(1 << upA)) {
                int shift = ((idx * (1 << upA)) >> 1) & 0x1F;
                return av1g_round2(above[base] * (32 - shift) + above[base + 1] * shift, 5);
            }
            idx = (i << 6) - (j + 1) * dy;
            base = idx >> (6 - upL);
            int shift = ((idx * (1 << upL)) >> 1) & 0x1F;
            return av1g_round2(left[base] * (32 - shift) + left[base + 1] * shift, 5);
        }
        {
            int dy = AV1G_T(Dr_Intra_Derivative)[270 - pAngle];
            int idx = (j + 1) * dy;
            int base = (idx >> (6 - upL)) + (i << upL);
            int shift = ((idx << upL) >> 1) & 0x1F;
            return av1g_round2(left[base] * (32 - shift) + left[base + 1] * shift, 5);
        }
    }
    if (mode == AV1G_SMOOTH_PRED) {
        const uint8_t *wx = av1g_sm_weights(log2W), *wy = av1g_sm_weights(log2H);
        int s = wy[i] * above[j] + (256 - wy[i]) * left[h - 1] + wx[j] * left[i] + (256 - wx[j]) * above[w - 1];
        return av1g_round2(s, 9);
    }
    if (mode == AV1G_SMOOTH_V_PRED) {
        const uint8_t *wy = av1g_sm_weights(log2H);
        return av1g_round2(wy[i] * above[j] + (256 - wy[i]) * left[h - 1], 8);
    }
    if (mode == AV1G_SMOOTH_H_PRED) {
        const uint8_t *wx = av1g_sm_weights(log2W);
        return av1g_round2(wx[j] * left[i] + (256 - wx[j]) * above[w - 1], 8);
    }
    /* PAETH (basic intra prediction process) */
    {
        int base = above[j] + left[i] - above[-1];
        int pLeft = base - left[i]; if (pLeft < 0) pLeft = -pLeft;
        int pTop = base - above[j]; if (pTop < 0) pTop = -pTop;
        int pTopLeft = base - above[-1]; if (pTopLeft < 0) pTopLeft = -pTopLeft;
        if (pLeft <= pTop && pLeft <= pTopLeft) return left[i];
        if (pTop <= pTopLeft) return above[j];
        return above[-1];
    }
}
AV1G_HD int av1g_pred_pixel(int mode, int pAngle, int i, int j, int log2W, int log2H,
                            const uint8_t *above, const uint8_t *left) {
    return av1g_pred_pixel_up(mode, pAngle, i, j, log2W, log2H, above, left, 0, 0);
}

/* ---- intra edge filter + upsampling (spec 7.11.2.4 step 4, 7.11.2.7 .. 7.11.2.12) ---- */
AV1G_HD int av1g_edge_strength(int w, int h, int filterType, int delta) {  /* 7.11.2.9 */
    const int d = delta < 0 ? -delta : delta, blkWh = w + h;
    int strength = 0;
    if (filterType == 0) {
        if (blkWh <= 8) { if (d >= 56) strength = 1; }
        else if (blkWh <= 12) { if (d >= 40) strength = 1; }
        else if (blkWh <= 16) { if (d >= 40) strength = 1; }
        else if (blkWh <= 24) { if (d >= 8) strength = 1; if (d >= 16) strength = 2; if (d >= 32) strength = 3; }
        else if (blkWh <= 32) { strength = 1; if (d >= 4) strength = 2; if (d >= 32) strength = 3; }
        else strength = 3;
    } else {
        if (blkWh <= 8) { if (d >= 40) strength = 1; if (d >= 64) strength = 2; }
        else if (blkWh <= 16) { if (d >= 20) strength = 1; if (d >= 48) strength = 2; }
        else if (blkWh <= 24) { if (d >= 4) strength = 3; }
        else strength = 3;
    }
    return strength;
}
AV1G_HD int av1g_edge_use_upsample(int w, int h, int filterType, int delta) {  /* 7.11.2.10 */
    const int d = delta < 0 ? -delta : delta, blkWh = w + h;
    if (d <= 0 || d >= 40) return 0;
    return filterType == 0 ? (blkWh <= 16) : (blkWh <= 8);
}
/* 7.11.2.12: filter buf[0 .. sz-2] (edge[i] = buf[i-1]) */
AV1G_HD void av1g_edge_filter(uint8_t *buf, int sz, int strength) {
    if (!strength) return;
    uint8_t edge[160];
    for (int i = 0; i < sz; i++) edge[i] = buf[i - 1];
    for (int i = 1; i < sz; i++) {
        int s = 0;
        for (int j = 0; j < AV1G_INTRA_EDGE_TAPS; j++) {
            int k = av1g_clip3(0, sz - 1, i - 2 + j);
            s += AV1G_T(Intra_Edge_Kernel)[strength - 1][j] * edge[k];
        }
        buf[i - 1] = (uint8_t)((s + 8) >> 4);
    }
}
/* 7.11.2.11: upsample buf[-1 .. numPx-1] into buf[-2 .. 2*numPx-2] */
AV1G_HD void av1g_edge_upsample(uint8_t *buf, int numPx) {
    uint8_t dup[40];
    dup[0] = buf[-1];
    for (int i = -1; i < numPx; i++) dup[i + 2] = buf[i];
    dup[numPx + 2] = buf[numPx - 1];
    buf[-2] = dup[0];
    for (int i = 0; i < numPx; i++) {
        int s = -dup[i] + 9 * dup[i + 1] + 9 * dup[i + 2] - dup[i + 3];
        s = av1g_clip1(av1g_round2(s, 4));
        buf[2 * i - 1] = (uint8_t)s;
        buf[2 * i] = dup[i + 2];
    }
}
/* Edge preprocessing of a directional prediction when enable_intra_edge_filter = 1:
 * corner filter, above/left edge filters, upsampling.  above/left are modified in place
 * (they need valid storage for index -2 .. 2*(w+h)); returns the upsampling flags.
 * filterType: 1 if the above or left block uses a SMOOTH* mode (spec get_filter_type,
 * av1g_get_filter_type helps).  (x, y, maxX, maxY) as for av1g_build_edges. */
AV1G_HD void av1g_edge_prepare(int pAngle, int log2W, int log2H, int filterType, int haveLeft, int haveAbove, int x, int y,
                               int maxX, int maxY, uint8_t *above, uint8_t *left, int *upA, int *upL) {
    const int w = 1 << log2W, h = 1 << log2H;
    *upA = *upL = 0;
    if (pAngle != 90 && pAngle != 180) {
        if (pAngle > 90 && pAngle < 180 && (w + h) >= 24) {
            const uint8_t c = (uint8_t)av1g_round2(left[0] * 5 + above[-1] * 6 + above[0] * 5, 4);
            left[-1] = c;
            above[-1] = c;
        }
        if (haveAbove) {
            const int strength = av1g_edge_strength(w, h, filterType, pAngle - 90);
            const int numPx = (w < maxX - x + 1 ? w : maxX - x + 1) + (pAngle < 90 ? h : 0) + 1;
            av1g_edge_filter(above, numPx, strength);
        }
        if (haveLeft) {
            const int strength = av1g_edge_strength(w, h, filterType, pAngle - 180);
            const int numPx = (h < maxY - y + 1 ? h : maxY - y + 1) + (pAngle > 180 ? w : 0) + 1;
            av1g_edge_filter(left, numPx, strength);
        }
    }
    *upA = av1g_edge_use_upsample(w, h, filterType, pAngle - 90);
    if (*upA) av1g_edge_upsample(above, w + (pAngle < 90 ? h : 0));
    *upL = av1g_edge_use_upsample(w, h, filterType, pAngle - 180);
    if (*upL) av1g_edge_upsample(left, h + (pAngle > 180 ? w : 0));
}

/* Recursive (filter-intra) prediction, spec 7.11.2.3, mode = filter_intra_mode 0..4.
 * dst doubles as the pred array (row stride). */
AV1G_HD void av1g_predict_filter_intra(int mode, int log2W, int log2H, const uint8_t *above, const uint8_t *left,
                                       uint8_t *dst, int stride) {
    const int w4 = (1 << log2W) >> 2, h2 = (1 << log2H) >> 1;
    for (int i2 = 0; i2 < h2; i2++)
        for (int j4 = 0; j4 < w4; j4++) {
            int p[7];
            for (int i = 0; i < 5; i++) {
                if (i2 == 0) p[i] = above[(j4 << 2) + i - 1];
                else if (j4 == 0 && i == 0) p[i] = left[(i2 << 1) - 1];
                else p[i] = dst[((i2 << 1) - 1) * stride + (j4 << 2) + i - 1];
            }
            for (int i = 5; i < 7; i++)
                p[i] = j4 == 0 ? left[(i2 << 1) + i - 5] : dst[((i2 << 1) + i - 5) * stride + (j4 << 2) - 1];
            for (int i1 = 0; i1 < 2; i1++)
                for (int j1 = 0; j1 < 4; j1++) {
                    int pr = 0;
                    for (int i = 0; i < 7; i++) pr += AV1G_T(Intra_Filter_Taps)[mode][(i1 << 2) + j1][i] * p[i];
                    dst[((i2 << 1) + i1) * stride + (j4 << 2) + j1] = (uint8_t)av1g_clip1(av1g_round2signed(pr, 4));
                }
        }
}

/* Predict a whole tx block into dst (stride).  mode is the effective mode
 * (DC for CFL), angleDelta is AngleDeltaY/UV. */
AV1G_HD void av1g_predict_intra(int mode, int angleDelta, int haveLeft, int haveAbove, int log2W, int log2H,
                                const uint8_t *above, const uint8_t *left, uint8_t *dst, int stride) {
    const int w = 1 << log2W, h = 1 << log2H;
    if (mode == AV1G_DC_PRED) {
        uint8_t v = (uint8_t)av1g_dc_value(above, left, haveLeft, haveAbove, log2W, log2H);
        for (int i = 0; i < h; i++) for (int j = 0; j < w; j++) dst[i * stride + j] = v;
        return;
    }
    int pAngle = av1g_is_directional(mode) ? AV1G_T(Mode_To_Angle)[mode] + angleDelta * AV1G_ANGLE_STEP : 0;
    for (int i = 0; i < h; i++)
        for (int j = 0; j < w; j++)
            dst[i * stride + j] = (uint8_t)av1g_pred_pixel(mode, pAngle, i, j, log2W, log2H, above, left);
}

/* Full intra prediction of one tx block (spec 7.11.2): filter intra (filterIntraMode >= 0,
 * luma only), directional with optional edge filter / upsampling (edgeFilter =
 * enable_intra_edge_filter; above/left are modified), or the other modes. */
AV1G_HD void av1g_predict_intra_ex(int mode, int angleDelta, int filterIntraMode, int edgeFilter, int filterType,
                                   int haveLeft, int haveAbove, int log2W, int log2H, int x, int y, int maxX, int maxY,
                                   uint8_t *above, uint8_t *left, uint8_t *dst, int stride) {
    if (filterIntraMode >= 0) {
        av1g_predict_filter_intra(filterIntraMode, log2W, log2H, above, left, dst, stride);
        return;
    }
    if (av1g_is_directional(mode)) {
        const int w = 1 << log2W, h = 1 << log2H;
        const int pAngle = AV1G_T(Mode_To_Angle)[mode] + angleDelta * AV1G_ANGLE_STEP;
        int upA = 0, upL = 0;
        if (edgeFilter) av1g_edge_prepare(pAngle, log2W, log2H, filterType, haveLeft, haveAbove, x, y, maxX, maxY, above, left, &upA, &upL);
        for (int i = 0; i < h; i++)
            for (int j = 0; j < w; j++) dst[i * stride + j] = (uint8_t)av1g_pred_pixel_up(mode, pAngle, i, j, log2W, log2H, above, left, upA, upL);
        return;
    }
    av1g_predict_intra(mode, angleDelta, haveLeft, haveAbove, log2W, log2H, above, left, dst, stride);
}

/* Chroma from luma (spec 7.11.5).  chroma/luma point at sample (0,0) of their
 * planes; (startX,startY) in chroma samples; the DC prediction must already be in
 * the chroma plane. */
AV1G_HD void av1g_cfl_predict(uint8_t *chroma, int cstride, const uint8_t *luma, int lstride,
                              int startX, int startY, int txSz, int subX, int subY,
                              int maxLumaW, int maxLumaH, int alpha) {
    const int log2W = AV1G_T(Tx_Width_Log2)[txSz], log2H = AV1G_T(Tx_Height_Log2)[txSz];
    const int w = 1 << log2W, h = 1 << log2H;
    int lumaAvg = 0;
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < h; i++) {
            int lumaY = (startY + i) << subY;
            if (lumaY > maxLumaH - (1 << subY)) lumaY = maxLumaH - (1 << subY);
            for (int j = 0; j < w; j++) {
                int lumaX = (startX + j) << subX;
                if (lumaX > maxLumaW - (1 << subX)) lumaX = maxLumaW - (1 << subX);
                int t = 0;
                for (int dy = 0; dy <= subY; dy++)
                    for (int dx = 0; dx <= subX; dx++) t += luma[(lumaY + dy) * lstride + lumaX + dx];
                int v = t << (3 - subX - subY);
                if (pass == 0) lumaAvg += v;
                else {
                    uint8_t *p = chroma + (startY + i) * cstride + startX + j;
                    int scaled = av1g_round2signed(alpha * (v - lumaAvg), 6);
                    *p = (uint8_t)av1g_clip1(*p + scaled);
                }
            }
        }
        if (pass == 0) lumaAvg = av1g_round2(lumaAvg, log2W + log2H);
    }
}

#endif
