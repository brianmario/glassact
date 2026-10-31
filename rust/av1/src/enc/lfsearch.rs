//! The host half of the deblocking-level and CDEF-strength search (Sources/AV1Encoder/src/
//! lfsearch.cpp; AV1MetalPostfilter.search, Shaders/postfilter.metal): libaom's RD choice of
//! cdef_bits and the presets it signals, and a sequential reference of the GPU's joint preset
//! search for the tests. The tune=iq frame decisions are in [`super::tuneiq`].
//!
//! From av1gpu's av1f/src/lfsearch.cu (BSD-2), the AV1F_LF_FROM_Q + AV1F_CDEF_AOM path (libaom s6:
//! LPF_PICK_FROM_Q, CDEF_FAST_SEARCH_LVL4, tune=iq CDEF_ADAPTIVE) with SSE distortion.
use crate::types::{FrameParams, GaCdefCand};

/// av1enc_cdef_bits: libaom's RD choice of cdef_bits. `tots[i]` is the joint search's SSE with 2^i
/// presets (`max_bits + 1` of them), `n_active` the 64x64s that code a cdef_idx.
pub fn cdef_bits(tots: &[u64], max_bits: i32, n_active: i32, mono: bool, rdmult: i32) -> i32 {
    let mut best = 0;
    let mut best_rd = 0.0;
    for i in 0..=max_bits {
        let nb = 1i64 << i;
        let bits = n_active as i64 * i as i64 + nb * 6 * if mono { 1 } else { 2 };
        // libaom's integer RDCOST: ((bits * 512 * rdmult + 256) >> 9) + sse * 16 * 128
        let rd = ((bits.wrapping_mul(512).wrapping_mul(rdmult as i64).wrapping_add(256)) >> 9) as f64
            + tots[i as usize] as f64 * 2048.0;
        if i == 0 || rd < best_rd {
            best_rd = rd;
            best = i;
        }
    }
    best
}

/// av1enc_cdef_presets: writes enable_cdef, cdef_bits and the presets the search chose (`lev`: 8
/// luma then 8 chroma candidate indices) into `fp`, halving them in CDEF mode 1 as libaom's
/// CDEF_ADAPTIVE does.
pub fn cdef_presets(lev: &[i32; 16], bits: i32, cdef_mode: i32, cd: &GaCdefCand, fp: &mut FrameParams) {
    let nb = 1usize << bits;
    fp.enable_cdef = 1;
    fp.cdef_bits = bits as u8;
    fp.cdef_y_pri = [0; 8];
    fp.cdef_y_sec = [0; 8];
    fp.cdef_uv_pri = [0; 8];
    fp.cdef_uv_sec = [0; 8];
    let sig = |s: i32| if s == 4 { 3 } else { s };
    let app = |s: i32| if s == 3 { 4 } else { s };
    for j in 0..nb {
        let (jy, juv) = (lev[j], lev[8 + j]);
        let mut yp = cd.pri[(jy / cd.nsec) as usize];
        let mut ys = cd.sec[(jy % cd.nsec) as usize];
        let (mut up, mut us) = (cd.pri[(juv / cd.nsec) as usize], cd.sec[(juv % cd.nsec) as usize]);
        if fp.monochrome != 0 {
            (up, us) = (0, 0);
        }
        if cdef_mode == 1 {
            // CDEF_ADAPTIVE: halve the signalled values
            yp >>= 1;
            up >>= 1;
            ys = app(sig(ys) >> 1);
            us = app(sig(us) >> 1);
        }
        fp.cdef_y_pri[j] = yp as u8;
        fp.cdef_y_sec[j] = ys as u8;
        fp.cdef_uv_pri[j] = up as u8;
        fp.cdef_uv_sec[j] = us as u8;
    }
}

/// av1enc_cdef_select_cpu: the joint greedy preset search (libaom search_one_dual + refinement) on
/// per-SB SSE tables (`[nsb][nc]`, luma and chroma; `muv` unused, and may be empty, for mono),
/// sequentially: the reference the GPU's search is held to. Writes `(max_bits + 1) x 16` levels to
/// `lev_out` and `max_bits + 1` totals to `tot_out`.
#[allow(clippy::too_many_arguments)]
pub fn cdef_select_cpu(
    my: &[u32],
    muv: &[u32],
    nc: usize,
    nsb: usize,
    mono: bool,
    max_bits: usize,
    refine: usize,
    fast_mono: bool,
    lev_out: &mut [i32],
    tot_out: &mut [u64],
) {
    let pairs = if mono { nc } else { nc * nc };
    let my = &my[..nsb * nc];
    let muv = if mono { &[][..] } else { &muv[..nsb * nc] };
    // Every SB's cost under every (luma, chroma) candidate pair fits 32 bits for real SSE tables
    // (a 64x64's luma and chroma SSE together stay under 2^29): then the search runs on per-pair
    // rows, and each step is a vectorizable min and widening sum. Otherwise, the reference loop.
    let fits = my.iter().max().copied().unwrap_or(0) as u64 + muv.iter().max().copied().unwrap_or(0) as u64
        <= u32::MAX as u64;
    if fits && pairs <= 16 {
        return select_rows(my, muv, nc, nsb, mono, max_bits, refine, fast_mono, lev_out, tot_out);
    }
    let mut lev = [0usize; 16];
    let mut cur = vec![0u64; nsb];
    let mut tot = vec![0u64; pairs];
    for i in 0..=max_bits {
        let nb = 1 << i;
        let steps = nb + if fast_mono { 0 } else { refine * nb };
        for st in 0..steps {
            let k = if st < nb { st } else { nb - 1 };
            if st >= nb {
                for j in 0..nb - 1 {
                    lev[j] = lev[j + 1];
                    lev[8 + j] = lev[8 + j + 1];
                }
            }
            for (sb, c) in cur.iter_mut().enumerate() {
                let mut b = u64::MAX;
                for g in 0..k {
                    let mut c = my[sb * nc + lev[g]] as u64;
                    if !mono {
                        c += muv[sb * nc + lev[8 + g]] as u64;
                    }
                    b = b.min(c);
                }
                *c = b;
            }
            for (p, t) in tot.iter_mut().enumerate() {
                let (pj, pk) = if mono { (p, 0) } else { (p / nc, p % nc) };
                let mut s = 0u64;
                for (sb, &cb) in cur.iter().enumerate() {
                    let mut c = my[sb * nc + pj] as u64;
                    if !mono {
                        c += muv[sb * nc + pk] as u64;
                    }
                    s = s.wrapping_add(c.min(cb));
                }
                *t = s;
            }
            let mut bi = 0;
            for q in 1..pairs {
                if tot[q] < tot[bi] {
                    bi = q;
                }
            }
            lev[k] = if mono { bi } else { bi / nc };
            lev[8 + k] = if mono { 0 } else { bi % nc };
            tot_out[i] = tot[bi];
        }
        for j in 0..16 {
            lev_out[i * 16 + j] = lev[j] as i32;
        }
    }
}

/// cdef_select_cpu on per-pair rows: `rows[p][sb]` is SB sb's cost under candidate pair p (luma p / nc,
/// chroma p % nc; luma p for mono). Same steps, same results.
#[allow(clippy::too_many_arguments)]
fn select_rows(
    my: &[u32],
    muv: &[u32],
    nc: usize,
    nsb: usize,
    mono: bool,
    max_bits: usize,
    refine: usize,
    fast_mono: bool,
    lev_out: &mut [i32],
    tot_out: &mut [u64],
) {
    let pairs = if mono { nc } else { nc * nc };
    let mut rows = vec![0u32; pairs * nsb];
    for (p, row) in rows.chunks_exact_mut(nsb).enumerate() {
        let (pj, pk) = if mono { (p, 0) } else { (p / nc, p % nc) };
        for (sb, r) in row.iter_mut().enumerate() {
            *r = my[sb * nc + pj] + if mono { 0 } else { muv[sb * nc + pk] };
        }
    }
    let pair_of = |lev: &[usize; 16], g: usize| if mono { lev[g] } else { lev[g] * nc + lev[8 + g] };
    let mut lev = [0usize; 16];
    let mut cur = vec![0u32; nsb];
    let mut tot = [0u64; 16];
    for i in 0..=max_bits {
        let nb = 1 << i;
        let steps = nb + if fast_mono { 0 } else { refine * nb };
        for st in 0..steps {
            let k = if st < nb { st } else { nb - 1 };
            if st >= nb {
                for j in 0..nb - 1 {
                    lev[j] = lev[j + 1];
                    lev[8 + j] = lev[8 + j + 1];
                }
            }
            // the cost with the k presets kept (none: no bound)
            cur.fill(u32::MAX);
            for g in 0..k {
                let row = &rows[pair_of(&lev, g) * nsb..][..nsb];
                for (c, &r) in cur.iter_mut().zip(row) {
                    *c = (*c).min(r);
                }
            }
            for (p, t) in tot[..pairs].iter_mut().enumerate() {
                *t = min_sum(&rows[p * nsb..][..nsb], &cur);
            }
            let mut bi = 0;
            for q in 1..pairs {
                if tot[q] < tot[bi] {
                    bi = q;
                }
            }
            lev[k] = if mono { bi } else { bi / nc };
            lev[8 + k] = if mono { 0 } else { bi % nc };
            tot_out[i] = tot[bi];
        }
        for j in 0..16 {
            lev_out[i * 16 + j] = lev[j] as i32;
        }
    }
}

/// sum over i of min(a[i], b[i]), widened to u64
#[inline]
fn min_sum(a: &[u32], b: &[u32]) -> u64 {
    #[cfg(target_arch = "aarch64")]
    {
        use core::arch::aarch64::*;
        let n = a.len().min(b.len());
        let mut i = 0;
        // SAFETY: loads stay within i + 8 <= n; NEON is baseline on aarch64.
        let mut acc = unsafe { [vdupq_n_u64(0); 2] };
        unsafe {
            while i + 8 <= n {
                let m0 = vminq_u32(vld1q_u32(a.as_ptr().add(i)), vld1q_u32(b.as_ptr().add(i)));
                let m1 = vminq_u32(vld1q_u32(a.as_ptr().add(i + 4)), vld1q_u32(b.as_ptr().add(i + 4)));
                acc[0] = vpadalq_u32(acc[0], m0);
                acc[1] = vpadalq_u32(acc[1], m1);
                i += 8;
            }
        }
        // SAFETY: NEON is baseline on aarch64.
        let mut s = unsafe { vaddvq_u64(vaddq_u64(acc[0], acc[1])) };
        for j in i..n {
            s += a[j].min(b[j]) as u64;
        }
        s
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        a.iter().zip(b).map(|(&x, &y)| x.min(y) as u64).sum()
    }
}
