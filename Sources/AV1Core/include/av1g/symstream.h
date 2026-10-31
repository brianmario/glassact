/* av1g/symstream.h - per-tile symbol streams (M4).
 *
 * A tile's entropy-coded payload is fully determined by its ordered list of
 * (cdf, symbol, alphabet) triples; the CDF *values* evolve during coding but the
 * cdf *identities* do not depend on them.  So symbolization (contexts) is parallel
 * and only od_ec + CDF adaptation is serial per tile.
 *
 * One uint32 per syntax element:
 *   bits  0..15  cdf id = uint16 offset of the CDF inside av1g_cdfs
 *   bits 16..19  symbol value
 *   bits 20..23  N - 1 (alphabet size, 2..16)
 *   bits 24..25  kind: 0 adaptive symbol, 1 equiprobable bit (read_bool),
 *                      2 split_or_horz, 3 split_or_vert (bool derived from the
 *                      *current* partition CDF at cdf id, spec 8.3.2)
 */
#ifndef AV1G_SYMSTREAM_H
#define AV1G_SYMSTREAM_H

#include <stdint.h>
#include "av1g/hd.h"
#include "av1g/entenc.h"
#include "av1g/cdfctx.h"

#define AV1G_SYM_ADAPT 0u
#define AV1G_SYM_BOOL 1u
#define AV1G_SYM_SPLIT_OR_HORZ 2u
#define AV1G_SYM_SPLIT_OR_VERT 3u

AV1G_HD uint32_t av1g_sym_pack(uint32_t kind, uint32_t cdf, uint32_t s, uint32_t N) {
    return (cdf & 0xFFFFu) | ((s & 15u) << 16) | (((N - 1) & 15u) << 20) | (kind << 24);
}

/* psum of the partition symbols that imply "split" for split_or_horz / split_or_vert */
AV1G_HD uint32_t av1g_split_or_psum(const uint16_t *pc, int vert) {
#define P_(x) ((uint32_t)pc[x] - (x > 0 ? (uint32_t)pc[(x) - 1] : 0u))
    if (!vert)  /* split_or_horz */
        return P_(AV1G_PARTITION_VERT) + P_(AV1G_PARTITION_SPLIT) + P_(AV1G_PARTITION_HORZ_A) +
               P_(AV1G_PARTITION_VERT_A) + P_(AV1G_PARTITION_VERT_B) + P_(AV1G_PARTITION_VERT_4);
    return P_(AV1G_PARTITION_HORZ) + P_(AV1G_PARTITION_SPLIT) + P_(AV1G_PARTITION_HORZ_A) +
           P_(AV1G_PARTITION_HORZ_B) + P_(AV1G_PARTITION_VERT_A) + P_(AV1G_PARTITION_HORZ_4);
#undef P_
}

/* Entropy-code one tile's symbol stream.  cdf must be initialised with
 * av1g_cdfs_init(cdf, base_q_idx); ec initialised with av1g_ec_init(). */
AV1G_HD void av1g_code_symbols(const uint32_t *syms, uint32_t n, av1g_cdfs *cdf, av1g_ec *ec) {
    uint16_t *base = (uint16_t *)cdf;
    for (uint32_t i = 0; i < n; i++) {
        const uint32_t w = syms[i];
        const uint32_t kind = w >> 24, s = (w >> 16) & 15u, N = ((w >> 20) & 15u) + 1, off = w & 0xFFFFu;
        if (kind == AV1G_SYM_ADAPT) {
            av1g_ec_symbol(ec, (int)s, base + off, (int)N);
        } else if (kind == AV1G_SYM_BOOL) {
            av1g_ec_bool(ec, (int)s);
        } else {
            const uint32_t psum = av1g_split_or_psum(base + off, kind == AV1G_SYM_SPLIT_OR_VERT);
            uint16_t tmp[2] = {(uint16_t)(32768u - psum), 32768u};
            av1g_ec_encode_cdf(ec, (int)s, tmp, 2);
        }
    }
}

#endif
