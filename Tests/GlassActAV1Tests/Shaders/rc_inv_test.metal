// RcInvTests: the closed loop's register-resident inverse transform (rc_inv.h),
// driven as k_recon's cta_inverse_add drives it: 128 threads take the rows,
// then the columns, of one tx block per threadgroup.
#include "av1g_test/dsp_cases.h"
#include "rc_inv.h"

#define NT 128

kernel void rc_inv_itx(device const av1t_itx_case *cases [[buffer(0)]], device const int16_t *coeffs [[buffer(1)]],
                       device int16_t *residual [[buffer(2)]], device uint32_t *flags [[buffer(3)]],
                       uint g [[threadgroup_position_in_grid]], uint t [[thread_position_in_threadgroup]]) {
    threadgroup int16_t res[64 * 64];
    threadgroup atomic_uint errFlag;
    const int tid = (int)t;
    const av1t_itx_case c = cases[g];
    const int txSz = c.txSz;
    const int W = av1g_tx_w(txSz), H = av1g_tx_h(txSz);
    const int lw = AV1G_T(Tx_Width_Log2)[txSz], lh = AV1G_T(Tx_Height_Log2)[txSz];
    const int tw = W > 32 ? 32 : W, th = H > 32 ? 32 : H;
    const int den = av1g_dq_denom(txSz);
    const int rk = av1g_row_kind(c.txType), ck = av1g_col_kind(c.txType);
    const int rowShift = AV1G_T(Transform_Row_Shift)[txSz];
    const bool rect = (lw - lh == 1 || lh - lw == 1);
    AV1G_CONST const uint8_t *qm = av1g_qm(c.qmLevel >= 0, c.qmLevel, c.plane, txSz, c.txType);
    device const int16_t *q = coeffs + g * AV1T_ITX_COEFFS;
    if (tid == 0) atomic_store_explicit(&errFlag, 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint32_t err = 0;
    switch (lw) {
#define RC_ROWS(LW) for (int i = tid; i < H; i += NT) err |= rci::row<LW>(i, th, tw, q, c.dcQ, c.acQ, qm, den, rect, rk, rowShift, res)
    case 2: RC_ROWS(2); break;
    case 3: RC_ROWS(3); break;
    case 4: RC_ROWS(4); break;
    case 5: RC_ROWS(5); break;
    default: RC_ROWS(6); break;
#undef RC_ROWS
    }
    if (err) atomic_fetch_or_explicit(&errFlag, err, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    err = 0;
    switch (lh) {
#define RC_COLS(LH) for (int j = tid; j < W; j += NT) err |= rci::col<LH>(j, W, ck, res)
    case 2: RC_COLS(2); break;
    case 3: RC_COLS(3); break;
    case 4: RC_COLS(4); break;
    case 5: RC_COLS(5); break;
    default: RC_COLS(6); break;
#undef RC_COLS
    }
    if (err) atomic_fetch_or_explicit(&errFlag, err, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (int p = tid; p < W * H; p += NT) residual[g * AV1T_ITX_RESIDUAL + p] = res[p];
    if (tid == 0) flags[g] = atomic_load_explicit(&errFlag, memory_order_relaxed);
}
