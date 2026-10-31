/* av1g/cdfctx.h - the adaptive CDF state of one tile (intra-only subset of the
 * spec's Tile* arrays), as one flat POD struct of uint16 so that a symbol's CDF can
 * be named by its uint16 offset inside the struct (the "cdf id" used by the
 * symbol streams of M4).  Initialised from the generated spec defaults. */
#ifndef AV1G_CDFCTX_H
#define AV1G_CDFCTX_H

#include <stdint.h>
#include "av1g/hd.h"
#include "av1g/cdf_defaults.h"

typedef struct av1g_cdfs {
    /* non-coefficient CDFs (init_non_coeff_cdfs) */
    uint16_t y_mode[5][5][14];          /* TileIntraFrameYModeCdf */
    uint16_t uv_mode_cfl_not_allowed[13][14];
    uint16_t uv_mode_cfl_allowed[13][15];
    uint16_t angle_delta[8][8];
    uint16_t partition_w8[4][5];
    uint16_t partition_w16[4][11];
    uint16_t partition_w32[4][11];
    uint16_t partition_w64[4][11];
    uint16_t tx_8x8[3][3];
    uint16_t tx_16x16[3][4];
    uint16_t tx_32x32[3][4];
    uint16_t tx_64x64[3][4];
    uint16_t skip[3][3];
    uint16_t filter_intra_mode[6];
    uint16_t filter_intra[22][3];
    uint16_t delta_q[5];
    uint16_t delta_lf[5];
    uint16_t delta_lf_multi[4][5];
    uint16_t intra_tx_set1[2][13][8];
    uint16_t intra_tx_set2[3][13][6];
    uint16_t cfl_sign[9];
    uint16_t cfl_alpha[6][17];
    uint16_t palette_y_mode[7][3][3];   /* has_palette_y (only with allow_screen_content_tools) */
    uint16_t palette_uv_mode[2][3];     /* has_palette_uv */
    /* coefficient CDFs (init_coeff_cdfs, one quantizer context) */
    uint16_t txb_skip[5][13][3];
    uint16_t eob_pt_16[2][2][6];
    uint16_t eob_pt_32[2][2][7];
    uint16_t eob_pt_64[2][2][8];
    uint16_t eob_pt_128[2][2][9];
    uint16_t eob_pt_256[2][2][10];
    uint16_t eob_pt_512[2][11];
    uint16_t eob_pt_1024[2][12];
    uint16_t eob_extra[5][2][9][3];
    uint16_t dc_sign[2][3][3];
    uint16_t coeff_base_eob[5][2][4][4];
    uint16_t coeff_base[5][2][42][5];
    uint16_t coeff_br[5][2][21][5];
} av1g_cdfs;

/* quantizer context for init_coeff_cdfs */
AV1G_HD int av1g_coeff_cdf_q_ctx(int base_q_idx) {
    if (base_q_idx <= 20) return 0;
    if (base_q_idx <= 60) return 1;
    if (base_q_idx <= 120) return 2;
    return 3;
}

#define AV1G_CDF_COPY(dst, src) do { \
    const uint16_t *s_ = (const uint16_t *)(src); uint16_t *d_ = (uint16_t *)(dst); \
    for (unsigned i_ = 0; i_ < sizeof(dst) / sizeof(uint16_t); i_++) d_[i_] = s_[i_]; } while (0)

AV1G_HDI void av1g_cdfs_init(av1g_cdfs *c, int base_q_idx) {
    const int q = av1g_coeff_cdf_q_ctx(base_q_idx);
    AV1G_CDF_COPY(c->y_mode, AV1G_T(Default_Intra_Frame_Y_Mode_Cdf));
    AV1G_CDF_COPY(c->uv_mode_cfl_not_allowed, AV1G_T(Default_Uv_Mode_Cfl_Not_Allowed_Cdf));
    AV1G_CDF_COPY(c->uv_mode_cfl_allowed, AV1G_T(Default_Uv_Mode_Cfl_Allowed_Cdf));
    AV1G_CDF_COPY(c->angle_delta, AV1G_T(Default_Angle_Delta_Cdf));
    AV1G_CDF_COPY(c->partition_w8, AV1G_T(Default_Partition_W8_Cdf));
    AV1G_CDF_COPY(c->partition_w16, AV1G_T(Default_Partition_W16_Cdf));
    AV1G_CDF_COPY(c->partition_w32, AV1G_T(Default_Partition_W32_Cdf));
    AV1G_CDF_COPY(c->partition_w64, AV1G_T(Default_Partition_W64_Cdf));
    AV1G_CDF_COPY(c->tx_8x8, AV1G_T(Default_Tx_8x8_Cdf));
    AV1G_CDF_COPY(c->tx_16x16, AV1G_T(Default_Tx_16x16_Cdf));
    AV1G_CDF_COPY(c->tx_32x32, AV1G_T(Default_Tx_32x32_Cdf));
    AV1G_CDF_COPY(c->tx_64x64, AV1G_T(Default_Tx_64x64_Cdf));
    AV1G_CDF_COPY(c->skip, AV1G_T(Default_Skip_Cdf));
    AV1G_CDF_COPY(c->filter_intra_mode, AV1G_T(Default_Filter_Intra_Mode_Cdf));
    AV1G_CDF_COPY(c->filter_intra, AV1G_T(Default_Filter_Intra_Cdf));
    AV1G_CDF_COPY(c->delta_q, AV1G_T(Default_Delta_Q_Cdf));
    AV1G_CDF_COPY(c->delta_lf, AV1G_T(Default_Delta_Lf_Cdf));
    for (int i = 0; i < 4; i++) AV1G_CDF_COPY(c->delta_lf_multi[i], AV1G_T(Default_Delta_Lf_Cdf));
    AV1G_CDF_COPY(c->intra_tx_set1, AV1G_T(Default_Intra_Tx_Type_Set1_Cdf));
    AV1G_CDF_COPY(c->intra_tx_set2, AV1G_T(Default_Intra_Tx_Type_Set2_Cdf));
    AV1G_CDF_COPY(c->cfl_sign, AV1G_T(Default_Cfl_Sign_Cdf));
    AV1G_CDF_COPY(c->cfl_alpha, AV1G_T(Default_Cfl_Alpha_Cdf));
    AV1G_CDF_COPY(c->palette_y_mode, AV1G_T(Default_Palette_Y_Mode_Cdf));
    AV1G_CDF_COPY(c->palette_uv_mode, AV1G_T(Default_Palette_Uv_Mode_Cdf));
    AV1G_CDF_COPY(c->txb_skip, AV1G_T(Default_Txb_Skip_Cdf)[q]);
    AV1G_CDF_COPY(c->eob_pt_16, AV1G_T(Default_Eob_Pt_16_Cdf)[q]);
    AV1G_CDF_COPY(c->eob_pt_32, AV1G_T(Default_Eob_Pt_32_Cdf)[q]);
    AV1G_CDF_COPY(c->eob_pt_64, AV1G_T(Default_Eob_Pt_64_Cdf)[q]);
    AV1G_CDF_COPY(c->eob_pt_128, AV1G_T(Default_Eob_Pt_128_Cdf)[q]);
    AV1G_CDF_COPY(c->eob_pt_256, AV1G_T(Default_Eob_Pt_256_Cdf)[q]);
    AV1G_CDF_COPY(c->eob_pt_512, AV1G_T(Default_Eob_Pt_512_Cdf)[q]);
    AV1G_CDF_COPY(c->eob_pt_1024, AV1G_T(Default_Eob_Pt_1024_Cdf)[q]);
    AV1G_CDF_COPY(c->eob_extra, AV1G_T(Default_Eob_Extra_Cdf)[q]);
    AV1G_CDF_COPY(c->dc_sign, AV1G_T(Default_Dc_Sign_Cdf)[q]);
    AV1G_CDF_COPY(c->coeff_base_eob, AV1G_T(Default_Coeff_Base_Eob_Cdf)[q]);
    AV1G_CDF_COPY(c->coeff_base, AV1G_T(Default_Coeff_Base_Cdf)[q]);
    AV1G_CDF_COPY(c->coeff_br, AV1G_T(Default_Coeff_Br_Cdf)[q]);
}

#endif
