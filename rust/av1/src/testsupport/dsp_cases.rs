//! av1gpu's GPU-vs-CPU cases for the shared DSP, with the CPU's results (Sources/
//! AV1CoreTestSupport/dsp_cases.cpp and include/av1g_test/dsp_cases.h, from av1gpu's
//! tests/gpu_dsp_test.cu, BSD-2). The Metal kernels (Tests/GlassActAV1Tests/Shaders/
//! dsp_test.metal) run the same cases, so DSPEquivalenceTests can require identical results:
//!   1. dequant (incl. quantizer matrices) + 2-D inverse transform + conformance flags
//!   2. intra prediction (13 modes x angle deltas, every tx size, random edges and availability,
//!      intra edge filter and upsampling, filter intra)
//!   3. CfL
//!   4. od_ec range coder + CDF adaptation
//!
//! Every seed gives the same set as the C++, byte for byte.
#![allow(clippy::needless_range_loop)]
use crate::dsp::{
    EDGE_LEN, Edge, ac_q, build_edges, cfl_predict, dc_q, dequant, get_tx_set_intra, inv_txfm2d, is_directional,
    predict_intra_ex, qm, tx_coeffs, tx_type_in_set_intra,
};
use crate::entropy::{Cdfs, Ec};
use crate::tables::*;
use core::ffi::c_void;
use core::mem::offset_of;

// ---- 1. inverse transforms ----

/// av1t_itx_case
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ItxCase {
    pub tx_sz: i32,
    pub tx_type: i32,
    pub dc_q: i32,
    pub ac_q: i32,
    pub qm_level: i32,
    pub plane: i32,
}
/// AV1T_ITX_COEFFS: coefficients per case, the coded (at most 32x32) quadrant.
pub const ITX_COEFFS: usize = 1024;
/// AV1T_ITX_RESIDUAL: residual samples per case.
pub const ITX_RESIDUAL: usize = 4096;

/// av1t_itx_run: dequantizes `q` into the scratch `dq` (ITX_COEFFS), inverse-transforms it into
/// `res`; returns the conformance flags.
pub fn itx_run(c: &ItxCase, q: &[i16], res: &mut [i32], dq: &mut [i32]) -> u32 {
    let m = qm(c.qm_level >= 0, c.qm_level, c.plane, c.tx_sz, c.tx_type);
    dequant(q, dq, c.tx_sz, c.dc_q, c.ac_q, m);
    inv_txfm2d(dq, c.tx_sz, c.tx_type, res)
}

// ---- 2./3. prediction + CfL ----

/// av1t_pred_case
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PredCase {
    pub mode: i32,
    pub delta: i32,
    pub log2w: i32,
    pub log2h: i32,
    pub have_left: i32,
    pub have_above: i32,
    pub have_ar: i32,
    pub have_bl: i32,
    pub x: i32,
    pub y: i32,
    pub max_x: i32,
    pub max_y: i32,
    pub cfl: i32,
    pub alpha: i32,
    pub edge_filter: i32,
    pub filter_type: i32,
    pub fi_mode: i32,
}
/// AV1T_PW: side of each case's plane; the luma plane for CfL is 2x.
pub const PW: usize = 160;

/// av1t_pred_run: copies `plane` (PW x PW) to `out` and predicts the case's block in it;
/// `luma` is the (2 PW)^2 plane CfL reads.
pub fn pred_run(c: &PredCase, plane: &[u8], luma: &[u8], out: &mut [u8]) {
    let mut a: Edge = [0; EDGE_LEN];
    let mut l: Edge = [0; EDGE_LEN];
    // copy the plane so prediction writes stay private
    out[..PW * PW].copy_from_slice(&plane[..PW * PW]);
    build_edges(
        out,
        PW,
        c.x,
        c.y,
        c.log2w,
        c.log2h,
        c.have_left != 0,
        c.have_above != 0,
        c.have_ar != 0,
        c.have_bl != 0,
        c.max_x,
        c.max_y,
        &mut a,
        &mut l,
    );
    predict_intra_ex(
        c.mode,
        c.delta,
        c.fi_mode,
        c.edge_filter != 0,
        c.filter_type,
        c.have_left != 0,
        c.have_above != 0,
        c.log2w,
        c.log2h,
        c.x,
        c.y,
        c.max_x,
        c.max_y,
        &mut a,
        &mut l,
        &mut out[c.y as usize * PW + c.x as usize..],
        PW,
    );
    if c.cfl != 0 {
        let mut tx_sz = -1;
        for t in 0..TX_SIZES_ALL {
            if Tx_Width_Log2[t as usize] as i32 == c.log2w && Tx_Height_Log2[t as usize] as i32 == c.log2h {
                tx_sz = t;
            }
        }
        cfl_predict(
            out,
            PW,
            luma,
            2 * PW,
            c.x,
            c.y,
            tx_sz,
            1,
            1,
            2 * (c.x + (1 << c.log2w)),
            2 * (c.y + (1 << c.log2h)),
            c.alpha,
        );
    }
}

// ---- 4. entropy coder ----

/// av1t_sym: an adaptive symbol of the N-symbol CDF at u16 offset `cdf_off` in [`Cdfs`], or
/// (`is_bool`) an equiprobable bit.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Sym {
    pub cdf_off: u16,
    pub s: u16,
    pub n: u16,
    pub is_bool: u16,
}

/// av1t_ec_stream: codes `syms` with `cdf` (adapted in place) into `out` (cleared first), with a
/// precarry buffer of `cap` entries. Returns the number of bytes, or -1 (`out` empty) where the
/// C++'s buffer overflows: when the stream is longer than `cap` bytes.
pub fn ec_stream(syms: &[Sym], cdf: &mut Cdfs, ec: &mut Ec, cap: usize, out: &mut Vec<u8>) -> i32 {
    ec.reset();
    let w = cdf.words_mut();
    for s in syms {
        if s.is_bool != 0 {
            ec.bool(s.s != 0);
        } else {
            ec.symbol_dyn(s.s as u32, &mut w[s.cdf_off as usize..], s.n as u32);
        }
    }
    out.clear();
    let n = ec.finish(out);
    if n > cap {
        out.clear();
        return -1;
    }
    n as i32
}

// ---- the set ----

/// av1t_dsp_set (av1core_test.h): the set as Swift reads it. Arrays are tightly packed per case.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct DspSetC {
    // 1. dequant + inverse transform: coeffs in, residual and conformance flags out
    pub itx_count: i32,
    pub itx_flagged_count: i32,
    pub itx_cases: *const c_void,
    pub itx_case_size: u32,
    pub itx_coeffs_per_case: u32,
    pub itx_residual_per_case: u32,
    pub itx_coeffs: *const i16,
    pub itx_residual: *const i32,
    pub itx_flags: *const u32,
    // 2./3. intra prediction + CfL: a side x side plane per case in, predicted plane out
    pub pred_count: i32,
    pub pred_cfl_count: i32,
    pub pred_side: i32,
    pub pred_cases: *const c_void,
    pub pred_case_size: u32,
    pub pred_luma_size: u32,
    pub pred_planes: *const u8,
    pub pred_luma: *const u8,
    pub pred_out: *const u8,
    // 4. range coder: symbol streams in, coded bytes out (ec_capacity per stream)
    pub ec_count: i32,
    pub ec_qindex: i32,
    pub ec_symbol_count: i32,
    pub ec_capacity: u32,
    pub ec_cdfs_size: u32,
    pub ec_symbol_size: u32,
    pub ec_symbols: *const c_void,
    pub ec_offsets: *const i32,
    pub ec_counts: *const i32,
    pub ec_sizes: *const i32,
    pub ec_bytes: *const u8,
    pub priv_: *mut c_void,
}

/// The cases and the CPU's results (the C++'s `Set`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DspSet {
    pub itx: Vec<ItxCase>,
    /// ITX_COEFFS per case
    pub itx_coeffs: Vec<i16>,
    /// ITX_RESIDUAL per case
    pub itx_residual: Vec<i32>,
    pub itx_flags: Vec<u32>,
    pub itx_flagged_count: i32,
    pub pred: Vec<PredCase>,
    /// PW x PW per case
    pub pred_planes: Vec<u8>,
    /// (2 PW)^2, shared by every case
    pub pred_luma: Vec<u8>,
    /// PW x PW per case
    pub pred_out: Vec<u8>,
    pub pred_cfl_count: i32,
    pub ec_qindex: i32,
    pub ec_capacity: u32,
    pub ec_symbols: Vec<Sym>,
    pub ec_offsets: Vec<i32>,
    pub ec_counts: Vec<i32>,
    pub ec_sizes: Vec<i32>,
    /// ec_capacity per stream
    pub ec_bytes: Vec<u8>,
}

/// xorshift64, the low 32 bits.
struct Rng {
    s: u64,
}

impl Rng {
    fn next(&mut self) -> u32 {
        self.s ^= self.s << 13;
        self.s ^= self.s >> 7;
        self.s ^= self.s << 17;
        self.s as u32
    }
}

fn make_itx(rnd: &mut Rng, s: &mut DspSet, n: usize) {
    s.itx = vec![ItxCase::default(); n];
    s.itx_coeffs = vec![0; n * ITX_COEFFS];
    for i in 0..n {
        let c = &mut s.itx[i];
        c.tx_sz = (rnd.next() % 19) as i32;
        let sqr_up = Tx_Size_Sqr_Up[c.tx_sz as usize] as i32;
        c.tx_type = if sqr_up == TX_64X64 {
            DCT_DCT
        } else {
            (rnd.next() % 16) as i32
        };
        if sqr_up == TX_32X32 && c.tx_type != IDTX {
            c.tx_type = DCT_DCT;
        }
        let qi = 1 + (rnd.next() % 255) as i32;
        c.dc_q = dc_q(qi);
        c.ac_q = ac_q(qi);
        // half the cases with quantizer matrices
        c.qm_level = if !rnd.next().is_multiple_of(2) {
            (rnd.next() % 16) as i32
        } else {
            -1
        };
        c.plane = (rnd.next() % 3) as i32;
        let nc = tx_coeffs(c.tx_sz) as u32;
        let k = 1 + rnd.next() % 12;
        for _ in 0..k {
            let pos = if rnd.next().is_multiple_of(3) {
                rnd.next() % nc
            } else {
                rnd.next() % nc.min(16)
            };
            let mag = if rnd.next().is_multiple_of(10) {
                (rnd.next() % 3000) as i32
            } else {
                (rnd.next() % 40) as i32
            };
            s.itx_coeffs[i * ITX_COEFFS + pos as usize] = (if rnd.next() & 1 != 0 { -mag } else { mag }) as i16;
        }
    }
    s.itx_residual = vec![0; n * ITX_RESIDUAL];
    s.itx_flags = vec![0; n];
    let mut scratch = vec![0i32; ITX_COEFFS];
    for i in 0..n {
        s.itx_flags[i] = itx_run(
            &s.itx[i],
            &s.itx_coeffs[i * ITX_COEFFS..][..ITX_COEFFS],
            &mut s.itx_residual[i * ITX_RESIDUAL..][..ITX_RESIDUAL],
            &mut scratch,
        );
    }
}

fn make_pred(rnd: &mut Rng, s: &mut DspSet, n: usize) {
    s.pred = vec![PredCase::default(); n];
    s.pred_planes = (0..n * PW * PW).map(|_| rnd.next() as u8).collect();
    s.pred_luma = (0..4 * PW * PW).map(|_| rnd.next() as u8).collect();
    let mut ncfl = 0;
    for c in &mut s.pred {
        let t = (rnd.next() % 19) as usize;
        c.log2w = Tx_Width_Log2[t] as i32;
        c.log2h = Tx_Height_Log2[t] as i32;
        c.mode = (rnd.next() % 13) as i32;
        c.delta = if is_directional(c.mode) {
            (rnd.next() % 7) as i32 - 3
        } else {
            0
        };
        c.have_left = (rnd.next() & 1) as i32;
        c.have_above = (rnd.next() & 1) as i32;
        c.have_ar = (rnd.next() & 1) as i32;
        c.have_bl = (rnd.next() & 1) as i32;
        c.x = if c.have_left != 0 {
            1 + (rnd.next() % 8) as i32
        } else {
            0
        };
        c.y = if c.have_above != 0 {
            1 + (rnd.next() % 8) as i32
        } else {
            0
        };
        c.max_x = (c.x + (1 << c.log2w) + (rnd.next() % 64) as i32 - 1).min(PW as i32 - 1);
        c.max_y = (c.y + (1 << c.log2h) + (rnd.next() % 64) as i32 - 1).min(PW as i32 - 1);
        c.edge_filter = (rnd.next() & 1) as i32;
        c.filter_type = (rnd.next() & 1) as i32;
        c.fi_mode = if c.mode == DC_PRED && c.log2w <= 5 && c.log2h <= 5 && rnd.next() & 1 != 0 {
            (rnd.next() % 5) as i32
        } else {
            -1
        };
        c.cfl = (c.log2w <= 5 && c.log2h <= 5 && rnd.next().is_multiple_of(3)) as i32;
        if c.cfl != 0 {
            c.mode = DC_PRED;
            c.delta = 0;
            c.alpha = (rnd.next() % 33) as i32 - 16;
            c.fi_mode = -1;
            ncfl += 1;
        }
    }
    s.pred_out = vec![0; s.pred_planes.len()];
    for i in 0..n {
        let k = i * PW * PW;
        pred_run(
            &s.pred[i],
            &s.pred_planes[k..k + PW * PW],
            &s.pred_luma,
            &mut s.pred_out[k..k + PW * PW],
        );
    }
    s.pred_cfl_count = ncfl;
}

fn make_ec(rnd: &mut Rng, s: &mut DspSet, n: usize, qidx: i32, cap: usize) {
    // pick symbols from the real CDF layout: (u16 offset, N, number of CDFs) of a few arrays
    const ARRS: [(usize, u16, u32); 8] = [
        (offset_of!(Cdfs, y_mode) / 2, 13, 25),
        (offset_of!(Cdfs, skip) / 2, 2, 3),
        (offset_of!(Cdfs, coeff_base) / 2, 4, 5 * 2 * 42),
        (offset_of!(Cdfs, coeff_br) / 2, 4, 5 * 2 * 21),
        (offset_of!(Cdfs, txb_skip) / 2, 2, 5 * 13),
        (offset_of!(Cdfs, partition_w64) / 2, 10, 4),
        (offset_of!(Cdfs, cfl_alpha) / 2, 16, 6),
        (offset_of!(Cdfs, eob_pt_1024) / 2, 11, 2),
    ];
    s.ec_offsets = vec![0; n];
    s.ec_counts = vec![0; n];
    for i in 0..n {
        s.ec_offsets[i] = s.ec_symbols.len() as i32;
        s.ec_counts[i] = 1 + (rnd.next() % 8000) as i32;
        for _ in 0..s.ec_counts[i] {
            let sym = if rnd.next().is_multiple_of(6) {
                Sym {
                    is_bool: 1,
                    s: (rnd.next() & 1) as u16,
                    cdf_off: 0,
                    n: 2,
                }
            } else {
                let (off, an, count) = ARRS[(rnd.next() % 8) as usize];
                let ctx = (rnd.next() % count) as usize;
                Sym {
                    is_bool: 0,
                    n: an,
                    cdf_off: (off + ctx * (an as usize + 1)) as u16,
                    s: (if !rnd.next().is_multiple_of(4) {
                        rnd.next() % 2
                    } else {
                        rnd.next() % an as u32
                    }) as u16,
                }
            };
            s.ec_symbols.push(sym);
        }
    }
    s.ec_sizes = vec![0; n];
    s.ec_bytes = vec![0; n * cap];
    let mut ec = Ec::with_capacity(cap);
    let mut out = Vec::with_capacity(cap);
    for i in 0..n {
        let mut c = Cdfs::new(qidx);
        let syms = &s.ec_symbols[s.ec_offsets[i] as usize..][..s.ec_counts[i] as usize];
        s.ec_sizes[i] = ec_stream(syms, &mut c, &mut ec, cap, &mut out);
        s.ec_bytes[i * cap..][..out.len()].copy_from_slice(&out);
    }
}

impl DspSet {
    /// av1t_dsp_set_make: the cases of `seed` (deterministic; 0 picks a fixed seed) and their CPU
    /// results: 2048 inverse transforms, 1024 predictions, 128 symbol streams.
    pub fn make(seed: u64) -> DspSet {
        let mut rnd = Rng {
            s: if seed != 0 { seed } else { 0x123456789abcdef },
        };
        const N_ITX: usize = 2048;
        const N_PRED: usize = 1024;
        const N_EC: usize = 128;
        const QIDX: i32 = 100;
        const CAP: u32 = 1 << 15;
        let mut s = DspSet {
            ec_qindex: QIDX,
            ec_capacity: CAP,
            ..DspSet::default()
        };
        make_itx(&mut rnd, &mut s, N_ITX);
        make_pred(&mut rnd, &mut s, N_PRED);
        make_ec(&mut rnd, &mut s, N_EC, QIDX, CAP as usize);
        s.itx_flagged_count = s.itx_flags.iter().filter(|&&f| f != 0).count() as i32;
        s
    }

    /// The av1t_dsp_set view of the set, pointing into it (`priv_` null).
    pub fn c_view(&self) -> DspSetC {
        DspSetC {
            itx_count: self.itx.len() as i32,
            itx_flagged_count: self.itx_flagged_count,
            itx_cases: self.itx.as_ptr() as *const c_void,
            itx_case_size: size_of::<ItxCase>() as u32,
            itx_coeffs_per_case: ITX_COEFFS as u32,
            itx_residual_per_case: ITX_RESIDUAL as u32,
            itx_coeffs: self.itx_coeffs.as_ptr(),
            itx_residual: self.itx_residual.as_ptr(),
            itx_flags: self.itx_flags.as_ptr(),
            pred_count: self.pred.len() as i32,
            pred_cfl_count: self.pred_cfl_count,
            pred_side: PW as i32,
            pred_cases: self.pred.as_ptr() as *const c_void,
            pred_case_size: size_of::<PredCase>() as u32,
            pred_luma_size: self.pred_luma.len() as u32,
            pred_planes: self.pred_planes.as_ptr(),
            pred_luma: self.pred_luma.as_ptr(),
            pred_out: self.pred_out.as_ptr(),
            ec_count: self.ec_sizes.len() as i32,
            ec_qindex: self.ec_qindex,
            ec_symbol_count: self.ec_symbols.len() as i32,
            ec_capacity: self.ec_capacity,
            ec_cdfs_size: size_of::<Cdfs>() as u32,
            ec_symbol_size: size_of::<Sym>() as u32,
            ec_symbols: self.ec_symbols.as_ptr() as *const c_void,
            ec_offsets: self.ec_offsets.as_ptr(),
            ec_counts: self.ec_counts.as_ptr(),
            ec_sizes: self.ec_sizes.as_ptr(),
            ec_bytes: self.ec_bytes.as_ptr(),
            priv_: core::ptr::null_mut(),
        }
    }
}

/// av1t_dsp_set_make: [`DspSet::make`].
pub fn dsp_set_make(seed: u64) -> DspSet {
    DspSet::make(seed)
}

/// av1t_inverse_transform: av1core's exact 2-D inverse transform of dequantized coefficients
/// (th x tw, row-major, at most 32x32) into `residual` (h x w). Returns the conformance flags.
pub fn inverse_transform(tx_sz: i32, tx_type: i32, dq: &[i32], residual: &mut [i32]) -> u32 {
    inv_txfm2d(dq, tx_sz, tx_type, residual)
}

/// av1t_tx_type_allowed: whether `tx_type` is in `tx_sz`'s intra set (DCT only for 64-point sizes).
pub fn tx_type_allowed(tx_sz: i32, tx_type: i32) -> bool {
    if Tx_Size_Sqr_Up[tx_sz as usize] as i32 > TX_32X32 {
        return tx_type == DCT_DCT;
    }
    tx_type_in_set_intra(get_tx_set_intra(tx_sz, false), tx_type)
}
