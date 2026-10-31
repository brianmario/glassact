// The decoder's post-filters on the GPU (Glass Act): av1gpu's av1core/src/gpu_postfilter.cu
// (BSD-2, Sources/AV1Core/LICENSE), whose kernels are thin wrappers around av1g/postfilter.h,
// the implementation the CPU writer shares. Bit-exact with the decoder.
//
// Order (spec 7.14 / 7.15): p_mark fills the maps; p_deblock pass 0 (vertical edges), then
// pass 1 (horizontal), every plane at once; then CDEF reads the deblocked planes and writes
// separate output planes.
#include "cuda_compat.h"
#include "av1g/hd.h"
#include "av1g/enums_gen.h"
#include "av1g/spec_tables.h"
#include "av1g/dsp.h"
#include "av1g/blockinfo.h"
#include "av1g/postfilter.h"

kernel void p_mark(constant av1g_pf_frame &f [[buffer(0)]], device const av1g_block *blocks [[buffer(1)]],
                   constant uint32_t &n [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= n) return;
    const av1g_block b = blocks[i];
    av1g_pf_mark_block(&f, &b);
}

// one thread per (plane, 4x4 edge position); chroma positions in chroma 4x4 units
kernel void p_deblock(constant av1g_pf_frame &f [[buffer(0)]], constant int32_t &pass [[buffer(2)]],
                      uint3 g [[thread_position_in_grid]]) {
    const int plane = (int)g.z, sub = plane ? 1 : 0;
    const int col = (int)g.x, row = (int)g.y;
    if (col >= (f.MiCols >> sub) || row >= (f.MiRows >> sub)) return;
    av1g_lf_edge(&f, plane, pass, row << sub, col << sub);
}

kernel void p_cdef_dir(constant av1g_pf_frame &f [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
    const int bx = (int)g.x, by = (int)g.y;
    const int n8c = f.MiCols >> 1;
    if (bx >= n8c || by >= (f.MiRows >> 1)) return;
    int yDir = 0, var = 0;
    if (av1g_cdef_active_idx(&f, by * 2, bx * 2) >= 0)
        av1g_cdef_direction(f.plane[0] + (by * 8) * f.stride[0] + bx * 8, f.stride[0], &yDir, &var);
    f.cdefDirVar[by * n8c + bx] = (var << 3) | yDir;
}

// one thread per sample of one plane (z = plane: no luma/chroma divergence); outputs have the
// sources' strides
kernel void p_cdef(constant av1g_pf_frame &f [[buffer(0)]], device uint8_t *outY [[buffer(3)]],
                   device uint8_t *outU [[buffer(4)]], device uint8_t *outV [[buffer(5)]],
                   uint3 g [[thread_position_in_grid]]) {
    const int plane = (int)g.z, sub = plane ? 1 : 0;
    const int x = (int)g.x, y = (int)g.y;
    if (x >= (f.MiCols * 4) >> sub || y >= (f.MiRows * 4) >> sub) return;
    const int bx = x >> (3 - sub), by = y >> (3 - sub);  // 8x8 luma block index
    const int idx = av1g_cdef_active_idx(&f, by * 2, bx * 2);
    device const uint8_t *src = f.plane[plane];
    const int ss = f.stride[plane];
    int v = src[y * ss + x];
    if (idx >= 0) {
        const int dv = f.cdefDirVar[by * (f.MiCols >> 1) + bx];
        const av1g_cdef_blk b = av1g_cdef_params(&f, idx, dv & 7, dv >> 3);
        v = plane == 0 ? av1g_cdef_pixel(&f, src, ss, 0, x, y, b.yPri, b.ySec, f.cdefDamping, b.yDir)
                       : av1g_cdef_pixel(&f, src, ss, plane, x, y, b.uvPri, b.uvSec, f.cdefDamping - 1, b.uvDir);
    }
    device uint8_t *out = plane == 0 ? outY : plane == 1 ? outU : outV;
    out[y * ss + x] = (uint8_t)v;
}
