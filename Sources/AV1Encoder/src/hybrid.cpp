// The CPU half of the hybrid encoder (GlassActAV1.AV1HybridEncoder): the closed loop on blocks the
// Metal analysis decided (partition and luma modes). Per block, chroma modes and CfL from the
// source; then av1core's writer with a TxbHook, which gets each tx block's exact prediction and
// chooses its coefficients (the GPU's dead-zone quantizer, luma tx types by exact reconstruction
// error), reconstructing as it goes, tiles on parallel threads; then skip flags for all-zero
// blocks. The caller filters the reconstruction and writes the bitstream.
//
// Glass Act: from av1gpu's CPU reference engine (av1core/src/ref_engine.cpp, BSD-2,
// Sources/AV1Core/LICENSE): its forward transform (here also in float, vectorizable), padded
// source, Hadamard cost proxy, chroma decisions and quantization hook, unchanged otherwise.
#include "av1enc.h"
#include "av1g/av1g.h"
#include "av1g/blockinfo.h"
#include "av1g/dsp.h"
#include "av1g/internal.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace av1g {

namespace {

struct HybridOpts {
    int qindex = 100;
    int min_block = 8, max_block = 64;  // the reference engine's partition search (unused here)
    bool angle_deltas = true;
    bool cfl = true;
    bool tx_types = true;
    int reduced_tx_set = 0;
    double split_bias = 1.0;
    double quant_rnd = 0.375, quant_zbin = 0.656;  // the Metal encoder's dead zone (GpParams rnd, zbin)
    int given_luma_tx = 0;                        // 0: search luma tx types; 1: keep the record's; 2: theirs vs DCT_DCT
};



// ---------------------------------------------------------------------------
// forward transforms derived from the exact inverse
// ---------------------------------------------------------------------------
struct FwdTx {
    // F[kind][log2n] = inverse of the n x n matrix of the 1-D inverse transform
    std::vector<double> F[3][7];
    // Glass Act: the same in float, and transposed (FT[k * n + j] = F[j * n + k]), for forward_f
    std::vector<float> Ff[3][7], FfT[3][7];
    FwdTx() {
        for (int k = 0; k < 3; k++)
            for (int ln = 2; ln <= 6; ln++) {
                if (k == AV1G_K_ADST && ln > 4) continue;
                if (k == AV1G_K_IDT && ln > 5) continue;
                const int n = 1 << ln;
                std::vector<double> M((size_t)n * n);
                const int A = 1 << 14;
                for (int j = 0; j < n; j++) {
                    int32_t T[64] = {0};
                    T[j] = A;
                    uint32_t err = 0;
                    av1g_inv_1d(T, k, ln, 31, &err);
                    for (int i = 0; i < n; i++) M[(size_t)i * n + j] = (double)T[i] / A;
                }
                F[k][ln] = invert(M, n);
                Ff[k][ln].resize((size_t)n * n);
                FfT[k][ln].resize((size_t)n * n);
                for (int i = 0; i < n; i++)
                    for (int j = 0; j < n; j++) {
                        Ff[k][ln][(size_t)i * n + j] = (float)F[k][ln][(size_t)i * n + j];
                        FfT[k][ln][(size_t)j * n + i] = (float)F[k][ln][(size_t)i * n + j];
                    }
            }
    }
    static std::vector<double> invert(std::vector<double> a, int n) {
        std::vector<double> inv((size_t)n * n, 0.0);
        for (int i = 0; i < n; i++) inv[(size_t)i * n + i] = 1.0;
        for (int c = 0; c < n; c++) {
            int p = c;
            for (int r = c + 1; r < n; r++) if (fabs(a[(size_t)r * n + c]) > fabs(a[(size_t)p * n + c])) p = r;
            if (p != c)
                for (int k = 0; k < n; k++) { std::swap(a[(size_t)c * n + k], a[(size_t)p * n + k]); std::swap(inv[(size_t)c * n + k], inv[(size_t)p * n + k]); }
            double d = a[(size_t)c * n + c];
            for (int k = 0; k < n; k++) { a[(size_t)c * n + k] /= d; inv[(size_t)c * n + k] /= d; }
            for (int r = 0; r < n; r++)
                if (r != c) {
                    double f = a[(size_t)r * n + c];
                    if (f != 0.0)
                        for (int k = 0; k < n; k++) { a[(size_t)r * n + k] -= f * a[(size_t)c * n + k]; inv[(size_t)r * n + k] -= f * inv[(size_t)c * n + k]; }
                }
        }
        return inv;
    }
    // residual (h x w, row-major) -> Dequant-domain coefficients (th x tw)
    void forward(const int *res, int txSz, int txType, double *out) const {
        const int lw = AV1G_T(Tx_Width_Log2)[txSz], lh = AV1G_T(Tx_Height_Log2)[txSz];
        const int w = 1 << lw, h = 1 << lh, tw = w > 32 ? 32 : w, th = h > 32 ? 32 : h;
        const int rk = av1g_row_kind(txType), ck = av1g_col_kind(txType);
        const double *Fr = F[rk][lw].data(), *Fc = F[ck][lh].data();
        const int fud = av1g_flip_ud(txType), flr = av1g_flip_lr(txType);
        double rect = (lw - lh == 1 || lh - lw == 1) ? 2896.0 / 4096.0 : 1.0;
        double scale = (double)(1 << (AV1G_T(Transform_Row_Shift)[txSz] + 4)) / rect;
        // tmp = Fc * R  (only th rows needed)
        static thread_local double tmp[64 * 64];
        for (int i = 0; i < th; i++)
            for (int j = 0; j < w; j++) {
                double s = 0;
                for (int k = 0; k < h; k++) {
                    int yy = fud ? h - 1 - k : k, xx = flr ? w - 1 - j : j;
                    s += Fc[(size_t)i * h + k] * res[yy * w + xx];
                }
                tmp[i * w + j] = s;
            }
        for (int i = 0; i < th; i++)
            for (int j = 0; j < tw; j++) {
                double s = 0;
                for (int k = 0; k < w; k++) s += tmp[i * w + k] * Fr[(size_t)j * w + k];
                out[i * tw + j] = s * scale;
            }
    }
};

// Glass Act: forward() in float with the flips applied once and the loops in axpy form, so the
// compiler vectorizes them (the hybrid encoder's closed loop spends most of its time here).
void forward_f(const FwdTx &F, const int *res, int txSz, int txType, float *out) {
    const int lw = AV1G_T(Tx_Width_Log2)[txSz], lh = AV1G_T(Tx_Height_Log2)[txSz];
    const int w = 1 << lw, h = 1 << lh, tw = w > 32 ? 32 : w, th = h > 32 ? 32 : h;
    const int rk = av1g_row_kind(txType), ck = av1g_col_kind(txType);
    const float *FrT = F.FfT[rk][lw].data(), *Fc = F.Ff[ck][lh].data();
    const int fud = av1g_flip_ud(txType), flr = av1g_flip_lr(txType);
    const float rect = (lw - lh == 1 || lh - lw == 1) ? 2896.0f / 4096.0f : 1.0f;
    const float scale = (float)(1 << (AV1G_T(Transform_Row_Shift)[txSz] + 4)) / rect;
    static thread_local float r[64 * 64], tmp[64 * 64];
    for (int i = 0; i < h; i++) {
        const int *src = res + (fud ? h - 1 - i : i) * w;
        float *d = r + i * w;
        if (flr) for (int j = 0; j < w; j++) d[j] = (float)src[w - 1 - j];
        else for (int j = 0; j < w; j++) d[j] = (float)src[j];
    }
    for (int i = 0; i < th; i++) {  // tmp = Fc * r (th rows)
        float *t = tmp + i * w;
        for (int j = 0; j < w; j++) t[j] = 0.f;
        const float *fc = Fc + (size_t)i * h;
        for (int k = 0; k < h; k++) {
            const float c = fc[k];
            if (c == 0.f) continue;
            const float *rk_ = r + k * w;
            for (int j = 0; j < w; j++) t[j] += c * rk_[j];
        }
    }
    for (int i = 0; i < th; i++) {  // out = tmp * Fr^T (tw columns)
        float *o = out + i * tw;
        for (int j = 0; j < tw; j++) o[j] = 0.f;
        const float *t = tmp + i * w;
        for (int k = 0; k < w; k++) {
            const float c = t[k];
            if (c == 0.f) continue;
            const float *ft = FrT + (size_t)k * w;
            for (int j = 0; j < tw; j++) o[j] += c * ft[j];
        }
        for (int j = 0; j < tw; j++) o[j] *= scale;
    }
}

const FwdTx &fwd() {
    static FwdTx f;
    return f;
}

// ---------------------------------------------------------------------------
// padded source
// ---------------------------------------------------------------------------
struct Src {
    int stride[3], height[3];
    std::vector<uint8_t> p[3];
    const uint8_t *at(int pl, int x, int y) const { return p[pl].data() + (size_t)y * stride[pl] + x; }
};

// the source planes (tight: Y W x H, U/V half, rounded up), padded to whole superblocks by edge
// replication; s keeps its capacity from picture to picture
void pad_source(const uint8_t *const planes[3], int W, int H, int sbCols, int sbRows, Src &s) {
    for (int pl = 0; pl < 3; pl++) {
        const int sub = pl ? 1 : 0;
        s.stride[pl] = (sbCols * 64) >> sub;
        s.height[pl] = (sbRows * 64) >> sub;
        s.p[pl].resize((size_t)s.stride[pl] * s.height[pl]);
        const int w = pl ? (W + 1) >> 1 : W, h = pl ? (H + 1) >> 1 : H;
        for (int y = 0; y < s.height[pl]; y++) {
            const uint8_t *srow = planes[pl] + (size_t)(y < h ? y : h - 1) * w;
            uint8_t *d = s.p[pl].data() + (size_t)y * s.stride[pl];
            memcpy(d, srow, w);
            memset(d + w, srow[w - 1], s.stride[pl] - w);
        }
    }
}

// ---------------------------------------------------------------------------
// Hadamard RD proxy
// ---------------------------------------------------------------------------
void hadamard4(int *a, int stride) {
    for (int i = 0; i < 4; i++) {
        int *r = a + i * stride;
        int s0 = r[0] + r[1], s1 = r[0] - r[1], s2 = r[2] + r[3], s3 = r[2] - r[3];
        r[0] = s0 + s2; r[1] = s1 + s3; r[2] = s0 - s2; r[3] = s1 - s3;
    }
    for (int j = 0; j < 4; j++) {
        int *c = a + j;
        int s0 = c[0] + c[stride], s1 = c[0] - c[stride], s2 = c[2 * stride] + c[3 * stride], s3 = c[2 * stride] - c[3 * stride];
        c[0] = s0 + s2; c[stride] = s1 + s3; c[2 * stride] = s0 - s2; c[3 * stride] = s1 - s3;
    }
}

struct Proxy {
    double step, lambda;
    // RD proxy of a residual block (w x h, multiple of 4): orthonormal 4x4 Hadamard
    double cost(const int *res, int w, int h) const {
        static thread_local int tmp[64 * 64];
        memcpy(tmp, res, sizeof(int) * w * h);
        double D = 0, R = 0;
        for (int y = 0; y < h; y += 4)
            for (int x = 0; x < w; x += 4) {
                hadamard4(tmp + y * w + x, w);
                for (int i = 0; i < 4; i++)
                    for (int j = 0; j < 4; j++) {
                        double c = tmp[(y + i) * w + x + j] * 0.25;  // orthonormal
                        double a = fabs(c);
                        if (a < 0.6 * step) D += c * c;
                        else { D += step * step / 12.0; R += 2.0 + 2.0 * log2(a / step + 1.0); }
                    }
            }
        return D + lambda * R;
    }
};

// ---------------------------------------------------------------------------
// pre-pass (open loop on source pixels)
// ---------------------------------------------------------------------------
struct Decider {
    const Src &src;
    const HybridOpts &o;
    int MiCols, MiRows, mono;
    Proxy luma, chroma;
    int tx0, ty0;  // tile origin (luma pixels)
    const std::vector<uint8_t> *sbq = nullptr;  // per-SB qindex (delta-q), raster over the SB grid
    int sbCols = 0;

    Decider(const Src &s, const HybridOpts &op, int mc, int mr, int mn, double stepY, double stepC)
        : src(s), o(op), MiCols(mc), MiRows(mr), mono(mn) {
        luma.step = stepY;
        luma.lambda = 0.12 * stepY * stepY;
        chroma.step = stepC;
        chroma.lambda = 0.12 * stepC * stepC;
    }

    // open-loop prediction of a w x h region at (x,y) of plane pl
    void predict(int pl, int x, int y, int lw, int lh, int mode, int delta, uint8_t *dst) const {
        const int sub = pl ? 1 : 0;
        uint8_t ea[AV1G_EDGE_LEN], el[AV1G_EDGE_LEN];
        uint8_t *A = ea + AV1G_EDGE_OFF, *L = el + AV1G_EDGE_OFF;
        const int haveLeft = x > (tx0 >> sub), haveAbove = y > (ty0 >> sub);
        const int maxX = ((MiCols * 4) >> sub) - 1, maxY = ((MiRows * 4) >> sub) - 1;
        av1g_build_edges(src.p[pl].data(), src.stride[pl], x, y, lw, lh, haveLeft, haveAbove, 0, 0, maxX, maxY, A, L);
        av1g_predict_intra(mode, delta, haveLeft, haveAbove, lw, lh, A, L, dst, 1 << lw);
    }

    double pred_cost(int pl, int x, int y, int lw, int lh, const uint8_t *pred, const Proxy &px) const {
        const int w = 1 << lw, h = 1 << lh;
        static thread_local int res[64 * 64];
        const uint8_t *s = src.at(pl, x, y);
        for (int i = 0; i < h; i++)
            for (int j = 0; j < w; j++) res[i * w + j] = s[i * src.stride[pl] + j] - pred[i * w + j];
        return px.cost(res, w, h);
    }

    // best luma mode for a block; returns J
    double best_luma(int x, int y, int bs, av1g_block &b) const {
        const int lw = AV1G_T(Tx_Width_Log2)[AV1G_T(Max_Tx_Size_Rect)[bs]];
        const int lh = AV1G_T(Tx_Height_Log2)[AV1G_T(Max_Tx_Size_Rect)[bs]];
        uint8_t pred[64 * 64];
        double best = 1e300;
        int bestMode = 0;
        for (int m = 0; m < AV1G_INTRA_MODES; m++) {
            predict(0, x, y, lw, lh, m, 0, pred);
            double J = pred_cost(0, x, y, lw, lh, pred, luma) + luma.lambda * (av1g_is_directional(m) ? 5.5 : 4.0);
            if (J < best) { best = J; bestMode = m; }
        }
        b.y_mode = (uint8_t)bestMode;
        b.angle_delta_y = 0;
        if (o.angle_deltas && av1g_is_directional(bestMode) && bs >= AV1G_BLOCK_8X8) {
            for (int d = -3; d <= 3; d++) {
                if (!d) continue;
                predict(0, x, y, lw, lh, bestMode, d, pred);
                double J = pred_cost(0, x, y, lw, lh, pred, luma) + luma.lambda * 5.5;
                if (J < best) { best = J; b.angle_delta_y = (int8_t)d; }
            }
        }
        return best;
    }

    void best_chroma(int x, int y, int bs, av1g_block &b) const {
        const int ubs = av1g_uv_bsize(bs);
        const int txSz = av1g_uv_tx_size(bs);
        const int lw = AV1G_T(Tx_Width_Log2)[txSz], lh = AV1G_T(Tx_Height_Log2)[txSz];
        // chroma block origin: (MiCol >> 1) * 4 (sub-8x8 blocks carry the chroma of the 8x8 area)
        const int cx = ((x >> 2) >> 1) << 2, cy = ((y >> 2) >> 1) << 2;
        (void)ubs;
        uint8_t pred[2][32 * 32];
        double best = 1e300;
        int bestMode = AV1G_DC_PRED;
        for (int m = 0; m < AV1G_INTRA_MODES; m++) {
            double J = 0;
            for (int pl = 1; pl <= 2; pl++) {
                predict(pl, cx, cy, lw, lh, m, 0, pred[0]);
                J += pred_cost(pl, cx, cy, lw, lh, pred[0], chroma);
            }
            J += chroma.lambda * (av1g_is_directional(m) ? 5.0 : 3.5);
            if (J < best) { best = J; bestMode = m; }
        }
        b.uv_mode = (uint8_t)bestMode;
        b.angle_delta_uv = 0;
        b.cfl_alpha_u = b.cfl_alpha_v = 0;
        if (o.cfl && av1g_cfl_allowed(bs)) {
            // least-squares alpha against source luma (3 fractional bits, as in the spec)
            const int w = 1 << lw, h = 1 << lh;
            static thread_local int L[32 * 32];
            long long sum = 0;
            for (int i = 0; i < h; i++)
                for (int j = 0; j < w; j++) {
                    const uint8_t *s = src.at(0, (cx + j) * 2, (cy + i) * 2);
                    int v = (s[0] + s[1] + s[src.stride[0]] + s[src.stride[0] + 1]) << 1;
                    L[i * w + j] = v;
                    sum += v;
                }
            int avg = (int)((sum + (w * h / 2)) / (w * h));
            int alpha[2];
            double J = chroma.lambda * 8.0;
            for (int pl = 1; pl <= 2; pl++) {
                predict(pl, cx, cy, lw, lh, AV1G_DC_PRED, 0, pred[pl - 1]);
                double num = 0, den = 0;
                for (int i = 0; i < h; i++)
                    for (int j = 0; j < w; j++) {
                        double l = (L[i * w + j] - avg) / 8.0;
                        num += (src.at(pl, cx + j, cy + i)[0] - pred[pl - 1][i * w + j]) * l;
                        den += l * l;
                    }
                int a = den > 0 ? (int)lrint(8.0 * num / den) : 0;
                alpha[pl - 1] = std::max(-16, std::min(16, a));
                for (int i = 0; i < h; i++)
                    for (int j = 0; j < w; j++) {
                        int v = pred[pl - 1][i * w + j] + av1g_round2signed(alpha[pl - 1] * (L[i * w + j] - avg), 6);
                        pred[pl - 1][i * w + j] = (uint8_t)av1g_clip1(v);
                    }
                J += pred_cost(pl, cx, cy, lw, lh, pred[pl - 1], chroma);
            }
            if ((alpha[0] || alpha[1]) && J < best) {
                b.uv_mode = AV1G_UV_CFL_PRED;
                b.cfl_alpha_u = (int8_t)alpha[0];
                b.cfl_alpha_v = (int8_t)alpha[1];
            }
        }
    }

    void leaf(int r, int c, int bs, std::vector<av1g_block> &out) const {
        av1g_block b;
        memset(&b, 0, sizeof b);
        b.mi_row = (uint16_t)r;
        b.mi_col = (uint16_t)c;
        b.bsize = (uint8_t)bs;
        if (sbq) b.sb_qindex = (*sbq)[(size_t)(r >> 4) * sbCols + (c >> 4)];
        best_luma(c * 4, r * 4, bs, b);
        if (av1g_has_chroma(bs, r, c, mono)) best_chroma(c * 4, r * 4, bs, b);
        out.push_back(b);
    }

    static int sq(int log2px) {  // square block size enum for 4..64
        switch (log2px) {
        case 2: return AV1G_BLOCK_4X4;
        case 3: return AV1G_BLOCK_8X8;
        case 4: return AV1G_BLOCK_16X16;
        case 5: return AV1G_BLOCK_32X32;
        default: return AV1G_BLOCK_64X64;
        }
    }

    void node(int r, int c, int log2px, std::vector<av1g_block> &out) const {
        if (r >= MiRows || c >= MiCols) return;
        const int bs = sq(log2px);
        const int half = (1 << log2px) >> 3;  // in 4x4 units
        const int hasRows = (r + half) < MiRows, hasCols = (c + half) < MiCols;
        const int size = 1 << log2px;
        bool split;
        if (log2px == 2) split = false;
        else if (!hasRows || !hasCols || size > o.max_block) split = true;
        else if (size <= o.min_block) split = false;
        else {
            av1g_block tmp;
            memset(&tmp, 0, sizeof tmp);
            double Jn = best_luma(c * 4, r * 4, bs, tmp);
            double Js = 0;
            const int sbs = sq(log2px - 1);
            for (int q = 0; q < 4; q++) {
                int rr = r + (q >> 1) * half, cc = c + (q & 1) * half;
                if (rr < MiRows && cc < MiCols) Js += best_luma(cc * 4, rr * 4, sbs, tmp);
            }
            Js += luma.lambda * 6.0;  // partition + extra mode signalling
            split = Js * o.split_bias < Jn;
        }
        if (!split) { leaf(r, c, bs, out); return; }
        if (log2px == 3) {  // 8x8 -> four 4x4 blocks (PARTITION_SPLIT of an 8x8 node)
            for (int q = 0; q < 4; q++) leaf(r + (q >> 1), c + (q & 1), AV1G_BLOCK_4X4, out);
            return;
        }
        node(r, c, log2px - 1, out);
        node(r, c + half, log2px - 1, out);
        node(r + half, c, log2px - 1, out);
        node(r + half, c + half, log2px - 1, out);
    }
};

// ---------------------------------------------------------------------------
// closed-loop quantization hook
// ---------------------------------------------------------------------------
struct QuantHook : TxbHook {
    const Src &src;
    const HybridOpts &o;
    int reduced;
    double lambda[3];
    QuantHook(const Src &s, const HybridOpts &op, double lY, double lC) : src(s), o(op), reduced(op.reduced_tx_set) {
        lambda[0] = lY; lambda[1] = lambda[2] = lC;
    }

    // quantize + exact reconstruction SSE + rate proxy for one tx type
    double trial(const int *res, int txSz, int type, int dcQ, int acQ, int16_t *q, const uint8_t *pred, int pstride,
                 const uint8_t *s, int sstride, int plane, int qmLevel) const {
        const int n = av1g_tx_coeffs(txSz);
        const int tw = std::min(32, av1g_tx_w(txSz));
        static thread_local float D[1024];
        forward_f(fwd(), res, txSz, type, D);
        const int den = av1g_dq_denom(txSz);
        const uint8_t *qm = av1g_qm(1, qmLevel, plane, txSz, type);  // NULL for level 15 / IDTX-class types
        const double lambda = 0.12 * (acQ / 8.0) * (acQ / 8.0);       // follows the block's (delta-q) quantizer
        int nz = 0;
        for (int i = 0; i < n; i++) {
            const double v = (double)D[i] * den / av1g_qm_step(i == 0 ? dcQ : acQ, qm, i);
            const double a = fabs(v);
            int qi = a < o.quant_zbin ? 0 : (int)floor(a + o.quant_rnd);
            if (qi > 32767) qi = 32767;
            q[i] = (int16_t)(v < 0 ? -qi : qi);
            nz |= q[i];
        }
        (void)tw;
        const int w = av1g_tx_w(txSz), h = av1g_tx_h(txSz);
        double sse = 0, R = 1.0;
        if (nz) {
            static thread_local int32_t dq[1024], rr[4096];
            av1g_dequant(q, dq, txSz, dcQ, acQ, qm);
            uint32_t err = 0;
            av1g_inv_txfm2d(dq, txSz, type, rr, &err);
            if (err) return 1e300;
            const int fud = av1g_flip_ud(type), flr = av1g_flip_lr(type);
            for (int i = 0; i < h; i++)
                for (int j = 0; j < w; j++) {
                    int yy = fud ? h - 1 - i : i, xx = flr ? w - 1 - j : j;
                    int rec = av1g_clip1(pred[yy * pstride + xx] + rr[i * w + j]);
                    int d = s[yy * sstride + xx] - rec;
                    sse += d * d;
                }
            const uint16_t *scan = av1g_get_scan(txSz, type);
            int last = 0;
            for (int c = n - 1; c >= 0; c--) if (q[scan[c]]) { last = c; break; }
            int zeros = 0;
            for (int c = 0; c <= last; c++) {
                int a = q[scan[c]] < 0 ? -q[scan[c]] : q[scan[c]];
                if (a) R += 2 + 2 * floor(log2((double)a));
                else zeros++;
            }
            R += 0.3 * zeros;
        } else {
            for (int i = 0; i < h; i++)
                for (int j = 0; j < w; j++) { int d = s[i * sstride + j] - pred[i * pstride + j]; sse += d * d; }
        }
        return sse + lambda * R;
    }

    void on_txb(const av1g_block &b, uint32_t, av1g_txb &t, int16_t *coeffs, const uint8_t *pred, int pstride,
                int dcQ, int acQ, int derivedTxType, int qmLevel) override {
        const double lam = 0.12 * (acQ / 8.0) * (acQ / 8.0);
        const int plane = t.plane, txSz = t.tx_size;
        const int w = av1g_tx_w(txSz), h = av1g_tx_h(txSz);
        const uint8_t *s = src.at(plane, t.x4 * 4, t.y4 * 4);
        const int sstride = src.stride[plane];
        static thread_local int res[64 * 64];
        for (int i = 0; i < h; i++)
            for (int j = 0; j < w; j++) res[i * w + j] = s[i * sstride + j] - pred[i * pstride + j];
        const int n = av1g_tx_coeffs(txSz);
        if (plane > 0) {
            trial(res, txSz, derivedTxType, dcQ, acQ, coeffs, pred, pstride, s, sstride, plane, qmLevel);
            return;
        }
        const int set = av1g_get_tx_set_intra(txSz, reduced);
        if (o.given_luma_tx) {
            if (!av1g_tx_type_in_set_intra(set, t.tx_type)) t.tx_type = AV1G_DCT_DCT;
            const double J = trial(res, txSz, t.tx_type, dcQ, acQ, coeffs, pred, pstride, s, sstride, 0, qmLevel);
            if (o.given_luma_tx == 2 && t.tx_type != AV1G_DCT_DCT) {
                static thread_local int16_t dct[1024];
                const double lam = 0.12 * (acQ / 8.0) * (acQ / 8.0);
                const double Jd = trial(res, txSz, AV1G_DCT_DCT, dcQ, acQ, dct, pred, pstride, s, sstride, 0, qmLevel);
                if (Jd + lam * 1.0 < J + lam * 3.0) {
                    t.tx_type = AV1G_DCT_DCT;
                    memcpy(coeffs, dct, sizeof(int16_t) * av1g_tx_coeffs(txSz));
                }
            }
            return;
        }
        if (set == AV1G_TX_SET_DCTONLY || !o.tx_types) {
            t.tx_type = AV1G_DCT_DCT;
            trial(res, txSz, AV1G_DCT_DCT, dcQ, acQ, coeffs, pred, pstride, s, sstride, 0, qmLevel);
            return;
        }
        static thread_local int16_t best[1024], cur[1024];
        double bestJ = 1e301;
        int bestType = AV1G_DCT_DCT;
        for (int type = 0; type < AV1G_TX_TYPES; type++) {
            if (!av1g_tx_type_in_set_intra(set, type)) continue;
            double J = trial(res, txSz, type, dcQ, acQ, cur, pred, pstride, s, sstride, 0, qmLevel);
            J += lam * (type == AV1G_DCT_DCT ? 1.0 : 3.0);
            if (J < bestJ) { bestJ = J; bestType = type; memcpy(best, cur, sizeof(int16_t) * n); }
        }
        t.tx_type = (uint8_t)bestType;
        memcpy(coeffs, best, sizeof(int16_t) * n);
    }
};

}  // namespace
}  // namespace av1g

struct av1enc_hybrid {
    av1g::Src src;
    av1g_decision_record rec;
    std::vector<av1g_block> blocks;
    std::vector<uint32_t> block_txb;
    std::vector<av1g_txb> txb;
    std::vector<int16_t> coeffs;
    av1g_output out;
    double seconds[2] = {0, 0};
    av1enc_hybrid() { memset(&rec, 0, sizeof rec); memset(&out, 0, sizeof out); }
    ~av1enc_hybrid() { av1g_output_free(&out); }
    void bind() {
        rec.n_blocks = (uint32_t)blocks.size();
        rec.n_txb = (uint32_t)txb.size();
        rec.blocks = blocks.data();
        rec.block_txb = block_txb.data();
        rec.txb = txb.data();
        rec.coeffs = coeffs.data();
    }
    int layout() {  // av1g_layout into vectors that keep their capacity
        block_txb.assign(blocks.size() + 1, 0);
        rec.n_blocks = (uint32_t)blocks.size();
        rec.blocks = blocks.data();
        rec.block_txb = block_txb.data();
        rec.txb = nullptr;
        av1g_layout(&rec, 0, 0);
        txb.assign(rec.n_txb, av1g_txb());
        coeffs.assign(rec.n_coeffs + 1, 0);
        bind();
        return av1g_layout(&rec, rec.n_txb, rec.n_coeffs);
    }
};

extern "C" av1enc_hybrid *av1enc_hybrid_create(void) { return new av1enc_hybrid(); }
extern "C" void av1enc_hybrid_destroy(av1enc_hybrid *h) { delete h; }

extern "C" int av1enc_hybrid_closed_loop(av1enc_hybrid *h, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                                         uint32_t W, uint32_t H, const av1g_block *given, uint32_t n, int qindex,
                                         int tile_cols_log2, int tile_rows_log2, char *err, size_t errlen) {
    using namespace av1g;
    using clk = std::chrono::steady_clock;
    auto fail = [&](int rc, const std::string &m) {
        if (err && errlen) snprintf(err, errlen, "%s", m.c_str());
        return rc;
    };
    if (!h || !y || !u || !v || !given || !n || W < 1 || H < 1) return fail(AV1G_ERR_INVALID, "bad arguments");
    const auto t0 = clk::now();
    HybridOpts o;
    o.qindex = qindex;
    av1g_output_free(&h->out);
    memset(&h->out, 0, sizeof h->out);
    memset(&h->rec, 0, sizeof h->rec);
    av1g_frame_params &fp = h->rec.fp;
    fp.version = AV1G_DECISIONS_VERSION;
    fp.width = W;
    fp.height = H;
    fp.base_q_idx = (uint8_t)qindex;
    fp.tile_cols_log2 = (int8_t)tile_cols_log2;
    fp.tile_rows_log2 = (int8_t)tile_rows_log2;
    const int MiCols = av1g_mi_cols((int)W), MiRows = av1g_mi_rows((int)H);
    const int sbCols = (MiCols + 15) >> 4, sbRows = (MiRows + 15) >> 4;
    const uint8_t *planes[3] = {y, u, v};
    pad_source(planes, (int)W, (int)H, sbCols, sbRows, h->src);
    av1g_tiles tiles;
    if (av1g_tile_layout(W, H, tile_cols_log2, tile_rows_log2, &tiles) != AV1G_OK) return fail(AV1G_ERR_INVALID, "tiling");
    const double step = av1g_ac_q(qindex) / 8.0;
    Decider dec(h->src, o, MiCols, MiRows, 0, step, step);
    h->blocks.assign(given, given + n);
    {  // chroma from the source, on every core (each block's decision is its own)
        std::atomic<size_t> next{0};
        auto work = [&]() {
            Decider d = dec;
            for (;;) {
                const size_t i = next.fetch_add(64);
                if (i >= h->blocks.size()) break;
                for (size_t k = i; k < std::min(h->blocks.size(), i + 64); k++) {
                    av1g_block &b = h->blocks[k];
                    uint32_t tc = 0, tr = 0;  // the block's tile, for edge availability
                    while (tc + 1 < tiles.cols && tiles.mi_col_starts[tc + 1] <= b.mi_col) tc++;
                    while (tr + 1 < tiles.rows && tiles.mi_row_starts[tr + 1] <= b.mi_row) tr++;
                    d.tx0 = (int)tiles.mi_col_starts[tc] * 4;
                    d.ty0 = (int)tiles.mi_row_starts[tr] * 4;
                    b.uv_mode = AV1G_DC_PRED;
                    b.angle_delta_uv = 0;
                    b.cfl_alpha_u = b.cfl_alpha_v = 0;
                    b.skip = 0;
                    b.tx_depth = 0;
                    b.sb_qindex = (uint8_t)qindex;
                    if (av1g_has_chroma(b.bsize, b.mi_row, b.mi_col, 0)) d.best_chroma(b.mi_col * 4, b.mi_row * 4, b.bsize, b);
                }
            }
        };
        const int nthreads = std::max(1, (int)std::thread::hardware_concurrency());
        std::vector<std::thread> th;
        for (int i = 0; i < nthreads; i++) th.emplace_back(work);
        for (auto &t : th) t.join();
    }
    if (h->layout() != AV1G_OK) return fail(AV1G_ERR_INVALID, "layout");
    const auto t1 = clk::now();
    QuantHook hook(h->src, o, 0.12 * step * step, 0.12 * step * step);
    av1g_encode_opts eo = {AV1G_ENC_FIX_RANGE | AV1G_ENC_PREFILTER_RECON, -1};
    const int rc = encode_with_hook(&h->rec, &eo, &h->out, &hook);
    if (rc != AV1G_OK) return fail(rc, h->out.error);
    for (uint32_t b = 0; b < h->rec.n_blocks; b++) {  // skip flags change no reconstruction before the filters
        bool zero = true;
        for (uint32_t t = h->block_txb[b]; t < h->block_txb[b + 1]; t++) zero &= h->txb[t].eob == 0;
        if (zero) h->blocks[b].skip = 1;
    }
    const auto t2 = clk::now();
    h->seconds[0] = std::chrono::duration<double>(t1 - t0).count();
    h->seconds[1] = std::chrono::duration<double>(t2 - t1).count();
    return AV1G_OK;
}

extern "C" av1g_decision_record *av1enc_hybrid_record(av1enc_hybrid *h) { return &h->rec; }
extern "C" const uint8_t *av1enc_hybrid_recon(const av1enc_hybrid *h, int plane) {
    return plane >= 0 && plane < 3 ? h->out.recon[plane] : nullptr;
}
extern "C" const uint8_t *av1enc_hybrid_source(const av1enc_hybrid *h, int plane, int *stride) {
    if (plane < 0 || plane > 2) return nullptr;
    if (stride) *stride = h->src.stride[plane];
    return h->src.p[plane].data();
}
extern "C" double av1enc_hybrid_seconds(const av1enc_hybrid *h, int which) { return h->seconds[which ? 1 : 0]; }
