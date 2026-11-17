//! Decodes the hybrid's AV1 streams with this crate alone, and times it: the decoder
//! (`decoder::Decoder`), or with `--writer` the first measurement's path (each frame parsed by
//! `writer::parse_with` into its record, then reconstructed by `Writer::encode_ex`, which re-codes
//! the symbols too, from the slots its earlier frames refreshed).
//!
//!   cargo run --release --example own_decode -- [--writer] [--threads N] [--repeat K] <stream.ivf> [<aomdec.i420>]
//!
//! With an I420 file (`aomdec --rawvideo -o <file> <stream.ivf>`), every frame is compared with
//! libaom's. `--repeat` decodes the stream K times (after a reset) and keeps each frame's fastest
//! time.
use glassact_av1::decoder::Decoder;
use glassact_av1::types::EncodeOpts;
use glassact_av1::writer::{Output, ParseState, RefPicture, RefSlots, Writer, parse_with};
use std::rc::Rc;
use std::time::Instant;

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut take = |flag: &str| -> Option<String> {
        let i = args.iter().position(|a| a == flag)?;
        args.remove(i);
        (flag != "--writer").then(|| args.remove(i)).or(Some(String::new()))
    };
    let writer_path = take("--writer").is_some();
    let threads: usize = take("--threads").map_or(0, |v| v.parse().unwrap());
    let repeat: usize = take("--repeat").map_or(1, |v| v.parse().unwrap());
    let ivf = std::fs::read(&args[0]).expect("read ivf");
    let reference = args.get(1).map(|p| std::fs::read(p).expect("read i420"));
    assert_eq!(&ivf[0..4], b"DKIF");
    let (w, h) = (u16::from_le_bytes([ivf[12], ivf[13]]) as usize, u16::from_le_bytes([ivf[14], ivf[15]]) as usize);
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    let frame_bytes = w * h + 2 * cw * ch;
    let mut tus = Vec::new();
    let mut at = u16::from_le_bytes([ivf[6], ivf[7]]) as usize;
    while at + 12 <= ivf.len() {
        let size = u32::from_le_bytes(ivf[at..at + 4].try_into().unwrap()) as usize;
        tus.push(&ivf[at + 12..at + 12 + size]);
        at += 12 + size;
    }
    let n = tus.len();
    let mut best = vec![f64::MAX; n];
    let mut key = vec![false; n];
    let mut exact = 0usize;
    let mut stages = [0f64; 5];
    let mut units = [0u64; 4];
    let compare = |k: usize, planes: [&[u8]; 3], stride: [usize; 3]| -> bool {
        let Some(r) = &reference else { return false };
        let f = &r[k * frame_bytes..(k + 1) * frame_bytes];
        let dims = [(w, h, 0), (cw, ch, w * h), (cw, ch, w * h + cw * ch)];
        dims.iter()
            .enumerate()
            .all(|(p, &(pw, ph, off))| (0..ph).all(|y| planes[p][y * stride[p]..][..pw] == f[off + y * pw..][..pw]))
    };
    let mut threads_used = 0;
    for round in 0..repeat {
        if writer_path {
            let mut state = ParseState::default();
            let mut writer = Writer::new();
            let mut slots: [Option<Rc<Output>>; 8] = Default::default();
            let opts = EncodeOpts { flags: 0, seq_level_idx: -1 };
            for (k, tu) in tus.iter().enumerate() {
                let t0 = Instant::now();
                let mut parsed = parse_with(tu, Some(&mut state)).unwrap_or_else(|e| panic!("frame {k}: parse: {}", e.msg));
                let refs: RefSlots = std::array::from_fn(|i| slots[i].as_deref().map(RefPicture::from_output));
                let mut out = Output::default();
                writer
                    .encode_ex(parsed.rec.as_mut(), &opts, &refs, &mut out)
                    .unwrap_or_else(|e| panic!("frame {k}: reconstruct: {}", e.msg));
                best[k] = best[k].min(t0.elapsed().as_secs_f64() * 1e3);
                key[k] = parsed.rec.fp.frame_type == 0;
                if round == 0 && compare(k, [&out.recon[0], &out.recon[1], &out.recon[2]], [w, cw, cw]) {
                    exact += 1;
                }
                let refresh = if key[k] { 0xFF } else { parsed.rec.fp.refresh_frame_flags };
                let out = Rc::new(out);
                for (i, slot) in slots.iter_mut().enumerate() {
                    if refresh & (1 << i) != 0 {
                        *slot = Some(out.clone());
                    }
                }
            }
        } else {
            let mut d = Decoder::new(threads);
            threads_used = d.threads();
            for (k, tu) in tus.iter().enumerate() {
                let t0 = Instant::now();
                let p = d.decode(tu).unwrap_or_else(|e| panic!("frame {k}: {}", e.msg));
                let dt = t0.elapsed().as_secs_f64() * 1e3;
                key[k] = p.key;
                if round == 0 && compare(k, p.planes, p.stride) {
                    exact += 1;
                }
                if dt < best[k] {
                    best[k] = dt;
                }
                if round == 0 {
                    let s = d.stats();
                    for (a, b) in stages
                        .iter_mut()
                        .zip([s.ms_header, s.ms_tiles, s.ms_maps, s.ms_filters, s.ms_output])
                    {
                        *a += b;
                    }
                    for (a, b) in units
                        .iter_mut()
                        .zip([s.units_copy, s.units_clean, s.units_filter, s.units_written])
                    {
                        *a += b as u64;
                    }
                }
            }
        }
    }
    let stats = |key_frames: bool| -> Option<(usize, f64, f64)> {
        let mut v: Vec<f64> = (0..n).filter(|&k| key[k] == key_frames).map(|k| best[k]).collect();
        if v.is_empty() {
            return None;
        }
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        Some((v.len(), v[v.len() / 2], v[v.len() - 1]))
    };
    let total: f64 = best.iter().sum();
    println!(
        "{}: {n} frames {w}x{h}, {}",
        args[0].rsplit('/').next().unwrap(),
        if writer_path {
            "parse + writer".to_string()
        } else {
            format!("decoder on {threads_used} threads")
        }
    );
    for (what, kf) in [("key", true), ("inter", false)] {
        if let Some((c, med, max)) = stats(kf) {
            println!("  {what:5} {c:3} frames: median {med:7.2} ms, max {max:7.2}");
        }
    }
    println!("  all: {:.2} ms a frame on average ({:.0} frames/s)", total / n as f64, n as f64 / total * 1e3);
    if !writer_path {
        let a = stages.map(|s| s / n as f64);
        println!(
            "  stages, mean ms: header {:.3}, tiles {:.3}, maps {:.3}, filters {:.3}, output {:.3}",
            a[0], a[1], a[2], a[3], a[4]
        );
        println!(
            "  64x64s: copied {}, as decoded {}, filtered {}; written {}",
            units[0], units[1], units[2], units[3]
        );
    }
    if reference.is_some() {
        println!("  {exact} of {n} frames identical to libaom's");
    }
}
