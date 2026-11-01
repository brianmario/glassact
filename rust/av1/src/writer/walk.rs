//! The syntax walk of one tile (spec 5.9 / 5.11 with the context derivations of 8.3.2), generic
//! over the [`Sink`]: in write mode it also reconstructs exactly (prediction, range-checked inverse
//! transform, the closed-loop hook).
//!
//! A tile reconstructs into its own [`TileBufs`] (planes and mode-info maps covering the tile's
//! superblocks, at tile-local coordinates): every read of the walk is gated by tile-local
//! availability, so tiles share nothing while they are coded.

mod palette;

use super::mvstack::{MvMaps, MvStack, REF_UNSET, derive_mode, find_mv_stack, mv_class};
use super::recon::TilePlan;
use super::sink::Sink;
use super::{Res, TileInfo, TxbCtx, TxbHook, fail};
use crate::blockinfo::*;
use crate::dsp::*;
use crate::entropy::{Cdfs, FrameCdfs, InterCdfs};
use crate::tables::*;
use crate::types::*;
use palette::PaletteMaps;
pub(crate) use palette::{map_dims, map_origin, predict_palette};

/// [`TileBufs::pal_at`]: a block without a palette.
pub(crate) const NO_PALETTE: u32 = u32::MAX;

/// The frame: shared and read only while its tiles are coded.
#[derive(Clone, Copy)]
pub(crate) struct Frame<'a> {
    pub fp: FrameParams,
    pub mi_cols: i32,
    pub mi_rows: i32,
    pub mono: bool,
    pub sb_cols: i32,
    pub sb_rows: i32,
    pub tiles: TileInfo,
    /// quantizer-matrix level per plane (15 = none)
    pub qm_level: [i32; 3],
    pub do_recon: bool,
    pub fix_range: bool,
    pub check_edges: bool,
    /// [`super::ENC_CHECK_EDGES`]: per plane, the covering tx block index of every 4x4
    pub ordmap: &'a [Vec<u32>; 3],
    /// an inter frame (video mode, frame_type INTER): inter_frame_mode_info
    pub inter: bool,
    /// an inter frame with a reconstruction: LAST_FRAME's planes
    pub refs: Option<[RefPlane<'a>; 3]>,
    /// the CDFs every tile starts from (primary_ref_frame's saved ones); `None`: the defaults
    pub cdfs_in: Option<&'a FrameCdfs>,
    /// video mode: where tile `context_tile` (context_update_tile_id) leaves its CDFs, counters
    /// cleared, and sets the flag
    pub cdfs_out: Option<&'a std::sync::Mutex<(bool, Box<FrameCdfs>)>>,
    pub context_tile: usize,
    /// fp.sb128: 128x128 superblocks
    pub sb128: bool,
    /// the picture may have palette blocks (writing: the record has palettes; parsing: with
    /// allow_screen_content_tools): the tiles keep [`TileBufs::pal_at`]
    pub palettes: bool,
}

impl Frame<'_> {
    #[inline(always)]
    fn planes(&self) -> usize {
        if self.mono { 1 } else { 3 }
    }
    /// the superblock's size in luma 4x4 units (sbSize4)
    #[inline(always)]
    fn sb_size4(&self) -> i32 {
        if self.sb128 { 32 } else { 16 }
    }
}

/// One tile's reconstruction and mode-info maps, at tile-local coordinates. Reused across pictures.
#[derive(Default)]
pub(crate) struct TileBufs {
    /// origin and size in luma mi units (the size up to the tile end, clamped to the coded area)
    pub r0: i32,
    pub c0: i32,
    pub mw: i32,
    pub mh: i32,
    /// the tile's 64x64s (also with 128x128 superblocks: the buffers stay 64x64-granular, a
    /// 128x128 superblock's blocks never reaching past the 64x64s that start inside the frame)
    pub sb_cols: i32,
    pub sb_rows: i32,
    /// the tile's 64x64s' samples, stride sb_cols * 64 >> sub
    pub plane: [Vec<u8>; 3],
    pub stride: [usize; 3],
    pub height: [usize; 3],
    pub has_planes: bool,
    // 4x4-granular mode info, mh x mw, stride mw
    pub mi_size: Vec<u8>,
    pub y_mode: Vec<u8>,
    pub skip: Vec<u8>,
    pub tx_size: Vec<u8>,
    pub uv_mode: Vec<u8>,
    /// LoopfilterTxSizes for U, V: (mh / 2) x (mw / 2)
    pub lf_uv: [Vec<u8>; 2],
    /// cdef_idx per 64x64 (-1: no non-skip block)
    pub sb_cdef: Vec<i8>,
    /// the palette (in `pals`) of the block covering each 4x4, or [`NO_PALETTE`] (PaletteSizes and
    /// PaletteColors of the spec), mh x mw; empty without [`Frame::palettes`] (none)
    pub pal_at: Vec<u32>,
    pub pals: Vec<BlockPalette>,
    /// inter frames: RefFrames[.][.][0] (0 intra, 1 LAST_FRAME, REF_UNSET not coded yet) and
    /// Mvs[.][.][0] (valid where LAST_FRAME), mh x mw
    pub ref0: Vec<u8>,
    pub mvs: Vec<[i16; 2]>,
}

impl TileBufs {
    /// Sizes the buffers for tile (tr, tc) of the frame and clears the maps; the planes (when
    /// `planes`) keep their samples, which the walk overwrites before reading.
    pub fn setup(&mut self, f: &Frame, tr: usize, tc: usize, planes: bool) {
        let t = &f.tiles;
        let (r0, r1) = (t.mi_row_starts[tr] as i32, t.mi_row_starts[tr + 1] as i32);
        let (c0, c1) = (t.mi_col_starts[tc] as i32, t.mi_col_starts[tc + 1] as i32);
        self.r0 = r0;
        self.c0 = c0;
        self.mw = c1 - c0;
        self.mh = r1 - r0;
        self.sb_cols = ((c1 + 15) >> 4) - (c0 >> 4);
        self.sb_rows = ((r1 + 15) >> 4) - (r0 >> 4);
        self.has_planes = planes;
        for p in 0..3 {
            let sub = (p != 0) as usize;
            self.stride[p] = (self.sb_cols as usize * 64) >> sub;
            self.height[p] = (self.sb_rows as usize * 64) >> sub;
            if planes && p < f.planes() {
                self.plane[p].resize(self.stride[p] * self.height[p], 0);
            }
        }
        let nmi = (self.mw * self.mh) as usize;
        for m in [
            &mut self.mi_size,
            &mut self.y_mode,
            &mut self.skip,
            &mut self.tx_size,
            &mut self.uv_mode,
        ] {
            m.clear();
            m.resize(nmi, 0);
        }
        let nuv = ((self.mw >> 1) * (self.mh >> 1)) as usize;
        for m in &mut self.lf_uv {
            m.clear();
            m.resize(nuv, 0);
        }
        self.pals.clear();
        self.pal_at.clear();
        if f.palettes {
            self.pal_at.resize(nmi, NO_PALETTE);
        }
        self.sb_cdef.clear();
        self.sb_cdef.resize((self.sb_cols * self.sb_rows) as usize, -1);
        if f.inter {
            self.ref0.clear();
            self.ref0.resize(nmi, REF_UNSET);
            self.mvs.resize(nmi, [0; 2]);
        }
    }

    /// A tile that isn't coded: zero samples and maps, as the C++'s zero-initialized frame has.
    pub fn zero_planes(&mut self, nplanes: usize) {
        for p in &mut self.plane[..nplanes] {
            p.fill(0);
        }
    }

    #[inline(always)]
    fn mi(&self, r: i32, c: i32) -> usize {
        ((r - self.r0) * self.mw + (c - self.c0)) as usize
    }

    /// The sb_cdef entry of the 64x64 holding luma 4x4 (r, c), if it's one of the tile's.
    #[inline(always)]
    fn cdef_at(&self, r: i32, c: i32) -> Option<usize> {
        let (y, x) = ((r - self.r0) >> 4, (c - self.c0) >> 4);
        (y < self.sb_rows && x < self.sb_cols).then_some((y * self.sb_cols + x) as usize)
    }
}

/// What the inter syntax coded, for the tests' coverage reports: GLOBALMV, NEARESTMV, NEARMV,
/// NEWMV blocks; NEARMV / NEWMV with a drl index > 0 / 1; intra blocks of inter frames; inter
/// blocks with a var-tx split; sub-8x8 chroma predicted from several blocks' motion; NEWMV
/// components with fr bits, with hp bits; then [`INTER_STAT_PHASE`]: the predictions' filter
/// phases.
#[cfg(test)]
pub(crate) static INTER_STAT: [std::sync::atomic::AtomicU64; INTER_STAT_PHASE + 64] =
    [const { std::sync::atomic::AtomicU64::new(0) }; INTER_STAT_PHASE + 64];
/// INTER_STAT[INTER_STAT_PHASE + chroma * 32 + four_tap * 16 + phase]: the 1/16-sample positions
/// (horizontal and vertical) predictions filtered at, by plane type and filter variant.
#[cfg(test)]
pub(crate) const INTER_STAT_PHASE: usize = 11;
/// What 128x128 superblocks coded, for the tests' coverage reports: the 128x128 node's partition
/// types (0..8); 128x128, 128x64, 64x128 blocks (8..11); of those, intra (11), inter (12), skip
/// (13), coded (14), inter and coded (15).
#[cfg(test)]
pub(crate) static SB128_STAT: [std::sync::atomic::AtomicU64; 16] = [const { std::sync::atomic::AtomicU64::new(0) }; 16];
#[inline(always)]
fn sb128_stat(_k: usize) {
    #[cfg(test)]
    SB128_STAT[_k].fetch_add(1, std::sync::atomic::Ordering::Relaxed);
}
#[inline(always)]
fn inter_stat(_k: usize) {
    #[cfg(test)]
    INTER_STAT[_k].fetch_add(1, std::sync::atomic::Ordering::Relaxed);
}

/// The parser's record being built.
#[derive(Default)]
pub(crate) struct ParseRec {
    /// inter frames: one entry per block
    pub inter: Vec<BlockInter>,
    /// with allow_screen_content_tools: one entry per block, and the palette blocks' maps
    pub palette: Vec<BlockPalette>,
    pub palette_map: Vec<u8>,
    pub blocks: Vec<Block>,
    pub block_txb: Vec<u32>,
    pub txb: Vec<Txb>,
    pub coeffs: Vec<i16>,
}

/// The record a tile walk reads (write) or builds (parse).
pub(crate) enum Rec<'a> {
    Write {
        blocks: &'a [Block],
        /// one per block, or empty (all intra)
        inter: &'a [BlockInter],
        /// one per block, or empty (no palettes), and their colour index maps
        palette: &'a [BlockPalette],
        palette_map: &'a [u8],
        block_txb: &'a [u32],
        /// this tile's tx blocks, the first being txb[txb_base]
        txb: &'a mut [Txb],
        txb_base: usize,
        /// this tile's coefficients, the first being coeffs[coeff_base]
        coeffs: &'a mut [i16],
        coeff_base: usize,
    },
    Parse(&'a mut ParseRec),
}

/// Padded coefficient level buffer (TX_PAD_HOR = 4 columns and rows): the context neighbours of
/// the spec (non-negative offsets only) never need a bounds check.
const LEV_STRIDE_PAD: usize = 4;
const LEV_N: usize = (32 + LEV_STRIDE_PAD) * (32 + LEV_STRIDE_PAD);

/// One worker's tile state: CDFs, coefficient contexts, BlockDecoded, the current block. Reused.
pub(crate) struct TileState {
    pub cdf: Cdfs,
    /// inter frames' CDFs
    icdf: Box<InterCdfs>,
    mc: Box<McScratch>,
    /// the current block's luma TxTypes (inter blocks: chroma derives from them), block-relative 4x4s
    tx_types: [[u8; 32]; 32],
    /// the current inter block's luma tx blocks in transform_tree order (of one 64x64 residual
    /// unit for blocks wider or taller than 64)
    tree: [(i32, i32); 16],
    n_tree: usize,
    is_inter: bool,
    above_level: [Vec<u8>; 3],
    above_dc: [Vec<u8>; 3],
    left_level: [Vec<u8>; 3],
    left_dc: [Vec<u8>; 3],
    /// BlockDecoded[plane][y + 1][x + 1], y and x -1 ..= sbSize4 >> sub
    block_decoded: [[[u8; 34]; 34]; 3],
    dq: Box<[i32; 1024]>,
    res: Box<[i32; 4096]>,
    lev: Box<[u8; LEV_N]>,
    // tile
    mi_row_start: i32,
    mi_row_end: i32,
    mi_col_start: i32,
    mi_col_end: i32,
    pub cursor: u32,
    pub tile_end: u32,
    pub n_fixed: u64,
    current_q_index: i32,
    read_deltas: bool,
    block_q: i32,
    dc_q: [i32; 3],
    ac_q: [i32; 3],
    // current block
    b_idx: u32,
    mi_row: i32,
    mi_col: i32,
    mi_size: i32,
    bw4: i32,
    bh4: i32,
    has_chroma: bool,
    avail_u: bool,
    avail_l: bool,
    avail_uc: bool,
    avail_lc: bool,
    tx_size: i32,
    /// the last luma tx block's extent (tile-local luma samples), for CfL
    max_luma_w: i32,
    max_luma_h: i32,
    cur_txb: u32,
    /// the current block's palettes and colour index maps
    pal: BlockPalette,
    maps: Option<Box<PaletteMaps>>,
}

impl Default for TileState {
    fn default() -> Self {
        TileState {
            cdf: Cdfs::new(0),
            icdf: Box::default(),
            mc: Box::default(),
            tx_types: [[0; 32]; 32],
            tree: [(0, 0); 16],
            n_tree: 0,
            is_inter: false,
            above_level: Default::default(),
            above_dc: Default::default(),
            left_level: Default::default(),
            left_dc: Default::default(),
            block_decoded: [[[0; 34]; 34]; 3],
            dq: Box::new([0; 1024]),
            res: Box::new([0; 4096]),
            lev: Box::new([0; LEV_N]),
            mi_row_start: 0,
            mi_row_end: 0,
            mi_col_start: 0,
            mi_col_end: 0,
            cursor: 0,
            tile_end: 0,
            n_fixed: 0,
            current_q_index: 0,
            read_deltas: false,
            block_q: -1,
            dc_q: [0; 3],
            ac_q: [0; 3],
            b_idx: 0,
            mi_row: 0,
            mi_col: 0,
            mi_size: 0,
            bw4: 0,
            bh4: 0,
            has_chroma: false,
            avail_u: false,
            avail_l: false,
            avail_uc: false,
            avail_lc: false,
            tx_size: 0,
            max_luma_w: 0,
            max_luma_h: 0,
            cur_txb: 0,
            pal: BlockPalette::default(),
            maps: None,
        }
    }
}

impl TileState {
    /// Sizes the coefficient context arrays for a frame.
    pub fn setup(&mut self, mi_cols: i32, mi_rows: i32) {
        for p in 0..3 {
            for (v, n) in [
                (&mut self.above_level[p], mi_cols),
                (&mut self.above_dc[p], mi_cols),
                (&mut self.left_level[p], mi_rows),
                (&mut self.left_dc[p], mi_rows),
            ] {
                v.resize(n as usize + 32, 0);
            }
        }
    }

    #[inline(always)]
    fn is_inside(&self, r: i32, c: i32) -> bool {
        c >= self.mi_col_start && c < self.mi_col_end && r >= self.mi_row_start && r < self.mi_row_end
    }

    #[inline]
    fn set_block_q(&mut self, fp: &FrameParams, qidx: i32) {
        if qidx == self.block_q {
            return;
        }
        self.block_q = qidx;
        self.dc_q = [
            dc_q(qidx + fp.delta_q_y_dc as i32),
            dc_q(qidx + fp.delta_q_u_dc as i32),
            dc_q(qidx + fp.delta_q_v_dc as i32),
        ];
        self.ac_q = [
            ac_q(qidx),
            ac_q(qidx + fp.delta_q_u_ac as i32),
            ac_q(qidx + fp.delta_q_v_ac as i32),
        ];
    }
}

/// One tile's walk.
pub(crate) struct Walk<'a, S: Sink, H: TxbHook> {
    pub st: &'a mut TileState,
    pub sk: S,
    pub f: &'a Frame<'a>,
    pub bufs: &'a mut TileBufs,
    pub hook: Option<&'a H>,
    pub hs: &'a mut H::Scratch,
    /// planning ([`super::recon`]): no symbols are coded and nothing is reconstructed; the walk
    /// records what the tile's reconstruction needs
    pub plan: Option<&'a mut TilePlan>,
}

/// What an inter block's prediction reads of its tile's maps (sub-8x8 chroma: the motion of the
/// blocks of its 8x8).
pub(super) struct InterMaps<'a> {
    pub ref0: &'a [u8],
    pub mvs: &'a [[i16; 2]],
    pub r0: i32,
    pub c0: i32,
    pub mw: i32,
    pub stride: [usize; 3],
}

/// An inter block's motion-compensated prediction of every plane, into the tile's planes (at
/// tile-local positions).
#[allow(clippy::too_many_arguments)]
pub(super) fn predict_inter_block(
    f: &Frame,
    refs: &[RefPlane; 3],
    maps: &InterMaps,
    planes: &mut [&mut [u8]; 3],
    r: i32,
    c: i32,
    bsize: i32,
    has_chroma: bool,
    mc: &mut McScratch,
) {
    let mi = |y: i32, x: i32| ((y - maps.r0) * maps.mw + (x - maps.c0)) as usize;
    for plane in 0..1 + 2 * has_chroma as usize {
        let sub = (plane != 0) as i32;
        let plane_sz = if plane != 0 { uv_bsize(bsize) } else { bsize };
        let (n4w, n4h) = (bw4(plane_sz), bh4(plane_sz));
        let (base_x, base_y) = ((c >> sub) * 4, (r >> sub) * 4);
        let (mut cand_r, mut cand_c) = ((r >> sub) << sub, (c >> sub) << sub);
        let (mut pw, mut ph) = ((4 * bw4(bsize)) >> sub, (4 * bh4(bsize)) >> sub);
        if sub != 0 {
            // someUseIntra over the 8x8 unit (positions past the coded area are this block's)
            let mut some_intra = false;
            for y in cand_r..(cand_r + (n4h << sub)).min(f.mi_rows) {
                for x in cand_c..(cand_c + (n4w << sub)).min(f.mi_cols) {
                    some_intra |= maps.ref0[mi(y, x)] as i32 == INTRA_FRAME;
                }
            }
            if !some_intra && (pw < 4 || ph < 4) {
                inter_stat(8);
            }
            if some_intra {
                (pw, ph) = (n4w * 4, n4h * 4);
                (cand_r, cand_c) = (r, c);
            }
        }
        let filters = [
            subpel_filter(EIGHTTAP, pw as usize),
            subpel_filter(EIGHTTAP, ph as usize),
        ];
        let (ox, oy) = ((maps.c0 * 4) >> sub, (maps.r0 * 4) >> sub);
        let stride = maps.stride[plane];
        let (w, h) = (pw as usize, ph as usize);
        for (ri, y) in (0..n4h * 4).step_by(h).enumerate() {
            for (ci, x) in (0..n4w * 4).step_by(w).enumerate() {
                let (px, py) = (base_x + x, base_y + y);
                let m = maps.mvs[mi(cand_r + ri as i32, cand_c + ci as i32)];
                #[cfg(test)]
                {
                    let (qx, qy) = crate::dsp::mc_position(px, py, [m[0] as i32, m[1] as i32], sub);
                    let k = INTER_STAT_PHASE + 32 * sub as usize;
                    inter_stat(k + 16 * (filters[0] >= 4) as usize + (qx & 15) as usize);
                    inter_stat(k + 16 * (filters[1] >= 4) as usize + (qy & 15) as usize);
                }
                // blocks wider or taller than MC_MAX (128-sample ones) in parts: a sample's
                // prediction depends only on its position and the block's filters
                for dy in (0..h).step_by(MC_MAX) {
                    for dx in (0..w).step_by(MC_MAX) {
                        let (qx, qy) = (px + dx as i32, py + dy as i32);
                        let off = (qy - oy) as usize * stride + (qx - ox) as usize;
                        predict_inter(
                            &refs[plane],
                            sub,
                            qx,
                            qy,
                            (w - dx).min(MC_MAX),
                            (h - dy).min(MC_MAX),
                            [m[0] as i32, m[1] as i32],
                            filters,
                            &mut planes[plane][off..],
                            stride,
                            mc,
                        );
                    }
                }
            }
        }
    }
}

/// What an intra tx block's prediction reads: which neighbours are decoded (spec 7.11.2's
/// haveLeft, haveAbove, haveAboveRight, haveBelowLeft) and the edge filter's type.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct TxbEdges {
    pub left: bool,
    pub above: bool,
    pub above_right: bool,
    pub below_left: bool,
    /// get_filter_type (0 or 1)
    pub filter_type: i32,
}

impl TxbEdges {
    pub fn pack(self) -> u8 {
        self.left as u8
            | (self.above as u8) << 1
            | (self.above_right as u8) << 2
            | (self.below_left as u8) << 3
            | (self.filter_type as u8) << 4
    }
    pub fn unpack(v: u8) -> TxbEdges {
        TxbEdges {
            left: v & 1 != 0,
            above: v & 2 != 0,
            above_right: v & 4 != 0,
            below_left: v & 8 != 0,
            filter_type: (v >> 4) as i32,
        }
    }
}

/// An intra tx block's prediction (with CfL, from the block's luma reconstructed so far: the
/// luma extent `max_luma`) into `cur`, its plane, at tile-local sample (lx, ly); `luma` is the
/// luma plane for a chroma tx block.
#[allow(clippy::too_many_arguments)]
pub(super) fn predict_intra_txb(
    fp: &FrameParams,
    b: &Block,
    plane: usize,
    tx_sz: i32,
    e: TxbEdges,
    (lx, ly): (i32, i32),
    (max_x, max_y): (i32, i32),
    cur: &mut [u8],
    stride: usize,
    luma: &[u8],
    luma_stride: usize,
    max_luma: (i32, i32),
) {
    let is_cfl = plane > 0 && b.uv_mode as i32 == UV_CFL_PRED;
    let mode = if plane == 0 {
        b.y_mode as i32
    } else if is_cfl {
        DC_PRED
    } else {
        b.uv_mode as i32
    };
    let log2w = t8(&Tx_Width_Log2, tx_sz);
    let log2h = t8(&Tx_Height_Log2, tx_sz);
    let mut edge_a: Edge = [0; EDGE_LEN];
    let mut edge_l: Edge = [0; EDGE_LEN];
    build_edges(
        cur,
        stride,
        lx,
        ly,
        log2w,
        log2h,
        e.left,
        e.above,
        e.above_right,
        e.below_left,
        max_x,
        max_y,
        &mut edge_a,
        &mut edge_l,
    );
    let angle = if plane == 0 { b.angle_delta_y } else { b.angle_delta_uv } as i32;
    let fi = if plane == 0 && b.filter_intra != 0 {
        b.filter_intra as i32 - 1
    } else {
        -1
    };
    let off = ly as usize * stride + lx as usize;
    predict_intra_ex(
        mode,
        angle,
        fi,
        fp.enable_intra_edge_filter != 0,
        e.filter_type,
        e.left,
        e.above,
        log2w,
        log2h,
        lx,
        ly,
        max_x,
        max_y,
        &mut edge_a,
        &mut edge_l,
        &mut cur[off..],
        stride,
    );
    if is_cfl {
        cfl_predict(
            cur,
            stride,
            luma,
            luma_stride,
            lx,
            ly,
            tx_sz,
            1,
            1,
            max_luma.0,
            max_luma.1,
            if plane == 1 { b.cfl_alpha_u } else { b.cfl_alpha_v } as i32,
        );
    }
}

/// A coded tx block's levels (write mode): with a reconstruction, the closed-loop hook's (which
/// may also pick the luma `tx_type`); the luma tx set check; and with a reconstruction the
/// range-checked dequantization and inverse transform into `res` (with fix_range, levels that
/// overflow it are halved until they don't, counted in `n_fixed`). Returns eob.
#[allow(clippy::too_many_arguments)]
pub(super) fn levels<H: TxbHook>(
    f: &Frame,
    hook: Option<(&H, &mut H::Scratch)>,
    ctx: &TxbCtx,
    t: &mut Txb,
    q: &mut [i16],
    tx_type: &mut i32,
    dq: &mut [i32; 1024],
    res: &mut [i32; 4096],
    n_fixed: &mut u64,
) -> Res<i32> {
    let fp = &f.fp;
    let plane = t.plane as usize;
    let tx_sz = t.tx_size as i32;
    let n = tx_coeffs(tx_sz);
    if f.do_recon
        && let Some((h, hs)) = hook
    {
        h.on_txb(hs, ctx, t, q);
        if plane == 0 {
            *tx_type = t.tx_type as i32;
        }
    }
    // eob, and whether any level is nonzero, from one pass (the scan of an invalid luma type is
    // never used: that is an error then)
    let mut eob = eob_of(&q[..n], get_iscan(tx_sz, *tx_type));
    let mut nz = eob > 0;
    if nz && plane == 0 {
        let reduced = fp.reduced_tx_set != 0;
        let (set, ok) = if ctx.is_inter {
            let set = get_tx_set_inter(tx_sz, reduced);
            (set, *tx_type < TX_TYPES && tx_type_in_set_inter(set, *tx_type))
        } else {
            let set = get_tx_set_intra(tx_sz, reduced);
            (set, *tx_type < TX_TYPES && tx_type_in_set_intra(set, *tx_type))
        };
        if !ok {
            fail!(
                ERR_INVALID,
                "block {}: luma tx_type {} not in {} tx set {set} of tx size {tx_sz}",
                ctx.block_idx,
                *tx_type,
                if ctx.is_inter { "inter" } else { "intra" }
            );
        }
    }
    if nz && f.do_recon {
        let m = qm(fp.using_qmatrix != 0, f.qm_level[plane], plane as i32, tx_sz, *tx_type);
        loop {
            dequant(q, &mut dq[..], tx_sz, ctx.dc_q, ctx.ac_q, m);
            let err = inv_txfm2d(&dq[..], tx_sz, *tx_type, &mut res[..]);
            if err == 0 {
                break;
            }
            if !f.fix_range {
                fail!(
                    ERR_RANGE,
                    "block {} plane {plane} tx ({},{}): coefficients overflow inverse transform range (flags {err})",
                    ctx.block_idx,
                    t.x4,
                    t.y4
                );
            }
            nz = false;
            for v in &mut q[..n] {
                *v /= 2;
                nz |= *v != 0;
            }
            *n_fixed += 1;
            if !nz {
                break;
            }
        }
        eob = eob_of(&q[..n], get_iscan(tx_sz, *tx_type));
    }
    Ok(eob)
}

/// The inverse of [`get_scan`]: the scan index of each coefficient position.
pub(crate) fn get_iscan(tx_sz: i32, tx_type: i32) -> &'static [u16] {
    if tx_sz == TX_16X64 {
        return &IDefault_Scan_16x32;
    }
    if tx_sz == TX_64X16 {
        return &IDefault_Scan_32x16;
    }
    if Tx_Size_Sqr_Up[tx_sz as usize] as i32 == TX_64X64 {
        return &IDefault_Scan_32x32;
    }
    let cls = if tx_type == IDTX {
        TX_CLASS_2D
    } else {
        tx_class(tx_type)
    };
    if cls == TX_CLASS_VERT {
        return match tx_sz {
            TX_4X4 => &IMrow_Scan_4x4,
            TX_4X8 => &IMrow_Scan_4x8,
            TX_8X4 => &IMrow_Scan_8x4,
            TX_8X8 => &IMrow_Scan_8x8,
            TX_8X16 => &IMrow_Scan_8x16,
            TX_16X8 => &IMrow_Scan_16x8,
            TX_16X16 => &IMrow_Scan_16x16,
            TX_4X16 => &IMrow_Scan_4x16,
            _ => &IMrow_Scan_16x4,
        };
    }
    if cls == TX_CLASS_HORIZ {
        return match tx_sz {
            TX_4X4 => &IMcol_Scan_4x4,
            TX_4X8 => &IMcol_Scan_4x8,
            TX_8X4 => &IMcol_Scan_8x4,
            TX_8X8 => &IMcol_Scan_8x8,
            TX_8X16 => &IMcol_Scan_8x16,
            TX_16X8 => &IMcol_Scan_16x8,
            TX_16X16 => &IMcol_Scan_16x16,
            TX_4X16 => &IMcol_Scan_4x16,
            _ => &IMcol_Scan_16x4,
        };
    }
    match tx_sz {
        TX_4X4 => &IDefault_Scan_4x4,
        TX_4X8 => &IDefault_Scan_4x8,
        TX_8X4 => &IDefault_Scan_8x4,
        TX_8X8 => &IDefault_Scan_8x8,
        TX_8X16 => &IDefault_Scan_8x16,
        TX_16X8 => &IDefault_Scan_16x8,
        TX_16X16 => &IDefault_Scan_16x16,
        TX_16X32 => &IDefault_Scan_16x32,
        TX_32X16 => &IDefault_Scan_32x16,
        TX_4X16 => &IDefault_Scan_4x16,
        TX_16X4 => &IDefault_Scan_16x4,
        TX_8X32 => &IDefault_Scan_8x32,
        TX_32X8 => &IDefault_Scan_32x8,
        _ => &IDefault_Scan_32x32,
    }
}

/// The end of block of levels `q`: 1 + the largest scan index of a nonzero level (0 if none), from
/// one pass over the levels in raster order rather than a reverse walk of the scan.
#[inline]
pub(crate) fn eob_of(q: &[i16], iscan: &[u16]) -> i32 {
    if iscan.len() < q.len() {
        // the scan of a tx type the size doesn't have: only "nonzero" matters (an error then)
        return q.iter().any(|&v| v != 0) as i32;
    }
    #[cfg(target_arch = "aarch64")]
    if q.len().is_multiple_of(16) {
        return eob_of_neon(q, iscan);
    }
    eob_of_scalar(q, iscan)
}

/// [`eob_of`]'s reference.
pub(crate) fn eob_of_scalar(q: &[i16], iscan: &[u16]) -> i32 {
    q.iter()
        .zip(iscan)
        .filter(|&(&v, _)| v != 0)
        .map(|(_, &s)| s as i32 + 1)
        .max()
        .unwrap_or(0)
}

#[cfg(target_arch = "aarch64")]
fn eob_of_neon(q: &[i16], iscan: &[u16]) -> i32 {
    use core::arch::aarch64::*;
    assert!(iscan.len() >= q.len() && q.len().is_multiple_of(16));
    // SAFETY: NEON is baseline on aarch64; the loads stay inside q and iscan (the assert).
    unsafe {
        let (qp, sp) = (q.as_ptr(), iscan.as_ptr());
        let one = vdupq_n_u16(1);
        let (mut a0, mut a1) = (vdupq_n_u16(0), vdupq_n_u16(0));
        for i in (0..q.len()).step_by(16) {
            let (q0, q1) = (vld1q_s16(qp.add(i)), vld1q_s16(qp.add(i + 8)));
            let (s0, s1) = (vld1q_u16(sp.add(i)), vld1q_u16(sp.add(i + 8)));
            a0 = vmaxq_u16(a0, vandq_u16(vaddq_u16(s0, one), vtstq_s16(q0, q0)));
            a1 = vmaxq_u16(a1, vandq_u16(vaddq_u16(s1, one), vtstq_s16(q1, q1)));
        }
        vmaxvq_u16(vmaxq_u16(a0, a1)) as i32
    }
}

/// `d.fill(v)` for the walk's short runs (contexts, mode-info rows): the usual lengths are single
/// stores rather than memset calls.
#[inline(always)]
fn fill_small(d: &mut [u8], v: u8) {
    match d.len() {
        1 => d[0] = v,
        2 => d.copy_from_slice(&[v; 2]),
        4 => d.copy_from_slice(&[v; 4]),
        8 => d.copy_from_slice(&[v; 8]),
        16 => d.copy_from_slice(&[v; 16]),
        _ => d.fill(v),
    }
}

#[inline(always)]
fn t8(t: &[u8], i: i32) -> i32 {
    t[i as usize] as i32
}

impl<S: Sink, H: TxbHook> Walk<'_, S, H> {
    /// L(n): a literal, MSB first.
    #[inline]
    fn lit(&mut self, v_w: i32, n: i32) -> i32 {
        let mut v = 0;
        for i in (0..n).rev() {
            v = (v << 1) | self.sk.bit((v_w >> i) & 1);
        }
        v
    }

    /// decode_tile: the tile's superblocks.
    pub fn tile(&mut self, rec: &mut Rec, tile_row: usize, tile_col: usize) -> Res<()> {
        let f = self.f;
        let st = &mut *self.st;
        st.mi_row_start = f.tiles.mi_row_starts[tile_row] as i32;
        st.mi_row_end = f.tiles.mi_row_starts[tile_row + 1] as i32;
        st.mi_col_start = f.tiles.mi_col_starts[tile_col] as i32;
        st.mi_col_end = f.tiles.mi_col_starts[tile_col + 1] as i32;
        match f.cdfs_in {
            Some(c) => {
                st.cdf.clone_from(&c.cdf);
                (*st.icdf).clone_from(&c.icdf);
            }
            None => {
                st.cdf.init(f.fp.base_q_idx as i32);
                st.icdf.init();
            }
        }
        st.current_q_index = f.fp.base_q_idx as i32;
        st.block_q = -1;
        st.set_block_q(&f.fp, f.fp.base_q_idx as i32);
        for p in 0..3 {
            st.above_level[p].fill(0);
            st.above_dc[p].fill(0);
        }
        let (r0, r1, c0, c1) = (st.mi_row_start, st.mi_row_end, st.mi_col_start, st.mi_col_end);
        let sb4 = f.sb_size4();
        let sb_bsize = if f.sb128 { BLOCK_128X128 } else { BLOCK_64X64 };
        for r in (r0..r1).step_by(sb4 as usize) {
            for p in 0..3 {
                self.st.left_level[p].fill(0);
                self.st.left_dc[p].fill(0);
            }
            for c in (c0..c1).step_by(sb4 as usize) {
                self.st.read_deltas = f.fp.delta_q_present != 0;
                // clear_cdef: the superblock's 64x64s
                for y in (r..r + sb4).step_by(16) {
                    for x in (c..c + sb4).step_by(16) {
                        if let Some(k) = self.bufs.cdef_at(y, x) {
                            self.bufs.sb_cdef[k] = -1;
                        }
                    }
                }
                self.clear_block_decoded(r, c);
                self.partition(rec, r, c, sb_bsize)?;
            }
        }
        // the frame-end CDF update: the context tile's CDFs, counters cleared
        if let Some(out) = f.cdfs_out
            && tile_row * f.tiles.cols as usize + tile_col == f.context_tile
        {
            let mut g = out.lock().unwrap();
            g.1.cdf.clone_from(&self.st.cdf);
            g.1.icdf.clone_from(&self.st.icdf);
            g.1.clear_counters();
            g.0 = true;
        }
        Ok(())
    }

    fn clear_block_decoded(&mut self, r: i32, c: i32) {
        let sb4 = self.f.sb_size4();
        let st = &mut *self.st;
        for p in 0..self.f.planes() {
            let sub = (p != 0) as i32;
            let sb_width4 = (st.mi_col_end - c) >> sub;
            let sb_height4 = (st.mi_row_end - r) >> sub;
            for y in -1..=(sb4 >> sub) {
                for x in -1..=(sb4 >> sub) {
                    let v = (y < 0 && x < sb_width4) || (x < 0 && y < sb_height4);
                    st.block_decoded[p][(y + 1) as usize][(x + 1) as usize] = v as u8;
                }
            }
            st.block_decoded[p][((sb4 >> sub) + 1) as usize][0] = 0;
        }
    }

    /// The partition type of node (r, c, b_size) implied by the block sequence (write mode).
    fn derive_partition(&self, rec: &Rec, r: i32, c: i32, b_size: i32, has_rows: bool, has_cols: bool) -> Res<i32> {
        let Rec::Write { blocks, .. } = rec else { unreachable!() };
        let st = &*self.st;
        let cursor = st.cursor;
        if cursor >= st.tile_end {
            fail!(
                ERR_INVALID,
                "block list ends inside tile (expected block at mi {r},{c})"
            );
        }
        let b = &blocks[cursor as usize];
        if b.mi_row as i32 != r || b.mi_col as i32 != c {
            fail!(
                ERR_INVALID,
                "block {cursor} at mi ({},{}), expected a block starting at ({r},{c})",
                b.mi_row,
                b.mi_col
            );
        }
        let half = bw4(b_size) >> 1;
        let sub = |p: i32| Partition_Subsize[p as usize][b_size as usize] as i32;
        let (hz, vt, sp, h4, v4) = (
            sub(PARTITION_HORZ),
            sub(PARTITION_VERT),
            sub(PARTITION_SPLIT),
            sub(PARTITION_HORZ_4),
            sub(PARTITION_VERT_4),
        );
        let nxt = |k: u32| (cursor + k < st.tile_end).then(|| &blocks[(cursor + k) as usize]);
        let at = |n: Option<&Block>, rr: i32, cc: i32, bs: i32| {
            n.is_some_and(|n| n.mi_row as i32 == rr && n.mi_col as i32 == cc && n.bsize as i32 == bs)
        };
        let bs = b.bsize as i32;
        let p = if bs == b_size {
            PARTITION_NONE
        } else if bs == hz {
            if at(nxt(1), r + half, c, sp) {
                PARTITION_HORZ_B
            } else {
                PARTITION_HORZ
            }
        } else if bs == vt {
            if at(nxt(1), r, c + half, sp) {
                PARTITION_VERT_B
            } else {
                PARTITION_VERT
            }
        } else if bs == sp && b_size > BLOCK_8X8 && has_rows && has_cols && at(nxt(1), r + half, c, sp) {
            PARTITION_VERT_A
        } else if bs == sp
            && b_size > BLOCK_8X8
            && has_rows
            && has_cols
            && at(nxt(1), r, c + half, sp)
            && at(nxt(2), r + half, c, hz)
        {
            PARTITION_HORZ_A
        } else if b_size > BLOCK_8X8 && bs == h4 {
            PARTITION_HORZ_4
        } else if b_size > BLOCK_8X8 && bs == v4 {
            PARTITION_VERT_4
        } else {
            PARTITION_SPLIT
        };
        let ok = if (b_size == BLOCK_8X8 && p > PARTITION_SPLIT) || (b_size == BLOCK_128X128 && p > PARTITION_VERT_B) {
            false
        } else if has_rows && has_cols {
            true
        } else if has_cols {
            p == PARTITION_HORZ || p == PARTITION_SPLIT
        } else if has_rows {
            p == PARTITION_VERT || p == PARTITION_SPLIT
        } else {
            p == PARTITION_SPLIT
        };
        if !ok {
            fail!(
                ERR_INVALID,
                "block {cursor}: implied partition {p} of {}x{} node at mi ({r},{c}) not allowed here",
                4 * bw4(b_size),
                4 * bh4(b_size)
            );
        }
        Ok(p)
    }

    /// decode_partition
    fn partition(&mut self, rec: &mut Rec, r: i32, c: i32, b_size: i32) -> Res<()> {
        let f = self.f;
        if r >= f.mi_rows || c >= f.mi_cols {
            return Ok(());
        }
        let a_u = self.st.is_inside(r - 1, c);
        let a_l = self.st.is_inside(r, c - 1);
        let num4x4 = bw4(b_size);
        let (half, quarter) = (num4x4 >> 1, num4x4 >> 2);
        let has_rows = (r + half) < f.mi_rows;
        let has_cols = (c + half) < f.mi_cols;
        let p = if b_size < BLOCK_8X8 {
            PARTITION_NONE
        } else {
            let p_w = if S::WRITE {
                self.derive_partition(rec, r, c, b_size, has_rows, has_cols)?
            } else {
                0
            };
            let bsl = t8(&Mi_Width_Log2, b_size);
            let above = a_u && t8(&Mi_Width_Log2, self.bufs.mi_size[self.bufs.mi(r - 1, c)] as i32) < bsl;
            let left = a_l && t8(&Mi_Height_Log2, self.bufs.mi_size[self.bufs.mi(r, c - 1)] as i32) < bsl;
            let ctx = left as usize * 2 + above as usize;
            let cdf = &mut self.st.cdf;
            if bsl == 1 {
                if !(has_rows && has_cols) {
                    fail!(
                        ERR_INTERNAL,
                        "8x8 partition node at mi ({r},{c}) without rows or columns"
                    );
                }
                self.sk.sym(&mut cdf.partition_w8[ctx], p_w)
            } else if bsl == 5 {
                // the 128x128 node: no 4-way splits
                let pc = &mut self.st.icdf.partition_w128[ctx];
                if has_rows && has_cols {
                    self.sk.sym(pc, p_w)
                } else if has_cols {
                    if self.sk.split_or(pc, false, (p_w == PARTITION_SPLIT) as i32) != 0 {
                        PARTITION_SPLIT
                    } else {
                        PARTITION_HORZ
                    }
                } else if has_rows {
                    if self.sk.split_or(pc, true, (p_w == PARTITION_SPLIT) as i32) != 0 {
                        PARTITION_SPLIT
                    } else {
                        PARTITION_VERT
                    }
                } else {
                    PARTITION_SPLIT
                }
            } else {
                let pc = match bsl {
                    2 => &mut cdf.partition_w16[ctx],
                    3 => &mut cdf.partition_w32[ctx],
                    _ => &mut cdf.partition_w64[ctx],
                };
                if has_rows && has_cols {
                    self.sk.sym(pc, p_w)
                } else if has_cols {
                    if self.sk.split_or(pc, false, (p_w == PARTITION_SPLIT) as i32) != 0 {
                        PARTITION_SPLIT
                    } else {
                        PARTITION_HORZ
                    }
                } else if has_rows {
                    if self.sk.split_or(pc, true, (p_w == PARTITION_SPLIT) as i32) != 0 {
                        PARTITION_SPLIT
                    } else {
                        PARTITION_VERT
                    }
                } else {
                    PARTITION_SPLIT
                }
            }
        };
        if S::WRITE && b_size == BLOCK_128X128 {
            sb128_stat(p as usize);
        }
        let sub_size = Partition_Subsize[p as usize][b_size as usize] as i32;
        let split_size = Partition_Subsize[PARTITION_SPLIT as usize][b_size as usize] as i32;
        match p {
            PARTITION_NONE => self.block(rec, r, c, sub_size)?,
            PARTITION_HORZ => {
                self.block(rec, r, c, sub_size)?;
                if has_rows {
                    self.block(rec, r + half, c, sub_size)?;
                }
            }
            PARTITION_VERT => {
                self.block(rec, r, c, sub_size)?;
                if has_cols {
                    self.block(rec, r, c + half, sub_size)?;
                }
            }
            PARTITION_SPLIT => {
                self.partition(rec, r, c, sub_size)?;
                self.partition(rec, r, c + half, sub_size)?;
                self.partition(rec, r + half, c, sub_size)?;
                self.partition(rec, r + half, c + half, sub_size)?;
            }
            PARTITION_HORZ_A => {
                self.block(rec, r, c, split_size)?;
                self.block(rec, r, c + half, split_size)?;
                self.block(rec, r + half, c, sub_size)?;
            }
            PARTITION_HORZ_B => {
                self.block(rec, r, c, sub_size)?;
                self.block(rec, r + half, c, split_size)?;
                self.block(rec, r + half, c + half, split_size)?;
            }
            PARTITION_VERT_A => {
                self.block(rec, r, c, split_size)?;
                self.block(rec, r + half, c, split_size)?;
                self.block(rec, r, c + half, sub_size)?;
            }
            PARTITION_VERT_B => {
                self.block(rec, r, c, sub_size)?;
                self.block(rec, r, c + half, split_size)?;
                self.block(rec, r + half, c + half, split_size)?;
            }
            PARTITION_HORZ_4 => {
                for i in 0..4 {
                    if i < 3 || r + quarter * 3 < f.mi_rows {
                        self.block(rec, r + quarter * i, c, sub_size)?;
                    }
                }
            }
            _ => {
                for i in 0..4 {
                    if i < 3 || c + quarter * 3 < f.mi_cols {
                        self.block(rec, r, c + quarter * i, sub_size)?;
                    }
                }
            }
        }
        Ok(())
    }

    /// The intra mode info of a block: intra_frame_mode_info's modes (key frames: y mode CDFs by
    /// the neighbours' modes) or intra_block_mode_info (inter frames: by size group), then the
    /// angles, the chroma mode and CfL, palette_mode_info (never a palette) and
    /// filter_intra_mode_info.
    #[inline(always)]
    fn intra_mode_info(&mut self, b: &mut Block, r: i32, c: i32, bsize: i32) -> Res<()> {
        let f = self.f;
        let fp = &f.fp;
        let st = &mut *self.st;
        let (avail_u, avail_l, has_chroma_) = (st.avail_u, st.avail_l, st.has_chroma);
        let (bw, bh) = (st.bw4, st.bh4);
        let bufs = &*self.bufs;
        let cdf = &mut st.cdf;
        if f.inter {
            let ctx = Size_Group[bsize as usize] as usize;
            b.y_mode = self.sk.sym(&mut st.icdf.y_mode[ctx], b.y_mode as i32) as u8;
        } else {
            let am = t8(
                &Intra_Mode_Context,
                if avail_u {
                    bufs.y_mode[bufs.mi(r - 1, c)] as i32
                } else {
                    DC_PRED
                },
            );
            let lm = t8(
                &Intra_Mode_Context,
                if avail_l {
                    bufs.y_mode[bufs.mi(r, c - 1)] as i32
                } else {
                    DC_PRED
                },
            );
            b.y_mode = self.sk.sym(&mut cdf.y_mode[am as usize][lm as usize], b.y_mode as i32) as u8;
        }
        if bsize >= BLOCK_8X8 && is_directional(b.y_mode as i32) {
            let s = self.sk.sym(
                &mut cdf.angle_delta[(b.y_mode as i32 - V_PRED) as usize],
                b.angle_delta_y as i32 + MAX_ANGLE_DELTA,
            );
            b.angle_delta_y = (s - MAX_ANGLE_DELTA) as i8;
        }
        if has_chroma_ {
            b.uv_mode = if cfl_allowed(bsize) {
                self.sk
                    .sym(&mut cdf.uv_mode_cfl_allowed[b.y_mode as usize], b.uv_mode as i32)
            } else {
                self.sk
                    .sym(&mut cdf.uv_mode_cfl_not_allowed[b.y_mode as usize], b.uv_mode as i32)
            } as u8;
            if b.uv_mode as i32 == UV_CFL_PRED {
                let sgn = |a: i8| {
                    if a == 0 {
                        CFL_SIGN_ZERO
                    } else if a < 0 {
                        CFL_SIGN_NEG
                    } else {
                        CFL_SIGN_POS
                    }
                };
                let (w_u, w_v) = (sgn(b.cfl_alpha_u), sgn(b.cfl_alpha_v));
                let js = self.sk.sym(&mut cdf.cfl_sign, w_u * 3 + w_v - 1);
                let (sign_u, sign_v) = ((js + 1) / 3, (js + 1) % 3);
                b.cfl_alpha_u = if sign_u != CFL_SIGN_ZERO {
                    let ctx = ((sign_u - 1) * 3 + sign_v) as usize;
                    let a = self
                        .sk
                        .sym(&mut cdf.cfl_alpha[ctx], b.cfl_alpha_u.unsigned_abs() as i32 - 1)
                        + 1;
                    (if sign_u == CFL_SIGN_NEG { -a } else { a }) as i8
                } else {
                    0
                };
                b.cfl_alpha_v = if sign_v != CFL_SIGN_ZERO {
                    let ctx = ((sign_v - 1) * 3 + sign_u) as usize;
                    let a = self
                        .sk
                        .sym(&mut cdf.cfl_alpha[ctx], b.cfl_alpha_v.unsigned_abs() as i32 - 1)
                        + 1;
                    (if sign_v == CFL_SIGN_NEG { -a } else { a }) as i8
                } else {
                    0
                };
            }
            if bsize >= BLOCK_8X8 && is_directional(b.uv_mode as i32) {
                let s = self.sk.sym(
                    &mut cdf.angle_delta[(b.uv_mode as i32 - V_PRED) as usize],
                    b.angle_delta_uv as i32 + MAX_ANGLE_DELTA,
                );
                b.angle_delta_uv = (s - MAX_ANGLE_DELTA) as i8;
            }
        }
        // palette_mode_info()
        if fp.allow_screen_content_tools != 0 && bsize >= BLOCK_8X8 && bw <= 16 && bh <= 16 {
            self.palette_mode_info(b, bsize)?;
        }
        let cdf = &mut self.st.cdf;
        // filter_intra_mode_info()
        if fp.enable_filter_intra != 0 && b.y_mode as i32 == DC_PRED && self.st.pal.size_y == 0 && bw <= 8 && bh <= 8 {
            b.filter_intra = if self
                .sk
                .sym(&mut cdf.filter_intra[bsize as usize], (b.filter_intra != 0) as i32)
                != 0
            {
                (self.sk.sym(&mut cdf.filter_intra_mode, b.filter_intra as i32 - 1) + 1) as u8
            } else {
                0
            };
        } else if !S::WRITE {
            b.filter_intra = 0;
        }
        Ok(())
    }

    /// The tile's mode info as the MV stack reads it.
    fn mv_maps(&self) -> MvMaps<'_> {
        let (bufs, st) = (&*self.bufs, &*self.st);
        MvMaps {
            ref0: &bufs.ref0,
            mvs: &bufs.mvs,
            y_mode: &bufs.y_mode,
            mi_size: &bufs.mi_size,
            r0: bufs.r0,
            c0: bufs.c0,
            mw: bufs.mw,
            row_start: st.mi_row_start,
            row_end: st.mi_row_end,
            col_start: st.mi_col_start,
            col_end: st.mi_col_end,
            mi_rows: self.f.mi_rows,
            mi_cols: self.f.mi_cols,
            mv_precision: self.f.fp.mv_precision,
        }
    }

    /// inter_block_mode_info for the writer's toolset: read_ref_frames (LAST_FRAME), the MV stack,
    /// the mode (derived from the MV when writing), the drl index, assign_mv. Returns the YMode.
    #[inline(never)]
    fn inter_block_mode_info(&mut self, r: i32, c: i32, bsize: i32, bi: &mut BlockInter) -> Res<i32> {
        let b_idx = self.st.b_idx;
        // read_ref_frames: single_ref_p1 = p3 = p4 = 0. With only LAST_FRAME and intra neighbours
        // every count but LAST_FRAME's is 0, so the three contexts are ref_count_ctx(last, 0).
        let last_count = {
            let (bufs, st) = (&*self.bufs, &*self.st);
            let last = |k: usize| (bufs.ref0[k] as i32 == LAST_FRAME) as i32;
            (if st.avail_u { last(bufs.mi(r - 1, c)) } else { 0 })
                + if st.avail_l { last(bufs.mi(r, c - 1)) } else { 0 }
        };
        let rctx = if last_count == 0 { 1 } else { 2 };
        for p in [0, 2, 3] {
            if self.sk.sym(&mut self.st.icdf.single_ref[rctx][p], 0) != 0 {
                fail!(
                    ERR_INVALID,
                    "block {b_idx}: reference frames other than LAST_FRAME are not supported"
                );
            }
        }
        let s: MvStack = find_mv_stack(&self.mv_maps(), r, c, bsize);
        let mv_w = [bi.mv_row as i32, bi.mv_col as i32];
        let (mode_w, idx_w) = if S::WRITE {
            match derive_mode(&s, mv_w) {
                Some(m) => m,
                None => fail!(
                    ERR_INVALID,
                    "block {b_idx}: mv ({},{}) is too far from every candidate to code (NEWMV difference > 2^14)",
                    mv_w[0],
                    mv_w[1]
                ),
            }
        } else {
            (0, 0)
        };
        let ic = &mut self.st.icdf;
        let mode = if self.sk.sym(&mut ic.new_mv[s.new_mv_ctx], (mode_w != NEWMV) as i32) == 0 {
            NEWMV
        } else if self.sk.sym(&mut ic.zero_mv[0], (mode_w != GLOBALMV) as i32) == 0 {
            GLOBALMV // ZeroMvContext is 0 without reference-frame MVs
        } else if self.sk.sym(&mut ic.ref_mv[s.ref_mv_ctx], (mode_w == NEARMV) as i32) == 0 {
            NEARESTMV
        } else {
            NEARMV
        };
        let mut ref_mv_idx = 0;
        let first = if mode == NEWMV {
            Some(0)
        } else if mode == NEARMV {
            ref_mv_idx = 1;
            Some(1)
        } else {
            None
        };
        if let Some(first) = first {
            for idx in first..first + 2 {
                if s.num > idx + 1 {
                    if self.sk.sym(&mut ic.drl_mode[s.drl_ctx[idx]], (idx_w > idx) as i32) == 0 {
                        ref_mv_idx = idx;
                        break;
                    }
                    ref_mv_idx = idx + 1;
                }
            }
        }
        if S::WRITE && (mode, ref_mv_idx) != (mode_w, if mode_w == NEARESTMV { 0 } else { idx_w }) {
            fail!(
                ERR_INTERNAL,
                "block {b_idx}: inter mode {mode_w}/{idx_w} coded as {mode}/{ref_mv_idx}"
            );
        }
        // assign_mv
        let mv = match mode {
            GLOBALMV => [0, 0],
            NEARESTMV => s.mv[0],
            NEARMV => s.mv[ref_mv_idx],
            _ => {
                let pred = s.mv[if s.num <= 1 { 0 } else { ref_mv_idx }];
                let dw = [mv_w[0] - pred[0], mv_w[1] - pred[1]];
                // read_mv: mv_joint, then the nonzero components
                let joint = self.sk.sym(
                    &mut self.st.icdf.mv_joint,
                    ((dw[0] != 0) as i32) * 2 + (dw[1] != 0) as i32,
                );
                let dr = if joint == 2 || joint == 3 {
                    self.mv_component(0, dw[0])
                } else {
                    0
                };
                let dc = if joint == 1 || joint == 3 {
                    self.mv_component(1, dw[1])
                } else {
                    0
                };
                [pred[0] + dr, pred[1] + dc]
            }
        };
        if !S::WRITE && (mv[0].abs() >= 1 << 14 || mv[1].abs() >= 1 << 14) {
            fail!(ERR_INVALID, "block {b_idx}: invalid mv ({},{})", mv[0], mv[1]);
        }
        if S::WRITE && mv != mv_w {
            fail!(
                ERR_INTERNAL,
                "block {b_idx}: mv ({},{}) coded as ({},{})",
                mv_w[0],
                mv_w[1],
                mv[0],
                mv[1]
            );
        }
        (bi.mv_row, bi.mv_col) = (mv[0] as i16, mv[1] as i16);
        if S::WRITE {
            inter_stat(match mode {
                GLOBALMV => 0,
                NEARESTMV => 1,
                NEARMV => 2,
                _ => 3,
            });
            if (mode == NEARMV && ref_mv_idx > 1) || (mode == NEWMV && ref_mv_idx > 0) {
                inter_stat(4 + (mode == NEWMV) as usize);
            }
        }
        Ok(mode)
    }

    /// read_mv_component (MvCtx 0) of the difference `v` (1/8 sample, nonzero, |v| <= 2^14, of
    /// the frame's precision): mv_class0_fr / mv_fr are 3 with force_integer_mv (fp.mv_precision
    /// 0), mv_class0_hp / mv_hp 1 without allow_high_precision_mv (fp.mv_precision 0, 1).
    fn mv_component(&mut self, comp: usize, v: i32) -> i32 {
        let prec = self.f.fp.mv_precision;
        let ic = &mut self.st.icdf;
        let sign = self.sk.sym(&mut ic.mv_sign[comp], (v < 0) as i32);
        let a = v.unsigned_abs().max(1);
        let cls = self.sk.sym(&mut ic.mv_class[comp], mv_class(a) as i32);
        // the class's first magnitude - 1, and the written magnitude's offset in the class:
        // d << 3 | fr << 1 | hp
        let base = if cls == 0 { 0 } else { CLASS0_SIZE << (cls + 2) };
        let off_w = a as i32 - 1 - base;
        let (d, fr_cdf, hp_cdf) = if cls == 0 {
            let bit = self.sk.sym(&mut ic.mv_class0_bit[comp], (off_w >> 3) & 1);
            (
                bit,
                &mut ic.mv_class0_fr[comp][bit as usize],
                &mut ic.mv_class0_hp[comp],
            )
        } else {
            let mut d = 0;
            for i in 0..cls as usize {
                d |= self.sk.sym(&mut ic.mv_bit[comp][i], (off_w >> (3 + i)) & 1) << i;
            }
            (d, &mut ic.mv_fr[comp], &mut ic.mv_hp[comp])
        };
        let fr = if prec == 0 {
            3
        } else {
            self.sk.sym(fr_cdf, (off_w >> 1) & 3)
        };
        let hp = if prec == 2 { self.sk.sym(hp_cdf, off_w & 1) } else { 1 };
        if S::WRITE && prec != 0 {
            inter_stat(9 + (prec == 2) as usize);
        }
        let mag = base + ((d << 3) | (fr << 1) | hp) + 1;
        if sign != 0 { -mag } else { mag }
    }

    /// read_var_tx_size: the txfm_split tree of an inter block (write: split down to `want`
    /// levels everywhere). Leaves set InterTxSizes (the tile's tx_size map); `leaf` gets their
    /// depth, which must be the same for all (the record has one tx_depth per block).
    #[inline(never)]
    fn var_tx(&mut self, row: i32, col: i32, tx_sz: i32, depth: i32, want: i32, leaf: &mut i32) -> Res<()> {
        let f = self.f;
        if row >= f.mi_rows || col >= f.mi_cols {
            return Ok(());
        }
        let (tw, th) = (t8(&Tx_Width, tx_sz), t8(&Tx_Height, tx_sz));
        let split = if tx_sz == TX_4X4 || depth == 2 {
            false
        } else {
            let (bufs, st) = (&*self.bufs, &*self.st);
            // get_above_tx_width / get_left_tx_height
            let above_w = if row == st.mi_row && !st.avail_u {
                64
            } else {
                let k = bufs.mi(row - 1, col);
                if row == st.mi_row && bufs.skip[k] != 0 && bufs.ref0[k] as i32 == LAST_FRAME {
                    4 * bw4(bufs.mi_size[k] as i32)
                } else {
                    t8(&Tx_Width, bufs.tx_size[k] as i32)
                }
            };
            let left_h = if col == st.mi_col && !st.avail_l {
                64
            } else {
                let k = bufs.mi(row, col - 1);
                if col == st.mi_col && bufs.skip[k] != 0 && bufs.ref0[k] as i32 == LAST_FRAME {
                    4 * bh4(bufs.mi_size[k] as i32)
                } else {
                    t8(&Tx_Height, bufs.tx_size[k] as i32)
                }
            };
            let size = (4 * st.bw4.max(st.bh4)).min(64);
            let max_tx_sz = size.trailing_zeros() as i32 - 2; // find_tx_size(size, size): TX_4X4 .. TX_64X64
            let ctx = (t8(&Tx_Size_Sqr_Up, tx_sz) != max_tx_sz) as usize * 3
                + (TX_SIZES - 1 - max_tx_sz) as usize * 6
                + (above_w < tw) as usize
                + (left_h < th) as usize;
            self.sk.sym(&mut self.st.icdf.txfm_split[ctx], (depth < want) as i32) != 0
        };
        if split {
            let sub = t8(&Split_Tx_Size, tx_sz);
            let (sw, sh) = (t8(&Tx_Width, sub) >> 2, t8(&Tx_Height, sub) >> 2);
            for i in (0..th >> 2).step_by(sh as usize) {
                for j in (0..tw >> 2).step_by(sw as usize) {
                    self.var_tx(row + i, col + j, sub, depth + 1, want, leaf)?;
                }
            }
            return Ok(());
        }
        if *leaf < 0 {
            *leaf = depth;
        } else if *leaf != depth {
            fail!(
                ERR_INVALID,
                "block {}: transform split depths differ within the block (not supported)",
                self.st.b_idx
            );
        }
        let bufs = &mut *self.bufs;
        let (r_end, c_end) = ((row + (th >> 2)).min(f.mi_rows), (col + (tw >> 2)).min(f.mi_cols));
        for y in row..r_end {
            let k = bufs.mi(y, col);
            fill_small(&mut bufs.tx_size[k..k + (c_end - col) as usize], tx_sz as u8);
        }
        Ok(())
    }

    /// compute_prediction of an inter block (spec 5.11.33 / 7.11.3): its planes from LAST_FRAME,
    /// the whole block (past the coded area too: the closed loop transforms whole tx blocks). The
    /// chroma of a block narrower or lower than 8 luma samples is predicted from the motion of each
    /// block of its 8x8 unit, unless one of them is intra.
    #[inline(never)]
    fn predict_inter_block(&mut self, bsize: i32, has_chroma: bool) {
        let Some(refs) = self.f.refs.as_ref() else { return };
        let (st, bufs) = (&mut *self.st, &mut *self.bufs);
        let maps = InterMaps {
            ref0: &bufs.ref0,
            mvs: &bufs.mvs,
            r0: bufs.r0,
            c0: bufs.c0,
            mw: bufs.mw,
            stride: bufs.stride,
        };
        let [a, b, c] = &mut bufs.plane;
        let mut planes: [&mut [u8]; 3] = [a, b, c];
        predict_inter_block(
            self.f,
            refs,
            &maps,
            &mut planes,
            st.mi_row,
            st.mi_col,
            bsize,
            has_chroma,
            &mut st.mc,
        );
    }

    /// check_block_fields for a block with an inter entry (kept out of the intra path).
    #[inline(never)]
    fn check_inter_fields(&self, b: &Block, bi: &BlockInter) -> Res<()> {
        let b_idx = self.st.b_idx;
        if bi.is_inter > 1 || bi.reserved != [0; 3] {
            fail!(
                ERR_INVALID,
                "block {b_idx}: inter entry: is_inter must be 0/1, reserved 0"
            );
        }
        if bi.is_inter != 0 {
            if !self.f.inter {
                fail!(ERR_INVALID, "block {b_idx}: inter block outside an inter frame");
            }
            let (mr, mc) = (bi.mv_row as i32, bi.mv_col as i32);
            // fp.mv_precision: whole samples (multiples of 8), quarter (even), eighth (any)
            let (mask, what) = match self.f.fp.mv_precision {
                0 => (7, "whole samples: multiples of 8"),
                1 => (1, "quarter samples: even"),
                _ => (0, "eighth samples"),
            };
            if (mr | mc) & mask != 0 || mr.abs() >= 1 << 14 || mc.abs() >= 1 << 14 {
                fail!(
                    ERR_INVALID,
                    "block {b_idx}: mv ({mr},{mc}) must be below 2^14 and of the frame's precision ({what})"
                );
            }
            if b.y_mode != 0
                || b.angle_delta_y != 0
                || b.uv_mode != 0
                || b.angle_delta_uv != 0
                || b.cfl_alpha_u != 0
                || b.cfl_alpha_v != 0
                || b.filter_intra != 0
            {
                fail!(
                    ERR_INVALID,
                    "block {b_idx}: an inter block's intra mode fields must be 0"
                );
            }
            if b.skip != 0 && b.tx_depth != 0 {
                fail!(ERR_INVALID, "block {b_idx}: a skip inter block has no tx_depth (0)");
            }
        } else if bi.mv_row != 0 || bi.mv_col != 0 {
            fail!(ERR_INVALID, "block {b_idx}: an intra block's mv must be 0");
        }
        Ok(())
    }

    /// A block's palettes (write mode): where palette_mode_info codes them, their sizes, colour
    /// order and maps inside the record.
    #[inline(never)]
    fn check_palette(&self, rec: &Rec, b: &Block, bi: &BlockInter) -> Res<()> {
        let (f, st) = (self.f, &*self.st);
        let (p, b_idx) = (&st.pal, st.b_idx);
        let bs = b.bsize as i32;
        if f.fp.allow_screen_content_tools == 0 || bi.is_inter != 0 || bs < BLOCK_8X8 || bw4(bs) > 16 || bh4(bs) > 16 {
            fail!(
                ERR_INVALID,
                "block {b_idx}: a palette needs allow_screen_content_tools and an intra block of 8x8 to 64x64"
            );
        }
        let ok_size = |n: u8| n == 0 || (2..=8).contains(&n);
        if !ok_size(p.size_y) || !ok_size(p.size_uv) {
            fail!(ERR_INVALID, "block {b_idx}: palette sizes {} {}", p.size_y, p.size_uv);
        }
        let mut len = 0;
        if p.size_y != 0 {
            let c = &p.colors[0][..p.size_y as usize];
            if b.y_mode as i32 != DC_PRED || b.filter_intra != 0 || c.windows(2).any(|w| w[0] >= w[1]) {
                fail!(
                    ERR_INVALID,
                    "block {b_idx}: a luma palette needs y_mode DC_PRED, no filter intra and increasing colours"
                );
            }
            let d = map_dims(bs, st.mi_row, st.mi_col, f.mi_rows, f.mi_cols, false);
            len += d.w * d.h;
        }
        if p.size_uv != 0 {
            let c = &p.colors[1][..p.size_uv as usize];
            if !st.has_chroma || b.uv_mode as i32 != DC_PRED || c.windows(2).any(|w| w[0] > w[1]) {
                fail!(
                    ERR_INVALID,
                    "block {b_idx}: a chroma palette needs chroma, uv_mode DC_PRED and non-decreasing U colours"
                );
            }
            let d = map_dims(bs, st.mi_row, st.mi_col, f.mi_rows, f.mi_cols, true);
            len += d.w * d.h;
        }
        let Rec::Write { palette_map, .. } = rec else {
            unreachable!()
        };
        if p.map_off as usize + len > palette_map.len() {
            fail!(ERR_INVALID, "block {b_idx}: colour index maps outside the record");
        }
        Ok(())
    }

    fn check_block_fields(&self, b: &Block, bi: &BlockInter) -> Res<()> {
        let fp = &self.f.fp;
        let (st, b_idx) = (&*self.st, self.st.b_idx);
        let bs = b.bsize as i32;
        if bs >= BLOCK_SIZES || (!self.f.sb128 && (bs == BLOCK_64X128 || bs == BLOCK_128X64 || bs == BLOCK_128X128)) {
            fail!(
                ERR_INVALID,
                "block {b_idx}: invalid bsize {bs} (128-sample blocks need fp.sb128)"
            );
        }
        if b.skip > 1 {
            fail!(ERR_INVALID, "block {b_idx}: skip must be 0/1");
        }
        if *bi != BlockInter::default() {
            self.check_inter_fields(b, bi)?;
        }
        if b.y_mode as i32 > PAETH_PRED {
            fail!(ERR_INVALID, "block {b_idx}: y_mode {}", b.y_mode);
        }
        let dir_ok = bs >= BLOCK_8X8;
        if b.angle_delta_y < -3
            || b.angle_delta_y > 3
            || (b.angle_delta_y != 0 && !(dir_ok && is_directional(b.y_mode as i32)))
        {
            fail!(
                ERR_INVALID,
                "block {b_idx}: angle_delta_y {} not allowed",
                b.angle_delta_y
            );
        }
        if fp.tx_mode_select != 0 {
            if b.tx_depth as i32 > max_tx_depth(bs) || (bs == BLOCK_4X4 && b.tx_depth != 0) {
                fail!(ERR_INVALID, "block {b_idx}: tx_depth {} too large", b.tx_depth);
            }
        } else if b.tx_depth != 0 {
            fail!(ERR_INVALID, "block {b_idx}: tx_depth must be 0 (TX_MODE_LARGEST)");
        }
        let cdef_bad = if fp.enable_cdef != 0 {
            b.cdef_idx < 0 || b.cdef_idx as i32 >= (1 << fp.cdef_bits)
        } else {
            b.cdef_idx != 0
        };
        if cdef_bad {
            fail!(ERR_INVALID, "block {b_idx}: cdef_idx {} out of range", b.cdef_idx);
        }
        if b.filter_intra != 0
            && (b.filter_intra > 5
                || fp.enable_filter_intra == 0
                || b.y_mode as i32 != DC_PRED
                || bw4(bs) > 8
                || bh4(bs) > 8)
        {
            fail!(
                ERR_INVALID,
                "block {b_idx}: filter_intra {} not allowed here",
                b.filter_intra
            );
        }
        if fp.delta_q_present == 0 && b.sb_qindex != 0 && b.sb_qindex != fp.base_q_idx {
            fail!(ERR_INVALID, "block {b_idx}: sb_qindex set but delta_q_present = 0");
        }
        if st.has_chroma {
            if b.uv_mode as i32 > UV_CFL_PRED {
                fail!(ERR_INVALID, "block {b_idx}: uv_mode {}", b.uv_mode);
            }
            if b.uv_mode as i32 == UV_CFL_PRED {
                if !cfl_allowed(bs) {
                    fail!(ERR_INVALID, "block {b_idx}: CFL not allowed for bsize {bs}");
                }
                if b.cfl_alpha_u < -16
                    || b.cfl_alpha_u > 16
                    || b.cfl_alpha_v < -16
                    || b.cfl_alpha_v > 16
                    || (b.cfl_alpha_u == 0 && b.cfl_alpha_v == 0)
                {
                    fail!(
                        ERR_INVALID,
                        "block {b_idx}: bad CFL alphas {} {}",
                        b.cfl_alpha_u,
                        b.cfl_alpha_v
                    );
                }
            }
            if b.angle_delta_uv < -3
                || b.angle_delta_uv > 3
                || (b.angle_delta_uv != 0 && !(dir_ok && is_directional(b.uv_mode as i32)))
            {
                fail!(
                    ERR_INVALID,
                    "block {b_idx}: angle_delta_uv {} not allowed",
                    b.angle_delta_uv
                );
            }
        }
        Ok(())
    }

    /// decode_block (intra_frame_mode_info / inter_frame_mode_info, the prediction of inter
    /// blocks, the residual)
    fn block(&mut self, rec: &mut Rec, r: i32, c: i32, bsize: i32) -> Res<()> {
        let f = self.f;
        let fp = &f.fp;
        let mut b;
        let mut bi = BlockInter::default();
        let mut parse_txb0 = 0u32;
        match rec {
            Rec::Write {
                blocks, inter, palette, ..
            } => {
                let st = &mut *self.st;
                if st.cursor >= st.tile_end {
                    fail!(ERR_INVALID, "block list ends early (expected block at mi {r},{c})");
                }
                st.b_idx = st.cursor;
                b = blocks[st.cursor as usize];
                if let Some(x) = inter.get(st.cursor as usize) {
                    bi = *x;
                }
                st.pal = palette.get(st.cursor as usize).copied().unwrap_or_default();
                if b.mi_row as i32 != r || b.mi_col as i32 != c || b.bsize as i32 != bsize {
                    fail!(
                        ERR_INVALID,
                        "block {}: got mi ({},{}) bsize {}, partition syntax expects ({r},{c}) bsize {bsize}",
                        st.cursor,
                        b.mi_row,
                        b.mi_col,
                        b.bsize
                    );
                }
                st.cursor += 1;
            }
            Rec::Parse(p) => {
                b = Block {
                    mi_row: r as u16,
                    mi_col: c as u16,
                    bsize: bsize as u8,
                    ..Default::default()
                };
                self.st.pal = BlockPalette::default();
                self.st.b_idx = p.blocks.len() as u32;
                parse_txb0 = p.txb.len() as u32;
            }
        }
        let st = &mut *self.st;
        st.mi_row = r;
        st.mi_col = c;
        st.mi_size = bsize;
        st.bw4 = bw4(bsize);
        st.bh4 = bh4(bsize);
        st.has_chroma = has_chroma(bsize, r, c, f.mono);
        st.avail_u = st.is_inside(r - 1, c);
        st.avail_l = st.is_inside(r, c - 1);
        st.avail_uc = st.avail_u;
        st.avail_lc = st.avail_l;
        if st.has_chroma {
            if st.bh4 == 1 {
                st.avail_uc = st.is_inside(r - 2, c);
            }
            if st.bw4 == 1 {
                st.avail_lc = st.is_inside(r, c - 2);
            }
        } else {
            st.avail_uc = false;
            st.avail_lc = false;
        }
        let (avail_u, avail_l, has_chroma_) = (st.avail_u, st.avail_l, st.has_chroma);
        let (bw, bh) = (st.bw4, st.bh4);
        if S::WRITE {
            self.check_block_fields(&b, &bi)?;
            if self.st.pal != BlockPalette::default() {
                self.check_palette(rec, &b, &bi)?;
            }
        }
        // ---- intra_frame_mode_info / inter_frame_mode_info: skip, cdef, delta q ----
        {
            let bufs = &*self.bufs;
            let ctx = if avail_u { bufs.skip[bufs.mi(r - 1, c)] } else { 0 }
                + if avail_l { bufs.skip[bufs.mi(r, c - 1)] } else { 0 };
            b.skip = self.sk.sym(&mut self.st.cdf.skip[ctx as usize], b.skip as i32) as u8;
        }
        // ---- read_cdef: per 64x64 (a block larger than 64x64 sets every one it covers) ----
        if fp.enable_cdef != 0 && b.skip == 0 {
            let (r64, c64) = (r & !15, c & !15);
            let sbi = self.bufs.cdef_at(r64, c64).unwrap();
            let sb = self.bufs.sb_cdef[sbi];
            if sb == -1 {
                b.cdef_idx = self.lit(b.cdef_idx as i32, fp.cdef_bits as i32) as i8;
                for y in (r64..r64 + bh).step_by(16) {
                    for x in (c64..c64 + bw).step_by(16) {
                        if let Some(k) = self.bufs.cdef_at(y, x) {
                            self.bufs.sb_cdef[k] = b.cdef_idx;
                        }
                    }
                }
            } else if S::WRITE {
                if b.cdef_idx != sb {
                    fail!(
                        ERR_INVALID,
                        "block {}: cdef_idx {} differs from its 64x64's {sb}",
                        self.st.b_idx,
                        b.cdef_idx
                    );
                }
            } else {
                b.cdef_idx = sb;
            }
        }
        // ---- read_delta_qindex ----
        let sb_bsize = if f.sb128 { BLOCK_128X128 } else { BLOCK_64X64 };
        if fp.delta_q_present != 0 {
            if self.st.read_deltas && !(bsize == sb_bsize && b.skip != 0) {
                let res = fp.delta_q_res as i32;
                let step = 1 << res;
                let mut reduced_w = 0;
                if S::WRITE {
                    let diff = b.sb_qindex as i32 - self.st.current_q_index;
                    if b.sb_qindex < 1 || diff % step != 0 {
                        fail!(
                            ERR_INVALID,
                            "block {}: sb_qindex {} not reachable from {} with delta_q_res {res} (use av1g_legalize_sb_qindex)",
                            self.st.b_idx,
                            b.sb_qindex,
                            self.st.current_q_index
                        );
                    }
                    reduced_w = diff / step;
                }
                let abs_w = reduced_w.abs();
                let mut a = self.sk.sym(&mut self.st.cdf.delta_q, abs_w.min(DELTA_Q_SMALL));
                if a == DELTA_Q_SMALL {
                    let mut rem_w = 1;
                    while ((abs_w - 1) >> (rem_w + 1)) > 0 {
                        rem_w += 1; // floor(log2(abs - 1))
                    }
                    let rem_bits = self.lit(rem_w - 1, 3) + 1;
                    let abs_bits = self.lit((abs_w - 1) - (1 << rem_bits), rem_bits);
                    a = abs_bits + (1 << rem_bits) + 1;
                }
                if a != 0 {
                    let sign = self.sk.bit((reduced_w < 0) as i32);
                    let reduced = if sign != 0 { -a } else { a };
                    self.st.current_q_index = clip3(1, 255, self.st.current_q_index + reduced * step);
                }
            }
            if S::WRITE {
                if b.sb_qindex as i32 != self.st.current_q_index && !(bsize == sb_bsize && b.skip != 0) {
                    fail!(
                        ERR_INVALID,
                        "block {}: sb_qindex {} differs from its superblock's qindex {}",
                        self.st.b_idx,
                        b.sb_qindex,
                        self.st.current_q_index
                    );
                }
            } else {
                b.sb_qindex = self.st.current_q_index as u8;
            }
        }
        let st = &mut *self.st;
        st.read_deltas = false;
        let q = if fp.delta_q_present != 0 {
            st.current_q_index
        } else {
            fp.base_q_idx as i32
        };
        st.set_block_q(fp, q);
        // ---- read_is_inter ----
        let is_inter = if f.inter {
            let bufs = &*self.bufs;
            let intra_at = |k: usize| bufs.ref0[k] as i32 == INTRA_FRAME;
            let above_intra = avail_u && intra_at(bufs.mi(r - 1, c));
            let left_intra = avail_l && intra_at(bufs.mi(r, c - 1));
            let ctx = if avail_u && avail_l {
                if left_intra && above_intra {
                    3
                } else {
                    (left_intra || above_intra) as usize
                }
            } else if avail_u || avail_l {
                2 * (if avail_u { above_intra } else { left_intra }) as usize
            } else {
                0
            };
            self.sk.sym(&mut self.st.icdf.is_inter[ctx], bi.is_inter as i32) != 0
        } else {
            false
        };
        bi.is_inter = is_inter as u8;
        self.st.is_inter = is_inter;
        // the YModes value of the block: its intra mode, or its inter mode
        let y_mode_map = if is_inter {
            self.inter_block_mode_info(r, c, bsize, &mut bi)? as u8
        } else {
            self.intra_mode_info(&mut b, r, c, bsize)?;
            b.y_mode
        };
        // ---- palette_tokens ----
        let pal = self.st.pal;
        if pal.size_y != 0 || pal.size_uv != 0 {
            match rec {
                Rec::Write { palette_map, .. } => {
                    let map = palette_map.get(pal.map_off as usize..).unwrap_or(&[]);
                    self.palette_tokens(bsize, map)?;
                }
                Rec::Parse(p) => {
                    self.palette_tokens(bsize, &[])?;
                    // the maps as the record holds them: luma, then chroma
                    self.st.pal.map_off = p.palette_map.len() as u32;
                    let maps = self.st.maps.as_ref().unwrap();
                    for (uv, n) in [(false, pal.size_y), (true, pal.size_uv)] {
                        if n != 0 {
                            let d = map_dims(bsize, r, c, f.mi_rows, f.mi_cols, uv);
                            p.palette_map.extend_from_slice(&maps.map[uv as usize][..d.w * d.h]);
                        }
                    }
                }
            }
            // PaletteSizes and PaletteColors of the block's 4x4s
            let bufs = &mut *self.bufs;
            let k = bufs.pals.len() as u32;
            bufs.pals.push(self.st.pal);
            let (r_end, c_end) = ((r + bh).min(f.mi_rows), (c + bw).min(f.mi_cols));
            for y in r..r_end {
                let i = bufs.mi(y, c);
                bufs.pal_at[i..i + (c_end - c) as usize].fill(k);
            }
        }

        // ---- read_block_tx_size ----
        if fp.tx_mode_select != 0 && bsize > BLOCK_4X4 {
            if is_inter {
                if b.skip == 0 {
                    // read_var_tx_size of every Max_Tx_Size_Rect area (blocks larger than 64x64:
                    // their 64x64s in raster order)
                    let mut leaf = -1;
                    let max_tx = t8(&Max_Tx_Size_Rect, bsize);
                    let (tw4, th4) = (t8(&Tx_Width, max_tx) >> 2, t8(&Tx_Height, max_tx) >> 2);
                    for row in (r..r + bh).step_by(th4 as usize) {
                        for col in (c..c + bw).step_by(tw4 as usize) {
                            self.var_tx(row, col, max_tx, 0, b.tx_depth as i32, &mut leaf)?;
                        }
                    }
                    if !S::WRITE {
                        b.tx_depth = leaf.max(0) as u8;
                    }
                }
            } else {
                let bufs = &*self.bufs;
                let cdf = &mut self.st.cdf;
                let max_rect = t8(&Max_Tx_Size_Rect, bsize);
                let max_tx_depth = t8(&Max_Tx_Depth, bsize);
                let inter_at = |k: usize| f.inter && bufs.ref0[k] as i32 == LAST_FRAME;
                let above_w = if !avail_u {
                    0
                } else {
                    let k = bufs.mi(r - 1, c);
                    if inter_at(k) {
                        4 * bw4(bufs.mi_size[k] as i32)
                    } else {
                        t8(&Tx_Width, bufs.tx_size[k] as i32)
                    }
                };
                let left_h = if !avail_l {
                    0
                } else {
                    let k = bufs.mi(r, c - 1);
                    if inter_at(k) {
                        4 * bh4(bufs.mi_size[k] as i32)
                    } else {
                        t8(&Tx_Height, bufs.tx_size[k] as i32)
                    }
                };
                let ctx =
                    ((above_w >= t8(&Tx_Width, max_rect)) as usize) + ((left_h >= t8(&Tx_Height, max_rect)) as usize);
                let d = b.tx_depth as i32;
                b.tx_depth = match max_tx_depth {
                    4 => self.sk.sym(&mut cdf.tx_64x64[ctx], d),
                    3 => self.sk.sym(&mut cdf.tx_32x32[ctx], d),
                    2 => self.sk.sym(&mut cdf.tx_16x16[ctx], d),
                    _ => self.sk.sym(&mut cdf.tx_8x8[ctx], d),
                } as u8;
            }
        }
        let tx_size = luma_tx_size(bsize, b.tx_depth as i32);
        self.st.tx_size = tx_size;
        if S::WRITE && f.inter {
            if !is_inter {
                inter_stat(6);
            } else if b.tx_depth > 0 {
                inter_stat(7);
            }
        }
        if S::WRITE && (bw > 16 || bh > 16) {
            sb128_stat(match bsize {
                BLOCK_128X128 => 8,
                BLOCK_128X64 => 9,
                _ => 10,
            });
            sb128_stat(if is_inter { 12 } else { 11 });
            sb128_stat(if b.skip != 0 { 13 } else { 14 });
            if is_inter && b.skip == 0 {
                sb128_stat(15);
            }
        }
        if !S::WRITE {
            self.check_block_fields(&b, &bi)?;
        }

        let planes = 1 + 2 * has_chroma_ as usize;
        if b.skip != 0 {
            // reset_block_context
            let st = &mut *self.st;
            for p in 0..planes {
                let sub = (p != 0) as i32;
                for i in (c >> sub)..((c + bw) >> sub) {
                    st.above_level[p][i as usize] = 0;
                    st.above_dc[p][i as usize] = 0;
                }
                for i in (r >> sub)..((r + bh) >> sub) {
                    st.left_level[p][i as usize] = 0;
                    st.left_dc[p][i as usize] = 0;
                }
            }
        }
        let r_end = (r + bh).min(f.mi_rows);
        let c_end = (c + bw).min(f.mi_cols);
        {
            let bufs = &mut *self.bufs;
            let n = (c_end - c) as usize;
            for y in r..r_end {
                let k = bufs.mi(y, c);
                fill_small(&mut bufs.y_mode[k..k + n], y_mode_map);
                if is_inter {
                    // UVModes is only read for intra blocks (is_smooth checks RefFrames first)
                    fill_small(&mut bufs.uv_mode[k..k + n], 0xFF);
                } else if has_chroma_ {
                    fill_small(&mut bufs.uv_mode[k..k + n], b.uv_mode);
                }
                if f.inter {
                    fill_small(
                        &mut bufs.ref0[k..k + n],
                        if is_inter { LAST_FRAME } else { INTRA_FRAME } as u8,
                    );
                    if is_inter {
                        bufs.mvs[k..k + n].fill([bi.mv_row, bi.mv_col]);
                    }
                }
            }
        }
        if let Some(p) = self.plan.as_deref_mut() {
            let st = &*self.st;
            p.block(st.b_idx, r, c, bsize, is_inter, has_chroma_, st.block_q);
        }
        // ---- compute_prediction (inter blocks: the whole block, before its residual) ----
        if is_inter && f.do_recon {
            self.predict_inter_block(bsize, has_chroma_);
        }

        // ---- residual: tx blocks in bitstream order (an inter block's luma in transform_tree
        // order) ----
        let (mi_cols, mi_rows) = (f.mi_cols, f.mi_rows);
        if is_inter {
            let st = &mut *self.st;
            st.n_tree = tx_tree_order(res_unit_bsize(bsize), tx_size, &mut st.tree);
        }
        let (units_w, units_h) = res_units(bsize);
        // every coded tx block of the block, in order (per 64x64 residual unit: Y, U, V): $body
        // with (plane, tx_sz, x, y, x4, y4)
        macro_rules! for_each_txb {
            (|$plane:ident, $tx_sz:ident, $x:ident, $y:ident, $x4:ident, $y4:ident| $body:block) => {
                for uy in 0..units_h {
                    for ux in 0..units_w {
                        for $plane in 0..planes {
                            let sub = ($plane != 0) as i32;
                            let $tx_sz = if $plane != 0 { uv_tx_size(bsize) } else { tx_size };
                            let step_x = t8(&Tx_Width, $tx_sz) >> 2;
                            let step_y = t8(&Tx_Height, $tx_sz) >> 2;
                            let plane_sz = if $plane != 0 { uv_bsize(bsize) } else { bsize };
                            let (num4x4_w, num4x4_h) = (bw4(plane_sz).min(16 >> sub), bh4(plane_sz).min(16 >> sub));
                            let (ox, oy) = ((ux << 4) >> sub, (uy << 4) >> sub);
                            let (base_x4, base_y4) = (c >> sub, r >> sub);
                            let (max_x4, max_y4) = (mi_cols >> sub, mi_rows >> sub);
                            if $plane == 0 && is_inter {
                                for k in 0..self.st.n_tree {
                                    let (tx, ty) = self.st.tree[k];
                                    let ($x, $y) = (tx + ox, ty + oy);
                                    let ($x4, $y4) = (base_x4 + $x, base_y4 + $y);
                                    if $x4 >= max_x4 || $y4 >= max_y4 {
                                        continue;
                                    }
                                    $body
                                }
                            } else {
                                for $y in (oy..oy + num4x4_h).step_by(step_y as usize) {
                                    for $x in (ox..ox + num4x4_w).step_by(step_x as usize) {
                                        let ($x4, $y4) = (base_x4 + $x, base_y4 + $y);
                                        if $x4 >= max_x4 || $y4 >= max_y4 {
                                            continue;
                                        }
                                        $body
                                    }
                                }
                            }
                        }
                    }
                }
            };
        }
        match rec {
            Rec::Write {
                block_txb,
                txb,
                txb_base,
                coeffs,
                coeff_base,
                ..
            } => {
                let b_idx = self.st.b_idx as usize;
                let (t0, t1) = (block_txb[b_idx] as usize, block_txb[b_idx + 1] as usize);
                let mut ti = t0;
                for_each_txb!(|plane, tx_sz, x, y, x4, y4| {
                    let tl = ti.wrapping_sub(*txb_base);
                    let t = match txb.get_mut(tl) {
                        Some(t)
                            if ti < t1
                                && t.plane as usize == plane
                                && t.tx_size as i32 == tx_sz
                                && t.x4 as i32 == x4
                                && t.y4 as i32 == y4 =>
                        {
                            t
                        }
                        _ => fail!(ERR_INVALID, "block {b_idx}: tx layout mismatch (call av1g_layout)"),
                    };
                    let n = tx_coeffs(tx_sz);
                    let off = (t.coeff_off as usize).wrapping_sub(*coeff_base);
                    let Some(q) = coeffs.get_mut(off..off.wrapping_add(n)) else {
                        fail!(
                            ERR_INVALID,
                            "block {b_idx}: coefficients of tx block {ti} outside the record"
                        );
                    };
                    if let Some(p) = self.plan.as_deref_mut() {
                        p.coeffs_at(off, n);
                    }
                    self.st.cur_txb = ti as u32;
                    self.txb(&b, t, q, x, y)?;
                    ti += 1;
                });
                if ti != t1 {
                    fail!(ERR_INVALID, "block {b_idx}: tx layout mismatch (count)");
                }
            }
            Rec::Parse(p) => {
                for_each_txb!(|plane, tx_sz, x, y, x4, y4| {
                    let off = p.coeffs.len();
                    let n = tx_coeffs(tx_sz);
                    let mut t = Txb {
                        coeff_off: off as u32,
                        x4: x4 as u16,
                        y4: y4 as u16,
                        plane: plane as u8,
                        tx_size: tx_sz as u8,
                        ..Default::default()
                    };
                    p.coeffs.resize(off + n, 0);
                    self.txb(&b, &mut t, &mut p.coeffs[off..off + n], x, y)?;
                    p.txb.push(t);
                });
                p.blocks.push(b);
                p.block_txb.push(parse_txb0);
                if fp.allow_screen_content_tools != 0 {
                    p.palette.push(self.st.pal);
                }
                if f.inter {
                    p.inter.push(bi);
                }
            }
        }

        let bufs = &mut *self.bufs;
        for y in r..r_end {
            let k = bufs.mi(y, c);
            let n = (c_end - c) as usize;
            fill_small(&mut bufs.skip[k..k + n], b.skip);
            fill_small(&mut bufs.tx_size[k..k + n], tx_size as u8);
            fill_small(&mut bufs.mi_size[k..k + n], bsize as u8);
        }
        Ok(())
    }

    /// An intra tx block's [`TxbEdges`] (BlockDecoded; with ENC_CHECK_EDGES, checked against
    /// av1g_txb_edges).
    #[allow(clippy::too_many_arguments)]
    fn intra_edges(&self, b: &Block, t: &Txb, xi: i32, yi: i32, sbr: i32, sbc: i32, step: (i32, i32)) -> Res<TxbEdges> {
        let (f, st, bufs) = (self.f, &*self.st, &*self.bufs);
        let plane = t.plane as usize;
        let sub = (plane != 0) as i32;
        let (step_x, step_y) = step;
        let (bl, bu) = if plane == 0 {
            (st.avail_l, st.avail_u)
        } else {
            (st.avail_lc, st.avail_uc)
        };
        let bd = &st.block_decoded[plane];
        let e = TxbEdges {
            left: bl || xi > 0,
            above: bu || yi > 0,
            above_right: bd[((sbr >> sub) - 1 + 1) as usize][((sbc >> sub) + step_x + 1) as usize] != 0,
            below_left: bd[((sbr >> sub) + step_y + 1) as usize][((sbc >> sub) - 1 + 1) as usize] != 0,
            filter_type: {
                let mode = if plane == 0 {
                    b.y_mode as i32
                } else if b.uv_mode as i32 == UV_CFL_PRED {
                    DC_PRED
                } else {
                    b.uv_mode as i32
                };
                if f.fp.enable_intra_edge_filter != 0 && is_directional(mode) {
                    get_filter_type(
                        plane as i32,
                        st.mi_row - bufs.r0,
                        st.mi_col - bufs.c0,
                        bu,
                        bl,
                        &bufs.y_mode,
                        &bufs.uv_mode,
                        bufs.mw,
                    )
                } else {
                    0
                }
            },
        };
        if f.check_edges && !f.sb128 {
            let c = txb_edges(
                plane as i32,
                t.x4 as i32,
                t.y4 as i32,
                t.tx_size as i32,
                st.cur_txb,
                xi,
                yi,
                bl,
                bu,
                st.mi_row_end,
                st.mi_col_end,
                &f.ordmap[plane],
                ((f.sb_cols * 16) >> sub) as usize,
            );
            if c.have_left != e.left
                || c.have_above != e.above
                || c.have_above_right != e.above_right
                || c.have_below_left != e.below_left
            {
                fail!(
                    ERR_INTERNAL,
                    "block {} plane {plane} tx ({},{}): av1g_txb_edges {}{}{}{} != spec {}{}{}{}",
                    st.b_idx,
                    t.x4,
                    t.y4,
                    c.have_left as i32,
                    c.have_above as i32,
                    c.have_above_right as i32,
                    c.have_below_left as i32,
                    e.left as i32,
                    e.above as i32,
                    e.above_right as i32,
                    e.below_left as i32
                );
            }
        }
        Ok(e)
    }

    /// transform_block: prediction (write mode), the hook, the range check, coeffs(), the
    /// reconstruction. Planning, only the intra edges (and the maps).
    fn txb(&mut self, b: &Block, t: &mut Txb, q: &mut [i16], xi: i32, yi: i32) -> Res<()> {
        let f = self.f;
        let fp = &f.fp;
        let plane = t.plane as usize;
        let tx_sz = t.tx_size as i32;
        let sub = (plane != 0) as i32;
        let (start_x, start_y) = (t.x4 as i32 * 4, t.y4 as i32 * 4);
        let row = (start_y << sub) >> 2;
        let col = (start_x << sub) >> 2;
        let sb_mask = f.sb_size4() - 1;
        let (sbr, sbc) = (row & sb_mask, col & sb_mask);
        let step_x = t8(&Tx_Width, tx_sz) >> 2;
        let step_y = t8(&Tx_Height, tx_sz) >> 2;
        // tile-local sample position
        let (ox, oy) = ((self.bufs.c0 * 4) >> sub, (self.bufs.r0 * 4) >> sub);
        let (lx, ly) = (start_x - ox, start_y - oy);
        let stride = self.bufs.stride[plane];
        let off = ly as usize * stride + lx as usize;
        let is_inter = self.st.is_inter;

        if plane == 0
            && b.skip == 0
            && let Some(p) = self.plan.as_deref_mut()
        {
            // a luma type outside its set fails coding (if the levels aren't all zero): such a
            // record is coded in one pass
            let (ty, reduced) = (t.tx_type as i32, fp.reduced_tx_set != 0);
            p.ok &= ty < TX_TYPES
                && if is_inter {
                    tx_type_in_set_inter(get_tx_set_inter(tx_sz, reduced), ty)
                } else {
                    tx_type_in_set_intra(get_tx_set_intra(tx_sz, reduced), ty)
                };
        }
        if (f.do_recon || self.plan.is_some()) && !is_inter {
            let e = self.intra_edges(b, t, xi, yi, sbr, sbc, (step_x, step_y))?;
            if let Some(p) = self.plan.as_deref_mut() {
                p.edges[self.st.cur_txb as usize - p.txb_base] = e.pack();
            } else if [self.st.pal.size_y, self.st.pal.size_uv][(plane > 0) as usize] != 0 {
                // predict_palette (palette_tokens filled the maps)
                let st = &*self.st;
                let d = map_dims(st.mi_size, st.mi_row, st.mi_col, f.mi_rows, f.mi_cols, plane > 0);
                let (bx, by) = map_origin(st.mi_row, st.mi_col, sub);
                predict_palette(
                    &mut self.bufs.plane[plane],
                    off,
                    stride,
                    (tx_w(tx_sz) as usize, tx_h(tx_sz) as usize),
                    ((start_x - bx) as usize, (start_y - by) as usize),
                    &st.pal.colors[plane],
                    &st.maps.as_ref().unwrap().map[(plane > 0) as usize],
                    d,
                );
            } else {
                let max = (((f.mi_cols * 4) >> sub) - 1 - ox, ((f.mi_rows * 4) >> sub) - 1 - oy);
                let st = &*self.st;
                let [l, u, v] = &mut self.bufs.plane;
                let (cur, luma): (&mut [u8], &[u8]) = match plane {
                    0 => (l, &[]),
                    1 => (u, l),
                    _ => (v, l),
                };
                let luma_stride = self.bufs.stride[0];
                predict_intra_txb(
                    fp,
                    b,
                    plane,
                    tx_sz,
                    e,
                    (lx, ly),
                    max,
                    cur,
                    stride,
                    luma,
                    luma_stride,
                    (st.max_luma_w, st.max_luma_h),
                );
            }
        }
        if plane == 0 && !is_inter {
            self.st.max_luma_w = lx + step_x * 4;
            self.st.max_luma_h = ly + step_y * 4;
        }
        if self.plan.is_none() {
            t.eob = 0;
            let mut tx_type = if plane == 0 {
                t.tx_type as i32
            } else if is_inter && b.skip != 0 {
                // unused: the spec derives an inter block's chroma type only where it codes one,
                // from the luma types its coded luma left (a skip block's would be another block's)
                DCT_DCT
            } else {
                let tt = if is_inter {
                    // compute_tx_type: the luma type at Max(MiRow / MiCol, the chroma position << 1)
                    let st = &*self.st;
                    let (y4, x4) = (
                        ((t.y4 as i32) << 1).max(st.mi_row) - st.mi_row,
                        ((t.x4 as i32) << 1).max(st.mi_col) - st.mi_col,
                    );
                    chroma_tx_type_inter(
                        tx_sz,
                        st.tx_types[y4 as usize][x4 as usize] as i32,
                        fp.reduced_tx_set != 0,
                    )
                } else {
                    chroma_tx_type(tx_sz, b.uv_mode as i32, fp.reduced_tx_set != 0)
                };
                t.tx_type = tt as u8;
                tt
            };
            if b.skip == 0 {
                let mut eob = 0;
                if S::WRITE {
                    let st = &mut *self.st;
                    let ctx = TxbCtx {
                        block: b,
                        block_idx: st.b_idx,
                        recon: self.bufs.plane[plane].get(off..).unwrap_or(&[]),
                        recon_stride: stride,
                        dc_q: st.dc_q[plane],
                        ac_q: st.ac_q[plane],
                        derived_tx_type: tx_type,
                        qm_level: if fp.using_qmatrix != 0 { f.qm_level[plane] } else { 15 },
                        is_inter,
                    };
                    let hook = self.hook.map(|h| (h, &mut *self.hs));
                    eob = levels(
                        f,
                        hook,
                        &ctx,
                        t,
                        q,
                        &mut tx_type,
                        &mut st.dq,
                        &mut st.res,
                        &mut st.n_fixed,
                    )?;
                }
                eob = self.coeffs(b, plane, tx_sz, &mut tx_type, t.x4 as i32, t.y4 as i32, q, eob)?;
                if plane == 0 {
                    t.tx_type = tx_type as u8;
                }
                t.eob = eob as u16;
                if eob > 0 && f.do_recon {
                    add_residual(
                        &mut self.bufs.plane[plane][off..],
                        stride,
                        &self.st.res[..],
                        tx_sz,
                        tx_type,
                    );
                }
            }
        }
        let st = &mut *self.st;
        let bd = &mut st.block_decoded[plane];
        let x0 = ((sbc >> sub) + 1) as usize;
        for i in 0..step_y {
            fill_small(&mut bd[((sbr >> sub) + i + 1) as usize][x0..x0 + step_x as usize], 1);
        }
        if plane > 0 {
            // LoopfilterTxSizes for the chroma planes (luma uses the tx_size map)
            let bufs = &mut *self.bufs;
            let (cs, cr) = (f.mi_cols >> 1, f.mi_rows >> 1);
            let (cx0, cy0, cw) = (bufs.c0 >> 1, bufs.r0 >> 1, bufs.mw >> 1);
            let m = &mut bufs.lf_uv[plane - 1];
            let (x4, y4) = (t.x4 as i32, t.y4 as i32);
            for i in 0..step_y {
                if y4 + i >= cr {
                    break;
                }
                for j in 0..step_x {
                    if x4 + j >= cs {
                        break;
                    }
                    m[((y4 + i - cy0) * cw + x4 + j - cx0) as usize] = tx_sz as u8;
                }
            }
        }
        Ok(())
    }

    /// coeffs() (spec 5.11.39). Write: `q` holds the levels, `eob` was computed by the caller.
    /// Parse: `q` is zero on entry and receives the decoded levels. Returns eob; the luma
    /// `tx_type` is coded / decoded here.
    fn coeffs(
        &mut self,
        b: &Block,
        plane: usize,
        tx_sz: i32,
        tx_type: &mut i32,
        x4: i32,
        y4: i32,
        q: &mut [i16],
        mut eob: i32,
    ) -> Res<i32> {
        let f = self.f;
        let st = &mut *self.st;
        let cdf = &mut st.cdf;
        let ptype = (plane > 0) as usize;
        let sub = (plane != 0) as i32;
        let tsz = tx_sz as usize;
        let tx_sz_ctx = (Tx_Size_Sqr[tsz] as usize + Tx_Size_Sqr_Up[tsz] as usize + 1) >> 1;
        let (w, h) = (Tx_Width[tsz] as i32, Tx_Height[tsz] as i32);
        let (w4, h4) = (w >> 2, h >> 2);
        let (max_x4, max_y4) = (f.mi_cols >> sub, f.mi_rows >> sub);
        let (xs, ys) = (x4 as usize, y4 as usize);

        // all_zero context
        let ctx = {
            let al = &st.above_level[plane];
            let ll = &st.left_level[plane];
            let bsz = if plane != 0 { uv_bsize(st.mi_size) } else { st.mi_size };
            let (bw, bh) = (4 * bw4(bsz), 4 * bh4(bsz));
            let wn = w4.min(max_x4 - x4).max(0) as usize;
            let hn = h4.min(max_y4 - y4).max(0) as usize;
            if plane == 0 {
                let top = al[xs..xs + wn].iter().copied().max().unwrap_or(0) as i32;
                let left = ll[ys..ys + hn].iter().copied().max().unwrap_or(0) as i32;
                let (mx, mn) = (top.max(left), top.min(left));
                if bw == w && bh == h {
                    0
                } else if top == 0 && left == 0 {
                    1
                } else if top == 0 || left == 0 {
                    2 + (mx > 3) as usize
                } else if mx <= 3 {
                    4
                } else if mn <= 3 {
                    5
                } else {
                    6
                }
            } else {
                let ad = &st.above_dc[plane];
                let ld = &st.left_dc[plane];
                let above = al[xs..xs + wn]
                    .iter()
                    .zip(&ad[xs..xs + wn])
                    .fold(0, |a, (&l, &d)| a | l | d);
                let left = ll[ys..ys + hn]
                    .iter()
                    .zip(&ld[ys..ys + hn])
                    .fold(0, |a, (&l, &d)| a | l | d);
                let mut ctx = (above != 0) as usize + (left != 0) as usize + 7;
                if bw * bh > w * h {
                    ctx += 3;
                }
                ctx
            }
        };
        let all_zero = self.sk.sym(&mut cdf.txb_skip[tx_sz_ctx][ctx], (eob == 0) as i32);
        let mut cul_level = 0i32;
        let mut dc_category = 0u8;
        if all_zero != 0 {
            eob = 0;
            if plane == 0 {
                *tx_type = DCT_DCT;
            }
        } else {
            if plane == 0 && st.is_inter {
                // transform_type(), inter sets
                let set = get_tx_set_inter(tx_sz, f.fp.reduced_tx_set != 0);
                let ic = &mut st.icdf;
                let sqr = Tx_Size_Sqr[tsz] as usize;
                let pos = |inv: &[u8]| inv.iter().rposition(|&t| t as i32 == *tx_type).unwrap_or(0) as i32;
                *tx_type = match set {
                    TX_SET_INTER_1 => {
                        let i = self.sk.sym(&mut ic.inter_tx_set1[sqr], pos(&Tx_Type_Inter_Inv_Set1));
                        Tx_Type_Inter_Inv_Set1[i as usize] as i32
                    }
                    TX_SET_INTER_2 => {
                        let i = self.sk.sym(&mut ic.inter_tx_set2, pos(&Tx_Type_Inter_Inv_Set2));
                        Tx_Type_Inter_Inv_Set2[i as usize] as i32
                    }
                    TX_SET_INTER_3 => {
                        let i = self.sk.sym(&mut ic.inter_tx_set3[sqr], pos(&Tx_Type_Inter_Inv_Set3));
                        Tx_Type_Inter_Inv_Set3[i as usize] as i32
                    }
                    _ => DCT_DCT,
                };
            } else if plane == 0 {
                // transform_type()
                let set = get_tx_set_intra(tx_sz, f.fp.reduced_tx_set != 0);
                if set > 0 {
                    let sqr = Tx_Size_Sqr[tsz] as usize;
                    let intra_dir = if b.filter_intra != 0 {
                        Filter_Intra_Mode_To_Intra_Dir[b.filter_intra as usize - 1] as usize
                    } else {
                        b.y_mode as usize
                    };
                    if set == TX_SET_INTRA_1 {
                        let idx = Tx_Type_Intra_Inv_Set1
                            .iter()
                            .rposition(|&t| t as i32 == *tx_type)
                            .unwrap_or(0);
                        let idx = self.sk.sym(&mut cdf.intra_tx_set1[sqr][intra_dir], idx as i32);
                        *tx_type = Tx_Type_Intra_Inv_Set1[idx as usize] as i32;
                    } else {
                        let idx = Tx_Type_Intra_Inv_Set2
                            .iter()
                            .rposition(|&t| t as i32 == *tx_type)
                            .unwrap_or(0);
                        let idx = self.sk.sym(&mut cdf.intra_tx_set2[sqr][intra_dir], idx as i32);
                        *tx_type = Tx_Type_Intra_Inv_Set2[idx as usize] as i32;
                    }
                } else {
                    *tx_type = DCT_DCT;
                }
            }
            let scan = get_scan(tx_sz, *tx_type);
            let tx_class = tx_class(*tx_type);
            // eob
            let eob_multisize = (Tx_Width_Log2[tsz] as i32).min(5) + (Tx_Height_Log2[tsz] as i32).min(5) - 4;
            let mut eob_pt_w = 1;
            if S::WRITE {
                if eob <= 2 {
                    eob_pt_w = eob;
                } else {
                    eob_pt_w = 2;
                    let mut v = eob - 1;
                    while v > 1 {
                        v >>= 1;
                        eob_pt_w += 1;
                    }
                }
            }
            let ectx = (tx_class != TX_CLASS_2D) as usize;
            let s = eob_pt_w - 1;
            let eob_pt = match eob_multisize {
                0 => self.sk.sym(&mut cdf.eob_pt_16[ptype][ectx], s),
                1 => self.sk.sym(&mut cdf.eob_pt_32[ptype][ectx], s),
                2 => self.sk.sym(&mut cdf.eob_pt_64[ptype][ectx], s),
                3 => self.sk.sym(&mut cdf.eob_pt_128[ptype][ectx], s),
                4 => self.sk.sym(&mut cdf.eob_pt_256[ptype][ectx], s),
                5 => self.sk.sym(&mut cdf.eob_pt_512[ptype], s),
                _ => self.sk.sym(&mut cdf.eob_pt_1024[ptype], s),
            } + 1;
            {
                let eob_w = eob;
                eob = if eob_pt < 2 { eob_pt } else { (1 << (eob_pt - 2)) + 1 };
                let rem_w = eob_w - eob;
                if eob_pt >= 3 {
                    let e = &mut cdf.eob_extra[tx_sz_ctx][ptype][(eob_pt - 3) as usize];
                    if self.sk.sym(e, (rem_w >> (eob_pt - 3)) & 1) != 0 {
                        eob += 1 << (eob_pt - 3);
                    }
                    for i in 1..eob_pt - 2 {
                        let sh = eob_pt - 2 - 1 - i;
                        if self.sk.bit((rem_w >> sh) & 1) != 0 {
                            eob += 1 << sh;
                        }
                    }
                }
            }
            if eob > tx_coeffs(tx_sz) as i32 {
                fail!(ERR_INVALID, "eob {eob} out of range");
            }
            // levels (reverse scan order), contexts from already-coded levels
            let adj = Adjusted_Tx_Size[tsz] as usize;
            let bwl = Tx_Width_Log2[adj] as usize;
            let (width, height) = (1usize << bwl, Tx_Height[adj] as usize);
            let ls = width + LEV_STRIDE_PAD; // padded level stride
            let lev = &mut st.lev[..];
            lev[..ls * (height + LEV_STRIDE_PAD)].fill(0);
            let area = (height << bwl) as i32;
            let sig = &Sig_Ref_Diff_Offset[tx_class as usize];
            let magoff = &Mag_Ref_Offset_With_Tx_Class[tx_class as usize];
            let base_ctx_off = &Coeff_Base_Ctx_Offset[tsz];
            let brsz = tx_sz_ctx.min(TX_32X32 as usize);
            let coeff_base_eob = &mut cdf.coeff_base_eob[tx_sz_ctx][ptype];
            let coeff_base = &mut cdf.coeff_base[tx_sz_ctx][ptype];
            let coeff_br = &mut cdf.coeff_br[brsz][ptype];
            for c in (0..eob).rev() {
                let pos = scan[c as usize] as usize;
                let v = (q[pos] as i32).abs();
                let level_w = v.min(15);
                let (row, col) = (pos >> bwl, pos & (width - 1));
                let lp = row * ls + col;
                let mut level;
                if c == eob - 1 {
                    let bctx = if c == 0 {
                        0
                    } else if c <= area / 8 {
                        1
                    } else if c <= area / 4 {
                        2
                    } else {
                        3
                    };
                    level = self.sk.sym(&mut coeff_base_eob[bctx], level_w.min(3) - 1) + 1;
                } else {
                    let mut mag = 0;
                    for o in sig {
                        let l = lev[lp + o[0] as usize * ls + o[1] as usize] as i32;
                        mag += l.min(3);
                    }
                    let mut bctx = ((mag + 1) >> 1).min(4) as usize;
                    if tx_class == TX_CLASS_2D {
                        if row == 0 && col == 0 {
                            bctx = 0;
                        } else {
                            bctx += base_ctx_off[row.min(4)][col.min(4)] as usize;
                        }
                    } else {
                        let id = if tx_class == TX_CLASS_VERT { row } else { col };
                        bctx += Coeff_Base_Pos_Ctx_Offset[id.min(2)] as usize;
                    }
                    level = self.sk.sym(&mut coeff_base[bctx], level_w.min(3));
                }
                if level > NUM_BASE_LEVELS {
                    let mut mag = 0;
                    for o in magoff {
                        let l = lev[lp + o[0] as usize * ls + o[1] as usize] as i32;
                        mag += l.min(15);
                    }
                    let mag = ((mag + 1) >> 1).min(6) as usize;
                    let brctx = if pos == 0 {
                        mag
                    } else if tx_class == TX_CLASS_2D {
                        if row < 2 && col < 2 { mag + 7 } else { mag + 14 }
                    } else if tx_class == TX_CLASS_HORIZ {
                        if col == 0 { mag + 7 } else { mag + 14 }
                    } else if row == 0 {
                        mag + 7
                    } else {
                        mag + 14
                    };
                    let mut rem_w = level_w - 3;
                    for _ in 0..COEFF_BASE_RANGE / (BR_CDF_SIZE - 1) {
                        let k = self.sk.sym(&mut coeff_br[brctx], rem_w.min(3));
                        level += k;
                        rem_w -= k;
                        if k < BR_CDF_SIZE - 1 {
                            break;
                        }
                    }
                }
                lev[lp] = level as u8;
            }
            // signs and Golomb remainders (forward scan order)
            let ad = &st.above_dc[plane];
            let ld = &st.left_dc[plane];
            for c in 0..eob as usize {
                let pos = scan[c] as usize;
                let lp = (pos >> bwl) * ls + (pos & (width - 1));
                if lev[lp] == 0 {
                    continue;
                }
                let v_w = q[pos] as i32;
                let sign_w = (v_w < 0) as i32;
                let a_w = v_w.abs();
                let sign = if c == 0 {
                    let mut dc_sign = 0;
                    for k in 0..w4 {
                        if x4 + k < max_x4 {
                            match ad[xs + k as usize] {
                                1 => dc_sign -= 1,
                                2 => dc_sign += 1,
                                _ => {}
                            }
                        }
                    }
                    for k in 0..h4 {
                        if y4 + k < max_y4 {
                            match ld[ys + k as usize] {
                                1 => dc_sign -= 1,
                                2 => dc_sign += 1,
                                _ => {}
                            }
                        }
                    }
                    let dctx = if dc_sign < 0 {
                        1
                    } else if dc_sign > 0 {
                        2
                    } else {
                        0
                    };
                    self.sk.sym(&mut cdf.dc_sign[ptype][dctx], sign_w)
                } else {
                    self.sk.bit(sign_w)
                };
                let mut a = lev[lp] as i32;
                if a > NUM_BASE_LEVELS + COEFF_BASE_RANGE {
                    let x_w = if S::WRITE {
                        (a_w - (NUM_BASE_LEVELS + COEFF_BASE_RANGE)) as u32
                    } else {
                        1
                    };
                    let mut len_w = 0;
                    while (x_w >> len_w) > 1 {
                        len_w += 1; // floor(log2 x)
                    }
                    let mut length = 0;
                    loop {
                        // golomb_length_bit
                        length += 1;
                        if self.sk.bit((length - 1 == len_w) as i32) != 0 {
                            break;
                        }
                        if length > 20 {
                            fail!(ERR_INVALID, "golomb length > 20");
                        }
                    }
                    let mut x = 1u32;
                    for i in (0..length - 1).rev() {
                        x = (x << 1) | self.sk.bit(((x_w >> i) & 1) as i32) as u32;
                    }
                    a = (x as i32).wrapping_add(COEFF_BASE_RANGE + NUM_BASE_LEVELS);
                }
                a &= 0xFFFFF;
                if !S::WRITE {
                    if a > 32767 {
                        fail!(ERR_INVALID, "coefficient {a} does not fit the int16 record");
                    }
                    q[pos] = (if sign != 0 { -a } else { a }) as i16;
                }
                if pos == 0 {
                    dc_category = if sign != 0 { 1 } else { 2 };
                }
                cul_level += a;
            }
            cul_level = cul_level.min(63);
        }
        if plane == 0 && st.is_inter {
            // TxTypes of the block's luma (the chroma of inter blocks derives from them)
            let (y0, x0) = ((y4 - st.mi_row) as usize, (x4 - st.mi_col) as usize);
            for row in &mut st.tx_types[y0..(y0 + h4 as usize).min(32)] {
                fill_small(&mut row[x0..(x0 + w4 as usize).min(32)], *tx_type as u8);
            }
        }
        let (al, ad) = (&mut st.above_level[plane], &mut st.above_dc[plane]);
        fill_small(&mut al[xs..xs + w4 as usize], cul_level as u8);
        fill_small(&mut ad[xs..xs + w4 as usize], dc_category);
        let (ll, ld) = (&mut st.left_level[plane], &mut st.left_dc[plane]);
        fill_small(&mut ll[ys..ys + h4 as usize], cul_level as u8);
        fill_small(&mut ld[ys..ys + h4 as usize], dc_category);
        Ok(eob)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The NEON eob scan equals the scalar one on random sparse levels.
    #[test]
    fn eob_of_matches_scalar() {
        let mut r = crate::dsp::Rng(17);
        for tx in 0..TX_SIZES_ALL {
            for ty in [DCT_DCT, V_DCT, H_DCT, IDTX] {
                if !tx_type_in_set_intra(get_tx_set_intra(tx, false), ty) && ty != DCT_DCT {
                    continue;
                }
                let n = tx_coeffs(tx);
                let iscan = get_iscan(tx, ty);
                for _ in 0..200 {
                    let mut q = vec![0i16; n];
                    let k = r.below(6);
                    for _ in 0..k {
                        q[r.below(n as u32) as usize] = r.range(-32768, 32767) as i16;
                    }
                    assert_eq!(eob_of(&q, iscan), eob_of_scalar(&q, iscan));
                }
            }
        }
    }

    /// get_iscan inverts get_scan for every tx size and type.
    #[test]
    fn iscan_inverts_scan() {
        for tx in 0..TX_SIZES_ALL {
            for ty in 0..TX_TYPES {
                if !tx_type_in_set_intra(get_tx_set_intra(tx, false), ty) {
                    continue;
                }
                let (s, i) = (get_scan(tx, ty), get_iscan(tx, ty));
                let n = tx_coeffs(tx);
                for c in 0..n {
                    assert_eq!(i[s[c] as usize] as usize, c, "tx {tx} type {ty}");
                }
            }
        }
    }
}
