// The host half of the GPU entropy path (Shaders/entropy.h): a picture's plan for the kernels,
// and the OBUs around the tile payloads they code.
//
// Glass Act: from av1gpu (BSD-2, Sources/AV1Core/LICENSE): the frame and tile tables of
// build_plan (av1core/src/gpu_entropy.cu), for one picture, and gp_assemble_obus with its header
// writer (encoder/src/entropy_gpu.cpp), which mirrors av1core's Encoder::write_headers; the
// tests hold both to av1core's writer, byte for byte.
#include "av1enc.h"
#include "av1enc/ent.h"
#include "av1g/av1g.h"
#include "av1g/blockinfo.h"
#include "av1g/internal.h"
#include "av1g/levels_gen.h"

#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

int choose_level(uint32_t W, uint32_t H, int ntiles, int tcols) {
    if (W < 16 || H < 16) return 31;
    for (int i = 0; i < AV1G_NUM_LEVELS; i++) {
        const uint32_t *L = av1g_levels[i];
        if ((uint64_t)W * H <= L[1] && W <= L[2] && H <= L[3] && (uint32_t)ntiles <= L[4] && (uint32_t)tcols <= L[5])
            return (int)L[0];
    }
    return 31;
}

void write_headers(const av1g_frame_params *fp, const av1g::TileInfo &tiles, int level, av1g::BitWriter &seq,
                   av1g::BitWriter &fh) {
    const int W = (int)fp->width, H = (int)fp->height, mono = fp->monochrome;
    const int diff_uv = (fp->delta_q_v_dc != fp->delta_q_u_dc || fp->delta_q_v_ac != fp->delta_q_u_ac);
    const int separate_uv = !mono && (diff_uv || (fp->using_qmatrix && fp->qm_v != fp->qm_u));
    seq.put(0, 3);
    seq.put(1, 1);
    seq.put(1, 1);
    seq.put(level, 5);
    int wb = 1, hb = 1;
    while ((uint32_t)(W - 1) >> wb) wb++;
    while ((uint32_t)(H - 1) >> hb) hb++;
    seq.put(wb - 1, 4);
    seq.put(hb - 1, 4);
    seq.put(W - 1, wb);
    seq.put(H - 1, hb);
    seq.put(0, 1);
    seq.put(fp->enable_filter_intra, 1);
    seq.put(fp->enable_intra_edge_filter, 1);
    seq.put(0, 1);
    seq.put(fp->enable_cdef, 1);
    seq.put(0, 1);
    seq.put(0, 1);
    seq.put(mono, 1);
    seq.put(1, 1);
    seq.put(1, 8);
    seq.put(13, 8);
    seq.put(6, 8);
    seq.put(1, 1);
    if (!mono) {
        seq.put(0, 2);
        seq.put(separate_uv, 1);
    }
    seq.put(0, 1);
    seq.trailing_bits();

    fh.put(0, 1);
    fh.put(fp->allow_screen_content_tools, 1);
    if (fp->allow_screen_content_tools) fh.put(0, 1);
    fh.put(0, 1);
    if (fp->allow_screen_content_tools) fh.put(0, 1);
    fh.put(1, 1);
    for (int k = tiles.minLog2TileCols; k < tiles.maxLog2TileCols; k++) {
        if (k < tiles.colsLog2) fh.put(1, 1);
        else { fh.put(0, 1); break; }
    }
    for (int k = tiles.minLog2TileRows; k < tiles.maxLog2TileRows; k++) {
        if (k < tiles.rowsLog2) fh.put(1, 1);
        else { fh.put(0, 1); break; }
    }
    if (tiles.colsLog2 > 0 || tiles.rowsLog2 > 0) {
        fh.put(0, tiles.colsLog2 + tiles.rowsLog2);
        fh.put(tiles.tileSizeBytes - 1, 2);
    }
    fh.put(fp->base_q_idx, 8);
    auto delta_q = [&](int v) {
        if (v) { fh.put(1, 1); fh.su(v, 7); } else fh.put(0, 1);
    };
    delta_q(fp->delta_q_y_dc);
    if (!mono) {
        if (separate_uv) fh.put(diff_uv, 1);
        delta_q(fp->delta_q_u_dc);
        delta_q(fp->delta_q_u_ac);
        if (diff_uv) {
            delta_q(fp->delta_q_v_dc);
            delta_q(fp->delta_q_v_ac);
        }
    }
    fh.put(fp->using_qmatrix, 1);
    if (fp->using_qmatrix) {
        fh.put(fp->qm_y, 4);
        fh.put(fp->qm_u, 4);
        if (separate_uv) fh.put(fp->qm_v, 4);
    }
    fh.put(0, 1);
    fh.put(fp->delta_q_present, 1);
    if (fp->delta_q_present) {
        fh.put(fp->delta_q_res, 2);
        fh.put(0, 1);
    }
    fh.put(fp->loop_filter_level[0], 6);
    fh.put(fp->loop_filter_level[1], 6);
    if (!mono && (fp->loop_filter_level[0] || fp->loop_filter_level[1])) {
        fh.put(fp->loop_filter_level[2], 6);
        fh.put(fp->loop_filter_level[3], 6);
    }
    fh.put(fp->loop_filter_sharpness, 3);
    fh.put(0, 1);
    if (fp->enable_cdef) {
        fh.put(fp->cdef_damping_minus_3, 2);
        fh.put(fp->cdef_bits, 2);
        for (int i = 0; i < (1 << fp->cdef_bits); i++) {
            fh.put(fp->cdef_y_pri[i], 4);
            fh.put(fp->cdef_y_sec[i] == 4 ? 3 : fp->cdef_y_sec[i], 2);
            if (!mono) {
                fh.put(fp->cdef_uv_pri[i], 4);
                fh.put(fp->cdef_uv_sec[i] == 4 ? 3 : fp->cdef_uv_sec[i], 2);
            }
        }
    }
    fh.put(fp->tx_mode_select ? 1 : 0, 1);
    fh.put(fp->reduced_tx_set ? 1 : 0, 1);
    fh.byte_align();
}

}  // namespace

extern "C" uint32_t av1enc_ent_plan(const av1g_frame_params *fp, uint32_t nBlocks, uint32_t nTxb, GaEntFrame *frame,
                                    GaEntTile *tiles) {
    if (!fp || !frame || !tiles || !nBlocks || !nTxb) return 0;
    GaEntFrame &g = *frame;
    memset(&g, 0, sizeof g);
    g.W = (int32_t)fp->width;
    g.H = (int32_t)fp->height;
    g.MiCols = av1g_mi_cols(g.W);
    g.MiRows = av1g_mi_rows(g.H);
    g.mono = fp->monochrome;
    g.qidx = fp->base_q_idx;
    g.reduced = fp->reduced_tx_set;
    g.txsel = fp->tx_mode_select;
    g.sct = fp->allow_screen_content_tools;
    g.dq = fp->delta_q_present;
    g.dqRes = fp->delta_q_res;
    g.fi = fp->enable_filter_intra;
    g.cdefBits = fp->enable_cdef ? fp->cdef_bits : -1;
    g.miTotal = (uint32_t)(g.MiCols * g.MiRows);
    uint32_t ctx = 0;
    for (int p = 0; p < 3; p++) {
        const int sub = p ? 1 : 0;
        g.ctxStride[p] = g.MiCols >> sub;
        g.ctxRows[p] = g.MiRows >> sub;
        g.ctxBase[p] = ctx;
        if (p == 0 || !g.mono) ctx += (uint32_t)(g.ctxStride[p] * g.ctxRows[p]);
    }
    g.ctxTotal = ctx;
    g.nBlocks = nBlocks;
    g.nTxb = nTxb;
    av1g::TileInfo ti;
    if (!av1g::compute_tiles(fp->width, fp->height, fp->tile_cols_log2, fp->tile_rows_log2, ti)) return 0;
    const int sbCols = (g.MiCols + 15) >> 4, sbRows = (g.MiRows + 15) >> 4;
    g.tileCols = (int32_t)ti.cols;
    g.tileRows = (int32_t)ti.rows;
    g.tileWsb = ti.cols > 1 ? (int32_t)(ti.miColStarts[1] >> 4) : sbCols;
    g.tileHsb = ti.rows > 1 ? (int32_t)(ti.miRowStarts[1] >> 4) : sbRows;
    uint32_t nSb = 0, n = 0;
    for (uint32_t tr = 0; tr < ti.rows; tr++)
        for (uint32_t tc = 0; tc < ti.cols; tc++) {
            if ((int)ti.miColStarts[tc] != (int)tc * g.tileWsb * 16 || (int)ti.miRowStarts[tr] != (int)tr * g.tileHsb * 16)
                return 0;  // non-uniform tiling
            GaEntTile &t = tiles[n++];
            memset(&t, 0, sizeof t);
            t.miRowStart = (int32_t)ti.miRowStarts[tr];
            t.miRowEnd = (int32_t)ti.miRowStarts[tr + 1];
            t.miColStart = (int32_t)ti.miColStarts[tc];
            t.miColEnd = (int32_t)ti.miColStarts[tc + 1];
            t.sbRow0 = t.miRowStart >> 4;
            t.sbCol0 = t.miColStart >> 4;
            t.sbCols = ((t.miColEnd + 15) >> 4) - t.sbCol0;
            t.nSb = (uint32_t)(t.sbCols * (((t.miRowEnd + 15) >> 4) - t.sbRow0));
            t.sbBase = nSb;
            nSb += t.nSb;
        }
    g.nSb = nSb;
    g.nTiles = n;
    return n;
}

extern "C" int av1enc_assemble_obus(const av1g_frame_params *fp, const uint8_t *const *tileData, const size_t *tileSizes,
                                    uint32_t nTiles, int temporalDelimiter, uint8_t **out, size_t *outSize) {
    if (!fp || !out || !outSize || (nTiles && (!tileData || !tileSizes))) return -1;
    av1g::TileInfo tiles;
    if (!av1g::compute_tiles(fp->width, fp->height, fp->tile_cols_log2, fp->tile_rows_log2, tiles)) return -1;
    if (nTiles != tiles.cols * tiles.rows) return -1;
    uint64_t maxSz = 0;
    for (uint32_t i = 0; i + 1 < nTiles; i++) {
        if (!tileSizes[i]) return -1;
        if (tileSizes[i] - 1 > maxSz) maxSz = tileSizes[i] - 1;
    }
    tiles.tileSizeBytes = maxSz < (1u << 8) ? 1 : maxSz < (1u << 16) ? 2 : maxSz < (1u << 24) ? 3 : 4;
    const int level = choose_level(fp->width, fp->height, (int)nTiles, (int)tiles.cols);
    av1g::BitWriter seq, fh;
    write_headers(fp, tiles, level, seq, fh);
    std::vector<uint8_t> frame = fh.buf;
    if (nTiles > 1) frame.push_back(0);  // tile_start_and_end_present_flag = 0 + byte_alignment
    for (uint32_t i = 0; i < nTiles; i++) {
        if (i + 1 < nTiles) {
            const uint64_t v = tileSizes[i] - 1;
            for (int k = 0; k < tiles.tileSizeBytes; k++) frame.push_back((uint8_t)(v >> (8 * k)));
        }
        frame.insert(frame.end(), tileData[i], tileData[i] + tileSizes[i]);
    }
    std::vector<uint8_t> obu;
    if (temporalDelimiter) { obu.push_back(0x12); obu.push_back(0x00); }
    obu.push_back(0x0A);  // OBU_SEQUENCE_HEADER, has_size_field
    av1g::put_leb128(obu, seq.buf.size());
    obu.insert(obu.end(), seq.buf.begin(), seq.buf.end());
    obu.push_back(0x32);  // OBU_FRAME, has_size_field
    av1g::put_leb128(obu, frame.size());
    obu.insert(obu.end(), frame.begin(), frame.end());
    *out = (uint8_t *)malloc(obu.size());
    if (!*out) return -1;
    memcpy(*out, obu.data(), obu.size());
    *outSize = obu.size();
    return 0;
}
