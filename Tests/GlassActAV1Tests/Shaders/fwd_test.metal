// ForwardTransformTests: the encoder's float forward transform (dev_tx.h,
// with the generated g_fwd tables), one tx block per SIMD-group.
#include "dev_tx.h"

struct FwdCase { int txSz, txType; };

kernel void fwd_tx(device const FwdCase *cases [[buffer(0)]], device const int16_t *residual [[buffer(1)]],
                   device float *coeffs [[buffer(2)]], uint g [[threadgroup_position_in_grid]],
                   uint lane [[thread_index_in_simdgroup]]) {
    threadgroup int16_t res[64 * 64];
    threadgroup float tmp[32 * 65];
    const FwdCase c = cases[g];
    const int W = av1g_tx_w(c.txSz), H = av1g_tx_h(c.txSz);
    for (int i = (int)lane; i < W * H; i += 32) res[i] = residual[g * 4096 + i];
    simdgroup_barrier(mem_flags::mem_threadgroup);
    warp_fwd_rt(res, tmp, W, H, c.txSz, c.txType, (int)lane);
    const int tw = W > 32 ? 32 : W, th = H > 32 ? 32 : H;
    for (int p = (int)lane; p < tw * th; p += 32) coeffs[g * 1024 + p] = tmp[(p / tw) * (W + 1) + p % tw];
}
