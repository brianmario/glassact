//! The spec's tables and constants, generated from the C headers the Metal kernels compile
//! (scripts/gen-av1-rust-tables), so the CPU and the GPU use the same values.
pub mod consts;
#[rustfmt::skip]
pub mod spec;

pub use consts::*;
pub use spec::*;
