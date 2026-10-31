/* av1g/entenc.h - AV1 multi-symbol range encoder (od_ec) + CDF adaptation.
 *
 * Port of libaom aom_dsp/entenc.c (the classic 32-bit window / 16-bit precarry
 * buffer formulation, which produces the same bytes as the current 64-bit window
 * version) using CDFs in AV1 *spec* format (cumulative, cdf[N-1] == 32768,
 * cdf[N] = adaptation counter).  Header-only, host + device: the caller owns the
 * precarry buffer (uint16 per output byte, carries resolved in av1g_ec_done).
 */
#ifndef AV1G_ENTENC_H
#define AV1G_ENTENC_H

#include <stdint.h>
#include "av1g/hd.h"

typedef struct av1g_ec {
    uint32_t low;       /* od_ec_window */
    uint32_t rng;       /* 32768 <= rng < 65536 */
    int32_t  cnt;
    uint32_t offs;      /* precarry entries written */
    uint32_t cap;       /* capacity of buf */
    uint16_t *buf;      /* precarry buffer */
    int32_t  overflow;  /* set if buf was too small (output invalid) */
} av1g_ec;

AV1G_HD void av1g_ec_init(av1g_ec *e, uint16_t *buf, uint32_t cap) {
    e->low = 0; e->rng = 0x8000; e->cnt = -9; e->offs = 0; e->cap = cap; e->buf = buf; e->overflow = 0;
}

AV1G_HD int av1g_ilog_nz(uint32_t x) { /* 1 + floor(log2(x)), x > 0 */
#if defined(__CUDA_ARCH__)
    return 32 - __clz(x);
#else
    return 32 - __builtin_clz(x);
#endif
}

AV1G_HD void av1g_ec_normalize(av1g_ec *e, uint32_t low, uint32_t rng) {
    int c = e->cnt;
    int d = 16 - av1g_ilog_nz(rng);
    int s = c + d;
    if (s >= 0) {
        if (e->offs + 2 > e->cap) { e->overflow = 1; e->offs = 0; }
        c += 16;
        uint32_t m = (1u << c) - 1;
        if (s >= 8) {
            e->buf[e->offs++] = (uint16_t)(low >> c);
            low &= m;
            c -= 8;
            m >>= 8;
        }
        e->buf[e->offs++] = (uint16_t)(low >> c);
        s = c + d - 24;
        low &= m;
    }
    e->low = low << d;
    e->rng = rng << d;
    e->cnt = s;
}

/* od_ec_encode_q15: fl = 32768 - cumfreq(before s), fh = 32768 - cumfreq(through s) */
AV1G_HD void av1g_ec_encode_q15(av1g_ec *e, uint32_t fl, uint32_t fh, int s, int nsyms) {
    uint32_t l = e->low, r = e->rng;
    const int N = nsyms - 1;
    if (fl < 32768u) {
        uint32_t u = (((r >> 8) * (fl >> 6)) >> 1) + 4u * (uint32_t)(N - (s - 1));
        uint32_t v = (((r >> 8) * (fh >> 6)) >> 1) + 4u * (uint32_t)(N - s);
        l += r - u;
        r = u - v;
    } else {
        r -= (((r >> 8) * (fh >> 6)) >> 1) + 4u * (uint32_t)(N - s);
    }
    av1g_ec_normalize(e, l, r);
}

/* encode symbol s with a spec-format cdf of N symbols (no adaptation) */
AV1G_HD void av1g_ec_encode_cdf(av1g_ec *e, int s, const uint16_t *cdf, int N) {
    uint32_t fl = s > 0 ? 32768u - cdf[s - 1] : 32768u;
    uint32_t fh = 32768u - cdf[s];
    av1g_ec_encode_q15(e, fl, fh, s, N);
}

/* CDF adaptation (spec 8.2.6 symbol decoding process, disable_cdf_update = 0) */
AV1G_HD void av1g_update_cdf(uint16_t *cdf, int s, int N) {
    int cnt = cdf[N];
    int rate = 3 + (cnt > 15) + (cnt > 31) + (N >= 4 ? 2 : 1); /* Min(FloorLog2(N), 2), N >= 2 */
    for (int i = 0; i < N - 1; i++) {
        if (i < s) cdf[i] = (uint16_t)(cdf[i] - (cdf[i] >> rate));
        else cdf[i] = (uint16_t)(cdf[i] + ((32768 - cdf[i]) >> rate));
    }
    cdf[N] = (uint16_t)(cnt + (cnt < 32));
}

/* adaptive symbol (S() descriptor) */
AV1G_HD void av1g_ec_symbol(av1g_ec *e, int s, uint16_t *cdf, int N) {
    av1g_ec_encode_cdf(e, s, cdf, N);
    av1g_update_cdf(cdf, s, N);
}

/* read_bool(): equiprobable bit, cdf {16384, 32768} (never adapted) */
AV1G_HD void av1g_ec_bool(av1g_ec *e, int bit) {
    av1g_ec_encode_q15(e, bit ? 16384u : 32768u, bit ? 0u : 16384u, bit, 2);
}

/* L(n): n-bit literal, MSB first */
AV1G_HD void av1g_ec_literal(av1g_ec *e, uint32_t v, int n) {
    for (int i = n - 1; i >= 0; i--) av1g_ec_bool(e, (v >> i) & 1);
}

/* Flush.  Writes the final bytes (carry-resolved) to out[] (capacity >= offs +
 * 4); returns the number of bytes, or -1 on buffer overflow. */
AV1G_HD int av1g_ec_done(av1g_ec *e, uint8_t *out) {
    uint32_t l = e->low;
    int c = e->cnt;
    int s = 10;
    uint32_t m = 0x3FFF;
    uint32_t en = ((l + m) & ~m) | (m + 1);
    s += c;
    if (s > 0) {
        uint32_t n = (1u << (c + 16)) - 1;
        do {
            if (e->offs + 1 > e->cap) { e->overflow = 1; break; }
            e->buf[e->offs++] = (uint16_t)(en >> (c + 16));
            en &= n;
            s -= 8;
            c -= 8;
            n >>= 8;
        } while (s > 0);
    }
    if (e->overflow) return -1;
    uint32_t offs = e->offs;
    uint32_t carry = 0;
    while (offs > 0) {
        offs--;
        carry = e->buf[offs] + carry;
        out[offs] = (uint8_t)carry;
        carry >>= 8;
    }
    return (int)e->offs;
}

#endif
