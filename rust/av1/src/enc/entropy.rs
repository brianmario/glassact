//! The host half of the GPU entropy path (Sources/AV1Encoder/src/entropy.cpp, Shaders/entropy.h): a
//! picture's plan for the kernels, and the OBUs around the tile payloads they code (the writer's
//! own header code: the tests hold the two paths to the same bytes).
use crate::blockinfo::{mi_cols, mi_rows};
use crate::types::{FrameParams, GaEntFrame, GaEntTile};
use crate::writer::{BitWriter, TileInfo, compute_tiles, frame_obus};

/// av1enc_ent_plan: the frame table and the tile table (raster order) of one picture. Returns the
/// number of tiles, or 0 (no blocks or tx blocks, an illegal or non-uniform tiling, or `tiles`
/// shorter than the tile count; `frame` may be partly written then, as the C++ leaves it).
pub fn ent_plan(fp: &FrameParams, n_blocks: u32, n_txb: u32, frame: &mut GaEntFrame, tiles: &mut [GaEntTile]) -> u32 {
    if n_blocks == 0 || n_txb == 0 {
        return 0;
    }
    let g = frame;
    *g = GaEntFrame::default();
    g.w = fp.width as i32;
    g.h = fp.height as i32;
    g.mi_cols = mi_cols(g.w);
    g.mi_rows = mi_rows(g.h);
    g.mono = fp.monochrome as i32;
    g.qidx = fp.base_q_idx as i32;
    g.reduced = fp.reduced_tx_set as i32;
    g.txsel = fp.tx_mode_select as i32;
    g.sct = fp.allow_screen_content_tools as i32;
    g.dq = fp.delta_q_present as i32;
    g.dq_res = fp.delta_q_res as i32;
    g.fi = fp.enable_filter_intra as i32;
    g.cdef_bits = if fp.enable_cdef != 0 { fp.cdef_bits as i32 } else { -1 };
    g.mi_total = (g.mi_cols * g.mi_rows) as u32;
    let mut ctx = 0u32;
    for p in 0..3 {
        let sub = (p != 0) as i32;
        g.ctx_stride[p] = g.mi_cols >> sub;
        g.ctx_rows[p] = g.mi_rows >> sub;
        g.ctx_base[p] = ctx;
        if p == 0 || g.mono == 0 {
            ctx += (g.ctx_stride[p] * g.ctx_rows[p]) as u32;
        }
    }
    g.ctx_total = ctx;
    g.n_blocks = n_blocks;
    g.n_txb = n_txb;
    let mut ti = TileInfo::default();
    if !compute_tiles(
        fp.width,
        fp.height,
        fp.tile_cols_log2 as i32,
        fp.tile_rows_log2 as i32,
        &mut ti,
    ) {
        return 0;
    }
    let (sb_cols, sb_rows) = ((g.mi_cols + 15) >> 4, (g.mi_rows + 15) >> 4);
    g.tile_cols = ti.cols as i32;
    g.tile_rows = ti.rows as i32;
    g.tile_wsb = if ti.cols > 1 {
        (ti.mi_col_starts[1] >> 4) as i32
    } else {
        sb_cols
    };
    g.tile_hsb = if ti.rows > 1 {
        (ti.mi_row_starts[1] >> 4) as i32
    } else {
        sb_rows
    };
    let (mut n_sb, mut n) = (0u32, 0usize);
    for tr in 0..ti.rows as usize {
        for tc in 0..ti.cols as usize {
            if ti.mi_col_starts[tc] as i32 != tc as i32 * g.tile_wsb * 16
                || ti.mi_row_starts[tr] as i32 != tr as i32 * g.tile_hsb * 16
                || n >= tiles.len()
            {
                return 0; // non-uniform tiling
            }
            let mut t = GaEntTile {
                mi_row_start: ti.mi_row_starts[tr] as i32,
                mi_row_end: ti.mi_row_starts[tr + 1] as i32,
                mi_col_start: ti.mi_col_starts[tc] as i32,
                mi_col_end: ti.mi_col_starts[tc + 1] as i32,
                ..Default::default()
            };
            t.sb_row0 = t.mi_row_start >> 4;
            t.sb_col0 = t.mi_col_start >> 4;
            t.sb_cols = ((t.mi_col_end + 15) >> 4) - t.sb_col0;
            t.n_sb = (t.sb_cols * (((t.mi_row_end + 15) >> 4) - t.sb_row0)) as u32;
            t.sb_base = n_sb;
            n_sb += t.n_sb;
            tiles[n] = t;
            n += 1;
        }
    }
    g.n_sb = n_sb;
    g.n_tiles = n as u32;
    n as u32
}

/// av1enc_assemble_obus: [TD] + sequence header + OBU_FRAME around the tile payloads (raster order).
/// Errors (-1): an illegal tiling, a payload count that isn't the tile count, an empty payload
/// before the last.
pub fn assemble_obus<P: AsRef<[u8]>>(fp: &FrameParams, tiles: &[P], temporal_delimiter: bool) -> Result<Vec<u8>, i32> {
    let mut ti = TileInfo::default();
    if !compute_tiles(
        fp.width,
        fp.height,
        fp.tile_cols_log2 as i32,
        fp.tile_rows_log2 as i32,
        &mut ti,
    ) {
        return Err(-1);
    }
    let n = tiles.len();
    if n != (ti.cols * ti.rows) as usize {
        return Err(-1);
    }
    if tiles[..n.saturating_sub(1)].iter().any(|t| t.as_ref().is_empty()) {
        return Err(-1);
    }
    let mut out = Vec::new();
    let (mut seq, mut fh) = (BitWriter::default(), BitWriter::default());
    frame_obus(
        fp,
        &mut ti,
        None,
        tiles,
        temporal_delimiter,
        &mut seq,
        &mut fh,
        &mut out,
    );
    Ok(out)
}
