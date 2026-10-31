// Test shim: sizeof / offsetof of the C API's structures, for the Rust port's layout test.
#include <cstddef>
#include <cstring>
#include "av1g/av1g.h"
#include "av1enc.h"

#define S(name, T) if (!strcmp(what, name)) return (long long)sizeof(T);
#define O(name, T, f) if (!strcmp(what, name "." #f)) return (long long)offsetof(T, f);

extern "C" long long oracle_layout(const char *what) {
    S("Block", av1g_block) O("Block", av1g_block, mi_row) O("Block", av1g_block, bsize) O("Block", av1g_block, cdef_idx)
    O("Block", av1g_block, sb_qindex)
    S("Txb", av1g_txb) O("Txb", av1g_txb, coeff_off) O("Txb", av1g_txb, x4) O("Txb", av1g_txb, eob)
    S("FrameParams", av1g_frame_params) O("FrameParams", av1g_frame_params, width) O("FrameParams", av1g_frame_params, monochrome)
    O("FrameParams", av1g_frame_params, loop_filter_level) O("FrameParams", av1g_frame_params, cdef_y_pri)
    O("FrameParams", av1g_frame_params, cdef_uv_sec) O("FrameParams", av1g_frame_params, allow_screen_content_tools)
    O("FrameParams", av1g_frame_params, video) O("FrameParams", av1g_frame_params, frame_type)
    O("FrameParams", av1g_frame_params, ref_slot) O("FrameParams", av1g_frame_params, refresh_frame_flags)
    O("FrameParams", av1g_frame_params, error_resilient_mode) O("FrameParams", av1g_frame_params, reserved)
    S("BlockInter", av1g_block_inter) O("BlockInter", av1g_block_inter, mv_row) O("BlockInter", av1g_block_inter, mv_col)
    O("BlockInter", av1g_block_inter, is_inter) O("BlockInter", av1g_block_inter, reserved)
    S("RefPlanes", av1g_ref_planes) O("RefPlanes", av1g_ref_planes, plane) O("RefPlanes", av1g_ref_planes, stride)
    S("DecisionRecord", av1g_decision_record) O("DecisionRecord", av1g_decision_record, n_blocks)
    O("DecisionRecord", av1g_decision_record, n_coeffs) O("DecisionRecord", av1g_decision_record, blocks)
    O("DecisionRecord", av1g_decision_record, coeffs) O("DecisionRecord", av1g_decision_record, inter)
    S("EncodeOpts", av1g_encode_opts) O("EncodeOpts", av1g_encode_opts, seq_level_idx)
    S("Output", av1g_output) O("Output", av1g_output, obu_size) O("Output", av1g_output, recon) O("Output", av1g_output, recon_h)
    O("Output", av1g_output, tile_bytes) O("Output", av1g_output, n_symbols) O("Output", av1g_output, n_fixed_txb)
    O("Output", av1g_output, error)
    S("Tiles", av1g_tiles) O("Tiles", av1g_tiles, cols) O("Tiles", av1g_tiles, mi_col_starts) O("Tiles", av1g_tiles, mi_row_starts)
    S("Parsed", av1g_parsed) O("Parsed", av1g_parsed, seq_level_idx) O("Parsed", av1g_parsed, tile_bytes)
    O("Parsed", av1g_parsed, error) O("Parsed", av1g_parsed, priv)
    S("AvifMeta", av1g_avif_meta) O("AvifMeta", av1g_avif_meta, icc_size) O("AvifMeta", av1g_avif_meta, imir)
    S("GaPfAddrs", GaPfAddrs) O("GaPfAddrs", GaPfAddrs, stride) O("GaPfAddrs", GaPfAddrs, skip) O("GaPfAddrs", GaPfAddrs, lfTx)
    O("GaPfAddrs", GaPfAddrs, cdefDirVar)
    S("GaTuneiqFrame", GaTuneiqFrame) O("GaTuneiqFrame", GaTuneiqFrame, rdmult)
    S("GaCdefCand", GaCdefCand) O("GaCdefCand", GaCdefCand, sec) O("GaCdefCand", GaCdefCand, nsec)
    S("GaEntFrame", GaEntFrame) O("GaEntFrame", GaEntFrame, cdefBits) O("GaEntFrame", GaEntFrame, ctxBase)
    O("GaEntFrame", GaEntFrame, ctxTotal) O("GaEntFrame", GaEntFrame, tileHsb) O("GaEntFrame", GaEntFrame, symCap)
    S("GaEntTile", GaEntTile) O("GaEntTile", GaEntTile, firstBlock) O("GaEntTile", GaEntTile, sbCols)
    return -1;
}
