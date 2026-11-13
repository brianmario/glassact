// Test shims: av1g/dsp.h and av1g/blockinfo.h (header-inline functions), for the Rust port's
// differential tests (src/dsp/tests.rs, src/blockinfo.rs). Edge arrays are passed whole
// (AV1G_EDGE_LEN bytes, AboveRow[k] at index AV1G_EDGE_OFF + k).
#include <cstring>
#include "av1g/blockinfo.h"
#include "av1g/dsp.h"

extern "C" {

// small int-valued helpers, by name
long long oracle_dsp_int(const char *what, int a, int b, int c, int d) {
#define F(name, expr) if (!strcmp(what, name)) return (long long)(expr);
    F("get_tx_set_intra", av1g_get_tx_set_intra(a, b))
    F("chroma_tx_type", av1g_chroma_tx_type(a, b, c))
    F("tx_class", av1g_tx_class(a))
    F("dc_q", av1g_dc_q(a))
    F("ac_q", av1g_ac_q(a))
    F("dq_denom", av1g_dq_denom(a))
    F("dequant_coef", av1g_dequant_coef(a, b, c))
    F("qm_step", av1g_qm_step(a, av1g_qm(1, b, c, d >> 8, d & 255), 0))
    F("qm_level_allintra", av1g_qm_level_allintra(a))
    F("row_kind", av1g_row_kind(a))
    F("col_kind", av1g_col_kind(a))
    F("flip_ud", av1g_flip_ud(a))
    F("flip_lr", av1g_flip_lr(a))
    F("edge_strength", av1g_edge_strength(a, b, c, d))
    F("edge_use_upsample", av1g_edge_use_upsample(a, b, c, d))
    F("round2signed", av1g_round2signed(a, b))
    F("bw4", av1g_bw4(a))
    F("bh4", av1g_bh4(a))
    F("mi_cols", av1g_mi_cols(a))
    F("mi_rows", av1g_mi_rows(a))
    F("has_chroma", av1g_has_chroma(a, b, c, d))
    F("luma_tx_size", av1g_luma_tx_size(a, b))
    F("max_tx_depth", av1g_max_tx_depth(a))
    F("uv_bsize", av1g_uv_bsize(a))
    F("uv_tx_size", av1g_uv_tx_size(a))
    F("cfl_allowed", av1g_cfl_allowed(a))
    F("tx_coeffs", av1g_tx_coeffs(a))
#undef F
    return -999999;
}

const uint16_t *oracle_dsp_get_scan(int txSz, int txType) { return av1g_get_scan(txSz, txType); }
const uint8_t *oracle_dsp_qm(int using_qm, int level, int plane, int txSz, int txType) {
    return av1g_qm(using_qm, level, plane, txSz, txType);
}

void oracle_dsp_dequant(const int16_t *quant, int32_t *out, int txSz, int dcQ, int acQ, int using_qm, int level, int plane,
                        int txType) {
    av1g_dequant(quant, out, txSz, dcQ, acQ, av1g_qm(using_qm, level, plane, txSz, txType));
}

void oracle_dsp_inv_1d(int32_t *T, int kind, int n, int r, uint32_t *err) { av1g_inv_1d(T, kind, n, r, err); }

void oracle_dsp_add_residual(uint8_t *dst, int stride, const int32_t *res, int txSz, int txType) {
    av1g_add_residual(dst, stride, res, txSz, txType);
}

void oracle_dsp_build_edges(const uint8_t *plane, int stride, int x, int y, int log2W, int log2H, int haveLeft, int haveAbove,
                            int haveAboveRight, int haveBelowLeft, int maxX, int maxY, uint8_t *above, uint8_t *left) {
    av1g_build_edges(plane, stride, x, y, log2W, log2H, haveLeft, haveAbove, haveAboveRight, haveBelowLeft, maxX, maxY,
                     above + AV1G_EDGE_OFF, left + AV1G_EDGE_OFF);
}

int oracle_dsp_dc_value(const uint8_t *above, const uint8_t *left, int haveLeft, int haveAbove, int log2W, int log2H) {
    return av1g_dc_value(above + AV1G_EDGE_OFF, left + AV1G_EDGE_OFF, haveLeft, haveAbove, log2W, log2H);
}

int oracle_dsp_pred_pixel_up(int mode, int pAngle, int i, int j, int log2W, int log2H, const uint8_t *above,
                             const uint8_t *left, int upA, int upL) {
    return av1g_pred_pixel_up(mode, pAngle, i, j, log2W, log2H, above + AV1G_EDGE_OFF, left + AV1G_EDGE_OFF, upA, upL);
}

void oracle_dsp_edge_filter(uint8_t *buf, int sz, int strength) { av1g_edge_filter(buf + AV1G_EDGE_OFF, sz, strength); }
void oracle_dsp_edge_upsample(uint8_t *buf, int numPx) { av1g_edge_upsample(buf + AV1G_EDGE_OFF, numPx); }

void oracle_dsp_edge_prepare(int pAngle, int log2W, int log2H, int filterType, int haveLeft, int haveAbove, int x, int y,
                             int maxX, int maxY, uint8_t *above, uint8_t *left, int *upA, int *upL) {
    av1g_edge_prepare(pAngle, log2W, log2H, filterType, haveLeft, haveAbove, x, y, maxX, maxY, above + AV1G_EDGE_OFF,
                      left + AV1G_EDGE_OFF, upA, upL);
}

void oracle_dsp_predict_filter_intra(int mode, int log2W, int log2H, const uint8_t *above, const uint8_t *left, uint8_t *dst,
                                     int stride) {
    av1g_predict_filter_intra(mode, log2W, log2H, above + AV1G_EDGE_OFF, left + AV1G_EDGE_OFF, dst, stride);
}

void oracle_dsp_predict_intra(int mode, int angleDelta, int haveLeft, int haveAbove, int log2W, int log2H,
                              const uint8_t *above, const uint8_t *left, uint8_t *dst, int stride) {
    av1g_predict_intra(mode, angleDelta, haveLeft, haveAbove, log2W, log2H, above + AV1G_EDGE_OFF, left + AV1G_EDGE_OFF,
                       dst, stride);
}

void oracle_dsp_predict_intra_ex(int mode, int angleDelta, int filterIntraMode, int edgeFilter, int filterType, int haveLeft,
                                 int haveAbove, int log2W, int log2H, int x, int y, int maxX, int maxY, uint8_t *above,
                                 uint8_t *left, uint8_t *dst, int stride) {
    av1g_predict_intra_ex(mode, angleDelta, filterIntraMode, edgeFilter, filterType, haveLeft, haveAbove, log2W, log2H, x, y,
                          maxX, maxY, above + AV1G_EDGE_OFF, left + AV1G_EDGE_OFF, dst, stride);
}

void oracle_dsp_cfl_predict(uint8_t *chroma, int cstride, const uint8_t *luma, int lstride, int startX, int startY, int txSz,
                            int subX, int subY, int maxLumaW, int maxLumaH, int alpha) {
    av1g_cfl_predict(chroma, cstride, luma, lstride, startX, startY, txSz, subX, subY, maxLumaW, maxLumaH, alpha);
}

// ---- blockinfo.h ----

void oracle_bi_block_avail(int bsize, int mi_row, int mi_col, int mono, int r0, int r1, int c0, int c1, int *out4) {
    av1g_block_avail(bsize, mi_row, mi_col, mono, r0, r1, c0, c1, &out4[0], &out4[1], &out4[2], &out4[3]);
}

void oracle_bi_txb_edges(int plane, int x4, int y4, int txSz, uint32_t t, int xi, int yi, int availL, int availU, int tileR1,
                         int tileC1, const uint32_t *ordmap, int stride, int *out4) {
    av1g_txb_edges(plane, x4, y4, txSz, t, xi, yi, availL, availU, tileR1, tileC1, ordmap, stride, &out4[0], &out4[1],
                   &out4[2], &out4[3]);
}

int oracle_bi_get_filter_type(int plane, int mi_row, int mi_col, int availU, int availL, const uint8_t *yModes,
                              const uint8_t *uvModes, int miCols) {
    return av1g_get_filter_type(plane, mi_row, mi_col, availU, availL, yModes, uvModes, miCols);
}

// av1g_for_each_txb: writes (plane, txSz, x4, y4, xi, yi) per tx block into out (6 ints each), returns the count
int oracle_bi_for_each_txb(int bsize, int mi_row, int mi_col, int tx_depth, int mono, int mi_rows, int mi_cols, int *out,
                           int cap) {
    int k = 0;
    int n = av1g_for_each_txb(bsize, mi_row, mi_col, tx_depth, mono, mi_rows, mi_cols,
                              [&](int plane, int txSz, int x4, int y4, int xi, int yi) {
                                  if (k < cap) {
                                      int *o = out + 6 * k;
                                      o[0] = plane, o[1] = txSz, o[2] = x4, o[3] = y4, o[4] = xi, o[5] = yi;
                                  }
                                  k++;
                              });
    return n;
}

}  // extern "C"
