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

// ---------------------------------------------------------------------------
// The strength search (av1gpu's av1f/src/lfsearch.cu, the AV1F_CDEF_AOM path with SSE): per-SB SSE
// of every candidate CDEF strength, then libaom's joint greedy preset search.
//
// Deviations from the CUDA: the direction table is flat (hd.h on Metal's multi-dimensional constant
// arrays); sums are SIMD-group reductions, and the search's per-pair totals are per-thread partials
// summed in a fixed order instead of 64-bit threadgroup atomics, which Metal doesn't have.

// GaCdefCand (av1enc.h)
struct LfCand {
    int pri[16], sec[4];
    int npri, nsec;
};

kernel void l_cdef_idx_norm(constant av1g_pf_frame &f [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    if ((int)i < f.sbCols * f.sbRows) f.cdefIdx[i] = f.cdefIdx[i] >= 0 ? 0 : -1;
}

// [dir][k][dy, dx]
constant int8_t lf_dirs[32] = {-1, 1, -2, 2, 0, 1, -1, 2, 0, 1, 0, 2, 0, 1, 1, 2,
                               1, 1, 2, 2,   1, 0, 2, 1,  1, 0, 2, 0, 1, 0, 2, -1};

// Taps of one direction set: primary at dir, secondary at dir -/+ 2; availability = frame bounds.
struct LfTaps {
    int p[4];  // primary samples (k = 0, 1) x (sign -1, +1); -1 = unavailable
    int s[8];  // secondary samples (k) x (sign) x (dir - 2, dir + 2)
    int mn, mx;
};

static inline int lf_tap(device const uint8_t *src, int stride, int x, int y, int dy, int dx, int sub, int MiRows, int MiCols) {
    const int yy = y + dy, xx = x + dx;
    if (yy < 0 || xx < 0 || ((yy << sub) >> 2) >= MiRows || ((xx << sub) >> 2) >= MiCols) return -1;
    return src[yy * stride + xx];
}

static inline void lf_gather(thread LfTaps &t, device const uint8_t *src, int stride, int x, int y, int dir, int sub,
                             int MiRows, int MiCols, int x0) {
    t.mn = t.mx = x0;
    for (int k = 0; k < 2; k++)
        for (int sg = 0; sg < 2; sg++) {
            const int sign = sg ? 1 : -1;
            int v = lf_tap(src, stride, x, y, sign * lf_dirs[dir * 4 + k * 2], sign * lf_dirs[dir * 4 + k * 2 + 1], sub, MiRows, MiCols);
            t.p[k * 2 + sg] = v;
            if (v >= 0) { t.mn = min(t.mn, v); t.mx = max(t.mx, v); }
            for (int o = 0; o < 2; o++) {
                const int dd = (dir + (o ? 2 : -2)) & 7;
                v = lf_tap(src, stride, x, y, sign * lf_dirs[dd * 4 + k * 2], sign * lf_dirs[dd * 4 + k * 2 + 1], sub, MiRows, MiCols);
                t.s[(k * 2 + sg) * 2 + o] = v;
                if (v >= 0) { t.mn = min(t.mn, v); t.mx = max(t.mx, v); }
            }
        }
}

static inline int lf_sec_sum(thread const LfTaps &t, int x0, int sec, int damping) {
    if (!sec) return 0;
    int s = 0;
    for (int i = 0; i < 8; i++)
        if (t.s[i] >= 0) s += (i < 4 ? 2 : 1) * av1g_cdef_constrain(t.s[i] - x0, sec, damping);  // Cdef_Sec_Taps[k]
    return s;
}

static inline int lf_pri_sum(thread const LfTaps &t, int x0, int adj, int damping) {
    if (!adj) return 0;
    const int w0 = (adj & 1) ? 3 : 4, w1 = (adj & 1) ? 3 : 2;  // Cdef_Pri_Taps[adj & 1]
    int s = 0;
    for (int i = 0; i < 4; i++)
        if (t.p[i] >= 0) s += (i < 2 ? w0 : w1) * av1g_cdef_constrain(t.p[i] - x0, adj, damping);
    return s;
}

#define LF_NPRI 2
#define LF_NSEC 2
#define LF_NC (LF_NPRI * LF_NSEC)

// one threadgroup (256 threads) per 64x64: luma, then both chroma planes; targets are the source
// planes, padded like the reconstruction, with its strides
static void lf_cdef_sse_sb(constant av1g_pf_frame &f, constant LfCand &cd, device const uint8_t *s0,
                           device const uint8_t *s1, device const uint8_t *s2, device uint32_t *mse_y,
                           device uint32_t *mse_uv, uint sb, uint tid, uint lane, uint warp,
                           threadgroup uint32_t (&red)[8][LF_NC]) {
    const int sbr = (int)sb / f.sbCols, sbc = (int)sb % f.sbCols;
    const bool active = f.cdefIdx[sb] >= 0;
    const int n8c = f.MiCols >> 1;
    for (int pass = 0; pass < (f.mono ? 1 : 2); pass++) {
        uint32_t acc[LF_NC];
        for (int j = 0; j < LF_NC; j++) acc[j] = 0;
        if (active) {
            const int npx = pass == 0 ? 4096 : 2048;
            for (int i = (int)tid; i < npx; i += 256) {
                int plane, x, y;
                if (pass == 0) { plane = 0; y = sbr * 64 + (i >> 6); x = sbc * 64 + (i & 63); }
                else { plane = 1 + (i >> 10); const int j = i & 1023; y = sbr * 32 + (j >> 5); x = sbc * 32 + (j & 31); }
                const int sub = plane ? 1 : 0;
                if (((x << sub) >> 2) >= f.MiCols || ((y << sub) >> 2) >= f.MiRows) continue;
                const int ly = y << sub, lx = x << sub;  // luma position of the sample's 8x8
                if (av1g_cdef_active_idx(&f, (ly >> 3) * 2, (lx >> 3) * 2) < 0) continue;
                const int dv = f.cdefDirVar[(ly >> 3) * n8c + (lx >> 3)];
                const int yDir = dv & 7, var = dv >> 3;
                int varStr = 0;
                if (var >> 6) { varStr = av1g_floor_log2((uint32_t)(var >> 6)); if (varStr > 12) varStr = 12; }
                device const uint8_t *src = f.plane[plane];
                const int st = f.stride[plane];
                device const uint8_t *tg = plane == 0 ? s0 : plane == 1 ? s1 : s2;
                const int damping = plane ? f.cdefDamping - 1 : f.cdefDamping;
                const int target = tg[y * st + x];
                const int x0 = src[y * st + x];
                LfTaps tA, t0;
                lf_gather(tA, src, st, x, y, yDir, sub, f.MiRows, f.MiCols, x0);
                lf_gather(t0, src, st, x, y, 0, sub, f.MiRows, f.MiCols, x0);
                int SA[LF_NSEC], S0[LF_NSEC];
                for (int si = 0; si < LF_NSEC; si++) {
                    SA[si] = lf_sec_sum(tA, x0, cd.sec[si], damping);
                    S0[si] = lf_sec_sum(t0, x0, cd.sec[si], damping);
                }
                for (int pi = 0; pi < LF_NPRI; pi++) {
                    const int pri = cd.pri[pi];
                    const int adj = sub ? pri : (var ? (pri * (4 + varStr) + 8) >> 4 : 0);
                    const int P = pri ? lf_pri_sum(tA, x0, adj, damping) : 0;
                    const int mn = pri ? tA.mn : t0.mn, mx = pri ? tA.mx : t0.mx;
                    for (int si = 0; si < LF_NSEC; si++) {
                        const int sum = P + (pri ? SA[si] : S0[si]);
                        int v = x0 + ((8 + sum - (sum < 0)) >> 4);
                        v = v < mn ? mn : v > mx ? mx : v;
                        const int e = v - target;
                        acc[pi * LF_NSEC + si] += (uint32_t)(e * e);
                    }
                }
            }
        }
        for (int j = 0; j < LF_NC; j++) {
            const uint32_t v = simd_sum(acc[j]);
            if (lane == 0) red[warp][j] = v;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid < LF_NC) {
            uint32_t t = 0;
            for (int w = 0; w < 8; w++) t += red[w][tid];
            (pass == 0 ? mse_y : mse_uv)[sb * LF_NC + tid] = t;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

kernel void l_cdef_sse(constant av1g_pf_frame &f [[buffer(0)]], constant LfCand &cd [[buffer(1)]],
                       device const uint8_t *s0 [[buffer(3)]], device const uint8_t *s1 [[buffer(4)]],
                       device const uint8_t *s2 [[buffer(5)]], device uint32_t *mse_y [[buffer(6)]],
                       device uint32_t *mse_uv [[buffer(7)]], uint sb [[threadgroup_position_in_grid]],
                       uint tid [[thread_position_in_threadgroup]], uint lane [[thread_index_in_simdgroup]],
                       uint warp [[simdgroup_index_in_threadgroup]]) {
    threadgroup uint32_t red[8][LF_NC];
    lf_cdef_sse_sb(f, cd, s0, s1, s2, mse_y, mse_uv, sb, tid, lane, warp, red);
}

// every active 64x64's preset: the cheapest of the chosen ones (first on ties)
kernel void l_assign(constant av1g_pf_frame &f [[buffer(0)]], device const uint32_t *my [[buffer(1)]],
                     device const uint32_t *muv [[buffer(2)]], device const int32_t *lev [[buffer(3)]],
                     constant int32_t *args [[buffer(4)]], uint sb [[thread_position_in_grid]]) {
    const int nc = args[0], nsb = args[1], mono = args[2], nb = args[3];
    if ((int)sb >= nsb) return;
    if (f.cdefIdx[sb] < 0) return;
    uint64_t b = ~(uint64_t)0;
    int bg = 0;
    for (int g = 0; g < nb; g++) {
        uint64_t c = my[sb * nc + lev[g]];
        if (!mono) c += muv[sb * nc + lev[8 + g]];
        if (c < b) { b = c; bg = g; }
    }
    f.cdefIdx[sb] = (int8_t)bg;
}

// ---------------------------------------------------------------------------
// Glass Act: the same filters over a list of 64x64s only (AV1MetalPostfilter.search with changed
// SBs): everything else keeps the previous picture's output. One thread per position of a listed
// SB; z = plane.

struct PfRegion {
    uint32_t n, sbCols;  // listed SBs, SBs per row
};

kernel void p_deblock_r(constant av1g_pf_frame &f [[buffer(0)]], constant int32_t &pass [[buffer(2)]],
                        constant PfRegion &R [[buffer(8)]], device const uint32_t *list [[buffer(9)]],
                        uint3 g [[thread_position_in_grid]]) {
    const int plane = (int)g.z, sub = plane ? 1 : 0;
    const uint32_t j = g.x / 256, k = g.x % 256;  // 16 x 16 luma 4x4 positions per SB, 8 x 8 chroma
    if (j >= R.n) return;
    const int side = 16 >> sub;
    if ((int)k >= side * side) return;
    const uint32_t sb = list[j];
    const int col = (int)(sb % R.sbCols) * side + (int)k % side, row = (int)(sb / R.sbCols) * side + (int)k / side;
    if (col >= (f.MiCols >> sub) || row >= (f.MiRows >> sub)) return;
    av1g_lf_edge(&f, plane, pass, row << sub, col << sub);
}

kernel void p_cdef_dir_r(constant av1g_pf_frame &f [[buffer(0)]], constant PfRegion &R [[buffer(8)]],
                         device const uint32_t *list [[buffer(9)]], uint gid [[thread_position_in_grid]]) {
    const uint32_t j = gid / 64, k = gid % 64;  // 8 x 8 blocks of 8x8 per SB
    if (j >= R.n) return;
    const uint32_t sb = list[j];
    const int bx = (int)(sb % R.sbCols) * 8 + (int)k % 8, by = (int)(sb / R.sbCols) * 8 + (int)k / 8;
    const int n8c = f.MiCols >> 1;
    if (bx >= n8c || by >= (f.MiRows >> 1)) return;
    int yDir = 0, var = 0;
    if (av1g_cdef_active_idx(&f, by * 2, bx * 2) >= 0)
        av1g_cdef_direction(f.plane[0] + (by * 8) * f.stride[0] + bx * 8, f.stride[0], &yDir, &var);
    f.cdefDirVar[by * n8c + bx] = (var << 3) | yDir;
}

kernel void p_cdef_r(constant av1g_pf_frame &f [[buffer(0)]], device uint8_t *outY [[buffer(3)]],
                     device uint8_t *outU [[buffer(4)]], device uint8_t *outV [[buffer(5)]],
                     constant PfRegion &R [[buffer(8)]], device const uint32_t *list [[buffer(9)]],
                     uint3 g [[thread_position_in_grid]]) {
    const int plane = (int)g.z, sub = plane ? 1 : 0;
    const uint32_t j = g.x / 4096, k = g.x % 4096;
    if (j >= R.n) return;
    const int side = 64 >> sub;
    if ((int)k >= side * side) return;
    const uint32_t sb = list[j];
    const int x = (int)(sb % R.sbCols) * side + (int)k % side, y = (int)(sb / R.sbCols) * side + (int)k / side;
    if (x >= (f.MiCols * 4) >> sub || y >= (f.MiRows * 4) >> sub) return;
    const int bx = x >> (3 - sub), by = y >> (3 - sub);
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

kernel void l_cdef_sse_r(constant av1g_pf_frame &f [[buffer(0)]], constant LfCand &cd [[buffer(1)]],
                         device const uint8_t *s0 [[buffer(3)]], device const uint8_t *s1 [[buffer(4)]],
                         device const uint8_t *s2 [[buffer(5)]], device uint32_t *mse_y [[buffer(6)]],
                         device uint32_t *mse_uv [[buffer(7)]], constant PfRegion &R [[buffer(8)]],
                         device const uint32_t *list [[buffer(9)]], uint tg [[threadgroup_position_in_grid]],
                         uint tid [[thread_position_in_threadgroup]], uint lane [[thread_index_in_simdgroup]],
                         uint warp [[simdgroup_index_in_threadgroup]]) {
    threadgroup uint32_t red[8][LF_NC];
    if (tg >= R.n) return;
    lf_cdef_sse_sb(f, cd, s0, s1, s2, mse_y, mse_uv, list[tg], tid, lane, warp, red);
}

// the SBs outside the region take the preset they had (their SSE rows, and so the assignment, are
// unchanged); the region's are assigned anew by l_assign_r
kernel void l_restore_idx(constant av1g_pf_frame &f [[buffer(0)]], device const int8_t *prev [[buffer(1)]],
                          device const uint8_t *inRegion [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if ((int)i >= f.sbCols * f.sbRows || inRegion[i]) return;
    if (f.cdefIdx[i] >= 0) f.cdefIdx[i] = prev[i];
}

kernel void l_assign_r(constant av1g_pf_frame &f [[buffer(0)]], device const uint32_t *my [[buffer(1)]],
                       device const uint32_t *muv [[buffer(2)]], device const int32_t *lev [[buffer(3)]],
                       constant int32_t *args [[buffer(4)]], constant PfRegion &R [[buffer(8)]],
                       device const uint32_t *list [[buffer(9)]], uint j [[thread_position_in_grid]]) {
    const int nc = args[0], mono = args[2], nb = args[3];
    if (j >= R.n) return;
    const uint32_t sb = list[j];
    if (f.cdefIdx[sb] < 0) return;
    uint64_t b = ~(uint64_t)0;
    int bg = 0;
    for (int g = 0; g < nb; g++) {
        uint64_t c = my[sb * nc + lev[g]];
        if (!mono) c += muv[sb * nc + lev[8 + g]];
        if (c < b) { b = c; bg = g; }
    }
    f.cdefIdx[sb] = (int8_t)bg;
}
