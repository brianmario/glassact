// structures shared by host code and the GPU kernels.
//
// Glass Act: av1gpu's encoder/src/gp.h (BSD-2, Sources/AV1Core/LICENSE). Pointer members are
// GPU addresses the host writes (MTLBuffer.gpuAddress), so on Metal they say `device` (GP_DEV),
// and `unsigned long long` is uint64_t, which both compilers spell the same width.
//
// One "batch" = many images encoded together.  All per-image state lives on the GPU; kernels
// index it through GpImage descriptors.  Stage overview (see docs/ARCHITECTURE.md):
//   analysis  per block shape: open-loop (source-edge) SATD screening of luma modes -> top-K,
//             exact-rate RD of the top-K (DCT_DCT), tx-type search for the winner     (k_analysis)
//   dp        per 64x64 SB: partition DP over the per-shape J grids -> leaf blocks   (k_dp)
//   recon     closed loop in SB wavefront order (2-SB lag): re-check top-K with the real
//             reconstructed edges + exact contexts, chroma modes / CfL, quantize, exact
//             inverse transform + reconstruction (bit-exact with the decoder)          (k_recon)
//   pack      per-SB outputs -> DecisionRecord arrays in decode order                 (k_pack)
//   entropy   av1core GPU symbolize + od_ec (or the CPU writer), OBUs, AVIF
#ifndef GP_H
#define GP_H

#include <stdint.h>
#if defined(__METAL_VERSION__)
#include "av1g/decisions.h"
#else
#include "av1g/av1g.h"  // AV1Core's module header, so Swift sees its types as AV1Core's
#endif

#if defined(__METAL_VERSION__)
#define GP_DEV device
#else
#define GP_DEV
#endif

// C names for the structs (Swift imports this header as C)
typedef struct GpParams GpParams;
typedef struct GpImage GpImage;
typedef struct GpBlockRes GpBlockRes;
typedef struct GpLeaf GpLeaf;
typedef struct GpSbOut GpSbOut;
typedef struct GpExtCand GpExtCand;
typedef struct GpBatch GpBatch;
typedef struct GpLeafDecision GpLeafDecision;
typedef struct GpInterRes GpInterRes;

#define GP_MAXK 6            // max top-K luma candidates kept per block by the analysis
#define GP_NSHAPES 22        // indexed by AV1 bsize (13..15 = 128-sizes, unused)
#define GP_MAX_LEAVES 256    // per 64x64 SB
#define GP_MAX_TXB 384       // per SB: 256 luma + 2 x 64 chroma
#define GP_SB_COEFFS 6144    // per SB: 64*64 + 2*32*32 (64-point tx store 32x32 only)
#define GP_RC_BIG_BYTES 18560  // per-CTA global scratch of k_recon for 32/64-point evaluations
#define GP_NCDF (sizeof(av1g_cdfs) / 2)
#define GP_ME_CANDS 8        // Glass Act: shift candidates per inter frame (GpImage.meCand)
#define GP_ME_KEEP 2         // Glass Act: motion vectors k_me keeps per 16x16

// Tunables (host -> kernels by value).
struct GpParams {
    float lambdaMul;     // multiplier on the libaom-style lambda (calibrate by BD-rate sweep)
    float satdLambda;    // screening: J_s = SATD + satdLambda * sqrt(lambda) * bits
    float rnd, zbin;     // dead-zone quantizer: q = |c|/step < zbin ? 0 : floor(|c|/step + rnd)
    float rndC, zbinC;   // same for chroma
    int K;               // luma candidates kept by the analysis (1..GP_MAXK)
    int Krecheck;        // candidates re-evaluated in the closed loop with real edges (1..K)
    int txSearch;        // 1: tx-type search (luma); 0: DCT_DCT only
    int txSearchCL;      // tx-type search again in the closed loop (real residual)
    int deltas;          // 0: no angle deltas, 1: +-1..3 around the best 2 directional modes
    int uvDeltas;        // reserved
    int cfl;             // 1: try CfL
    int uvK;             // chroma modes fully evaluated after SATD screening (>= 1)
    int shapeMask;       // bit per bsize (AV1G_BLOCK_*): shapes the analysis evaluates
    int partMask8, partMaskN;  // allowed partition types (bit per AV1G_PARTITION_*) at 8x8 / larger nodes
    int maxPart;         // largest node size allowing NONE/rect (64 or 32)
    float uvOverheadBits;  // open-loop estimate of chroma signalling per chroma-carrying block
    float splitBias;     // multiplies the J of PARTITION_NONE (1 = neutral)
    int rdoq;            // 1: greedy RDOQ in the closed loop
    float lambdaCMul;    // chroma lambda relative to luma
    int qmDist;          // 1: coefficient errors weighted by (32 / QM weight)^2 (libaom dist-metric=qm-psnr)
    int qmRnd;           // 1: rounding offset scaled by 32 / QM weight (libaom FP quantizer with QM)
    int smallKernel;     // 1: thread-per-block analysis for shapes <= 64 pixels
    float pruneVar;      // > 0: skip blocks of >= pruneMinArea pixels whose source variance > pruneVar * step_ac^2
    int pruneMinArea;
    int screenSub;       // 2: checkerboard-subsampled SATD screening for blocks >= 256 pixels
    int filterIntra;     // 1: filter-intra candidates in the closed loop (enable_filter_intra)
    int kLarge;          // > 0: K for shapes of >= 1024 pixels
    int deltasMaxArea;   // angle-delta screening only for shapes up to this area (0 = all)
    int profile;         // 1: per-phase clock64 accounting in k_recon (B.prof)
    int uvInDp;          // 1: add an open-loop chroma RD term to the analysis J (chroma-aware partitioning)
    int txSizeSearch;    // 1: closed-loop tx-size search (largest vs one split level), frame uses TX_MODE_SELECT
    int txAllCL;         // 1: closed loop evaluates every tx type for every re-checked candidate (no separate pass 2)
    int poisonSmem;      // debug: fill k_recon shared memory with 0x7F at CTA start (GP_POISON_SMEM)
    float pruneFlat;     // > 0: skip shapes < 16x16 inside 16x16 regions whose 8x8 variances are all < pruneFlat * step_ac^2
    // Glass Act: after the DP, decide every leaf's chroma mode / CfL and luma tx type open loop (k_leaf)
    int leafDecide;      // 1: run k_leaf (AV1HybridEncoder)
    int leafTxSearch;    // k_leaf searches luma tx types of blocks up to this many pixels (<= 256); 0: DCT_DCT
    int leafChromaAngled; // 1: k_leaf screens all 13 chroma modes; 0: not the six angled ones (D45 .. D67)
    // Glass Act: inter frames' motion search refines to quarter samples (k_me, k_inter); 0: whole samples
    int meSubpel;
};

// Per-image descriptor (device copy in an array; host fills it).
struct GpImage {
    int W, H;                // visible size
    int MiCols, MiRows;      // coded area in 4x4 units (picture padded to a multiple of 8)
    int sbCols, sbRows;
    int mono;
    int baseQ, qctx;         // base_q_idx, coefficient-CDF quantizer context (0..3)
    int dqRes;               // delta_q_res
    GP_DEV const uint8_t *sbQ;      // per-SB qindex (raster sbRows x sbCols); NULL = baseQ everywhere
    int usingQm, qm[3];      // quantizer matrices (level 15 = flat)
    int dqUDc, dqUAc, dqVDc, dqVAc;  // frame chroma delta-q (DeltaQUDc ...)
    int edgeFilter;          // enable_intra_edge_filter
    GP_DEV const float *ssimLog;    // per 16x16 cell: log of the normalised tune=iq SSIM rdmult scale (NULL = off)
    int cols16, rows16;
    GP_DEV const float *var16;      // per 16x16 cell: max per-pixel variance of its 8x8 blocks (flat pruning; NULL = off)
    GP_DEV const uint8_t *src[3];   // source planes, padded (replicated) to aw x ah (chroma aw/2 x ah/2)
    int spitch[3];
    GP_DEV uint8_t *rec[3];         // reconstruction planes, same geometry
    int rpitch[3];
    int aw, ah;
    // tiles (mi units; [n] = MiCols / MiRows)
    int tileCols, tileRows;
    int tileColStart[65], tileRowStart[65];
    // analysis grids per shape: blocks shOff[s] .. shOff[s] + shNbx[s]*shNby[s] in the shape arrays
    uint32_t shOff[GP_NSHAPES];
    int shNbx[GP_NSHAPES], shNby[GP_NSHAPES];
    uint32_t sbBase;         // first SB of this image in the global SB arrays (raster per image)
    // 4x4 maps (MiRows x MiCols, raster) for closed-loop contexts
    GP_DEV uint8_t *mYMode, *mUVMode, *mSkip, *mMiSize, *mTx;
    // per-plane 4x4 coefficient-context maps (culLevel, dcCategory); chroma (MiRows/2)x(MiCols/2)
    GP_DEV uint8_t *cLvl[3], *cDc[3];
    // Glass Act: an inter frame's motion search (k_me, k_inter). ref: the previous picture's luma
    // source, padded like src[0] (pitch spitch[0]); NULL: not an inter frame. meCand: the frame's
    // shift candidates (dx, dy: the block at (x, y) predicts from (x + dx, y + dy)).
    GP_DEV const uint8_t *ref;
    int nMeCand;
    int16_t meCand[2 * GP_ME_CANDS];
    // per 16x16 of the padded picture (aw / 16 x ah / 16, raster): k_me's best GP_ME_KEEP (dx, dy),
    // 1/8 luma sample
    GP_DEV int16_t *meBest;
};

// Analysis result per (shape, position).
struct GpBlockRes {
    float J;                   // best RD cost (luma, open loop) incl. mode bits
    uint8_t cand[GP_MAXK];     // candidates (mode << 3 | (delta + 3)), best first
    uint8_t ncand;
    uint8_t tx;                // best tx type for cand[0]
};

// Glass Act: the inter analysis per (shape, position), parallel to GpBlockRes (inter frames): when
// isInter, the block's J is its prediction from the previous picture at (dx, dy), 1/8 luma sample.
struct GpInterRes {
    int16_t dx, dy;
    uint8_t isInter;
    uint8_t pad[3];
};

// DP output: leaf blocks of one SB in decode order.
struct GpLeaf {
    uint8_t bsize;
    uint8_t x4, y4;            // position inside the SB in 4x4 units
    uint8_t pad;
};

// Glass Act: a leaf's open-loop decisions after the DP (k_leaf), parallel to leaves[]: chroma from
// the source (av1gpu's CPU reference engine's rule), luma tx type for the analysis's mode.
struct GpLeafDecision {
    uint8_t uvMode;
    int8_t angleUV, cflU, cflV;
    uint8_t lumaTx;
    uint8_t pad[3];
};

// Closed-loop outputs per SB (fixed-capacity slots, compacted by k_pack).
struct GpSbOut {
    uint32_t nBlocks, nTxb, nCoeffs;
    uint32_t pad;
};

// External candidate (optional external screener hook, 8 bytes; unused by default).
struct GpExtCand {
    float J;
    uint8_t mode;
    int8_t delta;
    uint8_t tx;
    uint8_t pad;
};

// Per-batch device pointers.
struct GpBatch {
    int nimg;
    GP_DEV GpImage *img;              // [nimg]
    GP_DEV GpBlockRes *blk;           // analysis results (all shapes, all images)
    GP_DEV uint32_t *shImgStart;      // [GP_NSHAPES][nimg + 1] first block of each image in shape s
    uint32_t nSb;              // total SBs
    GP_DEV uint32_t *sbImg;           // [nSb] image of each SB
    GP_DEV uint8_t *leafCount;        // [nSb] (0..255 means 1..256: stored as count-1)
    GP_DEV uint16_t *leafCountW;      // [nSb]
    GP_DEV GpLeaf *leaves;            // [nSb * GP_MAX_LEAVES]
    GP_DEV float *sbJ;                // [nSb] DP cost (stats)
    // closed-loop outputs
    GP_DEV GpSbOut *sbOut;            // [nSb]
    GP_DEV av1g_block *oBlocks;       // [nSb * GP_MAX_LEAVES]
    GP_DEV uint16_t *oBlockTxb;       // [nSb * GP_MAX_LEAVES] first txb (SB-local) of each block
    GP_DEV av1g_txb *oTxb;            // [nSb * GP_MAX_TXB]  (coeff_off SB-local)
    GP_DEV int16_t *oCoeffs;          // [nSb * GP_SB_COEFFS]
    GP_DEV uint32_t *stats;           // [16] counters
    // optional external screener: per shape [nblocks][extTopK] candidates, index extOff[s * nimg + img] + local
    GP_DEV const void *extCand[GP_NSHAPES];
    GP_DEV const int64_t *extOff;
    int extTopK;
    GP_DEV uint64_t *prof;       // [16] k_recon phase cycles (GpParams::profile)
    GP_DEV uint32_t *sbCyc;           // [nSb] k_recon cycles per SB (profile only, may be null)
    GP_DEV void *bigScratch;          // [max CTAs per wavefront step] x GP_RC_BIG_BYTES (k_recon)
    GP_DEV GpLeafDecision *leafDec;   // Glass Act: [nSb][GP_MAX_LEAVES] (k_leaf), may be null
    // Glass Act: per SB (raster), 1 = keep the previous picture's analysis, DP and leaf decisions
    // (the source it reads is unchanged); may be null (compute every SB)
    GP_DEV const uint8_t *sbKeep;
    // Glass Act: if set (one image), the analysis kernels and the DP visit only these SBs (raster),
    // nSbList of them: per shape the grid is nSbList x the shape's blocks per SB
    GP_DEV const uint32_t *sbList;
    uint32_t nSbList;
    // Glass Act: inter frames: per (shape, position), parallel to blk (NULL: an intra picture)
    GP_DEV GpInterRes *inter;
};

#endif
