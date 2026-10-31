// Every av1core header the kernels share, compiled as MSL (ShaderSourceTests).
#include "av1g/dsp.h"
#include "av1g/blockinfo.h"
#include "av1g/entenc.h"
#include "av1g/cdfctx.h"
#include "av1g/symstream.h"
#include "av1g/postfilter.h"

kernel void headers_check(device int *out [[buffer(0)]]) { out[0] = av1g_dc_q(out[1]); }
