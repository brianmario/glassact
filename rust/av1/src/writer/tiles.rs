//! Tile layout (spec 5.9.15 tile_info with uniform spacing) and the level choice.
use crate::blockinfo::{mi_cols, mi_rows};
use crate::tables::*;
use crate::types::{ERR_INVALID, Tiles};

/// The tiling of a picture (av1g::TileInfo).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TileInfo {
    pub cols_log2: i32,
    pub rows_log2: i32,
    pub cols: u32,
    pub rows: u32,
    pub min_log2_tile_cols: i32,
    pub max_log2_tile_cols: i32,
    pub max_log2_tile_rows: i32,
    pub min_log2_tiles: i32,
    pub min_log2_tile_rows: i32,
    /// in 4x4 units, `[cols]` = MiCols
    pub mi_col_starts: [u32; 65],
    pub mi_row_starts: [u32; 65],
    pub tile_size_bytes: i32,
}

impl Default for TileInfo {
    fn default() -> Self {
        TileInfo {
            cols_log2: 0,
            rows_log2: 0,
            cols: 1,
            rows: 1,
            min_log2_tile_cols: 0,
            max_log2_tile_cols: 0,
            max_log2_tile_rows: 0,
            min_log2_tiles: 0,
            min_log2_tile_rows: 0,
            mi_col_starts: [0; 65],
            mi_row_starts: [0; 65],
            tile_size_bytes: 4,
        }
    }
}

fn tile_log2(blk: i32, target: i32) -> i32 {
    let mut k = 0;
    while (blk << k) < target {
        k += 1;
    }
    k
}

/// compute_tiles: the tiling for `cols_log2` / `rows_log2` (-1: the minimum legal one; rows grow
/// until the tile area is legal). Returns false (with `t` partly set, as the C++) for an
/// out-of-range request.
pub fn compute_tiles(w: u32, h: u32, cols_log2: i32, rows_log2: i32, t: &mut TileInfo) -> bool {
    let (mi_cols, mi_rows) = (mi_cols(w as i32), mi_rows(h as i32));
    let (sb_cols, sb_rows) = ((mi_cols + 15) >> 4, (mi_rows + 15) >> 4);
    let max_tile_width_sb = MAX_TILE_WIDTH >> 6;
    let max_tile_area_sb = MAX_TILE_AREA >> 12;
    t.min_log2_tile_cols = tile_log2(max_tile_width_sb, sb_cols);
    t.max_log2_tile_cols = tile_log2(1, sb_cols.min(MAX_TILE_COLS));
    t.max_log2_tile_rows = tile_log2(1, sb_rows.min(MAX_TILE_ROWS));
    t.min_log2_tiles = tile_log2(max_tile_area_sb, sb_rows * sb_cols).max(t.min_log2_tile_cols);
    let cols_log2 = if cols_log2 < 0 { t.min_log2_tile_cols } else { cols_log2 };
    if cols_log2 < t.min_log2_tile_cols || cols_log2 > t.max_log2_tile_cols {
        return false;
    }
    t.cols_log2 = cols_log2;
    let tile_width_sb = (sb_cols + (1 << cols_log2) - 1) >> cols_log2;
    let mut i = 0;
    let mut s = 0;
    while s < sb_cols {
        t.mi_col_starts[i] = (s << 4) as u32;
        i += 1;
        s += tile_width_sb;
    }
    t.mi_col_starts[i] = mi_cols as u32;
    t.cols = i as u32;
    t.min_log2_tile_rows = (t.min_log2_tiles - cols_log2).max(0);
    let auto_rows = rows_log2 < 0;
    let mut rows_log2 = if auto_rows { t.min_log2_tile_rows } else { rows_log2 };
    loop {
        if rows_log2 < t.min_log2_tile_rows || rows_log2 > t.max_log2_tile_rows {
            return false;
        }
        let tile_height_sb = (sb_rows + (1 << rows_log2) - 1) >> rows_log2;
        if tile_width_sb * tile_height_sb <= max_tile_area_sb {
            let mut i = 0;
            let mut s = 0;
            while s < sb_rows {
                t.mi_row_starts[i] = (s << 4) as u32;
                i += 1;
                s += tile_height_sb;
            }
            t.mi_row_starts[i] = mi_rows as u32;
            t.rows = i as u32;
            t.rows_log2 = rows_log2;
            return true;
        }
        if !auto_rows {
            return false; // conformance: tile area too large
        }
        rows_log2 += 1;
    }
}

/// av1g_tile_layout: the tile boundaries for a picture size and tiling choice (-1: minimum legal).
/// Errors: [`ERR_INVALID`] (an empty picture or an out-of-range request).
pub fn tile_layout(width: u32, height: u32, cols_log2: i32, rows_log2: i32) -> Result<Tiles, i32> {
    let mut t = TileInfo::default();
    if width < 1 || height < 1 || !compute_tiles(width, height, cols_log2, rows_log2, &mut t) {
        return Err(ERR_INVALID);
    }
    let mut out = Tiles {
        cols_log2: t.cols_log2,
        rows_log2: t.rows_log2,
        cols: t.cols,
        rows: t.rows,
        mi_col_starts: [0; 65],
        mi_row_starts: [0; 65],
    };
    out.mi_col_starts[..=t.cols as usize].copy_from_slice(&t.mi_col_starts[..=t.cols as usize]);
    out.mi_row_starts[..=t.rows as usize].copy_from_slice(&t.mi_row_starts[..=t.rows as usize]);
    Ok(out)
}

/// The smallest level that fits (annex A.3), 31 if a side is under 16 or none fits.
pub(crate) fn choose_level(w: u32, h: u32, ntiles: i32, tcols: i32) -> i32 {
    if w < 16 || h < 16 {
        return 31;
    }
    for l in av1g_levels.iter() {
        if (w as u64) * (h as u64) <= l[1] as u64
            && w <= l[2]
            && h <= l[3]
            && ntiles as u32 <= l[4]
            && tcols as u32 <= l[5]
        {
            return l[0] as i32;
        }
    }
    31
}
