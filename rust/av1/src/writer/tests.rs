//! The writer against the C++ (Sources/AV1Core/src/encoder.cpp): random legal records of av1gpu's
//! fuzzer (av1t_case_make) with every flag, invalid records, the hook path, tile skips and symbol
//! streams, the parser; and the enc module's entropy plan, OBU assembly and post-filter frame.
#![cfg(feature = "oracle")]

use super::*;
use crate::blockinfo::*;
use crate::dsp::{get_tx_set_intra, tx_coeffs, tx_h, tx_type_in_set_intra, tx_w};
use crate::tables::*;
use core::ffi::{c_char, c_int};

// ---------------------------------------------------------------------------------------------
// the oracle
// ---------------------------------------------------------------------------------------------

type CCase = core::ffi::c_void;

unsafe extern "C" {
    fn av1t_case_make(seed: u64, maxdim: c_int, big_pct: c_int) -> *mut CCase;
    fn av1t_case_record(c: *mut CCase) -> *mut DecisionRecord;
    fn av1t_case_free(c: *mut CCase);
    fn av1g_output_free(out: *mut crate::types::Output);
    fn av1g_validate(rec: *const DecisionRecord, err: *mut c_char, errlen: usize) -> c_int;
    fn av1g_layout(rec: *mut DecisionRecord, txb_cap: u32, coeff_cap: u64) -> c_int;
    fn av1g_tile_layout(w: u32, h: u32, cols_log2: c_int, rows_log2: c_int, out: *mut Tiles) -> c_int;
    fn av1g_legalize_sb_qindex(base: c_int, res: c_int, target: *const u8, n: usize, legal: *mut u8);
    fn av1g_apply_sb_qindex(rec: *mut DecisionRecord, map: *const u8) -> c_int;
    fn av1g_parse(obus: *const u8, size: usize, out: *mut *mut crate::types::Parsed) -> c_int;
    fn av1g_parsed_free(p: *mut crate::types::Parsed);
    fn oracle_writer_encode(
        rec: *mut DecisionRecord,
        opts: *const EncodeOpts,
        out: *mut crate::types::Output,
        hook_mode: c_int,
        record_syms: c_int,
        nskip: u32,
        skip: *const u8,
        payloads: *const *const u8,
        payload_sizes: *const usize,
    ) -> c_int;
    fn oracle_writer_n_tiles() -> usize;
    fn oracle_writer_n_sym_tiles() -> usize;
    fn oracle_writer_syms(tile: usize, n: *mut usize) -> *const u32;
    fn oracle_writer_payload(tile: usize, n: *mut usize) -> *const u8;
    fn av1enc_ent_plan(fp: *const FrameParams, nb: u32, nt: u32, frame: *mut GaEntFrame, tiles: *mut GaEntTile) -> u32;
    fn av1enc_assemble_obus(
        fp: *const FrameParams,
        data: *const *const u8,
        sizes: *const usize,
        n: u32,
        td: c_int,
        out: *mut *mut u8,
        size: *mut usize,
    ) -> c_int;
    fn av1enc_pf_frame(fp: *const FrameParams, a: *const GaPfAddrs, out: *mut u8, cap: usize) -> usize;
    fn free(p: *mut core::ffi::c_void);
}

/// av1t_case_make's record, copied.
fn case(seed: u64, maxdim: i32, big_pct: i32) -> Option<Record> {
    // SAFETY: the C test support's case and its record's arrays (counts from av1g_layout).
    unsafe {
        let c = av1t_case_make(seed, maxdim, big_pct);
        if c.is_null() {
            return None;
        }
        let r = &*av1t_case_record(c);
        unsafe fn sl<T: Clone>(p: *const T, n: usize) -> Vec<T> {
            if n == 0 {
                Vec::new()
            } else {
                unsafe { core::slice::from_raw_parts(p, n) }.to_vec()
            }
        }
        let rec = Record {
            fp: r.fp,
            blocks: sl(r.blocks as *const Block, r.n_blocks as usize),
            block_txb: sl(r.block_txb as *const u32, r.n_blocks as usize + 1),
            txb: sl(r.txb as *const Txb, r.n_txb as usize),
            coeffs: sl(r.coeffs as *const i16, r.n_coeffs as usize),
        };
        av1t_case_free(c);
        Some(rec)
    }
}

/// An encode's results: the return code, the output, the tile payloads and symbol streams.
#[derive(Debug, PartialEq, Eq)]
struct Enc {
    rc: i32,
    out: Output,
    payloads: Vec<Vec<u8>>,
    syms: Vec<Vec<u32>>,
}

fn c_output(o: &crate::types::Output) -> Output {
    // SAFETY: av1g_output's buffers, sized by its fields.
    let v = |p: *mut u8, n: usize| {
        if p.is_null() {
            Vec::new()
        } else {
            unsafe { core::slice::from_raw_parts(p, n) }.to_vec()
        }
    };
    Output {
        obu: v(o.obu, o.obu_size),
        avif: v(o.avif, o.avif_size),
        recon: core::array::from_fn(|p| v(o.recon[p], (o.recon_w[p] * o.recon_h[p]) as usize)),
        recon_w: o.recon_w,
        recon_h: o.recon_h,
        seq_level_idx: o.seq_level_idx,
        tile_cols: o.tile_cols,
        tile_rows: o.tile_rows,
        header_bytes: o.header_bytes,
        tile_bytes: o.tile_bytes,
        n_symbols: o.n_symbols,
        n_fixed_txb: o.n_fixed_txb,
    }
}

/// The C++ encode_with_hook on `rec` (changed in place, as the C++ changes it).
fn c_encode(
    rec: &mut Record,
    flags: u32,
    level: i32,
    hook: i32,
    syms: bool,
    skip: Option<(&[bool], &[Vec<u8>])>,
) -> Enc {
    let opts = EncodeOpts {
        flags,
        seq_level_idx: level,
    };
    let mut cr = rec.as_c();
    // SAFETY: av1g_output is plain data (zeroed is its initial state); the record points into rec.
    unsafe {
        let mut o: crate::types::Output = core::mem::zeroed();
        let (flags_, ptrs, sizes): (Vec<u8>, Vec<*const u8>, Vec<usize>) = match skip {
            Some((s, p)) => (
                s.iter().map(|&b| b as u8).collect(),
                p.iter()
                    .map(|v| if v.is_empty() { core::ptr::null() } else { v.as_ptr() })
                    .collect(),
                p.iter().map(|v| v.len()).collect(),
            ),
            None => (Vec::new(), Vec::new(), Vec::new()),
        };
        let rc = oracle_writer_encode(
            &mut cr,
            &opts,
            &mut o,
            hook,
            syms as c_int,
            flags_.len() as u32,
            flags_.as_ptr(),
            ptrs.as_ptr(),
            sizes.as_ptr(),
        );
        let out = if rc == OK { c_output(&o) } else { Output::default() };
        av1g_output_free(&mut o);
        let mut payloads = Vec::new();
        let mut symv = Vec::new();
        if rc == OK {
            for t in 0..oracle_writer_n_tiles() {
                let mut n = 0;
                let p = oracle_writer_payload(t, &mut n);
                payloads.push(if n == 0 {
                    Vec::new()
                } else {
                    core::slice::from_raw_parts(p, n).to_vec()
                });
            }
            for t in 0..oracle_writer_n_sym_tiles() {
                let mut n = 0;
                let p = oracle_writer_syms(t, &mut n);
                symv.push(if n == 0 {
                    Vec::new()
                } else {
                    core::slice::from_raw_parts(p, n).to_vec()
                });
            }
        }
        Enc {
            rc,
            out,
            payloads,
            syms: symv,
        }
    }
}

/// The test hook: the same function as oracle/writer.cpp's TestHook.
struct TestHook(i32);

impl TxbHook for TestHook {
    type Scratch = ();
    fn on_txb(&self, _: &mut (), c: &TxbCtx, t: &mut Txb, coeffs: &mut [i16]) {
        let tx_sz = t.tx_size as i32;
        let (w, h, n) = (tx_w(tx_sz) as usize, tx_h(tx_sz) as usize, tx_coeffs(tx_sz));
        let mut s = c.block_idx.wrapping_mul(2654435761)
            ^ ((t.plane as u32) << 7)
            ^ (c.dc_q as u32).wrapping_mul(31)
            ^ (c.ac_q as u32).wrapping_mul(17)
            ^ (c.derived_tx_type as u32).wrapping_mul(5)
            ^ (c.qm_level as u32).wrapping_mul(3)
            ^ (c.block.y_mode as u32).wrapping_mul(7);
        for i in 0..h {
            for j in 0..w {
                s = s.wrapping_mul(31).wrapping_add(c.recon[i * c.recon_stride + j] as u32);
            }
        }
        for k in coeffs.iter_mut().take(n) {
            s = s.wrapping_mul(1103515245).wrapping_add(12345);
            let v = (s >> 16) % 64;
            let mut x = 0i32;
            if v >= 56 {
                x = v as i32 - 60;
            } else if v >= 54 {
                x = ((s >> 4) % 61) as i32 - 30;
            }
            if self.0 == 2 && (s >> 3).is_multiple_of(97) {
                x = ((s >> 5) % 65535) as i32 - 32767;
            }
            *k = x as i16;
        }
        if t.plane == 0 {
            s = s.wrapping_mul(1103515245).wrapping_add(12345);
            let mut ty = DCT_DCT;
            if (Tx_Size_Sqr_Up[tx_sz as usize] as i32) < TX_32X32 {
                ty = ((s >> 16) % 16) as i32;
                if !tx_type_in_set_intra(TX_SET_INTRA_2, ty) {
                    ty = DCT_DCT;
                }
            }
            t.tx_type = ty as u8;
        }
    }
}

/// The Rust encode on `rec` (changed in place).
fn r_encode(
    w: &mut Writer,
    rec: &mut Record,
    flags: u32,
    level: i32,
    hook: i32,
    syms: bool,
    skip: Option<(&[bool], &[Vec<u8>])>,
) -> Enc {
    let opts = EncodeOpts {
        flags,
        seq_level_idx: level,
    };
    let sk: Option<Vec<TileSkip>> = skip.map(|(s, p)| {
        s.iter()
            .zip(p)
            .map(|(&skip, p)| TileSkip {
                skip,
                payload: (!p.is_empty()).then_some(&p[..]),
            })
            .collect()
    });
    let extras = Extras {
        tile_skip: sk.as_deref(),
        record_syms: syms,
    };
    let mut out = Output::default();
    let r = if hook != 0 {
        w.encode_with_hook(rec.as_mut(), &opts, Some(&TestHook(hook)), &extras, &mut out)
    } else {
        w.encode_with_hook::<NoHook>(rec.as_mut(), &opts, None, &extras, &mut out)
    };
    match r {
        Ok(()) => Enc {
            rc: OK,
            out,
            payloads: w.tile_payloads().to_vec(),
            syms: w.tile_syms().to_vec(),
        },
        Err(e) => Enc {
            rc: e.code,
            out: Output::default(),
            payloads: Vec::new(),
            syms: Vec::new(),
        },
    }
}

fn first_diff<T: PartialEq>(a: &[T], b: &[T]) -> Option<usize> {
    if a.len() != b.len() {
        return Some(a.len().min(b.len()));
    }
    a.iter().zip(b).position(|(x, y)| x != y)
}

fn check_same(what: &str, c: &Enc, r: &Enc, crec: &Record, rrec: &Record) {
    assert_eq!(c.rc, r.rc, "{what}: return code");
    let (co, ro) = (&c.out, &r.out);
    assert!(
        first_diff(&co.obu, &ro.obu).is_none(),
        "{what}: OBUs differ at {:?}",
        first_diff(&co.obu, &ro.obu)
    );
    assert!(co.avif == ro.avif, "{what}: AVIF");
    for p in 0..3 {
        assert_eq!(
            (co.recon_w[p], co.recon_h[p]),
            (ro.recon_w[p], ro.recon_h[p]),
            "{what}: recon size {p}"
        );
        if let Some(i) = first_diff(&co.recon[p], &ro.recon[p]) {
            let w = co.recon_w[p].max(1) as usize;
            panic!("{what}: recon plane {p} differs at ({}, {})", i % w, i / w);
        }
    }
    assert_eq!(co, ro, "{what}: stats");
    assert_eq!(c.payloads, r.payloads, "{what}: tile payloads");
    assert_eq!(c.syms.len(), r.syms.len(), "{what}: symbol streams");
    for (t, (a, b)) in c.syms.iter().zip(&r.syms).enumerate() {
        assert!(a == b, "{what}: tile {t} symbols differ at {:?}", first_diff(a, b));
    }
    // after an error, the C++'s other tile threads have written back whatever they reached
    let tiles = tile_layout(
        crec.fp.width,
        crec.fp.height,
        crec.fp.tile_cols_log2 as i32,
        crec.fp.tile_rows_log2 as i32,
    );
    if c.rc != OK && tiles.is_ok_and(|t| t.cols * t.rows > 1) {
        return;
    }
    if let Some(i) = first_diff(&crec.txb, &rrec.txb) {
        panic!(
            "{what} rc {}: txb {i} written back: {:?} vs {:?}",
            c.rc, crec.txb[i], rrec.txb[i]
        );
    }
    if let Some(i) = first_diff(&crec.coeffs, &rrec.coeffs) {
        panic!(
            "{what}: coefficient {i} written back: {} vs {}",
            crec.coeffs[i], rrec.coeffs[i]
        );
    }
}

/// Encodes `rec` with both, compares everything, returns the C++ results.
fn both(w: &mut Writer, what: &str, rec: &Record, flags: u32, level: i32, hook: i32, syms: bool) -> (Enc, Record) {
    let (mut cr, mut rr) = (rec.clone(), rec.clone());
    let mut c = c_encode(&mut cr, flags, level, hook, syms, None);
    let r = r_encode(w, &mut rr, flags, level, hook, syms, None);
    // Errors in several tiles: the C++ reports the error of whichever tile thread comes first
    // (Rust: the first tile's, as sequential coding does). It must be one the C++ can report.
    let tiles = tile_layout(
        rec.fp.width,
        rec.fp.height,
        rec.fp.tile_cols_log2 as i32,
        rec.fp.tile_rows_log2 as i32,
    );
    if c.rc != r.rc && c.rc != OK && r.rc != OK && tiles.is_ok_and(|t| t.cols * t.rows > 1) {
        for _ in 0..200 {
            cr = rec.clone();
            c = c_encode(&mut cr, flags, level, hook, syms, None);
            if c.rc == r.rc {
                break;
            }
        }
    }
    check_same(what, &c, &r, &cr, &rr);
    (c, cr)
}

const FLAG_SETS: [u32; 9] = [
    0,
    ENC_TD | ENC_AVIF,
    ENC_PREFILTER_RECON,
    ENC_NO_RECON,
    ENC_BITSTREAM_ONLY,
    ENC_FIX_RANGE,
    ENC_FIX_RANGE | ENC_PREFILTER_RECON | ENC_AVIF,
    ENC_CHECK_EDGES | ENC_FIX_RANGE,
    ENC_BITSTREAM_ONLY | ENC_TD | ENC_NO_RECON,
];

/// Runs `f` over seeds on several threads (each with its own writer).
fn par_seeds(seeds: core::ops::Range<u64>, threads: usize, f: impl Fn(&mut Writer, u64) + Sync) {
    let next = std::sync::atomic::AtomicU64::new(seeds.start);
    std::thread::scope(|s| {
        for _ in 0..threads {
            s.spawn(|| {
                let mut w = Writer::new();
                loop {
                    let seed = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    if seed >= seeds.end {
                        break;
                    }
                    f(&mut w, seed);
                }
            });
        }
    });
}

// ---------------------------------------------------------------------------------------------
// encode
// ---------------------------------------------------------------------------------------------

/// Every flag combination on random legal records (all sizes, tilings, delta-q, QMs, filter
/// intra, the edge filter, post-filters, monochrome, screen content). One writer per thread is
/// reused across records, so leftovers of a previous picture would show.
#[test]
fn encode_matches_c_random_records() {
    // ok, errors, multi-tile, repaired tx blocks; records with: delta-q, QMs, filter intra, the
    // edge filter, deblocking, CDEF, monochrome, odd sizes, screen content, filter-intra blocks,
    // CfL blocks, skip blocks
    let stats = std::sync::Mutex::new([0u64; 16]);
    par_seeds(0..1500, 8, |w, seed| {
        let Some(rec) = case(seed, 300, 4) else { return };
        let mut ntiles = 0;
        for &flags in &FLAG_SETS {
            let (c, _) = both(w, &format!("seed {seed} flags {flags:#x}"), &rec, flags, -1, 0, false);
            if flags == ENC_FIX_RANGE {
                ntiles = c.out.tile_cols * c.out.tile_rows;
                let fp = &rec.fp;
                let mut s = stats.lock().unwrap();
                s[(c.rc == OK) as usize] += 1;
                s[2] += (ntiles > 1) as u64;
                s[3] += c.out.n_fixed_txb as u64;
                for (k, on) in [
                    fp.delta_q_present != 0,
                    fp.using_qmatrix != 0,
                    fp.enable_filter_intra != 0,
                    fp.enable_intra_edge_filter != 0,
                    fp.loop_filter_level != [0; 4],
                    fp.enable_cdef != 0,
                    fp.monochrome != 0,
                    fp.width % 8 != 0 || fp.height % 8 != 0,
                    fp.allow_screen_content_tools != 0,
                    rec.blocks.iter().any(|b| b.filter_intra != 0),
                    rec.blocks.iter().any(|b| b.uv_mode as i32 == UV_CFL_PRED),
                    rec.blocks.iter().any(|b| b.skip != 0),
                ]
                .into_iter()
                .enumerate()
                {
                    s[4 + k] += on as u64;
                }
            }
        }
        // a forced level, and one tile thread
        both(w, &format!("seed {seed} level 13"), &rec, ENC_TD, 13, 0, false);
        if ntiles > 1 {
            let mut w1 = Writer::with_threads(1);
            both(&mut w1, &format!("seed {seed} one thread"), &rec, 0, -1, 0, false);
        }
    });
    let s = stats.lock().unwrap();
    eprintln!(
        "records: {} ok, {} errors, {} multi-tile, {} repaired tx blocks; delta-q {}, QM {}, filter intra {}, \
         edge filter {}, deblocking {}, CDEF {}, monochrome {}, odd sizes {}, screen content {}",
        s[1], s[0], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11], s[12]
    );
    assert!(s[1] > 1400 && s[2] > 30 && s[3] > 0);
    assert!(s[4..16].iter().all(|&n| n > 50), "{:?}", &s[4..16]);
}

/// All 128 combinations of the flags.
#[test]
fn encode_matches_c_every_flag_combination() {
    let bits = [
        ENC_FIX_RANGE,
        ENC_NO_RECON,
        ENC_TD,
        ENC_AVIF,
        ENC_PREFILTER_RECON,
        ENC_BITSTREAM_ONLY,
        ENC_CHECK_EDGES,
    ];
    par_seeds(5000..5040, 8, |w, seed| {
        let Some(rec) = case(seed, 160, 3) else { return };
        for m in 0..1u32 << bits.len() {
            let flags = (0..bits.len()).filter(|&i| m >> i & 1 != 0).fold(0, |f, i| f | bits[i]);
            both(
                w,
                &format!("seed {seed} flags {flags:#x}"),
                &rec,
                flags,
                -1,
                (m % 3) as i32,
                m % 5 == 0,
            );
        }
    });
}

/// Big pictures: several tiles on parallel threads, with every output.
#[test]
fn encode_matches_c_multi_tile() {
    par_seeds(1000..1024, 3, |w, seed| {
        let Some(rec) = case(seed, 300, 100) else { return };
        for flags in [
            0,
            ENC_FIX_RANGE | ENC_PREFILTER_RECON | ENC_AVIF | ENC_TD,
            ENC_BITSTREAM_ONLY,
        ] {
            both(w, &format!("seed {seed} flags {flags:#x}"), &rec, flags, -1, 0, false);
        }
    });
}

/// The closed-loop hook: rewrites every tx block's coefficients and luma tx type from its exact
/// prediction (with large levels the range repair runs too).
#[test]
fn hook_matches_c() {
    par_seeds(0..200, 6, |w, seed| {
        let Some(rec) = case(seed, 200, 5) else { return };
        for (mode, flags) in [
            (1, ENC_FIX_RANGE | ENC_PREFILTER_RECON),
            (1, 0),
            (2, ENC_FIX_RANGE),
            (2, 0),
            (1, ENC_NO_RECON | ENC_TD),
        ] {
            both(
                w,
                &format!("seed {seed} hook {mode} flags {flags:#x}"),
                &rec,
                flags,
                -1,
                mode,
                false,
            );
        }
    });
}

/// Per-tile symbol streams (TeeSink), payloads and tile skips with given or missing payloads.
#[test]
fn tile_skips_and_symbols_match_c() {
    par_seeds(2000..2030, 3, |w, seed| {
        let Some(rec) = case(seed, 300, 70) else { return };
        let (c, _) = both(w, &format!("seed {seed} symbols"), &rec, ENC_FIX_RANGE, -1, 0, true);
        if c.rc != OK {
            return;
        }
        let n = c.payloads.len();
        let mut rnd = seed.wrapping_mul(0x9E3779B97F4A7C15) | 1;
        let mut bit = || {
            rnd ^= rnd << 13;
            rnd ^= rnd >> 7;
            rnd ^= rnd << 17;
            rnd & 1 != 0
        };
        for round in 0..3 {
            let skip: Vec<bool> = (0..n).map(|_| bit()).collect();
            let given: Vec<Vec<u8>> = c
                .payloads
                .iter()
                .map(|p| if round == 2 && bit() { Vec::new() } else { p.clone() })
                .collect();
            for (flags, hook) in [
                (ENC_FIX_RANGE | ENC_PREFILTER_RECON, 1),
                (ENC_TD | ENC_BITSTREAM_ONLY, 0),
                (0, 0),
            ] {
                let (mut cr, mut rr) = (rec.clone(), rec.clone());
                let what = format!("seed {seed} skip round {round} flags {flags:#x}");
                let cres = c_encode(&mut cr, flags, -1, hook, round == 1, Some((&skip, &given)));
                let rres = r_encode(w, &mut rr, flags, -1, hook, round == 1, Some((&skip, &given)));
                check_same(&what, &cres, &rres, &cr, &rr);
            }
        }
        // a wrong-sized skip list
        let (mut cr, mut rr) = (rec.clone(), rec.clone());
        let (s, g) = (vec![false; n + 1], vec![Vec::new(); n + 1]);
        let cres = c_encode(&mut cr, 0, -1, 0, false, Some((&s, &g)));
        let rres = r_encode(w, &mut rr, 0, -1, 0, false, Some((&s, &g)));
        assert_eq!((cres.rc, rres.rc), (ERR_INVALID, ERR_INVALID));
    });
}

// ---------------------------------------------------------------------------------------------
// invalid records
// ---------------------------------------------------------------------------------------------

struct Rnd(u64);
impl Rnd {
    fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 16) as u32
    }
    fn below(&mut self, n: u32) -> u32 {
        self.next() % n
    }
}

/// One random corruption of a valid record (fields, order, layout, coefficients, frame).
fn corrupt(rec: &mut Record, r: &mut Rnd) -> &'static str {
    let nb = rec.blocks.len() as u32;
    let b = r.below(nb) as usize;
    let k = r.below(32);
    let fp = &mut rec.fp;
    match k {
        0 => rec.blocks[b].bsize = r.below(24) as u8,
        1 => rec.blocks[b].skip = 2 + r.below(3) as u8,
        2 => rec.blocks[b].y_mode = 13 + r.below(5) as u8,
        3 => rec.blocks[b].angle_delta_y = r.below(9) as i8 - 4,
        4 => rec.blocks[b].uv_mode = r.below(16) as u8,
        5 => {
            rec.blocks[b].uv_mode = UV_CFL_PRED as u8;
            rec.blocks[b].cfl_alpha_u = r.below(40) as i8 - 20;
            rec.blocks[b].cfl_alpha_v = if r.below(2) == 0 { 0 } else { r.below(40) as i8 - 20 };
        }
        6 => rec.blocks[b].angle_delta_uv = r.below(9) as i8 - 4,
        7 => rec.blocks[b].tx_depth = r.below(4) as u8,
        8 => rec.blocks[b].filter_intra = r.below(7) as u8,
        9 => rec.blocks[b].cdef_idx = r.below(12) as i8 - 2,
        10 => rec.blocks[b].sb_qindex = r.below(256) as u8,
        11 => rec.blocks[b].mi_row = rec.blocks[b].mi_row.wrapping_add(1 + r.below(4) as u16),
        12 => rec.blocks[b].mi_col = rec.blocks[b].mi_col.wrapping_sub(1 + r.below(4) as u16),
        13 if nb > 1 => {
            let b2 = r.below(nb) as usize;
            rec.blocks.swap(b, b2);
            return "swap blocks";
        }
        14 if nb > 1 => {
            // drop a block (its tx blocks stay: the layout is stale)
            rec.blocks.remove(b);
            rec.block_txb.remove(b);
            return "drop block";
        }
        15 => {
            let t = r.below(rec.txb.len() as u32) as usize;
            rec.txb[t].tx_type = r.below(20) as u8;
        }
        16 => {
            let t = r.below(rec.txb.len() as u32) as usize;
            rec.txb[t].tx_size = r.below(19) as u8;
        }
        17 => {
            let t = r.below(rec.txb.len() as u32) as usize;
            rec.txb[t].x4 = rec.txb[t].x4.wrapping_add(1);
        }
        18 => {
            // large coefficients: inverse transform range violations
            let t = r.below(rec.txb.len() as u32) as usize;
            let (o, n) = (rec.txb[t].coeff_off as usize, tx_coeffs(rec.txb[t].tx_size as i32));
            for v in &mut rec.coeffs[o..o + n] {
                *v = if r.below(2) == 0 { 32767 } else { -32768 };
            }
        }
        19 => *rec.block_txb.last_mut().unwrap() += 1,
        20 => fp.version = 2,
        21 => {
            fp.width = [0, 65536, fp.width + 8, fp.width.saturating_sub(9)][r.below(4) as usize];
        }
        22 => fp.base_q_idx = 0,
        23 => match r.below(3) {
            0 => fp.monochrome = 2,
            1 => fp.tx_mode_select = 2,
            _ => fp.reduced_tx_set = 1 - fp.reduced_tx_set.min(1),
        },
        24 => fp.delta_q_u_ac = [64, -65, 100][r.below(3) as usize],
        25 => match r.below(4) {
            0 => fp.enable_filter_intra = 2,
            1 => fp.loop_filter_level[r.below(4) as usize] = 64,
            2 => fp.loop_filter_sharpness = 8,
            _ => {
                fp.loop_filter_level = [0, 0, 5, 0];
            }
        },
        26 => match r.below(4) {
            0 => fp.enable_cdef = 2,
            1 => fp.cdef_bits = 4,
            2 => fp.cdef_y_sec[r.below(8) as usize] = 3,
            _ => fp.cdef_uv_pri[r.below(8) as usize] = 16,
        },
        27 => match r.below(4) {
            0 => fp.delta_q_present = 1 - fp.delta_q_present.min(1),
            1 => fp.delta_q_res = 4,
            2 => fp.qm_v = 16,
            _ => fp.using_qmatrix = 2,
        },
        28 => fp.reserved[r.below(15) as usize] = 1,
        29 => fp.allow_screen_content_tools = 2,
        30 => {
            fp.tile_cols_log2 = r.below(8) as i8 - 1;
            fp.tile_rows_log2 = r.below(8) as i8 - 1;
        }
        _ => {
            fp.enable_cdef ^= 1;
        }
    }
    "field"
}

/// Records with a corruption: the same error codes from encode (every flag set) and validate.
#[test]
fn invalid_records_match_c() {
    let codes = std::sync::Mutex::new([0u64; 5]);
    par_seeds(0..1500, 6, |w, seed| {
        let Some(mut rec) = case(seed, 150, 0) else { return };
        let mut r = Rnd(seed * 7919 + 1);
        let n = 1 + r.below(3);
        let mut what = String::new();
        for _ in 0..n {
            what += corrupt(&mut rec, &mut r);
        }
        if rec.blocks.is_empty() || rec.block_txb.len() != rec.blocks.len() + 1 {
            return;
        }
        for flags in [0, ENC_FIX_RANGE, ENC_BITSTREAM_ONLY | ENC_NO_RECON, ENC_CHECK_EDGES] {
            let (c, _) = both(
                w,
                &format!("seed {seed} ({what}) flags {flags:#x}"),
                &rec,
                flags,
                -1,
                0,
                false,
            );
            if flags == 0 {
                codes.lock().unwrap()[(-c.rc) as usize] += 1;
            }
        }
        // validate
        let mut cr = rec.clone();
        let mut crec = cr.as_c();
        // SAFETY: crec points into cr.
        let mut crc = unsafe { av1g_validate(&crec, core::ptr::null_mut(), 0) };
        let _ = &mut crec;
        let mut rr = rec.clone();
        let rrc = validate(rr.as_mut()).map_or_else(|e| e.code, |_| OK);
        let tiles = tile_layout(
            rec.fp.width,
            rec.fp.height,
            rec.fp.tile_cols_log2 as i32,
            rec.fp.tile_rows_log2 as i32,
        );
        let multi = tiles.is_ok_and(|t| t.cols * t.rows > 1);
        for _ in 0..200 {
            if crc == rrc || crc == OK || rrc == OK || !multi {
                break;
            }
            let mut c2 = rec.clone();
            // SAFETY: as above.
            crc = unsafe { av1g_validate(&c2.as_c(), core::ptr::null_mut(), 0) };
        }
        assert_eq!(crc, rrc, "seed {seed} ({what}): validate");
        if crc == OK || !multi {
            assert_eq!(cr.txb, rr.txb, "seed {seed}: validate's write-back");
        }
    });
    let c = codes.lock().unwrap();
    eprintln!("ok {} invalid {} range {}", c[0], c[1], c[3]);
    assert!(c[1] > 500 && c[3] > 10);
}

/// The C view of a record whose arrays are missing.
#[test]
fn missing_arrays_are_invalid() {
    let mut rec = case(3, 64, 0).unwrap();
    let mut c = rec.as_c();
    c.txb = core::ptr::null_mut();
    // SAFETY: the other pointers point into rec.
    assert_eq!(unsafe { RecordMut::from_c(&mut c) }.unwrap_err().code, ERR_INVALID);
    let mut c = rec.as_c();
    // SAFETY: as above.
    let r = unsafe { RecordMut::from_c(&mut c) }.unwrap();
    assert_eq!(r.blocks.len(), rec.blocks.len());
}

// ---------------------------------------------------------------------------------------------
// layout, tiles, delta-q helpers
// ---------------------------------------------------------------------------------------------

#[test]
fn tile_layout_matches_c() {
    let mut r = Rnd(77);
    for i in 0..20000 {
        let (w, h) = match i % 4 {
            0 => (r.below(70000), r.below(70000)),
            1 => (1 + r.below(9000), 1 + r.below(9000)),
            2 => (1 + r.below(300), 1 + r.below(300)),
            _ => (4000 + r.below(5000), 2000 + r.below(3000)),
        };
        let (cl, rl) = (r.below(9) as i32 - 1, r.below(9) as i32 - 1);
        // SAFETY: plain data.
        let mut c: Tiles = unsafe { core::mem::zeroed() };
        let crc = unsafe { av1g_tile_layout(w, h, cl, rl, &mut c) };
        match tile_layout(w, h, cl, rl) {
            Ok(t) => {
                assert_eq!(crc, OK, "{w}x{h} {cl}/{rl}");
                assert_eq!(
                    (t.cols_log2, t.rows_log2, t.cols, t.rows),
                    (c.cols_log2, c.rows_log2, c.cols, c.rows)
                );
                assert_eq!(t.mi_col_starts[..=t.cols as usize], c.mi_col_starts[..=t.cols as usize]);
                assert_eq!(t.mi_row_starts[..=t.rows as usize], c.mi_row_starts[..=t.rows as usize]);
            }
            Err(e) => assert_eq!(crc, e, "{w}x{h} {cl}/{rl}"),
        }
    }
}

#[test]
fn layout_matches_c() {
    let mut r = Rnd(5);
    for seed in 0..300 {
        let Some(mut rec) = case(seed, 200, 2) else { continue };
        if seed % 3 == 0 {
            // out-of-range blocks / sizes
            let b = r.below(rec.blocks.len() as u32) as usize;
            match r.below(3) {
                0 => rec.blocks[b].bsize = 22 + r.below(3) as u8,
                1 => rec.blocks[b].mi_row = 30000,
                _ => rec.blocks[b].tx_depth = 7,
            }
        }
        let fp = rec.fp;
        let rust = layout_counts(&fp, &rec.blocks);
        let mut cr = rec.clone();
        for t in &mut cr.txb {
            t.eob = 9;
            t.tx_type = 5;
        }
        let mut c = cr.as_c();
        // capacity: counts only
        let mut c0 = c;
        c0.txb = core::ptr::null_mut();
        // SAFETY: c / c0 point into cr (txb and coeffs as long as the layout's counts, as the case
        // built them).
        let crc0 = unsafe { av1g_layout(&mut c0, 0, 0) };
        match rust {
            Err(e) => {
                assert_eq!(crc0, e, "seed {seed}");
                continue;
            }
            Ok(n) => {
                assert_eq!(crc0, ERR_CAPACITY);
                assert_eq!((c0.n_txb, c0.n_coeffs), (n.n_txb, n.n_coeffs), "seed {seed}");
                if (n.n_txb as usize) != cr.txb.len() {
                    continue; // tx_depth clamps changed the counts: arrays too small for the C++
                }
            }
        }
        let crc = unsafe { av1g_layout(&mut c, c.n_txb, c.n_coeffs) };
        assert_eq!(crc, OK);
        let mut rr = rec.clone();
        let n = rr.layout().unwrap();
        assert_eq!((n.n_txb as usize, n.n_coeffs as usize), (rr.txb.len(), rr.coeffs.len()));
        assert_eq!(cr.block_txb, rr.block_txb, "seed {seed}");
        assert_eq!(cr.txb, rr.txb, "seed {seed}");
        // too small
        let mut small = vec![Txb::default(); n.n_txb as usize - 1];
        assert_eq!(
            layout(&fp, &rec.blocks, &mut rr.block_txb, &mut small),
            Err(ERR_CAPACITY)
        );
    }
}

#[test]
fn delta_q_helpers_match_c() {
    let mut r = Rnd(11);
    for _ in 0..2000 {
        let (base, res) = (1 + r.below(255) as i32, r.below(8) as i32);
        let target: Vec<u8> = (0..64).map(|_| r.below(256) as u8).collect();
        let (mut a, mut b) = (vec![0u8; 64], vec![0u8; 64]);
        // SAFETY: 64-entry arrays.
        unsafe { av1g_legalize_sb_qindex(base, res, target.as_ptr(), 64, a.as_mut_ptr()) };
        legalize_sb_qindex(base, res, &target, &mut b);
        assert_eq!(a, b, "base {base} res {res}");
    }
    for seed in 0..50 {
        let Some(rec) = case(seed, 300, 0) else { continue };
        let sbc = ((mi_cols(rec.fp.width as i32) + 15) >> 4) as usize;
        let sbr = ((mi_rows(rec.fp.height as i32) + 15) >> 4) as usize;
        let map: Vec<u8> = (0..sbc * sbr).map(|_| r.below(256) as u8).collect();
        let (mut cr, mut rr) = (rec.clone(), rec.clone());
        let mut c = cr.as_c();
        // SAFETY: c points into cr; the map covers the SB grid.
        unsafe { av1g_apply_sb_qindex(&mut c, map.as_ptr()) };
        apply_sb_qindex(&rr.fp, &mut rr.blocks, &map).unwrap();
        assert_eq!(cr.blocks, rr.blocks);
        assert_eq!(
            apply_sb_qindex(&rr.fp, &mut rr.blocks, &map[..map.len() - 1]),
            Err(ERR_INVALID)
        );
    }
}

// ---------------------------------------------------------------------------------------------
// parse
// ---------------------------------------------------------------------------------------------

/// av1g_parse, copied (rc, record, level, tile sizes and offsets).
fn c_parse(obus: &[u8]) -> (i32, Parsed) {
    // SAFETY: av1g_parse's result and the arrays it owns, freed after copying.
    unsafe {
        let mut p: *mut crate::types::Parsed = core::ptr::null_mut();
        let rc = av1g_parse(obus.as_ptr(), obus.len(), &mut p);
        let q = &*p;
        let r = &q.rec;
        let sl = |ptr: *const u8, n: usize| {
            if n == 0 || ptr.is_null() {
                &[][..]
            } else {
                core::slice::from_raw_parts(ptr, n)
            }
        };
        let mut out = Parsed::default();
        if rc == OK {
            out.rec = Record {
                fp: r.fp,
                blocks: core::slice::from_raw_parts(r.blocks, r.n_blocks as usize).to_vec(),
                block_txb: core::slice::from_raw_parts(r.block_txb, r.n_blocks as usize + 1).to_vec(),
                txb: core::slice::from_raw_parts(r.txb, r.n_txb as usize).to_vec(),
                coeffs: if r.n_coeffs == 0 {
                    Vec::new()
                } else {
                    core::slice::from_raw_parts(r.coeffs, r.n_coeffs as usize).to_vec()
                },
            };
            out.seq_level_idx = q.seq_level_idx;
            out.tile_bytes = core::slice::from_raw_parts(q.tile_bytes, q.n_tiles as usize).to_vec();
            out.tile_offsets = core::slice::from_raw_parts(q.tile_offsets, q.n_tiles as usize).to_vec();
        }
        let _ = sl;
        av1g_parsed_free(p);
        (rc, out)
    }
}

fn check_parse(what: &str, obus: &[u8]) -> Option<Parsed> {
    let (crc, c) = c_parse(obus);
    match parse(obus) {
        Ok(r) => {
            assert_eq!(crc, OK, "{what}: rust parsed what the C++ rejects");
            assert_eq!(c.rec.fp, r.rec.fp, "{what}: frame params");
            assert!(
                c.rec.blocks == r.rec.blocks,
                "{what}: blocks differ at {:?}",
                first_diff(&c.rec.blocks, &r.rec.blocks)
            );
            assert_eq!(c.rec.block_txb, r.rec.block_txb, "{what}");
            assert!(
                c.rec.txb == r.rec.txb,
                "{what}: txb differ at {:?}",
                first_diff(&c.rec.txb, &r.rec.txb)
            );
            assert!(c.rec.coeffs == r.rec.coeffs, "{what}: coeffs");
            assert_eq!(
                (c.seq_level_idx, &c.tile_bytes, &c.tile_offsets),
                (r.seq_level_idx, &r.tile_bytes, &r.tile_offsets)
            );
            Some(r)
        }
        Err(e) => {
            assert_eq!(crc, e.code, "{what}: parse error code ({})", e.msg);
            None
        }
    }
}

/// Parsing the writer's streams: the same records as the C++ parser, and the record that was
/// written (decisions, coefficients and the written-back eob / tx types).
#[test]
fn parse_matches_c() {
    par_seeds(0..300, 6, |w, seed| {
        let Some(rec) = case(seed, 260, 4) else { return };
        let mut rr = rec.clone();
        let flags = if seed % 2 == 0 {
            ENC_TD | ENC_FIX_RANGE
        } else {
            ENC_BITSTREAM_ONLY
        };
        let opts = EncodeOpts {
            flags,
            seq_level_idx: -1,
        };
        let mut out = Output::default();
        if w.encode(rr.as_mut(), &opts, &mut out).is_err() {
            return;
        }
        let p = check_parse(&format!("seed {seed}"), &out.obu).expect("parse");
        let mut want = rr.clone();
        want.fp.tile_cols_log2 = p.rec.fp.tile_cols_log2;
        want.fp.tile_rows_log2 = p.rec.fp.tile_rows_log2;
        for (b, pb) in want.blocks.iter_mut().zip(&p.rec.blocks) {
            if b.skip != 0 {
                // a skip block's cdef_idx isn't coded, nor a skipped 64x64's qindex
                b.cdef_idx = pb.cdef_idx;
                if b.bsize as i32 == BLOCK_64X64 {
                    b.sb_qindex = pb.sb_qindex;
                }
            }
            if want.fp.delta_q_present == 0 {
                b.sb_qindex = pb.sb_qindex;
            }
        }
        assert_eq!(want.blocks.len(), p.rec.blocks.len());
        for (i, (a, b)) in want.blocks.iter().zip(&p.rec.blocks).enumerate() {
            let mut a = *a;
            if !has_chroma(
                a.bsize as i32,
                a.mi_row as i32,
                a.mi_col as i32,
                want.fp.monochrome != 0,
            ) {
                a.uv_mode = b.uv_mode;
                a.angle_delta_uv = b.angle_delta_uv;
                a.cfl_alpha_u = b.cfl_alpha_u;
                a.cfl_alpha_v = b.cfl_alpha_v;
            }
            assert_eq!(a, *b, "seed {seed}: block {i} round trip");
        }
        assert_eq!(want.txb.len(), p.rec.txb.len());
        for (i, (a, b)) in want.txb.iter().zip(&p.rec.txb).enumerate() {
            assert_eq!(
                (a.plane, a.tx_size, a.x4, a.y4, a.coeff_off, a.eob),
                (b.plane, b.tx_size, b.x4, b.y4, b.coeff_off, b.eob),
                "seed {seed}: txb {i}"
            );
            if a.eob > 0 {
                assert_eq!(a.tx_type, b.tx_type, "seed {seed}: txb {i}");
                let n = tx_coeffs(a.tx_size as i32);
                assert_eq!(
                    want.coeffs[a.coeff_off as usize..][..n],
                    p.rec.coeffs[b.coeff_off as usize..][..n],
                    "seed {seed}: txb {i}"
                );
            }
        }
    });
}

/// The picture of `fp` with its tile payloads as a libaom-style stream: full (not reduced)
/// sequence and frame headers with random values of the fields the parser skips, OBU extensions,
/// other OBUs, a last OBU without a size field. `bad`: one random header bit flipped.
fn full_header_stream(fp: &FrameParams, payloads: &[Vec<u8>], r: &mut Rnd, bad: bool) -> Vec<u8> {
    let bit = |r: &mut Rnd| r.below(2);
    let mut tiles = TileInfo::default();
    assert!(compute_tiles(
        fp.width,
        fp.height,
        fp.tile_cols_log2 as i32,
        fp.tile_rows_log2 as i32,
        &mut tiles
    ));
    let mono = fp.monochrome != 0;
    let diff_uv = fp.delta_q_v_dc != fp.delta_q_u_dc || fp.delta_q_v_ac != fp.delta_q_u_ac;
    let separate_uv = !mono && (diff_uv || (fp.using_qmatrix != 0 && fp.qm_v != fp.qm_u));
    let mut s = BitWriter::default();
    s.put(0, 3);
    s.put(bit(r), 1); // still_picture
    s.put(0, 1); // reduced_still_picture_header
    if bit(r) != 0 {
        s.put(1, 1); // timing_info_present_flag
        s.put(r.next(), 32);
        s.put(r.next(), 32);
        let eq = bit(r);
        s.put(eq, 1);
        if eq != 0 {
            let k = r.below(5) as i32; // uvlc
            s.put(0, k);
            s.put(1, 1);
            s.put(r.next(), k);
        }
        s.put(0, 1); // decoder_model_info_present_flag
    } else {
        s.put(0, 1);
    }
    let idd = bit(r);
    s.put(idd, 1);
    let nops = 1 + r.below(3);
    s.put(nops - 1, 5);
    for _ in 0..nops {
        s.put(r.next(), 12);
        let lv = r.below(32);
        s.put(lv, 5);
        if lv > 7 {
            s.put(bit(r), 1);
        }
        if idd != 0 {
            let p = bit(r);
            s.put(p, 1);
            if p != 0 {
                s.put(r.next(), 4);
            }
        }
    }
    let need = |v: u32| 32 - (v.max(1) - 1).leading_zeros().min(31) as i32;
    let (wb, hb) = (
        (need(fp.width) + r.below(2) as i32).min(16),
        (need(fp.height) + r.below(2) as i32).min(16),
    );
    let override_ = bit(r) != 0;
    s.put((wb - 1) as u32, 4);
    s.put((hb - 1) as u32, 4);
    let (maxw, maxh) = if override_ {
        (fp.width - 1 + r.below(8), fp.height - 1 + r.below(8))
    } else {
        (fp.width - 1, fp.height - 1)
    };
    s.put(maxw.min((1 << wb) - 1), wb);
    s.put(maxh.min((1 << hb) - 1), hb);
    s.put(0, 1); // frame_id_numbers_present_flag
    s.put(0, 1); // use_128x128_superblock
    s.put(fp.enable_filter_intra as u32, 1);
    s.put(fp.enable_intra_edge_filter as u32, 1);
    s.put(r.below(16), 4); // interintra, masked, warped, dual filter
    let oh = bit(r);
    s.put(oh, 1);
    if oh != 0 {
        s.put(r.below(4), 2);
    }
    let force_sct = if bit(r) != 0 {
        s.put(1, 1);
        2
    } else {
        s.put(0, 1);
        s.put(fp.allow_screen_content_tools as u32, 1);
        fp.allow_screen_content_tools as u32
    };
    let mut force_int_mv = 2;
    if force_sct > 0 {
        if bit(r) != 0 {
            s.put(1, 1);
        } else {
            s.put(0, 1);
            force_int_mv = bit(r);
            s.put(force_int_mv, 1);
        }
    }
    let ohb = if oh != 0 { 1 + r.below(8) as i32 } else { 0 };
    if oh != 0 {
        s.put((ohb - 1) as u32, 3);
    }
    s.put(0, 1); // enable_superres
    s.put(fp.enable_cdef as u32, 1);
    let lr = bit(r) != 0;
    s.put(lr as u32, 1);
    s.put(0, 1); // high_bitdepth
    s.put(mono as u32, 1);
    let cd = bit(r);
    s.put(cd, 1);
    if cd != 0 {
        let (mut cp, tc, mc) = (r.below(4), r.below(16), r.below(8));
        if !mono && tc == 13 && mc == 0 {
            cp = 2;
        }
        s.put(cp, 8);
        s.put(tc, 8);
        s.put(mc, 8);
    }
    s.put(bit(r), 1); // color_range
    if !mono {
        s.put(r.below(4), 2);
        s.put(separate_uv as u32, 1);
    }
    s.put(0, 1); // film_grain_params_present
    s.trailing_bits();

    let mut f = BitWriter::default();
    f.put(0, 1); // show_existing_frame
    f.put(0, 2); // KEY_FRAME
    f.put(1, 1); // show_frame
    f.put(0, 1); // disable_cdf_update
    let sct = fp.allow_screen_content_tools as u32;
    if force_sct == 2 {
        f.put(sct, 1);
    }
    if sct != 0 && force_int_mv == 2 {
        f.put(bit(r), 1);
    }
    f.put(override_ as u32, 1);
    if ohb != 0 {
        f.put(r.next(), ohb);
    }
    if override_ {
        f.put(fp.width - 1, wb);
        f.put(fp.height - 1, hb);
    }
    let rs = bit(r);
    f.put(rs, 1);
    if rs != 0 {
        f.put(r.next(), 16);
        f.put(r.next(), 16);
    }
    if sct != 0 {
        f.put(0, 1); // allow_intrabc
    }
    f.put(bit(r), 1); // disable_frame_end_update_cdf
    f.put(1, 1); // uniform_tile_spacing_flag
    for k in tiles.min_log2_tile_cols..tiles.max_log2_tile_cols {
        f.put((k < tiles.cols_log2) as u32, 1);
        if k >= tiles.cols_log2 {
            break;
        }
    }
    for k in tiles.min_log2_tile_rows..tiles.max_log2_tile_rows {
        f.put((k < tiles.rows_log2) as u32, 1);
        if k >= tiles.rows_log2 {
            break;
        }
    }
    let n = payloads.len();
    let max_sz = payloads[..n - 1].iter().map(|p| p.len() as u64 - 1).max().unwrap_or(0);
    let tsb = if max_sz < 256 { 1 + r.below(4) as usize } else { 4 };
    if tiles.cols_log2 > 0 || tiles.rows_log2 > 0 {
        f.put(r.next(), tiles.cols_log2 + tiles.rows_log2);
        f.put(tsb as u32 - 1, 2);
    }
    f.put(fp.base_q_idx as u32, 8);
    let dq = |f: &mut BitWriter, v: i8| {
        f.put((v != 0) as u32, 1);
        if v != 0 {
            f.su(v as i32, 7);
        }
    };
    dq(&mut f, fp.delta_q_y_dc);
    if !mono {
        if separate_uv {
            f.put(diff_uv as u32, 1);
        }
        dq(&mut f, fp.delta_q_u_dc);
        dq(&mut f, fp.delta_q_u_ac);
        if diff_uv {
            dq(&mut f, fp.delta_q_v_dc);
            dq(&mut f, fp.delta_q_v_ac);
        }
    }
    f.put(fp.using_qmatrix as u32, 1);
    if fp.using_qmatrix != 0 {
        f.put(fp.qm_y as u32, 4);
        f.put(fp.qm_u as u32, 4);
        if separate_uv {
            f.put(fp.qm_v as u32, 4);
        }
    }
    f.put(0, 1); // segmentation_enabled
    f.put(fp.delta_q_present as u32, 1);
    if fp.delta_q_present != 0 {
        f.put(fp.delta_q_res as u32, 2);
        f.put(0, 1);
    }
    // loop filter: random levels and ref deltas
    let lv = [r.below(64), r.below(64), r.below(64), r.below(64)];
    f.put(lv[0], 6);
    f.put(lv[1], 6);
    if !mono && (lv[0] != 0 || lv[1] != 0) {
        f.put(lv[2], 6);
        f.put(lv[3], 6);
    }
    f.put(r.below(8), 3);
    let de = bit(r);
    f.put(de, 1);
    if de != 0 {
        let up = bit(r);
        f.put(up, 1);
        if up != 0 {
            for _ in 0..10 {
                let u = bit(r);
                f.put(u, 1);
                if u != 0 {
                    f.su(r.below(128) as i32 - 64, 7);
                }
            }
        }
    }
    if fp.enable_cdef != 0 {
        f.put(fp.cdef_damping_minus_3 as u32, 2);
        f.put(fp.cdef_bits as u32, 2);
        for _ in 0..1 << fp.cdef_bits {
            f.put(r.below(16), 4);
            f.put(r.below(4), 2);
            if !mono {
                f.put(r.below(16), 4);
                f.put(r.below(4), 2);
            }
        }
    }
    if lr {
        for _ in 0..if mono { 1 } else { 3 } {
            f.put(if r.below(20) == 0 { 1 } else { 0 }, 2);
        }
    }
    f.put(fp.tx_mode_select as u32, 1);
    f.put(fp.reduced_tx_set as u32, 1);
    f.byte_align();
    if n > 1 {
        f.buf.push(0);
    }
    for (i, p) in payloads.iter().enumerate() {
        if i + 1 < n {
            let v = p.len() as u64 - 1;
            for k in 0..tsb {
                f.buf.push((v >> (8 * k)) as u8);
            }
        }
        f.buf.extend_from_slice(p);
    }
    if bad {
        let (k, b) = (r.below(2), r.next() as usize);
        let v = if k == 0 { &mut s.buf } else { &mut f.buf };
        let i = b % v.len().min(24);
        v[i] ^= 1 << ((b >> 8) % 8);
    }
    let mut o = Vec::new();
    let obu = |o: &mut Vec<u8>, ty: u8, data: &[u8], r: &mut Rnd, last: bool| {
        let ext = r.below(4) == 0;
        let sized = !last || r.below(2) == 0;
        o.push((ty << 3) | (ext as u8) << 2 | (sized as u8) << 1);
        if ext {
            o.push(r.next() as u8);
        }
        if sized {
            super::headers::put_leb128(o, data.len() as u64);
        }
        o.extend_from_slice(data);
    };
    if bit(r) != 0 {
        obu(&mut o, 2, &[], r, false); // temporal delimiter
    }
    obu(&mut o, 1, &s.buf, r, false);
    if bit(r) != 0 {
        obu(&mut o, 5, &[1, 2, 3, 4], r, false); // metadata
    }
    obu(&mut o, 6, &f.buf, r, true);
    o
}

/// Full (libaom-style) headers: the parser's non-reduced paths, against the C++'s.
#[test]
fn parse_full_headers_matches_c() {
    let n = [
        std::sync::atomic::AtomicU64::new(0),
        std::sync::atomic::AtomicU64::new(0),
    ];
    par_seeds(0..400, 6, |w, seed| {
        let Some(mut rec) = case(seed, 200, 3) else { return };
        let opts = EncodeOpts {
            flags: ENC_BITSTREAM_ONLY,
            seq_level_idx: -1,
        };
        if w.encode(rec.as_mut(), &opts, &mut Output::default()).is_err() {
            return;
        }
        let payloads = w.tile_payloads().to_vec();
        let mut fp = rec.fp;
        let t = tile_layout(fp.width, fp.height, fp.tile_cols_log2 as i32, fp.tile_rows_log2 as i32).unwrap();
        (fp.tile_cols_log2, fp.tile_rows_log2) = (t.cols_log2 as i8, t.rows_log2 as i8);
        let mut r = Rnd(seed * 31 + 7);
        for k in 0..8 {
            let s = full_header_stream(&fp, &payloads, &mut r, k >= 4);
            let ok = check_parse(&format!("seed {seed} stream {k}"), &s).is_some();
            n[ok as usize].fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if ok && k < 4 {
                // same decisions as the reduced stream's
                let p = parse(&s).unwrap();
                assert_eq!(p.rec.blocks.len(), rec.blocks.len(), "seed {seed}");
                assert_eq!(p.rec.txb.len(), rec.txb.len(), "seed {seed}");
            }
        }
    });
    let n = n.map(|a| a.into_inner());
    eprintln!("full-header streams: {} parsed, {} rejected", n[1], n[0]);
    assert!(n[1] > 1000 && n[0] > 50);
}

/// Damaged tile payloads: the same errors or the same records.
#[test]
fn parse_damaged_matches_c() {
    let n_ok = std::sync::atomic::AtomicU64::new(0);
    par_seeds(0..400, 6, |w, seed| {
        let Some(mut rec) = case(seed, 120, 0) else { return };
        let mut out = Output::default();
        let opts = EncodeOpts {
            flags: ENC_BITSTREAM_ONLY,
            seq_level_idx: -1,
        };
        if w.encode(rec.as_mut(), &opts, &mut out).is_err() {
            return;
        }
        let tail = out.tile_bytes as usize;
        let mut r = Rnd(seed + 99);
        for k in 0..6 {
            let mut o = out.obu.clone();
            let n = o.len();
            for _ in 0..1 + r.below(4) {
                let i = n - 1 - r.below(tail as u32) as usize;
                o[i] ^= 1 << r.below(8);
            }
            if check_parse(&format!("seed {seed} damage {k}"), &o).is_some() {
                n_ok.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            }
        }
        // truncated streams and junk
        for cut in [1, 2, 5, out.obu.len() / 2, out.obu.len() - 1] {
            check_parse(&format!("seed {seed} cut {cut}"), &out.obu[..out.obu.len().min(cut)]);
        }
    });
    eprintln!("damaged streams that parsed: {}", n_ok.into_inner());
}

// ---------------------------------------------------------------------------------------------
// enc: entropy plan, OBU assembly, post-filter frame
// ---------------------------------------------------------------------------------------------

#[test]
fn ent_plan_matches_c() {
    let mut r = Rnd(3);
    for seed in 0..300 {
        let Some(rec) = case(seed, 64, 0) else { continue };
        let mut fp = rec.fp;
        fp.width = 1 + r.below(if seed % 4 == 0 { 9000 } else { 2000 });
        fp.height = 1 + r.below(if seed % 4 == 1 { 9000 } else { 2000 });
        fp.cdef_bits = r.below(4) as u8;
        if seed % 5 == 0 {
            fp.tile_cols_log2 = r.below(8) as i8 - 1;
            fp.tile_rows_log2 = r.below(8) as i8 - 1;
        }
        let (nb, nt) = (r.below(3) * 1000, r.below(3) * 7);
        let mut cf = GaEntFrame {
            w: 77,
            ..Default::default()
        };
        let mut ct = vec![GaEntTile::default(); GA_ENT_MAX_TILES];
        let (mut rf, mut rt) = (cf, ct.clone());
        // SAFETY: GA_ENT_MAX_TILES entries.
        let cn = unsafe { av1enc_ent_plan(&fp, nb, nt, &mut cf, ct.as_mut_ptr()) };
        let rn = crate::enc::ent_plan(&fp, nb, nt, &mut rf, &mut rt);
        assert_eq!(cn, rn, "seed {seed}");
        assert_eq!(cf, rf, "seed {seed}");
        assert_eq!(ct, rt, "seed {seed}");
    }
}

#[test]
fn assemble_obus_matches_c_and_the_writer() {
    par_seeds(0..120, 4, |w, seed| {
        let Some(mut rec) = case(seed, 300, 30) else { return };
        let mut out = Output::default();
        let opts = EncodeOpts {
            flags: ENC_BITSTREAM_ONLY | if seed % 2 == 0 { ENC_TD } else { 0 },
            seq_level_idx: -1,
        };
        let mut payloads: Vec<Vec<u8>> = Vec::new();
        let ok = w.encode(rec.as_mut(), &opts, &mut out).is_ok();
        if ok {
            payloads = w.tile_payloads().to_vec();
        }
        let mut variants = vec![payloads.clone()];
        if !payloads.is_empty() {
            let mut v = payloads.clone();
            v[0].clear(); // empty first tile
            variants.push(v);
            variants.push(payloads[..payloads.len() - 1].to_vec());
            variants.push(payloads.iter().map(|p| [&p[..], &[7u8; 300][..]].concat()).collect());
        }
        for (k, v) in variants.iter().enumerate() {
            let td = opts.flags & ENC_TD != 0;
            let ptrs: Vec<*const u8> = v.iter().map(|p| p.as_ptr()).collect();
            let sizes: Vec<usize> = v.iter().map(|p| p.len()).collect();
            let (mut cp, mut cn) = (core::ptr::null_mut(), 0usize);
            // SAFETY: n payload pointers and sizes; the result is malloc'd.
            let crc = unsafe {
                av1enc_assemble_obus(
                    &rec.fp,
                    ptrs.as_ptr(),
                    sizes.as_ptr(),
                    v.len() as u32,
                    td as c_int,
                    &mut cp,
                    &mut cn,
                )
            };
            let c = if crc == 0 {
                let c = unsafe { core::slice::from_raw_parts(cp, cn) }.to_vec();
                unsafe { free(cp as *mut _) };
                Ok(c)
            } else {
                Err(crc)
            };
            let r = crate::enc::assemble_obus(&rec.fp, v, td);
            assert_eq!(c, r, "seed {seed} variant {k}");
            if k == 0 && ok {
                assert_eq!(r.unwrap(), out.obu, "seed {seed}: assembled = written");
            }
        }
    });
}

#[test]
fn pf_frame_matches_c() {
    let mut r = Rnd(9);
    // SAFETY: a size query.
    assert_eq!(
        unsafe { av1enc_pf_frame(core::ptr::null(), core::ptr::null(), core::ptr::null_mut(), 0) },
        280
    );
    for seed in 0..200 {
        let Some(rec) = case(seed, 64, 0) else { continue };
        let mut fp = rec.fp;
        fp.width = 1 + r.below(6000);
        fp.height = 1 + r.below(4000);
        if seed % 3 == 0 {
            fp.loop_filter_level = [0, 0, 7, 9];
            fp.monochrome = r.below(3) as u8;
        }
        let a = GaPfAddrs {
            plane: [
                r.next() as u64 * 4096,
                (r.next() as u64) << 20,
                0xdead_beef_0000 + r.next() as u64,
            ],
            stride: [r.next() as i32, r.next() as i32, -(r.below(100) as i32)],
            skip: r.next() as u64,
            lf_tx: [1, 2, (r.next() as u64) << 30],
            cdef_idx: r.next() as u64,
            cdef_dir_var: r.next() as u64 | 1 << 40,
        };
        let mut c = vec![0xAAu8; 280];
        // SAFETY: 280 bytes.
        let n = unsafe { av1enc_pf_frame(&fp, &a, c.as_mut_ptr(), c.len()) };
        assert_eq!(n, 280);
        let f = crate::enc::pf_frame(&fp, &a);
        assert_eq!(f.as_bytes(), &c[..], "seed {seed}");
    }
}

// ---------------------------------------------------------------------------------------------
// benchmarks
// ---------------------------------------------------------------------------------------------

/// A random legal record of a whole picture with the tools a tune=iq encode uses (QMs, delta-q,
/// filter intra, the edge filter, deblocking, CDEF) and sparse, mostly small coefficients.
pub(crate) fn big_record(seed: u64, w: u32, h: u32, cols_log2: i8, rows_log2: i8) -> Record {
    let mut r = Rnd(seed | 1);
    let mut fp = FrameParams {
        version: DECISIONS_VERSION,
        width: w,
        height: h,
        base_q_idx: 120,
        tx_mode_select: 1,
        tile_cols_log2: cols_log2,
        tile_rows_log2: rows_log2,
        enable_filter_intra: 1,
        enable_intra_edge_filter: 1,
        delta_q_present: 1,
        delta_q_res: 2,
        using_qmatrix: 1,
        qm_y: 8,
        qm_u: 9,
        qm_v: 9,
        loop_filter_level: [14, 12, 8, 8],
        enable_cdef: 1,
        cdef_damping_minus_3: 2,
        cdef_bits: 2,
        ..Default::default()
    };
    for i in 0..4 {
        fp.cdef_y_pri[i] = r.below(16) as u8;
        fp.cdef_y_sec[i] = [0, 1, 2, 4][r.below(4) as usize];
        fp.cdef_uv_pri[i] = r.below(16) as u8;
        fp.cdef_uv_sec[i] = [0, 1, 2, 4][r.below(4) as usize];
    }
    let (mc, mr) = (mi_cols(w as i32), mi_rows(h as i32));
    let t = tile_layout(w, h, cols_log2 as i32, rows_log2 as i32).unwrap();
    let sbc = ((mc + 15) >> 4) as usize;
    let sbr = ((mr + 15) >> 4) as usize;
    let target: Vec<u8> = (0..sbc * sbr).map(|_| (100 + r.below(41)) as u8).collect();
    let mut sbq = vec![0u8; target.len()];
    legalize_sb_qindex(fp.base_q_idx as i32, fp.delta_q_res as i32, &target, &mut sbq);
    let sb_cdef: Vec<i8> = (0..sbc * sbr).map(|_| r.below(4) as i8).collect();
    let mut blocks = Vec::new();
    fn part(r: &mut Rnd, row: i32, col: i32, bs: i32, mr: i32, mc: i32, out: &mut Vec<(i32, i32, i32)>) {
        if row >= mr || col >= mc {
            return;
        }
        let half = bw4(bs) >> 1;
        let (has_rows, has_cols) = (row + half < mr, col + half < mc);
        let sub = |p: i32| Partition_Subsize[p as usize][bs as usize] as i32;
        let p = if bs < BLOCK_8X8 {
            PARTITION_NONE
        } else if !(has_rows && has_cols) {
            if has_cols && r.below(2) == 0 {
                PARTITION_HORZ
            } else if has_rows && r.below(2) == 0 {
                PARTITION_VERT
            } else {
                PARTITION_SPLIT
            }
        } else if bs == BLOCK_8X8 {
            r.below(4) as i32
        } else if r.below(100) < [0, 0, 0, 0, 0, 0, 30, 0, 0, 45, 0, 0, 55][bs as usize] {
            PARTITION_SPLIT
        } else {
            r.below(10) as i32
        };
        let (s, sp, q) = (sub(p), sub(PARTITION_SPLIT), half >> 1);
        let mut b = |rr: i32, cc: i32, s: i32| out.push((rr, cc, s));
        match p {
            PARTITION_NONE => b(row, col, s),
            PARTITION_HORZ => {
                b(row, col, s);
                if has_rows {
                    b(row + half, col, s)
                }
            }
            PARTITION_VERT => {
                b(row, col, s);
                if has_cols {
                    b(row, col + half, s)
                }
            }
            PARTITION_SPLIT => {
                for (dr, dc) in [(0, 0), (0, half), (half, 0), (half, half)] {
                    part(r, row + dr, col + dc, s, mr, mc, out);
                }
            }
            PARTITION_HORZ_A => {
                b(row, col, sp);
                b(row, col + half, sp);
                b(row + half, col, s);
            }
            PARTITION_HORZ_B => {
                b(row, col, s);
                b(row + half, col, sp);
                b(row + half, col + half, sp);
            }
            PARTITION_VERT_A => {
                b(row, col, sp);
                b(row + half, col, sp);
                b(row, col + half, s);
            }
            PARTITION_VERT_B => {
                b(row, col, s);
                b(row, col + half, sp);
                b(row + half, col + half, sp);
            }
            PARTITION_HORZ_4 => {
                for i in 0..4 {
                    if i < 3 || row + q * 3 < mr {
                        b(row + q * i, col, s)
                    }
                }
            }
            _ => {
                for i in 0..4 {
                    if i < 3 || col + q * 3 < mc {
                        b(row, col + q * i, s)
                    }
                }
            }
        }
    }
    let mut pos = Vec::new();
    for tr in 0..t.rows as usize {
        for tc in 0..t.cols as usize {
            for row in (t.mi_row_starts[tr]..t.mi_row_starts[tr + 1]).step_by(16) {
                for col in (t.mi_col_starts[tc]..t.mi_col_starts[tc + 1]).step_by(16) {
                    pos.clear();
                    part(&mut r, row as i32, col as i32, BLOCK_64X64, mr, mc, &mut pos);
                    let sb = (row as usize >> 4) * sbc + (col as usize >> 4);
                    for &(rr, cc, bs) in &pos {
                        let mut b = Block {
                            mi_row: rr as u16,
                            mi_col: cc as u16,
                            bsize: bs as u8,
                            skip: (r.below(100) < 15) as u8,
                            y_mode: r.below(13) as u8,
                            sb_qindex: sbq[sb],
                            cdef_idx: sb_cdef[sb],
                            ..Default::default()
                        };
                        if bs > BLOCK_4X4 {
                            b.tx_depth = r.below(max_tx_depth(bs) as u32 + 1) as u8;
                        }
                        if bs >= BLOCK_8X8 && crate::dsp::is_directional(b.y_mode as i32) && r.below(2) == 0 {
                            b.angle_delta_y = r.below(7) as i8 - 3;
                        }
                        if has_chroma(bs, rr, cc, false) {
                            b.uv_mode = r.below(if cfl_allowed(bs) { 14 } else { 13 }) as u8;
                            if b.uv_mode as i32 == UV_CFL_PRED {
                                b.cfl_alpha_u = r.below(33) as i8 - 16;
                                b.cfl_alpha_v = if b.cfl_alpha_u == 0 {
                                    1 + r.below(16) as i8
                                } else {
                                    r.below(33) as i8 - 16
                                };
                            }
                            if bs >= BLOCK_8X8 && crate::dsp::is_directional(b.uv_mode as i32) && r.below(2) == 0 {
                                b.angle_delta_uv = r.below(7) as i8 - 3;
                            }
                        }
                        if b.y_mode as i32 == DC_PRED && bw4(bs) <= 8 && bh4(bs) <= 8 && r.below(3) == 0 {
                            b.filter_intra = 1 + r.below(5) as u8;
                        }
                        blocks.push(b);
                    }
                }
            }
        }
    }
    let mut rec = Record::new(fp, blocks);
    rec.layout().unwrap();
    for bi in 0..rec.blocks.len() {
        let b = rec.blocks[bi];
        for ti in rec.block_txb[bi] as usize..rec.block_txb[bi + 1] as usize {
            let t = rec.txb[ti];
            let tx = t.tx_size as i32;
            let ty = if t.plane == 0 {
                let set = get_tx_set_intra(tx, false);
                let mut ty;
                loop {
                    ty = r.below(16) as i32;
                    if tx_type_in_set_intra(set, ty) {
                        break;
                    }
                }
                rec.txb[ti].tx_type = ty as u8;
                ty
            } else {
                crate::dsp::chroma_tx_type(tx, b.uv_mode as i32, false)
            };
            let n = tx_coeffs(tx);
            let q = &mut rec.coeffs[t.coeff_off as usize..][..n];
            q.fill(0);
            if r.below(100) < 35 {
                continue;
            }
            let scan = crate::dsp::get_scan(tx, ty);
            let eob = 1 + r.below((n as u32 / 6).max(1)) as usize;
            for c in 0..eob {
                if c + 1 != eob && r.below(100) < 55 {
                    continue;
                }
                let m = r.below(1000);
                let mag = if m < 650 {
                    1
                } else if m < 900 {
                    2 + r.below(3)
                } else if m < 990 {
                    5 + r.below(20)
                } else {
                    25 + r.below(200)
                } as i16;
                q[scan[c] as usize] = if r.below(2) == 0 { -mag } else { mag };
            }
        }
    }
    // conformant coefficients (an encoder's never overflow the inverse transform)
    let opts = EncodeOpts {
        flags: ENC_FIX_RANGE | ENC_NO_RECON,
        seq_level_idx: -1,
    };
    Writer::new()
        .encode(rec.as_mut(), &opts, &mut Output::default())
        .unwrap();
    rec
}

fn time<T>(runs: usize, mut f: impl FnMut() -> T) -> (f64, T) {
    let mut best = f64::MAX;
    let mut last = None;
    for _ in 0..runs {
        let t = std::time::Instant::now();
        let v = f();
        best = best.min(t.elapsed().as_secs_f64());
        last = Some(v);
    }
    (best * 1e3, last.unwrap())
}

/// The writer vs the C++ on a 5K picture (cargo test --release --no-default-features --features
/// oracle bench_writer -- --ignored --nocapture).
#[test]
#[ignore]
fn bench_writer_5k() {
    let only = std::env::var("BENCH_ONLY").ok();
    for (w_, h_, cl, rl) in [
        (4096, 2304, -1, -1),
        (5120, 2880, -1, -1),
        (5120, 2880, 2, 2),
        (5120, 2880, 3, 2),
    ] {
        if only.as_ref().is_some_and(|o| *o != format!("{w_}x{h_}/{cl}/{rl}")) {
            continue;
        }
        let rec = big_record(42, w_, h_, cl, rl);
        let mut w = Writer::new();
        for (name, flags, hook) in [
            ("full (deblock + CDEF)", 0, 0),
            ("pre-filter recon", ENC_PREFILTER_RECON, 0),
            ("bitstream only", ENC_BITSTREAM_ONLY, 0),
            ("hook, fix range, pre-filter", ENC_FIX_RANGE | ENC_PREFILTER_RECON, 1),
        ] {
            let (tc, c) = time(5, || {
                let mut cr = rec.clone();
                c_encode(&mut cr, flags, -1, hook, false, None)
            });
            let (tr, r) = time(5, || {
                let mut rr = rec.clone();
                r_encode(&mut w, &mut rr, flags, -1, hook, false, None)
            });
            assert_eq!((c.rc, r.rc), (OK, OK), "{name}");
            assert!(c.out == r.out, "{name}: outputs differ");
            // the record clone, outside the encode
            let (tclone, _) = time(5, || rec.clone());
            eprintln!(
                "{w_}x{h_} {}x{} tiles, {} blocks, {} symbols, {} bytes: {name:28} C++ {:7.2} ms  Rust {:7.2} ms  ({:.2}x)",
                c.out.tile_cols,
                c.out.tile_rows,
                rec.blocks.len(),
                c.out.n_symbols,
                c.out.obu.len(),
                tc - tclone,
                tr - tclone,
                (tc - tclone) / (tr - tclone)
            );
        }
    }
}

/// The Rust writer alone, in a loop, for a profiler (PROF_FLAGS, PROF_THREADS, PROF_SECS).
#[test]
#[ignore]
fn profile_writer() {
    let env = |k: &str, d: u64| std::env::var(k).map(|v| v.parse().unwrap()).unwrap_or(d);
    let rec = big_record(42, 5120, 2880, 2, 2);
    let mut w = Writer::with_threads(env("PROF_THREADS", 0) as usize);
    let opts = EncodeOpts {
        flags: env("PROF_FLAGS", ENC_BITSTREAM_ONLY as u64) as u32,
        seq_level_idx: -1,
    };
    let hook = env("PROF_HOOK", 0) as i32;
    unsafe extern "C" {
        fn pthread_set_qos_class_self_np(qos: u32, prio: i32) -> i32;
        fn clock_gettime_nsec_np(clock: u32) -> u64;
    }
    // SAFETY: QOS_CLASS_USER_INTERACTIVE (P cores, mostly), CLOCK_THREAD_CPUTIME_ID.
    unsafe { pthread_set_qos_class_self_np(0x21, 0) };
    let cpu = || unsafe { clock_gettime_nsec_np(16) };
    let t = std::time::Instant::now();
    let (mut n, mut best, mut best_cpu) = (0, f64::MAX, u64::MAX);
    let mut out = Output::default();
    let mut rr = rec.clone();
    while t.elapsed().as_secs() < env("PROF_SECS", 10) {
        rr.coeffs.copy_from_slice(&rec.coeffs);
        let (t0, c0) = (std::time::Instant::now(), cpu());
        let r = if hook != 0 {
            w.encode_with_hook(rr.as_mut(), &opts, Some(&TestHook(hook)), &Extras::default(), &mut out)
        } else {
            w.encode(rr.as_mut(), &opts, &mut out)
        };
        best = best.min(t0.elapsed().as_secs_f64());
        best_cpu = best_cpu.min(cpu() - c0);
        r.unwrap();
        n += 1;
    }
    eprintln!(
        "{:.2} ms per picture (best {:.2} ms, this thread's CPU best {:.2} ms)",
        t.elapsed().as_secs_f64() * 1e3 / n as f64,
        best * 1e3,
        best_cpu as f64 * 1e-6
    );
}

/// One record, both encoders' messages (SEED=n FLAGS=f ... debug_seed -- --ignored --nocapture).
#[test]
#[ignore]
fn debug_seed() {
    let seed: u64 = std::env::var("SEED").unwrap().parse().unwrap();
    let flags: u32 = std::env::var("FLAGS").map(|f| f.parse().unwrap()).unwrap_or(0);
    let rec = case(seed, 300, 4).unwrap();
    let mut cr = rec.clone();
    let mut c = cr.as_c();
    let opts = EncodeOpts {
        flags,
        seq_level_idx: -1,
    };
    // SAFETY: c points into cr; the output is freed.
    unsafe {
        let mut o: crate::types::Output = core::mem::zeroed();
        let rc = oracle_writer_encode(
            &mut c,
            &opts,
            &mut o,
            0,
            0,
            0,
            core::ptr::null(),
            core::ptr::null(),
            core::ptr::null(),
        );
        eprintln!(
            "C++ rc {rc}: {}",
            core::ffi::CStr::from_ptr(o.error.as_ptr() as *const c_char).to_string_lossy()
        );
        av1g_output_free(&mut o);
    }
    let mut rr = rec.clone();
    let r = Writer::new().encode(rr.as_mut(), &opts, &mut Output::default());
    eprintln!("Rust {r:?}");
}
