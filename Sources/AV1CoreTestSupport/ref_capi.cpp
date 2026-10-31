// Glass Act: C API over av1gpu's CPU reference engine (include/av1core_test.h).
#include "av1core_test.h"
#include "tools.h"

#include <cstring>
#include <string>

extern "C" int av1t_ref_encode(const uint8_t *y, const uint8_t *u, const uint8_t *v, uint32_t w, uint32_t h,
                               const av1t_ref_opts *opts, av1g_output *out) {
    av1g::Image img;
    img.W = (int)w;
    img.H = (int)h;
    img.mono = 0;
    const size_t cw = (w + 1) / 2, ch = (h + 1) / 2;
    img.p[0].assign(y, y + (size_t)w * h);
    img.p[1].assign(u, u + cw * ch);
    img.p[2].assign(v, v + cw * ch);
    av1g::RefEngineOpts o;
    o.qindex = opts->qindex;
    o.min_block = opts->min_block;
    o.max_block = opts->max_block;
    o.lf_level = opts->lf_level;
    o.cdef = opts->cdef;
    o.edge_filter = opts->edge_filter != 0;
    av1g::OwnedRecord rec;
    std::string err;
    memset(out, 0, sizeof *out);
    int rc = av1g::ref_engine_encode(img, o, rec, out, nullptr, err);
    if (rc != AV1G_OK && !err.empty()) snprintf(out->error, sizeof out->error, "%s", err.c_str());
    return rc;
}

struct av1t_hybrid {
    av1g::OwnedRecord rec;
    av1g_output out;
    av1g::RefEngineStats stats;
};

extern "C" av1t_hybrid *av1t_hybrid_closed_loop(const uint8_t *y, const uint8_t *u, const uint8_t *v, uint32_t w, uint32_t h,
                                                 const av1g_block *blocks, uint32_t n, const uint8_t *luma_tx, int qindex,
                                                 double rnd, double zbin, int tx_types, int tile_cols_log2, int tile_rows_log2,
                                                 char *err, size_t errlen) {
    av1g::Image img;
    img.W = (int)w;
    img.H = (int)h;
    const size_t cw = (w + 1) / 2, ch = (h + 1) / 2;
    img.p[0].assign(y, y + (size_t)w * h);
    img.p[1].assign(u, u + cw * ch);
    img.p[2].assign(v, v + cw * ch);
    av1g::RefEngineOpts o;
    o.qindex = qindex;
    o.quant_rnd = rnd;
    o.quant_zbin = zbin;
    o.tx_types = tx_types != 0;
    o.given_luma_tx = luma_tx != nullptr;
    o.tile_cols_log2 = tile_cols_log2;
    o.tile_rows_log2 = tile_rows_log2;
    auto *hy = new av1t_hybrid();
    memset(&hy->out, 0, sizeof hy->out);
    std::string e;
    std::vector<av1g_block> given(blocks, blocks + n);
    if (av1g::ref_engine_closed_loop(img, o, given, hy->rec, &hy->out, &hy->stats, e, luma_tx) != AV1G_OK) {
        if (err && errlen) snprintf(err, errlen, "%s", e.c_str());
        av1g_output_free(&hy->out);
        delete hy;
        return nullptr;
    }
    hy->rec.bind();
    return hy;
}

extern "C" av1g_decision_record *av1t_hybrid_record(av1t_hybrid *h) { return &h->rec.rec; }
extern "C" const uint8_t *av1t_hybrid_recon(const av1t_hybrid *h, int plane) { return h->out.recon[plane]; }
extern "C" double av1t_hybrid_seconds(const av1t_hybrid *h, int which) {
    return which == 0 ? h->stats.seconds_decide : h->stats.seconds_encode;
}
extern "C" void av1t_hybrid_free(av1t_hybrid *h) {
    if (!h) return;
    av1g_output_free(&h->out);
    delete h;
}
