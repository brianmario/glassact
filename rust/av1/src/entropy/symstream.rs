//! Per-tile symbol streams (av1g/symstream.h).
//!
//! A tile's entropy-coded payload is fully determined by its ordered list of (cdf, symbol,
//! alphabet) triples; the CDF values evolve during coding but the cdf identities don't depend on
//! them. So symbolization (contexts) is parallel and only od_ec + CDF adaptation is serial per tile.
//!
//! One u32 per syntax element:
//! - bits 0..15: cdf id = u16 offset of the CDF inside [`Cdfs`]
//! - bits 16..19: symbol value
//! - bits 20..23: N - 1 (alphabet size, 2..16)
//! - bits 24..25: kind: 0 adaptive symbol, 1 equiprobable bit (read_bool), 2 split_or_horz,
//!   3 split_or_vert (a bool derived from the *current* partition CDF at cdf id, spec 8.3.2)
use super::{Cdfs, Ec};
use crate::tables::*;

pub const SYM_ADAPT: u32 = 0;
pub const SYM_BOOL: u32 = 1;
pub const SYM_SPLIT_OR_HORZ: u32 = 2;
pub const SYM_SPLIT_OR_VERT: u32 = 3;

/// av1g_sym_pack
#[inline(always)]
pub fn sym_pack(kind: u32, cdf: u32, s: u32, n: u32) -> u32 {
    (cdf & 0xFFFF) | ((s & 15) << 16) | ((n.wrapping_sub(1) & 15) << 20) | (kind << 24)
}

/// av1g_split_or_psum: the probability sum of the partition symbols that imply "split", for
/// split_or_horz (`vert` false) or split_or_vert.
#[inline(always)]
pub fn split_or_psum(pc: &[u16], vert: bool) -> u32 {
    let p = |x: i32| -> u32 {
        let x = x as usize;
        (pc[x] as u32).wrapping_sub(if x > 0 { pc[x - 1] as u32 } else { 0 })
    };
    if !vert {
        p(PARTITION_VERT)
            .wrapping_add(p(PARTITION_SPLIT))
            .wrapping_add(p(PARTITION_HORZ_A))
            .wrapping_add(p(PARTITION_VERT_A))
            .wrapping_add(p(PARTITION_VERT_B))
            .wrapping_add(p(PARTITION_VERT_4))
    } else {
        p(PARTITION_HORZ)
            .wrapping_add(p(PARTITION_SPLIT))
            .wrapping_add(p(PARTITION_HORZ_A))
            .wrapping_add(p(PARTITION_HORZ_B))
            .wrapping_add(p(PARTITION_VERT_A))
            .wrapping_add(p(PARTITION_HORZ_4))
    }
}

/// av1g_code_symbols: entropy-codes one tile's symbol stream. `cdf` starts as
/// [`Cdfs::new`]`(base_q_idx)`; `ec` as new or reset.
pub fn code_symbols(syms: &[u32], cdf: &mut Cdfs, ec: &mut Ec) {
    let base = cdf.words_mut();
    for &w in syms {
        let kind = w >> 24;
        let s = (w >> 16) & 15;
        let n = ((w >> 20) & 15) + 1;
        let off = (w & 0xFFFF) as usize;
        if kind == SYM_ADAPT {
            ec.symbol_dyn(s, &mut base[off..], n);
        } else if kind == SYM_BOOL {
            ec.bool(s != 0);
        } else {
            ec.split_or(&base[off..], kind == SYM_SPLIT_OR_VERT, s != 0);
        }
    }
}
