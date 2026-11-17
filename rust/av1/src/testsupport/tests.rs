//! The test support's snapshots: every record and every DSP set for fixed seeds (until 2026-11-17
//! held equal to the C++'s, Sources/AV1CoreTestSupport, where these were recorded); the C layouts.
use super::snapshot::{Fnv, Snapshot};
use super::*;
use crate::tables::*;
use core::mem::{offset_of, size_of};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::types::tests::c_layout;

macro_rules! check {
    ($t:ty, $name:literal, $($f:ident : $cf:literal),*) => {
        assert_eq!(size_of::<$t>() as i64, c_layout($name), "sizeof {}", $name);
        $(assert_eq!(offset_of!($t, $f) as i64, c_layout(concat!($name, ".", $cf)), "{}.{}", $name, $cf);)*
    };
}

#[test]
fn layouts_match_c() {
    check!(ItxCase, "ItxCase", tx_sz: "txSz", tx_type: "txType", dc_q: "dcQ", ac_q: "acQ", qm_level: "qmLevel",
           plane: "plane");
    check!(PredCase, "PredCase", mode: "mode", delta: "delta", log2w: "log2W", log2h: "log2H", have_left: "haveLeft",
           have_above: "haveAbove", have_ar: "haveAR", have_bl: "haveBL", x: "x", y: "y", max_x: "maxX", max_y: "maxY",
           cfl: "cfl", alpha: "alpha", edge_filter: "edgeFilter", filter_type: "filterType", fi_mode: "fiMode");
    check!(Sym, "Sym", cdf_off: "cdfOff", s: "s", n: "N", is_bool: "isBool");
    check!(DspSetC, "DspSet", itx_count: "itx_count", itx_flagged_count: "itx_flagged_count", itx_cases: "itx_cases",
           itx_case_size: "itx_case_size", itx_coeffs_per_case: "itx_coeffs_per_case",
           itx_residual_per_case: "itx_residual_per_case", itx_coeffs: "itx_coeffs", itx_residual: "itx_residual",
           itx_flags: "itx_flags", pred_count: "pred_count", pred_cfl_count: "pred_cfl_count", pred_side: "pred_side",
           pred_cases: "pred_cases", pred_case_size: "pred_case_size", pred_luma_size: "pred_luma_size",
           pred_planes: "pred_planes", pred_luma: "pred_luma", pred_out: "pred_out", ec_count: "ec_count",
           ec_qindex: "ec_qindex", ec_symbol_count: "ec_symbol_count", ec_capacity: "ec_capacity",
           ec_cdfs_size: "ec_cdfs_size", ec_symbol_size: "ec_symbol_size", ec_symbols: "ec_symbols",
           ec_offsets: "ec_offsets", ec_counts: "ec_counts", ec_sizes: "ec_sizes", ec_bytes: "ec_bytes",
           priv_: "priv");
}

// ---- dsp_cases ----

#[test]
fn dsp_sets_snapshot() {
    let snaps = Mutex::new(Vec::new());
    let seeds = [
        0u64,
        1,
        2,
        3,
        0x5eed,
        0xdead_beef,
        0x0123_4567_89ab_cdef,
        u64::MAX,
        1 << 63,
        42,
        1000,
        77777,
        0xfeed,
    ];
    std::thread::scope(|sc| {
        for (k, &seed) in seeds.iter().enumerate() {
            let snaps = &snaps;
            sc.spawn(move || {
                let r = DspSet::make(seed);
                let v = r.c_view();
                let mut s = Snapshot::new(&["counts", "itx", "pred", "ec"]);
                s.put(
                    "counts",
                    &(
                        (v.itx_count, v.itx_flagged_count, v.itx_case_size, v.itx_coeffs_per_case),
                        (v.itx_residual_per_case, v.pred_count, v.pred_cfl_count, v.pred_side),
                        (v.pred_case_size, v.pred_luma_size, v.ec_count, v.ec_qindex),
                        (v.ec_symbol_count, v.ec_capacity, v.ec_cdfs_size, v.ec_symbol_size),
                    ),
                );
                s.put("itx", &(&r.itx, &r.itx_coeffs, &r.itx_residual, &r.itx_flags));
                s.put("pred", &(&r.pred, &r.pred_planes, &r.pred_luma, &r.pred_out));
                s.put(
                    "ec",
                    &(&r.ec_symbols, &r.ec_offsets, &r.ec_counts, &r.ec_sizes, &r.ec_bytes),
                );
                snaps.lock().unwrap().push((k, s));
                assert!(r.itx_flagged_count > 0, "seed {seed}: no flagged transform");
                assert!(r.pred_cfl_count > 0 && r.ec_sizes.iter().all(|&s| s > 0));
            });
        }
    });
    let mut v = snaps.into_inner().unwrap();
    v.sort_by_key(|c| c.0);
    let mut s = Snapshot::new(&["counts", "itx", "pred", "ec"]);
    v.iter().for_each(|c| s.absorb(&c.1));
    s.check(&[
        ("counts", 0x8c7d540fa24319b8),
        ("itx", 0x50eb661b23df36de),
        ("pred", 0x79ece522ae47915f),
        ("ec", 0x17240dc07e2bc11d),
    ]);
}

/// xorshift64 for the tests' own inputs.
struct XRng(u64);
impl XRng {
    fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 16) as u32
    }
    fn range(&mut self, lo: i32, hi: i32) -> i32 {
        lo + (self.next() % (hi - lo + 1) as u32) as i32
    }
}

#[test]
fn tx_type_allowed_snapshot() {
    let mut s = Snapshot::new(&["allowed"]);
    for tx_sz in 0..TX_SIZES_ALL {
        for tx_type in 0..TX_TYPES {
            s.put("allowed", &(tx_type_allowed(tx_sz, tx_type)));
        }
    }
    s.check(&[("allowed", 0x55ffa6fa39ffa72e)]);
}

#[test]
fn inverse_transform_snapshot() {
    let mut s = Snapshot::new(&["flags", "residual"]);
    let mut r = XRng(0x17a_5eed);
    let mut flagged = 0;
    for tx_sz in 0..TX_SIZES_ALL {
        let n = crate::dsp::tx_coeffs(tx_sz);
        for tx_type in (0..TX_TYPES).filter(|&t| tx_type_allowed(tx_sz, t)) {
            for k in 0..64 {
                let mut dq = vec![0i32; n];
                match k % 4 {
                    0 => {
                        for _ in 0..1 + r.next() % 12 {
                            dq[(r.next() as usize) % n.min(16)] = r.range(-3000, 3000);
                        }
                    }
                    1 => dq.iter_mut().for_each(|v| {
                        *v = if r.next().is_multiple_of(4) {
                            r.range(-400, 400)
                        } else {
                            0
                        }
                    }),
                    2 => dq.iter_mut().for_each(|v| *v = r.range(-32768, 32767)),
                    _ => {
                        for _ in 0..1 + r.next() % 4 {
                            dq[(r.next() as usize) % n] = if r.next().is_multiple_of(2) { -32768 } else { 32767 };
                        }
                    }
                }
                let mut a = vec![0i32; 4096];
                let fr = inverse_transform(tx_sz, tx_type, &dq, &mut a);
                s.put("flags", &fr);
                s.put("residual", &a);
                flagged += (fr != 0) as u32;
            }
        }
    }
    assert!(flagged > 0);
    s.check(&[("flags", 0xca1a78ab56ae9816), ("residual", 0x1d87a8d133f66351)]);
}

#[test]
fn ec_stream_overflows_as_c() {
    // the C++ fails exactly when the stream is longer than the precarry buffer
    let syms: Vec<Sym> = (0..2000)
        .map(|i| Sym {
            s: (i % 3 == 0) as u16,
            is_bool: 1,
            n: 2,
            cdf_off: 0,
        })
        .collect();
    let mut ec = crate::entropy::Ec::new();
    let mut out = Vec::new();
    let mut cdf = crate::entropy::Cdfs::new(100);
    let n = ec_stream(&syms, &mut cdf, &mut ec, 1 << 15, &mut out);
    assert_eq!(n as usize, out.len());
    assert_eq!(ec_stream(&syms, &mut cdf, &mut ec, n as usize, &mut out), n);
    assert_eq!(ec_stream(&syms, &mut cdf, &mut ec, n as usize - 1, &mut out), -1);
    assert!(out.is_empty());
}

// ---- fuzz_gen ----

/// The Rust records of `count` seeds from `first` (wrapping), made across threads, hashed in seed
/// order into the family `fam` of `snap`.
fn compare_cases(snap: &mut Snapshot, fam: &str, first: u64, count: u64, maxdim: i32, big_pct: i32) {
    let next = AtomicU64::new(0);
    let fails = Mutex::new(Vec::new());
    let hashes = Mutex::new(Vec::new());
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get());
    std::thread::scope(|sc| {
        for _ in 0..threads {
            sc.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    if i >= count {
                        break;
                    }
                    let seed = first.wrapping_add(i);
                    let mut h = Fnv::default();
                    h.put(&FuzzCase::make(seed, maxdim, big_pct));
                    hashes.lock().unwrap().push((i, h.0));
                }
            });
        }
    });
    let mut fails: Vec<String> = fails.into_inner().unwrap();
    fails.sort();
    assert!(
        fails.is_empty(),
        "{} of {} seeds differ:\n{}",
        fails.len(),
        count,
        fails.join("\n")
    );
    let mut hashes = hashes.into_inner().unwrap();
    hashes.sort();
    assert_eq!(hashes.len() as u64, count);
    for (_, h) in hashes {
        snap.put(fam, &h);
    }
}

/// The parameters the Swift tests use (DecoderGateTests, EntropyTests, PostfilterTests).
#[test]
fn fuzz_cases_snapshot_swift_params() {
    let mut s = Snapshot::new(&["0+2000 300/2"]);
    compare_cases(&mut s, "0+2000 300/2", 0, 2000, 300, 2);
    s.check(&[("0+2000 300/2", 0x2c8387278dbecd5d)]);
}

#[test]
fn fuzz_cases_snapshot_small() {
    let mut s = Snapshot::new(&["0+2000 1/0", "0+2000 64/0"]);
    compare_cases(&mut s, "0+2000 1/0", 0, 2000, 1, 0);
    compare_cases(&mut s, "0+2000 64/0", 0, 2000, 64, 0);
    s.check(&[("0+2000 1/0", 0x9b3dee59c8dcd794), ("0+2000 64/0", 0x0249e7e234b62469)]);
}

#[test]
fn fuzz_cases_snapshot_wide() {
    let mut s = Snapshot::new(&[
        "2000+1000 300/2",
        "0+500 1000/10",
        "2^40+500 2000/0",
        "max-200+400 300/2",
    ]);
    compare_cases(&mut s, "2000+1000 300/2", 2000, 1000, 300, 2);
    compare_cases(&mut s, "0+500 1000/10", 0, 500, 1000, 10);
    compare_cases(&mut s, "2^40+500 2000/0", 1 << 40, 500, 2000, 0);
    compare_cases(&mut s, "max-200+400 300/2", u64::MAX - 200, 400, 300, 2);
    s.check(&[
        ("2000+1000 300/2", 0x6f96db648409ddaf),
        ("0+500 1000/10", 0x4a635d7bfd6b5f07),
        ("2^40+500 2000/0", 0x44bfb1ba45f44d1e),
        ("max-200+400 300/2", 0xed5495a07540e8a4),
    ]);
}

#[test]
fn fuzz_cases_snapshot_big() {
    // mostly forced-tile pictures (several tiles, up to 9000 wide or 4096 x 2600)
    let mut s = Snapshot::new(&["0+60 300/100", "5000+60 300/50"]);
    compare_cases(&mut s, "0+60 300/100", 0, 60, 300, 100);
    compare_cases(&mut s, "5000+60 300/50", 5000, 60, 300, 50);
    s.check(&[
        ("0+60 300/100", 0xe5a08adae86a659b),
        ("5000+60 300/50", 0x05ea7afa9c534350),
    ]);
}

/// The Rust record is laid out, valid and points into its vectors.
#[test]
fn fuzz_records_validate() {
    let mut big = 0;
    for seed in 0..300 {
        let mut c = FuzzCase::make(seed, 300, 2).unwrap();
        let rec = c.record();
        assert_eq!(rec.n_blocks as usize, c.blocks.len());
        assert_eq!(rec.blocks, c.blocks.as_mut_ptr());
        assert_eq!(c.block_txb[c.blocks.len()] as usize, c.txb.len());
        let mut rec = rec;
        // SAFETY: rec points into c, which outlives the view.
        let r = unsafe { crate::writer::RecordMut::from_c(&mut rec) }.and_then(crate::writer::validate);
        assert_eq!(r.map_err(|e| e.code), Ok(()), "seed {seed}");
        big += (c.fp.width > 4096) as u32;
    }
    assert!(big > 0);
}

/// The compared seeds reach every feature of the generator.
#[test]
fn fuzz_cases_cover_features() {
    let mut sizes = [false; BLOCK_SIZES as usize];
    let (mut tiles, mut dq, mut cdef, mut lf, mut qm, mut fi, mut cfl, mut sct, mut golomb, mut mono) =
        (false, false, false, false, false, false, false, false, false, false);
    for seed in 0..2000 {
        let c = FuzzCase::make(seed, 300, 2).unwrap();
        let fp = &c.fp;
        tiles |= fp.tile_cols_log2 > 0 || fp.tile_rows_log2 > 0 || fp.width > 4096;
        dq |= fp.delta_q_present != 0 && c.blocks.iter().any(|b| b.sb_qindex != fp.base_q_idx);
        cdef |= fp.enable_cdef != 0 && c.blocks.iter().any(|b| b.cdef_idx > 0);
        lf |= fp.loop_filter_level.iter().all(|&l| l > 0);
        qm |= fp.using_qmatrix != 0;
        sct |= fp.allow_screen_content_tools != 0;
        mono |= fp.monochrome != 0;
        fi |= c.blocks.iter().any(|b| b.filter_intra != 0);
        cfl |= c.blocks.iter().any(|b| b.uv_mode as i32 == UV_CFL_PRED);
        golomb |= c.coeffs.iter().any(|&q| q.unsigned_abs() > 5000);
        for b in &c.blocks {
            sizes[b.bsize as usize] = true;
        }
    }
    let got = [tiles, dq, cdef, lf, qm, fi, cfl, sct, golomb, mono];
    assert!(
        got.iter().all(|&g| g),
        "tiles dq cdef lf qm fi cfl sct golomb mono: {got:?}"
    );
    // every partition type: every block size but the 128-sample ones
    let want = |b: usize| !(BLOCK_64X128 as usize..=BLOCK_128X128 as usize).contains(&b);
    assert!((0..BLOCK_SIZES as usize).all(|b| sizes[b] == want(b)), "{sizes:?}");
}
