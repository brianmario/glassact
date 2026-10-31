//! Block / transform geometry rules of the AV1 syntax that every engine needs
//! (Sources/AV1Core/include/av1g/blockinfo.h). 4:2:0 or monochrome, no 128x128 blocks.
#![allow(clippy::too_many_arguments, clippy::needless_range_loop)]
use crate::tables::*;

pub use crate::dsp::tx_coeffs;

#[inline]
pub fn bw4(bsize: i32) -> i32 {
    Num_4x4_Blocks_Wide[bsize as usize] as i32
}
#[inline]
pub fn bh4(bsize: i32) -> i32 {
    Num_4x4_Blocks_High[bsize as usize] as i32
}

/// MiCols of the coded area (spec compute_image_size).
#[inline]
pub fn mi_cols(width: i32) -> i32 {
    2 * ((width + 7) >> 3)
}
/// MiRows of the coded area (spec compute_image_size).
#[inline]
pub fn mi_rows(height: i32) -> i32 {
    2 * ((height + 7) >> 3)
}

/// HasChroma (spec decode_block), 4:2:0.
pub fn has_chroma(bsize: i32, mi_row: i32, mi_col: i32, mono: bool) -> bool {
    !(mono || (bh4(bsize) == 1 && (mi_row & 1) == 0) || (bw4(bsize) == 1 && (mi_col & 1) == 0))
}

/// The luma TxSize of an intra block for a given tx_depth (read_tx_size).
pub fn luma_tx_size(bsize: i32, tx_depth: i32) -> i32 {
    let mut t = Max_Tx_Size_Rect[bsize as usize] as i32;
    for _ in 0..tx_depth {
        t = Split_Tx_Size[t as usize] as i32;
    }
    t
}
/// The largest legal tx_depth for an intra block.
pub fn max_tx_depth(bsize: i32) -> i32 {
    (Max_Tx_Depth[bsize as usize] as i32).min(2)
}

/// The chroma block size (get_plane_residual_size, plane > 0, 4:2:0).
#[inline]
pub fn uv_bsize(bsize: i32) -> i32 {
    Subsampled_Size[bsize as usize][1][1] as i32
}

/// The chroma TxSize (get_tx_size for plane > 0).
pub fn uv_tx_size(bsize: i32) -> i32 {
    let uv_tx = Max_Tx_Size_Rect[uv_bsize(bsize) as usize] as i32;
    let (w, h) = (Tx_Width[uv_tx as usize], Tx_Height[uv_tx as usize]);
    if w == 64 || h == 64 {
        if w == 16 {
            return TX_16X32;
        }
        if h == 16 {
            return TX_32X16;
        }
        return TX_32X32;
    }
    uv_tx
}

/// CflAllowed for a non-lossless block.
pub fn cfl_allowed(bsize: i32) -> bool {
    bw4(bsize) <= 8 && bh4(bsize) <= 8
}

/// Block-level neighbour availability (spec decode_block).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Avail {
    /// AvailU / AvailL
    pub u: bool,
    pub l: bool,
    /// AvailUChroma / AvailLChroma (false without chroma)
    pub u_chroma: bool,
    pub l_chroma: bool,
}

/// AvailU / AvailL for luma and AvailUChroma / AvailLChroma; tile bounds in luma mi units.
pub fn block_avail(
    bsize: i32,
    mi_row: i32,
    mi_col: i32,
    mono: bool,
    tile_r0: i32,
    tile_r1: i32,
    tile_c0: i32,
    tile_c1: i32,
) -> Avail {
    let inside = |r: i32, c: i32| c >= tile_c0 && c < tile_c1 && r >= tile_r0 && r < tile_r1;
    let u = inside(mi_row - 1, mi_col);
    let l = inside(mi_row, mi_col - 1);
    let (mut u_chroma, mut l_chroma) = (false, false);
    if has_chroma(bsize, mi_row, mi_col, mono) {
        u_chroma = if bh4(bsize) == 1 { inside(mi_row - 2, mi_col) } else { u };
        l_chroma = if bw4(bsize) == 1 { inside(mi_row, mi_col - 2) } else { l };
    }
    Avail {
        u,
        l,
        u_chroma,
        l_chroma,
    }
}

/// A coded tx block's edge availability for intra prediction (spec transform_block).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TxbEdges {
    pub have_left: bool,
    pub have_above: bool,
    pub have_above_right: bool,
    pub have_below_left: bool,
}

/// Edge availability of a coded tx block for intra prediction (spec transform_block: haveLeft,
/// haveAbove, haveAboveRight, haveBelowLeft) WITHOUT the decoder's sequential BlockDecoded state:
/// `ordmap[y4 * stride + x4]` (plane units) holds the index (layout order) of the coded tx block of
/// this plane covering that 4x4, or 0xFFFFFFFF. The map must cover the whole 64x64 superblock grid
/// (stride >= (sbCols * 16) >> ss, rows >= (sbRows * 16) >> ss) and every coded tx block marks its
/// FULL area, also the part beyond the frame edge (as the spec's BlockDecoded marking does). A
/// neighbour is "decoded" iff it lies in the current superblock and its covering tx block precedes
/// t, or it is in the row above / column left of the SB inside the tile (spec
/// clear_block_decoded_flags). For GPU closed-loop engines.
///   plane/x4/y4/tx_sz/t: the tx block; xi/yi: its 4x4 offset inside the block;
///   block_avail_l/u: AvailL/AvailU (plane 0) or AvailLChroma/AvailUChroma.
pub fn txb_edges(
    plane: i32,
    x4: i32,
    y4: i32,
    tx_sz: i32,
    t: u32,
    xi: i32,
    yi: i32,
    block_avail_l: bool,
    block_avail_u: bool,
    tile_r1: i32,
    tile_c1: i32,
    ordmap: &[u32],
    stride: usize,
) -> TxbEdges {
    let sub = (plane != 0) as i32;
    let (row, col) = (y4 << sub, x4 << sub); // luma mi
    let (sb_r, sb_c) = (row & !15, col & !15); // SB origin, luma mi
    let (by, bx) = ((row & 15) >> sub, (col & 15) >> sub);
    let step_x = Tx_Width[tx_sz as usize] as i32 >> 2;
    let step_y = Tx_Height[tx_sz as usize] as i32 >> 2;
    let sb_size = 16 >> sub;
    let (sb_w4, sb_h4) = ((tile_c1 - sb_c) >> sub, (tile_r1 - sb_r) >> sub);
    let (x0, y0) = (sb_c >> sub, sb_r >> sub); // SB origin, plane 4x4 units
    // BlockDecoded[plane][yy][xx] in SB-relative plane units
    let bd = |yy: i32, xx: i32| -> bool {
        if yy < 0 {
            xx < sb_w4
        } else if xx < 0 {
            yy < sb_h4 && yy != sb_size
        } else if yy >= sb_size || xx >= sb_size {
            false
        } else {
            ordmap[(y0 + yy) as usize * stride + (x0 + xx) as usize] < t
        }
    };
    TxbEdges {
        have_left: block_avail_l || xi > 0,
        have_above: block_avail_u || yi > 0,
        have_above_right: bd(by - 1, bx + step_x),
        have_below_left: bd(by + step_y, bx - 1),
    }
}

#[inline]
fn is_smooth(m: u8) -> bool {
    matches!(m as i32, SMOOTH_PRED | SMOOTH_V_PRED | SMOOTH_H_PRED)
}

/// get_filter_type (spec 7.11.2.8) for the intra edge filter: 1 if the above or left block (chroma:
/// the chroma-carrying block of that 8x8 unit) uses SMOOTH / SMOOTH_V / SMOOTH_H. `y_modes` /
/// `uv_modes`: 4x4 maps (stride = MiCols) of YMode and UVMode (UVMode written by blocks that carry
/// chroma); avail_u / avail_l: AvailU / AvailL (plane 0) or AvailUChroma / AvailLChroma.
pub fn get_filter_type(
    plane: i32,
    mi_row: i32,
    mi_col: i32,
    avail_u: bool,
    avail_l: bool,
    y_modes: &[u8],
    uv_modes: &[u8],
    mi_cols: i32,
) -> i32 {
    let m = if plane != 0 { uv_modes } else { y_modes };
    let mut above_smooth = false;
    let mut left_smooth = false;
    if avail_u {
        let (mut r, mut c) = (mi_row - 1, mi_col);
        if plane > 0 {
            if mi_col & 1 == 0 {
                c += 1;
            }
            if mi_row & 1 != 0 {
                r -= 1;
            }
        }
        above_smooth = is_smooth(m[r as usize * mi_cols as usize + c as usize]);
    }
    if avail_l {
        let (mut r, mut c) = (mi_row, mi_col - 1);
        if plane > 0 {
            if mi_col & 1 != 0 {
                c -= 1;
            }
            if mi_row & 1 == 0 {
                r += 1;
            }
        }
        left_smooth = is_smooth(m[r as usize * mi_cols as usize + c as usize]);
    }
    (above_smooth || left_smooth) as i32
}

/// Iterates the coded tx blocks of one block in bitstream order: calls `f(plane, tx_sz, x4, y4, xi,
/// yi)` where (x4, y4) is the tx block's position in its plane (4-sample units) and (xi, yi) its
/// index within the block (4x4 units of the plane, the spec's x / y in transform_block). Returns
/// the count.
pub fn for_each_txb(
    bsize: i32,
    mi_row: i32,
    mi_col: i32,
    tx_depth: i32,
    mono: bool,
    mi_rows: i32,
    mi_cols: i32,
    mut f: impl FnMut(i32, i32, i32, i32, i32, i32),
) -> i32 {
    let mut n = 0;
    let planes = if has_chroma(bsize, mi_row, mi_col, mono) { 3 } else { 1 };
    for plane in 0..planes {
        let sub = (plane != 0) as i32;
        let tx_sz = if plane != 0 {
            uv_tx_size(bsize)
        } else {
            luma_tx_size(bsize, tx_depth)
        };
        let step_x = Tx_Width[tx_sz as usize] as usize >> 2;
        let step_y = Tx_Height[tx_sz as usize] as usize >> 2;
        let plane_sz = if plane != 0 { uv_bsize(bsize) } else { bsize };
        let (num4x4_w, num4x4_h) = (bw4(plane_sz), bh4(plane_sz));
        let (base_x4, base_y4) = (mi_col >> sub, mi_row >> sub);
        let (max_x4, max_y4) = (mi_cols >> sub, mi_rows >> sub); // (MiCols * MI_SIZE) >> sub in 4-units
        for y in (0..num4x4_h).step_by(step_y) {
            for x in (0..num4x4_w).step_by(step_x) {
                let (x4, y4) = (base_x4 + x, base_y4 + y);
                if x4 >= max_x4 || y4 >= max_y4 {
                    continue;
                }
                f(plane, tx_sz, x4, y4, x, y);
                n += 1;
            }
        }
    }
    n
}

/// The luma tx blocks of an inter block whose tx size is `tx_sz` everywhere (a uniform var-tx
/// tree: at most 2 splits, so at most 16 leaves), in the spec's transform_tree order: (x, y) in
/// 4x4 units within the block, into `out`. Returns the count.
pub fn tx_tree_order(bsize: i32, tx_sz: i32, out: &mut [(i32, i32); 16]) -> usize {
    let (tw, th) = (
        Tx_Width[tx_sz as usize] as i32 >> 2,
        Tx_Height[tx_sz as usize] as i32 >> 2,
    );
    fn tree(x: i32, y: i32, w: i32, h: i32, tw: i32, th: i32, out: &mut [(i32, i32); 16], n: &mut usize) {
        if w <= tw && h <= th {
            out[*n] = (x, y);
            *n += 1;
        } else if w > h {
            tree(x, y, w / 2, h, tw, th, out, n);
            tree(x + w / 2, y, w / 2, h, tw, th, out, n);
        } else if w < h {
            tree(x, y, w, h / 2, tw, th, out, n);
            tree(x, y + h / 2, w, h / 2, tw, th, out, n);
        } else {
            tree(x, y, w / 2, h / 2, tw, th, out, n);
            tree(x + w / 2, y, w / 2, h / 2, tw, th, out, n);
            tree(x, y + h / 2, w / 2, h / 2, tw, th, out, n);
            tree(x + w / 2, y + h / 2, w / 2, h / 2, tw, th, out, n);
        }
    }
    let mut n = 0;
    tree(0, 0, bw4(bsize), bh4(bsize), tw, th, out, &mut n);
    n
}

/// [`for_each_txb`] for a block that may be inter: an inter block's luma tx blocks (one uniform
/// size, `tx_depth` splits of Max_Tx_Size_Rect) come in the spec's transform_tree order (halves
/// of the longer side, quadrants of squares, recursively), which differs from raster order when
/// a quadrant is split again. Chroma is as for intra blocks.
pub fn for_each_txb_ex(
    bsize: i32,
    mi_row: i32,
    mi_col: i32,
    tx_depth: i32,
    inter: bool,
    mono: bool,
    mi_rows: i32,
    mi_cols: i32,
    mut f: impl FnMut(i32, i32, i32, i32, i32, i32),
) -> i32 {
    if !inter {
        return for_each_txb(bsize, mi_row, mi_col, tx_depth, mono, mi_rows, mi_cols, f);
    }
    let tx_sz = luma_tx_size(bsize, tx_depth);
    let mut order = [(0, 0); 16];
    let mut n = 0;
    let leaves = tx_tree_order(bsize, tx_sz, &mut order);
    for &(x, y) in &order[..leaves] {
        if mi_col + x < mi_cols && mi_row + y < mi_rows {
            f(0, tx_sz, mi_col + x, mi_row + y, x, y);
            n += 1;
        }
    }
    if has_chroma(bsize, mi_row, mi_col, mono) {
        let tx_sz = uv_tx_size(bsize);
        let step_x = Tx_Width[tx_sz as usize] as usize >> 2;
        let step_y = Tx_Height[tx_sz as usize] as usize >> 2;
        let plane_sz = uv_bsize(bsize);
        let (base_x4, base_y4) = (mi_col >> 1, mi_row >> 1);
        for plane in 1..3 {
            for y in (0..bh4(plane_sz)).step_by(step_y) {
                for x in (0..bw4(plane_sz)).step_by(step_x) {
                    let (x4, y4) = (base_x4 + x, base_y4 + y);
                    if x4 >= mi_cols >> 1 || y4 >= mi_rows >> 1 {
                        continue;
                    }
                    f(plane, tx_sz, x4, y4, x, y);
                    n += 1;
                }
            }
        }
    }
    n
}

#[cfg(all(test, feature = "oracle"))]
mod tests {
    use super::*;
    use crate::dsp::Rng;
    use core::ffi::{c_char, c_int};

    unsafe extern "C" {
        fn oracle_dsp_int(what: *const c_char, a: c_int, b: c_int, c: c_int, d: c_int) -> i64;
        fn oracle_bi_block_avail(
            bsize: c_int,
            r: c_int,
            c: c_int,
            mono: c_int,
            r0: c_int,
            r1: c_int,
            c0: c_int,
            c1: c_int,
            out: *mut c_int,
        );
        fn oracle_bi_txb_edges(
            plane: c_int,
            x4: c_int,
            y4: c_int,
            tx_sz: c_int,
            t: u32,
            xi: c_int,
            yi: c_int,
            al: c_int,
            au: c_int,
            r1: c_int,
            c1: c_int,
            ordmap: *const u32,
            stride: c_int,
            out: *mut c_int,
        );
        fn oracle_bi_get_filter_type(
            plane: c_int,
            r: c_int,
            c: c_int,
            au: c_int,
            al: c_int,
            y: *const u8,
            uv: *const u8,
            mi_cols: c_int,
        ) -> c_int;
        fn oracle_bi_for_each_txb(
            bsize: c_int,
            r: c_int,
            c: c_int,
            d: c_int,
            mono: c_int,
            mr: c_int,
            mc: c_int,
            out: *mut c_int,
            cap: c_int,
        ) -> c_int;
    }
    fn ci(what: &str, a: i32, b: i32, c: i32, d: i32) -> i64 {
        let s = std::ffi::CString::new(what).unwrap();
        // SAFETY: plain ints.
        let v = unsafe { oracle_dsp_int(s.as_ptr(), a, b, c, d) };
        assert_ne!(v, -999999, "oracle_dsp_int doesn't know {what}");
        v
    }

    #[test]
    fn helpers_match() {
        for bs in 0..BLOCK_SIZES {
            assert_eq!(bw4(bs) as i64, ci("bw4", bs, 0, 0, 0));
            assert_eq!(bh4(bs) as i64, ci("bh4", bs, 0, 0, 0));
            assert_eq!(max_tx_depth(bs) as i64, ci("max_tx_depth", bs, 0, 0, 0));
            assert_eq!(cfl_allowed(bs) as i64, ci("cfl_allowed", bs, 0, 0, 0));
            if bs != BLOCK_128X128 && bs != BLOCK_128X64 && bs != BLOCK_64X128 {
                assert_eq!(uv_bsize(bs) as i64, ci("uv_bsize", bs, 0, 0, 0));
                assert_eq!(uv_tx_size(bs) as i64, ci("uv_tx_size", bs, 0, 0, 0));
            }
            for d in 0..=max_tx_depth(bs) {
                assert_eq!(luma_tx_size(bs, d) as i64, ci("luma_tx_size", bs, d, 0, 0));
            }
            for r in 0..4 {
                for c in 0..4 {
                    for mono in 0..2 {
                        assert_eq!(has_chroma(bs, r, c, mono != 0) as i64, ci("has_chroma", bs, r, c, mono));
                    }
                }
            }
        }
        for t in 0..TX_SIZES_ALL {
            assert_eq!(tx_coeffs(t) as i64, ci("tx_coeffs", t, 0, 0, 0));
        }
        for w in 1..300 {
            assert_eq!(mi_cols(w) as i64, ci("mi_cols", w, 0, 0, 0));
            assert_eq!(mi_rows(w) as i64, ci("mi_rows", w, 0, 0, 0));
        }
    }

    #[test]
    fn block_avail_and_for_each_txb_match() {
        let mut r = Rng(21);
        let mut out = vec![0i32; 6 * 512];
        for _ in 0..4000 {
            let bs = r.range(0, BLOCK_SIZES - 1);
            if bs == BLOCK_128X128 || bs == BLOCK_128X64 || bs == BLOCK_64X128 {
                continue;
            }
            let (mr, mc) = (r.range(1, 80), r.range(1, 80));
            let (row, col) = (r.range(0, mr - 1) & !(bh4(bs) - 1), r.range(0, mc - 1) & !(bw4(bs) - 1));
            let mono = r.below(5) == 0;
            let (r0, c0) = (row - r.range(0, 8), col - r.range(0, 8));
            let (r1, c1) = (row + r.range(1, 20), col + r.range(1, 20));
            let a = block_avail(bs, row, col, mono, r0, r1, c0, c1);
            let mut o = [0i32; 4];
            // SAFETY: 4 ints out.
            unsafe { oracle_bi_block_avail(bs, row, col, mono as i32, r0, r1, c0, c1, o.as_mut_ptr()) };
            assert_eq!([a.u, a.l, a.u_chroma, a.l_chroma].map(|v| v as i32), o);
            let d = r.range(0, max_tx_depth(bs));
            let mut mine = Vec::new();
            let n = for_each_txb(bs, row, col, d, mono, mr, mc, |p, t, x4, y4, xi, yi| {
                mine.extend([p, t, x4, y4, xi, yi])
            });
            // SAFETY: room for 512 tx blocks.
            let m = unsafe { oracle_bi_for_each_txb(bs, row, col, d, mono as i32, mr, mc, out.as_mut_ptr(), 512) };
            assert_eq!(n, m);
            assert_eq!(mine, out[..6 * m as usize]);
        }
    }

    #[test]
    fn txb_edges_and_filter_type_match() {
        let mut r = Rng(22);
        let (sb_cols, sb_rows) = (3usize, 3usize);
        let stride = sb_cols * 16;
        let mut ordmap = vec![0u32; stride * sb_rows * 16];
        for _ in 0..200 {
            for v in ordmap.iter_mut() {
                *v = if r.below(10) == 0 { u32::MAX } else { r.below(1000) };
            }
            for _ in 0..200 {
                let plane = r.range(0, 2);
                let sub = (plane != 0) as i32;
                let t_sz = r.range(0, TX_SIZES_ALL - 1);
                let (sw, sh) = (
                    (Tx_Width[t_sz as usize] >> 2) as i32,
                    (Tx_Height[t_sz as usize] >> 2) as i32,
                );
                let x4 = r.range(0, (48 >> sub) - 1) & !(sw - 1);
                let y4 = r.range(0, (48 >> sub) - 1) & !(sh - 1);
                let (xi, yi) = (r.range(0, 3), r.range(0, 3));
                let (tr1, tc1) = (r.range(1, 48), r.range(1, 48));
                let t = r.below(1000);
                let (al, au) = (r.below(2) == 0, r.below(2) == 0);
                let s = stride >> sub;
                let e = txb_edges(plane, x4, y4, t_sz, t, xi, yi, al, au, tr1, tc1, &ordmap, s);
                let mut o = [0i32; 4];
                // SAFETY: the map covers the SB grid at this stride; 4 ints out.
                unsafe {
                    oracle_bi_txb_edges(
                        plane,
                        x4,
                        y4,
                        t_sz,
                        t,
                        xi,
                        yi,
                        al as i32,
                        au as i32,
                        tr1,
                        tc1,
                        ordmap.as_ptr(),
                        s as i32,
                        o.as_mut_ptr(),
                    )
                };
                assert_eq!(
                    [e.have_left, e.have_above, e.have_above_right, e.have_below_left].map(|v| v as i32),
                    o
                );
            }
        }
        let mc = 40;
        for _ in 0..20000 {
            let y: Vec<u8> = (0..mc * mc).map(|_| r.below(13) as u8).collect();
            let uv: Vec<u8> = (0..mc * mc).map(|_| r.below(14) as u8).collect();
            let plane = r.range(0, 2);
            let (row, col) = (r.range(2, mc - 3), r.range(2, mc - 3));
            let (au, al) = (r.below(2) == 0, r.below(2) == 0);
            let v = get_filter_type(plane, row, col, au, al, &y, &uv, mc);
            // SAFETY: maps of mc x mc; the neighbours read stay inside.
            let c = unsafe {
                oracle_bi_get_filter_type(plane, row, col, au as i32, al as i32, y.as_ptr(), uv.as_ptr(), mc)
            };
            assert_eq!(v, c);
        }
    }
}
