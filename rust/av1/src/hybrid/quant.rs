//! The closed-loop quantization hook (hybrid.cpp / ref_engine.cpp QuantHook): for every tx block,
//! the residual against the writer's exact prediction, the forward transform and the dead-zone (or
//! rounding) quantizer; luma tx types kept, or searched by exact reconstruction error and a rate
//! proxy.
//!
//! The C++ computes every trial's cost and discards it where nothing compares it (chroma, a kept or
//! DCT-only luma type); here those trials stop after the quantizer, with the same coefficients.
use super::decide::SrcView;
use super::fmac;
use super::fwd::{FWD_F_TMP, FWD_TMP, FwdTx, Stage1Cache, forward, forward_f, forward_f_cached, fwd};
use crate::dsp::{
    clip1, dequant, dq_denom, flip_lr, flip_ud, get_scan, get_tx_set_inter, get_tx_set_intra, inv_txfm2d, qm, qm_step,
    tx_coeffs, tx_h, tx_type_in_set_inter, tx_type_in_set_intra, tx_w,
};
use crate::tables::{DCT_DCT, TX_SET_DCTONLY, TX_TYPES};
use super::{rdoq, tx_model};
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
    /// whether RDOQ applies to this tx block (its source spans [`QuantHook::rdoq_range`]), once
    /// asked ([`QuantHook::rdoq_here`]): 0 not yet, 1 no, 2 yes
    rdoq_here: u8,
    /// the residual's energy (sum of squares), with [`QuantHook::td_dist`]
    energy: u64,
    /// the residual's first forward products, shared by the types a search tries
    s1: Stage1Cache,
    /// RDOQ's level map
    lev: Box<[u8; rdoq::LEV]>,
}

/// A tile thread's scratch (what the C++ keeps in thread_locals).
pub struct Scratch {
    w: Work,
    cur: Vec<i16>,
    best: Vec<i16>,
    /// `best`'s forward coefficients (for RDOQ, which would otherwise redo the transform)
    best_df: Vec<f32>,
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
                rdoq_here: 0,
                energy: 0,
                s1: Stage1Cache::default(),
                lev: Box::new([0; rdoq::LEV]),
            },
            cur: vec![0; 1024],
            best: vec![0; 1024],
            best_df: vec![0.0; 1024],
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
    /// RDOQ's coefficient costs (super::rdoq), or None: the dead-zone quantizer's levels as they are
    pub rdoq: Option<&'a rdoq::CoeffCosts>,
    /// with `rdoq`, luma trials optimize their levels before they're compared, so the tx type
    /// search weighs each type after RDOQ (else only the chosen type's levels are)
    pub rdoq_trials: bool,
    /// with `rdoq`, only tx blocks whose source spans at least this many values: text and UI edges,
    /// not the flat gradients (sky, shading) whose small coefficients RDOQ would drop into bands
    pub rdoq_range: u8,
    /// compared trials' distortion in the transform domain (libaom's tx_domain_dist): the
    /// residual's energy less what the coded coefficients take of it, at the transform's gain,
    /// with no inverse transform (else the exact reconstruction's SSE)
    pub td_dist: bool,
    /// a luma search stops at DCT_DCT (the first type tried) when it codes nothing
    pub dct_zero_stops: bool,
    /// the tx types a luma search may try (bit t: type t; DCT_DCT always)
    pub tx_types: u32,
}

/// Each coefficient's position in [`get_scan`]'s order for the tx size and type.
fn inverse_scan(tx_sz: i32, ty: i32) -> &'static [u16] {
    static T: std::sync::OnceLock<(Vec<Vec<u16>>, Vec<u8>)> = std::sync::OnceLock::new();
    let (tabs, at) = T.get_or_init(|| {
        let (mut tabs, mut ptrs, mut at) = (Vec::new(), Vec::<*const u16>::new(), Vec::new());
        for t in 0..crate::tables::TX_SIZES_ALL {
            for y in 0..16 {
                let scan = get_scan(t, y);
                let k = ptrs.iter().position(|&p| p == scan.as_ptr()).unwrap_or_else(|| {
                    let mut inv = vec![0u16; scan.len()];
                    for (i, &p) in scan.iter().enumerate() {
                        inv[p as usize] = i as u16;
                    }
                    ptrs.push(scan.as_ptr());
                    tabs.push(inv);
                    tabs.len() - 1
                });
                at.push(k as u8);
            }
        }
        (tabs, at)
    });
    &tabs[at[tx_sz as usize * 16 + ty as usize] as usize]
}

/// [`coeff_gain`] per tx size and type, measured on first use.
fn coeff_gain_t(f: &FwdTx, tx_sz: i32, ty: i32) -> f32 {
    use std::sync::atomic::{AtomicU32, Ordering};
    const UNSET: u32 = u32::MAX;
    static G: [AtomicU32; crate::tables::TX_SIZES_ALL as usize * 16] =
        [const { AtomicU32::new(UNSET) }; crate::tables::TX_SIZES_ALL as usize * 16];
    let slot = &G[tx_sz as usize * 16 + ty as usize];
    let v = slot.load(Ordering::Relaxed);
    if v != UNSET {
        return f32::from_bits(v);
    }
    let (tw, th) = (tx_w(tx_sz) as usize, tx_h(tx_sz) as usize);
    let mut r = 1u32;
    let res: Vec<f32> = (0..tw * th)
        .map(|_| {
            r = r.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            ((r >> 16) % 61) as f32 - 30.0
        })
        .collect();
    let mut out = vec![0f32; 1024];
    let mut tmp = vec![0f32; FWD_F_TMP];
    forward_f(f, &res, tx_sz, ty, &mut out, &mut tmp);
    let er: f32 = res.iter().map(|v| v * v).sum();
    let ec: f32 = out[..tx_coeffs(tx_sz)].iter().map(|v| v * v).sum();
    let g = if ec > 0.0 { er / ec } else { 1.0 };
    slot.store(g.to_bits(), Ordering::Relaxed);
    g
}

/// The sample-domain SSE of a unit transform-domain error, per tx size (the forward transform's
/// gain, measured on a fixed noise residual with DCT_DCT).
fn coeff_gain(f: &FwdTx, tx_sz: i32) -> f32 {
    static G: std::sync::OnceLock<Vec<f32>> = std::sync::OnceLock::new();
    G.get_or_init(|| {
        (0..crate::tables::TX_SIZES_ALL)
            .map(|t| {
                let (tw, th) = (tx_w(t) as usize, tx_h(t) as usize);
                let mut r = 1u32;
                let res: Vec<f32> = (0..tw * th)
                    .map(|_| {
                        r = r.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                        ((r >> 16) % 61) as f32 - 30.0
                    })
                    .collect();
                let mut out = vec![0f32; 1024];
                let mut tmp = vec![0f32; FWD_F_TMP];
                forward_f(f, &res, t, DCT_DCT, &mut out, &mut tmp);
                let er: f32 = res.iter().map(|v| v * v).sum();
                let ec: f32 = out[..tx_coeffs(t)].iter().map(|v| v * v).sum();
                if ec > 0.0 { er / ec } else { 1.0 }
            })
            .collect()
    })[tx_sz as usize]
}

impl<'a> QuantHook<'a> {
    pub fn new(src: SrcView<'a>, o: HookOpts) -> QuantHook<'a> {
        QuantHook {
            src,
            o,
            f: fwd(),
            tx_model: None,
            collect: None,
            rdoq: None,
            rdoq_trials: false,
            rdoq_range: 0,
            td_dist: false,
            dct_zero_stops: false,
            tx_types: u32::MAX,
        }
    }

    /// The types of the set (`in_set`) to try: the model's choice, or all of them.
    fn tx_mask(&self, w: &Work, tw: usize, th: usize, ac_q: i32, inter: bool, in_set: impl Fn(i32) -> bool) -> u32 {
        (self.tx_types | 1 << DCT_DCT) & self.tx_mask_model(w, tw, th, ac_q, inter, in_set)
    }

    /// The types the learned model keeps, or every type.
    fn tx_mask_model(&self, w: &Work, tw: usize, th: usize, ac_q: i32, inter: bool, in_set: impl Fn(i32) -> bool) -> u32 {
        match self.tx_model {
            // (below 8x8 a trial costs about what the model does: every type)
            Some((weights, eps)) if tw * th >= tx_model::MIN_SAMPLES => {
                tx_model::keep(weights, &tx_model::features(&w.resf, tw, th, ac_q, inter), in_set, eps)
            }
            _ => u32::MAX,
        }
    }

    /// RDOQ (super::rdoq) of the levels `q` of type `ty`, from that type's forward coefficients in
    /// `w.df` (the trial's); quantizer matrices and the double forward leave them be.
    /// `trialed`: the levels are a compared trial's, which `rdoq_trials` optimized already.
    #[allow(clippy::too_many_arguments)]
    fn optimize(&self, w: &mut Work, q: &mut [i16], s: &[u8], ss: usize, tx_sz: i32, ty: i32, plane: usize, dc_q: i32, ac_q: i32, qm_level: i32, lam: f64, trialed: bool) {
        let Some(cc) = self.rdoq else { return };
        if self.rdoq_trials && plane == 0 && trialed {
            return;
        }
        if self.o.double_fwd || qm(true, qm_level, plane as i32, tx_sz, ty).is_some() {
            return;
        }
        let n = tx_coeffs(tx_sz);
        // (RDOQ leaves all-zero levels be: no need to look at the source for them)
        if q[..n].iter().all(|&v| v == 0) || !self.rdoq_here(w, s, ss, tx_sz) {
            return;
        }
        rdoq::optimize(
            &mut w.lev,
            cc,
            &mut q[..n],
            &w.df[..n],
            tx_sz,
            ty,
            plane,
            dc_q as f32,
            ac_q as f32,
            dq_denom(tx_sz) as f32,
            coeff_gain(self.f, tx_sz),
            lam as f32,
        );
    }

    /// Whether RDOQ applies to the tx block (`s`, its source): asked once a tx block, and only
    /// where levels would be optimized.
    #[inline]
    fn rdoq_here(&self, w: &mut Work, s: &[u8], ss: usize, tx_sz: i32) -> bool {
        if w.rdoq_here == 0 {
            let (tw, th) = (tx_w(tx_sz) as usize, tx_h(tx_sz) as usize);
            let on = self.rdoq.is_some() && (self.rdoq_range == 0 || spans(s, ss, tw, th, self.rdoq_range));
            w.rdoq_here = 1 + on as u8;
        }
        w.rdoq_here == 2
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
/// Whether a tw x th source block's values span at least `min_range`.
fn spans(s: &[u8], ss: usize, tw: usize, th: usize, min_range: u8) -> bool {
    let (mut lo, mut hi) = (255u8, 0u8);
    for i in 0..th {
        for &v in &s[i * ss..][..tw] {
            lo = lo.min(v);
            hi = hi.max(v);
        }
    }
    hi.saturating_sub(lo) >= min_range
}

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
#[inline(never)]
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
        // the exact path two lanes at a time: the same IEEE operations as `exact` (d * den, then
        // / step, |v| + rnd, floor), so the same levels
        // SAFETY: NEON is part of the aarch64 baseline.
        let (vden, vstep, vrnd, vzbin, vmax) = unsafe {
            (
                vdupq_n_f64(den as f64),
                vdupq_n_f64(ac_q as f64),
                vdupq_n_f64(rnd),
                vdupq_n_f64(zbin),
                vdupq_n_f64(32767.0),
            )
        };
        let mut any = unsafe { vdupq_n_s64(0) };
        for c in (4..n).step_by(4) {
            let x: &[f32; 4] = d[c..c + 4].try_into().unwrap();
            // SAFETY: NEON is part of the aarch64 baseline; x is 4 floats, q[c..c + 4] 4 levels.
            unsafe {
                let xf = vld1q_f32(x.as_ptr());
                if vminvq_u32(vcltq_f32(vabsq_f32(xf), vdupq_n_f32(thr))) != 0 {
                    q[c..c + 4].fill(0);
                    continue;
                }
                let level = |v: float64x2_t| {
                    let v = vdivq_f64(vmulq_f64(v, vden), vstep);
                    let a = vabsq_f64(v);
                    let t = vminq_f64(vrndmq_f64(vaddq_f64(a, vrnd)), vmax);
                    let t = vbslq_f64(vcltq_f64(a, vzbin), vdupq_n_f64(0.0), t);
                    let l = vcvtq_s64_f64(t);
                    vbslq_s64(vcltzq_f64(v), vnegq_s64(l), l)
                };
                let (lo, hi) = (level(vcvt_f64_f32(vget_low_f32(xf))), level(vcvt_high_f64_f32(xf)));
                any = vorrq_s64(any, vorrq_s64(lo, hi));
                let l = vcombine_s32(vmovn_s64(lo), vmovn_s64(hi));
                vst1_s16(q[c..c + 4].as_mut_ptr(), vmovn_s32(l));
            }
        }
        // SAFETY: NEON is part of the aarch64 baseline.
        nz |= unsafe { vmaxvq_u32(vreinterpretq_u32_s64(any)) } != 0;
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
        } else if m.is_none() && {
            // Glass Act: a residual too small for any coefficient to reach the quantizer's zero
            // region (FwdTx::coeff_bound, zero_below at the smaller step) quantizes to all zeros
            // whatever its transform: no transform. Nothing reads its coefficients (w.df) then: RDOQ
            // and skip_if_cheaper leave all-zero levels be, and the trial costs it by its energy.
            let b = self.f.coeff_bound(tx_sz, ty);
            let thr = zero_below(dc_q.min(ac_q), den, rnd, zbin);
            b * b * (w.energy as f64) < thr * thr
        } {
            q[..n].fill(0);
            false
        } else {
            forward_f_cached(self.f, &w.resf, tx_sz, ty, &mut w.df, &mut w.ftmp, &mut w.s1);
            let mut nz = quantize_f(&w.df[..n], q, den, dc_q, ac_q, m, rnd, zbin);
            if let Some(cc) = self.rdoq.filter(|_| self.rdoq_trials && need_j && plane == 0 && m.is_none() && nz && self.rdoq_here(w, s, ss, tx_sz)) {
                let lam = 0.12 * (ac_q as f32 / 8.0) * (ac_q as f32 / 8.0);
                rdoq::optimize(&mut w.lev, cc, &mut q[..n], &w.df[..n], tx_sz, ty, 0, dc_q as f32, ac_q as f32, den as f32, coeff_gain(self.f, tx_sz), lam);
                nz = q[..n].iter().any(|&v| v != 0);
            }
            nz
        };
        if !need_j {
            return 0.0;
        }
        let lambda = 0.12 * (ac_q as f64 / 8.0) * (ac_q as f64 / 8.0); // follows the block's (delta-q) quantizer
        let (tw, th) = (tx_w(tx_sz) as usize, tx_h(tx_sz) as usize);
        let mut sse = 0u64;
        let mut r = 1.0f64;
        if nz && self.td_dist && m.is_none() && !self.o.double_fwd {
            // E - g sum(c^2 - (c - c')^2), c' = q step / den: what the coded coefficients take of
            // the residual's energy E
            let (dcs, acs) = (dc_q as f32 / den as f32, ac_q as f32 / den as f32);
            let mut acc = 0f32;
            for (i, (&c, &l)) in w.df[..n].iter().zip(&q[..n]).enumerate() {
                if l != 0 {
                    let e = c - l as f32 * if i == 0 { dcs } else { acs };
                    acc += c * c - e * e;
                }
            }
            let d = w.energy as f64 - coeff_gain_t(self.f, tx_sz, ty) as f64 * acc as f64;
            r = self.rate(q, tx_sz, ty, n);
            return fmac(lambda, r, d.max(0.0));
        }
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
            r = self.rate(q, tx_sz, ty, n);
        } else if self.td_dist && !self.o.double_fwd {
            sse = w.energy;
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
    /// The trials' rate proxy: 1 + 2 + 2 floor(log2 |level|) a nonzero level, 0.3 a zero one
    /// before the last in scan order. In raster order (the scan's position of each coefficient
    /// gives the last), so a loop LLVM vectorizes; the same sums as walking the scan.
    #[inline(never)]
    fn rate(&self, q: &[i16], tx_sz: i32, ty: i32, n: usize) -> f64 {
        let iscan = inverse_scan(tx_sz, ty);
        let (mut bits, mut nnz, mut last) = (0u32, 0u32, 0u32);
        for (&l, &p) in q[..n].iter().zip(&iscan[..n]) {
            let a = l.unsigned_abs() as u32;
            let nzb = (a != 0) as u32;
            bits += nzb * (2 + 2 * (31 - (a | 1).leading_zeros()));
            nnz += nzb;
            last = last.max(nzb * p as u32);
        }
        // the scan's zeros up to its last nonzero (one, the first, when there is none)
        let zeros = last + 1 - nnz;
        fmac(0.3, zeros as f64, 1.0 + bits as f64)
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
        let Scratch { w, cur, best, best_df, dct } = sc;
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
            let mut e = 0u64;
            for i in 0..th {
                let (sr, p, d) = (&s[i * ss..][..tw], &pred[i * ps..][..tw], &mut w.resf[i * tw..][..tw]);
                for ((d, &s), &p) in d.iter_mut().zip(sr).zip(p) {
                    let v = s as i32 - p as i32;
                    e += (v * v) as u64;
                    *d = v as f32;
                }
            }
            w.energy = e;
            w.s1.reset();
        }
        w.rdoq_here = 0;
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
            self.optimize(w, coeffs, s, ss, tx_sz, ty, plane, dc_q, ac_q, qm_level, lam, false);
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
                    core::mem::swap(&mut w.df, best_df);
                }
                if ty == DCT_DCT && self.dct_zero_stops && best[..n].iter().all(|&v| v == 0) {
                    break;
                }
            }
            core::mem::swap(&mut w.df, best_df);
            t.tx_type = best_type as u8;
            coeffs.copy_from_slice(&best[..n]);
            self.collect_sample(w, tw, th, ac_q, true, best_type, tx_sz);
            self.optimize(w, coeffs, s, ss, tx_sz, best_type, 0, dc_q, ac_q, qm_level, lam, true);
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
            self.optimize(w, coeffs, s, ss, tx_sz, DCT_DCT, 0, dc_q, ac_q, qm_level, lam, rd_skip);
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
            self.optimize(w, coeffs, s, ss, tx_sz, DCT_DCT, 0, dc_q, ac_q, qm_level, lam, false);
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
                core::mem::swap(&mut w.df, best_df);
            }
            if ty == DCT_DCT && self.dct_zero_stops && best[..n].iter().all(|&v| v == 0) {
                break;
            }
        }
        core::mem::swap(&mut w.df, best_df);
        t.tx_type = best_type as u8;
        coeffs.copy_from_slice(&best[..n]);
        self.collect_sample(w, tw, th, ac_q, false, best_type, tx_sz);
        self.optimize(w, coeffs, s, ss, tx_sz, best_type, 0, dc_q, ac_q, qm_level, lam, true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tables::*;

    fn hook() -> QuantHook<'static> {
        let o = HookOpts {
            tx_types: true,
            reduced_tx_set: false,
            given_luma_tx: 0,
            rnd: 0.45,
            zbin: 0.0,
            double_fwd: false,
            inter_rd_skip: true,
            inter_tx_types: true,
        };
        QuantHook::new(
            super::super::decide::SrcView {
                stride: [0; 3],
                p: [&[], &[], &[]],
            },
            o,
        )
    }

    /// FwdTx::coeff_bound bounds every coefficient of forward_f (scalar and NEON), so the all-zero
    /// shortcut in `trial` skips only transforms that quantize to nothing: residuals of every size
    /// and type, from one sample to dense, and one concentrated in a coefficient's own pattern.
    #[test]
    fn coeff_bound_holds() {
        let f = fwd();
        let mut r = 0x2545_f491u32;
        let mut next = || {
            r ^= r << 13;
            r ^= r >> 17;
            r ^= r << 5;
            r
        };
        let (mut res, mut out, mut tmp) = (vec![0f32; 4096], vec![0f32; 1024], vec![0f32; FWD_F_TMP]);
        for case in 0..6_000 {
            let tx = (next() % TX_SIZES_ALL as u32) as i32;
            let ty = (next() % 16) as i32;
            let b = f.coeff_bound(tx, ty);
            if !b.is_finite() {
                continue;
            }
            let (wf, hf) = (tx_w(tx) as usize, tx_h(tx) as usize);
            let (n, nc) = (wf * hf, tx_coeffs(tx));
            let density = 1 + next() % 8;
            let amp = 1 + next() % 255;
            for (i, v) in res[..n].iter_mut().enumerate() {
                let x = next();
                *v = if case % 3 == 0 {
                    // a smooth pattern (a DC or a slow ramp: one coefficient takes most of it)
                    ((i / wf + i % wf) as u32 % (1 + amp / 32)) as f32 + (amp / 2) as f32
                } else if x % 8 < density {
                    ((x >> 8) % (2 * amp + 1)) as f32 - amp as f32
                } else {
                    0.0
                };
            }
            let e: f64 = res[..n].iter().map(|&v| v as f64 * v as f64).sum();
            let lim = b * e.sqrt();
            forward_f(f, &res, tx, ty, &mut out, &mut tmp);
            for &c in &out[..nc] {
                assert!((c.abs() as f64) <= lim, "tx {tx} type {ty}: |{c}| > {lim}");
            }
            super::super::fwd::forward_f_scalar(f, &res, tx, ty, &mut out, &mut tmp);
            for &c in &out[..nc] {
                assert!((c.abs() as f64) <= lim, "tx {tx} type {ty} (scalar): |{c}| > {lim}");
            }
        }
    }

    /// The rate proxy in raster order sums what walking the scan to its last nonzero does.
    #[test]
    fn rate_matches_the_scan_walk() {
        let h = hook();
        let mut r = 0x9e37_79b9u32;
        let mut next = || {
            r ^= r << 13;
            r ^= r >> 17;
            r ^= r << 5;
            r
        };
        let mut q = vec![0i16; 1024];
        for case in 0..20_000 {
            let tx = (next() % TX_SIZES_ALL as u32) as i32;
            let ty = (next() % 16) as i32;
            // (the types the search tries: every inter set holds the intra one's)
            if !tx_type_in_set_inter(get_tx_set_inter(tx, false), ty) {
                continue;
            }
            let n = tx_coeffs(tx);
            let density = next() % 5;
            for v in &mut q[..n] {
                let x = next();
                *v = if x % 8 < density {
                    ((x >> 8) % 300) as i16 - 150
                } else {
                    0
                };
                if x % 997 == 0 {
                    *v = if x & 1 == 0 { 32767 } else { -32767 };
                }
            }
            let scan = get_scan(tx, ty);
            let last = (0..n).rev().find(|&c| q[scan[c] as usize] != 0).unwrap_or(0);
            let (mut bits, mut zeros) = (0i64, 0i32);
            for &p in &scan[..=last] {
                let a = (q[p as usize] as i32).unsigned_abs();
                if a != 0 {
                    bits += 2 + 2 * a.ilog2() as i64;
                } else {
                    zeros += 1;
                }
            }
            let want = fmac(0.3, zeros as f64, 1.0 + bits as f64);
            assert_eq!(
                h.rate(&q, tx, ty, n).to_bits(),
                want.to_bits(),
                "case {case} tx {tx} type {ty}"
            );
        }
    }

    /// The trial's parts per tx size: forward, quantizer, rate (q20's steps, ±30 residuals).
    #[test]
    #[ignore]
    fn bench_trial_parts() {
        let f = fwd();
        let (dcq, acq) = (crate::dsp::dc_q(20), crate::dsp::ac_q(20));
        for (name, tx) in [
            ("4x4", TX_4X4),
            ("8x8", TX_8X8),
            ("16x16", TX_16X16),
            ("32x32", TX_32X32),
            ("8x16", TX_8X16),
        ] {
            let (tw, th) = (tx_w(tx) as usize, tx_h(tx) as usize);
            let n = tx_coeffs(tx);
            let mut r = 7u32;
            let res: Vec<f32> = (0..tw * th)
                .map(|_| {
                    r = r.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                    ((r >> 16) % 61) as f32 - 30.0
                })
                .collect();
            let mut out = vec![0f32; 1024];
            let mut tmp = vec![0f32; FWD_F_TMP];
            let mut q = vec![0i16; 1024];
            let iters = 2_000_000 / (tw * th);
            let t = std::time::Instant::now();
            for _ in 0..iters {
                forward_f(f, &res, tx, DCT_DCT, &mut out, &mut tmp);
                std::hint::black_box(&out);
            }
            let tf = t.elapsed().as_nanos() as f64 / iters as f64;
            let t = std::time::Instant::now();
            for _ in 0..iters {
                std::hint::black_box(quantize_f(&out[..n], &mut q, dq_denom(tx), dcq, acq, None, 0.45, 0.0));
            }
            let tq = t.elapsed().as_nanos() as f64 / iters as f64;
            let hook = hook();
            let t = std::time::Instant::now();
            for _ in 0..iters {
                std::hint::black_box(hook.rate(&q, tx, DCT_DCT, n));
            }
            let tr = t.elapsed().as_nanos() as f64 / iters as f64;
            let nz = q[..n].iter().filter(|&&v| v != 0).count();
            let mut dq = vec![0i32; 1024];
            let mut rr = vec![0i32; 64 * 64];
            let t = std::time::Instant::now();
            for _ in 0..iters {
                dequant(&q, &mut dq, tx, dcq, acq, None);
                std::hint::black_box(inv_txfm2d(&dq, tx, DCT_DCT, &mut rr));
            }
            let ti = t.elapsed().as_nanos() as f64 / iters as f64;
            println!(
                "{name}: forward {tf:.0} ns, quantize {tq:.0}, rate {tr:.0}, dequant+inverse {ti:.0} ({nz}/{n} nonzero)"
            );
        }
    }
}
