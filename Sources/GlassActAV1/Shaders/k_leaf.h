// Glass Act: the leaves' open-loop decisions after the partition DP, for AV1HybridEncoder:
// everything about a block that the source decides, so that the CPU's closed loop only quantizes
// and reconstructs. One threadgroup per 64x64 SB; each of its SIMD-groups takes one leaf at a time.
//   luma tx type   for the analysis's mode, by the analysis's exact-rate RD (eval_scalar, open-loop
//                  source edges), one tx type per lane: blocks up to 16x16, where an intra set has
//                  more than DCT_DCT
//   chroma         av1gpu's CPU reference engine's rule (AV1Encoder/src/hybrid.cpp, Decider::
//                  best_chroma): 13 modes by its Hadamard RD proxy on source edges, then CfL with a
//                  least-squares alpha against source luma; lanes take 4x4 sub-blocks
// The arithmetic is float where the CPU's is double, so a near tie can go the other way.
#pragma once
#include "k_analysis_small.h"

#define LEAF_NW 4  // SIMD-groups per threadgroup
#ifndef LEAF_WARP_TX
#define LEAF_WARP_TX 1
#endif

struct LeafSmem {
    int16_t res[16 * 16];
    float tmp[16 * 17];  // the warp-parallel tx evaluation's scratch
    int16_t q[16 * 16];
    uint8_t ea[3][AV1G_EDGE_LEN], el[3][AV1G_EDGE_LEN];  // luma, U, V
};

// av1gpu's reference-engine RD proxy of one 4x4 residual (orthonormal Hadamard, dead zone 0.6 step)
static inline float leaf_proxy4(thread int *d, float step, float lambda) {
    for (int i = 0; i < 4; i++) {
        thread int *r = d + i * 4;
        const int s0 = r[0] + r[1], s1 = r[0] - r[1], s2 = r[2] + r[3], s3 = r[2] - r[3];
        r[0] = s0 + s2; r[1] = s1 + s3; r[2] = s0 - s2; r[3] = s1 - s3;
    }
    for (int j = 0; j < 4; j++) {
        thread int *c = d + j;
        const int s0 = c[0] + c[4], s1 = c[0] - c[4], s2 = c[8] + c[12], s3 = c[8] - c[12];
        c[0] = s0 + s2; c[4] = s1 + s3; c[8] = s0 - s2; c[12] = s1 - s3;
    }
    float D = 0.f, R = 0.f;
    for (int k = 0; k < 16; k++) {
        const float v = (float)d[k] * 0.25f;
        const float m = fabs(v);
        if (m < 0.6f * step) D += v * v;
        else { D += step * step / 12.f; R += 2.f + 2.f * log2(m / step + 1.f); }
    }
    return D + lambda * R;
}

// the luma tx type for the analysis's candidate c of a W x H block at (x, y)
template <int W, int H>
static uint8_t leaf_luma_tx(device const GpImage &I, constant GpParams &P, int x, int y, int c,
                            threadgroup LeafSmem &S, uint lane) {
    typedef SmallTx<W, H> T;
    constexpr int txSz = (W == 4 && H == 4) ? AV1G_TX_4X4 : (W == 8 && H == 8) ? AV1G_TX_8X8 : (W == 4 && H == 8) ? AV1G_TX_4X8
                       : (W == 8 && H == 4) ? AV1G_TX_8X4 : (W == 4 && H == 16) ? AV1G_TX_4X16 : (W == 16 && H == 4) ? AV1G_TX_16X4
                       : (W == 8 && H == 16) ? AV1G_TX_8X16 : (W == 16 && H == 8) ? AV1G_TX_16X8 : AV1G_TX_16X16;
    const int set = av1g_get_tx_set_intra(txSz, 0);
    if (set == AV1G_TX_SET_DCTONLY || W * H > P.leafTxSearch) return AV1G_DCT_DCT;  // largest block searched, in pixels
    const TileBox tb = tile_of(I, x, y);
    const int haveLeft = x > tb.x0, haveAbove = y > tb.y0;
    const int haveAR = ol_decoded(x + W, y - 1, x, y, 0, tb);
    const int haveBL = ol_decoded(x - 1, y + H, x, y, 0, tb);
    const int maxX = I.MiCols * 4 - 1, maxY = I.MiRows * 4 - 1;
    device const uint8_t *src = I.src[0] + (size_t)y * I.spitch[0] + x;
    const int sp = I.spitch[0];
    threadgroup uint8_t *A = S.ea[0] + AV1G_EDGE_OFF, *L = S.el[0] + AV1G_EDGE_OFF;
    build_edges_par(I.src[0], sp, x, y, T::lw, T::lh, haveLeft, haveAbove, haveAR, haveBL, maxX, maxY, A, L, (int)lane, 32);
    simdgroup_barrier(mem_flags::mem_threadgroup);
    const int dcv = av1g_dc_value(A, L, haveLeft, haveAbove, T::lw, T::lh);
    const PredCand pc = pred_cand(c, T::lw, T::lh);
    for (int p = (int)lane; p < W * H; p += 32) {
        const int i = p / W, j = p % W;
        S.res[p] = (int16_t)((int)src[i * sp + j] - pred_fast(pc, i, j, A, L, dcv));
    }
    simdgroup_barrier(mem_flags::mem_threadgroup);
#if LEAF_WARP_TX
    // the set's types one after another, each evaluated by the whole SIMD-group
    const int qidx = sb_qindex(I, x, y);
    const float lambda = gp_lambda(qidx, P.lambdaMul) * ssim_scale(I, x, y, W, H);
    EvalIn e;
    e.txSz = txSz; e.plane = 0;
    e.dcQ = av1g_dc_q(qidx); e.acQ = av1g_ac_q(qidx);
    e.rnd = P.rnd; e.zbin = P.zbin;
    e.skipCtx = 0; e.dcCtx = 0; e.reduced = 0; e.C = g_cost[I.qctx];
    e.qmDist = P.qmDist; e.qmRnd = P.qmRnd; e.resEnergy = 0;
    e.intraDir = cand_mode(c);
    float bestJ = GP_INF;
    int bt = AV1G_DCT_DCT;
    for (int t = 0; t < 16; t++) {
        if (!av1g_tx_type_in_set_intra(set, t)) continue;
        e.txType = t;
        e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, t);
        EvalOut o;
        warp_eval<W, H>(S.res, S.tmp, S.q, e, o, (int)lane);
        const float J = o.D + lambda * o.R;
        if (J < bestJ) { bestJ = J; bt = t; }
    }
    simdgroup_barrier(mem_flags::mem_threadgroup);
    return (uint8_t)bt;
#else
    // lane l evaluates the l-th tx type of the set
    int t = -1, n = 0;
    for (int k = 0; k < 16; k++)
        if (av1g_tx_type_in_set_intra(set, k)) { if (n == (int)lane) t = k; n++; }
    float J = GP_INF;
    if (t >= 0) {
        const int qidx = sb_qindex(I, x, y);
        const float lambda = gp_lambda(qidx, P.lambdaMul) * ssim_scale(I, x, y, W, H);
        int16_t res[W * H];
        for (int p = 0; p < W * H; p++) res[p] = S.res[p];
        EvalIn e;
        e.txSz = txSz; e.plane = 0;
        e.dcQ = av1g_dc_q(qidx); e.acQ = av1g_ac_q(qidx);
        e.rnd = P.rnd; e.zbin = P.zbin;
        e.skipCtx = 0; e.dcCtx = 0; e.reduced = 0; e.C = g_cost[I.qctx];
        e.qmDist = P.qmDist; e.qmRnd = P.qmRnd; e.resEnergy = 0;
        e.intraDir = cand_mode(c);
        e.txType = t;
        e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, t);
        const EvalOut o = eval_scalar<W, H>(res, e);
        J = o.D + lambda * o.R;
    }
    const float best = simd_min(J);
    const uint win = ctz((uint)static_cast<simd_vote::vote_t>(simd_ballot(J == best && t >= 0)));  // the first type on ties
    const int bt = simd_shuffle(t, (ushort)win);
    simdgroup_barrier(mem_flags::mem_threadgroup);
    return (uint8_t)(bt >= 0 ? bt : AV1G_DCT_DCT);
#endif
}

// Decider::best_chroma, lanes over 4x4 sub-blocks
static void leaf_chroma(device const GpImage &I, constant GpParams &P, int x, int y, int bs, int qidx, threadgroup LeafSmem &S, uint lane,
                        thread GpLeafDecision &d) {
    const int txSz = av1g_uv_tx_size(bs);
    const int lw = AV1G_T(Tx_Width_Log2)[txSz], lh = AV1G_T(Tx_Height_Log2)[txSz];
    const int w = 1 << lw, h = 1 << lh, nsx = w / 4, nsub = (w / 4) * (h / 4);
    const int cx = ((x >> 2) >> 1) << 2, cy = ((y >> 2) >> 1) << 2;  // sub-8x8 blocks carry the 8x8's chroma
    const TileBox tb = tile_of(I, x, y);
    const int haveLeft = cx > (tb.x0 >> 1), haveAbove = cy > (tb.y0 >> 1);
    const int maxX = ((I.MiCols * 4) >> 1) - 1, maxY = ((I.MiRows * 4) >> 1) - 1;
    const float step = (float)av1g_ac_q(qidx) / 8.f, lambda = 0.12f * step * step;
    int dcv[3];
    for (int pl = 1; pl <= 2; pl++) {
        build_edges_par(I.src[pl], I.spitch[pl], cx, cy, lw, lh, haveLeft, haveAbove, 0, 0, maxX, maxY,
                        S.ea[pl] + AV1G_EDGE_OFF, S.el[pl] + AV1G_EDGE_OFF, (int)lane, 32);
    }
    simdgroup_barrier(mem_flags::mem_threadgroup);
    for (int pl = 1; pl <= 2; pl++)
        dcv[pl] = av1g_dc_value(S.ea[pl] + AV1G_EDGE_OFF, S.el[pl] + AV1G_EDGE_OFF, haveLeft, haveAbove, lw, lh);
    // every (mode, plane, 4x4 sub-block) is an item; a lane's costs accumulate per mode
    float part[AV1G_INTRA_MODES];
    for (int m = 0; m < AV1G_INTRA_MODES; m++) part[m] = 0.f;
    // the modes screened: all 13, or the seven without an angle (cheaper per pixel)
    constexpr int plain[7] = {AV1G_DC_PRED, AV1G_V_PRED, AV1G_H_PRED, AV1G_SMOOTH_PRED, AV1G_SMOOTH_V_PRED,
                              AV1G_SMOOTH_H_PRED, AV1G_PAETH_PRED};
    const int nmodes = P.leafChromaAngled ? AV1G_INTRA_MODES : 7;
    const int items = nmodes * 2 * nsub;
    for (int it = (int)lane; it < items; it += 32) {
        const int mi = it / (2 * nsub), m = P.leafChromaAngled ? mi : plain[mi];
        const int pl = 1 + (it / nsub) % 2, sb = it % nsub;
        const int sx = (sb % nsx) * 4, sy = (sb / nsx) * 4;
        device const uint8_t *s = I.src[pl] + (size_t)cy * I.spitch[pl] + cx;
        threadgroup uint8_t *A = S.ea[pl] + AV1G_EDGE_OFF, *L = S.el[pl] + AV1G_EDGE_OFF;
        const PredCand pc = pred_cand(cand_pack(m, 0), lw, lh);
        int r[16];
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++)
                r[i * 4 + j] = (int)s[(sy + i) * I.spitch[pl] + sx + j] - pred_fast(pc, sy + i, sx + j, A, L, dcv[pl]);
        part[m] += leaf_proxy4(r, step, lambda);
    }
    float best = GP_INF;
    int bestMode = AV1G_DC_PRED;
    for (int mi = 0; mi < nmodes; mi++) {
        const int m = P.leafChromaAngled ? mi : plain[mi];
        const float J = simd_sum(part[m]) + lambda * (av1g_is_directional(m) ? 5.0f : 3.5f);
        if (J < best) { best = J; bestMode = m; }
    }
    d.uvMode = (uint8_t)bestMode;
    d.angleUV = 0;
    d.cflU = d.cflV = 0;
    if (!av1g_cfl_allowed(bs)) return;
    // least-squares alpha against source luma (3 fractional bits, as in the spec)
    device const uint8_t *Y = I.src[0];
    const int ys = I.spitch[0];
    auto lumaAt = [&](int i, int j) -> int {
        device const uint8_t *s = Y + (size_t)((cy + i) * 2) * ys + (cx + j) * 2;
        return (s[0] + s[1] + s[ys] + s[ys + 1]) << 1;
    };
    int lsum = 0;
    for (int p = (int)lane; p < w * h; p += 32) lsum += lumaAt(p / w, p % w);
    const int avg = (simd_sum(lsum) + (w * h / 2)) / (w * h);
    int alpha[3] = {0, 0, 0};
    float J = lambda * 8.f;
    for (int pl = 1; pl <= 2; pl++) {
        device const uint8_t *s = I.src[pl] + (size_t)cy * I.spitch[pl] + cx;
        float num = 0.f, den = 0.f;
        for (int p = (int)lane; p < w * h; p += 32) {
            const int i = p / w, j = p % w;
            const float l = (float)(lumaAt(i, j) - avg) / 8.f;
            num += (float)((int)s[i * I.spitch[pl] + j] - dcv[pl]) * l;
            den += l * l;
        }
        num = simd_sum(num);
        den = simd_sum(den);
        const int a = den > 0.f ? (int)rint(8.f * num / den) : 0;
        alpha[pl] = max(-16, min(16, a));
        float part = 0.f;
        for (int sb = (int)lane; sb < nsub; sb += 32) {
            const int sx = (sb % nsx) * 4, sy = (sb / nsx) * 4;
            int r[16];
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++) {
                    const int pr = av1g_clip1(dcv[pl] + av1g_round2signed(alpha[pl] * (lumaAt(sy + i, sx + j) - avg), 6));
                    r[i * 4 + j] = (int)s[(sy + i) * I.spitch[pl] + sx + j] - pr;
                }
            part += leaf_proxy4(r, step, lambda);
        }
        J += simd_sum(part);
    }
    if ((alpha[1] || alpha[2]) && J < best) {
        d.uvMode = AV1G_UV_CFL_PRED;
        d.cflU = (int8_t)alpha[1];
        d.cflV = (int8_t)alpha[2];
    }
    simdgroup_barrier(mem_flags::mem_threadgroup);
}

// the leaves of every SB analyzed (not kept: B.sbKeep) as one list: leafOff[sb] = leaves before it,
// leafOff[nSb] = all; and the indirect dispatch of k_leaf (LEAF_NW leaves per threadgroup), which
// so doesn't visit the kept SBs' leaves. One threadgroup of 1024 threads.
kernel void k_leaf_scan(constant GpBatch &B [[buffer(0)]], device uint32_t *leafOff [[buffer(2)]],
                        device uint32_t *dispatch [[buffer(3)]], uint tid [[thread_position_in_threadgroup]]) {
    threadgroup uint32_t part[1024];
    const uint32_t n = B.nSb, per = (n + 1023) / 1024, b = min(tid * per, n), e = min(b + per, n);
    auto count = [&](uint32_t i) -> uint32_t { return B.sbKeep && B.sbKeep[i] ? 0u : (uint32_t)B.leafCountW[i]; };
    uint32_t s = 0;
    for (uint32_t i = b; i < e; i++) s += count(i);
    part[tid] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint32_t d = 1; d < 1024; d <<= 1) {
        const uint32_t v = tid >= d ? part[tid - d] : 0;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        part[tid] += v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    uint32_t run = tid ? part[tid - 1] : 0;
    for (uint32_t i = b; i < e; i++) {
        leafOff[i] = run;
        run += count(i);
    }
    if (tid == 1023) {
        leafOff[n] = part[1023];
        dispatch[0] = (part[1023] + LEAF_NW - 1) / LEAF_NW;
        dispatch[1] = 1;
        dispatch[2] = 1;
    }
}

kernel void k_leaf(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                   device const uint32_t *leafOff [[buffer(2)]],
                   uint tg [[threadgroup_position_in_grid]], uint lane [[thread_index_in_simdgroup]],
                   uint warp [[simdgroup_index_in_threadgroup]]) {
    threadgroup LeafSmem smem[LEAF_NW];
    threadgroup LeafSmem &S = smem[warp];
    const uint32_t g = tg * LEAF_NW + warp;  // this SIMD-group's leaf in the whole picture
    if (g >= leafOff[B.nSb]) return;
    uint32_t lo = 0, hi = B.nSb;  // its SB: the last with leafOff <= g
    while (hi - lo > 1) {
        const uint32_t mid = (lo + hi) >> 1;
        if (leafOff[mid] <= g) lo = mid; else hi = mid;
    }
    // (the last SB with leafOff <= g is the one with the leaf: kept SBs before it have none here)
    const uint32_t sb = lo, k = g - leafOff[sb];
    if (B.sbKeep && B.sbKeep[sb]) return;  // unchanged source: the previous picture's decisions stand
    device const GpImage &I = B.img[B.sbImg[sb]];
    const uint32_t local = sb - I.sbBase;
    {
        const GpLeaf leaf = B.leaves[sb * GP_MAX_LEAVES + k];
        const int x = (int)(local % I.sbCols) * 64 + leaf.x4 * 4, y = (int)(local / I.sbCols) * 64 + leaf.y4 * 4;
        const int bs = leaf.bsize;
        GpLeafDecision d;
        d.uvMode = AV1G_DC_PRED; d.angleUV = 0; d.cflU = d.cflV = 0; d.lumaTx = AV1G_DCT_DCT;
        d.pad[0] = d.pad[1] = d.pad[2] = 0;
        // the analysis's result for this shape and position
        const int W = 4 * av1g_bw4(bs), H = 4 * av1g_bh4(bs);
        const uint32_t bi = I.shOff[bs] + (y / H) * I.shNbx[bs] + x / W;
        device const GpBlockRes &r = B.blk[bi];
        if (B.inter && B.inter[bi].isInter) {  // an inter block: no intra decisions (fields 0, DCT_DCT)
            if (lane == 0) B.leafDec[sb * GP_MAX_LEAVES + k] = d;
            return;
        }
        if (r.ncand > 0) {
            const int c = r.cand[0];
            switch (bs) {
            case AV1G_BLOCK_4X4: d.lumaTx = leaf_luma_tx<4, 4>(I, P, x, y, c, S, lane); break;
            case AV1G_BLOCK_4X8: d.lumaTx = leaf_luma_tx<4, 8>(I, P, x, y, c, S, lane); break;
            case AV1G_BLOCK_8X4: d.lumaTx = leaf_luma_tx<8, 4>(I, P, x, y, c, S, lane); break;
            case AV1G_BLOCK_8X8: d.lumaTx = leaf_luma_tx<8, 8>(I, P, x, y, c, S, lane); break;
            case AV1G_BLOCK_4X16: d.lumaTx = leaf_luma_tx<4, 16>(I, P, x, y, c, S, lane); break;
            case AV1G_BLOCK_16X4: d.lumaTx = leaf_luma_tx<16, 4>(I, P, x, y, c, S, lane); break;
            case AV1G_BLOCK_8X16: d.lumaTx = leaf_luma_tx<8, 16>(I, P, x, y, c, S, lane); break;
            case AV1G_BLOCK_16X8: d.lumaTx = leaf_luma_tx<16, 8>(I, P, x, y, c, S, lane); break;
            case AV1G_BLOCK_16X16: d.lumaTx = leaf_luma_tx<16, 16>(I, P, x, y, c, S, lane); break;
            default: break;
            }
        }
        if (av1g_has_chroma(bs, y >> 2, x >> 2, I.mono)) leaf_chroma(I, P, x, y, bs, sb_qindex(I, x, y), S, lane, d);
        if (lane == 0) B.leafDec[sb * GP_MAX_LEAVES + k] = d;
    }
}
