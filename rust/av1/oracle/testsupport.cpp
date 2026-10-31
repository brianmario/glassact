// Test shims for the Rust port's testsupport module: sizeof / offsetof of the DSP case structs
// (av1g_test/dsp_cases.h) and of av1t_dsp_set (av1core_test.h), by name, as oracle_layout.
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
