// Glass Act's C API over the vendored libaom (ThirdParty/THIRD_PARTY.md).
//
// libaom is compiled into arm64 builds only: on any other architecture
// glassact_aom_available() is 0, creation returns NULL, and the Host doesn't
// offer AV1. The encoder is libaom's realtime mode tuned for screen content
// (palette, IntraBC), low delay, CBR, with key frames only on request.

#ifndef GLASSACT_AOM_H
#define GLASSACT_AOM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 1 when libaom is compiled in (arm64).
int glassact_aom_available(void);

// One 8-bit 4:2:0 picture. Planes are owned by whoever returned it.
typedef struct {
    const uint8_t *planes[3];
    int strides[3];
    int width;
    int height;
} glassact_aom_frame;

typedef struct glassact_aom_enc glassact_aom_enc;

// A realtime encoder for width×height (even), `threads` worker threads,
// a CBR target of bitrate_kbps. Timestamps are microseconds. NULL on
// failure.
glassact_aom_enc *glassact_aom_enc_create(int width, int height, int threads, int bitrate_kbps);

// Runtime rate control: the CBR target, and the coarsest quantizer the
// encoder may use (0–63, libaom's scale).
int glassact_aom_enc_set_bitrate(glassact_aom_enc *enc, int bitrate_kbps);
int glassact_aom_enc_set_max_quantizer(glassact_aom_enc *enc, int quantizer);

// Encode one frame shown at pts_us for duration_us. 0 on success; then read
// the output with glassact_aom_enc_next_packet.
int glassact_aom_enc_encode(glassact_aom_enc *enc, const glassact_aom_frame *frame,
                            int64_t pts_us, uint32_t duration_us, int force_key);

// The next output packet of the last encode, or NULL when there are no
// more. Valid until the next encode or destroy.
const uint8_t *glassact_aom_enc_next_packet(glassact_aom_enc *enc, size_t *size, int *is_key);

// The sequence header OBU, for the codec configuration record (av1C).
// Returns its length, or -1 if it doesn't fit in `capacity`.
int glassact_aom_enc_sequence_header(glassact_aom_enc *enc, uint8_t *out, size_t capacity);

// The encoder's own reconstruction of the last encoded frame: what a
// correct decoder must output for it. 0 on success.
int glassact_aom_enc_reconstruction(glassact_aom_enc *enc, glassact_aom_frame *out);

const char *glassact_aom_enc_error(glassact_aom_enc *enc);
void glassact_aom_enc_destroy(glassact_aom_enc *enc);

typedef struct glassact_aom_dec glassact_aom_dec;

// A decoder, for tests and the bench (the Viewer decodes in hardware).
glassact_aom_dec *glassact_aom_dec_create(int threads);
// Decode one temporal unit; `out` is valid until the next call. 0 on success.
int glassact_aom_dec_decode(glassact_aom_dec *dec, const uint8_t *data, size_t size,
                            glassact_aom_frame *out);
void glassact_aom_dec_destroy(glassact_aom_dec *dec);

#ifdef __cplusplus
}
#endif

#endif
