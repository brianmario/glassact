// Test shims for the Rust port's testsupport module: sizeof / offsetof of the DSP case structs
// (av1g_test/dsp_cases.h) and of av1t_dsp_set (av1core_test.h), by name, as oracle_layout; the
// reference engine with all its options.
#include <cstddef>
#include <cstring>
#include "av1core_test.h"
#include "av1g_test/dsp_cases.h"

#define S(name, T) if (!strcmp(what, name)) return (long long)sizeof(T);
#define O(name, T, f) if (!strcmp(what, name "." #f)) return (long long)offsetof(T, f);

extern "C" long long oracle_testsupport_layout(const char *what) {
    S("ItxCase", av1t_itx_case)
    O("ItxCase", av1t_itx_case, txSz) O("ItxCase", av1t_itx_case, txType) O("ItxCase", av1t_itx_case, dcQ)
    O("ItxCase", av1t_itx_case, acQ) O("ItxCase", av1t_itx_case, qmLevel) O("ItxCase", av1t_itx_case, plane)
    S("PredCase", av1t_pred_case)
    O("PredCase", av1t_pred_case, mode) O("PredCase", av1t_pred_case, delta) O("PredCase", av1t_pred_case, log2W)
    O("PredCase", av1t_pred_case, log2H) O("PredCase", av1t_pred_case, haveLeft) O("PredCase", av1t_pred_case, haveAbove)
    O("PredCase", av1t_pred_case, haveAR) O("PredCase", av1t_pred_case, haveBL) O("PredCase", av1t_pred_case, x)
    O("PredCase", av1t_pred_case, y) O("PredCase", av1t_pred_case, maxX) O("PredCase", av1t_pred_case, maxY)
    O("PredCase", av1t_pred_case, cfl) O("PredCase", av1t_pred_case, alpha) O("PredCase", av1t_pred_case, edgeFilter)
    O("PredCase", av1t_pred_case, filterType) O("PredCase", av1t_pred_case, fiMode)
    S("Sym", av1t_sym)
    O("Sym", av1t_sym, cdfOff) O("Sym", av1t_sym, s) O("Sym", av1t_sym, N) O("Sym", av1t_sym, isBool)
    S("DspSet", av1t_dsp_set)
    O("DspSet", av1t_dsp_set, itx_count) O("DspSet", av1t_dsp_set, itx_flagged_count) O("DspSet", av1t_dsp_set, itx_cases)
    O("DspSet", av1t_dsp_set, itx_case_size) O("DspSet", av1t_dsp_set, itx_coeffs_per_case)
    O("DspSet", av1t_dsp_set, itx_residual_per_case) O("DspSet", av1t_dsp_set, itx_coeffs)
    O("DspSet", av1t_dsp_set, itx_residual) O("DspSet", av1t_dsp_set, itx_flags) O("DspSet", av1t_dsp_set, pred_count)
    O("DspSet", av1t_dsp_set, pred_cfl_count) O("DspSet", av1t_dsp_set, pred_side) O("DspSet", av1t_dsp_set, pred_cases)
    O("DspSet", av1t_dsp_set, pred_case_size) O("DspSet", av1t_dsp_set, pred_luma_size)
    O("DspSet", av1t_dsp_set, pred_planes) O("DspSet", av1t_dsp_set, pred_luma) O("DspSet", av1t_dsp_set, pred_out)
    O("DspSet", av1t_dsp_set, ec_count) O("DspSet", av1t_dsp_set, ec_qindex) O("DspSet", av1t_dsp_set, ec_symbol_count)
    O("DspSet", av1t_dsp_set, ec_capacity) O("DspSet", av1t_dsp_set, ec_cdfs_size)
    O("DspSet", av1t_dsp_set, ec_symbol_size) O("DspSet", av1t_dsp_set, ec_symbols) O("DspSet", av1t_dsp_set, ec_offsets)
    O("DspSet", av1t_dsp_set, ec_counts) O("DspSet", av1t_dsp_set, ec_sizes) O("DspSet", av1t_dsp_set, ec_bytes)
    O("DspSet", av1t_dsp_set, priv)
    return -1;
}

// ref_engine_encode with every RefEngineOpts field (av1t_ref_encode exposes six), mono included.
#include <string>
#include "tools.h"

struct oracle_ref_opts {
    int32_t qindex, min_block, max_block, angle_deltas, cfl, tx_types, reduced_tx_set;
    double split_bias;
    int32_t qm_level, qm_level_uv, deltaq, deltaq_res;
    double deltaq_strength;
    int32_t edge_filter, lf_level, lf_sharpness, cdef, cdef_y_pri, cdef_y_sec, cdef_uv_pri, cdef_uv_sec, cdef_damping;
};

extern "C" int oracle_testsupport_ref_encode(const uint8_t *y, const uint8_t *u, const uint8_t *v, uint32_t w,
                                             uint32_t h, int mono, const oracle_ref_opts *o, av1g_output *out) {
    av1g::Image img;
    img.W = (int)w;
    img.H = (int)h;
    img.mono = mono;
    const size_t cw = (w + 1) / 2, ch = (h + 1) / 2;
    img.p[0].assign(y, y + (size_t)w * h);
    if (!mono) {
        img.p[1].assign(u, u + cw * ch);
        img.p[2].assign(v, v + cw * ch);
    }
    av1g::RefEngineOpts r;
    r.qindex = o->qindex;
    r.min_block = o->min_block;
    r.max_block = o->max_block;
    r.angle_deltas = o->angle_deltas != 0;
    r.cfl = o->cfl != 0;
    r.tx_types = o->tx_types != 0;
    r.reduced_tx_set = o->reduced_tx_set;
    r.split_bias = o->split_bias;
    r.qm_level = o->qm_level;
    r.qm_level_uv = o->qm_level_uv;
    r.deltaq = o->deltaq;
    r.deltaq_res = o->deltaq_res;
    r.deltaq_strength = o->deltaq_strength;
    r.edge_filter = o->edge_filter != 0;
    r.lf_level = o->lf_level;
    r.lf_sharpness = o->lf_sharpness;
    r.cdef = o->cdef;
    r.cdef_y_pri = o->cdef_y_pri;
    r.cdef_y_sec = o->cdef_y_sec;
    r.cdef_uv_pri = o->cdef_uv_pri;
    r.cdef_uv_sec = o->cdef_uv_sec;
    r.cdef_damping = o->cdef_damping;
    av1g::OwnedRecord rec;
    std::string err;
    memset(out, 0, sizeof *out);
    int rc = av1g::ref_engine_encode(img, r, rec, out, nullptr, err);
    if (rc != AV1G_OK && !err.empty()) snprintf(out->error, sizeof out->error, "%s", err.c_str());
    return rc;
}
