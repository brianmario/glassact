/* av1g/postfilter.h - the decoder's post-filters for intra frames, header-only and
 * host + device (one implementation shared by the CPU backend, the GPU kernels and engines):
 *   deblocking loop filter  (spec 7.14)   av1g_lf_edge()   one 4-sample edge segment
 *   CDEF                    (spec 7.15)   av1g_cdef_setup() + av1g_cdef_pixel(), or av1g_cdef_block()
 *
 * The frame is described by av1g_pf_frame: plane pointers plus the 4x4-granular maps the
 * filters read (Skips, LoopfilterTxSizes per plane, cdef_idx per 64x64).  Build the maps
 * with av1g_pf_frame_init(), cdefIdx[] = -1, then av1g_pf_mark_block() for every block of
 * the record (blocks never overlap, so one thread per block is fine).
 *
 * Order (spec 7.14 / 7.15): deblock every plane - pass 0 (vertical edges) of a plane
 * completes before its pass 1 (horizontal edges); within a pass all edges are independent
 * - then CDEF reads the deblocked frame and writes a separate output frame; all 8x8 blocks
 * are independent.  8-bit, 4:2:0 or monochrome, no segmentation / delta-lf / lossless;
 * lfLevel[] are the effective levels (Y vertical, Y horizontal, U, V).
 *
 * Define AV1G_PF_STAT(kind) before including to count filter paths (tests only). */
#ifndef AV1G_POSTFILTER_H
#define AV1G_POSTFILTER_H

#include <stddef.h>
#include <stdint.h>
#include "av1g/hd.h"
#include "av1g/dsp.h"
#include "av1g/blockinfo.h"
#include "av1g/decisions.h"

#ifndef AV1G_PF_STAT
#define AV1G_PF_STAT(kind) ((void)0)
#endif
enum { AV1G_PF_LF_MASKED = 0, AV1G_PF_LF_NARROW_HEV, AV1G_PF_LF_NARROW, AV1G_PF_LF_WIDE6, AV1G_PF_LF_WIDE8, AV1G_PF_LF_WIDE16,
       AV1G_PF_CDEF_SKIP8X8, AV1G_PF_CDEF_FILTERED, AV1G_PF_CDEF_CLAMPED, AV1G_PF_STAT_COUNT };

typedef struct av1g_pf_frame {
    int W, H, MiRows, MiCols, mono;
    uint8_t *plane[3];          /* frame being deblocked in place / CDEF source */
    int stride[3];
    uint8_t *skip;              /* Skips, MiRows x MiCols, stride MiCols */
    uint8_t *lfTx[3];           /* LoopfilterTxSizes: luma like skip; chroma (MiRows/2) x (MiCols/2), stride MiCols/2 */
    int8_t *cdefIdx;            /* per 64x64, raster, stride sbCols; -1 = no CDEF (no non-skip block in it) */
    int32_t *cdefDirVar;        /* optional (GPU path): per 8x8, (var << 3) | yDir, stride MiCols/2 */
    int sbCols, sbRows;
    int lfLevel[4];             /* effective loop filter levels Y vert, Y horz, U, V (0..63); 0 = off */
    int sharpness;              /* 0..7 */
    int enableCdef;
    int cdefDamping;            /* CdefDamping = cdef_damping_minus_3 + 3 */
    int cdefYPri[8], cdefYSec[8], cdefUVPri[8], cdefUVSec[8];  /* sec strengths are 0, 1, 2, 4 */
} av1g_pf_frame;

/* Copies the frame-level parameters; pointers are left for the caller. */
AV1G_HD void av1g_pf_frame_init(const av1g_frame_params *fp, av1g_pf_frame *f) {
    f->W = (int)fp->width;
    f->H = (int)fp->height;
    f->MiRows = av1g_mi_rows((int)fp->height);
    f->MiCols = av1g_mi_cols((int)fp->width);
    f->mono = fp->monochrome;
    f->sbCols = (f->MiCols + 15) >> 4;
    f->sbRows = (f->MiRows + 15) >> 4;
    for (int i = 0; i < 4; i++) f->lfLevel[i] = fp->loop_filter_level[i];
    if (!fp->loop_filter_level[0] && !fp->loop_filter_level[1]) f->lfLevel[2] = f->lfLevel[3] = 0;
    f->sharpness = fp->loop_filter_sharpness;
    f->enableCdef = fp->enable_cdef;
    f->cdefDamping = fp->cdef_damping_minus_3 + 3;
    for (int i = 0; i < 8; i++) {
        f->cdefYPri[i] = fp->cdef_y_pri[i];
        f->cdefYSec[i] = fp->cdef_y_sec[i];
        f->cdefUVPri[i] = fp->cdef_uv_pri[i];
        f->cdefUVSec[i] = fp->cdef_uv_sec[i];
    }
}

/* Writes one block's entries into the maps (Skips / LoopfilterTxSizes / cdef_idx). */
AV1G_HD void av1g_pf_mark_block(const av1g_pf_frame *f, const av1g_block *b) {
    const int r0 = b->mi_row, c0 = b->mi_col, bs = b->bsize;
    const int bw4 = av1g_bw4(bs), bh4 = av1g_bh4(bs);
    const int txY = av1g_luma_tx_size(bs, b->tx_depth);
    for (int y = r0; y < r0 + bh4 && y < f->MiRows; y++)
        for (int x = c0; x < c0 + bw4 && x < f->MiCols; x++) {
            const size_t k = (size_t)y * f->MiCols + x;
            f->skip[k] = b->skip;
            f->lfTx[0][k] = (uint8_t)txY;
        }
    if (av1g_has_chroma(bs, r0, c0, f->mono)) {
        const int uvSz = av1g_uv_bsize(bs), txUV = av1g_uv_tx_size(bs);
        const int cr = f->MiRows >> 1, cc = f->MiCols >> 1, y0 = r0 >> 1, x0 = c0 >> 1;
        const int w = av1g_bw4(uvSz), h = av1g_bh4(uvSz);
        for (int y = y0; y < y0 + h && y < cr; y++)
            for (int x = x0; x < x0 + w && x < cc; x++) {
                f->lfTx[1][(size_t)y * cc + x] = (uint8_t)txUV;
                f->lfTx[2][(size_t)y * cc + x] = (uint8_t)txUV;
            }
    }
    if (f->enableCdef && !b->skip) f->cdefIdx[(size_t)(r0 >> 4) * f->sbCols + (c0 >> 4)] = b->cdef_idx;
}

/* ---------------- deblocking ---------------- */
AV1G_HD int av1g_iabs(int x) { return x < 0 ? -x : x; }

/* Sample filtering process (7.14.6) for one line across an edge.  q0p points at q0 and
 * step is the distance between successive samples across the edge (1 or the stride). */
AV1G_HD void av1g_lf_line(uint8_t *q0p, ptrdiff_t step, int plane, int filterSize, int limit, int blimit, int thresh) {
#define S_(k) ((int)q0p[(k) * step])
    const int q0 = S_(0), q1 = S_(1), p0 = S_(-1), p1 = S_(-2);
    const int filterLen = filterSize == 4 ? 4 : plane ? 6 : filterSize == 8 ? 8 : 16;
    int mask = (av1g_iabs(p1 - p0) > limit) | (av1g_iabs(q1 - q0) > limit) |
               (av1g_iabs(p0 - q0) * 2 + av1g_iabs(p1 - q1) / 2 > blimit);
    int q2 = 0, p2 = 0, q3 = 0, p3 = 0;
    if (filterLen >= 6) { q2 = S_(2); p2 = S_(-3); mask |= (av1g_iabs(p2 - p1) > limit) | (av1g_iabs(q2 - q1) > limit); }
    if (filterLen >= 8) { q3 = S_(3); p3 = S_(-4); mask |= (av1g_iabs(p3 - p2) > limit) | (av1g_iabs(q3 - q2) > limit); }
    if (mask) { AV1G_PF_STAT(AV1G_PF_LF_MASKED); return; }  /* filterMask == 0 */
    const int hevMask = (av1g_iabs(p1 - p0) > thresh) | (av1g_iabs(q1 - q0) > thresh);
    int flatMask = 0, flatMask2 = 0;
    if (filterSize >= 8) {
        int m = (av1g_iabs(p1 - p0) > 1) | (av1g_iabs(q1 - q0) > 1) | (av1g_iabs(p2 - p0) > 1) | (av1g_iabs(q2 - q0) > 1);
        if (filterLen >= 8) m |= (av1g_iabs(p3 - p0) > 1) | (av1g_iabs(q3 - q0) > 1);
        flatMask = !m;
    }
    if (filterSize >= 16 && flatMask) {
        const int q4 = S_(4), q5 = S_(5), q6 = S_(6), p4 = S_(-5), p5 = S_(-6), p6 = S_(-7);
        const int m = (av1g_iabs(p6 - p0) > 1) | (av1g_iabs(q6 - q0) > 1) | (av1g_iabs(p5 - p0) > 1) | (av1g_iabs(q5 - q0) > 1) |
                      (av1g_iabs(p4 - p0) > 1) | (av1g_iabs(q4 - q0) > 1);
        flatMask2 = !m;
    }
    if (filterSize == 4 || !flatMask) {  /* narrow filter (7.14.6.3) */
        AV1G_PF_STAT(hevMask ? AV1G_PF_LF_NARROW_HEV : AV1G_PF_LF_NARROW);
#define C4(v) av1g_clip3(-128, 127, (v))
        const int ps1 = p1 - 128, ps0 = p0 - 128, qs0 = q0 - 128, qs1 = q1 - 128;
        int filter = hevMask ? C4(ps1 - qs1) : 0;
        filter = C4(filter + 3 * (qs0 - ps0));
        const int filter1 = C4(filter + 4) >> 3, filter2 = C4(filter + 3) >> 3;
        q0p[0] = (uint8_t)(C4(qs0 - filter1) + 128);
        q0p[-step] = (uint8_t)(C4(ps0 + filter2) + 128);
        if (!hevMask) {
            const int fr = av1g_round2(filter1, 1);
            q0p[step] = (uint8_t)(C4(qs1 - fr) + 128);
            q0p[-2 * step] = (uint8_t)(C4(ps1 + fr) + 128);
        }
#undef C4
        return;
    }
    /* wide filter (7.14.6.4) */
    const int log2Size = (filterSize == 8 || !flatMask2) ? 3 : 4;
    const int n = log2Size == 4 ? 6 : plane == 0 ? 3 : 2;
    const int n2 = (log2Size == 3 && plane == 0) ? 0 : 1;
    AV1G_PF_STAT(n == 6 ? AV1G_PF_LF_WIDE16 : n == 3 ? AV1G_PF_LF_WIDE8 : AV1G_PF_LF_WIDE6);
    int F[12];
    for (int i = -n; i < n; i++) {
        int t = 0;
        for (int j = -n; j <= n; j++) {
            const int p = av1g_clip3(-(n + 1), n, i + j);
            t += S_(p) * (av1g_iabs(j) <= n2 ? 2 : 1);
        }
        F[i + n] = av1g_round2(t, log2Size);
    }
    for (int i = -n; i < n; i++) q0p[i * step] = (uint8_t)F[i + n];
#undef S_
}

/* Edge loop filter process (7.14.2): plane, pass, luma 4x4 position (row, col) - the 4
 * lines of one edge segment.  Callers visit row/col in steps of 2 for chroma. */
AV1G_HD void av1g_lf_edge(const av1g_pf_frame *f, int plane, int pass, int row, int col) {
    const int sub = plane ? 1 : 0;
    const int x = col * 4, y = row * 4;
    if (x >= f->W || y >= f->H) return;
    if (pass == 0 && x == 0) return;
    if (pass == 1 && y == 0) return;
    row |= sub;
    col |= sub;
    const int xP = x >> sub, yP = y >> sub;
    const int prevRow = row - ((pass == 1) << sub), prevCol = col - ((pass == 0) << sub);
    const int s = f->MiCols >> sub;
    const int txSz = f->lfTx[plane][(size_t)(row >> sub) * s + (col >> sub)];
    const int prevTxSz = f->lfTx[plane][(size_t)(prevRow >> sub) * s + (prevCol >> sub)];
    /* intra frame: applyFilter = isTxEdge (isIntra = 1), so MiSize / skip do not matter */
    int cur, prev;
    if (pass == 0) {
        cur = AV1G_T(Tx_Width)[txSz];
        prev = AV1G_T(Tx_Width)[prevTxSz];
        if (xP & (cur - 1)) return;
    } else {
        cur = AV1G_T(Tx_Height)[txSz];
        prev = AV1G_T(Tx_Height)[prevTxSz];
        if (yP & (cur - 1)) return;
    }
    const int baseSize = prev < cur ? prev : cur;
    const int cap = plane ? 8 : 16;
    const int filterSize = baseSize < cap ? baseSize : cap;
    /* frame-level levels: the re-evaluation at (prevRow, prevCol) when lvl == 0 gives the same value */
    const int lvl = f->lfLevel[plane == 0 ? pass : plane + 1];
    if (lvl == 0) return;
    const int shift = f->sharpness > 4 ? 2 : f->sharpness > 0 ? 1 : 0;
    const int limit = f->sharpness > 0 ? av1g_clip3(1, 9 - f->sharpness, lvl >> shift) : ((lvl >> shift) > 1 ? lvl >> shift : 1);
    const int blimit = 2 * (lvl + 2) + limit, thresh = lvl >> 4;
    uint8_t *pl = f->plane[plane];
    const int st = f->stride[plane];
    const ptrdiff_t step = pass == 0 ? 1 : st;
    for (int i = 0; i < 4; i++) {
        uint8_t *q0 = pl + (size_t)(yP + (pass == 0) * i) * st + xP + (pass == 1) * i;
        av1g_lf_line(q0, step, plane, filterSize, limit, blimit, thresh);
    }
}

/* Whole-frame deblocking in the spec's order (host reference). */
AV1G_HD void av1g_deblock_frame(const av1g_pf_frame *f) {
    if (!f->lfLevel[0] && !f->lfLevel[1]) return;
    for (int p = 0; p < (f->mono ? 1 : 3); p++) {
        if (p > 0 && !f->lfLevel[1 + p]) continue;
        const int step = p ? 2 : 1;
        for (int pass = 0; pass < 2; pass++)
            for (int row = 0; row < f->MiRows; row += step)
                for (int col = 0; col < f->MiCols; col += step) av1g_lf_edge(f, p, pass, row, col);
    }
}

/* ---------------- CDEF ---------------- */
AV1G_HD int av1g_floor_log2(uint32_t x) {  /* FloorLog2; -1 for 0 */
#ifdef __CUDA_ARCH__
    return 31 - __clz((int)x);
#else
    return x ? 31 - __builtin_clz(x) : -1;
#endif
}

/* CDEF direction process (7.15.2) for the 8x8 luma block at src */
AV1G_HD void av1g_cdef_direction(const uint8_t *src, int stride, int *yDir, int *var) {
    int cost[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    int partial[8][15];
    for (int i = 0; i < 8; i++)
        for (int j = 0; j < 15; j++) partial[i][j] = 0;
    for (int i = 0; i < 8; i++)
        for (int j = 0; j < 8; j++) {
            const int x = src[i * stride + j] - 128;
            partial[0][i + j] += x;
            partial[1][i + j / 2] += x;
            partial[2][i] += x;
            partial[3][3 + i - j / 2] += x;
            partial[4][7 + i - j] += x;
            partial[5][3 - i / 2 + j] += x;
            partial[6][j] += x;
            partial[7][i / 2 + j] += x;
        }
    const int Div[9] = {0, 840, 420, 280, 210, 168, 140, 120, 105};  /* Div_Table (7.15.2) */
    for (int i = 0; i < 8; i++) {
        cost[2] += partial[2][i] * partial[2][i];
        cost[6] += partial[6][i] * partial[6][i];
    }
    cost[2] *= Div[8];
    cost[6] *= Div[8];
    for (int i = 0; i < 7; i++) {
        cost[0] += (partial[0][i] * partial[0][i] + partial[0][14 - i] * partial[0][14 - i]) * Div[i + 1];
        cost[4] += (partial[4][i] * partial[4][i] + partial[4][14 - i] * partial[4][14 - i]) * Div[i + 1];
    }
    cost[0] += partial[0][7] * partial[0][7] * Div[8];
    cost[4] += partial[4][7] * partial[4][7] * Div[8];
    for (int i = 1; i < 8; i += 2) {
        for (int j = 0; j < 4 + 1; j++) cost[i] += partial[i][3 + j] * partial[i][3 + j];
        cost[i] *= Div[8];
        for (int j = 0; j < 4 - 1; j++)
            cost[i] += (partial[i][j] * partial[i][j] + partial[i][10 - j] * partial[i][10 - j]) * Div[2 * j + 2];
    }
    int bestCost = 0, d = 0;
    for (int i = 0; i < 8; i++)
        if (cost[i] > bestCost) { bestCost = cost[i]; d = i; }
    *yDir = d;
    *var = (bestCost - cost[(d + 4) & 7]) >> 10;
}

/* constrain() of 7.15.3 with dampingAdj = Max(0, damping - FloorLog2(threshold)) precomputed */
AV1G_HD int av1g_cdef_constrain_adj(int diff, int threshold, int dampingAdj) {
    if (!threshold) return 0;
    const int a = av1g_iabs(diff);
    const int v = av1g_clip3(0, a, threshold - (a >> dampingAdj));
    return diff < 0 ? -v : v;
}
AV1G_HD int av1g_cdef_damping_adj(int threshold, int damping) {
    const int d = threshold ? damping - av1g_floor_log2((uint32_t)threshold) : 0;
    return d > 0 ? d : 0;
}
AV1G_HD int av1g_cdef_constrain(int diff, int threshold, int damping) {
    return av1g_cdef_constrain_adj(diff, threshold, av1g_cdef_damping_adj(threshold, damping));
}

/* Per-8x8 CDEF parameters (7.15.1).  filtered == 0: the block is copied unchanged. */
typedef struct av1g_cdef_blk {
    int filtered;
    int yPri, ySec, yDir, uvPri, uvSec, uvDir;
} av1g_cdef_blk;

/* cdef_idx of the 8x8 block at luma 4x4 position (r, c) (even), or -1 when CDEF leaves it
 * unchanged (no CDEF in its 64x64, or all four 4x4s skipped). */
AV1G_HD int av1g_cdef_active_idx(const av1g_pf_frame *f, int r, int c) {
    const int idx = f->cdefIdx[(size_t)(r >> 4) * f->sbCols + (c >> 4)];
    if (idx < 0) return -1;
    const uint8_t *sk = f->skip;
    const size_t mc = (size_t)f->MiCols;
    if (sk[r * mc + c] && sk[(r + 1) * mc + c] && sk[r * mc + c + 1] && sk[(r + 1) * mc + c + 1]) return -1;
    return idx;
}

/* Strengths / directions of an active block from its direction-process outputs (7.15.1). */
AV1G_HD av1g_cdef_blk av1g_cdef_params(const av1g_pf_frame *f, int idx, int yDir, int var) {
    av1g_cdef_blk o;
    o.filtered = 1;
    const int pri = f->cdefYPri[idx];
    o.yDir = pri == 0 ? 0 : yDir;
    int varStr = 0;
    if (var >> 6) { varStr = av1g_floor_log2((uint32_t)(var >> 6)); if (varStr > 12) varStr = 12; }
    o.yPri = var ? (pri * (4 + varStr) + 8) >> 4 : 0;
    o.ySec = f->cdefYSec[idx];
    o.uvPri = f->cdefUVPri[idx];
    o.uvSec = f->cdefUVSec[idx];
    o.uvDir = o.uvPri == 0 ? 0 : yDir;  /* Cdef_Uv_Dir[1][1] is the identity (4:2:0) */
    return o;
}

/* r, c: 8x8 block position in luma 4x4 units (even).  src0: deblocked luma plane. */
AV1G_HD av1g_cdef_blk av1g_cdef_setup(const av1g_pf_frame *f, const uint8_t *src0, int stride0, int r, int c) {
    av1g_cdef_blk o = {0, 0, 0, 0, 0, 0, 0};
    const int idx = av1g_cdef_active_idx(f, r, c);
    if (idx < 0) {
        if (f->cdefIdx[(size_t)(r >> 4) * f->sbCols + (c >> 4)] >= 0) AV1G_PF_STAT(AV1G_PF_CDEF_SKIP8X8);
        return o;
    }
    int yDir, var;
    av1g_cdef_direction(src0 + (size_t)(r * 4) * stride0 + c * 4, stride0, &yDir, &var);
    return av1g_cdef_params(f, idx, yDir, var);
}

/* CDEF filter process (7.15.3) for the sample at plane coordinates (x, y) of the deblocked
 * plane src.  damping: CdefDamping for luma, CdefDamping - 1 for chroma. */
AV1G_HD int av1g_cdef_pixel(const av1g_pf_frame *f, const uint8_t *src, int sstride, int plane, int x, int y, int priStr,
                            int secStr, int damping, int dir) {
    const int sub = plane ? 1 : 0;
    const int8_t Dirs[8][2][2] = {{{-1, 1}, {-2, 2}}, {{0, 1}, {-1, 2}}, {{0, 1}, {0, 2}}, {{0, 1}, {1, 2}},  /* Cdef_Directions */
                                  {{1, 1}, {2, 2}},   {{1, 0}, {2, 1}},  {{1, 0}, {2, 0}}, {{1, 0}, {2, -1}}};
    const int8_t PriTaps[2][2] = {{4, 2}, {3, 3}}, SecTaps[2] = {2, 1};  /* Cdef_Pri_Taps / Cdef_Sec_Taps */
    const int x0v = src[(size_t)y * sstride + x];
    const int priAdj = av1g_cdef_damping_adj(priStr, damping), secAdj = av1g_cdef_damping_adj(secStr, damping);
    int sum = 0, mx = x0v, mn = x0v;
    for (int k = 0; k < 2; k++)
        for (int sign = -1; sign <= 1; sign += 2)
            for (int t = 0; t < 3; t++) {  /* t = 0: primary tap (dir), 1/2: secondary (dir - 2, dir + 2) */
                const int dd = t == 0 ? dir : (dir + (t == 1 ? -2 : 2)) & 7;
                const int yy = y + sign * Dirs[dd][k][0], xx = x + sign * Dirs[dd][k][1];
                /* is_inside_filter_region: the frame (MiRows x MiCols in luma 4x4 units) */
                if (yy < 0 || xx < 0 || ((yy << sub) >> 2) >= f->MiRows || ((xx << sub) >> 2) >= f->MiCols) continue;
                const int p = src[(size_t)yy * sstride + xx];
                if (t == 0) sum += PriTaps[priStr & 1][k] * av1g_cdef_constrain_adj(p - x0v, priStr, priAdj);
                else sum += SecTaps[k] * av1g_cdef_constrain_adj(p - x0v, secStr, secAdj);
                mx = p > mx ? p : mx;
                mn = p < mn ? p : mn;
            }
    const int v = x0v + ((8 + sum - (sum < 0)) >> 4);
    if (v < mn || v > mx) AV1G_PF_STAT(AV1G_PF_CDEF_CLAMPED);
    return av1g_clip3(mn, mx, v);
}

/* CDEF block process (7.15.1) for the 8x8 luma block at 4x4 position (r, c), all planes:
 * source = deblocked frame (f->plane / f->stride), dst = CdefFrame. */
AV1G_HD void av1g_cdef_block(const av1g_pf_frame *f, uint8_t *const dst[3], const int dstride[3], int r, int c) {
    const av1g_cdef_blk o = av1g_cdef_setup(f, f->plane[0], f->stride[0], r, c);
    if (o.filtered) AV1G_PF_STAT(AV1G_PF_CDEF_FILTERED);
    for (int p = 0; p < (f->mono ? 1 : 3); p++) {
        const int sub = p ? 1 : 0, x0 = (c * 4) >> sub, y0 = (r * 4) >> sub, w = 8 >> sub;
        const uint8_t *src = f->plane[p];
        const int ss = f->stride[p];
        for (int i = 0; i < w; i++)
            for (int j = 0; j < w; j++) {
                int v = src[(size_t)(y0 + i) * ss + x0 + j];
                if (o.filtered)
                    v = p == 0 ? av1g_cdef_pixel(f, src, ss, 0, x0 + j, y0 + i, o.yPri, o.ySec, f->cdefDamping, o.yDir)
                               : av1g_cdef_pixel(f, src, ss, p, x0 + j, y0 + i, o.uvPri, o.uvSec, f->cdefDamping - 1, o.uvDir);
                dst[p][(size_t)(y0 + i) * dstride[p] + x0 + j] = (uint8_t)v;
            }
    }
}

/* Whole-frame CDEF (host reference): f->plane = deblocked frame, dst = output frame. */
AV1G_HD void av1g_cdef_frame(const av1g_pf_frame *f, uint8_t *const dst[3], const int dstride[3]) {
    for (int r = 0; r < f->MiRows; r += 2)
        for (int c = 0; c < f->MiCols; c += 2) av1g_cdef_block(f, dst, dstride, r, c);
}

#endif
