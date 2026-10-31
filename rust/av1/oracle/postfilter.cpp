// Test shims: av1g/postfilter.h (header-inline functions), for the Rust port's differential tests
// (src/postfilter/tests.rs). The whole-frame paths use the C API av1g_postfilter directly.
#include <cstring>
#include <vector>
#include "av1g/postfilter.h"

namespace {
struct Maps {
    std::vector<uint8_t> skip, txY, txU, txV;
    std::vector<int8_t> cdef;
};
// av1g_pf_frame_init + av1g_pf_mark_block of every block, as av1g_postfilter sets the frame up
void setup(const av1g_frame_params *fp, const av1g_block *blocks, uint32_t n, av1g_pf_frame &f, Maps &m) {
    memset(&f, 0, sizeof f);
    av1g_pf_frame_init(fp, &f);
    const size_t nmi = (size_t)f.MiRows * f.MiCols, nuv = (size_t)(f.MiRows >> 1) * (f.MiCols >> 1);
    m.skip.assign(nmi, 0);
    m.txY.assign(nmi, 0);
    m.txU.assign(nuv, 0);
    m.txV.assign(nuv, 0);
    m.cdef.assign((size_t)f.sbCols * f.sbRows, -1);
    f.skip = m.skip.data();
    f.lfTx[0] = m.txY.data();
    f.lfTx[1] = m.txU.data();
    f.lfTx[2] = m.txV.data();
    f.cdefIdx = m.cdef.data();
    for (uint32_t b = 0; b < n; b++) av1g_pf_mark_block(&f, &blocks[b]);
}
}  // namespace

extern "C" {

// the frame parameters as ints: W H MiRows MiCols mono sbCols sbRows lfLevel[4] sharpness enableCdef damping
// cdefYPri[8] cdefYSec[8] cdefUVPri[8] cdefUVSec[8] (46 ints)
void oracle_pf_frame(const av1g_frame_params *fp, int *out) {
    av1g_pf_frame f;
    memset(&f, 0, sizeof f);
    av1g_pf_frame_init(fp, &f);
    int k = 0;
    out[k++] = f.W, out[k++] = f.H, out[k++] = f.MiRows, out[k++] = f.MiCols, out[k++] = f.mono, out[k++] = f.sbCols,
    out[k++] = f.sbRows;
    for (int i = 0; i < 4; i++) out[k++] = f.lfLevel[i];
    out[k++] = f.sharpness, out[k++] = f.enableCdef, out[k++] = f.cdefDamping;
    for (int i = 0; i < 8; i++) out[k++] = f.cdefYPri[i];
    for (int i = 0; i < 8; i++) out[k++] = f.cdefYSec[i];
    for (int i = 0; i < 8; i++) out[k++] = f.cdefUVPri[i];
    for (int i = 0; i < 8; i++) out[k++] = f.cdefUVSec[i];
}

// the maps of a record's blocks (sizes as PfMapsBuf::new)
void oracle_pf_maps(const av1g_frame_params *fp, const av1g_block *blocks, uint32_t n, uint8_t *skip, uint8_t *txY,
                    uint8_t *txU, uint8_t *txV, int8_t *cdef) {
    av1g_pf_frame f;
    Maps m;
    setup(fp, blocks, n, f, m);
    memcpy(skip, m.skip.data(), m.skip.size());
    memcpy(txY, m.txY.data(), m.txY.size());
    memcpy(txU, m.txU.data(), m.txU.size());
    memcpy(txV, m.txV.data(), m.txV.size());
    memcpy(cdef, m.cdef.data(), m.cdef.size());
}

void oracle_pf_lf_line(uint8_t *buf, long q0, long step, int plane, int filterSize, int limit, int blimit, int thresh) {
    av1g_lf_line(buf + q0, step, plane, filterSize, limit, blimit, thresh);
}

// deblocking only (av1g_deblock_frame), in place
void oracle_pf_deblock(const av1g_frame_params *fp, const av1g_block *blocks, uint32_t n, uint8_t *const planes[3],
                       const int stride[3]) {
    av1g_pf_frame f;
    Maps m;
    setup(fp, blocks, n, f, m);
    for (int p = 0; p < (f.mono ? 1 : 3); p++) { f.plane[p] = planes[p]; f.stride[p] = stride[p]; }
    av1g_deblock_frame(&f);
}

// CDEF only (av1g_cdef_frame): src -> dst
void oracle_pf_cdef(const av1g_frame_params *fp, const av1g_block *blocks, uint32_t n, uint8_t *const src[3],
                    uint8_t *const dst[3], const int stride[3]) {
    av1g_pf_frame f;
    Maps m;
    setup(fp, blocks, n, f, m);
    for (int p = 0; p < (f.mono ? 1 : 3); p++) { f.plane[p] = src[p]; f.stride[p] = stride[p]; }
    av1g_cdef_frame(&f, dst, stride);
}

void oracle_pf_cdef_direction(const uint8_t *src, int stride, int *yDir, int *var) { av1g_cdef_direction(src, stride, yDir, var); }

int oracle_pf_cdef_constrain(int diff, int threshold, int damping) { return av1g_cdef_constrain(diff, threshold, damping); }

int oracle_pf_cdef_pixel(int miRows, int miCols, const uint8_t *src, int sstride, int plane, int x, int y, int priStr, int secStr,
                         int damping, int dir) {
    av1g_pf_frame f;
    memset(&f, 0, sizeof f);
    f.MiRows = miRows;
    f.MiCols = miCols;
    return av1g_cdef_pixel(&f, src, sstride, plane, x, y, priStr, secStr, damping, dir);
}

}  // extern "C"
