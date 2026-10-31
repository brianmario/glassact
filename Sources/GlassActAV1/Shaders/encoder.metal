// The Metal port of av1gpu's encoder (Glass Act): its kernels, instantiated.
//
// Analysis: one kernel per block shape, k_analysis_<W>x<H>_w<NW>. NW warps share a
// threadgroup: av1gpu's 4 (2 for 64-point shapes), fewer where their scratch would pass
// Metal's 32 KB of threadgroup memory (CUDA allows 48). The host reads NW from the name.
#include "k_analysis.h"

#define GA_AN_NW(W, H) (32768 / sizeof(ASmem<W, H>) >= 4 ? 4 : 32768 / sizeof(ASmem<W, H>))
#define GA_ANALYSIS(W, H, BS, NWS)                                                                          \
    template [[host_name("k_analysis_" #W "x" #H "_w" #NWS)]] kernel void k_analysis<W, H, BS, NWS>(       \
        constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],                              \
        constant uint32_t &nTotal [[buffer(2)]], uint blockIdx_x [[threadgroup_position_in_grid]],          \
        uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]);    \
    static_assert(NWS == GA_AN_NW(W, H), "k_analysis_" #W "x" #H ": NW must be " "the most that fits");

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
GA_ANALYSIS(16, 32, AV1G_BLOCK_16X32, 4)
GA_ANALYSIS(32, 16, AV1G_BLOCK_32X16, 4)
GA_ANALYSIS(32, 32, AV1G_BLOCK_32X32, 3)
GA_ANALYSIS(32, 64, AV1G_BLOCK_32X64, 2)
GA_ANALYSIS(64, 32, AV1G_BLOCK_64X32, 2)
GA_ANALYSIS(64, 64, AV1G_BLOCK_64X64, 1)
GA_ANALYSIS(16, 64, AV1G_BLOCK_16X64, 4)
GA_ANALYSIS(64, 16, AV1G_BLOCK_64X16, 4)

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

// Closed loop: one threadgroup of RC_NT (128) threads per 64x64, in wavefront steps.
#include "k_recon.h"
