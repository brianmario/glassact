// The GPU half of DSPEquivalenceTests: one thread per case runs the same
// av1g_test/dsp_cases.h function the CPU ran (av1gpu's gpu_dsp_test kernels).
#include "av1g_test/dsp_cases.h"

kernel void dsp_itx(device const av1t_itx_case *cases [[buffer(0)]], device const int16_t *coeffs [[buffer(1)]],
                    device int32_t *residual [[buffer(2)]], device uint32_t *flags [[buffer(3)]],
                    device int32_t *scratch [[buffer(4)]], constant uint &count [[buffer(5)]],
                    uint i [[thread_position_in_grid]]) {
    if (i >= count) return;
    av1t_itx_run(cases[i], coeffs + i * AV1T_ITX_COEFFS, residual + i * AV1T_ITX_RESIDUAL, flags + i,
                 scratch + i * AV1T_ITX_COEFFS);
}

kernel void dsp_pred(device const av1t_pred_case *cases [[buffer(0)]], device const uint8_t *planes [[buffer(1)]],
                     device const uint8_t *luma [[buffer(2)]], device uint8_t *out [[buffer(3)]],
                     constant uint &count [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    if (i >= count) return;
    av1t_pred_run(cases[i], planes + i * AV1T_PW * AV1T_PW, luma, out + i * AV1T_PW * AV1T_PW);
}

kernel void dsp_ec(device const av1t_sym *symbols [[buffer(0)]], device const int32_t *offsets [[buffer(1)]],
                   device const int32_t *counts [[buffer(2)]], device av1g_cdfs *cdfs [[buffer(3)]],
                   device uint16_t *precarry [[buffer(4)]], device uint8_t *out [[buffer(5)]],
                   device int32_t *sizes [[buffer(6)]], constant uint &capacity [[buffer(7)]],
                   constant uint &count [[buffer(8)]], constant int &qindex [[buffer(9)]],
                   uint i [[thread_position_in_grid]]) {
    if (i >= count) return;
    av1g_cdfs_init(&cdfs[i], qindex);
    sizes[i] = av1t_ec_stream(symbols + offsets[i], counts[i], &cdfs[i], precarry + i * capacity, capacity,
                              out + i * capacity);
}

