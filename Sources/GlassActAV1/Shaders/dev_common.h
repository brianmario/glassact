// Glass Act: av1gpu's encoder/src/dev_common.cuh (BSD-2, Sources/AV1Core/LICENSE), for Metal:
// - the derived tables come from the generated include (AV1Encoder/src/tables.cpp) instead of
//   __device__ globals filled with cudaMemcpyToSymbol;
// - CID is integer offsetof arithmetic, not pointer differences inside a dummy struct (see hd.h
//   on Metal's multi-dimensional constant arrays);
// - lambda is computed in float (Metal has no double);
// - warp shuffles are SIMD-group shuffles; pointers into tables say AV1G_CONST.
// device-side tables and helpers (included once, by kernels.cu).
#pragma once
#include "cuda_compat.h"
#include "av1g/hd.h"
#include "av1g/enums_gen.h"
#include "av1g/spec_tables.h"
#include "av1g/dsp.h"
#include "av1g/blockinfo.h"
#include "av1g/cdfctx.h"
#include "av1enc/gp.h"
#include "av1enc_tables.h"

#define GP_INF 3.0e38f

// ---------------------------------------------------------------------------
// forward transform matrices (float inverse of av1core's exact 1-D inverse transforms)
//   g_fwd + g_fwdOff[kind][log2n]: n x n row-major, coef[i] = sum_k F[i][k] * x[k]
//   kinds: AV1G_K_DCT (n 4..64), AV1G_K_ADST (4..16), AV1G_K_IDT (4..32)
// g_txg[txSz][txType]: pixel-domain energy per unit coefficient energy (orthogonal-up-to-scale)
// g_txScale[txSz]: 2^(rowShift + 4) / rect   (forward output scale, dequant domain)
// g_cost[qctx][cid]: symbol costs (bits) parallel to av1g_cdfs, per coefficient-CDF q-context
// g_avgYMode, g_avgPart, g_avgSkip0: open-loop averages over unknown neighbour contexts
// (all in av1enc_tables.h)
// ---------------------------------------------------------------------------

// cdf ids: uint16 offsets into av1g_cdfs (same convention as av1core gpu_entropy)
#define CID(expr) ((uint32_t)(__builtin_offsetof(av1g_cdfs, expr) / 2))

__device__ __forceinline__ float cost_of(AV1G_CONST const float *C, uint32_t cid, int s) { return C[cid + s]; }

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------
__device__ __forceinline__ float warp_sum(float v) {
    for (int o = 16; o > 0; o >>= 1) v += simd_shuffle_xor(v, (ushort)o);
    return v;
}
__device__ __forceinline__ int warp_max(int v) {
    for (int o = 16; o > 0; o >>= 1) v = max(v, simd_shuffle_xor(v, (ushort)o));
    return v;
}
__device__ __forceinline__ int warp_sumi(int v) {
    for (int o = 16; o > 0; o >>= 1) v += simd_shuffle_xor(v, (ushort)o);
    return v;
}

__device__ __forceinline__ int bw_px(int bs) { return 4 * av1g_bw4(bs); }
__device__ __forceinline__ int bh_px(int bs) { return 4 * av1g_bh4(bs); }

// libaom-style lambda (per bit, in 8-bit SSE units): rdmult = dc_q^2 * (3.3 + 0.0015 dc_q) * w/128 (tune=iq
// key frame), lambda = rdmult / 2048 (RDCOST: R in 1/512 bit units * rdmult >> 9, D = SSE * 16 << 7).
inline float gp_lambda(int qindex, float mul) {
    const int q = AV1G_T(Dc_Qlookup)[0][qindex < 0 ? 0 : qindex > 255 ? 255 : qindex];
    float rd = (float)q * q * (3.3f + 0.0015f * q);
    int w = ((255 - qindex) * 3) / 4;
    w = w < 0 ? 0 : w > 72 ? 72 : w;
    rd = rd * (128 + w) / 128.0f;
    return rd / 2048.0f * mul;
}

__device__ __forceinline__ int sb_qindex(const GpImage &I, int x, int y) {
    if (!I.sbQ) return I.baseQ;
    return I.sbQ[(y >> 6) * I.sbCols + (x >> 6)];
}

// quantizers of one block (spec: set_block_q)
struct BlockQ {
    int dcQ[3], acQ[3];
};
__device__ __forceinline__ BlockQ block_q(const GpImage &I, int qidx) {
    BlockQ q;
    q.dcQ[0] = av1g_dc_q(qidx); q.acQ[0] = av1g_ac_q(qidx);
    q.dcQ[1] = av1g_dc_q(qidx + I.dqUDc); q.acQ[1] = av1g_ac_q(qidx + I.dqUAc);
    q.dcQ[2] = av1g_dc_q(qidx + I.dqVDc); q.acQ[2] = av1g_ac_q(qidx + I.dqVAc);
    return q;
}

// tile containing luma pixel (x, y): bounds in pixels
struct TileBox { int x0, y0, x1, y1; };
__device__ __forceinline__ TileBox tile_of(const GpImage &I, int x, int y) {
    TileBox t;
    int c = 0, r = 0;
    while (c + 1 < I.tileCols && x >= I.tileColStart[c + 1] * 4) c++;
    while (r + 1 < I.tileRows && y >= I.tileRowStart[r + 1] * 4) r++;
    t.x0 = I.tileColStart[c] * 4; t.x1 = I.tileColStart[c + 1] * 4;
    t.y0 = I.tileRowStart[r] * 4; t.y1 = I.tileRowStart[r + 1] * 4;
    return t;
}

__device__ __forceinline__ int zorder16(int x, int y) {  // x, y in 0..15
    int z = 0;
    for (int b = 0; b < 4; b++) z |= (((x >> b) & 1) << (2 * b)) | (((y >> b) & 1) << (2 * b + 1));
    return z;
}

// Open-loop guess of "pixel (px,py) (plane units, sub = chroma shift) is decoded before the block at
// (x,y)": previous SB row and left SB as the spec's BlockDecoded init, Z-order inside the SB.
__device__ __forceinline__ bool ol_decoded(int px, int py, int x, int y, int sub, const TileBox &t) {
    const int tx0 = t.x0 >> sub, ty0 = t.y0 >> sub, tx1 = t.x1 >> sub, ty1 = t.y1 >> sub;
    if (px < tx0 || py < ty0 || px >= tx1 || py >= ty1) return false;
    const int S = 64 >> sub;
    const int sbx = (x / S) * S, sby = (y / S) * S;
    if (py < sby) return true;
    if (px < sbx) return py < sby + S;
    if (px >= sbx + S || py >= sby + S) return false;
    const int u = 4;  // 4x4 units of the plane
    return zorder16(((px - sbx) / u) & 15, ((py - sby) / u) & 15) < zorder16(((x - sbx) / u) & 15, ((y - sby) / u) & 15);
}

// candidate packing: mode << 3 | (delta + 3)
__device__ __forceinline__ int cand_mode(int c) { return c >> 3; }
__device__ __forceinline__ int cand_delta(int c) { return (c & 7) - 3; }
__device__ __forceinline__ int cand_pack(int m, int d) { return (m << 3) | (d + 3); }

// Parallel replica of av1g_build_edges (spec 7.11.2 edge preparation): threads tid = 0..nt-1 of a group
// fill AboveRow[-1 .. w+h-1] / LeftCol[-1 .. w+h-1].  Identical output (checked against the serial one).
__device__ __forceinline__ void build_edges_par(const uint8_t *plane, int stride, int x, int y, int lw, int lh, int haveL,
                                                int haveA, int haveAR, int haveBL, int maxX, int maxY, uint8_t *above,
                                                uint8_t *left, int tid, int nt) {
    const int w = 1 << lw, h = 1 << lh, n = w + h;
    int alim = x + (haveAR ? 2 * w : w) - 1;
    if (alim > maxX) alim = maxX;
    int llim = y + (haveBL ? 2 * h : h) - 1;
    if (llim > maxY) llim = maxY;
    for (int i = tid; i < n; i += nt) {
        uint8_t a, l;
        if (!haveA && haveL) a = plane[(size_t)y * stride + x - 1];
        else if (!haveA && !haveL) a = 127;
        else a = plane[(size_t)(y - 1) * stride + min(x + i, alim)];
        if (!haveL && haveA) l = plane[(size_t)(y - 1) * stride + x];
        else if (!haveL && !haveA) l = 129;
        else l = plane[(size_t)min(y + i, llim) * stride + x - 1];
        above[i] = a;
        left[i] = l;
    }
    if (tid == 0) {
        uint8_t c;
        if (haveA && haveL) c = plane[(size_t)(y - 1) * stride + x - 1];
        else if (haveA) c = plane[(size_t)(y - 1) * stride + x];
        else if (haveL) c = plane[(size_t)y * stride + x - 1];
        else c = 128;
        above[-1] = c;
        left[-1] = c;
    }
}

// tune=iq per-block rdmult scale: geometric mean of the per-16x16 SSIM factors the block covers
// (libaom av1_set_ssim_rdmult)
__device__ __forceinline__ float ssim_scale(const GpImage &I, int x, int y, int w, int h) {
    if (!I.ssimLog) return 1.f;
    const int c0 = x >> 4, r0 = y >> 4;
    const int nc = (w + 15) >> 4, nr = (h + 15) >> 4;
    float s = 0.f;
    int n = 0;
    for (int r = r0; r < r0 + nr && r < I.rows16; r++)
        for (int c = c0; c < c0 + nc && c < I.cols16; c++) { s += I.ssimLog[r * I.cols16 + c]; n++; }
    return n ? __expf(s / n) : 1.f;
}

// flat-area pruning of shapes below 16x16 (GpParams::pruneFlat)
__device__ __forceinline__ bool prune_flat(const GpImage &I, const GpParams &P, int x, int y, int W, int H, int qidx) {
    if (P.pruneFlat <= 0.f || !I.var16 || W * H >= 256) return false;
    const int cx = x >> 4, cy = y >> 4;
    if ((cx + 1) * 16 > I.MiCols * 4 || (cy + 1) * 16 > I.MiRows * 4) return false;   // incomplete region: keep
    const float st = av1g_ac_q(qidx) / 8.f;
    return I.var16[cy * I.cols16 + cx] < P.pruneFlat * st * st;
}
