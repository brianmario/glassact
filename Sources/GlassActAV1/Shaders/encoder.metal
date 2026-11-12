// The Metal port of av1gpu's encoder (Glass Act): its kernels, instantiated.
//
// Analysis: one kernel per block shape, k_analysis_<W>x<H>_w<NW>. NW warps share a
// threadgroup: av1gpu's 4 (2 for 64-point shapes), fewer where their scratch would pass
// Metal's 32 KB of threadgroup memory (CUDA allows 48). The big shapes take a block a threadgroup
// on more threads (GA_ANALYSIS_T: k_analysis_<W>x<H>_w1t<NT>, 64 for 16x32 and 32x16, 128 for
// 32x32 and 64x64; BENCHMARKS "a block on several SIMD-groups"). The host reads NW (and NT) from
// the name.
#include "k_analysis.h"

#define GA_AN_NW(W, H) (32768 / sizeof(ASmem<W, H>) >= 4 ? 4 : 32768 / sizeof(ASmem<W, H>))
#define GA_ANALYSIS(W, H, BS, NWS)                                                                          \
    template [[host_name("k_analysis_" #W "x" #H "_w" #NWS)]] kernel void k_analysis<W, H, BS, NWS>(       \
        constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],                              \
        constant uint32_t &nTotal [[buffer(2)]], device const float *fwdM [[buffer(3)]],                    \
        uint blockIdx_x [[threadgroup_position_in_grid]],                                                   \
        uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]);    \
    static_assert(NWS <= GA_AN_NW(W, H), "k_analysis_" #W "x" #H ": its NW warps' scratch must fit");

// A block on NT threads (one block a threadgroup): k_analysis_<W>x<H>_w1t<NT>
#define GA_ANALYSIS_T(W, H, BS, NT)                                                                         \
    template [[host_name("k_analysis_" #W "x" #H "_w1t" #NT)]] kernel void k_analysis<W, H, BS, 1, NT>(     \
        constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],                              \
        constant uint32_t &nTotal [[buffer(2)]], device const float *fwdM [[buffer(3)]],                    \
        uint blockIdx_x [[threadgroup_position_in_grid]],                                                   \
        uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]);    \
    static_assert(sizeof(ASmem<W, H>) <= 32768, "k_analysis_" #W "x" #H ": its scratch must fit");

// Glass Act: the start-up check of warp_fwd_mma (AV1MetalEncoder.forwardMMAIsExact): a WxW residual
// a threadgroup of NT (as k_analysis runs the shape: 16x16 a SIMD-group, 32x32 and 64x64 on 128),
// through the matrix units and through the passes k_analysis otherwise runs (warp_eval's: warp_fwd_rt
// below 64 points, whose row pass takes the column pass's non-integer outputs, and warp_fwd_ct at
// 64), both results out as they leave tmp (scaled). have[0] = 1 where the matrix path is compiled.
template <int W, int NT>
kernel void k_fwd_mma_check(device const int16_t *res [[buffer(0)]], device float *outMMA [[buffer(1)]],
                            device float *outRef [[buffer(2)]], device uint *have [[buffer(3)]],
                            device const float *fwdM [[buffer(4)]],
                            uint g [[threadgroup_position_in_grid]], uint t [[thread_position_in_threadgroup]]) {
    constexpr int th = W > 32 ? 32 : W, TS = W + 1, N = W * W, NO = th * th, lw = W == 16 ? 4 : W == 32 ? 5 : 6;
    constexpr int txSz = W == 16 ? AV1G_TX_16X16 : W == 32 ? AV1G_TX_32X32 : AV1G_TX_64X64;
    threadgroup int16_t r[N];
    threadgroup float tmp[th * TS];
    const int lane = (int)t;
    for (int p = lane; p < N; p += NT) r[p] = res[g * N + p];
#ifdef GA_FWD_MMA
    ga_sync<NT>();
    warp_fwd_mma<W, NT>(r, tmp, fwdM + ga_fwd_matrix_offset(lw), g_txScale[txSz], lane);
    for (int p = lane; p < NO; p += NT) outMMA[g * NO + p] = tmp[(p / th) * TS + p % th];
    if (g == 0 && lane == 0) have[0] = 1;
#endif
    ga_sync<NT>();
    if (W == 64) warp_fwd_ct<W, W, NT>(r, tmp, txSz, AV1G_DCT_DCT, lane);
    else warp_fwd_rt<NT>(r, tmp, W, W, txSz, AV1G_DCT_DCT, lane);
    for (int p = lane; p < NO; p += NT) outRef[g * NO + p] = tmp[(p / th) * TS + p % th];
}
#define GA_MMA_CHECK(W, NT)                                                                                      \
    template [[host_name("k_fwd_mma_check_" #W)]] kernel void k_fwd_mma_check<W, NT>(                            \
        device const int16_t *res [[buffer(0)]], device float *outMMA [[buffer(1)]], device float *outRef [[buffer(2)]], \
        device uint *have [[buffer(3)]], device const float *fwdM [[buffer(4)]], uint g [[threadgroup_position_in_grid]], \
        uint t [[thread_position_in_threadgroup]]);
GA_MMA_CHECK(16, 32)
GA_MMA_CHECK(32, 128)
GA_MMA_CHECK(64, 128)

// Glass Act: the DCT matrices warp_fwd_mma reads, into a device buffer (dev_tx.h)
kernel void k_fwd_matrices(device float *out [[buffer(0)]], uint t [[thread_position_in_grid]]) {
    if (t >= GA_FWD_MATRIX_FLOATS) return;
    const int lw = t < 256 ? 4 : t < 1280 ? 5 : 6;
    out[t] = g_fwd[g_fwdOff[AV1G_K_DCT][lw] + ((int)t - ga_fwd_matrix_offset(lw))];
}

GA_ANALYSIS(4, 4, AV1G_BLOCK_4X4, 4)
GA_ANALYSIS(4, 8, AV1G_BLOCK_4X8, 4)
GA_ANALYSIS(8, 4, AV1G_BLOCK_8X4, 4)
GA_ANALYSIS(8, 8, AV1G_BLOCK_8X8, 4)
GA_ANALYSIS(4, 16, AV1G_BLOCK_4X16, 4)
GA_ANALYSIS(16, 4, AV1G_BLOCK_16X4, 4)
GA_ANALYSIS(8, 16, AV1G_BLOCK_8X16, 4)
GA_ANALYSIS(16, 8, AV1G_BLOCK_16X8, 4)
GA_ANALYSIS(16, 16, AV1G_BLOCK_16X16, 4)
GA_ANALYSIS(8, 32, AV1G_BLOCK_8X32, 4)
GA_ANALYSIS(32, 8, AV1G_BLOCK_32X8, 4)
GA_ANALYSIS_T(16, 32, AV1G_BLOCK_16X32, 64)
GA_ANALYSIS_T(32, 16, AV1G_BLOCK_32X16, 64)
GA_ANALYSIS_T(32, 32, AV1G_BLOCK_32X32, 128)
GA_ANALYSIS(32, 64, AV1G_BLOCK_32X64, 2)
GA_ANALYSIS(64, 32, AV1G_BLOCK_64X32, 2)
GA_ANALYSIS_T(64, 64, AV1G_BLOCK_64X64, 128)
GA_ANALYSIS(16, 64, AV1G_BLOCK_16X64, 3)
GA_ANALYSIS(64, 16, AV1G_BLOCK_64X16, 3)

// Inter frames' motion search (k_me, then k_inter per shape of 8x8 and up, after the analysis):
// k_inter_<W>x<H>_w<NW>, NW as the analysis's, for the shapes inside one 16x16 Q blocks a
// SIMD-group (_p<Q>, k_inter_q), and for those whose RD takes several SIMD-groups a block a
// SIMD-group before it (_p1, k_inter_s).
#include "k_inter.h"
#define GA_INTER(W, H, BS, NWS)                                                                            \
    template [[host_name("k_inter_" #W "x" #H "_w" #NWS)]] kernel void k_inter<W, H, BS, NWS>(            \
        constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],                              \
        constant uint32_t &nTotal [[buffer(2)]], uint blockIdx_x [[threadgroup_position_in_grid]],          \
        uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]);    \
    static_assert(NWS <= GA_AN_NW(W, H), "k_inter_" #W "x" #H ": its NW warps' scratch must fit");

// k_inter_<W>x<H>_w<NW>p<Q>: Q blocks a SIMD-group before the RD (k_inter_q)
#define GA_INTER_Q(W, H, BS, NWS, Q)                                                                       \
    template [[host_name("k_inter_" #W "x" #H "_w" #NWS "p" #Q)]] kernel void k_inter_q<W, H, BS, NWS, Q>( \
        constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],                              \
        constant uint32_t &nTotal [[buffer(2)]], uint blockIdx_x [[threadgroup_position_in_grid]],          \
        uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]);

// k_inter_<W>x<H>_w<NW>p1: a block a SIMD-group before an RD on all NW SIMD-groups (k_inter_s)
#define GA_INTER_S(W, H, BS, NWS)                                                                          \
    template [[host_name("k_inter_" #W "x" #H "_w" #NWS "p1")]] kernel void k_inter_s<W, H, BS, NWS * 32>( \
        constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],                              \
        constant uint32_t &nTotal [[buffer(2)]], uint blockIdx_x [[threadgroup_position_in_grid]],          \
        uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]);

GA_INTER_Q(8, 8, AV1G_BLOCK_8X8, 2, 8)
GA_INTER_Q(8, 16, AV1G_BLOCK_8X16, 2, 4)
GA_INTER_Q(16, 8, AV1G_BLOCK_16X8, 2, 4)
GA_INTER_Q(16, 16, AV1G_BLOCK_16X16, 2, 4)
GA_INTER(8, 32, AV1G_BLOCK_8X32, 4)
GA_INTER(32, 8, AV1G_BLOCK_32X8, 4)
GA_INTER_S(16, 32, AV1G_BLOCK_16X32, 2)
GA_INTER_S(32, 16, AV1G_BLOCK_32X16, 2)
GA_INTER_S(32, 32, AV1G_BLOCK_32X32, 4)
GA_INTER(32, 64, AV1G_BLOCK_32X64, 2)
GA_INTER(64, 32, AV1G_BLOCK_64X32, 2)
GA_INTER_S(64, 64, AV1G_BLOCK_64X64, 4)
GA_INTER(16, 64, AV1G_BLOCK_16X64, 3)
GA_INTER(64, 16, AV1G_BLOCK_64X16, 3)

// Partition DP: one thread per 64x64.
#include "k_dp.h"

// The layouts the host fills (Swift's import of gp.h) and the kernels read: EncoderLayoutTests
// compares them field by field.
kernel void ga_layout(device uint *out [[buffer(0)]]) {
    uint i = 0;
#define GA_OFF(T, f) out[i++] = (uint)__builtin_offsetof(T, f)
    out[i++] = sizeof(GpParams); GA_OFF(GpParams, satdLambda); GA_OFF(GpParams, K); GA_OFF(GpParams, shapeMask);
    GA_OFF(GpParams, uvOverheadBits); GA_OFF(GpParams, pruneFlat);
    out[i++] = sizeof(GpImage); GA_OFF(GpImage, sbQ); GA_OFF(GpImage, usingQm); GA_OFF(GpImage, ssimLog); GA_OFF(GpImage, src);
    GA_OFF(GpImage, spitch); GA_OFF(GpImage, rec); GA_OFF(GpImage, aw); GA_OFF(GpImage, tileColStart);
    GA_OFF(GpImage, shOff); GA_OFF(GpImage, sbBase); GA_OFF(GpImage, mYMode); GA_OFF(GpImage, cDc);
    out[i++] = sizeof(GpBlockRes); GA_OFF(GpBlockRes, cand); GA_OFF(GpBlockRes, tx);
    out[i++] = sizeof(GpLeaf); out[i++] = sizeof(GpSbOut);
    out[i++] = sizeof(GpBatch); GA_OFF(GpBatch, img); GA_OFF(GpBatch, nSb); GA_OFF(GpBatch, leaves); GA_OFF(GpBatch, oCoeffs);
    GA_OFF(GpBatch, extCand); GA_OFF(GpBatch, extTopK); GA_OFF(GpBatch, bigScratch);
    out[i++] = sizeof(av1g_block); out[i++] = sizeof(av1g_txb);
#undef GA_OFF
    out[i++] = 0xFFFFFFFFu;
}

// Analysis of the shapes up to 64 pixels, one thread per block (GpParams.smallKernel):
// k_analysis_small_<W>x<H>, dispatched in threadgroups of 128.
#include "k_analysis_small.h"
#define GA_SMALL(W, H, BS)                                                                                    \
    template [[host_name("k_analysis_small_" #W "x" #H)]] kernel void k_analysis_small<W, H, BS>(            \
        constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],                               \
        constant uint32_t &nTotal [[buffer(2)]], uint gb [[thread_position_in_grid]]);
GA_SMALL(4, 4, AV1G_BLOCK_4X4)
GA_SMALL(4, 8, AV1G_BLOCK_4X8)
GA_SMALL(8, 4, AV1G_BLOCK_8X4)
GA_SMALL(8, 8, AV1G_BLOCK_8X8)
GA_SMALL(4, 16, AV1G_BLOCK_4X16)
GA_SMALL(16, 4, AV1G_BLOCK_16X4)
GA_SMALL(8, 16, AV1G_BLOCK_8X16)  // Glass Act: upstream stops at 64 pixels; these measured faster too
GA_SMALL(16, 8, AV1G_BLOCK_16X8)

// Learned pruning of the analysis (before k_leaf, whose chroma model it defines).
#include "k_ml.h"

// The leaves' open-loop decisions after the DP (AV1HybridEncoder): one thread per leaf.
#include "k_leaf.h"

// Closed loop: one threadgroup of RC_NT (128) threads per 64x64, in wavefront steps.
#include "k_recon.h"
