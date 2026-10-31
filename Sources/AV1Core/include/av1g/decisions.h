/* av1g/decisions.h - the DecisionRecord: every coding decision + quantized
 * coefficients for ONE AV1 picture (8-bit, 4:2:0 or monochrome, 64x64
 * superblocks): an intra-only still picture (reduced_still_picture_header), or a
 * key frame or inter frame of a video stream (fp.video, see "Video mode" below).
 * Interface version 2 (version 1 records are still accepted: they are still
 * pictures, and the version-2 fields are not read).
 *
 * Any search engine that fills this record gets (a) the exact decoder
 * reconstruction and (b) a conformant OBU stream / AVIF from av1core (av1g.h).
 * Plain C, fixed-size POD records (16-byte block/txb entries), no host-only
 * types: usable from C/C++, CUDA kernels (device pointers) and ctypes/numpy/cupy
 * (structured dtypes, see tools/av1g_ctypes.py).
 *
 * ============================== SPEC / INVARIANTS ===============================
 * Coordinates.  mi_row/mi_col are in units of 4 luma samples.  MiCols =
 *   2*((width+7)>>3), MiRows = 2*((height+7)>>3): the coded area is the picture
 *   padded to a multiple of 8.  Engines must pad their source planes the same way
 *   (edge replication) - samples in the padding are coded and reconstructed like
 *   any others, the output is cropped to width x height.
 *
 * Tiles.  Uniform tile spacing, 64x64 superblocks.  fp.tile_cols_log2 /
 *   fp.tile_rows_log2 = -1 selects the minimum legal tiling (one tile unless the
 *   padded width > 4096 or area > 4096*2304 luma samples); av1g_tile_layout()
 *   returns the tile boundaries.  Edge availability for prediction and contexts is
 *   TILE-LOCAL (AV1 is_inside()).
 *
 * Block order (blocks[]).  Exactly the order of decode_block() calls in the AV1
 *   syntax: tiles in raster order; superblocks in raster order inside the tile;
 *   inside a superblock the pre-order walk of decode_partition():
 *     NONE   : B
 *     HORZ   : top, bottom (bottom omitted when it starts at/after MiRows)
 *     VERT   : left, right (right omitted when it starts at/after MiCols)
 *     SPLIT  : the four quadrants recursively in raster order (quadrants that start
 *              outside the coded area contribute nothing)
 *     HORZ_A : top-left quarter, top-right quarter, bottom half
 *     HORZ_B : top half, bottom-left quarter, bottom-right quarter
 *     VERT_A : top-left quarter, bottom-left quarter, right half
 *     VERT_B : left half, top-right quarter, bottom-right quarter
 *     HORZ_4 : 4 horizontal strips top to bottom (4th omitted if outside)
 *     VERT_4 : 4 vertical strips left to right (4th omitted if outside)
 *   The partition tree is NOT stored: it is uniquely implied by this sequence and
 *   re-derived (and fully validated) by the backend.  Rules the sequence must obey:
 *   8x8 nodes only use NONE/HORZ/VERT/SPLIT; a node whose lower half starts outside
 *   the coded area may only be HORZ or SPLIT, one whose right half starts outside only
 *   VERT or SPLIT, one with both only SPLIT; 128-pixel block sizes are not allowed.
 *   Blocks may extend past the coded area (e.g. a 64x64 block covering 8 visible
 *   columns); only transform blocks whose top-left lies inside are coded.
 *
 * Per-block fields (av1g_block, 16 bytes):
 *   bsize          AV1G_BLOCK_* (any of the 19 sizes 4x4..64x64)
 *   skip           1 = no residual in any plane (coefficients are ignored);
 *                  0 = residual coded (a tx block may still be all-zero)
 *   tx_depth       0..min(2, Max_Tx_Depth[bsize]); luma tx size =
 *                  Max_Tx_Size_Rect[bsize] split tx_depth times (Split_Tx_Size).
 *                  Must be 0 when fp.tx_mode_select == 0 or bsize == 4x4.
 *                  Intra blocks use ONE luma tx size for the whole block; chroma
 *                  always uses the largest size for the chroma block (<= 32x32).
 *   y_mode         AV1G_DC_PRED..AV1G_PAETH_PRED (0..12)
 *   angle_delta_y  -3..3; must be 0 unless y_mode is directional (V_PRED..D67_PRED)
 *                  and bsize >= 8x8 (by size enum: not 4x4/4x8/8x4)
 *   uv_mode        0..12 or AV1G_UV_CFL_PRED (13).  CFL only if max(bw,bh) <= 32.
 *                  Ignored (write 0) when the block carries no chroma (monochrome,
 *                  or 4:2:0 sub-8x8 blocks at even mi_row/mi_col: chroma of a 4xN /
 *                  Nx4 pair is coded with the LAST (odd row/col) block and covers
 *                  the union area).
 *   angle_delta_uv like angle_delta_y but for uv_mode (same bsize >= 8x8 rule,
 *                  uses the LUMA bsize).
 *   cfl_alpha_u/v  -16..16, not both 0, when uv_mode == CFL (else 0).  These are
 *                  the spec's CflAlphaU/V (alpha in 1/8 units, applied with >>6 to
 *                  the 3-bit-scaled luma AC).
 *   sb_qindex      delta-q (fp.delta_q_present = 1): the qindex used for every block of
 *                  this block's superblock (same value in all blocks of the SB; legal values are
 *                  == base_q_idx mod 2^delta_q_res, see av1g_legalize_sb_qindex()).  The backend
 *                  codes the per-SB delta on the first block of each SB (spec read_delta_qindex);
 *                  an SB consisting of a single skipped 64x64 block codes no delta and its value
 *                  is ignored.  0 when delta_q_present = 0.
 *   filter_intra   fp.enable_filter_intra = 1: 0 = off, 1 + FILTER_INTRA_MODE (1..5); only
 *                  for y_mode == DC_PRED and blocks with both sides <= 32 (spec
 *                  filter_intra_mode_info); 0 otherwise.  Luma tx type CDFs then use
 *                  Filter_Intra_Mode_To_Intra_Dir (the backend handles it).
 *   cdef_idx       fp.enable_cdef = 1: preset index 0 .. (1 << cdef_bits) - 1 of this
 *                  block's 64x64; must be the same in every NON-skip block of the 64x64
 *                  (coded once, on the first non-skip block; ignored for skip blocks, an
 *                  all-skip 64x64 is not filtered).  0 when CDEF is off.
 *
 * Transform blocks (txb[], 16 bytes each).  For every block, in order: all luma
 *   tx blocks of the block in raster order, then (if the block carries chroma) all
 *   U tx blocks, then all V tx blocks.  Tx blocks whose top-left sample is outside
 *   the coded area (x >= MiCols*4 >> ssx or y >= MiRows*4 >> ssy) do not exist.
 *   block_txb[b] .. block_txb[b+1]-1 are block b's entries.  The layout (offsets,
 *   positions, sizes) is deterministic given blocks[] - call av1g_layout() (or
 *   reimplement it on the GPU) and then fill tx_type + coefficients.
 *   tx_type        luma: AV1G_DCT_DCT.. that is in the intra set of get_tx_set()
 *                  (DCT only for tx sizes whose square-up is 32 or 64; reduced_tx_set
 *                  selects INTRA_2).  If the tx block's coefficients are all zero the
 *                  type is irrelevant.  chroma: ignored on input; the backend
 *                  writes the derived type (Mode_To_Txfm[uv_mode] if in set, else
 *                  DCT_DCT) - av1g_chroma_tx_type() computes it for engines.
 *   eob            output: written by the backend (last nonzero scan index + 1).
 *
 * Coefficients (coeffs[], int16).  Each tx block owns tw*th values at coeff_off,
 *   tw = min(32, tx width), th = min(32, tx height), ROW-MAJOR (index = row*tw +
 *   col), i.e. exactly the spec's Quant[] array (quantized levels, signed, NOT
 *   dequantized, natural order - the backend applies the scan).  For 64-point
 *   transforms only the top-left 32x32 (16x32/32x16) quadrant exists.  |value| <=
 *   32767 (larger is pointless: dequantized values saturate at 2^15 for 8-bit).
 *   Bitstream conformance also requires every intermediate of the inverse transform
 *   to stay in range (AV1 spec 7.13.2); av1g_encode() checks this and, with
 *   AV1G_ENC_FIX_RANGE, repairs offending tx blocks by halving their coefficients
 *   (reported in the stats) - real quantizers never trip it.
 *
 * Quantizer matrices (fp.using_qmatrix, qm_y/u/v): coefficients stay plain levels;
 *   the decoder's step for coefficient i is Round2(q * W[i], 5) (q = dc/ac quantizer,
 *   W = av1g_qm(...) weights, 32 = flat) - engines quantize with that step.  Tx types
 *   >= IDTX are never weighted.
 *
 * Post-filters (fp.loop_filter_*, fp.enable_cdef / cdef_*): the reconstruction returned
 *   by av1g_encode is the decoder's output, i.e. deblocked then CDEF-filtered;
 *   AV1G_ENC_PREFILTER_RECON returns the padded pre-filter frame instead (strength
 *   searches), av1g_postfilter() / av1g/gpu_postfilter.h apply the filters exactly.
 *   loop_filter_level[4] = effective levels (Y vertical edges, Y horizontal edges, U, V;
 *   0..63; chroma levels need a nonzero luma level), loop_filter_sharpness 0..7 (ref/mode
 *   deltas are not used).  CDEF: damping 3..6 (cdef_damping_minus_3), 1 << cdef_bits presets,
 *   primary strengths 0..15, secondary strengths 0, 1, 2 or 4.
 *
 * Frame-level decisions are in av1g_frame_params.  Lossless (base_q_idx 0), loop
 * restoration, segmentation, delta-lf, palette and intra block copy are not supported.
 *
 * Video mode (fp.video = 1, version 2).  The picture is one frame of a stream: a full
 *   sequence header (not still_picture, no timing info, one operating point, no order
 *   hints, so no ref-frame MVs / skip mode / distance weights; screen content tools
 *   selected per frame; seq_force_integer_mv = 1) and a full frame header (show_frame =
 *   1, primary_ref_frame = NONE: every frame starts from the default CDFs and needs only
 *   its reference pictures; EIGHTTAP interpolation, not switchable; no motion modes,
 *   compound, inter-intra, global or warped motion; reference_select = 0).  Everything the
 *   sequence header carries must be the same in every frame of a stream: width, height,
 *   monochrome, enable_filter_intra, enable_intra_edge_filter, enable_cdef (a frame can
 *   still turn CDEF off with cdef_bits = 0 and zero strengths) and separate_uv_delta_q
 *   (delta_q_v / qm_v differ from U), and the seq_level_idx (pass it in the options when
 *   tilings differ).
 *   fp.frame_type AV1G_FRAME_KEY: a key frame; it refreshes every reference slot, and its
 *     tile data and reconstruction are exactly the still picture's (video = 0).  ref_slot,
 *     refresh_frame_flags and error_resilient_mode must be 0.
 *   fp.lf_inter_off (inter frames): 1 codes loop_filter_delta_enabled with ref deltas
 *     INTRA_FRAME 0 and LAST_FRAME -63, so an inter block's filter level is 0 and an edge is
 *     deblocked only when a block on either side of it is intra (at the frame's levels); an
 *     encoder that copies already-filtered content leaves it as it is.  0: deltas off, every
 *     edge at the frame's levels.  Key frames: 0.
 *   fp.cdf_from_ref (inter frames, error_resilient_mode 0): 1 codes primary_ref_frame = LAST, so
 *     the frame's CDFs start from the ones its reference saved (av1g_output.cdfs, passed back in
 *     av1g_ref_planes.cdfs), not the defaults: a frame of few changes costs few bits.  Every
 *     video frame saves its CDFs (disable_frame_end_update_cdf = 0; context_update_tile_id: the
 *     median tile by block count; none are saved when that tile is reused).  0: primary_ref_frame
 *     NONE, as before.
 *   fp.frame_type AV1G_FRAME_INTER: an inter frame predicting from ONE reference picture
 *     (LAST_FRAME; ref_frame_idx[] of all 7 references = fp.ref_slot); it refreshes the
 *     slots in fp.refresh_frame_flags.  allow_screen_content_tools must be 1 (it carries
 *     force_integer_mv: every motion vector is whole-pel in luma).  Blocks are intra or
 *     inter (av1g_decision_record.inter); intra blocks use the inter-frame syntax (y_mode
 *     CDFs by size group, is_inter, palette flags coded as 0) with the same fields.
 *   The encoder takes the reference pictures (av1g_encode_ex): the decoder's output of
 *   the frames that refreshed each slot (its av1g_output.recon planes, post-filter and
 *   cropped); prediction clamps to their edges as the spec does.
 *
 * Inter blocks (av1g_block_inter, one per block when rec.inter != NULL).
 *   is_inter       1: the block predicts from LAST_FRAME with motion vector (mv_row, mv_col);
 *                  0: an intra block (av1g_block's mode fields apply).  NULL rec.inter, and
 *                  every block of a key frame: intra.
 *   mv_row/mv_col  luma motion in 1/8 sample, multiples of 8 (whole samples), |mv| < 2^14
 *                  (spec is_mv_valid).  May point outside the reference: samples clamp to its
 *                  edges.  Chroma (4:2:0) uses mv / 2: half-sample positions, filtered with
 *                  EIGHTTAP (4-tap for blocks 4 wide / high or less), as the spec specifies.
 *   The mode is not stored: the writer derives it from the MV and the block's MV candidate
 *   stack (spec 7.10.2, which depends only on decisions already coded): mv == 0 -> GLOBALMV
 *   (identity global motion); mv == RefStackMv[0] -> NEARESTMV; mv == RefStackMv[1..3]
 *   (an index the stack has) -> NEARMV with that drl index; otherwise NEWMV, coded as a
 *   difference to the candidate (drl index 0..2 the stack allows) whose difference costs
 *   the fewest MV-class bits (2 + 2 * mv_class per nonzero component, + the drl index; ties
 *   to the lowest index).  The difference must fit (each component |diff| <= 2^14).
 *   An inter block's av1g_block fields: mi_row, mi_col, bsize, skip, tx_depth, cdef_idx,
 *   sb_qindex as for intra blocks; y_mode, angle_delta_y/uv, uv_mode, cfl_alpha_u/v and
 *   filter_intra must be 0.  tx_depth (fp.tx_mode_select = 1, skip = 0): the luma tx size
 *   is Max_Tx_Size_Rect[bsize] split tx_depth times, uniformly over the block (the spec's
 *   var-tx tree, txfm_split coded at every node), 0..min(2, Max_Tx_Depth[bsize]) as for
 *   intra blocks; skip inter blocks have no tx_depth (0).  Luma tx blocks are laid out in
 *   the spec's transform_tree order (recursive halves / quadrants, not raster: they differ
 *   for depth 2), then U and V as for intra blocks.  Luma tx_type: a type of the INTER set
 *   of get_tx_set() (16 types up to 16x16, 12 at 16x16, IDTX / DCT at 32 or with
 *   reduced_tx_set, DCT only at 64).  Chroma tx_type is derived (output): the co-located
 *   luma tx block's type if it is in the chroma size's inter set, else DCT_DCT.
 * ==============================================================================
 */
#ifndef AV1G_DECISIONS_H
#define AV1G_DECISIONS_H

#include <stdint.h>
#include "av1g/enums_gen.h"

#ifdef __cplusplus
extern "C" {
#endif

#define AV1G_DECISIONS_VERSION 2

/* av1g_frame_params.frame_type (video mode) */
#define AV1G_FRAME_KEY   0
#define AV1G_FRAME_INTER 1

typedef struct av1g_block {
    uint16_t mi_row;         /* top-left position, luma 4x4 units */
    uint16_t mi_col;
    uint8_t  bsize;          /* AV1G_BLOCK_* */
    uint8_t  skip;           /* 1: no residual */
    uint8_t  tx_depth;       /* 0..2 */
    uint8_t  y_mode;         /* AV1G_DC_PRED .. AV1G_PAETH_PRED */
    int8_t   angle_delta_y;  /* -3..3 */
    uint8_t  uv_mode;        /* 0..12, 13 = AV1G_UV_CFL_PRED */
    int8_t   angle_delta_uv; /* -3..3 */
    int8_t   cfl_alpha_u;    /* -16..16 (CflAlphaU) */
    int8_t   cfl_alpha_v;    /* -16..16 (CflAlphaV) */
    uint8_t  filter_intra;   /* M5: 0 = off, 1 + filter_intra_mode (fp.enable_filter_intra) */
    int8_t   cdef_idx;       /* M5: CDEF preset of this block's 64x64 (fp.enable_cdef), see above */
    uint8_t  sb_qindex;      /* M5 delta-q: CurrentQIndex of this block's 64x64 superblock (1..255),
                                identical for all blocks of the SB; 0 when fp.delta_q_present == 0 */
} av1g_block;

typedef struct av1g_txb {
    uint32_t coeff_off;      /* layout: first coefficient in coeffs[] */
    uint16_t x4, y4;         /* layout: position in its plane, 4-sample units */
    uint8_t  plane;          /* layout: 0 = Y, 1 = U, 2 = V */
    uint8_t  tx_size;        /* layout: AV1G_TX_* */
    uint8_t  tx_type;        /* decision (luma) / derived output (chroma) */
    uint8_t  flags;          /* reserved, 0 */
    uint16_t eob;            /* output: end of block (0 = all zero) */
    uint16_t reserved;
} av1g_txb;

typedef struct av1g_frame_params {
    uint32_t version;        /* AV1G_DECISIONS_VERSION */
    uint32_t width, height;  /* output picture size, 1..65535 */
    uint8_t  monochrome;     /* 1: Y only (grayscale JPEG) */
    uint8_t  base_q_idx;     /* 1..255 */
    uint8_t  tx_mode_select; /* 0: TX_MODE_LARGEST, 1: TX_MODE_SELECT */
    uint8_t  reduced_tx_set; /* 0/1 */
    int8_t   tile_cols_log2; /* -1 = minimum legal */
    int8_t   tile_rows_log2; /* -1 = minimum legal */
    int8_t   delta_q_y_dc;   /* -64..63 (DeltaQYDc) */
    int8_t   delta_q_u_dc;   /* -64..63 */
    int8_t   delta_q_u_ac;
    int8_t   delta_q_v_dc;   /* if V differs from U the sequence header sets separate_uv_delta_q */
    int8_t   delta_q_v_ac;
    /* ---- M5 (active): intra tools (sequence header flags) ---- */
    uint8_t  enable_filter_intra;      /* 1: blocks may use filter_intra (use_filter_intra is coded) */
    uint8_t  enable_intra_edge_filter; /* 1: intra edge filter + upsampling in directional prediction */
    /* ---- M5 (active): per-superblock delta-q and quantizer matrices ---- */
    uint8_t  delta_q_present;  /* 1: every SB carries its own qindex (av1g_block.sb_qindex) */
    uint8_t  delta_q_res;      /* 0..3: SB qindex values must be == base_q_idx mod (1 << delta_q_res);
                                  av1g_legalize_sb_qindex() maps a target map onto legal values */
    uint8_t  using_qmatrix;    /* 1: quantizer matrices; levels 0..15 (15 = flat) per plane */
    uint8_t  qm_y, qm_u, qm_v; /* qm_v != qm_u sets separate_uv_delta_q in the sequence header */
    /* ---- M5 (active): post-filters (see "Post-filters" above) ---- */
    uint8_t  loop_filter_level[4];     /* Y vert, Y horz, U, V: 0..63 (0, 0, x, x = no deblocking) */
    uint8_t  loop_filter_sharpness;    /* 0..7 */
    uint8_t  enable_cdef, cdef_damping_minus_3, cdef_bits;   /* 0/1, 0..3, 0..3 */
    uint8_t  cdef_y_pri[8], cdef_y_sec[8], cdef_uv_pri[8], cdef_uv_sec[8];  /* pri 0..15, sec 0/1/2/4 */
    /* ---- v1 extension (0 = off, backward compatible) ---- */
    uint8_t  allow_screen_content_tools; /* 1: frame header allows screen content tools; palette is still
                                            never used (has_palette_y/uv coded as 0).  Only needed to
                                            replay libaom streams whose screen-content detection set it.
                                            Inter frames: must be 1 (force_integer_mv). */
    /* ---- v2: video mode (0 = a still picture, as in v1), see "Video mode" above ---- */
    uint8_t  video;                /* 1: one frame of a stream (full sequence + frame headers) */
    uint8_t  frame_type;           /* AV1G_FRAME_KEY / AV1G_FRAME_INTER (needs video) */
    uint8_t  ref_slot;             /* inter: the reference slot 0..7 LAST_FRAME (all 7 refs) uses */
    uint8_t  refresh_frame_flags;  /* inter: bit i = this frame replaces slot i (0 = none) */
    uint8_t  error_resilient_mode; /* inter: 0/1 (header only: primary_ref_frame is NONE anyway) */
    uint8_t  lf_inter_off;         /* inter: 1 = inter blocks are not deblocked (see "Video mode") */
    uint8_t  cdf_from_ref;         /* inter: 1 = start from the reference's saved CDFs (see "Video mode") */
    uint8_t  reserved[8];
} av1g_frame_params;

typedef struct av1g_block_inter {
    int16_t  mv_row;         /* luma, 1/8 sample, multiple of 8 */
    int16_t  mv_col;
    uint8_t  is_inter;       /* 1: inter (LAST_FRAME), 0: intra */
    uint8_t  reserved[3];    /* 0 */
} av1g_block_inter;

typedef struct av1g_decision_record {
    av1g_frame_params fp;
    uint32_t    n_blocks;
    uint32_t    n_txb;       /* set by av1g_layout() */
    uint64_t    n_coeffs;    /* set by av1g_layout() */
    av1g_block *blocks;      /* [n_blocks] decode order */
    uint32_t   *block_txb;   /* [n_blocks + 1] first txb of each block (layout) */
    av1g_txb   *txb;         /* [n_txb] */
    int16_t    *coeffs;      /* [n_coeffs] */
    /* ---- v2 ---- */
    av1g_block_inter *inter; /* [n_blocks] or NULL: every block intra (read for version >= 2 only) */
} av1g_decision_record;

#ifdef __cplusplus
}
#endif
#endif
