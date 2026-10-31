// The host half of the deblocking-level and CDEF-strength search (AV1MetalPostfilter.search,
// Shaders/postfilter.metal): libaom's tune=iq frame decisions, its RD choice of cdef_bits and the
// presets it signals, and a sequential reference of the GPU's joint preset search for the tests.
//
// Glass Act: from av1gpu's av1f/src/lfsearch.cu (BSD-2, Sources/AV1Core/LICENSE), the
// AV1F_LF_FROM_Q + AV1F_CDEF_AOM path (libaom s6: LPF_PICK_FROM_Q, CDEF_FAST_SEARCH_LVL4,
// tune=iq CDEF_ADAPTIVE) with SSE distortion.
#include "av1enc.h"
#include "av1f/tuneiq.h"

#include <cstring>
#include <vector>

extern "C" void av1enc_tuneiq_frame(int base_q_idx, int mono, GaTuneiqFrame *out) {
    av1f_tuneiq_frame t;
    av1f_tuneiq_frame_init(base_q_idx, 1, 1, mono, &t);
    out->lf_level = t.lf_level;
    out->lf_sharpness = t.lf_sharpness;
    out->cdef_damping = t.cdef_damping;
    out->cdef_mode = t.cdef_mode;
    out->rdmult = t.rdmult;
}

extern "C" int av1enc_cdef_bits(const uint64_t *tots, int max_bits, int n_active, int mono, int rdmult) {
    int best = 0;
    double bestRd = 0;
    for (int i = 0; i <= max_bits; i++) {
        const int nb = 1 << i;
        const long long bits = (long long)n_active * i + nb * 6 * (mono ? 1 : 2);
        // libaom's integer RDCOST: ((bits * 512 * rdmult + 256) >> 9) + sse * 16 * 128
        const double rd = (double)((bits * 512 * (long long)rdmult + 256) >> 9) + (double)tots[i] * 2048.0;
        if (i == 0 || rd < bestRd) { bestRd = rd; best = i; }
    }
    return best;
}

extern "C" void av1enc_cdef_presets(const int32_t lev[16], int bits, int cdef_mode, const GaCdefCand *cd,
                                    av1g_frame_params *fp) {
    const int nb = 1 << bits;
    fp->enable_cdef = 1;
    fp->cdef_bits = (uint8_t)bits;
    for (int j = 0; j < 8; j++) fp->cdef_y_pri[j] = fp->cdef_y_sec[j] = fp->cdef_uv_pri[j] = fp->cdef_uv_sec[j] = 0;
    for (int j = 0; j < nb; j++) {
        const int jy = lev[j], juv = lev[8 + j];
        int yp = cd->pri[jy / cd->nsec], ys = cd->sec[jy % cd->nsec];
        int up = cd->pri[juv / cd->nsec], us = cd->sec[juv % cd->nsec];
        if (fp->monochrome) up = us = 0;
        if (cdef_mode == 1) {  // CDEF_ADAPTIVE: halve the signalled values
            auto sig = [](int s) { return s == 4 ? 3 : s; };
            auto app = [](int s) { return s == 3 ? 4 : s; };
            yp >>= 1;
            up >>= 1;
            ys = app(sig(ys) >> 1);
            us = app(sig(us) >> 1);
        }
        fp->cdef_y_pri[j] = (uint8_t)yp;
        fp->cdef_y_sec[j] = (uint8_t)ys;
        fp->cdef_uv_pri[j] = (uint8_t)up;
        fp->cdef_uv_sec[j] = (uint8_t)us;
    }
}

extern "C" void av1enc_cdef_select_cpu(const uint32_t *my, const uint32_t *muv, int nc, int nsb, int mono, int max_bits,
                                       int refine, int fast_mono, int32_t *lev_out, uint64_t *tot_out) {
    const int pairs = mono ? nc : nc * nc;
    int lev[16];
    memset(lev, 0, sizeof lev);
    std::vector<uint64_t> cur((size_t)nsb), tot((size_t)pairs);
    for (int i = 0; i <= max_bits; i++) {
        const int nb = 1 << i;
        const int steps = nb + (fast_mono ? 0 : refine * nb);
        for (int st = 0; st < steps; st++) {
            const int k = st < nb ? st : nb - 1;
            if (st >= nb)
                for (int j = 0; j < nb - 1; j++) { lev[j] = lev[j + 1]; lev[8 + j] = lev[8 + j + 1]; }
            for (int sb = 0; sb < nsb; sb++) {
                uint64_t b = ~0ull;
                for (int g = 0; g < k; g++) {
                    uint64_t c = my[(size_t)sb * nc + lev[g]];
                    if (!mono) c += muv[(size_t)sb * nc + lev[8 + g]];
                    b = c < b ? c : b;
                }
                cur[sb] = b;
            }
            for (int p = 0; p < pairs; p++) {
                const int pj = mono ? p : p / nc, pk = mono ? 0 : p % nc;
                uint64_t t = 0;
                for (int sb = 0; sb < nsb; sb++) {
                    uint64_t c = my[(size_t)sb * nc + pj];
                    if (!mono) c += muv[(size_t)sb * nc + pk];
                    t += c < cur[sb] ? c : cur[sb];
                }
                tot[p] = t;
            }
            int bi = 0;
            for (int q = 1; q < pairs; q++) if (tot[q] < tot[bi]) bi = q;
            lev[k] = mono ? bi : bi / nc;
            lev[8 + k] = mono ? 0 : bi % nc;
            tot_out[i] = tot[bi];
        }
        for (int j = 0; j < 16; j++) lev_out[i * 16 + j] = lev[j];
    }
}
