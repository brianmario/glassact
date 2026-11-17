//! Glass Act's AV1 decoder, for the streams the writer produces (the hybrid encoder's): still
//! pictures, and key and inter frames of video streams, 8-bit 4:2:0, 4:4:4 key frames, monochrome;
//! 64x64 or 128x128 superblocks, uniform tiles, palettes, intra block copy, deblocking and CDEF,
//! LAST_FRAME and the long-term GOLDEN_FRAME slots. Anything else is refused with an error, never
//! decoded approximately: other profiles and bit depths, film grain, loop restoration, superres,
//! segmentation, compound, warped and OBMC motion, switchable filters, scaled references, a
//! feature the parser doesn't model. Frames come off the network, so every input is checked
//! (DESIGN §8, INV-6): no input panics, loops without end, allocates without bound (frames are at
//! most [`MAX_DIM`] a side, or the caller's cap: [`Decoder::with_max_size`]) or reads outside a
//! buffer.
//!
//! [`Decoder::decode`] takes one temporal unit at a time, in stream order, and returns the frame
//! it shows ([`Picture`]: cropped planes at a stride, valid until the next call). The reference
//! pictures (at most nine: the eight slots share pictures), their saved CDFs and loop filter
//! deltas live in the decoder, which allocates them once per picture size.
//!
//! How a frame is decoded:
//! - its tiles in parallel on the crate's worker pool, each walk (`writer::decode`) parsing and
//!   reconstructing its blocks into the tile's own planes, which the decoder keeps from frame to
//!   frame: an inter block with no motion whose reference the tile's planes already hold there
//!   isn't predicted (`Frame::elide`);
//! - then per 64x64 ("unit"), in bands of unit rows on the pool: a unit whose blocks all copy one
//!   reference with no motion and no residual, where neither filter touches it, is that
//!   reference's unit; one the filters don't touch is the tile's planes; the rest are deblocked
//!   and CDEF-filtered (`postfilter::deblock_rect`, `cdef_rect`) from a frame-level copy. Each
//!   unit of every picture (and of the tile planes) carries a content id, so a unit is copied
//!   only where its destination holds something else.
//!
//! The result is the spec's decoding process, bit for bit: the tests compare every frame with the
//! writer's reconstruction (which dav1d and libaom reproduce) and with those decoders.
#![allow(clippy::too_many_arguments, clippy::needless_range_loop)]

use crate::blockinfo::{mi_cols, mi_rows};
use crate::dsp::RefPlane;
use crate::entropy::FrameCdfs;
use crate::postfilter::{
    LF_ZERO, PF_BLK_INTER, PF_BLK_LF_ZERO, PfFrame, PfMaps, cdef_rect, deblock_rect, pf_skip_value,
};
use crate::tables::LAST_FRAME;
use crate::types::{CHROMA_444, ERR_INVALID, GOLDEN};
use crate::writer::decode::{Frame, TileBufs, TileDecoder};
use crate::writer::{Error, FrameHdr, LfDeltas, Seq, TileInfo, parse_frame_header, parse_seq_obu, tile_spans};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Instant;

#[cfg(test)]
mod tests;

/// The largest frame side the decoder takes: the encoder's limit.
pub const MAX_DIM: u32 = 8192;

/// [`Error::code`] of a frame that needs a picture the decoder doesn't have: an inter frame after
/// [`Decoder::reset`], an error, a new sequence header, or before the stream's first key frame.
/// The stream can resume at its next key frame.
pub const ERR_NO_REFERENCE: i32 = -5;

/// A unit's kind ([`Decoder::kind`]): deblocked and CDEF-filtered from the tile planes.
const K_FILTER: u8 = 0;
/// The tile planes' samples, which no filter changes.
const K_CLEAN: u8 = 1;
/// LAST_FRAME's unit (or GOLDEN_FRAME's: [`K_COPY_GOLDEN`]): every block a copy of it with no
/// motion and no residual, which no filter changes.
const K_COPY_LAST: u8 = 2;
const K_COPY_GOLDEN: u8 = 3;
/// The destination picture's unit must be written (it holds other samples).
const K_DIRTY: u8 = 0x80;

/// [`Decoder::summ`]: every 4x4 of the unit is skipped.
const S_SKIP: u8 = 1;
/// Every 4x4 of the unit copies LAST_FRAME (or GOLDEN_FRAME: [`S_GOLDEN`]) with no motion, skipped.
const S_LAST: u8 = 2;
const S_GOLDEN: u8 = 4;

/// A picture's format: what its planes hold, and what a reference must match.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Geo {
    w: u32,
    h: u32,
    /// the chroma subsampling: 1 (4:2:0) or 0 (4:4:4)
    ss: i32,
    mono: bool,
}

impl Geo {
    fn planes(&self) -> usize {
        if self.mono { 1 } else { 3 }
    }
    fn sub(&self, p: usize) -> i32 {
        if p != 0 { self.ss } else { 0 }
    }
    /// 64x64s across and down
    fn units(&self) -> (usize, usize) {
        (
            ((mi_cols(self.w as i32) + 15) >> 4) as usize,
            ((mi_rows(self.h as i32) + 15) >> 4) as usize,
        )
    }
}

/// A decoded picture: the planes of the decoded area padded to whole 64x64s (after the filters),
/// each 64x64's content id, its saved CDFs and loop filter deltas, and the slots holding it.
#[derive(Default)]
struct Pic {
    geo: Geo,
    planes: [Vec<u8>; 3],
    stride: [usize; 3],
    /// per 64x64 (raster): its samples' id (0: unknown); equal ids, equal samples over the decoded
    /// area
    ids: Vec<u64>,
    cdfs: Option<Box<FrameCdfs>>,
    deltas: LfDeltas,
    /// the slots holding it
    refs: u32,
    /// what it was decoded as
    key: bool,
    render: (u32, u32),
    colour: [u32; 4],
}

impl Pic {
    /// Sized for `geo` (its samples unknown if that changes).
    fn setup(&mut self, geo: Geo) {
        if self.geo == geo && !self.ids.is_empty() {
            return;
        }
        self.geo = geo;
        let (uc, ur) = geo.units();
        for p in 0..3 {
            let sub = geo.sub(p) as usize;
            self.stride[p] = (uc * 64) >> sub;
            let n = if p < geo.planes() {
                self.stride[p] * ((ur * 64) >> sub)
            } else {
                0
            };
            self.planes[p].clear();
            self.planes[p].resize(n, 0);
        }
        self.ids.clear();
        self.ids.resize(uc * ur, 0);
    }

    fn ref_planes(&self) -> [RefPlane<'_>; 3] {
        core::array::from_fn(|p| {
            let sub = self.geo.sub(p) as u32;
            RefPlane {
                data: &self.planes[p],
                stride: self.stride[p],
                w: if p < self.geo.planes() {
                    ((self.geo.w + sub) >> sub) as i32
                } else {
                    0
                },
                h: if p < self.geo.planes() {
                    ((self.geo.h + sub) >> sub) as i32
                } else {
                    0
                },
            }
        })
    }
}

/// A decoded frame as [`Decoder::decode`] returns it: valid until the decoder's next call.
#[derive(Clone, Copy, Debug)]
pub struct Picture<'a> {
    /// the decoded frame's size (its luma plane's)
    pub width: u32,
    pub height: u32,
    /// the size the stream asks it shown at (render_size: a reduced frame's stream size)
    pub render_width: u32,
    pub render_height: u32,
    /// [`crate::types::CHROMA_420`] or [`CHROMA_444`]
    pub chroma_format: u8,
    pub monochrome: bool,
    /// a key frame (or still picture)
    pub key: bool,
    /// the sequence header's color_primaries, transfer_characteristics, matrix_coefficients and
    /// color_range
    pub colour: [u32; 4],
    /// Y, U, V: row r of plane p at `planes[p][r * stride[p]..]`, `plane_w[p]` x `plane_h[p]`
    /// samples (monochrome: the chroma planes are empty)
    pub planes: [&'a [u8]; 3],
    pub stride: [usize; 3],
    pub plane_w: [u32; 3],
    pub plane_h: [u32; 3],
}

/// What the last frame's decode did, and how long its stages took (ms).
#[derive(Clone, Copy, Debug, Default)]
pub struct Stats {
    pub tiles: u32,
    /// the threads its tiles were decoded on (at most the decoder's)
    pub tile_threads: u32,
    /// its 64x64s: copied from a reference, the tile planes' as they are, filtered
    pub units_copy: u32,
    pub units_clean: u32,
    pub units_filter: u32,
    /// 64x64s written to the output picture (the rest held the right samples already)
    pub units_written: u32,
    /// stages: the headers, the tiles, the maps, the frame-level copy and the filters, the output
    pub ms_header: f64,
    pub ms_tiles: f64,
    pub ms_maps: f64,
    pub ms_filters: f64,
    pub ms_output: f64,
}

/// The AV1 decoder: see the module.
pub struct Decoder {
    threads: usize,
    /// the largest frame it takes, width and height ([`Decoder::with_max_size`])
    max: (u32, u32),
    seq: Option<Box<Seq>>,
    pics: Vec<Pic>,
    /// the reference slots' pictures
    slot: [Option<usize>; 8],
    /// the last frame shown
    out: Option<usize>,
    workers: Vec<TileDecoder>,
    tiles: Vec<TileBufs>,
    /// what the tile planes hold: the frame layout they were last decoded for, each 64x64's id
    t_key: Option<(Geo, bool, i8, i8)>,
    t_ids: Vec<u64>,
    spans: Vec<(usize, usize)>,
    /// per 64x64 of the frame: its tile's column, and per unit row its tile row
    unit_tc: Vec<u16>,
    band_tr: Vec<u16>,
    // the frame's post-filter maps (PfMaps)
    pf_skip: Vec<u8>,
    lf_tx: [Vec<u8>; 3],
    cdef_idx: Vec<i8>,
    /// per 64x64: K_* | K_DIRTY, S_*, the elision mask ([`Frame::elide`])
    kind: Vec<u8>,
    summ: Vec<u8>,
    elide: Vec<u8>,
    /// the frame-level planes the filters run on, and each 64x64's id there (0: filtered, unknown)
    s: [Vec<u8>; 3],
    s_ids: Vec<u64>,
    s_geo: Geo,
    saved: Mutex<(bool, Box<FrameCdfs>)>,
    next_id: u64,
    stats: Stats,
    /// tests: decode every 64x64 by the full path (no copies, no elision)
    full: bool,
    /// tests: frames whose tiles were walked
    pub(crate) walks: u64,
}

impl Default for Decoder {
    fn default() -> Self {
        Self::new(0)
    }
}

fn err(code: i32, msg: impl Into<String>) -> Error {
    Error { code, msg: msg.into() }
}

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1e3
}

/// `f(k, item k)` for each of the `n` items of `items`, on at most `threads` threads of the pool,
/// which take them from one queue (no list of them, no lock each).
fn par<T: Send>(threads: usize, n: usize, items: impl Iterator<Item = T> + Send, f: impl Fn(usize, T) + Sync) {
    if threads <= 1 || n <= 1 {
        for (k, it) in items.enumerate() {
            f(k, it);
        }
        return;
    }
    let q = Mutex::new(items.enumerate());
    crate::pool::run(threads.min(n), |_| {
        loop {
            let next = q.lock().unwrap_or_else(|e| e.into_inner()).next();
            let Some((k, it)) = next else { break };
            f(k, it);
        }
    });
}

/// `v` (rows of `row` elements) in bands of `rows` rows.
fn bands<T>(v: &mut [T], row: usize, rows: usize) -> impl Iterator<Item = &mut [T]> {
    v.chunks_mut((row * rows).max(1))
}

/// Copies the `w` x `h` samples at (x, y) of `src` (stride `ss`) to (x, y - dy) of `dst` (stride
/// `ds`).
fn copy_rect(src: &[u8], ss: usize, dst: &mut [u8], ds: usize, x: usize, y: usize, dy: usize, w: usize, h: usize) {
    for i in 0..h {
        dst[(y - dy + i) * ds + x..][..w].copy_from_slice(&src[(y + i) * ss + x..][..w]);
    }
}

impl Decoder {
    /// A decoder using at most `threads` threads (0: the available parallelism), for frames up
    /// to [`MAX_DIM`] a side.
    pub fn new(threads: usize) -> Decoder {
        Self::with_max_size(threads, MAX_DIM, MAX_DIM)
    }

    /// A decoder for frames up to `max_width` x `max_height` (each at most [`MAX_DIM`]; 0:
    /// [`MAX_DIM`]), as [`Decoder::new`]: a Viewer's, sized by its region. A sequence header for
    /// larger frames, or a frame larger than that, is an error before anything is allocated for
    /// it, so its pictures and buffers never take more than a frame of that size implies.
    pub fn with_max_size(threads: usize, max_width: u32, max_height: u32) -> Decoder {
        let cap = |v: u32| if v == 0 { MAX_DIM } else { v.min(MAX_DIM) };
        let threads = if threads == 0 {
            std::thread::available_parallelism().map_or(1, |n| n.get())
        } else {
            threads
        };
        Decoder {
            threads,
            max: (cap(max_width), cap(max_height)),
            seq: None,
            pics: Vec::new(),
            slot: [None; 8],
            out: None,
            workers: Vec::new(),
            tiles: Vec::new(),
            t_key: None,
            t_ids: Vec::new(),
            spans: Vec::new(),
            unit_tc: Vec::new(),
            band_tr: Vec::new(),
            pf_skip: Vec::new(),
            lf_tx: Default::default(),
            cdef_idx: Vec::new(),
            kind: Vec::new(),
            summ: Vec::new(),
            elide: Vec::new(),
            s: Default::default(),
            s_ids: Vec::new(),
            s_geo: Geo::default(),
            saved: Mutex::new((false, Box::new(FrameCdfs::new(0)))),
            next_id: 1,
            stats: Stats::default(),
            full: false,
            walks: 0,
        }
    }

    /// The threads it decodes on.
    pub fn threads(&self) -> usize {
        self.threads
    }

    /// The largest frame it takes, width and height.
    pub fn max_size(&self) -> (u32, u32) {
        self.max
    }

    /// Forgets the stream: the reference pictures, their CDFs, the sequence header. The next
    /// frame must be a key frame with its sequence header. Buffers are kept.
    pub fn reset(&mut self) {
        self.drop_refs();
        self.seq = None;
    }

    /// Every slot emptied (a new sequence, an error): only a key frame decodes next.
    fn drop_refs(&mut self) {
        self.slot = [None; 8];
        for p in &mut self.pics {
            p.refs = 0;
        }
        self.out = None;
        self.t_key = None;
    }

    /// The last frame's [`Stats`].
    pub fn stats(&self) -> Stats {
        self.stats
    }

    /// Tests: every 64x64 decoded and filtered as a whole frame would be (no copies, no
    /// elision), the oracle for the copy path.
    #[cfg(test)]
    pub(crate) fn set_full(&mut self, full: bool) {
        self.full = full;
    }

    /// The last frame shown, if the last call decoded one.
    pub fn picture(&self) -> Option<Picture<'_>> {
        let p = &self.pics[self.out?];
        let g = p.geo;
        let nplanes = g.planes();
        Some(Picture {
            width: g.w,
            height: g.h,
            render_width: p.render.0,
            render_height: p.render.1,
            chroma_format: if g.ss == 0 {
                CHROMA_444
            } else {
                crate::types::CHROMA_420
            },
            monochrome: g.mono,
            key: p.key,
            colour: p.colour,
            planes: core::array::from_fn(|k| if k < nplanes { &p.planes[k][..] } else { &[] }),
            stride: core::array::from_fn(|k| if k < nplanes { p.stride[k] } else { 0 }),
            plane_w: core::array::from_fn(|k| {
                if k < nplanes {
                    (g.w + g.sub(k) as u32) >> g.sub(k)
                } else {
                    0
                }
            }),
            plane_h: core::array::from_fn(|k| {
                if k < nplanes {
                    (g.h + g.sub(k) as u32) >> g.sub(k)
                } else {
                    0
                }
            }),
        })
    }

    /// Decodes one temporal unit (OBUs: a temporal delimiter, a sequence header, one OBU_FRAME,
    /// metadata and padding ignored) and returns the frame it shows. On an error nothing is shown
    /// and the reference slots are emptied: the stream resumes at a key frame.
    pub fn decode(&mut self, tu: &[u8]) -> Result<Picture<'_>, Error> {
        self.out = None;
        match self.decode_tu(tu) {
            Ok(()) => Ok(self.picture().expect("a decoded frame")),
            Err(e) => {
                self.drop_refs();
                Err(e)
            }
        }
    }

    fn decode_tu(&mut self, tu: &[u8]) -> Result<(), Error> {
        let t0 = Instant::now();
        let n = tu.len();
        let (mut pos, mut frame) = (0usize, None);
        let mut seq: Option<Seq> = None;
        while pos < n {
            let h = tu[pos];
            pos += 1;
            if h & 0x80 != 0 {
                return Err(err(ERR_INVALID, "OBU forbidden bit set"));
            }
            let (ty, ext, has_size) = ((h >> 3) & 15, (h >> 2) & 1, (h >> 1) & 1);
            if ext != 0 {
                // temporal and spatial ids: one operating point of every layer (the sequence
                // header checks operating_point_idc), so none is dropped
                pos += 1;
            }
            if pos > n {
                return Err(err(ERR_INVALID, "OBU truncated"));
            }
            let mut sz = (n - pos) as u64;
            if has_size != 0 {
                sz = 0;
                let mut i = 0;
                loop {
                    let Some(&b) = tu.get(pos) else {
                        return Err(err(ERR_INVALID, "OBU size truncated"));
                    };
                    pos += 1;
                    sz |= ((b & 0x7f) as u64) << (7 * i);
                    i += 1;
                    if b & 0x80 == 0 {
                        break;
                    }
                    if i == 8 {
                        return Err(err(ERR_INVALID, "OBU size longer than 8 bytes"));
                    }
                }
            }
            if sz > (n - pos) as u64 {
                return Err(err(ERR_INVALID, "OBU size beyond the temporal unit"));
            }
            let span = (pos, sz as usize);
            match ty {
                1 if frame.is_some() => return Err(err(ERR_INVALID, "a sequence header after the frame")),
                1 => {
                    // every one must parse; the last one counts
                    let mut sq = Seq::new();
                    parse_seq_obu(&tu[pos..pos + span.1], &mut sq).map_err(|e| *e)?;
                    seq = Some(sq);
                }
                6 if frame.is_some() => return Err(err(ERR_INVALID, "more than one frame in a temporal unit")),
                6 => frame = Some(span),
                3 | 4 | 7 | 8 => {
                    return Err(err(
                        ERR_INVALID,
                        format!("OBU type {ty} (separate frame headers and tile groups, tile lists) not supported"),
                    ));
                }
                // temporal delimiters, metadata, padding and reserved types are ignored
                _ => {}
            }
            pos += sz as usize;
        }
        let Some((fpos, fsz)) = frame else {
            return Err(err(ERR_INVALID, "no frame in the temporal unit"));
        };
        if let Some(sq) = seq {
            if sq.op_idc {
                return Err(err(ERR_INVALID, "operating points (operating_point_idc) not supported"));
            }
            if sq.max_w > MAX_DIM || sq.max_h > MAX_DIM {
                return Err(err(
                    ERR_INVALID,
                    format!("frames up to {}x{}: more than {MAX_DIM} a side", sq.max_w, sq.max_h),
                ));
            }
            if sq.max_w > self.max.0 || sq.max_h > self.max.1 {
                return Err(err(
                    ERR_INVALID,
                    format!(
                        "frames up to {}x{}: larger than the decoder's {}x{}",
                        sq.max_w, sq.max_h, self.max.0, self.max.1
                    ),
                ));
            }
            if self.seq.as_deref() != Some(&sq) {
                // a new coded video sequence: it starts at a key frame
                self.drop_refs();
                self.seq = Some(Box::new(sq));
            }
        }
        let Some(sq) = self.seq.take() else {
            return Err(err(ERR_NO_REFERENCE, "a frame before any sequence header"));
        };
        let r = self.decode_frame(&sq, &tu[fpos..fpos + fsz], t0);
        self.seq = Some(sq);
        r
    }

    fn decode_frame(&mut self, sq: &Seq, p: &[u8], t0: Instant) -> Result<(), Error> {
        let slot_deltas: [Option<LfDeltas>; 8] = core::array::from_fn(|i| self.slot[i].map(|k| self.pics[k].deltas));
        let hdr: FrameHdr = parse_frame_header(sq, p, &slot_deltas, true).map_err(|e| {
            let mut e = *e;
            if e.msg.contains("saved state") {
                e.code = ERR_NO_REFERENCE;
            }
            e
        })?;
        let fp = hdr.fp;
        // (the frame header holds it to the sequence header's size, which is within the cap)
        if fp.width > self.max.0 || fp.height > self.max.1 {
            return Err(err(
                ERR_INVALID,
                format!(
                    "a {}x{} frame: larger than the decoder's {}x{}",
                    fp.width, fp.height, self.max.0, self.max.1
                ),
            ));
        }
        let geo = Geo {
            w: fp.width,
            h: fp.height,
            ss: crate::blockinfo::chroma_ss(&fp),
            mono: fp.monochrome != 0,
        };
        let inter = hdr.inter;
        if inter && geo.ss == 0 {
            return Err(err(ERR_INVALID, "4:4:4 inter frames not supported"));
        }
        // the references: LAST_FRAME's slot, GOLDEN_FRAME's (its own, or LAST_FRAME's)
        let (last, golden) = if inter {
            let get = |s: u8| -> Result<usize, Error> {
                let Some(k) = self.slot[s as usize] else {
                    return Err(err(ERR_NO_REFERENCE, format!("reference slot {s} is empty")));
                };
                if self.pics[k].geo != geo {
                    return Err(err(
                        ERR_INVALID,
                        format!(
                            "reference slot {s} holds a {}x{} picture of another format: scaled references not supported",
                            self.pics[k].geo.w, self.pics[k].geo.h
                        ),
                    ));
                }
                Ok(k)
            };
            let l = get(fp.ref_slot)?;
            let g = if fp.golden_slot != 0 {
                get(fp.golden_slot - 1)?
            } else {
                l
            };
            (Some(l), Some(g))
        } else {
            (None, None)
        };
        // the output picture: one no slot holds
        let d = match self.pics.iter().position(|p| p.refs == 0) {
            Some(k) => k,
            None => {
                self.pics.push(Pic::default());
                self.pics.len() - 1
            }
        };
        let mut dpic = std::mem::take(&mut self.pics[d]);
        dpic.setup(geo);
        let r = self.decode_into(sq, p, &hdr, geo, last, golden, &mut dpic, t0);
        // a failed frame leaves the tile planes and the output picture unknown
        if r.is_err() {
            self.t_key = None;
            dpic.ids.fill(0);
        }
        self.pics[d] = dpic;
        r?;
        // the slots it refreshes (a key frame: all)
        let refresh = if inter { fp.refresh_frame_flags } else { 0xFF };
        for i in 0..8 {
            if refresh >> i & 1 != 0 {
                if let Some(k) = self.slot[i] {
                    self.pics[k].refs -= 1;
                }
                self.slot[i] = Some(d);
                self.pics[d].refs += 1;
            }
        }
        self.out = Some(d);
        Ok(())
    }

    fn decode_into(
        &mut self,
        sq: &Seq,
        p: &[u8],
        hdr: &FrameHdr,
        geo: Geo,
        last: Option<usize>,
        golden: Option<usize>,
        d: &mut Pic,
        t0: Instant,
    ) -> Result<(), Error> {
        let fp = hdr.fp;
        let threads = self.threads;
        let (mi_c, mi_r) = (mi_cols(fp.width as i32), mi_rows(fp.height as i32));
        let (uc, ur) = geo.units();
        let nunits = uc * ur;
        let nplanes = geo.planes();
        let tiles: TileInfo = hdr.tiles;
        let ntiles = (tiles.cols * tiles.rows) as usize;
        tile_spans(hdr, p, &mut self.spans).map_err(|e| *e)?;

        // the tile planes: what they hold, if laid out as before
        let key = (geo, sq.sb128, fp.tile_cols_log2, fp.tile_rows_log2);
        if self.t_key != Some(key) || self.t_ids.len() != nunits {
            self.t_ids.clear();
            self.t_ids.resize(nunits, 0);
        }
        self.t_key = None;
        let lastp = last.map(|k| &self.pics[k]);
        let goldp = golden.map(|k| &self.pics[k]);
        // which units of the tile planes hold a reference's samples (only units inside the
        // picture: past its edge a prediction replicates the edge, not the reference's samples)
        self.elide.clear();
        self.elide.resize(nunits, 0);
        let full_unit = |u: usize| ((u % uc) as u32 + 1) * 64 <= geo.w && ((u / uc) as u32 + 1) * 64 <= geo.h;
        if !self.full
            && let (Some(l), Some(g)) = (lastp, goldp)
        {
            for u in 0..nunits {
                let t = self.t_ids[u];
                if t != 0 && full_unit(u) {
                    self.elide[u] = (t == l.ids[u]) as u8 | ((t == g.ids[u]) as u8) << 1;
                }
            }
        }
        // per unit, its tile column; per unit row, its tile row
        self.unit_tc.clear();
        self.unit_tc.extend((0..uc).map(|x| {
            (0..tiles.cols as usize)
                .rfind(|&tc| tiles.mi_col_starts[tc] <= 16 * x as u32)
                .unwrap_or(0) as u16
        }));
        self.band_tr.clear();
        self.band_tr.extend((0..ur).map(|y| {
            (0..tiles.rows as usize)
                .rfind(|&tr| tiles.mi_row_starts[tr] <= 16 * y as u32)
                .unwrap_or(0) as u16
        }));

        let refs = lastp.map(|l| l.ref_planes());
        let refs_golden = goldp.map(|g| g.ref_planes());
        let cdfs_in = if fp.cdf_from_ref != 0 {
            match lastp.and_then(|l| l.cdfs.as_deref()) {
                Some(c) => Some(c),
                None => return Err(err(ERR_NO_REFERENCE, "the reference has no saved CDFs")),
            }
        } else {
            None
        };
        self.saved.get_mut().unwrap_or_else(|e| e.into_inner()).0 = false;
        let mono = geo.mono;
        let ordmap: &[Vec<u32>; 3] = &EMPTY_ORDMAP;
        let f = Frame {
            fp,
            mi_cols: mi_c,
            mi_rows: mi_r,
            mono,
            ss: geo.ss,
            sb_cols: (mi_c + 15) >> 4,
            sb_rows: (mi_r + 15) >> 4,
            tiles,
            qm_level: [
                fp.qm_y as i32,
                fp.qm_u as i32,
                if !mono && fp.using_qmatrix != 0 {
                    fp.qm_v
                } else {
                    fp.qm_u
                } as i32,
            ],
            do_recon: true,
            fix_range: false,
            check_edges: false,
            ordmap,
            inter: hdr.inter,
            intrabc: fp.allow_intrabc != 0,
            refs,
            refs_golden,
            cdfs_in,
            cdfs_out: hdr.end_update.then_some(&self.saved),
            context_tile: hdr.context_tile,
            sb128: sq.sb128,
            palettes: fp.allow_screen_content_tools != 0,
            block_bits: None,
            elide: (!self.full && hdr.inter).then_some(&self.elide[..]),
        };
        let ms_header = ms(t0);

        // ---- the tiles ----
        let t1 = Instant::now();
        self.walks += 1;
        let nw = threads.min(ntiles).max(1);
        if self.workers.len() < nw {
            self.workers.resize_with(nw, TileDecoder::default);
        }
        for w in &mut self.workers[..nw] {
            w.setup(mi_c, mi_r);
        }
        if self.tiles.len() < ntiles {
            self.tiles.resize_with(ntiles, TileBufs::default);
        }
        {
            // the tiles in one queue, the workers' states in another (a task takes one)
            let tiles_q = Mutex::new(self.tiles[..ntiles].iter_mut().enumerate());
            let workers_q = Mutex::new(self.workers[..nw].iter_mut());
            let stop = AtomicBool::new(false);
            let first_err: Mutex<Option<(usize, Box<Error>)>> = Mutex::new(None);
            let spans = &self.spans;
            let cols = tiles.cols as usize;
            let work = |w: &mut TileDecoder| {
                while !stop.load(Ordering::Relaxed) {
                    let next = tiles_q.lock().unwrap_or_else(|e| e.into_inner()).next();
                    let Some((k, bufs)) = next else { break };
                    let (at, len) = spans[k];
                    if let Err(e) = w.decode(&f, bufs, &p[at..at + len], k / cols, k % cols) {
                        stop.store(true, Ordering::Relaxed);
                        let mut g = first_err.lock().unwrap_or_else(|e| e.into_inner());
                        if g.as_ref().is_none_or(|(j, _)| k < *j) {
                            *g = Some((k, e));
                        }
                    }
                }
            };
            if nw == 1 {
                let w = workers_q.lock().unwrap_or_else(|e| e.into_inner()).next();
                work(w.expect("a worker"));
            } else {
                crate::pool::run(nw, |_| {
                    let w = workers_q.lock().unwrap_or_else(|e| e.into_inner()).next();
                    if let Some(w) = w {
                        work(w);
                    }
                });
            }
            if let Some((_, e)) = first_err.into_inner().unwrap_or_else(|e| e.into_inner()) {
                return Err(*e);
            }
        }
        if hdr.end_update && !self.saved.get_mut().unwrap_or_else(|e| e.into_inner()).0 {
            return Err(err(ERR_INVALID, "the context tile saved no CDFs"));
        }
        let ms_tiles = ms(t1);

        // ---- the frame's maps, and what each 64x64 is ----
        let t2 = Instant::now();
        let (mc, mr) = (mi_c as usize, mi_r as usize);
        let ss = geo.ss as usize;
        let inter = hdr.inter;
        let lf_off = inter && fp.lf_inter_off != 0;
        let pf_inner = inter && (lf_off || sq.sb128);
        let pf_flags = if lf_off {
            PF_BLK_LF_ZERO | PF_BLK_INTER
        } else {
            PF_BLK_INTER
        };
        self.pf_skip.resize(mr * mc, 0);
        self.lf_tx[0].resize(mr * mc, 0);
        for m in &mut self.lf_tx[1..] {
            m.resize((mr >> ss) * (mc >> ss), 0);
        }
        self.cdef_idx.resize(nunits, -1);
        self.summ.resize(nunits, 0);
        self.kind.resize(nunits, 0);
        {
            let tbufs = &self.tiles[..ntiles];
            let (unit_tc, band_tr) = (&self.unit_tc, &self.band_tr);
            let [y_m, u_m, v_m] = &mut self.lf_tx;
            let items = bands(&mut self.pf_skip, mc, 16)
                .zip(bands(y_m, mc, 16))
                .zip(bands(u_m, mc >> ss, 16 >> ss).zip(bands(v_m, mc >> ss, 16 >> ss)))
                .zip(bands(&mut self.cdef_idx, uc, 1).zip(bands(&mut self.summ, uc, 1)));
            par(threads, ur, items, |k, (((skip, tx), (u, v)), (cdef, summ))| {
                let tr = band_tr[k] as usize;
                let (r0, r1) = (16 * k, (16 * k + 16).min(mr));
                for x in 0..uc {
                    let t = &tbufs[tr * tiles.cols as usize + unit_tc[x] as usize];
                    let (tr0, tc0, tmw) = (t.r0 as usize, t.c0 as usize, t.mw as usize);
                    let (c0, c1) = (16 * x, (16 * x + 16).min(mc));
                    let mut sm = S_SKIP | S_LAST | S_GOLDEN;
                    for y in r0..r1 {
                        let tk = (y - tr0) * tmw + c0 - tc0;
                        let row = y - r0;
                        let n = c1 - c0;
                        tx[row * mc + c0..][..n].copy_from_slice(&t.tx_size[tk..tk + n]);
                        let dst = &mut skip[row * mc + c0..][..n];
                        for j in 0..n {
                            let sk = t.skip[tk + j];
                            let rf = if inter { t.ref0[tk + j] } else { 0 };
                            let is_ref = rf as i32 == LAST_FRAME || rf == GOLDEN;
                            dst[j] = if pf_inner && is_ref {
                                pf_skip_value(sk != 0, pf_flags, t.mi_size[tk + j] as i32)
                            } else {
                                sk
                            };
                            if sk == 0 {
                                sm = 0;
                            } else if !(is_ref && t.mvs[tk + j] == [0, 0]) {
                                sm &= S_SKIP;
                            } else if rf == GOLDEN {
                                sm &= S_SKIP | S_GOLDEN;
                            } else {
                                sm &= S_SKIP | S_LAST;
                            }
                        }
                    }
                    summ[x] = sm;
                    // chroma LoopfilterTxSizes
                    let (cc0, cn, ctmw) = (c0 >> ss, (c1 >> ss) - (c0 >> ss), tmw >> ss);
                    for y in (r0 >> ss)..(r1 >> ss) {
                        let tk = (y - (tr0 >> ss)) * ctmw + cc0 - (tc0 >> ss);
                        let row = y - (r0 >> ss);
                        u[row * (mc >> ss) + cc0..][..cn].copy_from_slice(&t.lf_uv[0][tk..tk + cn]);
                        v[row * (mc >> ss) + cc0..][..cn].copy_from_slice(&t.lf_uv[1][tk..tk + cn]);
                    }
                    let (ty, tx_) = ((16 * k - tr0) >> 4, (16 * x - tc0) >> 4);
                    cdef[x] = t.sb_cdef[ty * t.sb_cols as usize + tx_];
                }
            });
        }
        // what each unit is (needs its neighbours' maps), the ids of the tile planes' and the
        // output's samples
        let pf = PfFrame::new(&fp);
        let deblock = pf.lf_level[0] != 0 || pf.lf_level[1] != 0;
        let cdef = fp.enable_cdef != 0 && fp.allow_intrabc == 0;
        let base = self.next_id;
        self.next_id += 2 * nunits as u64;
        let full = self.full;
        let (n_copy, n_clean, n_filter) = {
            let (pf_skip, summ) = (&self.pf_skip, &self.summ);
            let ring_zero = |ux: usize, uy: usize| -> bool {
                let (r0, r1, c0, c1) = (16 * uy, (16 * uy + 16).min(mr), 16 * ux, (16 * ux + 16).min(mc));
                let z = |y: usize, x: usize| pf_skip[y * mc + x] & LF_ZERO != 0;
                let rows = r0.saturating_sub(1)..(r1 + 2).min(mr);
                let cols = c0.saturating_sub(1)..(c1 + 2).min(mc);
                rows.clone().all(|y| (c0..c1).all(|x| z(y, x))) && (r0..r1).all(|y| cols.clone().all(|x| z(y, x)))
            };
            let items = bands(&mut self.kind, uc, 1).zip(bands(&mut self.t_ids, uc, 1).zip(bands(&mut d.ids, uc, 1)));
            let counts: [AtomicUsize; 3] = Default::default();
            par(threads, ur, items, |uy, (kind, (tids, dids))| {
                let (mut a, mut b, mut c) = (0, 0, 0);
                for ux in 0..uc {
                    let u = uy * uc + ux;
                    let sm = summ[u];
                    let clean = !full && (!cdef || sm & S_SKIP != 0) && (!deblock || ring_zero(ux, uy));
                    let fullu = full_unit(u);
                    let copy_of = if !fullu {
                        None
                    } else if sm & S_LAST != 0 {
                        lastp.map(|p| (K_COPY_LAST, p.ids[u]))
                    } else if sm & S_GOLDEN != 0 {
                        goldp.map(|p| (K_COPY_GOLDEN, p.ids[u]))
                    } else {
                        None
                    };
                    // the tile planes: the reference's unit where every block copies it
                    let t_new = match copy_of {
                        Some((_, id)) if id != 0 => id,
                        _ => base + 2 * u as u64,
                    };
                    tids[ux] = t_new;
                    let (k, d_new) = match copy_of {
                        Some((k, id)) if clean && id != 0 => {
                            a += 1;
                            (k, id)
                        }
                        _ if clean => {
                            b += 1;
                            (K_CLEAN, t_new)
                        }
                        _ => {
                            c += 1;
                            (K_FILTER, base + 2 * u as u64 + 1)
                        }
                    };
                    kind[ux] = k | if dids[ux] != d_new || k == K_FILTER { K_DIRTY } else { 0 };
                    dids[ux] = d_new;
                }
                for (n, v) in counts.iter().zip([a, b, c]) {
                    n.fetch_add(v, Ordering::Relaxed);
                }
            });
            let [a, b, c] = counts.map(|n| n.into_inner() as u32);
            (a, b, c)
        };
        let ms_maps = ms(t2);

        // ---- the filtered units: the tile planes into the frame-level planes, deblocked ----
        let t3 = Instant::now();
        let m = PfMaps {
            skip: &self.pf_skip,
            lf_tx: [&self.lf_tx[0], &self.lf_tx[1], &self.lf_tx[2]],
            cdef_idx: &self.cdef_idx,
        };
        let plane_rows: [usize; 3] = core::array::from_fn(|p| (ur * 64) >> geo.sub(p));
        let stride: [usize; 3] = d.stride;
        if n_filter > 0 {
            if self.s_geo != geo || self.s_ids.len() != nunits {
                for p in 0..3 {
                    self.s[p].clear();
                    self.s[p].resize(if p < nplanes { stride[p] * plane_rows[p] } else { 0 }, 0);
                }
                self.s_ids.clear();
                self.s_ids.resize(nunits, 0);
                self.s_geo = geo;
            }
            let kind = &self.kind;
            let k_of = |x: isize, y: isize| -> u8 {
                if x < 0 || y < 0 || x >= uc as isize || y >= ur as isize {
                    K_CLEAN
                } else {
                    kind[y as usize * uc + x as usize] & !K_DIRTY
                }
            };
            let (tbufs, unit_tc, band_tr, t_ids) = (&self.tiles[..ntiles], &self.unit_tc, &self.band_tr, &self.t_ids);
            {
                let [s0, s1, s2] = &mut self.s;
                let rows: [usize; 3] = core::array::from_fn(|p| 64 >> geo.sub(p));
                let items = bands(s0, stride[0], rows[0])
                    .zip(bands(s1, stride[1].max(1), rows[1]).chain(std::iter::repeat_with(|| &mut [][..])))
                    .zip(bands(s2, stride[2].max(1), rows[2]).chain(std::iter::repeat_with(|| &mut [][..])))
                    .zip(bands(&mut self.s_ids, uc, 1));
                par(threads, ur, items, |uy, (((a, b), c), sids)| {
                    let band: [&mut [u8]; 3] = [a, b, c];
                    let t_row = band_tr[uy] as usize;
                    for ux in 0..uc {
                        let k = k_of(ux as isize, uy as isize);
                        let need = k == K_FILTER
                            || (cdef
                                && (-1..=1)
                                    .any(|dy| (-1..=1).any(|dx| k_of(ux as isize + dx, uy as isize + dy) == K_FILTER)));
                        let u = uy * uc + ux;
                        if !need || (k != K_FILTER && sids[ux] == t_ids[u]) {
                            continue;
                        }
                        let t = &tbufs[t_row * tiles.cols as usize + unit_tc[ux] as usize];
                        for p in 0..nplanes {
                            let sub = geo.sub(p) as usize;
                            let (n, ts) = (64 >> sub, t.stride[p]);
                            let (tx, ty) = (
                                (ux * 64 - t.c0 as usize * 4) >> sub,
                                (uy * 64 - t.r0 as usize * 4) >> sub,
                            );
                            for i in 0..n {
                                band[p][i * stride[p] + ((ux * 64) >> sub)..][..n]
                                    .copy_from_slice(&t.plane[p][(ty + i) * ts + tx..][..n]);
                            }
                        }
                        sids[ux] = if k == K_FILTER { 0 } else { t_ids[u] };
                    }
                });
            }
            if deblock {
                // pass 0 by bands; pass 1 by every other band, each with the 8 rows above it
                for pass in 0..2 {
                    for phase in 0..1 + pass {
                        let [s0, s1, s2] = &mut self.s;
                        // the bands of this phase, each split off the rest as it's taken
                        let mut rest: [&mut [u8]; 3] = [s0, s1, s2];
                        let mut at = [0usize; 3];
                        let mut uys = (phase..ur).step_by(1 + pass);
                        let items = std::iter::from_fn(move || {
                            let uy = uys.next()?;
                            let mut e: [(&mut [u8], usize); 3] = Default::default();
                            for pl in 0..nplanes {
                                let rows = 64 >> geo.sub(pl);
                                let y0 = (uy * rows).saturating_sub(8 * pass);
                                let y1 = ((uy + 1) * rows).min(plane_rows[pl]);
                                let r = core::mem::take(&mut rest[pl]);
                                let (_, r) = r.split_at_mut((y0 - at[pl]) * stride[pl]);
                                let (band, r) = r.split_at_mut((y1 - y0) * stride[pl]);
                                rest[pl] = r;
                                at[pl] = y1;
                                e[pl] = (band, y0);
                            }
                            Some((uy, e))
                        });
                        let n = (ur - phase).div_ceil(1 + pass);
                        par(threads, n, items, |_, (uy, mut e)| {
                            for ux in 0..uc {
                                if k_of(ux as isize, uy as isize) != K_FILTER {
                                    continue;
                                }
                                let rows = (16 * uy as i32, 16 * uy as i32 + 16);
                                let cols = (16 * ux as i32, 16 * ux as i32 + 16);
                                for (pl, (band, y0)) in e.iter_mut().enumerate().take(nplanes) {
                                    deblock_rect(&pf, &m, pl, pass, band, *y0, stride[pl], rows, cols);
                                }
                            }
                        });
                    }
                }
            }
        }
        let ms_filters = ms(t3);

        // ---- the output picture: filtered units through CDEF, copies where it differs ----
        let t4 = Instant::now();
        let n_written = {
            let (tbufs, unit_tc, band_tr, kind) = (&self.tiles[..ntiles], &self.unit_tc, &self.band_tr, &self.kind);
            let src: [&[u8]; 3] = [&self.s[0], &self.s[1], &self.s[2]];
            let [d0, d1, d2] = &mut d.planes;
            let rows: [usize; 3] = core::array::from_fn(|p| 64 >> geo.sub(p));
            let items = bands(d0, stride[0], rows[0])
                .zip(bands(d1, stride[1].max(1), rows[1]).chain(std::iter::repeat_with(|| &mut [][..])))
                .zip(bands(d2, stride[2].max(1), rows[2]).chain(std::iter::repeat_with(|| &mut [][..])));
            let written = AtomicUsize::new(0);
            par(threads, ur, items, |uy, ((a, b), c)| {
                let mut band: [&mut [u8]; 3] = [a, b, c];
                let t_row = band_tr[uy] as usize;
                let mut nw = 0;
                for ux in 0..uc {
                    let k = kind[uy * uc + ux];
                    if k & K_DIRTY == 0 {
                        continue;
                    }
                    nw += 1;
                    match k & !K_DIRTY {
                        K_FILTER if cdef => {
                            let (r, c) = (16 * uy as i32, 16 * ux as i32);
                            cdef_rect(&pf, &m, &src, &stride, &mut band, &stride, r, (r, r + 16), (c, c + 16));
                        }
                        K_FILTER => {
                            for p in 0..nplanes {
                                let (n, sub) = (rows[p], geo.sub(p) as usize);
                                copy_rect(
                                    src[p],
                                    stride[p],
                                    band[p],
                                    stride[p],
                                    (ux * 64) >> sub,
                                    uy * n,
                                    uy * n,
                                    n,
                                    n,
                                );
                            }
                        }
                        K_CLEAN => {
                            let t = &tbufs[t_row * tiles.cols as usize + unit_tc[ux] as usize];
                            for p in 0..nplanes {
                                let (n, sub) = (rows[p], geo.sub(p) as usize);
                                let (tx, ty) = (
                                    (ux * 64 - t.c0 as usize * 4) >> sub,
                                    (uy * 64 - t.r0 as usize * 4) >> sub,
                                );
                                for i in 0..n {
                                    band[p][i * stride[p] + ((ux * 64) >> sub)..][..n]
                                        .copy_from_slice(&t.plane[p][(ty + i) * t.stride[p] + tx..][..n]);
                                }
                            }
                        }
                        k => {
                            let r = if k == K_COPY_GOLDEN { goldp } else { lastp };
                            if let Some(r) = r {
                                for p in 0..nplanes {
                                    let (n, sub) = (rows[p], geo.sub(p) as usize);
                                    copy_rect(
                                        &r.planes[p],
                                        stride[p],
                                        band[p],
                                        stride[p],
                                        (ux * 64) >> sub,
                                        uy * n,
                                        uy * n,
                                        n,
                                        n,
                                    );
                                }
                            }
                        }
                    }
                }
                written.fetch_add(nw, Ordering::Relaxed);
            });
            written.into_inner() as u32
        };
        // the saved CDFs: the context tile's, or (no frame-end update) the ones it started from
        let cdfs = d.cdfs.get_or_insert_with(|| Box::new(FrameCdfs::new(0)));
        if hdr.end_update {
            core::mem::swap(&mut self.saved.get_mut().unwrap_or_else(|e| e.into_inner()).1, cdfs);
        } else if let Some(c) = cdfs_in {
            (**cdfs).clone_from(c);
        } else {
            cdfs.cdf.init(fp.base_q_idx as i32);
            cdfs.icdf.init();
        }
        d.deltas = hdr.deltas;
        d.key = !hdr.inter;
        d.render = hdr.render;
        d.colour = sq.colour;
        self.t_key = Some(key);
        let ms_output = ms(t4);
        self.stats = Stats {
            tiles: ntiles as u32,
            tile_threads: nw as u32,
            units_copy: n_copy,
            units_clean: n_clean,
            units_filter: n_filter,
            units_written: n_written,
            ms_header,
            ms_tiles,
            ms_maps,
            ms_filters,
            ms_output,
        };
        Ok(())
    }
}

static EMPTY_ORDMAP: [Vec<u32>; 3] = [Vec::new(), Vec::new(), Vec::new()];
