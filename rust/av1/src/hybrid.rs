//! The CPU half of the hybrid encoder (Sources/AV1Encoder/src/hybrid.cpp, av1enc.h's
//! `av1enc_hybrid_*`): the closed loop on blocks the Metal analysis decided (partition and luma
//! modes). Per block, chroma modes and CfL from the source; then the writer with a [`TxbHook`],
//! which gets each tx block's exact prediction and chooses its coefficients (the GPU's dead-zone
//! quantizer, luma tx types by exact reconstruction error), reconstructing as it goes, tiles on
//! parallel threads; then skip flags for all-zero blocks. The caller filters the reconstruction and
//! writes the bitstream ([`Hybrid::write`]). With [`Hybrid::set_intrabc`], a key frame's blocks go
//! through the intra block copy search first ([`intrabc`]), and a frame that copies is written
//! without post-filters.
//!
//! From av1gpu's CPU reference engine (BSD-2): its forward transform (here also in float), padded
//! source, Hadamard cost proxy, chroma decisions and quantization hook, which the reference engine
//! ([`crate::testsupport::ref_engine`]) shares.
//!
//! **Tiles kept across pictures.** Prediction never crosses a tile and its CDFs start afresh, so a
//! tile whose blocks' decisions and source are unchanged codes to the same coefficients and
//! reconstruction; and to the same bytes while its cdef_idx values and cdef_bits are unchanged too.
//! The C++ copies each coded tile's source, coefficients and reconstruction aside; here the previous
//! picture's record and reconstruction are kept whole (two of each, alternating), and the source is
//! compared with the previous one while it is padded. A tile whose source and block positions are
//! unchanged also keeps its chroma decisions (they read nothing else). The results are the C++'s.
//!
//! [`TxbHook`]: crate::writer::TxbHook
#![allow(clippy::too_many_arguments, clippy::needless_range_loop)]

mod decide;
mod fwd;
#[cfg(target_arch = "aarch64")]
mod fwd_neon;
mod intrabc;
mod palette;
mod quant;
mod rdoq;

pub(crate) use intrabc::hash_picture as hash_ibc_picture;
mod tx_model;
mod tx_weights;
#[cfg(test)]
pub(crate) mod tests;

pub(crate) use decide::{DecOpts, Decider, Src, SrcView, pad_source};
pub(crate) use quant::{HookOpts, QuantHook};

use crate::blockinfo::{bh4, bw4, for_each_txb_ex, has_chroma, max_tx_depth, mi_cols, mi_rows};
use crate::entropy::FrameCdfs;
use crate::tables::{BLOCK_SIZES, DC_PRED, DCT_DCT};
use crate::types::*;
use crate::writer::{
    Error, Extras, LayoutCounts, NoHook, Output, Record, RefPicture, RefSlots, TileSkip, Writer, layout_counts_ex,
    tile_layout_ex,
};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

pub(crate) use crate::enc::fmac;

/// [`fmac`] in float.
#[cfg_attr(target_arch = "aarch64", allow(dead_code))]
#[inline(always)]
pub(crate) fn fmacf(a: f32, b: f32, c: f32) -> f32 {
    #[cfg(target_arch = "aarch64")]
    {
        a.mul_add(b, c)
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        a * b + c
    }
}

/// [`Hybrid::closed_loop`] flags (AV1ENC_HYBRID_GIVEN_CHROMA): the blocks' uv_mode /
/// angle_delta_uv / cfl_alpha_* are decided already.
pub const GIVEN_CHROMA: i32 = 1;

/// A frame of a stream for [`Hybrid::closed_loop_ex`] (av1enc_hybrid_closed_loop_ex).
#[derive(Clone, Copy, Debug)]
pub struct Video<'a> {
    /// the frame's video fields: video, frame_type, ref_slot, refresh_frame_flags,
    /// error_resilient_mode, lf_inter_off, allow_screen_content_tools, cdf_from_ref, mv_precision,
    /// sb128, golden_slot (the rest is ignored). With sb128 the blocks are in 128x128-superblock decode order
    /// ([`crate::motion::Motion::apply_ex`] makes it from a 64x64 one) and the tiles are
    /// [`tile_layout_ex`]'s.
    pub fp: FrameParams,
    /// inter frames: one per block (empty: every block intra). Inter blocks are skip blocks
    /// (tx_depth 0, intra fields 0): they copy LAST_FRAME at their motion vector.
    pub inter: &'a [BlockInter],
    /// inter frames: LAST_FRAME's picture (the decoder's output of the frame in fp.ref_slot)
    pub reference: Option<RefPicture<'a>>,
    /// inter frames with fp.golden_slot: GOLDEN_FRAME's (the output of the frame in its slot)
    pub golden: Option<RefPicture<'a>>,
    /// The source already padded as the closed loop pads it (to whole 64x64s by edge
    /// replication: luma sb_cols * 64 wide and sb_rows * 64 high, chroma half that each way),
    /// for an inter frame's closed loop to read in place of its own copy (the Metal analysis's
    /// source, say). A key frame pads its own, which the next one compares tiles with; the
    /// picture after an inter frame keeps no tiles anyway.
    pub padded: Option<[&'a [u8]; 3]>,
}

/// The closed loop's quantizer: the Metal analysis's dead zone (GpParams zbin) and a rounding
/// offset above its 0.375 (GpParams rnd, the C++'s): 0.6-1.8 % smaller at equal quality on the
/// reference traces (BENCHMARKS, 2026-11-01).
const QUANT_RND: f64 = 0.45;
const QUANT_ZBIN: f64 = 0.656;

fn error(code: i32, msg: &str) -> Error {
    Error {
        code,
        msg: msg.to_string(),
    }
}

/// What a tile was last coded from and to, beyond the previous picture's record and
/// reconstruction.
#[derive(Clone, Debug)]
struct TileMem {
    valid: bool,
    payload_valid: bool,
    /// its chroma decisions were the closed loop's (not given)
    cpu_chroma: bool,
    luma_tx: Vec<u8>,
    payload: Vec<u8>,
    /// its blocks' cdef_idx when `payload` was written
    cdef: Vec<i8>,
    cdef_bits: i32,
    /// `payload` codes use_intrabc (the frame had intra block copies)
    abc: bool,
}

impl Default for TileMem {
    fn default() -> Self {
        TileMem {
            valid: false,
            payload_valid: false,
            cpu_chroma: false,
            luma_tx: Vec::new(),
            payload: Vec::new(),
            cdef: Vec::new(),
            cdef_bits: -1,
            abc: false,
        }
    }
}

/// The hybrid encoder's CPU state (av1enc_hybrid): one per stream. The record, the reconstruction
/// and the padded source of the last closed loop live here until the next call, at stable
/// addresses while the picture's geometry stays the same.
pub struct Hybrid {
    /// the closed loop's rounding offset ([`QUANT_RND`]; the C++ hybrid's 0.375 in its tests)
    quant_rnd: f64,
    /// the closed loop searches the luma tx types even where the analysis gave one (the C++
    /// hybrid keeps them: off in its tests): 1.1-1.5 % smaller (BENCHMARKS, 2026-11-01)
    search_luma_tx: bool,
    /// an inter block's (a motion-searched one's, an intra block copy's) luma tx types are
    /// searched in its inter set, not DCT_DCT only (the C++ hybrid's: off in its tests): 0.1-2.4 %
    /// smaller, most on 720p's inter frames (BENCHMARKS, 2026-11-01)
    search_inter_tx: bool,
    /// key frames search for intra block copies ([`intrabc`]; off by default)
    intrabc: bool,
    /// the next pictures' qindex per 64x64 superblock (raster; empty: `qindex` everywhere), coded
    /// with delta_q_present; not with 128x128 superblocks ([`Hybrid::set_sb_qindex`])
    sb_qindex: Vec<u8>,
    /// the learned tx type pruning's eps ([`tx_model`], [`Hybrid::set_tx_model`]), or None: off
    tx_model_eps: Option<f32>,
    /// [`Hybrid::set_quick_tx_trials`]
    quick_tx_trials: bool,
    /// [`Hybrid::set_tx_types`]
    tx_types: u32,
    /// RDOQ ([`rdoq`], [`Hybrid::set_rdoq`]): its coefficient costs, for the qindex they're of
    rdoq: bool,
    rdoq_trials: bool,
    rdoq_range: u8,
    rdoq_costs: Option<(i32, rdoq::CoeffCosts)>,
    /// palette blocks decided by cost before the closed loop ([`palette`], [`Hybrid::set_palette`];
    /// off by default)
    palette: bool,
    /// the decisions' symbol costs, made on first use
    pal_costs: Option<Box<palette::PalCosts>>,
    /// the decisions' workers' buffers, kept from picture to picture
    pal_pool: Mutex<Vec<palette::PalScratch>>,
    /// this picture's units: (tile, first block, end block, first map byte)
    pal_units: Vec<(u32, u32, u32, u32)>,
    /// the decisions' totals since the encoder was made, and their seconds
    pal_stats: palette::Stats,
    pal_seconds: f64,
    pal_frames: u64,
    /// research: with GA_TX_SAMPLES naming a file, every searched luma tx block's features and
    /// chosen type, appended to it after each picture (examples/prune_train.rs, MODEL=tx)
    tx_samples: Option<(std::sync::Mutex<Vec<u8>>, String)>,
    ibc: intrabc::IntraBc,
    src: Src,
    /// per-tile reuse, for one geometry and quantizer
    mem: Vec<TileMem>,
    /// this picture's tiles taken from the previous one
    reused: Vec<bool>,
    reused_count: u32,
    /// block ranges, tile raster order (this picture's and the previous one's)
    tile_first: Vec<u32>,
    prev_tile_first: Vec<u32>,
    tiles: Option<Tiles>,
    key: [u64; 4],
    reuse: bool,
    /// the records and reconstructions of this picture (`cur`) and the previous one
    recs: [Record; 2],
    outs: [Output; 2],
    cur: usize,
    writer: Writer,
    /// the writes' own state, out while a write job has it ([`Hybrid::write_begin`])
    side: Option<Box<WriteSide>>,
    seconds: [f64; 2],
    threads: usize,
    src_changed: Vec<bool>,
    keep_chroma: Vec<bool>,
    /// the last closed loop coded an inter frame (its tiles aren't kept)
    last_inter: bool,
    /// the last closed loop read its caller's padded source ([`Video::padded`]), not `src` (an
    /// inter frame's, so the next picture keeps no tiles)
    src_given: bool,
    /// the last closed loop wrote its reconstruction into its caller's planes, not `outs`
    recon_given: bool,
    /// video mode: the slots whose saved CDFs the writes begun so far leave them (the closed loop's
    /// cdf_from_ref; the CDFs are the write side's)
    slot_known: u8,
    /// what the closed loop's inter frames take for a reference's saved CDFs: it codes nothing, so
    /// their values don't enter its reconstruction
    cl_cdfs: Box<FrameCdfs>,
}

/// What a picture's write needs besides its record: the writer, its output, and each reference
/// slot's saved CDFs (video mode). A [`WriteJob`] takes it, so a write runs beside the next closed
/// loop.
struct WriteSide {
    writer: Writer,
    obu: Output,
    /// video mode: each reference slot's saved CDFs, from the writes that refreshed it
    slot_cdfs: [Option<Box<FrameCdfs>>; 8],
    /// research (GA_PALETTE_BITS set): every write counts its blocks' bits into `bits`: all
    /// blocks', intra blocks', palette blocks'
    count_bits: bool,
    bits: [f64; 3],
}

/// A picture's write, begun by [`Hybrid::write_begin`] and given back to [`Hybrid::write_end`];
/// [`WriteJob::run`] codes it on any thread, beside the next closed loop.
pub struct WriteJob {
    side: Box<WriteSide>,
    /// the record (taken from its slot in `Hybrid::recs`), or None: written already, in place
    rec: Option<Record>,
    at: usize,
    flags: u32,
    /// coded (or failed) already
    done: Option<Result<(), Error>>,
}

impl WriteJob {
    /// Codes the frame (once; later calls return the first result).
    pub fn run(&mut self) -> Result<(), Error> {
        if let Some(r) = &self.done {
            return r.clone();
        }
        let rec = self.rec.as_mut().expect("a job not yet coded has its record");
        let r = write_record(&mut self.side, rec, None, self.flags).map(|_| ());
        self.done = Some(r.clone());
        r
    }
}

/// Codes `rec` (its fp and cdef_idx set) with `side`'s writer into `side.obu`, its tiles skipped as
/// `skips` says (None: none), and keeps the CDFs of the slots it refreshes. Returns the slots it
/// left with saved CDFs (video mode; all refreshed ones but where none were known).
fn write_record(side: &mut WriteSide, rec: &mut Record, skips: Option<&[TileSkip]>, flags: u32) -> Result<u8, Error> {
    let fp = rec.fp;
    let opts = EncodeOpts {
        flags: ENC_TD | ENC_BITSTREAM_ONLY | flags,
        seq_level_idx: -1,
    };
    // an inter frame reads its reference's saved CDFs (no planes: the bitstream only)
    let inter = fp.frame_type == FRAME_INTER;
    let WriteSide {
        writer,
        obu,
        slot_cdfs,
        count_bits,
        bits,
    } = side;
    let opts = EncodeOpts {
        flags: opts.flags | if *count_bits { crate::writer::ENC_BLOCK_BITS } else { 0 },
        ..opts
    };
    let mut slots: RefSlots = [None; 8];
    if inter {
        let s = (fp.ref_slot & 7) as usize;
        slots[s] = Some(RefPicture {
            cdfs: slot_cdfs[s].as_deref(),
            ..Default::default()
        });
    }
    let extras = Extras {
        tile_skip: skips,
        record_syms: false,
        refs: inter.then_some(&slots),
    };
    writer.encode_with_hook::<NoHook>(rec.as_mut(), &opts, None, &extras, obu)?;
    if *count_bits {
        for k in 0..rec.blocks.len() {
            let v = writer.block_bits(k) as f64;
            bits[0] += v;
            if rec.inter.get(k).is_none_or(|i| i.is_inter == 0) {
                bits[1] += v;
            }
            if rec.palette.get(k).is_some_and(|p| p.size_y != 0) {
                bits[2] += v;
            }
        }
    }
    // the slots it refreshes keep its saved CDFs (none known: a later frame starts afresh)
    let mut known = 0u8;
    if fp.video != 0 {
        let refresh = if inter { fp.refresh_frame_flags } else { 0xFF };
        for (i, s) in slot_cdfs.iter_mut().enumerate() {
            if refresh >> i & 1 != 0 {
                match (&obu.saved_cdfs, s.as_mut()) {
                    (Some(c), Some(b)) => b.clone_from(c),
                    (Some(c), None) => *s = Some(c.clone()),
                    (None, _) => *s = None,
                }
            }
            known |= (s.is_some() as u8) << i;
        }
    }
    Ok(known)
}

impl Default for Hybrid {
    fn default() -> Self {
        Self::new()
    }
}

/// av1g_block equality but for skip and cdef_idx (the C++ compares its decisions with those
/// zeroed).
#[inline]
fn same_decisions(a: &Block, b: &Block) -> bool {
    let (mut a, mut b) = (*a, *b);
    (a.skip, a.cdef_idx, b.skip, b.cdef_idx) = (0, 0, 0, 0);
    a == b
}

/// Whether `n` blocks of `a` from `a0` have the palettes (sizes, colours and maps) of `b`'s from
/// `b0` (a record without palettes has none).
fn same_palettes(a: &Record, a0: usize, b: &Record, b0: usize, n: usize) -> bool {
    if a.palette.is_empty() && b.palette.is_empty() {
        return true;
    }
    let none = BlockPalette::default();
    (0..n).all(|k| {
        let (pa, pb) = (
            a.palette.get(a0 + k).unwrap_or(&none),
            b.palette.get(b0 + k).unwrap_or(&none),
        );
        if (pa.size_y, pa.size_uv, pa.colors) != (pb.size_y, pb.size_uv, pb.colors) {
            return false;
        }
        if pa.size_y == 0 && pa.size_uv == 0 {
            return true;
        }
        let bs = a.blocks[a0 + k].bsize as i32;
        let len = (bw4(bs) * bh4(bs) * 16) as usize * (1 + (pa.size_uv != 0) as usize);
        let (ma, mb) = (pa.map_off as usize, pb.map_off as usize);
        match (a.palette_map.get(ma..ma + len), b.palette_map.get(mb..mb + len)) {
            (Some(x), Some(y)) => x == y,
            _ => false,
        }
    })
}

/// A palette worker's buffers, lent from the pool for one picture's decisions.
struct Lease<'a> {
    pool: &'a Mutex<Vec<palette::PalScratch>>,
    s: Option<palette::PalScratch>,
}

impl Drop for Lease<'_> {
    fn drop(&mut self) {
        if let Some(s) = self.s.take() {
            self.pool.lock().unwrap().push(s);
        }
    }
}

/// A tile's coded area in luma samples: (x0, y0, x1, y1).
fn area(t: &Tiles, i: usize, mi_cols: usize, mi_rows: usize) -> (usize, usize, usize, usize) {
    let (tr, tc) = (i / t.cols as usize, i % t.cols as usize);
    (
        t.mi_col_starts[tc] as usize * 4,
        t.mi_row_starts[tr] as usize * 4,
        (t.mi_col_starts[tc + 1] as usize).min(mi_cols) * 4,
        (t.mi_row_starts[tr + 1] as usize).min(mi_rows) * 4,
    )
}

impl Hybrid {
    /// av1enc_hybrid_create.
    pub fn new() -> Hybrid {
        Hybrid {
            quant_rnd: QUANT_RND,
            search_luma_tx: true,
            search_inter_tx: true,
            intrabc: false,
            sb_qindex: Vec::new(),
            tx_model_eps: None,
            quick_tx_trials: false,
            tx_types: u32::MAX,
            rdoq: false,
            rdoq_trials: false,
            rdoq_range: 0,
            rdoq_costs: None,
            palette: false,
            pal_costs: None,
            pal_pool: Mutex::new(Vec::new()),
            pal_units: Vec::new(),
            pal_stats: palette::Stats::default(),
            pal_seconds: 0.0,
            pal_frames: 0,
            tx_samples: std::env::var("GA_TX_SAMPLES").ok().map(|p| (std::sync::Mutex::new(Vec::new()), p)),
            ibc: intrabc::IntraBc::default(),
            src: Src::default(),
            mem: Vec::new(),
            reused: Vec::new(),
            reused_count: 0,
            tile_first: Vec::new(),
            prev_tile_first: Vec::new(),
            tiles: None,
            key: [0; 4],
            reuse: true,
            recs: Default::default(),
            outs: Default::default(),
            cur: 0,
            writer: Writer::new(),
            side: Some(Box::new(WriteSide {
                writer: Writer::new(),
                obu: Output::default(),
                slot_cdfs: Default::default(),
                count_bits: std::env::var_os("GA_PALETTE_BITS").is_some(),
                bits: [0.0; 3],
            })),
            seconds: [0.0; 2],
            threads: std::thread::available_parallelism().map_or(1, |n| n.get()),
            src_changed: Vec::new(),
            keep_chroma: Vec::new(),
            last_inter: false,
            src_given: false,
            recon_given: false,
            slot_known: 0,
            cl_cdfs: Box::new(FrameCdfs::new(0)),
        }
    }

    /// av1enc_hybrid_closed_loop: the closed loop on blocks the Metal analysis decided (mi_row,
    /// mi_col, bsize, y_mode and angle_delta_y set; the rest is decided here), on 8-bit 4:2:0
    /// planes (tight: Y w x h, U and V ((w + 1) / 2) x ((h + 1) / 2)), with the given tiling.
    /// `luma_tx`: every block's luma tx type from the analysis (the closed loop searches its own; it
    /// keeps these only as the C++ hybrid did, in the tests). `flags`: [`GIVEN_CHROMA`].
    /// On success [`Hybrid::record`] has the record (chroma modes, coefficients, skip flags) and
    /// [`Hybrid::recon`] the exact pre-filter reconstruction.
    pub fn closed_loop(
        &mut self,
        y: &[u8],
        u: &[u8],
        v: &[u8],
        width: u32,
        height: u32,
        blocks: &[Block],
        luma_tx: Option<&[u8]>,
        flags: i32,
        qindex: i32,
        tile_cols_log2: i32,
        tile_rows_log2: i32,
    ) -> Result<(), Error> {
        self.closed_loop_ex(
            y,
            u,
            v,
            width,
            height,
            blocks,
            luma_tx,
            flags,
            qindex,
            tile_cols_log2,
            tile_rows_log2,
            None,
            None,
        )
    }

    /// av1enc_hybrid_closed_loop_ex: [`Hybrid::closed_loop`] for a frame of a stream. An inter
    /// frame's tiles are coded afresh, and the next picture's aren't kept from it.
    ///
    /// `recon_into`: planes (each at least [`Hybrid::recon`]'s size) the reconstruction goes
    /// into as well: an inter frame writes it there in place of its own (no copy, and
    /// [`Hybrid::recon`] gives `None`); any other frame keeps its own, which the next picture's
    /// tiles are kept from, and copies it there. Samples past MiCols * 4 x MiRows * 4 (chroma half)
    /// are left as they were.
    pub fn closed_loop_ex(
        &mut self,
        y: &[u8],
        u: &[u8],
        v: &[u8],
        width: u32,
        height: u32,
        blocks: &[Block],
        luma_tx: Option<&[u8]>,
        flags: i32,
        qindex: i32,
        tile_cols_log2: i32,
        tile_rows_log2: i32,
        video: Option<&Video>,
        recon_into: Option<[&mut [u8]; 3]>,
    ) -> Result<(), Error> {
        let (w, h) = (width as usize, height as usize);
        let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
        let n = blocks.len();
        let (rw, rh) = (mi_cols(width as i32) as usize * 4, mi_rows(height as i32) as usize * 4);
        if n == 0
            || w < 1
            || h < 1
            || w > 65535
            || h > 65535
            || y.len() < w * h
            || u.len() < cw * ch
            || v.len() < cw * ch
            || luma_tx.is_some_and(|l| l.len() < n)
            || video.is_some_and(|v| !v.inter.is_empty() && v.inter.len() != n)
            || recon_into.as_ref().is_some_and(|r| {
                r.iter()
                    .enumerate()
                    .any(|(p, r)| r.len() < (rw >> (p > 0) as usize) * (rh >> (p > 0) as usize))
            })
        {
            return Err(error(ERR_INVALID, "bad arguments"));
        }
        let r = self.run(
            [y, u, v],
            width,
            height,
            blocks,
            luma_tx,
            flags,
            qindex,
            tile_cols_log2,
            tile_rows_log2,
            video,
            recon_into,
        );
        if r.is_err() {
            // the source and the records were overwritten: nothing is kept
            for m in &mut self.mem {
                m.valid = false;
                m.payload_valid = false;
            }
        }
        r
    }

    fn run(
        &mut self,
        planes: [&[u8]; 3],
        width: u32,
        height: u32,
        given: &[Block],
        luma_tx: Option<&[u8]>,
        flags: i32,
        qindex: i32,
        tile_cols_log2: i32,
        tile_rows_log2: i32,
        video: Option<&Video>,
        recon_into: Option<[&mut [u8]; 3]>,
    ) -> Result<(), Error> {
        let t0 = Instant::now();
        let given_chroma = flags & GIVEN_CHROMA != 0;
        let inter_frame = video.is_some_and(|v| v.fp.frame_type == FRAME_INTER);
        if inter_frame || self.last_inter {
            // tiles are kept by their decisions and source, which an inter block's reference
            // isn't part of
            for m in &mut self.mem {
                m.valid = false;
                m.payload_valid = false;
            }
        }
        self.last_inter = inter_frame;
        self.cur ^= 1;
        let cur = self.cur;
        let Hybrid {
            src,
            mem,
            reused,
            reused_count,
            tile_first,
            prev_tile_first,
            tiles: tiles_out,
            key: key_out,
            reuse,
            recs,
            outs,
            writer,
            seconds,
            threads,
            src_changed,
            keep_chroma,
            slot_known,
            cl_cdfs,
            src_given,
            recon_given,
            quant_rnd,
            search_luma_tx,
            search_inter_tx,
            intrabc,
            ibc,
            sb_qindex,
            tx_model_eps,
            quick_tx_trials,
            tx_types,
            tx_samples,
            rdoq,
            rdoq_trials,
            rdoq_range,
            rdoq_costs,
            palette: pal_on,
            pal_costs,
            pal_pool,
            pal_units,
            pal_stats,
            pal_seconds,
            pal_frames,
            ..
        } = self;
        let inter: &[BlockInter] = video.map_or(&[], |v| v.inter);
        let reuse = *reuse;
        let [r0, r1] = recs;
        let (rec, prev) = if cur == 0 { (r0, &*r1) } else { (r1, &*r0) };
        let [o0, o1] = outs;
        let (out, prev_out) = if cur == 0 { (o0, &*o1) } else { (o1, &*o0) };
        out.clear();
        let (w, h) = (width as usize, height as usize);
        rec.fp = FrameParams {
            version: DECISIONS_VERSION,
            width,
            height,
            base_q_idx: qindex as u8,
            tile_cols_log2: tile_cols_log2 as i8,
            tile_rows_log2: tile_rows_log2 as i8,
            ..FrameParams::default()
        };
        if let Some(v) = video {
            let f = &mut rec.fp;
            (f.video, f.frame_type, f.ref_slot) = (v.fp.video, v.fp.frame_type, v.fp.ref_slot);
            (f.refresh_frame_flags, f.error_resilient_mode) = (v.fp.refresh_frame_flags, v.fp.error_resilient_mode);
            (f.lf_inter_off, f.allow_screen_content_tools) = (v.fp.lf_inter_off, v.fp.allow_screen_content_tools);
            (f.mv_precision, f.sb128) = (v.fp.mv_precision, v.fp.sb128);
            (f.stream_width, f.stream_height) = (v.fp.stream_width, v.fp.stream_height);
            f.golden_slot = if v.fp.frame_type == FRAME_INTER { v.fp.golden_slot } else { 0 };
            // from the reference's saved CDFs, where the slot has them
            f.cdf_from_ref = (v.fp.cdf_from_ref != 0 && *slot_known >> (v.fp.ref_slot & 7) & 1 != 0) as u8;
        }
        rec.inter.clear();
        rec.inter.extend_from_slice(inter);
        let (mc, mr) = (mi_cols(width as i32), mi_rows(height as i32));
        let (sb_cols, sb_rows) = (((mc + 15) >> 4) as usize, ((mr + 15) >> 4) as usize);
        let (mcu, mru) = (mc as usize, mr as usize);
        // rows of the source on several threads: a 5K picture is 22 MB
        let pad_threads = ((sb_cols * sb_rows * 6144) >> 20).clamp(1, 8).min(*threads);
        let sb128 = rec.fp.sb128 != 0;
        let Ok(tiles) = tile_layout_ex(width, height, tile_cols_log2, tile_rows_log2, sb128) else {
            pad_source(planes, w, h, sb_cols, sb_rows, 3, src, pad_threads, None);
            return Err(error(ERR_INVALID, "tiling"));
        };
        let ntiles = (tiles.rows * tiles.cols) as usize;
        let key = [
            width as u64 | (sb128 as u64) << 32,
            height as u64,
            ((tile_cols_log2 as u32 as u64) << 32) | tile_rows_log2 as u32 as u64,
            qindex as i64 as u64,
        ];
        if key != *key_out || mem.len() != ntiles {
            mem.clear();
            mem.resize(ntiles, TileMem::default());
            *key_out = key;
        }
        let compare = reuse && mem.iter().any(|m| m.valid);
        src_changed.clear();
        src_changed.resize(ntiles, false);
        let cmp = compare.then(|| decide::Compare {
            tiles: &tiles,
            mi_cols: mcu,
            mi_rows: mru,
            changed: &mut src_changed[..],
        });
        let theirs = video.and_then(|v| v.padded).filter(|p| {
            inter_frame
                && !compare
                && (0..3).all(|pl| {
                    let sub = (pl > 0) as usize;
                    p[pl].len() >= ((sb_cols * 64) >> sub) * ((sb_rows * 64) >> sub)
                })
        });
        *src_given = theirs.is_some();
        let src: SrcView = match theirs {
            Some(p) => SrcView {
                stride: [sb_cols * 64, (sb_cols * 64) >> 1, (sb_cols * 64) >> 1],
                p,
            },
            None => {
                pad_source(planes, w, h, sb_cols, sb_rows, 3, src, pad_threads, cmp);
                src.view()
            }
        };
        // a key frame's intra block copies: from here on its blocks, inter entries and luma tx
        // types are the search's (a copy reads only its tile, so a tile is kept as before, when its
        // inter entries are the same too)
        // (a picture whose source and blocks are the last one's: the last search's answer)
        let searches = *intrabc && !inter_frame && inter.is_empty();
        if !searches {
            ibc.forget();
        }
        let abc = searches
            && match ibc.again(width, height, sb128, &tiles, given, luma_tx, qindex) {
                Some(copied) if compare && !src_changed.iter().any(|&c| c) => copied,
                _ => ibc.search(
                    src, width, height, sb128, false, &tiles, given, luma_tx, qindex, *threads,
                ),
            };
        ibc.clear_hashes();
        let (given, inter, luma_tx) = if abc {
            (&ibc.blocks[..], &ibc.inter[..], luma_tx.map(|_| &ibc.tx[..]))
        } else {
            (given, inter, luma_tx)
        };
        let is_inter = |b: usize| inter.get(b).is_some_and(|i| i.is_inter != 0);
        if abc {
            (rec.fp.allow_intrabc, rec.fp.allow_screen_content_tools) = (1, 1);
            rec.inter.clear();
            rec.inter.extend_from_slice(inter);
        }

        rec.blocks.clear();
        rec.blocks.extend_from_slice(given);
        let n = given.len();
        // an inter block's skip is given (a copy: no residual); elsewhere it's the closed loop's
        for (i, b) in rec.blocks.iter_mut().enumerate() {
            b.skip = if is_inter(i) { b.skip.min(1) } else { 0 };
        }
        if !given_chroma {
            // the chroma decisions read the blocks' areas: no block outside the padded source (an
            // inter block, which has none, may be larger than 64x64 with 128x128 superblocks)
            for (i, b) in rec.blocks.iter().enumerate() {
                let bs = b.bsize as i32;
                if bs >= BLOCK_SIZES
                    || ((bw4(bs) > 16 || bh4(bs) > 16) && !(sb128 && is_inter(i)))
                    || b.mi_row as i32 >= mr
                    || b.mi_col as i32 >= mc
                    || b.mi_row as usize + bh4(bs) as usize > sb_rows * 16
                    || b.mi_col as usize + bw4(bs) as usize > sb_cols * 16
                {
                    return Err(error(ERR_INVALID, "layout"));
                }
            }
        }
        // every tile's blocks: those inside it, contiguous in tile order
        tile_first.clear();
        let mut c = 0usize;
        for tr in 0..tiles.rows as usize {
            for tc in 0..tiles.cols as usize {
                tile_first.push(c as u32);
                let (r0, r1) = (tiles.mi_row_starts[tr], tiles.mi_row_starts[tr + 1]);
                let (c0, c1) = (tiles.mi_col_starts[tc], tiles.mi_col_starts[tc + 1]);
                while c < n {
                    let b = &rec.blocks[c];
                    if (b.mi_row as u32) < r0
                        || b.mi_row as u32 >= r1
                        || (b.mi_col as u32) < c0
                        || b.mi_col as u32 >= c1
                    {
                        break;
                    }
                    c += 1;
                }
            }
        }
        tile_first.push(c as u32);
        let have_prev = compare && prev_tile_first.len() == ntiles + 1;
        let prange = |i: usize| (prev_tile_first[i] as usize, prev_tile_first[i + 1] as usize);
        let range = |i: usize| (tile_first[i] as usize, tile_first[i + 1] as usize);

        // ---- chroma ----
        // each block's qindex: its 64x64's from the map, if there is one (delta-q), else the frame's
        let qi = qindex as u8;
        let sb_cols64 = (mi_cols(width as i32) as usize).div_ceil(16);
        let qmap: &[u8] = if rec.fp.sb128 == 0 && sb_qindex.len() == sb_cols64 * (mi_rows(height as i32) as usize).div_ceil(16) {
            (rec.fp.delta_q_present, rec.fp.delta_q_res) = (1, 0);
            &sb_qindex[..]
        } else {
            &[]
        };
        let q_of = |b: &Block| -> u8 {
            if qmap.is_empty() { qi } else { qmap[(b.mi_row as usize >> 4) * sb_cols64 + (b.mi_col as usize >> 4)].max(1) }
        };
        if given_chroma {
            // the GPU decided chroma: only the fields the closed loop sets
            for b in rec.blocks.iter_mut() {
                (b.tx_depth, b.sb_qindex) = (0, q_of(b));
            }
        } else {
            // A tile whose source and block positions are unchanged keeps its chroma decisions:
            // they read only those.
            keep_chroma.clear();
            keep_chroma.resize(ntiles, false);
            if have_prev {
                for i in 0..ntiles {
                    let m = &mem[i];
                    let ((b0, b1), (p0, p1)) = (range(i), prange(i));
                    keep_chroma[i] = m.valid
                        && m.cpu_chroma
                        && !src_changed[i]
                        && b1 - b0 == p1 - p0
                        && rec.blocks[b0..b1]
                            .iter()
                            .zip(&prev.blocks[p0..p1])
                            .all(|(a, b)| (a.mi_row, a.mi_col, a.bsize) == (b.mi_row, b.mi_col, b.bsize));
                    if keep_chroma[i] {
                        for (b, p) in rec.blocks[b0..b1].iter_mut().zip(&prev.blocks[p0..p1]) {
                            (b.skip, b.tx_depth, b.sb_qindex) = (0, 0, q_of(b));
                            (b.uv_mode, b.angle_delta_uv) = (p.uv_mode, p.angle_delta_uv);
                            (b.cfl_alpha_u, b.cfl_alpha_v) = (p.cfl_alpha_u, p.cfl_alpha_v);
                        }
                    }
                }
            }
            // the others from the source, on every core (each block's decision is its own), 64
            // blocks at a time
            // a block's index from its address (inter blocks get no chroma decision)
            let (base, size) = (rec.blocks.as_ptr() as usize, size_of::<Block>());
            let mut chunks: Vec<&mut [Block]> = Vec::new();
            let mut rest: &mut [Block] = &mut rec.blocks;
            let mut at = 0usize;
            for i in 0..ntiles {
                if !keep_chroma[i] {
                    let (b0, b1) = range(i);
                    chunks.extend(take_range(&mut rest, &mut at, b0, b1).chunks_mut(64));
                }
            }
            chunks.extend(take_range(&mut rest, &mut at, tile_first[ntiles] as usize, n).chunks_mut(64));
            let step = crate::dsp::ac_q(qindex) as f64 / 8.0;
            let dec = Decider::new(src, hybrid_dec_opts(), mc, mr, false, step, step);
            par_for(
                *threads,
                &mut chunks,
                || dec.clone(),
                |d, chunk| {
                    for b in chunk.iter_mut() {
                        let (mut tc, mut tr) = (0usize, 0usize); // the block's tile, for edge availability
                        while tc + 1 < tiles.cols as usize && tiles.mi_col_starts[tc + 1] <= b.mi_col as u32 {
                            tc += 1;
                        }
                        while tr + 1 < tiles.rows as usize && tiles.mi_row_starts[tr + 1] <= b.mi_row as u32 {
                            tr += 1;
                        }
                        d.tx0 = tiles.mi_col_starts[tc] as i32 * 4;
                        d.ty0 = tiles.mi_row_starts[tr] as i32 * 4;
                        let inter_block = is_inter((b as *const Block as usize - base) / size);
                        (b.tx_depth, b.sb_qindex) = (0, q_of(b));
                        (b.uv_mode, b.angle_delta_uv, b.cfl_alpha_u, b.cfl_alpha_v) = (DC_PRED as u8, 0, 0, 0);
                        let (bs, r, c) = (b.bsize as i32, b.mi_row as i32, b.mi_col as i32);
                        if !inter_block && has_chroma(bs, r, c, false) {
                            d.best_chroma(c * 4, r * 4, bs, b);
                        }
                    }
                },
            );
        }
        if layout_tiles(rec, tile_first, (n / 2048).clamp(1, *threads)).is_err() {
            return Err(error(ERR_INVALID, "layout"));
        }
        if let Some(l) = luma_tx {
            // one luma tx block per block at tx_depth 0
            for b in 0..n {
                let (t0, t1) = (rec.block_txb[b] as usize, rec.block_txb[b + 1] as usize);
                for t in &mut rec.txb[t0..t1] {
                    if t.plane == 0 {
                        t.tx_type = l[b];
                    }
                }
            }
        }
        let t1 = Instant::now();
        let mut hook = QuantHook::new(
            src,
            HookOpts {
                tx_types: true,
                reduced_tx_set: false,
                given_luma_tx: (luma_tx.is_some() && !*search_luma_tx) as i32,
                rnd: *quant_rnd,
                zbin: QUANT_ZBIN,
                double_fwd: false,
                inter_rd_skip: true,
                inter_tx_types: *search_inter_tx,
            },
        );
        // (recording samples, the search tries every type: they're what it chooses unpruned)
        hook.tx_model = tx_model_eps
            .filter(|_| tx_weights::TX_WEIGHTS.len() == tx_model::TX_FLOATS && tx_samples.is_none())
            .map(|e| (&tx_weights::TX_WEIGHTS[..], e));
        hook.collect = tx_samples.as_ref().map(|(m, _)| m);
        (hook.td_dist, hook.dct_zero_stops) = (*quick_tx_trials, *quick_tx_trials);
        hook.tx_types = *tx_types;
        if *rdoq {
            if rdoq_costs.as_ref().is_none_or(|(q, _)| *q != qindex) {
                *rdoq_costs = Some((qindex, rdoq::CoeffCosts::new(qindex)));
            }
            hook.rdoq = rdoq_costs.as_ref().map(|(_, c)| c);
            hook.rdoq_trials = *rdoq_trials;
            hook.rdoq_range = *rdoq_range;
        }

        // ---- palette blocks, by cost ----
        if *pal_on {
            let tp = Instant::now();
            let costs = &**pal_costs.get_or_insert_with(palette::PalCosts::new);
            let sb_shift = if sb128 { 5 } else { 4 };
            pal_units.clear();
            let mut map_len = 0usize;
            for i in 0..ntiles {
                let (b0, b1) = range(i);
                let mut k = b0;
                while k < b1 {
                    let row = rec.blocks[k].mi_row >> sb_shift;
                    let (start, base) = (k, map_len);
                    while k < b1 && rec.blocks[k].mi_row >> sb_shift == row {
                        map_len += palette::slot(&rec.blocks[k], is_inter(k)).unwrap_or(0);
                        k += 1;
                    }
                    pal_units.push((i as u32, start as u32, k as u32, base as u32));
                }
            }
            rec.palette.clear();
            rec.palette.resize(n, BlockPalette::default());
            // (only palette blocks' slots are read: the rest needn't be cleared)
            rec.palette_map.resize(map_len, 0);
            let cx = palette::Ctx {
                hook: &hook,
                src,
                costs,
                inter_frame,
                mi_rows: mr,
                mi_cols: mc,
                width,
                height,
                sb_mi: 1 << sb_shift,
                qindex: qmap.is_empty().then_some(qindex),
            };
            let mut units: Vec<palette::Unit> = Vec::with_capacity(pal_units.len());
            {
                let (mut bl, mut pl, mut ml): (&mut [Block], &mut [BlockPalette], &mut [u8]) =
                    (&mut rec.blocks, &mut rec.palette, &mut rec.palette_map);
                let (mut bat, mut pat, mut mat) = (0usize, 0usize, 0usize);
                for (j, &(i, b0, b1, base)) in pal_units.iter().enumerate() {
                    let (b0, b1) = (b0 as usize, b1 as usize);
                    let end = pal_units.get(j + 1).map_or(map_len, |u| u.3 as usize);
                    let (tr, tc) = (i as usize / tiles.cols as usize, i as usize % tiles.cols as usize);
                    let r0 = (given[b0].mi_row as i32 >> sb_shift) << sb_shift;
                    units.push(palette::Unit {
                        blocks: take_range(&mut bl, &mut bat, b0, b1),
                        inter: if inter.is_empty() { &[] } else { &inter[b0..b1] },
                        pal: take_range(&mut pl, &mut pat, b0, b1),
                        map: take_range(&mut ml, &mut mat, base as usize, end),
                        map_base: base,
                        c0: tiles.mi_col_starts[tc] as i32,
                        c1: (tiles.mi_col_starts[tc + 1] as i32).min(mc),
                        tile_r0: tiles.mi_row_starts[tr] as i32,
                        r0,
                        stats: palette::Stats::default(),
                    });
                }
            }
            let pool = &*pal_pool;
            par_for(
                *threads,
                &mut units,
                || Lease {
                    pool,
                    s: Some(pool.lock().unwrap().pop().unwrap_or_else(palette::PalScratch::new)),
                },
                |l, u| palette::decide_unit(&cx, l.s.as_mut().expect("leased"), u),
            );
            let mut st = palette::Stats::default();
            for u in &units {
                st.add(&u.stats);
            }
            drop(units);
            pal_stats.add(&st);
            if st.chosen == 0 {
                rec.palette.clear();
                rec.palette_map.clear();
            } else {
                rec.fp.allow_screen_content_tools = 1;
            }
            *pal_seconds += tp.elapsed().as_secs_f64();
            *pal_frames += 1;
        } else {
            rec.palette.clear();
            rec.palette_map.clear();
        }

        // ---- tiles unchanged since they were last coded keep their closed loop ----
        *tiles_out = Some(tiles);
        reused.clear();
        reused.resize(ntiles, false);
        *reused_count = 0;
        if reuse && have_prev && tile_first[ntiles] as usize == n {
            let pn_txb = prev.txb.len();
            // per tile: its blocks' inter entries (intra block copies) are the previous picture's
            let entry = |r: &Record, k: usize| r.inter.get(k).copied().unwrap_or_default();
            let same_inter: Vec<bool> = (0..ntiles)
                .map(|i| {
                    let ((b0, b1), (p0, p1)) = (range(i), prange(i));
                    b1 - b0 == p1 - p0
                        && (0..b1 - b0).all(|k| entry(rec, b0 + k) == entry(prev, p0 + k))
                        && same_palettes(rec, b0, prev, p0, b1 - b0)
                })
                .collect();
            let mut parts = split_tiles(rec, tile_first);
            par_for(
                (n / 2048).clamp(1, *threads),
                &mut parts,
                || (),
                |_, t| {
                    let i = t.i;
                    let m = &mem[i];
                    if !m.valid || src_changed[i] || !same_inter[i] {
                        return;
                    }
                    let (p0, p1) = prange(i);
                    let nb = t.blocks.len();
                    if nb != p1 - p0
                        || !t
                            .blocks
                            .iter()
                            .zip(&prev.blocks[p0..p1])
                            .all(|(a, b)| same_decisions(a, b))
                    {
                        return;
                    }
                    if let Some(l) = luma_tx
                        && (m.luma_tx.len() < nb || l[t.b0..t.b0 + nb] != m.luma_tx[..nb])
                    {
                        return;
                    }
                    // the tile's coefficients, tx types and skip flags as they were
                    let (q0, q1) = (prev.block_txb[p0] as usize, prev.block_txb[p1] as usize);
                    if t.txb.len() != q1 - q0 {
                        return;
                    }
                    let d0 = if q0 < q1 { prev.txb[q0].coeff_off as usize } else { 0 };
                    let d1 = if q1 < pn_txb {
                        prev.txb[q1].coeff_off as usize
                    } else {
                        prev.coeffs.len()
                    };
                    if t.coeffs.len() != d1 - d0 {
                        return;
                    }
                    for (x, p) in t.txb.iter_mut().zip(&prev.txb[q0..q1]) {
                        (x.tx_type, x.eob) = (p.tx_type, p.eob);
                    }
                    t.coeffs.copy_from_slice(&prev.coeffs[d0..d1]);
                    for (b, p) in t.blocks.iter_mut().zip(&prev.blocks[p0..p1]) {
                        b.skip = p.skip;
                    }
                    t.kept = true;
                },
            );
            for t in &parts {
                reused[t.i] = t.kept;
                *reused_count += t.kept as u32;
            }
        }
        let skips: Vec<TileSkip> = reused.iter().map(|&skip| TileSkip { skip, payload: None }).collect();
        // (its coding would be discarded: write_ex codes the frame once the filters are chosen)
        let opts = EncodeOpts {
            flags: ENC_FIX_RANGE | ENC_PREFILTER_RECON | crate::writer::ENC_NO_CODE,
            seq_level_idx: -1,
        };
        let mut slots: RefSlots = [None; 8];
        if let Some(v) = video
            && inter_frame
        {
            let s = (v.fp.ref_slot & 7) as usize;
            slots[s] = v.reference.map(|r| RefPicture {
                cdfs: (*slot_known >> s & 1 != 0).then_some(&**cl_cdfs),
                ..r
            });
            let g = (v.fp.golden_slot as usize).wrapping_sub(1) & 7;
            if v.fp.golden_slot != 0 && g != s {
                slots[g] = v.golden;
            }
        }
        let extras = Extras {
            tile_skip: Some(&skips),
            record_syms: false,
            refs: inter_frame.then_some(&slots),
        };
        // an inter frame's reconstruction straight into its caller's planes (no tile is kept from
        // it); any other's kept here for the next picture's tiles, and copied there
        let (direct, copy_to) = if inter_frame {
            (recon_into, None)
        } else {
            (None, recon_into)
        };
        *recon_given = direct.is_some();
        writer.encode_into(rec.as_mut(), &opts, Some(&hook), &extras, direct, out)?;
        if *reused_count > 0 {
            // kept tiles' reconstruction, into the picture's: by plane and tile row
            let recon_w = out.recon_w;
            let mut rows: Vec<(usize, usize, &mut [u8])> = Vec::new();
            for (p, plane) in out.recon.iter_mut().enumerate() {
                let sub = (p > 0) as usize;
                let stride = recon_w[p] as usize;
                let mut rest: &mut [u8] = plane;
                for tr in 0..tiles.rows as usize {
                    let y0 = (tiles.mi_row_starts[tr] as usize * 4) >> sub;
                    let y1 = ((tiles.mi_row_starts[tr + 1] as usize).min(mru) * 4) >> sub;
                    let (part, r) = core::mem::take(&mut rest).split_at_mut((y1 - y0) * stride);
                    rest = r;
                    rows.push((p, tr, part));
                }
            }
            let nthreads = (*reused_count as usize).min(rows.len()).clamp(1, *threads);
            par_for(
                nthreads,
                &mut rows,
                || (),
                |_, (p, tr, part)| {
                    let (p, tr) = (*p, *tr);
                    let sub = (p > 0) as usize;
                    let stride = recon_w[p] as usize;
                    let y0 = (tiles.mi_row_starts[tr] as usize * 4) >> sub;
                    for tc in 0..tiles.cols as usize {
                        let i = tr * tiles.cols as usize + tc;
                        if !reused[i] {
                            continue;
                        }
                        let (x0, _, x1, _) = area(&tiles, i, mcu, mru);
                        let (px0, pw) = (x0 >> sub, (x1 - x0) >> sub);
                        for (y, row) in part.chunks_mut(stride).enumerate() {
                            let o = (y0 + y) * stride + px0;
                            row[px0..px0 + pw].copy_from_slice(&prev_out.recon[p][o..o + pw]);
                        }
                    }
                },
            );
        }
        for i in 0..ntiles {
            if reused[i] {
                continue;
            }
            let (b0, b1) = range(i);
            for b in b0..b1 {
                // skip flags change no reconstruction before the filters
                let (t0, t1) = (rec.block_txb[b] as usize, rec.block_txb[b + 1] as usize);
                if rec.txb[t0..t1].iter().all(|t| t.eob == 0) {
                    rec.blocks[b].skip = 1;
                }
            }
            // remember it
            let m = &mut mem[i];
            m.luma_tx.clear();
            if let Some(l) = luma_tx {
                m.luma_tx.extend_from_slice(&l[b0..b1]);
            }
            m.valid = true;
            m.payload_valid = false;
            m.cpu_chroma = !given_chroma;
        }
        if let Some(to) = copy_to {
            for (to, from) in to.into_iter().zip(&out.recon) {
                to[..from.len()].copy_from_slice(from);
            }
        }
        prev_tile_first.clear();
        prev_tile_first.extend_from_slice(tile_first);
        let t2 = Instant::now();
        *seconds = [(t1 - t0).as_secs_f64(), (t2 - t1).as_secs_f64()];
        if let Some((m, path)) = tx_samples.as_ref() {
            let mut v = m.lock().unwrap();
            if !v.is_empty() {
                use std::io::Write;
                if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
                    let _ = f.write_all(&v);
                }
                v.clear();
            }
        }
        Ok(())
    }

    /// av1enc_hybrid_write: the bitstream of the last closed loop's picture with the post-filter
    /// parameters chosen (`fp`) and every 64x64's cdef_idx (`sb_cdef`, raster, `sb_cols` wide; -1
    /// as 0; `None`: all 0): [TD,] sequence header and frame. A tile whose closed loop was kept, and
    /// whose cdef_idx values and cdef_bits are as last written, keeps its bytes. The bytes live
    /// here until the next write.
    pub fn write(&mut self, fp: &FrameParams, sb_cdef: Option<&[i8]>, sb_cols: usize) -> Result<&[u8], Error> {
        self.write_ex(fp, sb_cdef, sb_cols, 0)
    }

    /// av1enc_hybrid_write_ex: [`Hybrid::write`] with encode flags: [`ENC_NO_SEQ_HEADER`] (a later
    /// frame of a stream: no sequence header) or 0.
    pub fn write_ex(
        &mut self,
        fp: &FrameParams,
        sb_cdef: Option<&[i8]>,
        sb_cols: usize,
        flags: u32,
    ) -> Result<&[u8], Error> {
        let mut job = self.write_begin(fp, sb_cdef, sb_cols, flags)?;
        let r = job.run();
        self.write_end(job)?;
        r?;
        Ok(&self.side.as_ref().expect("given back").obu.obu)
    }

    /// av1enc_hybrid_write_begin: [`Hybrid::write_ex`]'s frame as a job: [`WriteJob::run`] codes it
    /// on any thread while the next closed loop runs, and [`Hybrid::write_end`] takes it back
    /// (before the closed loop after that one, which reuses its record, and before the next write).
    /// Where the closed loop kept tiles, which the write reads and updates, it's written here and
    /// the job is done already.
    pub fn write_begin(
        &mut self,
        fp: &FrameParams,
        sb_cdef: Option<&[i8]>,
        sb_cols: usize,
        flags: u32,
    ) -> Result<Box<WriteJob>, Error> {
        if flags & !ENC_NO_SEQ_HEADER != 0 {
            return Err(error(ERR_INVALID, "write flags: ENC_NO_SEQ_HEADER or 0"));
        }
        if self.side.is_none() {
            return Err(error(ERR_INVALID, "a write is running: write_end it first"));
        }
        let Hybrid {
            mem,
            reused,
            tile_first,
            reuse,
            recs,
            cur,
            side,
            slot_known,
            ..
        } = self;
        let rec = &mut recs[*cur];
        // a frame with intra block copies stays one: no post-filters, every cdef_idx 0
        let abc = rec.fp.allow_intrabc != 0;
        rec.fp = *fp;
        if rec.palette.iter().any(|p| p.size_y != 0 || p.size_uv != 0) {
            // palette blocks need screen content tools (a key frame's are otherwise off)
            rec.fp.allow_screen_content_tools = 1;
        }
        if abc {
            (rec.fp.allow_intrabc, rec.fp.allow_screen_content_tools) = (1, 1);
            rec.fp.loop_filter_level = [0; 4];
            (rec.fp.cdef_bits, rec.fp.loop_filter_sharpness) = (0, 0);
        }
        let sb_cdef = sb_cdef.filter(|_| !abc);
        for k in &mut rec.blocks {
            let c = match sb_cdef {
                Some(s) => match s.get((k.mi_row as usize >> 4) * sb_cols + (k.mi_col as usize >> 4)) {
                    Some(&c) => c,
                    None => return Err(error(ERR_INVALID, "sb_cdef doesn't cover the picture")),
                },
                None => 0,
            };
            k.cdef_idx = c.max(0);
        }
        let mut side = side.take().expect("checked");
        // An inter frame keeps no tile from the last picture (its closed loop dropped them), and
        // what the write would note for the next picture's tiles the next closed loop drops too
        // (`last_inter`): so it touches nothing the next closed loop does, and runs beside it.
        // Likewise where no tile is kept at all. The slots it refreshes will have its CDFs: every
        // tile is coded, the context tile too.
        if fp.frame_type == FRAME_INTER || !mem.iter().any(|m| m.valid) {
            if fp.video != 0 {
                *slot_known |= if fp.frame_type == FRAME_INTER { fp.refresh_frame_flags } else { 0xFF };
            }
            return Ok(Box::new(WriteJob {
                side,
                rec: Some(std::mem::take(rec)),
                at: *cur,
                flags,
                done: None,
            }));
        }
        // a reused tile keeps its bytes while its cdef_idx values and cdef_bits are as they were coded
        let ntiles = mem.len();
        let cdef_bits = if fp.enable_cdef != 0 { fp.cdef_bits as i32 } else { -1 };
        let skips: Vec<TileSkip> = (0..ntiles)
            .map(|i| {
                let m = &mem[i];
                let skip = *reuse
                    && reused.get(i).is_some_and(|&r| r)
                    && m.payload_valid
                    && m.cdef_bits == cdef_bits
                    && m.abc == abc
                    && tile_first.len() > i + 1
                    && {
                        let (b0, b1) = (tile_first[i] as usize, tile_first[i + 1] as usize);
                        m.cdef.len() == b1 - b0 && rec.blocks[b0..b1].iter().zip(&m.cdef).all(|(b, &c)| b.cdef_idx == c)
                    };
                TileSkip {
                    skip,
                    payload: Some(&m.payload),
                }
            })
            .collect();
        let r = write_record(&mut side, rec, Some(&skips), flags);
        if let Ok(known) = r {
            if fp.video != 0 {
                *slot_known = known;
            }
            let skipped: Vec<bool> = skips.iter().map(|s| s.skip).collect();
            let payloads = side.writer.tile_payloads();
            for i in 0..ntiles.min(payloads.len()) {
                let m = &mut mem[i];
                if skipped[i] || !m.valid {
                    continue;
                }
                let (b0, b1) = (tile_first[i] as usize, tile_first[i + 1] as usize);
                m.payload.clear();
                m.payload.extend_from_slice(&payloads[i]);
                m.cdef.clear();
                m.cdef.extend(rec.blocks[b0..b1].iter().map(|b| b.cdef_idx));
                m.cdef_bits = cdef_bits;
                m.abc = abc;
                m.payload_valid = true;
            }
        }
        Ok(Box::new(WriteJob {
            side,
            rec: None,
            at: *cur,
            flags,
            done: Some(r.map(|_| ())),
        }))
    }

    /// av1enc_hybrid_write_end: takes back a job [`Hybrid::write_begin`] gave (run or not: an unrun
    /// one is run here) and its record; its result, the bitstream in [`Hybrid::written`].
    pub fn write_end(&mut self, mut job: Box<WriteJob>) -> Result<(), Error> {
        let r = job.run();
        let WriteJob { side, rec, at, .. } = *job;
        if let Some(rec) = rec {
            self.recs[at] = rec;
        }
        self.side = Some(side);
        if r.is_err() {
            // the slots' CDFs are unknown after a failed write
            self.slot_known = 0;
            if let Some(s) = &mut self.side {
                s.slot_cdfs = Default::default();
            }
        }
        r
    }

    /// The last write's bitstream (empty while a write job runs).
    pub fn written(&self) -> &[u8] {
        self.side.as_ref().map_or(&[], |s| &s.obu.obu)
    }

    /// The bitstream a job coded.
    pub fn job_bitstream(job: &WriteJob) -> &[u8] {
        &job.side.obu.obu
    }

    /// av1enc_hybrid_set_reuse: keep unchanged tiles' closed loop and bitstream from picture to
    /// picture (on by default).
    /// The C++ hybrid's closed loop, for the differential tests: its rounding offset (0.375),
    /// and the analysis's luma tx types kept.
    #[cfg(test)]
    pub(crate) fn as_cpp(&mut self) {
        self.quant_rnd = 0.375;
        self.search_luma_tx = false;
        self.search_inter_tx = false;
    }

    /// av1enc_hybrid_set_intrabc: key frames search for intra block copies (off by default): a
    /// frame where blocks copy has no post-filters (the record's fp.allow_intrabc says so).
    pub fn set_intrabc(&mut self, on: bool) {
        self.intrabc = on;
    }

    /// av1enc_hybrid_set_palette: intra blocks may be palette blocks (luma), decided by cost before
    /// the closed loop ([`palette`]; off by default: the output is as without it).
    pub fn set_palette(&mut self, on: bool) {
        self.palette = on;
    }

    /// av1enc_hybrid_palette_stats: the palette decisions' totals since the encoder was made:
    /// pictures decided, intra blocks that may be palettes, of them tried (past the gate), palette
    /// blocks, the eligible blocks' area and the palette blocks' (samples), the decisions' seconds;
    /// then from writes, with GA_PALETTE_BITS set: all blocks' bits, intra blocks', palette
    /// blocks'; then the palette blocks past the picture's right or bottom edge.
    pub fn palette_stats(&self) -> [f64; 11] {
        let s = &self.pal_stats;
        let b = self.side.as_ref().map_or([0.0; 3], |w| w.bits);
        [
            self.pal_frames as f64,
            s.eligible as f64,
            s.tried as f64,
            s.chosen as f64,
            s.eligible_area as f64,
            s.chosen_area as f64,
            self.pal_seconds,
            b[0],
            b[1],
            b[2],
            s.at_edge as f64,
        ]
    }

    /// av1enc_hybrid_set_tx_search: the closed loop searches intra blocks' luma tx types (else keeps
    /// the analysis's, DCT_DCT without them) and inter blocks' (else DCT_DCT); both on by default.
    pub fn set_tx_search(&mut self, luma: bool, inter: bool) {
        (self.search_luma_tx, self.search_inter_tx) = (luma, inter);
    }

    /// av1enc_hybrid_use_ibc_hashes: the next call's intra block copy search takes its hashes from
    /// `v` (intrabc::hash_picture of that call's picture, `width` x `height`), which gets the buffer
    /// they replace.
    pub fn use_ibc_hashes(&mut self, v: &mut Vec<u32>, width: u32, height: u32) {
        self.ibc.use_hashes(v, width, height);
    }

    /// av1enc_hybrid_set_rdoq: the closed loop's levels optimized by rate and distortion ([`rdoq`])
    /// after the dead-zone quantizer (off by default).
    /// With `trials`, luma tx type trials optimize their levels before they're compared; only tx
    /// blocks whose source spans at least `min_range` values are optimized (0: all).
    pub fn set_rdoq(&mut self, on: bool, trials: bool, min_range: u8) {
        (self.rdoq, self.rdoq_trials, self.rdoq_range) = (on, trials, min_range);
    }

    /// av1enc_hybrid_set_tx_model: the luma tx type search tries only the types the learned model
    /// ([`tx_model`]) keeps, until all but `eps` of their probability (and DCT_DCT); eps < 0: off.
    /// Without shipped weights it stays off.
    pub fn set_tx_model(&mut self, eps: f32) {
        self.tx_model_eps = (eps >= 0.0).then_some(eps);
    }

    /// av1enc_hybrid_set_quick_tx_trials: the luma tx type search measures each compared type's
    /// distortion in the transform domain (no inverse transform), and stops at DCT_DCT, the first
    /// type it tries, when that codes nothing. Off: the exact reconstruction's SSE, every type.
    pub fn set_quick_tx_trials(&mut self, on: bool) {
        self.quick_tx_trials = on;
    }

    /// av1enc_hybrid_set_tx_types: the luma tx type search tries only these types (bit t: type t;
    /// DCT_DCT always), within each block's set. All by default.
    pub fn set_tx_types(&mut self, mask: u32) {
        self.tx_types = mask;
    }

    /// av1enc_hybrid_set_sb_qindex: the next pictures' qindex per 64x64 superblock (raster, 1..255;
    /// its blocks are quantized and λ'd by it, coded with delta_q_present), or empty for the frame's
    /// qindex everywhere. A map of another size than the picture's 64x64s, or a picture with 128x128
    /// superblocks, uses the frame's. Kept tiles stay right: a block's qindex is in the decisions
    /// they're kept by.
    pub fn set_sb_qindex(&mut self, map: &[u8]) {
        self.sb_qindex.clear();
        self.sb_qindex.extend_from_slice(map);
    }

    pub fn set_reuse(&mut self, on: bool) {
        self.reuse = on;
        if !on {
            self.mem.clear();
        }
    }

    /// av1enc_hybrid_reused_tiles: tiles the last closed loop kept.
    pub fn reused_tiles(&self) -> u32 {
        self.reused_count
    }

    /// av1enc_hybrid_changed_superblocks: per 64x64 (raster, `sb_cols` x `sb_rows` into `out`),
    /// nonzero where the last closed loop re-coded the tile: elsewhere the reconstruction, blocks
    /// and source are the previous picture's. Returns false if unknown.
    pub fn changed_superblocks(&self, out: &mut [u8], sb_cols: usize, sb_rows: usize) -> bool {
        let Some(t) = &self.tiles else { return false };
        if self.reused.len() != (t.rows * t.cols) as usize || self.reused.is_empty() || out.len() < sb_cols * sb_rows {
            return false;
        }
        for r in 0..sb_rows {
            for c in 0..sb_cols {
                let (mut tc, mut tr) = (0usize, 0usize);
                while tc + 1 < t.cols as usize && t.mi_col_starts[tc + 1] as usize <= c * 16 {
                    tc += 1;
                }
                while tr + 1 < t.rows as usize && t.mi_row_starts[tr + 1] as usize <= r * 16 {
                    tr += 1;
                }
                out[r * sb_cols + c] = !self.reused[tr * t.cols as usize + tc] as u8;
            }
        }
        true
    }

    /// av1enc_hybrid_record: the last closed loop's record.
    pub fn record(&self) -> &Record {
        &self.recs[self.cur]
    }

    /// The record as av1g_decision_record: pointers into this `Hybrid`'s vectors, valid until the
    /// next closed loop or write.
    pub fn record_c(&mut self) -> DecisionRecord {
        self.recs[self.cur].as_c()
    }

    /// av1enc_hybrid_recon: plane `plane`'s pre-filter reconstruction of the last closed loop,
    /// `MiCols * 4 >> sub` wide and `MiRows * 4 >> sub` high (sub = 1 for chroma); empty after a
    /// failure, `None` for a plane > 2 or when the call wrote it into its caller's planes.
    pub fn recon(&self, plane: usize) -> Option<&[u8]> {
        (!self.recon_given)
            .then(|| self.outs[self.cur].recon.get(plane).map(|p| &p[..]))
            .flatten()
    }

    /// The last closed loop's output (its reconstruction's sizes, and the stats of its encode).
    pub fn output(&self) -> &Output {
        &self.outs[self.cur]
    }

    /// av1enc_hybrid_source: the source the last call coded, padded by edge replication to whole
    /// superblocks (at least the post-filters' MiCols * 4 x MiRows * 4, chroma half), and its
    /// stride; `None` for a plane > 2, or when the call read its caller's ([`Video::padded`]).
    pub fn source(&self, plane: usize) -> Option<(&[u8], usize)> {
        (plane < 3 && !self.src_given).then(|| (&self.src.p[plane][..], self.src.stride[plane]))
    }

    /// av1enc_hybrid_seconds: the last call's seconds: 0 chroma decisions, 1 closed loop.
    pub fn seconds(&self, which: usize) -> f64 {
        self.seconds[(which != 0) as usize]
    }
}

/// Runs `f` on every task on up to `threads` threads (this one included), each thread with its own
/// state from `init`.
fn par_for<T: Send, S>(
    threads: usize,
    tasks: &mut [T],
    init: impl Fn() -> S + Sync,
    f: impl Fn(&mut S, &mut T) + Sync,
) {
    let n = threads.min(tasks.len());
    if n <= 1 {
        let mut s = init();
        for t in tasks {
            f(&mut s, t);
        }
        return;
    }
    let cells: Vec<Mutex<&mut T>> = tasks.iter_mut().map(Mutex::new).collect();
    let next = AtomicUsize::new(0);
    let work = || {
        let mut s = init();
        loop {
            let k = next.fetch_add(1, Ordering::Relaxed);
            let Some(c) = cells.get(k) else { break };
            f(&mut s, &mut c.lock().unwrap());
        }
    };
    crate::pool::run(n, |_| work());
}

/// `rest[b0 - at..b1 - at]`, with `rest` and `at` moved past it (ranges taken in order).
fn take_range<'a, T>(rest: &mut &'a mut [T], at: &mut usize, b0: usize, b1: usize) -> &'a mut [T] {
    let (_, r) = core::mem::take(rest).split_at_mut(b0 - *at);
    let (part, r) = r.split_at_mut(b1 - b0);
    *rest = r;
    *at = b1;
    part
}

/// One tile's part of a laid-out record.
struct TileParts<'a> {
    i: usize,
    b0: usize,
    blocks: &'a mut [Block],
    txb: &'a mut [Txb],
    coeffs: &'a mut [i16],
    kept: bool,
}

/// The tiles' parts of a laid-out record: blocks `tile_first[i]..tile_first[i + 1]`, their tx
/// blocks and coefficients (contiguous and in order in a layout).
fn split_tiles<'a>(rec: &'a mut Record, tile_first: &[u32]) -> Vec<TileParts<'a>> {
    let ntiles = tile_first.len() - 1;
    let ranges: Vec<(usize, usize, usize, usize, usize, usize)> = (0..ntiles)
        .scan(0usize, |c, i| {
            let (b0, b1) = (tile_first[i] as usize, tile_first[i + 1] as usize);
            let (t0, t1) = (rec.block_txb[b0] as usize, rec.block_txb[b1] as usize);
            let c0 = *c;
            if t1 > t0 {
                let last = &rec.txb[t1 - 1];
                *c = last.coeff_off as usize + crate::dsp::tx_coeffs(last.tx_size as i32);
            }
            Some((b0, b1, t0, t1, c0, *c))
        })
        .collect();
    let (mut blocks, mut txb, mut coeffs): (&mut [Block], &mut [Txb], &mut [i16]) =
        (&mut rec.blocks, &mut rec.txb, &mut rec.coeffs);
    let (mut bat, mut tat, mut cat) = (0, 0, 0);
    ranges
        .into_iter()
        .enumerate()
        .map(|(i, (b0, b1, t0, t1, c0, c1))| TileParts {
            i,
            b0,
            blocks: take_range(&mut blocks, &mut bat, b0, b1),
            txb: take_range(&mut txb, &mut tat, t0, t1),
            coeffs: take_range(&mut coeffs, &mut cat, c0, c1),
            kept: false,
        })
        .collect()
}

/// [`Record::layout`] (av1g_layout), tile by tile on `threads` threads: the same layout.
fn layout_tiles(rec: &mut Record, tile_first: &[u32], threads: usize) -> Result<(), i32> {
    let n = rec.blocks.len();
    let ntiles = tile_first.len() - 1;
    if threads <= 1 || ntiles < 2 || tile_first[ntiles] as usize != n {
        return rec.layout().map(drop);
    }
    let fp = rec.fp;
    let inter = &rec.inter;
    let tile_inter = |b0: usize, b1: usize| if inter.is_empty() { &inter[..] } else { &inter[b0..b1] };
    let mut counts: Vec<(usize, usize, Result<LayoutCounts, i32>)> = (0..ntiles)
        .map(|i| {
            (
                tile_first[i] as usize,
                tile_first[i + 1] as usize,
                Ok(LayoutCounts::default()),
            )
        })
        .collect();
    let blocks = &rec.blocks;
    par_for(
        threads,
        &mut counts,
        || (),
        |_, (b0, b1, c)| *c = layout_counts_ex(&fp, &blocks[*b0..*b1], tile_inter(*b0, *b1)),
    );
    let mut base = Vec::with_capacity(ntiles);
    let (mut nt, mut nc) = (0u32, 0u64);
    for (_, _, c) in &counts {
        let c = (*c)?;
        base.push((nt, nc));
        nt += c.n_txb;
        nc += c.n_coeffs;
    }
    rec.block_txb.resize(n + 1, 0);
    rec.txb.resize(nt as usize, Txb::default());
    rec.coeffs.resize(nc as usize, 0);
    rec.block_txb[n] = nt;
    struct Fill<'a> {
        blocks: &'a [Block],
        inter: &'a [BlockInter],
        block_txb: &'a mut [u32],
        txb: &'a mut [Txb],
        t0: u32,
        c0: u64,
    }
    let (mut bt, mut tx): (&mut [u32], &mut [Txb]) = (&mut rec.block_txb[..n], &mut rec.txb);
    let (mut bat, mut tat) = (0, 0);
    let blocks = &rec.blocks;
    let mut fills: Vec<Fill> = (0..ntiles)
        .map(|i| {
            let (b0, b1) = (counts[i].0, counts[i].1);
            let (t0, c0) = base[i];
            let t1 = if i + 1 < ntiles { base[i + 1].0 } else { nt };
            Fill {
                blocks: &blocks[b0..b1],
                inter: tile_inter(b0, b1),
                block_txb: take_range(&mut bt, &mut bat, b0, b1),
                txb: take_range(&mut tx, &mut tat, t0 as usize, t1 as usize),
                t0,
                c0,
            }
        })
        .collect();
    let (mi_c, mi_r, mono) = (mi_cols(fp.width as i32), mi_rows(fp.height as i32), fp.monochrome != 0);
    par_for(
        threads,
        &mut fills,
        || (),
        |_, f| {
            let (mut k, mut c) = (0usize, f.c0);
            for (j, b) in f.blocks.iter().enumerate() {
                f.block_txb[j] = f.t0 + k as u32;
                let bs = b.bsize as i32;
                let depth = (b.tx_depth as i32).min(max_tx_depth(bs));
                for_each_txb_ex(
                    bs,
                    b.mi_row as i32,
                    b.mi_col as i32,
                    depth,
                    f.inter.get(j).is_some_and(|i| i.is_inter != 0),
                    mono,
                    mi_r,
                    mi_c,
                    |plane, tx_sz, x4, y4, _, _| {
                        f.txb[k] = Txb {
                            coeff_off: c as u32,
                            x4: x4 as u16,
                            y4: y4 as u16,
                            plane: plane as u8,
                            tx_size: tx_sz as u8,
                            tx_type: DCT_DCT as u8,
                            flags: 0,
                            eob: 0,
                            reserved: 0,
                        };
                        k += 1;
                        c += crate::dsp::tx_coeffs(tx_sz) as u64;
                    },
                );
            }
        },
    );
    Ok(())
}

// the C API keeps a Hybrid behind a handle Swift may use from any thread
const _: () = {
    const fn send<T: Send>() {}
    send::<Hybrid>();
};

/// The hybrid's decision options (HybridOpts).
fn hybrid_dec_opts() -> DecOpts {
    DecOpts {
        min_block: 8,
        max_block: 64,
        angle_deltas: true,
        cfl: true,
        split_bias: 1.0,
    }
}
