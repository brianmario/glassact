// Glass Act: inter frames' motion search, inside the open-loop analysis. Prediction is from the
// previous picture's source (GpImage.ref), so the analysis needn't wait for the previous picture's
// reconstruction and keeps overlapping the CPU's work; the closed loop predicts from the decoded
// picture, exactly. Vectors are in 1/8 luma sample (the bitstream's unit).
//   k_me     one SIMD-group per 16x16 of the listed SBs: SAD (every other row) at whole-sample
//            vectors within +-8 of no motion and +-4 of each of the frame's shift candidates; the
//            best refined to half and then quarter samples (GpParams.meSubpel); keeps the best
//            GP_ME_KEEP in GpImage.meBest
//   k_inter  one SIMD-group per (shape, position) of 8x8 and up, after k_analysis: SAD screening
//            of no motion and the vectors k_me kept for the 16x16s the block covers, then the
//            analysis's exact-rate RD (DCT_DCT) of the best; where it costs less than the intra
//            J, it takes its place (GpInterRes.isInter), and the partition DP weighs it as any other
// Sub-sample positions are predicted bilinearly here: an estimate of AV1's 8-tap filter, which only
// the closed loop needs exactly. (The 8-tap filter here measured 1 % smaller frames than bilinear
// on 720p photos for a third of the frame rate: BENCHMARKS.)
#pragma once
#include "k_analysis.h"

// k_me's vectors: index i < 289 is no motion's +-8 window, then 81 per candidate (+-4)
constant int GA_ME_ZERO = 289;
static inline int2 ga_me_vector(device const GpImage &I, int i) {
    if (i < GA_ME_ZERO) return int2(i % 17 - 8, i / 17 - 8);
    const int j = i - GA_ME_ZERO, c = j / 81, o = j % 81;
    return int2(I.meCand[2 * c] + o % 9 - 4, I.meCand[2 * c + 1] + o / 9 - 4);
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
    const int n = GA_ME_ZERO + 81 * min(I.nMeCand, GP_ME_CANDS);
    uint k0 = 0xFFFFFFFFu, k1 = 0xFFFFFFFFu;  // (sad << 10 | i): the lane's best two
    for (int i = (int)lane; i < n; i += 32) {
        const int2 v = ga_me_vector(I, i);
        const int rx = x + v.x, ry = y + v.y;
        if (rx < 0 || ry < 0 || rx > I.aw - 16 || ry > I.ah - 16) continue;
        device const uint8_t *r = I.ref + (size_t)ry * sp + rx;
        uint sad = 0;
        for (int row = 0; row < 16; row += 2)
            for (int col = 0; col < 16; col++) sad += (uint)abs((int)cur[warp][row * 16 + col] - (int)r[row * sp + col]);
        const uint key = (sad << 10) | (uint)i;
        if (key < k0) { k1 = k0; k0 = key; }
        else if (key < k1) k1 = key;
    }
    const uint b0 = simd_min(k0);
    const uint b1 = simd_min(k0 == b0 ? k1 : k0);
    // none found (every vector outside the picture): no motion
    int2 best[2] = {b0 == 0xFFFFFFFFu ? int2(0, 0) : ga_me_vector(I, (int)(b0 & 1023)) * 8,
                    b1 == 0xFFFFFFFFu ? int2(0, 0) : ga_me_vector(I, (int)(b1 & 1023)) * 8};
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
