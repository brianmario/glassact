// The encoder's derived tables, as Metal source (av1enc.h).
//
// Glass Act: the host half of av1gpu's encoder/src/k_misc.cu gp_init_tables (BSD-2,
// Sources/AV1Core/LICENSE), computed the same way. Upstream copies them into
// mutable __device__ globals; Metal has none, and the kernels are compiled at run
// time anyway, so they become `constant` tables in the source. Floats are written
// as hex literals, so the GPU sees exactly these values.
#include "av1enc.h"
#include "av1enc/gp.h"
#include "av1g/blockinfo.h"
#include "av1g/cdfctx.h"
#include "av1g/dsp.h"

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdlib>
#include <cstring>
#include <string>
#include <type_traits>
#include <vector>

// forward transform matrices: DCT 4..64, ADST 4..16, identity 4..32 (n x n each)
#define GP_FWD_FLOATS ((16 + 64 + 256 + 1024 + 4096) + (16 + 64 + 256) + (16 + 64 + 256 + 1024))

namespace {

std::vector<double> invert(std::vector<double> a, int n) {
    std::vector<double> inv((size_t)n * n, 0.0);
    for (int i = 0; i < n; i++) inv[(size_t)i * n + i] = 1.0;
    for (int c = 0; c < n; c++) {
        int p = c;
        for (int r = c + 1; r < n; r++)
            if (fabs(a[(size_t)r * n + c]) > fabs(a[(size_t)p * n + c])) p = r;
        if (p != c)
            for (int k = 0; k < n; k++) {
                std::swap(a[(size_t)c * n + k], a[(size_t)p * n + k]);
                std::swap(inv[(size_t)c * n + k], inv[(size_t)p * n + k]);
            }
        const double d = a[(size_t)c * n + c];
        for (int k = 0; k < n; k++) { a[(size_t)c * n + k] /= d; inv[(size_t)c * n + k] /= d; }
        for (int r = 0; r < n; r++)
            if (r != c) {
                const double f = a[(size_t)r * n + c];
                if (f != 0.0)
                    for (int k = 0; k < n; k++) {
                        a[(size_t)r * n + k] -= f * a[(size_t)c * n + k];
                        inv[(size_t)r * n + k] -= f * inv[(size_t)c * n + k];
                    }
            }
    }
    return inv;
}

template <typename Arr>
void cost_field(const av1g_cdfs &c, const Arr &field, float *out) {
    typedef typename std::remove_reference<Arr>::type T;
    constexpr size_t L = std::extent<T, std::rank<T>::value - 1>::value;
    const uint16_t *p = (const uint16_t *)&field;
    const size_t off = (size_t)(p - (const uint16_t *)&c);
    const size_t total = sizeof(T) / 2;
    for (size_t b = 0; b < total; b += L)
        for (size_t s = 0; s + 1 < L; s++) {
            const double lo = s ? p[b + s - 1] : 0.0, hi = p[b + s];
            const double pr = std::max((hi - lo) / 32768.0, 1.0 / 32768.0);
            out[off + b + s] = (float)-std::log2(pr);
        }
}

struct Writer {
    std::string s;
    void f(const char *fmt, ...) __attribute__((format(printf, 2, 3))) {
        char buf[256];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(buf, sizeof buf, fmt, ap);
        va_end(ap);
        s += buf;
    }
    void floats(const char *decl, const float *v, size_t n, const char *attr = "") {
        s += "constant float ";
        s += decl;
        s += attr;
        s += " = {";
        for (size_t i = 0; i < n; i++) f(i ? ",%af" : "%af", (double)v[i]);
        s += "};\n";
    }
    void ints(const char *decl, const int *v, size_t n) {
        s += "constant int ";
        s += decl;
        s += " = {";
        for (size_t i = 0; i < n; i++) f(i ? ",%d" : "%d", v[i]);
        s += "};\n";
    }
};

}  // namespace

extern "C" char *av1enc_tables_msl(size_t *length) {
    // forward matrices
    std::vector<float> fwd(GP_FWD_FLOATS, 0.f), fwdT(GP_FWD_FLOATS, 0.f);
    int fwdOff[3][7];
    double norm2[3][7];
    memset(fwdOff, 0, sizeof fwdOff);
    memset(norm2, 0, sizeof norm2);
    size_t at = 0;
    for (int k = 0; k < 3; k++)
        for (int ln = 2; ln <= 6; ln++) {
            if (k == AV1G_K_ADST && ln > 4) continue;
            if (k == AV1G_K_IDT && ln > 5) continue;
            const int n = 1 << ln;
            std::vector<double> M((size_t)n * n);
            const int A = 1 << 14;
            double nn = 0;
            for (int j = 0; j < n; j++) {
                int32_t T[64] = {0};
                T[j] = A;
                uint32_t e = 0;
                av1g_inv_1d(T, k, ln, 31, &e);
                for (int i = 0; i < n; i++) {
                    M[(size_t)i * n + j] = (double)T[i] / A;
                    nn += M[(size_t)i * n + j] * M[(size_t)i * n + j];
                }
            }
            norm2[k][ln] = nn / n;
            std::vector<double> F = invert(M, n);
            fwdOff[k][ln] = (int)at;
            for (size_t i = 0; i < (size_t)n * n; i++) fwd[at + i] = (float)F[i];
            for (int i = 0; i < n; i++)
                for (int j = 0; j < n; j++) fwdT[at + (size_t)j * n + i] = fwd[at + (size_t)i * n + j];
            at += (size_t)n * n;
        }
    if (at != GP_FWD_FLOATS) return nullptr;
    float txg[19][16], txScale[19];
    for (int t = 0; t < 19; t++) {
        const int lw = AV1G_T(Tx_Width_Log2)[t], lh = AV1G_T(Tx_Height_Log2)[t];
        const double rect = (lw - lh == 1 || lh - lw == 1) ? 2896.0 / 4096.0 : 1.0;
        const double s = (double)(1 << (AV1G_T(Transform_Row_Shift)[t] + 4));
        txScale[t] = (float)(s / rect);
        for (int ty = 0; ty < 16; ty++) {
            const int rk = av1g_row_kind(ty), ck = av1g_col_kind(ty);
            double nr = norm2[rk][lw], nc = norm2[ck][lh];
            if (nr == 0 || nc == 0) { txg[t][ty] = 0; continue; }  // illegal combination (e.g. ADST64)
            txg[t][ty] = (float)(rect * rect * nr * nc / (s * s));
        }
    }
    // symbol costs per coefficient q-context
    std::vector<float> costs((size_t)4 * GP_NCDF, 0.f);
    const int qrep[4] = {20, 60, 120, 255};
    float avgY[13], avgPart[5][10], avgSkip0 = 0;
    for (int qc = 0; qc < 4; qc++) {
        av1g_cdfs c;
        av1g_cdfs_init(&c, qrep[qc]);
        float *out = costs.data() + (size_t)qc * GP_NCDF;
#define CF(f) cost_field(c, c.f, out)
        CF(y_mode); CF(uv_mode_cfl_not_allowed); CF(uv_mode_cfl_allowed); CF(angle_delta);
        CF(partition_w8); CF(partition_w16); CF(partition_w32); CF(partition_w64);
        CF(tx_8x8); CF(tx_16x16); CF(tx_32x32); CF(tx_64x64); CF(skip); CF(filter_intra_mode); CF(filter_intra);
        CF(delta_q); CF(delta_lf); CF(delta_lf_multi); CF(intra_tx_set1); CF(intra_tx_set2); CF(cfl_sign); CF(cfl_alpha);
        CF(palette_y_mode); CF(palette_uv_mode); CF(txb_skip); CF(eob_pt_16); CF(eob_pt_32); CF(eob_pt_64); CF(eob_pt_128);
        CF(eob_pt_256); CF(eob_pt_512); CF(eob_pt_1024); CF(eob_extra); CF(dc_sign); CF(coeff_base_eob); CF(coeff_base);
        CF(coeff_br);
#undef CF
        if (qc == 0) {
            for (int m = 0; m < 13; m++) {
                double p = 0;
                for (int a = 0; a < 5; a++)
                    for (int l = 0; l < 5; l++) {
                        const uint16_t *cd = c.y_mode[a][l];
                        p += (cd[m] - (m ? cd[m - 1] : 0)) / 32768.0;
                    }
                avgY[m] = (float)-std::log2(std::max(p / 25.0, 1e-6));
            }
            for (int bsl = 0; bsl < 5; bsl++)
                for (int p = 0; p < 10; p++) avgPart[bsl][p] = 20.f;
            for (int bsl = 1; bsl <= 4; bsl++) {
                const int N = bsl == 1 ? 4 : 10;
                for (int p = 0; p < N; p++) {
                    double pr = 0;
                    for (int ctx = 0; ctx < 4; ctx++) {
                        const uint16_t *cd = bsl == 1 ? c.partition_w8[ctx] : bsl == 2 ? c.partition_w16[ctx]
                                           : bsl == 3 ? c.partition_w32[ctx] : c.partition_w64[ctx];
                        pr += (cd[p] - (p ? cd[p - 1] : 0)) / 32768.0;
                    }
                    avgPart[bsl][p] = (float)-std::log2(std::max(pr / 4.0, 1e-6));
                }
            }
            double ps = 0;
            for (int ctx = 0; ctx < 3; ctx++) ps += c.skip[ctx][0] / 32768.0;
            avgSkip0 = (float)-std::log2(ps / 3.0);
        }
    }
    Writer w;
    w.s.reserve(1 << 20);
    w.s += "// av1enc_tables_msl: the encoder's derived tables (AV1Encoder/src/tables.cpp)\n";
    w.f("#define GP_FWD_FLOATS %d\n", (int)GP_FWD_FLOATS);
    w.floats("g_fwd[GP_FWD_FLOATS]", fwd.data(), fwd.size());
    w.floats("g_fwdT[GP_FWD_FLOATS]", fwdT.data(), fwdT.size(), " __attribute__((aligned(16)))");  // float4 loads
    w.ints("g_fwdOff[3][7]", &fwdOff[0][0], 21);
    w.floats("g_txg[19][16]", &txg[0][0], 19 * 16);
    w.floats("g_txScale[19]", txScale, 19);
    w.f("constant float g_cost[4][%d] = {", (int)GP_NCDF);
    for (size_t i = 0; i < costs.size(); i++) w.f(i ? ",%af" : "%af", (double)costs[i]);
    w.s += "};\n";
    w.floats("g_avgYMode[13]", avgY, 13);
    w.floats("g_avgPart[5][10]", &avgPart[0][0], 50);
    w.f("constant float g_avgSkip0 = %af;\n", (double)avgSkip0);
    char *out = (char *)malloc(w.s.size() + 1);
    if (!out) return nullptr;
    memcpy(out, w.s.c_str(), w.s.size() + 1);
    if (length) *length = w.s.size();
    return out;
}
