//! Trains the Metal encoder's learned pruning (Sources/GlassActAV1/Shaders/k_ml.h; BENCHMARKS
//! "learned pruning of the analysis"). Two models:
//! - level: per 8x8 cell, which tree level (8/16/32/64) the full search chooses, from statistics
//!   of the cell's four nested nodes;
//! - mode: per tree node, which luma modes its own blocks choose, from the node's statistics and
//!   its gradients' orientations;
//! - chroma: per leaf, which of the 7 chroma modes k_leaf screens, and CfL, it chooses, from its
//!   chroma's statistics, how much each plane follows luma, its size and its luma mode;
//! - tx: per luma tx block of the CPU closed loop, which tx type its search chooses, from its
//!   residual's statistics (rust/av1/src/hybrid/tx_model.rs), on samples the closed loop records
//!   with GA_TX_SAMPLES naming a file: TXDIR=<dir of .txs files> MODEL=tx (EXPORT_TX=<.rs>
//!   writes src/hybrid/tx_weights.rs).
//!
//! Data: pictures dumped by `glassact-bench av1seq --dump-partition <dir>/<trace>-<anything>`, one
//! directory each (the trace id before the first '-'; `scripts/train-pruner` makes them from
//! `scripts/pruner-traces.txt`): the "GAML" sections PICT (luma), CHRO (chroma), LEAF (the full
//! search's leaves, with k_leaf's chroma), NODE (the partition DP's node costs) and MODE (each
//! analyzed block's best mode).
//!
//! cargo run --release --example prune_train -- <dumps>
//!     each trace scored by models trained on the others: for the level model, the analysis
//!     skipped and the cost the skips add, all at once (the DP over the GPU's node costs, with
//!     k_ml_tree's repair); for the mode model, the modes screened and how many chosen leaves'
//!     modes they miss; for the chroma model, likewise. MODEL=level, mode or chroma for one.
//! SUB=3 STEPS=3000000 EXPORT=<file.swift> cargo run --release --example prune_train -- <dumps>
//!     train all three on everything and write Sources/GlassActAV1/AV1PrunerWeights.swift (any
//!     other name: the level model's raw f32s, then the mode model's, then the chroma model's)
//! EVAL=<raw weights> cargo run --release --example prune_train -- <dumps>
//!     score raw weights (as EXPORT writes them) on the dumps
//! MODEL=nodes SUB=8 cargo run --release --example prune_train -- <dumps>
//!     an experiment: node-level rules for keeping the 32x32s' and 64x64s' shapes against k_ml_tree's
//!     any-cell rule, held out as above (see nodes_experiment)
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
/// CONTEXT=1 (an experiment the GPU doesn't run): the level model also gets the mean statistics of
/// its 8 and 16 nodes' 8 neighbours (2 PF more), the mode model its node's neighbours' mean
/// orientations (OB more).
fn context() -> bool {
    std::env::var("CONTEXT").is_ok_and(|v| v == "1")
}
fn level_nf() -> usize {
    LEVEL_NF + if context() { 2 * PF } else { 0 }
}
fn mode_nf() -> usize {
    MODE_NF + if context() { OB } else { 0 }
}
const MODE_H: usize = 24;
const MODES: usize = 13;
/// The chroma model: per plane (U, V) its log variance, gradients and squared correlation with luma;
/// the chroma block's log2 size; the luma mode's family (one-hot: DC, V, H, smooth, Paeth, another
/// angle); a bias. 8 classes: k_leaf's 7 plain modes (CHROMA_MODES' order), then CfL.
const CHROMA_NF: usize = 8 + 1 + 6 + 1;
const CHROMA_H: usize = 16;
const CHROMA_C: usize = 8;
/// k_leaf's plain chroma modes, in its order (DC, V, H, SMOOTH, SMOOTH_V, SMOOTH_H, PAETH).
const CHROMA_MODES: [u8; 7] = [0, 1, 2, 9, 10, 11, 12];

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
    /// chroma model samples: (a chroma-carrying leaf's features, its class)
    chroma: Vec<(Vec<f32>, u8)>,
}

/// The chroma model's features of a leaf whose chroma block is cw x ch at (cx, cy) (k_leaf's).
fn chroma_features(y: &[u8], w: usize, uv: [&[u8]; 2], cwp: usize, cx: usize, cy: usize, cw: usize, ch: usize, st2: f64, y_mode: u8) -> Vec<f32> {
    let luma = |i: usize, j: usize| {
        let (r, c) = ((cy + i) * 2, (cx + j) * 2);
        (y[r * w + c] as f64 + y[r * w + c + 1] as f64 + y[(r + 1) * w + c] as f64 + y[(r + 1) * w + c + 1] as f64) / 4.0
    };
    let n = (cw * ch) as f64;
    let (mut l1, mut l2) = (0f64, 0f64);
    for i in 0..ch {
        for j in 0..cw {
            let l = luma(i, j);
            l1 += l;
            l2 += l * l;
        }
    }
    let lvar = l2 / n - (l1 / n) * (l1 / n);
    let mut f = Vec::with_capacity(CHROMA_NF);
    for p in uv {
        let (mut s1, mut s2, mut sl, mut dx, mut dy) = (0f64, 0f64, 0f64, 0f64, 0f64);
        for i in 0..ch {
            for j in 0..cw {
                let v = p[(cy + i) * cwp + cx + j] as f64;
                s1 += v;
                s2 += v * v;
                sl += v * luma(i, j);
                if j + 1 < cw {
                    dx += (p[(cy + i) * cwp + cx + j + 1] as f64 - v).abs();
                }
                if i + 1 < ch {
                    dy += (p[(cy + i + 1) * cwp + cx + j] as f64 - v).abs();
                }
            }
        }
        let var = s2 / n - (s1 / n) * (s1 / n);
        let cov = sl / n - (s1 / n) * (l1 / n);
        let corr2 = if var * lvar > 1e-6 { (cov * cov / (var * lvar)).min(1.0) } else { 0.0 };
        let (dx, dy) = (dx / (n - ch as f64).max(1.0), dy / (n - cw as f64).max(1.0));
        f.push((1.0 + var.max(0.0) / st2).ln() as f32);
        f.push((1.0 + dx * dx / st2).ln() as f32);
        f.push((1.0 + dy * dy / st2).ln() as f32);
        f.push(corr2 as f32);
    }
    f.push(((cw * ch) as f32).log2() / 10.0);
    let family = match y_mode {
        0 => 0,
        1 => 1,
        2 => 2,
        9..=11 => 3,
        12 => 4,
        _ => 5,
    };
    for k in 0..6 {
        f.push((k == family) as u8 as f32);
    }
    f.push(1.0);
    f
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

/// Threads for loading and scoring (THREADS, default 4: the Mac is shared).
fn threads() -> usize {
    std::env::var("THREADS").map_or(4, |v| v.parse().unwrap()).max(1)
}

fn load(dir: &str, sub: usize) -> (Vec<String>, Vec<Pic>) {
    let mut traces: Vec<String> = vec![];
    let mut entries: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect();
    entries.sort();
    let mut work = vec![];
    // PICK=k: every k-th picture only (quick experiments)
    let pick = std::env::var("PICK").map_or(1, |v| v.parse::<usize>().unwrap()).max(1);
    for e in entries.into_iter().step_by(pick) {
        let name = e.file_name().unwrap().to_string_lossy().to_string();
        let tr = name.split('-').next().unwrap().to_string();
        if !traces.contains(&tr) {
            traces.push(tr.clone());
        }
        work.push((e, traces.iter().position(|t| *t == tr).unwrap()));
    }
    // pictures in parallel (MODEL=nodes needs only the level model's cells and the node costs)
    let lite = std::env::var("MODEL").is_ok_and(|m| m == "nodes");
    let next = std::sync::atomic::AtomicUsize::new(0);
    let mut pics: Vec<Option<Pic>> = (0..work.len()).map(|_| None).collect();
    let slots = std::sync::Mutex::new(&mut pics);
    std::thread::scope(|s| {
        for _ in 0..threads() {
            s.spawn(|| {
                loop {
                    let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    if i >= work.len() {
                        break;
                    }
                    let p = load_pic(&work[i].0, work[i].1, sub, lite);
                    slots.lock().unwrap()[i] = Some(p);
                }
            });
        }
    });
    (traces, pics.into_iter().map(|p| p.unwrap()).collect())
}

fn load_pic(e: &std::path::Path, ti: usize, sub: usize, lite: bool) -> Pic {
    {
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
        let mut chroma = vec![];
        let cwp = w.div_ceil(2);
        let chro = s.get("CHRO").map(|c| [&c[..cwp * h.div_ceil(2)], &c[cwp * h.div_ceil(2)..]]);
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
            // a leaf with chroma (sub-8x8: the 8x8's last), k_leaf's chroma block
            let has_chroma = (bw > 4 || mi_col & 1 == 1) && (bh > 4 || mi_row & 1 == 1);
            if let Some(uv) = chro
                && !lite
                && has_chroma
                && (sub <= 1 || (mi_row * 7 + mi_col * 13) % sub == 0)
            {
                let (cx, cy) = ((mi_col >> 1) * 4, (mi_row >> 1) * 4);
                let (cw, ch) = ((bw / 2).clamp(4, 32), (bh / 2).clamp(4, 32));
                let class = if r[9] == 13 { Some(7) } else { CHROMA_MODES.iter().position(|&m| m == r[9]) };
                if let Some(class) = class
                    && (cy + ch) * 2 <= h
                    && (cx + cw) * 2 <= w
                {
                    let st = glassact_av1::dsp::ac_q(q as i32) as f64 / 8.0;
                    chroma.push((chroma_features(y, w, uv, cwp, cx, cy, cw, ch, st * st, r[7]), class as u8));
                }
            }
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
                    if lite { vec![] } else { (0..k).map(|k| hog(y, w, (k % cols) * n, (k / cols) * n, n)).collect() },
                )
            })
            .collect();
        // the mean of a grid's 8 neighbours of (nx, ny) (those inside it)
        let neighbours = |v: &dyn Fn(usize) -> Vec<f32>, cols: usize, rows: usize, nx: usize, ny: usize, k: usize| -> Vec<f32> {
            let mut m = vec![0f32; k];
            let mut c = 0f32;
            for dy in -1i32..=1 {
                for dx in -1i32..=1 {
                    let (x, y) = (nx as i32 + dx, ny as i32 + dy);
                    if (dx, dy) == (0, 0) || x < 0 || y < 0 || x >= cols as i32 || y >= rows as i32 {
                        continue;
                    }
                    for (a, b) in m.iter_mut().zip(v(y as usize * cols + x as usize)) {
                        *a += b;
                    }
                    c += 1.0;
                }
            }
            m.iter().map(|a| a / c.max(1.0)).collect()
        };
        let node_features = |li: usize, nx: usize, ny: usize| -> Vec<f32> {
            let (cols, g, o) = &grids[li];
            let mut f = Vec::with_capacity(mode_nf());
            f.extend_from_slice(&g[ny * cols + nx]);
            f.extend_from_slice(&o[ny * cols + nx]);
            if context() {
                let rows = h / (8 << li);
                f.extend(neighbours(&|i| o[i].to_vec(), *cols, rows, nx, ny, OB));
            }
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
                let mut f = vec![0f32; level_nf()];
                for (li, n) in [8usize, 16, 32, 64].iter().enumerate() {
                    let (cols, g, _) = &grids[li];
                    f[li * PF..li * PF + PF].copy_from_slice(&g[(cy * 8 / n) * cols + cx * 8 / n]);
                }
                if context() {
                    for li in 0..2 {
                        let (cols, g, _) = &grids[li];
                        let n = 8 << li;
                        let m = neighbours(&|i| g[i].to_vec(), *cols, h / n, cx * 8 / n, cy * 8 / n, PF);
                        f[4 * PF + li * PF..4 * PF + li * PF + PF].copy_from_slice(&m);
                    }
                }
                let nf = level_nf();
                f[nf - 1] = 1.0;
                cells.push((cy * (w / 8) + cx, f, lvl[(cy * 2) * mc + cx * 2]));
            }
        }
        // the mode model: every analyzed block of a whole node's own shapes, its best mode
        let mut nodes = vec![];
        if let Some(md) = s.get("MODE").filter(|_| !lite) {
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
                !lite && x + n <= (w / n) * n && y0 + n <= (h / n) * n
            })
            .map(|&(x, y0, li, m)| (node_features(li, x / (8 << li), y0 / (8 << li)), m))
            .collect();
        Pic { trace: ti, w, h, sbc, costs, cells, nodes, leaves, chroma }
    }
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
    train_by(data, None, nf, hn, c, steps, seed)
}

/// `train`, with each step's sample drawn in proportion to its weight when `weights` are given.
fn train_by(data: &[(&[f32], u8)], weights: Option<&[f64]>, nf: usize, hn: usize, c: usize, steps: usize, seed: u64) -> Mlp {
    let cum: Option<Vec<f64>> = weights.map(|w| {
        w.iter()
            .scan(0f64, |a, &x| {
                *a += x;
                Some(*a)
            })
            .collect()
    });
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
        let pick = match &cum {
            None => (rnd() as usize) % data.len(),
            Some(cw) => {
                let u = (rnd() >> 11) as f64 / (1u64 << 53) as f64 * cw[cw.len() - 1];
                cw.partition_point(|&x| x <= u).min(cw.len() - 1)
            }
        };
        let (f, y) = data[pick];
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

fn report_chroma(m: &Mlp, pics: &[&Pic]) -> String {
    let (mut h, mut p) = (vec![0f32; m.h], vec![0f32; m.c]);
    let mut out = String::new();
    for &eps in &EPSS {
        let (mut kept, mut cfl, mut miss, mut n) = (0f64, 0f64, 0f64, 0f64);
        for pic in pics {
            for (f, class) in &pic.chroma {
                m.fwd(f, &mut h, &mut p);
                let k = keep_classes(&p, eps);
                kept += (k & 0x7F).count_ones() as f64;
                cfl += (k >> 7 & 1) as f64;
                if k >> class & 1 == 0 {
                    miss += 1.0;
                }
                n += 1.0;
            }
        }
        out += &format!(
            " eps {eps}: {:.1} modes, CfL {:.0} %, leaves missed {:.1} % |",
            kept / n.max(1.0),
            cfl / n.max(1.0) * 100.,
            miss / n.max(1.0) * 100.
        );
    }
    out
}

/// The tx model's features' count, hidden units and types (src/hybrid/tx_model.rs).
const TX_NF: usize = 15;
const TX_H: usize = 16;
const TX_C: usize = 16;

/// The tx samples of a directory of .txs files (the trace before the first '-'): per trace,
/// (features, chosen type, allowed types).
fn load_tx(dir: &str) -> (Vec<String>, Vec<(usize, Vec<f32>, u8, u32)>) {
    use glassact_av1::dsp::{get_tx_set_inter, get_tx_set_intra, tx_type_in_set_inter, tx_type_in_set_intra};
    let mut traces: Vec<String> = vec![];
    let mut out = vec![];
    let mut entries: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect();
    entries.sort();
    let sub = std::env::var("SUB").map_or(1, |v| v.parse::<usize>().unwrap()).max(1);
    for e in entries.iter().filter(|e| e.extension().is_some_and(|x| x == "txs")) {
        let name = e.file_name().unwrap().to_string_lossy().to_string();
        let tr = name.split('-').next().unwrap().to_string();
        if !traces.contains(&tr) {
            traces.push(tr.clone());
        }
        let ti = traces.iter().position(|t| *t == tr).unwrap();
        let d = fs::read(e).unwrap();
        for (k, r) in d.chunks(64).enumerate() {
            if r.len() < 64 || k % sub != 0 {
                continue;
            }
            let f: Vec<f32> = (0..TX_NF).map(|i| f32::from_le_bytes(r[4 * i..4 * i + 4].try_into().unwrap())).collect();
            let (chosen, tx_sz, inter) = (r[60], r[61] as i32, r[62] != 0);
            let mut allowed = 0u32;
            for t in 0..16 {
                let ok = if inter {
                    tx_type_in_set_inter(get_tx_set_inter(tx_sz, false), t)
                } else {
                    tx_type_in_set_intra(get_tx_set_intra(tx_sz, false), t)
                };
                if ok {
                    allowed |= 1 << t;
                }
            }
            out.push((ti, f, chosen, allowed));
        }
    }
    (traces, out)
}

/// The tx model's types kept, as src/hybrid/tx_model.rs keep(): the allowed types' renormalized
/// probabilities, the likeliest until all but eps, and DCT_DCT.
fn keep_tx(m: &Mlp, f: &[f32], allowed: u32, eps: f32, h: &mut [f32], p: &mut [f32]) -> u32 {
    m.fwd(f, h, p);
    let sum: f32 = (0..TX_C).filter(|&c| allowed >> c & 1 != 0).map(|c| p[c]).sum();
    // DCT_DCT always, and its probability with it
    let mut bits = 1u32;
    let mut kept = if allowed & 1 != 0 { p[0] } else { 0.0 };
    while kept < (1.0 - eps) * sum {
        let best = (0..TX_C).filter(|&c| allowed >> c & 1 != 0 && bits >> c & 1 == 0).max_by(|&a, &b| p[a].partial_cmp(&p[b]).unwrap());
        match best {
            Some(b) => {
                bits |= 1 << b;
                kept += p[b];
            }
            None => break,
        }
    }
    bits & allowed | 1
}

fn report_tx(m: &Mlp, data: &[&(usize, Vec<f32>, u8, u32)]) -> String {
    let (mut h, mut p) = (vec![0f32; TX_H], vec![0f32; TX_C]);
    let mut out = String::new();
    let allowed: f64 = data.iter().map(|d| d.3.count_ones() as f64).sum::<f64>() / data.len().max(1) as f64;
    out += &format!(" {:.1} types allowed |", allowed);
    for &eps in &EPSS {
        let (mut kept, mut miss) = (0f64, 0f64);
        for d in data {
            let k = keep_tx(m, &d.1, d.3, eps, &mut h, &mut p);
            kept += k.count_ones() as f64;
            if k >> d.2 & 1 == 0 {
                miss += 1.0;
            }
        }
        let n = data.len().max(1) as f64;
        out += &format!(" eps {eps}: {:.1} tried, missed {:.1} % |", kept / n, miss / n * 100.);
    }
    out
}

// MODEL=nodes (an offline experiment; the GPU runs none of it): whether the 32x32s and 64x64s keep
// their own shapes by a node-level decision instead of k_ml_tree's "any cell keeps the level".
// Every trace's cells get probabilities from the level model trained on the other traces (seeds as
// the level report's), the 8x8s and 16x16s keep the cells' rule at eps, and each 64x64 and 32x32 is
// kept by one of:
// - any: a cell keeps its level (today's rule);
// - mean / q50 / q75 / q90 / max: that statistic of its cells' probability of its level passes a
//   threshold (one for both levels, then a grid of one per level);
// - frac: a share of its cells keeps its level at eps;
// - net: a small network per node (one for the 64x64s, one for the 32x32s, the 64x64 decided first)
//   from its cells' probabilities, its keep bits and its statistics, trained on what skipping it
//   costs the SB's best J (the DP over the dumped node costs) against the analysis it saves;
// - oracle: per SB, the best of the 32 choices of its five large nodes for a trade of J for time
//   (a bound for any node-level rule given the small levels).
// A large node a cell keeps but the rule drops must split, as k_ml_tree's repair makes a node a cell
// below needs (its children without a partition of their own keep theirs).
// Reported: per level the share of nodes skipped as ms of LEVEL_MS (a 5K picture), totals over all
// pictures (each picture weighted alike, as joint()) and over the 5K ones; the J the skips add,
// pooled. ΔJ is the open-loop RD cost of the analysis's DP, a proxy for bytes.
// NODE_STEPS (default STEPS), NODE_H (12), NODE_KMUL (1: the weight of J against time, the classes'
// totals balanced), NODE_W (the weight of a node whose skip costs J: cap, its J capped at its SB's;
// raw; log; flat, every sample alike), NODE_FEAT=p (the cells' outputs only, not the node's
// statistics), NODE_EPS (0.02,0.05), NODE_ONLY (rules, net, oracle: some).

const LVB: [usize; 4] = [0, 1, 5, 21];
/// Nodes per SB at each level (8, 16, 32, 64).
const PER_SB: [f64; 4] = [64.0, 16.0, 4.0, 1.0];

fn child(lv: usize, t: usize, q: usize) -> usize {
    let per = 1 << lv;
    LVB[lv + 1] + ((t / per) * 2 + q / 2) * per * 2 + (t % per) * 2 + q % 2
}

/// An SB's nodes (by depth, as joint()) whose own level a cell keeps, and those where a cell keeps a
/// level below theirs.
fn sb_flags(pic: &Pic, keep: &[u8], sbx: usize, sby: usize) -> ([bool; 85], [bool; 85]) {
    let cols8 = pic.w / 8;
    let (mut own, mut below) = ([false; 85], [false; 85]);
    for lv in 0..4 {
        let (per, n, level) = (1 << lv, 64 >> lv, 3 - lv);
        for t in 0..per * per {
            let (x0, y0) = (sbx * 64 + (t % per) * n, sby * 64 + (t / per) * n);
            for cy in y0 / 8..(y0 + n) / 8 {
                for cx in x0 / 8..(x0 + n) / 8 {
                    let b = keep[cy * cols8 + cx];
                    own[LVB[lv] + t] |= b >> level & 1 != 0;
                    below[LVB[lv] + t] |= b & ((1 << level) - 1) != 0;
                }
            }
        }
    }
    (own, below)
}

/// k_ml_tree's repair of `own`, then the DP: (the best J with the shapes kept, with all of them).
fn sb_dp(c: &[f32], own: &mut [bool; 85], below: &[bool; 85]) -> (f32, f32) {
    let mut feas = [false; 85];
    for lv in (0..4).rev() {
        for t in 0..(1 << lv) * (1 << lv) {
            let i = LVB[lv] + t;
            feas[i] = own[i] || (lv < 3 && (0..4).all(|q| feas[child(lv, t, q)]));
        }
    }
    for lv in 0..3 {
        for t in 0..(1 << lv) * (1 << lv) {
            if !below[LVB[lv] + t] {
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
    let (mut bo, mut bn) = ([0f32; 85], [0f32; 85]);
    for lv in (0..4).rev() {
        for t in 0..(1 << lv) * (1 << lv) {
            let i = LVB[lv] + t;
            bo[i] = c[2 * i].min(c[2 * i + 1]);
            if lv == 3 {
                bn[i] = if own[i] { bo[i] } else { f32::INFINITY };
                continue;
            }
            let d: f32 = (0..4).map(|q| bn[child(lv, t, q)] - bo[child(lv, t, q)]).sum();
            bn[i] = (if own[i] { c[2 * i] } else { f32::INFINITY }).min(c[2 * i + 1] + d);
        }
    }
    (bn[0], bo[0])
}

/// An SB with the large nodes `d` decides (bit i: node i kept; 0 the 64x64, 1..5 the 32x32s), or as
/// its cells say: (J added / λ, J / λ, nodes skipped per level 8..64).
fn sb_eval(c: &[f32], own: &[bool; 85], below: &[bool; 85], d: Option<u8>) -> (f64, f64, [u8; 4]) {
    let (mut own, mut below) = (*own, *below);
    if let Some(d) = d {
        for i in 0..5 {
            let k = d >> i & 1 != 0;
            if own[i] && !k {
                below[i] = true;
            }
            own[i] = k;
        }
    }
    let lam = c[170].max(1e-6) as f64;
    let (bn, bo) = sb_dp(c, &mut own, &below);
    let mut cnt = [0u8; 4];
    for lv in 0..4 {
        for t in 0..(1 << lv) * (1 << lv) {
            cnt[3 - lv] += !own[LVB[lv] + t] as u8;
        }
    }
    if !bo.is_finite() {
        return (0.0, 0.0, cnt);
    }
    (((bn - bo) as f64 / lam).min(1e7), bo as f64 / lam, cnt)
}

#[derive(Clone, Copy, Default)]
struct Score {
    added: f64,
    total: f64,
    /// the J added with each SB's capped at its own J, and the SBs whose J the skips more than double
    capped: f64,
    blowups: f64,
    /// per level (8..64): the sum over pictures of the share of its nodes skipped
    skip: [f64; 4],
    pics: f64,
}
impl Score {
    fn add(&mut self, o: &Score) {
        self.added += o.added;
        self.total += o.total;
        self.capped += o.capped;
        self.blowups += o.blowups;
        for l in 0..4 {
            self.skip[l] += o.skip[l];
        }
        self.pics += o.pics;
    }
    fn dj(&self) -> f64 {
        self.added / self.total.max(1e-9) * 100.0
    }
    fn dj_capped(&self) -> f64 {
        self.capped / self.total.max(1e-9) * 100.0
    }
    fn ms(&self, l: usize) -> f64 {
        LEVEL_MS[l] * self.skip[l] / self.pics.max(1.0)
    }
    fn ms_total(&self) -> f64 {
        (0..4).map(|l| self.ms(l)).sum()
    }
}

/// Runs `f` on 0..n over threads(), in order.
fn par_map<T: Send>(n: usize, f: &(dyn Fn(usize) -> T + Sync)) -> Vec<T> {
    let next = std::sync::atomic::AtomicUsize::new(0);
    let out: std::sync::Mutex<Vec<Option<T>>> = std::sync::Mutex::new((0..n).map(|_| None).collect());
    std::thread::scope(|s| {
        for _ in 0..threads().min(n.max(1)) {
            s.spawn(|| {
                loop {
                    let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    if i >= n {
                        break;
                    }
                    let v = f(i);
                    out.lock().unwrap()[i] = Some(v);
                }
            });
        }
    });
    out.into_inner().unwrap().into_iter().map(|v| v.unwrap()).collect()
}

/// The pictures' scores (all of them, the 5K ones) with the large nodes `decide` (picture, SB)
/// returns, or the cells' rule where it returns None.
fn score(pics: &[&Pic], keeps: &[Vec<u8>], decide: &(dyn Fn(usize, usize) -> Option<u8> + Sync)) -> (Score, Score) {
    score_with(pics, keeps, decide, false)
}

/// `score`; with `and_any`, a large node is kept only where the cells' rule keeps it too.
fn score_with(pics: &[&Pic], keeps: &[Vec<u8>], decide: &(dyn Fn(usize, usize) -> Option<u8> + Sync), and_any: bool) -> (Score, Score) {
    let per: Vec<Score> = par_map(pics.len(), &|pi| {
        let pic = pics[pi];
        let nsb = ((pic.w / 64) * (pic.h / 64)) as f64;
        let mut s = Score { pics: 1.0, ..Default::default() };
        let mut cnt = [0f64; 4];
        for sby in 0..pic.h / 64 {
            for sbx in 0..pic.w / 64 {
                let sb = sby * pic.sbc + sbx;
                let (own, below) = sb_flags(pic, &keeps[pi], sbx, sby);
                let own5 = (0..5).fold(0u8, |m, i| m | (own[i] as u8) << i);
                let d = decide(pi, sb).map(|d| if and_any { d & own5 } else { d });
                let (a, t, c) = sb_eval(&pic.costs[sb * 171..sb * 171 + 171], &own, &below, d);
                s.added += a;
                s.total += t;
                s.capped += a.min(t);
                s.blowups += (a > t) as u8 as f64;
                for l in 0..4 {
                    cnt[l] += c[l] as f64;
                }
            }
        }
        for l in 0..4 {
            s.skip[l] = cnt[l] / (PER_SB[l] * nsb);
        }
        s
    });
    let (mut all, mut big) = (Score::default(), Score::default());
    for (pi, s) in per.iter().enumerate() {
        all.add(s);
        if pics[pi].w >= 2560 {
            big.add(s);
        }
    }
    (all, big)
}

/// The best skipped ms at a ΔJ on a curve of (ΔJ, ms) points (its upper frontier, linear between
/// points; NaN below its first).
fn ms_at(points: &[(f64, f64)], dj: f64) -> f64 {
    let mut p = points.to_vec();
    p.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
    let mut f: Vec<(f64, f64)> = vec![];
    for q in p {
        if f.last().is_none_or(|l| q.1 > l.1) {
            f.push(q);
        }
    }
    let mut out = f64::NAN;
    for k in 0..f.len() {
        if f[k].0 <= dj {
            out = f[k].1;
            if k + 1 < f.len() && f[k + 1].0 > dj {
                let (a, b) = (f[k], f[k + 1]);
                out = a.1 + (b.1 - a.1) * (dj - a.0) / (b.0 - a.0);
            }
        }
    }
    out
}

/// The least ΔJ for a skipped ms on a curve of (ΔJ, ms) points (NaN past its last).
fn dj_at(points: &[(f64, f64)], ms: f64) -> f64 {
    let mut p = points.to_vec();
    p.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    // the frontier from the most skipped down: ΔJ falling
    let mut f: Vec<(f64, f64)> = vec![];
    for q in p {
        if f.last().is_none_or(|l| q.0 < l.0) {
            f.push(q);
        }
    }
    let mut out = f64::NAN;
    for k in 0..f.len() {
        if f[k].1 >= ms {
            out = f[k].0;
            if k + 1 < f.len() && f[k + 1].1 < ms {
                let (a, b) = (f[k + 1], f[k]);
                out = a.0 + (b.0 - a.0) * (ms - a.1) / (b.1 - a.1);
            }
        }
    }
    out
}

/// A large node's cells' positions in `pic.cells` (64 for the 64x64, 16 for a 32x32).
fn node_cells(pic: &Pic, sbx: usize, sby: usize, i: usize) -> Vec<usize> {
    let cw = (pic.w / 64) * 8;
    let (x0, y0, n) = if i == 0 { (0, 0, 8) } else { (((i - 1) % 2) * 4, ((i - 1) / 2) * 4, 4) };
    let mut v = Vec::with_capacity(n * n);
    for r in 0..n {
        for c in 0..n {
            v.push((sby * 8 + y0 + r) * cw + sbx * 8 + x0 + c);
        }
    }
    v
}

const AGGS: [&str; 6] = ["mean", "q50", "q75", "q90", "max", "min"];

/// A large node's statistics of its cells' probability of its level, in AGGS' order.
fn node_aggs(probs: &[[f32; 4]], cells: &[usize], l: usize) -> [f32; 6] {
    let mut v: Vec<f32> = cells.iter().map(|&c| probs[c][l]).collect();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let q = |f: f32| v[((v.len() - 1) as f32 * f).round() as usize];
    [v.iter().sum::<f32>() / v.len() as f32, q(0.5), q(0.75), q(0.9), v[v.len() - 1], v[0]]
}

/// The node network's features (NODE_NF64 or NODE_NF32 with the parent's).
fn node_features(pic: &Pic, probs: &[[f32; 4]], keep: &[u8], sbx: usize, sby: usize, i: usize, parent: Option<(bool, f32)>) -> Vec<f32> {
    let l = if i == 0 { 3 } else { 2 };
    let cells = node_cells(pic, sbx, sby, i);
    let n = cells.len() as f32;
    let mut f = Vec::with_capacity(21);
    for k in 0..4 {
        f.push(cells.iter().map(|&c| probs[c][k]).sum::<f32>() / n);
    }
    let a = node_aggs(probs, &cells, l);
    f.extend_from_slice(&[a[4], a[5], a[2]]);
    let cols8 = pic.w / 8;
    let cw = (pic.w / 64) * 8;
    let kb = |c: usize| keep[(c / cw) * cols8 + c % cw];
    f.push(cells.iter().filter(|&&c| kb(c) >> l & 1 != 0).count() as f32 / n);
    f.push(cells.iter().filter(|&&c| kb(c) & ((1 << l) - 1) != 0).count() as f32 / n);
    if std::env::var("NODE_FEAT").map_or(true, |v| v != "p") {
        f.extend_from_slice(&pic.cells[cells[0]].1[l * PF..l * PF + PF]);
    }
    if let Some((kept, p64)) = parent {
        f.push(kept as u8 as f32);
        f.push(p64);
    }
    f.push(1.0);
    f
}

fn nodes_experiment(traces: &[String], pics: &[Pic], sub: usize, steps: usize) {
    let env = |k: &str, d: usize| std::env::var(k).map_or(d, |v| v.parse().unwrap());
    let node_steps = env("NODE_STEPS", steps);
    let node_h = env("NODE_H", 12);
    let kmul: f64 = std::env::var("NODE_KMUL").map_or(1.0, |v| v.parse().unwrap());
    let wmode = std::env::var("NODE_W").unwrap_or_default();
    let only = std::env::var("NODE_ONLY").unwrap_or_default();
    let run = |what: &str| only.is_empty() || only.split(',').any(|o| o == what);
    let epss: Vec<f32> =
        std::env::var("NODE_EPS").map_or(vec![0.02, 0.05], |v| v.split(',').map(|x| x.parse().unwrap()).collect());
    for p in pics {
        assert_eq!(p.cells.len(), (p.w / 64) * 8 * (p.h / 64) * 8, "MODEL=nodes needs every cell (no SUB at load)");
    }
    let pics: Vec<&Pic> = pics.iter().collect();
    // an SB's index among its picture's whole SBs
    let sbi = |pi: usize, sb: usize| {
        let p = pics[pi];
        (sb / p.sbc) * (p.w / 64) + sb % p.sbc
    };
    let t0 = std::time::Instant::now();
    // every picture's cells' probabilities from the level model trained on the other traces
    let models: Vec<Mlp> = par_map(traces.len(), &|t| {
        let data: Vec<(&[f32], u8)> = pics
            .iter()
            .filter(|p| p.trace != t)
            .flat_map(|p| p.cells.iter().enumerate().filter(|(i, _)| i % sub.max(1) == 0).map(|(_, c)| (c.1.as_slice(), c.2)))
            .collect();
        train(&data, level_nf(), LEVEL_H, 4, steps, 5 + t as u64)
    });
    let probs: Vec<Vec<[f32; 4]>> = par_map(pics.len(), &|pi| {
        let m = &models[pics[pi].trace];
        let (mut h, mut p) = (vec![0f32; m.h], vec![0f32; m.c]);
        pics[pi]
            .cells
            .iter()
            .map(|(_, f, _)| {
                m.fwd(f, &mut h, &mut p);
                [p[0], p[1], p[2], p[3]]
            })
            .collect()
    });
    eprintln!("nodes: level models trained and run, {:.0} s", t0.elapsed().as_secs_f64());
    let all = &pics;
    let keeps_at = |eps: f32| -> Vec<Vec<u8>> {
        par_map(pics.len(), &|pi| {
            let p = &pics[pi];
            let mut k = vec![0xFu8; (p.w / 8) * (p.h / 8)];
            for (ci, (cell, _, _)) in p.cells.iter().enumerate() {
                k[*cell] = keep_classes(&probs[pi][ci], eps) as u8;
            }
            k
        })
    };
    // the large nodes' statistics of their cells' probabilities, per picture and SB
    let aggs: Vec<Vec<[[f32; 6]; 5]>> = par_map(pics.len(), &|pi| {
        let p = &pics[pi];
        let mut v = vec![[[0f32; 6]; 5]; p.sbc * (p.h / 64)];
        for sby in 0..p.h / 64 {
            for sbx in 0..p.w / 64 {
                for i in 0..5 {
                    v[sby * p.sbc + sbx][i] = node_aggs(&probs[pi], &node_cells(p, sbx, sby, i), if i == 0 { 3 } else { 2 });
                }
            }
        }
        v
    });
    let row = |name: &str, thr: &str, s: &(Score, Score)| {
        let (a, b) = s;
        println!(
            "{name:7} {thr:>13} | 5K ms skipped 8 {:5.2} 16 {:5.2} 32 {:5.2} 64 {:5.2} = {:5.2} | dJ {:6.3} % capped {:6.3} % blowups {:3} | all: {:5.2} ms dJ {:6.3} % capped {:6.3} % | 32 {:5.2} 64 {:5.2}",
            b.ms(0),
            b.ms(1),
            b.ms(2),
            b.ms(3),
            b.ms_total(),
            b.dj(),
            b.dj_capped(),
            b.blowups,
            a.ms_total(),
            a.dj(),
            a.dj_capped(),
            a.ms(2),
            a.ms(3)
        );
    };
    // the current rule's curve, checked against joint()
    let mut any_pts: Vec<(f32, Score, Score)> = vec![];
    for &eps in &EPSS {
        let keeps = keeps_at(eps);
        let s = score(&all, &keeps, &|_, _| None);
        if eps == 0.02 {
            let (mut add, mut tot) = (0.0, 0.0);
            for (pi, p) in pics.iter().enumerate() {
                let (a, t, _) = joint(p, &keeps[pi]);
                add += a;
                tot += t;
            }
            assert!((add / tot * 100.0 - s.0.dj()).abs() < 1e-9, "the any rule differs from joint()");
        }
        if std::env::var("NODE_DEBUG").is_ok() {
            let mut top: Vec<(f64, usize, usize, f64)> = vec![];
            for (pi, p) in pics.iter().enumerate() {
                for sby in 0..p.h / 64 {
                    for sbx in 0..p.w / 64 {
                        let sb = sby * p.sbc + sbx;
                        let (own, below) = sb_flags(p, &keeps[pi], sbx, sby);
                        let (a, t, _) = sb_eval(&p.costs[sb * 171..sb * 171 + 171], &own, &below, None);
                        top.push((a, pi, sb, t));
                    }
                }
            }
            top.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
            let tot: f64 = top.iter().map(|t| t.3).sum();
            for t in &top[..8] {
                eprintln!("eps {eps}: pic {} ({}x{}) sb {}: added {:.1} ({:.4} % of all J), its J {:.1}", t.1, pics[t.1].w, pics[t.1].h, t.2, t.0, t.0 / tot * 100.0, t.3);
            }
        }
        row("any", &format!("eps {eps}"), &s);
        any_pts.push((eps, s.0, s.1));
    }
    let taus = [0.002f32, 0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5];
    let fracs = [1.0f32 / 64.0, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75];
    let pts = |v: &[(Score, Score)], big: bool| -> Vec<(f64, f64)> {
        v.iter().map(|(a, b)| if big { (b.dj(), b.ms_total()) } else { (a.dj(), a.ms_total()) }).collect()
    };
    let pts_capped = |v: &[(Score, Score)], big: bool| -> Vec<(f64, f64)> {
        v.iter().map(|(a, b)| if big { (b.dj_capped(), b.ms_total()) } else { (a.dj_capped(), a.ms_total()) }).collect()
    };
    // (family, eps) -> points
    let mut curves: Vec<(String, f32, Vec<(Score, Score)>)> = vec![];
    for &eps in &epss {
        let keeps = keeps_at(eps);
        let anchor = any_pts.iter().find(|p| p.0 == eps).map(|p| (p.1, p.2));
        println!("-- small levels at eps {eps}; the large nodes:");
        // 1: one threshold on a statistic of the cells' probabilities
        for (ai, an) in AGGS.iter().enumerate().filter(|_| run("rules")) {
            let mut v = vec![];
            for &tau in &taus {
                let s = score(&all, &keeps, &|pi, sb| {
                    let a = &aggs[pi][sb];
                    Some((0..5).fold(0u8, |m, i| m | ((a[i][ai] >= tau) as u8) << i))
                });
                row(an, &format!("{tau}"), &s);
                v.push(s);
            }
            curves.push((an.to_string(), eps, v));
            if ai == 0 || ai == 2 {
                let mut v = vec![];
                for &tau in &taus {
                    let s = score_with(
                        &all,
                        &keeps,
                        &|pi, sb| {
                            let a = &aggs[pi][sb];
                            Some((0..5).fold(0u8, |m, i| m | ((a[i][ai] >= tau) as u8) << i))
                        },
                        true,
                    );
                    row(&format!("{an}&any"), &format!("{tau}"), &s);
                    v.push(s);
                }
                curves.push((format!("{an}&any"), eps, v));
            }
        }
        // a share of the cells keeping the level at eps
        if run("rules") {
            let mut v = vec![];
            for &fr in &fracs {
                let s = score(&all, &keeps, &|pi, sb| {
                    let p = pics[pi];
                    let (sbx, sby) = (sb % p.sbc, sb / p.sbc);
                    Some((0..5).fold(0u8, |m, i| {
                        let l = if i == 0 { 3 } else { 2 };
                        let cells = node_cells(p, sbx, sby, i);
                        let n = cells.iter().filter(|&&c| keeps[pi][p.cells[c].0] >> l & 1 != 0).count();
                        m | ((n as f32 >= fr * cells.len() as f32 - 1e-6) as u8) << i
                    }))
                });
                row("frac", &format!("{fr:.3}"), &s);
                v.push(s);
            }
            curves.push(("frac".into(), eps, v));
        }
        // 2: a threshold per level (32x32, 64x64) for mean and q75
        for ai in [0usize, 2].into_iter().filter(|_| run("rules")) {
            let mut v = vec![];
            for &t32 in &taus {
                for &t64 in &taus {
                    let s = score(&all, &keeps, &|pi, sb| {
                        let a = &aggs[pi][sb];
                        Some((0..5).fold(0u8, |m, i| m | ((a[i][ai] >= if i == 0 { t64 } else { t32 }) as u8) << i))
                    });
                    v.push(s);
                }
            }
            // its frontier only
            let p = pts(&v, true);
            let mut order: Vec<usize> = (0..v.len()).collect();
            order.sort_by(|&a, &b| p[a].0.partial_cmp(&p[b].0).unwrap());
            let mut best = -1.0;
            for &k in &order {
                if p[k].1 > best {
                    best = p[k].1;
                    let (t32, t64) = (taus[k / taus.len()], taus[k % taus.len()]);
                    row(&format!("{}2", AGGS[ai]), &format!("{t32}/{t64}"), &v[k]);
                }
            }
            curves.push((format!("{}2", AGGS[ai]), eps, v));
        }
        // 3: the node networks, each trace scored by ones trained on the others
        if run("net") {
            // per picture and SB: the features of the 64x64, of each 32x32 with it kept and dropped,
            // and what dropping each costs (J / λ added, the SB's analysis saved, as shares)
            let wl: Vec<f64> = (0..4).map(|l| LEVEL_MS[l] / PER_SB[l] / LEVEL_MS.iter().sum::<f64>()).collect();
            struct NodeSet {
                f: Vec<Vec<f32>>,
                dj: Vec<f64>,
                saved: Vec<f64>,
                /// the SB's J (with every large node)
                j: Vec<f64>,
            }
            let sets: Vec<NodeSet> = par_map(pics.len(), &|pi| {
                let p = pics[pi];
                let mut s = NodeSet { f: vec![], dj: vec![], saved: vec![], j: vec![] };
                for sby in 0..p.h / 64 {
                    for sbx in 0..p.w / 64 {
                        let sb = sby * p.sbc + sbx;
                        let c = &p.costs[sb * 171..sb * 171 + 171];
                        let (own, below) = sb_flags(p, &keeps[pi], sbx, sby);
                        let ev = |d: u8| sb_eval(c, &own, &below, Some(d));
                        let sv = |a: &[u8; 4], b: &[u8; 4]| (0..4).map(|l| (b[l] as f64 - a[l] as f64) * wl[l]).sum::<f64>();
                        let base = ev(0x1F);
                        let no64 = ev(0x1E);
                        let p64 = aggs[pi][sb][0][0];
                        s.f.push(node_features(p, &probs[pi], &keeps[pi], sbx, sby, 0, None));
                        s.dj.push(no64.0 - base.0);
                        s.saved.push(sv(&base.2, &no64.2));
                        s.j.extend([base.1; 9]);
                        for i in 1..5 {
                            let k = ev(0x1F & !(1 << i));
                            s.f.push(node_features(p, &probs[pi], &keeps[pi], sbx, sby, i, Some((true, p64))));
                            s.dj.push(k.0 - base.0);
                            s.saved.push(sv(&base.2, &k.2));
                            let d = ev(0x1E & !(1 << i));
                            s.f.push(node_features(p, &probs[pi], &keeps[pi], sbx, sby, i, Some((false, p64))));
                            s.dj.push(d.0 - no64.0);
                            s.saved.push(sv(&no64.2, &d.2));
                        }
                    }
                }
                s
            });
            // per picture and SB: P(keep) of the 64x64, of each 32x32 with it kept, dropped
            let outs: Vec<Vec<[f32; 9]>> = {
                let nets: Vec<(Mlp, Mlp)> = par_map(traces.len(), &|t| {
                    let mut by = [(vec![], vec![]), (vec![], vec![])];
                    for (pi, s) in sets.iter().enumerate() {
                        if pics[pi].trace == t {
                            continue;
                        }
                        for (k, f) in s.f.iter().enumerate() {
                            let sbk = k / 9;
                            if sub > 1 && (sbk * 7 + pi * 13) % sub != 0 {
                                continue;
                            }
                            let m = (k % 9 != 0) as usize;
                            if s.dj[k] > 0.0 {
                                let (d, j) = (s.dj[k], s.j[k].max(1e-6));
                                by[m].0.push((f.as_slice(), 1u8));
                                by[m].1.push(match wmode.as_str() {
                                    "raw" => d,
                                    "log" => (1.0 + 100.0 * d / j).ln() * j / 100.0,
                                    "flat" => 1.0,
                                    _ => d.min(j),
                                });
                            }
                            if s.saved[k] > 0.0 {
                                by[m].0.push((f.as_slice(), 0u8));
                                by[m].1.push(if wmode == "flat" { 1.0 } else { s.saved[k] });
                            }
                        }
                    }
                    let mut nets = vec![];
                    for (m, (data, w)) in by.iter_mut().enumerate() {
                        // the classes' totals balanced, then NODE_KMUL more weight on J
                        let (wj, ws) = data.iter().zip(w.iter()).fold((0f64, 0f64), |a, (d, &x)| if d.1 == 1 { (a.0 + x, a.1) } else { (a.0, a.1 + x) });
                        let k = ws / wj.max(1e-12) * kmul;
                        for (d, x) in data.iter().zip(w.iter_mut()) {
                            if d.1 == 1 {
                                *x *= k;
                            }
                        }
                        let nf = data[0].0.len();
                        nets.push(train_by(data, Some(w.as_slice()), nf, node_h, 2, node_steps, 17 + 2 * t as u64 + m as u64));
                    }
                    let n32 = nets.pop().unwrap();
                    (nets.pop().unwrap(), n32)
                });
                par_map(pics.len(), &|pi| {
                    let (n64, n32) = &nets[pics[pi].trace];
                    let (mut h, mut p) = (vec![0f32; node_h], vec![0f32; 2]);
                    sets[pi]
                        .f
                        .chunks(9)
                        .map(|fs| {
                            let mut o = [0f32; 9];
                            for (k, f) in fs.iter().enumerate() {
                                if k == 0 { n64 } else { n32 }.fwd(f, &mut h, &mut p);
                                o[k] = p[1];
                            }
                            o
                        })
                        .collect()
                })
            };
            let ntaus = [0.001f32, 0.002, 0.005, 0.01, 0.02, 0.03, 0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8];
            let mut v = vec![];
            for &tau in &ntaus {
                let s = score(&all, &keeps, &|pi, sb| {
                    let o = &outs[pi][sbi(pi, sb)];
                    let k64 = o[0] >= tau;
                    Some((0..4).fold(k64 as u8, |m, i| m | ((o[1 + 2 * i + !k64 as usize] >= tau) as u8) << (i + 1)))
                });
                row("net", &format!("{tau}"), &s);
                v.push(s);
            }
            curves.push(("net".into(), eps, v.clone()));
            let mut va = vec![];
            for &tau in &ntaus {
                let s = score_with(
                    &all,
                    &keeps,
                    &|pi, sb| {
                        let o = &outs[pi][sbi(pi, sb)];
                        let k64 = o[0] >= tau;
                        Some((0..4).fold(k64 as u8, |m, i| m | ((o[1 + 2 * i + !k64 as usize] >= tau) as u8) << (i + 1)))
                    },
                    true,
                );
                row("net&any", &format!("{tau}"), &s);
                va.push(s);
            }
            curves.push(("net&any".into(), eps, va));
            let mut v2 = vec![];
            for &t32 in &ntaus {
                for &t64 in &ntaus {
                    v2.push(score(&all, &keeps, &|pi, sb| {
                        let o = &outs[pi][sbi(pi, sb)];
                        let k64 = o[0] >= t64;
                        Some((0..4).fold(k64 as u8, |m, i| m | ((o[1 + 2 * i + !k64 as usize] >= t32) as u8) << (i + 1)))
                    }));
                }
            }
            let p = pts(&v2, true);
            let mut order: Vec<usize> = (0..v2.len()).collect();
            order.sort_by(|&a, &b| p[a].0.partial_cmp(&p[b].0).unwrap());
            let mut best = -1.0;
            for &k in &order {
                if p[k].1 > best {
                    best = p[k].1;
                    row("net2", &format!("{}/{}", ntaus[k / ntaus.len()], ntaus[k % ntaus.len()]), &v2[k]);
                }
            }
            curves.push(("net2".into(), eps, v2));
        }
        // the oracle: per SB the best choice of its large nodes for J against time
        if run("oracle") {
            let tot: f64 = anchor.map_or(1.0, |a| a.0.total);
            let choices: Vec<Vec<[(f32, [u8; 4]); 32]>> = par_map(pics.len(), &|pi| {
                let p = pics[pi];
                let mut v = vec![];
                for sby in 0..p.h / 64 {
                    for sbx in 0..p.w / 64 {
                        let sb = sby * p.sbc + sbx;
                        let c = &p.costs[sb * 171..sb * 171 + 171];
                        let (own, below) = sb_flags(p, &keeps[pi], sbx, sby);
                        let mut a = [(0f32, [0u8; 4]); 32];
                        for (d, x) in a.iter_mut().enumerate() {
                            let (ad, _, cnt) = sb_eval(c, &own, &below, Some(d as u8));
                            *x = (ad as f32, cnt);
                        }
                        v.push(a);
                    }
                }
                v
            });
            let mut v = vec![];
            for lam in [0.3f64, 1.0, 3.0, 10.0, 30.0, 100.0, 300.0, 1000.0, 3000.0, 10000.0] {
                let s = score(&all, &keeps, &|pi, sb| {
                    let p = pics[pi];
                    let nsb = ((p.w / 64) * (p.h / 64)) as f64;
                    let a = &choices[pi][sbi(pi, sb)];
                    let cost = |x: &(f32, [u8; 4])| {
                        x.0 as f64 / tot * 100.0
                            - lam / 1000.0 * (0..4).map(|l| LEVEL_MS[l] * x.1[l] as f64 / PER_SB[l] / nsb).sum::<f64>() / pics.len() as f64
                    };
                    Some((0..32).min_by(|&x, &y| cost(&a[x]).partial_cmp(&cost(&a[y])).unwrap()).unwrap() as u8)
                });
                row("oracle", &format!("{lam}"), &s);
                v.push(s);
            }
            curves.push(("oracle".into(), eps, v));
        }
        // the comparison at the current rule's ΔJ and skipped ms at this eps
        if let Some((a, b)) = anchor {
            println!("-- against any at eps {eps}: 5K {:.2} ms dJ {:.3} %, all {:.2} ms dJ {:.3} %", b.ms_total(), b.dj(), a.ms_total(), a.dj());
            println!("   (capped: each SB's added J at most its own J)");
            for (name, _, v) in curves.iter().filter(|c| c.1 == eps) {
                let (pb, pa, cb, ca) = (pts(v, true), pts(v, false), pts_capped(v, true), pts_capped(v, false));
                println!(
                    "{name:7} 5K: at equal dJ {:+6.2} ms, at equal ms {:+7.3} % dJ; capped {:+6.2} ms, {:+7.3} % | all: {:+6.2} ms, {:+7.3} %; capped {:+6.2} ms, {:+7.3} %",
                    ms_at(&pb, b.dj()) - b.ms_total(),
                    dj_at(&pb, b.ms_total()) - b.dj(),
                    ms_at(&cb, b.dj_capped()) - b.ms_total(),
                    dj_at(&cb, b.ms_total()) - b.dj_capped(),
                    ms_at(&pa, a.dj()) - a.ms_total(),
                    dj_at(&pa, a.ms_total()) - a.dj(),
                    ms_at(&ca, a.dj_capped()) - a.ms_total(),
                    dj_at(&ca, a.ms_total()) - a.dj_capped()
                );
            }
        }
    }
    eprintln!("nodes: done, {:.0} s", t0.elapsed().as_secs_f64());
}

fn main() {
    let dir = std::env::args().nth(1).expect("usage: prune_train <dumps> (see the file comment)");
    if let Ok(txdir) = std::env::var("TXDIR") {
        let steps = std::env::var("STEPS").map_or(3_000_000usize, |v| v.parse().unwrap());
        let (traces, data) = load_tx(&txdir);
        if let Ok(out) = std::env::var("EXPORT_TX") {
            let all: Vec<(&[f32], u8)> = data.iter().map(|d| (d.1.as_slice(), d.2)).collect();
            let m = train(&all, TX_NF, TX_H, TX_C, steps, 13);
            let v = m.floats();
            let body: String = v
                .chunks(6)
                .map(|row| format!("    {},\n", row.iter().map(|x| format!("{x:e}")).collect::<Vec<_>>().join(", ")))
                .collect();
            fs::write(
                &out,
                format!(
                    "//! Generated by examples/prune_train.rs (MODEL=tx, EXPORT_TX): the closed loop's tx type model's\n\
                     //! weights ([`super::tx_model`]), from {} tx blocks.\n\
                     #[rustfmt::skip]\npub(crate) static TX_WEIGHTS: [f32; {}] = [\n{}];\n",
                    all.len(),
                    v.len(),
                    body
                ),
            )
            .unwrap();
            println!("{} floats written to {out} ({} tx blocks)", v.len(), all.len());
            return;
        }
        for t in 0..traces.len() {
            let train_set: Vec<(&[f32], u8)> = data.iter().filter(|d| d.0 != t).map(|d| (d.1.as_slice(), d.2)).collect();
            let test: Vec<&(usize, Vec<f32>, u8, u32)> = data.iter().filter(|d| d.0 == t).collect();
            let m = train(&train_set, TX_NF, TX_H, TX_C, steps, 13 + t as u64);
            println!("{} tx: {} blocks trained on |{}", traces[t], train_set.len(), report_tx(&m, &test));
        }
        return;
    }
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
        let level = Mlp::from_floats(&v, level_nf(), LEVEL_H, 4);
        let all: Vec<&Pic> = pics.iter().collect();
        println!("level:{}", report_level(&level, &all));
        let nl = level.floats().len();
        if v.len() > nl {
            let mode = Mlp::from_floats(&v[nl..], mode_nf(), MODE_H, MODES);
            println!("mode:{}", report_mode(&mode, &all));
            let nm = mode.floats().len();
            if v.len() > nl + nm {
                let chroma = Mlp::from_floats(&v[nl + nm..], CHROMA_NF, CHROMA_H, CHROMA_C);
                println!("chroma:{}", report_chroma(&chroma, &all));
            }
        }
        return;
    }
    if let Ok(out) = std::env::var("EXPORT") {
        assert!(!context(), "CONTEXT=1 is an offline experiment: the GPU's models have no context features");
        // the data is subsampled at load (SUB) here, so every sample counts
        let level_all: Vec<(&[f32], u8)> = pics.iter().flat_map(|p| p.cells.iter().map(|c| (c.1.as_slice(), c.2))).collect();
        let level = train(&level_all, level_nf(), LEVEL_H, 4, steps, 5);
        let mode_all = mode_data(&|_| true);
        let mode = train(&mode_all, mode_nf(), MODE_H, MODES, steps, 7);
        let chroma_all: Vec<(&[f32], u8)> = pics.iter().flat_map(|p| p.chroma.iter().map(|c| (c.0.as_slice(), c.1))).collect();
        let chroma = train(&chroma_all, CHROMA_NF, CHROMA_H, CHROMA_C, steps, 11);
        let (lv, mv, cv) = (level.floats(), mode.floats(), chroma.floats());
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
                 \x20   /// The mode model (ML_MODE_FLOATS): {} blocks of {} pictures.\n    public static let modeV1: [Float] = [\n{}    ]\n\
                 \x20   /// The chroma model (ML_CHROMA_FLOATS): {} leaves of {} pictures.\n    public static let chromaV1: [Float] = [\n{}    ]\n}}\n",
                level_all.len(),
                pics.len(),
                array(&lv),
                mode_all.len(),
                pics.len(),
                array(&mv),
                chroma_all.len(),
                pics.len(),
                array(&cv)
            );
            fs::write(&out, t).unwrap();
        } else {
            fs::write(&out, lv.iter().chain(&mv).chain(&cv).flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>()).unwrap();
        }
        println!(
            "{} + {} + {} floats written to {out} ({} cells, {} blocks, {} leaves)",
            lv.len(),
            mv.len(),
            cv.len(),
            level_all.len(),
            mode_all.len(),
            chroma_all.len()
        );
        return;
    }
    if model == "nodes" {
        nodes_experiment(&traces, &pics, sub, steps);
        return;
    }
    for t in 0..traces.len() {
        let test: Vec<&Pic> = pics.iter().filter(|p| p.trace == t).collect();
        if model.is_empty() || model == "level" {
            let m = train(&level_data(&|p| p.trace != t), level_nf(), LEVEL_H, 4, steps, 5 + t as u64);
            println!("{} level:{}", traces[t], report_level(&m, &test));
        }
        if model.is_empty() || model == "chroma" {
            let data: Vec<(&[f32], u8)> =
                pics.iter().filter(|p| p.trace != t).flat_map(|p| p.chroma.iter().map(|c| (c.0.as_slice(), c.1))).collect();
            let m = train(&data, CHROMA_NF, CHROMA_H, CHROMA_C, steps, 11 + t as u64);
            println!("{} chroma: {} leaves trained on |{}", traces[t], data.len(), report_chroma(&m, &test));
        }
        if model.is_empty() || model == "mode" {
            let data = mode_data(&|p| p.trace != t);
            let sampled: Vec<(&[f32], u8)> = data.iter().enumerate().filter(|(i, _)| i % sub.max(1) == 0).map(|(_, d)| *d).collect();
            let m = train(&sampled, mode_nf(), MODE_H, MODES, steps, 7 + t as u64);
            println!("{} mode: {} blocks trained on |{}", traces[t], sampled.len(), report_mode(&m, &test));
        }
    }
}
