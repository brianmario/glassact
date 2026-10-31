//! Differential tests against the C++ (Sources/AV1CoreTestSupport): every record and every DSP set
//! equal the C++'s for fixed seeds.
// src/dsp/tests.rs and src/entropy/tests.rs declare av1t_dsp_set_make with their own set types
#![allow(clashing_extern_declarations)]
use super::*;
use crate::tables::*;
use crate::types::{Block, DecisionRecord, ERR_CAPACITY, FrameParams, OK, Tiles, Txb};
use core::ffi::{c_char, c_void};
use core::mem::{offset_of, size_of};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

unsafe extern "C" {
    // oracle/testsupport.cpp: sizeof / offsetof of the case structs and av1t_dsp_set, by name
    fn oracle_testsupport_layout(what: *const c_char) -> i64;
    // av1core_test.h
    fn av1t_case_make(seed: u64, maxdim: i32, big_pct: i32) -> *mut c_void;
    fn av1t_case_record(c: *mut c_void) -> *mut DecisionRecord;
    fn av1t_case_free(c: *mut c_void);
    fn av1t_dsp_set_make(seed: u64) -> *const DspSetC;
    fn av1t_dsp_set_free(set: *const DspSetC);
    fn av1t_inverse_transform(tx_sz: i32, tx_type: i32, dq: *const i32, residual: *mut i32) -> u32;
    fn av1t_tx_type_allowed(tx_sz: i32, tx_type: i32) -> i32;
    // av1g.h
    fn av1g_tile_layout(width: u32, height: u32, cols_log2: i32, rows_log2: i32, out: *mut Tiles) -> i32;
    fn av1g_layout(rec: *mut DecisionRecord, txb_cap: u32, coeff_cap: u64) -> i32;
    fn av1g_legalize_sb_qindex(base_q_idx: i32, delta_q_res: i32, target: *const u8, n: usize, legal: *mut u8);
    fn av1g_apply_sb_qindex(rec: *mut DecisionRecord, sb_map: *const u8) -> i32;
    fn av1g_validate(rec: *const DecisionRecord, err: *mut c_char, errlen: usize) -> i32;
}

fn c_layout(what: &str) -> i64 {
    let s = std::ffi::CString::new(what).unwrap();
    // SAFETY: a NUL-terminated name; the shim only compares it.
    let v = unsafe { oracle_testsupport_layout(s.as_ptr()) };
    assert!(v >= 0, "oracle_testsupport_layout doesn't know {what}");
    v
}

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

/// `n` elements at `p` as bytes.
///
/// SAFETY: `p` points to `n` initialized `T`s that outlive the slice.
unsafe fn bytes_of<'a, T>(p: *const T, n: usize) -> &'a [u8] {
    // SAFETY: as the caller promises; any initialized memory reads as bytes.
    unsafe { core::slice::from_raw_parts(p as *const u8, n * size_of::<T>()) }
}
fn as_bytes<T>(v: &[T]) -> &[u8] {
    // SAFETY: a live slice; the element types here are padding-free repr(C) structs and integers.
    unsafe { bytes_of(v.as_ptr(), v.len()) }
}

#[test]
fn dsp_sets_match_c() {
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
    ];
    std::thread::scope(|sc| {
        for &seed in &seeds {
            sc.spawn(move || {
                let r = DspSet::make(seed);
                let v = r.c_view();
                // SAFETY: the C set lives until av1t_dsp_set_free; the array lengths are its own counts.
                unsafe {
                    let c = &*av1t_dsp_set_make(seed);
                    macro_rules! same {
                        ($($f:ident),*) => { $(assert_eq!(v.$f, c.$f, "seed {seed}: {}", stringify!($f));)* };
                    }
                    same!(
                        itx_count,
                        itx_flagged_count,
                        itx_case_size,
                        itx_coeffs_per_case,
                        itx_residual_per_case,
                        pred_count,
                        pred_cfl_count,
                        pred_side,
                        pred_case_size,
                        pred_luma_size,
                        ec_count,
                        ec_qindex,
                        ec_symbol_count,
                        ec_capacity,
                        ec_cdfs_size,
                        ec_symbol_size
                    );
                    let (ni, np, ne) = (c.itx_count as usize, c.pred_count as usize, c.ec_count as usize);
                    let side2 = (c.pred_side * c.pred_side) as usize;
                    let arrays: [(&str, &[u8], &[u8]); 13] = [
                        (
                            "itx_cases",
                            as_bytes(&r.itx),
                            bytes_of(c.itx_cases as *const ItxCase, ni),
                        ),
                        (
                            "itx_coeffs",
                            as_bytes(&r.itx_coeffs),
                            bytes_of(c.itx_coeffs, ni * ITX_COEFFS),
                        ),
                        (
                            "itx_residual",
                            as_bytes(&r.itx_residual),
                            bytes_of(c.itx_residual, ni * ITX_RESIDUAL),
                        ),
                        ("itx_flags", as_bytes(&r.itx_flags), bytes_of(c.itx_flags, ni)),
                        (
                            "pred_cases",
                            as_bytes(&r.pred),
                            bytes_of(c.pred_cases as *const PredCase, np),
                        ),
                        ("pred_planes", &r.pred_planes, bytes_of(c.pred_planes, np * side2)),
                        (
                            "pred_luma",
                            &r.pred_luma,
                            bytes_of(c.pred_luma, c.pred_luma_size as usize),
                        ),
                        ("pred_out", &r.pred_out, bytes_of(c.pred_out, np * side2)),
                        (
                            "ec_symbols",
                            as_bytes(&r.ec_symbols),
                            bytes_of(c.ec_symbols as *const Sym, c.ec_symbol_count as usize),
                        ),
                        ("ec_offsets", as_bytes(&r.ec_offsets), bytes_of(c.ec_offsets, ne)),
                        ("ec_counts", as_bytes(&r.ec_counts), bytes_of(c.ec_counts, ne)),
                        ("ec_sizes", as_bytes(&r.ec_sizes), bytes_of(c.ec_sizes, ne)),
                        (
                            "ec_bytes",
                            &r.ec_bytes,
                            bytes_of(c.ec_bytes, ne * c.ec_capacity as usize),
                        ),
                    ];
                    for (name, rust, cpp) in arrays {
                        assert_eq!(rust.len(), cpp.len(), "seed {seed}: {name} length");
                        if let Some(i) = rust.iter().zip(cpp).position(|(a, b)| a != b) {
                            panic!("seed {seed}: {name} differs at byte {i}");
                        }
                    }
                    // the per-case views (the arrays above are their concatenations)
                    assert!(r.itx[..] == *core::slice::from_raw_parts(c.itx_cases as *const ItxCase, ni));
                    assert!(r.pred[..] == *core::slice::from_raw_parts(c.pred_cases as *const PredCase, np));
                    av1t_dsp_set_free(c);
                }
                assert!(r.itx_flagged_count > 0, "seed {seed}: no flagged transform");
                assert!(r.pred_cfl_count > 0 && r.ec_sizes.iter().all(|&s| s > 0));
            });
        }
    });
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
fn tx_type_allowed_matches_c() {
    for tx_sz in 0..TX_SIZES_ALL {
        for tx_type in 0..TX_TYPES {
            // SAFETY: plain ints.
            let c = unsafe { av1t_tx_type_allowed(tx_sz, tx_type) };
            assert_eq!(tx_type_allowed(tx_sz, tx_type), c != 0, "{tx_sz} {tx_type}");
        }
    }
}

#[test]
fn inverse_transform_matches_c() {
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
                let (mut a, mut b) = (vec![0i32; 4096], vec![0i32; 4096]);
                let fr = inverse_transform(tx_sz, tx_type, &dq, &mut a);
                // SAFETY: dq holds the th x tw coefficients, b the h x w residual.
                let fc = unsafe { av1t_inverse_transform(tx_sz, tx_type, dq.as_ptr(), b.as_mut_ptr()) };
                assert_eq!(fr, fc, "flags {tx_sz} {tx_type} {k}");
                assert!(a == b, "residual {tx_sz} {tx_type} {k}");
                flagged += (fr != 0) as u32;
            }
        }
    }
    assert!(flagged > 0);
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

/// The C++ writer's functions (Sources/AV1Core/src/encoder.cpp), until crate::writer has them.
struct OracleWriter;

impl WriterOps for OracleWriter {
    fn tile_layout(&self, width: u32, height: u32, cols_log2: i32, rows_log2: i32) -> Option<Tiles> {
        let mut t = Tiles {
            cols_log2: 0,
            rows_log2: 0,
            cols: 0,
            rows: 0,
            mi_col_starts: [0; 65],
            mi_row_starts: [0; 65],
        };
        // SAFETY: t is a whole av1g_tiles.
        (unsafe { av1g_tile_layout(width, height, cols_log2, rows_log2, &mut t) } == OK).then_some(t)
    }

    fn layout(&self, fp: &FrameParams, blocks: &[Block], block_txb: &mut Vec<u32>, txb: &mut Vec<Txb>) -> Option<u64> {
        block_txb.resize(blocks.len() + 1, 0);
        let mut rec = DecisionRecord {
            fp: *fp,
            n_blocks: blocks.len() as u32,
            n_txb: 0,
            n_coeffs: 0,
            blocks: blocks.as_ptr() as *mut Block, // av1g_layout only reads the blocks
            block_txb: block_txb.as_mut_ptr(),
            txb: core::ptr::null_mut(),
            coeffs: core::ptr::null_mut(),
        };
        // SAFETY: the record's arrays are the slices above (txb null: counts only).
        if unsafe { av1g_layout(&mut rec, 0, 0) } != ERR_CAPACITY {
            return None;
        }
        txb.clear();
        txb.resize(rec.n_txb as usize, Txb::default());
        rec.txb = txb.as_mut_ptr();
        // SAFETY: txb now holds n_txb entries, block_txb n_blocks + 1.
        (unsafe { av1g_layout(&mut rec, rec.n_txb, rec.n_coeffs) } == OK).then_some(rec.n_coeffs)
    }

    fn legalize_sb_qindex(&self, base_q_idx: i32, delta_q_res: i32, target: &[u8], legal: &mut [u8]) {
        assert_eq!(target.len(), legal.len());
        // SAFETY: both arrays hold target.len() bytes.
        unsafe {
            av1g_legalize_sb_qindex(
                base_q_idx,
                delta_q_res,
                target.as_ptr(),
                target.len(),
                legal.as_mut_ptr(),
            )
        }
    }

    fn apply_sb_qindex(&self, fp: &FrameParams, blocks: &mut [Block], sb_map: &[u8]) {
        let mut rec = DecisionRecord {
            fp: *fp,
            n_blocks: blocks.len() as u32,
            n_txb: 0,
            n_coeffs: 0,
            blocks: blocks.as_mut_ptr(),
            block_txb: core::ptr::null_mut(),
            txb: core::ptr::null_mut(),
            coeffs: core::ptr::null_mut(),
        };
        // SAFETY: the C reads the blocks and the SB map (one entry per SB of fp's picture).
        unsafe { av1g_apply_sb_qindex(&mut rec, sb_map.as_ptr()) };
    }
}

/// SAFETY: `p` points to `n` initialized `T`s that outlive the slice.
unsafe fn sl<'a, T>(p: *const T, n: usize) -> &'a [T] {
    // SAFETY: as the caller promises.
    unsafe { core::slice::from_raw_parts(p, n) }
}

/// Compares the Rust record of (seed, maxdim, big_pct) with the C++'s; Err describes the first
/// difference.
fn compare_case(seed: u64, maxdim: i32, big_pct: i32) -> Result<(), String> {
    let r = FuzzCase::make(seed, maxdim, big_pct, &OracleWriter);
    // SAFETY: the C case and its record live until av1t_case_free; the lengths are the record's own
    // (coeffs has n_coeffs + 1 entries, block_txb n_blocks + 1).
    unsafe {
        let c = av1t_case_make(seed, maxdim, big_pct);
        let res = match (&r, c.is_null()) {
            (None, true) => Ok(()),
            (Some(_), true) | (None, false) => Err(format!("made by one side only (rust: {})", r.is_some())),
            (Some(r), false) => {
                let rec = &*av1t_case_record(c);
                let (nb, nt, nc) = (rec.n_blocks as usize, rec.n_txb as usize, rec.n_coeffs as usize);
                if r.fp != rec.fp {
                    Err(format!("frame params\n rust {:?}\n c++  {:?}", r.fp, rec.fp))
                } else if (r.blocks.len(), r.txb.len(), r.n_coeffs) != (nb, nt, rec.n_coeffs) {
                    Err(format!(
                        "counts: rust {} {} {}, c++ {nb} {nt} {nc}",
                        r.blocks.len(),
                        r.txb.len(),
                        r.n_coeffs
                    ))
                } else if let Some(i) = r.blocks.iter().zip(sl(rec.blocks, nb)).position(|(a, b)| a != b) {
                    Err(format!(
                        "block {i}: rust {:?}, c++ {:?}",
                        r.blocks[i],
                        *rec.blocks.add(i)
                    ))
                } else if r.block_txb[..] != *sl(rec.block_txb, nb + 1) {
                    Err("block_txb".into())
                } else if let Some(i) = r.txb.iter().zip(sl(rec.txb, nt)).position(|(a, b)| a != b) {
                    Err(format!("txb {i}: rust {:?}, c++ {:?}", r.txb[i], *rec.txb.add(i)))
                } else if r.coeffs.len() != nc + 1 {
                    Err(format!("coeffs length {}", r.coeffs.len()))
                } else if let Some(i) = r.coeffs.iter().zip(sl(rec.coeffs, nc + 1)).position(|(a, b)| a != b) {
                    Err(format!("coeff {i}: rust {}, c++ {}", r.coeffs[i], *rec.coeffs.add(i)))
                } else {
                    Ok(())
                }
            }
        };
        if !c.is_null() {
            av1t_case_free(c);
        }
        res
    }
}

/// Runs compare_case on `count` seeds from `first` (wrapping) across threads; panics with every
/// failing seed.
fn compare_cases(first: u64, count: u64, maxdim: i32, big_pct: i32) {
    let next = AtomicU64::new(0);
    let fails = Mutex::new(Vec::new());
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
                    if let Err(e) = compare_case(seed, maxdim, big_pct) {
                        fails
                            .lock()
                            .unwrap()
                            .push(format!("seed {seed} ({maxdim}, {big_pct}): {e}"));
                    }
                }
            });
        }
    });
    let mut fails = fails.into_inner().unwrap();
    fails.sort();
    assert!(
        fails.is_empty(),
        "{} of {} seeds differ:\n{}",
        fails.len(),
        count,
        fails.join("\n")
    );
}

/// The parameters the Swift tests use (DecoderGateTests, EntropyTests, PostfilterTests).
#[test]
fn fuzz_cases_match_c_swift_params() {
    compare_cases(0, 2000, 300, 2);
}

#[test]
fn fuzz_cases_match_c_small() {
    compare_cases(0, 2000, 1, 0);
    compare_cases(0, 2000, 64, 0);
}

#[test]
fn fuzz_cases_match_c_wide() {
    compare_cases(2000, 1000, 300, 2);
    compare_cases(0, 500, 1000, 10);
    compare_cases(1 << 40, 500, 2000, 0);
    compare_cases(u64::MAX - 200, 400, 300, 2);
}

#[test]
fn fuzz_cases_match_c_big() {
    // mostly forced-tile pictures (several tiles, up to 9000 wide or 4096 x 2600)
    compare_cases(0, 60, 300, 100);
    compare_cases(5000, 60, 300, 50);
}

/// The Rust record is laid out, valid and points into its vectors.
#[test]
fn fuzz_records_validate() {
    let mut big = 0;
    for seed in 0..300 {
        let mut c = FuzzCase::make(seed, 300, 2, &OracleWriter).unwrap();
        let rec = c.record();
        assert_eq!(rec.n_blocks as usize, c.blocks.len());
        assert_eq!(rec.blocks, c.blocks.as_mut_ptr());
        assert_eq!(c.block_txb[c.blocks.len()] as usize, c.txb.len());
        let mut err = [0 as c_char; 256];
        // SAFETY: rec points into c, which outlives the call; err is 256 bytes.
        let rc = unsafe { av1g_validate(&rec, err.as_mut_ptr(), err.len()) };
        // SAFETY: av1g_validate NUL-terminates err.
        let msg = unsafe { std::ffi::CStr::from_ptr(err.as_ptr()) };
        assert_eq!(rc, OK, "seed {seed}: {msg:?}");
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
        let c = FuzzCase::make(seed, 300, 2, &OracleWriter).unwrap();
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
