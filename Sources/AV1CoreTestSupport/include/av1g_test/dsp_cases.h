/* av1g_test/dsp_cases.h - one random case of av1core's shared DSP, run the same way on
 * the CPU (dsp_cases.cpp) and in Metal kernels (Tests/GlassActAV1Tests/Shaders/
 * dsp_test.metal), so DSPEquivalenceTests can require identical results:
 *   1. dequant (incl. quantizer matrices) + 2-D inverse transform + conformance flags
 *   2. intra prediction (13 modes x angle deltas, every tx size, random edges and
 *      availability, intra edge filter and upsampling, filter intra)
 *   3. CfL
 *   4. od_ec range coder + CDF adaptation
 *
 * Glass Act: from av1gpu's tests/gpu_dsp_test.cu (BSD-2, Sources/AV1Core/LICENSE),
 * with its CUDA kernels' bodies as functions both sides call.
 */
#ifndef AV1T_DSP_CASES_H
#define AV1T_DSP_CASES_H

#include <stdint.h>
#include "av1g/dsp.h"
#include "av1g/entenc.h"
#include "av1g/cdfctx.h"
#include "av1g/blockinfo.h"

/* ---- 1. inverse transforms ---- */
typedef struct av1t_itx_case { int32_t txSz, txType, dcQ, acQ, qmLevel, plane; } av1t_itx_case;
#define AV1T_ITX_COEFFS 1024 /* per case: the coded (at most 32x32) quadrant */
#define AV1T_ITX_RESIDUAL 4096

AV1G_HD void av1t_itx_run(av1t_itx_case c, const int16_t *q, int32_t *res, uint32_t *err, int32_t *dq) {
    av1g_dequant(q, dq, c.txSz, c.dcQ, c.acQ, av1g_qm(c.qmLevel >= 0, c.qmLevel, c.plane, c.txSz, c.txType));
    *err = 0;
    av1g_inv_txfm2d(dq, c.txSz, c.txType, res, err);
}

/* ---- 2./3. prediction + CfL ---- */
typedef struct av1t_pred_case {
    int32_t mode, delta, log2W, log2H, haveLeft, haveAbove, haveAR, haveBL, x, y, maxX, maxY, cfl, alpha, edgeFilter,
        filterType, fiMode;
} av1t_pred_case;
#define AV1T_PW 160 /* side of each case's plane; the luma plane for CfL is 2x */

AV1G_HD void av1t_pred_run(av1t_pred_case c, const uint8_t *plane, const uint8_t *luma, uint8_t *out) {
    uint8_t ea[AV1G_EDGE_LEN], el[AV1G_EDGE_LEN];
    uint8_t *A = ea + AV1G_EDGE_OFF, *L = el + AV1G_EDGE_OFF;
    /* copy the plane so prediction writes stay private */
    for (int i = 0; i < AV1T_PW * AV1T_PW; i++) out[i] = plane[i];
    av1g_build_edges(out, AV1T_PW, c.x, c.y, c.log2W, c.log2H, c.haveLeft, c.haveAbove, c.haveAR, c.haveBL, c.maxX,
                     c.maxY, A, L);
    av1g_predict_intra_ex(c.mode, c.delta, c.fiMode, c.edgeFilter, c.filterType, c.haveLeft, c.haveAbove, c.log2W,
                          c.log2H, c.x, c.y, c.maxX, c.maxY, A, L, out + c.y * AV1T_PW + c.x, AV1T_PW);
    if (c.cfl) {
        int txSz = -1;
        for (int t = 0; t < 19; t++)
            if (AV1G_T(Tx_Width_Log2)[t] == c.log2W && AV1G_T(Tx_Height_Log2)[t] == c.log2H) txSz = t;
        av1g_cfl_predict(out, AV1T_PW, luma, 2 * AV1T_PW, c.x, c.y, txSz, 1, 1, 2 * (c.x + (1 << c.log2W)),
                         2 * (c.y + (1 << c.log2H)), c.alpha);
    }
}

/* ---- 4. entropy coder ---- */
typedef struct av1t_sym { uint16_t cdfOff, s, N, isBool; } av1t_sym;

AV1G_HD int av1t_ec_stream(const av1t_sym *syms, int nsym, av1g_cdfs *cdf, uint16_t *pbuf, uint32_t cap,
                           uint8_t *out) {
    av1g_ec e;
    av1g_ec_init(&e, pbuf, cap);
    uint16_t *base = (uint16_t *)cdf;
    for (int i = 0; i < nsym; i++) {
        if (syms[i].isBool) av1g_ec_bool(&e, syms[i].s);
        else av1g_ec_symbol(&e, syms[i].s, base + syms[i].cdfOff, syms[i].N);
    }
    return av1g_ec_done(&e, out);
}

#endif
