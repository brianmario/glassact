//! The DecisionRecord writer (Sources/AV1Core/src/encoder.cpp with av1g/internal.h): a record's
//! decisions and quantized coefficients in, a conformant OBU stream (and AVIF) and the decoder's
//! exact reconstruction out; and the parser, OBUs back to a record.
//!
//! A record is a still picture, or (video mode, decisions.h) a key or inter frame of a stream.
//! Inter frames take their reference pictures ([`RefSlots`], [`Extras::refs`],
//! [`Writer::encode_ex`]): blocks predict from LAST_FRAME with whole-sample motion, and the writer
//! derives each inter block's mode from its MV and the spec's candidate stack (`mvstack`).
//!
//! One syntax walk, two directions. The walk mirrors the AV1 spec syntax (5.9 / 5.11) element by
//! element with the spec's context derivations (8.3.2), generic over a [`sink::Sink`]:
//! - writing: every syntax element's value comes from the record, the sink codes it (od_ec) and
//!   returns it unchanged;
//! - parsing: the sink decodes the element (spec 8.2 symbol decoder) and the walk stores it into a
//!   record being built.
//!
//! Tiles are coded on parallel threads ([`std::thread::scope`]). Prediction never crosses a tile
//! (is_inside() is tile-local), so each tile reconstructs into its own buffers (tile-local planes
//! and mode-info maps), which are merged into the frame for the post-filters and the outputs.
//!
//! - [`Writer`]: the encoder, with its scratch (one per stream: a long-lived writer doesn't
//!   allocate per picture once its buffers have grown); [`Writer::encode`], [`Writer::encode_ex`]
//!   (reference pictures), [`Writer::encode_with_hook`] (the closed-loop [`TxbHook`], tile skips,
//!   per-tile symbols, references);
//! - [`validate`], [`parse`];
//! - [`layout`] / [`layout_counts`] (`_ex`: with inter blocks) / [`Record::layout`]: the tx-block
//!   layout;
//! - [`tile_layout`], [`legalize_sb_qindex`], [`apply_sb_qindex`].
#![allow(clippy::too_many_arguments, clippy::needless_range_loop)]

use crate::entropy::FrameCdfs;
use crate::types::*;

mod encode;
mod headers;
mod layout;
mod mvstack;
mod parse;
pub(crate) mod sink;
mod tiles;
mod walk;

#[cfg(test)]
mod inter_tests;
#[cfg(test)]
mod tests;

pub use encode::{ENC_CHECK_EDGES, ENC_SKIP_RECON, Extras, Writer, encode, validate};
pub(crate) use headers::{BitWriter, frame_obus};
pub use layout::{
    LayoutCounts, apply_sb_qindex, layout, layout_counts, layout_counts_ex, layout_ex, legalize_sb_qindex,
};
pub use parse::{ParseState, Parsed, parse, parse_with};
pub(crate) use tiles::choose_level;
pub use tiles::{TileInfo, compute_tiles, tile_layout};

/// An error of the writer or the parser: one of the `ERR_*` codes and a message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    pub code: i32,
    pub msg: String,
}

impl core::fmt::Display for Error {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "{} (av1g error {})", self.msg, self.code)
    }
}
impl std::error::Error for Error {}

/// The walk's errors are boxed: the Ok path of every walk function stays a register.
pub(crate) type Res<T> = Result<T, Box<Error>>;

macro_rules! fail {
    ($code:expr, $($a:tt)*) => {
        return Err(Box::new($crate::writer::Error { code: $code, msg: format!($($a)*) }))
    };
}
pub(crate) use fail;

/// A DecisionRecord with its storage (av1g_decision_record and the vectors it points into).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Record {
    pub fp: FrameParams,
    /// decode order
    pub blocks: Vec<Block>,
    /// n_blocks + 1 entries: block b's tx blocks are `block_txb[b]..block_txb[b + 1]`
    pub block_txb: Vec<u32>,
    pub txb: Vec<Txb>,
    pub coeffs: Vec<i16>,
    /// one entry per block, or empty: every block intra (decisions.h "Inter blocks")
    pub inter: Vec<BlockInter>,
}

impl Record {
    pub fn new(fp: FrameParams, blocks: Vec<Block>) -> Record {
        Record {
            fp,
            blocks,
            ..Default::default()
        }
    }

    /// av1g_layout into the record's vectors (they keep their capacity): `block_txb` and `txb` are
    /// rewritten (tx_type DCT_DCT, eob 0), `coeffs` is resized to the layout's count (existing
    /// values are kept, new ones are 0). Errors: [`ERR_INVALID`] (a block's bsize or position).
    pub fn layout(&mut self) -> Result<LayoutCounts, i32> {
        let n = layout_counts_ex(&self.fp, &self.blocks, &self.inter)?;
        self.block_txb.resize(self.blocks.len() + 1, 0);
        self.txb.resize(n.n_txb as usize, Txb::default());
        self.coeffs.resize(n.n_coeffs as usize, 0);
        layout_ex(&self.fp, &self.blocks, &self.inter, &mut self.block_txb, &mut self.txb)
    }

    /// The record as the writer takes it.
    pub fn as_mut(&mut self) -> RecordMut<'_> {
        RecordMut {
            fp: self.fp,
            blocks: &self.blocks,
            block_txb: &self.block_txb,
            txb: &mut self.txb,
            coeffs: &mut self.coeffs,
            inter: &self.inter,
        }
    }

    /// A C view of the record (pointers into its vectors, valid while it isn't changed).
    pub fn as_c(&mut self) -> DecisionRecord {
        DecisionRecord {
            fp: self.fp,
            n_blocks: self.blocks.len() as u32,
            n_txb: self.txb.len() as u32,
            n_coeffs: self.coeffs.len() as u64,
            blocks: self.blocks.as_mut_ptr(),
            block_txb: self.block_txb.as_mut_ptr(),
            txb: self.txb.as_mut_ptr(),
            coeffs: self.coeffs.as_mut_ptr(),
            inter: if self.inter.is_empty() {
                core::ptr::null_mut()
            } else {
                self.inter.as_mut_ptr()
            },
        }
    }
}

/// A record as the writer takes it: the decisions (read only) and the arrays it writes back (the tx
/// blocks' eob and chroma tx_type, luma tx_type normalized to DCT_DCT when all zero, coefficients
/// repaired by [`ENC_FIX_RANGE`] or rewritten by a hook).
#[derive(Debug)]
pub struct RecordMut<'a> {
    pub fp: FrameParams,
    pub blocks: &'a [Block],
    /// `blocks.len() + 1` entries
    pub block_txb: &'a [u32],
    pub txb: &'a mut [Txb],
    pub coeffs: &'a mut [i16],
    /// `blocks.len()` entries, or empty: every block intra
    pub inter: &'a [BlockInter],
}

impl<'a> RecordMut<'a> {
    /// Borrows a C record's arrays (n_blocks + 1 block_txb entries, n_txb tx blocks, n_coeffs
    /// coefficients, and for version >= 2 the n_blocks inter entries if `inter` isn't null).
    /// Errors as av1g_encode: [`ERR_INVALID`] when an array is missing.
    ///
    /// # Safety
    /// The record's pointers must be valid for its counts (block_txb for n_blocks + 1) and not
    /// aliased elsewhere for `'a`.
    pub unsafe fn from_c(rec: &'a mut DecisionRecord) -> Result<RecordMut<'a>, Error> {
        if rec.blocks.is_null()
            || rec.block_txb.is_null()
            || rec.txb.is_null()
            || (rec.coeffs.is_null() && rec.n_coeffs != 0)
        {
            return Err(Error {
                code: ERR_INVALID,
                msg: "record arrays missing".into(),
            });
        }
        // SAFETY: the caller guarantees the pointers and counts; empty arrays may dangle.
        unsafe {
            Ok(RecordMut {
                fp: rec.fp,
                blocks: core::slice::from_raw_parts(rec.blocks, rec.n_blocks as usize),
                block_txb: core::slice::from_raw_parts(rec.block_txb, rec.n_blocks as usize + 1),
                txb: core::slice::from_raw_parts_mut(rec.txb, rec.n_txb as usize),
                coeffs: if rec.n_coeffs == 0 {
                    &mut []
                } else {
                    core::slice::from_raw_parts_mut(rec.coeffs, rec.n_coeffs as usize)
                },
                inter: if rec.fp.version < 2 || rec.inter.is_null() || rec.n_blocks == 0 {
                    &[]
                } else {
                    core::slice::from_raw_parts(rec.inter, rec.n_blocks as usize)
                },
            })
        }
    }

    /// A shorter-lived view of the same record.
    pub fn reborrow(&mut self) -> RecordMut<'_> {
        RecordMut {
            fp: self.fp,
            blocks: self.blocks,
            block_txb: self.block_txb,
            txb: self.txb,
            coeffs: self.coeffs,
            inter: self.inter,
        }
    }
}

/// The encoder's results (av1g_output with owned buffers). A reused `Output` keeps its buffers'
/// capacity.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Output {
    /// [TD] + OBU_SEQUENCE_HEADER + OBU_FRAME
    pub obu: Vec<u8>,
    /// the AVIF file ([`ENC_AVIF`]), else empty
    pub avif: Vec<u8>,
    /// the reconstruction, `recon_w[p] x recon_h[p]` row-major: cropped (Y w x h, U / V ((w + 1) / 2)
    /// x ((h + 1) / 2)) or, with [`ENC_PREFILTER_RECON`], the padded pre-filter frame (MiCols * 4 x
    /// MiRows * 4, chroma half). Empty with [`ENC_NO_RECON`] / [`ENC_BITSTREAM_ONLY`] and for the
    /// chroma planes of monochrome pictures.
    pub recon: [Vec<u8>; 3],
    pub recon_w: [u32; 3],
    pub recon_h: [u32; 3],
    pub seq_level_idx: u32,
    pub tile_cols: u32,
    pub tile_rows: u32,
    /// everything except tile payloads
    pub header_bytes: u32,
    /// sum of tile payloads
    pub tile_bytes: u64,
    /// adaptive symbols + literal bits coded
    pub n_symbols: u64,
    /// tx blocks repaired by [`ENC_FIX_RANGE`]
    pub n_fixed_txb: u32,
    /// video mode: the frame's saved CDFs (a later frame with `fp.cdf_from_ref` that references a
    /// slot this frame refreshes starts from them; [`RefPicture::cdfs`]). `None` when not known:
    /// a still picture, or every coded tile skipped ([`TileSkip`]).
    pub saved_cdfs: Option<Box<FrameCdfs>>,
}

impl Output {
    /// Empties the buffers (keeping their capacity) and zeroes the stats.
    pub fn clear(&mut self) {
        let Output {
            obu,
            avif,
            recon,
            recon_w,
            recon_h,
            seq_level_idx,
            tile_cols,
            tile_rows,
            header_bytes,
            tile_bytes,
            n_symbols,
            n_fixed_txb,
            saved_cdfs: _,
        } = self;
        obu.clear();
        avif.clear();
        recon.iter_mut().for_each(Vec::clear);
        (*recon_w, *recon_h) = ([0; 3], [0; 3]);
        (*seq_level_idx, *tile_cols, *tile_rows, *header_bytes) = (0, 0, 0, 0);
        (*tile_bytes, *n_symbols, *n_fixed_txb) = (0, 0, 0);
    }
}

/// A reference picture for inter frames: the decoder's output of the frame that refreshed a slot
/// (that frame's [`Output::recon`]: post-filter, cropped, Y width x height, U / V ((width + 1) / 2)
/// x ((height + 1) / 2), the stream's size), each plane at its row stride. Monochrome: Y only (the
/// chroma slices are not read).
#[derive(Clone, Copy, Debug, Default)]
pub struct RefPicture<'a> {
    pub plane: [&'a [u8]; 3],
    pub stride: [usize; 3],
    /// the frame's saved CDFs ([`Output::saved_cdfs`]): needed by a `fp.cdf_from_ref` frame
    pub cdfs: Option<&'a FrameCdfs>,
}

impl<'a> RefPicture<'a> {
    /// A reconstruction as the writer returns it (tightly packed cropped planes), with its CDFs.
    pub fn from_output(o: &'a Output) -> RefPicture<'a> {
        RefPicture {
            plane: [&o.recon[0], &o.recon[1], &o.recon[2]],
            stride: [o.recon_w[0] as usize, o.recon_w[1] as usize, o.recon_w[2] as usize],
            cdfs: o.saved_cdfs.as_deref(),
        }
    }
}

/// The 8 reference slots (NUM_REF_FRAMES); an inter frame reads `fp.ref_slot`'s.
pub type RefSlots<'a> = [Option<RefPicture<'a>>; 8];

/// A tile the caller already has (its blocks unchanged since it was coded): the writer doesn't walk
/// it and takes its payload as given (an empty payload if `None`). Its blocks' outputs (tx block
/// eob, reconstruction: zeros in the output) are the caller's to fill.
#[derive(Clone, Copy, Debug, Default)]
pub struct TileSkip<'a> {
    pub skip: bool,
    pub payload: Option<&'a [u8]>,
}

/// What a [`TxbHook`] gets for one tx block.
#[derive(Clone, Copy, Debug)]
pub struct TxbCtx<'a> {
    pub block: &'a Block,
    /// the block's index in the record
    pub block_idx: u32,
    /// the tx block's exact prediction: sample (i, j) at `recon[i * recon_stride + j]`, i < tx
    /// height, j < tx width (the slice runs on through the tile's reconstruction: other samples
    /// are not the picture's)
    pub recon: &'a [u8],
    pub recon_stride: usize,
    /// the block's quantizers of this plane (delta-q applied)
    pub dc_q: i32,
    pub ac_q: i32,
    /// the chroma tx type the writer derived (planes 1, 2); the luma decision for plane 0
    pub derived_tx_type: i32,
    /// the plane's quantizer-matrix level (15 = none): the weights of a tx type are
    /// `dsp::qm(true, qm_level, plane, tx_size, tx_type)`
    pub qm_level: i32,
    /// the block is inter: `recon` holds its motion-compensated prediction, a luma tx_type the
    /// hook picks must be in the inter set (`dsp::get_tx_set_inter`), and the chroma type
    /// derives from the co-located luma type (already final: luma is coded first)
    pub is_inter: bool,
}

/// The closed-loop hook: called for every coded tx block of a non-skip block after its exact
/// prediction has been written to the reconstruction (an intra tx block's, or an inter block's
/// motion-compensated prediction, which is made for the whole block first; [`TxbCtx::is_inter`])
/// and before the coefficients are range-checked and coded. It may overwrite the tx block's coefficients (`coeffs`, tw * th row-major) and, for
/// luma, `txb.tx_type`. Used by the hybrid encoder's closed loop and the reference engine.
///
/// Tiles run on parallel threads and share the hook (`&self`, hence `Sync`), as the C++ shares its
/// hook object; each thread has its own `Scratch` (what the C++ hooks keep in thread_locals),
/// created with `Default` for each encode and reused for all the tiles that thread codes.
pub trait TxbHook: Sync {
    type Scratch: Default + Send;
    fn on_txb(&self, scratch: &mut Self::Scratch, ctx: &TxbCtx<'_>, txb: &mut Txb, coeffs: &mut [i16]);
}

/// No hook.
pub struct NoHook;
impl TxbHook for NoHook {
    type Scratch = ();
    #[inline(always)]
    fn on_txb(&self, _: &mut (), _: &TxbCtx<'_>, _: &mut Txb, _: &mut [i16]) {}
}
