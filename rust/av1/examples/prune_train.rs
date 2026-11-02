//! Trains the Metal encoder's learned pruning (Sources/GlassActAV1/Shaders/k_ml.h; BENCHMARKS
//! "learned pruning of the analysis"). Two models:
//! - level: per 8x8 cell, which tree level (8/16/32/64) the full search chooses, from statistics
//!   of the cell's four nested nodes;
//! - mode: per tree node, which luma modes its own blocks choose, from the node's statistics and
//!   its gradients' orientations.
//!
//! Data: pictures dumped by `glassact-bench av1seq --dump-partition <dir>/<trace>-<anything>`, one
//! directory each (the trace id before the first '-'; `scripts/train-pruner` makes them from
//! `scripts/pruner-traces.txt`): the "GAML" sections PICT (luma), LEAF (the full search's leaves),
//! NODE (the partition DP's node costs) and MODE (each analyzed block's best mode).
//!
//! cargo run --release --example prune_train -- <dumps>
//!     each trace scored by models trained on the others: for the level model, the analysis
//!     skipped and the cost the skips add, all at once (the DP over the GPU's node costs, with
//!     k_ml_tree's repair); for the mode model, the modes screened and how many chosen leaves'
//!     modes they miss. MODEL=level or MODEL=mode for one.
//! SUB=3 STEPS=3000000 EXPORT=<file.swift> cargo run --release --example prune_train -- <dumps>
//!     train both on everything and write Sources/GlassActAV1/AV1PrunerWeights.swift (any other
//!     name: the level model's raw f32s, then the mode model's)
//! EVAL=<raw weights> cargo run --release --example prune_train -- <dumps>
//!     score raw weights (as EXPORT writes them) on the dumps
use std::collections::HashMap;
use std::fs;

const LEVEL_MS: [f64; 4] = [23.2, 21.1, 28.6, 12.9];
/// Statistics per node (`stats`), as k_ml_stats computes them.
const PF: usize = 8;
/// Orientation bins per node (`hog`), as k_ml_stats computes them.
const OB: usize = 8;
/// The level model: 4 nodes' statistics and a bias; ML_H hidden; 4 levels.
const LEVEL_NF: usize = 4 * PF + 1;
const LEVEL_H: usize = 24;
/// The mode model: the node's statistics, its orientations, its level (one-hot) and a bias; 13 modes.
const MODE_NF: usize = PF + OB + 4 + 1;
const MODE_H: usize = 24;
const MODES: usize = 13;

/// One dumped picture.
struct Pic {
    trace: usize,
    w: usize,
    h: usize,
    sbc: usize,
    costs: Vec<f32>,
    /// level model samples: (cell index, features, chosen level)
    cells: Vec<(usize, Vec<f32>, u8)>,
    /// mode model samples: (node features, best mode of one of the node's own blocks)
    nodes: Vec<(Vec<f32>, u8)>,
    /// chosen leaves: (their node's features, their mode)
    leaves: Vec<(Vec<f32>, u8)>,
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

/// Gradient orientations inside a node: central differences on its interior samples, 8 bins of
/// the angle mod pi (bin k: [k pi/8, (k+1) pi/8), angles from the x axis, y down), weighted by the
/// gradient's L1 magnitude, as shares of the total (all 0 on a flat node).
fn hog(y: &[u8], w: usize, x0: usize, y0: usize, n: usize) -> [f32; OB] {
    let mut b = [0f32; OB];
    let mut total = 0f32;
    for r in 1..n - 1 {
        for c in 1..n - 1 {
            let p = |dr: isize, dc: isize| y[((y0 + r) as isize + dr) as usize * w + ((x0 + c) as isize + dc) as usize] as f32;
            let gx = p(0, 1) - p(0, -1);
            let gy = p(1, 0) - p(-1, 0);
            let mag = gx.abs() + gy.abs();
            if mag == 0.0 {
                continue;
            }
            let mut a = gy.atan2(gx);
            if a < 0.0 {
                a += std::f32::consts::PI;
            }
            let k = ((a / std::f32::consts::PI * OB as f32) as usize).min(OB - 1);
            b[k] += mag;
            total += mag;
        }
    }
    if total > 0.0 {
        for v in &mut b {
            *v /= total;
        }
    }
    b
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

/// The level (0: 8 .. 3: 64) whose node a block of these dimensions belongs to (k_ml.h's).
fn level_of(bw: usize, bh: usize) -> usize {
    match bw.max(bh) {
        0..=8 => 0,
        9..=16 => 1,
        17..=32 => 2,
        _ => 3,
    }
}

/// A dump's sections by tag.
fn sections(d: &[u8], path: &str) -> HashMap<String, Vec<u8>> {
    assert!(d.len() >= 8 && &d[0..4] == b"GAML", "{path}: not a version 2 dump (re-dump it)");
    let mut out = HashMap::new();
    let mut o = 8;
    while o + 8 <= d.len() {
        let tag = String::from_utf8_lossy(&d[o..o + 4]).to_string();
        let n = u32::from_le_bytes(d[o + 4..o + 8].try_into().unwrap()) as usize;
        out.insert(tag, d[o + 8..o + 8 + n].to_vec());
        o += 8 + n;
    }
    out
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
        let path = e.join("p000.bin");
        let d = fs::read(&path).unwrap();
        let s = sections(&d, &path.display().to_string());
        let pict = &s["PICT"];
        let u = |b: &[u8], o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap()) as usize;
        let (w, h, q) = (u(pict, 0), u(pict, 4), u(pict, 8));
        let y = &pict[12..12 + w * h];
        let leaf = &s["LEAF"];
        let costs: Vec<f32> = s["NODE"].chunks(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())).collect();
        let sbc = w.div_ceil(64);
        let (mc, mr) = (w / 4, h / 4);
        let mut lvl = vec![0u8; mc * mr];
        let mut leaf_list = vec![];
        for r in leaf.chunks(16) {
            let (mi_row, mi_col, bs) =
                (u16::from_le_bytes([r[0], r[1]]) as usize, u16::from_le_bytes([r[2], r[3]]) as usize, r[4]);
            let (bw, bh) = bsize_dims(bs);
            let l = level_of(bw, bh) as u8;
            for rr in mi_row..(mi_row + bh / 4).min(mr) {
                for cc in mi_col..(mi_col + bw / 4).min(mc) {
                    lvl[rr * mc + cc] = l;
                }
            }
            leaf_list.push((mi_col * 4, mi_row * 4, l as usize, r[7]));
        }
        let st = glassact_av1::dsp::ac_q(q as i32) as f64 / 8.0;
        let st2 = st * st;
        // node statistics and orientations per level, on the level's grid (whole nodes only)
        let grids: Vec<(usize, Vec<[f32; PF]>, Vec<[f32; OB]>)> = [8usize, 16, 32, 64]
            .iter()
            .map(|&n| {
                let cols = w / n;
                let k = (h / n) * cols;
                (
                    cols,
                    (0..k).map(|k| stats(y, w, (k % cols) * n, (k / cols) * n, n, st2)).collect(),
                    (0..k).map(|k| hog(y, w, (k % cols) * n, (k / cols) * n, n)).collect(),
                )
            })
            .collect();
        let node_features = |li: usize, nx: usize, ny: usize| -> Vec<f32> {
            let (cols, g, o) = &grids[li];
            let mut f = Vec::with_capacity(MODE_NF);
            f.extend_from_slice(&g[ny * cols + nx]);
            f.extend_from_slice(&o[ny * cols + nx]);
            for k in 0..4 {
                f.push((k == li) as u8 as f32);
            }
            f.push(1.0);
            f
        };
        let mut cells = vec![];
        // cells in whole 64x64 SBs only (edge SBs keep everything)
        for cy in 0..(h / 64) * 8 {
            for cx in 0..(w / 64) * 8 {
                if sub > 1 && (cx * 7 + cy * 13) % sub != 0 {
                    continue;
                }
                let mut f = vec![0f32; LEVEL_NF];
                for (li, n) in [8usize, 16, 32, 64].iter().enumerate() {
                    let (cols, g, _) = &grids[li];
                    f[li * PF..li * PF + PF].copy_from_slice(&g[(cy * 8 / n) * cols + cx * 8 / n]);
                }
                f[LEVEL_NF - 1] = 1.0;
                cells.push((cy * (w / 8) + cx, f, lvl[(cy * 2) * mc + cx * 2]));
            }
        }
        // the mode model: every analyzed block of a whole node's own shapes, its best mode
        let mut nodes = vec![];
        if let Some(md) = s.get("MODE") {
            let mut o = 0;
            while o + 12 <= md.len() {
                let (bs, cols, rows) = (u(md, o) as u8, u(md, o + 4), u(md, o + 8));
                let (bw, bh) = bsize_dims(bs);
                let li = level_of(bw, bh);
                let n = 8 << li;
                for k in 0..cols * rows {
                    let m = md[o + 12 + k];
                    let (x, y0) = ((k % cols) * bw, (k / cols) * bh);
                    if m == 255 || x + bw > (w / n) * n || y0 + bh > (h / n) * n {
                        continue;
                    }
                    if sub > 1 && (x / 4 * 7 + y0 / 4 * 13 + bs as usize) % (sub * 4) != 0 {
                        continue;
                    }
                    nodes.push((node_features(li, x / n, y0 / n), m >> 3));
                }
                o += 12 + cols * rows;
            }
        }
        let leaves = leaf_list
            .iter()
            .filter(|&&(x, y0, li, _)| {
                let n = 8 << li;
                x + n <= (w / n) * n && y0 + n <= (h / n) * n
            })
            .map(|&(x, y0, li, m)| (node_features(li, x / (8 << li), y0 / (8 << li)), m))
            .collect();
        pics.push(Pic { trace: ti, w, h, sbc, costs, cells, nodes, leaves });
    }
    (traces, pics)
}

/// A one-hidden-layer network (tanh, softmax), its inputs standardized.
struct Mlp {
    nf: usize,
    h: usize,
    c: usize,
    w1: Vec<f32>,
    b1: Vec<f32>,
    w2: Vec<f32>,
    b2: Vec<f32>,
    mu: Vec<f32>,
    sd: Vec<f32>,
}
impl Mlp {
    fn fwd(&self, f: &[f32], h: &mut [f32], p: &mut [f32]) {
        let (nf, hn, c) = (self.nf, self.h, self.c);
        let x: Vec<f32> = (0..nf).map(|k| (f[k] - self.mu[k]) / self.sd[k]).collect();
        for j in 0..hn {
            let mut a = self.b1[j];
            for k in 0..nf {
                a += self.w1[j * nf + k] * x[k];
            }
            h[j] = a.tanh();
        }
        let mut mx = f32::MIN;
        for k in 0..c {
            let mut z = self.b2[k];
            for j in 0..hn {
                z += self.w2[k * hn + j] * h[j];
            }
            p[k] = z;
            mx = mx.max(z);
        }
        let mut s = 0.0;
        for v in p.iter_mut().take(c) {
            *v = (*v - mx).exp();
            s += *v;
        }
        for v in p.iter_mut().take(c) {
            *v /= s;
        }
    }
    /// mu, sd, w1, b1, w2, b2: k_ml.h's order.
    fn floats(&self) -> Vec<f32> {
        [&self.mu, &self.sd, &self.w1, &self.b1, &self.w2, &self.b2].iter().flat_map(|v| v.iter().copied()).collect()
    }
    fn from_floats(v: &[f32], nf: usize, h: usize, c: usize) -> Mlp {
        let mut o = 0;
        let mut take = |n: usize| {
            o += n;
            v[o - n..o].to_vec()
        };
        Mlp { nf, h, c, mu: take(nf), sd: take(nf), w1: take(h * nf), b1: take(h), w2: take(c * h), b2: take(c) }
    }
}

fn train(data: &[(&[f32], u8)], nf: usize, hn: usize, c: usize, steps: usize, seed: u64) -> Mlp {
    let mut mu = vec![0f32; nf];
    let mut sd = vec![0f32; nf];
    for (f, _) in data {
        for k in 0..nf {
            mu[k] += f[k];
        }
    }
    for v in &mut mu {
        *v /= data.len() as f32;
    }
    for (f, _) in data {
        for k in 0..nf {
            sd[k] += (f[k] - mu[k]).powi(2);
        }
    }
    for v in &mut sd {
        *v = (*v / data.len() as f32).sqrt().max(1e-3);
    }
    mu[nf - 1] = 0.0;
    sd[nf - 1] = 1.0;
    let mut r = seed | 1;
    let mut rnd = move || {
        r ^= r << 13;
        r ^= r >> 7;
        r ^= r << 17;
        r
    };
    let mut m = Mlp {
        nf,
        h: hn,
        c,
        w1: (0..hn * nf).map(|_| ((rnd() % 10000) as f32 / 10000.0 - 0.5) * 0.4).collect(),
        b1: vec![0.0; hn],
        w2: (0..c * hn).map(|_| ((rnd() % 10000) as f32 / 10000.0 - 0.5) * 0.4).collect(),
        b2: vec![0.0; c],
        mu,
        sd,
    };
    let (mut h, mut p) = (vec![0f32; hn], vec![0f32; c]);
    let mut gh = vec![0f32; hn];
    for it in 0..steps {
        let lr = 0.03 * (1.0 - it as f32 / steps as f32) + 0.001;
        let (f, y) = data[(rnd() as usize) % data.len()];
        m.fwd(f, &mut h, &mut p);
        let x: Vec<f32> = (0..nf).map(|k| (f[k] - m.mu[k]) / m.sd[k]).collect();
        gh.iter_mut().for_each(|g| *g = 0.0);
        for k in 0..c {
            let e = p[k] - if k == y as usize { 1.0 } else { 0.0 };
            for j in 0..hn {
                gh[j] += e * m.w2[k * hn + j];
                m.w2[k * hn + j] -= lr * e * h[j];
            }
            m.b2[k] -= lr * e;
        }
        for j in 0..hn {
            let g = gh[j] * (1.0 - h[j] * h[j]);
            m.b1[j] -= lr * g;
            for k in 0..nf {
                m.w1[j * nf + k] -= lr * g * x[k];
            }
        }
    }
    m
}

/// The classes kept: the likeliest until all but eps of the probability is (k_ml.h's rule).
fn keep_classes(p: &[f32], eps: f32) -> u32 {
    let mut idx: Vec<usize> = (0..p.len()).collect();
    idx.sort_by(|&a, &b| p[b].partial_cmp(&p[a]).unwrap());
    let (mut m, mut cum) = (0u32, 0f32);
    for &i in &idx {
        m |= 1 << i;
        cum += p[i];
        if cum >= 1.0 - eps {
            break;
        }
    }
    m
}

/// The level model's joint DP: (added cost, total cost, stage cost skipped / total) for one
/// picture's kept levels, after k_ml_tree's repair.
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
            let child = |lv: usize, t: usize, q: usize| {
                let per = 1 << lv;
                lvb[lv + 1] + ((t / per) * 2 + q / 2) * per * 2 + (t % per) * 2 + q % 2
            };
            for lv in (0..4).rev() {
                for t in 0..(1 << lv) * (1 << lv) {
                    let i = lvb[lv] + t;
                    feas[i] = own[i] || (lv < 3 && (0..4).all(|q| feas[child(lv, t, q)]));
                }
            }
            for lv in 0..3 {
                for t in 0..(1 << lv) * (1 << lv) {
                    if !below[lvb[lv] + t] {
                        continue;
                    }
                    for q in 0..4 {
                        let ci = child(lv, t, q);
                        if !feas[ci] {
                            own[ci] = true;
                            feas[ci] = true;
                        }
                    }
                }
            }
            let mut bo = [0f32; 85];
            let mut bn = [0f32; 85];
            for lv in (0..4).rev() {
                let per = 1 << lv;
                for t in 0..per * per {
                    let i = lvb[lv] + t;
                    bo[i] = c[2 * i].min(c[2 * i + 1]);
                    if !own[i] {
                        skipped += LEVEL_MS[3 - lv] / (per * per) as f64 / nsb as f64;
                    }
                    if lv == 3 {
                        bn[i] = if own[i] { bo[i] } else { f32::INFINITY };
                        continue;
                    }
                    let d: f32 = (0..4).map(|q| bn[child(lv, t, q)] - bo[child(lv, t, q)]).sum();
                    bn[i] = (if own[i] { c[2 * i] } else { f32::INFINITY }).min(c[2 * i + 1] + d);
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

const EPSS: [f32; 6] = [0.002, 0.005, 0.01, 0.02, 0.05, 0.1];

fn report_level(m: &Mlp, pics: &[&Pic]) -> String {
    let (mut h, mut p) = (vec![0f32; m.h], vec![0f32; m.c]);
    let mut out = String::new();
    for &eps in &EPSS {
        let (mut add, mut tot, mut sk) = (0.0, 0.0, 0.0);
        for pic in pics {
            let mut keep = vec![0xFu8; (pic.w / 8) * (pic.h / 8)];
            for (cell, f, _) in &pic.cells {
                m.fwd(f, &mut h, &mut p);
                keep[*cell] = keep_classes(&p, eps) as u8;
            }
            let (a, t, s) = joint(pic, &keep);
            add += a;
            tot += t;
            sk += s / pics.len() as f64;
        }
        out += &format!(" eps {eps}: skip {:.0} % adds {:.2} % |", sk * 100., add / tot * 100.);
    }
    out
}

fn report_mode(m: &Mlp, pics: &[&Pic]) -> String {
    let (mut h, mut p) = (vec![0f32; m.h], vec![0f32; m.c]);
    let mut out = String::new();
    for &eps in &EPSS {
        let (mut kept, mut n, mut miss, mut nl) = (0f64, 0f64, 0f64, 0f64);
        for pic in pics {
            for (f, _) in &pic.nodes {
                m.fwd(f, &mut h, &mut p);
                kept += keep_classes(&p, eps).count_ones() as f64;
                n += 1.0;
            }
            for (f, mode) in &pic.leaves {
                m.fwd(f, &mut h, &mut p);
                if keep_classes(&p, eps) >> mode & 1 == 0 {
                    miss += 1.0;
                }
                nl += 1.0;
            }
        }
        out += &format!(" eps {eps}: {:.1} modes, leaves missed {:.1} % |", kept / n.max(1.0), miss / nl.max(1.0) * 100.);
    }
    out
}

fn main() {
    let dir = std::env::args().nth(1).expect("usage: prune_train <dumps> (see the file comment)");
    let env = |k: &str, d: usize| std::env::var(k).map_or(d, |v| v.parse().unwrap());
    let sub = env("SUB", 1);
    let steps = env("STEPS", 1_500_000);
    let model = std::env::var("MODEL").unwrap_or_default();
    let (traces, pics) = load(&dir, if std::env::var("EXPORT").is_ok() { sub } else { 1 });
    let level_data = |keep: &dyn Fn(&Pic) -> bool| -> Vec<(&[f32], u8)> {
        pics.iter()
            .filter(|p| keep(p))
            .flat_map(|p| {
                p.cells.iter().enumerate().filter(|(i, _)| i % sub.max(1) == 0).map(|(_, c)| (c.1.as_slice(), c.2))
            })
            .collect()
    };
    let mode_data = |keep: &dyn Fn(&Pic) -> bool| -> Vec<(&[f32], u8)> {
        pics.iter().filter(|p| keep(p)).flat_map(|p| p.nodes.iter().map(|n| (n.0.as_slice(), n.1))).collect()
    };
    if let Ok(wf) = std::env::var("EVAL") {
        let v: Vec<f32> = fs::read(&wf).unwrap().chunks(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())).collect();
        let level = Mlp::from_floats(&v, LEVEL_NF, LEVEL_H, 4);
        let all: Vec<&Pic> = pics.iter().collect();
        println!("level:{}", report_level(&level, &all));
        let nl = level.floats().len();
        if v.len() > nl {
            let mode = Mlp::from_floats(&v[nl..], MODE_NF, MODE_H, MODES);
            println!("mode:{}", report_mode(&mode, &all));
        }
        return;
    }
    if let Ok(out) = std::env::var("EXPORT") {
        // the data is subsampled at load (SUB) here, so every sample counts
        let level_all: Vec<(&[f32], u8)> = pics.iter().flat_map(|p| p.cells.iter().map(|c| (c.1.as_slice(), c.2))).collect();
        let level = train(&level_all, LEVEL_NF, LEVEL_H, 4, steps, 5);
        let mode_all = mode_data(&|_| true);
        let mode = train(&mode_all, MODE_NF, MODE_H, MODES, steps, 7);
        let (lv, mv) = (level.floats(), mode.floats());
        if out.ends_with(".swift") {
            let array = |v: &[f32]| -> String {
                v.chunks(6).map(|row| format!("        {},\n", row.iter().map(|x| format!("{x:e}")).collect::<Vec<_>>().join(", "))).collect()
            };
            let t = format!(
                "// Generated by rust/av1/examples/prune_train.rs (EXPORT); BENCHMARKS \"learned pruning of the analysis\".\n\
                 // The learned pruning's weights, each model in Shaders/k_ml.h's order: means, deviations, first\n\
                 // layer, its biases, output layer, its biases.\n\n\
                 /// See `AV1MetalEncoder.learnedPrune`.\npublic enum AV1PrunerWeights {{\n\
                 \x20   /// The level model (ML_FLOATS): {} cells of {} pictures.\n    public static let cellV1: [Float] = [\n{}    ]\n\
                 \x20   /// The mode model (ML_MODE_FLOATS): {} blocks of {} pictures.\n    public static let modeV1: [Float] = [\n{}    ]\n}}\n",
                level_all.len(),
                pics.len(),
                array(&lv),
                mode_all.len(),
                pics.len(),
                array(&mv)
            );
            fs::write(&out, t).unwrap();
        } else {
            fs::write(&out, lv.iter().chain(&mv).flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>()).unwrap();
        }
        println!("{} + {} floats written to {out} ({} cells, {} blocks)", lv.len(), mv.len(), level_all.len(), mode_all.len());
        return;
    }
    for t in 0..traces.len() {
        let test: Vec<&Pic> = pics.iter().filter(|p| p.trace == t).collect();
        if model.is_empty() || model == "level" {
            let m = train(&level_data(&|p| p.trace != t), LEVEL_NF, LEVEL_H, 4, steps, 5 + t as u64);
            println!("{} level:{}", traces[t], report_level(&m, &test));
        }
        if model.is_empty() || model == "mode" {
            let data = mode_data(&|p| p.trace != t);
            let sampled: Vec<(&[f32], u8)> = data.iter().enumerate().filter(|(i, _)| i % sub.max(1) == 0).map(|(_, d)| *d).collect();
            let m = train(&sampled, MODE_NF, MODE_H, MODES, steps, 7 + t as u64);
            println!("{} mode: {} blocks trained on |{}", traces[t], sampled.len(), report_mode(&m, &test));
        }
    }
}
