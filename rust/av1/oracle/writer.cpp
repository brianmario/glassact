// Test shims for the Rust port's writer (src/writer/tests.rs): av1g::encode_with_hook with a
// deterministic test hook, tile skips, per-tile symbol streams and payloads (C++ internals with no
// C API).
#include <cstring>
#include <vector>
#include "av1g/av1g.h"
#include "av1g/blockinfo.h"
#include "av1g/dsp.h"
#include "av1g/internal.h"

namespace {

// Rewrites a tx block's coefficients (and the luma tx type) from a hash of its exact prediction:
// the same function as TestHook in src/writer/tests.rs.
struct TestHook : av1g::TxbHook {
    int mode;  // 1: sparse small levels, 2: also large ones (range repairs)
    explicit TestHook(int m) : mode(m) {}
    void on_txb(const av1g_block &b, uint32_t bi, av1g_txb &t, int16_t *coeffs, const uint8_t *recon, int stride,
                int dcQ, int acQ, int derived, int qmLevel) override {
        const int txSz = t.tx_size, w = av1g_tx_w(txSz), h = av1g_tx_h(txSz), n = av1g_tx_coeffs(txSz);
        uint32_t s = bi * 2654435761u ^ ((uint32_t)t.plane << 7) ^ (uint32_t)dcQ * 31u ^ (uint32_t)acQ * 17u ^
                     (uint32_t)derived * 5u ^ (uint32_t)qmLevel * 3u ^ (uint32_t)b.y_mode * 7u;
        for (int i = 0; i < h; i++)
            for (int j = 0; j < w; j++) s = s * 31u + recon[i * stride + j];
        for (int k = 0; k < n; k++) {
            s = s * 1103515245u + 12345u;
            const uint32_t v = (s >> 16) % 64;
            int c = 0;
            if (v >= 56) c = (int)(v - 60);
            else if (v >= 54) c = (int)((s >> 4) % 61) - 30;
            if (mode == 2 && (s >> 3) % 97 == 0) c = (int)((s >> 5) % 65535) - 32767;
            coeffs[k] = (int16_t)c;
        }
        if (t.plane == 0) {
            s = s * 1103515245u + 12345u;
            int type = AV1G_DCT_DCT;
            if (AV1G_T(Tx_Size_Sqr_Up)[txSz] < AV1G_TX_32X32) {
                type = (int)((s >> 16) % 16);
                if (!av1g_tx_type_in_set_intra(AV1G_TX_SET_INTRA_2, type)) type = AV1G_DCT_DCT;
            }
            t.tx_type = (uint8_t)type;
        }
    }
};

struct Results {
    std::vector<std::vector<uint32_t>> syms;
    std::vector<std::vector<uint8_t>> payloads;
};
thread_local Results g_res;

}  // namespace

extern "C" {

// encode_with_hook: hook_mode 0 = none, 1 / 2 = TestHook; record_syms: per-tile symbol streams;
// nskip > 0: skip flags (one per tile) with the payloads of skipped tiles (null = empty).
int oracle_writer_encode(av1g_decision_record *rec, const av1g_encode_opts *opts, av1g_output *out, int hook_mode,
                         int record_syms, uint32_t nskip, const uint8_t *skip, const uint8_t *const *payloads,
                         const size_t *payload_sizes) {
    TestHook hook(hook_mode);
    std::vector<std::vector<uint8_t>> given(nskip);
    std::vector<av1g::TileSkip> sk(nskip);
    for (uint32_t i = 0; i < nskip; i++) {
        sk[i].skip = skip[i] != 0;
        if (payloads && payloads[i]) {
            given[i].assign(payloads[i], payloads[i] + payload_sizes[i]);
            sk[i].payload = &given[i];
        }
    }
    g_res = Results();
    return av1g::encode_with_hook(rec, opts, out, hook_mode ? &hook : nullptr, record_syms ? &g_res.syms : nullptr,
                                  nskip ? &sk : nullptr, &g_res.payloads);
}

size_t oracle_writer_n_tiles(void) { return g_res.payloads.size(); }
size_t oracle_writer_n_sym_tiles(void) { return g_res.syms.size(); }
const uint32_t *oracle_writer_syms(size_t tile, size_t *n) {
    *n = g_res.syms[tile].size();
    return g_res.syms[tile].data();
}
const uint8_t *oracle_writer_payload(size_t tile, size_t *n) {
    *n = g_res.payloads[tile].size();
    return g_res.payloads[tile].data();
}

}  // extern "C"
