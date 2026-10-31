//! The host half of the Metal encoder (Sources/AV1Encoder): libaom tune=iq's frame decisions, the
//! host half of the post-filter strength search, and the derived tables the kernels compile.
pub mod lfsearch;
pub mod tables;
pub mod tuneiq;

pub use lfsearch::{cdef_bits, cdef_presets, cdef_select_cpu};
pub use tables::tables_msl;
pub use tuneiq::{TuneiqFrame, tuneiq_fill_fp, tuneiq_frame, tuneiq_frame_init};

/// `a * b + c` as the C++ evaluates it: clang contracts a multiply-add in one expression into a
/// fused multiply-add where the target has one (-ffp-contract=on: every aarch64), not on x86_64,
/// whose baseline has no FMA. The results are rounded differently, so the port does the same.
#[inline(always)]
pub(crate) fn fmac(a: f64, b: f64, c: f64) -> f64 {
    #[cfg(target_arch = "aarch64")]
    {
        a.mul_add(b, c)
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        a * b + c
    }
}

#[cfg(test)]
mod tests;
