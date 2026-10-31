// Every av1core header the kernels share, compiled as MSL (ShaderSourceTests).
#include "av1g/dsp.h"
#include "av1g/blockinfo.h"
#include "av1g/entenc.h"
#include "av1g/cdfctx.h"
#include "av1g/symstream.h"
#include "av1g/postfilter.h"

kernel void headers_check(device int *out [[buffer(0)]]) { out[0] = av1g_dc_q(out[1]); }

// The encoder's ported device headers, instantiated.
#include "dev_tx.h"

kernel void encoder_headers_check(device float *out [[buffer(0)]], uint lane [[thread_index_in_simdgroup]]) {
    threadgroup int16_t res[64], q[64];
    threadgroup float tmp[8 * 9];
    EvalIn e = {};
    e.txSz = AV1G_TX_8X8;
    e.txType = AV1G_DCT_DCT;
    e.dcQ = av1g_dc_q(100);
    e.acQ = av1g_ac_q(100);
    e.rnd = 0.5f;
    e.zbin = 0.5f;
    e.C = &g_cost[2][0];
    EvalOut o;
    for (int i = (int)lane; i < 64; i += 32) res[i] = (int16_t)(i - 32);
    warp_eval<8, 8>(res, tmp, q, e, o, (int)lane);
    if (lane == 0) { out[0] = o.D; out[1] = o.R; out[2] = (float)o.eob; out[3] = gp_lambda(100, 1.f); }
}
