//! The closed loop's learned luma tx type pruning (BENCHMARKS "learned pruning of the analysis"):
//! a small network on statistics of a tx block's residual rates the 16 tx types, and the search
//! tries only the likeliest of the block's set (and DCT_DCT always). Trained offline
//! (examples/prune_train.rs, MODEL=tx) on samples the closed loop records ([`record`], with
//! GA_TX_SAMPLES naming a file); the weights are [`super::tx_weights::TX_WEIGHTS`].

use crate::tables::TX_TYPES;

/// Features: the residual's energy share in 4 column bands and 4 row bands, its horizontal and
/// vertical neighbour correlation, its log energy against the quantizer step, the tx block's log2
/// width and height / 6, whether the block is inter, and a bias.
pub const TX_NF: usize = 15;
pub const TX_H: usize = 16;
pub const TX_C: usize = TX_TYPES as usize;
/// The weights' length: means, deviations, first layer, its biases, output layer, its biases.
pub const TX_FLOATS: usize = 2 * TX_NF + TX_H * TX_NF + TX_H + TX_C * TX_H + TX_C;
/// A recorded sample: the features, then the chosen type, the tx size and whether inter (one byte
/// each), padded to 64 bytes.
pub const TX_RECORD: usize = 64;
/// The smallest tx block (samples) the model chooses types for: every one, 4x4 too, now that tanh
/// and exp are approximated (with libm's, a 4x4's trials cost about what the model did, and only
/// 8x8 and up paid).
pub const MIN_SAMPLES: usize = 16;

/// The features of a tw x th residual (row-major).
pub fn features(res: &[f32], tw: usize, th: usize, ac_q: i32, inter: bool) -> [f32; TX_NF] {
    let mut f = [0f32; TX_NF];
    let (mut cols, mut rows) = ([0f32; 4], [0f32; 4]);
    let (mut e, mut hx, mut hl, mut hr, mut vx, mut vu, mut vd) = (0f32, 0f32, 0f32, 0f32, 0f32, 0f32, 0f32);
    for i in 0..th {
        let row = &res[i * tw..][..tw];
        for j in 0..tw {
            let v = row[j];
            let v2 = v * v;
            e += v2;
            cols[j * 4 / tw] += v2;
            rows[i * 4 / th] += v2;
            if j + 1 < tw {
                hx += v * row[j + 1];
                hl += v2;
                hr += row[j + 1] * row[j + 1];
            }
            if i + 1 < th {
                let d = res[(i + 1) * tw + j];
                vx += v * d;
                vu += v2;
                vd += d * d;
            }
        }
    }
    for k in 0..4 {
        f[k] = if e > 0.0 { cols[k] / e } else { 0.25 };
        f[4 + k] = if e > 0.0 { rows[k] / e } else { 0.25 };
    }
    f[8] = if hl * hr > 0.0 { hx / (hl * hr).sqrt() } else { 0.0 };
    f[9] = if vu * vd > 0.0 { vx / (vu * vd).sqrt() } else { 0.0 };
    let step = ac_q as f32 / 8.0;
    f[10] = (1.0 + e / ((tw * th) as f32 * step * step)).ln();
    f[11] = (tw as f32).log2() / 6.0;
    f[12] = (th as f32).log2() / 6.0;
    f[13] = inter as u8 as f32;
    f[14] = 1.0;
    f
}

/// The types (bit t: type t) to try: of those `allowed` keeps, the likeliest until all but `eps` of
/// their probability is kept, and DCT_DCT.
pub fn keep(weights: &[f32], f: &[f32; TX_NF], allowed: impl Fn(i32) -> bool, eps: f32) -> u32 {
    let (mu, rest) = weights.split_at(TX_NF);
    let (sd, rest) = rest.split_at(TX_NF);
    let (w1, rest) = rest.split_at(TX_H * TX_NF);
    let (b1, rest) = rest.split_at(TX_H);
    let (w2, b2) = rest.split_at(TX_C * TX_H);
    let mut x = [0f32; TX_NF];
    for k in 0..TX_NF {
        x[k] = (f[k] - mu[k]) / sd[k];
    }
    let mut h = [0f32; TX_H];
    for j in 0..TX_H {
        let mut a = b1[j];
        for k in 0..TX_NF {
            a += w1[j * TX_NF + k] * x[k];
        }
        h[j] = fast_tanh(a);
    }
    let mut p = [0f32; TX_C];
    let mut mx = f32::MIN;
    for c in 0..TX_C {
        if !allowed(c as i32) {
            p[c] = f32::MIN;
            continue;
        }
        let mut z = b2[c];
        for j in 0..TX_H {
            z += w2[c * TX_H + j] * h[j];
        }
        p[c] = z;
        mx = mx.max(z);
    }
    let mut sum = 0f32;
    for c in 0..TX_C {
        p[c] = if allowed(c as i32) { fast_exp(p[c] - mx) } else { 0.0 };
        sum += p[c];
    }
    // DCT_DCT always, and its probability with it
    let dct = crate::tables::DCT_DCT as usize;
    let mut bits = 1u32 << dct;
    let mut kept = p[dct];
    while kept < (1.0 - eps) * sum {
        let mut best = usize::MAX;
        for c in 0..TX_C {
            if p[c] > 0.0 && bits >> c & 1 == 0 && (best == usize::MAX || p[c] > p[best]) {
                best = c;
            }
        }
        if best == usize::MAX {
            break;
        }
        bits |= 1 << best;
        kept += p[best];
    }
    bits
}

/// tanh within ~2e-3 (a rational fit, clamped): ranking tx types doesn't need more, and libm's
/// costs about what the trials it saves do.
#[inline(always)]
fn fast_tanh(x: f32) -> f32 {
    let x = x.clamp(-4.97, 4.97);
    let x2 = x * x;
    x * (27.0 + x2) / (27.0 + 9.0 * x2)
}

/// exp(x) for x <= 0 within ~0.2 % (2^(x log2 e) from the float's bits, a cubic for the fraction).
#[inline(always)]
fn fast_exp(x: f32) -> f32 {
    let t = (x * std::f32::consts::LOG2_E).max(-126.0);
    let i = t.floor();
    let f = t - i;
    let p = 1.0 + f * (0.695_976_1 + f * (0.226_131_3 + f * 0.078_024_5));
    f32::from_bits(((i as i32 + 127) as u32) << 23) * p
}

/// A sample's bytes ([`TX_RECORD`]).
pub fn record(out: &mut Vec<u8>, f: &[f32; TX_NF], chosen: i32, tx_sz: i32, inter: bool) {
    let at = out.len();
    for v in f {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&[chosen as u8, tx_sz as u8, inter as u8]);
    out.resize(at + TX_RECORD, 0);
}
