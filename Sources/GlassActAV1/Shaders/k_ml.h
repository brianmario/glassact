// Glass Act: learned pruning of the analysis (research; BENCHMARKS "learned pruning").
//
// A small network per 8x8 cell says which tree level (8, 16, 32 or 64) the full search will
// choose there, from statistics of the cell's four nested nodes. A cell keeps its likeliest levels
// (until all but `eps` of the probability is kept); a node's own shapes (NONE / HORZ / VERT, and
// at 8 the 4x4 split) are searched where any of its cells keeps that level, and skipped
// elsewhere. Every cell keeps a level, so a partition always remains. Edge SBs (not whole) keep
// everything. Weights are trained offline on the full search's choices (ML_FLOATS of them: means,
// deviations, ML_H x ML_NF first layer, ML_H biases, ML_C x ML_H output layer, ML_C biases).
//
// Passes: k_ml_stats (node statistics, every level, a threadgroup per SB), k_ml_cell (the
// network, per cell), k_ml_tree (each 8x8 cell's skip byte per level: GpImage.mlSkip), then for
// the shapes the thread-per-block kernel takes, k_ml_list: the blocks still analyzed,
// front-packed, so its SIMD-groups don't idle on skipped neighbours (a skipped block gets its
// pruned result here).
#pragma once

// tanh of a clamped argument: fast-math tanh overflows to NaN (inf / inf) for large ones, which
// would leave a cell or node keeping nothing
#define ML_TANH(a) tanh(clamp((a), -15.f, 15.f))

#define ML_PF 8
#define ML_NF (4 * ML_PF + 1)
#define ML_H 24
#define ML_C 4
#define ML_FLOATS (2 * ML_NF + ML_H * ML_NF + ML_H + ML_C * ML_H + ML_C)
// The mode model: per whole node, its statistics, its gradients' orientations (ML_OB bins), its
// level (one-hot) and a bias; ML_MODE_H hidden; the 13 luma modes. A node keeps its likeliest
// modes until all but its eps of the probability is kept, and the analysis screens only those for
// the node's own blocks (k_analysis*.h, ml_mode_mask).
#define ML_OB 8
#define ML_STRIDE (ML_PF + ML_OB)  // a node's record in the statistics buffer
#define ML_MODE_NF (ML_PF + ML_OB + 4 + 1)
#define ML_MODE_H 24
#define ML_MODES 13
#define ML_MODE_FLOATS (2 * ML_MODE_NF + ML_MODE_H * ML_MODE_NF + ML_MODE_H + ML_MODES * ML_MODE_H + ML_MODES)
// The chroma model (k_leaf.h, leaf_chroma): per leaf with chroma, for U and V its log variance,
// gradients and squared correlation with luma, the chroma block's log2 size / 10, its luma mode's
// family (one-hot: DC, V, H, smooth, Paeth, another angle) and a bias; ML_CHROMA_H hidden; 8 classes:
// k_leaf's 7 plain modes, then CfL.
#define ML_CHROMA_NF 16
#define ML_CHROMA_H 16
#define ML_CHROMA_C 8
#define ML_CHROMA_FLOATS (2 * ML_CHROMA_NF + ML_CHROMA_H * ML_CHROMA_NF + ML_CHROMA_H + ML_CHROMA_C * ML_CHROMA_H + ML_CHROMA_C)

// A node's statistics as whole-number sums, which a node's four children add up to exactly (with
// the terms their seams add): its sum and sum of squares, its quadrants' (its children's), the
// values it holds (bits) and their range, its neighbour differences across and down, and its
// interior samples' gradient orientations (ML_OB bins of L1 magnitude) and their total.
struct MlSums {
    uint s1, s2, q1[4], q2[4], bits[8], lo, hi, dx, dy, ob[ML_OB], total;
};

// A sample's gradient orientation for the mode model, from central differences: its L1 magnitude
// (0 where flat), and in `bin` the angle mod pi in ML_OB bins.
static inline uint ga_ml_orient(device const uint8_t *p, int sp, thread int &bin) {
    const float gx = (float)p[1] - (float)p[-1], gy = (float)p[sp] - (float)p[-sp];
    const float mag = fabs(gx) + fabs(gy);
    if (mag == 0.f) return 0;
    float ang = atan2(gy, gx);
    if (ang < 0.f) ang += M_PI_F;
    bin = min((int)(ang / M_PI_F * (float)ML_OB), ML_OB - 1);
    return (uint)mag;
}

static inline void ga_ml_sums_clear(thread MlSums &m) {
    m.s1 = m.s2 = m.hi = m.dx = m.dy = m.total = 0;
    m.lo = 255;
    for (int k = 0; k < 4; k++) m.q1[k] = m.q2[k] = 0;
    for (int k = 0; k < 8; k++) m.bits[k] = 0;
    for (int k = 0; k < ML_OB; k++) m.ob[k] = 0;
}

// A node's features (ML_STRIDE floats) from its sums: log variance, the quadrants' least and
// greatest variance, horizontal and vertical activity, log distinct values, log range and the
// activity's direction, then (with the mode model) the orientations as shares.
static inline void ga_ml_features(thread const MlSums &m, int n, float st2, bool orientations, device float *out) {
    const float a = (float)(n * n), mean = (float)m.s1 / a, var = (float)m.s2 / a - mean * mean, qa = a / 4.f;
    float qmin = 1e30f, qmax = 0.f;
    for (int q = 0; q < 4; q++) {
        const float qm = (float)m.q1[q] / qa, v = (float)m.q2[q] / qa - qm * qm;
        qmin = min(qmin, v);
        qmax = max(qmax, v);
    }
    uint distinct = 0;
    for (int k = 0; k < 8; k++) distinct += popcount(m.bits[k]);
    const float dx = (float)m.dx / (a - (float)n), dy = (float)m.dy / (a - (float)n);
    const float range = (float)(m.hi - m.lo);
    auto l = [&](float v) { return log(1.f + max(v, 0.f) / st2); };
    out[0] = l(var);
    out[1] = l(qmin);
    out[2] = l(qmax);
    out[3] = log(1.f + dx * dx / st2);
    out[4] = log(1.f + dy * dy / st2);
    out[5] = log((float)distinct);
    out[6] = l(range * range);
    out[7] = fabs(log((dx + 0.5f) / (dy + 0.5f)));
    if (!orientations) return;  // only the mode model reads them
    for (int k = 0; k < ML_OB; k++) out[ML_PF + k] = m.total > 0 ? (float)m.ob[k] / (float)m.total : 0.f;
}

// The smallest node level (0: 8x8 ... 3: 64x64) holding both of two adjacent SB coordinates a
// and a + 1 (a % 64 < 63), and the smallest level whose node has coordinate a inside its border.
static inline int ga_ml_pair_level(int a) { return (a & 7) != 7 ? 0 : (a & 15) != 15 ? 1 : (a & 31) != 31 ? 2 : 3; }
static inline int ga_ml_inner_level(int a) {
    for (int l = 0; l < 4; l++) {
        const int r = a & ((8 << l) - 1);
        if (r >= 1 && r <= (8 << l) - 2) return l;
    }
    return 4;  // on the SB's own border
}

// One threadgroup of 64 per 64x64 SB, a thread per 8x8 cell. Each sample is visited once: its
// cell's sums take its value; a pair of neighbours goes to the smallest node holding both, and
// a sample's orientation to the smallest node it's inside the border of (above the cells, by
// threadgroup atomics: whole numbers, so the order doesn't matter). A node above the cells is then
// its children's sums with its own seams'. Each whole node inside the visible picture
// (n = 8 << level) gets its features at its level's base, raster within the level's grid.
kernel void k_ml_stats(constant GpBatch &B [[buffer(0)]], device float *stats [[buffer(3)]],
                       constant uint32_t *bases [[buffer(4)]], uint tg [[threadgroup_position_in_grid]],
                       uint t [[thread_position_in_threadgroup]]) {
    device const GpImage &I = B.img[0];
    // with kept analysis, a threadgroup per SB of the stale list (B.sbList)
    const uint sb = B.sbList ? (tg < B.nSbList ? B.sbList[tg] : 0xFFFFFFFFu) : tg;
    if ((int)sb >= I.sbCols * I.sbRows) return;  // (the whole threadgroup)
    if (B.sbKeep && B.sbKeep[I.sbBase + (int)sb]) return;  // kept: its analysis is the last picture's
    // the 85 nodes' sums (cells, then 16, 4, 1), and the seams of the 21 above the cells
    threadgroup MlSums sums[85];
    threadgroup atomic_uint seam[21][2 + ML_OB + 1];  // dx, dy, the bins, their total
    const bool orientations = I.mlModes != nullptr;
    const int sbx = (int)sb % I.sbCols * 64, sby = (int)sb / I.sbCols * 64, sp = I.spitch[0];
    const float step = (float)av1g_ac_q(sb_qindex(I, sbx, sby)) / 8.f, st2 = step * step;
    if (t < 21)
        for (int k = 0; k < 2 + ML_OB + 1; k++) atomic_store_explicit(&seam[t][k], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const int first[4] = {0, 64, 80, 84};
    // a level's node index among the 21 above the cells, from SB coordinates
    auto upper = [&](int l, int x, int y) { const int per = 8 >> l; return first[l] - 64 + (y >> (3 + l)) * per + (x >> (3 + l)); };
    // only whole nodes inside the visible picture count (their samples may still be read)
    const int vw = I.W - sbx, vh = I.H - sby;
    {
        const int cx = (int)t % 8 * 8, cy = (int)t / 8 * 8;
        MlSums m;
        ga_ml_sums_clear(m);
        device const uint8_t *src = I.src[0] + (size_t)(sby + cy) * sp + sbx + cx;
        for (int r = 0; r < 8; r++) {
            device const uint8_t *row = src + (size_t)r * sp;
            const int y = cy + r;
            for (int c = 0; c < 8; c++) {
                const int x = cx + c;
                const uint v = row[c], v2 = v * v;
                m.s1 += v;
                m.s2 += v2;
                const int q = (r >= 4 ? 2 : 0) + (c >= 4 ? 1 : 0);
                m.q1[q] += v;
                m.q2[q] += v2;
                m.bits[v >> 5] |= 1u << (v & 31);
                m.lo = min(m.lo, v);
                m.hi = max(m.hi, v);
                if (x < 63 && x + 1 < vw) {
                    const uint d = (uint)abs((int)row[c + 1] - (int)v);
                    const int l = ga_ml_pair_level(x);
                    if (l == 0) m.dx += d;
                    else if (d) atomic_fetch_add_explicit(&seam[upper(l, x, y)][0], d, memory_order_relaxed);
                }
                if (y < 63 && y + 1 < vh) {
                    const uint d = (uint)abs((int)row[c + sp] - (int)v);
                    const int l = ga_ml_pair_level(y);
                    if (l == 0) m.dy += d;
                    else if (d) atomic_fetch_add_explicit(&seam[upper(l, x, y)][1], d, memory_order_relaxed);
                }
                if (orientations && x + 1 < vw && y + 1 < vh) {
                    const int l = max(ga_ml_inner_level(x), ga_ml_inner_level(y));
                    int k = 0;
                    const uint mag = l < 4 ? ga_ml_orient(row + c, sp, k) : 0;
                    if (mag && l == 0) {
                        m.ob[k] += mag;
                        m.total += mag;
                    } else if (mag) {
                        atomic_fetch_add_explicit(&seam[upper(l, x, y)][2 + k], mag, memory_order_relaxed);
                        atomic_fetch_add_explicit(&seam[upper(l, x, y)][2 + ML_OB], mag, memory_order_relaxed);
                    }
                }
            }
        }
        sums[t] = m;
        if (sbx + cx + 8 <= I.W / 8 * 8 && sby + cy + 8 <= I.H / 8 * 8)
            ga_ml_features(m, 8, st2, orientations, stats + bases[0] + ((sby + cy) / 8 * (I.W / 8) + (sbx + cx) / 8) * ML_STRIDE);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (int level = 1; level < 4; level++) {
        const int n = 8 << level, per = 8 >> level;
        if ((int)t < per * per) {
            const int nx = (int)t % per, ny = (int)t / per, i = first[level] - 64 + (int)t;
            const int cp = per * 2, c0 = first[level - 1] + ny * 2 * cp + nx * 2;
            const int at[4] = {c0, c0 + 1, c0 + cp, c0 + cp + 1};
            MlSums m;
            ga_ml_sums_clear(m);
            for (int k = 0; k < 4; k++) {
                threadgroup const MlSums &c = sums[at[k]];
                m.s1 += c.s1;
                m.s2 += c.s2;
                m.q1[k] = c.s1;
                m.q2[k] = c.s2;
                for (int b = 0; b < 8; b++) m.bits[b] |= c.bits[b];
                m.lo = min(m.lo, c.lo);
                m.hi = max(m.hi, c.hi);
                m.dx += c.dx;
                m.dy += c.dy;
                for (int b = 0; b < ML_OB; b++) m.ob[b] += c.ob[b];
                m.total += c.total;
            }
            m.dx += atomic_load_explicit(&seam[i][0], memory_order_relaxed);
            m.dy += atomic_load_explicit(&seam[i][1], memory_order_relaxed);
            for (int b = 0; b < ML_OB; b++) m.ob[b] += atomic_load_explicit(&seam[i][2 + b], memory_order_relaxed);
            m.total += atomic_load_explicit(&seam[i][2 + ML_OB], memory_order_relaxed);
            sums[first[level] + (int)t] = m;
            const int x0 = sbx + nx * n, y0 = sby + ny * n, cols = I.W / n;
            if (x0 / n < cols && y0 / n < I.H / n)
                ga_ml_features(m, n, st2, orientations, stats + bases[level] + ((y0 / n) * cols + x0 / n) * ML_STRIDE);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

// One thread per 8x8 cell of the padded picture: the levels it keeps (bit L = level L), all four
// outside the whole SBs. Also clears the list counts for k_ml_list.
kernel void k_ml_cell(constant GpBatch &B [[buffer(0)]], device const float *stats [[buffer(3)]],
                      constant uint32_t *bases [[buffer(4)]], device const float *wts [[buffer(5)]],
                      device uint8_t *keep [[buffer(6)]], constant float &eps [[buffer(7)]],
                      device atomic_uint *counts [[buffer(8)]], uint gid [[thread_position_in_grid]]) {
    device const GpImage &I = B.img[0];
    if (gid < GP_NSHAPES) atomic_store_explicit(&counts[gid], 0u, memory_order_relaxed);
    const int cols8 = I.aw / 8, rows8 = I.ah / 8;
    uint g = gid;
    if (B.sbList) {  // with kept analysis, 64 threads per SB of the stale list
        if (gid / 64 >= B.nSbList) return;
        const int sb = (int)B.sbList[gid / 64], k = (int)gid % 64;
        g = (uint)(((sb / I.sbCols) * 8 + k / 8) * cols8 + (sb % I.sbCols) * 8 + k % 8);
    }
    if ((int)g >= cols8 * rows8) return;
    const int cx = (int)g % cols8, cy = (int)g / cols8;
    if (B.sbKeep && B.sbKeep[I.sbBase + (cy / 8) * I.sbCols + cx / 8]) return;  // kept
    if (cx >= (I.W / 64) * 8 || cy >= (I.H / 64) * 8) { keep[g] = 0xF; return; }
    float f[ML_NF];
    for (int lv = 0; lv < 4; lv++) {
        const int n = 8 << lv, cols = I.W / n;
        device const float *s = stats + bases[lv] + ((cy * 8 / n) * cols + cx * 8 / n) * ML_STRIDE;
        for (int k = 0; k < ML_PF; k++) f[lv * ML_PF + k] = s[k];
    }
    f[ML_NF - 1] = 1.f;
    device const float *mu = wts, *sd = wts + ML_NF, *w1 = sd + ML_NF, *b1 = w1 + ML_H * ML_NF, *w2 = b1 + ML_H,
                       *b2 = w2 + ML_C * ML_H;
    float x[ML_NF], h[ML_H], p[ML_C];
    for (int k = 0; k < ML_NF; k++) x[k] = (f[k] - mu[k]) / sd[k];
    for (int j = 0; j < ML_H; j++) {
        float a = b1[j];
        for (int k = 0; k < ML_NF; k++) a += w1[j * ML_NF + k] * x[k];
        h[j] = ML_TANH(a);
    }
    float mx = -1e30f, sum = 0.f;
    for (int c = 0; c < ML_C; c++) {
        float z = b2[c];
        for (int j = 0; j < ML_H; j++) z += w2[c * ML_H + j] * h[j];
        p[c] = z;
        mx = max(mx, z);
    }
    for (int c = 0; c < ML_C; c++) { p[c] = exp(p[c] - mx); sum += p[c]; }
    // the likeliest levels until all but eps of the probability is kept
    uint8_t bits = 0;
    float kept = 0.f;
    for (int i = 0; i < ML_C && kept < (1.f - eps) * sum; i++) {
        int best = -1;
        for (int c = 0; c < ML_C; c++)
            if (!(bits >> c & 1) && (best < 0 || p[c] > p[best])) best = c;
        bits |= (uint8_t)(1 << best);
        kept += p[best];
    }
    keep[g] = bits ? bits : 0xF;  // (never empty)
}

// One thread per 64x64 SB: each node's own shapes are searched where a cell in it keeps the node's
// level; then, top-down, wherever a cell below needs a node to split, every child that has no
// complete partition of its own keeps its own shapes, so each cell's levels stay reachable (a
// SPLIT needs all four children). Writes each 8x8 cell's skip byte per level.
kernel void k_ml_tree(constant GpBatch &B [[buffer(0)]], device const uint8_t *keep [[buffer(6)]],
                      device uint8_t *mask [[buffer(9)]], uint tid [[thread_position_in_grid]]) {
    device const GpImage &I = B.img[0];
    // with kept analysis, a thread per SB of the stale list
    const uint gid = B.sbList ? (tid < B.nSbList ? B.sbList[tid] : 0xFFFFFFFFu) : tid;
    if ((int)gid >= I.sbCols * I.sbRows) return;
    if (B.sbKeep && B.sbKeep[I.sbBase + (int)gid]) return;  // kept
    const int sbx = (int)gid % I.sbCols, sby = (int)gid / I.sbCols, cols8 = I.aw / 8, rows8 = I.ah / 8;
    uint8_t cell[64];
    for (int k = 0; k < 64; k++) {
        const int r = sby * 8 + k / 8, c = sbx * 8 + k % 8;
        cell[k] = r < rows8 && c < cols8 ? keep[r * cols8 + c] : 0xF;
    }
    // nodes by depth d (0: the 64, 3: the 8s), raster within a depth; level L = 3 - d
    const int base[4] = {0, 1, 5, 21};
    bool own[85], below[85], feas[85];
    for (int d = 0; d < 4; d++) {
        const int per = 1 << d, nc = 8 >> d, L = 3 - d;
        for (int t = 0; t < per * per; t++) {
            const int nx = t % per, ny = t / per;
            bool o = false, b = false;
            for (int r = ny * nc; r < ny * nc + nc; r++)
                for (int c = nx * nc; c < nx * nc + nc; c++) {
                    o = o || (cell[r * 8 + c] >> L & 1);
                    b = b || (cell[r * 8 + c] & ((1 << L) - 1));
                }
            own[base[d] + t] = o;
            below[base[d] + t] = b;
        }
    }
    for (int d = 3; d >= 0; d--) {
        const int per = 1 << d;
        for (int t = 0; t < per * per; t++) {
            const int i = base[d] + t, nx = t % per, ny = t / per;
            bool f = own[i];
            if (d < 3) {
                bool all = true;
                for (int k = 0; k < 4; k++) all = all && feas[base[d + 1] + (ny * 2 + k / 2) * per * 2 + nx * 2 + k % 2];
                f = f || all;
            }
            feas[i] = f;
        }
    }
    for (int d = 0; d < 3; d++) {
        const int per = 1 << d;
        for (int t = 0; t < per * per; t++) {
            if (!below[base[d] + t]) continue;
            const int nx = t % per, ny = t / per;
            for (int k = 0; k < 4; k++) {
                const int ci = base[d + 1] + (ny * 2 + k / 2) * per * 2 + nx * 2 + k % 2;
                if (!feas[ci]) { own[ci] = true; feas[ci] = true; }
            }
        }
    }
    for (int k = 0; k < 64; k++) {
        const int r = sby * 8 + k / 8, c = sbx * 8 + k % 8;
        if (r >= rows8 || c >= cols8) continue;
        for (int d = 0; d < 4; d++) {
            const int per = 1 << d, nc = 8 >> d;
            const bool o = own[base[d] + ((k / 8) / nc) * per + (k % 8) / nc];
            mask[(r * cols8 + c) * 4 + (3 - d)] = o ? 0 : 1;
        }
    }
}

// One thread per whole node of the level: the luma modes its own blocks screen (13 bits), on the
// level's grid of whole nodes (GpImage.mlModes from mlModeBase[level]; other nodes screen all).
kernel void k_ml_mode(constant GpBatch &B [[buffer(0)]], constant uint32_t &level [[buffer(2)]],
                      device const float *stats [[buffer(3)]], constant uint32_t &base [[buffer(4)]],
                      device const float *wts [[buffer(5)]], constant float &eps [[buffer(7)]],
                      device uint16_t *modes [[buffer(10)]], uint tid [[thread_position_in_grid]]) {
    device const GpImage &I = B.img[0];
    const int n = 8 << level, cols = I.W / n, rows = I.H / n;
    uint gid = tid;
    if (B.sbList) {  // with kept analysis, the level's nodes of the stale list's SBs
        const int per = 8 >> level;
        if (tid / (per * per) >= B.nSbList) return;
        const int sb = (int)B.sbList[tid / (per * per)], k = (int)tid % (per * per);
        const int nx = (sb % I.sbCols) * per + k % per, ny = (sb / I.sbCols) * per + k / per;
        if (nx >= cols || ny >= rows) return;
        gid = (uint)(ny * cols + nx);
    }
    if ((int)gid >= cols * rows) return;
    if (B.sbKeep && B.sbKeep[I.sbBase + ((int)gid / cols * n >> 6) * I.sbCols + ((int)gid % cols * n >> 6)]) return;  // kept
    float f[ML_MODE_NF];
    device const float *s = stats + base + gid * ML_STRIDE;
    for (int k = 0; k < ML_STRIDE; k++) f[k] = s[k];
    for (int k = 0; k < 4; k++) f[ML_STRIDE + k] = k == (int)level ? 1.f : 0.f;
    f[ML_MODE_NF - 1] = 1.f;
    device const float *mu = wts, *sd = wts + ML_MODE_NF, *w1 = sd + ML_MODE_NF, *b1 = w1 + ML_MODE_H * ML_MODE_NF,
                       *w2 = b1 + ML_MODE_H, *b2 = w2 + ML_MODES * ML_MODE_H;
    float x[ML_MODE_NF], h[ML_MODE_H], p[ML_MODES];
    for (int k = 0; k < ML_MODE_NF; k++) x[k] = (f[k] - mu[k]) / sd[k];
    for (int j = 0; j < ML_MODE_H; j++) {
        float a = b1[j];
        for (int k = 0; k < ML_MODE_NF; k++) a += w1[j * ML_MODE_NF + k] * x[k];
        h[j] = ML_TANH(a);
    }
    float mx = -1e30f, sum = 0.f;
    for (int c = 0; c < ML_MODES; c++) {
        float z = b2[c];
        for (int j = 0; j < ML_MODE_H; j++) z += w2[c * ML_MODE_H + j] * h[j];
        p[c] = z;
        mx = max(mx, z);
    }
    for (int c = 0; c < ML_MODES; c++) { p[c] = exp(p[c] - mx); sum += p[c]; }
    uint bits = 0;
    float kept = 0.f;
    for (int i = 0; i < ML_MODES && kept < (1.f - eps) * sum; i++) {
        int best = -1;
        for (int c = 0; c < ML_MODES; c++)
            if (!(bits >> c & 1) && (best < 0 || p[c] > p[best])) best = c;
        bits |= 1u << best;
        kept += p[best];
    }
    modes[I.mlModeBase[level] + gid] = (uint16_t)(bits ? bits : 0x1FFFu);  // (never empty)
}

// One thread per block of shape `bs` (the thread-per-block kernel's): the blocks it must still
// analyze go to the shape's list (front-packed, any order: each block's result is its own); a
// skipped one gets the result k_analysis_small's prune would give it. Mirrors the kernel's
// checks before the prune, so the results are the same as without the list.
kernel void k_ml_list(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                      constant uint32_t &bs [[buffer(2)]], device atomic_uint *counts [[buffer(8)]],
                      uint tid [[thread_position_in_grid]]) {
    device const GpImage &I = B.img[0];
    const int nbx = I.shNbx[bs], nby = I.shNby[bs];
    const int W = bw_px((int)bs), H = bh_px((int)bs);
    uint gid = tid;
    if (B.sbList) {  // with kept analysis, the stale list's SBs' blocks (as k_analysis_small reads it)
        const uint per = (uint)((64 / W) * (64 / H));
        if (tid / per >= B.nSbList) return;
        const uint sb = B.sbList[tid / per], k = tid % per;
        const int bx = (int)(sb % I.sbCols) * (64 / W) + (int)(k % (64 / W));
        const int by = (int)(sb / I.sbCols) * (64 / H) + (int)(k / (64 / W));
        if (bx >= nbx || by >= nby) return;
        gid = (uint)(by * nbx + bx);
    }
    if ((int)gid >= nbx * nby) return;
    const int x = (int)(gid % nbx) * W, y = (int)(gid / nbx) * H;
    bool analyze = true;
    if (x < I.MiCols * 4 && y < I.MiRows * 4) {
        if (B.sbKeep && B.sbKeep[I.sbBase + (y >> 6) * I.sbCols + (x >> 6)]) return;  // kept: untouched
        device GpInterRes *ir = W >= 8 && H >= 8 && B.inter ? B.inter + I.shOff[bs] + gid : nullptr;  // ga_inter_of's
        const bool zeroInter = ir && P.interSkipsIntra && ir->zero && ir->J < GP_INF;
        const int m = max(W, H), level = m <= 8 ? 0 : m <= 16 ? 1 : m <= 32 ? 2 : 3;
        if (!zeroInter && I.mlSkip[((y >> 3) * I.cols8 + (x >> 3)) * 4 + level]) {
            device GpBlockRes &out = B.blk[I.shOff[bs] + gid];
            ga_merge_inter(out, ir, GP_INF);
            out.ncand = 0;
            analyze = false;
        }
    }
    if (analyze) {
        const uint k = atomic_fetch_add_explicit(&counts[bs], 1u, memory_order_relaxed);
        B.mlList[I.shOff[bs] + k] = gid;
    }
}
