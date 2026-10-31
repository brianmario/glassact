// Glass Act: av1gpu's encoder/src/k_analysis.cuh (BSD-2, Sources/AV1Core/LICENSE), for Metal:
// the kernel's arguments come by reference from buffers and its thread indices are parameters;
// the per-warp scratch is threadgroup memory, its SATD sums threadgroup atomics; helpers take
// the lane; pointers into tables say AV1G_CONST. Instantiated per shape in encoder.metal.
// open-loop luma analysis, one warp per (image, block position) of one block shape.
//   1. edges from SOURCE pixels (open loop), spec availability approximated by Z-order
//   2. SATD screening (orthonormal 4x4 Hadamard) of the 13 modes at delta 0, then angle deltas
//      +-1..3 around the two best directional modes -> top-K by SATD + lambda_s * mode bits
//   3. exact-rate RD (float forward transform, dead-zone quantizer, AV1 default-CDF coefficient
//      rate) of the top-K with DCT_DCT, tx-type search for the winner
//   -> GpBlockRes {J, candidates best-first, tx type}
#pragma once
#include "dev_tx.h"

template <int W, int H>
struct ASmem {
    int16_t res[W * H];
    float tmp[TxD<W, H>::th * TxD<W, H>::TS];
    int16_t q[TxD<W, H>::n];
    uint8_t ea[AV1G_EDGE_LEN], el[AV1G_EDGE_LEN];
    uint8_t pa[AV1G_EDGE_LEN], pl[AV1G_EDGE_LEN];   // edge-filter prepared edges (RD stage)
    int up[2];
    float satd[32];
    int cand[32];
    int dcv;
};

__device__ __forceinline__ float hadamard4_abs(int *d) {
    // rows
#pragma unroll
    for (int i = 0; i < 4; i++) {
        int *r = d + 4 * i;
        int s0 = r[0] + r[1], s1 = r[0] - r[1], s2 = r[2] + r[3], s3 = r[2] - r[3];
        r[0] = s0 + s2; r[1] = s1 + s3; r[2] = s0 - s2; r[3] = s1 - s3;
    }
    int sum = 0;
#pragma unroll
    for (int j = 0; j < 4; j++) {
        int s0 = d[j] + d[4 + j], s1 = d[j] - d[4 + j], s2 = d[8 + j] + d[12 + j], s3 = d[8 + j] - d[12 + j];
        sum += abs(s0 + s2) + abs(s1 + s3) + abs(s0 - s2) + abs(s1 - s3);
    }
    return (float)sum * 0.25f;
}

__device__ __forceinline__ int pangle_of(int mode, int delta) {
    return av1g_is_directional(mode) ? AV1G_T(Mode_To_Angle)[mode] + delta * AV1G_ANGLE_STEP : 0;
}

// prediction of pixel (i, j) for candidate c, edges A/L, dc value dcv
__device__ __forceinline__ int pred_px(int c, int i, int j, int lw, int lh, const uint8_t *A, const uint8_t *L, int dcv) {
    const int m = cand_mode(c);
    if (m == AV1G_DC_PRED) return dcv;
    return av1g_pred_pixel(m, pangle_of(m, cand_delta(c)), i, j, lw, lh, A, L);
}

// SATD of candidates cands[c0..c1) (all 4x4 sub-blocks), accumulated into satd[]
template <int W, int H>
__device__ __forceinline__ void warp_screen(const uint8_t *src, int sp, const int *cands, int c0, int c1, threadgroup float *satd,
                                            const uint8_t *A, const uint8_t *L, int dcv, int lane, int sub = 1) {
    typedef TxD<W, H> T;
    constexpr int nsx = W / 4, nsub0 = (W / 4) * (H / 4);
    // sub == 2: checkerboard of 4x4 sub-blocks (nsx is even for every shape >= 256 pixels)
    const int nsub = sub == 2 ? nsub0 / 2 : nsub0;
    const int items = (c1 - c0) * nsub;
    for (int it = lane; it < items; it += 32) {
        const int ci = c0 + it / nsub;
        int sb = it % nsub;
        if (sub == 2) { const int r = (2 * sb) / nsx; sb = 2 * sb + (r & 1); }
        const int sx = (sb % nsx) * 4, sy = (sb / nsx) * 4;
        const int c = cands[ci];
        int d[16];
#pragma unroll
        for (int i = 0; i < 4; i++)
#pragma unroll
            for (int j = 0; j < 4; j++)
                d[i * 4 + j] = (int)src[(sy + i) * sp + sx + j] - pred_px(c, sy + i, sx + j, T::lw, T::lh, A, L, dcv);
        atomic_fetch_add_explicit((threadgroup atomic_float *)&satd[ci], hadamard4_abs(d), memory_order_relaxed);
    }
    __syncwarp();
}

// residual of candidate c into res (W x H), returns sum r^2 (all lanes).  With the intra edge filter,
// directional candidates use edges prepared by lane 0 into pa/pl (filter type 0: neighbour modes unknown).
template <int W, int H>
__device__ __forceinline__ float warp_residual(const uint8_t *src, int sp, int c, int16_t *res, const uint8_t *A,
                                               const uint8_t *L, int dcv, int lane, uint8_t *pa = nullptr, uint8_t *pl = nullptr,
                                               int *up = nullptr, int edgeFilter = 0, int haveL = 0, int haveA = 0, int x = 0,
                                               int y = 0, int maxX = 0, int maxY = 0) {
    typedef TxD<W, H> T;
    const int m = cand_mode(c);
    const bool ef = edgeFilter && av1g_is_directional(m);
    if (ef) {
        if (lane == 0) {
            for (int k = 0; k < AV1G_EDGE_LEN; k++) { pa[k] = A[k - AV1G_EDGE_OFF]; pl[k] = L[k - AV1G_EDGE_OFF]; }
            av1g_edge_prepare(pangle_of(m, cand_delta(c)), T::lw, T::lh, 0, haveL, haveA, x, y, maxX, maxY, pa + AV1G_EDGE_OFF,
                              pl + AV1G_EDGE_OFF, &up[0], &up[1]);
        }
        __syncwarp();
    }
    float e = 0.f;
    for (int p = lane; p < W * H; p += 32) {
        const int i = p / W, j = p % W;
        const int pr = ef ? av1g_pred_pixel_up(m, pangle_of(m, cand_delta(c)), i, j, T::lw, T::lh, pa + AV1G_EDGE_OFF,
                                               pl + AV1G_EDGE_OFF, up[0], up[1])
                          : pred_px(c, i, j, T::lw, T::lh, A, L, dcv);
        const int r = (int)src[i * sp + j] - pr;
        res[p] = (int16_t)r;
        e += (float)(r * r);
    }
    __syncwarp();
    return warp_sum(e);
}

template <int W, int H, int BS, int NW>
kernel void k_analysis(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                       constant uint32_t &nTotal [[buffer(2)]], uint blockIdx_x [[threadgroup_position_in_grid]],
                       uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]) {
    typedef TxD<W, H> T;
    threadgroup ASmem<W, H> smem[NW];
    const int warp = (int)threadIdx_x >> 5, lane = (int)threadIdx_x & 31;
    threadgroup ASmem<W, H> &S = smem[warp];
    threadgroup uint8_t *A = S.ea + AV1G_EDGE_OFF, *L = S.el + AV1G_EDGE_OFF;
    device const uint32_t *starts = B.shImgStart + (size_t)BS * (B.nimg + 1);
    constexpr int txSz = W == H ? (W == 4 ? AV1G_TX_4X4 : W == 8 ? AV1G_TX_8X8 : W == 16 ? AV1G_TX_16X16 : W == 32 ? AV1G_TX_32X32 : AV1G_TX_64X64)
                       : (W == 4 && H == 8) ? AV1G_TX_4X8 : (W == 8 && H == 4) ? AV1G_TX_8X4 : (W == 8 && H == 16) ? AV1G_TX_8X16
                       : (W == 16 && H == 8) ? AV1G_TX_16X8 : (W == 16 && H == 32) ? AV1G_TX_16X32 : (W == 32 && H == 16) ? AV1G_TX_32X16
                       : (W == 32 && H == 64) ? AV1G_TX_32X64 : (W == 64 && H == 32) ? AV1G_TX_64X32 : (W == 4 && H == 16) ? AV1G_TX_4X16
                       : (W == 16 && H == 4) ? AV1G_TX_16X4 : (W == 8 && H == 32) ? AV1G_TX_8X32 : (W == 32 && H == 8) ? AV1G_TX_32X8
                       : (W == 16 && H == 64) ? AV1G_TX_16X64 : AV1G_TX_64X16;
    const int set = av1g_get_tx_set_intra(txSz, 0);

    for (uint32_t gb = blockIdx_x * NW + warp; gb < nTotal; gb += gridDim_x * NW) {
        // image of this block (binary search over the per-image starts of this shape)
        int lo = 0, hi = B.nimg - 1;
        while (lo < hi) {
            const int mid = (lo + hi + 1) >> 1;
            if (starts[mid] <= gb) lo = mid; else hi = mid - 1;
        }
        device const GpImage &I = B.img[lo];
        const int nbx = I.shNbx[BS];
        uint32_t li = gb - starts[lo];
        if (B.sbList) {  // Glass Act: only the listed SBs (one image)
            const uint32_t per = (64 / W) * (64 / H), sb = B.sbList[gb / per], k = gb % per;
            const int bx = (int)(sb % I.sbCols) * (64 / W) + (int)(k % (64 / W));
            const int by = (int)(sb / I.sbCols) * (64 / H) + (int)(k / (64 / W));
            if (bx >= nbx || by >= I.shNby[BS]) continue;
            li = (uint32_t)(by * nbx + bx);
        }
        const int x = (int)(li % nbx) * W, y = (int)(li / nbx) * H;
        device GpBlockRes &out = B.blk[I.shOff[BS] + li];
        if (x >= I.MiCols * 4 || y >= I.MiRows * 4) {
            if (lane == 0) { out.J = GP_INF; out.ncand = 0; }
            continue;
        }
        if (B.sbKeep && B.sbKeep[I.sbBase + (y >> 6) * I.sbCols + (x >> 6)]) continue;  // Glass Act: unchanged source
        const TileBox tb = tile_of(I, x, y);
        const int haveLeft = x > tb.x0, haveAbove = y > tb.y0;
        const int haveAR = ol_decoded(x + W, y - 1, x, y, 0, tb);
        const int haveBL = ol_decoded(x - 1, y + H, x, y, 0, tb);
        const int maxX = I.MiCols * 4 - 1, maxY = I.MiRows * 4 - 1;
        device const uint8_t *src = I.src[0] + (size_t)y * I.spitch[0] + x;
        const int sp = I.spitch[0];
        const int qidx = sb_qindex(I, x, y);
        const float lambda = gp_lambda(qidx, P.lambdaMul) * ssim_scale(I, x, y, W, H);
        const float lamS = P.satdLambda * sqrtf(lambda);
        AV1G_CONST const float *C = g_cost[I.qctx];
        if (prune_flat(I, P, x, y, W, H, qidx)) {
            if (lane == 0) { out.J = GP_INF; out.ncand = 0; }
            __syncwarp();
            continue;
        }
        if (P.pruneVar > 0.f && W * H >= P.pruneMinArea) {
            float s1 = 0.f, s2 = 0.f;
            for (int p = lane; p < W * H; p += 32) {
                const float v = (float)src[(p / W) * sp + p % W];
                s1 += v;
                s2 += v * v;
            }
            s1 = warp_sum(s1);
            s2 = warp_sum(s2);
            const float var = s2 / (W * H) - (s1 / (W * H)) * (s1 / (W * H));
            const float st = av1g_ac_q(qidx) / 8.f;
            if (var > P.pruneVar * st * st) {
                if (lane == 0) { out.J = GP_INF; out.ncand = 0; }
                __syncwarp();
                continue;
            }
        }
        build_edges_par(I.src[0], sp, x, y, T::lw, T::lh, haveLeft, haveAbove, haveAR, haveBL, maxX, maxY, A, L, lane, 32);
        __syncwarp();
        if (lane == 0) S.dcv = av1g_dc_value(A, L, haveLeft, haveAbove, T::lw, T::lh);
        __syncwarp();
        const int dcv = S.dcv;
        device const GpExtCand *ext = (device const GpExtCand *)B.extCand[BS];
        int K = min((W * H >= 1024 && P.kLarge > 0) ? P.kLarge : P.K, GP_MAXK);
        int top[GP_MAXK];
        auto mbits = [&](int c) -> float {
            const int m = cand_mode(c);
            float b = g_avgYMode[m];
            if (BS >= AV1G_BLOCK_8X8 && av1g_is_directional(m)) b += C[CID(angle_delta[m - AV1G_V_PRED]) + cand_delta(c) + 3];
            return b;
        };
        if (ext) {
            // candidates from an external screener (optional hook, unused by default), best first
            device const GpExtCand *ec = ext + (size_t)(B.extOff[BS * B.nimg + lo] + li) * B.extTopK;
            int n = 0;
            for (int k = 0; k < B.extTopK && n < GP_MAXK; k++) {
                const int m = ec[k].mode;
                if (m >= 13) continue;
                const int d = (BS >= AV1G_BLOCK_8X8 && av1g_is_directional(m)) ? ec[k].delta : 0;
                if (lane == 0) S.cand[n] = cand_pack(m, d);
                top[n] = n;
                n++;
            }
            K = min(K, n);
            __syncwarp();
        } else {
        if (lane < 32) { S.satd[lane] = 0.f; S.cand[lane] = 0; }
        if (lane < 13) S.cand[lane] = cand_pack(lane, 0);
        __syncwarp();
        // ---- screening: 13 modes at delta 0 ----
        const int ssub = (P.screenSub == 2 && W * H >= 256) ? 2 : 1;
        warp_screen<W, H>(src, sp, S.cand, 0, 13, S.satd, A, L, dcv, lane, ssub);
        int ncand = 13;
        const bool allowDelta = P.deltas && BS >= AV1G_BLOCK_8X8 && (P.deltasMaxArea <= 0 || W * H <= P.deltasMaxArea);
        if (allowDelta) {
            // best two directional modes by screening cost
            int b0 = -1, b1 = -1;
            float j0 = GP_INF, j1 = GP_INF;
            for (int m = AV1G_V_PRED; m <= AV1G_D67_PRED; m++) {
                const float j = S.satd[m] + lamS * mbits(cand_pack(m, 0));
                if (j < j0) { j1 = j0; b1 = b0; j0 = j; b0 = m; }
                else if (j < j1) { j1 = j; b1 = m; }
            }
            if (lane < 12) {
                const int m = lane < 6 ? b0 : b1;
                const int k = lane % 6;
                const int d = k < 3 ? -(k + 1) : (k - 2);
                S.cand[13 + lane] = cand_pack(m, d);
            }
            __syncwarp();
            warp_screen<W, H>(src, sp, S.cand, 13, 25, S.satd, A, L, dcv, lane, ssub);
            ncand = 25;
        }
        // ---- top-K by screening cost (every lane computes the same selection) ----
        float topJ[GP_MAXK];
        for (int k = 0; k < K; k++) { top[k] = -1; topJ[k] = GP_INF; }
        for (int i = 0; i < ncand; i++) {
            const float j = S.satd[i] + lamS * mbits(S.cand[i]);
            if (j < topJ[K - 1]) {
                int k = K - 1;
                while (k > 0 && topJ[k - 1] > j) { topJ[k] = topJ[k - 1]; top[k] = top[k - 1]; k--; }
                topJ[k] = j; top[k] = i;
            }
        }
        }
        // ---- RD of the top-K with DCT_DCT ----
        const int hasC = av1g_has_chroma(BS, y >> 2, x >> 2, I.mono);
        const float overhead = (hasC ? P.uvOverheadBits : 0.f) + g_avgSkip0;
        EvalIn e;
        e.txSz = txSz; e.plane = 0;
        e.dcQ = av1g_dc_q(qidx); e.acQ = av1g_ac_q(qidx);
        e.rnd = P.rnd; e.zbin = P.zbin;
        e.skipCtx = 0; e.dcCtx = 0; e.reduced = 0; e.C = C;
        e.qmDist = P.qmDist; e.qmRnd = P.qmRnd;
        float bestJ = GP_INF;
        int bestK = 0, bestTx = AV1G_DCT_DCT;
        for (int k = 0; k < K; k++) {
            if (top[k] < 0) break;
            const int c = S.cand[top[k]];
            e.resEnergy = warp_residual<W, H>(src, sp, c, S.res, A, L, dcv, lane, S.pa, S.pl, S.up, I.edgeFilter, haveLeft, haveAbove, x, y, maxX, maxY);
            e.txType = AV1G_DCT_DCT;
            e.intraDir = cand_mode(c);
            e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, AV1G_DCT_DCT);
            EvalOut o;
            warp_eval<W, H>(S.res, S.tmp, S.q, e, o, lane);
            const float J = o.D + lambda * (o.R + mbits(c) + overhead);
            if (J < bestJ) { bestJ = J; bestK = k; }
        }
        // ---- tx-type search for the winner ----
        if (P.txSearch && set != AV1G_TX_SET_DCTONLY) {
            const int c = S.cand[top[bestK]];
            e.resEnergy = warp_residual<W, H>(src, sp, c, S.res, A, L, dcv, lane, S.pa, S.pl, S.up, I.edgeFilter, haveLeft, haveAbove, x, y, maxX, maxY);
            e.intraDir = cand_mode(c);
            for (int t = 1; t < 16; t++) {
                if (!av1g_tx_type_in_set_intra(set, t)) continue;
                e.txType = t;
                e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, t);
                EvalOut o;
                warp_eval<W, H>(S.res, S.tmp, S.q, e, o, lane);
                const float J = o.D + lambda * (o.R + mbits(c) + overhead);
                if (J < bestJ) { bestJ = J; bestTx = t; }
            }
        }
        if (lane == 0) {
            out.J = bestJ;
            out.tx = (uint8_t)bestTx;
            int n = 0;
            out.cand[n++] = (uint8_t)S.cand[top[bestK]];
            for (int k = 0; k < K && top[k] >= 0; k++)
                if (k != bestK) out.cand[n++] = (uint8_t)S.cand[top[k]];
            out.ncand = (uint8_t)n;
        }
        __syncwarp();
    }
}
