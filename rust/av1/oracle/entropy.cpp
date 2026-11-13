// Test shims for the Rust port's entropy module: the header-only range encoder, CDF context and
// symbol streams (av1g/entenc.h, cdfctx.h, symstream.h).
#include <chrono>
#include <cstddef>
#include <cstring>
#include "av1g/av1g.h"
#include "av1g/dsp.h"
#include "av1g/entenc.h"
#include "av1g/cdfctx.h"
#include "av1g/symstream.h"
#include "av1core_test.h"

extern "C" {

// av1g_cdfs_init(qidx) as words (sizeof(av1g_cdfs) / 2 of them).
void oracle_entropy_cdfs_init(int qidx, uint16_t *out) {
    av1g_cdfs c;
    av1g_cdfs_init(&c, qidx);
    memcpy(out, &c, sizeof c);
}

int oracle_entropy_coeff_cdf_q_ctx(int qidx) { return av1g_coeff_cdf_q_ctx(qidx); }

// sizeof(av1g_cdfs), then every field's offset in declaration order (38 values).
void oracle_entropy_cdfs_layout(long long *out) {
    int i = 0;
    out[i++] = (long long)sizeof(av1g_cdfs);
#define F(f) out[i++] = (long long)offsetof(av1g_cdfs, f);
    F(y_mode) F(uv_mode_cfl_not_allowed) F(uv_mode_cfl_allowed) F(angle_delta) F(partition_w8) F(partition_w16)
    F(partition_w32) F(partition_w64) F(tx_8x8) F(tx_16x16) F(tx_32x32) F(tx_64x64) F(skip) F(filter_intra_mode)
    F(filter_intra) F(delta_q) F(delta_lf) F(delta_lf_multi) F(intra_tx_set1) F(intra_tx_set2) F(cfl_sign)
    F(cfl_alpha) F(palette_y_mode) F(palette_uv_mode) F(txb_skip) F(eob_pt_16) F(eob_pt_32) F(eob_pt_64)
    F(eob_pt_128) F(eob_pt_256) F(eob_pt_512) F(eob_pt_1024) F(eob_extra) F(dc_sign) F(coeff_base_eob)
    F(coeff_base) F(coeff_br)
#undef F
}

void oracle_entropy_update_cdf(uint16_t *cdf, int s, int n) { av1g_update_cdf(cdf, s, n); }

// One encoder operation on CDFs in `words` (any CDF arrangement):
//   0 adaptive symbol (a = cdf offset, b = s, c = N)   1 bool (b)   2 literal (a = value, c = bits)
//   3 symbol without adaptation (a, b, c as 0)         4 split_or (a = partition cdf offset, b, c = vert)
typedef struct { uint32_t kind, a, b, c; } oracle_ec_op;

// Runs ops on a fresh encoder with a cap-entry precarry buffer; flushes into out (cap + 8 bytes).
// Returns av1g_ec_done's result (bytes, or -1 on overflow). words is updated in place.
int oracle_entropy_ops(const oracle_ec_op *ops, uint32_t n, uint16_t *words, uint8_t *out, uint32_t cap) {
    uint16_t *pbuf = new uint16_t[cap];
    av1g_ec e;
    av1g_ec_init(&e, pbuf, cap);
    for (uint32_t i = 0; i < n; i++) {
        const oracle_ec_op &o = ops[i];
        switch (o.kind) {
        case 0: av1g_ec_symbol(&e, (int)o.b, words + o.a, (int)o.c); break;
        case 1: av1g_ec_bool(&e, (int)o.b); break;
        case 2: av1g_ec_literal(&e, o.a, (int)o.c); break;
        case 3: av1g_ec_encode_cdf(&e, (int)o.b, words + o.a, (int)o.c); break;
        default: {
            uint16_t tmp[3] = {(uint16_t)(32768u - av1g_split_or_psum(words + o.a, (int)o.c)), 32768, 0};
            av1g_ec_encode_cdf(&e, (int)o.b, tmp, 2);
        }
        }
    }
    int r = av1g_ec_done(&e, out);
    delete[] pbuf;
    return r;
}

uint32_t oracle_entropy_split_or_psum(const uint16_t *pc, int vert) { return av1g_split_or_psum(pc, vert); }
uint32_t oracle_entropy_sym_pack(uint32_t kind, uint32_t cdf, uint32_t s, uint32_t n) {
    return av1g_sym_pack(kind, cdf, s, n);
}

// av1g_code_symbols on av1g_cdfs_init(qidx); the final CDFs to cdfs_out (if set).
int oracle_entropy_code_symbols(const uint32_t *syms, uint32_t n, int qidx, uint8_t *out, uint32_t cap,
                                uint16_t *cdfs_out) {
    av1g_cdfs c;
    av1g_cdfs_init(&c, qidx);
    uint16_t *pbuf = new uint16_t[cap];
    av1g_ec e;
    av1g_ec_init(&e, pbuf, cap);
    av1g_code_symbols(syms, n, &c, &e);
    int r = av1g_ec_done(&e, out);
    delete[] pbuf;
    if (cdfs_out) memcpy(cdfs_out, &c, sizeof c);
    return r;
}

// Micro-benchmark: reps x (init + av1g_code_symbols + done). Returns nanoseconds; *bytes the size.
uint64_t oracle_entropy_bench_code_symbols(const uint32_t *syms, uint32_t n, int qidx, int reps, uint8_t *out,
                                           uint32_t cap, int *bytes) {
    uint16_t *pbuf = new uint16_t[cap];
    av1g_cdfs c;
    int r = 0;
    auto t0 = std::chrono::steady_clock::now();
    for (int k = 0; k < reps; k++) {
        av1g_cdfs_init(&c, qidx);
        av1g_ec e;
        av1g_ec_init(&e, pbuf, cap);
        av1g_code_symbols(syms, n, &c, &e);
        r = av1g_ec_done(&e, out);
    }
    auto t1 = std::chrono::steady_clock::now();
    delete[] pbuf;
    *bytes = r;
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
}

// Where av1t_dsp_set's range-coder fields are, for the Rust mirror of the struct.
void oracle_entropy_dsp_set_layout(long long *out) {
    out[0] = (long long)sizeof(av1t_dsp_set);
    out[1] = (long long)offsetof(av1t_dsp_set, ec_count);
    out[2] = (long long)offsetof(av1t_dsp_set, ec_symbols);
    out[3] = (long long)offsetof(av1t_dsp_set, ec_bytes);
}

// The writer's call pattern: av1g_ec_symbol at fixed call sites with constant N.
// op = site << 24 | ctx << 8 | s; sites: 0 txb_skip (2), 1 coeff_base_eob (3), 2 coeff_base (4),
// 3 coeff_br (4), 4 dc_sign (2), 5 eob_pt_256 (9), 6 y_mode (13), 7 cfl_alpha (16), 8 bool.
static inline void oracle_site(av1g_ec *e, av1g_cdfs *c, uint32_t op) {
    const uint32_t ctx = (op >> 8) & 0xFFFF;
    const int s = (int)(op & 0xFF);
    switch (op >> 24) {
    case 0: av1g_ec_symbol(e, s, (&c->txb_skip[0][0][0]) + 3 * ctx, 2); break;
    case 1: av1g_ec_symbol(e, s, (&c->coeff_base_eob[0][0][0][0]) + 4 * ctx, 3); break;
    case 2: av1g_ec_symbol(e, s, (&c->coeff_base[0][0][0][0]) + 5 * ctx, 4); break;
    case 3: av1g_ec_symbol(e, s, (&c->coeff_br[0][0][0][0]) + 5 * ctx, 4); break;
    case 4: av1g_ec_symbol(e, s, (&c->dc_sign[0][0][0]) + 3 * ctx, 2); break;
    case 5: av1g_ec_symbol(e, s, (&c->eob_pt_256[0][0][0]) + 10 * ctx, 9); break;
    case 6: av1g_ec_symbol(e, s, (&c->y_mode[0][0][0]) + 14 * ctx, 13); break;
    case 7: av1g_ec_symbol(e, s, (&c->cfl_alpha[0][0]) + 17 * ctx, 16); break;
    default: av1g_ec_bool(e, s); break;
    }
}

int oracle_entropy_sites(const uint32_t *ops, uint32_t n, int qidx, uint8_t *out, uint32_t cap) {
    uint16_t *pbuf = new uint16_t[cap];
    av1g_cdfs c;
    av1g_cdfs_init(&c, qidx);
    av1g_ec e;
    av1g_ec_init(&e, pbuf, cap);
    for (uint32_t i = 0; i < n; i++) oracle_site(&e, &c, ops[i]);
    int r = av1g_ec_done(&e, out);
    delete[] pbuf;
    return r;
}

// Micro-benchmark: reps x (init + the sites + done). Returns nanoseconds; *bytes the size.
uint64_t oracle_entropy_bench_sites(const uint32_t *ops, uint32_t n, int qidx, int reps, uint8_t *out, uint32_t cap,
                                    int *bytes) {
    uint16_t *pbuf = new uint16_t[cap];
    av1g_cdfs c;
    int r = 0;
    auto t0 = std::chrono::steady_clock::now();
    for (int k = 0; k < reps; k++) {
        av1g_cdfs_init(&c, qidx);
        av1g_ec e;
        av1g_ec_init(&e, pbuf, cap);
        for (uint32_t i = 0; i < n; i++) oracle_site(&e, &c, ops[i]);
        r = av1g_ec_done(&e, out);
    }
    auto t1 = std::chrono::steady_clock::now();
    delete[] pbuf;
    *bytes = r;
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
}

}  // extern "C"
