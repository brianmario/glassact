// Glass Act: av1gpu's encoder/src/dev_tx.cuh (BSD-2, Sources/AV1Core/LICENSE), for Metal: the
// lane is a parameter (CUDA's threadIdx is a global; Metal's thread indices are kernel
// arguments), pointers into tables say AV1G_CONST, and the transposed forward matrices are
// read as float4 from the generated, 16-byte aligned g_fwdT.
// warp-level "evaluate one transform block": float forward transform, dead-zone
// quantization (incl. quantizer matrices), exact coefficient rate from the AV1 default CDFs (all
// in-block contexts computed in parallel), transform-domain distortion.
#pragma once
#include "dev_common.h"

// Glass Act: the warp-level routines below take NT threads to one block (default one SIMD-group;
// more for the big shapes, k_analysis): NT > 32 syncs with threadgroup barriers and reduces
// through `red` / `redi` (NT / 32 entries of threadgroup memory), the SIMD-groups' partials summed
// in a fixed order. NT == 32 is the SIMD-group code as it was.
template <int NT>
__device__ __forceinline__ void ga_sync() {
    if (NT > 32) threadgroup_barrier(mem_flags::mem_threadgroup);
    else __syncwarp();
}
template <int NT>
__device__ __forceinline__ float ga_sum(float v, int tid, float *red) {
    v = warp_sum(v);
    if (NT == 32) return v;
    threadgroup_barrier(mem_flags::mem_threadgroup);  // (red free)
    if ((tid & 31) == 0) red[tid >> 5] = v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float t = 0.f;
    for (int w = 0; w < NT / 32; w++) t += red[w];
    return t;
}
template <int NT>
__device__ __forceinline__ uint ga_sumu(uint v, int tid, int *redi) {
    v = simd_sum(v);
    if (NT == 32) return v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if ((tid & 31) == 0) redi[tid >> 5] = (int)v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint t = 0;
    for (int w = 0; w < NT / 32; w++) t += (uint)redi[w];
    return t;
}
template <int NT>
__device__ __forceinline__ int ga_max(int v, int tid, int *redi) {
    v = warp_max(v);
    if (NT == 32) return v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if ((tid & 31) == 0) redi[tid >> 5] = v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int t = redi[0];
    for (int w = 1; w < NT / 32; w++) t = max(t, redi[w]);
    return t;
}

template <int W, int H>
struct TxD {
    static constexpr constant int w = W, h = H;
    static constexpr constant int tw = W > 32 ? 32 : W, th = H > 32 ? 32 : H;
    static constexpr constant int TS = W + 1;        // tmp row stride (floats), odd -> conflict-free
    static constexpr constant int n = tw * th;
    static constexpr constant int lw = W == 4 ? 2 : W == 8 ? 3 : W == 16 ? 4 : W == 32 ? 5 : 6;
    static constexpr constant int lh = H == 4 ? 2 : H == 8 ? 3 : H == 16 ? 4 : H == 32 ? 5 : 6;
    // scratch sizes (bytes)
    static constexpr constant int resBytes = W * H * 2;
    static constexpr constant int tmpBytes = th * TS * 4;
    static constexpr constant int qBytes = n * 2;
};

struct EvalIn {
    int txSz, txType, plane;     // plane 0 = Y
    int dcQ, acQ;                // quantizers (pre-dqDenom), already offset by delta-q
    AV1G_CONST const uint8_t *qm; // av1g_qm(...) or NULL
    float rnd, zbin;
    int skipCtx, dcCtx;          // txb_skip context, dc_sign context
    int intraDir;                // luma mode (tx-type CDF context)
    int reduced;                 // reduced_tx_set
    AV1G_CONST const float *C;   // cost table (image's q-context)
    float resEnergy;             // sum r^2 (needed for 64-point transforms: energy of dropped coefficients)
    int qmDist, qmRnd;           // QM-weighted distortion / QM-scaled rounding (GpParams)
};
struct EvalOut {
    float D, R;   // pixel-domain SSE estimate, bits (coefficients + txb_skip + tx type)
    int eob;
};

__device__ __forceinline__ int tx_type_index_in_set(int set, int t) {
    if (set == AV1G_TX_SET_INTRA_1) {
        for (int i = 0; i < 7; i++) if (AV1G_T(Tx_Type_Intra_Inv_Set1)[i] == t) return i;
    } else {
        for (int i = 0; i < 5; i++) if (AV1G_T(Tx_Type_Intra_Inv_Set2)[i] == t) return i;
    }
    return 0;
}

// fixed part of the coefficient rate: txb_skip, tx type (luma), eob position
static __device__ float base_bits(thread const EvalIn &e, int eob) {
    const int txSz = e.txSz;
    const int txSzCtx = (AV1G_T(Tx_Size_Sqr)[txSz] + AV1G_T(Tx_Size_Sqr_Up)[txSz] + 1) >> 1;
    AV1G_CONST const float *C = e.C;
    if (eob == 0) return C[CID(txb_skip[txSzCtx][e.skipCtx]) + 1];
    float b = C[CID(txb_skip[txSzCtx][e.skipCtx]) + 0];
    const int ptype = e.plane > 0;
    if (e.plane == 0) {
        const int set = av1g_get_tx_set_intra(txSz, e.reduced);
        if (set > 0) {
            const int sqr = AV1G_T(Tx_Size_Sqr)[txSz];
            const int idx = tx_type_index_in_set(set, e.txType);
            if (set == AV1G_TX_SET_INTRA_1) b += C[CID(intra_tx_set1[sqr][e.intraDir]) + idx];
            else b += C[CID(intra_tx_set2[sqr][e.intraDir]) + idx];
        }
    }
    const int txClass = av1g_tx_class(e.txType);
    const int eobMultisize = min((int)AV1G_T(Tx_Width_Log2)[txSz], 5) + min((int)AV1G_T(Tx_Height_Log2)[txSz], 5) - 4;
    int eobPt;
    if (eob <= 2) eobPt = eob;
    else { eobPt = 2; int v = eob - 1; while (v > 1) { v >>= 1; eobPt++; } }
    const int ectx = txClass == AV1G_TX_CLASS_2D ? 0 : 1;
    uint32_t c;
    switch (eobMultisize) {
    case 0: c = CID(eob_pt_16[ptype][ectx]); break;
    case 1: c = CID(eob_pt_32[ptype][ectx]); break;
    case 2: c = CID(eob_pt_64[ptype][ectx]); break;
    case 3: c = CID(eob_pt_128[ptype][ectx]); break;
    case 4: c = CID(eob_pt_256[ptype][ectx]); break;
    case 5: c = CID(eob_pt_512[ptype]); break;
    default: c = CID(eob_pt_1024[ptype]); break;
    }
    b += C[c + eobPt - 1];
    if (eobPt >= 3) {
        const int rem = eob - ((1 << (eobPt - 2)) + 1);
        b += C[CID(eob_extra[txSzCtx][ptype][eobPt - 3]) + ((rem >> (eobPt - 3)) & 1)];
        b += (float)(eobPt - 3);
    }
    return b;
}

// rate of the coefficient at scan position c (< eob), given all quantized levels q (natural order)
static __device__ float coeff_bits(int c, int eob, const int16_t *q, AV1G_CONST const uint16_t *scan, int txSz, int txClass, int ptype,
                            int dcCtx, AV1G_CONST const float *C) {
    const int txSzCtx = (AV1G_T(Tx_Size_Sqr)[txSz] + AV1G_T(Tx_Size_Sqr_Up)[txSz] + 1) >> 1;
    const int adj = AV1G_T(Adjusted_Tx_Size)[txSz];
    const int bwl = AV1G_T(Tx_Width_Log2)[adj];
    const int width = 1 << bwl, height = AV1G_T(Tx_Height)[adj];
    const int pos = scan[c];
    const int qv = q[pos];
    const int v = qv < 0 ? -qv : qv;
    const int level = v < 15 ? v : 15;
    const int row = pos >> bwl, col = pos - (row << bwl);
    float b;
    if (c == eob - 1) {
        const int bctx = c == 0 ? 0 : c <= (height << bwl) / 8 ? 1 : c <= (height << bwl) / 4 ? 2 : 3;
        b = C[CID(coeff_base_eob[txSzCtx][ptype][bctx]) + min(level, 3) - 1];
    } else {
        int mag = 0;
#pragma unroll
        for (int idx = 0; idx < 5; idx++) {
            const int rr = row + AV1G_T(Sig_Ref_Diff_Offset)[txClass][idx][0];
            const int cc = col + AV1G_T(Sig_Ref_Diff_Offset)[txClass][idx][1];
            if (rr >= 0 && cc >= 0 && rr < height && cc < width) {
                int a = q[(rr << bwl) + cc];
                a = a < 0 ? -a : a;
                mag += min(a, 3);
            }
        }
        int bctx = min((mag + 1) >> 1, 4);
        if (txClass == AV1G_TX_CLASS_2D) {
            if (row == 0 && col == 0) bctx = 0;
            else bctx += AV1G_T(Coeff_Base_Ctx_Offset)[txSz][min(row, 4)][min(col, 4)];
        } else {
            const int id = txClass == AV1G_TX_CLASS_VERT ? row : col;
            bctx += AV1G_T(Coeff_Base_Pos_Ctx_Offset)[min(id, 2)];
        }
        b = C[CID(coeff_base[txSzCtx][ptype][bctx]) + min(level, 3)];
    }
    if (level > 2) {
        int mag = 0;
#pragma unroll
        for (int idx = 0; idx < 3; idx++) {
            const int rr = row + AV1G_T(Mag_Ref_Offset_With_Tx_Class)[txClass][idx][0];
            const int cc = col + AV1G_T(Mag_Ref_Offset_With_Tx_Class)[txClass][idx][1];
            if (rr >= 0 && cc >= 0 && rr < height && cc < width) {
                int a = q[rr * width + cc];
                a = a < 0 ? -a : a;
                mag += min(a, 15);
            }
        }
        mag = min((mag + 1) >> 1, 6);
        int brctx;
        if (pos == 0) brctx = mag;
        else if (txClass == AV1G_TX_CLASS_2D) brctx = (row < 2 && col < 2) ? mag + 7 : mag + 14;
        else if (txClass == AV1G_TX_CLASS_HORIZ) brctx = col == 0 ? mag + 7 : mag + 14;
        else brctx = row == 0 ? mag + 7 : mag + 14;
        const int brsz = min(txSzCtx, (int)AV1G_TX_32X32);
        const uint32_t cid = CID(coeff_br[brsz][ptype][brctx]);
        int rem = level - 3;
        for (int i = 0; i < 4; i++) {
            const int k = min(rem, 3);
            b += C[cid + k];
            rem -= k;
            if (k < 3) break;
        }
    }
    if (v) {
        if (c == 0) b += C[CID(dc_sign[ptype][dcCtx]) + (qv < 0)];
        else b += 1.0f;
        if (v > 14) {
            const int xg = v - 14;
            const int len = 31 - __clz(xg);
            b += (float)(2 * len + 1);
        }
    }
    return b;
}

// Forward transform (dequant-domain coefficients into tmp, th x tw with row stride W + 1).
// Runtime sizes; the passes are templated on the number of outputs per lane (TH / TW in 4..32) so
// the accumulators stay in registers.
template <int TH, int NT = 32>
__device__ __forceinline__ void fwd_col_pass(const int16_t *res, float *tmp, int W, int H, int ck, int fud, int flr,
                                             AV1G_CONST const float *Fc, AV1G_CONST const float *FcT, int lane) {
    const int TS = W + 1;
    for (int j = lane; j < W; j += NT) {
        const int jj = flr ? W - 1 - j : j;
        if (ck == AV1G_K_IDT) {   // diagonal (identity transforms are never 64 long, so TH == H)
#pragma unroll
            for (int i = 0; i < TH; i++) tmp[i * TS + j] = __ldg(&Fc[i * H + i]) * (float)res[(fud ? H - 1 - i : i) * W + jj];
            continue;
        }
        float acc[TH];
#pragma unroll
        for (int i = 0; i < TH; i++) acc[i] = 0.f;
        for (int k = 0; k < H; k++) {
            const float x = (float)res[(fud ? H - 1 - k : k) * W + jj];
            AV1G_CONST const float4 *f4 = (AV1G_CONST const float4 *)(FcT + k * H);   // FcT[k][i] = Fc[i][k], 16-byte aligned
#pragma unroll
            for (int i4 = 0; i4 < TH / 4; i4++) {
                const float4 f = __ldg(&f4[i4]);
                acc[4 * i4 + 0] = fmaf(f.x, x, acc[4 * i4 + 0]);
                acc[4 * i4 + 1] = fmaf(f.y, x, acc[4 * i4 + 1]);
                acc[4 * i4 + 2] = fmaf(f.z, x, acc[4 * i4 + 2]);
                acc[4 * i4 + 3] = fmaf(f.w, x, acc[4 * i4 + 3]);
            }
        }
#pragma unroll
        for (int i = 0; i < TH; i++) tmp[i * TS + j] = acc[i];
    }
}
template <int TW, int NT = 32>
__device__ __forceinline__ void fwd_row_pass(float *tmp, int W, int th, int rk, AV1G_CONST const float *Fr, AV1G_CONST const float *FrT,
                                             float scale, int lane) {
    const int TS = W + 1;
    for (int i = lane; i < th; i += NT) {
        float acc[TW];
#pragma unroll
        for (int jj = 0; jj < TW; jj++) acc[jj] = 0.f;
        if (rk == AV1G_K_IDT) {
#pragma unroll
            for (int jj = 0; jj < TW; jj++) acc[jj] = __ldg(&Fr[jj * W + jj]) * tmp[i * TS + jj];
        } else {
            for (int k = 0; k < W; k++) {
                const float x = tmp[i * TS + k];
                AV1G_CONST const float4 *f4 = (AV1G_CONST const float4 *)(FrT + k * W);   // FrT[k][jj] = Fr[jj][k]
#pragma unroll
                for (int j4 = 0; j4 < TW / 4; j4++) {
                    const float4 f = __ldg(&f4[j4]);
                    acc[4 * j4 + 0] = fmaf(f.x, x, acc[4 * j4 + 0]);
                    acc[4 * j4 + 1] = fmaf(f.y, x, acc[4 * j4 + 1]);
                    acc[4 * j4 + 2] = fmaf(f.z, x, acc[4 * j4 + 2]);
                    acc[4 * j4 + 3] = fmaf(f.w, x, acc[4 * j4 + 3]);
                }
            }
        }
#pragma unroll
        for (int jj = 0; jj < TW; jj++) tmp[i * TS + jj] = acc[jj] * scale;
    }
}

__device__ __forceinline__ int log2i(int v) { return 31 - __clz(v); }

template <int NT = 32>
__device__ __forceinline__ void warp_fwd_rt(const int16_t *res, float *tmp, int W, int H, int txSz, int txType, int lane) {
    const int th = H > 32 ? 32 : H, tw = W > 32 ? 32 : W;
    const int rk = av1g_row_kind(txType), ck = av1g_col_kind(txType);
    const int fud = av1g_flip_ud(txType), flr = av1g_flip_lr(txType);
    AV1G_CONST const float *Fc = g_fwd + g_fwdOff[ck][log2i(H)];
    AV1G_CONST const float *Fr = g_fwd + g_fwdOff[rk][log2i(W)];
    AV1G_CONST const float *FcT = g_fwdT + g_fwdOff[ck][log2i(H)];
    AV1G_CONST const float *FrT = g_fwdT + g_fwdOff[rk][log2i(W)];
    switch (th) {
    case 4: fwd_col_pass<4, NT>(res, tmp, W, H, ck, fud, flr, Fc, FcT, lane); break;
    case 8: fwd_col_pass<8, NT>(res, tmp, W, H, ck, fud, flr, Fc, FcT, lane); break;
    case 16: fwd_col_pass<16, NT>(res, tmp, W, H, ck, fud, flr, Fc, FcT, lane); break;
    default: fwd_col_pass<32, NT>(res, tmp, W, H, ck, fud, flr, Fc, FcT, lane); break;
    }
    ga_sync<NT>();
    const float scale = g_txScale[txSz];
    switch (tw) {
    case 4: fwd_row_pass<4, NT>(tmp, W, th, rk, Fr, FrT, scale, lane); break;
    case 8: fwd_row_pass<8, NT>(tmp, W, th, rk, Fr, FrT, scale, lane); break;
    case 16: fwd_row_pass<16, NT>(tmp, W, th, rk, Fr, FrT, scale, lane); break;
    default: fwd_row_pass<32, NT>(tmp, W, th, rk, Fr, FrT, scale, lane); break;
    }
    ga_sync<NT>();
}

// Quantize tmp -> q, return distortion / rate.  All lanes get the results.
template <int NT = 32>
__device__ __forceinline__ void warp_quant_rate_rt(const float *tmp, int16_t *q, thread const EvalIn &e, thread EvalOut &o, int W, int H,
                                                   int lane, float *red = nullptr, int *redi = nullptr) {
    const int th = H > 32 ? 32 : H, tw = W > 32 ? 32 : W, TS = W + 1, n = tw * th;
    const int lt = log2i(tw);
    const int den = av1g_dq_denom(e.txSz);
    float dist = 0.f, kept = 0.f;
    for (int idx = lane; idx < n; idx += NT) {
        const int i = idx >> lt, j = idx & (tw - 1);
        const float v = tmp[i * TS + j];
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
        kept = fmaf(v, v, kept);
    }
    dist = ga_sum<NT>(dist, lane, red);
    ga_sync<NT>();
    AV1G_CONST const uint16_t *scan = av1g_get_scan(e.txSz, e.txType);
    int last = 0;
    for (int c = lane; c < n; c += NT)
        if (q[scan[c]]) last = c + 1;
    const int eob = ga_max<NT>(last, lane, redi);
    float bits = lane == 0 ? base_bits(e, eob) : 0.f;
    if (eob > 0) {
        const int txClass = av1g_tx_class(e.txType);
        for (int c = lane; c < eob; c += NT) bits += coeff_bits(c, eob, q, scan, e.txSz, txClass, e.plane > 0, e.dcCtx, e.C);
    }
    bits = ga_sum<NT>(bits, lane, red);
    const float g = g_txg[e.txSz][e.txType];
    float D = g * dist;
    if (W == 64 || H == 64) {
        kept = ga_sum<NT>(kept, lane, red);
        D += fmaxf(0.f, e.resEnergy - g * kept);
    }
    o.D = D;
    o.R = bits;
    o.eob = eob;
}

template <int NT = 32>
__device__ __forceinline__ void warp_eval_rt(const int16_t *res, float *tmp, int16_t *q, thread const EvalIn &e, thread EvalOut &o,
                                             int W, int H, int lane, float *red = nullptr, int *redi = nullptr) {
    warp_fwd_rt<NT>(res, tmp, W, H, e.txSz, e.txType, lane);
    warp_quant_rate_rt<NT>(tmp, q, e, o, W, H, lane, red, redi);
}

// Glass Act: warp_fwd_rt at a compile-time size, its outputs spread over the lanes: where a pass
// has fewer columns (rows) than lanes, a lane takes part of one's outputs instead of all of them.
// Each output accumulates over k in the same order, so the same coefficients; the row pass reads
// a whole row of tmp before any lane writes into it. Only the rectangles and 64x64 (warp_eval):
// 16x16 and 32x32 measured slower so (BENCHMARKS, "the analysis's forward transform").
template <int W, int H, int NT>
__device__ __forceinline__ void warp_fwd_ct(const int16_t *res, float *tmp, int txSz, int txType, int lane) {
    constexpr int th = H > 32 ? 32 : H, tw = W > 32 ? 32 : W, TS = W + 1;
    constexpr int SC = NT >= 2 * W ? (NT / W < th / 4 ? NT / W : th / 4) : 1, CC = th / SC;  // column pass: parts a column
    constexpr int SR = NT / th < tw / 4 ? NT / th : tw / 4, CR = tw / SR;                    // row pass: parts a row
    const int rk = av1g_row_kind(txType), ck = av1g_col_kind(txType);
    const int fud = av1g_flip_ud(txType), flr = av1g_flip_lr(txType);
    AV1G_CONST const float *Fc = g_fwd + g_fwdOff[ck][log2i(H)];
    AV1G_CONST const float *Fr = g_fwd + g_fwdOff[rk][log2i(W)];
    AV1G_CONST const float *FcT = g_fwdT + g_fwdOff[ck][log2i(H)];
    AV1G_CONST const float *FrT = g_fwdT + g_fwdOff[rk][log2i(W)];
    for (int t = lane; t < W * SC; t += NT) {
        const int j = t % W, i0 = (t / W) * CC;
        const int jj = flr ? W - 1 - j : j;
        if (ck == AV1G_K_IDT) {
#pragma unroll
            for (int i = i0; i < i0 + CC; i++) tmp[i * TS + j] = __ldg(&Fc[i * H + i]) * (float)res[(fud ? H - 1 - i : i) * W + jj];
            continue;
        }
        float acc[CC];
#pragma unroll
        for (int i = 0; i < CC; i++) acc[i] = 0.f;
        for (int k = 0; k < H; k++) {
            const float x = (float)res[(fud ? H - 1 - k : k) * W + jj];
            AV1G_CONST const float4 *f4 = (AV1G_CONST const float4 *)(FcT + k * H + i0);
#pragma unroll
            for (int i4 = 0; i4 < CC / 4; i4++) {
                const float4 f = __ldg(&f4[i4]);
                acc[4 * i4 + 0] = fmaf(f.x, x, acc[4 * i4 + 0]);
                acc[4 * i4 + 1] = fmaf(f.y, x, acc[4 * i4 + 1]);
                acc[4 * i4 + 2] = fmaf(f.z, x, acc[4 * i4 + 2]);
                acc[4 * i4 + 3] = fmaf(f.w, x, acc[4 * i4 + 3]);
            }
        }
#pragma unroll
        for (int i = 0; i < CC; i++) tmp[(i0 + i) * TS + j] = acc[i];
    }
    ga_sync<NT>();
    const float scale = g_txScale[txSz];
    // (th * SR <= NT: one item a lane at most, so every lane reaches the barrier once)
    const bool on = lane < th * SR;
    const int i = lane % th, j0 = (lane / th) * CR;
    float acc[CR];
#pragma unroll
    for (int jj = 0; jj < CR; jj++) acc[jj] = 0.f;
    if (on) {
        if (rk == AV1G_K_IDT) {
#pragma unroll
            for (int jj = 0; jj < CR; jj++) acc[jj] = __ldg(&Fr[(j0 + jj) * W + j0 + jj]) * tmp[i * TS + j0 + jj];
        } else {
            for (int k = 0; k < W; k++) {
                const float x = tmp[i * TS + k];
                AV1G_CONST const float4 *f4 = (AV1G_CONST const float4 *)(FrT + k * W + j0);
#pragma unroll
                for (int j4 = 0; j4 < CR / 4; j4++) {
                    const float4 f = __ldg(&f4[j4]);
                    acc[4 * j4 + 0] = fmaf(f.x, x, acc[4 * j4 + 0]);
                    acc[4 * j4 + 1] = fmaf(f.y, x, acc[4 * j4 + 1]);
                    acc[4 * j4 + 2] = fmaf(f.z, x, acc[4 * j4 + 2]);
                    acc[4 * j4 + 3] = fmaf(f.w, x, acc[4 * j4 + 3]);
                }
            }
        }
    }
    ga_sync<NT>();
    if (on) {
#pragma unroll
        for (int jj = 0; jj < CR; jj++) tmp[i * TS + j0 + jj] = acc[jj] * scale;
    }
    ga_sync<NT>();
}

// Glass Act: the square DCT_DCT forward transform (16, 32, 64 points) on the SIMD-group matrix
// units, the same coefficients as fwd_col_pass / fwd_row_pass: each output there is a sequential
// fma over k from 0, and simdgroup_multiply_accumulate chained over the 8-blocks of k in order
// gives exactly that (a probe on M4 Pro: 2,097,152 of 2,097,152 outputs bit-identical, with integer
// and with float right-hand sides; a sum of the 8-blocks' fma chains matched 18 %, unfused
// products 35 %). The specification leaves the order open, so this rests on that probe and on
// the streams' digests, and the host checks each size at start-up (k_fwd_mma_check). F is the DCT
// matrix's first th rows (th x W, stride W), in device memory (k_fwd_matrices; simdgroup_load reads
// no constant address space) or threadgroup memory; the residual goes through tmp as floats, th
// rows at a time (all of it below 64 points). k_analysis takes it for 32x32 only
// (BENCHMARKS, "the analysis's forward DCT on the matrix units"). Where the compiler has no
// SIMD-group matrices (AMD and Intel GPUs), the old passes.
#if defined(__HAVE_SIMDGROUP_MATRIX__)
#define GA_FWD_MMA 1
template <int W, int NT, typename FPtr>
__device__ __forceinline__ void warp_fwd_mma(const threadgroup int16_t *res, threadgroup float *tmp, FPtr F,
                                             float scale, int lane) {
    constexpr int th = W > 32 ? 32 : W, TS = W + 1, NS = NT / 32;
    constexpr int RT = th / 8, CT = W / 8;               // output tiles of the column pass: RT x CT
    // a SIMD-group's tiles (column pass, row pass); (at least 1 so that the unused shapes compile)
    constexpr int T1 = RT * CT / NS > 0 ? RT * CT / NS : 1, T2 = RT * RT / NS > 0 ? RT * RT / NS : 1;
    const int sg = lane / 32;
    simdgroup_float8x8 acc[T1];
#pragma unroll
    for (int u = 0; u < T1; u++) acc[u] = simdgroup_float8x8(0.f);
    // column pass: tmp(th x W) = F(th x W) * R(W x W), over chunks of th rows of R
    for (int c0 = 0; c0 < W; c0 += th) {
        if (c0 > 0) ga_sync<NT>();  // (the previous chunk read)
        for (int p = lane; p < th * W; p += NT) tmp[(p / W) * TS + p % W] = (float)res[(c0 + p / W) * W + p % W];
        ga_sync<NT>();
#pragma unroll
        for (int u = 0; u < T1; u++) {
            const int t = sg * T1 + u, ti = t / CT, tj = t % CT;
            for (int kb = 0; kb < th; kb += 8) {
                simdgroup_float8x8 a, b;
                simdgroup_load(a, F, W, ulong2(c0 + kb, ti * 8));
                simdgroup_load(b, tmp, TS, ulong2(tj * 8, kb));
                simdgroup_multiply_accumulate(acc[u], a, b, acc[u]);
            }
        }
    }
    ga_sync<NT>();
#pragma unroll
    for (int u = 0; u < T1; u++) {
        const int t = sg * T1 + u;
        simdgroup_store(acc[u], tmp, TS, ulong2((t % CT) * 8, (t / CT) * 8));
    }
    ga_sync<NT>();
    // row pass: out(th x th) = tmp(th x W) * F^T(W x th)
    simdgroup_float8x8 o[T2];
#pragma unroll
    for (int u = 0; u < T2; u++) {
        o[u] = simdgroup_float8x8(0.f);
        const int t = sg * T2 + u, ti = t / RT, tj = t % RT;
        for (int kb = 0; kb < W; kb += 8) {
            simdgroup_float8x8 a, b;
            simdgroup_load(a, tmp, TS, ulong2(kb, ti * 8));
            simdgroup_load(b, F, W, ulong2(kb, tj * 8), true);
            simdgroup_multiply_accumulate(o[u], a, b, o[u]);
        }
    }
    ga_sync<NT>();
#pragma unroll
    for (int u = 0; u < T2; u++) {
        const int t = sg * T2 + u;
        simdgroup_store(o[u], tmp, TS, ulong2((t % RT) * 8, (t / RT) * 8));
    }
    ga_sync<NT>();
    for (int p = lane; p < th * th; p += NT) tmp[(p / th) * TS + p % th] *= scale;
    ga_sync<NT>();
}
#endif

// Glass Act: the forward DCT matrices warp_fwd_mma reads (16, 32 and 64 points, n x n row-major as
// in g_fwd), copied into a device buffer once an encoder (k_fwd_matrices): simdgroup_load reads
// device and threadgroup memory but not constant, and a threadgroup copy a block took threadgroup
// memory (4 KB at 32x32) from every threadgroup of the shape.
#define GA_FWD_MATRIX_FLOATS (256 + 1024 + 4096)
static inline int ga_fwd_matrix_offset(int lw) { return lw == 4 ? 0 : lw == 5 ? 256 : 1280; }

// compile-time-size wrapper (analysis kernels): constants propagate through the inlined runtime code
template <int W, int H, int NT = 32>
__device__ __forceinline__ void warp_eval(const int16_t *res, float *tmp, int16_t *q, thread const EvalIn &e, thread EvalOut &o,
                                          int lane, float *red = nullptr, int *redi = nullptr) {
    if (W != H || W == 64) {
        warp_fwd_ct<W, H, NT>(res, tmp, e.txSz, e.txType, lane);
        warp_quant_rate_rt<NT>(tmp, q, e, o, W, H, lane, red, redi);
    } else {
        warp_eval_rt<NT>(res, tmp, q, e, o, W, H, lane, red, redi);
    }
}

// Runtime dispatch over the 19 transform sizes (closed loop).
#define GP_TX_SWITCH(txSz, MACRO)                       \
    switch (txSz) {                                     \
    case AV1G_TX_4X4: MACRO(4, 4); break;               \
    case AV1G_TX_8X8: MACRO(8, 8); break;               \
    case AV1G_TX_16X16: MACRO(16, 16); break;           \
    case AV1G_TX_32X32: MACRO(32, 32); break;           \
    case AV1G_TX_64X64: MACRO(64, 64); break;           \
    case AV1G_TX_4X8: MACRO(4, 8); break;               \
    case AV1G_TX_8X4: MACRO(8, 4); break;               \
    case AV1G_TX_8X16: MACRO(8, 16); break;             \
    case AV1G_TX_16X8: MACRO(16, 8); break;             \
    case AV1G_TX_16X32: MACRO(16, 32); break;           \
    case AV1G_TX_32X16: MACRO(32, 16); break;           \
    case AV1G_TX_32X64: MACRO(32, 64); break;           \
    case AV1G_TX_64X32: MACRO(64, 32); break;           \
    case AV1G_TX_4X16: MACRO(4, 16); break;             \
    case AV1G_TX_16X4: MACRO(16, 4); break;             \
    case AV1G_TX_8X32: MACRO(8, 32); break;             \
    case AV1G_TX_32X8: MACRO(32, 8); break;             \
    case AV1G_TX_16X64: MACRO(16, 64); break;           \
    default: MACRO(64, 16); break;                      \
    }
