//! Rate-distortion optimized quantization in the closed loop (libaom's greedy av1_optimize_txb, in
//! outline): after the dead-zone quantizer, each nonzero level is tried one lower, in reverse scan
//! order, with the writer's own coefficient contexts and costs from the frame's coefficient CDFs
//! (their defaults for the frame's quantizer: the closed loop's tx blocks are reconstructed apart
//! from their coding, so the tile's adapted CDFs aren't at hand); then the last coefficient is
//! dropped while that pays. Distortion is the transform domain's, scaled to samples per tx size.
//! The writer codes and reconstructs whatever levels come out, so the stream stays the decoder's.
//! The closed loop optimizes only tx blocks whose source has contrast (`QuantHook::rdoq_range`):
//! in flat gradients the levels it drops show as bands (BENCHMARKS "RDOQ in the closed loop").

use crate::dsp::{get_scan, tx_class};
use crate::entropy::Cdfs;
use crate::tables::*;

/// -log2(p) in bits for p = i / 4096 (the CDFs' 15-bit probabilities, 3 bits dropped).
fn bits_table() -> &'static [f32; 4097] {
    static T: std::sync::OnceLock<[f32; 4097]> = std::sync::OnceLock::new();
    T.get_or_init(|| {
        let mut t = [0f32; 4097];
        for (i, v) in t.iter_mut().enumerate() {
            *v = -((i.max(1) as f32) / 4096.0).log2();
        }
        t
    })
}

/// The cost in bits of symbol `s` of a spec-format CDF.
#[inline(always)]
fn sym_bits(cdf: &[u16], s: usize) -> f32 {
    let lo = if s == 0 { 0 } else { cdf[s - 1] as u32 };
    bits_table()[((cdf[s] as u32 - lo) >> 3) as usize]
}

/// The frame's coefficient costs, in bits.
pub(crate) struct CoeffCosts {
    /// [tx_sz_ctx][ptype][ctx][level 0..3]
    base: Vec<[f32; 4]>,
    /// [tx_sz_ctx][ptype][ctx][level 1..3]
    base_eob: Vec<[f32; 3]>,
    /// [brsz][ptype][ctx][k 0..3]
    br: Vec<[f32; 4]>,
    /// [tx_sz_ctx][ptype][pt - 3][bit]
    eob_extra: Vec<[f32; 2]>,
    /// [multisize][ptype][ectx][pt - 1]
    eob_pt: Vec<[f32; 11]>,
}

impl CoeffCosts {
    pub(crate) fn new(base_q_idx: i32) -> CoeffCosts {
        let c = Cdfs::new(base_q_idx);
        let mut base = Vec::with_capacity(5 * 2 * 42);
        let mut base_eob = Vec::with_capacity(5 * 2 * 4);
        let mut br = Vec::with_capacity(5 * 2 * 21);
        let mut eob_extra = Vec::with_capacity(5 * 2 * 9);
        for t in 0..5 {
            for p in 0..2 {
                for k in 0..42 {
                    base.push(core::array::from_fn(|s| sym_bits(&c.coeff_base[t][p][k], s)));
                }
                for k in 0..4 {
                    base_eob.push(core::array::from_fn(|s| sym_bits(&c.coeff_base_eob[t][p][k], s)));
                }
                for k in 0..21 {
                    br.push(core::array::from_fn(|s| sym_bits(&c.coeff_br[t][p][k], s)));
                }
                for k in 0..9 {
                    eob_extra.push(core::array::from_fn(|s| sym_bits(&c.eob_extra[t][p][k], s)));
                }
            }
        }
        let mut eob_pt = Vec::with_capacity(7 * 2 * 2);
        for m in 0..7 {
            for p in 0..2 {
                for e in 0..2 {
                    let mut v = [0f32; 11];
                    let n = 5 + m;
                    for (s, x) in v.iter_mut().enumerate().take(n) {
                        *x = match m {
                            0 => sym_bits(&c.eob_pt_16[p][e], s),
                            1 => sym_bits(&c.eob_pt_32[p][e], s),
                            2 => sym_bits(&c.eob_pt_64[p][e], s),
                            3 => sym_bits(&c.eob_pt_128[p][e], s),
                            4 => sym_bits(&c.eob_pt_256[p][e], s),
                            5 => sym_bits(&c.eob_pt_512[p], s),
                            _ => sym_bits(&c.eob_pt_1024[p], s),
                        };
                    }
                    eob_pt.push(v);
                }
            }
        }
        CoeffCosts { base, base_eob, br, eob_extra, eob_pt }
    }
}

/// Bits of the levels above 2 at a coefficient: the BR symbols and the Golomb remainder.
#[inline(always)]
fn high_bits(cc: &CoeffCosts, bri: usize, l: i32) -> f32 {
    if l <= NUM_BASE_LEVELS {
        return 0.0;
    }
    let mut b = 0f32;
    let mut rem = l - (NUM_BASE_LEVELS + 1);
    for _ in 0..COEFF_BASE_RANGE / (BR_CDF_SIZE - 1) {
        let k = rem.min(BR_CDF_SIZE - 1);
        b += cc.br[bri][k as usize];
        rem -= k;
        if k < BR_CDF_SIZE - 1 {
            break;
        }
    }
    if l > NUM_BASE_LEVELS + COEFF_BASE_RANGE {
        let x = (l - NUM_BASE_LEVELS - COEFF_BASE_RANGE) as u32;
        b += (2 * (31 - x.leading_zeros()) + 1) as f32;
    }
    b
}

/// Bits of coding the end of block at `eob` (> 0).
fn eob_bits(cc: &CoeffCosts, multi: usize, ptype: usize, ectx: usize, tx_sz_ctx: usize, eob: i32) -> f32 {
    let pt = if eob <= 2 {
        eob
    } else {
        let mut pt = 2;
        let mut v = eob - 1;
        while v > 1 {
            v >>= 1;
            pt += 1;
        }
        pt
    };
    let e = if multi >= 5 { 0 } else { ectx };
    let mut b = cc.eob_pt[(multi * 2 + ptype) * 2 + e][(pt - 1) as usize];
    if pt >= 3 {
        let rem = eob - ((1 << (pt - 2)) + 1);
        b += cc.eob_extra[(tx_sz_ctx * 2 + ptype) * 9 + (pt - 3) as usize][((rem >> (pt - 3)) & 1) as usize];
        b += (pt - 3) as f32;
    }
    b
}

/// [`optimize`]'s level map: a 32x32's, padded by 4 to the right and below.
pub(crate) const LEV: usize = (32 + 4) * (32 + 4);

/// Optimizes the levels `q` (a tw x th tx block of `tx_sz`, `tx_type`, plane `plane`) quantized from
/// the transform coefficients `v` with dequantization `step(i) / den`: `dist` is the sample-domain
/// SSE of a unit coefficient error, `lambda` the weight of a bit. `lev` is scratch (its contents
/// don't matter: the part the block reads is cleared).
#[allow(clippy::too_many_arguments)]
pub(crate) fn optimize(
    lev: &mut [u8; LEV],
    cc: &CoeffCosts,
    q: &mut [i16],
    v: &[f32],
    tx_sz: i32,
    tx_type: i32,
    plane: usize,
    dc_step: f32,
    ac_step: f32,
    den: f32,
    dist: f32,
    lambda: f32,
) {
    let tsz = tx_sz as usize;
    let scan = get_scan(tx_sz, tx_type);
    let n = scan.len().min(q.len());
    let mut eob = 0usize;
    for (c, &pos) in scan.iter().enumerate().take(n) {
        if q[pos as usize] != 0 {
            eob = c + 1;
        }
    }
    if eob == 0 {
        return;
    }
    let ptype = (plane > 0) as usize;
    let tx_sz_ctx = (Tx_Size_Sqr[tsz] as usize + Tx_Size_Sqr_Up[tsz] as usize + 1) >> 1;
    let brsz = tx_sz_ctx.min(TX_32X32 as usize);
    let class = tx_class(tx_type);
    let multi = ((Tx_Width_Log2[tsz] as i32).min(5) + (Tx_Height_Log2[tsz] as i32).min(5) - 4) as usize;
    let ectx = (class != TX_CLASS_2D) as usize;
    let adj = Adjusted_Tx_Size[tsz] as usize;
    let bwl = Tx_Width_Log2[adj] as usize;
    let (width, height) = (1usize << bwl, Tx_Height[adj] as usize);
    let area = (height << bwl) as i32;
    let ls = width + 4;
    // the levels decided so far and their padding: what the contexts read (rows up to 4 below the
    // block's last, columns up to 4 right of its last, inside a row of `ls`)
    let lev = &mut lev[..(height + 4) * ls];
    lev.fill(0);
    let sig = &Sig_Ref_Diff_Offset[class as usize];
    let magoff = &Mag_Ref_Offset_With_Tx_Class[class as usize];
    let base_ctx_off = &Coeff_Base_Ctx_Offset[tsz];
    let base_i = |ctx: usize| (tx_sz_ctx * 2 + ptype) * 42 + ctx;
    let br_i = |ctx: usize| (brsz * 2 + ptype) * 21 + ctx;
    let deq = |pos: usize, l: i32| l as f32 * if pos == 0 { dc_step } else { ac_step } / den;
    let derr = |pos: usize, l: i32| {
        let e = v[pos].abs() - deq(pos, l);
        e * e * dist
    };
    // the contexts of a coefficient from the levels already decided (those after it in scan order)
    let ctxs = |lev: &[u8], pos: usize, c: usize| -> (usize, usize) {
        let (row, col) = (pos >> bwl, pos & (width - 1));
        let lp = row * ls + col;
        let mut mag = 0;
        for o in sig {
            mag += (lev[lp + o[0] as usize * ls + o[1] as usize] as i32).min(3);
        }
        let mut bctx = ((mag + 1) >> 1).min(4) as usize;
        if class == TX_CLASS_2D {
            bctx = if row == 0 && col == 0 { 0 } else { bctx + base_ctx_off[row.min(4)][col.min(4)] as usize };
        } else {
            let id = if class == TX_CLASS_VERT { row } else { col };
            bctx += Coeff_Base_Pos_Ctx_Offset[id.min(2)] as usize;
        }
        let mut mag = 0;
        for o in magoff {
            mag += (lev[lp + o[0] as usize * ls + o[1] as usize] as i32).min(15);
        }
        let mag = ((mag + 1) >> 1).min(6) as usize;
        let brctx = if pos == 0 {
            mag
        } else if class == TX_CLASS_2D {
            if row < 2 && col < 2 { mag + 7 } else { mag + 14 }
        } else if class == TX_CLASS_HORIZ {
            if col == 0 { mag + 7 } else { mag + 14 }
        } else if row == 0 {
            mag + 7
        } else {
            mag + 14
        };
        let _ = c;
        (bctx, brctx)
    };
    let eob_bctx = |c: usize| {
        let c = c as i32;
        if c == 0 {
            0
        } else if c <= area / 8 {
            1
        } else if c <= area / 4 {
            2
        } else {
            3
        }
    };
    // a level's bits at scan position c with its contexts (the last: coeff_base_eob), sign included
    let bits_at = |(bctx, brctx): (usize, usize), c: usize, last: bool, l: i32| -> f32 {
        if l == 0 {
            return cc.base[base_i(bctx)][0];
        }
        let b = if last {
            cc.base_eob[(tx_sz_ctx * 2 + ptype) * 4 + eob_bctx(c)][(l.min(3) - 1) as usize]
        } else {
            cc.base[base_i(bctx)][l.min(3) as usize]
        };
        b + high_bits(cc, br_i(brctx), l) + 1.0
    };
    let level_bits = |lev: &[u8], pos: usize, c: usize, last: bool, l: i32| bits_at(ctxs(lev, pos, c), c, last, l);
    // reverse scan: each nonzero level against one lower
    let lp_of = |pos: usize| (pos >> bwl) * ls + (pos & (width - 1));
    for c in (0..eob).rev() {
        let pos = scan[c] as usize;
        let l = (q[pos] as i32).abs();
        if l == 0 {
            continue;
        }
        let last = c == eob - 1;
        if !(last && l == 1) {
            // one lower (a 2 straight to nothing measured the same: BENCHMARKS)
            let cx = ctxs(lev, pos, c);
            let j0 = derr(pos, l) + lambda * bits_at(cx, c, last, l);
            let j1 = derr(pos, l - 1) + lambda * bits_at(cx, c, last, l - 1);
            if j1 < j0 {
                let nl = l - 1;
                q[pos] = (if q[pos] < 0 { -nl } else { nl }) as i16;
            }
        }
        lev[lp_of(pos)] = (q[pos] as i32).abs().min(15) as u8;
    }
    // the end of block: drop a last level of 1 while that pays (never the block's only level)
    loop {
        let pos = scan[eob - 1] as usize;
        if (q[pos] as i32).abs() != 1 {
            break;
        }
        let Some(prev) = (0..eob - 1).rev().find(|&c| q[scan[c] as usize] != 0) else { break };
        let ppos = scan[prev] as usize;
        let pl = (q[ppos] as i32).abs();
        // with it: its own bits and the end at eob; the previous level coded as a plain one
        lev[lp_of(pos)] = 1;
        let r_with = eob_bits(cc, multi, ptype, ectx, tx_sz_ctx, eob as i32)
            + level_bits(lev, pos, eob - 1, true, 1)
            + (prev + 1..eob - 1).map(|c| level_bits(lev, scan[c] as usize, c, false, 0)).sum::<f32>()
            + level_bits(lev, ppos, prev, false, pl);
        lev[lp_of(pos)] = 0;
        let r_without = eob_bits(cc, multi, ptype, ectx, tx_sz_ctx, prev as i32 + 1) + level_bits(lev, ppos, prev, true, pl);
        let dj = derr(pos, 0) - derr(pos, 1) + lambda * (r_without - r_with);
        if dj >= 0.0 {
            break;
        }
        q[pos] = 0;
        eob = prev + 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// On random levels of every tx size and class, RDOQ only lowers magnitudes, keeps signs, and
    /// leaves a block with levels at least one; an all-zero block stays so.
    #[test]
    fn only_lowers_levels() {
        let cc = CoeffCosts::new(80);
        let mut r = 0x1234_5678u64;
        let mut rnd = move || {
            r ^= r << 13;
            r ^= r >> 7;
            r ^= r << 17;
            r
        };
        for tx_sz in 0..TX_SIZES_ALL {
            let n = crate::dsp::tx_coeffs(tx_sz);
            for tx_type in [DCT_DCT, ADST_ADST, V_DCT, H_DCT, IDTX] {
                if crate::dsp::get_scan(tx_sz, tx_type).len() < n {
                    continue;
                }
                for trial in 0..20 {
                    let mut q: Vec<i16> = (0..n)
                        .map(|_| if rnd() % 4 == 0 { (rnd() % 40) as i16 - 20 } else { 0 })
                        .collect();
                    if trial == 0 {
                        q.iter_mut().for_each(|v| *v = 0);
                    }
                    let v: Vec<f32> = q.iter().map(|&l| l as f32 * 40.0 / 8.0 + ((rnd() % 100) as f32 - 50.0) / 20.0).collect();
                    let before = q.clone();
                    optimize(&mut [0x55; LEV], &cc, &mut q, &v, tx_sz, tx_type, 0, 40.0, 40.0, 8.0, 1.0, 150.0);
                    for (a, b) in before.iter().zip(&q) {
                        assert!(b.abs() <= a.abs() && (*b == 0 || b.signum() == a.signum()), "tx {tx_sz} type {tx_type}: {a} -> {b}");
                    }
                    assert_eq!(before.iter().any(|&x| x != 0), q.iter().any(|&x| x != 0), "tx {tx_sz} type {tx_type}: emptied");
                }
            }
        }
    }
}
