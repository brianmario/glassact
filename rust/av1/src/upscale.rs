//! Upscaling 8-bit pictures (one plane, or BGRA) by a separable filter in integers: the Viewer's
//! reduced frames (decisions.h "Reduced frames": coded smaller, shown at the stream's size), which
//! Glass Act's decoder shows scaled up to the region, as VideoToolbox does.
//!
//! - **Mapping:** sample centres, the full extents mapped onto each other (output x samples the
//!   source at `(x + 0.5) * src / dst - 0.5`), as vImage scales the Host's picture down. Taps
//!   outside the picture take its edge sample.
//! - **The filter** ([`Filter`]; Lanczos-5 by default): per axis and output position, `2 * radius`
//!   weights, rounded to integers that sum exactly to the pass's one (so a flat picture stays flat
//!   and alpha stays 255), from plain IEEE arithmetic ([`sinpi`]: no libm), so the tables, and so
//!   every output, are the same bits on aarch64 and x86_64.
//! - **Two passes, vertical first**, both with Q15 weights (summing to 32768) and each product
//!   rounded as `(a * w + 2^14) >> 15` (NEON's `vqrdmulh`, SSSE3's `pmulhrsw`), summed in i16:
//!   per output row, the source rows' weighted sum at the source's width, of the samples times 32
//!   (`p << 5`); then per output sample, that row's weighted sum, and `(sum + 16) >> 5` clamped to
//!   0..=255. [`Upscaler::scale`] checks that no sum can leave i16 for the filter's weights
//!   (Lanczos-5's lobes need the 32 rather than 64 a little over twice the size).
//! - **Exactly twice the size** on an axis (the Host's half-size frames, where the side is a
//!   multiple of 4): only two phases (±1/4), so the horizontal pass's SIMD takes fixed weights,
//!   with no table; other ratios (a side that isn't, whose coded size `(n / 2) & !1` is a little
//!   under half) take the table's per output sample. The vertical pass is the same either way.
//! - **SIMD** (NEON on aarch64, SSE4.1 on x86_64), with the scalar code the reference: a test holds
//!   every SIMD path to it exactly.
//! - **Threads:** bands of output rows on the pool ([`crate::pool::run`]), one task a thread, each
//!   with its own row of the vertical pass. An [`Upscaler`] keeps its tables and rows between
//!   pictures and rebuilds them only when the sizes change: a picture allocates no buffers (the
//!   pool takes a task record a call).
use std::sync::Mutex;

/// Taps per output sample, at most (the tables' stride; Lanczos-5 takes 10).
pub const MAX_TAPS: usize = 16;
/// Both passes' weights sum to this (Q15).
const ONE: i32 = 1 << 15;
/// Output rows a band of the pool's (a task takes bands from a queue until none is left).
const BAND_ROWS: usize = 16;
/// Lanes past the vertical pass's row that the horizontal pass's loads of 8 or 16 lanes may read
/// (with a weight of 0).
const PAD: usize = 16;

/// The upscaling filter. Lanczos-5 (10 taps) is the default: of the candidates the one as close
/// to the source as vImage's high-quality resampling, or closer, on video and on text alike
/// (BENCHMARKS "Glass Act's decoder scales reduced frames up itself"); the others are research.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Filter {
    #[default]
    Lanczos5,
    /// 6 taps: as close on video, 0.17 dB further on text.
    Lanczos3,
    /// 8 taps.
    Lanczos4,
    /// Lanczos with 2 lobes: 4 taps.
    Lanczos2,
    /// Catmull-Rom (the cubic with B = 0, C = 1/2): 4 taps.
    CatmullRom,
}

impl Filter {
    /// Its support, in source samples each side.
    pub fn radius(self) -> usize {
        match self {
            Filter::CatmullRom | Filter::Lanczos2 => 2,
            Filter::Lanczos3 => 3,
            Filter::Lanczos4 => 4,
            Filter::Lanczos5 => 5,
        }
    }

    /// Its kernel at `x` source samples from the output's position.
    fn kernel(self, x: f64) -> f64 {
        let ax = x.abs();
        match self {
            Filter::CatmullRom => {
                if ax < 1.0 {
                    1.5 * ax * ax * ax - 2.5 * ax * ax + 1.0
                } else if ax < 2.0 {
                    -0.5 * ax * ax * ax + 2.5 * ax * ax - 4.0 * ax + 2.0
                } else {
                    0.0
                }
            }
            _ => {
                let a = self.radius() as f64;
                if ax >= a { 0.0 } else { sinc(x) * sinc(x / a) }
            }
        }
    }

    /// From the C API's number (`AV1G_UPSCALE_*`).
    pub fn from_c(n: i32) -> Option<Filter> {
        Some(match n {
            0 => Filter::Lanczos5,
            1 => Filter::Lanczos3,
            2 => Filter::Lanczos4,
            3 => Filter::Lanczos2,
            4 => Filter::CatmullRom,
            _ => return None,
        })
    }
}

/// sin(πx) in plain IEEE arithmetic (a reduction to [-1/2, 1/2] and a Taylor series), so that the
/// filters' tables are the same bits on every architecture, whatever its libm.
pub fn sinpi(x: f64) -> f64 {
    let n = (x + 0.5).floor();
    let r = x - n;
    let z = core::f64::consts::PI * r;
    let z2 = z * z;
    let (mut term, mut sum) = (z, z);
    for k in 1..13 {
        let k = k as f64;
        term = -term * z2 / ((2.0 * k) * (2.0 * k + 1.0));
        sum += term;
    }
    if (n as i64) & 1 == 0 { sum } else { -sum }
}

fn sinc(x: f64) -> f64 {
    if x == 0.0 { 1.0 } else { sinpi(x) / (core::f64::consts::PI * x) }
}

/// One axis's taps: per output position, `taps` source indices (clamped to the picture) and
/// weights summing to the pass's one, [`MAX_TAPS`] apart (the rest 0).
#[derive(Clone, Debug, Default)]
struct Axis {
    src: usize,
    dst: usize,
    taps: usize,
    idx: Vec<u32>,
    w: Vec<i16>,
    /// the outputs whose taps are all inside the source (none clamped), from `idx[x * MAX_TAPS]` on
    inner: (usize, usize),
    /// the largest sum of a position's positive weights, and of its negative ones' magnitudes
    pos: i64,
    neg: i64,
    /// `dst == 2 * src` with an interior (sources `radius..src - radius`): every interior output
    /// takes `even`'s weights at x = 2i (taps from i - radius) or `odd`'s at 2i + 1 (from
    /// i - radius + 1)
    two: bool,
    even: [i16; MAX_TAPS],
    odd: [i16; MAX_TAPS],
}

impl Axis {
    fn new(src: usize, dst: usize, filter: Filter, one: i32) -> Axis {
        let r = filter.radius();
        let taps = 2 * r;
        let mut idx = Vec::with_capacity(dst * MAX_TAPS);
        let mut w = Vec::with_capacity(dst * MAX_TAPS);
        let mut inner = (usize::MAX, 0);
        for x in 0..dst {
            // the position, src * (2x + 1) / (2 dst) - 1/2, as an exact fraction: num / den
            let num = (2 * x as i64 + 1) * src as i64 - dst as i64;
            let den = 2 * dst as i64;
            let fl = num.div_euclid(den);
            let frac = num.rem_euclid(den) as f64 / den as f64;
            let first = fl - r as i64 + 1;
            let mut f = [0f64; MAX_TAPS];
            let mut sum = 0.0;
            for (k, fk) in f.iter_mut().enumerate().take(taps) {
                // tap first + k, (first + k) - (fl + frac) samples from the position
                *fk = filter.kernel((k as i64 - r as i64 + 1) as f64 - frac);
                sum += *fk;
            }
            let mut q = [0i32; MAX_TAPS];
            let mut total = 0;
            let mut big = 0;
            for k in 0..taps {
                q[k] = (f[k] / sum * one as f64).round() as i32;
                total += q[k];
                if q[k] > q[big] {
                    big = k;
                }
            }
            q[big] += one - total;
            if q[big] > i16::MAX as i32 {
                // a tap on the position itself (weight 1): the unit over i16 to its neighbour
                let next = if big + 1 < taps { big + 1 } else { big - 1 };
                q[next] += q[big] - i16::MAX as i32;
                q[big] = i16::MAX as i32;
            }
            for (k, &qk) in q.iter().enumerate() {
                idx.push((first + k.min(taps - 1) as i64).clamp(0, src as i64 - 1) as u32);
                w.push(qk as i16);
            }
            if first >= 0 && first + taps as i64 <= src as i64 {
                inner = (inner.0.min(x), x + 1);
            }
        }
        if inner.0 == usize::MAX {
            inner = (0, 0);
        }
        let mut a = Axis {
            src,
            dst,
            taps,
            idx,
            w,
            inner,
            pos: 0,
            neg: 0,
            two: dst == 2 * src && src > 2 * r,
            even: [0; MAX_TAPS],
            odd: [0; MAX_TAPS],
        };
        for x in 0..dst {
            let (p, n) = a.sums(x);
            (a.pos, a.neg) = (a.pos.max(p), a.neg.max(n));
        }
        if a.two {
            let i = r;
            let (even, odd) = (a.weights(2 * i).to_vec(), a.weights(2 * i + 1).to_vec());
            a.even[..taps].copy_from_slice(&even);
            a.odd[..taps].copy_from_slice(&odd);
        }
        a
    }

    fn weights(&self, x: usize) -> &[i16] {
        &self.w[x * MAX_TAPS..][..self.taps]
    }

    fn indices(&self, x: usize) -> &[u32] {
        &self.idx[x * MAX_TAPS..][..self.taps]
    }

    /// Per position, the sums of its positive weights and of its negative ones' magnitudes.
    fn sums(&self, x: usize) -> (i64, i64) {
        let w = self.weights(x);
        let pos = w.iter().filter(|&&v| v > 0).map(|&v| v as i64).sum();
        let neg = w.iter().filter(|&&v| v < 0).map(|&v| -(v as i64)).sum();
        (pos, neg)
    }
}

/// `(v * w + 2^14) >> 15`: one product of either pass (`vqrdmulh`, `pmulhrsw`).
#[inline(always)]
fn mulhrs(v: i16, w: i16) -> i32 {
    (v as i32 * w as i32 + (1 << 14)) >> 15
}

/// The final rounding: `(sum + 16) >> 5`, clamped.
#[inline(always)]
fn narrow(s: i32) -> u8 {
    ((s + 16) >> 5).clamp(0, 255) as u8
}

/// The vertical pass, scalar: lanes `from..` of the output row `y` (`ch` samples a pixel).
fn vertical_scalar(src: &[u8], stride: usize, v: &Axis, y: usize, tmp: &mut [i16], from: usize) {
    let (ws, is) = (v.weights(y), v.indices(y));
    for (x, t) in tmp.iter_mut().enumerate().skip(from) {
        let mut s = 0i32;
        for (&w, &i) in ws.iter().zip(is) {
            s += mulhrs((src[i as usize * stride + x] as i16) << 5, w);
        }
        *t = s as i16;
    }
}

/// The horizontal pass, scalar: output pixels `xs` of one row from the vertical pass's `tmp`.
fn horizontal_scalar(tmp: &[i16], h: &Axis, ch: usize, out: &mut [u8], xs: core::ops::Range<usize>) {
    for x in xs {
        let (ws, is) = (h.weights(x), h.indices(x));
        for c in 0..ch {
            let mut s = 0i32;
            for (&w, &i) in ws.iter().zip(is) {
                s += mulhrs(tmp[i as usize * ch + c], w);
            }
            out[x * ch + c] = narrow(s);
        }
    }
}

/// Which code runs the passes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Path {
    Scalar,
    /// NEON (aarch64) or SSE4.1 (x86_64)
    Simd,
}

impl Path {
    fn best() -> Path {
        #[cfg(target_arch = "aarch64")]
        return Path::Simd;
        #[cfg(target_arch = "x86_64")]
        return if sse::available() { Path::Simd } else { Path::Scalar };
        #[allow(unreachable_code)]
        Path::Scalar
    }
}

/// One output row: the vertical pass into `tmp`, then the horizontal into `out`.
#[allow(clippy::too_many_arguments)]
fn row(src: &[u8], stride: usize, ch: usize, h: &Axis, v: &Axis, y: usize, tmp: &mut [i16], out: &mut [u8], path: Path) {
    let n = h.src * ch;
    let tmp = &mut tmp[..n + PAD];
    let out = &mut out[..h.dst * ch];
    let mut done = 0;
    if path == Path::Simd {
        done = simd::vertical(src, stride, v, y, &mut tmp[..n]);
    }
    vertical_scalar(src, stride, v, y, &mut tmp[..n], done);
    // the SIMD's interior, outputs lo..hi (exactly twice the width: the fixed phases; else the
    // table's); the edges and the rest scalar
    let (lo, hi) = match path {
        Path::Simd if h.two => simd::horizontal_two(tmp, h, ch, out),
        Path::Simd => simd::horizontal_table(tmp, h, ch, out),
        Path::Scalar => (0, 0),
    };
    horizontal_scalar(tmp, h, ch, out, 0..lo);
    horizontal_scalar(tmp, h, ch, out, hi.max(lo)..h.dst);
}

/// Upscales pictures, keeping its tables and rows between them.
pub struct Upscaler {
    threads: usize,
    filter: Filter,
    path: Path,
    /// the axes' tables last used, by (src, dst), the latest last: a picture's planes (Y's sizes
    /// and chroma's) take four
    axes: Vec<Axis>,
    /// per task, the vertical pass's row (the source's width × channels)
    rows: Vec<Mutex<Vec<i16>>>,
}

/// Axes an [`Upscaler`] keeps.
const AXES: usize = 8;

/// Why [`Upscaler::scale`] refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Invalid(pub &'static str);

impl Upscaler {
    /// An upscaler on at most `threads` threads (0: the available parallelism).
    pub fn new(threads: usize, filter: Filter) -> Upscaler {
        let threads = if threads == 0 {
            std::thread::available_parallelism().map_or(1, |n| n.get())
        } else {
            threads
        };
        Upscaler {
            threads,
            filter,
            path: Path::best(),
            axes: Vec::with_capacity(AXES),
            rows: (0..threads).map(|_| Mutex::new(Vec::new())).collect(),
        }
    }

    pub fn filter(&self) -> Filter {
        self.filter
    }

    pub fn set_filter(&mut self, f: Filter) {
        if f != self.filter {
            self.filter = f;
            self.axes.clear();
        }
    }

    /// Tests: the scalar reference instead of the SIMD.
    #[cfg(test)]
    pub(crate) fn set_path(&mut self, p: Path) {
        self.path = p;
    }

    /// The axis from `src` to `dst` samples, made if it isn't kept, last in `axes`.
    fn touch(&mut self, src: usize, dst: usize) {
        if let Some(i) = self.axes.iter().position(|a| a.src == src && a.dst == dst) {
            let a = self.axes.remove(i);
            self.axes.push(a);
            return;
        }
        if self.axes.len() == AXES {
            self.axes.remove(0);
        }
        self.axes.push(Axis::new(src, dst, self.filter, ONE));
    }

    fn axis(&self, src: usize, dst: usize) -> &Axis {
        self.axes.iter().rev().find(|a| a.src == src && a.dst == dst).expect("touched")
    }

    /// Scales `src` (`sw` x `sh` pixels of `ch` interleaved samples, 1 or 4; rows `src_stride`
    /// bytes apart) up to `dst` (`dw` x `dh`, each at least the source's; rows `dst_stride` apart).
    #[allow(clippy::too_many_arguments)]
    pub fn scale(
        &mut self,
        src: &[u8],
        sw: usize,
        sh: usize,
        src_stride: usize,
        ch: usize,
        dst: &mut [u8],
        dw: usize,
        dh: usize,
        dst_stride: usize,
    ) -> Result<(), Invalid> {
        if ch != 1 && ch != 4 {
            return Err(Invalid("channels: 1 or 4"));
        }
        if sw == 0 || sh == 0 || dw < sw || dh < sh || dw > 1 << 15 || dh > 1 << 15 {
            return Err(Invalid("sizes: 1 <= source <= destination <= 32768"));
        }
        let need = |w: usize, h: usize, s: usize| (h - 1).checked_mul(s).and_then(|n| n.checked_add(w * ch));
        if src_stride < sw * ch || dst_stride < dw * ch {
            return Err(Invalid("a stride shorter than its row"));
        }
        if need(sw, sh, src_stride).is_none_or(|n| src.len() < n) || need(dw, dh, dst_stride).is_none_or(|n| dst.len() < n)
        {
            return Err(Invalid("a buffer shorter than its picture"));
        }
        self.touch(sw, dw);
        self.touch(sh, dh);
        let (h, v) = (self.axis(sw, dw), self.axis(sh, dh));
        // i16 headroom: every partial sum is within its positive and negative terms' sums (each
        // product rounded at most a unit up): the vertical pass's in -vneg..=vpos, the
        // horizontal's in -hneg..=hpos, which its final rounding's + 16 must not overflow
        let (vpos, vneg) = ((((255 << 5) * v.pos) >> 15) + v.taps as i64, (((255 << 5) * v.neg) >> 15) + v.taps as i64);
        let hpos = ((h.pos * vpos + h.neg * vneg) >> 15) + h.taps as i64;
        let hneg = ((h.pos * vneg + h.neg * vpos) >> 15) + h.taps as i64;
        assert!(vpos.max(vneg).max(hneg) <= i16::MAX as i64 && hpos + 16 <= i16::MAX as i64, "upscale: weights overflow i16");
        for r in &self.rows {
            let mut r = r.lock().unwrap_or_else(|e| e.into_inner());
            if r.len() < sw * 4 + PAD {
                r.resize(sw * 4 + PAD, 0);
            }
        }
        let path = self.path;
        let bands = dh.div_ceil(BAND_ROWS);
        let tasks = self.threads.min(bands).max(1);
        let queue = Mutex::new(dst.chunks_mut(BAND_ROWS * dst_stride).enumerate());
        let rows = &self.rows;
        crate::pool::run(tasks, |t| {
            let mut tmp = rows[t].lock().unwrap_or_else(|e| e.into_inner());
            loop {
                let next = queue.lock().unwrap_or_else(|e| e.into_inner()).next();
                let Some((b, band)) = next else { break };
                for (r, y) in (b * BAND_ROWS..dh.min((b + 1) * BAND_ROWS)).enumerate() {
                    let out = &mut band[r * dst_stride..];
                    row(src, src_stride, ch, h, v, y, &mut tmp, out, path);
                }
            }
        });
        Ok(())
    }
}

#[cfg(target_arch = "aarch64")]
use neon as simd;
#[cfg(target_arch = "x86_64")]
use sse as simd;

/// No SIMD: the scalar code does everything.
#[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
mod simd {
    pub(super) fn vertical(_: &[u8], _: usize, _: &super::Axis, _: usize, _: &mut [i16]) -> usize {
        0
    }
    pub(super) fn horizontal_two(_: &[i16], _: &super::Axis, _: usize, _: &mut [u8]) -> (usize, usize) {
        (0, 0)
    }
    pub(super) fn horizontal_table(_: &[i16], _: &super::Axis, _: usize, _: &mut [u8]) -> (usize, usize) {
        (0, 0)
    }
}

#[cfg(target_arch = "aarch64")]
mod neon {
    use super::Axis;
    use core::arch::aarch64::*;

    /// The vertical pass on 16 lanes at a time: returns the lanes done.
    pub(super) fn vertical(src: &[u8], stride: usize, v: &Axis, y: usize, tmp: &mut [i16]) -> usize {
        let n = tmp.len() / 16 * 16;
        let (ws, is) = (v.weights(y), v.indices(y));
        let mut rows = [core::ptr::null::<u8>(); super::MAX_TAPS];
        for (k, &i) in is.iter().enumerate() {
            // every tap row holds at least `tmp.len()` samples (Upscaler::scale checked the source)
            let r = &src[i as usize * stride..][..tmp.len()];
            rows[k] = r.as_ptr();
        }
        let out = tmp.as_mut_ptr();
        let mut x = 0;
        while x < n {
            // SAFETY: x + 16 <= tmp.len(), and each tap row has tmp.len() samples (above).
            unsafe {
                let (mut lo, mut hi) = (vdupq_n_s16(0), vdupq_n_s16(0));
                for k in 0..ws.len() {
                    let p = vld1q_u8(rows[k].add(x));
                    let w = ws[k];
                    lo = vaddq_s16(lo, vqrdmulhq_n_s16(vreinterpretq_s16_u16(vshll_n_u8::<5>(vget_low_u8(p))), w));
                    hi = vaddq_s16(hi, vqrdmulhq_n_s16(vreinterpretq_s16_u16(vshll_high_n_u8::<5>(p)), w));
                }
                vst1q_s16(out.add(x), lo);
                vst1q_s16(out.add(x + 8), hi);
            }
            x += 16;
        }
        n
    }

    /// The horizontal pass at exactly twice the width, on the interior: returns the outputs done,
    /// `lo..hi`.
    pub(super) fn horizontal_two(tmp: &[i16], h: &Axis, ch: usize, out: &mut [u8]) -> (usize, usize) {
        let r = h.taps / 2;
        // source samples i in r..=src - 1 - r, `step` at a time (CH 4: 2 pixels of 4 lanes; CH 1:
        // 8 samples)
        let step = if ch == 4 { 2 } else { 8 };
        if h.src < 2 * r + step {
            return (0, 0);
        }
        let last = h.src - 1 - r; // the last interior source sample
        let count = (last + 1 - r) / step;
        assert!(tmp.len() >= h.src * ch && out.len() >= h.dst * ch);
        let t = tmp.as_ptr();
        let o = out.as_mut_ptr();
        let taps = h.taps;
        let mut we = [0i16; super::MAX_TAPS];
        let mut wo = [0i16; super::MAX_TAPS];
        we.copy_from_slice(&h.even);
        wo.copy_from_slice(&h.odd);
        for s in 0..count {
            let i = r + s * step;
            // SAFETY: the loads read samples (i - r)*ch .. (i + step - 1 + r)*ch + ch - 1, inside
            // tmp since i - r >= 0 and i + step - 1 + r <= src - 1; the stores write outputs
            // 2i*ch .. (2i + 2*step)*ch, inside out (dst = 2 src).
            unsafe {
                let (mut e0, mut o0) = (vdupq_n_s16(0), vdupq_n_s16(0));
                if ch == 4 {
                    for k in 0..taps {
                        e0 = vaddq_s16(e0, vqrdmulhq_n_s16(vld1q_s16(t.add((i - r + k) * 4)), we[k]));
                        o0 = vaddq_s16(o0, vqrdmulhq_n_s16(vld1q_s16(t.add((i - r + 1 + k) * 4)), wo[k]));
                    }
                    let a = vreinterpretq_s16_s64(vzip1q_s64(vreinterpretq_s64_s16(e0), vreinterpretq_s64_s16(o0)));
                    let b = vreinterpretq_s16_s64(vzip2q_s64(vreinterpretq_s64_s16(e0), vreinterpretq_s64_s16(o0)));
                    vst1q_u8(o.add(2 * i * 4), vcombine_u8(vqrshrun_n_s16::<5>(a), vqrshrun_n_s16::<5>(b)));
                } else {
                    for k in 0..taps {
                        e0 = vaddq_s16(e0, vqrdmulhq_n_s16(vld1q_s16(t.add(i - r + k)), we[k]));
                        o0 = vaddq_s16(o0, vqrdmulhq_n_s16(vld1q_s16(t.add(i - r + 1 + k)), wo[k]));
                    }
                    let a = vzip1q_s16(e0, o0);
                    let b = vzip2q_s16(e0, o0);
                    vst1q_u8(o.add(2 * i), vcombine_u8(vqrshrun_n_s16::<5>(a), vqrshrun_n_s16::<5>(b)));
                }
            }
        }
        (2 * r, 2 * (r + count * step))
    }

    /// The horizontal pass by the table, on the outputs whose taps are inside the source: CH 4 two
    /// pixels at a time, CH 1 eight samples (each an 8-lane dot product, the taps past `taps`
    /// weighted 0, summed by pairwise adds). Returns the outputs done, `lo..hi`.
    pub(super) fn horizontal_table(tmp: &[i16], h: &Axis, ch: usize, out: &mut [u8]) -> (usize, usize) {
        let (lo, hi) = h.inner;
        let group = if ch == 4 { 2 } else { 8 };
        let count = hi.saturating_sub(lo) / group;
        assert!(tmp.len() >= h.src * ch + super::PAD && out.len() >= h.dst * ch);
        assert!(h.idx.len() >= h.dst * super::MAX_TAPS && h.w.len() >= h.dst * super::MAX_TAPS);
        let (t, o, wp, ip) = (tmp.as_ptr(), out.as_mut_ptr(), h.w.as_ptr(), h.idx.as_ptr());
        let taps = h.taps;
        for g in 0..count {
            let x0 = lo + g * group;
            // SAFETY: x0 + group <= hi <= dst, inside the tables (above); an inner output's taps
            // first..first + taps are inside the source, so its loads read lanes below
            // (first + taps) * ch, or (CH 1) first + 8, first + 16 past 8 taps (first <= src - taps,
            // so <= src + PAD): inside tmp; the stores write outputs x0..x0 + group, inside out.
            unsafe {
                if ch == 4 {
                    let mut acc = [vdup_n_s16(0); 2];
                    for (j, a) in acc.iter_mut().enumerate() {
                        let x = x0 + j;
                        let f = *ip.add(x * super::MAX_TAPS) as usize;
                        for k in 0..taps {
                            let w = *wp.add(x * super::MAX_TAPS + k);
                            *a = vadd_s16(*a, vqrdmulh_n_s16(vld1_s16(t.add((f + k) * 4)), w));
                        }
                    }
                    vst1_u8(o.add(x0 * 4), vqrshrun_n_s16::<5>(vcombine_s16(acc[0], acc[1])));
                } else {
                    let mut p = [vdupq_n_s16(0); 8];
                    for (j, pj) in p.iter_mut().enumerate() {
                        let x = x0 + j;
                        let f = *ip.add(x * super::MAX_TAPS) as usize;
                        let w = wp.add(x * super::MAX_TAPS);
                        *pj = vqrdmulhq_s16(vld1q_s16(t.add(f)), vld1q_s16(w));
                        if taps > 8 {
                            *pj = vaddq_s16(*pj, vqrdmulhq_s16(vld1q_s16(t.add(f + 8)), vld1q_s16(w.add(8))));
                        }
                    }
                    let (a, b) = (vpaddq_s16(p[0], p[1]), vpaddq_s16(p[2], p[3]));
                    let (c, d) = (vpaddq_s16(p[4], p[5]), vpaddq_s16(p[6], p[7]));
                    let s = vpaddq_s16(vpaddq_s16(a, b), vpaddq_s16(c, d));
                    vst1_u8(o.add(x0), vqrshrun_n_s16::<5>(s));
                }
            }
        }
        (lo, lo + count * group)
    }
}

#[cfg(target_arch = "x86_64")]
mod sse {
    use super::Axis;
    use core::arch::x86_64::*;

    pub(super) fn available() -> bool {
        std::arch::is_x86_feature_detected!("sse4.1")
    }

    pub(super) fn vertical(src: &[u8], stride: usize, v: &Axis, y: usize, tmp: &mut [i16]) -> usize {
        if !available() {
            return 0;
        }
        // SAFETY: SSE4.1 is there (above).
        unsafe { vertical_sse41(src, stride, v, y, tmp) }
    }

    #[target_feature(enable = "sse4.1")]
    unsafe fn vertical_sse41(src: &[u8], stride: usize, v: &Axis, y: usize, tmp: &mut [i16]) -> usize {
        let n = tmp.len() / 16 * 16;
        let (ws, is) = (v.weights(y), v.indices(y));
        let mut rows = [core::ptr::null::<u8>(); super::MAX_TAPS];
        for (k, &i) in is.iter().enumerate() {
            // every tap row holds at least `tmp.len()` samples (Upscaler::scale checked the source)
            let r = &src[i as usize * stride..][..tmp.len()];
            rows[k] = r.as_ptr();
        }
        let out = tmp.as_mut_ptr();
        let mut x = 0;
        while x < n {
            // SAFETY: x + 16 <= tmp.len(), and each tap row has tmp.len() samples (above).
            unsafe {
                let (mut lo, mut hi) = (_mm_setzero_si128(), _mm_setzero_si128());
                for k in 0..ws.len() {
                    let p = _mm_loadu_si128(rows[k].add(x) as *const __m128i);
                    let w = _mm_set1_epi16(ws[k]);
                    let (a, b) = (_mm_cvtepu8_epi16(p), _mm_cvtepu8_epi16(_mm_srli_si128::<8>(p)));
                    lo = _mm_add_epi16(lo, _mm_mulhrs_epi16(_mm_slli_epi16::<5>(a), w));
                    hi = _mm_add_epi16(hi, _mm_mulhrs_epi16(_mm_slli_epi16::<5>(b), w));
                }
                _mm_storeu_si128(out.add(x) as *mut __m128i, lo);
                _mm_storeu_si128(out.add(x + 8) as *mut __m128i, hi);
            }
            x += 16;
        }
        n
    }

    pub(super) fn horizontal_two(tmp: &[i16], h: &Axis, ch: usize, out: &mut [u8]) -> (usize, usize) {
        if !available() {
            return (0, 0);
        }
        // SAFETY: SSE4.1 is there (above).
        unsafe { horizontal_two_sse41(tmp, h, ch, out) }
    }

    #[target_feature(enable = "sse4.1")]
    unsafe fn horizontal_two_sse41(tmp: &[i16], h: &Axis, ch: usize, out: &mut [u8]) -> (usize, usize) {
        let r = h.taps / 2;
        let step = if ch == 4 { 2 } else { 8 };
        if h.src < 2 * r + step {
            return (0, 0);
        }
        let last = h.src - 1 - r;
        let count = (last + 1 - r) / step;
        assert!(tmp.len() >= h.src * ch && out.len() >= h.dst * ch);
        let t = tmp.as_ptr();
        let o = out.as_mut_ptr();
        let taps = h.taps;
        let round = _mm_set1_epi16(16);
        for s in 0..count {
            let i = r + s * step;
            // SAFETY: as NEON's: the loads stay inside tmp, the stores inside out.
            unsafe {
                let (mut e0, mut o0) = (_mm_setzero_si128(), _mm_setzero_si128());
                let (sh, base) = if ch == 4 { (4, i * 4) } else { (1, i) };
                for k in 0..taps {
                    let we = _mm_set1_epi16(h.even[k]);
                    let wo = _mm_set1_epi16(h.odd[k]);
                    let a = _mm_loadu_si128(t.add(base - r * sh + k * sh) as *const __m128i);
                    let b = _mm_loadu_si128(t.add(base - r * sh + (k + 1) * sh) as *const __m128i);
                    e0 = _mm_add_epi16(e0, _mm_mulhrs_epi16(a, we));
                    o0 = _mm_add_epi16(o0, _mm_mulhrs_epi16(b, wo));
                }
                let (a, b) = if ch == 4 {
                    (_mm_unpacklo_epi64(e0, o0), _mm_unpackhi_epi64(e0, o0))
                } else {
                    (_mm_unpacklo_epi16(e0, o0), _mm_unpackhi_epi16(e0, o0))
                };
                let a = _mm_srai_epi16::<5>(_mm_add_epi16(a, round));
                let b = _mm_srai_epi16::<5>(_mm_add_epi16(b, round));
                _mm_storeu_si128(o.add(2 * base) as *mut __m128i, _mm_packus_epi16(a, b));
            }
        }
        (2 * r, 2 * (r + count * step))
    }

    pub(super) fn horizontal_table(tmp: &[i16], h: &Axis, ch: usize, out: &mut [u8]) -> (usize, usize) {
        if !available() {
            return (0, 0);
        }
        // SAFETY: SSE4.1 is there (above).
        unsafe { horizontal_table_sse41(tmp, h, ch, out) }
    }

    /// As NEON's: CH 4 two pixels at a time, CH 1 eight samples (`phaddw` for the pairwise adds).
    #[target_feature(enable = "sse4.1")]
    unsafe fn horizontal_table_sse41(tmp: &[i16], h: &Axis, ch: usize, out: &mut [u8]) -> (usize, usize) {
        let (lo, hi) = h.inner;
        let group = if ch == 4 { 2 } else { 8 };
        let count = hi.saturating_sub(lo) / group;
        assert!(tmp.len() >= h.src * ch + super::PAD && out.len() >= h.dst * ch);
        assert!(h.idx.len() >= h.dst * super::MAX_TAPS && h.w.len() >= h.dst * super::MAX_TAPS);
        let (t, o, wp, ip) = (tmp.as_ptr(), out.as_mut_ptr(), h.w.as_ptr(), h.idx.as_ptr());
        let taps = h.taps;
        let round = _mm_set1_epi16(16);
        for g in 0..count {
            let x0 = lo + g * group;
            // SAFETY: as NEON's.
            unsafe {
                let s = if ch == 4 {
                    let mut acc = [_mm_setzero_si128(); 2];
                    for (j, a) in acc.iter_mut().enumerate() {
                        let x = x0 + j;
                        let f = *ip.add(x * super::MAX_TAPS) as usize;
                        for k in 0..taps {
                            let w = _mm_set1_epi16(*wp.add(x * super::MAX_TAPS + k));
                            let v = _mm_loadl_epi64(t.add((f + k) * 4) as *const __m128i);
                            *a = _mm_add_epi16(*a, _mm_mulhrs_epi16(v, w));
                        }
                    }
                    _mm_unpacklo_epi64(acc[0], acc[1])
                } else {
                    let mut p = [_mm_setzero_si128(); 8];
                    for (j, pj) in p.iter_mut().enumerate() {
                        let x = x0 + j;
                        let f = *ip.add(x * super::MAX_TAPS) as usize;
                        let v = _mm_loadu_si128(t.add(f) as *const __m128i);
                        let w = wp.add(x * super::MAX_TAPS);
                        *pj = _mm_mulhrs_epi16(v, _mm_loadu_si128(w as *const __m128i));
                        if taps > 8 {
                            let v2 = _mm_loadu_si128(t.add(f + 8) as *const __m128i);
                            *pj = _mm_add_epi16(*pj, _mm_mulhrs_epi16(v2, _mm_loadu_si128(w.add(8) as *const __m128i)));
                        }
                    }
                    let (a, b) = (_mm_hadd_epi16(p[0], p[1]), _mm_hadd_epi16(p[2], p[3]));
                    let (c, d) = (_mm_hadd_epi16(p[4], p[5]), _mm_hadd_epi16(p[6], p[7]));
                    _mm_hadd_epi16(_mm_hadd_epi16(a, b), _mm_hadd_epi16(c, d))
                };
                let s = _mm_srai_epi16::<5>(_mm_add_epi16(s, round));
                _mm_storel_epi64(o.add(x0 * ch) as *mut __m128i, _mm_packus_epi16(s, s));
            }
        }
        (lo, lo + count * group)
    }
}

#[cfg(test)]
mod tests;
