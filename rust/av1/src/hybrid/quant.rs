//! The closed-loop quantization hook (hybrid.cpp / ref_engine.cpp QuantHook): for every tx block,
//! the residual against the writer's exact prediction, the forward transform and the dead-zone (or
//! rounding) quantizer; luma tx types kept, or searched by exact reconstruction error and a rate
//! proxy.
//!
//! The C++ computes every trial's cost and discards it where nothing compares it (chroma, a kept or
//! DCT-only luma type); here those trials stop after the quantizer, with the same coefficients.
use super::decide::SrcView;
use super::fmac;
use super::fwd::{FWD_F_TMP, FWD_TMP, FwdTx, forward, forward_f, fwd};
use crate::dsp::{
    clip1, dequant, dq_denom, flip_lr, flip_ud, get_scan, get_tx_set_inter, get_tx_set_intra, inv_txfm2d, qm, qm_step,
    tx_coeffs, tx_h, tx_type_in_set_inter, tx_type_in_set_intra, tx_w,
};
use crate::tables::{DCT_DCT, TX_SET_DCTONLY, TX_TYPES};
use super::tx_model;
use crate::types::Txb;
use crate::writer::{TxbCtx, TxbHook};

/// The hook's options (HybridOpts / RefEngineOpts fields it reads).
#[derive(Clone, Copy, Debug)]
pub(crate) struct HookOpts {
    /// search luma tx types (else DCT_DCT)
    pub tx_types: bool,
    pub reduced_tx_set: bool,
    /// 0: search luma tx types; 1: keep the record's; 2: theirs vs DCT_DCT
    pub given_luma_tx: i32,
    /// the quantizer: q = |v| < zbin ? 0 : floor(|v| + rnd)
    pub rnd: f64,
    pub zbin: f64,
    /// the reference engine's double forward transform (else the hybrid's float one)
    pub double_fwd: bool,
    /// an inter block's tx block codes no coefficients where that costs less (D + lambda R) than
    /// its quantized residual: libaom realtime's skip when coding costs more than the distortion
    pub inter_rd_skip: bool,
    /// search an inter block's luma tx types in its inter set (else DCT_DCT)
    pub inter_tx_types: bool,
}

/// One tx block's working buffers.
pub(crate) struct Work {
    resf: Vec<f32>,
    resi: Vec<i32>,
    df: Vec<f32>,
    dd: Vec<f64>,
    ftmp: Vec<f32>,
    dtmp: Vec<f64>,
    dq: Vec<i32>,
    rr: Vec<i32>,
}

/// A tile thread's scratch (what the C++ keeps in thread_locals).
pub struct Scratch {
    w: Work,
    cur: Vec<i16>,
    best: Vec<i16>,
    dct: Vec<i16>,
}

impl Scratch {
    fn new() -> Scratch {
        Scratch {
            w: Work {
                resf: vec![0.0; 64 * 64],
                resi: vec![0; 64 * 64],
                df: vec![0.0; 1024],
                dd: vec![0.0; 1024],
                ftmp: vec![0.0; FWD_F_TMP],
                dtmp: vec![0.0; FWD_TMP],
                dq: vec![0; 1024],
                rr: vec![0; 64 * 64],
            },
            cur: vec![0; 1024],
            best: vec![0; 1024],
            dct: vec![0; 1024],
        }
    }
}

pub(crate) struct QuantHook<'a> {
    pub src: SrcView<'a>,
    pub o: HookOpts,
    pub f: &'static FwdTx,
    /// the learned tx type pruning's weights and eps (super::tx_model), or None: every type of the set
    pub tx_model: Option<(&'a [f32], f32)>,
    /// research: every searched luma tx block's features and chosen type ([`tx_model::record`])
    pub collect: Option<&'a std::sync::Mutex<Vec<u8>>>,
}

impl<'a> QuantHook<'a> {
    pub fn new(src: SrcView<'a>, o: HookOpts) -> QuantHook<'a> {
        QuantHook { src, o, f: fwd(), tx_model: None, collect: None }
    }

    /// The types of the set (`in_set`) to try: the model's choice, or all of them.
    fn tx_mask(&self, w: &Work, tw: usize, th: usize, ac_q: i32, inter: bool, in_set: impl Fn(i32) -> bool) -> u32 {
        match self.tx_model {
            // (below 8x8 a trial costs about what the model does: every type)
            Some((weights, eps)) if tw * th >= tx_model::MIN_SAMPLES => {
                tx_model::keep(weights, &tx_model::features(&w.resf, tw, th, ac_q, inter), in_set, eps)
            }
            _ => u32::MAX,
        }
    }

    /// Research: records the block's features and the type the search chose.
    fn collect_sample(&self, w: &Work, tw: usize, th: usize, ac_q: i32, inter: bool, chosen: i32, tx_sz: i32) {
        if let Some(c) = self.collect {
            let f = tx_model::features(&w.resf, tw, th, ac_q, inter);
            tx_model::record(&mut c.lock().unwrap(), &f, chosen, tx_sz, inter);
        }
    }
}

/// One coefficient: q = |v| < zbin ? 0 : floor(|v| + rnd), at most 32767, with v's sign.
#[inline(always)]
fn qcoef(v: f64, rnd: f64, zbin: f64) -> i16 {
    let a = v.abs();
    let qi = if a < zbin {
        0
    } else {
        ((a + rnd).floor() as i32).min(32767)
    };
    (if v < 0.0 { -qi } else { qi }) as i16
}

/// |D| below this gives q = 0 for every AC coefficient without a quantizer matrix: 1 % under the
/// quantizer's zero region (|v| < max(zbin, 1 - rnd)), far more than the rounding of the float
/// compare and of the double division.
#[inline]
fn zero_below(ac_q: i32, den: i32, rnd: f64, zbin: f64) -> f64 {
    0.99 * zbin.max(1.0 - rnd) * ac_q as f64 / den as f64
}

/// The quantizer over float coefficients; returns whether any level is nonzero.
pub(crate) fn quantize_f(
    d: &[f32],
    q: &mut [i16],
    den: i32,
    dc_q: i32,
    ac_q: i32,
    m: Option<&[u8]>,
    rnd: f64,
    zbin: f64,
) -> bool {
    let n = d.len();
    let q = &mut q[..n];
    let exact = |i: usize, q: &mut [i16]| {
        let v = d[i] as f64 * den as f64 / qm_step(if i == 0 { dc_q } else { ac_q }, m, i) as f64;
        q[i] = qcoef(v, rnd, zbin);
        q[i] != 0
    };
    let mut nz = false;
    if m.is_some() || n < 16 {
        for i in 0..n {
            nz |= exact(i, q);
        }
        return nz;
    }
    let thr = zero_below(ac_q, den, rnd, zbin) as f32;
    for i in 0..4 {
        nz |= exact(i, q);
    }
    #[cfg(target_arch = "aarch64")]
    {
        use core::arch::aarch64::*;
        for c in (4..n).step_by(4) {
            let x: &[f32; 4] = d[c..c + 4].try_into().unwrap();
            // SAFETY: NEON is part of the aarch64 baseline; x is 4 floats.
            let all_zero = unsafe { vminvq_u32(vcltq_f32(vabsq_f32(vld1q_f32(x.as_ptr())), vdupq_n_f32(thr))) != 0 };
            if all_zero {
                q[c..c + 4].fill(0);
            } else {
                for i in c..c + 4 {
                    nz |= exact(i, q);
                }
            }
        }
    }
    #[cfg(not(target_arch = "aarch64"))]
    for i in 4..n {
        if d[i].abs() < thr {
            q[i] = 0;
        } else {
            nz |= exact(i, q);
        }
    }
    nz
}

/// The quantizer over double coefficients (the reference engine's).
fn quantize_d(d: &[f64], q: &mut [i16], den: i32, dc_q: i32, ac_q: i32, m: Option<&[u8]>, rnd: f64, zbin: f64) -> bool {
    let thr = if m.is_none() {
        zero_below(ac_q, den, rnd, zbin)
    } else {
        -1.0
    };
    let mut nz = false;
    for (i, (&x, q)) in d.iter().zip(q.iter_mut()).enumerate() {
        if i > 0 && x.abs() < thr {
            *q = 0;
            continue;
        }
        let v = x * den as f64 / qm_step(if i == 0 { dc_q } else { ac_q }, m, i) as f64;
        *q = qcoef(v, rnd, zbin);
        nz |= *q != 0;
    }
    nz
}

impl QuantHook<'_> {
    /// Quantizes one tx type's coefficients into `q` and, with `need_j`, returns exact
    /// reconstruction SSE + lambda * rate proxy (else 0: the caller doesn't compare it).
    fn trial(
        &self,
        w: &mut Work,
        tx_sz: i32,
        ty: i32,
        dc_q: i32,
        ac_q: i32,
        q: &mut [i16],
        pred: &[u8],
        ps: usize,
        s: &[u8],
        ss: usize,
        plane: i32,
        qm_level: i32,
        need_j: bool,
    ) -> f64 {
        let n = tx_coeffs(tx_sz);
        let den = dq_denom(tx_sz);
        let m = qm(true, qm_level, plane, tx_sz, ty); // None for level 15 / IDTX-class types
        let (rnd, zbin) = (self.o.rnd, self.o.zbin);
        let nz = if self.o.double_fwd {
            forward(self.f, &w.resi, tx_sz, ty, &mut w.dd, &mut w.dtmp);
            quantize_d(&w.dd[..n], q, den, dc_q, ac_q, m, rnd, zbin)
        } else {
            forward_f(self.f, &w.resf, tx_sz, ty, &mut w.df, &mut w.ftmp);
            quantize_f(&w.df[..n], q, den, dc_q, ac_q, m, rnd, zbin)
        };
        if !need_j {
            return 0.0;
        }
        let lambda = 0.12 * (ac_q as f64 / 8.0) * (ac_q as f64 / 8.0); // follows the block's (delta-q) quantizer
        let (tw, th) = (tx_w(tx_sz) as usize, tx_h(tx_sz) as usize);
        let mut sse = 0u64;
        let mut r = 1.0f64;
        if nz {
            dequant(q, &mut w.dq, tx_sz, dc_q, ac_q, m);
            if inv_txfm2d(&w.dq, tx_sz, ty, &mut w.rr) != 0 {
                return 1e300;
            }
            let (fud, flr) = (flip_ud(ty), flip_lr(ty));
            for i in 0..th {
                let yy = if fud { th - 1 - i } else { i };
                let (p, sr, rr) = (&pred[yy * ps..][..tw], &s[yy * ss..][..tw], &w.rr[i * tw..][..tw]);
                let d = |(&rr, (&p, &s)): (&i32, (&u8, &u8))| {
                    let d = s as i32 - clip1(p as i32 + rr);
                    (d * d) as u32
                };
                sse += if flr {
                    rr.iter().zip(p.iter().zip(sr).rev()).map(d).sum::<u32>()
                } else {
                    rr.iter().zip(p.iter().zip(sr)).map(d).sum::<u32>()
                } as u64;
            }
            let scan = get_scan(tx_sz, ty);
            let last = (0..n).rev().find(|&c| q[scan[c] as usize] != 0).unwrap_or(0);
            let (mut bits, mut zeros) = (0i64, 0i32);
            for &p in &scan[..=last] {
                let a = (q[p as usize] as i32).unsigned_abs();
                if a != 0 {
                    bits += 2 + 2 * a.ilog2() as i64; // 2 + 2 floor(log2 a), exact
                } else {
                    zeros += 1;
                }
            }
            r = fmac(0.3, zeros as f64, r + bits as f64);
        } else {
            for i in 0..th {
                let (p, sr) = (&pred[i * ps..][..tw], &s[i * ss..][..tw]);
                sse += p
                    .iter()
                    .zip(sr)
                    .map(|(&p, &s)| {
                        let d = s as i32 - p as i32;
                        (d * d) as u32
                    })
                    .sum::<u32>() as u64;
            }
        }
        fmac(lambda, r, sse as f64)
    }
}

impl QuantHook<'_> {
    /// Zeroes `q` where coding nothing (the prediction's error, and a txb_skip bit) costs less than
    /// `j`, the coded residual's cost from [`QuantHook::trial`].
    fn skip_if_cheaper(
        &self,
        j: f64,
        q: &mut [i16],
        pred: &[u8],
        ps: usize,
        s: &[u8],
        ss: usize,
        tw: usize,
        th: usize,
        ac_q: i32,
    ) {
        if q.iter().all(|&c| c == 0) {
            return;
        }
        let lambda = 0.12 * (ac_q as f64 / 8.0) * (ac_q as f64 / 8.0);
        let mut sse = 0u64;
        for i in 0..th {
            sse += pred[i * ps..][..tw]
                .iter()
                .zip(&s[i * ss..][..tw])
                .map(|(&p, &v)| {
                    let d = v as i32 - p as i32;
                    (d * d) as u64
                })
                .sum::<u64>();
        }
        if fmac(lambda, 1.0, sse as f64) <= j {
            q.fill(0);
        }
    }
}

impl TxbHook for QuantHook<'_> {
    type Scratch = Option<Box<Scratch>>;
    // a given type outside its set becomes DCT_DCT; searched ones are in it
    const KEEPS_TX_SETS: bool = true;

    fn on_txb(&self, scratch: &mut Option<Box<Scratch>>, ctx: &TxbCtx<'_>, t: &mut Txb, coeffs: &mut [i16]) {
        let sc = &mut **scratch.get_or_insert_with(|| Box::new(Scratch::new()));
        let Scratch { w, cur, best, dct } = sc;
        let (dc_q, ac_q, qm_level) = (ctx.dc_q, ctx.ac_q, ctx.qm_level);
        let lam = 0.12 * (ac_q as f64 / 8.0) * (ac_q as f64 / 8.0);
        let plane = t.plane as usize;
        let tx_sz = t.tx_size as i32;
        let (tw, th) = (tx_w(tx_sz) as usize, tx_h(tx_sz) as usize);
        let ss = self.src.stride[plane];
        let s = self.src.at(plane, t.x4 as usize * 4, t.y4 as usize * 4);
        let (pred, ps) = (ctx.recon, ctx.recon_stride);
        if self.o.double_fwd {
            for i in 0..th {
                let (sr, p, d) = (&s[i * ss..][..tw], &pred[i * ps..][..tw], &mut w.resi[i * tw..][..tw]);
                for ((d, &s), &p) in d.iter_mut().zip(sr).zip(p) {
                    *d = s as i32 - p as i32;
                }
            }
        } else {
            for i in 0..th {
                let (sr, p, d) = (&s[i * ss..][..tw], &pred[i * ps..][..tw], &mut w.resf[i * tw..][..tw]);
                for ((d, &s), &p) in d.iter_mut().zip(sr).zip(p) {
                    *d = (s as i32 - p as i32) as f32;
                }
            }
        }
        let n = tx_coeffs(tx_sz);
        let coeffs = &mut coeffs[..n];
        let rd_skip = ctx.is_inter && self.o.inter_rd_skip;
        if plane > 0 {
            let ty = ctx.derived_tx_type;
            let j = self.trial(
                w,
                tx_sz,
                ty,
                dc_q,
                ac_q,
                coeffs,
                pred,
                ps,
                s,
                ss,
                plane as i32,
                qm_level,
                rd_skip,
            );
            if rd_skip {
                self.skip_if_cheaper(j, coeffs, pred, ps, s, ss, tw, th, ac_q);
            }
            return;
        }
        if ctx.is_inter && self.o.inter_tx_types {
            // the inter set's types, as intra's below (a type other than DCT_DCT costs a few bits
            // more to signal); then coding nothing where that's cheaper
            let set = get_tx_set_inter(tx_sz, self.o.reduced_tx_set);
            let mask = self.tx_mask(w, tw, th, ac_q, true, |ty| tx_type_in_set_inter(set, ty));
            let mut best_j = 1e301;
            let mut best_type = DCT_DCT;
            for ty in 0..TX_TYPES {
                if !tx_type_in_set_inter(set, ty) || mask >> ty & 1 == 0 {
                    continue;
                }
                let mut j = self.trial(w, tx_sz, ty, dc_q, ac_q, cur, pred, ps, s, ss, 0, qm_level, true);
                j = fmac(lam, if ty == DCT_DCT { 1.0 } else { 3.0 }, j);
                if j < best_j {
                    best_j = j;
                    best_type = ty;
                    core::mem::swap(cur, best);
                }
            }
            t.tx_type = best_type as u8;
            coeffs.copy_from_slice(&best[..n]);
            self.collect_sample(w, tw, th, ac_q, true, best_type, tx_sz);
            if rd_skip {
                self.skip_if_cheaper(best_j, coeffs, pred, ps, s, ss, tw, th, ac_q);
            }
            return;
        }
        if ctx.is_inter {
            // DCT_DCT (in every inter set)
            t.tx_type = DCT_DCT as u8;
            let j = self.trial(
                w, tx_sz, DCT_DCT, dc_q, ac_q, coeffs, pred, ps, s, ss, 0, qm_level, rd_skip,
            );
            if rd_skip {
                self.skip_if_cheaper(j, coeffs, pred, ps, s, ss, tw, th, ac_q);
            }
            return;
        }
        let set = get_tx_set_intra(tx_sz, self.o.reduced_tx_set);
        let in_set = |ty: i32| ty < TX_TYPES && tx_type_in_set_intra(set, ty);
        if self.o.given_luma_tx != 0 {
            if !in_set(t.tx_type as i32) {
                t.tx_type = DCT_DCT as u8;
            }
            let ty = t.tx_type as i32;
            let both = self.o.given_luma_tx == 2 && ty != DCT_DCT;
            let j = self.trial(w, tx_sz, ty, dc_q, ac_q, coeffs, pred, ps, s, ss, 0, qm_level, both);
            if both {
                let jd = self.trial(w, tx_sz, DCT_DCT, dc_q, ac_q, dct, pred, ps, s, ss, 0, qm_level, true);
                if fmac(lam, 1.0, jd) < fmac(lam, 3.0, j) {
                    t.tx_type = DCT_DCT as u8;
                    coeffs.copy_from_slice(&dct[..n]);
                }
            }
            return;
        }
        if set == TX_SET_DCTONLY || !self.o.tx_types {
            t.tx_type = DCT_DCT as u8;
            self.trial(
                w, tx_sz, DCT_DCT, dc_q, ac_q, coeffs, pred, ps, s, ss, 0, qm_level, false,
            );
            return;
        }
        let mask = self.tx_mask(w, tw, th, ac_q, false, in_set);
        let mut best_j = 1e301;
        let mut best_type = DCT_DCT;
        for ty in 0..TX_TYPES {
            if !tx_type_in_set_intra(set, ty) || mask >> ty & 1 == 0 {
                continue;
            }
            let mut j = self.trial(w, tx_sz, ty, dc_q, ac_q, cur, pred, ps, s, ss, 0, qm_level, true);
            j = fmac(lam, if ty == DCT_DCT { 1.0 } else { 3.0 }, j);
            if j < best_j {
                best_j = j;
                best_type = ty;
                core::mem::swap(cur, best);
            }
        }
        t.tx_type = best_type as u8;
        coeffs.copy_from_slice(&best[..n]);
        self.collect_sample(w, tw, th, ac_q, false, best_type, tx_sz);
    }
}
