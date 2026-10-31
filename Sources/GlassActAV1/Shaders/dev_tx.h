// Glass Act: av1gpu's encoder/src/dev_tx.cuh (BSD-2, Sources/AV1Core/LICENSE), for Metal: the
// lane is a parameter (CUDA's threadIdx is a global; Metal's thread indices are kernel
// arguments), pointers into tables say AV1G_CONST, and the transposed forward matrices are
// read as float4 from the generated, 16-byte aligned g_fwdT.
// warp-level "evaluate one transform block": float forward transform, dead-zone
// quantization (incl. quantizer matrices), exact coefficient rate from the AV1 default CDFs (all
// in-block contexts computed in parallel), transform-domain distortion.
#pragma once
#include "dev_common.h"

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
template <int TH>
__device__ __forceinline__ void fwd_col_pass(const int16_t *res, float *tmp, int W, int H, int ck, int fud, int flr,
                                             AV1G_CONST const float *Fc, AV1G_CONST const float *FcT, int lane) {
    const int TS = W + 1;
    for (int j = lane; j < W; j += 32) {
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
template <int TW>
__device__ __forceinline__ void fwd_row_pass(float *tmp, int W, int th, int rk, AV1G_CONST const float *Fr, AV1G_CONST const float *FrT,
                                             float scale, int lane) {
    const int TS = W + 1;
    for (int i = lane; i < th; i += 32) {
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

__device__ __forceinline__ void warp_fwd_rt(const int16_t *res, float *tmp, int W, int H, int txSz, int txType, int lane) {
    const int th = H > 32 ? 32 : H, tw = W > 32 ? 32 : W;
    const int rk = av1g_row_kind(txType), ck = av1g_col_kind(txType);
    const int fud = av1g_flip_ud(txType), flr = av1g_flip_lr(txType);
    AV1G_CONST const float *Fc = g_fwd + g_fwdOff[ck][log2i(H)];
    AV1G_CONST const float *Fr = g_fwd + g_fwdOff[rk][log2i(W)];
    AV1G_CONST const float *FcT = g_fwdT + g_fwdOff[ck][log2i(H)];
    AV1G_CONST const float *FrT = g_fwdT + g_fwdOff[rk][log2i(W)];
    switch (th) {
    case 4: fwd_col_pass<4>(res, tmp, W, H, ck, fud, flr, Fc, FcT, lane); break;
    case 8: fwd_col_pass<8>(res, tmp, W, H, ck, fud, flr, Fc, FcT, lane); break;
    case 16: fwd_col_pass<16>(res, tmp, W, H, ck, fud, flr, Fc, FcT, lane); break;
    default: fwd_col_pass<32>(res, tmp, W, H, ck, fud, flr, Fc, FcT, lane); break;
    }
    __syncwarp();
    const float scale = g_txScale[txSz];
    switch (tw) {
    case 4: fwd_row_pass<4>(tmp, W, th, rk, Fr, FrT, scale, lane); break;
    case 8: fwd_row_pass<8>(tmp, W, th, rk, Fr, FrT, scale, lane); break;
    case 16: fwd_row_pass<16>(tmp, W, th, rk, Fr, FrT, scale, lane); break;
    default: fwd_row_pass<32>(tmp, W, th, rk, Fr, FrT, scale, lane); break;
    }
    __syncwarp();
}

// Quantize tmp -> q, return distortion / rate.  All lanes get the results.
__device__ __forceinline__ void warp_quant_rate_rt(const float *tmp, int16_t *q, thread const EvalIn &e, thread EvalOut &o, int W, int H,
                                                   int lane) {
    const int th = H > 32 ? 32 : H, tw = W > 32 ? 32 : W, TS = W + 1, n = tw * th;
    const int lt = log2i(tw);
    const int den = av1g_dq_denom(e.txSz);
    float dist = 0.f, kept = 0.f;
    for (int idx = lane; idx < n; idx += 32) {
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
    dist = warp_sum(dist);
    __syncwarp();
    AV1G_CONST const uint16_t *scan = av1g_get_scan(e.txSz, e.txType);
    int last = 0;
    for (int c = lane; c < n; c += 32)
        if (q[scan[c]]) last = c + 1;
    const int eob = warp_max(last);
    float bits = lane == 0 ? base_bits(e, eob) : 0.f;
    if (eob > 0) {
        const int txClass = av1g_tx_class(e.txType);
        for (int c = lane; c < eob; c += 32) bits += coeff_bits(c, eob, q, scan, e.txSz, txClass, e.plane > 0, e.dcCtx, e.C);
    }
    bits = warp_sum(bits);
    const float g = g_txg[e.txSz][e.txType];
    float D = g * dist;
    if (W == 64 || H == 64) {
        kept = warp_sum(kept);
        D += fmaxf(0.f, e.resEnergy - g * kept);
    }
    o.D = D;
    o.R = bits;
    o.eob = eob;
}

__device__ __forceinline__ void warp_eval_rt(const int16_t *res, float *tmp, int16_t *q, thread const EvalIn &e, thread EvalOut &o,
                                             int W, int H, int lane) {
    warp_fwd_rt(res, tmp, W, H, e.txSz, e.txType, lane);
    warp_quant_rate_rt(tmp, q, e, o, W, H, lane);
}

// compile-time-size wrapper (analysis kernels): constants propagate through the inlined runtime code
template <int W, int H>
__device__ __forceinline__ void warp_eval(const int16_t *res, float *tmp, int16_t *q, thread const EvalIn &e, thread EvalOut &o,
                                          int lane) {
    warp_eval_rt(res, tmp, q, e, o, W, H, lane);
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
