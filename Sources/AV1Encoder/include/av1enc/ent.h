// Structures shared by the host and the GPU entropy kernels (Shaders/entropy.h).
//
// Glass Act: the FrameG / TileG / SbG / DevStatus of av1gpu's av1core/src/gpu_entropy.cu (BSD-2,
// Sources/AV1Core/LICENSE), for one picture rather than a batch: there are no frame indices or
// per-frame bases, and symbol offsets are 32-bit (a picture's items already fit in 31 bits).
// Pointers are GPU addresses the host writes (MTLBuffer.gpuAddress): `device` on Metal (GP_DEV).
#ifndef AV1ENC_ENT_H
#define AV1ENC_ENT_H

#include <stdint.h>
#include "av1enc/gp.h"

typedef struct GaEntFrame GaEntFrame;
typedef struct GaEntTile GaEntTile;
typedef struct GaEntSb GaEntSb;
typedef struct GaEntStatus GaEntStatus;
typedef struct GaEntBufs GaEntBufs;

#define GA_ENT_MAX_TILES 4096  // AV1's 64 x 64

// AV1G_GPU_ERR_* of av1core's gpu_entropy.h
enum { GA_ENT_ERR_SYMBOLS = 1, GA_ENT_ERR_OUTPUT = 2, GA_ENT_ERR_ORDER = 4 };

struct GaEntFrame {
    int32_t W, H, MiCols, MiRows, mono, qidx, reduced, txsel, sct, dq, dqRes, fi, cdefBits;  // cdefBits -1: CDEF off
    uint32_t ctxBase[3];  // per-plane offsets of the 4x4 context maps in ctxLvl / ctxDc
    int32_t ctxStride[3], ctxRows[3];
    uint32_t ctxTotal, miTotal;
    uint32_t nBlocks, nTxb, nSb, nTiles;
    int32_t tileCols, tileRows, tileWsb, tileHsb;  // uniform tile grid
    uint32_t symCap;                               // capacity of syms[], in symbols
};

struct GaEntTile {
    int32_t miRowStart, miRowEnd, miColStart, miColEnd;
    uint32_t firstBlock, endBlock;  // device-computed
    uint32_t sbBase, nSb;           // decode-order SB range
    int32_t sbRow0, sbCol0, sbCols;
};

struct GaEntSb {
    uint32_t tile, firstBlock, endBlock;
    int32_t r, c;
    int32_t qBefore;  // CurrentQIndex before this SB (the delta-q chain, per tile)
};

struct GaEntStatus {
    int32_t error;  // GA_ENT_ERR_* bits
    uint32_t symbols, symbolCapacity, reserved;
};

struct GaEntBufs {
    // the record
    GP_DEV const av1g_block *blocks;
    GP_DEV const uint32_t *blockTxb;
    GP_DEV const av1g_txb *txb;
    GP_DEV const int16_t *coeffs;
    // plan
    GP_DEV GaEntTile *tiles;
    GP_DEV GaEntSb *sbs;
    GP_DEV GaEntStatus *status;
    GP_DEV uint32_t *blockTile, *blockTxbG, *txbBlock, *sbFirst;  // blockTxbG: nBlocks + 1
    // mode info and coefficient context maps
    GP_DEV uint8_t *mMiSize, *mYMode, *mSkip, *mTx;
    GP_DEV uint8_t *ctxLvl, *ctxDc;
    GP_DEV uint16_t *txbEob;
    GP_DEV uint8_t *txbType;
    // symbols: one item per block and per tx block, in bitstream order
    GP_DEV uint32_t *count, *off;  // nBlocks + nTxb + 1
    GP_DEV uint32_t *syms;
    // per tile: symbol range, q, payload capacity / offset / size
    GP_DEV uint32_t *tb, *te;
    GP_DEV int32_t *tq;
    GP_DEV uint32_t *capArr, *capOff, *sizes;  // capArr, capOff: nTiles + 1
    GP_DEV uint8_t *staging;
    GP_DEV const uint16_t *cdfDefaults;  // 4 av1g_cdfs images, by coefficient q context
};

#endif
