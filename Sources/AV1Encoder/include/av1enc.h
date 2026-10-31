// Glass Act's C API over the host half of av1gpu's encoder (Sources/AV1Encoder):
// what the Metal kernels need from the CPU. The structures the host and the
// kernels share are in av1enc/gp.h.
#ifndef AV1ENC_H
#define AV1ENC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The encoder's derived tables (forward transform matrices, transform energy
// and scale factors, symbol costs from the default CDFs) as Metal source:
// `constant` arrays the kernels index. NUL-terminated, malloc'd (free it);
// NULL on failure.
char *av1enc_tables_msl(size_t *length);

#ifdef __cplusplus
}
#endif
#endif
