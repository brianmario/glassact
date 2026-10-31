// Test support for AV1Core: av1gpu's random legal decision records, and its
// CPU reference engine. Not for the product.
#ifndef AV1CORE_TEST_H
#define AV1CORE_TEST_H

#include <stdint.h>
#include "av1g/av1g.h"

#ifdef __cplusplus
extern "C" {
#endif

// The random legal record of `seed` (deterministic), as av1gpu's fuzzer makes
// it: sides up to `maxdim`, `big_pct` percent of cases wide enough to force
// several tiles. Laid out (av1g_layout) and ready for av1g_encode.
typedef struct av1t_case av1t_case;
av1t_case *av1t_case_make(uint64_t seed, int maxdim, int big_pct);
av1g_decision_record *av1t_case_record(av1t_case *c);
void av1t_case_free(av1t_case *c);

// A random legal inter sequence of `seed` (deterministic, video mode, see
// av1g/decisions.h): `nframes` frames, the first a key frame, then mostly inter
// frames with random inter / intra blocks, whole-sample motion vectors (some
// far outside the picture), skip / non-skip, var-tx depths, random
// coefficients, reference slots, refresh flags and post-filters; sides up to
// `maxdim`, monochrome and odd sizes included. Every record is laid out and
// ready for av1g_encode_ex: frame k's references are the reconstructions of
// the frames that last refreshed each slot (a key frame refreshes all 8; an
// inter frame the slots in fp.refresh_frame_flags), which the caller tracks.
typedef struct av1t_inter_case av1t_inter_case;
av1t_inter_case *av1t_inter_case_make(uint64_t seed, int maxdim, int nframes);
int av1t_inter_case_frames(const av1t_inter_case *c);
av1g_decision_record *av1t_inter_case_record(av1t_inter_case *c, int frame);
void av1t_inter_case_free(av1t_inter_case *c);

// av1gpu's CPU reference engine (valid and reasonable, not good) on 8-bit
// 4:2:0 planes: Y w x h, U and V ((w+1)/2) x ((h+1)/2), tightly packed.
// Writes the encoded picture (with its reconstruction) to `out`; free it
// with av1g_output_free. Returns AV1G_OK or an error (message in out->error).
typedef struct av1t_ref_opts {
    int32_t qindex;          // 1..255
    int32_t min_block;       // 4 or 8
    int32_t max_block;       // 8..64
    int32_t lf_level;        // deblocking level for every plane, -1 off
    int32_t cdef;            // 1: one fixed CDEF preset
    int32_t edge_filter;     // 1: intra edge filter
} av1t_ref_opts;
int av1t_ref_encode(const uint8_t *y, const uint8_t *u, const uint8_t *v, uint32_t w, uint32_t h,
                    const av1t_ref_opts *opts, av1g_output *out);

// av1gpu's GPU-vs-CPU cases for the shared DSP (av1g_test/dsp_cases.h), with
// the CPU's results. Arrays are tightly packed per case; the case and symbol
// structs are opaque here (Swift only uploads them), sized by *_size.
typedef struct av1t_dsp_set {
    // 1. dequant + inverse transform: coeffs in, residual and conformance flags out
    int32_t itx_count, itx_flagged_count;
    const void *itx_cases;
    uint32_t itx_case_size, itx_coeffs_per_case, itx_residual_per_case;
    const int16_t *itx_coeffs;
    const int32_t *itx_residual;
    const uint32_t *itx_flags;
    // 2./3. intra prediction + CfL: a side x side plane per case in, predicted plane out
    int32_t pred_count, pred_cfl_count, pred_side;
    const void *pred_cases;
    uint32_t pred_case_size, pred_luma_size;
    const uint8_t *pred_planes;
    const uint8_t *pred_luma;
    const uint8_t *pred_out;
    // 4. range coder: symbol streams in, coded bytes out (ec_capacity per stream)
    int32_t ec_count, ec_qindex, ec_symbol_count;
    uint32_t ec_capacity, ec_cdfs_size, ec_symbol_size;
    const void *ec_symbols;
    const int32_t *ec_offsets, *ec_counts;
    const int32_t *ec_sizes;
    const uint8_t *ec_bytes;
    void *priv;
} av1t_dsp_set;
const av1t_dsp_set *av1t_dsp_set_make(uint64_t seed);
void av1t_dsp_set_free(const av1t_dsp_set *set);

// av1core's exact 2-D inverse transform of dequantized coefficients (th x tw,
// row-major, at most 32x32) into residual (W x H). Returns the conformance flags.
uint32_t av1t_inverse_transform(int32_t txSz, int32_t txType, const int32_t *dq, int32_t *residual);
// 1 if txType is in txSz's intra set (DCT only for 64-point sizes).
int32_t av1t_tx_type_allowed(int32_t txSz, int32_t txType);

#ifdef __cplusplus
}
#endif
#endif
