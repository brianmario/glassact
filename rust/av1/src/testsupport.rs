//! Test support, not for the product (Sources/AV1CoreTestSupport, include/av1core_test.h):
//!
//! - [`fuzz_gen`]: av1gpu's random legal decision records, deterministic per seed;
//! - [`ref_engine`]: av1gpu's CPU reference engine (av1t_ref_encode);
//! - [`dsp_cases`]: av1gpu's GPU-vs-CPU cases of the shared DSP with the CPU's results. The case
//!   structs are `#[repr(C)]` with the C layouts (av1g_test/dsp_cases.h): Swift uploads them to the
//!   Metal kernels as raw bytes.
pub mod dsp_cases;
pub mod fuzz_gen;
pub mod ref_engine;
#[cfg(all(test, feature = "oracle"))]
mod tests;

pub use dsp_cases::{
    DspSet, DspSetC, ITX_COEFFS, ITX_RESIDUAL, ItxCase, PW, PredCase, Sym, dsp_set_make, ec_stream, inverse_transform,
    itx_run, pred_run, tx_type_allowed,
};
pub use fuzz_gen::{FuzzCase, case_make};
pub use ref_engine::{Image, RefEngineOpts, RefEngineStats, RefOpts, ref_encode, ref_engine_encode};
