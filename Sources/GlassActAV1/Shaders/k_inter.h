// Glass Act: inter frames' motion search, inside the open-loop analysis. Prediction is from the
// previous picture's source (GpImage.ref), so the analysis needn't wait for the previous picture's
// reconstruction and keeps overlapping the CPU's work; the closed loop predicts from the decoded
// picture, exactly. Vectors are in 1/8 luma sample (the bitstream's unit).
//   k_proj   one threadgroup per listed SB: long-range motion from row and column projections
//            (libaom's av1_int_pro_motion_estimation, for screen content): the SB's 64 row sums
//            matched against the previous picture's over +-192 rows, its 64 column sums over +-96
//            columns (doubled from 3840 wide), by the variance of the difference (so a fade still
//            matches); the horizontal, vertical and combined vectors checked by SAD, the best into
//            GpImage.meSb
//   k_me     one SIMD-group per 16x16 of the listed SBs: SAD (every other row) at whole-sample
//            vectors within +-8 of no motion, +-4 of each of the frame's shift candidates and +-4
//            of its SB's k_proj vector; the best refined to half and then quarter samples
//            (GpParams.meSubpel); keeps the best GP_ME_KEEP in GpImage.meBest
//   k_inter  one SIMD-group per (shape, position) of 8x8 and up, after k_analysis: SAD screening
//            of no motion and the vectors k_me kept for the 16x16s the block covers, then the
//            analysis's exact-rate RD (DCT_DCT) of the best; where it costs less than the intra
//            J, it takes its place (GpInterRes.isInter), and the partition DP weighs it as any other
// Sub-sample positions are predicted bilinearly here: an estimate of AV1's 8-tap filter, which only
// the closed loop needs exactly. (The 8-tap filter here measured 1 % smaller frames than bilinear
// on 720p photos for a third of the frame rate: BENCHMARKS.)
#pragma once
#include "k_analysis.h"

// k_me's vectors: index i < 289 is no motion's +-8 window, then 81 per candidate (+-4): the frame's
// shift candidates, then the SB's k_proj vector `sbv`
constant int GA_ME_ZERO = 289;
static inline int2 ga_me_vector(device const GpImage &I, int i, int2 sbv) {
    if (i < GA_ME_ZERO) return int2(i % 17 - 8, i / 17 - 8);
    const int j = i - GA_ME_ZERO, c = j / 81, o = j % 81;
    const int2 centre = c < min(I.nMeCand, GP_ME_CANDS) ? int2(I.meCand[2 * c], I.meCand[2 * c + 1]) : sbv;
    return centre + int2(o % 9 - 4, o / 9 - 4);
}

#define GA_PROJ_T 256
#define GA_PROJ_RY 192
#define GA_PROJ_RX 96
// the variance of a - b (64 terms), the projections' match cost
static inline float ga_proj_cost(threadgroup const int *a, threadgroup const int *b) {
    float s = 0.f, s2 = 0.f;
    for (int k = 0; k < 64; k++) {
        const float d = (float)(a[k] - b[k]);
        s += d;
        s2 += d * d;
    }
    return s2 - s * s / 64.f;
}

kernel void k_proj(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                   constant uint32_t &nSbs [[buffer(2)]], uint tg [[threadgroup_position_in_grid]],
                   uint tid [[thread_position_in_threadgroup]]) {
    constexpr int RYMAX = 2 * GA_PROJ_RY, RXMAX = 2 * GA_PROJ_RX;
    threadgroup int srow[64], scol[64], rrow[64 + 2 * RYMAX], rcol[64 + 2 * RXMAX];
    threadgroup float bestCost[GA_PROJ_T];
    threadgroup int bestOff[GA_PROJ_T];
    threadgroup uint sadOf[4];
    if (tg >= nSbs) return;
    device const GpImage &I = B.img[0];
    const uint32_t sb = B.sbList ? B.sbList[tg] : tg;
    const int x = (int)(sb % I.sbCols) * 64, y = (int)(sb / I.sbCols) * 64, sp = I.spitch[0];
    const int big = I.W >= 3840 ? 2 : 1, ry = GA_PROJ_RY * big, rx = GA_PROJ_RX * big;
    device const uint8_t *src = I.src[0], *ref = I.ref;
    // the SB's projections, and the previous picture's over the search range (outside it: none)
    for (int k = (int)tid; k < 64; k += GA_PROJ_T) {
        int r = 0, c = 0;
        for (int j = 0; j < 64; j++) {
            r += src[(size_t)(y + k) * sp + x + j];
            c += src[(size_t)(y + j) * sp + x + k];
        }
        srow[k] = r;
        scol[k] = c;
    }
    for (int k = (int)tid; k < 64 + 2 * ry; k += GA_PROJ_T) {
        const int row = y - ry + k;
        int r = -1;
        if (row >= 0 && row < I.ah) {
            r = 0;
            for (int j = 0; j < 64; j++) r += ref[(size_t)row * sp + x + j];
        }
        rrow[k] = r;
    }
    for (int k = (int)tid; k < 64 + 2 * rx; k += GA_PROJ_T) {
        const int col = x - rx + k;
        int c = -1;
        if (col >= 0 && col < I.aw) {
            c = 0;
            for (int j = 0; j < 64; j++) c += ref[(size_t)(y + j) * sp + col];
        }
        rcol[k] = c;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // best offset along one axis: each thread takes offsets, then a reduction (smaller |d| on ties)
    auto search = [&](threadgroup const int *a, threadgroup const int *b, int r) -> int {
        float bc = GP_INF;
        int bo = 0;
        for (int d = (int)tid - r; d <= r; d += GA_PROJ_T) {
            threadgroup const int *t = b + r + d;
            if (t[0] < 0 || t[63] < 0) continue;  // reaches outside the picture
            const float c = ga_proj_cost(a, t) * (1.f + 0.0005f * (float)abs(d));
            if (c < bc) { bc = c; bo = d; }
        }
        bestCost[tid] = bc;
        bestOff[tid] = bo;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint s = GA_PROJ_T / 2; s > 0; s >>= 1) {
            if (tid < s && (bestCost[tid + s] < bestCost[tid] ||
                            (bestCost[tid + s] == bestCost[tid] && abs(bestOff[tid + s]) < abs(bestOff[tid])))) {
                bestCost[tid] = bestCost[tid + s];
                bestOff[tid] = bestOff[tid + s];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        const int o = bestOff[0];
        threadgroup_barrier(mem_flags::mem_threadgroup);
        return o;
    };
    const int dy = search(srow, rrow, ry), dx = search(scol, rcol, rx);
    // the candidates by SAD over the SB (every 4th row): none, horizontal, vertical, both
    const int2 cand[4] = {int2(0, 0), int2(dx, 0), int2(0, dy), int2(dx, dy)};
    if (tid < 4) sadOf[tid] = 0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (int c = 0; c < 4; c++) {
        const int2 v = cand[c];
        if (x + v.x < 0 || y + v.y < 0 || x + v.x + 64 > I.aw || y + v.y + 64 > I.ah) {
            if (tid == 0) sadOf[c] = 0xFFFFFFFFu;
            continue;
        }
        uint sad = 0;
        for (int p = (int)tid; p < 16 * 64; p += GA_PROJ_T) {
            const int r = (p >> 6) * 4, cc = p & 63;
            sad += (uint)abs((int)src[(size_t)(y + r) * sp + x + cc] - (int)ref[(size_t)(y + r + v.y) * sp + x + cc + v.x]);
        }
        atomic_fetch_add_explicit((threadgroup atomic_uint *)&sadOf[c], sad, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        int b = 0;
        for (int c = 1; c < 4; c++)
            if (sadOf[c] < sadOf[b]) b = c;
        I.meSb[2 * sb] = (int16_t)cand[b].x;
        I.meSb[2 * sb + 1] = (int16_t)cand[b].y;
    }
}

// motion vector bits (v in 1/8 sample), roughly: is_inter and the mode, then per nonzero component
// its class and bits, and with sub-sample vectors its fraction
static inline float ga_mv_bits(int2 v, int subpel) {
    if (v.x == 0 && v.y == 0) return 3.f;
    float b = 4.f;
    if (v.x) b += 2.f + 2.f * log2((float)abs(v.x >> 3) + 1.f) + (subpel ? 2.f : 0.f);
    if (v.y) b += 2.f + 2.f * log2((float)abs(v.y >> 3) + 1.f) + (subpel ? 2.f : 0.f);
    return b;
}

// the reference sample at (x, y) + v (1/8 sample): bilinear between whole samples
static inline int ga_ref_px(device const uint8_t *ref, int sp, int x, int y, int2 v) {
    const int px = (x << 3) + v.x, py = (y << 3) + v.y;
    const int ix = px >> 3, iy = py >> 3, fx = px & 7, fy = py & 7;
    device const uint8_t *r = ref + (size_t)iy * sp + ix;
    if ((fx | fy) == 0) return r[0];
    const int a = r[0], b = r[1], c = r[sp], d = r[sp + 1];
    return ((8 - fx) * (8 - fy) * a + fx * (8 - fy) * b + (8 - fx) * fy * c + fx * fy * d + 32) >> 6;
}

// whether a W x H block at (x, y) + v reads only the padded reference (one more sample across a
// fractional position, for bilinear)
static inline bool ga_ref_inside(device const GpImage &I, int x, int y, int2 v, int W, int H) {
    const int x0 = x + (v.x >> 3), y0 = y + (v.y >> 3);
    return x0 >= 0 && y0 >= 0 && x0 + W + ((v.x & 7) != 0) <= I.aw && y0 + H + ((v.y & 7) != 0) <= I.ah;
}

#define GA_ME_NW 4
kernel void k_me(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                 constant uint32_t &nCells [[buffer(2)]], uint tg [[threadgroup_position_in_grid]],
                 uint lane [[thread_index_in_simdgroup]], uint warp [[simdgroup_index_in_threadgroup]]) {
    threadgroup uint8_t cur[GA_ME_NW][256];
    const uint32_t g = tg * GA_ME_NW + warp;
    if (g >= nCells) return;
    device const GpImage &I = B.img[0];
    const uint32_t sb = B.sbList ? B.sbList[g / 16] : g / 16, k = g % 16;
    const int x = (int)(sb % I.sbCols) * 64 + (int)(k % 4) * 16, y = (int)(sb / I.sbCols) * 64 + (int)(k / 4) * 16;
    const int sp = I.spitch[0];
    device const uint8_t *src = I.src[0] + (size_t)y * sp + x;
    for (int p = (int)lane; p < 256; p += 32) cur[warp][p] = src[(p >> 4) * sp + (p & 15)];
    simdgroup_barrier(mem_flags::mem_threadgroup);
    const int2 sbv = I.meSb ? int2(I.meSb[2 * sb], I.meSb[2 * sb + 1]) : int2(0, 0);
    const int n = GA_ME_ZERO + 81 * (min(I.nMeCand, GP_ME_CANDS) + (I.meSb && (sbv.x | sbv.y) ? 1 : 0));
    uint k0 = 0xFFFFFFFFu, k1 = 0xFFFFFFFFu;  // (sad << 11 | i): the lane's best two
    for (int i = (int)lane; i < n; i += 32) {
        const int2 v = ga_me_vector(I, i, sbv);
        const int rx = x + v.x, ry = y + v.y;
        if (rx < 0 || ry < 0 || rx > I.aw - 16 || ry > I.ah - 16) continue;
        device const uint8_t *r = I.ref + (size_t)ry * sp + rx;
        uint sad = 0;
        for (int row = 0; row < 16; row += 2)
            for (int col = 0; col < 16; col++) sad += (uint)abs((int)cur[warp][row * 16 + col] - (int)r[row * sp + col]);
        const uint key = (sad << 11) | (uint)i;
        if (key < k0) { k1 = k0; k0 = key; }
        else if (key < k1) k1 = key;
    }
    const uint b0 = simd_min(k0);
    const uint b1 = simd_min(k0 == b0 ? k1 : k0);
    // none found (every vector outside the picture): no motion
    int2 best[2] = {b0 == 0xFFFFFFFFu ? int2(0, 0) : ga_me_vector(I, (int)(b0 & 2047), sbv) * 8,
                    b1 == 0xFFFFFFFFu ? int2(0, 0) : ga_me_vector(I, (int)(b1 & 2047), sbv) * 8};
    if (P.meSubpel && b0 != 0xFFFFFFFFu) {
        // the best one to half, then quarter samples: the 8 neighbours at each step, every row
        uint bestSad = 0xFFFFFFFFu;
        for (int step = 4; step >= 2; step >>= 1) {
            const int2 c = best[0];
            // lanes 0..8: the centre (once, at the first step) and the 8 neighbours
            uint sad = 0xFFFFFFFFu;
            if (lane < 9 && (lane != 4 || step == 4)) {
                const int2 v = c + int2(((int)lane % 3 - 1) * step, ((int)lane / 3 - 1) * step);
                if (ga_ref_inside(I, x, y, v, 16, 16)) {
                    sad = 0;
                    for (int row = 0; row < 16; row++)
                        for (int col = 0; col < 16; col++)
                            sad += (uint)abs((int)cur[warp][row * 16 + col] - ga_ref_px(I.ref, sp, x + col, y + row, v));
                }
            }
            if (lane == 4 && step != 4) sad = bestSad;  // the centre, as the last step measured it
            const uint key = sad == 0xFFFFFFFFu ? 0xFFFFFFFFu : (sad << 4) | (lane == 4 ? 0u : lane + 1);  // centre first on ties
            const uint win = simd_min(lane < 9 ? key : 0xFFFFFFFFu);
            if (win != 0xFFFFFFFFu) {
                const uint l = (win & 15) == 0 ? 4 : (win & 15) - 1;
                best[0] = c + int2(((int)l % 3 - 1) * step, ((int)l / 3 - 1) * step);
                bestSad = win >> 4;
            }
        }
    }
    if (lane == 0) {
        device int16_t *o = I.meBest + ((size_t)(y >> 4) * (I.aw >> 4) + (x >> 4)) * 2 * GP_ME_KEEP;
        for (int j = 0; j < GP_ME_KEEP; j++) {
            o[2 * j] = (int16_t)best[j].x;
            o[2 * j + 1] = (int16_t)best[j].y;
        }
    }
}

template <int W, int H>
constexpr int ga_tx_of() {
    return W == H ? (W == 4 ? AV1G_TX_4X4 : W == 8 ? AV1G_TX_8X8 : W == 16 ? AV1G_TX_16X16 : W == 32 ? AV1G_TX_32X32 : AV1G_TX_64X64)
         : (W == 8 && H == 16) ? AV1G_TX_8X16 : (W == 16 && H == 8) ? AV1G_TX_16X8 : (W == 16 && H == 32) ? AV1G_TX_16X32
         : (W == 32 && H == 16) ? AV1G_TX_32X16 : (W == 32 && H == 64) ? AV1G_TX_32X64 : (W == 64 && H == 32) ? AV1G_TX_64X32
         : (W == 8 && H == 32) ? AV1G_TX_8X32 : (W == 32 && H == 8) ? AV1G_TX_32X8 : (W == 16 && H == 64) ? AV1G_TX_16X64
         : AV1G_TX_64X16;
}

template <int W, int H, int BS, int NW>
kernel void k_inter(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                    constant uint32_t &nTotal [[buffer(2)]], uint blockIdx_x [[threadgroup_position_in_grid]],
                    uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]) {
    threadgroup ASmem<W, H> smem[NW];
    const int warp = (int)threadIdx_x >> 5, lane = (int)threadIdx_x & 31;
    threadgroup ASmem<W, H> &S = smem[warp];
    constexpr int txSz = ga_tx_of<W, H>();
    for (uint32_t gb = blockIdx_x * NW + warp; gb < nTotal; gb += gridDim_x * NW) {
        device const GpImage &I = B.img[0];
        const int nbx = I.shNbx[BS];
        uint32_t li = gb;
        if (B.sbList) {
            const uint32_t per = (64 / W) * (64 / H), sb = B.sbList[gb / per], k = gb % per;
            const int bx = (int)(sb % I.sbCols) * (64 / W) + (int)(k % (64 / W));
            const int by = (int)(sb / I.sbCols) * (64 / H) + (int)(k / (64 / W));
            if (bx >= nbx || by >= I.shNby[BS]) continue;
            li = (uint32_t)(by * nbx + bx);
        }
        const int x = (int)(li % nbx) * W, y = (int)(li / nbx) * H;
        device GpBlockRes &out = B.blk[I.shOff[BS] + li];
        device GpInterRes &ir = B.inter[I.shOff[BS] + li];
        if (x >= I.MiCols * 4 || y >= I.MiRows * 4) {
            if (lane == 0) ir.isInter = 0;
            continue;
        }
        if (B.sbKeep && B.sbKeep[I.sbBase + (y >> 6) * I.sbCols + (x >> 6)]) continue;
        const int sp = I.spitch[0];
        device const uint8_t *src = I.src[0] + (size_t)y * sp + x;
        const int qidx = sb_qindex(I, x, y);
        const float lambda = gp_lambda(qidx, P.lambdaMul) * ssim_scale(I, x, y, W, H);
        const float lamS = P.satdLambda * sqrtf(lambda);
        // candidates: no motion, and k_me's vectors of the 16x16s covered (duplicates cost a little time)
        const int c0x = x >> 4, c0y = y >> 4, c1x = (x + W - 1) >> 4, c1y = (y + H - 1) >> 4;
        const int nc = 1 + (c1x - c0x + 1) * (c1y - c0y + 1) * GP_ME_KEEP;
        float bestS = GP_INF;
        int2 best = int2(0, 0);
        for (int c = 0; c < nc; c++) {
            int2 v = int2(0, 0);
            if (c > 0) {
                const int j = c - 1, cell = j / GP_ME_KEEP, kk = j % GP_ME_KEEP;
                const int cx = c0x + cell % (c1x - c0x + 1), cy = c0y + cell / (c1x - c0x + 1);
                device const int16_t *m = I.meBest + ((size_t)cy * (I.aw >> 4) + cx) * 2 * GP_ME_KEEP + 2 * kk;
                v = int2(m[0], m[1]);
            }
            if (!ga_ref_inside(I, x, y, v, W, H)) continue;
            float sad = 0.f;
            for (int p = lane; p < W * H; p += 32)
                sad += (float)abs((int)src[(p / W) * sp + p % W] - ga_ref_px(I.ref, sp, x + p % W, y + p / W, v));
            sad = warp_sum(sad) + lamS * ga_mv_bits(v, P.meSubpel);
            if (sad < bestS) { bestS = sad; best = v; }
        }
        // the best one's exact-rate RD, as the analysis costs an intra candidate
        float en = 0.f;
        for (int p = lane; p < W * H; p += 32) {
            const int d = (int)src[(p / W) * sp + p % W] - ga_ref_px(I.ref, sp, x + p % W, y + p / W, best);
            S.res[p] = (int16_t)d;
            en += (float)(d * d);
        }
        __syncwarp();
        EvalIn e;
        e.txSz = txSz; e.plane = 0; e.txType = AV1G_DCT_DCT;
        e.dcQ = av1g_dc_q(qidx); e.acQ = av1g_ac_q(qidx);
        e.rnd = P.rnd; e.zbin = P.zbin;
        e.skipCtx = 0; e.dcCtx = 0; e.reduced = 0; e.C = g_cost[I.qctx];
        e.qmDist = P.qmDist; e.qmRnd = P.qmRnd;
        e.resEnergy = warp_sum(en);
        e.intraDir = AV1G_DC_PRED;
        e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, AV1G_DCT_DCT);
        EvalOut o;
        warp_eval<W, H>(S.res, S.tmp, S.q, e, o, lane);
        const int hasC = av1g_has_chroma(BS, y >> 2, x >> 2, I.mono);
        const float J = o.D + lambda * (o.R + ga_mv_bits(best, P.meSubpel) + (hasC ? P.uvOverheadBits : 0.f) + g_avgSkip0);
        if (lane == 0) {
            const bool wins = J < out.J;
            if (wins) out.J = J;
            ir.dx = (int16_t)best.x;
            ir.dy = (int16_t)best.y;
            ir.isInter = wins ? 1 : 0;
        }
        __syncwarp();
    }
}
