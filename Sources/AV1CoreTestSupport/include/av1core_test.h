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

#ifdef __cplusplus
}
#endif
#endif
