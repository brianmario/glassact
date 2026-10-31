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
