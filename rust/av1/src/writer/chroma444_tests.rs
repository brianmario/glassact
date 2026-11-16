//! 4:4:4 (fp.chroma_format, seq_profile 1): random legal key frames and still pictures (every
//! intra mode, CfL, luma and chroma palettes, intra block copy, every tx size and type, odd and
//! tiny sizes, 64x64 and 128x128 superblocks), with the post-filters on and off. They encode the
//! same apart from their coding as in one pass, parse back to the record that was written (which
//! codes the same stream again), and (ignored: `cargo test --release -- --ignored --nocapture
//! decoders_444`) decode in dav1d and aomdec to exactly the writer's reconstruction. There is no
//! C++ oracle for 4:4:4 (oracle/cpp is 4:2:0): the decoders are the oracle.
use super::inter_tests::{decode_check, expect_parsed, seeds};
use super::palette_tests::add_palettes;
use super::*;
use crate::blockinfo::*;
use crate::dsp::{
    Rng, chroma_tx_type, get_scan, get_tx_set_inter, get_tx_set_intra, tx_coeffs, tx_type_in_set_inter,
    tx_type_in_set_intra,
};
use crate::tables::*;
use crate::testsupport::FuzzCase;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

/// What the 4:4:4 records coded (eob > 0 for tx blocks), for the coverage checks.
struct Cov {
    /// [plane type][tx size][tx type]
    txb: [[[AtomicU64; 16]; 19]; 2],
    y_mode: [AtomicU64; 13],
    /// 0..13 (13: CfL)
    uv_mode: [AtomicU64; 14],
    pal_y: AtomicU64,
    pal_uv: AtomicU64,
    intrabc: AtomicU64,
    /// frames: width not a multiple of 8, height not, both under 64, non-square, 128x128
    /// superblocks, with deblocking (chroma levels nonzero), with CDEF (chroma strengths nonzero),
    /// with no post-filter, video key frames
    frames: [AtomicU64; 9],
}

impl Cov {
    fn new() -> Cov {
        Cov {
            txb: Default::default(),
            y_mode: Default::default(),
            uv_mode: Default::default(),
            pal_y: AtomicU64::new(0),
            pal_uv: AtomicU64::new(0),
            intrabc: AtomicU64::new(0),
            frames: Default::default(),
        }
    }

    fn add(&self, rec: &Record) {
        let fp = &rec.fp;
        let (w, h) = (fp.width, fp.height);
        let lf = fp.loop_filter_level;
        let flags = [
            w % 8 != 0,
            h % 8 != 0,
            w < 64 && h < 64,
            w != h,
            fp.sb128 != 0,
            (lf[0] != 0 || lf[1] != 0) && lf[2] != 0 && lf[3] != 0,
            fp.enable_cdef != 0 && fp.cdef_uv_pri.iter().chain(&fp.cdef_uv_sec).any(|&s| s != 0),
            lf == [0; 4] && fp.enable_cdef == 0,
            fp.video != 0,
        ];
        for (c, f) in self.frames.iter().zip(flags) {
            c.fetch_add(f as u64, Relaxed);
        }
        for (i, b) in rec.blocks.iter().enumerate() {
            let inter = rec.inter.get(i).is_some_and(|x| x.is_inter != 0);
            if inter {
                self.intrabc.fetch_add(1, Relaxed);
            } else {
                self.y_mode[b.y_mode as usize].fetch_add(1, Relaxed);
                self.uv_mode[b.uv_mode as usize].fetch_add(1, Relaxed);
            }
            if let Some(p) = rec.palette.get(i) {
                self.pal_y.fetch_add((p.size_y != 0) as u64, Relaxed);
                self.pal_uv.fetch_add((p.size_uv != 0) as u64, Relaxed);
            }
        }
        for t in &rec.txb {
            if t.eob > 0 {
                self.txb[(t.plane > 0) as usize][t.tx_size as usize][t.tx_type as usize].fetch_add(1, Relaxed);
            }
        }
    }

    fn report(&self) -> String {
        let n = |a: &AtomicU64| a.load(Relaxed);
        let sizes = |p: usize| (0..19).filter(|&t| self.txb[p][t].iter().any(|a| n(a) > 0)).count();
        let types = |p: usize| {
            (0..19)
                .map(|t| self.txb[p][t].iter().filter(|a| n(a) > 0).count())
                .sum::<usize>()
        };
        format!(
            "luma: {} tx sizes, {} (size, type) pairs; chroma: {} tx sizes, {} pairs; y modes {:?}; uv modes {:?}; \
             palette blocks luma {} chroma {}; intra block copies {}; frames (w % 8, h % 8, < 64, non-square, \
             sb128, deblocked, CDEF, unfiltered, video) {:?}",
            sizes(0),
            types(0),
            sizes(1),
            types(1),
            self.y_mode.iter().map(n).collect::<Vec<_>>(),
            self.uv_mode.iter().map(n).collect::<Vec<_>>(),
            n(&self.pal_y),
            n(&self.pal_uv),
            n(&self.intrabc),
            self.frames.iter().map(n).collect::<Vec<_>>()
        )
    }

    /// Every intra mode and chroma mode (CfL too); palettes of both plane types; intra block
    /// copies; every luma tx size with every type its intra set has; every chroma tx size 4:4:4
    /// has (the 14 without a 64-sample side); every kind of frame.
    fn check(&self) {
        let n = |a: &AtomicU64| a.load(Relaxed);
        let r = self.report();
        assert!(self.y_mode.iter().all(|a| n(a) > 0), "{r}");
        assert!(self.uv_mode.iter().all(|a| n(a) > 0), "{r}");
        assert!(n(&self.pal_y) > 0 && n(&self.pal_uv) > 0 && n(&self.intrabc) > 0, "{r}");
        assert!(self.frames.iter().all(|a| n(a) > 0), "{r}");
        for t in 0..TX_SIZES_ALL {
            for ty in 0..TX_TYPES {
                if tx_type_in_set_intra(get_tx_set_intra(t, false), ty) {
                    assert!(n(&self.txb[0][t as usize][ty as usize]) > 0, "luma tx {t} type {ty}: {r}");
                }
            }
            let big = tx_w(t) == 64 || tx_h(t) == 64;
            let any = self.txb[1][t as usize].iter().any(|a| n(a) > 0);
            assert_eq!(any, !big, "chroma tx {t}: {r}");
        }
    }
}

fn tx_w(t: i32) -> i32 {
    Tx_Width[t as usize] as i32
}
fn tx_h(t: i32) -> i32 {
    Tx_Height[t as usize] as i32
}

/// Random sparse levels for one tx block (`q` zeroed): small mostly, some in the Golomb range.
fn fill_levels(r: &mut Rng, q: &mut [i16], tx_sz: i32, tx_type: i32) {
    let n = tx_coeffs(tx_sz) as i32;
    if r.below(5) == 0 {
        return;
    }
    let scan = get_scan(tx_sz, tx_type);
    let eob = match r.below(10) {
        0..=3 => r.range(1, n.min(4)),
        4..=7 => r.range(1, n.min(32)),
        _ => r.range(1, n),
    };
    let density = r.range(5, 100) as u32;
    for c in 0..eob {
        if c != eob - 1 && r.below(100) >= density {
            continue;
        }
        let mag = match r.below(1000) {
            0..=599 => 1,
            600..=799 => r.range(2, 3),
            800..=919 => r.range(4, 15),
            920..=989 => r.range(16, 300),
            _ => r.range(300, 3000),
        };
        q[scan[c as usize] as usize] = if r.below(2) == 0 { -mag } else { mag } as i16;
    }
}

/// A random legal 4:4:4 record of `seed`: FuzzCase::make_444 (64x64 or, one seed in four, 128x128
/// superblocks; a still picture, or one seed in three a video key frame), then by the seed's kind
/// luma and chroma palettes and / or intra block copies, the post-filters on (`filters`: deblocking
/// and CDEF with nonzero chroma strengths, unless the frame copies) or off, and fresh luma tx types
/// (from each block's set) and levels.
pub(super) fn record_444(seed: u64, maxdim: i32, filters: bool) -> Option<Record> {
    let sb128 = seed % 4 == 3;
    let mut case = FuzzCase::make_444(seed, maxdim, 3, sb128)?;
    let mut rec = Record {
        fp: case.fp,
        blocks: core::mem::take(&mut case.blocks),
        ..Default::default()
    };
    let mut r = Rng(seed.wrapping_mul(0xD1B5_4A32_D192_ED03) | 1);
    let mut fp = rec.fp;
    if seed % 3 == 1 {
        fp.video = 1;
    }
    let kind = seed % 5;
    let (palettes, intrabc) = (kind == 1 || kind == 3, kind == 2 || kind == 3);
    let sb_cols = (mi_cols(fp.width as i32) as usize).div_ceil(16);
    if intrabc {
        // no post-filters with intra block copy
        (fp.allow_screen_content_tools, fp.allow_intrabc) = (1, 1);
        (fp.loop_filter_level, fp.loop_filter_sharpness, fp.enable_cdef) = ([0; 4], 0, 0);
        (fp.cdef_damping_minus_3, fp.cdef_bits) = (0, 0);
        (fp.cdef_y_pri, fp.cdef_y_sec, fp.cdef_uv_pri, fp.cdef_uv_sec) = ([0; 8], [0; 8], [0; 8], [0; 8]);
        let tiles = tile_layout_ex(
            fp.width,
            fp.height,
            fp.tile_cols_log2 as i32,
            fp.tile_rows_log2 as i32,
            sb128,
        )
        .ok()?;
        rec.inter = vec![BlockInter::default(); rec.blocks.len()];
        crate::testsupport::inter_gen::add_intrabc_seeded(seed, &fp, &tiles, &mut rec.blocks, &mut rec.inter);
    } else if filters {
        const SEC: [u8; 4] = [0, 1, 2, 4];
        let lv = |r: &mut Rng| r.range(1, 63) as u8;
        fp.loop_filter_level = [lv(&mut r), lv(&mut r), lv(&mut r), lv(&mut r)];
        if r.below(4) == 0 {
            fp.loop_filter_level[r.below(2) as usize] = 0; // one luma direction off
        }
        fp.loop_filter_sharpness = r.below(8) as u8;
        (fp.enable_cdef, fp.cdef_damping_minus_3, fp.cdef_bits) = (1, r.below(4) as u8, r.below(4) as u8);
        (fp.cdef_y_pri, fp.cdef_y_sec, fp.cdef_uv_pri, fp.cdef_uv_sec) = ([0; 8], [0; 8], [0; 8], [0; 8]);
        for i in 0..1usize << fp.cdef_bits {
            fp.cdef_y_pri[i] = r.below(16) as u8;
            fp.cdef_y_sec[i] = SEC[r.below(4) as usize];
            fp.cdef_uv_pri[i] = r.range(1, 15) as u8;
            fp.cdef_uv_sec[i] = SEC[r.below(4) as usize];
        }
    } else {
        // (what the frame header doesn't code then is 0, as the parser gives it)
        (fp.loop_filter_level, fp.enable_cdef) = ([0; 4], 0);
        (fp.cdef_damping_minus_3, fp.cdef_bits) = (0, 0);
        (fp.cdef_y_pri, fp.cdef_y_sec, fp.cdef_uv_pri, fp.cdef_uv_sec) = ([0; 8], [0; 8], [0; 8], [0; 8]);
    }
    let cdef_bits = if fp.enable_cdef != 0 { fp.cdef_bits } else { 0 };
    let sbc: Vec<i8> = (0..sb_cols * (mi_rows(fp.height as i32) as usize).div_ceil(16))
        .map(|_| r.below(1 << cdef_bits) as i8)
        .collect();
    let on = fp.enable_cdef != 0;
    rec.fp = fp;
    for b in &mut rec.blocks {
        b.cdef_idx = if on {
            sbc[(b.mi_row as usize >> 4) * sb_cols + (b.mi_col as usize >> 4)]
        } else {
            0
        };
    }
    if palettes {
        add_palettes(&mut rec, seed, 40);
    }
    rec.layout().ok()?;
    rec.coeffs.fill(0);
    let reduced = rec.fp.reduced_tx_set != 0;
    for b in 0..rec.blocks.len() {
        let inter = rec.inter.get(b).is_some_and(|i| i.is_inter != 0);
        let uv_mode = rec.blocks[b].uv_mode as i32;
        for t in rec.block_txb[b] as usize..rec.block_txb[b + 1] as usize {
            let x = rec.txb[t];
            let tx_sz = x.tx_size as i32;
            let tx_type = if x.plane == 0 {
                let ok = |ty: i32| {
                    if inter {
                        tx_type_in_set_inter(get_tx_set_inter(tx_sz, reduced), ty)
                    } else {
                        tx_type_in_set_intra(get_tx_set_intra(tx_sz, reduced), ty)
                    }
                };
                let mut ty = DCT_DCT;
                if r.below(10) < 8 {
                    loop {
                        ty = r.range(0, 15);
                        if ok(ty) {
                            break;
                        }
                    }
                }
                rec.txb[t].tx_type = ty as u8;
                ty
            } else if inter {
                DCT_DCT // derived from luma by the writer; any scan is a fine source of levels
            } else {
                chroma_tx_type(tx_sz, uv_mode, reduced)
            };
            let off = x.coeff_off as usize;
            fill_levels(&mut r, &mut rec.coeffs[off..off + tx_coeffs(tx_sz)], tx_sz, tx_type);
        }
    }
    Some(rec)
}

fn opts(flags: u32) -> EncodeOpts {
    EncodeOpts {
        flags,
        seq_level_idx: -1,
    }
}

/// Codes `rec` (repairing levels out of range) on `w` and on one thread (its reconstruction then in
/// one pass): the same output and record; it parses back to the record written, which codes the
/// same stream again. Returns the output and the record as written.
fn check_444(w: &mut Writer, rec: &Record, what: &str) -> (Output, Record) {
    let mut flags = ENC_FIX_RANGE | ENC_TD;
    if rec.fp.sb128 == 0 {
        flags |= ENC_CHECK_EDGES;
    }
    if rec.fp.video == 0 {
        flags |= ENC_AVIF;
    }
    let (mut a, mut b) = (rec.clone(), rec.clone());
    let (mut oa, mut ob) = (Output::default(), Output::default());
    w.encode(a.as_mut(), &opts(flags), &mut oa)
        .unwrap_or_else(|e| panic!("{what}: {e}"));
    Writer::with_threads(1).encode(b.as_mut(), &opts(flags), &mut ob).unwrap();
    assert!(oa == ob, "{what}: split vs one pass");
    assert!(a.txb == b.txb && a.coeffs == b.coeffs, "{what}: split vs one pass, record");
    // every plane is the picture's size
    for p in 0..3 {
        assert_eq!((oa.recon_w[p], oa.recon_h[p]), (rec.fp.width, rec.fp.height), "{what}: plane {p}");
    }
    let p = parse(&oa.obu).unwrap_or_else(|e| panic!("{what}: parse: {e}"));
    assert_eq!(p.rec.fp.chroma_format, CHROMA_444, "{what}");
    expect_parsed(&a, &p.rec, what);
    // the palettes (their maps: through the stream the parsed record codes, below)
    let none = BlockPalette::default();
    for (k, x) in a.palette.iter().enumerate() {
        let y = p.rec.palette.get(k).unwrap_or(&none);
        let n = [x.size_y, x.size_uv, x.size_uv];
        assert_eq!((x.size_y, x.size_uv), (y.size_y, y.size_uv), "{what}: palette {k}");
        for c in 0..3 {
            assert_eq!(x.colors[c][..n[c] as usize], y.colors[c][..n[c] as usize], "{what}: palette {k}");
        }
    }
    let mut again = p.rec.clone();
    let mut o = Output::default();
    w.encode(again.as_mut(), &opts(ENC_BITSTREAM_ONLY | ENC_TD), &mut o).unwrap();
    assert!(o.obu == oa.obu, "{what}: the parsed record codes another stream");
    (oa, a)
}

/// Random 4:4:4 records, the post-filters on and off: one pass and split reconstructions agree,
/// and they parse back to what was written.
#[test]
fn chroma444_round_trip() {
    let cov = Cov::new();
    seeds(120, |w, seed| {
        for filters in [true, false] {
            let Some(rec) = record_444(seed, 200, filters) else { continue };
            let (_, written) = check_444(w, &rec, &format!("seed {seed} filters {filters}"));
            cov.add(&written);
        }
    });
    eprintln!("{}", cov.report());
    cov.check();
}

/// The installed decoders (dav1d, aomdec) decode random 4:4:4 key frames and still pictures, the
/// post-filters on and off, to exactly the writer's reconstruction.
#[test]
#[ignore]
fn decoders_444() {
    let tools = [
        ("dav1d", vec!["-q", "-i", "IN", "-o", "OUT"]),
        ("aomdec", vec!["--rawvideo", "-o", "OUT", "IN"]),
    ];
    let installed: Vec<&str> = tools
        .iter()
        .map(|t| t.0)
        .filter(|t| std::path::Path::new(&format!("/opt/homebrew/bin/{t}")).exists())
        .collect();
    assert!(!installed.is_empty(), "neither dav1d nor aomdec is installed");
    let env = |k: &str, d: u64| std::env::var(k).map_or(d, |v| v.parse().unwrap());
    let (n, maxdim) = (env("SEQS", 240), env("MAXDIM", 200) as i32);
    let dir = std::env::temp_dir().join(format!("glassact-av1-444-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let cov = Cov::new();
    let pictures = AtomicU64::new(0);
    seeds(n, |w, seed| {
        for filters in [true, false] {
            let Some(rec) = record_444(seed, maxdim, filters) else { continue };
            if rec.fp.allow_intrabc != 0 && filters {
                continue; // (no post-filters with intra block copy: the unfiltered one is the same)
            }
            let what = format!("seed {seed} filters {filters}");
            let (out, written) = check_444(w, &rec, &what);
            let name = format!("s{seed}-{}", if filters { "f" } else { "u" });
            let kind = if rec.fp.allow_intrabc != 0 {
                "4:4:4, intra block copy"
            } else if filters {
                "4:4:4, filtered"
            } else {
                "4:4:4, unfiltered"
            };
            decode_check(&dir, &tools, &name, &[out], &rec.fp, &[kind]);
            cov.add(&written);
            pictures.fetch_add(1, Relaxed);
        }
    });
    eprintln!(
        "{} 4:4:4 pictures decode exactly in {}; {}",
        pictures.into_inner(),
        installed.join(" and "),
        cov.report()
    );
    cov.check();
    let _ = std::fs::remove_dir_all(&dir);
}

/// The rules 4:4:4 changes, from the spec (and libaom's decoder): every block has chroma, its
/// chroma block is its own, the chroma tx size caps 64-sample sides at 32, CfL is allowed by the
/// luma size as in 4:2:0.
#[test]
fn chroma444_geometry() {
    for bs in 0..BLOCK_SIZES {
        for (r, c) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
            assert!(has_chroma(bs, r, c, false, 0));
            assert!(!has_chroma(bs, r, c, true, 0));
        }
        assert_eq!(uv_bsize(bs, 0), bs);
        let t = Max_Tx_Size_Rect[bs as usize] as i32;
        let want = match t {
            TX_64X64 | TX_32X64 | TX_64X32 => TX_32X32,
            TX_16X64 => TX_16X32,
            TX_64X16 => TX_32X16,
            t => t,
        };
        assert_eq!(uv_tx_size(bs, 0), want, "bsize {bs}");
        let a = block_avail(bs, 5, 5, false, 0, 0, 64, 0, 64);
        assert_eq!((a.u_chroma, a.l_chroma), (a.u, a.l));
    }
    // a 64x64 block's chroma is four 32x32s per plane, in raster order
    let mut v = Vec::new();
    for_each_txb(BLOCK_64X64, 0, 0, 0, false, 0, 16, 16, |p, t, x4, y4, _, _| {
        if p == 1 {
            v.push((t, x4, y4))
        }
    });
    assert_eq!(v, [(TX_32X32, 0, 0), (TX_32X32, 8, 0), (TX_32X32, 0, 8), (TX_32X32, 8, 8)]);
}

/// The sequence header of a 4:4:4 picture is the High profile's (seq_profile 1, no mono_chrome, no
/// chroma_sample_position), and its AVIF's av1C says so.
#[test]
fn chroma444_headers() {
    let rec = (0..40).find_map(|s| record_444(s, 64, false).filter(|r| r.fp.video == 0)).unwrap();
    let mut a = rec.clone();
    let out = encode(a.as_mut(), &opts(ENC_FIX_RANGE | ENC_AVIF)).unwrap();
    // OBU_SEQUENCE_HEADER (0x0A), its size, then seq_profile in the top 3 bits
    assert_eq!(out.obu[0], 0x0A);
    assert_eq!(out.obu[2] >> 5, 1, "seq_profile");
    let i = out.avif.windows(4).position(|w| w == b"av1C").unwrap() + 4;
    let c = &out.avif[i..i + 4];
    assert_eq!(c[1] >> 5, 1, "av1C seq_profile");
    // high_bitdepth, twelve_bit, monochrome 0; chroma_subsampling_x / _y 0; position 0
    assert_eq!(c[2] & 0x7F, 0, "av1C chroma fields");
    let p = parse(&out.obu).unwrap();
    assert_eq!((p.rec.fp.chroma_format, p.rec.fp.monochrome), (CHROMA_444, 0));
}

/// What 4:4:4 refuses: inter frames, monochrome, chroma formats other than 0 and 1, symbol
/// streams; and a version 1 record's chroma_format is not read (4:2:0).
#[test]
fn chroma444_refusals() {
    let rec = (0..40).find_map(|s| record_444(s, 64, false).filter(|r| r.fp.allow_intrabc == 0)).unwrap();
    // the error's message, or "" for success
    let refused = |r: &Record, extras: &Extras| {
        let mut r = r.clone();
        Writer::with_threads(1)
            .encode_into::<NoHook>(r.as_mut(), &opts(ENC_FIX_RANGE), None, extras, None, &mut Output::default())
            .map_or_else(|e| e.msg, |_| String::new())
    };
    let none = Extras::default();
    assert_eq!(refused(&rec, &none), "");
    let mut bad = rec.clone();
    bad.fp.monochrome = 1;
    assert!(refused(&bad, &none).contains("4:4:4"), "monochrome");
    let mut bad = rec.clone();
    bad.fp.chroma_format = 2;
    assert!(refused(&bad, &none).contains("chroma_format"), "chroma_format 2");
    let mut bad = rec.clone();
    (bad.fp.video, bad.fp.frame_type) = (1, FRAME_INTER);
    assert!(refused(&bad, &none).contains("4:4:4"), "inter frame");
    let syms = Extras {
        record_syms: true,
        ..Extras::default()
    };
    assert!(refused(&rec, &syms).contains("4:2:0"), "symbol streams");
    // version 1: 4:2:0, whatever the byte says (the layout of a 4:4:4 record isn't 4:2:0's)
    let mut v1 = rec.clone();
    v1.fp.version = 1;
    assert_eq!(chroma_ss(&v1.fp), 1);
}
