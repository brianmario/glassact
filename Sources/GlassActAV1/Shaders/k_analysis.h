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

// Glass Act: the analysis at the hybrid encoder's settings (AV1MetalEncoder.fixedAnalysis): one
// candidate (K 1), no tx-type search, no intra edge filter, no quantizer matrices, no external
// screener. A function constant, so that those pipelines are compiled without the general code
// (the kernels are register-bound: BENCHMARKS); the others leave it undefined, which is false. The
// host takes the fixed pipelines only where the settings are those, so the results are the same.
constant bool ga_fixed_fc [[function_constant(0)]];
constant bool ga_fixed = is_function_constant_defined(ga_fixed_fc) && ga_fixed_fc;
// Glass Act: the 16x16, 32x32 and 64x64 forward DCTs on the matrix units (warp_fwd_mma), only where
// the host's start-up check found them all bit-identical to the passes they replace on this GPU
// (AV1MetalEncoder.forwardMMAIsExact, k_fwd_mma_check); undefined is false.
constant bool ga_mma_fc [[function_constant(1)]];
constant bool ga_mma = is_function_constant_defined(ga_mma_fc) && ga_mma_fc;

// Glass Act: a block's scratch, no more than its shape uses (threadgroup memory limits how many
// threadgroups a core holds):
// - the edges as long as the shape reads them (k_analysis_small's EL: the edge filter's upsampling
//   included), not the 64x64's;
// - shapes with a side of 32 or 64 have DCT_DCT only (av1g_get_tx_set_intra), so no tx-type
//   search re-reads the residual after its transform: their quantized levels go over it (`qOf`);
// - the edge filter's prepared edges are made before a residual and read only while it's made, so
//   where the transform's tmp holds both they live there (`paOf`, `plOf`).
template <int W, int H>
struct ASmem {
    static constexpr constant int EL = AV1G_EDGE_OFF + 2 * (W + H) + 8 < AV1G_EDGE_LEN ? AV1G_EDGE_OFF + 2 * (W + H) + 8 : AV1G_EDGE_LEN;
    static constexpr constant bool qInRes = W >= 32 || H >= 32;
    static constexpr constant bool edgesInTmp = (int)(TxD<W, H>::th * TxD<W, H>::TS * sizeof(float)) >= 2 * EL;
    int16_t res[W * H];
    float tmp[TxD<W, H>::th * TxD<W, H>::TS];
    int16_t q[qInRes ? 1 : TxD<W, H>::n];
    uint8_t ea[EL], el[EL];
    uint8_t pa[edgesInTmp ? 1 : EL], pl[edgesInTmp ? 1 : EL];   // edge-filter prepared edges (RD stage)
    int up[2];
    float satd[32];
    int cand[32];
    int dcv;
    float red[8];  // ga_sum / ga_max across a block's SIMD-groups (NT > 32)
    int redi[8];
};

template <int W, int H>
static inline threadgroup int16_t *qOf(threadgroup ASmem<W, H> &S) { return ASmem<W, H>::qInRes ? S.res : S.q; }
template <int W, int H>
static inline threadgroup uint8_t *paOf(threadgroup ASmem<W, H> &S) { return ASmem<W, H>::edgesInTmp ? (threadgroup uint8_t *)S.tmp : S.pa; }
template <int W, int H>
static inline threadgroup uint8_t *plOf(threadgroup ASmem<W, H> &S) {
    return ASmem<W, H>::edgesInTmp ? (threadgroup uint8_t *)S.tmp + ASmem<W, H>::EL : S.pl;
}

// Glass Act: the sum of absolute coefficients, a whole number (hadamard4_abs: a quarter of it)
__device__ __forceinline__ int hadamard4_sum(int *d) {
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
    return sum;
}
__device__ __forceinline__ float hadamard4_abs(int *d) { return (float)hadamard4_sum(d) * 0.25f; }

__device__ __forceinline__ int pangle_of(int mode, int delta) {
    return av1g_is_directional(mode) ? AV1G_T(Mode_To_Angle)[mode] + delta * AV1G_ANGLE_STEP : 0;
}

// prediction of pixel (i, j) for candidate c, edges A/L, dc value dcv
__device__ __forceinline__ int pred_px(int c, int i, int j, int lw, int lh, const uint8_t *A, const uint8_t *L, int dcv) {
    const int m = cand_mode(c);
    if (m == AV1G_DC_PRED) return dcv;
    return av1g_pred_pixel(m, pangle_of(m, cand_delta(c)), i, j, lw, lh, A, L);
}

// Glass Act: pred_px with the per-candidate work hoisted. av1g_pred_pixel derives the angle's zone
// and derivatives for every pixel. Screening predicts each candidate over a whole block, so they are
// derived once here, and a pixel costs a few integer ops. Identical to pred_px (edges unfiltered,
// not upsampled).
struct PredCand {
    int mode, zone, dx, dy, w, h;  // zone: 0 DC, 1 <90, 2 90..180, 3 >180, 4 90, 5 180, 6 non-directional
    AV1G_CONST const uint8_t *wx, *wy;
};
__device__ __forceinline__ PredCand pred_cand(int c, int lw, int lh) {
    PredCand p;
    p.mode = cand_mode(c);
    p.w = 1 << lw; p.h = 1 << lh;
    p.dx = 0; p.dy = 0;
    p.wx = av1g_sm_weights(lw); p.wy = av1g_sm_weights(lh);
    if (p.mode == AV1G_DC_PRED) { p.zone = 0; return p; }
    if (!av1g_is_directional(p.mode)) { p.zone = 6; return p; }
    const int a = pangle_of(p.mode, cand_delta(c));
    if (a == 90) p.zone = 4;
    else if (a == 180) p.zone = 5;
    else if (a < 90) { p.zone = 1; p.dx = AV1G_T(Dr_Intra_Derivative)[a]; }
    else if (a < 180) { p.zone = 2; p.dx = AV1G_T(Dr_Intra_Derivative)[180 - a]; p.dy = AV1G_T(Dr_Intra_Derivative)[a - 90]; }
    else { p.zone = 3; p.dy = AV1G_T(Dr_Intra_Derivative)[270 - a]; }
    return p;
}
__device__ __forceinline__ int pred_fast(thread const PredCand &p, int i, int j, const uint8_t *A, const uint8_t *L, int dcv) {
    switch (p.zone) {
    case 0: return dcv;
    case 4: return A[j];
    case 5: return L[i];
    case 1: {
        const int idx = (i + 1) * p.dx, base = (idx >> 6) + j, shift = (idx >> 1) & 0x1F, maxBase = p.w + p.h - 1;
        return base < maxBase ? (A[base] * (32 - shift) + A[base + 1] * shift + 16) >> 5 : A[maxBase];
    }
    case 2: {
        int idx = (j << 6) - (i + 1) * p.dx, base = idx >> 6;
        if (base >= -1) {
            const int shift = (idx >> 1) & 0x1F;
            return (A[base] * (32 - shift) + A[base + 1] * shift + 16) >> 5;
        }
        idx = (i << 6) - (j + 1) * p.dy; base = idx >> 6;
        const int shift = (idx >> 1) & 0x1F;
        return (L[base] * (32 - shift) + L[base + 1] * shift + 16) >> 5;
    }
    case 3: {
        const int idx = (j + 1) * p.dy, base = (idx >> 6) + i, shift = (idx >> 1) & 0x1F;
        return (L[base] * (32 - shift) + L[base + 1] * shift + 16) >> 5;
    }
    default: break;
    }
    if (p.mode == AV1G_SMOOTH_PRED)
        return (p.wy[i] * A[j] + (256 - p.wy[i]) * L[p.h - 1] + p.wx[j] * L[i] + (256 - p.wx[j]) * A[p.w - 1] + 256) >> 9;
    if (p.mode == AV1G_SMOOTH_V_PRED) return (p.wy[i] * A[j] + (256 - p.wy[i]) * L[p.h - 1] + 128) >> 8;
    if (p.mode == AV1G_SMOOTH_H_PRED) return (p.wx[j] * L[i] + (256 - p.wx[j]) * A[p.w - 1] + 128) >> 8;
    const int base = A[j] + L[i] - A[-1];  // PAETH
    const int pL = abs(base - L[i]), pT = abs(base - A[j]), pTL = abs(base - A[-1]);
    return (pL <= pT && pL <= pTL) ? L[i] : pT <= pTL ? A[j] : A[-1];
}

// pred_cand of mode m at delta 0, from literals (Mode_To_Angle, Dr_Intra_Derivative), so that a
// constant m leaves a constant
__device__ __forceinline__ PredCand pred_cand0(int m, int lw, int lh) {
    PredCand p;
    p.mode = m;
    p.w = 1 << lw; p.h = 1 << lh;
    p.dx = 0; p.dy = 0;
    p.wx = av1g_sm_weights(lw); p.wy = av1g_sm_weights(lh);
    switch (m) {
    case AV1G_DC_PRED: p.zone = 0; break;
    case AV1G_V_PRED: p.zone = 4; break;
    case AV1G_H_PRED: p.zone = 5; break;
    case AV1G_D45_PRED: p.zone = 1; p.dx = 64; break;
    case AV1G_D67_PRED: p.zone = 1; p.dx = 27; break;
    case AV1G_D113_PRED: p.zone = 2; p.dx = 27; p.dy = 151; break;
    case AV1G_D135_PRED: p.zone = 2; p.dx = 64; p.dy = 64; break;
    case AV1G_D157_PRED: p.zone = 2; p.dx = 151; p.dy = 27; break;
    case AV1G_D203_PRED: p.zone = 3; p.dy = 27; break;
    default: p.zone = 6; break;
    }
    return p;
}

// SATD of candidates cands[c0..c1) (all 4x4 sub-blocks), accumulated into satd[]
template <int W, int H, int NT = 32>
__device__ __forceinline__ void warp_screen(const uint8_t *src, int sp, const int *cands, int c0, int c1, threadgroup float *satd,
                                            const uint8_t *A, const uint8_t *L, int dcv, int lane, int sub = 1) {
    typedef TxD<W, H> T;
    constexpr int nsx = W / 4, nsub0 = (W / 4) * (H / 4);
    // sub == 2: checkerboard of 4x4 sub-blocks (nsx is even for every shape >= 256 pixels)
    const int nsub = sub == 2 ? nsub0 / 2 : nsub0;
    // (32 4x4s, a SIMD-group's lanes, take the loop below a lane a 4x4: one candidate a SIMD-group
    // too, without the shuffles; 32x32 at screenSub 2: 2.55 -> 2.47 ms. 64x64's 128 were slower so)
    if (nsub >= 8 && nsub != 32) {
        // Glass Act: four lanes a 4x4, a row each (its prediction, then the Hadamard's row pass;
        // the column pass across the four by shuffles), so a SIMD-group takes one candidate at a
        // time: no divergence between candidates' predictions. Integer transforms, then quarters
        // summed exactly: the same SATDs as below.
        const int per = nsub * 4, items4 = (c1 - c0) * per;
        for (int base = 0; base < items4; base += NT) {
            const int it = base + lane;
            const bool on = it < items4;
            const int ci = c0 + it / per, k = it % per, i = k & 3;
            int sb = k >> 2;
            if (sub == 2) { const int r = (2 * sb) / nsx; sb = 2 * sb + (r & 1); }
            const int sx = (sb % nsx) * 4, sy = (sb / nsx) * 4;
            int r0 = 0, r1 = 0, r2 = 0, r3 = 0;
            if (on) {
                const PredCand pc = pred_cand(cands[ci], T::lw, T::lh);
                const uint8_t *s = src + (sy + i) * sp + sx;
                const int d0 = (int)s[0] - pred_fast(pc, sy + i, sx, A, L, dcv);
                const int d1 = (int)s[1] - pred_fast(pc, sy + i, sx + 1, A, L, dcv);
                const int d2 = (int)s[2] - pred_fast(pc, sy + i, sx + 2, A, L, dcv);
                const int d3 = (int)s[3] - pred_fast(pc, sy + i, sx + 3, A, L, dcv);
                const int s0 = d0 + d1, s1 = d0 - d1, s2 = d2 + d3, s3 = d2 - d3;
                r0 = s0 + s2; r1 = s1 + s3; r2 = s0 - s2; r3 = s1 - s3;
            }
            // columns: rows (0, 1) and (2, 3) into sums and differences, then those across pairs;
            // row i keeps output i of each column
            int a = 0;
            const int rr[4] = {r0, r1, r2, r3};
#pragma unroll
            for (int j = 0; j < 4; j++) {
                const int v = rr[j], b = simd_shuffle_xor(v, (ushort)1);
                const int plus = v + b, minus = (i & 1) ? b - v : v - b;
                const int pp = simd_shuffle_xor(plus, (ushort)2), pm = simd_shuffle_xor(minus, (ushort)2);
                a += abs(i == 0 ? plus + pp : i == 1 ? minus + pm : i == 2 ? pp - plus : pm - minus);
            }
            const float v = simd_sum(on ? (float)a * 0.25f : 0.f);
            if (on && (lane & 31) == 0)
                atomic_fetch_add_explicit((threadgroup atomic_float *)&satd[ci], v, memory_order_relaxed);
        }
        ga_sync<NT>();
        return;
    }
    const int items = (c1 - c0) * nsub;
    // Glass Act: a candidate's items are nsub (a power of two) consecutive ones, so aligned groups
    // of g lanes of a SIMD-group share one: they sum in registers, and one lane a group adds to
    // satd (instead of every lane, which serialized on one address). Each SATD is a multiple of
    // 0.25 and a candidate's total stays below 2^22, so every order sums exactly: the same totals.
    const int g = min(nsub, 32), sl = lane & 31;
    for (int base = 0; base < items; base += NT) {
        const int it = base + lane;
        const int ci = c0 + it / nsub;
        float v = 0.f;
        if (it < items) {
            int sb = it % nsub;
            if (sub == 2) { const int r = (2 * sb) / nsx; sb = 2 * sb + (r & 1); }
            const int sx = (sb % nsx) * 4, sy = (sb / nsx) * 4;
            const PredCand pc = pred_cand(cands[ci], T::lw, T::lh);
            int d[16];
#pragma unroll
            for (int i = 0; i < 4; i++)
#pragma unroll
                for (int j = 0; j < 4; j++)
                    d[i * 4 + j] = (int)src[(sy + i) * sp + sx + j] - pred_fast(pc, sy + i, sx + j, A, L, dcv);
            v = hadamard4_abs(d);
        }
        for (int off = g >> 1; off > 0; off >>= 1) v += simd_shuffle_down(v, (ushort)off);
        if (it < items && (sl & (g - 1)) == 0)
            atomic_fetch_add_explicit((threadgroup atomic_float *)&satd[ci], v, memory_order_relaxed);
    }
    ga_sync<NT>();
}

// Glass Act: the 4-point Walsh-Hadamard of hadamard4_abs's passes (rows, then columns): outputs
// (s0 + s2, s1 + s3, s0 - s2, s1 - s3) of s0 = x0 + x1, s1 = x0 - x1, s2 = x2 + x3, s3 = x2 - x3
static inline int4 ga_wh4(int x0, int x1, int x2, int x3) {
    const int s0 = x0 + x1, s1 = x0 - x1, s2 = x2 + x3, s3 = x2 - x3;
    return int4(s0 + s2, s1 + s3, s0 - s2, s1 - s3);
}
// Glass Act: a lane's row of a 4x4 (four lanes, rows 0..3, aligned), its row pass `r` done: the
// column pass across the four by shuffles, as warp_screen's, returning row i of the 4x4's
// coefficients (column j in component j), signs and all
static inline int4 ga_col4(int4 r, int i) {
    int4 o;
#pragma unroll
    for (int j = 0; j < 4; j++) {
        const int v = r[j], b = simd_shuffle_xor(v, (ushort)1);
        const int plus = v + b, minus = (i & 1) ? b - v : v - b;
        const int pp = simd_shuffle_xor(plus, (ushort)2), pm = simd_shuffle_xor(minus, (ushort)2);
        o[j] = i == 0 ? plus + pp : i == 1 ? minus + pm : i == 2 ? pp - plus : pm - minus;
    }
    return o;
}
static inline int ga_abs4(int4 v) { return abs(v.x) + abs(v.y) + abs(v.z) + abs(v.w); }

// Glass Act: warp_screen of the modes at delta 0 that the mask `mm` leaves (packed in mode order in
// satd, as k_analysis lists them), each mode compiled for itself (pred_cand0 of a constant), and DC,
// V and H in the transform domain. The Hadamard is linear and in integers, so H(src - pred) =
// H(src) - H(pred) exactly, and those three predictors' transforms are a few coefficients: DC's
// 16 dcv at (0, 0); V's rows all A[sx..sx+3], so 4 wh4(A) in row 0; H's columns all L[sy..sy+3],
// so 4 wh4(L) in column 0. One pass over the source's transforms makes all three SATDs, the same
// integers. Each SATD is a multiple of 0.25 below 2^22 and its quarter-integers sum exactly in any
// order (warp_screen), so a lane's whole-number partials, summed over a SIMD-group and added once
// a SIMD-group, give the same totals. Shapes with fewer than 32 items a mode keep warp_screen.
template <int W, int H, int NT>
__device__ __forceinline__ void warp_screen_modes(const uint8_t *src, int sp, uint mm, threadgroup float *satd, const uint8_t *A,
                                                  const uint8_t *L, int dcv, int tsc, int sub, const int *cands) {
    typedef TxD<W, H> T;
    constexpr int nsx = W / 4, nsub0 = (W / 4) * (H / 4);
    const int nsub = sub == 2 ? nsub0 / 2 : nsub0;
    const bool rows4 = nsub >= 8 && nsub != 32;  // four lanes a 4x4 (warp_screen's choice)
    const int per = rows4 ? nsub * 4 : nsub;     // items a mode: a power of two
    if (per < 32) {
        warp_screen<W, H, NT>(src, sp, cands, 0, (int)popcount(mm), satd, A, L, dcv, tsc, sub);
        return;
    }
    // a mode's items on all NT threads (per >= NT), or on aligned groups of per threads, the modes
    // dealt out to them in turn (per < NT: whole SIMD-groups, as per >= 32)
    const int lp = (int)ctz((uint)per);
    const int G = per >= NT ? 1 : NT >> lp, grp = G == 1 ? 0 : tsc >> lp;
    const int k0 = G == 1 ? tsc : tsc & (per - 1), nit = G == 1 ? per / NT : 1;
    // this thread's items: their 4x4s and, a lane a row, its row; the source read once for all modes
    // (at most MIT items a thread: the rows of 64x64 on 256, 32x32 on 128, 16x16 on 32 are 4, 2, 2;
    // the shapes with more, 16x64 to 64x32 on a SIMD-group, keep warp_screen)
    constexpr int MIT = (W * H) / (4 * NT) < 1 ? 1 : (W * H) / (4 * NT);
    if (MIT > 4) {
        warp_screen<W, H, NT>(src, sp, cands, 0, (int)popcount(mm), satd, A, L, dcv, tsc, sub);
        return;
    }
    int sxs[MIT], sys[MIT];
    uint sv[MIT][4];
    const int i = k0 & 3;
#pragma unroll
    for (int it = 0; it < MIT; it++) {
        sxs[it] = 0; sys[it] = 0;
        sv[it][0] = sv[it][1] = sv[it][2] = sv[it][3] = 0;
        if (it >= nit) continue;
        const int k = k0 + it * NT;
        int sb = rows4 ? k >> 2 : k;
        if (sub == 2) { const int r = (2 * sb) / nsx; sb = 2 * sb + (r & 1); }
        sxs[it] = (sb % nsx) * 4; sys[it] = (sb / nsx) * 4;
        const uint8_t *s = src + sys[it] * sp + sxs[it];
        if (rows4) {
            s += i * sp;
            sv[it][0] = (uint)s[0] | (uint)s[1] << 8 | (uint)s[2] << 16 | (uint)s[3] << 24;
        } else {
#pragma unroll
            for (int r = 0; r < 4; r++) sv[it][r] = (uint)s[r * sp] | (uint)s[r * sp + 1] << 8 | (uint)s[r * sp + 2] << 16 | (uint)s[r * sp + 3] << 24;
        }
    }
    auto px = [&](uint v, int j) -> int { return (int)((v >> (8 * j)) & 0xFFu); };
    // a SIMD-group's whole-number partial into a candidate's SATD
    auto add = [&](int slot, int a) {
        const int v = simd_sum(a);
        if ((tsc & 31) == 0) atomic_fetch_add_explicit((threadgroup atomic_float *)&satd[slot], (float)v * 0.25f, memory_order_relaxed);
    };
    int job = 0;
    // DC, V and H from the source's transforms
    if (mm & 7u) {
        if (job % G == grp) {
            int aDC = 0, aV = 0, aH = 0;
#pragma unroll
            for (int it = 0; it < MIT; it++) {
                if (it >= nit) continue;
                const int sx = sxs[it], sy = sys[it];
                const int4 ra = ga_wh4(A[sx], A[sx + 1], A[sx + 2], A[sx + 3]) * 4;
                const int4 rl = ga_wh4(L[sy], L[sy + 1], L[sy + 2], L[sy + 3]) * 4;
                if (rows4) {
                    const uint v = sv[it][0];
                    const int4 c = ga_col4(ga_wh4(px(v, 0), px(v, 1), px(v, 2), px(v, 3)), i);
                    const int tot = ga_abs4(c);
                    aDC += i == 0 ? tot - abs(c.x) + abs(c.x - 16 * dcv) : tot;
                    aV += i == 0 ? ga_abs4(c - ra) : tot;
                    aH += tot - abs(c.x) + abs(c.x - rl[i]);
                } else {
                    int4 rr[4];
#pragma unroll
                    for (int r = 0; r < 4; r++) { const uint v = sv[it][r]; rr[r] = ga_wh4(px(v, 0), px(v, 1), px(v, 2), px(v, 3)); }
                    int4 c[4];  // c[i][j]: row i, column j
#pragma unroll
                    for (int j = 0; j < 4; j++) {
                        const int4 o = ga_wh4(rr[0][j], rr[1][j], rr[2][j], rr[3][j]);
                        c[0][j] = o.x; c[1][j] = o.y; c[2][j] = o.z; c[3][j] = o.w;
                    }
                    const int t0 = ga_abs4(c[0]), t1 = ga_abs4(c[1]), t2 = ga_abs4(c[2]), t3 = ga_abs4(c[3]);
                    const int tot = t0 + t1 + t2 + t3;
                    aDC += tot - abs(c[0].x) + abs(c[0].x - 16 * dcv);
                    aV += tot - t0 + ga_abs4(c[0] - ra);
                    aH += tot - abs(c[0].x) - abs(c[1].x) - abs(c[2].x) - abs(c[3].x) + abs(c[0].x - rl.x) + abs(c[1].x - rl.y) +
                          abs(c[2].x - rl.z) + abs(c[3].x - rl.w);
                }
            }
            int slot = 0;
            if (mm & 1u) add(slot++, aDC);
            if (mm & 2u) add(slot++, aV);
            if (mm & 4u) add(slot, aH);
        }
        job++;
    }
#pragma unroll
    for (int m = AV1G_D45_PRED; m <= AV1G_PAETH_PRED; m++) {
        if (!(mm >> m & 1)) continue;
        if (job++ % G != grp) continue;
        const PredCand pc = pred_cand0(m, T::lw, T::lh);
        int a = 0;
#pragma unroll
        for (int it = 0; it < MIT; it++) {
            if (it >= nit) continue;
            const int sx = sxs[it], sy = sys[it];
            if (rows4) {
                const uint v = sv[it][0];
                const int y = sy + i;
                const int4 r = ga_wh4(px(v, 0) - pred_fast(pc, y, sx, A, L, dcv), px(v, 1) - pred_fast(pc, y, sx + 1, A, L, dcv),
                                      px(v, 2) - pred_fast(pc, y, sx + 2, A, L, dcv), px(v, 3) - pred_fast(pc, y, sx + 3, A, L, dcv));
                a += ga_abs4(ga_col4(r, i));
            } else {
                int d[16];
#pragma unroll
                for (int r = 0; r < 4; r++)
#pragma unroll
                    for (int j = 0; j < 4; j++) d[r * 4 + j] = px(sv[it][r], j) - pred_fast(pc, sy + r, sx + j, A, L, dcv);
                a += hadamard4_sum(d);
            }
        }
        add((int)popcount(mm & ((1u << m) - 1u)), a);
    }
    ga_sync<NT>();
}

// Glass Act: warp_residual's loop for a mode at delta 0 without the edge filter, the mode a
// constant (pred_cand0), so its predictor is compiled for itself: the same samples p0, p0 + step,
// ..., the same residuals, and (sq) the same float sum of their squares in the same order
template <int W, int H, int M>
__device__ __forceinline__ float ga_res_mode(const uint8_t *src, int sp, int16_t *res, const uint8_t *A, const uint8_t *L, int dcv,
                                             int p0, int step, bool sq) {
    typedef TxD<W, H> T;
    const PredCand pc = pred_cand0(M, T::lw, T::lh);
    float e = 0.f;
    for (int p = p0; p < W * H; p += step) {
        const int i = p / W, j = p % W;
        const int r = (int)src[i * sp + j] - pred_fast(pc, i, j, A, L, dcv);
        res[p] = (int16_t)r;
        if (sq) e += (float)(r * r);
    }
    return e;
}
template <int W, int H>
__device__ __forceinline__ float ga_res_modes(int m, const uint8_t *src, int sp, int16_t *res, const uint8_t *A, const uint8_t *L,
                                              int dcv, int p0, int step, bool sq) {
    switch (m) {
    case 0: return ga_res_mode<W, H, 0>(src, sp, res, A, L, dcv, p0, step, sq);
    case 1: return ga_res_mode<W, H, 1>(src, sp, res, A, L, dcv, p0, step, sq);
    case 2: return ga_res_mode<W, H, 2>(src, sp, res, A, L, dcv, p0, step, sq);
    case 3: return ga_res_mode<W, H, 3>(src, sp, res, A, L, dcv, p0, step, sq);
    case 4: return ga_res_mode<W, H, 4>(src, sp, res, A, L, dcv, p0, step, sq);
    case 5: return ga_res_mode<W, H, 5>(src, sp, res, A, L, dcv, p0, step, sq);
    case 6: return ga_res_mode<W, H, 6>(src, sp, res, A, L, dcv, p0, step, sq);
    case 7: return ga_res_mode<W, H, 7>(src, sp, res, A, L, dcv, p0, step, sq);
    case 8: return ga_res_mode<W, H, 8>(src, sp, res, A, L, dcv, p0, step, sq);
    case 9: return ga_res_mode<W, H, 9>(src, sp, res, A, L, dcv, p0, step, sq);
    case 10: return ga_res_mode<W, H, 10>(src, sp, res, A, L, dcv, p0, step, sq);
    case 11: return ga_res_mode<W, H, 11>(src, sp, res, A, L, dcv, p0, step, sq);
    default: return ga_res_mode<W, H, 12>(src, sp, res, A, L, dcv, p0, step, sq);
    }
}

// residual of candidate c into res (W x H), returns sum r^2 (all lanes).  With the intra edge filter,
// directional candidates use edges prepared by lane 0 into pa/pl (filter type 0: neighbour modes unknown).
// Glass Act: NTS > NT (k_analysis's screening threads, tsc each): the residual on all NTS, then
// the sum of squares read back from res by the first NT, each over the samples and in the order
// it would have computed them (p = lane, lane + NT, ...): the same float sum.
template <int W, int H, int NT = 32, int NTS = NT>
__device__ __forceinline__ float warp_residual(const uint8_t *src, int sp, int c, int16_t *res, const uint8_t *A,
                                               const uint8_t *L, int dcv, int lane, uint8_t *pa = nullptr, uint8_t *pl = nullptr,
                                               int *up = nullptr, int edgeFilter = 0, int haveL = 0, int haveA = 0, int x = 0,
                                               int y = 0, int maxX = 0, int maxY = 0, float *red = nullptr, int tsc = 0) {
    typedef TxD<W, H> T;
    const int m = cand_mode(c);
    const bool ef = edgeFilter && av1g_is_directional(m);
    if (ef) {
        if (lane == 0) {
            for (int k = 0; k < ASmem<W, H>::EL; k++) { pa[k] = A[k - AV1G_EDGE_OFF]; pl[k] = L[k - AV1G_EDGE_OFF]; }
            av1g_edge_prepare(pangle_of(m, cand_delta(c)), T::lw, T::lh, 0, haveL, haveA, x, y, maxX, maxY, pa + AV1G_EDGE_OFF,
                              pl + AV1G_EDGE_OFF, &up[0], &up[1]);
        }
        ga_sync<NT>();
    }
    const PredCand pc = pred_cand(c, T::lw, T::lh);
    float e = 0.f;
    const bool byMode = !ef && cand_delta(c) == 0;
    if (NTS != NT) {
        if (byMode) ga_res_modes<W, H>(m, src, sp, res, A, L, dcv, tsc, NTS, false);
        else
        for (int p = tsc; p < W * H; p += NTS) {
            const int i = p / W, j = p % W;
            const int pr = ef ? av1g_pred_pixel_up(m, pangle_of(m, cand_delta(c)), i, j, T::lw, T::lh, pa + AV1G_EDGE_OFF,
                                                   pl + AV1G_EDGE_OFF, up[0], up[1])
                              : pred_fast(pc, i, j, A, L, dcv);
            res[p] = (int16_t)((int)src[i * sp + j] - pr);
        }
        ga_sync<NT>();
        for (int p = lane; p < W * H; p += NT) {
            const int r = res[p];
            e += (float)(r * r);
        }
        return ga_sum<NT>(e, lane, red);
    }
    if (byMode) e = ga_res_modes<W, H>(m, src, sp, res, A, L, dcv, lane, NT, true);
    else
    for (int p = lane; p < W * H; p += NT) {
        const int i = p / W, j = p % W;
        const int pr = ef ? av1g_pred_pixel_up(m, pangle_of(m, cand_delta(c)), i, j, T::lw, T::lh, pa + AV1G_EDGE_OFF,
                                               pl + AV1G_EDGE_OFF, up[0], up[1])
                          : pred_fast(pc, i, j, A, L, dcv);
        const int r = (int)src[i * sp + j] - pr;
        res[p] = (int16_t)r;
        e += (float)(r * r);
    }
    ga_sync<NT>();
    return ga_sum<NT>(e, lane, red);
}

// Glass Act: an inter frame's candidate for a block of 8x8 and up (k_inter's, run before this), or
// null. The analysis keeps the cheaper of it and the intra J (`ga_merge_inter`), and doesn't search
// intra where the inter residual quantizes to nothing.
template <int W, int H>
static inline device GpInterRes *ga_inter_of(constant GpBatch &B, device const GpImage &I, int bs, uint32_t li) {
    return (W >= 8 && H >= 8 && B.inter) ? B.inter + I.shOff[bs] + li : nullptr;
}
static inline void ga_merge_inter(device GpBlockRes &out, device GpInterRes *ir, float intraJ) {
    out.J = intraJ;
    if (!ir) return;
    const bool inter = ir->J < intraJ;
    if (inter) out.J = ir->J;
    ir->isInter = inter ? 1 : 0;
}

// NT: threads to a block (32, or more for the big shapes, which then take one block a threadgroup)
// NTS: the threads a block screens on (NT, or 2 NT: 64x64), the rest of its work on the first NT;
// the others (ga_idle_lane) follow its every barrier and reduction without a part in them
template <int W, int H, int BS, int NW, int NT = 32, int NTS = NT>
kernel void k_analysis(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                       constant uint32_t &nTotal [[buffer(2)]], device const float *fwdM [[buffer(3)]],
                       uint blockIdx_x [[threadgroup_position_in_grid]],
                       uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]) {
    typedef TxD<W, H> T;
    threadgroup ASmem<W, H> smem[NW];
    static_assert(NTS == NT || (NW == 1 && NTS == 2 * NT && NT >= 64), "screening on more threads: one block a threadgroup");
    const int warp = (int)threadIdx_x / NTS, tsc = (int)threadIdx_x % NTS;  // the block's slot, its screening thread
    const int lane = ga_idle_lane<NT>(tsc);  // its thread in the rest
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
        device GpInterRes *ir = ga_inter_of<W, H>(B, I, BS, li);
        if (ir && P.interSkipsIntra && ir->zero && ir->J < GP_INF) {  // Glass Act: an inter block with no residual, no intra search
            if (lane == 0) { out.J = ir->J; out.ncand = 0; ir->isInter = 1; }
            ga_sync<NT>();
            continue;
        }
        // (pruned blocks are most of a level on a new picture: before the rest of the set-up)
        const int qidx = sb_qindex(I, x, y);
        if (prune_flat(I, P, x, y, W, H, qidx)) {
            if (lane == 0) { ga_merge_inter(out, ir, GP_INF); out.ncand = 0; }
            ga_sync<NT>();
            continue;
        }
        const TileBox tb = tile_of(I, x, y);
        const int haveLeft = x > tb.x0, haveAbove = y > tb.y0;
        const int haveAR = ol_decoded(x + W, y - 1, x, y, 0, tb);
        const int haveBL = ol_decoded(x - 1, y + H, x, y, 0, tb);
        const int maxX = I.MiCols * 4 - 1, maxY = I.MiRows * 4 - 1;
        device const uint8_t *src = I.src[0] + (size_t)y * I.spitch[0] + x;
        const int sp = I.spitch[0];
        const float lambda = gp_lambda(qidx, P.lambdaMul) * ssim_scale(I, x, y, W, H);
        const float lamS = P.satdLambda * sqrtf(lambda);
        AV1G_CONST const float *C = g_cost[I.qctx];
        if (P.pruneVar > 0.f && W * H >= P.pruneMinArea) {
            float s1 = 0.f, s2 = 0.f;
            for (int p = lane; p < W * H; p += NT) {
                const float v = (float)src[(p / W) * sp + p % W];
                s1 += v;
                s2 += v * v;
            }
            s1 = ga_sum<NT>(s1, lane, S.red);
            s2 = ga_sum<NT>(s2, lane, S.red);
            const float var = s2 / (W * H) - (s1 / (W * H)) * (s1 / (W * H));
            const float st = av1g_ac_q(qidx) / 8.f;
            if (var > P.pruneVar * st * st) {
                if (lane == 0) { ga_merge_inter(out, ir, GP_INF); out.ncand = 0; }
                ga_sync<NT>();
                continue;
            }
        }
        build_edges_par(I.src[0], sp, x, y, T::lw, T::lh, haveLeft, haveAbove, haveAR, haveBL, maxX, maxY, A, L, tsc, NTS);  // (integers: any threads)
        device const GpExtCand *ext = ga_fixed ? nullptr : (device const GpExtCand *)B.extCand[BS];
        // Glass Act: the screening's SATDs zeroed and its candidates listed (the modes learned mode
        // pruning leaves, in order) behind the edges' barrier: they read nothing the edges make, and
        // each entry is written by one thread (a mode's slot by its mode's, the rest by their own)
        const uint mm = ml_mode_mask(I, x, y, W, H);
        if (!ext && tsc < 32) {
            S.satd[tsc] = 0.f;
            if (tsc < 13 && (mm >> tsc & 1)) S.cand[popcount(mm & ((1u << tsc) - 1u))] = cand_pack(tsc, 0);
            if (tsc >= (int)popcount(mm)) S.cand[tsc] = 0;
        }
        ga_sync<NTS>();
        // Glass Act: the DC value's edge sums on the first SIMD-group (whole numbers, any order: the
        // same sum as av1g_dc_value's), each of its lanes then forming the value as av1g_dc_value
        // does; with more than a SIMD-group it reaches the others through S.dcv behind the flat
        // check's barriers
        int dcv = 0;
        if (tsc < 32) {
            int sum = 0;
            if (haveAbove)
                for (int k = tsc; k < W; k += 32) sum += A[k];
            if (haveLeft)
                for (int k = tsc; k < H; k += 32) sum += L[k];
            sum = simd_sum(sum);
            dcv = haveLeft && haveAbove ? (sum + ((W + H) >> 1)) / (W + H)
                : haveLeft              ? av1g_clip1((sum + (H >> 1)) >> T::lh)
                : haveAbove             ? av1g_clip1((sum + (W >> 1)) >> T::lw)
                                        : 1 << 7;
            if (NTS > 32 && tsc == 0) S.dcv = dcv;
        }
        // Glass Act: a flat block whose prediction edges are flat too (common on screens) is
        // predicted exactly by every mode, so every candidate screens at 0 and its RD is an
        // all-zero block's: the same results, without the predictions and transforms
        bool flat;
        {
            const uint8_t v = src[0];
            int bad = 0;
            for (int p = tsc; p < W * H; p += NTS) bad |= src[(p / W) * sp + p % W] != v;
            for (int i = tsc - 1; i < W + H; i += NTS) bad |= A[i] != v;
            for (int i = tsc; i < W + H; i += NTS) bad |= L[i] != v;
            if (NTS == 32) flat = ga_max<NTS>(bad, tsc, S.redi) == 0;
            else {  // (ga_max's two barriers, S.dcv written before them)
                bad = warp_max(bad);
                threadgroup_barrier(mem_flags::mem_threadgroup);
                if ((tsc & 31) == 0) S.redi[tsc >> 5] = bad;
                threadgroup_barrier(mem_flags::mem_threadgroup);
                int t = S.redi[0];
                for (int w = 1; w < NTS / 32; w++) t = max(t, S.redi[w]);
                flat = t == 0;
                dcv = S.dcv;
            }
        }
        int K = ga_fixed ? 1 : min((W * H >= 1024 && P.kLarge > 0) ? P.kLarge : P.K, GP_MAXK);
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
            ga_sync<NT>();
        } else {
        // ---- screening: the modes at delta 0 ----
        const int ssub = (P.screenSub == 2 && W * H >= 256) ? 2 : 1;
        int ncand = (int)popcount(mm);
        if (!flat) warp_screen_modes<W, H, NTS>(src, sp, mm, S.satd, A, L, dcv, tsc, ssub, S.cand);
        // (angle deltas read S.satd by mode: only with every mode screened)
        const bool allowDelta = P.deltas && mm == 0x1FFFu && BS >= AV1G_BLOCK_8X8 && (P.deltasMaxArea <= 0 || W * H <= P.deltasMaxArea);
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
            ga_sync<NT>();
            if (!flat) warp_screen<W, H, NTS>(src, sp, S.cand, 13, 25, S.satd, A, L, dcv, tsc, ssub);
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
        e.qmDist = ga_fixed ? 0 : P.qmDist; e.qmRnd = ga_fixed ? 0 : P.qmRnd;  // (without a matrix they weigh by 1)
        float bestJ = GP_INF;
        int bestK = 0, bestTx = AV1G_DCT_DCT;
        // (a flat block's: no distortion, and an all-zero block's bits whatever the mode or type)
        const float flatR = flat ? base_bits(e, 0) : 0.f;
        for (int k = 0; k < K; k++) {
            if (top[k] < 0) break;
            const int c = S.cand[top[k]];
            if (flat) {
                const float J = 0.f + lambda * (flatR + mbits(c) + overhead);
                if (J < bestJ) { bestJ = J; bestK = k; }
                continue;
            }
            e.resEnergy = warp_residual<W, H, NT, NTS>(src, sp, c, S.res, A, L, dcv, lane, paOf(S), plOf(S), S.up, ga_fixed ? 0 : I.edgeFilter, haveLeft, haveAbove, x, y, maxX, maxY, S.red, tsc);
            // Glass Act: a prediction that is exact (common on screens: stripes, a repeated row or
            // column) leaves nothing to transform: no distortion and an all-zero block's bits,
            // which is what the transform and the quantizer would arrive at
            if (e.resEnergy == 0.f) {
                const float J = 0.f + lambda * (base_bits(e, 0) + mbits(c) + overhead);
                if (J < bestJ) { bestJ = J; bestK = k; }
                continue;
            }
            e.txType = AV1G_DCT_DCT;
            e.intraDir = cand_mode(c);
            e.qm = ga_fixed ? nullptr : av1g_qm(I.usingQm, I.qm[0], 0, txSz, AV1G_DCT_DCT);
            EvalOut o;
#ifdef GA_FWD_MMA
            // (DCT_DCT on the matrix units, the same coefficients: the squares of 16 and up, their
            // matrix read from device memory. With a threadgroup copy of it 16x16 and 64x64 were
            // slower, 1.94 -> 2.56 and 2.33 -> 4.26 ms of a 5K picture of new content)
            if (ga_mma && W == H && W >= 16) {
                warp_fwd_mma<W, NTS>(S.res, S.tmp, fwdM + ga_fwd_matrix_offset(T::lw), g_txScale[txSz], tsc);
                warp_quant_rate_rt<NT>(S.tmp, qOf(S), e, o, W, H, lane, S.red, S.redi, ga_iscan(fwdM, txSz, AV1G_DCT_DCT));
            } else
#endif
            warp_eval<W, H, NT>(S.res, S.tmp, qOf(S), e, o, lane, S.red, S.redi, ga_iscan(fwdM, txSz, AV1G_DCT_DCT));
            const float J = o.D + lambda * (o.R + mbits(c) + overhead);
            if (J < bestJ) { bestJ = J; bestK = k; }
        }
        // ---- tx-type search for the winner ----
        if (!ga_fixed && P.txSearch && set != AV1G_TX_SET_DCTONLY && !flat) {
            const int c = S.cand[top[bestK]];
            e.resEnergy = warp_residual<W, H, NT>(src, sp, c, S.res, A, L, dcv, lane, paOf(S), plOf(S), S.up, ga_fixed ? 0 : I.edgeFilter, haveLeft, haveAbove, x, y, maxX, maxY, S.red);
            e.intraDir = cand_mode(c);
            for (int t = 1; t < 16; t++) {
                if (!av1g_tx_type_in_set_intra(set, t)) continue;
                e.txType = t;
                e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, t);
                EvalOut o;
                warp_eval<W, H, NT>(S.res, S.tmp, qOf(S), e, o, lane, S.red, S.redi, ga_iscan(fwdM, txSz, t));
                const float J = o.D + lambda * (o.R + mbits(c) + overhead);
                if (J < bestJ) { bestJ = J; bestTx = t; }
            }
        }
        if (lane == 0) {
            ga_merge_inter(out, ir, bestJ);
            out.tx = (uint8_t)bestTx;
            int n = 0;
            out.cand[n++] = (uint8_t)S.cand[top[bestK]];
            for (int k = 0; k < K && top[k] >= 0; k++)
                if (k != bestK) out.cand[n++] = (uint8_t)S.cand[top[k]];
            out.ncand = (uint8_t)n;
        }
        ga_sync<NT>();
    }
}
