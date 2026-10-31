// Glass Act's C API over the host half of av1gpu's encoder (Sources/AV1Encoder):
// what the Metal kernels need from the CPU. The structures the host and the
// kernels share are in av1enc/gp.h.
#ifndef AV1ENC_H
#define AV1ENC_H

#include <stddef.h>
#include <stdint.h>
#include "av1g/decisions.h"
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

#ifdef __cplusplus
}
#endif
#endif
