/* av1g/av1g.h - C API of libav1g (the av1core backend).
 *
 *   av1g_layout()        fill the deterministic tx-block layout of a record
 *   av1g_tile_layout()   tile boundaries for a picture size / tiling choice
 *   av1g_encode()        DecisionRecord -> OBUs (+AVIF) + exact reconstruction
 *
 * All pointers are host pointers.  Thread-safe (no global state).
 */
#ifndef AV1G_AV1G_H
#define AV1G_AV1G_H

#include <stddef.h>
#include <stdint.h>
#include "av1g/decisions.h"

#ifdef __cplusplus
extern "C" {
#endif

#define AV1G_OK              0
#define AV1G_ERR_INVALID    -1  /* record violates an invariant (see out->error) */
#define AV1G_ERR_CAPACITY   -2  /* layout arrays too small (counts written to the record) */
#define AV1G_ERR_RANGE      -3  /* coefficients overflow inverse-transform intermediates */
#define AV1G_ERR_INTERNAL   -4

/* av1g_encode_opts.flags */
#define AV1G_ENC_FIX_RANGE   1u  /* repair non-conformant tx blocks (halve coeffs) */
#define AV1G_ENC_NO_RECON    2u  /* do not return reconstruction planes */
#define AV1G_ENC_TD          4u  /* prefix the OBU stream with a temporal delimiter */
#define AV1G_ENC_AVIF        8u  /* also produce AVIF file bytes */
#define AV1G_ENC_PREFILTER_RECON 0x20u /* recon = before deblocking / CDEF, NOT cropped: planes are
                                         MiCols*4 x MiRows*4 (>> 1 for chroma) because the filters
                                         read the decoded area beyond the picture.  Strength
                                         searches start here; av1g_postfilter finishes it. */
#define AV1G_ENC_BITSTREAM_ONLY 0x10000u /* no reconstruction and no range check: symbol coding only
                                            (~2x faster; for engines that reconstruct themselves and
                                            guarantee conformant coefficients) */

typedef struct av1g_encode_opts {
    uint32_t flags;
    int32_t  seq_level_idx;  /* -1: smallest fitting level (31 if a side < 16) */
} av1g_encode_opts;

typedef struct av1g_output {
    uint8_t *obu;            /* [TD] + OBU_SEQUENCE_HEADER + OBU_FRAME */
    size_t   obu_size;
    uint8_t *avif;           /* AVIF file (AV1G_ENC_AVIF) */
    size_t   avif_size;
    uint8_t *recon[3];       /* cropped planes: Y w x h, U/V ((w+1)/2) x ((h+1)/2) */
    uint32_t recon_w[3], recon_h[3];
    /* stats */
    uint32_t seq_level_idx;
    uint32_t tile_cols, tile_rows;
    uint32_t header_bytes;   /* everything except tile payloads */
    uint64_t tile_bytes;     /* sum of tile payloads */
    uint64_t n_symbols;      /* adaptive symbols + literal bits coded */
    uint32_t n_fixed_txb;    /* tx blocks repaired by AV1G_ENC_FIX_RANGE */
    char     error[256];
} av1g_output;

typedef struct av1g_tiles {
    int32_t  cols_log2, rows_log2;
    uint32_t cols, rows;
    uint32_t mi_col_starts[65];   /* in 4x4 units, [cols] = MiCols */
    uint32_t mi_row_starts[65];
} av1g_tiles;

/* Tile layout for a picture.  cols_log2/rows_log2 = -1 -> minimum legal tiling.
 * Returns AV1G_OK or AV1G_ERR_INVALID (out of range request). */
int av1g_tile_layout(uint32_t width, uint32_t height, int cols_log2, int rows_log2, av1g_tiles *out);

/* Compute the tx-block layout of rec->blocks (positions, sizes, coefficient
 * offsets) into rec->block_txb / rec->txb and set rec->n_txb / rec->n_coeffs.
 * If rec->txb or rec->block_txb is NULL or txb_cap / coeff_cap is too small, only
 * the counts are written and AV1G_ERR_CAPACITY is returned. tx_type/eob are reset. */
int av1g_layout(av1g_decision_record *rec, uint32_t txb_cap, uint64_t coeff_cap);

/* Delta-q helpers (fp.delta_q_present = 1).
 * av1g_legalize_sb_qindex: map per-superblock target qindex values onto values the bitstream
 *   can code with delta_q_res: the nearest v with v == base_q_idx (mod 2^delta_q_res) and
 *   1 <= v <= 255.  Every legal value is reachable from every other one in one SB step
 *   (|reduced delta| <= 254 <= 512, no Clip3 effect), independent of decode order, tiles and
 *   skipped SBs - so engines can quantize with the returned values directly.
 * av1g_apply_sb_qindex: copy a per-SB map (raster over the 64x64 SB grid, sbCols =
 *   (MiCols + 15) >> 4) into blocks[].sb_qindex. */
void av1g_legalize_sb_qindex(int base_q_idx, int delta_q_res, const uint8_t *target, size_t n, uint8_t *legal);
int av1g_apply_sb_qindex(av1g_decision_record *rec, const uint8_t *sb_map);

/* Post-filters (deblocking, then CDEF) exactly as the decoder applies them, in place on a
 * pre-filter reconstruction (av1g_encode with AV1G_ENC_PREFILTER_RECON).  Uses fp's
 * loop_filter_* / cdef_* fields and the blocks' skip / tx_depth / cdef_idx.  planes: Y, U, V
 * (U/V ignored for monochrome), each at least MiCols*4 x MiRows*4 (>> 1 for chroma) with the
 * given strides.  Building blocks for GPU kernels are in av1g/postfilter.h (host + device). */
int av1g_postfilter(const av1g_decision_record *rec, uint8_t *const planes[3], const int stride[3]);

/* Validate a record (block sequence / partition derivation, field ranges).
 * err may be NULL.  Returns AV1G_OK or AV1G_ERR_INVALID. */
int av1g_validate(const av1g_decision_record *rec, char *err, size_t errlen);

/* Encode.  The record must have a valid layout (av1g_layout).  On success the
 * record's txb[].eob and chroma txb[].tx_type are written (and the luma tx_type of
 * all-zero tx blocks is normalised to DCT_DCT, as the spec does); with
 * AV1G_ENC_FIX_RANGE offending coefficients are modified in place. */
int av1g_encode(av1g_decision_record *rec, const av1g_encode_opts *opts, av1g_output *out);
void av1g_output_free(av1g_output *out);

/* Parse an AV1 OBU stream (sequence header + one intra OBU_FRAME using only the
 * Wave-1 toolset: no deblocking/CDEF/LR/QM/delta-q/segmentation/filter-intra/
 * edge filter/palette/intrabc, 64x64 superblocks, uniform tiles) back into a
 * DecisionRecord with all decisions and quantized coefficients.  Used for libaom
 * decision replay.  Free with av1g_parsed_free(). */
typedef struct av1g_parsed {
    av1g_decision_record rec;   /* points into storage owned by this object */
    uint32_t seq_level_idx;
    uint32_t n_tiles;
    const uint32_t *tile_bytes; /* per tile payload size in the parsed stream */
    const uint64_t *tile_offsets; /* per tile payload offset in the parsed buffer */
    char error[256];
    void *priv;
} av1g_parsed;
int av1g_parse(const uint8_t *obus, size_t size, av1g_parsed **out);
void av1g_parsed_free(av1g_parsed *p);

/* AVIF container (port of avif_conversion/hybrid_nvenc_libavif/avif_muxer.py).
 * Caller frees *avif with free(). */
int av1g_mux_avif(const uint8_t *obus, size_t obu_size, uint32_t width, uint32_t height,
                  uint8_t **avif, size_t *avif_size);

/* AVIF with optional ICC profile and orientation (libavif-compatible boxes):
 *   icc/icc_size  colr 'prof' property (the nclx colr is always written as well)
 *   irot          -1: none, else 0..3 = anti-clockwise rotation by 90 * irot degrees ('irot')
 *   imir          -1: none, else 0/1 = mirror axis ('imir'; applied after irot)
 * ispe stays the coded size.  irot/imir are essential transformative properties. */
typedef struct av1g_avif_meta {
    const uint8_t *icc;
    size_t icc_size;
    int32_t irot;
    int32_t imir;
} av1g_avif_meta;
int av1g_mux_avif_ex(const uint8_t *obus, size_t obu_size, uint32_t width, uint32_t height, const av1g_avif_meta *meta,
                     uint8_t **avif, size_t *avif_size);
/* EXIF orientation (1..8, JEITA CP-3451C) -> irot/imir, exactly as libavif
 * (avifImageExtractExifOrientationToIrotImir); 1 or invalid -> -1/-1. */
void av1g_exif_orientation_to_irot_imir(int orientation, int32_t *irot, int32_t *imir);

#ifdef __cplusplus
}
#endif
#endif
