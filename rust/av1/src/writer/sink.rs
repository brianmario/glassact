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
    /// split_or_horz / split_or_vert (spec 8.3.2), from the 10-symbol partition CDF `pc`
    fn split_or(&mut self, pc: &[u16; 11], vert: bool, b: i32) -> i32;
}

/// Writes with the range encoder.
pub(crate) struct EcSink<'a> {
    pub ec: &'a mut Ec,
    pub nsym: u64,
}

impl Sink for EcSink<'_> {
    const WRITE: bool = true;
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
    fn split_or(&mut self, pc: &[u16; 11], vert: bool, b: i32) -> i32 {
        self.ec.split_or(pc, vert, b != 0);
        self.nsym += 1;
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
    fn split_or(&mut self, pc: &[u16; 11], vert: bool, b: i32) -> i32 {
        let kind = if vert { SYM_SPLIT_OR_VERT } else { SYM_SPLIT_OR_HORZ };
        self.out.push(sym_pack(kind, Cdfs::cdf_id(self.base, pc), b as u32, 2));
        self.ec.split_or(pc, vert, b)
    }
}

/// The symbol decoder exactly as specified in AV1 spec 8.2.2 .. 8.2.6.
pub(crate) struct DecSink<'a> {
    data: &'a [u8],
    bitpos: usize,
    symbol_value: u32,
    symbol_range: u32,
    symbol_max_bits: i64,
}

impl<'a> DecSink<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        let mut d = DecSink {
            data,
            bitpos: 0,
            symbol_value: 0,
            symbol_range: 0,
            symbol_max_bits: 0,
        };
        let num_bits = (data.len() * 8).min(15) as i32;
        let buf = d.f(num_bits);
        let padded_buf = buf << (15 - num_bits);
        d.symbol_value = ((1u32 << 15) - 1) ^ padded_buf;
        d.symbol_range = 1 << 15;
        d.symbol_max_bits = 8 * data.len() as i64 - 15;
        d
    }

    fn f(&mut self, n: i32) -> u32 {
        let mut x = 0u32;
        for _ in 0..n {
            let byte = self.bitpos >> 3;
            let b = if byte < self.data.len() {
                (self.data[byte] >> (7 - (self.bitpos & 7))) & 1
            } else {
                0
            };
            x = 2 * x + b as u32;
            self.bitpos += 1;
        }
        x
    }

    /// read_symbol: decodes with `cdf` (`n` symbols).
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
        self.symbol_range = prev - cur;
        self.symbol_value -= cur;
        let bits = 15 - (31 - self.symbol_range.leading_zeros() as i32);
        self.symbol_range <<= bits;
        let num_bits = (bits as i64).min(self.symbol_max_bits.max(0)) as i32;
        let new_data = self.f(num_bits);
        let padded_data = new_data << (bits - num_bits);
        self.symbol_value = padded_data ^ (((self.symbol_value + 1) << bits) - 1);
        self.symbol_max_bits -= bits as i64;
        symbol
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
        self.read(&[1 << 14, 1 << 15, 0], 2) as i32
    }
    #[inline]
    fn split_or(&mut self, pc: &[u16; 11], vert: bool, _: i32) -> i32 {
        let tmp = [32768u32.wrapping_sub(split_or_psum(pc, vert)) as u16, 32768, 0];
        self.read(&tmp, 2) as i32
    }
}
