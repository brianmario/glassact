// Glass Act: av1gpu's encoder/src/k_analysis_small.cuh (BSD-2, Sources/AV1Core/LICENSE), for Metal,
// with k_analysis.h's conventions: arguments by reference from buffers, the thread index a parameter,
// pointers into tables AV1G_CONST, into images `device`. Instantiated per shape in encoder.metal.
// open-loop analysis for small block shapes (W*H <= 64: 4x4, 4x8, 8x4, 8x8, 4x16, 16x4),
// ONE THREAD PER BLOCK: the same algorithm as k_analysis (SATD screening of 13 modes + angle deltas,
// top-K, exact-rate RD with DCT_DCT, tx-type search for the winner) in scalar code - no shuffles, no
// syncs, 32 blocks per warp instead of one.
#pragma once
#include "dev_tx.h"
#include "k_analysis.h"

template <int W, int H>
struct SmallTx {
    static constexpr constant int lw = TxD<W, H>::lw, lh = TxD<W, H>::lh;
    static constexpr constant int n = W * H;
};

// scalar forward transform: out[i][j] (H x W, row-major, no 32-clipping needed for these sizes)
template <int W, int H>
__device__ __forceinline__ void fwd_scalar(const int16_t *res, float *out, int txSz, int txType) {
    const int rk = av1g_row_kind(txType), ck = av1g_col_kind(txType);
    const int fud = av1g_flip_ud(txType), flr = av1g_flip_lr(txType);
    AV1G_CONST const float *Fc = g_fwd + g_fwdOff[ck][SmallTx<W, H>::lh];
    AV1G_CONST const float *Fr = g_fwd + g_fwdOff[rk][SmallTx<W, H>::lw];
    float tmp[H * W];
    // columns
#pragma unroll
    for (int j = 0; j < W; j++) {
        const int jj = flr ? W - 1 - j : j;
#pragma unroll
        for (int i = 0; i < H; i++) {
            float s = 0.f;
            if (ck == AV1G_K_IDT) s = __ldg(&Fc[i * H + i]) * (float)res[(fud ? H - 1 - i : i) * W + jj];
            else {
#pragma unroll
                for (int k = 0; k < H; k++) s = fmaf(__ldg(&Fc[i * H + k]), (float)res[(fud ? H - 1 - k : k) * W + jj], s);
            }
            tmp[i * W + j] = s;
        }
    }
    const float scale = g_txScale[txSz];
#pragma unroll
    for (int i = 0; i < H; i++)
#pragma unroll
        for (int j = 0; j < W; j++) {
            float s = 0.f;
            if (rk == AV1G_K_IDT) s = __ldg(&Fr[j * W + j]) * tmp[i * W + j];
            else {
#pragma unroll
                for (int k = 0; k < W; k++) s = fmaf(__ldg(&Fr[j * W + k]), tmp[i * W + k], s);
            }
            out[i * W + j] = s * scale;
        }
}

template <int W, int H>
__device__ __forceinline__ EvalOut eval_scalar(const int16_t *res, thread const EvalIn &e) {
    constexpr int n = W * H;
    float c[n];
    int16_t q[n];
    fwd_scalar<W, H>(res, c, e.txSz, e.txType);
    const int den = av1g_dq_denom(e.txSz);
    float dist = 0.f;
    for (int idx = 0; idx < n; idx++) {
        const float v = c[idx];
        const int step = av1g_qm_step(idx == 0 ? e.dcQ : e.acQ, e.qm, idx);
        const float a = fabsf(v) * (float)den / (float)step;
        const float wr = e.qm ? 32.f / (float)e.qm[idx] : 1.f;
        int l = a < e.zbin ? 0 : (int)(a + (e.qmRnd ? e.rnd * wr : e.rnd));
        l = min(l, 16383);
        const int qv = v < 0 ? -l : l;
        q[idx] = (int16_t)qv;
        const float dq = l ? (float)av1g_dequant_coef(qv, step, den) : 0.f;
        const float d = v - dq;
        dist = fmaf(d * d, e.qmDist ? wr * wr : 1.f, dist);
    }
    AV1G_CONST const uint16_t *scan = av1g_get_scan(e.txSz, e.txType);
    int eob = 0;
    for (int k = n - 1; k >= 0; k--)
        if (q[scan[k]]) { eob = k + 1; break; }
    float bits = base_bits(e, eob);
    if (eob > 0) {
        const int txClass = av1g_tx_class(e.txType);
        for (int k = 0; k < eob; k++) bits += coeff_bits(k, eob, q, scan, e.txSz, txClass, 0, e.dcCtx, e.C);
    }
    EvalOut o;
    o.D = g_txg[e.txSz][e.txType] * dist;
    o.R = bits;
    o.eob = eob;
    return o;
}

template <int W, int H, int BS>
kernel void k_analysis_small(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                             constant uint32_t &nTotal [[buffer(2)]], uint gb [[thread_position_in_grid]]) {
    typedef SmallTx<W, H> T;
    if (gb >= nTotal) return;
    device const uint32_t *starts = B.shImgStart + (size_t)BS * (B.nimg + 1);
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
        if (bx >= nbx || by >= I.shNby[BS]) return;
        li = (uint32_t)(by * nbx + bx);
    }
    const int x = (int)(li % nbx) * W, y = (int)(li / nbx) * H;
    device GpBlockRes &out = B.blk[I.shOff[BS] + li];
    if (x >= I.MiCols * 4 || y >= I.MiRows * 4) { out.J = GP_INF; out.ncand = 0; return; }
    if (B.sbKeep && B.sbKeep[I.sbBase + (y >> 6) * I.sbCols + (x >> 6)]) return;  // unchanged source
    constexpr int txSz = (W == 4 && H == 4) ? AV1G_TX_4X4 : (W == 8 && H == 8) ? AV1G_TX_8X8 : (W == 4 && H == 8) ? AV1G_TX_4X8
                       : (W == 8 && H == 4) ? AV1G_TX_8X4 : (W == 4 && H == 16) ? AV1G_TX_4X16 : (W == 16 && H == 4) ? AV1G_TX_16X4
                       : (W == 8 && H == 16) ? AV1G_TX_8X16 : AV1G_TX_16X8;
    const int set = av1g_get_tx_set_intra(txSz, 0);
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
    if (prune_flat(I, P, x, y, W, H, qidx)) { out.J = GP_INF; out.ncand = 0; return; }
    constexpr int EL = AV1G_EDGE_OFF + 2 * (W + H) + 8;
    uint8_t ea[EL], el[EL];
    uint8_t *A = ea + AV1G_EDGE_OFF, *L = el + AV1G_EDGE_OFF;
    build_edges_par(I.src[0], sp, x, y, T::lw, T::lh, haveLeft, haveAbove, haveAR, haveBL, maxX, maxY, A, L, 0, 1);
    const int dcv = av1g_dc_value(A, L, haveLeft, haveAbove, T::lw, T::lh);
    uint8_t s[W * H];
#pragma unroll
    for (int i = 0; i < H; i++)
#pragma unroll
        for (int j = 0; j < W; j++) s[i * W + j] = src[i * sp + j];
    auto mbits = [&](int c) -> float {
        const int m = cand_mode(c);
        float b = g_avgYMode[m];
        if (BS >= AV1G_BLOCK_8X8 && av1g_is_directional(m)) b += C[CID(angle_delta[m - AV1G_V_PRED]) + cand_delta(c) + 3];
        return b;
    };
    auto satd_of = [&](int c) -> float {
        const PredCand pc = pred_cand(c, T::lw, T::lh);
        float t = 0.f;
        for (int sy = 0; sy < H; sy += 4)
            for (int sx = 0; sx < W; sx += 4) {
                int d[16];
#pragma unroll
                for (int i = 0; i < 4; i++)
#pragma unroll
                    for (int j = 0; j < 4; j++)
                        d[i * 4 + j] = (int)s[(sy + i) * W + sx + j] - pred_fast(pc, sy + i, sx + j, A, L, dcv);
                t += hadamard4_abs(d);
            }
        return t;
    };
    device const GpExtCand *ext = (device const GpExtCand *)B.extCand[BS];
    int K = min(P.K, GP_MAXK);
    int cands[GP_MAXK];
    int nc = 0;
    if (ext) {
        device const GpExtCand *ec = ext + (size_t)(B.extOff[BS * B.nimg + lo] + li) * B.extTopK;
        for (int k = 0; k < B.extTopK && nc < GP_MAXK; k++) {
            const int m = ec[k].mode;
            if (m >= 13) continue;
            cands[nc++] = cand_pack(m, (BS >= AV1G_BLOCK_8X8 && av1g_is_directional(m)) ? ec[k].delta : 0);
        }
        K = min(K, nc);
    } else {
        float topJ[GP_MAXK];
        for (int k = 0; k < K; k++) { cands[k] = -1; topJ[k] = GP_INF; }
        float dirJ[8];
        auto insert = [&](int c, float j) {
            if (j < topJ[K - 1]) {
                int k = K - 1;
                while (k > 0 && topJ[k - 1] > j) { topJ[k] = topJ[k - 1]; cands[k] = cands[k - 1]; k--; }
                topJ[k] = j; cands[k] = c;
            }
        };
        for (int m = 0; m < 13; m++) {
            const int c = cand_pack(m, 0);
            const float j = satd_of(c) + lamS * mbits(c);
            if (m >= AV1G_V_PRED && m <= AV1G_D67_PRED) dirJ[m - AV1G_V_PRED] = j;
            insert(c, j);
        }
        if (P.deltas && BS >= AV1G_BLOCK_8X8) {
            int b0 = 0, b1 = 1;
            if (dirJ[b1] < dirJ[b0]) { b0 = 1; b1 = 0; }
            for (int k = 2; k < 8; k++) {
                if (dirJ[k] < dirJ[b0]) { b1 = b0; b0 = k; }
                else if (dirJ[k] < dirJ[b1]) b1 = k;
            }
            for (int t = 0; t < 2; t++)
                for (int d = -3; d <= 3; d++) {
                    if (!d) continue;
                    const int c = cand_pack(AV1G_V_PRED + (t ? b1 : b0), d);
                    insert(c, satd_of(c) + lamS * mbits(c));
                }
        }
        nc = 0;
        while (nc < K && cands[nc] >= 0) nc++;
    }
    // ---- RD ----
    const int hasC = av1g_has_chroma(BS, y >> 2, x >> 2, I.mono);
    const float overhead = (hasC ? P.uvOverheadBits : 0.f) + g_avgSkip0;
    EvalIn e;
    e.txSz = txSz; e.plane = 0;
    e.dcQ = av1g_dc_q(qidx); e.acQ = av1g_ac_q(qidx);
    e.rnd = P.rnd; e.zbin = P.zbin;
    e.skipCtx = 0; e.dcCtx = 0; e.reduced = 0; e.C = C;
    e.qmDist = P.qmDist; e.qmRnd = P.qmRnd; e.resEnergy = 0;
    int16_t res[W * H];
    uint8_t pa[EL], pl[EL];
    auto residual = [&](int c) {
        const int m = cand_mode(c);
        const bool ef = I.edgeFilter && av1g_is_directional(m);
        int upA = 0, upL = 0;
        if (ef) {
            for (int k = 0; k < EL; k++) { pa[k] = ea[k]; pl[k] = el[k]; }
            av1g_edge_prepare(pangle_of(m, cand_delta(c)), T::lw, T::lh, 0, haveLeft, haveAbove, x, y, maxX, maxY,
                              pa + AV1G_EDGE_OFF, pl + AV1G_EDGE_OFF, &upA, &upL);
        }
        const PredCand pc = pred_cand(c, T::lw, T::lh);
#pragma unroll
        for (int i = 0; i < H; i++)
#pragma unroll
            for (int j = 0; j < W; j++) {
                const int pr = ef ? av1g_pred_pixel_up(m, pangle_of(m, cand_delta(c)), i, j, T::lw, T::lh, pa + AV1G_EDGE_OFF,
                                                       pl + AV1G_EDGE_OFF, upA, upL)
                                  : pred_fast(pc, i, j, A, L, dcv);
                res[i * W + j] = (int16_t)((int)s[i * W + j] - pr);
            }
    };
    float bestJ = GP_INF;
    int bestK = 0, bestTx = AV1G_DCT_DCT;
    for (int k = 0; k < nc && k < K; k++) {
        const int c = cands[k];
        residual(c);
        e.txType = AV1G_DCT_DCT;
        e.intraDir = cand_mode(c);
        e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, AV1G_DCT_DCT);
        const EvalOut o = eval_scalar<W, H>(res, e);
        const float J = o.D + lambda * (o.R + mbits(c) + overhead);
        if (J < bestJ) { bestJ = J; bestK = k; }
    }
    if (nc > 0 && P.txSearch && set != AV1G_TX_SET_DCTONLY) {
        const int c = cands[bestK];
        residual(c);
        e.intraDir = cand_mode(c);
        for (int t = 1; t < 16; t++) {
            if (!av1g_tx_type_in_set_intra(set, t)) continue;
            e.txType = t;
            e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, t);
            const EvalOut o = eval_scalar<W, H>(res, e);
            const float J = o.D + lambda * (o.R + mbits(c) + overhead);
            if (J < bestJ) { bestJ = J; bestTx = t; }
        }
    }
    out.J = nc ? bestJ : GP_INF;
    out.tx = (uint8_t)bestTx;
    int m = 0;
    if (nc) out.cand[m++] = (uint8_t)cands[bestK];
    for (int k = 0; k < nc && k < K; k++)
        if (k != bestK) out.cand[m++] = (uint8_t)cands[k];
    out.ncand = (uint8_t)m;
}
