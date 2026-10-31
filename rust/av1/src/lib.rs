//! Glass Act's AV1 CPU code: a port of av1gpu's av1core (BSD-2, LICENSE) and of the host half of
//! the Metal encoder, previously C++ (Sources/AV1Core, Sources/AV1Encoder).
//!
//! - the DecisionRecord writer: decisions and quantized coefficients in, OBUs and the decoder's
//!   exact reconstruction out;
//! - the post-filters (deblocking, CDEF) and their strength search's host half;
//! - the hybrid encoder's CPU closed loop;
//! - test support: random legal records, the reference engine, the GPU's DSP cases.
//!
//! The Metal kernels keep their own copy of the decoder-mirroring DSP in MSL
//! (Sources/GlassActAV1/Shaders); tests hold the two to the same results.
pub mod avif;
pub mod blockinfo;
#[cfg(feature = "capi")]
pub mod capi;
pub mod dsp;
pub mod enc;
pub mod entropy;
pub mod hybrid;
pub mod motion;
pub mod postfilter;
#[allow(clippy::all)]
pub mod tables;
pub mod testsupport;
pub mod types;
pub mod writer;
