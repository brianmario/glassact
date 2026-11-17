//! The decoder's size cap ([`Decoder::with_max_size`], `av1g_decoder_create_capped`), held to what
//! it allocates: a counting allocator (this test binary's own) tracks the live heap, and its peak
//! while a decoder works is compared with what a frame at the cap implies.
//! - A few-byte temporal unit for a 4096x2048 frame (one byte a tile) costs an uncapped decoder
//!   tens of MB (8192x8192: hundreds); a decoder capped at 1280x720 refuses it having allocated
//!   nothing for it.
//! - Streams decode exactly at their own size as the cap, and are refused one sample under it.
//! - Hostile input (truncated, bit-flipped, overwritten units, sequence headers whose sizes are
//!   damaged) through a decoder capped at the stream's size never takes more than the pictures
//!   and buffers of a frame that size.
use glassact_av1::decoder::{Decoder, MAX_DIM};
use glassact_av1::tables::BLOCK_64X64;
use glassact_av1::testsupport::inter_gen::InterSeq;
use glassact_av1::types::{
    Block, DECISIONS_VERSION, ENC_FIX_RANGE, ENC_NO_SEQ_HEADER, ENC_TD, EncodeOpts, FRAME_KEY, FrameParams,
};
use glassact_av1::writer::{Output, Record, RefPicture, RefSlots, Writer, parse, tile_layout_ex};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicI64, Ordering::Relaxed};

struct Counting;
static LIVE: AtomicI64 = AtomicI64::new(0);
static PEAK: AtomicI64 = AtomicI64::new(0);

fn grew(n: i64) {
    let now = LIVE.fetch_add(n, Relaxed) + n;
    PEAK.fetch_max(now, Relaxed);
}

// SAFETY: forwards to the system allocator, counting the live bytes and their peak.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        grew(l.size() as i64);
        // SAFETY: the caller's layout.
        unsafe { System.alloc(l) }
    }
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        grew(l.size() as i64);
        // SAFETY: the caller's layout.
        unsafe { System.alloc_zeroed(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        LIVE.fetch_sub(l.size() as i64, Relaxed);
        // SAFETY: p came from alloc with l.
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        grew(n as i64 - l.size() as i64);
        // SAFETY: as GlobalAlloc::realloc.
        unsafe { System.realloc(p, l, n) }
    }
}

#[global_allocator]
static A: Counting = Counting;

/// The heap's peak growth while `f` runs, in bytes.
fn peak_growth<R>(f: impl FnOnce() -> R) -> (R, i64) {
    let base = LIVE.load(Relaxed);
    PEAK.store(base, Relaxed);
    let r = f();
    (r, PEAK.load(Relaxed) - base)
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        if n == 0 { 0 } else { self.next() % n }
    }
}

/// Random sequence `seed`'s temporal units, as the writer codes them (frames up to `maxdim`).
fn stream(seed: u64, maxdim: i32) -> Option<Vec<Vec<u8>>> {
    let mut seq = InterSeq::make(seed, maxdim, 8)?;
    let mut w = Writer::with_threads(2);
    let mut outs: Vec<Output> = Vec::new();
    let mut slot_of = [usize::MAX; 8];
    for (k, rec) in seq.frames.iter_mut().enumerate() {
        let refs: RefSlots =
            core::array::from_fn(|s| (slot_of[s] != usize::MAX).then(|| RefPicture::from_output(&outs[slot_of[s]])));
        let mut out = Output::default();
        let flags = ENC_FIX_RANGE | ENC_TD | (seq.flags[k] & ENC_NO_SEQ_HEADER);
        let opts = EncodeOpts {
            flags,
            seq_level_idx: -1,
        };
        w.encode_ex(rec.as_mut(), &opts, &refs, &mut out).ok()?;
        let refresh = if rec.fp.frame_type == FRAME_KEY {
            0xFF
        } else {
            rec.fp.refresh_frame_flags
        };
        for (s, slot) in slot_of.iter_mut().enumerate() {
            if refresh >> s & 1 != 0 {
                *slot = k;
            }
        }
        outs.push(out);
    }
    Some(outs.into_iter().map(|o| o.obu).collect())
}

/// A stream's size: its frames', or a reduced frame's stream size (what its sequence header says).
fn stream_size(tus: &[Vec<u8>]) -> (u32, u32) {
    let mut d = Decoder::new(1);
    tus.iter().fold((0, 0), |(w, h), tu| {
        let p = d.decode(tu).unwrap();
        (w.max(p.width.max(p.render_width)), h.max(p.height.max(p.render_height)))
    })
}

/// A key frame of one skipped DC_PRED 64x64 a superblock (sides multiples of 64), in tile order.
fn flat_record(w: u32, h: u32) -> Record {
    let tiles = tile_layout_ex(w, h, -1, -1, false).unwrap();
    let mut fp = FrameParams {
        version: DECISIONS_VERSION,
        width: w,
        height: h,
        base_q_idx: 120,
        video: 1,
        tile_cols_log2: tiles.cols_log2 as i8,
        tile_rows_log2: tiles.rows_log2 as i8,
        ..Default::default()
    };
    fp.loop_filter_level = [10, 10, 5, 5];
    let mut blocks = Vec::new();
    for tr in 0..tiles.rows as usize {
        for tc in 0..tiles.cols as usize {
            for r in (tiles.mi_row_starts[tr]..tiles.mi_row_starts[tr + 1]).step_by(16) {
                for c in (tiles.mi_col_starts[tc]..tiles.mi_col_starts[tc + 1]).step_by(16) {
                    blocks.push(Block {
                        mi_row: r as u16,
                        mi_col: c as u16,
                        bsize: BLOCK_64X64 as u8,
                        skip: 1,
                        ..Default::default()
                    });
                }
            }
        }
    }
    let mut rec = Record::new(fp, blocks);
    rec.layout().unwrap();
    rec
}

/// `tu`'s frame with every tile's payload cut to one byte, its tile sizes and OBU size rewritten:
/// a well-formed unit of a few bytes for a whole frame.
fn one_byte_tiles(tu: &[u8]) -> Vec<u8> {
    let p = parse(tu).unwrap();
    let (offs, sizes) = (&p.tile_offsets, &p.tile_bytes);
    let n = offs.len();
    let tsb = if n > 1 {
        (offs[1] - offs[0]) as usize - sizes[0] as usize
    } else {
        0
    };
    let first = offs[0] as usize - tsb;
    let mut pos = 0;
    let mut frame_at = None;
    while pos < tu.len() {
        let h = tu[pos];
        let (ty, ext) = ((h >> 3) & 15, (h >> 2) & 1);
        let start = pos;
        pos += 1 + ext as usize;
        let (mut sz, mut i) = (0usize, 0);
        loop {
            let b = tu[pos];
            pos += 1;
            sz |= ((b & 0x7f) as usize) << (7 * i);
            i += 1;
            if b & 0x80 == 0 {
                break;
            }
        }
        if ty == 6 {
            frame_at = Some((start, pos));
            break;
        }
        pos += sz;
    }
    let (start, payload) = frame_at.unwrap();
    let mut body = tu[payload..first].to_vec();
    for k in 0..n {
        if k + 1 < n {
            body.extend(std::iter::repeat_n(0u8, tsb));
        }
        body.push(0x5a);
    }
    let mut out = tu[..start].to_vec();
    out.push(tu[start] | 2);
    let mut v = body.len();
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        out.push(if v != 0 { b | 0x80 } else { b });
        if v == 0 {
            break;
        }
    }
    out.extend_from_slice(&body);
    out
}

/// What a decoder capped at `w` x `h` may hold at most: its nine pictures, the frame-level planes
/// the filters run on and the tiles' planes (each three planes of the frame padded to 64x64s, 4:4:4
/// at worst), and a fixed part (CDFs, the tile walk's contexts, the pool) measured at the smallest
/// size.
fn bound(w: u32, h: u32, fixed: i64) -> i64 {
    let (wp, hp) = (w.div_ceil(64) as i64 * 64, h.div_ceil(64) as i64 * 64);
    (9 + 1 + 1) * 3 * wp * hp + 2 * wp * hp + fixed
}

#[test]
fn the_cap_bounds_what_the_decoder_allocates() {
    // ---- a few bytes for a 4096x4096 frame ----
    let mut out = Output::default();
    let opts = EncodeOpts {
        flags: ENC_FIX_RANGE | ENC_TD,
        seq_level_idx: -1,
    };
    Writer::new()
        .encode(flat_record(4096, 2048).as_mut(), &opts, &mut out)
        .unwrap();
    let tiny = one_byte_tiles(&out.obu);
    assert!(tiny.len() < 64, "{} bytes", tiny.len());
    let (mut open_d, mut capped_d) = (Decoder::new(4), Decoder::with_max_size(4, 1280, 720));
    let (r, open) = peak_growth(|| open_d.decode(&tiny).map(|_| ()).map_err(|e| e.msg));
    let (r2, capped) = peak_growth(|| capped_d.decode(&tiny).map(|_| ()).map_err(|e| e.msg));
    eprintln!(
        "{} bytes for 4096x2048: uncapped {:?}, peak +{:.1} MB; capped at 1280x720 {:?}, peak +{} bytes",
        tiny.len(),
        r,
        open as f64 / 1e6,
        r2,
        capped
    );
    assert!(
        r.is_ok() && open > 30_000_000,
        "the uncapped decoder: {r:?}, {open} bytes"
    );
    let msg = r2.expect_err("a 4096x2048 frame in a 1280x720 decoder");
    assert!(msg.contains("larger than the decoder's 1280x720"), "{msg}");
    assert!(
        capped < 1024,
        "the capped decoder allocated {capped} bytes for a frame it refused"
    );
    // the cap's own bounds
    assert_eq!(Decoder::with_max_size(1, 0, 0).max_size(), (MAX_DIM, MAX_DIM));
    assert_eq!(Decoder::with_max_size(1, 9000, 77).max_size(), (MAX_DIM, 77));
    assert_eq!(Decoder::new(1).max_size(), (MAX_DIM, MAX_DIM));

    // ---- streams at their own size; one sample under it ----
    let streams: Vec<(Vec<Vec<u8>>, (u32, u32))> = (0..24)
        .filter_map(|s| stream(s, 300))
        .map(|tus| {
            let size = stream_size(&tus);
            (tus, size)
        })
        .collect();
    assert!(streams.len() >= 12);
    let mut fixed = 0i64;
    let mut checked = 0;
    for (k, (tus, (sw, sh))) in streams.iter().enumerate() {
        let (sw, sh) = (*sw, *sh);
        let mut plain = Decoder::new(2);
        let mut at_cap = Decoder::with_max_size(2, sw, sh);
        for (i, tu) in tus.iter().enumerate() {
            let a: Vec<Vec<u8>> = {
                let pic = plain.decode(tu).unwrap_or_else(|e| panic!("stream {k} frame {i}: {e}"));
                (0..3).map(|q| pic.planes[q].to_vec()).collect()
            };
            let pic = at_cap
                .decode(tu)
                .unwrap_or_else(|e| panic!("stream {k} frame {i}, capped: {e}"));
            for (q, plane) in a.iter().enumerate() {
                assert!(pic.planes[q] == &plane[..], "stream {k} frame {i} plane {q}");
            }
        }
        if sw <= 64 && sh <= 64 {
            let (_, grown) = peak_growth(|| {
                let mut d = Decoder::with_max_size(2, sw, sh);
                for tu in tus {
                    d.decode(tu).unwrap();
                }
            });
            fixed = fixed.max(grown);
        }
        for (cw, ch) in [(sw - 1, sh), (sw, sh - 1)] {
            if cw == 0 || ch == 0 {
                continue;
            }
            let mut under = Decoder::with_max_size(2, cw, ch);
            let e = under
                .decode(&tus[0])
                .map(|_| ())
                .expect_err("a stream larger than the cap");
            assert!(e.msg.contains("larger than the decoder's"), "stream {k}: {}", e.msg);
            checked += 1;
        }
    }
    assert!(checked >= 12);
    let fixed = fixed.max(4 << 20);

    // ---- hostile input under the cap ----
    let mut rng = Rng(0x0C4F_D00D);
    let (mut cases, mut refused_size, mut worst) = (0usize, 0, 0f64);
    for (k, (tus, (sw, sh))) in streams.iter().enumerate() {
        let (sw, sh) = (*sw, *sh);
        let limit = bound(sw, sh, fixed);
        for _ in 0..120 {
            let mut d = Decoder::with_max_size(1 + cases % 3, sw, sh);
            let mut damaged: Vec<Vec<u8>> = tus.clone();
            let at = rng.below(tus.len() as u64) as usize;
            let tu = &mut damaged[at];
            match rng.below(4) {
                0 => tu.truncate(rng.below(tu.len() as u64 + 1) as usize),
                // the sequence header's sizes (just past the temporal delimiter and OBU header)
                1 => {
                    for _ in 0..1 + rng.below(3) {
                        let i = 4 + rng.below(8) as usize;
                        if i < tu.len() {
                            tu[i] ^= 1 << rng.below(8);
                        }
                    }
                }
                2 => {
                    for _ in 0..1 + rng.below(4) {
                        let lim = tu.len().min(48);
                        if lim > 0 {
                            let i = rng.below(lim as u64) as usize;
                            tu[i] ^= 1 << rng.below(8);
                        }
                    }
                }
                _ => {
                    if !tu.is_empty() {
                        let a = rng.below(tu.len() as u64) as usize;
                        let b = (a + 1 + rng.below(64) as usize).min(tu.len());
                        for x in &mut tu[a..b] {
                            *x = rng.next() as u8;
                        }
                    }
                }
            }
            let (_, grown) = peak_growth(|| {
                for tu in &damaged {
                    if let Err(e) = d.decode(tu)
                        && e.msg.contains("larger than the decoder's")
                    {
                        refused_size += 1;
                    }
                }
            });
            assert!(
                grown <= limit,
                "stream {k} ({sw}x{sh}): hostile input took {grown} bytes, over {limit}"
            );
            worst = worst.max(grown as f64 / limit as f64);
            cases += 1;
        }
    }
    eprintln!(
        "{} streams; {cases} hostile cases under the cap, {refused_size} decodes refused for their size; at most {:.0} % of the bound (fixed part {:.1} MB)",
        streams.len(),
        worst * 100.0,
        fixed as f64 / 1e6
    );
    assert!(refused_size > 0);
}
