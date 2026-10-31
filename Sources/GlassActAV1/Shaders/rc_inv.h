// Glass Act: av1gpu encoder/src/rc_inv.cuh (BSD-2, Sources/AV1Core/LICENSE), for Metal through
// cuda_compat.h; only `qm` gained AV1G_CONST. RcInvTests checks it against av1core's av1g_inv_txfm2d.
// W4: register-resident exact inverse transforms for k_recon.
//
// Templated copies of av1core dsp.h av1g_idct / av1g_iadst4/8/16 / av1g_iidentity / av1g_inv_1d with the
// transform size as a template parameter and every loop unrolled, so the working array lives in registers
// instead of local memory (the generic versions index int32_t T[64] / copyT[64] dynamically: ~45 % of
// k_recon's local stores).  The integer operations, their order and the conformance checks are the same as
// in av1core, so the residual and the error flags are bit-identical.
#pragma once
#include <stdint.h>
#include "av1g/dsp.h"
#include "cuda_compat.h"

namespace rci {

__host__ __device__ constexpr int brev(int numBits, int x) {
    int t = 0;
    for (int i = 0; i < numBits; i++) t |= ((x >> i) & 1) << (numBits - 1 - i);
    return t;
}
__device__ __forceinline__ int cos128(int angle) { return av1g_cos128(angle); }
__device__ __forceinline__ int sin128(int angle) { return av1g_cos128(angle - 64); }
__device__ __forceinline__ void chk(int64_t v, int bits, uint32_t &err, uint32_t flag) {
    if (v < -((int64_t)1 << (bits - 1)) || v > ((int64_t)1 << (bits - 1)) - 1) err |= flag;
}
template <int L>
__device__ __forceinline__ void B(int32_t (&T)[L], int a, int b, int angle, int flip, int r, uint32_t &err) {
    const int64_t c = cos128(angle), s = sin128(angle);
    const int64_t x = (int64_t)T[a] * c - (int64_t)T[b] * s;
    const int64_t y = (int64_t)T[a] * s + (int64_t)T[b] * c;
    const int64_t xa = av1g_round2_64(x, 12), yb = av1g_round2_64(y, 12);
    chk(xa, r, err, AV1G_ERR_B_RANGE);
    chk(yb, r, err, AV1G_ERR_B_RANGE);
    if (flip) { T[a] = (int32_t)yb; T[b] = (int32_t)xa; }
    else      { T[a] = (int32_t)xa; T[b] = (int32_t)yb; }
}
template <int L>
__device__ __forceinline__ void H(int32_t (&T)[L], int a, int b, int flip, int r) {
    if (flip) { const int t = a; a = b; b = t; }
    const int64_t x = T[a], y = T[b];
    const int64_t lo = -((int64_t)1 << (r - 1)), hi = ((int64_t)1 << (r - 1)) - 1;
    const int64_t s = x + y, d = x - y;
    T[a] = (int32_t)(s < lo ? lo : (s > hi ? hi : s));
    T[b] = (int32_t)(d < lo ? lo : (d > hi ? hi : d));
}

template <int n>
__device__ __forceinline__ void idct(int32_t (&T)[1 << n], int r, uint32_t &err) {
    constexpr int n0 = 1 << n;
    int32_t copyT[n0];
#pragma unroll
    for (int i = 0; i < n0; i++) copyT[i] = T[i];
#pragma unroll
    for (int i = 0; i < n0; i++) T[i] = copyT[brev(n, i)];                                     /* step 1 */
    if constexpr (n == 6) {
#pragma unroll
        for (int i = 0; i < 16; i++) B(T, 32 + i, 63 - i, 63 - 4 * brev(4, i), 0, r, err);
    }
    if constexpr (n >= 5) {
#pragma unroll
        for (int i = 0; i < 8; i++) B(T, 16 + i, 31 - i, 6 + (brev(3, 7 - i) << 3), 0, r, err);
    }
    if constexpr (n == 6) {
#pragma unroll
        for (int i = 0; i < 16; i++) H(T, 32 + i * 2, 33 + i * 2, i & 1, r);
    }
    if constexpr (n >= 4) {
#pragma unroll
        for (int i = 0; i < 4; i++) B(T, 8 + i, 15 - i, 12 + (brev(2, 3 - i) << 4), 0, r, err);
    }
    if constexpr (n >= 5) {
#pragma unroll
        for (int i = 0; i < 8; i++) H(T, 16 + 2 * i, 17 + 2 * i, i & 1, r);
    }
    if constexpr (n == 6) {
#pragma unroll
        for (int i = 0; i < 4; i++)
#pragma unroll
            for (int j = 0; j < 2; j++) B(T, 62 - i * 4 - j, 33 + i * 4 + j, 60 - 16 * brev(2, i) + 64 * j, 1, r, err);
    }
    if constexpr (n >= 3) {
#pragma unroll
        for (int i = 0; i < 2; i++) B(T, 4 + i, 7 - i, 56 - 32 * i, 0, r, err);
    }
    if constexpr (n >= 4) {
#pragma unroll
        for (int i = 0; i < 4; i++) H(T, 8 + 2 * i, 9 + 2 * i, i & 1, r);
    }
    if constexpr (n >= 5) {
#pragma unroll
        for (int i = 0; i < 2; i++)
#pragma unroll
            for (int j = 0; j < 2; j++) B(T, 30 - 4 * i - j, 17 + 4 * i + j, 24 + (j << 6) + ((1 - i) << 5), 1, r, err);
    }
    if constexpr (n == 6) {
#pragma unroll
        for (int i = 0; i < 8; i++)
#pragma unroll
            for (int j = 0; j < 2; j++) H(T, 32 + i * 4 + j, 35 + i * 4 - j, i & 1, r);
    }
#pragma unroll
    for (int i = 0; i < 2; i++) B(T, 2 * i, 2 * i + 1, 32 + 16 * i, 1 - i, r, err);              /* step 12 */
    if constexpr (n >= 3) {
#pragma unroll
        for (int i = 0; i < 2; i++) H(T, 4 + 2 * i, 5 + 2 * i, i, r);
    }
    if constexpr (n >= 4) {
#pragma unroll
        for (int i = 0; i < 2; i++) B(T, 14 - i, 9 + i, 48 + 64 * i, 1, r, err);
    }
    if constexpr (n >= 5) {
#pragma unroll
        for (int i = 0; i < 4; i++)
#pragma unroll
            for (int j = 0; j < 2; j++) H(T, 16 + 4 * i + j, 19 + 4 * i - j, i & 1, r);
    }
    if constexpr (n == 6) {
#pragma unroll
        for (int i = 0; i < 2; i++)
#pragma unroll
            for (int j = 0; j < 4; j++) B(T, 61 - i * 8 - j, 34 + i * 8 + j, 56 - i * 32 + (j >> 1) * 64, 1, r, err);
    }
#pragma unroll
    for (int i = 0; i < 2; i++) H(T, i, 3 - i, 0, r);                                            /* step 17 */
    if constexpr (n >= 3) B(T, 6, 5, 32, 1, r, err);
    if constexpr (n >= 4) {
#pragma unroll
        for (int i = 0; i < 2; i++)
#pragma unroll
            for (int j = 0; j < 2; j++) H(T, 8 + 4 * i + j, 11 + 4 * i - j, i, r);
    }
    if constexpr (n >= 5) {
#pragma unroll
        for (int i = 0; i < 4; i++) B(T, 29 - i, 18 + i, 48 + (i >> 1) * 64, 1, r, err);
    }
    if constexpr (n == 6) {
#pragma unroll
        for (int i = 0; i < 4; i++)
#pragma unroll
            for (int j = 0; j < 4; j++) H(T, 32 + 8 * i + j, 39 + 8 * i - j, i & 1, r);
    }
    if constexpr (n >= 3) {
#pragma unroll
        for (int i = 0; i < 4; i++) H(T, i, 7 - i, 0, r);                                       /* step 22 */
    }
    if constexpr (n >= 4) {
#pragma unroll
        for (int i = 0; i < 2; i++) B(T, 13 - i, 10 + i, 32, 1, r, err);
    }
    if constexpr (n >= 5) {
#pragma unroll
        for (int i = 0; i < 2; i++)
#pragma unroll
            for (int j = 0; j < 4; j++) H(T, 16 + i * 8 + j, 23 + i * 8 - j, i, r);
    }
    if constexpr (n == 6) {
#pragma unroll
        for (int i = 0; i < 8; i++) B(T, 59 - i, 36 + i, i < 4 ? 48 : 112, 1, r, err);
    }
    if constexpr (n >= 4) {
#pragma unroll
        for (int i = 0; i < 8; i++) H(T, i, 15 - i, 0, r);                                      /* step 26 */
    }
    if constexpr (n >= 5) {
#pragma unroll
        for (int i = 0; i < 4; i++) B(T, 27 - i, 20 + i, 32, 1, r, err);
    }
    if constexpr (n == 6) {
#pragma unroll
        for (int i = 0; i < 8; i++) { H(T, 32 + i, 47 - i, 0, r); H(T, 48 + i, 63 - i, 1, r); }
    }
    if constexpr (n >= 5) {
#pragma unroll
        for (int i = 0; i < 16; i++) H(T, i, 31 - i, 0, r);
    }
    if constexpr (n == 6) {
#pragma unroll
        for (int i = 0; i < 8; i++) B(T, 55 - i, 40 + i, 32, 1, r, err);
    }
    if constexpr (n == 6) {
#pragma unroll
        for (int i = 0; i < 32; i++) H(T, i, 63 - i, 0, r);                                     /* step 31 */
    }
}

template <int n>
__device__ __forceinline__ void iadst_in_perm(int32_t (&T)[1 << n]) {
    constexpr int n0 = 1 << n;
    int32_t copyT[n0];
#pragma unroll
    for (int i = 0; i < n0; i++) copyT[i] = T[i];
#pragma unroll
    for (int i = 0; i < n0; i++) T[i] = copyT[(i & 1) ? (i - 1) : (n0 - i - 1)];
}
template <int n>
__device__ __forceinline__ void iadst_out_perm(int32_t (&T)[1 << n]) {
    constexpr int n0 = 1 << n;
    int32_t copyT[n0];
#pragma unroll
    for (int i = 0; i < n0; i++) copyT[i] = T[i];
#pragma unroll
    for (int i = 0; i < n0; i++) {
        const int a = (i >> 3) & 1;
        const int b = ((i >> 2) & 1) ^ ((i >> 3) & 1);
        const int c = ((i >> 1) & 1) ^ ((i >> 2) & 1);
        const int d = (i & 1) ^ ((i >> 1) & 1);
        const int idx = ((d << 3) | (c << 2) | (b << 1) | a) >> (4 - n);
        T[i] = (i & 1) ? -copyT[idx] : copyT[idx];
    }
}

__device__ __forceinline__ void iadst4(int32_t (&T)[4], int r, uint32_t &err) {
    const int64_t SINPI_1_9 = 1321, SINPI_2_9 = 2482, SINPI_3_9 = 3344, SINPI_4_9 = 3803;
    int64_t s[7], x[4];
    s[0] = SINPI_1_9 * T[0];
    s[1] = SINPI_2_9 * T[0];
    s[2] = SINPI_3_9 * T[1];
    s[3] = SINPI_4_9 * T[2];
    s[4] = SINPI_1_9 * T[2];
    s[5] = SINPI_2_9 * T[3];
    s[6] = SINPI_4_9 * T[3];
    const int64_t a7 = (int64_t)T[0] - T[2];
    const int64_t b7 = a7 + T[3];
    chk(a7, r + 1, err, AV1G_ERR_ADST4_RANGE);
    chk(b7, r, err, AV1G_ERR_ADST4_RANGE);
#pragma unroll
    for (int i = 0; i < 7; i++) chk(s[i], r + 12, err, AV1G_ERR_ADST4_RANGE);
    s[0] = s[0] + s[3];
    s[1] = s[1] - s[4];
    s[3] = s[2];
    s[2] = SINPI_3_9 * b7;
    chk(s[0], r + 12, err, AV1G_ERR_ADST4_RANGE);
    chk(s[1], r + 12, err, AV1G_ERR_ADST4_RANGE);
    chk(s[2], r + 12, err, AV1G_ERR_ADST4_RANGE);
    s[0] = s[0] + s[5];
    s[1] = s[1] - s[6];
    chk(s[0], r + 12, err, AV1G_ERR_ADST4_RANGE);
    chk(s[1], r + 12, err, AV1G_ERR_ADST4_RANGE);
    x[0] = s[0] + s[3];
    x[1] = s[1] + s[3];
    x[2] = s[2];
    x[3] = s[0] + s[1];
    chk(x[3], r + 12, err, AV1G_ERR_ADST4_RANGE);
    x[3] = x[3] - s[3];
#pragma unroll
    for (int i = 0; i < 4; i++) chk(x[i], r + 12, err, AV1G_ERR_ADST4_RANGE);
#pragma unroll
    for (int i = 0; i < 4; i++) T[i] = (int32_t)av1g_round2_64(x[i], 12);
}
__device__ __forceinline__ void iadst8(int32_t (&T)[8], int r, uint32_t &err) {
    iadst_in_perm<3>(T);
#pragma unroll
    for (int i = 0; i < 4; i++) B(T, 2 * i, 2 * i + 1, 60 - 16 * i, 1, r, err);
#pragma unroll
    for (int i = 0; i < 4; i++) H(T, i, 4 + i, 0, r);
#pragma unroll
    for (int i = 0; i < 2; i++) B(T, 4 + 3 * i, 5 + i, 48 - 32 * i, 1, r, err);
#pragma unroll
    for (int i = 0; i < 2; i++)
#pragma unroll
        for (int j = 0; j < 2; j++) H(T, 4 * j + i, 2 + 4 * j + i, 0, r);
#pragma unroll
    for (int i = 0; i < 2; i++) B(T, 2 + 4 * i, 3 + 4 * i, 32, 1, r, err);
    iadst_out_perm<3>(T);
}
__device__ __forceinline__ void iadst16(int32_t (&T)[16], int r, uint32_t &err) {
    iadst_in_perm<4>(T);
#pragma unroll
    for (int i = 0; i < 8; i++) B(T, 2 * i, 2 * i + 1, 62 - 8 * i, 1, r, err);
#pragma unroll
    for (int i = 0; i < 8; i++) H(T, i, 8 + i, 0, r);
#pragma unroll
    for (int i = 0; i < 2; i++) {
        B(T, 8 + 2 * i, 9 + 2 * i, 56 - 32 * i, 1, r, err);
        B(T, 13 + 2 * i, 12 + 2 * i, 8 + 32 * i, 1, r, err);
    }
#pragma unroll
    for (int i = 0; i < 4; i++)
#pragma unroll
        for (int j = 0; j < 2; j++) H(T, 8 * j + i, 4 + 8 * j + i, 0, r);
#pragma unroll
    for (int i = 0; i < 2; i++)
#pragma unroll
        for (int j = 0; j < 2; j++) B(T, 4 + 8 * j + 3 * i, 5 + 8 * j + i, 48 - 32 * i, 1, r, err);
#pragma unroll
    for (int i = 0; i < 2; i++)
#pragma unroll
        for (int j = 0; j < 4; j++) H(T, 4 * j + i, 2 + 4 * j + i, 0, r);
#pragma unroll
    for (int i = 0; i < 4; i++) B(T, 2 + 4 * i, 3 + 4 * i, 32, 1, r, err);
    iadst_out_perm<4>(T);
}
template <int n>
__device__ __forceinline__ void iidentity(int32_t (&T)[1 << n]) {
#pragma unroll
    for (int i = 0; i < (1 << n); i++) {
        if constexpr (n == 2) T[i] = (int32_t)av1g_round2_64((int64_t)T[i] * 5793, 12);
        else if constexpr (n == 3) T[i] = T[i] * 2;
        else if constexpr (n == 4) T[i] = (int32_t)av1g_round2_64((int64_t)T[i] * 11586, 12);
        else T[i] = T[i] * 4;
    }
}
// av1g_inv_1d for a compile-time size (kinds that do not exist at a size are never requested)
template <int n>
__device__ __forceinline__ void inv_1d(int32_t (&T)[1 << n], int kind, int r, uint32_t &err) {
    if (kind == AV1G_K_DCT) idct<n>(T, r, err);
    else if (kind == AV1G_K_ADST) {
        if constexpr (n == 2) iadst4(T, r, err);
        else if constexpr (n == 3) iadst8(T, r, err);
        else if constexpr (n == 4) iadst16(T, r, err);
    } else {
        if constexpr (n <= 5) iidentity<n>(T);
    }
}

// one row of the 2-D inverse (dequantization + optional rect scaling + 1-D + row shift + clip); returns err
template <int LW>
__device__ __forceinline__ uint32_t row(int i, int th, int tw, const int16_t *q, int dcQ, int acQ, AV1G_CONST const uint8_t *qm, int den, bool rect,
                                        int rk, int rowShift, int16_t *res) {
    constexpr int W = 1 << LW;
    int32_t Tv[W];
    int nz = 0;
#pragma unroll
    for (int j = 0; j < W; j++) {
        int32_t d = 0;
        if (j < 32 && i < th && j < tw) {
            const int idx = i * tw + j;
            d = q[idx] ? av1g_dequant_coef(q[idx], av1g_qm_step(idx == 0 ? dcQ : acQ, qm, idx), den) : 0;
        }
        Tv[j] = d;
        nz |= d;
    }
    if (!nz) {
#pragma unroll
        for (int j = 0; j < W; j++) res[i * W + j] = 0;
        return 0;
    }
    if (rect) {
#pragma unroll
        for (int j = 0; j < W; j++) Tv[j] = (int32_t)av1g_round2_64((int64_t)Tv[j] * 2896, 12);
    }
    uint32_t err = 0;
    inv_1d<LW>(Tv, rk, 16, err);
#pragma unroll
    for (int j = 0; j < W; j++)
        res[i * W + j] = (int16_t)av1g_clip3(-(1 << 15), (1 << 15) - 1, (int32_t)av1g_round2_64(Tv[j], rowShift));
    return err;
}
// one column of the 2-D inverse (1-D + round + range flag 0x100); returns err
template <int LH>
__device__ __forceinline__ uint32_t col(int j, int W, int ck, int16_t *res) {
    constexpr int H = 1 << LH;
    int32_t Tv[H];
#pragma unroll
    for (int i = 0; i < H; i++) Tv[i] = res[i * W + j];
    uint32_t err = 0;
    inv_1d<LH>(Tv, ck, 16, err);
#pragma unroll
    for (int i = 0; i < H; i++) {
        const int32_t v = (int32_t)av1g_round2_64(Tv[i], 4);
        res[i * W + j] = (int16_t)av1g_clip3(-(1 << 15), (1 << 15) - 1, v);
        if (v < -(1 << 15) || v > (1 << 15) - 1) err |= 0x100u;
    }
    return err;
}

}  // namespace rci
