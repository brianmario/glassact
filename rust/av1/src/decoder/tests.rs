//! The decoder against the writer's reconstructions (which dav1d and libaom reproduce: the
//! writer's `decoders` tests) on random streams, against the installed decoders, on the 5K
//! streams, and on hostile input.
use super::*;
use crate::blockinfo::{mi_cols, mi_rows};
use crate::tables::{BLOCK_64X64, BLOCK_128X128};
use crate::testsupport::inter_gen::InterSeq;
use crate::types::{Block, BlockInter, ENC_FIX_RANGE, ENC_TD, EncodeOpts, FRAME_INTER, FRAME_KEY};
use crate::writer::chroma444_tests::record_444;
use crate::writer::inter_tests::{encode_seq, ivf, reduce, sb128_still};
use crate::writer::palette_tests::{add_palettes, fuzz_record};
use crate::writer::{Output, ParseState, Record, RefPicture, RefSlots, Writer, parse_with};
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

/// splitmix64
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
    fn chance(&mut self, pct: u64) -> bool {
        self.below(100) < pct
    }
}

/// `f(seed)` for seeds 0..n on up to 8 threads.
fn seeds(n: u64, f: impl Fn(u64) + Sync) {
    let next = AtomicU64::new(0);
    std::thread::scope(|s| {
        for _ in 0..std::thread::available_parallelism().map_or(4, |n| n.get()).min(8) {
            s.spawn(|| {
                loop {
                    let k = next.fetch_add(1, Relaxed);
                    if k >= n {
                        break;
                    }
                    f(k);
                }
            });
        }
    });
}

/// Whether `pic` is `out`'s reconstruction, plane by plane.
fn same(pic: &Picture, out: &Output) -> Result<(), String> {
    for p in 0..if pic.monochrome { 1 } else { 3 } {
        let (w, h) = (out.recon_w[p] as usize, out.recon_h[p] as usize);
        if (pic.plane_w[p] as usize, pic.plane_h[p] as usize) != (w, h) {
            return Err(format!("plane {p}: {}x{} for {w}x{h}", pic.plane_w[p], pic.plane_h[p]));
        }
        for y in 0..h {
            let (a, b) = (&pic.planes[p][y * pic.stride[p]..][..w], &out.recon[p][y * w..][..w]);
            if a != b {
                let x = (0..w).find(|&x| a[x] != b[x]).unwrap();
                return Err(format!("plane {p} differs first at ({x}, {y}): {} for {}", a[x], b[x]));
            }
        }
    }
    Ok(())
}

/// What the decoders did over a test: frames, and 64x64s copied, clean, filtered, written.
#[derive(Default)]
struct Cov {
    frames: AtomicU64,
    inter: AtomicU64,
    copy: AtomicU64,
    clean: AtomicU64,
    filter: AtomicU64,
    written: AtomicU64,
}

impl Cov {
    fn add(&self, s: &Stats, inter: bool) {
        self.frames.fetch_add(1, Relaxed);
        self.inter.fetch_add(inter as u64, Relaxed);
        self.copy.fetch_add(s.units_copy as u64, Relaxed);
        self.clean.fetch_add(s.units_clean as u64, Relaxed);
        self.filter.fetch_add(s.units_filter as u64, Relaxed);
        self.written.fetch_add(s.units_written as u64, Relaxed);
    }
    fn report(&self) -> String {
        format!(
            "{} frames ({} inter); 64x64s copied {}, as decoded {}, filtered {}; written {}",
            self.frames.load(Relaxed),
            self.inter.load(Relaxed),
            self.copy.load(Relaxed),
            self.clean.load(Relaxed),
            self.filter.load(Relaxed),
            self.written.load(Relaxed)
        )
    }
}

/// Makes most whole superblocks of `seq`'s inter frames one skipped block copying LAST_FRAME (or
/// GOLDEN_FRAME) with no motion, as the hybrid's copied 64x64s are (frames with delta-q, whose
/// superblock qindex chain it would break, are left alone).
fn copy_variant(seq: &mut InterSeq, seed: u64) {
    let mut r = Rng(seed ^ 0xC0FF_EE00_D15C_0DE5);
    for rec in &mut seq.frames {
        let fp = rec.fp;
        if fp.frame_type != FRAME_INTER || fp.delta_q_present != 0 {
            continue;
        }
        let sb4 = if fp.sb128 != 0 { 32 } else { 16 };
        let sb_bsize = if fp.sb128 != 0 { BLOCK_128X128 } else { BLOCK_64X64 };
        let (mc, mr) = (mi_cols(fp.width as i32), mi_rows(fp.height as i32));
        let pct = [60, 85, 97][r.below(3) as usize];
        // as the hybrid's: inter blocks not deblocked
        rec.fp.lf_inter_off = r.chance(80) as u8;
        let (mut blocks, mut inter) = (Vec::new(), Vec::new());
        let n = rec.blocks.len();
        let mut i = 0;
        while i < n {
            let b0 = rec.blocks[i];
            let sb = |b: &Block| (b.mi_row as i32 / sb4, b.mi_col as i32 / sb4);
            let (sr, sc) = sb(&b0);
            let mut j = i;
            while j < n && sb(&rec.blocks[j]) == (sr, sc) {
                j += 1;
            }
            if (sr + 1) * sb4 <= mr && (sc + 1) * sb4 <= mc && r.chance(pct) {
                blocks.push(Block {
                    mi_row: (sr * sb4) as u16,
                    mi_col: (sc * sb4) as u16,
                    bsize: sb_bsize as u8,
                    skip: 1,
                    cdef_idx: b0.cdef_idx,
                    sb_qindex: b0.sb_qindex,
                    ..Default::default()
                });
                let golden = fp.golden_slot != 0 && r.chance(25);
                inter.push(BlockInter {
                    is_inter: if golden { GOLDEN } else { 1 },
                    ..Default::default()
                });
            } else {
                blocks.extend_from_slice(&rec.blocks[i..j]);
                inter.extend_from_slice(&rec.inter[i..j]);
            }
            i = j;
        }
        (rec.blocks, rec.inter) = (blocks, inter);
        rec.palette.clear();
        rec.palette_map.clear();
        rec.layout().unwrap();
    }
}

/// Random sequence `seed` as the tests vary it: sometimes copy-heavy, reduced, with palettes.
fn test_seq(seed: u64, maxdim: i32, nframes: usize) -> Option<InterSeq> {
    let copies = seed.is_multiple_of(2);
    let mut seq = InterSeq::make(seed, if copies { 2 * maxdim } else { maxdim }, nframes)?;
    if copies {
        copy_variant(&mut seq, seed);
    }
    if seed % 3 == 1 {
        reduce(&mut seq, seed);
    }
    if seed % 5 == 2 {
        for (k, rec) in seq.frames.iter_mut().enumerate() {
            add_palettes(rec, seed + 1000 * k as u64, 40);
        }
    }
    Some(seq)
}

/// Every frame of random sequences (key and inter frames, every tool the writer has; copy-heavy,
/// reduced, with palettes) decodes to exactly the writer's reconstruction, by the copy path and
/// by the full one, on one thread and several.
#[test]
fn sequences_decode_as_written() {
    let (fast, full) = (Cov::default(), Cov::default());
    seeds(160, |seed| {
        let Some(mut seq) = test_seq(seed, 200, 8) else {
            return;
        };
        let mut w = Writer::with_threads(2);
        let outs = encode_seq(&mut w, &mut seq, ENC_FIX_RANGE | ENC_TD)
            .unwrap_or_else(|(k, e)| panic!("seed {seed} frame {k}: encode: {e}"));
        let mut a = Decoder::new(1 + (seed % 3) as usize);
        let mut b = Decoder::new(2);
        b.set_full(true);
        for (k, out) in outs.iter().enumerate() {
            let inter = seq.frames[k].fp.frame_type == FRAME_INTER;
            for (d, cov, what) in [(&mut a, &fast, "copy path"), (&mut b, &full, "full path")] {
                let pic = d
                    .decode(&out.obu)
                    .unwrap_or_else(|e| panic!("seed {seed} frame {k} ({what}): {e}"));
                same(&pic, out).unwrap_or_else(|e| panic!("seed {seed} frame {k} ({what}): {e}"));
                cov.add(&d.stats(), inter);
            }
        }
    });
    let elided = crate::writer::decode::ELIDED.load(Relaxed);
    eprintln!(
        "copy path: {}; {elided} inter blocks not predicted\nfull path: {}",
        fast.report(),
        full.report()
    );
    assert!(fast.copy.load(Relaxed) > 200 && fast.clean.load(Relaxed) > 1000 && elided > 200);
    assert!(
        fast.written.load(Relaxed) < fast.copy.load(Relaxed) + fast.clean.load(Relaxed) + fast.filter.load(Relaxed)
    );
    assert_eq!(full.copy.load(Relaxed) + full.clean.load(Relaxed), 0);
}

/// Still pictures (palettes, 128x128 superblocks), 4:4:4 key frames and still pictures (filters
/// on and off, intra block copy, palettes), one decoder for all: each its writer's
/// reconstruction.
#[test]
fn stills_and_444_decode_as_written() {
    let cov = Cov::default();
    let n444 = AtomicU64::new(0);
    seeds(150, |seed| {
        let mut w = Writer::with_threads(2);
        let mut d = Decoder::new(1 + (seed % 4) as usize);
        let mut recs: Vec<(Record, &str)> = Vec::new();
        if let Some(mut r) = fuzz_record(seed, 300) {
            add_palettes(&mut r, seed, 40);
            recs.push((r, "still"));
        }
        if let Some(r) = sb128_still(seed, 300) {
            recs.push((r, "still, 128x128 superblocks"));
        }
        for filters in [true, false] {
            if let Some(r) = record_444(seed, 200, filters) {
                recs.push((r, if filters { "4:4:4, filters" } else { "4:4:4" }));
            }
        }
        for (mut rec, what) in recs {
            if rec.fp.width > MAX_DIM || rec.fp.height > MAX_DIM {
                continue; // (the writer's, not the decoder's)
            }
            let opts = EncodeOpts {
                flags: ENC_FIX_RANGE | ENC_TD,
                seq_level_idx: -1,
            };
            let mut out = Output::default();
            w.encode(rec.as_mut(), &opts, &mut out).unwrap();
            let pic = d.decode(&out.obu).unwrap_or_else(|e| panic!("seed {seed} {what}: {e}"));
            same(&pic, &out).unwrap_or_else(|e| panic!("seed {seed} {what}: {e}"));
            assert!(pic.key);
            if rec.fp.chroma_format == CHROMA_444 {
                assert_eq!(pic.chroma_format, CHROMA_444);
                n444.fetch_add(1, Relaxed);
            }
            cov.add(&d.stats(), false);
        }
    });
    eprintln!("{}; {} in 4:4:4", cov.report(), n444.load(Relaxed));
    assert!(n444.load(Relaxed) > 200);
}

/// The region post-filters (NEON on aarch64) against their scalar references, on random pictures
/// and maps, by rectangles of whole 64x64s in bands as the decoder runs them.
#[test]
fn region_filters_match_scalar() {
    use crate::postfilter::{cdef_rect_scalar, deblock_rect_scalar};
    let mut r = Rng(7);
    for case in 0..60 {
        let ss = if case % 4 == 3 { 0 } else { 1 };
        let (w, h) = (8 + r.below(300) as u32, 8 + r.below(200) as u32);
        let mut fp = crate::types::FrameParams {
            width: w,
            height: h,
            chroma_format: (ss == 0) as u8,
            version: crate::types::DECISIONS_VERSION,
            ..Default::default()
        };
        fp.loop_filter_level = [
            1 + r.below(63) as u8,
            1 + r.below(63) as u8,
            r.below(64) as u8,
            r.below(64) as u8,
        ];
        fp.loop_filter_sharpness = r.below(8) as u8;
        fp.enable_cdef = 1;
        fp.cdef_damping_minus_3 = r.below(4) as u8;
        fp.cdef_bits = 3;
        for i in 0..8 {
            fp.cdef_y_pri[i] = r.below(16) as u8;
            fp.cdef_y_sec[i] = [0, 1, 2, 4][r.below(4) as usize];
            fp.cdef_uv_pri[i] = r.below(16) as u8;
            fp.cdef_uv_sec[i] = [0, 1, 2, 4][r.below(4) as usize];
        }
        let f = PfFrame::new(&fp);
        let (mc, mr) = (f.mi_cols as usize, f.mi_rows as usize);
        let (uc, ur) = (f.sb_cols as usize, f.sb_rows as usize);
        let txs = [0u8, 1, 2, 3, 4];
        let skip: Vec<u8> = (0..mc * mr)
            .map(|_| r.chance(30) as u8 | if r.chance(20) { LF_ZERO } else { 0 })
            .collect();
        // tx sizes in aligned squares, so that edges lie where blocks would put them
        let mut lf_tx: [Vec<u8>; 3] = Default::default();
        for p in 0..3 {
            let (cw, ch) = if p == 0 { (mc, mr) } else { (mc >> ss, mr >> ss) };
            let mut m = vec![0u8; cw * ch];
            for y in (0..ch).step_by(4) {
                for x in (0..cw).step_by(4) {
                    let t = txs[r.below(3) as usize];
                    for yy in y..(y + 4).min(ch) {
                        for xx in x..(x + 4).min(cw) {
                            m[yy * cw + xx] = t;
                        }
                    }
                }
            }
            lf_tx[p] = m;
        }
        let cdef_idx: Vec<i8> = (0..uc * ur).map(|_| r.below(9) as i8 - 1).collect();
        let m = PfMaps {
            skip: &skip,
            lf_tx: [&lf_tx[0], &lf_tx[1], &lf_tx[2]],
            cdef_idx: &cdef_idx,
        };
        let stride: [usize; 3] = core::array::from_fn(|p| (uc * 64) >> if p > 0 { ss } else { 0 });
        let rows: [usize; 3] = core::array::from_fn(|p| (ur * 64) >> if p > 0 { ss } else { 0 });
        let planes: Vec<Vec<u8>> = (0..3)
            .map(|p| {
                let mut v = vec![0u8; stride[p] * rows[p]];
                let mut base = r.below(256) as i32;
                for s in v.iter_mut() {
                    base = (base + r.below(7) as i32 - 3).clamp(0, 255);
                    *s = base as u8;
                }
                v
            })
            .collect();
        // deblocking: the scalar frame order against NEON rectangles, pass 0 then pass 1
        let mut a = planes.clone();
        let mut b = planes.clone();
        for p in 0..3 {
            for pass in 0..2 {
                deblock_rect_scalar(&f, &m, p, pass, &mut a[p], 0, stride[p], (0, f.mi_rows), (0, f.mi_cols));
                for uy in 0..ur {
                    for ux in 0..uc {
                        let y0 = ((uy * 64) >> if p > 0 { ss } else { 0 }).saturating_sub(8 * pass);
                        let pl = &mut b[p][y0 * stride[p]..];
                        let (rr, cc) = (
                            (16 * uy as i32, 16 * uy as i32 + 16),
                            (16 * ux as i32, 16 * ux as i32 + 16),
                        );
                        deblock_rect(&f, &m, p, pass, pl, y0, stride[p], rr, cc);
                    }
                }
            }
        }
        assert!(a == b, "case {case}: deblocking");
        // CDEF: the scalar reference against cdef_rect by unit, into bands
        let src: [&[u8]; 3] = [&a[0], &a[1], &a[2]];
        let mut da: Vec<Vec<u8>> = (0..3).map(|p| vec![0u8; stride[p] * rows[p]]).collect();
        let mut db = da.clone();
        {
            let [x0, x1, x2] = &mut da[..] else { unreachable!() };
            let mut dst: [&mut [u8]; 3] = [x0, x1, x2];
            cdef_rect_scalar(
                &f,
                &m,
                &src,
                &stride,
                &mut dst,
                &stride,
                0,
                (0, f.mi_rows),
                (0, f.mi_cols),
            );
        }
        for uy in 0..ur {
            for ux in 0..uc {
                let [x0, x1, x2] = &mut db[..] else { unreachable!() };
                let mut dst: [&mut [u8]; 3] = [x0, x1, x2];
                let off: [usize; 3] = core::array::from_fn(|p| ((uy * 64) >> if p > 0 { ss } else { 0 }) * stride[p]);
                let mut band: [&mut [u8]; 3] =
                    core::array::from_fn(|p| core::mem::take(&mut dst[p]).split_at_mut(off[p]).1);
                let (rr, cc) = (
                    (16 * uy as i32, 16 * uy as i32 + 16),
                    (16 * ux as i32, 16 * ux as i32 + 16),
                );
                cdef_rect(&f, &m, &src, &stride, &mut band, &stride, rr.0, rr, cc);
            }
        }
        assert!(da == db, "case {case}: CDEF");
    }
}

/// What the decoder refuses: a stream it doesn't have the references for, other sizes of
/// reference, and frames past its limits.
#[test]
fn refusals() {
    let mut seq = InterSeq::make(5, 120, 3).unwrap();
    for rec in &mut seq.frames[1..] {
        rec.fp.frame_type = FRAME_INTER;
    }
    let mut w = Writer::with_threads(1);
    let Ok(outs) = encode_seq(&mut w, &mut seq, ENC_FIX_RANGE | ENC_TD) else {
        return;
    };
    let mut d = Decoder::new(2);
    // an inter frame first: no reference
    if seq.frames[1].fp.frame_type == FRAME_INTER {
        let e = d
            .decode(&outs[1].obu)
            .expect_err("an inter frame without its references");
        assert_eq!(e.code, ERR_NO_REFERENCE, "{}", e.msg);
    }
    d.decode(&outs[0].obu).unwrap();
    d.reset();
    let e = d.decode(&outs[1].obu).expect_err("an inter frame after reset");
    assert!(e.code == ERR_NO_REFERENCE, "{}", e.msg);
    assert!(d.picture().is_none());
    // two frames in a temporal unit; nothing at all
    let mut two = outs[0].obu.clone();
    two.extend_from_slice(&outs[0].obu[2..]);
    assert!(d.decode(&two).is_err());
    assert!(d.decode(&[]).is_err());
    // a sequence header for frames larger than MAX_DIM (a reduced still picture's), and a frame
    for (w, h, ok) in [(MAX_DIM + 1, 16, false), (16, MAX_DIM + 8, false), (MAX_DIM, 16, true)] {
        let mut b = crate::writer::BitWriter::default();
        b.put(0, 3);
        b.put(1, 1);
        b.put(1, 1);
        b.put(31, 5);
        b.put(15, 4);
        b.put(15, 4);
        b.put(w - 1, 16);
        b.put(h - 1, 16);
        b.put(0, 3); // no 128x128 superblocks, filter intra or edge filter
        b.put(0, 3); // no superres, CDEF, restoration
        b.put(0, 1); // 8-bit
        b.put(0, 1); // not monochrome
        b.put(0, 1); // no colour description
        b.put(0, 4); // range, chroma position, separate_uv
        b.put(0, 1); // film grain
        b.trailing_bits();
        let mut tu = vec![0x12, 0x00, 0x0A, b.buf.len() as u8];
        tu.extend_from_slice(&b.buf);
        tu.extend_from_slice(&[0x32, 0x02, 0x00, 0x00]);
        let e = d.decode(&tu).expect_err("no frame to speak of");
        assert_eq!(!e.msg.contains("a side"), ok, "{w}x{h}: {}", e.msg);
    }
}

/// The C API (av1g/decoder.h) over the decoder: a stream's frames, the picture again, errors with
/// their messages, reset.
#[cfg(feature = "capi")]
#[test]
fn c_api() {
    use crate::capi::*;
    use crate::types::DecPicture;
    let mut seq = InterSeq::make(11, 150, 4).unwrap();
    let outs = encode_seq(&mut Writer::with_threads(1), &mut seq, ENC_FIX_RANGE | ENC_TD).unwrap();
    let d = av1g_decoder_create(3);
    let mut err = [0 as core::ffi::c_char; 128];
    let msg = |e: &[core::ffi::c_char]| {
        unsafe { core::ffi::CStr::from_ptr(e.as_ptr()) }
            .to_string_lossy()
            .into_owned()
    };
    for (k, o) in outs.iter().enumerate() {
        let mut p = DecPicture::default();
        let r = unsafe { av1g_decoder_decode(d, o.obu.as_ptr(), o.obu.len(), &mut p, err.as_mut_ptr(), err.len()) };
        assert_eq!(r, crate::types::OK, "frame {k}: {}", msg(&err));
        let n = if p.monochrome != 0 { 1 } else { 3 };
        for pl in 0..n {
            assert_eq!((p.plane_w[pl], p.plane_h[pl]), (o.recon_w[pl], o.recon_h[pl]));
            for y in 0..p.plane_h[pl] as usize {
                let row = unsafe {
                    core::slice::from_raw_parts(p.planes[pl].add(y * p.stride[pl] as usize), p.plane_w[pl] as usize)
                };
                assert!(
                    row == &o.recon[pl][y * o.recon_w[pl] as usize..][..o.recon_w[pl] as usize],
                    "frame {k} plane {pl}"
                );
            }
        }
        assert!(n == 3 || p.planes[1].is_null());
        assert_eq!(p.key != 0, seq.frames[k].fp.frame_type == FRAME_KEY);
        let mut again = DecPicture::default();
        assert_eq!(unsafe { av1g_decoder_picture(d, &mut again) }, crate::types::OK);
        assert_eq!((again.planes, again.width, again.key), (p.planes, p.width, p.key));
    }
    let mut p = DecPicture::default();
    let r = unsafe { av1g_decoder_decode(d, [0x12u8, 0].as_ptr(), 2, &mut p, err.as_mut_ptr(), err.len()) };
    assert_eq!(r, crate::types::ERR_INVALID);
    assert!(msg(&err).contains("no frame"), "{}", msg(&err));
    assert!(p.planes[0].is_null());
    assert_eq!(unsafe { av1g_decoder_picture(d, &mut p) }, crate::types::ERR_INVALID);
    unsafe { av1g_decoder_reset(d) };
    assert_eq!(
        unsafe { av1g_decoder_decode(d, core::ptr::null(), 0, &mut p, core::ptr::null_mut(), 0) },
        crate::types::ERR_INVALID
    );
    assert_eq!(
        unsafe {
            av1g_decoder_decode(
                core::ptr::null_mut(),
                core::ptr::null(),
                0,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            )
        },
        crate::types::ERR_INVALID
    );
    unsafe { av1g_decoder_destroy(d) };
}

// ---- hostile input ----

/// A stream: its temporal units and what they decode to.
struct Stream {
    tus: Vec<Vec<u8>>,
    outs: Vec<Output>,
}

/// Small valid streams of every kind the tests make.
fn corpus(n: u64) -> Vec<Stream> {
    let mut v = Vec::new();
    let mut w = Writer::with_threads(1);
    for seed in 0..n {
        if let Some(mut seq) = test_seq(seed, 96, 6)
            && let Ok(outs) = encode_seq(&mut w, &mut seq, ENC_FIX_RANGE | ENC_TD)
        {
            v.push(Stream {
                tus: outs.iter().map(|o| o.obu.clone()).collect(),
                outs,
            });
        }
        let mut stills = Vec::new();
        if let Some(r) = record_444(seed, 64, seed % 2 == 0) {
            stills.push(r);
        }
        if let Some(mut r) = fuzz_record(seed, 64) {
            add_palettes(&mut r, seed, 40);
            stills.push(r);
        }
        for mut rec in stills {
            let mut out = Output::default();
            let opts = EncodeOpts {
                flags: ENC_FIX_RANGE | ENC_TD,
                seq_level_idx: -1,
            };
            if w.encode(rec.as_mut(), &opts, &mut out).is_ok() {
                v.push(Stream {
                    tus: vec![out.obu.clone()],
                    outs: vec![out],
                });
            }
        }
    }
    v
}

/// The reference for decoded hostile input: the parser and the writer's reconstruction, with the
/// decoder's slots (emptied when it fails).
struct Oracle {
    ps: ParseState,
    slots: [Option<Rc<Output>>; 8],
    w: Writer,
}

impl Oracle {
    fn new() -> Oracle {
        Oracle {
            ps: ParseState::default(),
            slots: Default::default(),
            w: Writer::with_threads(1),
        }
    }
    fn drop_refs(&mut self) {
        self.slots = Default::default();
        self.ps.slots = Default::default();
    }
    fn decode(&mut self, tu: &[u8]) -> Result<Rc<Output>, String> {
        let mut parsed = parse_with(tu, Some(&mut self.ps)).map_err(|e| format!("parse: {e}"))?;
        let refs: RefSlots = core::array::from_fn(|i| self.slots[i].as_deref().map(RefPicture::from_output));
        let mut out = Output::default();
        let opts = EncodeOpts {
            flags: 0,
            seq_level_idx: -1,
        };
        self.w
            .encode_ex(parsed.rec.as_mut(), &opts, &refs, &mut out)
            .map_err(|e| format!("writer: {e}"))?;
        let out = Rc::new(out);
        let refresh = if parsed.rec.fp.frame_type == FRAME_KEY {
            0xFF
        } else {
            parsed.rec.fp.refresh_frame_flags
        };
        for (i, s) in self.slots.iter_mut().enumerate() {
            if refresh >> i & 1 != 0 {
                *s = Some(out.clone());
            }
        }
        Ok(out)
    }
}

/// What the fuzzing did.
#[derive(Default)]
struct FuzzCount {
    cases: AtomicU64,
    decodes: AtomicU64,
    decoded: AtomicU64,
    /// decodes that reached the tile walk
    walked: AtomicU64,
    /// decoded frames the oracle decoded identically; key frames after damage that decoded as
    /// they were written
    vouched: AtomicU64,
    resynced: AtomicU64,
    kinds: [AtomicU64; 7],
}

/// A random OBU sequence: random headers (types, extension bytes, size fields right, wrong and
/// overlong) around random payloads and pieces of a real temporal unit.
fn random_obus(r: &mut Rng, real: &[u8]) -> Vec<u8> {
    let mut v = Vec::new();
    for _ in 0..1 + r.below(4) {
        let ty = [1u8, 2, 3, 4, 5, 6, 7, 8, 15, r.below(16) as u8][r.below(10) as usize];
        let ext = r.chance(20);
        let has_size = r.chance(85);
        let forbidden = r.chance(3);
        v.push((forbidden as u8) << 7 | ty << 3 | (ext as u8) << 2 | (has_size as u8) << 1);
        if ext {
            v.push(r.next() as u8);
        }
        let payload: Vec<u8> = if r.chance(50) && !real.is_empty() {
            let a = r.below(real.len() as u64) as usize;
            let b = (a + r.below(400) as usize).min(real.len());
            real[a..b].to_vec()
        } else {
            (0..r.below(200)).map(|_| r.next() as u8).collect()
        };
        if has_size {
            let mut sz = payload.len() as u64;
            if r.chance(20) {
                sz = r.next() >> r.below(64);
            }
            let overlong = r.chance(10);
            loop {
                let b = (sz & 0x7f) as u8;
                sz >>= 7;
                if sz == 0 && !overlong {
                    v.push(b);
                    break;
                }
                v.push(b | 0x80);
                if sz == 0 && v.len() > 12 {
                    v.push(0);
                    break;
                }
            }
        }
        v.extend_from_slice(&payload);
    }
    v
}

/// One fuzz case: stream `s` damaged by kind `kind`, decoded in order by `d` and the oracle.
fn fuzz_case(s: &Stream, seed: u64, d: &mut Decoder, count: &FuzzCount, progress: &AtomicU64) {
    let mut r = Rng(seed.wrapping_mul(0x2545F4914F6CDD1D) ^ 0xF022);
    let mut tus: Vec<Option<Vec<u8>>> = s.tus.iter().cloned().map(Some).collect();
    let n = tus.len();
    let at = r.below(n as u64) as usize;
    let kind = r.below(7) as usize;
    count.kinds[kind].fetch_add(1, Relaxed);
    let mut reset_at = None;
    {
        let tu = tus[at].as_mut().unwrap();
        match kind {
            // truncated
            0 => tu.truncate(r.below(tu.len() as u64 + 1) as usize),
            // bits flipped: in the headers (the first 48 bytes) or anywhere
            1 => {
                for _ in 0..1 + r.below(4) {
                    let lim = if r.chance(50) { tu.len().min(48) } else { tu.len() };
                    if lim > 0 {
                        let i = r.below(lim as u64) as usize;
                        tu[i] ^= 1 << r.below(8);
                    }
                }
            }
            // a span overwritten with random bytes
            2 => {
                if !tu.is_empty() {
                    let a = r.below(tu.len() as u64) as usize;
                    let b = (a + 1 + r.below(64) as usize).min(tu.len());
                    for x in &mut tu[a..b] {
                        *x = r.next() as u8;
                    }
                }
            }
            // random bytes
            3 => *tu = (0..r.below(400)).map(|_| r.next() as u8).collect(),
            // random OBU structure
            4 => *tu = random_obus(&mut r, &s.tus[at]),
            // the tile data only: bytes flipped past the headers
            5 => {
                let len = tu.len();
                for _ in 0..1 + r.below(16) {
                    if len > 40 {
                        let i = 40 + r.below((len - 40) as u64) as usize;
                        tu[i] = r.next() as u8;
                    }
                }
            }
            // order: one dropped, duplicated or swapped, or a reset
            _ => {}
        }
    }
    let mut order: Vec<usize> = (0..n).collect();
    if kind == 6 {
        match r.below(4) {
            0 => {
                order.remove(at);
            }
            1 => order.insert(at, at),
            2 => {
                let b = r.below(n as u64) as usize;
                order.swap(at, b);
            }
            _ => reset_at = Some(at),
        }
        tus[at] = Some(s.tus[at].clone());
    }
    d.reset();
    let mut oracle = Oracle::new();
    let mut damaged = false;
    for (pos, &i) in order.iter().enumerate() {
        if reset_at == Some(pos) {
            d.reset();
            oracle = Oracle::new();
            damaged = true;
        }
        let tu = tus[i].as_deref().unwrap();
        let walks0 = d.walks;
        // the oracle starts from the decoder's sequence header (which it keeps through a failed
        // frame, from a temporal unit whose structure it accepted)
        oracle.ps.set_seq(d.seq.as_deref());
        let res = d.decode(tu).map(|_| ()).map_err(|e| e.msg);
        if std::env::var_os("FUZZ_VERBOSE").is_some() {
            eprintln!(
                "case {seed} kind {kind} at {at} pos {pos} tu {i} ({} bytes {:02x?}): {:?}",
                tu.len(),
                &tu[..tu.len().min(24)],
                res
            );
        }
        let ok = res.is_ok();
        progress.fetch_add(1, Relaxed);
        count.decodes.fetch_add(1, Relaxed);
        count.walked.fetch_add((d.walks != walks0) as u64, Relaxed);
        let mutated = i == at && kind != 6 || (kind == 6 && pos != i);
        damaged |= mutated;
        match ok {
            false => {
                if std::env::var_os("FUZZ_VERBOSE").is_some() {
                    eprintln!("  oracle: {:?}", oracle.decode(tu).map(|_| ()));
                }
                oracle.drop_refs()
            }
            true => {
                count.decoded.fetch_add(1, Relaxed);
                // a frame the decoder decodes, the parser and the writer decode alike
                let want = oracle.decode(tu);
                let pic = d.picture().unwrap();
                match want {
                    Ok(o) => {
                        same(&pic, &o).unwrap_or_else(|e| panic!("fuzz seed {seed} (kind {kind}) tu {i}: {e}"));
                        count.vouched.fetch_add(1, Relaxed);
                    }
                    Err(e) => panic!(
                        "fuzz seed {seed} (kind {kind}) tu {i}: decoded, but the parser and writer refuse it: {e}"
                    ),
                }
                // an undamaged key frame with its sequence header (the writer's: after the temporal
                // delimiter) decodes as written; one without decodes by the header the decoder has,
                // which damage may have changed
                let own_header = tu.len() > 2 && (tu[2] >> 3) & 15 == 1;
                if damaged && !mutated && pic.key && own_header {
                    same(&pic, &s.outs[i])
                        .unwrap_or_else(|e| panic!("fuzz seed {seed} (kind {kind}) tu {i}: after damage: {e}"));
                    count.resynced.fetch_add(1, Relaxed);
                }
            }
        }
    }
}

fn fuzz(streams: u64, cases_per_stream: u64) {
    let corpus = corpus(streams);
    let count = FuzzCount::default();
    let progress = AtomicU64::new(0);
    let done = std::sync::atomic::AtomicBool::new(false);
    let current: Vec<AtomicU64> = (0..8).map(|_| AtomicU64::new(u64::MAX)).collect();
    let t0 = Instant::now();
    let next = AtomicU64::new(0);
    std::thread::scope(|sc| {
        // the watchdog: a case that makes no progress for 30 s names its seed and aborts
        sc.spawn(|| {
            let mut last = (0, Instant::now());
            while !done.load(Relaxed) {
                std::thread::sleep(std::time::Duration::from_millis(100));
                let p = progress.load(Relaxed);
                if p != last.0 {
                    last = (p, Instant::now());
                } else if last.1.elapsed().as_secs() > 30 {
                    let seeds: Vec<u64> = current
                        .iter()
                        .map(|c| c.load(Relaxed))
                        .filter(|&c| c != u64::MAX)
                        .collect();
                    eprintln!("fuzz: no progress for 30 s; cases running: {seeds:?}");
                    std::process::abort();
                }
            }
        });
        let total = corpus.len() as u64 * cases_per_stream;
        let nthreads = std::thread::available_parallelism().map_or(4, |n| n.get()).min(8);
        let workers: Vec<_> = (0..nthreads)
            .map(|t| {
                let (next, corpus, count, progress, current) = (&next, &corpus, &count, &progress, &current);
                sc.spawn(move || {
                    let mut d = Decoder::new(1 + t % 3);
                    loop {
                        let k = next.fetch_add(1, Relaxed);
                        if k >= total {
                            break;
                        }
                        if let Ok(only) = std::env::var("FUZZ_ONLY")
                            && only.parse::<u64>().ok() != Some(k)
                        {
                            continue;
                        }
                        current[t].store(k, Relaxed);
                        fuzz_case(&corpus[(k % corpus.len() as u64) as usize], k, &mut d, count, progress);
                        count.cases.fetch_add(1, Relaxed);
                    }
                    current[t].store(u64::MAX, Relaxed);
                })
            })
            .collect();
        for w in workers {
            if let Err(p) = w.join() {
                done.store(true, Relaxed);
                std::panic::resume_unwind(p);
            }
        }
        done.store(true, Relaxed);
    });
    let k: Vec<u64> = count.kinds.iter().map(|k| k.load(Relaxed)).collect();
    eprintln!(
        "fuzz: {} streams, {} cases (truncated {}, bits flipped {}, random spans {}, random bytes {}, random OBUs {}, tile data {}, reordered {}), {} decodes in {:.1} s: {} reached the tile walk, {} decoded ({} identical to the parser and writer's), {} key frames after damage as written",
        corpus.len(),
        count.cases.load(Relaxed),
        k[0],
        k[1],
        k[2],
        k[3],
        k[4],
        k[5],
        k[6],
        count.decodes.load(Relaxed),
        t0.elapsed().as_secs_f64(),
        count.walked.load(Relaxed),
        count.decoded.load(Relaxed),
        count.vouched.load(Relaxed),
        count.resynced.load(Relaxed),
    );
    assert!(count.walked.load(Relaxed) > count.decodes.load(Relaxed) / 4);
    assert!(count.resynced.load(Relaxed) > 0);
}

/// Hostile input: truncated, bit-flipped, overwritten, random and reordered temporal units of real
/// streams, and random OBU structures. Nothing panics, loops or allocates without bound; what
/// decodes is what the parser and the writer make of it; key frames after damage decode as
/// written.
#[test]
fn hostile_input() {
    fuzz(40, 60);
}

/// [`hostile_input`] at length.
#[test]
#[ignore]
fn hostile_input_long() {
    let env = |k: &str, d: u64| std::env::var(k).map_or(d, |v| v.parse().unwrap());
    fuzz(env("STREAMS", 200), env("CASES", 1000));
}

// ---- the installed decoders and the 5K streams ----

fn tool(name: &str) -> Option<String> {
    let p = format!("/opt/homebrew/bin/{name}");
    std::path::Path::new(&p).exists().then_some(p)
}

/// `stream` (IVF) decoded by an installed decoder into I420 (or 4:4:4 / monochrome) frames.
fn external(tool: &str, stream: &std::path::Path, out: &std::path::Path) -> Vec<u8> {
    let args: Vec<String> = if tool.ends_with("dav1d") {
        vec![
            "-q".into(),
            "-i".into(),
            stream.display().to_string(),
            "-o".into(),
            out.display().to_string(),
        ]
    } else {
        vec![
            "--rawvideo".into(),
            "-o".into(),
            out.display().to_string(),
            stream.display().to_string(),
        ]
    };
    let st = std::process::Command::new(tool).args(&args).output().unwrap();
    assert!(st.status.success(), "{tool}: {}", String::from_utf8_lossy(&st.stderr));
    let v = std::fs::read(out).unwrap();
    let _ = std::fs::remove_file(out);
    v
}

/// The installed decoders (dav1d, aomdec) and this one decode random sequences (4:2:0 key and
/// inter frames, copy-heavy ones) and 4:4:4 key frames identically.
#[test]
#[ignore]
fn decoders_agree() {
    let tools: Vec<String> = ["dav1d", "aomdec"].iter().filter_map(|t| tool(t)).collect();
    assert!(!tools.is_empty(), "neither dav1d nor aomdec is installed");
    let env = |k: &str, d: u64| std::env::var(k).map_or(d, |v| v.parse().unwrap());
    let (n, maxdim) = (env("SEQS", 120), env("MAXDIM", 200) as i32);
    let dir = std::env::temp_dir().join(format!("glassact-av1-decoder-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let frames = AtomicU64::new(0);
    let f444 = AtomicU64::new(0);
    seeds(n, |seed| {
        let mut w = Writer::with_threads(2);
        let mut streams: Vec<(Vec<Output>, crate::types::FrameParams, String)> = Vec::new();
        if let Some(mut seq) = test_seq(seed, maxdim, 8) {
            // (a reduced stream's frames are its frames' size, which the IVF header's isn't)
            let outs = encode_seq(&mut w, &mut seq, ENC_FIX_RANGE | ENC_TD).unwrap();
            streams.push((outs, seq.frames[0].fp, format!("seq {seed}")));
        }
        for filters in [true, false] {
            if let Some(mut rec) = record_444(seed, maxdim, filters) {
                let mut out = Output::default();
                let opts = EncodeOpts {
                    flags: ENC_FIX_RANGE | ENC_TD,
                    seq_level_idx: -1,
                };
                w.encode(rec.as_mut(), &opts, &mut out).unwrap();
                streams.push((vec![out], rec.fp, format!("4:4:4 {seed} {filters}")));
                f444.fetch_add(1, Relaxed);
            }
        }
        for (k, (outs, fp, what)) in streams.into_iter().enumerate() {
            let src = dir.join(format!("s{seed}-{k}.ivf"));
            std::fs::write(&src, ivf(&outs, fp.width, fp.height)).unwrap();
            let mut d = Decoder::new(2);
            let ours: Vec<Vec<u8>> = outs
                .iter()
                .map(|o| {
                    let p = d.decode(&o.obu).unwrap_or_else(|e| panic!("{what}: {e}"));
                    let mut v = Vec::new();
                    for pl in 0..if p.monochrome { 1 } else { 3 } {
                        for y in 0..p.plane_h[pl] as usize {
                            v.extend_from_slice(&p.planes[pl][y * p.stride[pl]..][..p.plane_w[pl] as usize]);
                        }
                    }
                    v
                })
                .collect();
            let all: Vec<u8> = ours.concat();
            for t in &tools {
                let got = external(t, &src, &dir.join(format!("s{seed}-{k}.yuv")));
                assert!(got == all, "{what}: {t} decodes it otherwise");
            }
            frames.fetch_add(outs.len() as u64, Relaxed);
            let _ = std::fs::remove_file(&src);
        }
    });
    eprintln!(
        "{} frames ({} 4:4:4 pictures) decode identically here and in {}",
        frames.load(Relaxed),
        f444.load(Relaxed),
        tools.join(", ")
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The 5K streams in $OWNDEC_DIR (`<name>.ivf` with libaom's decode beside it as `<name>.i420`):
/// every frame identical to libaom's.
#[test]
#[ignore]
fn streams_match_libaom() {
    let Ok(dir) = std::env::var("OWNDEC_DIR") else {
        eprintln!("OWNDEC_DIR not set");
        return;
    };
    let mut names: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok()?.path().to_str().map(String::from))
        .filter(|p| p.ends_with(".ivf"))
        .collect();
    names.sort();
    let mut total = 0;
    for name in names {
        let ivf = std::fs::read(&name).unwrap();
        let Ok(raw) = std::fs::read(name.replace(".ivf", ".i420")) else {
            continue;
        };
        let mut d = Decoder::new(0);
        let mut at = 32;
        let mut k = 0;
        let mut off = 0;
        while at + 12 <= ivf.len() {
            let size = u32::from_le_bytes(ivf[at..at + 4].try_into().unwrap()) as usize;
            let tu = &ivf[at + 12..at + 12 + size];
            at += 12 + size;
            let p = d.decode(tu).unwrap_or_else(|e| panic!("{name} frame {k}: {e}"));
            for pl in 0..3 {
                let (w, h) = (p.plane_w[pl] as usize, p.plane_h[pl] as usize);
                for y in 0..h {
                    assert!(
                        p.planes[pl][y * p.stride[pl]..][..w] == raw[off + y * w..][..w],
                        "{name} frame {k} plane {pl} row {y}"
                    );
                }
                off += w * h;
            }
            k += 1;
        }
        assert_eq!(off, raw.len(), "{name}: frames");
        eprintln!("{name}: {k} frames identical to libaom's");
        total += k;
    }
    eprintln!("{total} frames");
}
