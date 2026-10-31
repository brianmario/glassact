//! Inter frames (video mode): random legal inter sequences (testsupport::inter_gen) encoded frame
//! by frame, each with the reconstructions of the frames that last refreshed its reference slots;
//! parse round trips; video key frames against still pictures; and, with the decoders installed,
//! the reconstructions against dav1d's and aomdec's output (ignored: `cargo test --release --
//! --ignored decoders`). The Swift DecoderGateTests hold the same sequences to the vendored libaom.
use super::*;
use crate::tables::*;
use crate::testsupport::{FuzzCase, InterSeq};

/// The outputs of a sequence's frames, encoded in order. The error names the frame.
pub(super) fn encode_seq(w: &mut Writer, seq: &mut InterSeq, flags: u32) -> Result<Vec<Output>, (usize, Error)> {
    let mut outs: Vec<Output> = Vec::with_capacity(seq.frames.len());
    let mut slot_of = [usize::MAX; 8];
    for (k, rec) in seq.frames.iter_mut().enumerate() {
        let mut out = Output::default();
        {
            let mut refs: RefSlots = [None; 8];
            for (s, r) in refs.iter_mut().enumerate() {
                if slot_of[s] != usize::MAX {
                    *r = Some(RefPicture::from_output(&outs[slot_of[s]]));
                }
            }
            let opts = EncodeOpts {
                flags,
                seq_level_idx: -1,
            };
            w.encode_ex(rec.as_mut(), &opts, &refs, &mut out).map_err(|e| (k, e))?;
        }
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
    Ok(outs)
}

/// What the parser gives back for a written record: the decisions the bitstream carries (a skip
/// block's cdef_idx and a skipped 64x64's qindex are not coded) and the written-back tx blocks.
fn expect_parsed(want: &Record, got: &Record, what: &str) {
    let mut fp = want.fp;
    (fp.tile_cols_log2, fp.tile_rows_log2) = (got.fp.tile_cols_log2, got.fp.tile_rows_log2);
    assert_eq!(fp, got.fp, "{what}: frame params");
    assert_eq!(want.blocks.len(), got.blocks.len(), "{what}: blocks");
    for (i, (b, pb)) in want.blocks.iter().zip(&got.blocks).enumerate() {
        let mut b = *b;
        if b.skip != 0 {
            b.cdef_idx = pb.cdef_idx;
            if b.bsize as i32 == BLOCK_64X64 {
                b.sb_qindex = pb.sb_qindex;
            }
        }
        if want.fp.delta_q_present == 0 {
            b.sb_qindex = pb.sb_qindex;
        }
        assert_eq!(b, *pb, "{what}: block {i}");
    }
    let inter = |r: &Record, i: usize| r.inter.get(i).copied().unwrap_or_default();
    for i in 0..want.blocks.len() {
        assert_eq!(inter(want, i), inter(got, i), "{what}: inter entry of block {i}");
    }
    assert_eq!(want.block_txb, got.block_txb, "{what}: layout");
    assert_eq!(want.txb.len(), got.txb.len(), "{what}: txb");
    for (i, (a, b)) in want.txb.iter().zip(&got.txb).enumerate() {
        assert_eq!(
            (a.plane, a.tx_size, a.x4, a.y4, a.coeff_off, a.eob),
            (b.plane, b.tx_size, b.x4, b.y4, b.coeff_off, b.eob),
            "{what}: txb {i}"
        );
        // tx types and levels of coded tx blocks (a skip block's are not coded)
        if a.eob > 0 {
            assert_eq!(a.tx_type, b.tx_type, "{what}: txb {i} type");
            let n = crate::dsp::tx_coeffs(a.tx_size as i32);
            let o = a.coeff_off as usize;
            assert_eq!(want.coeffs[o..o + n], got.coeffs[o..o + n], "{what}: txb {i} levels");
        }
    }
}

fn seeds(n: u64, f: impl Fn(&mut Writer, u64) + Sync) {
    let next = std::sync::atomic::AtomicU64::new(0);
    std::thread::scope(|s| {
        for _ in 0..std::thread::available_parallelism().map_or(4, |n| n.get()).min(8) {
            s.spawn(|| {
                let mut w = Writer::with_threads(2);
                loop {
                    let k = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    if k >= n {
                        break;
                    }
                    f(&mut w, k);
                }
            });
        }
    });
}

/// Every frame of random sequences encodes, parses back to the record that was written (which
/// codes the same stream again), and codes the same bytes and reconstruction on one thread as on
/// several.
#[test]
fn inter_sequences_round_trip() {
    let frames = std::sync::atomic::AtomicU64::new(0);
    seeds(160, |w, seed| {
        let Some(mut seq) = InterSeq::make(seed, 200, 6) else {
            return;
        };
        let outs = match encode_seq(w, &mut seq, ENC_FIX_RANGE | ENC_TD) {
            Ok(o) => o,
            Err((k, e)) => panic!("seed {seed} frame {k}: {e}"),
        };
        let mut ps = ParseState::default();
        for (k, (rec, out)) in seq.frames.iter().zip(&outs).enumerate() {
            let before = ps.clone();
            let p = parse_with(&out.obu, Some(&mut ps)).unwrap_or_else(|e| panic!("seed {seed} frame {k}: parse: {e}"));
            expect_parsed(rec, &p.rec, &format!("seed {seed} frame {k}"));
            // the parser's saved CDFs are the writer's
            if rec.fp.frame_type == FRAME_KEY || rec.fp.refresh_frame_flags != 0 {
                let s = (0..8)
                    .find(|&s| rec.fp.frame_type == FRAME_KEY || rec.fp.refresh_frame_flags >> s & 1 != 0)
                    .unwrap();
                assert!(ps.slots[s] == out.saved_cdfs, "seed {seed} frame {k}: saved CDFs");
            }
            let mut again = p.rec.clone();
            let opts = EncodeOpts {
                flags: ENC_BITSTREAM_ONLY | ENC_TD,
                seq_level_idx: out.seq_level_idx as i32,
            };
            let mut o = Output::default();
            let mut refs: RefSlots = [None; 8];
            for (r, c) in refs.iter_mut().zip(&before.slots) {
                *r = Some(RefPicture {
                    cdfs: c.as_deref(),
                    ..Default::default()
                });
            }
            w.encode_ex(again.as_mut(), &opts, &refs, &mut o).unwrap();
            assert!(
                o.obu == out.obu,
                "seed {seed} frame {k}: the parsed record codes another stream"
            );
        }
        frames.fetch_add(outs.len() as u64, std::sync::atomic::Ordering::Relaxed);
        if seed % 8 == 0 {
            let Some(mut again) = InterSeq::make(seed, 200, 6) else {
                return;
            };
            let one = encode_seq(&mut Writer::with_threads(1), &mut again, ENC_FIX_RANGE | ENC_TD).unwrap();
            assert!(one == outs, "seed {seed}: threads");
        }
    });
    eprintln!("{} frames; {}", frames.into_inner(), coverage());
}

/// A key frame in video mode codes a still picture's tile data and reconstructs exactly as it.
#[test]
fn video_key_frames_are_still_pictures() {
    seeds(120, |w, seed| {
        let Some(mut case) = FuzzCase::make(seed, 300, 2) else {
            return;
        };
        let mut rec = Record {
            fp: case.fp,
            blocks: core::mem::take(&mut case.blocks),
            block_txb: core::mem::take(&mut case.block_txb),
            txb: core::mem::take(&mut case.txb),
            coeffs: core::mem::take(&mut case.coeffs),
            inter: Vec::new(),
        };
        rec.coeffs.truncate(case.n_coeffs as usize);
        let opts = EncodeOpts {
            flags: ENC_FIX_RANGE,
            seq_level_idx: -1,
        };
        let mut still = Output::default();
        if w.encode(rec.as_mut(), &opts, &mut still).is_err() {
            return;
        }
        let still_tiles = w.tile_payloads().to_vec();
        rec.fp.video = 1;
        let mut video = Output::default();
        w.encode(rec.as_mut(), &opts, &mut video).unwrap();
        assert_eq!(w.tile_payloads(), &still_tiles[..], "seed {seed}: tile data");
        assert_eq!(still.recon, video.recon, "seed {seed}: reconstruction");
        assert_ne!(still.obu, video.obu);
        let p = parse(&video.obu).unwrap();
        assert_eq!((p.rec.fp.video, p.rec.fp.frame_type), (1, FRAME_KEY));
    });
}

/// A hook that checks the prediction it is shown for inter tx blocks against the spec's block
/// inter prediction from the frame's reference (luma; chroma of blocks 8x8 and up), and leaves
/// the coefficients alone.
struct McCheck<'a> {
    inter: &'a [BlockInter],
    reference: RefPicture<'a>,
    w: u32,
    h: u32,
    checked: std::sync::atomic::AtomicU64,
}

impl TxbHook for McCheck<'_> {
    type Scratch = Vec<u8>;
    fn on_txb(&self, want: &mut Vec<u8>, ctx: &TxbCtx<'_>, txb: &mut Txb, _: &mut [i16]) {
        use crate::blockinfo::{bh4, bw4};
        use crate::dsp::{RefPlane, predict_inter_ref, subpel_filter, tx_h, tx_w};
        let b = ctx.block;
        let p = txb.plane as usize;
        if !ctx.is_inter || (p > 0 && (bw4(b.bsize as i32) < 2 || bh4(b.bsize as i32) < 2)) {
            return;
        }
        let bi = self.inter[ctx.block_idx as usize];
        let sub = (p != 0) as u32;
        let r = RefPlane {
            data: self.reference.plane[p],
            stride: self.reference.stride[p],
            w: ((self.w + sub) >> sub) as i32,
            h: ((self.h + sub) >> sub) as i32,
        };
        let (tw, th) = (tx_w(txb.tx_size as i32) as usize, tx_h(txb.tx_size as i32) as usize);
        let (pw, ph) = (
            (4 * bw4(b.bsize as i32) as usize) >> sub,
            (4 * bh4(b.bsize as i32) as usize) >> sub,
        );
        let filters = [subpel_filter(EIGHTTAP, pw), subpel_filter(EIGHTTAP, ph)];
        want.resize(tw * th, 0);
        let (x, y) = (txb.x4 as i32 * 4, txb.y4 as i32 * 4);
        let mv = [bi.mv_row as i32, bi.mv_col as i32];
        predict_inter_ref(&r, sub as i32, x, y, tw, th, mv, filters, want, tw);
        for i in 0..th {
            assert_eq!(
                &ctx.recon[i * ctx.recon_stride..][..tw],
                &want[i * tw..][..tw],
                "block {} plane {p} tx ({x},{y}) row {i}: the hook's prediction",
                ctx.block_idx
            );
        }
        self.checked.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }
}

/// The closed-loop hook sees the exact inter prediction of every inter tx block, and a hook that
/// changes nothing changes nothing.
#[test]
fn hook_sees_the_inter_prediction() {
    let checked = std::sync::atomic::AtomicU64::new(0);
    seeds(120, |w, seed| {
        let Some(mut seq) = InterSeq::make(seed, 200, 5) else {
            return;
        };
        let plain = encode_seq(w, &mut seq.clone(), ENC_FIX_RANGE).unwrap();
        let mut slot_of = [0usize; 8];
        for k in 0..seq.frames.len() {
            let fp = seq.frames[k].fp;
            if fp.frame_type == FRAME_INTER {
                let rec = &mut seq.frames[k];
                let reference = RefPicture::from_output(&plain[slot_of[fp.ref_slot as usize]]);
                let refs: RefSlots = [Some(reference); 8];
                let inter = rec.inter.clone();
                let hook = McCheck {
                    inter: &inter,
                    reference,
                    w: fp.width,
                    h: fp.height,
                    checked: Default::default(),
                };
                let extras = Extras {
                    refs: Some(&refs),
                    ..Extras::default()
                };
                let opts = EncodeOpts {
                    flags: ENC_FIX_RANGE,
                    seq_level_idx: -1,
                };
                let mut out = Output::default();
                w.encode_with_hook(rec.as_mut(), &opts, Some(&hook), &extras, &mut out)
                    .unwrap();
                assert!(out == plain[k], "seed {seed} frame {k}: the hook changed the output");
                checked.fetch_add(hook.checked.into_inner(), std::sync::atomic::Ordering::Relaxed);
            }
            let refresh = if fp.frame_type == FRAME_KEY {
                0xFF
            } else {
                fp.refresh_frame_flags
            };
            for (s, slot) in slot_of.iter_mut().enumerate() {
                if refresh >> s & 1 != 0 {
                    *slot = k;
                }
            }
        }
    });
    let n = checked.into_inner();
    eprintln!("{n} inter tx blocks checked");
    assert!(n > 8000);
}

/// Damaged inter frames (bit flips in the headers and tile data, truncations) parse to an error
/// or a record, never a panic; a record that parses re-encodes (bitstream only).
#[test]
fn damaged_inter_frames_parse_or_fail() {
    let parsed = std::sync::atomic::AtomicU64::new(0);
    seeds(150, |w, seed| {
        let Some(mut seq) = InterSeq::make(seed, 120, 4) else {
            return;
        };
        let outs = encode_seq(w, &mut seq, ENC_FIX_RANGE).unwrap();
        let mut r = seed.wrapping_mul(0x9E3779B97F4A7C15) | 1;
        let mut next = move || {
            r ^= r << 13;
            r ^= r >> 7;
            r ^= r << 17;
            r
        };
        for o in &outs {
            for _ in 0..8 {
                let mut d = o.obu.clone();
                for _ in 0..1 + next() % 3 {
                    let i = (next() as usize) % d.len();
                    d[i] ^= 1 << (next() % 8);
                }
                if let Ok(mut p) = parse(&d) {
                    parsed.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    let opts = EncodeOpts {
                        flags: ENC_BITSTREAM_ONLY,
                        seq_level_idx: -1,
                    };
                    let _ = w.encode(p.rec.as_mut(), &opts, &mut Output::default());
                }
            }
            for cut in [1, 3, o.obu.len() / 3, o.obu.len() - 1] {
                let _ = parse(&o.obu[..cut]);
            }
        }
    });
    eprintln!("{} damaged frames parsed", parsed.into_inner());
}

/// Records the writer must refuse.
#[test]
fn inter_records_refused() {
    let mut seq = InterSeq::make(3, 64, 2).unwrap();
    let (key, inter) = (seq.frames[0].clone(), seq.frames[1].clone());
    let mut w = Writer::with_threads(1);
    let opts = EncodeOpts {
        flags: ENC_FIX_RANGE,
        seq_level_idx: -1,
    };
    let enc =
        |w: &mut Writer, r: &mut Record, refs: &RefSlots| w.encode_ex(r.as_mut(), &opts, refs, &mut Output::default());
    let k0 = encode_seq(&mut w, &mut seq, ENC_FIX_RANGE).unwrap();
    let mut refs: RefSlots = [Some(RefPicture::from_output(&k0[0])); 8];
    let bad = |what: &str, w: &mut Writer, mut r: Record, refs: &RefSlots| {
        let e = enc(w, &mut r, refs).expect_err(what);
        assert_eq!(e.code, ERR_INVALID, "{what}: {}", e.msg);
    };
    let mut r = inter.clone();
    r.fp.allow_screen_content_tools = 0;
    bad("inter frame without screen content tools", &mut w, r, &refs);
    let mut r = inter.clone();
    r.fp.video = 0;
    bad("inter frame outside video mode", &mut w, r, &refs);
    let mut r = key.clone();
    r.fp.refresh_frame_flags = 1;
    bad("key frame refresh flags", &mut w, r, &refs);
    let mut r = inter.clone();
    if let Some(i) = r.inter.iter().position(|i| i.is_inter != 0) {
        r.inter[i].mv_row |= 4;
        bad("half-sample mv", &mut w, r, &refs);
    }
    let mut r = key.clone();
    r.inter = vec![BlockInter::default(); r.blocks.len()];
    r.inter[0].is_inter = 1;
    bad("inter block in a key frame", &mut w, r, &refs);
    refs[inter.fp.ref_slot as usize] = None;
    bad("empty reference slot", &mut w, inter.clone(), &refs);
    // but the bitstream alone needs no references
    let mut r = inter.clone();
    w.encode_ex(
        r.as_mut(),
        &EncodeOpts {
            flags: ENC_BITSTREAM_ONLY,
            seq_level_idx: -1,
        },
        &refs,
        &mut Output::default(),
    )
    .unwrap();
}

/// IVF of a sequence's frames (each its TD + sequence header + frame).
fn ivf(outs: &[Output], w: u32, h: u32) -> Vec<u8> {
    let mut v = Vec::new();
    v.extend_from_slice(b"DKIF");
    v.extend_from_slice(&0u16.to_le_bytes());
    v.extend_from_slice(&32u16.to_le_bytes());
    v.extend_from_slice(b"AV01");
    v.extend_from_slice(&(w as u16).to_le_bytes());
    v.extend_from_slice(&(h as u16).to_le_bytes());
    v.extend_from_slice(&30u32.to_le_bytes());
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(&(outs.len() as u32).to_le_bytes());
    v.extend_from_slice(&0u32.to_le_bytes());
    for (k, o) in outs.iter().enumerate() {
        v.extend_from_slice(&(o.obu.len() as u32).to_le_bytes());
        v.extend_from_slice(&(k as u64).to_le_bytes());
        v.extend_from_slice(&o.obu);
    }
    v
}

/// The installed decoders (dav1d, aomdec) decode random sequences to exactly the writer's
/// reconstructions (a development check; the Swift test holds them to the vendored libaom).
#[test]
#[ignore]
fn decoders() {
    let tools = [
        ("dav1d", vec!["-q", "-i", "IN", "-o", "OUT"]),
        ("aomdec", vec!["--rawvideo", "-o", "OUT", "IN"]),
    ];
    let env = |k: &str, d: u64| std::env::var(k).map_or(d, |v| v.parse().unwrap());
    let (n, maxdim, nframes) = (env("SEQS", 60), env("MAXDIM", 160) as i32, env("FRAMES", 8) as usize);
    let dir = std::env::temp_dir().join(format!("glassact-av1-decoders-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let frames = std::sync::atomic::AtomicU64::new(0);
    seeds(n, |w, seed| {
        let Some(mut seq) = InterSeq::make(seed, maxdim, nframes) else {
            return;
        };
        let outs = encode_seq(w, &mut seq, ENC_FIX_RANGE | ENC_TD | ENC_CHECK_EDGES)
            .unwrap_or_else(|(k, e)| panic!("seed {seed} frame {k}: {e}"));
        let fp = seq.frames[0].fp;
        let src = dir.join(format!("s{seed}.ivf"));
        std::fs::write(&src, ivf(&outs, fp.width, fp.height)).unwrap();
        for (tool, args) in &tools {
            let path = format!("/opt/homebrew/bin/{tool}");
            if !std::path::Path::new(&path).exists() {
                continue;
            }
            let yuv = dir.join(format!("s{seed}.{tool}.yuv"));
            let args: Vec<String> = args
                .iter()
                .map(|a| match *a {
                    "IN" => src.display().to_string(),
                    "OUT" => yuv.display().to_string(),
                    a => a.to_string(),
                })
                .collect();
            let st = std::process::Command::new(&path).args(&args).output().unwrap();
            assert!(
                st.status.success(),
                "seed {seed}: {tool} failed: {}",
                String::from_utf8_lossy(&st.stderr)
            );
            let data = std::fs::read(&yuv).unwrap();
            let (pw, ph) = (fp.width as usize, fp.height as usize);
            let (cw, ch) = (pw.div_ceil(2), ph.div_ceil(2));
            let mono = fp.monochrome != 0;
            let per = if mono { pw * ph } else { pw * ph + 2 * cw * ch };
            assert_eq!(data.len(), per * outs.len(), "seed {seed}: {tool} output size");
            for (k, o) in outs.iter().enumerate() {
                let f = &data[k * per..];
                let planes = if mono { 1 } else { 3 };
                let mut at = 0;
                for p in 0..planes {
                    let n = o.recon[p].len();
                    if f[at..at + n] != o.recon[p][..] {
                        let i = (0..n).find(|&i| f[at + i] != o.recon[p][i]).unwrap();
                        let ww = o.recon_w[p] as usize;
                        panic!(
                            "seed {seed} {}x{} frame {k} ({}): {tool} plane {p} differs first at ({}, {}): writer {}, {tool} {}",
                            fp.width,
                            fp.height,
                            if seq.frames[k].fp.frame_type == FRAME_KEY {
                                "key"
                            } else {
                                "inter"
                            },
                            i % ww,
                            i / ww,
                            o.recon[p][i],
                            f[at + i]
                        );
                    }
                    at += n;
                }
            }
        }
        let _ = std::fs::remove_file(&src);
        frames.fetch_add(outs.len() as u64, std::sync::atomic::Ordering::Relaxed);
    });
    eprintln!("{} frames decode exactly; {}", frames.into_inner(), coverage());
    let _ = std::fs::remove_dir_all(&dir);
}

/// The inter syntax the writer has coded so far in this process (walk::INTER_STAT).
pub(super) fn coverage() -> String {
    let s = super::walk::INTER_STAT
        .each_ref()
        .map(|a| a.load(std::sync::atomic::Ordering::Relaxed));
    format!(
        "inter blocks: {} GLOBALMV, {} NEARESTMV, {} NEARMV ({} drl > 1), {} NEWMV ({} drl > 0); \
         {} intra blocks in inter frames, {} var-tx splits, {} sub-8x8 chroma from several MVs",
        s[0], s[1], s[2], s[4], s[3], s[5], s[6], s[7], s[8]
    )
}

/// Writer speed: an inter frame against the key frame of the same content (the reference
/// engine's decisions on a synthetic screen at 2560x1440 and 5120x2880, deblocking and CDEF on).
/// The scrolled inter frame keeps the key frame's partition, tx sizes and coefficients with every
/// block inter (a 16-row scroll: the luma copies and the chroma half-sample filters run on every
/// block; tx types DCT); the static one has every block inter with mv 0 and skip.
/// `cargo test --release -- --ignored --nocapture bench_inter`
#[test]
#[ignore]
fn bench_inter_vs_key() {
    use crate::testsupport::{Image, RefEngineOpts, ref_engine_encode};
    let time = |runs: usize, f: &mut dyn FnMut()| {
        let mut best = f64::MAX;
        for _ in 0..runs {
            let t = std::time::Instant::now();
            f();
            best = best.min(t.elapsed().as_secs_f64());
        }
        best * 1e3
    };
    for (w, h) in [(2560u32, 1440u32), (5120, 2880)] {
        // a screen: flat panels, text-like strokes, a gradient
        let (wu, hu) = (w as usize, h as usize);
        let (cw, ch) = (wu.div_ceil(2), hu.div_ceil(2));
        let mut y = vec![0u8; wu * hu];
        let mut seed = 12345u32;
        for r in 0..hu {
            for c in 0..wu {
                seed = seed.wrapping_mul(1103515245).wrapping_add(12345);
                let panel = ((r / 180) * 7 + (c / 320) * 13) % 5;
                y[r * wu + c] = match panel {
                    0 => 240,
                    1 => (c * 255 / wu) as u8,
                    2 if (r % 18 < 12) && ((c / 3 + r / 18) % 5 != 0) && (seed >> 28) < 9 => 30,
                    2 => 235,
                    3 => 60,
                    _ => ((r + c) % 64 * 3) as u8,
                };
            }
        }
        let u: Vec<u8> = (0..cw * ch).map(|i| (128 + (i % cw) * 40 / cw) as u8).collect();
        let v: Vec<u8> = (0..cw * ch).map(|i| (110 + (i / cw) * 30 / ch) as u8).collect();
        let img = Image {
            w,
            h,
            mono: false,
            planes: [&y, &u, &v],
        };
        let o = RefEngineOpts {
            qindex: 120,
            lf_level: 10,
            cdef: true,
            ..RefEngineOpts::default()
        };
        let mut key = Record::default();
        let key_out = ref_engine_encode(&img, &o, &mut key, None).unwrap();
        key.fp.video = 1;
        let mut scroll = key.clone();
        scroll.fp.frame_type = FRAME_INTER;
        scroll.fp.allow_screen_content_tools = 1;
        scroll.fp.refresh_frame_flags = 1;
        let mv = BlockInter {
            mv_row: 16 * 8,
            is_inter: 1,
            ..Default::default()
        };
        scroll.inter = vec![mv; scroll.blocks.len()];
        for b in &mut scroll.blocks {
            (b.y_mode, b.angle_delta_y, b.uv_mode, b.angle_delta_uv) = (0, 0, 0, 0);
            (b.cfl_alpha_u, b.cfl_alpha_v, b.filter_intra) = (0, 0, 0);
            if b.skip != 0 {
                b.tx_depth = 0;
            }
        }
        // transform_tree order; each tx block keeps its coefficients (same sizes, same offsets
        // where the order is the same, else another tx block's of the same size)
        scroll.layout().unwrap();
        scroll.txb.iter_mut().for_each(|t| t.tx_type = DCT_DCT as u8);
        let mut still = scroll.clone();
        still.inter.iter_mut().for_each(|i| i.mv_row = 0);
        still.blocks.iter_mut().for_each(|b| (b.skip, b.tx_depth) = (1, 0));
        still.layout().unwrap();
        let refs: RefSlots = [Some(RefPicture::from_output(&key_out)); 8];
        let mut wr = Writer::new();
        let opts = EncodeOpts {
            flags: ENC_FIX_RANGE,
            seq_level_idx: -1,
        };
        let mut out = Output::default();
        for (name, rec) in [
            ("key", &key),
            ("inter, scrolled, same residual", &scroll),
            ("inter, static, all skip", &still),
        ] {
            let mut r = rec.clone();
            wr.encode_ex(r.as_mut(), &opts, &refs, &mut out).unwrap();
            let (bytes, syms) = (out.obu.len(), out.n_symbols);
            let t = time(7, &mut || {
                let mut r = rec.clone();
                wr.encode_ex(r.as_mut(), &opts, &refs, &mut out).unwrap();
            });
            let tc = time(7, &mut || drop(rec.clone()));
            eprintln!(
                "{w}x{h} {} blocks: {name:32} {:7.2} ms ({bytes} bytes, {syms} symbols)",
                rec.blocks.len(),
                t - tc,
            );
        }
    }
}
