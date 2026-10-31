// CPU reference decision engine for av1core tests (valid + reasonable, not good).
//
//  1. pre-pass, per 64x64 superblock, open loop on SOURCE pixels (threads over SBs):
//     top-down partition search (NONE vs SPLIT, square blocks min_block..64) with a
//     Hadamard-domain RD proxy; luma mode = best of 13 modes, then angle-delta
//     refinement of the best directional mode; chroma mode = best of 13 modes + CFL
//     (least-squares alpha).  tx_depth 0 (TX_MODE_LARGEST).
//  2. closed loop through av1core's TxbHook: for every tx block the exact
//     prediction is available; residual -> forward transform (derived numerically
//     from av1core's exact inverse 1-D transforms) -> plain rounding quantization.
//     Luma tx type = argmin over the intra set of exact SSE + lambda * rate proxy.
//  3. blocks whose tx blocks are all zero get skip = 1 and the record is re-encoded
//     (reconstruction is unchanged; checked).
#include "tools.h"
#include "av1g/internal.h"
#include "av1g/blockinfo.h"
#include "av1g/dsp.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <thread>

namespace av1g {

void OwnedRecord::bind() {
    rec.n_blocks = (uint32_t)blocks.size();
    rec.n_txb = (uint32_t)txb.size();
    rec.blocks = blocks.data();
    rec.block_txb = block_txb.data();
    rec.txb = txb.data();
    rec.coeffs = coeffs.data();
}

int OwnedRecord::layout() {
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

namespace {

// ---------------------------------------------------------------------------
// forward transforms derived from the exact inverse
// ---------------------------------------------------------------------------
struct FwdTx {
    // F[kind][log2n] = inverse of the n x n matrix of the 1-D inverse transform
    std::vector<double> F[3][7];
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

void pad_source(const Image &img, int sbCols, int sbRows, Src &s) {
    for (int pl = 0; pl < (img.mono ? 1 : 3); pl++) {
        const int sub = pl ? 1 : 0;
        s.stride[pl] = (sbCols * 64) >> sub;
        s.height[pl] = (sbRows * 64) >> sub;
        s.p[pl].resize((size_t)s.stride[pl] * s.height[pl]);
        const int w = img.w(pl), h = img.h(pl);
        for (int y = 0; y < s.height[pl]; y++) {
            const uint8_t *srow = img.p[pl].data() + (size_t)(y < h ? y : h - 1) * w;
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
    const RefEngineOpts &o;
    int MiCols, MiRows, mono;
    Proxy luma, chroma;
    int tx0, ty0;  // tile origin (luma pixels)
    const std::vector<uint8_t> *sbq = nullptr;  // per-SB qindex (delta-q), raster over the SB grid
    int sbCols = 0;

    Decider(const Src &s, const RefEngineOpts &op, int mc, int mr, int mn, double stepY, double stepC)
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
    const RefEngineOpts &o;
    int reduced;
    double lambda[3];
    QuantHook(const Src &s, const RefEngineOpts &op, double lY, double lC) : src(s), o(op), reduced(op.reduced_tx_set) {
        lambda[0] = lY; lambda[1] = lambda[2] = lC;
    }

    // quantize + exact reconstruction SSE + rate proxy for one tx type
    double trial(const int *res, int txSz, int type, int dcQ, int acQ, int16_t *q, const uint8_t *pred, int pstride,
                 const uint8_t *s, int sstride, int plane, int qmLevel) const {
        const int n = av1g_tx_coeffs(txSz);
        const int tw = std::min(32, av1g_tx_w(txSz));
        static thread_local double D[1024];
        fwd().forward(res, txSz, type, D);
        const int den = av1g_dq_denom(txSz);
        const uint8_t *qm = av1g_qm(1, qmLevel, plane, txSz, type);  // NULL for level 15 / IDTX-class types
        const double lambda = 0.12 * (acQ / 8.0) * (acQ / 8.0);       // follows the block's (delta-q) quantizer
        int nz = 0;
        for (int i = 0; i < n; i++) {
            double v = D[i] * den / av1g_qm_step(i == 0 ? dcQ : acQ, qm, i);
            int qi = (int)floor(fabs(v) + 0.5);
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

int ref_engine_encode(const Image &img, const RefEngineOpts &o, OwnedRecord &R, av1g_output *out,
                      RefEngineStats *stats, std::string &err) {
    using clk = std::chrono::steady_clock;
    auto t0 = clk::now();
    memset(&R.rec, 0, sizeof R.rec);
    av1g_frame_params &fp = R.rec.fp;
    fp.version = AV1G_DECISIONS_VERSION;
    fp.width = img.W;
    fp.height = img.H;
    fp.monochrome = (uint8_t)img.mono;
    fp.base_q_idx = (uint8_t)o.qindex;
    fp.tx_mode_select = 0;
    fp.reduced_tx_set = (uint8_t)o.reduced_tx_set;
    fp.tile_cols_log2 = -1;
    fp.tile_rows_log2 = -1;
    if (o.qm_level >= 0 || o.qm_level == -2) {
        const int lv = o.qm_level == -2 ? av1g_qm_level_allintra(o.qindex) : o.qm_level;
        fp.using_qmatrix = 1;
        fp.qm_y = (uint8_t)lv;
        fp.qm_u = fp.qm_v = (uint8_t)(o.qm_level_uv >= 0 ? o.qm_level_uv : lv);
    }
    fp.enable_intra_edge_filter = o.edge_filter ? 1 : 0;
    if (o.lf_level > 0) {
        for (int i = 0; i < 4; i++) fp.loop_filter_level[i] = (uint8_t)std::min(63, o.lf_level);
        fp.loop_filter_sharpness = (uint8_t)o.lf_sharpness;
    }
    if (o.cdef) {  // cdef_idx stays 0 in every block: one preset
        fp.enable_cdef = 1;
        fp.cdef_damping_minus_3 = (uint8_t)(o.cdef_damping - 3);
        fp.cdef_bits = 0;
        fp.cdef_y_pri[0] = (uint8_t)o.cdef_y_pri;
        fp.cdef_y_sec[0] = (uint8_t)o.cdef_y_sec;
        fp.cdef_uv_pri[0] = (uint8_t)o.cdef_uv_pri;
        fp.cdef_uv_sec[0] = (uint8_t)o.cdef_uv_sec;
    }
    const int MiCols = av1g_mi_cols(img.W), MiRows = av1g_mi_rows(img.H);
    const int sbCols = (MiCols + 15) >> 4, sbRows = (MiRows + 15) >> 4;
    Src src;
    pad_source(img, sbCols, sbRows, src);
    av1g_tiles tiles;
    av1g_tile_layout(img.W, img.H, -1, -1, &tiles);
    // pixel-domain quantizer steps (Ac_Qlookup is 8x the orthonormal step)
    const double stepY = av1g_ac_q(o.qindex) / 8.0, stepC = av1g_ac_q(o.qindex) / 8.0;
    Decider dec(src, o, MiCols, MiRows, img.mono, stepY, stepC);
    // ---- delta-q: per-SB qindex from luma activity (log2 mean 8x8 variance vs frame mean) ----
    std::vector<uint8_t> sbq;
    if (o.deltaq) {
        fp.delta_q_present = 1;
        fp.delta_q_res = (uint8_t)o.deltaq_res;
        std::vector<double> act((size_t)sbCols * sbRows, 0.0);
        double mean = 0;
        int nsb = 0;
        for (int sr = 0; sr < sbRows; sr++)
            for (int sc = 0; sc < sbCols; sc++) {
                double v = 0;
                int nb = 0;
                for (int by = sr * 64; by < sr * 64 + 64 && by < MiRows * 4; by += 8)
                    for (int bx = sc * 64; bx < sc * 64 + 64 && bx < MiCols * 4; bx += 8) {
                        double s1 = 0, s2 = 0;
                        for (int y = 0; y < 8; y++)
                            for (int x = 0; x < 8; x++) { double p = src.at(0, bx + x, by + y)[0]; s1 += p; s2 += p * p; }
                        v += s2 / 64 - (s1 / 64) * (s1 / 64);
                        nb++;
                    }
                act[(size_t)sr * sbCols + sc] = log2(1.0 + v / std::max(1, nb));
                mean += act[(size_t)sr * sbCols + sc];
                nsb++;
            }
        mean /= std::max(1, nsb);
        std::vector<uint8_t> target(act.size());
        const int maxOff = std::max(8, o.qindex / 3);
        for (size_t i = 0; i < act.size(); i++) {
            int off = (int)lrint(o.deltaq_strength * (act[i] - mean));
            off = std::max(-maxOff, std::min(maxOff, off));
            target[i] = (uint8_t)std::max(1, std::min(255, o.qindex + off));
        }
        sbq.resize(target.size());
        av1g_legalize_sb_qindex(o.qindex, o.deltaq_res, target.data(), target.size(), sbq.data());
        dec.sbq = &sbq;
        dec.sbCols = sbCols;
    }

    // ---- pre-pass: superblocks in decode order, decided in parallel ----
    struct SbJob { int r, c, tx0, ty0; };
    std::vector<SbJob> jobs;
    for (uint32_t tr = 0; tr < tiles.rows; tr++)
        for (uint32_t tc = 0; tc < tiles.cols; tc++)
            for (uint32_t r = tiles.mi_row_starts[tr]; r < tiles.mi_row_starts[tr + 1]; r += 16)
                for (uint32_t c = tiles.mi_col_starts[tc]; c < tiles.mi_col_starts[tc + 1]; c += 16)
                    jobs.push_back({(int)r, (int)c, (int)tiles.mi_col_starts[tc] * 4, (int)tiles.mi_row_starts[tr] * 4});
    std::vector<std::vector<av1g_block>> sbBlocks(jobs.size());
    std::atomic<size_t> next{0};
    const int nthreads = std::max(1, std::min(4, (int)std::thread::hardware_concurrency()));
    auto work = [&]() {
        Decider d = dec;
        for (;;) {
            size_t i = next.fetch_add(1);
            if (i >= jobs.size()) break;
            d.tx0 = jobs[i].tx0;
            d.ty0 = jobs[i].ty0;
            d.node(jobs[i].r, jobs[i].c, 6, sbBlocks[i]);
        }
    };
    std::vector<std::thread> th;
    for (int i = 0; i < nthreads; i++) th.emplace_back(work);
    for (auto &t : th) t.join();
    R.blocks.clear();
    for (auto &v : sbBlocks) R.blocks.insert(R.blocks.end(), v.begin(), v.end());
    if (R.layout() != AV1G_OK) { err = "layout failed"; return AV1G_ERR_INTERNAL; }
    auto t1 = clk::now();

    // ---- closed loop ----
    QuantHook hook(src, o, 0.12 * stepY * stepY, 0.12 * stepC * stepC);
    // pre-filter (padded) recon in both passes: skip flags legitimately change CDEF's output
    av1g_encode_opts eo = {AV1G_ENC_FIX_RANGE | AV1G_ENC_PREFILTER_RECON, -1};
    av1g_output o1;
    int rc = encode_with_hook(&R.rec, &eo, &o1, &hook);
    if (rc != AV1G_OK) { err = o1.error; return rc; }
    // ---- skip pass ----
    uint32_t nskip = 0, ncfl = 0;
    for (uint32_t b = 0; b < R.rec.n_blocks; b++) {
        bool zero = true;
        for (uint32_t t = R.block_txb[b]; t < R.block_txb[b + 1]; t++) zero &= R.txb[t].eob == 0;
        if (zero) { R.blocks[b].skip = 1; nskip++; }
        if (R.blocks[b].uv_mode == AV1G_UV_CFL_PRED && av1g_has_chroma(R.blocks[b].bsize, R.blocks[b].mi_row, R.blocks[b].mi_col, img.mono)) ncfl++;
    }
    eo.flags = AV1G_ENC_AVIF | AV1G_ENC_PREFILTER_RECON;
    rc = av1g_encode(&R.rec, &eo, out);
    if (rc != AV1G_OK) { err = out->error; av1g_output_free(&o1); return rc; }
    for (int p = 0; p < (img.mono ? 1 : 3); p++)
        if (memcmp(o1.recon[p], out->recon[p], (size_t)out->recon_w[p] * out->recon_h[p]) != 0) {
            err = "internal: skip pass changed the reconstruction";
            av1g_output_free(&o1);
            return AV1G_ERR_INTERNAL;
        }
    av1g_output_free(&o1);
    {  // decoder output = post-filtered, cropped
        uint8_t *planes[3] = {out->recon[0], out->recon[1], out->recon[2]};
        int strides[3] = {(int)out->recon_w[0], (int)out->recon_w[1], (int)out->recon_w[2]};
        if (av1g_postfilter(&R.rec, planes, strides) != AV1G_OK) { err = "postfilter failed"; return AV1G_ERR_INTERNAL; }
        for (int p = 0; p < (img.mono ? 1 : 3); p++) {
            const int w = p ? (img.W + 1) >> 1 : img.W, h = p ? (img.H + 1) >> 1 : img.H;
            uint8_t *c = (uint8_t *)malloc((size_t)w * h);
            for (int y = 0; y < h; y++) memcpy(c + (size_t)y * w, out->recon[p] + (size_t)y * out->recon_w[p], (size_t)w);
            free(out->recon[p]);
            out->recon[p] = c;
            out->recon_w[p] = (uint32_t)w;
            out->recon_h[p] = (uint32_t)h;
        }
    }
    auto t2 = clk::now();
    if (stats) {
        stats->seconds_decide = std::chrono::duration<double>(t1 - t0).count();
        stats->seconds_encode = std::chrono::duration<double>(t2 - t1).count();
        stats->blocks = R.rec.n_blocks;
        stats->skip_blocks = nskip;
        stats->cfl_blocks = ncfl;
    }
    return AV1G_OK;
}

}  // namespace av1g
