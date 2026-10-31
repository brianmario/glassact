// The post-filters' frame for the Metal kernels (Shaders/postfilter.metal), as av1gpu's
// av1g_gpu_pf_prepare (av1core/src/gpu_postfilter.cu, BSD-2, Sources/AV1Core/LICENSE) sets it up.
#include "av1enc.h"
#include "av1g/postfilter.h"

#include <cstring>

extern "C" size_t av1enc_pf_frame(const av1g_frame_params *fp, const GaPfAddrs *a, void *out, size_t cap) {
    if (!fp || !a || !out || cap < sizeof(av1g_pf_frame)) return sizeof(av1g_pf_frame);
    av1g_pf_frame f;
    memset(&f, 0, sizeof f);
    av1g_pf_frame_init(fp, &f);
    for (int p = 0; p < 3; p++) {
        f.plane[p] = (uint8_t *)(uintptr_t)a->plane[p];
        f.stride[p] = a->stride[p];
        f.lfTx[p] = (uint8_t *)(uintptr_t)a->lfTx[p];
    }
    f.skip = (uint8_t *)(uintptr_t)a->skip;
    f.cdefIdx = (int8_t *)(uintptr_t)a->cdefIdx;
    f.cdefDirVar = (int32_t *)(uintptr_t)a->cdefDirVar;
    memcpy(out, &f, sizeof f);
    return sizeof f;
}
