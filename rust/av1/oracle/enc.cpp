// Test shims for the Rust port's enc module: the header-only tune=iq decisions (av1f/tuneiq.h).
#include <cstring>
#include "av1enc.h"
#include "av1f/tuneiq.h"

extern "C" {

int oracle_enc_qindex_for_quality(int q) { return av1f_qindex_for_quality(q); }
void oracle_enc_chroma_delta_q(int base, int ssx, int ssy, int out[4]) { av1f_chroma_delta_q(base, ssx, ssy, out); }
int oracle_enc_qm_level_allintra(int q, int first, int last) { return av1f_qm_level_allintra(q, first, last); }
int oracle_enc_qm_level_444_chroma(int q, int first, int last) { return av1f_qm_level_444_chroma(q, first, last); }
int oracle_enc_delta_q_res(int base) { return av1f_delta_q_res(base); }
int oracle_enc_log2i(int v) { return av1f_log2i(v); }
int oracle_enc_adjust_q(int res, int prev, int cur) { return av1f_adjust_q(res, prev, cur); }
int oracle_enc_varboost_qindex(int base, unsigned variance, int pct) { return av1f_varboost_qindex(base, variance, pct); }
unsigned oracle_enc_sb_variance(unsigned v[64]) { return av1f_sb_variance(v); }
unsigned oracle_enc_var8x8_from_sums(int sum, unsigned sse) { return av1f_var8x8_from_sums(sum, sse); }
int oracle_enc_frame_rdmult(int base) { return av1f_frame_rdmult(base); }
int oracle_enc_dc_q(int q) { return av1f_dc_q(q); }
int oracle_enc_ac_q(int q) { return av1f_ac_q(q); }

// av1f_tuneiq_frame_init as 14 ints in declaration order.
void oracle_enc_tuneiq_frame_init(int base, int ssx, int ssy, int mono, int out[14]) {
    av1f_tuneiq_frame f;
    av1f_tuneiq_frame_init(base, ssx, ssy, mono, &f);
    static_assert(sizeof f == 14 * sizeof(int), "av1f_tuneiq_frame");
    memcpy(out, &f, sizeof f);
}

void oracle_enc_tuneiq_fill_fp(av1g_frame_params *fp, int base, int mono) { av1f_tuneiq_fill_fp(fp, base, mono); }

}  // extern "C"
