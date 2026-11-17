//! Block and tool statistics of AV1 still pictures (one per tile): each parsed by `writer::parse`
//! and re-coded by the writer with `ENC_BLOCK_BITS`, so every block's bits are counted the same way
//! whoever encoded it (the hybrid, or libaom where it stays in the writer's toolset). Research.
//!
//!   cargo run --release --example tile_stats -- <tiles.obus> [...]
//!
//! A `.obus` file is the pictures as records of a little-endian u32 length and the OBUs.
use glassact_av1::blockinfo::{bh4, bw4};
use glassact_av1::types::EncodeOpts;
use glassact_av1::writer::{ENC_BLOCK_BITS, ENC_SKIP_RECON, Output, Writer, parse};

#[derive(Default)]
struct Acc {
    n: f64,
    area: f64,
    bits: f64,
}
impl Acc {
    fn add(&mut self, area: f64, bits: f64) {
        self.n += 1.0;
        self.area += area;
        self.bits += bits;
    }
}

fn main() {
    for path in std::env::args().skip(1) {
        let data = std::fs::read(&path).expect("read");
        let mut at = 0;
        let (mut pics, mut failed, mut bytes, mut payload, mut blockbits) = (0usize, 0usize, 0f64, 0f64, 0f64);
        let mut by_size: Vec<Acc> = (0..22).map(|_| Acc::default()).collect();
        let (mut pal_y, mut pal_uv, mut pal_both, mut cfl, mut fi, mut ibc, mut other) = (
            Acc::default(),
            Acc::default(),
            Acc::default(),
            Acc::default(),
            Acc::default(),
            Acc::default(),
            Acc::default(),
        );
        let mut pal_y_sizes = [0f64; 9];
        let mut pal_uv_sizes = [0f64; 9];
        let mut nz = [0f64; 3];
        let mut ymodes = [0f64; 13];
        let mut uvmodes = [0f64; 14];
        let mut hdr = std::collections::BTreeMap::<String, usize>::new();
        let mut errors = std::collections::BTreeMap::<String, usize>::new();
        let mut writer = Writer::new();
        while at + 4 <= data.len() {
            let len = u32::from_le_bytes(data[at..at + 4].try_into().unwrap()) as usize;
            let obus = &data[at + 4..at + 4 + len];
            at += 4 + len;
            let mut p = match parse(obus) {
                Ok(p) => p,
                Err(e) => {
                    failed += 1;
                    *errors.entry(e.msg.clone()).or_default() += 1;
                    continue;
                }
            };
            pics += 1;
            bytes += len as f64;
            payload += p.tile_bytes.iter().sum::<u32>() as f64;
            let f = p.rec.fp;
            let h = format!(
                "q {} dq_uv {} {} {} {} qm {} {}/{}/{} dqp {} lf {:?} sharp {} cdef {} bits {} y {:?} uv {:?} sct {} ibc {} txsel {} reduced {} filter_intra {}",
                f.base_q_idx,
                f.delta_q_u_dc,
                f.delta_q_u_ac,
                f.delta_q_v_dc,
                f.delta_q_v_ac,
                f.using_qmatrix,
                f.qm_y,
                f.qm_u,
                f.qm_v,
                f.delta_q_present,
                f.loop_filter_level,
                f.loop_filter_sharpness,
                f.enable_cdef,
                f.cdef_bits,
                &f.cdef_y_pri[..1 << f.cdef_bits],
                &f.cdef_uv_pri[..1 << f.cdef_bits],
                f.allow_screen_content_tools,
                f.allow_intrabc,
                f.tx_mode_select,
                f.reduced_tx_set,
                f.enable_filter_intra
            );
            *hdr.entry(h).or_default() += 1;
            let opts = EncodeOpts {
                flags: ENC_BLOCK_BITS | ENC_SKIP_RECON,
                seq_level_idx: -1,
            };
            let mut out = Output::default();
            if let Err(e) = writer.encode(p.rec.as_mut(), &opts, &mut out) {
                *errors.entry(format!("re-code: {}", e.msg)).or_default() += 1;
                continue;
            }
            for (k, b) in p.rec.blocks.iter().enumerate() {
                let bs = b.bsize as i32;
                let area = (16 * bw4(bs) * bh4(bs)) as f64;
                let bits = writer.block_bits(k) as f64;
                blockbits += bits;
                by_size[bs as usize].add(area, bits);
                let pal = p.rec.palette.get(k).copied().unwrap_or_default();
                let inter = p.rec.inter.get(k).is_some_and(|i| i.is_inter != 0);
                if inter {
                    ibc.add(area, bits);
                } else if pal.size_y != 0 && pal.size_uv != 0 {
                    pal_both.add(area, bits);
                } else if pal.size_y != 0 {
                    pal_y.add(area, bits);
                } else if pal.size_uv != 0 {
                    pal_uv.add(area, bits);
                } else if b.uv_mode == 13 {
                    cfl.add(area, bits);
                } else if b.filter_intra != 0 {
                    fi.add(area, bits);
                } else {
                    other.add(area, bits);
                }
                pal_y_sizes[pal.size_y as usize] += 1.0;
                pal_uv_sizes[pal.size_uv as usize] += 1.0;
                if !inter {
                    ymodes[(b.y_mode as usize).min(12)] += area;
                    uvmodes[(b.uv_mode as usize).min(13)] += area;
                }
                for t in &p.rec.txb[p.rec.block_txb[k] as usize..p.rec.block_txb[k + 1] as usize] {
                    nz[t.plane as usize] += t.eob as f64;
                }
            }
        }
        let n = pics.max(1) as f64;
        println!("== {path}: {pics} pictures parsed, {failed} not");
        for (e, c) in &errors {
            println!("  ({c}) {e}");
        }
        let mut hv: Vec<_> = hdr.iter().collect();
        hv.sort_by(|a, b| b.1.cmp(a.1));
        for (h, c) in hv.iter().take(4) {
            println!("  header ({c}): {h}");
        }
        println!(
            "  {:.1} B a picture, tile payload {:.1} B, blocks' bits {:.1} B ({:.0} %)",
            bytes / n,
            payload / n,
            blockbits / 8.0 / n,
            100.0 * blockbits / 8.0 / payload.max(1.0)
        );
        println!("  by size: blocks a picture · share of area · bytes a picture");
        let names = [
            "4x4", "4x8", "8x4", "8x8", "8x16", "16x8", "16x16", "16x32", "32x16", "32x32", "32x64", "64x32", "64x64",
            "64x128", "128x64", "128x128", "4x16", "16x4", "8x32", "32x8", "16x64", "64x16",
        ];
        let tot_area: f64 = by_size.iter().map(|a| a.area).sum();
        for (i, a) in by_size.iter().enumerate() {
            if a.n > 0.0 {
                println!(
                    "    {:7} {:6.2} · {:5.1} % · {:7.1} B",
                    names[i],
                    a.n / n,
                    100.0 * a.area / tot_area,
                    a.bits / 8.0 / n
                );
            }
        }
        println!("  by tool: blocks a picture · share of area · bytes a picture");
        for (name, a) in [
            ("palette Y", &pal_y),
            ("palette UV", &pal_uv),
            ("palette Y+UV", &pal_both),
            ("CfL", &cfl),
            ("filter intra", &fi),
            ("intra copy", &ibc),
            ("other intra", &other),
        ] {
            if a.n > 0.0 {
                println!(
                    "    {:12} {:6.2} · {:5.1} % · {:7.1} B",
                    name,
                    a.n / n,
                    100.0 * a.area / tot_area,
                    a.bits / 8.0 / n
                );
            }
        }
        println!(
            "  palette sizes Y {:?}",
            &pal_y_sizes[2..]
                .iter()
                .map(|v| v / n)
                .map(|v| (v * 100.0).round() / 100.0)
                .collect::<Vec<_>>()
        );
        println!(
            "  palette sizes UV {:?}",
            &pal_uv_sizes[2..]
                .iter()
                .map(|v| v / n)
                .map(|v| (v * 100.0).round() / 100.0)
                .collect::<Vec<_>>()
        );
        println!(
            "  y modes (% of intra area) {:?}",
            ymodes
                .iter()
                .map(|v| (1000.0 * v / tot_area).round() / 10.0)
                .collect::<Vec<_>>()
        );
        println!(
            "  uv modes (% of intra area) {:?}",
            uvmodes
                .iter()
                .map(|v| (1000.0 * v / tot_area).round() / 10.0)
                .collect::<Vec<_>>()
        );
        println!(
            "  coefficients up to eob a picture: Y {:.0}, U {:.0}, V {:.0}",
            nz[0] / n,
            nz[1] / n,
            nz[2] / n
        );
    }
}
