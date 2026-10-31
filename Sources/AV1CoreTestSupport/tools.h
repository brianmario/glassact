// av1core tools: the CPU reference decision engine.
// Glass Act: from av1gpu's av1core/src/tools.h (BSD-2), without JPEG input and record files.
#ifndef AV1G_TOOLS_H
#define AV1G_TOOLS_H

#include <cstdint>
#include <string>
#include <vector>
#include "av1g/av1g.h"

namespace av1g {

// Cropped source picture, 8-bit: Y w x h, U/V ((w+1)/2) x ((h+1)/2) (absent if mono).
struct Image {
    int W = 0, H = 0, mono = 0;
    std::vector<uint8_t> p[3];
    int w(int pl) const { return pl ? (W + 1) >> 1 : W; }
    int h(int pl) const { return pl ? (H + 1) >> 1 : H; }
};

// A DecisionRecord together with the storage it points into.
struct OwnedRecord {
    av1g_decision_record rec;
    std::vector<av1g_block> blocks;
    std::vector<uint32_t> block_txb;
    std::vector<av1g_txb> txb;
    std::vector<int16_t> coeffs;
    void bind();     // point rec at the vectors
    int layout();    // av1g_layout + allocation
};

struct RefEngineOpts {
    int qindex = 100;
    int min_block = 8;          // smallest block edge used by the partition search (4 or 8)
    int max_block = 64;
    bool angle_deltas = true;
    bool cfl = true;
    bool tx_types = true;
    int reduced_tx_set = 0;
    double split_bias = 1.0;    // >1 favours larger blocks
    int qm_level = -1;          // quantizer matrix level 0..15 for luma (-1: off, -2: libaom all-intra curve)
    int qm_level_uv = -1;       // chroma level (-1: same as luma)
    int deltaq = 0;             // 1: activity-based per-SB qindex (simple variance boost)
    int deltaq_res = 2;         // delta_q_res (step 1 << res)
    double deltaq_strength = 6.0;  // qindex per log2 unit of SB activity relative to the frame mean
    bool edge_filter = false;   // enable_intra_edge_filter (prediction only; decisions unchanged)
    int lf_level = -1;          // deblocking level for all planes/directions (-1: off); no search
    int lf_sharpness = 0;
    int cdef = 0;               // 1: CDEF with one fixed preset for every 64x64 (cdef_bits 0); no search
    int cdef_y_pri = 4, cdef_y_sec = 1, cdef_uv_pri = 2, cdef_uv_sec = 1, cdef_damping = 5;
    // Glass Act: the closed loop's quantizer, level = |v| < zbin ? 0 : floor(|v| + rnd) in step units
    // (default: plain rounding; the Metal encoder's dead zone is rnd 0.375, zbin 0.656)
    double quant_rnd = 0.5, quant_zbin = 0.0;
    // Glass Act: keep the record's luma tx types (decided elsewhere) instead of searching them
    bool given_luma_tx = false;
    int tile_cols_log2 = -1, tile_rows_log2 = -1;  // Glass Act: ref_engine_closed_loop's tiling
};

struct RefEngineStats {
    double seconds_decide = 0, seconds_encode = 0;
    uint32_t blocks = 0, skip_blocks = 0, cfl_blocks = 0;
};

// Simple CPU reference engine: open-loop (source-edge) SATD partition + mode
// decisions, closed-loop residual coding (exact prediction from av1core, float
// forward transform derived from the exact inverse, plain rounding quantization),
// greedy luma tx-type choice on exact reconstruction error + rate proxy, then a
// final pass that marks all-zero blocks as skip.  Produces the record and the
// encoded output.
int ref_engine_encode(const Image &src, const RefEngineOpts &o, OwnedRecord &rec, av1g_output *out,
                      RefEngineStats *stats, std::string &err);

// Glass Act: the engine's closed loop on given blocks (partition and luma modes decided elsewhere,
// e.g. by the Metal encoder's analysis): chroma modes and CfL from the source, then the closed
// loop and the skip pass. No post-filters: out->recon is the PADDED pre-filter reconstruction
// (AV1G_ENC_PREFILTER_RECON), and rec holds the record.
int ref_engine_closed_loop(const Image &src, const RefEngineOpts &o, const std::vector<av1g_block> &given,
                           OwnedRecord &rec, av1g_output *out, RefEngineStats *stats, std::string &err,
                           const uint8_t *luma_tx = nullptr);

}  // namespace av1g
#endif
