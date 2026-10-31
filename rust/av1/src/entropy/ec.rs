//! The AV1 multi-symbol range encoder (od_ec) and CDF adaptation (av1g/entenc.h).
//!
//! A port of libaom aom_dsp/entenc.c with a 16-bit precarry buffer, as the C++ (which has the
//! classic 32-bit window; this one is 64 bits wide, like current libaom's, for the same bytes), with
//! CDFs in the spec's format: cumulative, `cdf[N - 1] == 32768`, `cdf[N]` the adaptation counter.

/// od_ec: the encoder state and its precarry buffer (one u16 per output byte, carries resolved in
/// [`Ec::finish`]). The buffer grows as needed and keeps its capacity across [`Ec::reset`], so a
/// reused encoder doesn't allocate.
#[derive(Clone, Debug)]
pub struct Ec {
    low: u64, // od_ec_window
    rng: u32,
    cnt: i32,
    precarry: Vec<u16>,
}

/// The window holds `cnt + 25` bits (with a carry); bytes leave once `cnt` reaches this, which
/// keeps it under 32 + 15 and the window (and the flush's rounding) inside 64 bits.
const FLUSH_AT: i32 = 32;

impl Default for Ec {
    fn default() -> Self {
        Self::new()
    }
}

impl Ec {
    pub fn new() -> Self {
        Self::with_capacity(1 << 16)
    }

    /// An encoder whose precarry buffer starts with room for `bytes` output bytes.
    pub fn with_capacity(bytes: usize) -> Self {
        Ec {
            low: 0,
            rng: 0x8000,
            cnt: -9,
            precarry: Vec::with_capacity(bytes),
        }
    }

    /// av1g_ec_init, keeping the buffer.
    pub fn reset(&mut self) {
        self.low = 0;
        self.rng = 0x8000;
        self.cnt = -9;
        self.precarry.clear();
    }

    /// Precarry entries written so far: output bytes, lagging the coded bits by up to 6 bytes.
    #[inline]
    pub fn len(&self) -> usize {
        self.precarry.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.precarry.is_empty()
    }

    /// Renormalizes after coding a symbol. The window is 64 bits, so the bytes the 32-bit
    /// formulation would push one or two at a time leave in batches of 5 or 6, with the same
    /// precarry values summed into the same bytes; the flush branch is taken 5x less often.
    #[inline(always)]
    fn normalize(&mut self, mut low: u64, rng: u32) {
        let d = rng.leading_zeros() as i32 - 16; // 16 - ilog_nz(rng)
        let mut s = self.cnt + d;
        if s >= FLUSH_AT {
            // (s >> 3) + 1 bytes: the first with the carry above it, the rest masked
            let mut c = self.cnt + 16;
            let k = (s >> 3) + 1;
            for _ in 0..k {
                self.precarry.push((low >> c) as u16);
                low &= (1u64 << c) - 1;
                c -= 8;
            }
            s -= 8 * k;
        }
        self.low = low << d;
        self.rng = rng << d;
        self.cnt = s;
    }

    /// od_ec_encode_q15: `fl = 32768 - cumfreq(before s)`, `fh = 32768 - cumfreq(through s)`.
    #[inline(always)]
    pub fn encode_q15(&mut self, fl: u32, fh: u32, s: u32, nsyms: u32) {
        let r = self.rng;
        let n = nsyms.wrapping_sub(1);
        // fl == 32768 (the first symbol) is u = r: low stays, r - v remains. Branch-free.
        let u =
            (((r >> 8).wrapping_mul(fl >> 6)) >> 1).wrapping_add(4u32.wrapping_mul(n.wrapping_sub(s.wrapping_sub(1))));
        let u = if fl < 32768 { u } else { r };
        let v = (((r >> 8).wrapping_mul(fh >> 6)) >> 1).wrapping_add(4u32.wrapping_mul(n.wrapping_sub(s)));
        let l = self.low.wrapping_add(r.wrapping_sub(u) as u64);
        self.normalize(l, u.wrapping_sub(v));
    }

    /// av1g_ec_encode_cdf: symbol `s` of an `n`-symbol spec-format CDF, without adaptation.
    #[inline(always)]
    pub fn encode_cdf(&mut self, s: u32, cdf: &[u16], n: u32) {
        let fl = if s > 0 {
            32768u32.wrapping_sub(cdf[s as usize - 1] as u32)
        } else {
            32768
        };
        let fh = 32768u32.wrapping_sub(cdf[s as usize] as u32);
        self.encode_q15(fl, fh, s, n);
    }

    /// av1g_ec_symbol (the S() descriptor): codes `s` with `cdf` (`N = L - 1` symbols, `cdf[N]` the
    /// counter), then adapts it. The writer's CDFs are fixed-size arrays, so `N` is a constant
    /// and the update is straight-line code.
    #[inline(always)]
    pub fn symbol<const L: usize>(&mut self, s: u32, cdf: &mut [u16; L]) {
        self.encode_cdf(s, cdf, (L - 1) as u32);
        update_cdf_n::<L>(cdf, s);
    }

    /// av1g_ec_symbol with the alphabet size known at run time (2..=16; `cdf.len() > n`).
    #[inline(always)]
    pub fn symbol_dyn(&mut self, s: u32, cdf: &mut [u16], n: u32) {
        self.encode_cdf(s, cdf, n);
        update_cdf(cdf, s, n);
    }

    /// read_bool(): an equiprobable bit, cdf {16384, 32768}, never adapted.
    #[inline(always)]
    pub fn bool(&mut self, bit: bool) {
        if bit {
            self.encode_q15(16384, 0, 1, 2)
        } else {
            self.encode_q15(32768, 16384, 0, 2)
        }
    }

    /// L(n): an `n`-bit literal, MSB first.
    #[inline]
    pub fn literal(&mut self, v: u32, n: u32) {
        for i in (0..n).rev() {
            self.bool((v >> i) & 1 != 0);
        }
    }

    /// split_or_horz / split_or_vert (spec 8.3.2): the bool `b` with the probability derived from
    /// the current partition CDF `pc` (10 symbols: 8x8 blocks never need it), which isn't adapted.
    #[inline(always)]
    pub fn split_or(&mut self, pc: &[u16], vert: bool, b: bool) {
        let tmp = [32768u32.wrapping_sub(super::split_or_psum(pc, vert)) as u16, 32768, 0];
        self.encode_cdf(b as u32, &tmp, 2);
    }

    /// av1g_ec_done: flushes, resolves the carries and appends the bytes to `out`. Returns their
    /// number. The encoder is reset for the next tile.
    pub fn finish(&mut self, out: &mut Vec<u8>) -> usize {
        let l = self.low;
        let mut c = self.cnt;
        let mut s = 10 + c;
        let m = 0x3FFFu64;
        let mut en = (l.wrapping_add(m) & !m) | (m + 1);
        if s > 0 {
            let mut n = (1u64 << (c + 16)) - 1;
            loop {
                self.precarry.push((en >> (c + 16)) as u16);
                en &= n;
                s -= 8;
                c -= 8;
                n >>= 8;
                if s <= 0 {
                    break;
                }
            }
        }
        let len = self.precarry.len();
        let start = out.len();
        out.resize(start + len, 0);
        let mut carry = 0u32;
        for (o, &p) in out[start..].iter_mut().zip(&self.precarry).rev() {
            carry += p as u32;
            *o = carry as u8;
            carry >>= 8;
        }
        self.reset();
        len
    }
}

/// The adaptation rate of av1g_update_cdf: `3 + (cnt > 15) + (cnt > 31) + Min(FloorLog2(N), 2)`.
#[inline(always)]
fn rate(cnt: u16, n: u32) -> u32 {
    3 + (cnt > 15) as u32 + (cnt > 31) as u32 + if n >= 4 { 2 } else { 1 }
}

#[inline(always)]
fn adapt(v: u16, below: bool, rate: u32) -> u16 {
    let v = v as i32;
    (if below {
        v - (v >> rate)
    } else {
        v + ((32768 - v) >> rate)
    }) as u16
}

/// av1g_update_cdf (spec 8.2.6 with disable_cdf_update = 0) for an `L - 1`-symbol CDF.
#[inline(always)]
pub fn update_cdf_n<const L: usize>(cdf: &mut [u16; L], s: u32) {
    let n = (L - 1) as u32;
    let cnt = cdf[L - 1];
    let r = rate(cnt, n);
    #[cfg(target_arch = "aarch64")]
    if L >= 4 {
        neon::update_fixed(cdf, s, r);
        cdf[L - 1] = cnt + (cnt < 32) as u16;
        return;
    }
    for (i, v) in cdf[..L - 2].iter_mut().enumerate() {
        *v = adapt(*v, (i as u32) < s, r);
    }
    cdf[L - 1] = cnt + (cnt < 32) as u16;
}

/// av1g_update_cdf for an `n`-symbol CDF (`n` in 2..=16, `cdf.len() > n`). With 8 words in
/// `cdf` for `n <= 9`, or 16, the update runs on whole vectors (a CDF inside [`super::Cdfs`]'s
/// words, as the symbol streams have it).
#[inline(always)]
pub fn update_cdf(cdf: &mut [u16], s: u32, n: u32) {
    #[cfg(target_arch = "aarch64")]
    if (2..=16).contains(&n) && cdf.len() >= if n <= 9 { 8 } else { 16 } {
        let cnt = cdf[n as usize];
        neon::update_tail(cdf, s, n, rate(cnt, n));
        cdf[n as usize] = cnt + (cnt < 32) as u16;
        return;
    }
    update_cdf_scalar(cdf, s, n)
}

/// av1g_update_cdf as the C loop: the reference the other updates are tested against.
#[inline(always)]
pub fn update_cdf_scalar(cdf: &mut [u16], s: u32, n: u32) {
    let n_ = n as usize;
    let cnt = cdf[n_];
    let r = rate(cnt, n);
    for i in 0..n_.saturating_sub(1) {
        cdf[i] = adapt(cdf[i], (i as u32) < s, r);
    }
    cdf[n_] = cnt + (cnt < 32) as u16;
}

/// The adaptation on NEON: `v - (v >> rate)` below the symbol, `v + ((32768 - v) >> rate)` from it
/// on (the same as [`adapt`] for CDF values <= 32768).
#[cfg(target_arch = "aarch64")]
mod neon {
    use core::arch::aarch64::*;

    const IDX: [u16; 16] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

    /// Adapts lanes `lo..hi` of the 8 at `p` (lane i is CDF entry `first + i`), keeps the others.
    /// SAFETY: 8 u16 readable and writable at p.
    #[inline(always)]
    unsafe fn lanes8(p: *mut u16, first: u16, lo: u16, hi: u16, s: u32, r: u32) {
        unsafe {
            let idx = vaddq_u16(vld1q_u16(IDX.as_ptr()), vdupq_n_u16(first));
            let sh = vdupq_n_s16(-(r as i16));
            let v = vld1q_u16(p);
            let dec = vsubq_u16(v, vshlq_u16(v, sh));
            let inc = vaddq_u16(v, vshlq_u16(vsubq_u16(vdupq_n_u16(32768), v), sh));
            let new = vbslq_u16(vcltq_u16(idx, vdupq_n_u16(s as u16)), dec, inc);
            let upd = vandq_u16(vcgeq_u16(idx, vdupq_n_u16(lo)), vcltq_u16(idx, vdupq_n_u16(hi)));
            vst1q_u16(p, vbslq_u16(upd, new, v));
        }
    }

    /// The same on 4 lanes. SAFETY: 4 u16 readable and writable at p.
    #[inline(always)]
    unsafe fn lanes4(p: *mut u16, first: u16, lo: u16, hi: u16, s: u32, r: u32) {
        unsafe {
            let idx = vadd_u16(vld1_u16(IDX.as_ptr()), vdup_n_u16(first));
            let sh = vdup_n_s16(-(r as i16));
            let v = vld1_u16(p);
            let dec = vsub_u16(v, vshl_u16(v, sh));
            let inc = vadd_u16(v, vshl_u16(vsub_u16(vdup_n_u16(32768), v), sh));
            let new = vbsl_u16(vclt_u16(idx, vdup_n_u16(s as u16)), dec, inc);
            let upd = vand_u16(vcge_u16(idx, vdup_n_u16(lo)), vclt_u16(idx, vdup_n_u16(hi)));
            vst1_u16(p, vbsl_u16(upd, new, v));
        }
    }

    /// Lanes `0..L - 2` of a fixed-size CDF (L >= 4) with loads inside the array only: a second,
    /// overlapping vector covers the end. It is stored first, so that its copies of the first
    /// vector's lanes (kept unchanged) don't overwrite them.
    #[inline(always)]
    pub fn update_fixed<const L: usize>(cdf: &mut [u16; L], s: u32, r: u32) {
        let m = (L - 2) as u16; // lanes to adapt
        let p = cdf.as_mut_ptr();
        // SAFETY: every access is inside the L-word array: the branches on the constant L keep
        // offset + width <= L.
        unsafe {
            if L >= 8 {
                if m > 8 {
                    let off = if L - 8 < 8 { L - 8 } else { 8 };
                    lanes8(p.add(off), off as u16, 8, m, s, r);
                }
                lanes8(p, 0, 0, m, s, r);
            } else {
                if m > 4 {
                    lanes4(p.add(L - 4), (L - 4) as u16, 4, m, s, r);
                }
                lanes4(p, 0, 0, m, s, r);
            }
        }
    }

    /// Lanes `0..n - 1` of the CDF at the start of `cdf`, which holds 8 words (n <= 9) or 16.
    #[inline(always)]
    pub fn update_tail(cdf: &mut [u16], s: u32, n: u32, r: u32) {
        assert!(cdf.len() >= if n <= 9 { 8 } else { 16 });
        let p = cdf.as_mut_ptr();
        // SAFETY: the assert covers both vectors.
        unsafe {
            lanes8(p, 0, 0, (n - 1) as u16, s, r);
            if n > 9 {
                lanes8(p.add(8), 8, 0, (n - 1) as u16, s, r);
            }
        }
    }
}
