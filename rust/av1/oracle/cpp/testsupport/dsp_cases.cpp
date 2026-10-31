// Glass Act: the case generation and CPU results of av1gpu's tests/gpu_dsp_test.cu
// (BSD-2), for DSPEquivalenceTests (include/av1core_test.h). The GPU half runs
// the same av1g_test/dsp_cases.h functions in Metal.
#include "av1core_test.h"
#include "av1g_test/dsp_cases.h"

#include <cstring>
#include <vector>

namespace {

struct Rng {
    uint64_t s;
    uint32_t operator()() {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return (uint32_t)s;
    }
};

struct Set {
    av1t_dsp_set pub;
    std::vector<av1t_itx_case> itx;
    std::vector<int16_t> q;
    std::vector<int32_t> res;
    std::vector<uint32_t> err;
    std::vector<av1t_pred_case> pred;
    std::vector<uint8_t> planes, luma, predOut;
    std::vector<av1t_sym> syms;
    std::vector<int32_t> off, cnt, sizes;
    std::vector<uint8_t> bytes;
};

void make_itx(Rng &rnd, Set &S, int n) {
    S.itx.resize(n);
    S.q.assign((size_t)n * AV1T_ITX_COEFFS, 0);
    for (int i = 0; i < n; i++) {
        av1t_itx_case &c = S.itx[i];
        c.txSz = rnd() % 19;
        c.txType = (AV1G_T(Tx_Size_Sqr_Up)[c.txSz] == AV1G_TX_64X64) ? AV1G_DCT_DCT : (int)(rnd() % 16);
        if (AV1G_T(Tx_Size_Sqr_Up)[c.txSz] == AV1G_TX_32X32 && c.txType != AV1G_IDTX) c.txType = AV1G_DCT_DCT;
        int qi = 1 + rnd() % 255;
        c.dcQ = av1g_dc_q(qi);
        c.acQ = av1g_ac_q(qi);
        c.qmLevel = (rnd() % 2) ? (int)(rnd() % 16) : -1;  // half the cases with quantizer matrices
        c.plane = rnd() % 3;
        int nc = av1g_tx_coeffs(c.txSz), k = 1 + rnd() % 12;
        for (int j = 0; j < k; j++) {
            int pos = (rnd() % 3 == 0) ? (int)(rnd() % nc) : (int)(rnd() % (nc < 16 ? nc : 16));
            int mag = (rnd() % 10 == 0) ? (int)(rnd() % 3000) : (int)(rnd() % 40);
            S.q[(size_t)i * AV1T_ITX_COEFFS + pos] = (int16_t)((rnd() & 1) ? -mag : mag);
        }
    }
    S.res.assign((size_t)n * AV1T_ITX_RESIDUAL, 0);
    S.err.assign(n, 0);
    std::vector<int32_t> scratch(AV1T_ITX_COEFFS);
    for (int i = 0; i < n; i++)
        av1t_itx_run(S.itx[i], &S.q[(size_t)i * AV1T_ITX_COEFFS], &S.res[(size_t)i * AV1T_ITX_RESIDUAL], &S.err[i],
                     scratch.data());
}

void make_pred(Rng &rnd, Set &S, int n) {
    S.pred.resize(n);
    S.planes.resize((size_t)n * AV1T_PW * AV1T_PW);
    S.luma.resize((size_t)4 * AV1T_PW * AV1T_PW);
    for (auto &v : S.planes) v = (uint8_t)rnd();
    for (auto &v : S.luma) v = (uint8_t)rnd();
    int ncfl = 0;
    for (int i = 0; i < n; i++) {
        av1t_pred_case &c = S.pred[i];
        int t = rnd() % 19;
        c.log2W = AV1G_T(Tx_Width_Log2)[t];
        c.log2H = AV1G_T(Tx_Height_Log2)[t];
        c.mode = rnd() % 13;
        c.delta = av1g_is_directional(c.mode) ? (int)(rnd() % 7) - 3 : 0;
        c.haveLeft = rnd() & 1; c.haveAbove = rnd() & 1; c.haveAR = rnd() & 1; c.haveBL = rnd() & 1;
        c.x = c.haveLeft ? 1 + rnd() % 8 : 0;
        c.y = c.haveAbove ? 1 + rnd() % 8 : 0;
        c.maxX = c.x + (1 << c.log2W) + (int)(rnd() % 64) - 1;
        c.maxY = c.y + (1 << c.log2H) + (int)(rnd() % 64) - 1;
        if (c.maxX > AV1T_PW - 1) c.maxX = AV1T_PW - 1;
        if (c.maxY > AV1T_PW - 1) c.maxY = AV1T_PW - 1;
        c.edgeFilter = rnd() & 1;
        c.filterType = rnd() & 1;
        c.fiMode = (c.mode == AV1G_DC_PRED && c.log2W <= 5 && c.log2H <= 5 && (rnd() & 1)) ? (int)(rnd() % 5) : -1;
        c.cfl = (c.log2W <= 5 && c.log2H <= 5 && (rnd() % 3 == 0)) ? 1 : 0;
        if (c.cfl) { c.mode = AV1G_DC_PRED; c.delta = 0; c.alpha = (int)(rnd() % 33) - 16; c.fiMode = -1; ncfl++; }
    }
    S.predOut.resize(S.planes.size());
    for (int i = 0; i < n; i++)
        av1t_pred_run(S.pred[i], &S.planes[(size_t)i * AV1T_PW * AV1T_PW], S.luma.data(),
                      &S.predOut[(size_t)i * AV1T_PW * AV1T_PW]);
    S.pub.pred_cfl_count = ncfl;
}

void make_ec(Rng &rnd, Set &S, int n, int qidx, uint32_t cap) {
    av1g_cdfs proto;
    av1g_cdfs_init(&proto, qidx);
    // pick symbols from the real CDF layout: (offset, N) of a few arrays
    struct Arr { uint16_t *p; int N, count; };
    Arr arrs[] = {{&proto.y_mode[0][0][0], 13, 25}, {&proto.skip[0][0], 2, 3}, {&proto.coeff_base[0][0][0][0], 4, 5 * 2 * 42},
                  {&proto.coeff_br[0][0][0][0], 4, 5 * 2 * 21}, {&proto.txb_skip[0][0][0], 2, 5 * 13},
                  {&proto.partition_w64[0][0], 10, 4}, {&proto.cfl_alpha[0][0], 16, 6}, {&proto.eob_pt_1024[0][0], 11, 2}};
    S.off.resize(n);
    S.cnt.resize(n);
    for (int i = 0; i < n; i++) {
        S.off[i] = (int)S.syms.size();
        S.cnt[i] = 1 + rnd() % 8000;
        for (int k = 0; k < S.cnt[i]; k++) {
            av1t_sym s;
            if (rnd() % 6 == 0) { s.isBool = 1; s.s = rnd() & 1; s.cdfOff = 0; s.N = 2; }
            else {
                Arr &a = arrs[rnd() % 8];
                int ctx = rnd() % a.count;
                s.isBool = 0;
                s.N = (uint16_t)a.N;
                s.cdfOff = (uint16_t)((a.p - (uint16_t *)&proto) + ctx * (a.N + 1));
                s.s = (uint16_t)((rnd() % 4) ? rnd() % 2 : rnd() % a.N);
            }
            S.syms.push_back(s);
        }
    }
    S.sizes.resize(n);
    S.bytes.assign((size_t)n * cap, 0);
    std::vector<uint16_t> pbuf(cap);
    for (int i = 0; i < n; i++) {
        av1g_cdfs c;
        av1g_cdfs_init(&c, qidx);
        S.sizes[i] = av1t_ec_stream(&S.syms[S.off[i]], S.cnt[i], &c, pbuf.data(), cap, &S.bytes[(size_t)i * cap]);
    }
}

}  // namespace

extern "C" const av1t_dsp_set *av1t_dsp_set_make(uint64_t seed) {
    Set *S = new Set;
    memset(&S->pub, 0, sizeof S->pub);
    Rng rnd{seed ? seed : 0x123456789abcdefull};
    const int nItx = 2048, nPred = 1024, nEc = 128, qidx = 100;
    const uint32_t cap = 1 << 15;
    make_itx(rnd, *S, nItx);
    make_pred(rnd, *S, nPred);
    make_ec(rnd, *S, nEc, qidx, cap);
    av1t_dsp_set &p = S->pub;
    p.priv = S;
    p.itx_count = nItx;
    p.itx_cases = S->itx.data();
    p.itx_case_size = sizeof(av1t_itx_case);
    p.itx_coeffs = S->q.data();
    p.itx_coeffs_per_case = AV1T_ITX_COEFFS;
    p.itx_residual = S->res.data();
    p.itx_residual_per_case = AV1T_ITX_RESIDUAL;
    p.itx_flags = S->err.data();
    p.pred_count = nPred;
    p.pred_side = AV1T_PW;
    p.pred_cases = S->pred.data();
    p.pred_case_size = sizeof(av1t_pred_case);
    p.pred_planes = S->planes.data();
    p.pred_luma = S->luma.data();
    p.pred_luma_size = (uint32_t)S->luma.size();
    p.pred_out = S->predOut.data();
    p.ec_count = nEc;
    p.ec_qindex = qidx;
    p.ec_capacity = cap;
    p.ec_cdfs_size = sizeof(av1g_cdfs);
    p.ec_symbols = S->syms.data();
    p.ec_symbol_size = sizeof(av1t_sym);
    p.ec_symbol_count = (int32_t)S->syms.size();
    p.ec_offsets = S->off.data();
    p.ec_counts = S->cnt.data();
    p.ec_sizes = S->sizes.data();
    p.ec_bytes = S->bytes.data();
    for (int i = 0; i < nItx; i++) p.itx_flagged_count += S->err[i] != 0;
    return &S->pub;
}

extern "C" void av1t_dsp_set_free(const av1t_dsp_set *p) {
    delete static_cast<Set *>(p->priv);
}


extern "C" uint32_t av1t_inverse_transform(int32_t txSz, int32_t txType, const int32_t *dq, int32_t *residual) {
    uint32_t err = 0;
    av1g_inv_txfm2d(dq, txSz, txType, residual, &err);
    return err;
}

extern "C" int32_t av1t_tx_type_allowed(int32_t txSz, int32_t txType) {
    if (AV1G_T(Tx_Size_Sqr_Up)[txSz] > AV1G_TX_32X32) return txType == AV1G_DCT_DCT;
    return av1g_tx_type_in_set_intra(av1g_get_tx_set_intra(txSz, 0), txType);
}
