// Glass Act: learned pruning of the analysis (research; BENCHMARKS "learned pruning").
//
// A small network per tree level (8, 16, 32, 64) reads cheap statistics of a node's luma and
// says whether the search is likely to pick one of the node's own shapes (NONE / HORZ / VERT;
// at 8 also the 4x4 split). Where it isn't, the analysis skips them (prune_flat). Weights are
// trained offline on the full search's own choices: per level ML_NF means, ML_NF deviations,
// ML_H x ML_NF first-layer weights, ML_H biases, ML_H output weights, the output bias.
#pragma once

#define ML_NF 13
#define ML_H 16
#define ML_LEVEL_FLOATS (2 * ML_NF + ML_H * ML_NF + 2 * ML_H + 1)

struct GaNodeStats {
    float s1, s2, dx, dy;
    float q1[4], q2[4];
    uint lo, hi, distinct;
};

static inline GaNodeStats ga_node_stats(device const uint8_t *src, int sp, int x0, int y0, int n) {
    GaNodeStats st = {};
    uint bits[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    st.lo = 255;
    const int h2 = n / 2;
    for (int r = 0; r < n; r++) {
        device const uint8_t *row = src + (size_t)(y0 + r) * sp + x0;
        for (int c = 0; c < n; c++) {
            const uint v = row[c];
            const float f = (float)v;
            st.s1 += f;
            st.s2 += f * f;
            const int q = (r >= h2 ? 2 : 0) + (c >= h2 ? 1 : 0);
            st.q1[q] += f;
            st.q2[q] += f * f;
            bits[v >> 5] |= 1u << (v & 31);
            st.lo = min(st.lo, v);
            st.hi = max(st.hi, v);
            if (c + 1 < n) st.dx += fabs((float)row[c + 1] - f);
            if (r + 1 < n) st.dy += fabs((float)row[c + sp] - f);
        }
    }
    for (int k = 0; k < 8; k++) st.distinct += popcount(bits[k]);
    return st;
}

static inline float ga_node_var(device const uint8_t *src, int sp, int x0, int y0, int n) {
    float s1 = 0.f, s2 = 0.f;
    for (int r = 0; r < n; r++) {
        device const uint8_t *row = src + (size_t)(y0 + r) * sp + x0;
        for (int c = 0; c < n; c++) { const float f = (float)row[c]; s1 += f; s2 += f * f; }
    }
    const float a = (float)(n * n), m = s1 / a;
    return s2 / a - m * m;
}

// One thread per node of the level's grid over the padded picture: writes the node's skip flag
// into byte `level` of every 8x8 cell it holds (4 bytes a cell). A node whose parent leaves the
// visible picture is kept.
kernel void k_ml_prune(constant GpBatch &B [[buffer(0)]], constant GpParams &P [[buffer(1)]],
                       constant uint32_t &level [[buffer(2)]], device const float *wts [[buffer(3)]],
                       device uint8_t *mask [[buffer(4)]], constant float &threshold [[buffer(5)]],
                       uint gid [[thread_position_in_grid]]) {
    device const GpImage &I = B.img[0];
    const int n = 8 << level;
    const int cols = (I.aw + n - 1) / n, rows = (I.ah + n - 1) / n;
    if ((int)gid >= cols * rows) return;
    const int x0 = (int)(gid % cols) * n, y0 = (int)(gid / cols) * n;
    const int pn = n < 64 ? 2 * n : n, px = x0 / pn * pn, py = y0 / pn * pn;
    bool skip = false;
    if (px + pn <= I.W && py + pn <= I.H) {
        device const uint8_t *src = I.src[0];
        const int sp = I.spitch[0];
        const GaNodeStats s = ga_node_stats(src, sp, x0, y0, n);
        const float a = (float)(n * n), m = s.s1 / a, var = s.s2 / a - m * m;
        const float qa = a / 4.f;
        float qv[4];
        for (int q = 0; q < 4; q++) { const float qm = s.q1[q] / qa; qv[q] = s.q2[q] / qa - qm * qm; }
        const float qmin = min(min(qv[0], qv[1]), min(qv[2], qv[3])), qmax = max(max(qv[0], qv[1]), max(qv[2], qv[3]));
        const float qmean = (qv[0] + qv[1] + qv[2] + qv[3]) / 4.f;
        const float pv = n < 64 ? ga_node_var(src, sp, px, py, pn) : var;
        const float step = (float)av1g_ac_q(sb_qindex(I, x0, y0)) / 8.f, st2 = step * step;
        const float dx = s.dx / (a - (float)n), dy = s.dy / (a - (float)n);
        const float range = (float)(s.hi - s.lo);
        auto l = [&](float v) { return log(1.f + max(v, 0.f) / st2); };
        const float f[ML_NF] = {l(var), l(qmin), l(qmax), l(qmean), l(pv), log(1.f + dx * dx / st2), log(1.f + dy * dy / st2),
                                log((float)s.distinct), 0.f, l(range * range), l(qmax) - l(qmin),
                                fabs(log((dx + 0.5f) / (dy + 0.5f))), 1.f};
        device const float *W = wts + level * ML_LEVEL_FLOATS;
        device const float *mu = W, *sd = W + ML_NF, *w1 = W + 2 * ML_NF, *b1 = w1 + ML_H * ML_NF, *w2 = b1 + ML_H;
        const float b2 = w2[ML_H];
        float x[ML_NF];
        for (int k = 0; k < ML_NF; k++) x[k] = (f[k] - mu[k]) / sd[k];
        float z = b2;
        for (int j = 0; j < ML_H; j++) {
            float h = b1[j];
            for (int k = 0; k < ML_NF; k++) h += w1[j * ML_NF + k] * x[k];
            z += w2[j] * tanh(h);
        }
        skip = 1.f / (1.f + exp(-z)) < threshold;
    }
    const int cols8 = I.cols8, c0 = x0 / 8, r0 = y0 / 8, nc = n / 8;
    for (int r = r0; r < r0 + nc && r < I.ah / 8; r++)
        for (int c = c0; c < c0 + nc && c < cols8; c++) mask[(r * cols8 + c) * 4 + level] = skip ? 1 : 0;
}

// After the four levels: an 8x8 cell whose 16, 32 and 64 nodes are all skipped keeps its 8 node,
// so every area keeps a partition the search can choose.
kernel void k_ml_fix(constant GpBatch &B [[buffer(0)]], device uint8_t *mask [[buffer(4)]],
                     uint gid [[thread_position_in_grid]]) {
    device const GpImage &I = B.img[0];
    if ((int)gid >= I.cols8 * (I.ah / 8)) return;
    device uint8_t *m = mask + gid * 4;
    if (m[1] && m[2] && m[3]) m[0] = 0;
}
