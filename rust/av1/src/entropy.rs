//! Entropy coding: the AV1 range encoder with CDF adaptation (av1g/entenc.h), the tile's CDF
//! context (av1g/cdfctx.h) and the per-tile symbol streams (av1g/symstream.h).
//!
//! The encoder is the writer's serial hot path (one per tile, millions of symbols per 5K frame):
//! it doesn't allocate per symbol, the CDF update runs on fixed-size arrays, and the bytes go into
//! a reusable buffer.
mod cdfs;
mod ec;
pub mod symstream;

pub use cdfs::{Cdfs, InterCdfs, NCDF, coeff_cdf_q_ctx};
pub use ec::{Ec, update_cdf, update_cdf_n, update_cdf_scalar};
pub use symstream::{SYM_ADAPT, SYM_BOOL, SYM_SPLIT_OR_HORZ, SYM_SPLIT_OR_VERT, code_symbols, split_or_psum, sym_pack};

#[cfg(test)]
mod tests;
