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
// Passes: k_ml_stats per level (node statistics), k_ml_cell (the network, per cell), k_ml_node
// per level (each 8x8 cell's skip byte for the level: GpImage.mlSkip), then for the shapes the
// thread-per-block kernel takes, k_ml_list: the blocks still analyzed, front-packed, so its
// SIMD-groups don't idle on skipped neighbours (a skipped block gets its pruned result here).
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

static inline void ga_ml_node_features(device const uint8_t *src, int sp, int x0, int y0, int n, float st2,
                                       device float *out, bool orientations) {
    float s1 = 0.f, s2 = 0.f, dx = 0.f, dy = 0.f, q1[4] = {0, 0, 0, 0}, q2[4] = {0, 0, 0, 0};
    uint bits[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    uint lo = 255, hi = 0;
    const int h2 = n / 2;
    for (int r = 0; r < n; r++) {
        device const uint8_t *row = src + (size_t)(y0 + r) * sp + x0;
        for (int c = 0; c < n; c++) {
            const uint v = row[c];
            const float f = (float)v;
            s1 += f;
            s2 += f * f;
            const int q = (r >= h2 ? 2 : 0) + (c >= h2 ? 1 : 0);
            q1[q] += f;
            q2[q] += f * f;
            bits[v >> 5] |= 1u << (v & 31);
            lo = min(lo, v);
            hi = max(hi, v);
            if (c + 1 < n) dx += fabs((float)row[c + 1] - f);
            if (r + 1 < n) dy += fabs((float)row[c + sp] - f);
        }
    }
    const float a = (float)(n * n), m = s1 / a, var = s2 / a - m * m, qa = a / 4.f;
    float qmin = 1e30f, qmax = 0.f;
    for (int q = 0; q < 4; q++) {
        const float qm = q1[q] / qa, v = q2[q] / qa - qm * qm;
        qmin = min(qmin, v);
        qmax = max(qmax, v);
    }
    uint distinct = 0;
    for (int k = 0; k < 8; k++) distinct += popcount(bits[k]);
    dx /= a - (float)n;
    dy /= a - (float)n;
    const float range = (float)(hi - lo);
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
    // orientations: central differences on the interior samples, the angle mod pi in ML_OB bins,
    // weighted by the L1 magnitude, as shares (all 0 on a flat node)
    float ob[ML_OB] = {0, 0, 0, 0, 0, 0, 0, 0}, total = 0.f;
    for (int r = 1; r < n - 1; r++) {
        device const uint8_t *row = src + (size_t)(y0 + r) * sp + x0;
        for (int c = 1; c < n - 1; c++) {
            const float gx = (float)row[c + 1] - (float)row[c - 1], gy = (float)row[c + sp] - (float)row[c - sp];
            const float mag = fabs(gx) + fabs(gy);
            if (mag == 0.f) continue;
            float ang = atan2(gy, gx);
            if (ang < 0.f) ang += M_PI_F;
            const int k = min((int)(ang / M_PI_F * (float)ML_OB), ML_OB - 1);
            ob[k] += mag;
            total += mag;
        }
    }
    for (int k = 0; k < ML_OB; k++) out[ML_PF + k] = total > 0.f ? ob[k] / total : 0.f;
}

// One thread per whole node of the level (n = 8 << level) inside the visible picture.
kernel void k_ml_stats(constant GpBatch &B [[buffer(0)]], constant uint32_t &level [[buffer(2)]],
                       device float *stats [[buffer(3)]], constant uint32_t &base [[buffer(4)]],
                       uint gid [[thread_position_in_grid]]) {
    const bool orientations = B.img[0].mlModes != nullptr;
    device const GpImage &I = B.img[0];
    const int n = 8 << level, cols = I.W / n, rows = I.H / n;
    if ((int)gid >= cols * rows) return;
    const int x0 = (int)(gid % cols) * n, y0 = (int)(gid / cols) * n;
    const float step = (float)av1g_ac_q(sb_qindex(I, x0, y0)) / 8.f;
    ga_ml_node_features(I.src[0], I.spitch[0], x0, y0, n, step * step, stats + base + gid * ML_STRIDE, orientations);
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
    if ((int)gid >= cols8 * rows8) return;
    const int cx = (int)gid % cols8, cy = (int)gid / cols8;
    if (cx >= (I.W / 64) * 8 || cy >= (I.H / 64) * 8) { keep[gid] = 0xF; return; }
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
    keep[gid] = bits ? bits : 0xF;  // (never empty)
}

// One thread per 64x64 SB: each node's own shapes are searched where a cell in it keeps the node's
// level; then, top-down, wherever a cell below needs a node to split, every child that has no
// complete partition of its own keeps its own shapes, so each cell's levels stay reachable (a
// SPLIT needs all four children). Writes each 8x8 cell's skip byte per level.
kernel void k_ml_tree(constant GpBatch &B [[buffer(0)]], device const uint8_t *keep [[buffer(6)]],
                      device uint8_t *mask [[buffer(9)]], uint gid [[thread_position_in_grid]]) {
    device const GpImage &I = B.img[0];
    if ((int)gid >= I.sbCols * I.sbRows) return;
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
                      device uint16_t *modes [[buffer(10)]], uint gid [[thread_position_in_grid]]) {
    device const GpImage &I = B.img[0];
    const int n = 8 << level, cols = I.W / n, rows = I.H / n;
    if ((int)gid >= cols * rows) return;
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
                      uint gid [[thread_position_in_grid]]) {
    device const GpImage &I = B.img[0];
    const int nbx = I.shNbx[bs], nby = I.shNby[bs];
    if ((int)gid >= nbx * nby) return;
    const int W = bw_px((int)bs), H = bh_px((int)bs);
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
