//! Palette blocks: random records (still pictures of both superblock sizes, inter sequences) with
//! some of their eligible intra blocks turned into palette blocks. They encode, parse back to the
//! palettes and maps that were written, reconstruct the same apart from their coding as in one
//! pass, and (ignored: `cargo test --release -- --ignored --nocapture palette_decoders`) decode
//! exactly with dav1d and aomdec.
use super::inter_tests::{decode_check, encode_seq, sb128_still, seeds};
use super::*;
use crate::blockinfo::{bh4, bw4, has_chroma};
use crate::tables::*;
use crate::testsupport::{FuzzCase, InterSeq};

struct Rnd(u64);
impl Rnd {
    fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 32) as u32
    }
    fn below(&mut self, n: u32) -> u32 {
        self.next() % n
    }
}

/// Distinct sorted colours from a small pool (so neighbours share some: the palette cache).
fn colors(r: &mut Rnd, n: usize, pool: &[u8], distinct: bool) -> [u8; 8] {
    let mut c = [0u8; 8];
    let mut k = 0;
    while k < n {
        let v = if r.below(3) == 0 {
            r.below(256) as u8
        } else {
            pool[r.below(pool.len() as u32) as usize]
        };
        if distinct && c[..k].contains(&v) {
            continue;
        }
        c[k] = v;
        k += 1;
    }
    c[..n].sort_unstable();
    c
}

/// A colour index map of `n` colours, `w x h`: runs and copies of the row above, some noise.
fn map(r: &mut Rnd, n: usize, w: usize, h: usize, out: &mut Vec<u8>) {
    let at = out.len();
    for y in 0..h {
        for x in 0..w {
            let v = match r.below(8) {
                0..=3 if x > 0 => out[at + y * w + x - 1],
                4..=5 if y > 0 => out[at + (y - 1) * w + x],
                _ => r.below(n as u32) as u8,
            };
            out.push(v);
        }
    }
}

/// Turns about `pct` percent of the record's eligible intra blocks into palette blocks (luma,
/// chroma or both), with allow_screen_content_tools.
pub(super) fn add_palettes(rec: &mut Record, seed: u64, pct: u32) -> usize {
    let mut r = Rnd(seed.wrapping_mul(0x9E3779B97F4A7C15) | 1);
    rec.fp.allow_screen_content_tools = 1;
    let mono = rec.fp.monochrome != 0;
    let pool: Vec<u8> = (0..6).map(|_| r.below(256) as u8).collect();
    rec.palette = vec![BlockPalette::default(); rec.blocks.len()];
    rec.palette_map.clear();
    let mut n_pal = 0;
    for (i, b) in rec.blocks.iter_mut().enumerate() {
        let bs = b.bsize as i32;
        let intra = rec.inter.get(i).is_none_or(|x| x.is_inter == 0);
        if !intra || bs < BLOCK_8X8 || bw4(bs) > 16 || bh4(bs) > 16 || r.below(100) >= pct {
            continue;
        }
        let chroma = has_chroma(bs, b.mi_row as i32, b.mi_col as i32, mono);
        let (luma, uv) = match r.below(4) {
            0 => (true, false),
            1 if chroma => (false, true),
            _ => (true, chroma),
        };
        let p = &mut rec.palette[i];
        p.map_off = rec.palette_map.len() as u32;
        let (w, h) = ((4 * bw4(bs)) as usize, (4 * bh4(bs)) as usize);
        if luma {
            p.size_y = 2 + r.below(7) as u8;
            p.colors[0] = colors(&mut r, p.size_y as usize, &pool, true);
            (b.y_mode, b.angle_delta_y, b.filter_intra) = (DC_PRED as u8, 0, 0);
            map(&mut r, p.size_y as usize, w, h, &mut rec.palette_map);
        }
        if uv {
            let n = 2 + r.below(7) as usize;
            p.size_uv = n as u8;
            p.colors[1] = colors(&mut r, n, &pool, false);
            // V near U half the time (its delta coding), else anything
            for k in 0..n {
                p.colors[2][k] = if r.below(2) == 0 {
                    p.colors[1][k].wrapping_add(r.below(9) as u8).wrapping_sub(4)
                } else {
                    r.below(256) as u8
                };
            }
            (b.uv_mode, b.angle_delta_uv, b.cfl_alpha_u, b.cfl_alpha_v) = (DC_PRED as u8, 0, 0, 0);
            let (mi_cols, mi_rows) = (
                crate::blockinfo::mi_cols(rec.fp.width as i32),
                crate::blockinfo::mi_rows(rec.fp.height as i32),
            );
            let d = walk::map_dims(bs, b.mi_row as i32, b.mi_col as i32, mi_rows, mi_cols, true);
            map(&mut r, n, d.w, d.h, &mut rec.palette_map);
        }
        n_pal += 1;
    }
    n_pal
}

fn fuzz_record(seed: u64, maxdim: i32) -> Option<Record> {
    let mut case = FuzzCase::make(seed, maxdim, 20)?;
    let mut rec = Record {
        fp: case.fp,
        blocks: core::mem::take(&mut case.blocks),
        block_txb: core::mem::take(&mut case.block_txb),
        txb: core::mem::take(&mut case.txb),
        coeffs: core::mem::take(&mut case.coeffs),
        ..Default::default()
    };
    rec.coeffs.truncate(case.n_coeffs as usize);
    Some(rec)
}

/// The parsed record's palettes and the visible parts of their maps are the written ones.
fn expect_palettes(want: &Record, got: &Record, what: &str) {
    let fp = &want.fp;
    let (mi_cols, mi_rows) = (
        crate::blockinfo::mi_cols(fp.width as i32),
        crate::blockinfo::mi_rows(fp.height as i32),
    );
    let none = BlockPalette::default();
    for (i, a) in want.palette.iter().enumerate() {
        let b = got.palette.get(i).unwrap_or(&none);
        assert_eq!(
            (a.size_y, a.size_uv),
            (b.size_y, b.size_uv),
            "{what}: block {i} palette sizes"
        );
        for (k, n) in [a.size_y, a.size_uv, a.size_uv].into_iter().enumerate() {
            assert_eq!(
                a.colors[k][..n as usize],
                b.colors[k][..n as usize],
                "{what}: block {i} colours {k}"
            );
        }
        let bl = &want.blocks[i];
        let (bs, r, c) = (bl.bsize as i32, bl.mi_row as i32, bl.mi_col as i32);
        let (mut oa, mut ob) = (a.map_off as usize, b.map_off as usize);
        for (uv, n) in [(false, a.size_y), (true, a.size_uv)] {
            if n == 0 {
                continue;
            }
            let d = walk::map_dims(bs, r, c, mi_rows, mi_cols, uv);
            for y in 0..d.oh {
                assert_eq!(
                    want.palette_map[oa + y * d.w..][..d.ow],
                    got.palette_map[ob + y * d.w..][..d.ow],
                    "{what}: block {i} map {} row {y}",
                    uv as u8
                );
            }
            oa += d.w * d.h;
            ob += d.w * d.h;
        }
    }
    assert!(
        got.palette.len() <= want.palette.len().max(1),
        "{what}: palette entries"
    );
}

/// Encodes `rec` (split reconstruction: `w`) and checks it against one pass, the parser and a
/// bitstream-only re-encode of the parsed record. Returns the output.
fn check_still(w: &mut Writer, rec: &Record, what: &str) -> Output {
    let opts = |f| EncodeOpts {
        flags: f,
        seq_level_idx: -1,
    };
    let (mut a, mut b) = (rec.clone(), rec.clone());
    let (mut oa, mut ob) = (Output::default(), Output::default());
    w.encode(a.as_mut(), &opts(ENC_FIX_RANGE | ENC_TD), &mut oa)
        .unwrap_or_else(|e| panic!("{what}: {e}"));
    Writer::with_threads(1)
        .encode(b.as_mut(), &opts(ENC_FIX_RANGE | ENC_TD), &mut ob)
        .unwrap();
    assert!(oa == ob, "{what}: split vs one pass");
    assert!(
        a.txb == b.txb && a.coeffs == b.coeffs,
        "{what}: split vs one pass, record"
    );
    let p = parse(&oa.obu).unwrap_or_else(|e| panic!("{what}: parse: {e}"));
    expect_palettes(rec, &p.rec, what);
    let mut again = p.rec.clone();
    let mut o = Output::default();
    w.encode(again.as_mut(), &opts(ENC_BITSTREAM_ONLY | ENC_TD), &mut o)
        .unwrap();
    assert!(o.obu == oa.obu, "{what}: the parsed record codes another stream");
    oa
}

#[test]
fn palette_stills_round_trip() {
    let n = std::sync::atomic::AtomicU64::new(0);
    seeds(160, |w, seed| {
        for (rec, kind) in [(fuzz_record(seed, 300), "64x64"), (sb128_still(seed, 300), "128x128")] {
            let Some(mut rec) = rec else { continue };
            let k = add_palettes(&mut rec, seed, 50);
            check_still(w, &rec, &format!("seed {seed} {kind}"));
            n.fetch_add(k as u64, std::sync::atomic::Ordering::Relaxed);
        }
    });
    let n = n.into_inner();
    eprintln!("{n} palette blocks");
    assert!(n > 2000);
}

#[test]
fn palette_inter_sequences_round_trip() {
    seeds(60, |w, seed| {
        let Some(mut seq) = InterSeq::make(seed, 200, 4) else {
            return;
        };
        for (k, rec) in seq.frames.iter_mut().enumerate() {
            add_palettes(rec, seed + 1000 * k as u64, 60);
        }
        let mut one = seq.clone();
        let outs = encode_seq(w, &mut seq, ENC_FIX_RANGE | ENC_TD)
            .unwrap_or_else(|(k, e)| panic!("seed {seed} frame {k}: {e}"));
        let walk = encode_seq(&mut Writer::with_threads(1), &mut one, ENC_FIX_RANGE | ENC_TD).unwrap();
        assert!(outs == walk, "seed {seed}: split vs one pass");
        let mut ps = ParseState::default();
        for (k, (rec, out)) in seq.frames.iter().zip(&outs).enumerate() {
            let p = parse_with(&out.obu, Some(&mut ps)).unwrap_or_else(|e| panic!("seed {seed} frame {k}: parse: {e}"));
            expect_palettes(rec, &p.rec, &format!("seed {seed} frame {k}"));
        }
    });
}

/// Bad palettes are refused.
#[test]
fn palette_records_refused() {
    let mut rec = fuzz_record(3, 200).unwrap();
    assert!(add_palettes(&mut rec, 3, 100) > 0);
    let i = rec.palette.iter().position(|p| p.size_y != 0).unwrap();
    let opts = EncodeOpts {
        flags: ENC_FIX_RANGE,
        seq_level_idx: -1,
    };
    let refused = |rec: &Record| {
        let mut r = rec.clone();
        Writer::new().encode(r.as_mut(), &opts, &mut Output::default()).is_err()
    };
    let mut bad = rec.clone();
    bad.palette[i].size_y = 9;
    assert!(refused(&bad), "size 9");
    let mut bad = rec.clone();
    bad.palette[i].colors[0][1] = bad.palette[i].colors[0][0];
    assert!(refused(&bad), "repeated luma colour");
    let mut bad = rec.clone();
    bad.blocks[i].y_mode = V_PRED as u8;
    assert!(refused(&bad), "not DC_PRED");
    let mut bad = rec.clone();
    bad.fp.allow_screen_content_tools = 0;
    assert!(refused(&bad), "no screen content tools");
    let mut bad = rec.clone();
    let o = bad.palette[i].map_off as usize;
    bad.palette_map[o] = 8;
    assert!(refused(&bad), "colour index past the palette");
    let mut bad = rec.clone();
    bad.palette_map.truncate(bad.palette[i].map_off as usize + 1);
    assert!(refused(&bad), "maps outside the record");
    let mut bad = rec;
    bad.palette.pop();
    assert!(refused(&bad), "too few entries");
}

#[test]
#[ignore]
fn palette_decoders() {
    let tools = [
        ("dav1d", vec!["-q", "-i", "IN", "-o", "OUT"]),
        ("aomdec", vec!["--rawvideo", "-o", "OUT", "IN"]),
    ];
    let dir = std::env::temp_dir().join(format!("glassact-av1-palette-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    seeds(80, |w, seed| {
        for (rec, kind) in [(fuzz_record(seed, 300), "64x64"), (sb128_still(seed, 300), "128x128")] {
            let Some(mut rec) = rec else { continue };
            add_palettes(&mut rec, seed, 50);
            let out = check_still(w, &rec, &format!("seed {seed} {kind}"));
            decode_check(
                &dir,
                &tools,
                &format!("{kind}-{seed}"),
                &[out],
                &rec.fp,
                &["palette still"],
            );
        }
        let Some(mut seq) = InterSeq::make(seed, 200, 4) else {
            return;
        };
        for (k, rec) in seq.frames.iter_mut().enumerate() {
            add_palettes(rec, seed + 1000 * k as u64, 60);
        }
        let outs = encode_seq(w, &mut seq, ENC_FIX_RANGE | ENC_TD).unwrap();
        let kinds: Vec<&str> = seq
            .frames
            .iter()
            .map(|r| if r.fp.frame_type == FRAME_KEY { "key" } else { "inter" })
            .collect();
        decode_check(&dir, &tools, &format!("seq-{seed}"), &outs, &seq.frames[0].fp, &kinds);
    });
    let _ = std::fs::remove_dir_all(&dir);
}
