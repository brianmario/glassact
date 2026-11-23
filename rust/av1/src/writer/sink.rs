//! The syntax walk's sinks: every walk statement has the form `v = sink.sym(cdf, value, ...)`, so
//! writing and parsing share all context logic.
use crate::entropy::{
    Cdfs, Ec, SYM_ADAPT, SYM_BOOL, SYM_SPLIT_OR_HORZ, SYM_SPLIT_OR_VERT, split_or_psum, sym_pack, update_cdf_n,
};

pub(crate) trait Sink {
    /// true: values come from the record; false: they are decoded
    const WRITE: bool;
    /// S(): symbol `s` of the `L - 1`-symbol adaptive CDF `cdf`
    fn sym<const L: usize>(&mut self, cdf: &mut [u16; L], s: i32) -> i32;
    /// L(1): an equiprobable bit
    fn bit(&mut self, b: i32) -> i32;
    /// split_or_horz / split_or_vert (spec 8.3.2), from the partition CDF `pc` (10 symbols, or the
    /// 128x128 node's 8)
    fn split_or(&mut self, pc: &[u16], vert: bool, b: i32) -> i32;
    /// The bits coded so far (for differences; 0 where nothing is coded).
    fn bits(&self) -> f64 {
        0.0
    }
}

/// Writes with the range encoder.
pub(crate) struct EcSink<'a> {
    pub ec: &'a mut Ec,
    pub nsym: u64,
}

impl Sink for EcSink<'_> {
    const WRITE: bool = true;
    fn bits(&self) -> f64 {
        self.ec.tell_bits()
    }
    #[inline(always)]
    fn sym<const L: usize>(&mut self, cdf: &mut [u16; L], s: i32) -> i32 {
        self.ec.symbol(s as u32, cdf);
        self.nsym += 1;
        s
    }
    #[inline(always)]
    fn bit(&mut self, b: i32) -> i32 {
        self.ec.bool(b != 0);
        self.nsym += 1;
        b
    }
    #[inline(always)]
    fn split_or(&mut self, pc: &[u16], vert: bool, b: i32) -> i32 {
        self.ec.split_or(pc, vert, b != 0);
        self.nsym += 1;
        b
    }
}

/// Codes nothing: the values are the record's (the reconstruction's plan, [`super::recon`]).
pub(crate) struct NullSink;

impl Sink for NullSink {
    const WRITE: bool = true;
    #[inline(always)]
    fn sym<const L: usize>(&mut self, _: &mut [u16; L], s: i32) -> i32 {
        s
    }
    #[inline(always)]
    fn bit(&mut self, b: i32) -> i32 {
        b
    }
    #[inline(always)]
    fn split_or(&mut self, _: &[u16], _: bool, b: i32) -> i32 {
        b
    }
}

/// Writes and records the packed symbol stream (symstream; the GPU entropy coder's reference).
pub(crate) struct TeeSink<'a> {
    pub ec: EcSink<'a>,
    /// the address of the tile's Cdfs: cdf ids are u16 offsets from it
    pub base: usize,
    pub out: &'a mut Vec<u32>,
}

impl Sink for TeeSink<'_> {
    const WRITE: bool = true;
    fn bits(&self) -> f64 {
        self.ec.bits()
    }
    #[inline(always)]
    fn sym<const L: usize>(&mut self, cdf: &mut [u16; L], s: i32) -> i32 {
        self.out.push(sym_pack(
            SYM_ADAPT,
            Cdfs::cdf_id(self.base, cdf),
            s as u32,
            (L - 1) as u32,
        ));
        self.ec.sym(cdf, s)
    }
    #[inline(always)]
    fn bit(&mut self, b: i32) -> i32 {
        self.out.push(sym_pack(SYM_BOOL, 0, b as u32, 2));
        self.ec.bit(b)
    }
    #[inline(always)]
    fn split_or(&mut self, pc: &[u16], vert: bool, b: i32) -> i32 {
        let kind = if vert { SYM_SPLIT_OR_VERT } else { SYM_SPLIT_OR_HORZ };
        self.out.push(sym_pack(kind, Cdfs::cdf_id(self.base, pc), b as u32, 2));
        self.ec.split_or(pc, vert, b)
    }
}

/// The symbol decoder of AV1 spec 8.2.2 .. 8.2.6, with the bits it reads kept in a window.
///
/// The spec reads its new bits one at a time and keeps `SymbolValue` as
/// `((value + 1) << bits) - 1) ^ paddedData`, which is `(value << bits)` with the next `bits` bits
/// of the stream complemented below it (past the end of the data, zeros: complemented, ones). So
/// the stream is read a byte at a time, complemented, into `cache` (its next bits from the top;
/// past the end, zero bytes), and each renormalization takes its bits from there: the same
/// symbols. (The spec's bit-at-a-time reading was most of decoding a symbol: BENCHMARKS,
/// 2026-11-22.) `SymbolMaxBits` and the bit position only bound that reading, so they're gone.
pub(crate) struct DecSink<'a> {
    data: &'a [u8],
    /// the next byte of `data` to go into the cache
    pos: usize,
    /// the stream's next `cnt` bits from the top, complemented
    cache: u64,
    cnt: u32,
    symbol_value: u32,
    symbol_range: u32,
}

impl<'a> DecSink<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        let mut d = DecSink {
            data,
            pos: 0,
            cache: 0,
            cnt: 0,
            symbol_value: 0,
            symbol_range: 1 << 15,
        };
        // (the spec: the first 15 bits, zeros past the end, XOR (1 << 15) - 1)
        d.symbol_value = d.take(15);
        d
    }

    /// The stream's next `n` (<= 16) bits, complemented.
    #[inline(always)]
    fn take(&mut self, n: u32) -> u32 {
        if self.cnt < 16 {
            while self.cnt <= 56 {
                let b = self.data.get(self.pos).map_or(0, |&b| b);
                self.cache |= u64::from(!b) << (56 - self.cnt);
                self.pos += 1;
                self.cnt += 8;
            }
        }
        // (two shifts, so that n = 0 takes nothing)
        let x = ((self.cache >> 1) >> (63 - n)) as u32;
        self.cache <<= n;
        self.cnt -= n;
        x
    }

    /// The new range and value after a symbol (`SymbolRange = prev - cur`, `SymbolValue -= cur`),
    /// renormalized.
    #[inline(always)]
    fn finish(&mut self, range: u32, value: u32) {
        let bits = range.leading_zeros() - 16;
        self.symbol_range = range << bits;
        self.symbol_value = (value << bits) | self.take(bits);
    }

    /// read_symbol: decodes with `cdf` (`n` symbols).
    ///
    /// (The loop stays: counting the bounds above the value in NEON, as dav1d does, without the
    /// loop's branches, was 10 % slower a frame. A correctly predicted exit lets the core run on
    /// into the next symbol's context; the count's latency sat in front of every use of the
    /// symbol: BENCHMARKS, 2026-11-23.)
    fn read(&mut self, cdf: &[u16], n: usize) -> usize {
        let mut cur = self.symbol_range;
        let mut prev;
        let mut symbol = usize::MAX;
        loop {
            symbol = symbol.wrapping_add(1);
            prev = cur;
            let fq = (1u32 << 15) - cdf[symbol] as u32;
            cur = ((self.symbol_range >> 8) * (fq >> 6)) >> (7 - 6);
            cur += 4 * (n - symbol - 1) as u32;
            if self.symbol_value >= cur {
                break;
            }
        }
        self.finish(prev - cur, self.symbol_value - cur);
        symbol
    }

    /// read_symbol of the 2-symbol CDF {32768 - fq, 32768}, without a branch: the loop's first
    /// bound is `((SymbolRange >> 8) * (fq >> 6) >> 1) + 4` and its second 0, so the symbol is 1
    /// where the value is below the first. The equiprobable bits (signs, Golomb codes) and
    /// split_or's bools are this; their branches mispredicted half the time.
    #[inline(always)]
    fn read_bool(&mut self, fq: u32) -> usize {
        let (r, v) = (self.symbol_range, self.symbol_value);
        let cur = (((r >> 8) * (fq >> 6)) >> 1) + 4;
        let b = v < cur;
        let (range, value) = if b { (cur, v) } else { (r - cur, v - cur) };
        self.finish(range, value);
        b as usize
    }
}

impl Sink for DecSink<'_> {
    const WRITE: bool = false;
    #[inline]
    fn sym<const L: usize>(&mut self, cdf: &mut [u16; L], _: i32) -> i32 {
        let s = self.read(cdf, L - 1);
        update_cdf_n::<L>(cdf, s as u32);
        s as i32
    }
    #[inline]
    fn bit(&mut self, _: i32) -> i32 {
        self.read_bool(1 << 14) as i32
    }
    #[inline]
    fn split_or(&mut self, pc: &[u16], vert: bool, _: i32) -> i32 {
        // (the CDF {32768 - psum, 32768}, as the encoder's)
        let c0 = 32768u32.wrapping_sub(split_or_psum(pc, vert)) as u16;
        self.read_bool(32768 - c0 as u32) as i32
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dsp::Rng;

    /// The branchless bool reads against the spec's loop, on random streams and bounds (0 and
    /// 32768 among them), interleaved with symbols of larger CDFs.
    #[test]
    fn bool_reads_match_the_loop() {
        let mut rnd = Rng(0x5eed);
        for _ in 0..300 {
            let len = rnd.below(64) as usize;
            let data: Vec<u8> = (0..len).map(|_| rnd.below(256) as u8).collect();
            let (mut a, mut b) = (DecSink::new(&data), DecSink::new(&data));
            for _ in 0..2000 {
                let c0 = match rnd.below(8) {
                    0 => 0,
                    1 => 32768,
                    2 => 1 << 14,
                    _ => rnd.below(32769),
                } as u16;
                let cdf = [c0, 32768, 0];
                match rnd.below(3) {
                    0 => assert_eq!(a.read_bool(32768 - c0 as u32), b.read(&cdf, 2)),
                    1 => assert_eq!(a.bit(0), b.read(&[1 << 14, 1 << 15, 0], 2) as i32),
                    _ => {
                        let c = [8000, 20000, 32768, 0];
                        assert_eq!(a.read(&c, 3), b.read(&c, 3));
                    }
                }
                assert_eq!((a.symbol_range, a.symbol_value), (b.symbol_range, b.symbol_value));
            }
        }
    }
}
