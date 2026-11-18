//! The writer's snapshots (testsupport::snapshot): random legal records of av1gpu's fuzzer
//! (FuzzCase) with every flag, invalid records, the hook path, tile skips and symbol streams, the
//! parser; and the enc module's entropy plan, OBU assembly and post-filter frame. Until 2026-11-17
//! these compared the writer with the C++ it was ported from (Sources/AV1Core/src/encoder.cpp);
//! the hashes were recorded where the two agreed.

use super::*;
use crate::blockinfo::*;
use crate::dsp::{get_tx_set_intra, tx_coeffs, tx_h, tx_type_in_set_intra, tx_w};
use crate::tables::*;
use crate::testsupport::snapshot::{Cases, OUTPUT, Snapshot, fuzz_record, put_output};

/// av1gpu's fuzzer's record (testsupport's FuzzCase).
fn case(seed: u64, maxdim: i32, big_pct: i32) -> Option<Record> {
    fuzz_record(seed, maxdim, big_pct)
}

/// An encode's results: the return code, the output, the tile payloads and symbol streams.
#[derive(Debug, PartialEq, Eq)]
struct Enc {
    rc: i32,
    out: Output,
    payloads: Vec<Vec<u8>>,
    syms: Vec<Vec<u32>>,
}

/// The test hook (the C++ reference's tests had the same one, oracle/writer.cpp's TestHook).
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
        refs: None,
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

/// The families of an encode: its return code, output, tile payloads and symbol streams, and the
/// record's written-back tx blocks and coefficients.
const ENC: [&str; 8] = [
    "rc",
    OUTPUT[0],
    OUTPUT[1],
    OUTPUT[2],
    OUTPUT[3],
    "payloads",
    "syms",
    "writeback",
];

/// Feeds an encode's results to the [`ENC`] families of `s`; `rrec` is the record after it.
/// After an error in a picture of several tiles, the other tiles' threads have written back
/// whatever they reached: the write-back isn't fed then.
fn snap_enc(s: &mut Snapshot, r: &Enc, rrec: &Record) {
    s.put("rc", &r.rc);
    put_output(s, &r.out);
    s.put("payloads", &r.payloads);
    s.put("syms", &r.syms);
    let tiles = tile_layout(
        rrec.fp.width,
        rrec.fp.height,
        rrec.fp.tile_cols_log2 as i32,
        rrec.fp.tile_rows_log2 as i32,
    );
    if r.rc != OK && tiles.is_ok_and(|t| t.cols * t.rows > 1) {
        return;
    }
    s.put("writeback", &(&rrec.txb, &rrec.coeffs));
}

/// Encodes `rec`, fed to `s`; returns the results and the record after the encode.
#[allow(clippy::too_many_arguments)]
fn encode(
    w: &mut Writer,
    rec: &Record,
    flags: u32,
    level: i32,
    hook: i32,
    syms: bool,
    s: &mut Snapshot,
) -> (Enc, Record) {
    let mut rr = rec.clone();
    let r = r_encode(w, &mut rr, flags, level, hook, syms, None);
    snap_enc(s, &r, &rr);
    (r, rr)
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

/// Runs `f` over seeds on several threads (each with its own writer), each seed with its own
/// snapshot of the families `names`; returns them folded in seed order.
fn par_seeds(
    seeds: core::ops::Range<u64>,
    threads: usize,
    names: &'static [&'static str],
    f: impl Fn(&mut Writer, u64, &mut Snapshot) + Sync,
) -> Snapshot {
    let next = std::sync::atomic::AtomicU64::new(seeds.start);
    let cases = Cases::new(names);
    std::thread::scope(|s| {
        for _ in 0..threads {
            s.spawn(|| {
                let mut w = Writer::new();
                loop {
                    let seed = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    if seed >= seeds.end {
                        break;
                    }
                    let mut snap = cases.case();
                    f(&mut w, seed, &mut snap);
                    cases.add(seed, snap);
                }
            });
        }
    });
    cases.fold()
}

// ---------------------------------------------------------------------------------------------
// encode
// ---------------------------------------------------------------------------------------------

/// Every flag combination on random legal records (all sizes, tilings, delta-q, QMs, filter
/// intra, the edge filter, post-filters, monochrome, screen content). One writer per thread is
/// reused across records, so leftovers of a previous picture would show.
#[test]
fn encode_random_records_snapshot() {
    // ok, errors, multi-tile, repaired tx blocks; records with: delta-q, QMs, filter intra, the
    // edge filter, deblocking, CDEF, monochrome, odd sizes, screen content, filter-intra blocks,
    // CfL blocks, skip blocks
    let stats = std::sync::Mutex::new([0u64; 16]);
    let snap = par_seeds(0..1500, 8, &ENC, |w, seed, s| {
        let Some(rec) = case(seed, 300, 4) else { return };
        let mut ntiles = 0;
        for &flags in &FLAG_SETS {
            let (c, _) = encode(w, &rec, flags, -1, 0, false, s);
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
        encode(w, &rec, ENC_TD, 13, 0, false, s);
        if ntiles > 1 {
            let mut w1 = Writer::with_threads(1);
            encode(&mut w1, &rec, 0, -1, 0, false, s);
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
    snap.check(&[
        ("rc", 0x26f5c149c9c61259),
        ("obu", 0xd621a21e61132751),
        ("avif", 0x9f62199a6ce13aad),
        ("recon", 0x98b265c712797c3a),
        ("stats", 0xcdfc2bf4b8b4681b),
        ("payloads", 0x1788ac39c13b0699),
        ("syms", 0x7cd37ef1565a4fa3),
        ("writeback", 0x23f40f717d32bc2a),
    ]);
}

/// All 128 combinations of the flags.
#[test]
fn encode_every_flag_combination_snapshot() {
    let bits = [
        ENC_FIX_RANGE,
        ENC_NO_RECON,
        ENC_TD,
        ENC_AVIF,
        ENC_PREFILTER_RECON,
        ENC_BITSTREAM_ONLY,
        ENC_CHECK_EDGES,
    ];
    let snap = par_seeds(5000..5040, 8, &ENC, |w, seed, s| {
        let Some(rec) = case(seed, 160, 3) else { return };
        for m in 0..1u32 << bits.len() {
            let flags = (0..bits.len()).filter(|&i| m >> i & 1 != 0).fold(0, |f, i| f | bits[i]);
            encode(w, &rec, flags, -1, (m % 3) as i32, m % 5 == 0, s);
        }
    });
    snap.check(&[
        ("rc", 0x3835fec3e09c4f81),
        ("obu", 0x295248481cc2622d),
        ("avif", 0x9b170c3ad24e0e3d),
        ("recon", 0x2a90e85846b31ab0),
        ("stats", 0xe08819000a7e5e1c),
        ("payloads", 0x91524c203d8e3eca),
        ("syms", 0x865b5963452d05a7),
        ("writeback", 0xefe70dafdca2dd27),
    ]);
}

/// Big pictures: several tiles on parallel threads, with every output.
#[test]
fn encode_multi_tile_snapshot() {
    let snap = par_seeds(1000..1024, 3, &ENC, |w, seed, s| {
        let Some(rec) = case(seed, 300, 100) else { return };
        for flags in [
            0,
            ENC_FIX_RANGE | ENC_PREFILTER_RECON | ENC_AVIF | ENC_TD,
            ENC_BITSTREAM_ONLY,
        ] {
            encode(w, &rec, flags, -1, 0, false, s);
        }
    });
    snap.check(&[
        ("rc", 0xfe7ff6036ce2425d),
        ("obu", 0x98e44c0aa8c44c1b),
        ("avif", 0x719d3d153a48ff15),
        ("recon", 0xed10af2460812209),
        ("stats", 0x065d8fd58f7a4885),
        ("payloads", 0x972543fe36123364),
        ("syms", 0x4e41240738bc6d25),
        ("writeback", 0x6d30ec324966027b),
    ]);
}

/// The closed-loop hook: rewrites every tx block's coefficients and luma tx type from its exact
/// prediction (with large levels the range repair runs too).
#[test]
fn hook_snapshot() {
    let snap = par_seeds(0..200, 6, &ENC, |w, seed, s| {
        let Some(rec) = case(seed, 200, 5) else { return };
        for (mode, flags) in [
            (1, ENC_FIX_RANGE | ENC_PREFILTER_RECON),
            (1, 0),
            (2, ENC_FIX_RANGE),
            (2, 0),
            (1, ENC_NO_RECON | ENC_TD),
        ] {
            encode(w, &rec, flags, -1, mode, false, s);
        }
    });
    snap.check(&[
        ("rc", 0x2a64390269de777a),
        ("obu", 0xf63d247d18a75167),
        ("avif", 0x4b94ce34a6427985),
        ("recon", 0x2e14b873b89061e3),
        ("stats", 0x813c1a108e7e49c2),
        ("payloads", 0xf6e537eb71f436c2),
        ("syms", 0x4b94ce34a6427985),
        ("writeback", 0xb12a1fc857624a25),
    ]);
}

/// Per-tile symbol streams (TeeSink), payloads and tile skips with given or missing payloads.
#[test]
fn tile_skips_and_symbols_snapshot() {
    let snap = par_seeds(2000..2030, 3, &ENC, |w, seed, s| {
        let Some(rec) = case(seed, 300, 70) else { return };
        let (c, _) = encode(w, &rec, ENC_FIX_RANGE, -1, 0, true, s);
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
                let mut rr = rec.clone();
                let rres = r_encode(w, &mut rr, flags, -1, hook, round == 1, Some((&skip, &given)));
                snap_enc(s, &rres, &rr);
            }
        }
        // a wrong-sized skip list
        let mut rr = rec.clone();
        let (sk, g) = (vec![false; n + 1], vec![Vec::new(); n + 1]);
        let rres = r_encode(w, &mut rr, 0, -1, 0, false, Some((&sk, &g)));
        assert_eq!(rres.rc, ERR_INVALID);
        s.put("rc", &rres.rc);
    });
    snap.check(&[
        ("rc", 0x9b03b5fef55d33c0),
        ("obu", 0x5751aef4a9bc422a),
        ("avif", 0xbee578544a59c645),
        ("recon", 0x7272fe5e9be1d955),
        ("stats", 0x1e31adab76efa9f1),
        ("payloads", 0x98c5821747249984),
        ("syms", 0x1e1e4fafcbb01a1f),
        ("writeback", 0x162125e68034f81f),
    ]);
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
        20 => fp.version = 3,
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
        // (stream_width / stream_height: the C++ has no such fields; inter_records_refused)
        28 => fp.golden_slot = 1,
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
fn invalid_records_snapshot() {
    let codes = std::sync::Mutex::new([0u64; 5]);
    const FAMS: [&str; 9] = [
        ENC[0], ENC[1], ENC[2], ENC[3], ENC[4], ENC[5], ENC[6], ENC[7], "validate",
    ];
    let snap = par_seeds(0..1500, 6, &FAMS, |w, seed, s| {
        let Some(mut rec) = case(seed, 150, 0) else { return };
        let mut r = Rnd(seed * 7919 + 1);
        let n = 1 + r.below(3);
        for _ in 0..n {
            corrupt(&mut rec, &mut r);
        }
        if rec.blocks.is_empty() || rec.block_txb.len() != rec.blocks.len() + 1 {
            return;
        }
        for flags in [0, ENC_FIX_RANGE, ENC_BITSTREAM_ONLY | ENC_NO_RECON, ENC_CHECK_EDGES] {
            let (c, _) = encode(w, &rec, flags, -1, 0, false, s);
            if flags == 0 {
                codes.lock().unwrap()[(-c.rc) as usize] += 1;
            }
        }
        // validate
        let mut rr = rec.clone();
        let rrc = validate(rr.as_mut()).map_or_else(|e| e.code, |_| OK);
        let tiles = tile_layout(
            rec.fp.width,
            rec.fp.height,
            rec.fp.tile_cols_log2 as i32,
            rec.fp.tile_rows_log2 as i32,
        );
        let multi = tiles.is_ok_and(|t| t.cols * t.rows > 1);
        s.put("validate", &rrc);
        if rrc == OK || !multi {
            s.put("validate", &rr.txb);
        }
    });
    let c = codes.lock().unwrap();
    eprintln!("ok {} invalid {} range {}", c[0], c[1], c[3]);
    assert!(c[1] > 500 && c[3] > 10);
    snap.check(&[
        ("rc", 0x363be43469030b8c),
        ("obu", 0xe8a123b1b43772f6),
        ("avif", 0xeea4e77ab04547d5),
        ("recon", 0x7bdf36d8bfb614b4),
        ("stats", 0x0c488762ad70f89e),
        ("payloads", 0x3afc2a96af84ec2a),
        ("syms", 0xeea4e77ab04547d5),
        ("writeback", 0xe805d9a2be3b39fc),
        ("validate", 0x69721601f31d0d6a),
    ]);
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
fn tile_layout_snapshot() {
    let mut s = Snapshot::new(&["tile_layout"]);
    let mut r = Rnd(77);
    for i in 0..20000 {
        let (w, h) = match i % 4 {
            0 => (r.below(70000), r.below(70000)),
            1 => (1 + r.below(9000), 1 + r.below(9000)),
            2 => (1 + r.below(300), 1 + r.below(300)),
            _ => (4000 + r.below(5000), 2000 + r.below(3000)),
        };
        let (cl, rl) = (r.below(9) as i32 - 1, r.below(9) as i32 - 1);
        let rt = tile_layout(w, h, cl, rl);
        match rt {
            Ok(t) => s.put(
                "tile_layout",
                &(
                    (t.cols_log2, t.rows_log2, t.cols, t.rows),
                    &t.mi_col_starts[..=t.cols as usize],
                    &t.mi_row_starts[..=t.rows as usize],
                ),
            ),
            Err(e) => s.put("tile_layout", &e),
        }
    }
    s.check(&[("tile_layout", 0xf0c31ee9a0c51d11)]);
}

#[test]
fn layout_snapshot() {
    let mut s = Snapshot::new(&["counts", "layout"]);
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
        s.put("counts", &rust);
        match rust {
            Err(_e) => {
                continue;
            }
            Ok(n) => {
                if (n.n_txb as usize) != rec.txb.len() {
                    continue; // tx_depth clamps changed the counts: arrays too small for the C++
                }
            }
        }
        let mut rr = rec.clone();
        let n = rr.layout().unwrap();
        assert_eq!((n.n_txb as usize, n.n_coeffs as usize), (rr.txb.len(), rr.coeffs.len()));
        s.put("layout", &(&rr.block_txb, &rr.txb));
        // too small
        let mut small = vec![Txb::default(); n.n_txb as usize - 1];
        assert_eq!(
            layout(&fp, &rec.blocks, &mut rr.block_txb, &mut small),
            Err(ERR_CAPACITY)
        );
    }
    s.check(&[("counts", 0x9f6784ee3f37c9d0), ("layout", 0x9b267efbf8f0e3bc)]);
}

#[test]
fn delta_q_helpers_snapshot() {
    let mut s = Snapshot::new(&["legalize", "apply"]);
    let mut r = Rnd(11);
    for _ in 0..2000 {
        let (base, res) = (1 + r.below(255) as i32, r.below(8) as i32);
        let target: Vec<u8> = (0..64).map(|_| r.below(256) as u8).collect();
        let mut b = vec![0u8; 64];
        legalize_sb_qindex(base, res, &target, &mut b);
        s.put("legalize", &b);
    }
    for seed in 0..50 {
        let Some(rec) = case(seed, 300, 0) else { continue };
        let sbc = ((mi_cols(rec.fp.width as i32) + 15) >> 4) as usize;
        let sbr = ((mi_rows(rec.fp.height as i32) + 15) >> 4) as usize;
        let map: Vec<u8> = (0..sbc * sbr).map(|_| r.below(256) as u8).collect();
        let mut rr = rec.clone();
        apply_sb_qindex(&rr.fp, &mut rr.blocks, &map).unwrap();
        s.put("apply", &rr.blocks);
        assert_eq!(
            apply_sb_qindex(&rr.fp, &mut rr.blocks, &map[..map.len() - 1]),
            Err(ERR_INVALID)
        );
    }
    s.check(&[("legalize", 0x3bb5f540056eff17), ("apply", 0x57b9082de72070a5)]);
}

// ---------------------------------------------------------------------------------------------
// parse
// ---------------------------------------------------------------------------------------------

/// Parses `obus`, fed to the family "parse" of `s` (the error code, or the record, the level and
/// the tile sizes and offsets).
fn check_parse(obus: &[u8], s: &mut Snapshot) -> Option<Parsed> {
    let rp = parse(obus);
    match &rp {
        Ok(r) => s.put("parse", &(&r.rec, r.seq_level_idx, &r.tile_bytes, &r.tile_offsets)),
        Err(e) => s.put("parse", &e.code),
    }
    rp.ok()
}

/// Parsing the writer's streams: the records (as the C++ parser read them), and the record that was
/// written (decisions, coefficients and the written-back eob / tx types).
#[test]
fn parse_snapshot() {
    let snap = par_seeds(0..300, 6, &["parse"], |w, seed, s| {
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
        let p = check_parse(&out.obu, s).expect("parse");
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
                crate::blockinfo::chroma_ss(&want.fp),
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
    snap.check(&[("parse", 0xf41d48d6a8e982fd)]);
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
        false,
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

/// Full (libaom-style) headers: the parser's non-reduced paths.
#[test]
fn parse_full_headers_snapshot() {
    let n = [
        std::sync::atomic::AtomicU64::new(0),
        std::sync::atomic::AtomicU64::new(0),
    ];
    let snap = par_seeds(0..400, 6, &["parse"], |w, seed, s| {
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
            let st = full_header_stream(&fp, &payloads, &mut r, k >= 4);
            let ok = check_parse(&st, s).is_some();
            n[ok as usize].fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if ok && k < 4 {
                // same decisions as the reduced stream's
                let p = parse(&st).unwrap();
                assert_eq!(p.rec.blocks.len(), rec.blocks.len(), "seed {seed}");
                assert_eq!(p.rec.txb.len(), rec.txb.len(), "seed {seed}");
            }
        }
    });
    let n = n.map(|a| a.into_inner());
    eprintln!("full-header streams: {} parsed, {} rejected", n[1], n[0]);
    assert!(n[1] > 1000 && n[0] > 50);
    snap.check(&[("parse", 0xf213cf8d90c12027)]);
}

/// Damaged tile payloads: the same errors or the same records.
#[test]
fn parse_damaged_snapshot() {
    let n_ok = std::sync::atomic::AtomicU64::new(0);
    let snap = par_seeds(0..400, 6, &["parse"], |w, seed, s| {
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
        for _ in 0..6 {
            let mut o = out.obu.clone();
            let n = o.len();
            for _ in 0..1 + r.below(4) {
                let i = n - 1 - r.below(tail as u32) as usize;
                o[i] ^= 1 << r.below(8);
            }
            if check_parse(&o, s).is_some() {
                n_ok.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            }
        }
        // truncated streams and junk
        for cut in [1, 2, 5, out.obu.len() / 2, out.obu.len() - 1] {
            check_parse(&out.obu[..out.obu.len().min(cut)], s);
        }
    });
    eprintln!("damaged streams that parsed: {}", n_ok.into_inner());
    snap.check(&[("parse", 0x7b14b58ea414cc44)]);
}

// ---------------------------------------------------------------------------------------------
// enc: entropy plan, OBU assembly, post-filter frame
// ---------------------------------------------------------------------------------------------

#[test]
fn ent_plan_snapshot() {
    let mut s = Snapshot::new(&["ent_plan"]);
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
        let cf = GaEntFrame {
            w: 77,
            ..Default::default()
        };
        let ct = vec![GaEntTile::default(); GA_ENT_MAX_TILES];
        let (mut rf, mut rt) = (cf, ct.clone());
        let rn = crate::enc::ent_plan(&fp, nb, nt, &mut rf, &mut rt);
        s.put("ent_plan", &(rn, rf, &rt));
    }
    s.check(&[("ent_plan", 0x6058bec9ff509918)]);
}

#[test]
fn assemble_obus_snapshot() {
    let snap = par_seeds(0..120, 4, &["assemble"], |w, seed, s| {
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
            let r = crate::enc::assemble_obus(&rec.fp, v, td);
            s.put("assemble", &r);
            if k == 0 && ok {
                assert_eq!(r.unwrap(), out.obu, "seed {seed}: assembled = written");
            }
        }
    });
    snap.check(&[("assemble", 0x689b74a42f6c3830)]);
}

#[test]
fn pf_frame_snapshot() {
    let mut s = Snapshot::new(&["pf_frame"]);
    let mut r = Rnd(9);
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
        let f = crate::enc::pf_frame(&fp, &a);
        assert_eq!(f.as_bytes().len(), 280);
        s.put("pf_frame", f.as_bytes());
    }
    s.check(&[("pf_frame", 0x224c499b102e6573)]);
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
                        if has_chroma(bs, rr, cc, false, 1) {
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
