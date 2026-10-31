// Glass Act's C API over the host half of av1gpu's encoder (Sources/AV1Encoder):
// what the Metal kernels need from the CPU. The structures the host and the
// kernels share are in av1enc/gp.h.
#ifndef AV1ENC_H
#define AV1ENC_H

#include <stddef.h>
#include <stdint.h>
#include "av1g/av1g.h"  // AV1Core's module header, so Swift sees its types as AV1Core's
#include "av1enc/ent.h"

#ifdef __cplusplus
extern "C" {
#endif

// The encoder's derived tables (forward transform matrices, transform energy
// and scale factors, symbol costs from the default CDFs) as Metal source:
// `constant` arrays the kernels index. NUL-terminated, malloc'd (free it);
// NULL on failure.
char *av1enc_tables_msl(size_t *length);

// One picture's plan for the GPU entropy kernels: its frame table and its tiles (at most
// GA_ENT_MAX_TILES, in raster order), from the record's parameters and sizes. Leaves
// frame->symCap to the caller. Returns the number of tiles; 0 if the tiling isn't uniform
// or the record is empty.
uint32_t av1enc_ent_plan(const av1g_frame_params *fp, uint32_t nBlocks, uint32_t nTxb, GaEntFrame *frame,
                         GaEntTile *tiles);

// The OBUs of a picture whose tiles were entropy coded elsewhere: [temporal delimiter,]
// sequence header and OBU_FRAME (frame header, tile sizes, payloads), as av1g_encode writes
// them. *out is malloc'd (free it). Returns 0, or -1 if the tiles don't fit the parameters.
int av1enc_assemble_obus(const av1g_frame_params *fp, const uint8_t *const *tileData, const size_t *tileSizes,
                         uint32_t nTiles, int temporalDelimiter, uint8_t **out, size_t *outSize);

// GPU addresses of the post-filters' planes (being deblocked in place: MiCols*4 x MiRows*4,
// >> 1 for chroma) and maps (Skips and luma LoopfilterTxSizes MiRows x MiCols, chroma ones
// MiRows/2 x MiCols/2, cdef_idx per 64x64, direction and variance per 8x8).
typedef struct GaPfAddrs {
    uint64_t plane[3];
    int32_t stride[3];
    uint64_t skip, lfTx[3], cdefIdx, cdefDirVar;
} GaPfAddrs;

// The post-filters' frame for fp (av1core's av1g_pf_frame, opaque to Swift) pointing at
// those addresses, written to out when cap holds it. Returns its size.
size_t av1enc_pf_frame(const av1g_frame_params *fp, const GaPfAddrs *addrs, void *out, size_t cap);

// libaom tune=iq's frame-level loop-filter decisions for a base qindex (av1f_tuneiq_frame_init):
// the effective deblocking level (all four), sharpness, CDEF damping, CDEF mode (0: off at
// qindex <= 32, 1: halved strengths, 2: full) and the frame RDMULT.
typedef struct GaTuneiqFrame {
    int32_t lf_level, lf_sharpness, cdef_damping, cdef_mode, rdmult;
} GaTuneiqFrame;
void av1enc_tuneiq_frame(int base_q_idx, int mono, GaTuneiqFrame *out);

// CDEF candidate strengths: npri x nsec, signalled primary and applied secondary (0, 1, 2, 4)
// values. Candidate index = pri index * nsec + sec index. libaom's fast search: {0, 11} x {0, 2}.
typedef struct GaCdefCand {
    int32_t pri[16], sec[4];
    int32_t npri, nsec;
} GaCdefCand;

// libaom's RD choice of cdef_bits: tots[i] is the joint search's SSE with 2^i presets,
// n_active the 64x64s that code a cdef_idx.
int av1enc_cdef_bits(const uint64_t *tots, int max_bits, int n_active, int mono, int rdmult);

// Writes enable_cdef, cdef_bits and the presets the search chose (lev: 8 luma then 8 chroma
// candidate indices) into fp, halving them in CDEF mode 1 as libaom's CDEF_ADAPTIVE does.
void av1enc_cdef_presets(const int32_t lev[16], int bits, int cdef_mode, const GaCdefCand *cd,
                         av1g_frame_params *fp);

// The joint greedy preset search (libaom search_one_dual + refinement) on per-SB SSE tables
// ([nsb][nc], luma and chroma), sequentially: the reference the GPU's search is held to.
// lev_out: (max_bits + 1) x 16; tot_out: max_bits + 1.
void av1enc_cdef_select_cpu(const uint32_t *my, const uint32_t *muv, int nc, int nsb, int mono, int max_bits,
                            int refine, int fast_mono, int32_t *lev_out, uint64_t *tot_out);

// The CPU half of the hybrid encoder (src/hybrid.cpp): the closed loop on blocks the Metal
// analysis decided (av1g_block with mi_row, mi_col, bsize, y_mode and angle_delta_y set; the rest
// is decided here), on 8-bit 4:2:0 planes (tight: Y w x h, U and V ((w+1)/2) x ((h+1)/2)), with
// the given tiling. On success the handle holds the record (chroma modes, coefficients, skip
// flags; no post-filter parameters yet) and the PADDED pre-filter reconstruction
// (MiCols*4 x MiRows*4, chroma half), until the next call. Reuse one handle per picture stream.
typedef struct av1enc_hybrid av1enc_hybrid;
av1enc_hybrid *av1enc_hybrid_create(void);
void av1enc_hybrid_destroy(av1enc_hybrid *h);
// luma_tx (optional): every block's luma tx type, kept instead of searched. flags:
// AV1ENC_HYBRID_GIVEN_CHROMA: the blocks' uv_mode / angle_delta_uv / cfl_alpha_* are decided already.
#define AV1ENC_HYBRID_GIVEN_CHROMA 1
int av1enc_hybrid_closed_loop(av1enc_hybrid *h, const uint8_t *y, const uint8_t *u, const uint8_t *v, uint32_t w,
                              uint32_t hgt, const av1g_block *blocks, uint32_t n, const uint8_t *luma_tx, int flags,
                              int qindex, int tile_cols_log2, int tile_rows_log2, char *err, size_t errlen);
// av1enc_hybrid_closed_loop for a frame of a stream: video (null: a still picture) supplies the
// frame's video fields (video, frame_type, ref_slot, refresh_frame_flags, error_resilient_mode,
// lf_inter_off, allow_screen_content_tools; the rest is ignored). An inter frame takes inter (one
// per block, or null: all intra) and ref, LAST_FRAME's picture (the decoder's output of the frame
// in ref_slot: planes of the picture's size at their strides). Inter blocks are skip blocks
// (tx_depth 0, intra fields 0) and copy the reference at their motion vector. An inter frame's
// tiles are coded afresh, and the next picture's aren't kept from it.
int av1enc_hybrid_closed_loop_ex(av1enc_hybrid *h, const uint8_t *y, const uint8_t *u, const uint8_t *v, uint32_t w,
                                 uint32_t hgt, const av1g_block *blocks, uint32_t n, const uint8_t *luma_tx, int flags,
                                 int qindex, int tile_cols_log2, int tile_rows_log2, const av1g_frame_params *video,
                                 const av1g_block_inter *inter, const av1g_ref_planes *ref, char *err, size_t errlen);
av1g_decision_record *av1enc_hybrid_record(av1enc_hybrid *h);
// The bitstream of the last closed loop's picture with the post-filter parameters chosen (fp) and
// every 64x64's cdef_idx (raster, sb_cols wide; -1 as 0): [TD,] sequence header and frame. A tile
// whose closed loop was kept, and whose cdef_idx values and cdef_bits are as last written, keeps
// its bytes. *obu is malloc'd (free it).
int av1enc_hybrid_write(av1enc_hybrid *h, const av1g_frame_params *fp, const int8_t *sb_cdef, int sb_cols,
                        uint8_t **obu, size_t *size, char *err, size_t errlen);
// Keep unchanged tiles' closed loop and bitstream from picture to picture (on by default).
void av1enc_hybrid_set_reuse(av1enc_hybrid *h, int on);
// Tiles the last closed loop kept.
uint32_t av1enc_hybrid_reused_tiles(const av1enc_hybrid *h);
// Per 64x64 (raster), nonzero where the last closed loop re-coded the tile: elsewhere the
// reconstruction, blocks and source are the previous picture's. Returns 0 if unknown.
int av1enc_hybrid_changed_superblocks(const av1enc_hybrid *h, uint8_t *out, int sb_cols, int sb_rows);
const uint8_t *av1enc_hybrid_recon(const av1enc_hybrid *h, int plane);
// the source the last call coded, padded by edge replication to whole superblocks (at least the
// post-filters' MiCols*4 x MiRows*4, chroma half): rows *stride apart
const uint8_t *av1enc_hybrid_source(const av1enc_hybrid *h, int plane, int *stride);
// the last call's seconds: 0 chroma decisions, 1 closed loop
double av1enc_hybrid_seconds(const av1enc_hybrid *h, int which);

// Motion for screen content (rust/av1/src/motion.rs): superblocks that are exact copies of the
// previous picture's source, unchanged or at a whole-pixel shift, made inter blocks.
typedef struct av1enc_motion av1enc_motion;
av1enc_motion *av1enc_motion_create(void);
void av1enc_motion_destroy(av1enc_motion *m);
// Per 64x64 (raster) of cur: whether it equals prev unchanged, or else at a candidate shift (the
// left or upper neighbour's, or up to max_candidates from row and column hashes; even and at most
// 1000 samples each way). `planes` planes (1 or 3: Y w x h, chroma half that, rounded up) at their
// strides. out (optional): 3 ints per 64x64, copy (0/1), dx, dy (it copies prev at x + dx,
// y + dy). Returns the copies' count.
int av1enc_motion_classify(av1enc_motion *m, const uint8_t *const cur[3], const int cur_stride[3],
                           const uint8_t *const prev[3], const int prev_stride[3], int width, int height, int planes,
                           int max_candidates, int32_t *out);
// The last classify's shift candidates (dx, dy pairs, best first), up to max; returns the count.
int av1enc_motion_candidates(const av1enc_motion *m, int32_t *out, int max);
// A classify's decisions (sb_motion, as its out) applied to a partition in coding order (and its
// luma tx types and inter blocks, if given): every copied 64x64's blocks replaced by the largest
// legal blocks, skip inter blocks at its shift. *out_blocks / *out_inter / *out_luma_tx (one each
// per block) live in m until its next apply. Returns the block count.
int av1enc_motion_apply(av1enc_motion *m, const int32_t *sb_motion, const av1g_block *blocks, uint32_t n,
                        const uint8_t *luma_tx, const av1g_block_inter *inter, int width,
                        int height, const av1g_block **out_blocks, const av1g_block_inter **out_inter,
                        const uint8_t **out_luma_tx);

#ifdef __cplusplus
}
#endif
#endif
