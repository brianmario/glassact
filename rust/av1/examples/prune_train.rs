//! Trains the Metal encoder's learned pruning (Sources/GlassActAV1/Shaders/k_ml.h; BENCHMARKS
//! "learned pruning of the analysis"): per 8x8 cell, which tree level (8/16/32/64) the full
//! search chooses, from statistics of the cell's four nested nodes.
//!
//! Data: pictures dumped by `glassact-bench av1seq --dump-partition <dir>/<trace>-<anything>`,
//! one directory each (the trace id before the first '-'): their luma, the full search's leaves
//! and the partition DP's per-node costs. BENCHMARKS lists the pictures the shipped weights were
//! trained on.
//!
//! cargo run --release --example prune_train -- <dumps>
//!     each trace scored by a model trained on the others: the analysis skipped and the cost the
//!     skips add, all at once (the DP over the GPU's node costs, with k_ml_tree's repair)
//! SUB=3 STEPS=3000000 EXPORT=<file> cargo run --release --example prune_train -- <dumps>
//!     train on everything and write the weights: raw f32 (any name), or Swift source (.swift,
//!     Sources/GlassActAV1/AV1PrunerWeights.swift)
//! EVAL=<weights file> cargo run --release --example prune_train -- <dumps>
//!     score raw weights on the dumps
use std::fs;

const LEVEL_MS: [f64; 4] = [23.2, 21.1, 28.6, 12.9];
const PF: usize = 8; // features per level
const NF: usize = 4 * PF + 1;
const H: usize = 24;
const C: usize = 4;

struct Pic {
    trace: usize,
    w: usize,
    h: usize,
    sbc: usize,
    costs: Vec<f32>,
    cells: Vec<(usize, [f32; NF], u8)>,
}

fn stats(y: &[u8], w: usize, x0: usize, y0: usize, n: usize, st2: f64) -> [f32; PF] {
    let (mut s1, mut s2, mut dx, mut dy) = (0f64, 0f64, 0f64, 0f64);
    let mut bits = [0u32; 8];
    let (mut lo, mut hi) = (255u8, 0u8);
    let h2 = n / 2;
    let mut q1 = [0f64; 4];
    let mut q2 = [0f64; 4];
    for r in 0..n {
        let row = &y[(y0 + r) * w + x0..(y0 + r) * w + x0 + n];
        for c in 0..n {
            let v = row[c];
            let f = v as f64;
            s1 += f;
            s2 += f * f;
            let q = (r >= h2) as usize * 2 + (c >= h2) as usize;
            q1[q] += f;
            q2[q] += f * f;
            bits[(v >> 5) as usize] |= 1 << (v & 31);
            lo = lo.min(v);
            hi = hi.max(v);
            if c + 1 < n {
                dx += (row[c + 1] as f64 - f).abs();
            }
            if r + 1 < n {
                dy += (y[(y0 + r + 1) * w + x0 + c] as f64 - f).abs();
            }
        }
    }
    let a = (n * n) as f64;
    let m = s1 / a;
    let var = s2 / a - m * m;
    let qa = a / 4.0;
    let qv: Vec<f64> = (0..4)
        .map(|q| {
            let qm = q1[q] / qa;
            q2[q] / qa - qm * qm
        })
        .collect();
    let qmin = qv.iter().cloned().fold(f64::MAX, f64::min);
    let qmax = qv.iter().cloned().fold(0., f64::max);
    let l = |v: f64| (1.0 + v.max(0.0) / st2).ln() as f32;
    let (dx, dy) = (dx / (a - n as f64), dy / (a - n as f64));
    let distinct: u32 = bits.iter().map(|b| b.count_ones()).sum();
    [
        l(var),
        l(qmin),
        l(qmax),
        (1.0 + dx * dx / st2).ln() as f32,
        (1.0 + dy * dy / st2).ln() as f32,
        (distinct as f32).ln(),
        l(((hi - lo) as f64).powi(2)),
        ((dx + 0.5) / (dy + 0.5)).ln().abs() as f32,
    ]
}

fn bsize_dims(b: u8) -> (usize, usize) {
    match b {
        0 => (4, 4),
        1 => (4, 8),
        2 => (8, 4),
        3 => (8, 8),
        4 => (8, 16),
        5 => (16, 8),
        6 => (16, 16),
        7 => (16, 32),
        8 => (32, 16),
        9 => (32, 32),
        10 => (32, 64),
        11 => (64, 32),
        12 => (64, 64),
        16 => (4, 16),
        17 => (16, 4),
        18 => (8, 32),
        19 => (32, 8),
        20 => (16, 64),
        21 => (64, 16),
        _ => panic!("bsize {b}"),
    }
}

fn load(dir: &str, sub: usize) -> (Vec<String>, Vec<Pic>) {
    let mut traces: Vec<String> = vec![];
    let mut pics = vec![];
    let mut entries: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect();
    entries.sort();
    for e in entries {
        let name = e.file_name().unwrap().to_string_lossy().to_string();
        let tr = name.split('-').next().unwrap().to_string();
        if !traces.contains(&tr) {
            traces.push(tr.clone());
        }
        let ti = traces.iter().position(|t| *t == tr).unwrap();
        let d = fs::read(e.join("p000.bin")).unwrap();
        let u = |o: usize| u32::from_le_bytes(d[o..o + 4].try_into().unwrap()) as usize;
        let (w, h, q) = (u(0), u(4), u(8));
        let y = &d[12..12 + w * h];
        let nb = u(12 + w * h);
        let b0 = 16 + w * h;
        let c0 = b0 + nb * 16;
        let nc = u(c0);
        let costs: Vec<f32> = (0..nc)
            .map(|i| f32::from_le_bytes(d[c0 + 4 + 4 * i..c0 + 8 + 4 * i].try_into().unwrap()))
            .collect();
        let sbc = w.div_ceil(64);
        let mc = w / 4;
        let mr = h / 4;
        let mut lvl = vec![0u8; mc * mr];
        for k in 0..nb {
            let r = &d[b0 + 16 * k..];
            let (mi_row, mi_col, bs) = (
                u16::from_le_bytes([r[0], r[1]]) as usize,
                u16::from_le_bytes([r[2], r[3]]) as usize,
                r[4],
            );
            let (bw, bh) = bsize_dims(bs);
            let l = match bw.max(bh) {
                0..=8 => 0u8,
                9..=16 => 1,
                17..=32 => 2,
                _ => 3,
            };
            for rr in mi_row..(mi_row + bh / 4).min(mr) {
                for cc in mi_col..(mi_col + bw / 4).min(mc) {
                    lvl[rr * mc + cc] = l;
                }
            }
        }
        let st = glassact_av1::dsp::ac_q(q as i32) as f64 / 8.0;
        let st2 = st * st;
        // node stats per level, on the level's grid (whole nodes only)
        let grids: Vec<(usize, Vec<[f32; PF]>)> = [8usize, 16, 32, 64]
            .iter()
            .map(|&n| {
                let cols = w / n;
                (
                    cols,
                    (0..(h / n) * cols)
                        .map(|k| stats(y, w, (k % cols) * n, (k / cols) * n, n, st2))
                        .collect(),
                )
            })
            .collect();
        let mut cells = vec![];
        // cells in whole 64x64 SBs only (edge SBs keep everything)
        for cy in 0..(h / 64) * 8 {
            for cx in 0..(w / 64) * 8 {
                if sub > 1 && (cx * 7 + cy * 13) % sub != 0 {
                    continue;
                }
                let mut f = [0f32; NF];
                for (li, n) in [8usize, 16, 32, 64].iter().enumerate() {
                    let (cols, g) = &grids[li];
                    let s = g[(cy * 8 / n) * cols + cx * 8 / n];
                    f[li * PF..li * PF + PF].copy_from_slice(&s);
                }
                f[NF - 1] = 1.0;
                cells.push((cy * (w / 8) + cx, f, lvl[(cy * 2) * mc + cx * 2]));
            }
        }
        pics.push(Pic {
            trace: ti,
            w,
            h,
            sbc,
            costs,
            cells,
        });
    }
    (traces, pics)
}

struct Mlp {
    w1: Vec<f32>,
    b1: Vec<f32>,
    w2: Vec<f32>,
    b2: [f32; C],
    mu: [f32; NF],
    sd: [f32; NF],
}
impl Mlp {
    fn fwd(&self, f: &[f32; NF], h: &mut [f32; H], p: &mut [f32; C]) {
        let mut x = [0f32; NF];
        for k in 0..NF {
            x[k] = (f[k] - self.mu[k]) / self.sd[k];
        }
        for j in 0..H {
            let mut a = self.b1[j];
            for k in 0..NF {
                a += self.w1[j * NF + k] * x[k];
            }
            h[j] = a.tanh();
        }
        let mut mx = f32::MIN;
        for c in 0..C {
            let mut z = self.b2[c];
            for j in 0..H {
                z += self.w2[c * H + j] * h[j];
            }
            p[c] = z;
            mx = mx.max(z);
        }
        let mut s = 0.0;
        for c in 0..C {
            p[c] = (p[c] - mx).exp();
            s += p[c];
        }
        for c in 0..C {
            p[c] /= s;
        }
    }
}
fn train(data: &[(&[f32; NF], u8)], steps: usize, seed: u64) -> Mlp {
    let mut mu = [0f32; NF];
    let mut sd = [0f32; NF];
    for (f, _) in data {
        for k in 0..NF {
            mu[k] += f[k];
        }
    }
    for k in 0..NF {
        mu[k] /= data.len() as f32;
    }
    for (f, _) in data {
        for k in 0..NF {
            sd[k] += (f[k] - mu[k]).powi(2);
        }
    }
    for k in 0..NF {
        sd[k] = (sd[k] / data.len() as f32).sqrt().max(1e-3);
    }
    mu[NF - 1] = 0.0;
    sd[NF - 1] = 1.0;
    let mut r = seed | 1;
    let mut rnd = move || {
        r ^= r << 13;
        r ^= r >> 7;
        r ^= r << 17;
        r
    };
    let mut m = Mlp {
        w1: (0..H * NF)
            .map(|_| ((rnd() % 10000) as f32 / 10000.0 - 0.5) * 0.4)
            .collect(),
        b1: vec![0.0; H],
        w2: (0..C * H)
            .map(|_| ((rnd() % 10000) as f32 / 10000.0 - 0.5) * 0.4)
            .collect(),
        b2: [0.0; C],
        mu,
        sd,
    };
    let (mut h, mut p) = ([0f32; H], [0f32; C]);
    for it in 0..steps {
        let lr = 0.03 * (1.0 - it as f32 / steps as f32) + 0.001;
        let (f, y) = data[(rnd() as usize) % data.len()];
        m.fwd(f, &mut h, &mut p);
        let mut x = [0f32; NF];
        for k in 0..NF {
            x[k] = (f[k] - m.mu[k]) / m.sd[k];
        }
        let mut gh = [0f32; H];
        for c in 0..C {
            let e = p[c] - if c == y as usize { 1.0 } else { 0.0 };
            for j in 0..H {
                gh[j] += e * m.w2[c * H + j];
                m.w2[c * H + j] -= lr * e * h[j];
            }
            m.b2[c] -= lr * e;
        }
        for j in 0..H {
            let g = gh[j] * (1.0 - h[j] * h[j]);
            m.b1[j] -= lr * g;
            for k in 0..NF {
                m.w1[j * NF + k] -= lr * g * x[k];
            }
        }
    }
    m
}

/// keep[cell] bitmask of levels kept, by cumulative probability >= 1 - eps (at least the top one)
fn keep_levels(p: &[f32; C], eps: f32) -> u8 {
    let mut idx = [0usize, 1, 2, 3];
    idx.sort_by(|&a, &b| p[b].partial_cmp(&p[a]).unwrap());
    let (mut m, mut cum) = (0u8, 0f32);
    for &i in &idx {
        m |= 1 << i;
        cum += p[i];
        if cum >= 1.0 - eps {
            break;
        }
    }
    m
}

/// the joint DP: (added cost / total, stage cost skipped / total) for one picture's kept levels
fn joint(pic: &Pic, keep: &[u8]) -> (f64, f64, f64) {
    let cols8 = pic.w / 8;
    let (mut added, mut total, mut skipped) = (0f64, 0f64, 0f64);
    let lvb = [0usize, 1, 5, 21];
    let nsb = (pic.w / 64) * (pic.h / 64);
    for sby in 0..pic.h / 64 {
        for sbx in 0..pic.w / 64 {
            let sb = sby * pic.sbc + sbx;
            let c = &pic.costs[sb * 171..sb * 171 + 171];
            let lam = c[170].max(1e-6) as f64;
            // a node's own kept: any cell in it keeps the node's level; then k_ml_tree's repair
            let mut own = [false; 85];
            let mut below = [false; 85];
            let mut feas = [false; 85];
            for lv in 0..4 {
                let per = 1 << lv;
                let n = 64 >> lv;
                let level = 3 - lv;
                for t in 0..per * per {
                    let (x0, y0) = (sbx * 64 + (t % per) * n, sby * 64 + (t / per) * n);
                    for cy in y0 / 8..(y0 + n) / 8 {
                        for cx in x0 / 8..(x0 + n) / 8 {
                            let b = keep[cy * cols8 + cx];
                            if b >> level & 1 != 0 {
                                own[lvb[lv] + t] = true;
                            }
                            if b & ((1 << level) - 1) != 0 {
                                below[lvb[lv] + t] = true;
                            }
                        }
                    }
                }
            }
            for lv in (0..4).rev() {
                let per = 1 << lv;
                for t in 0..per * per {
                    let i = lvb[lv] + t;
                    feas[i] = own[i]
                        || (lv < 3
                            && (0..4).all(|q| {
                                feas[lvb[lv + 1] + ((t / per) * 2 + q / 2) * per * 2 + (t % per) * 2 + q % 2]
                            }));
                }
            }
            for lv in 0..3 {
                let per = 1 << lv;
                for t in 0..per * per {
                    if !below[lvb[lv] + t] {
                        continue;
                    }
                    for q in 0..4 {
                        let ci = lvb[lv + 1] + ((t / per) * 2 + q / 2) * per * 2 + (t % per) * 2 + q % 2;
                        if !feas[ci] {
                            own[ci] = true;
                            feas[ci] = true;
                        }
                    }
                }
            }
            let kept = |lv: usize, nx: usize, ny: usize| -> bool { own[lvb[lv] + ny * (1 << lv) + nx] };
            let mut bo = [0f32; 85];
            let mut bn = [0f32; 85];
            for lv in (0..4).rev() {
                let per = 1 << lv;
                for t in 0..per * per {
                    let i = lvb[lv] + t;
                    let (nx, ny) = (t % per, t / per);
                    bo[i] = c[2 * i].min(c[2 * i + 1]);
                    let k = kept(lv, nx, ny);
                    if !k {
                        skipped += LEVEL_MS[3 - lv] / (per * per) as f64 / nsb as f64;
                    }
                    if lv == 3 {
                        bn[i] = if k { bo[i] } else { f32::INFINITY };
                        continue;
                    }
                    let mut d = 0f32;
                    for q in 0..4 {
                        let ci = lvb[lv + 1] + (ny * 2 + q / 2) * per * 2 + nx * 2 + q % 2;
                        d += bn[ci] - bo[ci];
                    }
                    bn[i] = (if k { c[2 * i] } else { f32::INFINITY }).min(c[2 * i + 1] + d);
                }
            }
            if bo[0].is_finite() {
                total += bo[0] as f64 / lam;
                added += ((bn[0] - bo[0]) as f64 / lam).min(1e7);
            }
        }
    }
    (added, total, skipped / LEVEL_MS.iter().sum::<f64>())
}

fn main() {
    let dir = std::env::args().nth(1).unwrap();
    let sub: usize = std::env::var("SUB").map_or(1, |v| v.parse().unwrap());
    let (traces, pics) = load(&dir, if std::env::var("EXPORT").is_ok() { sub } else { 1 });
    let steps: usize = std::env::var("STEPS").map_or(1_500_000, |v| v.parse().unwrap());
    let epss = [0.002f32, 0.005, 0.01, 0.02, 0.05, 0.1];
    if let Ok(wf) = std::env::var("EVAL") {
        let b = fs::read(&wf).unwrap();
        let v: Vec<f32> = b.chunks(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())).collect();
        let mut m = Mlp {
            w1: vec![],
            b1: vec![],
            w2: vec![],
            b2: [0.0; C],
            mu: [0.0; NF],
            sd: [0.0; NF],
        };
        let mut o = 0;
        m.mu.copy_from_slice(&v[o..o + NF]);
        o += NF;
        m.sd.copy_from_slice(&v[o..o + NF]);
        o += NF;
        m.w1 = v[o..o + H * NF].to_vec();
        o += H * NF;
        m.b1 = v[o..o + H].to_vec();
        o += H;
        m.w2 = v[o..o + C * H].to_vec();
        o += C * H;
        m.b2.copy_from_slice(&v[o..o + C]);
        let (mut h, mut p) = ([0f32; H], [0f32; C]);
        for &eps in &epss {
            let (mut add, mut tot, mut sk) = (0.0, 0.0, 0.0);
            for pic in &pics {
                let mut keep = vec![0xFu8; (pic.w / 8) * (pic.h / 8)];
                for (cell, f, _) in &pic.cells {
                    m.fwd(f, &mut h, &mut p);
                    keep[*cell] = keep_levels(&p, eps);
                }
                let (a, tt, s) = joint(pic, &keep);
                add += a;
                tot += tt;
                sk += s / pics.len() as f64;
            }
            print!(" eps {eps}: skip {:.0} % adds {:.2} % |", sk * 100., add / tot * 100.);
        }
        println!();
        return;
    }
    if let Ok(out) = std::env::var("EXPORT") {
        let data: Vec<(&[f32; NF], u8)> = pics.iter().flat_map(|p| p.cells.iter().map(|c| (&c.1, c.2))).collect();
        let m = train(&data, steps, 5);
        let mut v: Vec<f32> = vec![];
        v.extend_from_slice(&m.mu);
        v.extend_from_slice(&m.sd);
        v.extend_from_slice(&m.w1);
        v.extend_from_slice(&m.b1);
        v.extend_from_slice(&m.w2);
        v.extend_from_slice(&m.b2);
        if out.ends_with(".swift") {
            let mut t = String::from(
                "// Generated by rust/av1/examples/prune_train.rs (EXPORT); BENCHMARKS \"learned pruning of the analysis\".\n",
            );
            t += "// The learned pruning's weights (Shaders/k_ml.h ML_FLOATS: means, deviations, first layer, its biases,\n";
            t += "// output layer, its biases).\n\n/// See `AV1MetalEncoder.learnedPrune`.\npublic enum AV1PrunerWeights {\n";
            t += &format!(
                "    /// {} cells of {} pictures.\n    public static let cellV1: [Float] = [\n",
                data.len(),
                pics.len()
            );
            for row in v.chunks(6) {
                t += "        ";
                t += &row.iter().map(|x| format!("{x:e}")).collect::<Vec<_>>().join(", ");
                t += ",\n";
            }
            t += "    ]\n}\n";
            fs::write(&out, t).unwrap();
        } else {
            fs::write(&out, v.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>()).unwrap();
        }
        println!("{} floats written to {out} ({} cells)", v.len(), data.len());
        return;
    }
    for t in 0..traces.len() {
        let data: Vec<(&[f32; NF], u8)> = pics
            .iter()
            .filter(|p| p.trace != t)
            .flat_map(|p| {
                p.cells
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| i % sub.max(1) == 0)
                    .map(|(_, c)| (&c.1, c.2))
            })
            .collect();
        let m = train(&data, steps, 5 + t as u64);
        let (mut h, mut p) = ([0f32; H], [0f32; C]);
        print!("{}:", traces[t]);
        for &eps in &epss {
            let (mut add, mut tot, mut sk, mut np) = (0.0, 0.0, 0.0, 0.0);
            for pic in pics.iter().filter(|p| p.trace == t) {
                let mut keep = vec![0xFu8; (pic.w / 8) * (pic.h / 8)];
                for (cell, f, _) in &pic.cells {
                    m.fwd(f, &mut h, &mut p);
                    keep[*cell] = keep_levels(&p, eps);
                }
                let (a, tt, s) = joint(pic, &keep);
                add += a;
                tot += tt;
                sk += s;
                np += 1.0;
            }
            print!(
                " eps {eps}: skip {:.0} % adds {:.2} % |",
                sk / np * 100.,
                add / tot * 100.
            );
        }
        println!();
    }
}
