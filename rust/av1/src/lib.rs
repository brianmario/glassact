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
pub mod tables;
pub mod types;
pub mod blockinfo;
pub mod dsp;
pub mod postfilter;
pub mod entropy;
pub mod avif;
pub mod writer;
pub mod enc;
pub mod hybrid;
pub mod testsupport;
