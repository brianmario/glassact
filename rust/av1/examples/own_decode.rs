//! A measurement, not a decoder yet: decode the hybrid's own AV1 streams with this crate alone. Each
//! frame is parsed (`writer::parse_with`, the spec's symbol decoder) into its decision record, then
//! reconstructed by the writer (`Writer::encode_ex`, the decoder-exact reconstruction, post-filters
//! included) from the reference slots its earlier frames refreshed. The writer also re-codes the
//! symbols, so its time is an upper bound on a reconstruction-only path.
//!
//!   cargo run --release --example own_decode -- <stream.ivf> [<aomdec.i420>]
//!
//! With an I420 file (`aomdec --rawvideo -o <file> <stream.ivf>`), every frame is compared with
//! libaom's.
use glassact_av1::types::EncodeOpts;
use glassact_av1::writer::{Output, ParseState, RefPicture, RefSlots, Writer, parse_with};
use std::rc::Rc;
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let ivf = std::fs::read(&args[1]).expect("read ivf");
    let reference = args.get(2).map(|p| std::fs::read(p).expect("read i420"));
    assert_eq!(&ivf[0..4], b"DKIF");
    let (w, h) = (u16::from_le_bytes([ivf[12], ivf[13]]) as usize, u16::from_le_bytes([ivf[14], ivf[15]]) as usize);
    let (cw, ch) = ((w + 1) / 2, (h + 1) / 2);
    let frame_bytes = w * h + 2 * cw * ch;
    let mut at = u16::from_le_bytes([ivf[6], ivf[7]]) as usize;

    let mut state = ParseState::default();
    let mut writer = Writer::new();
    let mut slots: [Option<Rc<Output>>; 8] = Default::default();
    let opts = EncodeOpts { flags: 0, seq_level_idx: -1 };
    let (mut parse_s, mut recon_s, mut n, mut exact) = (Vec::new(), Vec::new(), 0usize, 0usize);
    while at + 12 <= ivf.len() {
        let size = u32::from_le_bytes(ivf[at..at + 4].try_into().unwrap()) as usize;
        let data = &ivf[at + 12..at + 12 + size];
        at += 12 + size;

        let t0 = Instant::now();
        let mut parsed = parse_with(data, Some(&mut state)).unwrap_or_else(|e| panic!("frame {n}: parse: {}", e.msg));
        let t1 = Instant::now();
        let refs: RefSlots = std::array::from_fn(|i| slots[i].as_deref().map(RefPicture::from_output));
        let mut out = Output::default();
        writer
            .encode_ex(parsed.rec.as_mut(), &opts, &refs, &mut out)
            .unwrap_or_else(|e| panic!("frame {n}: reconstruct: {}", e.msg));
        let t2 = Instant::now();
        drop(refs);
        parse_s.push((t1 - t0).as_secs_f64() * 1e3);
        recon_s.push((t2 - t1).as_secs_f64() * 1e3);

        if let Some(r) = &reference {
            let f = &r[n * frame_bytes..(n + 1) * frame_bytes];
            let same = out.recon[0] == f[..w * h]
                && out.recon[1] == f[w * h..w * h + cw * ch]
                && out.recon[2] == f[w * h + cw * ch..];
            if same {
                exact += 1;
            } else if n - exact < 4 {
                println!("frame {n}: differs from libaom's");
            }
        }
        // a shown key frame refreshes every slot (the spec's refresh_frame_flags = allFrames)
        let refresh = if parsed.rec.fp.frame_type == 0 { 0xFF } else { parsed.rec.fp.refresh_frame_flags };
        let out = Rc::new(out);
        for (i, slot) in slots.iter_mut().enumerate() {
            if refresh & (1 << i) != 0 {
                *slot = Some(out.clone());
            }
        }
        n += 1;
    }
    let stats = |v: &mut Vec<f64>| {
        let first = v[0];
        let mut rest = v[1..].to_vec();
        rest.sort_by(|a, b| a.partial_cmp(b).unwrap());
        (first, rest[rest.len() / 2], rest[rest.len() - 1])
    };
    let (pk, pm, px) = stats(&mut parse_s);
    let (rk, rm, rx) = stats(&mut recon_s);
    println!("{}: {n} frames {w}x{h}", args[1].rsplit('/').next().unwrap());
    println!("  parse   key {pk:6.1} ms · inter median {pm:5.2}, max {px:6.1}");
    println!("  recon   key {rk:6.1} ms · inter median {rm:5.2}, max {rx:6.1}  (the writer: re-codes symbols too)");
    if reference.is_some() {
        println!("  {exact} of {n} frames identical to libaom's");
    }
}
