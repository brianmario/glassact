// Glass Act: av1gpu's encoder/src/k_recon.cuh (BSD-2, Sources/AV1Core/LICENSE), for Metal:
// - the thread index travels with the shared state (`S, tid_`): CUDA's threadIdx is a global;
// - shared state and scratch say `threadgroup`, the per-CTA global scratch `device`, the batch
//   and parameters `constant`; pointers into tables AV1G_CONST;
// - rc_edges' named barriers (PTX bar.sync over 64 threads) are threadgroup barriers every
//   thread reaches (all its callers are uniform across the threadgroup);
// - CfL's least-squares sums are reduced per warp and added in a fixed order: float atomics
//   would make alpha, and the encode, depend on scheduling;
// - the clock64 phase profiling is gone (Metal has no clock).
// closed-loop decision + reconstruction, one CTA (4 warps) per 64x64 superblock,
// launched in SB-wavefront steps (step = sbCol + 2 * sbRow: left and above-right neighbours are
// complete).  Inside the SB the blocks are processed in decode order exactly as the decoder does:
// BlockDecoded flags, real reconstructed edges, exact contexts from the 4x4 maps.
//
// Per block:
//   luma    re-evaluate the analysis top-K (DCT_DCT) with the REAL edges and exact mode/coefficient
//           contexts, tx-type search for the winner, final quantization, exact dequant + inverse
//           transform (av1core dsp.h) + reconstruction
//   chroma  SATD screening of the 13 UV modes with real edges -> top uvK + CfL (least-squares alpha
//           from the reconstructed luma) -> exact RD of U+V -> final quantization + reconstruction
//   record  av1g_block / av1g_txb / coefficients into the SB's output slots, maps + contexts
#pragma once
#include "dev_tx.h"
#include "k_analysis.h"
#include "rc_inv.h"

#define RC_NT 128
#define RC_NW 4

struct TxR {
    int w, h, tw, th, n, lw, lh;
    __device__ TxR(int W, int H) : w(W), h(H), tw(W > 32 ? 32 : W), th(H > 32 ? 32 : H), n(0), lw(log2i(W)), lh(log2i(H)) { n = tw * th; }
};

// Per-warp evaluation scratch for tx blocks up to 16x16 (all sizes with a tx-type search); larger
// tx blocks (32/64-point, DCT only) are evaluated one at a time by warp 0 in the shared big scratch.
struct RcWarpScr {
    int16_t res[16 * 16];
    float tmp[16 * 17];
    int16_t q[16 * 16];
};
struct RcBigScr {
    int16_t res[64 * 64];
    float tmp[32 * 65];
    int16_t q[32 * 32];
};
struct RcInvScr {
    int16_t res[64 * 64];   // residual after the row pass / final residual (both fit 16 bits, spec 7.13.3)
};
#define RC_TASKQ_OFF_C (sizeof(RcWarpScr) * RC_NW)
#define RC_TAIL_OFF (RC_TASKQ_OFF_C + 14 * 512)
// shared-memory union (warp scratches / inverse transform buffer / kept levels); the rare 32/64-point
// evaluations use a per-CTA slot of B.bigScratch in global memory (GP_RC_BIG_BYTES each)
#define RC_UNION_BYTES (RC_TAIL_OFF + 2048)
union RcUnion {
    RcWarpScr w[RC_NW];
    RcInvScr inv;
    uint8_t raw[RC_UNION_BYTES];
};
static_assert(sizeof(RcBigScr) <= GP_RC_BIG_BYTES, "GP_RC_BIG_BYTES too small");
// W5/W3: per-CTA global scratch = one big slot per warp (big tasks run on all warps) + kept
// levels of up to RC_BIGQ_MAX big chroma RD tasks (the final reuses them instead of re-quantizing)
#define RC_BIGQ_MAX 8
#define RC_CTA_BIG_BYTES ((size_t)RC_NW * sizeof(RcBigScr) + (size_t)RC_BIGQ_MAX * 32 * 32 * 2)
__device__ __forceinline__ bool rc_big(int W, int H) { return W > 16 || H > 16; }
// chroma RD task levels (tx <= 16x16) are kept in the union after the warp scratches: above the inverse
// transform's int16 buffer (8192 B) and below the union's end
#define RC_TASKQ_OFF (sizeof(RcWarpScr) * RC_NW)
#define RC_TASKQ_MAX ((int)((RC_TAIL_OFF - RC_TASKQ_OFF) / 512))
__device__ __forceinline__ threadgroup int16_t *rc_taskq(threadgroup RcUnion &u, int t) { return (threadgroup int16_t *)((threadgroup char *)&u + RC_TASKQ_OFF) + t * 256; }
// [16384, 18432) of the union: luma per-warp best levels (luma passes, tx <= 16x16) or CfL luma values
// (chroma of CfL-capable blocks: chroma tx <= 16x16, so never the big scratch).  Phase-disjoint uses.
__device__ __forceinline__ threadgroup int16_t *rc_bestq(threadgroup RcUnion &u, int w) { return (threadgroup int16_t *)((threadgroup char *)&u + RC_TAIL_OFF) + w * 256; }
__device__ __forceinline__ threadgroup const int16_t *rc_cflL(threadgroup const RcUnion &u) { return (threadgroup const int16_t *)((threadgroup const char *)&u + RC_TAIL_OFF); }
__device__ __forceinline__ threadgroup int16_t *rc_cflLw(threadgroup RcUnion &u) { return (threadgroup int16_t *)((threadgroup char *)&u + RC_TAIL_OFF); }

struct RcShared {
    RcUnion u;
    int16_t qfin[32 * 32];
    device RcBigScr *bigG;          // this CTA's global big scratch: one RcBigScr per warp (W5)
    device int16_t *bigQ;           // kept levels of big chroma RD tasks [RC_BIGQ_MAX][32 * 32] (W3)
    uint32_t bdm[3][18];            // BlockDecoded bitmask: row yy+1, bit xx+1 (yy, xx in -1..16)
    uint8_t ea[3][AV1G_EDGE_LEN], el[3][AV1G_EDGE_LEN];
    int dcv[3];
    // intra edge filter: per-warp prepared (filtered / upsampled) edges of the candidate being evaluated
    uint8_t wea[RC_NW][AV1G_EDGE_LEN], wel[RC_NW][AV1G_EDGE_LEN];
    int wup[RC_NW][2];
    int ft[3], hvL[3], hvA[3], px[3], py[3], mx[3], my[3];
    int edgeFilter;
    float taskJ[32];
    float satd[32];
    int uvc[32];
    int taskC[32], taskT[32], taskP[32], taskE[32];
    int nTask;
    float finD, finR;               // rc_final_quant: winner's distortion / rate (tx-size search)
    int errFlag, nzFlag;
    int nTxb, nCoef;
    int finEob;
    int cflAvg, cflAlpha[2];
    float cflNum[2], cflDen[2];
    float alphaSse[2][3];
    // per-warp best luma task (tx blocks <= 16x16): its levels are the final ones, no re-evaluation
    float bestJw[RC_NW];
    int bestCw[RC_NW], bestTw[RC_NW], bestEw[RC_NW];
    int sEob, sCul;                 // rc_record_txb (a __shared__ local in CUDA)
    float cflPart[RC_NW][3];        // per-warp CfL sums (num U, num V, den)
    float ssePart[RC_NW][6];        // per-warp alpha-refinement SSEs
};

// ---------------------------------------------------------------------------
// exact inverse transform + reconstruction (CTA-wide), mirrors av1g_inv_txfm2d / av1g_add_residual.
// q may be modified (halved) when the coefficients violate the conformance ranges
// (= AV1G_ENC_FIX_RANGE).  Returns the number of halvings (all threads).
__device__ int cta_inverse_add(int W, int H, threadgroup RcShared &S, int tid_, int16_t *q, int txSz, int txType, int dcQ, int acQ, AV1G_CONST const uint8_t *qm,
                               uint8_t *dst, int pitch) {
    const TxR T(W, H);
    const int tid = tid_;
    const int den = av1g_dq_denom(txSz);
    const int rk = av1g_row_kind(txType), ck = av1g_col_kind(txType);
    const int rowShift = AV1G_T(Transform_Row_Shift)[txSz];
    const bool rect = (T.lw - T.lh == 1 || T.lh - T.lw == 1);
    int16_t *res = S.u.inv.res;
    int fixes = 0;
    for (;;) {
        if (tid == 0) { S.errFlag = 0; S.nzFlag = 0; }
        __syncthreads();
        // W4: register-resident templated 1-D transforms (rc_inv.cuh), same arithmetic as av1g_inv_1d
        uint32_t err = 0;
        switch (T.lw) {
#define RC_ROWS(LW) for (int i = tid; i < H; i += RC_NT) err |= rci::row<LW>(i, T.th, T.tw, q, dcQ, acQ, qm, den, rect, rk, rowShift, res)
        case 2: RC_ROWS(2); break;
        case 3: RC_ROWS(3); break;
        case 4: RC_ROWS(4); break;
        case 5: RC_ROWS(5); break;
        default: RC_ROWS(6); break;
#undef RC_ROWS
        }
        if (err) atomicOr(&S.errFlag, (int)err);
        __syncthreads();
        err = 0;
        switch (T.lh) {
#define RC_COLS(LH) for (int j = tid; j < W; j += RC_NT) err |= rci::col<LH>(j, W, ck, res)
        case 2: RC_COLS(2); break;
        case 3: RC_COLS(3); break;
        case 4: RC_COLS(4); break;
        case 5: RC_COLS(5); break;
        default: RC_COLS(6); break;
#undef RC_COLS
        }
        if (err) atomicOr(&S.errFlag, (int)err);
        __syncthreads();
        if (!S.errFlag) break;
        fixes++;
        for (int idx = tid; idx < T.n; idx += RC_NT) {
            q[idx] = (int16_t)(q[idx] / 2);
            if (q[idx]) S.nzFlag = 1;
        }
        __syncthreads();
        if (!S.nzFlag) return fixes;  // all zero now: no residual
    }
    const int fud = av1g_flip_ud(txType), flr = av1g_flip_lr(txType);
    for (int p = tid; p < W * H; p += RC_NT) {
        const int i = p / W, j = p % W;
        const int xx = flr ? W - 1 - j : j, yy = fud ? H - 1 - i : i;
        uint8_t *d = dst + yy * pitch + xx;
        *d = (uint8_t)av1g_clip1((int)*d + res[i * W + j]);
    }
    __syncthreads();
    return fixes;
}

// ---------------------------------------------------------------------------
// coefficient contexts from the 4x4 maps (mirror of av1core k_txsym)
__device__ __forceinline__ void txb_ctx(device const GpImage &I, int plane, int txSz, int x4, int y4, int bsize, const TileBox &tb,
                                        int *skipCtx, int *dcCtx) {
    const int sub = plane ? 1 : 0;
    const int stride = I.MiCols >> sub;
    const int maxX4 = I.MiCols >> sub, maxY4 = I.MiRows >> sub;
    const uint8_t *L = I.cLvl[plane], *D = I.cDc[plane];
    const bool hasAbove = y4 > ((tb.y0 >> 2) >> sub), hasLeft = x4 > ((tb.x0 >> 2) >> sub);
    const int w = AV1G_T(Tx_Width)[txSz], h = AV1G_T(Tx_Height)[txSz], w4 = w >> 2, h4 = h >> 2;
    if (plane == 0) {
        const int bw = bw_px(bsize), bh = bh_px(bsize);
        if (bw == w && bh == h) *skipCtx = 0;
        else {
            int top = 0, left = 0;
            for (int i = 0; i < w4; i++) if (hasAbove && x4 + i < maxX4) top = max(top, (int)L[(size_t)(y4 - 1) * stride + x4 + i]);
            for (int i = 0; i < h4; i++) if (hasLeft && y4 + i < maxY4) left = max(left, (int)L[(size_t)(y4 + i) * stride + x4 - 1]);
            const int mx = max(top, left), mn = min(top, left);
            if (top == 0 && left == 0) *skipCtx = 1;
            else if (top == 0 || left == 0) *skipCtx = 2 + (mx > 3);
            else if (mx <= 3) *skipCtx = 4;
            else if (mn <= 3) *skipCtx = 5;
            else *skipCtx = 6;
        }
    } else {
        const int ub = av1g_uv_bsize(bsize);
        const int bw = bw_px(ub), bh = bh_px(ub);
        int above = 0, left = 0;
        for (int i = 0; i < w4; i++)
            if (hasAbove && x4 + i < maxX4) above |= L[(size_t)(y4 - 1) * stride + x4 + i] | D[(size_t)(y4 - 1) * stride + x4 + i];
        for (int i = 0; i < h4; i++)
            if (hasLeft && y4 + i < maxY4) left |= L[(size_t)(y4 + i) * stride + x4 - 1] | D[(size_t)(y4 + i) * stride + x4 - 1];
        *skipCtx = (above != 0) + (left != 0) + 7 + ((bw * bh > w * h) ? 3 : 0);
    }
    int dcSign = 0;
    for (int i = 0; i < w4; i++)
        if (hasAbove && x4 + i < maxX4) { const int s = D[(size_t)(y4 - 1) * stride + x4 + i]; dcSign += s == 1 ? -1 : s == 2 ? 1 : 0; }
    for (int i = 0; i < h4; i++)
        if (hasLeft && y4 + i < maxY4) { const int s = D[(size_t)(y4 + i) * stride + x4 - 1]; dcSign += s == 1 ? -1 : s == 2 ? 1 : 0; }
    *dcCtx = dcSign < 0 ? 1 : dcSign > 0 ? 2 : 0;
}

// prediction of one pixel: mode candidate c (or CfL with alpha when cfl), plane edges.  slot >= 0:
// directional modes use the edges prepared (intra edge filter) by warp `slot`.
__device__ __forceinline__ int rc_pred(threadgroup const RcShared &S, int tid_, int plane, int c, bool cfl, int alpha, int i, int j, int lw, int lh,
                                       int cw, int slot = -1) {
    if (cfl) {
        const int v = rc_cflL(S.u)[i * cw + j];
        return av1g_clip1(S.dcv[plane] + av1g_round2signed(alpha * (v - S.cflAvg), 6));
    }
    const int m = cand_mode(c);
    if (m == AV1G_DC_PRED) return S.dcv[plane];
    if (slot >= 0 && S.edgeFilter && av1g_is_directional(m))
        return av1g_pred_pixel_up(m, pangle_of(m, cand_delta(c)), i, j, lw, lh, S.wea[slot] + AV1G_EDGE_OFF,
                                  S.wel[slot] + AV1G_EDGE_OFF, S.wup[slot][0], S.wup[slot][1]);
    return av1g_pred_pixel(m, pangle_of(m, cand_delta(c)), i, j, lw, lh, S.ea[plane] + AV1G_EDGE_OFF, S.el[plane] + AV1G_EDGE_OFF);
}

// filter-intra candidates are coded as 128 + filter_intra_mode (y_mode DC_PRED)
__device__ __forceinline__ bool is_fi(int c) { return c >= 128; }
__device__ __forceinline__ int luma_mode(int c) { return c >= 128 ? AV1G_DC_PRED : cand_mode(c); }
__device__ __forceinline__ int intra_dir(int c) { return c >= 128 ? AV1G_T(Filter_Intra_Mode_To_Intra_Dir)[c - 128] : cand_mode(c); }

// warp: prepare the edge-filtered edges of (plane, candidate) into this warp's slot (lane 0)
__device__ __forceinline__ void rc_prepare_edges(threadgroup RcShared &S, int tid_, int plane, int c, bool cfl, int lw, int lh) {
    const int warp = tid_ >> 5;
    const int m = cand_mode(c);
    if (cfl || !S.edgeFilter || !av1g_is_directional(m)) return;
    if ((tid_ & 31) == 0) {
        for (int k = 0; k < AV1G_EDGE_LEN; k++) { S.wea[warp][k] = S.ea[plane][k]; S.wel[warp][k] = S.el[plane][k]; }
        int ua = 0, ul = 0;
        av1g_edge_prepare(pangle_of(m, cand_delta(c)), lw, lh, S.ft[plane], S.hvL[plane], S.hvA[plane], S.px[plane], S.py[plane],
                          S.mx[plane], S.my[plane], S.wea[warp] + AV1G_EDGE_OFF, S.wel[warp] + AV1G_EDGE_OFF, &ua, &ul);
        S.wup[warp][0] = ua;
        S.wup[warp][1] = ul;
    }
    __syncwarp();
}

// warp: residual of (plane, cand/cfl) for a W x H tx block into res; returns sum r^2
__device__ float rc_residual(int W, int H, threadgroup RcShared &S, int tid_, int plane, int c, bool cfl, int alpha, const uint8_t *src, int sp,
                             int16_t *res, uint8_t *fiBuf = nullptr) {
    const TxR T(W, H);
    const int lane = tid_ & 31;
    const int slot = tid_ >> 5;
    float e = 0.f;
    if (plane == 0 && is_fi(c)) {
        // recursive filter-intra prediction (spec 7.11.2.3), lane 0, into fiBuf (stride W)
        if (lane == 0)
            av1g_predict_filter_intra(c - 128, T.lw, T.lh, S.ea[0] + AV1G_EDGE_OFF, S.el[0] + AV1G_EDGE_OFF, fiBuf, W);
        __syncwarp();
        for (int p = lane; p < W * H; p += 32) {
            const int i = p / W, j = p % W;
            const int r = (int)src[i * sp + j] - (int)fiBuf[p];
            res[p] = (int16_t)r;
            e += (float)(r * r);
        }
        __syncwarp();
        return warp_sum(e);
    }
    rc_prepare_edges(S, tid_, plane, c, cfl, T.lw, T.lh);
    for (int p = lane; p < W * H; p += 32) {
        const int i = p / W, j = p % W;
        const int r = (int)src[i * sp + j] - rc_pred(S, tid_, plane, c, cfl, alpha, i, j, T.lw, T.lh, W, slot);
        res[p] = (int16_t)r;
        e += (float)(r * r);
    }
    __syncwarp();
    return warp_sum(e);
}

// final quantization of (plane, cand, txType) into S.qfin by warp 0 with distortion and rate (S.finEob, S.finD, S.finR):
// the tx-size search compares J; everything else uses the CTA-wide rc_final_quant below (levels only)
__device__ void rc_final_quant_rd(int W, int H, threadgroup RcShared &S, int tid_, thread const EvalIn &e, int plane, int c, bool cfl, int alpha, const uint8_t *src, int sp) {
    const int warp = tid_ >> 5;
    const bool big = rc_big(W, H);
    if (warp == 0) {
        device RcBigScr &BG = *S.bigG;
        int16_t *res = big ? (int16_t *)BG.res : (int16_t *)S.u.w[0].res;
        float *tmp = big ? (float *)BG.tmp : (float *)S.u.w[0].tmp;
        EvalIn ee = e;
        ee.resEnergy = rc_residual(W, H, S, tid_, plane, c, cfl, alpha, src, sp, res, (uint8_t *)tmp);
        EvalOut o;
        warp_eval_rt(res, tmp, S.qfin, ee, o, W, H, tid_ & 31);
        if ((tid_ & 31) == 0) { S.finEob = o.eob; S.finD = o.D; S.finR = o.R; }
    }
    __syncthreads();
}

// ---------------------------------------------------------------------------
// W1: CTA-wide final quantization (levels + eob only).  warp_eval_rt also computes D and R,
// which the final quantization never uses, and it runs on warp 0 alone; here the forward transform and
// the quantizer run on all 128 threads and the rate pass is skipped.  Every output keeps the arithmetic
// of fwd_col_pass / fwd_row_pass / warp_quant_rate_rt (same fmaf order per output, same quantizer
// expression), so the levels are bit-identical.
template <int TC>
__device__ __forceinline__ void cta_fwd_col(const int16_t *res, float *tmp, int W, int H, int TH, int ck, int fud, int flr,
                                            AV1G_CONST const float *Fc, AV1G_CONST const float *FcT, int nChunk, int tid_) {
    const int TS = W + 1;
    const int it = tid_;
    if (it >= W * nChunk) return;
    const int j = it % W, i0 = (it / W) * TC;
    const int jj = flr ? W - 1 - j : j;
    if (ck == AV1G_K_IDT) {   // identity: TH == H
        for (int i = i0; i < i0 + TC && i < TH; i++) tmp[i * TS + j] = __ldg(&Fc[i * H + i]) * (float)res[(fud ? H - 1 - i : i) * W + jj];
        return;
    }
    float acc[TC];
#pragma unroll
    for (int i = 0; i < TC; i++) acc[i] = 0.f;
    for (int k = 0; k < H; k++) {
        const float x = (float)res[(fud ? H - 1 - k : k) * W + jj];
        AV1G_CONST const float4 *f4 = (AV1G_CONST const float4 *)(FcT + k * H + i0);
#pragma unroll
        for (int i4 = 0; i4 < TC / 4; i4++) {
            const float4 f = __ldg(&f4[i4]);
            acc[4 * i4 + 0] = fmaf(f.x, x, acc[4 * i4 + 0]);
            acc[4 * i4 + 1] = fmaf(f.y, x, acc[4 * i4 + 1]);
            acc[4 * i4 + 2] = fmaf(f.z, x, acc[4 * i4 + 2]);
            acc[4 * i4 + 3] = fmaf(f.w, x, acc[4 * i4 + 3]);
        }
    }
#pragma unroll
    for (int i = 0; i < TC; i++) tmp[(i0 + i) * TS + j] = acc[i];
}
// row pass in place: all items read their row first, CTA barrier, then write (callers: every thread)
template <int TC>
__device__ __forceinline__ void cta_fwd_row(float *tmp, int W, int th, int rk, AV1G_CONST const float *Fr, AV1G_CONST const float *FrT, float scale, int nChunk, int tid_) {
    const int TS = W + 1;
    const int it = tid_;
    const bool act = it < th * nChunk;
    const int i = act ? it % th : 0, j0 = act ? (it / th) * TC : 0;
    float acc[TC];
#pragma unroll
    for (int jj = 0; jj < TC; jj++) acc[jj] = 0.f;
    if (act) {
        if (rk == AV1G_K_IDT) {
#pragma unroll
            for (int jj = 0; jj < TC; jj++) acc[jj] = __ldg(&Fr[(j0 + jj) * W + j0 + jj]) * tmp[i * TS + j0 + jj];
        } else {
            for (int k = 0; k < W; k++) {
                const float x = tmp[i * TS + k];
                AV1G_CONST const float4 *f4 = (AV1G_CONST const float4 *)(FrT + k * W + j0);
#pragma unroll
                for (int j4 = 0; j4 < TC / 4; j4++) {
                    const float4 f = __ldg(&f4[j4]);
                    acc[4 * j4 + 0] = fmaf(f.x, x, acc[4 * j4 + 0]);
                    acc[4 * j4 + 1] = fmaf(f.y, x, acc[4 * j4 + 1]);
                    acc[4 * j4 + 2] = fmaf(f.z, x, acc[4 * j4 + 2]);
                    acc[4 * j4 + 3] = fmaf(f.w, x, acc[4 * j4 + 3]);
                }
            }
        }
    }
    __syncthreads();
    if (act) {
#pragma unroll
        for (int jj = 0; jj < TC; jj++) tmp[i * TS + j0 + jj] = acc[jj] * scale;
    }
}
__device__ __forceinline__ int rc_chunks(int outs, int lanesPerChunk) { return max(1, min(outs / 4, RC_NT / lanesPerChunk)); }

// residual (whole CTA, edges prepared by warp 0 into slot 0) -> forward transform -> levels into S.qfin, S.finEob.
// res (and the prepared slot-0 edges) stay valid for rc_write_from_res / rc_write_pred.
__device__ void rc_final_quant(int W, int H, threadgroup RcShared &S, int tid_, thread const EvalIn &e, int plane, int c, bool cfl, int alpha, const uint8_t *src, int sp) {
    const TxR T(W, H);
    const int tid = tid_;
    const bool big = rc_big(W, H);
    device RcBigScr &BG = *S.bigG;
    int16_t *res = big ? (int16_t *)BG.res : (int16_t *)S.u.w[0].res;
    float *tmp = big ? (float *)BG.tmp : (float *)S.u.w[0].tmp;
    if (plane == 0 && is_fi(c)) {
        if (tid < 32) rc_residual(W, H, S, tid_, plane, c, cfl, alpha, src, sp, res, (uint8_t *)tmp);
    } else {
        if (tid < 32) rc_prepare_edges(S, tid_, plane, c, cfl, T.lw, T.lh);
        __syncthreads();
        for (int p = tid; p < W * H; p += RC_NT) {
            const int i = p / W, j = p % W;
            res[p] = (int16_t)((int)src[i * sp + j] - rc_pred(S, tid_, plane, c, cfl, alpha, i, j, T.lw, T.lh, W, 0));
        }
    }
    __syncthreads();
    // forward transform (mirrors warp_fwd_rt)
    const int th = T.th, tw = T.tw;
    const int rk = av1g_row_kind(e.txType), ck = av1g_col_kind(e.txType);
    const int fud = av1g_flip_ud(e.txType), flr = av1g_flip_lr(e.txType);
    {
        AV1G_CONST const float *Fc = g_fwd + g_fwdOff[ck][T.lh];
        AV1G_CONST const float *FcT = g_fwdT + g_fwdOff[ck][T.lh];
        const int nc = rc_chunks(th, W), TC = th / nc;
        if (TC == 4) cta_fwd_col<4>(res, tmp, W, H, th, ck, fud, flr, Fc, FcT, nc, tid_);
        else if (TC == 8) cta_fwd_col<8>(res, tmp, W, H, th, ck, fud, flr, Fc, FcT, nc, tid_);
        else cta_fwd_col<16>(res, tmp, W, H, th, ck, fud, flr, Fc, FcT, nc, tid_);
    }
    __syncthreads();
    {
        AV1G_CONST const float *Fr = g_fwd + g_fwdOff[rk][T.lw];
        AV1G_CONST const float *FrT = g_fwdT + g_fwdOff[rk][T.lw];
        const float scale = g_txScale[e.txSz];
        const int nc = rc_chunks(tw, th), TC = tw / nc;
        if (TC == 4) cta_fwd_row<4>(tmp, W, th, rk, Fr, FrT, scale, nc, tid_);
        else if (TC == 8) cta_fwd_row<8>(tmp, W, th, rk, Fr, FrT, scale, nc, tid_);
        else cta_fwd_row<16>(tmp, W, th, rk, Fr, FrT, scale, nc, tid_);
    }
    __syncthreads();
    // quantization (mirrors warp_quant_rate_rt's level computation)
    const int TS = W + 1, n = tw * th, lt = log2i(tw);
    const int den = av1g_dq_denom(e.txSz);
    int16_t *q = S.qfin;
    for (int idx = tid; idx < n; idx += RC_NT) {
        const int i = idx >> lt, j = idx & (tw - 1);
        const float v = tmp[i * TS + j];
        const int step = av1g_qm_step(idx == 0 ? e.dcQ : e.acQ, e.qm, idx);
        const float a = fabsf(v) * (float)den / (float)step;
        const float wr = e.qm ? 32.f / (float)e.qm[idx] : 1.f;
        int l = a < e.zbin ? 0 : (int)(a + (e.qmRnd ? e.rnd * wr : e.rnd));
        l = min(l, 16383);
        const int qv = v < 0 ? -l : l;
        q[idx] = (int16_t)qv;
    }
    if (tid == 0) S.finEob = 0;
    __syncthreads();
    AV1G_CONST const uint16_t *scan = av1g_get_scan(e.txSz, e.txType);
    int last = 0;
    for (int cc = tid; cc < n; cc += RC_NT)
        if (q[scan[cc]]) last = cc + 1;
    last = warp_max(last);
    if ((tid & 31) == 0 && last) atomicMax(&S.finEob, last);
    __syncthreads();
}

// reconstruction base = prediction = src - residual (the residual of the final candidate is exact:
// res = src - pred in integers), instead of evaluating the prediction again (CTA)
__device__ void rc_write_from_res(int W, int H, const uint8_t *src, int sp, const int16_t *res, uint8_t *dst, int pitch, int tid_) {
    for (int p = tid_; p < W * H; p += RC_NT) {
        const int i = p / W, j = p % W;
        dst[i * pitch + j] = (uint8_t)((int)src[i * sp + j] - (int)res[p]);
    }
    __syncthreads();
}

// write prediction into the reconstruction (CTA)
__device__ void rc_write_pred(int W, int H, threadgroup const RcShared &S, int tid_, int plane, int c, bool cfl, int alpha, uint8_t *dst, int pitch) {
    const TxR T(W, H);
    if (plane == 0 && is_fi(c)) {
        if (tid_ == 0)
            av1g_predict_filter_intra(c - 128, T.lw, T.lh, S.ea[0] + AV1G_EDGE_OFF, S.el[0] + AV1G_EDGE_OFF, dst, pitch);
        __syncthreads();
        return;
    }
    for (int p = tid_; p < W * H; p += RC_NT) {
        const int i = p / W, j = p % W;
        dst[i * pitch + j] = (uint8_t)rc_pred(S, tid_, plane, c, cfl, alpha, i, j, T.lw, T.lh, W, 0);
    }
    __syncthreads();
}

// record a finished tx block: txb entry, coefficients, context maps, BlockDecoded.  Returns eob.
__device__ int rc_record_txb(int W, int H, threadgroup RcShared &S, int tid_, constant GpBatch &B, uint32_t sb, device const GpImage &I, int plane, int txSz, int txType,
                             int x4, int y4, int sbr4, int sbc4) {
    const TxR T(W, H);
    const int tid = tid_;
    // coefficient offset: read BEFORE the barrier below - thread 0 advances S.nCoef after it, and a warp
    // reading it late wrote its levels one tx block too far, leaving stale memory in the record
    // (racecheck 2026-10-02; the 2-encoder batch-mode V-plane decoder mismatches)
    const uint32_t cOff = (uint32_t)S.nCoef;
    // eob / culLevel / dc category from the final levels (warp 0)
    if (tid < 32) {
        AV1G_CONST const uint16_t *scan = av1g_get_scan(txSz, txType);
        int last = 0;
        for (int c = tid; c < T.n; c += 32) if (S.qfin[scan[c]]) last = c + 1;
        const int eob = warp_max(last);
        int cul = 0;
        for (int c = tid; c < eob; c += 32) { const int v = S.qfin[scan[c]]; cul += v < 0 ? -v : v; }
        cul = warp_sumi(cul);
        if (tid == 0) { S.sEob = eob; S.sCul = min(cul, 63); }
    }
    __syncthreads();
    const int eob = S.sEob, cul = S.sCul;
    const int dcCat = S.qfin[0] < 0 ? 1 : S.qfin[0] > 0 ? 2 : 0;
    int16_t *oc = B.oCoeffs + (size_t)sb * GP_SB_COEFFS + cOff;
    for (int i = tid; i < T.n; i += RC_NT) oc[i] = S.qfin[i];
    // context maps (eob == 0 -> 0, the same as the decoder's skip / all-zero handling)
    const int sub = plane ? 1 : 0;
    const int stride = I.MiCols >> sub, rows = I.MiRows >> sub;
    const int w4 = W >> 2, h4 = H >> 2;
    for (int k = tid; k < w4 * h4; k += RC_NT) {
        const int yy = y4 + k / w4, xx = x4 + k % w4;
        if (yy < rows && xx < stride) {
            I.cLvl[plane][(size_t)yy * stride + xx] = (uint8_t)(eob ? cul : 0);
            I.cDc[plane][(size_t)yy * stride + xx] = (uint8_t)(eob ? dcCat : 0);
        }
    }
    // BlockDecoded (full tx block area, also beyond the frame edge)
    for (int k = tid; k < w4 * h4; k += RC_NT) atomicOr(&S.bdm[plane][sbr4 + k / w4 + 1], 1u << (sbc4 + k % w4 + 1));
    if (tid == 0) {
        av1g_txb t;
        t.coeff_off = cOff;
        t.x4 = (uint16_t)x4; t.y4 = (uint16_t)y4;
        t.plane = (uint8_t)plane; t.tx_size = (uint8_t)txSz;
        t.tx_type = (uint8_t)(plane == 0 && eob == 0 ? AV1G_DCT_DCT : txType);
        t.flags = 0; t.eob = (uint16_t)eob; t.reserved = 0;
        B.oTxb[(size_t)sb * GP_MAX_TXB + S.nTxb] = t;
        S.nTxb++;
        S.nCoef += T.n;
    }
    __syncthreads();
    return eob;
}

// edges of a tx block from the reconstruction, built by threads tid0 .. tid0+nt-1; then one thread
// records the edge-filter inputs and the DC value.  Callers __syncthreads() afterwards.
__device__ __forceinline__ void rc_edges(threadgroup RcShared &S, int tid_, device const GpImage &I, int plane, int px, int py, int lw, int lh, int haveL,
                                         int haveA, int haveAR, int haveBL, int mi_row, int mi_col, int tid0, int nt,
                                         int blkA = -1, int blkL = -1) {
    const int sub = plane ? 1 : 0;
    const int maxX = ((I.MiCols * 4) >> sub) - 1, maxY = ((I.MiRows * 4) >> sub) - 1;
    threadgroup uint8_t *A = S.ea[plane] + AV1G_EDGE_OFF, *L = S.el[plane] + AV1G_EDGE_OFF;
    const int t = (int)tid_ - tid0;
    const bool inGroup = t >= 0 && t < nt;
    if (inGroup)
        build_edges_par(I.rec[plane], I.rpitch[plane], px, py, lw, lh, haveL, haveA, haveAR, haveBL, maxX, maxY, A, L, t, nt);
    // CUDA syncs only the group's warps (a named barrier); Metal has no named barriers, so every
    // thread of the threadgroup reaches this one (every caller is uniform across it)
    if (nt <= 32) { if (inGroup) __syncwarp(); }
    else threadgroup_barrier(mem_flags::mem_threadgroup);
    if (!inGroup) return;
    if (t == 0) {
        S.dcv[plane] = av1g_dc_value(A, L, haveL, haveA, lw, lh);
        S.hvL[plane] = haveL; S.hvA[plane] = haveA; S.px[plane] = px; S.py[plane] = py; S.mx[plane] = maxX; S.my[plane] = maxY;
        S.ft[plane] = I.edgeFilter ? av1g_get_filter_type(plane, mi_row, mi_col, blkA >= 0 ? blkA : haveA, blkL >= 0 ? blkL : haveL,
                                                          I.mYMode, I.mUVMode, I.MiCols) : 0;
    }
}

// ---------------------------------------------------------------------------
// luma of one block (tx size = block size, tx_depth 0)
__device__ __noinline__ void rc_luma(int W, int H, threadgroup RcShared &S, int tid_, constant GpBatch &B, constant GpParams &P, uint32_t sb, device const GpImage &I, int bsize, int x,
                        int y, int availU, int availL, const TileBox &tb, const BlockQ &bq, float lambda, AV1G_CONST const float *C,
                        int *outMode, int *outDelta, int *outEob, int *outFi, int *outTxDepth) {
    const TxR T(W, H);
    const int tid = tid_;
    const int txSz = AV1G_T(Max_Tx_Size_Rect)[bsize];
    const int sbr4 = (y >> 2) & 15, sbc4 = (x >> 2) & 15;
    const int stepX = W >> 2, stepY = H >> 2;
    const int haveAR0 = (S.bdm[0][sbr4 - 1 + 1] >> (sbc4 + stepX + 1)) & 1;
    const int haveBL0 = (S.bdm[0][sbr4 + stepY + 1] >> (sbc4 - 1 + 1)) & 1;
    *outTxDepth = 0;
    rc_edges(S, tid_, I, 0, x, y, T.lw, T.lh, availL, availU, haveAR0, haveBL0, y >> 2, x >> 2, 0, 64);
    device const GpBlockRes &br = B.blk[I.shOff[bsize] + (uint32_t)(y / H) * I.shNbx[bsize] + x / W];
    int skipCtx, dcCtx;
    txb_ctx(I, 0, txSz, x >> 2, y >> 2, bsize, tb, &skipCtx, &dcCtx);
    const int mi_row = y >> 2, mi_col = x >> 2;
    const int am = AV1G_T(Intra_Mode_Context)[availU ? I.mYMode[(size_t)(mi_row - 1) * I.MiCols + mi_col] : AV1G_DC_PRED];
    const int lm = AV1G_T(Intra_Mode_Context)[availL ? I.mYMode[(size_t)mi_row * I.MiCols + mi_col - 1] : AV1G_DC_PRED];
    const bool fiOk = P.filterIntra && av1g_bw4(bsize) <= 8 && av1g_bh4(bsize) <= 8;
    auto mbits = [&](int c) -> float {
        const int m = luma_mode(c);
        float b = C[CID(y_mode[am][lm]) + m];
        if (!is_fi(c) && bsize >= AV1G_BLOCK_8X8 && av1g_is_directional(m)) b += C[CID(angle_delta[m - AV1G_V_PRED]) + cand_delta(c) + 3];
        if (fiOk && m == AV1G_DC_PRED) {
            b += C[CID(filter_intra[bsize]) + (is_fi(c) ? 1 : 0)];
            if (is_fi(c)) b += C[CID(filter_intra_mode) + c - 128];
        }
        return b;
    };
    EvalIn e;
    e.txSz = txSz; e.plane = 0; e.dcQ = bq.dcQ[0]; e.acQ = bq.acQ[0];
    e.rnd = P.rnd; e.zbin = P.zbin; e.skipCtx = skipCtx; e.dcCtx = dcCtx; e.reduced = 0; e.C = C;
    e.intraDir = 0; e.txType = 0; e.qm = 0; e.resEnergy = 0;
    e.qmDist = P.qmDist; e.qmRnd = P.qmRnd;
    const uint8_t *src = I.src[0] + (size_t)y * I.spitch[0] + x;
    const uint8_t *srcP[3] = {src, src, src};
    const int spP[3] = {I.spitch[0], I.spitch[0], I.spitch[0]};
    const int nc = max(1, min((int)br.ncand, P.Krecheck));
    const int set = av1g_get_tx_set_intra(txSz, 0);
    int bestC = br.cand[0], bestT = br.tx;
    __syncthreads();
    const bool big = rc_big(W, H);
    const bool pass2 = P.txSearchCL && set != AV1G_TX_SET_DCTONLY;
    bool evaluated = false;
    if (tid < RC_NW) S.bestJw[tid] = GP_INF;
    // run S.taskC/T on the warps (big tx: warp 0 only); taskJ per task, per-warp best (levels kept)
    // W2: when every task of a pass has the same (non-filter-intra) candidate (pass 2: tx types of
    // the winner), the residual is computed once by the CTA into S.u.w[0].res and shared by all warps
    // (read-only during the evaluation); it also gives the final prediction (src - res) for free.
    int sharedResC = -1;
    float sharedResE = 0.f;
    auto runTasks = [&](bool shared) {
        const int warp = tid >> 5;
        for (int t = warp; t < S.nTask; t += RC_NW) {   // W5: big tasks on every warp (own global slot)
            const int c = S.taskC[t];
            device RcBigScr &BG = S.bigG[warp];
            int16_t *res = big ? (int16_t *)BG.res : (shared ? (int16_t *)S.u.w[0].res : (int16_t *)S.u.w[warp].res);
            float *tmp = big ? (float *)BG.tmp : (float *)S.u.w[warp].tmp;
            int16_t *q = big ? (int16_t *)BG.q : (int16_t *)S.u.w[warp].q;
            EvalIn ee = e;
            ee.txType = S.taskT[t];
            ee.intraDir = intra_dir(c);
            ee.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, ee.txType);
            ee.resEnergy = shared ? sharedResE : rc_residual(W, H, S, tid_, 0, c, false, 0, src, I.spitch[0], res, (uint8_t *)tmp);
            EvalOut o;
            warp_eval_rt(res, tmp, q, ee, o, W, H, tid_ & 31);
            const float J = o.D + lambda * (o.R + mbits(c));
            if ((tid & 31) == 0) S.taskJ[t] = J;
            if (!big) {
                const bool better = J < S.bestJw[warp];   // identical in all lanes (warp-reduced values)
                __syncwarp();
                if (better) {
                    for (int i = tid & 31; i < W * H; i += 32) rc_bestq(S.u, warp)[i] = q[i];
                    if ((tid & 31) == 0) { S.bestJw[warp] = J; S.bestCw[warp] = c; S.bestTw[warp] = ee.txType; S.bestEw[warp] = o.eob; }
                }
                __syncwarp();
            }
        }
        __syncthreads();
    };
    if (P.txAllCL && set != AV1G_TX_SET_DCTONLY) {
        // every re-checked candidate (+ filter-intra modes) x every intra tx type of the set (libaom s3's
        // "tx search in mode evaluation"), in chunks of 32 tasks; per-warp best levels kept across chunks
        int types[16], nTypes = 0;
        for (int t = 0; t < 16; t++)
            if (av1g_tx_type_in_set_intra(set, t)) types[nTypes++] = t;
        const int total = (nc + (fiOk ? 5 : 0)) * nTypes;
        float bJ = GP_INF;
        for (int base = 0; base < total; base += 32) {
            if (tid == 0) {
                int n = 0;
                for (int i = base; i < total && n < 32; i++, n++) {
                    const int k = i / nTypes;
                    S.taskC[n] = k < nc ? br.cand[k] : 128 + (k - nc);
                    S.taskT[n] = types[i % nTypes];
                    S.taskP[n] = 0;
                }
                S.nTask = n;
            }
            __syncthreads();
            runTasks(false);
            for (int t = 0; t < S.nTask; t++)
                if (S.taskJ[t] < bJ) { bJ = S.taskJ[t]; bestC = S.taskC[t]; bestT = S.taskT[t]; }
            __syncthreads();   // all threads read the chunk before thread 0 writes the next one
        }
        evaluated = true;
    } else if (nc > 1 || pass2 || fiOk) {
        // pass 1: candidates with DCT_DCT (+ the analysis winner with its tx type, + filter-intra modes)
        if (tid == 0) {
            int n = 0;
            for (int k = 0; k < nc; k++) { S.taskC[n] = br.cand[k]; S.taskT[n] = AV1G_DCT_DCT; S.taskP[n] = 0; n++; }
            if (br.tx != AV1G_DCT_DCT) { S.taskC[n] = br.cand[0]; S.taskT[n] = br.tx; S.taskP[n] = 0; n++; }
            if (fiOk)
                for (int f = 0; f < 5; f++) { S.taskC[n] = 128 + f; S.taskT[n] = AV1G_DCT_DCT; S.taskP[n] = 0; n++; }
            S.nTask = n;
        }
        __syncthreads();
        const bool skip1 = S.nTask == 1;   // nothing to compare: bestC = that candidate
        if (!skip1) {
            runTasks(false);
            evaluated = true;
            float bJ = GP_INF;
            for (int t = 0; t < S.nTask; t++)
                if (S.taskJ[t] < bJ) { bJ = S.taskJ[t]; bestC = S.taskC[t]; bestT = S.taskT[t]; }
            __syncthreads();
        } else {
            bestC = S.taskC[0];
            bestT = S.taskT[0];
        }
        // every thread must have read S.nTask / taskC / taskT before thread 0 rewrites them for pass 2:
        // without this barrier a late warp saw pass 2's nTask, took the !skip1 branch (runTasks and its
        // __syncthreads) and misaligned the CTA's barriers - rare, timing-dependent corrupt records
        // (racecheck 2026-10-02; seen as V-plane decoder mismatches in 2-encoder batch runs)
        __syncthreads();
        // pass 2: tx-type search for the winner with the real residual (all types if pass 1 was skipped)
        if (pass2) {
            if (tid == 0) {
                int n = 0;
                for (int t = 0; t < 16; t++) {
                    if (!av1g_tx_type_in_set_intra(set, t)) continue;
                    if (!skip1 && (t == AV1G_DCT_DCT || (bestC == br.cand[0] && t == br.tx))) continue;
                    S.taskC[n] = bestC; S.taskT[n] = t; S.taskP[n] = 0; n++;
                }
                S.nTask = n;
            }
            __syncthreads();
            if (S.nTask > 0) {
                if (!big && !is_fi(bestC)) {
                    // shared residual of bestC: edges by warp 0 (slot 0), residual by the CTA; energy with the
                    // lane order of rc_residual (warp 0) so EvalIn.resEnergy is bit-identical
                    if (tid < 32) rc_prepare_edges(S, tid_, 0, bestC, false, T.lw, T.lh);
                    __syncthreads();
                    int16_t *res = S.u.w[0].res;
                    for (int p = tid; p < W * H; p += RC_NT) {
                        const int i = p / W, j = p % W;
                        res[p] = (int16_t)((int)src[i * I.spitch[0] + j] - rc_pred(S, tid_, 0, bestC, false, 0, i, j, T.lw, T.lh, W, 0));
                    }
                    __syncthreads();
                    if (W == 64 || H == 64) {   // only the 64-point distortion uses the energy (never in pass 2)
                        float en = 0.f;
                        for (int p = tid & 31; p < W * H; p += 32) en += (float)((int)res[p] * (int)res[p]);
                        sharedResE = warp_sum(en);
                    }
                    sharedResC = bestC;
                    runTasks(true);
                } else {
                    runTasks(false);
                }
                evaluated = true;
                if (big) {
                    float bJ = GP_INF;
                    for (int t = 0; t < S.nTask; t++)
                        if (S.taskJ[t] < bJ) { bJ = S.taskJ[t]; bestT = S.taskT[t]; }
                }
            }
            __syncthreads();
        }
    }
    int bestW = -1;
    if (evaluated && !big) {   // overall winner = best of the per-warp minima (levels already quantized)
        float bJ = GP_INF;
        for (int w = 0; w < RC_NW; w++)
            if (S.bestJw[w] < bJ) { bJ = S.bestJw[w]; bestW = w; }
        if (bestW >= 0) { bestC = S.bestCw[bestW]; bestT = S.bestTw[bestW]; }
    }
    (void)srcP; (void)spP;
    // final quantization + reconstruction
    e.txType = bestT;
    e.intraDir = intra_dir(bestC);
    e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, bestT);
    float J0;
    const bool trySplit = P.txSizeSearch && av1g_max_tx_depth(bsize) >= 1;
    // W1/W2: without the tx-size trial the final prediction is src - residual (the shared pass-2
    // residual of bestC, or the final quantization's), no second prediction pass
    const int16_t *predRes = nullptr;
    if (bestW >= 0) {
        // reuse the winner's levels
        for (int i = tid; i < W * H; i += RC_NT) S.qfin[i] = rc_bestq(S.u, bestW)[i];
        if (tid == 0) S.finEob = S.bestEw[bestW];
        if (!trySplit && sharedResC == bestC) predRes = S.u.w[0].res;
        else if (tid < 32) rc_prepare_edges(S, tid_, 0, bestC, false, T.lw, T.lh);
        __syncthreads();
        J0 = S.bestJw[bestW];
    } else if (trySplit) {
        rc_final_quant_rd(W, H, S, tid_, e, 0, bestC, false, 0, src, I.spitch[0]);
        J0 = S.finD + lambda * (S.finR + mbits(bestC));
    } else {
        rc_final_quant(W, H, S, tid_, e, 0, bestC, false, 0, src, I.spitch[0]);
        predRes = big ? (int16_t *)S.bigG->res : (int16_t *)S.u.w[0].res;
        J0 = 0.f;   // only the tx-size trial uses it
    }
    int txDepth = 0;
    if (P.txSizeSearch && av1g_max_tx_depth(bsize) >= 1) {
        // ---- tx-size search: largest tx (above) vs one split level, closed loop: every sub tx block is
        //      predicted from the reconstruction of the previous ones (raster order), tx type searched per
        //      sub block, recorded as it goes; rolled back when depth 0 wins ----
        const int eob0 = S.finEob;
        int16_t *keep0 = bestW >= 0 ? rc_bestq(S.u, bestW) : rc_bestq(S.u, 0);   // union tail, 2 KB
        const int nLv = min(W, 32) * min(H, 32);   // 64-point transforms keep 32x32 levels
        if (bestW < 0)
            for (int i = tid; i < nLv; i += RC_NT) keep0[i] = S.qfin[i];
        const int nTxb0 = S.nTxb, nCoef0 = S.nCoef;
        __syncthreads();
        const int txSub = AV1G_T(Split_Tx_Size)[txSz];
        const int Ws = AV1G_T(Tx_Width)[txSub], Hs = AV1G_T(Tx_Height)[txSub];
        const TxR Ts(Ws, Hs);
        const int setS = av1g_get_tx_set_intra(txSub, 0);
        int types[16], nTypes = 0;
        if ((P.txSearchCL || P.txAllCL) && setS != AV1G_TX_SET_DCTONLY) {
            for (int t = 0; t < 16; t++)
                if (av1g_tx_type_in_set_intra(setS, t)) types[nTypes++] = t;
        } else {
            types[nTypes++] = AV1G_DCT_DCT;
        }
        const bool bigS = rc_big(Ws, Hs);
        const int maxX4 = I.MiCols, maxY4 = I.MiRows;
        const int sqUp = AV1G_T(Tx_Size_Sqr_Up)[txSz];
        // tx_depth symbol, averaged over its 3 contexts
        auto depthBits = [&](int d) -> float {
            float s = 0.f;
            for (int ctx = 0; ctx < 3; ctx++)
                s += sqUp == AV1G_TX_8X8 ? C[CID(tx_8x8[ctx]) + d] : sqUp == AV1G_TX_16X16 ? C[CID(tx_16x16[ctx]) + d]
                   : sqUp == AV1G_TX_32X32 ? C[CID(tx_32x32[ctx]) + d] : C[CID(tx_64x64[ctx]) + d];
            return s * (1.f / 3.f);
        };
        float J1 = lambda * (mbits(bestC) + depthBits(1));
        const float limit = J0 + lambda * depthBits(0);
        int eobAny = 0;
        const int warp = tid >> 5;
        for (int iy = 0; iy < H / Hs && J1 < limit; iy++)
            for (int ix = 0; ix < W / Ws && J1 < limit; ix++) {
                const int xs = x + ix * Ws, ys = y + iy * Hs;
                if ((xs >> 2) >= maxX4 || (ys >> 2) >= maxY4) continue;   // tx blocks outside the frame are not coded
                const int sr4 = (ys >> 2) & 15, sc4 = (xs >> 2) & 15;
                const int hAR = (S.bdm[0][sr4 - 1 + 1] >> (sc4 + (Ws >> 2) + 1)) & 1;
                const int hBL = (S.bdm[0][sr4 + (Hs >> 2) + 1] >> (sc4 - 1 + 1)) & 1;
                rc_edges(S, tid_, I, 0, xs, ys, Ts.lw, Ts.lh, availL || ix > 0, availU || iy > 0, hAR, hBL, y >> 2, x >> 2, 0, 64, availU,
                         availL);
                __syncthreads();
                int sCtx, dCtx;
                txb_ctx(I, 0, txSub, xs >> 2, ys >> 2, bsize, tb, &sCtx, &dCtx);
                EvalIn es = e;
                es.txSz = txSub; es.skipCtx = sCtx; es.dcCtx = dCtx; es.intraDir = intra_dir(bestC);
                const uint8_t *srcS = I.src[0] + (size_t)ys * I.spitch[0] + xs;
                int tSel;
                float Jk;
                if (bigS) {   // 32x32 sub blocks of a 64x64: DCT only, warp 0 into S.qfin
                    es.txType = AV1G_DCT_DCT;
                    es.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSub, AV1G_DCT_DCT);
                    rc_final_quant_rd(Ws, Hs, S, tid_, es, 0, bestC, false, 0, srcS, I.spitch[0]);
                    tSel = AV1G_DCT_DCT;
                    Jk = S.finD + lambda * S.finR;
                } else {
                    float myJ = GP_INF;
                    int myT = AV1G_DCT_DCT, myE = 0;
                    for (int ti = warp; ti < nTypes; ti += RC_NW) {
                        int16_t *res = S.u.w[warp].res, *q = S.u.w[warp].q;
                        float *tmp = S.u.w[warp].tmp;
                        EvalIn ee = es;
                        ee.txType = types[ti];
                        ee.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSub, ee.txType);
                        ee.resEnergy = rc_residual(Ws, Hs, S, tid_, 0, bestC, false, 0, srcS, I.spitch[0], res, (uint8_t *)tmp);
                        EvalOut o;
                        warp_eval_rt(res, tmp, q, ee, o, Ws, Hs, tid_ & 31);
                        const float J = o.D + lambda * o.R;
                        if (J < myJ) {   // warp-uniform
                            __syncwarp();
                            for (int i = tid & 31; i < Ws * Hs; i += 32) rc_taskq(S.u, warp)[i] = q[i];
                            myJ = J; myT = ee.txType; myE = o.eob;
                        }
                        __syncwarp();
                    }
                    if ((tid & 31) == 0) { S.taskJ[warp] = myJ; S.taskT[warp] = myT; S.taskE[warp] = myE; }
                    __syncthreads();
                    int bw = 0;
                    for (int w = 1; w < RC_NW; w++)
                        if (S.taskJ[w] < S.taskJ[bw]) bw = w;
                    for (int i = tid; i < Ws * Hs; i += RC_NT) S.qfin[i] = rc_taskq(S.u, bw)[i];
                    if (tid == 0) S.finEob = S.taskE[bw];
                    tSel = S.taskT[bw];
                    Jk = S.taskJ[bw];
                    if (tid < 32) rc_prepare_edges(S, tid_, 0, bestC, false, Ts.lw, Ts.lh);
                    __syncthreads();
                }
                J1 += Jk;
                uint8_t *dstS = I.rec[0] + (size_t)ys * I.rpitch[0] + xs;
                rc_write_pred(Ws, Hs, S, tid_, 0, bestC, false, 0, dstS, I.rpitch[0]);
                if (S.finEob > 0) {
                    const int fixes = cta_inverse_add(Ws, Hs, S, tid_, S.qfin, txSub, tSel, e.dcQ, e.acQ,
                                                      av1g_qm(I.usingQm, I.qm[0], 0, txSub, tSel), dstS, I.rpitch[0]);
                    if (fixes && tid == 0) atomicAdd(&B.stats[3], 1u);
                }
                eobAny |= rc_record_txb(Ws, Hs, S, tid_, B, sb, I, 0, txSub, tSel, xs >> 2, ys >> 2, sr4, sc4);
            }
        if (J1 < limit) {
            txDepth = 1;
            *outEob = eobAny;
            if (tid == 0) atomicAdd(&B.stats[4], 1u);
        } else {
            // depth 0 wins: drop the trial's tx records, rebuild the block's edges and levels
            __syncthreads();
            if (tid == 0) { S.nTxb = nTxb0; S.nCoef = nCoef0; }
            rc_edges(S, tid_, I, 0, x, y, T.lw, T.lh, availL, availU, haveAR0, haveBL0, y >> 2, x >> 2, 0, 64);
            __syncthreads();
            for (int i = tid; i < nLv; i += RC_NT) S.qfin[i] = keep0[i];
            if (tid == 0) S.finEob = eob0;
            if (tid < 32) rc_prepare_edges(S, tid_, 0, bestC, false, T.lw, T.lh);
            __syncthreads();
        }
    }
    *outTxDepth = txDepth;
    if (txDepth == 0) {
        uint8_t *dst = I.rec[0] + (size_t)y * I.rpitch[0] + x;
        if (predRes) rc_write_from_res(W, H, src, I.spitch[0], predRes, dst, I.rpitch[0], tid_);
        else rc_write_pred(W, H, S, tid_, 0, bestC, false, 0, dst, I.rpitch[0]);
        if (S.finEob > 0) {
            const int fixes = cta_inverse_add(W, H, S, tid_, S.qfin, txSz, bestT, e.dcQ, e.acQ, e.qm, dst, I.rpitch[0]);
            if (fixes && tid == 0) atomicAdd(&B.stats[3], 1u);
        }
        *outEob = rc_record_txb(W, H, S, tid_, B, sb, I, 0, txSz, bestT, x >> 2, y >> 2, sbr4, sbc4);
    }
    *outMode = luma_mode(bestC);
    *outDelta = is_fi(bestC) ? 0 : cand_delta(bestC);
    *outFi = is_fi(bestC) ? bestC - 128 + 1 : 0;
}

// ---------------------------------------------------------------------------
// chroma of one block: U and V tx blocks (one each, W x H = chroma tx size)
__device__ __noinline__ void rc_chroma(int W, int H, threadgroup RcShared &S, int tid_, constant GpBatch &B, constant GpParams &P, uint32_t sb, device const GpImage &I, int bsize,
                          int mi_row, int mi_col, int yMode, int availUC, int availLC, const TileBox &tb, const BlockQ &bq,
                          float lambda, AV1G_CONST const float *C, int *outUv, int *outDuv, int *outAu, int *outAv, int *outEobU, int *outEobV) {
    const TxR T(W, H);
    const int tid = tid_;
    const int txSz = av1g_uv_tx_size(bsize);
    const int cx = (mi_col >> 1) * 4, cy = (mi_row >> 1) * 4;     // chroma pixels
    const int x4 = cx >> 2, y4 = cy >> 2;
    const int sbr4 = (mi_row & 15) >> 1, sbc4 = (mi_col & 15) >> 1;
    const int stepX = W >> 2, stepY = H >> 2;
    {
        const int pl = tid < 64 ? 1 : 2;
        const int haveAR = (S.bdm[pl][sbr4 - 1 + 1] >> (sbc4 + stepX + 1)) & 1;
        const int haveBL = (S.bdm[pl][sbr4 + stepY + 1] >> (sbc4 - 1 + 1)) & 1;
        rc_edges(S, tid_, I, pl, cx, cy, T.lw, T.lh, availLC, availUC, haveAR, haveBL, mi_row, mi_col, pl == 1 ? 0 : 64, 64);
    }
    if (tid < 32) S.satd[tid] = 0.f;
    const uint8_t *srcU = I.src[1] + (size_t)cy * I.spitch[1] + cx;
    const uint8_t *srcV = I.src[2] + (size_t)cy * I.spitch[2] + cx;
    const bool cflOk = P.cfl && av1g_cfl_allowed(bsize);
    const float lamS = P.satdLambda * sqrtf(lambda);
    auto uvbits = [&](int m) -> float {
        if (av1g_cfl_allowed(bsize)) return C[CID(uv_mode_cfl_allowed[yMode]) + m];
        return C[CID(uv_mode_cfl_not_allowed[yMode]) + m];
    };
    const bool uvDeltaOk = P.uvDeltas && bsize >= AV1G_BLOCK_8X8;
    auto uvcbits = [&](int c) -> float {   // candidate code (mode, delta)
        const int m = cand_mode(c);
        float b = uvbits(m);
        if (bsize >= AV1G_BLOCK_8X8 && av1g_is_directional(m)) b += C[CID(angle_delta[m - AV1G_V_PRED]) + cand_delta(c) + 3];
        return b;
    };
    __syncthreads();
    // ---- CfL luma values (reconstructed luma, spec 7.11.5) ----
    if (cflOk) {
        const int lumaTx = AV1G_T(Max_Tx_Size_Rect)[bsize];
        const int maxLumaW = mi_col * 4 + AV1G_T(Tx_Width)[lumaTx], maxLumaH = mi_row * 4 + AV1G_T(Tx_Height)[lumaTx];
        const uint8_t *luma = I.rec[0];
        const int lp = I.rpitch[0];
        int sum = 0;
        for (int p = tid; p < W * H; p += RC_NT) {
            const int i = p / W, j = p % W;
            int lumaY = (cy + i) << 1, lumaX = (cx + j) << 1;
            if (lumaY > maxLumaH - 2) lumaY = maxLumaH - 2;
            if (lumaX > maxLumaW - 2) lumaX = maxLumaW - 2;
            const int t = luma[lumaY * lp + lumaX] + luma[lumaY * lp + lumaX + 1] + luma[(lumaY + 1) * lp + lumaX] +
                          luma[(lumaY + 1) * lp + lumaX + 1];
            const int v = t << 1;
            rc_cflLw(S.u)[p] = (int16_t)v;
            sum += v;
        }
        sum = warp_sumi(sum);
        if (tid == 0) S.cflAvg = 0;
        __syncthreads();
        if ((tid & 31) == 0) atomicAdd(&S.cflAvg, sum);
        __syncthreads();
        if (tid == 0) S.cflAvg = av1g_round2(S.cflAvg, T.lw + T.lh);
        if (tid < 2) { S.cflNum[tid] = 0.f; S.cflDen[tid] = 0.f; }
        __syncthreads();
        // least-squares alpha per plane: r = src - DC, l = v - avg; alpha ~ 64 * sum(r l) / sum(l^2)
        float num[2] = {0.f, 0.f}, den = 0.f;
        for (int p = tid; p < W * H; p += RC_NT) {
            const int i = p / W, j = p % W;
            const float l = (float)(rc_cflL(S.u)[p] - S.cflAvg);
            num[0] += l * (float)((int)srcU[i * I.spitch[1] + j] - S.dcv[1]);
            num[1] += l * (float)((int)srcV[i * I.spitch[2] + j] - S.dcv[2]);
            den += l * l;
        }
        num[0] = warp_sum(num[0]); num[1] = warp_sum(num[1]); den = warp_sum(den);
        if ((tid & 31) == 0) { S.cflPart[tid >> 5][0] = num[0]; S.cflPart[tid >> 5][1] = num[1]; S.cflPart[tid >> 5][2] = den; }
        __syncthreads();
        if (tid == 0)   // in warp order, so the sums don't depend on scheduling
            for (int w = 0; w < RC_NW; w++) { S.cflNum[0] += S.cflPart[w][0]; S.cflNum[1] += S.cflPart[w][1]; S.cflDen[0] += S.cflPart[w][2]; }
        __syncthreads();
        if (tid < 2) {
            const float d = S.cflDen[0];
            int a = d > 0.f ? (int)rintf(64.f * S.cflNum[tid] / d) : 0;
            S.cflAlpha[tid] = max(-16, min(16, a));
        }
        if (tid < 6) S.alphaSse[tid / 3][tid % 3] = 0.f;
        __syncthreads();
        // refine alpha +-1 by pixel SSE
        {
            float sse[2][3] = {{0.f, 0.f, 0.f}, {0.f, 0.f, 0.f}};
            for (int p = tid; p < W * H; p += RC_NT) {
                const int i = p / W, j = p % W;
                const int l = rc_cflL(S.u)[p] - S.cflAvg;
                for (int pl = 0; pl < 2; pl++) {
                    const int s = pl == 0 ? srcU[i * I.spitch[1] + j] : srcV[i * I.spitch[2] + j];
                    for (int k = 0; k < 3; k++) {
                        const int a = max(-16, min(16, S.cflAlpha[pl] + k - 1));
                        const int pr = av1g_clip1(S.dcv[pl + 1] + av1g_round2signed(a * l, 6));
                        const float d = (float)(s - pr);
                        sse[pl][k] += d * d;
                    }
                }
            }
            for (int pl = 0; pl < 2; pl++)
                for (int k = 0; k < 3; k++) {
                    const float v = warp_sum(sse[pl][k]);
                    if ((tid & 31) == 0) S.ssePart[tid >> 5][pl * 3 + k] = v;
                }
        }
        __syncthreads();
        if (tid < 6)   // in warp order
            for (int w = 0; w < RC_NW; w++) S.alphaSse[tid / 3][tid % 3] += S.ssePart[w][tid];
        __syncthreads();
        if (tid == 0) {
            for (int pl = 0; pl < 2; pl++) {
                int bk = 1;
                for (int k = 0; k < 3; k++) if (S.alphaSse[pl][k] < S.alphaSse[pl][bk]) bk = k;
                S.cflAlpha[pl] = max(-16, min(16, S.cflAlpha[pl] + bk - 1));
            }
        }
        __syncthreads();
    }
    // ---- SATD screening of the 13 UV modes (real edges), then angle deltas +-1..3 around the best
    //      directional UV mode ----
    if (tid < 13) S.uvc[tid] = cand_pack(tid, 0);
    __syncthreads();
    int nuv = 13;
    for (int pass = 0; pass < 2; pass++) {
        const int c0 = pass ? 13 : 0, c1 = pass ? 19 : 13;
        if (pass) {
            if (!uvDeltaOk) break;
            if (tid == 0) {
                int bm = -1;
                float bj = GP_INF;
                for (int m = AV1G_V_PRED; m <= AV1G_D67_PRED; m++) {
                    const float j = S.satd[m] + lamS * uvcbits(cand_pack(m, 0));
                    if (j < bj) { bj = j; bm = m; }
                }
                for (int k = 0; k < 6; k++) S.uvc[13 + k] = cand_pack(bm, k < 3 ? -(k + 1) : (k - 2));
            }
            __syncthreads();
            nuv = 19;
        }
        const int nsx = W / 4, nsub = (W / 4) * (H / 4);
        const int nc = c1 - c0;
        const int items = nc * nsub * 2;
        for (int it = tid; it < items; it += RC_NT) {
            const int pl = 1 + it / (nc * nsub);
            const int rr = it % (nc * nsub);
            const int ci = c0 + rr / nsub, sbk = rr % nsub;
            const int sx = (sbk % nsx) * 4, sy = (sbk / nsx) * 4;
            const uint8_t *s = pl == 1 ? srcU : srcV;
            const int sp = I.spitch[pl];
            int d[16];
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++)
                    d[i * 4 + j] = (int)s[(sy + i) * sp + sx + j] - rc_pred(S, tid_, pl, S.uvc[ci], false, 0, sy + i, sx + j, T.lw, T.lh, W);
            atomicAdd(&S.satd[ci], hadamard4_abs(d));
        }
        __syncthreads();
    }
    // ---- exact RD: top uvK modes (+ CfL) for U and V ----
    if (tid == 0) {
        const int K = max(1, min(P.uvK, 6));
        int top[6];
        float tj[6];
        for (int k = 0; k < K; k++) { top[k] = -1; tj[k] = GP_INF; }
        for (int ci = 0; ci < nuv; ci++) {
            const float j = S.satd[ci] + lamS * uvcbits(S.uvc[ci]);
            if (j < tj[K - 1]) {
                int k = K - 1;
                while (k > 0 && tj[k - 1] > j) { tj[k] = tj[k - 1]; top[k] = top[k - 1]; k--; }
                tj[k] = j; top[k] = S.uvc[ci];
            }
        }
        int n = 0;
        for (int k = 0; k < K; k++) {
            if (top[k] < 0) continue;
            for (int pl = 1; pl <= 2; pl++) {
                S.taskC[n] = top[k];
                S.taskT[n] = av1g_chroma_tx_type(txSz, cand_mode(top[k]), 0);
                S.taskP[n] = pl;
                n++;
            }
        }
        if (cflOk && (S.cflAlpha[0] || S.cflAlpha[1])) {
            for (int pl = 1; pl <= 2; pl++) {
                S.taskC[n] = 255;
                S.taskT[n] = av1g_chroma_tx_type(txSz, AV1G_UV_CFL_PRED, 0);
                S.taskP[n] = pl;
                n++;
            }
        }
        S.nTask = n;
    }
    __syncthreads();
    int skipCtxU, dcCtxU, skipCtxV, dcCtxV;
    txb_ctx(I, 1, txSz, x4, y4, bsize, tb, &skipCtxU, &dcCtxU);
    txb_ctx(I, 2, txSz, x4, y4, bsize, tb, &skipCtxV, &dcCtxV);
    EvalIn e;
    e.txSz = txSz; e.plane = 1; e.dcQ = bq.dcQ[1]; e.acQ = bq.acQ[1];
    e.rnd = P.rndC; e.zbin = P.zbinC; e.skipCtx = skipCtxU; e.dcCtx = dcCtxU; e.reduced = 0; e.C = C;
    e.intraDir = 0; e.txType = 0; e.qm = 0; e.resEnergy = 0;
    e.qmDist = P.qmDist; e.qmRnd = P.qmRnd;
    {
        const int warp = tid >> 5;
        const bool big = rc_big(W, H);
        for (int t = warp; t < S.nTask; t += RC_NW) {   // W5: big tasks on every warp (own global slot)
            const int pl = S.taskP[t], c = S.taskC[t];
            const bool cfl = c == 255;
            device RcBigScr &BG = S.bigG[warp];
            int16_t *res = big ? (int16_t *)BG.res : (int16_t *)S.u.w[warp].res;
            float *tmp = big ? (float *)BG.tmp : (float *)S.u.w[warp].tmp;
            int16_t *qq = big ? (int16_t *)BG.q : (int16_t *)S.u.w[warp].q;
            EvalIn ee = e;
            ee.plane = pl;
            ee.dcQ = bq.dcQ[pl]; ee.acQ = bq.acQ[pl];
            ee.skipCtx = pl == 1 ? skipCtxU : skipCtxV;
            ee.dcCtx = pl == 1 ? dcCtxU : dcCtxV;
            ee.txType = S.taskT[t];
            ee.qm = av1g_qm(I.usingQm, I.qm[pl], pl, txSz, ee.txType);
            // Glass Act: av1gpu passes no filter-intra buffer (chroma never uses it), but with the
            // default nullptr reaching rc_residual's filter-intra branch, Metal's GPU compiler crashes
            // (MTLCompilerService SIGSEGV in LLVM's ScalarEvolution, macOS 27.2); luma passes its tmp too
            ee.resEnergy = rc_residual(W, H, S, tid_, pl, c, cfl, cfl ? S.cflAlpha[pl - 1] : 0, pl == 1 ? srcU : srcV, I.spitch[pl], res,
                                       (uint8_t *)tmp);

            EvalOut o;
            warp_eval_rt(res, tmp, qq, ee, o, W, H, tid_ & 31);

            if (!big && t < RC_TASKQ_MAX) {   // keep the levels: the final of the winner reuses them
                int16_t *dq = rc_taskq(S.u, t);
                for (int i = tid & 31; i < W * H; i += 32) dq[i] = qq[i];
                if ((tid & 31) == 0) S.taskE[t] = o.eob;
            } else if (big && t < RC_BIGQ_MAX) {   // W3: big tasks keep theirs in global memory
                int16_t *dq = S.bigQ + t * 1024;
                for (int i = tid & 31; i < T.n; i += 32) dq[i] = qq[i];
                if ((tid & 31) == 0) S.taskE[t] = o.eob;
            }
            if ((tid & 31) == 0) S.taskJ[t] = o.D + lambda * o.R;
        }
        __syncthreads();
    }
    // pick the best mode (sum over U and V + mode bits)
    int bestUv = AV1G_DC_PRED, bestUvC = cand_pack(AV1G_DC_PRED, 0);
    {
        float bJ = GP_INF;
        for (int t = 0; t + 1 < S.nTask; t += 2) {
            const int c = S.taskC[t];
            float J = S.taskJ[t] + S.taskJ[t + 1];
            int uv;
            if (c == 255) {
                uv = AV1G_UV_CFL_PRED;
                const int aU = S.cflAlpha[0], aV = S.cflAlpha[1];
                const int sU = aU == 0 ? 0 : aU < 0 ? 1 : 2, sV = aV == 0 ? 0 : aV < 0 ? 1 : 2;
                float b = uvbits(AV1G_UV_CFL_PRED) + C[CID(cfl_sign) + sU * 3 + sV - 1];
                if (sU) b += C[CID(cfl_alpha[(sU - 1) * 3 + sV]) + abs(aU) - 1];
                if (sV) b += C[CID(cfl_alpha[(sV - 1) * 3 + sU]) + abs(aV) - 1];
                J += lambda * b;
            } else {
                uv = cand_mode(c);
                J += lambda * uvcbits(c);
            }
            if (J < bJ) { bJ = J; bestUv = uv; bestUvC = c; }
        }
    }
    __syncthreads();
    const bool cfl = bestUv == AV1G_UV_CFL_PRED;
    const int uvTxType = av1g_chroma_tx_type(txSz, bestUv, 0);
    int eobs[2];
    for (int pl = 1; pl <= 2; pl++) {
        EvalIn ee = e;
        ee.plane = pl;
        ee.dcQ = bq.dcQ[pl]; ee.acQ = bq.acQ[pl];
        ee.skipCtx = pl == 1 ? skipCtxU : skipCtxV;
        ee.dcCtx = pl == 1 ? dcCtxU : dcCtxV;
        ee.txType = uvTxType;
        ee.qm = av1g_qm(I.usingQm, I.qm[pl], pl, txSz, uvTxType);
        const int alpha = cfl ? S.cflAlpha[pl - 1] : 0;
        const int c = cfl ? 255 : bestUvC;
        const uint8_t *s = pl == 1 ? srcU : srcV;
        int kept = -1;
        const bool bigC = rc_big(W, H);
        for (int t = 0; t < S.nTask && t < (bigC ? RC_BIGQ_MAX : RC_TASKQ_MAX); t++)
            if (S.taskP[t] == pl && S.taskC[t] == c) { kept = t; break; }
        if (kept >= 0) {
            if (bigC) for (int i = tid; i < T.n; i += RC_NT) S.qfin[i] = S.bigQ[kept * 1024 + i];
            else for (int i = tid; i < W * H; i += RC_NT) S.qfin[i] = rc_taskq(S.u, kept)[i];
            if (tid == 0) S.finEob = S.taskE[kept];
            if (tid < 32) rc_prepare_edges(S, tid_, pl, c, cfl, T.lw, T.lh);
            __syncthreads();
            uint8_t *dst = I.rec[pl] + (size_t)cy * I.rpitch[pl] + cx;
            rc_write_pred(W, H, S, tid_, pl, c, cfl, alpha, dst, I.rpitch[pl]);
        } else {
            rc_final_quant(W, H, S, tid_, ee, pl, c, cfl, alpha, s, I.spitch[pl]);
            uint8_t *dst = I.rec[pl] + (size_t)cy * I.rpitch[pl] + cx;
            rc_write_from_res(W, H, s, I.spitch[pl], rc_big(W, H) ? (int16_t *)S.bigG->res : (int16_t *)S.u.w[0].res, dst, I.rpitch[pl], tid_);
        }
        uint8_t *dst = I.rec[pl] + (size_t)cy * I.rpitch[pl] + cx;
        if (S.finEob > 0) {
            const int fixes = cta_inverse_add(W, H, S, tid_, S.qfin, txSz, uvTxType, ee.dcQ, ee.acQ, ee.qm, dst, I.rpitch[pl]);
            if (fixes && tid == 0) atomicAdd(&B.stats[3], 1u);
        }
        eobs[pl - 1] = rc_record_txb(W, H, S, tid_, B, sb, I, pl, txSz, uvTxType, x4, y4, sbr4, sbc4);
    }
    *outUv = bestUv;
    *outDuv = cfl ? 0 : cand_delta(bestUvC);
    *outAu = cfl ? S.cflAlpha[0] : 0;
    *outAv = cfl ? S.cflAlpha[1] : 0;
    *outEobU = eobs[0];
    *outEobV = eobs[1];
}

// ---------------------------------------------------------------------------
kernel void k_recon(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                    device const uint32_t *sbList [[buffer(2)]], uint blockIdx_x [[threadgroup_position_in_grid]],
                    uint tidU [[thread_position_in_threadgroup]]) {
    threadgroup RcShared S;
    const int tid_ = (int)tidU;
    const uint32_t sb = sbList[blockIdx_x];
    device const GpImage &I = B.img[B.sbImg[sb]];
    const uint32_t local = sb - I.sbBase;
    const int sbc = (int)(local % I.sbCols), sbr = (int)(local / I.sbCols);
    const int sbx = sbc * 64, sby = sbr * 64;
    const int tid = tid_;
    const TileBox tb = tile_of(I, sbx, sby);
    const int miRowEnd = tb.y1 >> 2, miColEnd = tb.x1 >> 2;
    if (P.poisonSmem) {   // debug: uninitialised shared-memory reads become a fixed pattern (0x7F7F levels)
        for (int i = tid; i < (int)(sizeof(RcShared) / 4); i += RC_NT) ((threadgroup uint32_t *)&S)[i] = 0x7F7F7F7Fu;
        __syncthreads();
    }
    // clear_block_decoded_flags (spec): one thread per (plane, row) word
    if (tid < 3 * 18) {
        const int p = tid / 18, yy = tid % 18 - 1;
        const int sub = p ? 1 : 0;
        const int sbW4 = (miColEnd - sbc * 16) >> sub, sbH4 = (miRowEnd - sbr * 16) >> sub;
        uint32_t w = 0;
        for (int xx = -1; xx <= 16; xx++) {
            int v;
            if (yy < 0 && xx < sbW4) v = 1;
            else if (xx < 0 && yy < sbH4) v = 1;
            else v = 0;
            if (yy == (16 >> sub) && xx == -1) v = 0;
            w |= (uint32_t)v << (xx + 1);
        }
        S.bdm[p][yy + 1] = w;
    }
    const int nLeaves = B.leafCountW[sb];
    if (tid == 0) { S.nTxb = 0; S.nCoef = 0; S.edgeFilter = I.edgeFilter; S.bigG = (device RcBigScr *)((device char *)B.bigScratch + (size_t)blockIdx_x * RC_CTA_BIG_BYTES); S.bigQ = (device int16_t *)(S.bigG + RC_NW); }
    const int qidx = sb_qindex(I, sbx, sby);
    const BlockQ bq = block_q(I, qidx);
    const float lambda = gp_lambda(qidx, P.lambdaMul);
    AV1G_CONST const float *C = g_cost[I.qctx];
    __syncthreads();
    for (int li = 0; li < nLeaves; li++) {
        const GpLeaf lf = B.leaves[(size_t)sb * GP_MAX_LEAVES + li];
        const int bsize = lf.bsize;
        const int x = sbx + lf.x4 * 4, y = sby + lf.y4 * 4;
        const int mi_row = y >> 2, mi_col = x >> 2;
        int availU, availL, availUC, availLC;
        av1g_block_avail(bsize, mi_row, mi_col, I.mono, tb.y0 >> 2, miRowEnd, tb.x0 >> 2, miColEnd, &availU, &availL, &availUC,
                         &availLC);
        const int hasChroma = av1g_has_chroma(bsize, mi_row, mi_col, I.mono);
        const uint32_t firstTxb = (uint32_t)S.nTxb;
        const float lambdaB = lambda * ssim_scale(I, x, y, bw_px(bsize), bh_px(bsize));
        int yMode = 0, yDelta = 0, eobY = 0, yFi = 0, yTxDepth = 0;
        const int txSz = AV1G_T(Max_Tx_Size_Rect)[bsize];
rc_luma(AV1G_T(Tx_Width)[txSz], AV1G_T(Tx_Height)[txSz], S, tid_, B, P, sb, I, bsize, x, y, availU, availL, tb, bq, lambdaB, C, &yMode, &yDelta, &eobY, &yFi, &yTxDepth);
        int uv = 0, duv = 0, aU = 0, aV = 0, eobU = 0, eobV = 0;
        if (hasChroma) {
            const int uvTx = av1g_uv_tx_size(bsize);
rc_chroma(AV1G_T(Tx_Width)[uvTx], AV1G_T(Tx_Height)[uvTx], S, tid_, B, P, sb, I, bsize, mi_row, mi_col, yMode, availUC, availLC, tb, bq, lambdaB * P.lambdaCMul, C, &uv, &duv, &aU, &aV, &eobU, &eobV);
        }
        const int skip = (eobY == 0 && eobU == 0 && eobV == 0) ? 1 : 0;
        // maps
        const int bw4 = av1g_bw4(bsize), bh4 = av1g_bh4(bsize);
        for (int k = tid; k < bw4 * bh4; k += RC_NT) {
            const int r = mi_row + k / bw4, c = mi_col + k % bw4;
            if (r < I.MiRows && c < I.MiCols) {
                const size_t o = (size_t)r * I.MiCols + c;
                I.mYMode[o] = (uint8_t)yMode;
                if (hasChroma) I.mUVMode[o] = (uint8_t)uv;
                I.mSkip[o] = (uint8_t)skip;
                I.mMiSize[o] = (uint8_t)bsize;
                I.mTx[o] = (uint8_t)(yTxDepth ? AV1G_T(Split_Tx_Size)[txSz] : txSz);
            }
        }
        if (tid == 0) {
            av1g_block b;
            b.mi_row = (uint16_t)mi_row; b.mi_col = (uint16_t)mi_col;
            b.bsize = (uint8_t)bsize; b.skip = (uint8_t)skip; b.tx_depth = (uint8_t)yTxDepth;
            b.y_mode = (uint8_t)yMode; b.angle_delta_y = (int8_t)(bsize >= AV1G_BLOCK_8X8 && av1g_is_directional(yMode) ? yDelta : 0);
            b.uv_mode = (uint8_t)(hasChroma ? uv : 0);
            b.angle_delta_uv = (int8_t)(hasChroma && bsize >= AV1G_BLOCK_8X8 && av1g_is_directional(uv) ? duv : 0);
            b.cfl_alpha_u = (int8_t)aU; b.cfl_alpha_v = (int8_t)aV;
            b.filter_intra = (uint8_t)yFi; b.cdef_idx = 0;
            b.sb_qindex = (uint8_t)(I.sbQ ? qidx : 0);
            B.oBlocks[(size_t)sb * GP_MAX_LEAVES + li] = b;
            B.oBlockTxb[(size_t)sb * GP_MAX_LEAVES + li] = (uint16_t)firstTxb;
            if (skip) atomicAdd(&B.stats[1], 1u);
            if (hasChroma && uv == AV1G_UV_CFL_PRED) atomicAdd(&B.stats[2], 1u);
            atomicAdd(&B.stats[0], 1u);
        }
        __syncthreads();
    }
    if (tid == 0) {
        GpSbOut o;
        o.nBlocks = (uint32_t)nLeaves; o.nTxb = (uint32_t)S.nTxb; o.nCoeffs = (uint32_t)S.nCoef; o.pad = 0;
        B.sbOut[sb] = o;
    }
}
