#include "glassact_aom.h"

#if defined(__aarch64__)

#include <stdlib.h>
#include <string.h>

#include "aom/aom_decoder.h"
#include "aom/aom_encoder.h"
#include "aom/aom_image.h"
#include "aom/aomcx.h"
#include "aom/aomdx.h"

int glassact_aom_available(void) { return 1; }

struct glassact_aom_enc {
    aom_codec_ctx_t ctx;
    aom_codec_enc_cfg_t cfg;
    aom_codec_iter_t iter;
    int initialized;
};

glassact_aom_enc *glassact_aom_enc_create(int width, int height, int threads, int bitrate_kbps) {
    if (width < 16 || height < 16 || (width & 1) || (height & 1)) return NULL;
    glassact_aom_enc *enc = calloc(1, sizeof(*enc));
    if (!enc) return NULL;
    aom_codec_enc_cfg_t *cfg = &enc->cfg;
    if (aom_codec_enc_config_default(aom_codec_av1_cx(), cfg, AOM_USAGE_REALTIME) != AOM_CODEC_OK) {
        free(enc);
        return NULL;
    }
    cfg->g_w = (unsigned int)width;
    cfg->g_h = (unsigned int)height;
    cfg->g_timebase.num = 1;
    cfg->g_timebase.den = 1000000;
    cfg->g_threads = (unsigned int)threads;
    cfg->g_lag_in_frames = 0;
    cfg->g_pass = AOM_RC_ONE_PASS;
    cfg->rc_end_usage = AOM_CBR;
    cfg->rc_target_bitrate = (unsigned int)bitrate_kbps;
    // A short rate buffer, as for a video call (WebRTC's libaom settings):
    // a one-second budget, so a detailed frame can't spend seconds of link
    // time. Never drop frames: the engine's send gate decides which frames
    // go, and every submit must produce one frame.
    cfg->rc_buf_sz = 1000;
    cfg->rc_buf_initial_sz = 600;
    cfg->rc_buf_optimal_sz = 600;
    cfg->rc_undershoot_pct = 50;
    cfg->rc_overshoot_pct = 50;
    cfg->rc_dropframe_thresh = 0;
    cfg->kf_mode = AOM_KF_DISABLED; // key frames only on request
    if (aom_codec_enc_init(&enc->ctx, aom_codec_av1_cx(), cfg, 0) != AOM_CODEC_OK) {
        free(enc);
        return NULL;
    }
    enc->initialized = 1;
    // The speed the old engine shipped and BENCHMARKS measured (realtime
    // speed 10), screen tools, and as many tile columns as the width allows
    // up to 8, for row-MT.
    aom_codec_control(&enc->ctx, AOME_SET_CPUUSED, 10);
    aom_codec_control(&enc->ctx, AV1E_SET_TUNE_CONTENT, AOM_CONTENT_SCREEN);
    aom_codec_control(&enc->ctx, AV1E_SET_ROW_MT, 1);
    aom_codec_control(&enc->ctx, AV1E_SET_TILE_COLUMNS, width >= 2048 ? 3 : width >= 1024 ? 2 : 1);
    // Key frames may take 15 average frames (a quarter second at 60 fps):
    // WebRTC's 3× left a region's first frame unreadably soft
    // (SSIMULACRA2 30 → 56, BENCHMARKS "AV1 back, as a Viewer opt-in").
    aom_codec_control(&enc->ctx, AOME_SET_MAX_INTRA_BITRATE_PCT, 1500);
    return enc;
}

int glassact_aom_enc_set_bitrate(glassact_aom_enc *enc, int bitrate_kbps) {
    if (!enc || bitrate_kbps <= 0) return -1;
    enc->cfg.rc_target_bitrate = (unsigned int)bitrate_kbps;
    return aom_codec_enc_config_set(&enc->ctx, &enc->cfg) == AOM_CODEC_OK ? 0 : -1;
}

int glassact_aom_enc_set_max_quantizer(glassact_aom_enc *enc, int quantizer) {
    if (!enc || quantizer < 0 || quantizer > 63) return -1;
    enc->cfg.rc_max_quantizer = (unsigned int)quantizer;
    if (enc->cfg.rc_min_quantizer > enc->cfg.rc_max_quantizer) enc->cfg.rc_min_quantizer = enc->cfg.rc_max_quantizer;
    return aom_codec_enc_config_set(&enc->ctx, &enc->cfg) == AOM_CODEC_OK ? 0 : -1;
}

int glassact_aom_enc_encode(glassact_aom_enc *enc, const glassact_aom_frame *frame,
                            int64_t pts_us, uint32_t duration_us, int force_key) {
    if (!enc || !frame) return -1;
    aom_image_t img;
    if (!aom_img_wrap(&img, AOM_IMG_FMT_I420, (unsigned int)frame->width, (unsigned int)frame->height,
                      1, (unsigned char *)frame->planes[0])) return -1;
    for (int p = 0; p < 3; p++) {
        img.planes[p] = (unsigned char *)frame->planes[p];
        img.stride[p] = frame->strides[p];
    }
    enc->iter = NULL;
    return aom_codec_encode(&enc->ctx, &img, pts_us, duration_us ? duration_us : 1,
                            force_key ? AOM_EFLAG_FORCE_KF : 0) == AOM_CODEC_OK ? 0 : -1;
}

const uint8_t *glassact_aom_enc_next_packet(glassact_aom_enc *enc, size_t *size, int *is_key) {
    if (!enc) return NULL;
    const aom_codec_cx_pkt_t *pkt;
    while ((pkt = aom_codec_get_cx_data(&enc->ctx, &enc->iter))) {
        if (pkt->kind != AOM_CODEC_CX_FRAME_PKT) continue;
        *size = pkt->data.frame.sz;
        *is_key = (pkt->data.frame.flags & AOM_FRAME_IS_KEY) != 0;
        return pkt->data.frame.buf;
    }
    return NULL;
}

int glassact_aom_enc_sequence_header(glassact_aom_enc *enc, uint8_t *out, size_t capacity) {
    if (!enc) return -1;
    aom_fixed_buf_t *header = aom_codec_get_global_headers(&enc->ctx);
    if (!header) return -1;
    int length = -1;
    if (header->sz <= capacity) {
        memcpy(out, header->buf, header->sz);
        length = (int)header->sz;
    }
    free(header->buf);
    free(header);
    return length;
}

static void frame_from_image(const aom_image_t *img, glassact_aom_frame *out) {
    for (int p = 0; p < 3; p++) {
        out->planes[p] = img->planes[p];
        out->strides[p] = img->stride[p];
    }
    out->width = (int)img->d_w;
    out->height = (int)img->d_h;
}

int glassact_aom_enc_reconstruction(glassact_aom_enc *enc, glassact_aom_frame *out) {
    if (!enc || !out) return -1;
    aom_image_t img;
    if (aom_codec_control(&enc->ctx, AV1_GET_NEW_FRAME_IMAGE, &img) != AOM_CODEC_OK) return -1;
    frame_from_image(&img, out);
    return 0;
}

const char *glassact_aom_enc_error(glassact_aom_enc *enc) {
    if (!enc) return "no encoder";
    const char *detail = aom_codec_error_detail(&enc->ctx);
    return detail ? detail : aom_codec_error(&enc->ctx);
}

void glassact_aom_enc_destroy(glassact_aom_enc *enc) {
    if (!enc) return;
    if (enc->initialized) aom_codec_destroy(&enc->ctx);
    free(enc);
}

struct glassact_aom_dec {
    aom_codec_ctx_t ctx;
};

glassact_aom_dec *glassact_aom_dec_create(int threads) {
    glassact_aom_dec *dec = calloc(1, sizeof(*dec));
    if (!dec) return NULL;
    aom_codec_dec_cfg_t cfg = { .threads = (unsigned int)threads, .allow_lowbitdepth = 1 };
    if (aom_codec_dec_init(&dec->ctx, aom_codec_av1_dx(), &cfg, 0) != AOM_CODEC_OK) {
        free(dec);
        return NULL;
    }
    return dec;
}

int glassact_aom_dec_decode(glassact_aom_dec *dec, const uint8_t *data, size_t size,
                            glassact_aom_frame *out) {
    if (!dec || !out) return -1;
    if (aom_codec_decode(&dec->ctx, data, size, NULL) != AOM_CODEC_OK) return -1;
    aom_codec_iter_t iter = NULL;
    aom_image_t *img = aom_codec_get_frame(&dec->ctx, &iter);
    if (!img) return -1;
    frame_from_image(img, out);
    return 0;
}

void glassact_aom_dec_destroy(glassact_aom_dec *dec) {
    if (!dec) return;
    aom_codec_destroy(&dec->ctx);
    free(dec);
}

#else // Not arm64: no libaom. The Host doesn't offer AV1.

int glassact_aom_available(void) { return 0; }
glassact_aom_enc *glassact_aom_enc_create(int width, int height, int threads, int bitrate_kbps) {
    (void)width; (void)height; (void)threads; (void)bitrate_kbps;
    return NULL;
}
int glassact_aom_enc_set_bitrate(glassact_aom_enc *enc, int bitrate_kbps) { (void)enc; (void)bitrate_kbps; return -1; }
int glassact_aom_enc_set_max_quantizer(glassact_aom_enc *enc, int quantizer) { (void)enc; (void)quantizer; return -1; }
int glassact_aom_enc_encode(glassact_aom_enc *enc, const glassact_aom_frame *frame,
                            int64_t pts_us, uint32_t duration_us, int force_key) {
    (void)enc; (void)frame; (void)pts_us; (void)duration_us; (void)force_key;
    return -1;
}
const uint8_t *glassact_aom_enc_next_packet(glassact_aom_enc *enc, size_t *size, int *is_key) {
    (void)enc; (void)size; (void)is_key;
    return NULL;
}
int glassact_aom_enc_sequence_header(glassact_aom_enc *enc, uint8_t *out, size_t capacity) {
    (void)enc; (void)out; (void)capacity;
    return -1;
}
int glassact_aom_enc_reconstruction(glassact_aom_enc *enc, glassact_aom_frame *out) { (void)enc; (void)out; return -1; }
const char *glassact_aom_enc_error(glassact_aom_enc *enc) { (void)enc; return "libaom is arm64 only"; }
void glassact_aom_enc_destroy(glassact_aom_enc *enc) { (void)enc; }
glassact_aom_dec *glassact_aom_dec_create(int threads) { (void)threads; return NULL; }
int glassact_aom_dec_decode(glassact_aom_dec *dec, const uint8_t *data, size_t size, glassact_aom_frame *out) {
    (void)dec; (void)data; (void)size; (void)out;
    return -1;
}
void glassact_aom_dec_destroy(glassact_aom_dec *dec) { (void)dec; }

#endif
