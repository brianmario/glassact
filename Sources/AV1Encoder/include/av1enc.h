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
// luma_tx (optional): every block's luma tx type from the analysis (the closed loop searches its own). flags:
// AV1ENC_HYBRID_GIVEN_CHROMA: the blocks' uv_mode / angle_delta_uv / cfl_alpha_* are decided already.
#define AV1ENC_HYBRID_GIVEN_CHROMA 1
int av1enc_hybrid_closed_loop(av1enc_hybrid *h, const uint8_t *y, const uint8_t *u, const uint8_t *v, uint32_t w,
                              uint32_t hgt, const av1g_block *blocks, uint32_t n, const uint8_t *luma_tx, int flags,
                              int qindex, int tile_cols_log2, int tile_rows_log2, char *err, size_t errlen);
// av1enc_hybrid_closed_loop for a frame of a stream: video (null: a still picture) supplies the
// frame's video fields (video, frame_type, ref_slot, refresh_frame_flags, error_resilient_mode,
// lf_inter_off, allow_screen_content_tools, cdf_from_ref, mv_precision, sb128, golden_slot; the rest is ignored). An inter frame takes inter (one
// per block, or null: all intra) and ref, LAST_FRAME's picture (the decoder's output of the frame
// in ref_slot: planes of the picture's size at their strides); with golden_slot, ref points to two:
// LAST_FRAME's, then GOLDEN_FRAME's (the output of the frame in golden_slot - 1). Inter blocks are
// skip blocks (tx_depth 0, intra fields 0) and copy their reference at their motion vector. An inter frame's
// tiles are coded afresh, and the next picture's aren't kept from it. With sb128 the blocks are in
// 128x128-superblock decode order (av1enc_motion_apply_ex makes it from a 64x64 one), tiled as
// av1g_tile_layout_ex(..., 1) gives it, and inter blocks may be 128x128, 128x64 or 64x128.
// padded (null, or with video: 3 planes) is the source already padded to whole 64x64s by edge
// replication, as the Metal analysis pads it: luma sb_cols * 64 x sb_rows * 64 (sb_cols =
// (MiCols + 15) / 16), chroma half each way, tight. An inter frame's closed loop reads it in
// place of padding its own copy (a key frame pads its own, which the next picture compares tiles
// with); it must stay unchanged until the call returns, and av1enc_hybrid_source then gives
// null.
// recon (null, or 3 planes of av1enc_hybrid_recon's size: MiCols * 4 x MiRows * 4, chroma half
// each way, tight) is where the reconstruction goes as well: an inter frame writes it there in
// place of its own (av1enc_hybrid_recon then gives null), any other frame keeps its own (the next
// picture's tiles are kept from it) and copies it there.
int av1enc_hybrid_closed_loop_ex(av1enc_hybrid *h, const uint8_t *y, const uint8_t *u, const uint8_t *v, uint32_t w,
                                 uint32_t hgt, const av1g_block *blocks, uint32_t n, const uint8_t *luma_tx, int flags,
                                 int qindex, int tile_cols_log2, int tile_rows_log2, const av1g_frame_params *video,
                                 const av1g_block_inter *inter, const av1g_ref_planes *ref,
                                 const uint8_t *const *padded, uint8_t *const *recon, char *err, size_t errlen);
av1g_decision_record *av1enc_hybrid_record(av1enc_hybrid *h);
// The bitstream of the last closed loop's picture with the post-filter parameters chosen (fp, its
// other fields as the closed loop's: video fields, sb128) and every 64x64's cdef_idx (raster,
// sb_cols wide; -1 as 0; a non-skip block larger than 64x64 takes its top-left 64x64's for every
// 64x64 it covers): [TD,] sequence header and frame. A tile
// whose closed loop was kept, and whose cdef_idx values and cdef_bits are as last written, keeps
// its bytes. *obu is malloc'd (free it).
int av1enc_hybrid_write(av1enc_hybrid *h, const av1g_frame_params *fp, const int8_t *sb_cdef, int sb_cols,
                        uint8_t **obu, size_t *size, char *err, size_t errlen);
// av1enc_hybrid_write with encode flags: AV1G_ENC_NO_SEQ_HEADER (a later frame of a video stream,
// whose earlier sequence header applies: [TD,] frame) or 0.
int av1enc_hybrid_write_ex(av1enc_hybrid *h, const av1g_frame_params *fp, const int8_t *sb_cdef, int sb_cols,
                           uint32_t flags, uint8_t **obu, size_t *size, char *err, size_t errlen);
// Keep unchanged tiles' closed loop and bitstream from picture to picture (on by default).
void av1enc_hybrid_set_reuse(av1enc_hybrid *h, int on);
// The closed loop searches intra blocks' luma tx types (else keeps the analysis's) and inter
// blocks' (else DCT_DCT): both on by default.
void av1enc_hybrid_set_tx_search(av1enc_hybrid *h, int luma, int inter);
// The closed loop's levels optimized by rate and distortion after the dead-zone quantizer, with
// costs from the frame's coefficient CDFs (off by default), in tx blocks whose source spans at
// least min_range values (0: all); with trials, the luma tx type search compares each type's
// levels after RDOQ.
void av1enc_hybrid_set_rdoq(av1enc_hybrid *h, int on, int trials, int min_range);
// The luma tx type search tries only what the learned tx model keeps, until all but eps of the
// probability (and DCT_DCT); eps < 0: off (the default). Off too without shipped weights.
void av1enc_hybrid_set_tx_model(av1enc_hybrid *h, float eps);
// The luma tx type search measures each compared type's distortion in the transform domain (no
// inverse transform), and stops at DCT_DCT, the first type tried, when that codes nothing. Off
// (the default): the exact reconstruction's SSE, every type.
void av1enc_hybrid_set_quick_tx_trials(av1enc_hybrid *h, int on);
// The next pictures' qindex per 64x64 superblock (raster, sb_cols x sb_rows, 1..255), coded with
// delta_q_present: their blocks are quantized and their RD weighed by it. NULL / 0: the frame's
// qindex everywhere. Not with 128x128 superblocks (the frame's then).
void av1enc_hybrid_set_sb_qindex(av1enc_hybrid *h, const uint8_t *map, size_t n);
// Key frames search for intra block copies (off by default). A frame where blocks copy has no
// post-filters: the record's fp.allow_intrabc is 1, and av1enc_hybrid_write_ex keeps it so (no
// deblocking, every cdef_idx 0) whatever fp it's given.
void av1enc_hybrid_set_intrabc(av1enc_hybrid *h, int on);
// A picture's intra block copy hashes, taken ahead of its closed loop on any thread (each handle
// on one at a time): av1enc_ibc_hashes_compute of its luma (rows width apart), then
// av1enc_hybrid_use_ibc_hashes right before that picture's av1enc_hybrid_closed_loop_ex, which
// then needn't take them (the handle gets the buffer they replace, to compute into again).
typedef struct av1enc_ibc_hashes av1enc_ibc_hashes;
av1enc_ibc_hashes *av1enc_ibc_hashes_create(void);
void av1enc_ibc_hashes_destroy(av1enc_ibc_hashes *p);
void av1enc_ibc_hashes_compute(av1enc_ibc_hashes *p, const uint8_t *y, uint32_t width, uint32_t height);
void av1enc_hybrid_use_ibc_hashes(av1enc_hybrid *h, av1enc_ibc_hashes *p);
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
// av1enc_motion_classify, then the 64x64s that don't copy prev against golden (null: none), an
// older picture (GOLDEN_FRAME's), the same way. out's copy is 2 for a copy of golden; apply makes
// it GOLDEN_FRAME inter blocks. av1enc_motion_candidates stay prev's.
int av1enc_motion_classify_ex(av1enc_motion *m, const uint8_t *const cur[3], const int cur_stride[3],
                              const uint8_t *const prev[3], const int prev_stride[3],
                              const uint8_t *const golden[3], const int golden_stride[3], int width, int height,
                              int planes, int max_candidates, int32_t *out);
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
// av1enc_motion_apply for 64x64 (sb128 = 0: exactly it) or 128x128 superblocks (sb128 = 1, the
// frame's tiling tile_cols_log2 / tile_rows_log2 as av1g_tile_layout_ex gives it; -1 minimum).
// With 128x128 superblocks `blocks` is a partition into 64x64s: every block inside one 64x64, each
// 64x64's blocks contiguous and in its own coding order (as av1enc_motion_apply takes them), the
// 64x64s in any order (e.g. tiles of 64x64s in raster order); every 64x64 starting inside the coded
// area has blocks unless sb_motion copies it.  The output is in the 128x128 superblocks' decode
// order: tiles in raster order, a tile's 128x128s in raster order, a 128x128's four 64x64 quadrants
// in raster order (each its blocks, or a copied one's cover).  A 128x128 whose quadrants inside the
// coded area are all copies at one shift becomes one 128x128 skip inter block (128x64 / 64x128, or
// its quadrants' covers, where only part of it is inside).  Returns the block count, or -1 (blocks
// not of that form, or an illegal tiling).
int av1enc_motion_apply_ex(av1enc_motion *m, const int32_t *sb_motion, const av1g_block *blocks, uint32_t n,
                           const uint8_t *luma_tx, const av1g_block_inter *inter, int width, int height, int sb128,
                           int tile_cols_log2, int tile_rows_log2, const av1g_block **out_blocks,
                           const av1g_block_inter **out_inter, const uint8_t **out_luma_tx);

#ifdef __cplusplus
}
#endif
#endif
