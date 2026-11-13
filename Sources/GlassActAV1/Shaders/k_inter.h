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
//   k_inter  one SIMD-group per (shape, position) of 8x8 and up, before the intra analysis: SAD
//            screening of no motion and the vectors k_me kept for the 16x16s the block covers, then
//            the analysis's exact-rate RD (DCT_DCT) of the best, into GpInterRes (J, and zero when
//            the residual quantizes to nothing). The intra analysis skips a zero one (libaom
//            realtime tries no intra where the best inter is skip) and otherwise keeps the cheaper,
//            so the partition DP weighs the inter block as any other. (8x8 to 16x16 run as k_inter_q,
//            several blocks a SIMD-group up to the RD, and 16x32, 32x16, 32x32 and 64x64 as
//            k_inter_s, a block a SIMD-group up to an RD on the threadgroup: the same results)
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

// Glass Act: the previous picture's 64-sample strips, every SB's once (k_proj_sums): row k of
// SB s sums to sums[s * 128 + k], column k to sums[s * 128 + 64 + k]. k_proj's search ranges are
// strips at its SB's column (rows) and row (columns) of SBs, so neighbouring SBs' ranges, which
// overlap, read them from here instead of summing them again. Whole numbers: the same sums.
kernel void k_proj_sums(constant GpBatch &B [[buffer(0)]], device int *sums [[buffer(3)]],
                        uint sb [[threadgroup_position_in_grid]], uint tid [[thread_position_in_threadgroup]]) {
    device const GpImage &I = B.img[0];
    if ((int)sb >= I.sbCols * I.sbRows) return;
    const int x = (int)(sb % I.sbCols) * 64, y = (int)(sb / I.sbCols) * 64, sp = I.spitch[0];
    device const uint8_t *ref = I.ref;
    const int k = (int)tid & 63;
    int t = 0;
    if (tid < 64)
        for (int j = 0; j < 64; j++) t += ref[(size_t)(y + k) * sp + x + j];
    else
        for (int j = 0; j < 64; j++) t += ref[(size_t)(y + j) * sp + x + k];
    sums[sb * 128 + tid] = t;
}

// (with useSums, the reference's strips from k_proj_sums's `sums`; else summed here)
kernel void k_proj(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                   constant uint32_t &nSbs [[buffer(2)]], device const int *sums [[buffer(3)]],
                   constant uint32_t &useSums [[buffer(4)]], uint tg [[threadgroup_position_in_grid]],
                   uint tid [[thread_position_in_threadgroup]]) {
    constexpr int RYMAX = 2 * GA_PROJ_RY, RXMAX = 2 * GA_PROJ_RX;
    threadgroup int srow[64], scol[64], rrow[64 + 2 * RYMAX], rcol[64 + 2 * RXMAX];
    threadgroup float bestCost[GA_PROJ_T / 32];
    threadgroup int bestOff[GA_PROJ_T / 32 + 1];
    threadgroup uint rankOf[GA_PROJ_T / 32];
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
    // (aw and ah are whole SBs: a row or column of the picture is one of an SB's strips)
    const int sbx = x >> 6, sby = y >> 6;
    for (int k = (int)tid; k < 64 + 2 * ry; k += GA_PROJ_T) {
        const int row = y - ry + k;
        int r = -1;
        if (row >= 0 && row < I.ah) {
            if (useSums) r = sums[((row >> 6) * I.sbCols + sbx) * 128 + (row & 63)];
            else {
                r = 0;
                for (int j = 0; j < 64; j++) r += ref[(size_t)row * sp + x + j];
            }
        }
        rrow[k] = r;
    }
    for (int k = (int)tid; k < 64 + 2 * rx; k += GA_PROJ_T) {
        const int col = x - rx + k;
        int c = -1;
        if (col >= 0 && col < I.aw) {
            if (useSums) c = sums[(sby * I.sbCols + (col >> 6)) * 128 + 64 + (col & 63)];
            else {
                c = 0;
                for (int j = 0; j < 64; j++) c += ref[(size_t)(y + j) * sp + col];
            }
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
        // Glass Act: the threads' best by (cost, |d|), and among equals the one a strided halving
        // (tid against tid + s, s = 128 .. 1, the lower kept unless the other is better) keeps: the
        // lowest tid bit-reversed. Each SIMD-group's by simd_min, then the 8 on the first
        const uint rank = reverse_bits(tid) >> 24;
        float m = simd_min(bc);
        uint ad = simd_min(bc == m ? (uint)abs(bo) : 0xFFFFFFFFu);
        uint rk = simd_min(bc == m && (uint)abs(bo) == ad ? rank : 0xFFFFFFFFu);
        if (rank == rk) {  // (one lane a SIMD-group)
            bestCost[tid / 32] = bc;
            bestOff[tid / 32] = bo;
            rankOf[tid / 32] = rank;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid < 32) {
            const int w = (int)tid;
            const float c = w < GA_PROJ_T / 32 ? bestCost[w] : GP_INF;
            const int oo = w < GA_PROJ_T / 32 ? bestOff[w] : 0;
            const uint rr = w < GA_PROJ_T / 32 ? rankOf[w] : 0xFFFFFFFFu;
            m = simd_min(c);
            ad = simd_min(c == m ? (uint)abs(oo) : 0xFFFFFFFFu);
            rk = simd_min(c == m && (uint)abs(oo) == ad ? rr : 0xFFFFFFFFu);
            if (rr == rk) bestOff[GA_PROJ_T / 32] = oo;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const int o = bestOff[GA_PROJ_T / 32];
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

// ga_ref_px from a window of the reference in threadgroup memory (pitch wp; x, y relative to it):
// the same arithmetic, the same values
static inline int ga_ref_px_tg(threadgroup const uint8_t *w, int wp, int x, int y, int2 v) {
    const int px = (x << 3) + v.x, py = (y << 3) + v.y;
    const int ix = px >> 3, iy = py >> 3, fx = px & 7, fy = py & 7;
    threadgroup const uint8_t *r = w + iy * wp + ix;
    if ((fx | fy) == 0) return r[0];
    const int a = r[0], b = r[1], c = r[wp], d = r[wp + 1];
    return ((8 - fx) * (8 - fy) * a + fx * (8 - fy) * b + (8 - fx) * fy * c + fx * fy * d + 32) >> 6;
}

// whether a W x H block at (x, y) + v reads only the padded reference (one more sample across a
// fractional position, for bilinear)
static inline bool ga_ref_inside(device const GpImage &I, int x, int y, int2 v, int W, int H) {
    const int x0 = x + (v.x >> 3), y0 = y + (v.y >> 3);
    return x0 >= 0 && y0 >= 0 && x0 + W + ((v.x & 7) != 0) <= I.aw && y0 + H + ((v.y & 7) != 0) <= I.ah;
}

#define GA_ME_NW 4
#define GA_ME_WIN 18  // k_me's sub-sample window: 16 + 1 sample either side
kernel void k_me(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                 constant uint32_t &nCells [[buffer(2)]], uint tg [[threadgroup_position_in_grid]],
                 uint lane [[thread_index_in_simdgroup]], uint warp [[simdgroup_index_in_threadgroup]]) {
    threadgroup uint8_t cur[GA_ME_NW][256];
    threadgroup uint8_t win[GA_ME_NW][GA_ME_WIN * GA_ME_WIN];
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
    // Glass Act: where no window's centre (no motion, each candidate) predicts better than the
    // cell's own mean (P.interGate times its SAD to it), new content: the centres only
    int nSearch = n;
    int wb = 0;  // the window whose centre measured best (with the gate; else no motion's)
    if (P.interGate > 0.f) {
        uint s1 = 0;
        for (int p = (int)lane; p < 128; p += 32) s1 += cur[warp][(p >> 4) * 32 + (p & 15)];  // the even rows'
        const int mean = (int)((simd_sum(s1) + 64) / 128);
        uint dc = 0;
        for (int p = (int)lane; p < 128; p += 32) dc += (uint)abs((int)cur[warp][(p >> 4) * 32 + (p & 15)] - mean);
        dc = simd_sum(dc);
        const int nw = 1 + (n - GA_ME_ZERO) / 81;
        // (each centre's SAD on the whole SIMD-group: 4 of its 128 samples a lane)
        uint best = 0xFFFFFFFFu;
        for (int w = 0; w < nw; w++) {
            const int i = w == 0 ? GA_ME_ZERO / 2 : GA_ME_ZERO + 81 * (w - 1) + 40;  // the window's centre
            const int2 v = ga_me_vector(I, i, sbv);
            const int rx = x + v.x, ry = y + v.y;
            if (rx < 0 || ry < 0 || rx > I.aw - 16 || ry > I.ah - 16) continue;
            device const uint8_t *r = I.ref + (size_t)ry * sp + rx;
            uint sad = 0;
            for (int p = (int)lane; p < 128; p += 32) {
                const int row = (p >> 4) * 2, col = p & 15;
                sad += (uint)abs((int)cur[warp][row * 16 + col] - (int)r[row * sp + col]);
            }
            sad = simd_sum(sad);
            if (sad < best) { best = sad; wb = w; }
        }
        if ((float)best > P.interGate * (float)dc) nSearch = 0;
    }
    // Glass Act: 32 vectors a round, each window from a centre; after each round the SIMD-group's
    // second best key so far, `thr`, and a lane stops measuring a vector once its partial SAD is
    // above thr's: its key would be above two already measured, so it can't be one of the best
    // two. The same vectors, indices and full SADs for every one that can, so the same best two
    // Glass Act: the window whose centre the gate measured best first (from its centre), so the
    // bound is tight early: where no motion's window has that centre, no motion's from it, else
    // that candidate's window, then no motion's; the other windows after, in order. (Any order
    // measures the same vectors, with the same indices.)
    uint thr = 0xFFFFFFFFu;
    const int2 cb = wb == 0 ? int2(0, 0) : ga_me_vector(I, GA_ME_ZERO + 81 * (wb - 1) + 40, sbv);
    const bool inZero = abs(cb.x) <= 8 && abs(cb.y) <= 8;
    const int f = inZero ? 0 : 81, z0 = inZero ? (cb.y + 8) * 17 + cb.x + 8 : GA_ME_ZERO / 2;
    // (the lane's vector: offset o, from the window's first, in the window at place wi of that
    // order; stepped 32 a round, each window larger than 32)
    int wi = 0, o = (int)lane;
    for (int q0 = 0; q0 < nSearch; q0 += 32) {
        const int q = q0 + (int)lane;
        const int w = f ? (wi == 0 ? wb : wi == 1 ? 0 : wi - 1 + (wi - 1 >= wb ? 1 : 0)) : wi;
        if (q < nSearch) {
            int i;
            int2 v;
            if (w == 0) {
                const int io = o + z0 - (o + z0 >= GA_ME_ZERO ? GA_ME_ZERO : 0);
                i = io;
                v = int2(io % 17 - 8, io / 17 - 8);
            } else {
                const int io = o + 40 - (o + 40 >= 81 ? 81 : 0), c = w - 1;
                i = GA_ME_ZERO + 81 * c + io;
                v = (c < min(I.nMeCand, GP_ME_CANDS) ? int2(I.meCand[2 * c], I.meCand[2 * c + 1]) : sbv) + int2(io % 9 - 4, io / 9 - 4);
            }
            bool seen = false;
            if (w > 0) {  // Glass Act: a vector an earlier window has (no motion's +-8, or a candidate's +-4) once
                seen = abs(v.x) <= 8 && abs(v.y) <= 8;
                const int c = w - 1;
                for (int e = 0; e < c && !seen; e++) {
                    const int2 ce = e < min(I.nMeCand, GP_ME_CANDS) ? int2(I.meCand[2 * e], I.meCand[2 * e + 1]) : sbv;
                    seen = abs(v.x - ce.x) <= 4 && abs(v.y - ce.y) <= 4;
                }
            }
            const int rx = x + v.x, ry = y + v.y;
            if (!seen && rx >= 0 && ry >= 0 && rx <= I.aw - 16 && ry <= I.ah - 16) {
                device const uint8_t *r = I.ref + (size_t)ry * sp + rx;
                // (the key so far, partial SAD << 11 | i, is at most the vector's: above thr, it can't
                // be one of the two; so where thr's SAD is 0, nothing after thr's index is measured)
                uint sad = 0;
                bool done = (uint)i < thr;
                for (int row = 0; row < (done ? 16 : 0); row += 2) {
                    for (int col = 0; col < 16; col++) sad += (uint)abs((int)cur[warp][row * 16 + col] - (int)r[row * sp + col]);
                    if (((sad << 11) | (uint)i) > thr) { done = false; break; }
                }
                if (done) {
                    const uint key = (sad << 11) | (uint)i;
                    if (key < k0) { k1 = k0; k0 = key; }
                    else if (key < k1) k1 = key;
                }
            }
        }
        o += 32;
        if (o >= (w == 0 ? GA_ME_ZERO : 81)) { o -= w == 0 ? GA_ME_ZERO : 81; wi++; }
        const uint t0 = simd_min(k0);
        thr = simd_min(k0 == t0 ? k1 : k0);
    }
    const uint b0 = simd_min(k0);
    const uint b1 = simd_min(k0 == b0 ? k1 : k0);
    // none found (every vector outside the picture): no motion
    int2 best[2] = {b0 == 0xFFFFFFFFu ? int2(0, 0) : ga_me_vector(I, (int)(b0 & 2047), sbv) * 8,
                    b1 == 0xFFFFFFFFu ? int2(0, 0) : ga_me_vector(I, (int)(b1 & 2047), sbv) * 8};
    if (P.meSubpel && b0 != 0xFFFFFFFFu) {
        // the best one to half, then quarter samples: the 8 neighbours at each step, every row. Each
        // lane measures 8 samples of each (a row's half), and the SIMD-group sums them
        // Glass Act: every position the two steps reach (within 6/8 of the whole-sample best), and
        // their bilinear neighbours, read from the reference once: an 18x18 window from one sample
        // above and left of the best's block, in threadgroup memory (outside the picture: unread,
        // as ga_ref_inside keeps those positions out)
        const int wx0 = x + (best[0].x >> 3) - 1, wy0 = y + (best[0].y >> 3) - 1;
        for (int p = (int)lane; p < GA_ME_WIN * GA_ME_WIN; p += 32) {
            const int wy = wy0 + p / GA_ME_WIN, wx = wx0 + p % GA_ME_WIN;
            win[warp][p] = wx >= 0 && wy >= 0 && wx < I.aw && wy < I.ah ? I.ref[(size_t)wy * sp + wx] : (uint8_t)0;
        }
        simdgroup_barrier(mem_flags::mem_threadgroup);
        uint bestSad = 0xFFFFFFFFu;
        const int row = (int)lane >> 1, col0 = ((int)lane & 1) * 8;
        const int bx = best[0].x >> 3, by = best[0].y >> 3;  // the whole-sample best: the window's (1, 1)
        int cv[8];  // the lane's 8 samples of the cell
        for (int col = 0; col < 8; col++) cv[col] = cur[warp][row * 16 + col0 + col];
        for (int step = 4; step >= 2; step >>= 1) {
            const int2 c = best[0];
            uint top = 0xFFFFFFFFu;
            // Glass Act: ga_ref_px's bilinear sum as (8 - fy) h(top) + fy h(below) (+ 32, >> 6), h a
            // row's (8 - fx) a + fx b: the same whole numbers. A step's 9 positions are 3 columns by
            // 3 rows of offsets, so the lane makes each column's h once for the 2 or 3 rows they read
            // and the column's 3 positions share them
            const int oy0 = ((c.y - step) >> 3) - by + 1, span = (((c.y + step) >> 3) - by + 1) - oy0;  // rows oy0 .. oy0 + span + 1
            uint pt[9];  // the lane's part of each position's SAD
            for (int j = 0; j < 3; j++) {
                const int vx = c.x + (j - 1) * step, ox = (vx >> 3) - bx + 1, fx = vx & 7;
                int h[3][8];
                for (int t = 0; t < 3; t++) {
                    if (t > span + 1) {  // (a row no position reads, and maybe past the window)
                        for (int col = 0; col < 8; col++) h[t][col] = 0;
                        continue;
                    }
                    threadgroup const uint8_t *w = win[warp] + (row + oy0 + t) * GA_ME_WIN + col0 + ox;
                    for (int col = 0; col < 8; col++) h[t][col] = (8 - fx) * (int)w[col] + fx * (int)w[col + 1];
                }
                for (int k = 0; k < 3; k++) {
                    const int l = k * 3 + j;
                    pt[l] = 0;
                    if (l == 4 && step != 4) continue;  // the centre, as the last step measured it
                    const int2 v = int2(vx, c.y + (k - 1) * step);
                    const int fy = v.y & 7, t = ((v.y >> 3) - by + 1) - oy0;
                    for (int col = 0; col < 8; col++)
                        pt[l] += (uint)abs(cv[col] - (((8 - fy) * (t ? h[1][col] : h[0][col]) +
                                                       fy * (t ? h[2][col] : h[1][col]) + 32) >> 6));
                }
            }
            // Glass Act: two positions' sums in one simd_sum, 16 bits each (a lane's part is at most
            // 8 * 255, the SIMD-group's 32 * 2040 < 65536: no carry between them)
            uint sum[9];
            for (int l = 0; l < 9; l += 2) {
                const uint both = simd_sum(pt[l] | (l + 1 < 9 ? pt[l + 1] << 16 : 0u));
                sum[l] = both & 0xFFFFu;
                if (l + 1 < 9) sum[l + 1] = both >> 16;
            }
            for (int l = 0; l < 9; l++) {
                // the centre once (at the first step) and the 8 neighbours; outside the padded
                // reference: none
                uint sad = 0xFFFFFFFFu;
                if (l == 4 && step != 4) sad = bestSad;
                else if (ga_ref_inside(I, x, y, c + int2((l % 3 - 1) * step, (l / 3 - 1) * step), 16, 16)) sad = sum[l];
                const uint key = sad == 0xFFFFFFFFu ? 0xFFFFFFFFu : (sad << 4) | (l == 4 ? 0u : (uint)l + 1);  // centre first on ties
                top = min(top, key);
            }
            if (top != 0xFFFFFFFFu) {
                const int l = (top & 15) == 0 ? 4 : (int)(top & 15) - 1;
                best[0] = c + int2((l % 3 - 1) * step, (l / 3 - 1) * step);
                bestSad = top >> 4;
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

// k_inter_sad: one threadgroup per listed SB, after k_me. Its distinct candidates (no motion, then
// its 16x16s' k_me vectors in raster order, each once) into GpImage.meU, and every 8x8's SAD at each
// into meSad (0xFFFF where the 8x8 at that vector would read outside the padded reference). k_inter
// sums them: a block's SAD at a vector is its 8x8s' (whole samples, so exactly), so each sample is
// measured once per vector instead of once per shape.
#define GA_SAD_T 128
kernel void k_inter_sad(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                        uint tg [[threadgroup_position_in_grid]], uint tid [[thread_position_in_threadgroup]]) {
    threadgroup int16_t u[2 * GP_ME_U];
    threadgroup int nu;
    threadgroup uint vk[16 * GP_ME_KEEP];
    threadgroup uchar first[16 * GP_ME_KEEP];
    device const GpImage &I = B.img[0];
    const uint32_t sb = B.sbList ? B.sbList[tg] : tg;
    const int sbx = (int)(sb % I.sbCols) * 64, sby = (int)(sb / I.sbCols) * 64;
    device GpMeU &U = I.meU[sb];
    // Glass Act: the distinct list on 32 threads, as a walk in raster order builds it: vector t is
    // new where it isn't no motion and no earlier one is the same; its slot is 1 + the new ones before
    // it, and each vector's index is its first occurrence's slot (no motion's: 0)
    constexpr int NV = 16 * GP_ME_KEEP;
    static_assert(NV <= 32, "k_inter_sad: a SIMD-group of vectors");
    if (tid < NV) {
        const int k = (int)tid / GP_ME_KEEP, kk = (int)tid % GP_ME_KEEP;
        device const int16_t *m = I.meBest + ((size_t)((sby >> 4) + k / 4) * (I.aw >> 4) + (sbx >> 4) + k % 4) * 2 * GP_ME_KEEP;
        vk[tid] = (uint)(uint16_t)m[2 * kk] | (uint)(uint16_t)m[2 * kk + 1] << 16;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid < NV) {  // (the first SIMD-group)
        const int t = (int)tid;
        const uint v = vk[t];
        int f = t;
        for (int e = 0; e < t && f == t; e++)
            if (vk[e] == v) f = e;
        const bool isNew = v != 0u && f == t;
        const int below = simd_prefix_exclusive_sum(isNew ? 1 : 0), total = simd_sum(isNew ? 1 : 0);
        if (isNew) {
            u[2 * (1 + below)] = (int16_t)(v & 0xFFFFu);
            u[2 * (1 + below) + 1] = (int16_t)(v >> 16);
        }
        first[t] = (uchar)(1 + below);
        simdgroup_barrier(mem_flags::mem_threadgroup);
        U.idx[t] = v == 0u ? (uint8_t)0 : (uint8_t)first[f];  // a repeat: its first occurrence's slot
        if (t == 0) { u[0] = 0; u[1] = 0; nu = 1 + total; U.n = (uint8_t)(1 + total); }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (int j = (int)tid; j < 2 * nu; j += GA_SAD_T) U.v[j] = u[j];
    const int sp = I.spitch[0];
    device uint16_t *out = I.meSad + (size_t)sb * GP_ME_U * 64;
    for (int it = (int)tid; it < nu * 64; it += GA_SAD_T) {
        const int j = it / 64, s8 = it % 64;
        const int x = sbx + (s8 % 8) * 8, y = sby + (s8 / 8) * 8;
        const int2 v = int2(u[2 * j], u[2 * j + 1]);
        uint sad = 0xFFFFu;
        if (ga_ref_inside(I, x, y, v, 8, 8)) {
            device const uint8_t *src = I.src[0] + (size_t)y * sp + x;
            // Glass Act: ga_ref_px's bilinear sum as (8 - fy) h(row) + fy h(row + 1) (+ 32, >> 6), h a
            // row's (8 - fx) a + fx b: the same whole numbers, each reference row read once (and the
            // samples ga_ref_px reads only: no next column without fx, no next row without fy), in a loop
            // of its own for each case (selects between the cases cost as much as the loads)
            const int fx = v.x & 7, fy = v.y & 7;
            device const uint8_t *ref = I.ref + (size_t)(y + (v.y >> 3)) * sp + x + (v.x >> 3);
            sad = 0;
            if ((fx | fy) == 0) {
                for (int r = 0; r < 8; r++)
                    for (int c = 0; c < 8; c++) sad += (uint)abs((int)src[r * sp + c] - (int)ref[r * sp + c]);
            } else if (fy == 0) {  // (8 h + 32) >> 6 a row
                for (int r = 0; r < 8; r++)
                    for (int c = 0; c < 8; c++)
                        sad += (uint)abs((int)src[r * sp + c] -
                                         ((8 * ((8 - fx) * (int)ref[r * sp + c] + fx * (int)ref[r * sp + c + 1]) + 32) >> 6));
            } else if (fx == 0) {  // h = 8 a
                int h0[8];
                for (int c = 0; c < 8; c++) h0[c] = 8 * (int)ref[c];
                for (int r = 0; r < 8; r++) {
                    device const uint8_t *n = ref + (size_t)(r + 1) * sp;
                    for (int c = 0; c < 8; c++) {
                        const int h1 = 8 * (int)n[c];
                        sad += (uint)abs((int)src[r * sp + c] - (((8 - fy) * h0[c] + fy * h1 + 32) >> 6));
                        h0[c] = h1;
                    }
                }
            } else {
                int h0[8];
                for (int c = 0; c < 8; c++) h0[c] = (8 - fx) * (int)ref[c] + fx * (int)ref[c + 1];
                for (int r = 0; r < 8; r++) {
                    device const uint8_t *n = ref + (size_t)(r + 1) * sp;
                    for (int c = 0; c < 8; c++) {
                        const int h1 = (8 - fx) * (int)n[c] + fx * (int)n[c + 1];
                        sad += (uint)abs((int)src[r * sp + c] - (((8 - fy) * h0[c] + fy * h1 + 32) >> 6));
                        h0[c] = h1;
                    }
                }
            }
        }
        out[j * 64 + s8] = (uint16_t)sad;
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

// k_inter's lanes per candidate: a power of two (at most a SIMD-group, and at most a candidate's n
// loads) that puts every one of the block's ncm candidates on the NT threads at once
constexpr int ga_inter_lanes(int n, int ncm, int nt) {
    int g = 32;
    while (g > 1 && (g > n || nt / g < ncm)) g >>= 1;
    return g;
}

// Glass Act: k_inter's scratch, what warp_eval and the sums use of the analysis's ASmem (no edges,
// screening lists or DCT matrix): less threadgroup memory a block, so more blocks a core
template <int W, int H>
struct GaInterSmem {
    int16_t res[W * H];
    float tmp[TxD<W, H>::th * TxD<W, H>::TS];
    int16_t q[TxD<W, H>::n];
    float red[8];
    int redi[8];
};

// Glass Act: k_inter's RD of a DCT_DCT block: warp_eval, with the squares of 16 and up on the matrix
// units where the analysis has them (ga_mma: the host's start-up check found them bit-identical to
// the passes warp_eval runs, at the thread counts k_inter runs them on), so the same coefficients;
// the end of block from the quantization loop (ga_iscan)
template <int W, int H, int NT>
__device__ __forceinline__ void ga_inter_eval(threadgroup GaInterSmem<W, H> &S, device const float *fwdM, thread const EvalIn &e,
                                              thread EvalOut &o, int lane) {
#ifdef GA_FWD_MMA
    if (ga_mma && W == H && W >= 16) {
        warp_fwd_mma<W, NT>(S.res, S.tmp, fwdM + ga_fwd_matrix_offset(TxD<W, H>::lw), g_txScale[e.txSz], lane);
        warp_quant_rate_rt<NT>(S.tmp, S.q, e, o, W, H, lane, S.red, S.redi, ga_iscan(fwdM, e.txSz, e.txType));
        return;
    }
#endif
    warp_eval<W, H, NT>(S.res, S.tmp, S.q, e, o, lane, S.red, S.redi, ga_iscan(fwdM, e.txSz, e.txType));
}

template <int W, int H, int BS, int NW, int NT = 32>
kernel void k_inter(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                    constant uint32_t &nTotal [[buffer(2)]], device const float *fwdM [[buffer(3)]],
                    uint blockIdx_x [[threadgroup_position_in_grid]],
                    uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]) {
    threadgroup GaInterSmem<W, H> smem[NW];
    const int warp = (int)threadIdx_x / NT, lane = (int)threadIdx_x % NT;  // the block's slot, its thread (k_analysis's NT)
    threadgroup GaInterSmem<W, H> &S = smem[warp];
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
        device GpInterRes &ir = B.inter[I.shOff[BS] + li];
        if (x >= I.MiCols * 4 || y >= I.MiRows * 4) {
            if (lane == 0) { ir.isInter = 0; ir.zero = 0; ir.J = GP_INF; }
            continue;
        }
        if (B.sbKeep && B.sbKeep[I.sbBase + (y >> 6) * I.sbCols + (x >> 6)]) continue;
        const int sp = I.spitch[0];
        device const uint8_t *src = I.src[0] + (size_t)y * sp + x;
        const int qidx = sb_qindex(I, x, y);
        const float lambda = gp_lambda(qidx, P.lambdaMul) * ssim_scale(I, x, y, W, H);
        const float lamS = P.satdLambda * sqrtf(lambda);
        // candidates: no motion, and k_me's vectors of the 16x16s covered, each once; their SADs the
        // sums of k_inter_sad's 8x8s (the same values as measuring the block)
        const int c0x = x >> 4, c0y = y >> 4, c1x = (x + W - 1) >> 4, c1y = (y + H - 1) >> 4;
        const int nc = 1 + (c1x - c0x + 1) * (c1y - c0y + 1) * GP_ME_KEEP;
        const int sbi = (y >> 6) * I.sbCols + (x >> 6);
        device const GpMeU &U = I.meU[I.sbBase + sbi];
        device const uint16_t *S8 = I.meSad + (size_t)(I.sbBase + sbi) * GP_ME_U * 64;
        const int bx8 = (x & 63) >> 3, by8 = (y & 63) >> 3;
        auto candJ = [&](int c) -> int {  // candidate c's index into U
            if (c == 0) return 0;
            const int k = c - 1, cell = k / GP_ME_KEEP, kk = k % GP_ME_KEEP;
            const int cx = c0x + cell % (c1x - c0x + 1), cy = c0y + cell / (c1x - c0x + 1);
            return U.idx[((cy & 3) * 4 + (cx & 3)) * GP_ME_KEEP + kk];
        };
        // Glass Act: the candidates side by side, G lanes each (an aligned run of a SIMD-group) summing
        // its 8x8s, then the ordered minimum of (s, c): the first candidate with the smallest s, as a
        // walk in candidate order taking strictly smaller ones picks. A vector met again (the same j)
        // has the same s and comes later, so it never wins and needn't be skipped. G puts all ncm
        // candidates on the NT threads at once, so the loop runs once
        constexpr int N8 = (W / 8) * (H / 8);
        constexpr int NCM = 1 + (W > 16 ? W / 16 : 1) * (H > 16 ? H / 16 : 1) * GP_ME_KEEP;
        constexpr int VEC = W / 8 < 4 ? W / 8 : 4;
        constexpr int G = ga_inter_lanes(N8 / VEC, NCM, NT), CP = NT / G;
        float bm = GP_INF;
        uint bk = 0xFFFFFFFFu;  // the winner's c << 23 | its SAD (64 x 0xFFFF at most)
        for (int base = 0; base < nc; base += CP) {
            const int c = base + lane / G;
            uint sad = 0;
            int2 v = int2(0, 0);
            bool ok = false;
            if (c < nc) {
                const int j = candJ(c);
                v = int2(U.v[2 * j], U.v[2 * j + 1]);
                ok = ga_ref_inside(I, x, y, v, W, H);
                if (ok) {
                    // VEC of a row's 8x8s a load (aligned: bx8 is a multiple of W / 8)
                    device const uint16_t *r8 = S8 + j * 64 + by8 * 8 + bx8;
                    for (int q = lane % G; q < N8 / VEC; q += G) {
                        const int p = q * VEC, o = (p / (W / 8)) * 8 + p % (W / 8);
                        if (VEC == 4) {
                            const ushort4 t = *(device const ushort4 *)(r8 + o);
                            sad += (uint)t.x + t.y + t.z + t.w;
                        } else if (VEC == 2) {
                            const ushort2 t = *(device const ushort2 *)(r8 + o);
                            sad += (uint)t.x + t.y;
                        } else sad += r8[o];
                    }
                }
            }
            for (int o = 1; o < G; o <<= 1) sad += simd_shuffle_xor(sad, (ushort)o);
            float sv = GP_INF;
            uint key = 0xFFFFFFFFu;
            if (ok) {
                const float s = (float)sad + lamS * ga_mv_bits(v, P.meSubpel);
                if (s < GP_INF) { sv = s; key = (uint)c << 23 | sad; }
            }
            const float m = simd_min(sv);
            const uint k = simd_min(sv == m ? key : 0xFFFFFFFFu);
            if (m < bm || (m == bm && k < bk)) { bm = m; bk = k; }
        }
        if (NT > 32) {  // the SIMD-groups' winners, in a fixed order
            threadgroup_barrier(mem_flags::mem_threadgroup);  // (red, redi free)
            if ((lane & 31) == 0) { S.red[lane >> 5] = bm; S.redi[lane >> 5] = (int)bk; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            bm = S.red[0];
            bk = (uint)S.redi[0];
            for (int w = 1; w < NT / 32; w++) {
                const float m = S.red[w];
                const uint k = (uint)S.redi[w];
                if (m < bm || (m == bm && k < bk)) { bm = m; bk = k; }
            }
        }
        uint bestSad = 1;
        int2 best = int2(0, 0);
        if (bk != 0xFFFFFFFFu) {
            const int j = candJ((int)(bk >> 23));
            bestSad = bk & 0x7FFFFFu;
            best = int2(U.v[2 * j], U.v[2 * j + 1]);
        }
        // the block's source, a thread's samples in the order the loops below visit them: read once
        // for the gate's mean and SAD to it, and the residual
        static_assert((W * H) % NT == 0, "k_inter: a block's samples split evenly over its threads");
        constexpr int NPX = W * H / NT;
        uint8_t px[NPX];
        uint s1 = 0;
        if (bestSad > 0)
            for (int i = 0; i < NPX; i++) {
                const int p = lane + NT * i;
                px[i] = src[(p / W) * sp + p % W];
                s1 += px[i];
            }
        // Glass Act: where the best candidate predicts worse than the block's own mean would (new
        // content), no RD for it: intra will code the block
        if (P.interGate > 0.f && bestSad > 0) {
            const int mean = (int)((ga_sumu<NT>(s1, lane, S.redi) + W * H / 2) / (W * H));
            uint dc = 0;
            for (int i = 0; i < NPX; i++) dc += (uint)abs((int)px[i] - mean);
            dc = ga_sumu<NT>(dc, lane, S.redi);
            if ((float)bestSad > P.interGate * (float)dc) {
                if (lane == 0) { ir.dx = (int16_t)best.x; ir.dy = (int16_t)best.y; ir.isInter = 0; ir.zero = 0; ir.J = GP_INF; }
                ga_sync<NT>();
                continue;
            }
        }
        // the best one's exact-rate RD, as the analysis costs an intra candidate
        EvalIn e;
        e.txSz = txSz; e.plane = 0; e.txType = AV1G_DCT_DCT;
        e.dcQ = av1g_dc_q(qidx); e.acQ = av1g_ac_q(qidx);
        e.rnd = P.rnd; e.zbin = P.zbin;
        e.skipCtx = 0; e.dcCtx = 0; e.reduced = 0; e.C = g_cost[I.qctx];
        e.qmDist = P.qmDist; e.qmRnd = P.qmRnd;
        e.intraDir = AV1G_DC_PRED;
        EvalOut o;
        if (bestSad == 0) {
            // an exact match: no residual, so what warp_eval gives zeros (no distortion, the skip flag's
            // bits) without the transform
            o.D = 0.f; o.R = base_bits(e, 0); o.eob = 0;
        } else {
            float en = 0.f;
            for (int i = 0; i < NPX; i++) {
                const int p = lane + NT * i;
                const int d = (int)px[i] - ga_ref_px(I.ref, sp, x + p % W, y + p / W, best);
                S.res[p] = (int16_t)d;
                en += (float)(d * d);
            }
            ga_sync<NT>();
            e.resEnergy = ga_sum<NT>(en, lane, S.red);
            e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, AV1G_DCT_DCT);
            ga_inter_eval<W, H, NT>(S, fwdM, e, o, lane);
        }
        const int hasC = av1g_has_chroma(BS, y >> 2, x >> 2, I.mono);
        const float J = o.D + lambda * (o.R + ga_mv_bits(best, P.meSubpel) + (hasC ? P.uvOverheadBits : 0.f) + g_avgSkip0);
        if (lane == 0) {
            ir.dx = (int16_t)best.x;
            ir.dy = (int16_t)best.y;
            ir.isInter = 0;
            ir.zero = o.eob == 0 ? 1 : 0;
            ir.J = J;
        }
        ga_sync<NT>();
    }
}

// Glass Act: k_inter for the shapes of one 16x16 at most (8x8 to 16x16), Q blocks a SIMD-group
// (32 / Q lanes each) for what comes before the RD (the set-up, the candidate pick and the gate):
// most of such a block's time where the picture is new, and one SIMD-group's latency a block in
// k_inter. Then each block that needs it gets the whole SIMD-group's RD, as k_inter<W, H> gives it.
// The same choices: a block's candidates are costed and ordered as there, its SADs and source sums
// are whole numbers (the same in any order), and the RD reads the source and residual on the same
// lanes as k_inter.
template <int W, int H, int BS, int NW, int Q>
kernel void k_inter_q(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                     constant uint32_t &nTotal [[buffer(2)]], device const float *fwdM [[buffer(3)]],
                    uint blockIdx_x [[threadgroup_position_in_grid]],
                     uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]) {
    static_assert(W <= 16 && H <= 16, "k_inter_q: blocks inside one 16x16");
    constexpr int NT = 32, GL = 32 / Q;
    threadgroup GaInterSmem<W, H> smem[NW];
    const int warp = (int)threadIdx_x / NT, lane = (int)threadIdx_x % NT;
    threadgroup GaInterSmem<W, H> &S = smem[warp];
    const int sub = lane / GL, sl = lane % GL;
    constexpr int txSz = ga_tx_of<W, H>();
    device const GpImage &I = B.img[0];
    const int nbx = I.shNbx[BS], sp = I.spitch[0];
    for (uint32_t g0 = (blockIdx_x * NW + warp) * Q; g0 < nTotal; g0 += gridDim_x * NW * Q) {
        const uint32_t gb = g0 + (uint32_t)sub;
        // this lane's block: live unless past the end, off the shape's grid, outside the picture or kept
        bool live = gb < nTotal;
        uint32_t li = gb;
        if (live && B.sbList) {
            const uint32_t per = (64 / W) * (64 / H), sb = B.sbList[gb / per], k = gb % per;
            const int bx = (int)(sb % I.sbCols) * (64 / W) + (int)(k % (64 / W));
            const int by = (int)(sb / I.sbCols) * (64 / H) + (int)(k / (64 / W));
            if (bx >= nbx || by >= I.shNby[BS]) live = false;
            else li = (uint32_t)(by * nbx + bx);
        }
        const int x = (int)(li % nbx) * W, y = (int)(li / nbx) * H;
        device GpInterRes &ir = B.inter[I.shOff[BS] + li];
        if (live && (x >= I.MiCols * 4 || y >= I.MiRows * 4)) {
            if (sl == 0) { ir.isInter = 0; ir.zero = 0; ir.J = GP_INF; }
            live = false;
        }
        if (live && B.sbKeep && B.sbKeep[I.sbBase + (y >> 6) * I.sbCols + (x >> 6)]) live = false;
        float lambda = 0.f;
        uint bestSad = 1;
        int2 best = int2(0, 0);
        bool rd = false;
        if (live) {
            const int qidx = sb_qindex(I, x, y);
            lambda = gp_lambda(qidx, P.lambdaMul) * ssim_scale(I, x, y, W, H);
            const float lamS = P.satdLambda * sqrtf(lambda);
            // candidates 0..2 (no motion, its 16x16's k_me vectors), CG of the block's lanes each summing
            // its 8x8s' SADs (as k_inter's G)
            const int sbi = (y >> 6) * I.sbCols + (x >> 6);
            device const GpMeU &U = I.meU[I.sbBase + sbi];
            device const uint16_t *S8 = I.meSad + (size_t)(I.sbBase + sbi) * GP_ME_U * 64;
            const int bx8 = (x & 63) >> 3, by8 = (y & 63) >> 3, cell = ((y & 63) >> 4) * 4 + ((x & 63) >> 4);
            constexpr int nc = 1 + GP_ME_KEEP;
            constexpr int N8 = (W / 8) * (H / 8), CG = ga_inter_lanes(N8, nc, GL);
            static_assert(nc * CG <= GL, "k_inter_q: a block's candidates on its lanes at once");
            const int c = sl / CG;
            float sv = GP_INF;
            uint key = 0xFFFFFFFFu;
            uint sad = 0;
            bool ok = false;
            int2 v = int2(0, 0);
            if (c < nc) {
                const int j = c == 0 ? 0 : U.idx[cell * GP_ME_KEEP + c - 1];
                v = int2(U.v[2 * j], U.v[2 * j + 1]);
                ok = ga_ref_inside(I, x, y, v, W, H);
                if (ok) {
                    device const uint16_t *r8 = S8 + j * 64 + by8 * 8 + bx8;
                    for (int p = sl % CG; p < N8; p += CG) sad += r8[(p / (W / 8)) * 8 + p % (W / 8)];
                }
            }
            for (int o = 1; o < CG; o <<= 1) sad += simd_shuffle_xor(sad, (ushort)o);
            if (ok) {
                const float s = (float)sad + lamS * ga_mv_bits(v, P.meSubpel);
                if (s < GP_INF) { sv = s; key = (uint)c << 23 | sad; }
            }
            // the ordered minimum of (s, c) over the block's lanes
            float m = sv;
            for (int o = 1; o < GL; o <<= 1) m = min(m, simd_shuffle_xor(m, (ushort)o));
            uint bk = sv == m ? key : 0xFFFFFFFFu;
            for (int o = 1; o < GL; o <<= 1) bk = min(bk, simd_shuffle_xor(bk, (ushort)o));
            if (bk != 0xFFFFFFFFu) {
                const int cb = (int)(bk >> 23);
                const int j = cb == 0 ? 0 : U.idx[cell * GP_ME_KEEP + cb - 1];
                bestSad = bk & 0x7FFFFFu;
                best = int2(U.v[2 * j], U.v[2 * j + 1]);
            }
            rd = true;
            // the gate on the block's lanes: its mean and its SAD to it (whole numbers)
            if (P.interGate > 0.f && bestSad > 0) {
                device const uint8_t *src = I.src[0] + (size_t)y * sp + x;
                constexpr int NP = W * H / GL;
                uint8_t px[NP];
                uint s1 = 0;
                for (int i = 0; i < NP; i++) {
                    const int p = sl + GL * i;
                    px[i] = src[(p / W) * sp + p % W];
                    s1 += px[i];
                }
                for (int o = 1; o < GL; o <<= 1) s1 += simd_shuffle_xor(s1, (ushort)o);
                const int mean = (int)((s1 + W * H / 2) / (W * H));
                uint dc = 0;
                for (int i = 0; i < NP; i++) dc += (uint)abs((int)px[i] - mean);
                for (int o = 1; o < GL; o <<= 1) dc += simd_shuffle_xor(dc, (ushort)o);
                if ((float)bestSad > P.interGate * (float)dc) {
                    if (sl == 0) { ir.dx = (int16_t)best.x; ir.dy = (int16_t)best.y; ir.isInter = 0; ir.zero = 0; ir.J = GP_INF; }
                    rd = false;
                }
            }
        }
        // the RD, a block at a time on the whole SIMD-group, as k_inter<W, H>
        for (int q = 0; q < Q; q++) {
            const ushort ql = (ushort)(q * GL);
            if (!simd_shuffle(rd ? 1 : 0, ql)) continue;
            const int qx = simd_shuffle(x, ql), qy = simd_shuffle(y, ql);
            const uint qSad = simd_shuffle(bestSad, ql);
            const int2 qBest = int2(simd_shuffle(best.x, ql), simd_shuffle(best.y, ql));
            const float qLambda = simd_shuffle(lambda, ql);
            const uint32_t qli = simd_shuffle(li, ql);
            const int qidx = sb_qindex(I, qx, qy);
            EvalIn e;
            e.txSz = txSz; e.plane = 0; e.txType = AV1G_DCT_DCT;
            e.dcQ = av1g_dc_q(qidx); e.acQ = av1g_ac_q(qidx);
            e.rnd = P.rnd; e.zbin = P.zbin;
            e.skipCtx = 0; e.dcCtx = 0; e.reduced = 0; e.C = g_cost[I.qctx];
            e.qmDist = P.qmDist; e.qmRnd = P.qmRnd;
            e.intraDir = AV1G_DC_PRED;
            EvalOut o;
            if (qSad == 0) {
                o.D = 0.f; o.R = base_bits(e, 0); o.eob = 0;
            } else {
                device const uint8_t *src = I.src[0] + (size_t)qy * sp + qx;
                float en = 0.f;
                for (int i = 0; i < W * H / NT; i++) {
                    const int p = lane + NT * i;
                    const int d = (int)src[(p / W) * sp + p % W] - ga_ref_px(I.ref, sp, qx + p % W, qy + p / W, qBest);
                    S.res[p] = (int16_t)d;
                    en += (float)(d * d);
                }
                ga_sync<NT>();
                e.resEnergy = ga_sum<NT>(en, lane, S.red);
                e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, AV1G_DCT_DCT);
                ga_inter_eval<W, H, NT>(S, fwdM, e, o, lane);
            }
            const int hasC = av1g_has_chroma(BS, qy >> 2, qx >> 2, I.mono);
            const float J = o.D + qLambda * (o.R + ga_mv_bits(qBest, P.meSubpel) + (hasC ? P.uvOverheadBits : 0.f) + g_avgSkip0);
            if (lane == 0) {
                device GpInterRes &qr = B.inter[I.shOff[BS] + qli];
                qr.dx = (int16_t)qBest.x;
                qr.dy = (int16_t)qBest.y;
                qr.isInter = 0;
                qr.zero = o.eob == 0 ? 1 : 0;
                qr.J = J;
            }
            ga_sync<NT>();
        }
    }
}

// Glass Act: k_inter for the shapes whose RD takes NT > 32 threads (32x32, 64x64), NT / 32 blocks a
// threadgroup: each SIMD-group takes one block's set-up, candidate pick and gate on its own (no
// threadgroup barriers: as k_inter<W, H> at NT 32, the same ordered minimum and whole-number sums),
// then the threadgroup gives each block that needs it the RD on all NT threads, exactly as
// k_inter<W, H, BS, 1, NT> does (the source and residual on the same threads, the same sums).
template <int W, int H, int BS, int NT>
kernel void k_inter_s(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                      constant uint32_t &nTotal [[buffer(2)]], device const float *fwdM [[buffer(3)]],
                    uint blockIdx_x [[threadgroup_position_in_grid]],
                      uint gridDim_x [[threadgroups_per_grid]], uint threadIdx_x [[thread_position_in_threadgroup]]) {
    static_assert(NT > 32 && NT % 32 == 0, "k_inter_s: a block's RD on several SIMD-groups");
    constexpr int NB = NT / 32;  // blocks a threadgroup
    struct Slot {
        int rd;  // 1: the RD wanted
        uint sad;
        int bx, by;
        float lambda;
        uint li;
    };
    threadgroup GaInterSmem<W, H> S;
    threadgroup Slot slot[NB];
    const int tid = (int)threadIdx_x, sg = tid / 32, l32 = tid % 32;
    constexpr int txSz = ga_tx_of<W, H>();
    device const GpImage &I = B.img[0];
    const int nbx = I.shNbx[BS], sp = I.spitch[0];
    for (uint32_t g0 = blockIdx_x * NB; g0 < nTotal; g0 += gridDim_x * NB) {
        // (one SIMD-group's block: uniform across its lanes)
        const uint32_t gb = g0 + (uint32_t)sg;
        bool live = gb < nTotal;
        uint32_t li = gb;
        if (live && B.sbList) {
            const uint32_t per = (64 / W) * (64 / H), sb = B.sbList[gb / per], k = gb % per;
            const int bx = (int)(sb % I.sbCols) * (64 / W) + (int)(k % (64 / W));
            const int by = (int)(sb / I.sbCols) * (64 / H) + (int)(k / (64 / W));
            if (bx >= nbx || by >= I.shNby[BS]) live = false;
            else li = (uint32_t)(by * nbx + bx);
        }
        const int x = (int)(li % nbx) * W, y = (int)(li / nbx) * H;
        device GpInterRes &ir = B.inter[I.shOff[BS] + li];
        if (live && (x >= I.MiCols * 4 || y >= I.MiRows * 4)) {
            if (l32 == 0) { ir.isInter = 0; ir.zero = 0; ir.J = GP_INF; }
            live = false;
        }
        if (live && B.sbKeep && B.sbKeep[I.sbBase + (y >> 6) * I.sbCols + (x >> 6)]) live = false;
        int rd = 0;
        uint bestSad = 1;
        int2 best = int2(0, 0);
        float lambda = 0.f;
        if (live) {
            const int qidx = sb_qindex(I, x, y);
            lambda = gp_lambda(qidx, P.lambdaMul) * ssim_scale(I, x, y, W, H);
            const float lamS = P.satdLambda * sqrtf(lambda);
            const int c0x = x >> 4, c0y = y >> 4, c1x = (x + W - 1) >> 4, c1y = (y + H - 1) >> 4;
            const int nc = 1 + (c1x - c0x + 1) * (c1y - c0y + 1) * GP_ME_KEEP;
            const int sbi = (y >> 6) * I.sbCols + (x >> 6);
            device const GpMeU &U = I.meU[I.sbBase + sbi];
            device const uint16_t *S8 = I.meSad + (size_t)(I.sbBase + sbi) * GP_ME_U * 64;
            const int bx8 = (x & 63) >> 3, by8 = (y & 63) >> 3;
            auto candJ = [&](int c) -> int {  // candidate c's index into U
                if (c == 0) return 0;
                const int k = c - 1, cell = k / GP_ME_KEEP, kk = k % GP_ME_KEEP;
                const int cx = c0x + cell % (c1x - c0x + 1), cy = c0y + cell / (c1x - c0x + 1);
                return U.idx[((cy & 3) * 4 + (cx & 3)) * GP_ME_KEEP + kk];
            };
            // the candidates side by side on the SIMD-group, as k_inter's (its G at 32 threads)
            constexpr int N8 = (W / 8) * (H / 8);
            constexpr int NCM = 1 + (W > 16 ? W / 16 : 1) * (H > 16 ? H / 16 : 1) * GP_ME_KEEP;
            constexpr int VEC = W / 8 < 4 ? W / 8 : 4;
            constexpr int G = ga_inter_lanes(N8 / VEC, NCM, 32), CP = 32 / G;
            float bm = GP_INF;
            uint bk = 0xFFFFFFFFu;
            for (int base = 0; base < nc; base += CP) {
                const int c = base + l32 / G;
                uint sad = 0;
                int2 v = int2(0, 0);
                bool ok = false;
                if (c < nc) {
                    const int j = candJ(c);
                    v = int2(U.v[2 * j], U.v[2 * j + 1]);
                    ok = ga_ref_inside(I, x, y, v, W, H);
                    if (ok) {
                        device const uint16_t *r8 = S8 + j * 64 + by8 * 8 + bx8;
                        for (int q = l32 % G; q < N8 / VEC; q += G) {
                            const int p = q * VEC, o = (p / (W / 8)) * 8 + p % (W / 8);
                            if (VEC == 4) {
                                const ushort4 t = *(device const ushort4 *)(r8 + o);
                                sad += (uint)t.x + t.y + t.z + t.w;
                            } else if (VEC == 2) {
                                const ushort2 t = *(device const ushort2 *)(r8 + o);
                                sad += (uint)t.x + t.y;
                            } else sad += r8[o];
                        }
                    }
                }
                for (int o = 1; o < G; o <<= 1) sad += simd_shuffle_xor(sad, (ushort)o);
                float sv = GP_INF;
                uint key = 0xFFFFFFFFu;
                if (ok) {
                    const float s = (float)sad + lamS * ga_mv_bits(v, P.meSubpel);
                    if (s < GP_INF) { sv = s; key = (uint)c << 23 | sad; }
                }
                const float m = simd_min(sv);
                const uint k = simd_min(sv == m ? key : 0xFFFFFFFFu);
                if (m < bm || (m == bm && k < bk)) { bm = m; bk = k; }
            }
            if (bk != 0xFFFFFFFFu) {
                const int j = candJ((int)(bk >> 23));
                bestSad = bk & 0x7FFFFFu;
                best = int2(U.v[2 * j], U.v[2 * j + 1]);
            }
            rd = 1;
            // the gate on the SIMD-group: the block's mean and its SAD to it (whole numbers)
            if (P.interGate > 0.f && bestSad > 0) {
                device const uint8_t *src = I.src[0] + (size_t)y * sp + x;
                constexpr int NP = W * H / 32;
                uint s1 = 0;
                for (int i = 0; i < NP; i++) {
                    const int p = l32 + 32 * i;
                    s1 += src[(p / W) * sp + p % W];
                }
                const int mean = (int)((simd_sum(s1) + W * H / 2) / (W * H));
                uint dc = 0;
                for (int i = 0; i < NP; i++) {
                    const int p = l32 + 32 * i;
                    dc += (uint)abs((int)src[(p / W) * sp + p % W] - mean);
                }
                dc = simd_sum(dc);
                if ((float)bestSad > P.interGate * (float)dc) {
                    if (l32 == 0) { ir.dx = (int16_t)best.x; ir.dy = (int16_t)best.y; ir.isInter = 0; ir.zero = 0; ir.J = GP_INF; }
                    rd = 0;
                }
            }
        }
        if (l32 == 0) slot[sg] = Slot{rd, bestSad, best.x, best.y, lambda, li};
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // the RD, a block at a time on all NT threads, as k_inter<W, H, BS, 1, NT>
        for (int q = 0; q < NB; q++) {
            if (!slot[q].rd) continue;  // (uniform: the slot is the threadgroup's)
            const uint qli = slot[q].li, qSad = slot[q].sad;
            const int2 qBest = int2(slot[q].bx, slot[q].by);
            const float qLambda = slot[q].lambda;
            const int qx = (int)(qli % nbx) * W, qy = (int)(qli / nbx) * H;
            const int qidx = sb_qindex(I, qx, qy);
            const int lane = tid;
            constexpr int NPX = W * H / NT;
            EvalIn e;
            e.txSz = txSz; e.plane = 0; e.txType = AV1G_DCT_DCT;
            e.dcQ = av1g_dc_q(qidx); e.acQ = av1g_ac_q(qidx);
            e.rnd = P.rnd; e.zbin = P.zbin;
            e.skipCtx = 0; e.dcCtx = 0; e.reduced = 0; e.C = g_cost[I.qctx];
            e.qmDist = P.qmDist; e.qmRnd = P.qmRnd;
            e.intraDir = AV1G_DC_PRED;
            EvalOut o;
            if (qSad == 0) {
                o.D = 0.f; o.R = base_bits(e, 0); o.eob = 0;
            } else {
                device const uint8_t *src = I.src[0] + (size_t)qy * sp + qx;
                float en = 0.f;
                for (int i = 0; i < NPX; i++) {
                    const int p = lane + NT * i;
                    const int d = (int)src[(p / W) * sp + p % W] - ga_ref_px(I.ref, sp, qx + p % W, qy + p / W, qBest);
                    S.res[p] = (int16_t)d;
                    en += (float)(d * d);
                }
                ga_sync<NT>();
                e.resEnergy = ga_sum<NT>(en, lane, S.red);
                e.qm = av1g_qm(I.usingQm, I.qm[0], 0, txSz, AV1G_DCT_DCT);
                ga_inter_eval<W, H, NT>(S, fwdM, e, o, lane);
            }
            const int hasC = av1g_has_chroma(BS, qy >> 2, qx >> 2, I.mono);
            const float J = o.D + qLambda * (o.R + ga_mv_bits(qBest, P.meSubpel) + (hasC ? P.uvOverheadBits : 0.f) + g_avgSkip0);
            if (lane == 0) {
                device GpInterRes &qr = B.inter[I.shOff[BS] + qli];
                qr.dx = (int16_t)qBest.x;
                qr.dy = (int16_t)qBest.y;
                qr.isInter = 0;
                qr.zero = o.eob == 0 ? 1 : 0;
                qr.J = J;
            }
            ga_sync<NT>();
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);  // (the slots read)
    }
}
