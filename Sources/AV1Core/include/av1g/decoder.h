/* av1g/decoder.h - Glass Act's AV1 decoder (rust/av1/src/decoder.rs), for the streams the
 * DecisionRecord writer (the hybrid encoder's) produces.
 *
 *   av1g_decoder_create()    a decoder: its reference pictures, CDFs and buffers
 *   av1g_decoder_decode()    one temporal unit in, the frame it shows out
 *   av1g_decoder_picture()   the last frame shown again
 *   av1g_decoder_reset()     forget the stream (the next frame must be a key frame)
 *   av1g_decoder_destroy()
 *
 * The toolset: still pictures, key and inter frames, 8-bit 4:2:0, 4:4:4 key frames, monochrome,
 * 64x64 or 128x128 superblocks, uniform tiles, palettes, intra block copy, deblocking and CDEF,
 * LAST_FRAME and GOLDEN_FRAME references, frames up to AV1G_DEC_MAX_DIM a side.  Anything else is
 * refused with an error (AV1G_ERR_INVALID), never decoded approximately.  Input may be hostile: no
 * input crashes, hangs or reads outside its buffer.  After an error the reference pictures are
 * dropped, so inter frames fail with AV1G_ERR_NO_REFERENCE until the next key frame.
 *
 * A decoder is used from one thread at a time; it decodes on the crate's worker threads.
 */
#ifndef AV1G_DECODER_H
#define AV1G_DECODER_H

#include <stddef.h>
#include <stdint.h>
#include "av1g/av1g.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The largest frame side the decoder takes (the encoder's limit). */
#define AV1G_DEC_MAX_DIM 8192
/* The frame needs a picture the decoder doesn't hold (after a reset, an error, a new sequence
 * header, or before the stream's first key frame): the stream resumes at its next key frame. */
#define AV1G_ERR_NO_REFERENCE -5

typedef struct av1g_decoder av1g_decoder;

/* A decoded frame: valid until the decoder's next decode, reset or destroy. */
typedef struct av1g_dec_picture {
    const uint8_t *planes[3];  /* Y, U, V: row r of plane p at planes[p] + r * stride[p]; U and V
                                  NULL for monochrome */
    uint32_t stride[3];
    uint32_t plane_w[3];       /* each plane's size: Y width x height, 4:2:0 chroma (w+1)/2 x (h+1)/2,
                                  4:4:4 chroma w x h */
    uint32_t plane_h[3];
    uint32_t width, height;    /* the decoded frame's (its Y plane's) */
    uint32_t render_width;     /* the size the stream asks it shown at (a reduced frame's: the */
    uint32_t render_height;    /*   stream's) */
    uint8_t  chroma_format;    /* AV1G_CHROMA_420 / AV1G_CHROMA_444 */
    uint8_t  monochrome;
    uint8_t  key;              /* a key frame or still picture */
    uint8_t  reserved;
    /* the sequence header's colour description (2, 2, 2 when it has none) and color_range */
    uint32_t color_primaries, transfer_characteristics, matrix_coefficients, color_range;
} av1g_dec_picture;

/* A decoder decoding on at most `threads` threads (<= 0: the available parallelism).  NULL only
 * when out of memory. */
av1g_decoder *av1g_decoder_create(int threads);

/* Decodes one temporal unit (`size` bytes of OBUs: a temporal delimiter, a sequence header, one
 * OBU_FRAME; metadata and padding are ignored) and fills `out` (if not NULL) with the frame it
 * shows.  Returns AV1G_OK, AV1G_ERR_INVALID (malformed, or outside the toolset),
 * AV1G_ERR_RANGE (coefficients out of the inverse transform's range) or AV1G_ERR_NO_REFERENCE,
 * with a message in `err` (if not NULL, `errlen` bytes, NUL-terminated); `out` is zeroed on an
 * error. */
int av1g_decoder_decode(av1g_decoder *d, const uint8_t *data, size_t size, av1g_dec_picture *out,
                        char *err, size_t errlen);

/* The frame the last decode showed: AV1G_OK, or AV1G_ERR_INVALID (`out` zeroed) when it showed
 * none. */
int av1g_decoder_picture(const av1g_decoder *d, av1g_dec_picture *out);

/* Forgets the stream (references, CDFs, sequence header); buffers are kept. */
void av1g_decoder_reset(av1g_decoder *d);

void av1g_decoder_destroy(av1g_decoder *d);

#ifdef __cplusplus
}
#endif

#endif
