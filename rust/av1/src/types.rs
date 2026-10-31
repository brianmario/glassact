//! The C API's structures (Sources/AV1Core/include/av1g/decisions.h and av1g.h, Sources/AV1Encoder/
//! include/av1enc.h and av1enc/ent.h), `#[repr(C)]` with the same layout: Swift and the Metal kernels
//! read and write them. `tests::layouts_match_c` checks every size and offset against the C compiler.
#![allow(non_camel_case_types)]

/// av1g_block: one block's decisions, in decode order (decisions.h documents every field).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Block {
    pub mi_row: u16,
    pub mi_col: u16,
    pub bsize: u8,
    pub skip: u8,
    pub tx_depth: u8,
    pub y_mode: u8,
    pub angle_delta_y: i8,
    pub uv_mode: u8,
    pub angle_delta_uv: i8,
    pub cfl_alpha_u: i8,
    pub cfl_alpha_v: i8,
    pub filter_intra: u8,
    pub cdef_idx: i8,
    pub sb_qindex: u8,
}

/// av1g_txb: one transform block (layout, the luma type decision, and the coded eob).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Txb {
    pub coeff_off: u32,
    pub x4: u16,
    pub y4: u16,
    pub plane: u8,
    pub tx_size: u8,
    pub tx_type: u8,
    pub flags: u8,
    pub eob: u16,
    pub reserved: u16,
}

/// av1g_frame_params: the frame-level decisions.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FrameParams {
    pub version: u32,
    pub width: u32,
    pub height: u32,
    pub monochrome: u8,
    pub base_q_idx: u8,
    pub tx_mode_select: u8,
    pub reduced_tx_set: u8,
    pub tile_cols_log2: i8,
    pub tile_rows_log2: i8,
    pub delta_q_y_dc: i8,
    pub delta_q_u_dc: i8,
    pub delta_q_u_ac: i8,
    pub delta_q_v_dc: i8,
    pub delta_q_v_ac: i8,
    pub enable_filter_intra: u8,
    pub enable_intra_edge_filter: u8,
    pub delta_q_present: u8,
    pub delta_q_res: u8,
    pub using_qmatrix: u8,
    pub qm_y: u8,
    pub qm_u: u8,
    pub qm_v: u8,
    pub loop_filter_level: [u8; 4],
    pub loop_filter_sharpness: u8,
    pub enable_cdef: u8,
    pub cdef_damping_minus_3: u8,
    pub cdef_bits: u8,
    pub cdef_y_pri: [u8; 8],
    pub cdef_y_sec: [u8; 8],
    pub cdef_uv_pri: [u8; 8],
    pub cdef_uv_sec: [u8; 8],
    pub allow_screen_content_tools: u8,
    // v2: video mode (decisions.h "Video mode")
    /// 1: one frame of a stream (full sequence and frame headers)
    pub video: u8,
    /// [`FRAME_KEY`] / [`FRAME_INTER`]
    pub frame_type: u8,
    /// inter: the reference slot (0..7) LAST_FRAME, and every other reference, uses
    pub ref_slot: u8,
    /// inter: bit i set = the frame replaces reference slot i
    pub refresh_frame_flags: u8,
    /// inter: 0/1
    pub error_resilient_mode: u8,
    /// inter: 1 = inter blocks are not deblocked (ref deltas INTRA 0, LAST -63)
    pub lf_inter_off: u8,
    /// inter: 1 = primary_ref_frame LAST: the frame starts from its reference's saved CDFs
    pub cdf_from_ref: u8,
    /// inter: the motion vectors' precision: 0 whole luma samples (force_integer_mv), 1 quarter
    /// (allow_high_precision_mv 0), 2 eighth (allow_high_precision_mv 1)
    pub mv_precision: u8,
    pub reserved: [u8; 7],
}

/// AV1G_DECISIONS_VERSION: 2 adds video mode and inter blocks; version 1 records (still pictures)
/// are still accepted.
pub const DECISIONS_VERSION: u32 = 2;
/// av1g_frame_params.frame_type
pub const FRAME_KEY: u8 = 0;
pub const FRAME_INTER: u8 = 1;

/// av1g_block_inter: an inter block's motion (decisions.h "Inter blocks"). All zero: intra.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BlockInter {
    /// luma motion, 1/8 sample, multiples of 8
    pub mv_row: i16,
    pub mv_col: i16,
    /// 1: inter (LAST_FRAME), 0: intra
    pub is_inter: u8,
    pub reserved: [u8; 3],
}

/// av1g_decision_record: the picture's decisions, with its arrays owned elsewhere (C pointers).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct DecisionRecord {
    pub fp: FrameParams,
    pub n_blocks: u32,
    pub n_txb: u32,
    pub n_coeffs: u64,
    pub blocks: *mut Block,
    pub block_txb: *mut u32,
    pub txb: *mut Txb,
    pub coeffs: *mut i16,
    /// v2: `n_blocks` entries, or null (every block intra); not read for version 1 records
    pub inter: *mut BlockInter,
}

// av1g.h return codes and av1g_encode_opts.flags
pub const OK: i32 = 0;
pub const ERR_INVALID: i32 = -1;
pub const ERR_CAPACITY: i32 = -2;
pub const ERR_RANGE: i32 = -3;
pub const ERR_INTERNAL: i32 = -4;
pub const ENC_FIX_RANGE: u32 = 1;
pub const ENC_NO_RECON: u32 = 2;
pub const ENC_TD: u32 = 4;
pub const ENC_AVIF: u32 = 8;
pub const ENC_PREFILTER_RECON: u32 = 0x20;
pub const ENC_BITSTREAM_ONLY: u32 = 0x10000;

/// av1g_encode_opts
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct EncodeOpts {
    pub flags: u32,
    pub seq_level_idx: i32,
}

/// av1g_output: the encoder's results; buffers are malloc'd (av1g_output_free).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Output {
    pub obu: *mut u8,
    pub obu_size: usize,
    pub avif: *mut u8,
    pub avif_size: usize,
    pub recon: [*mut u8; 3],
    pub recon_w: [u32; 3],
    pub recon_h: [u32; 3],
    pub seq_level_idx: u32,
    pub tile_cols: u32,
    pub tile_rows: u32,
    pub header_bytes: u32,
    pub tile_bytes: u64,
    pub n_symbols: u64,
    pub n_fixed_txb: u32,
    /// video mode: the frame's saved CDFs, for a later frame's av1g_ref_planes.cdfs (or null)
    pub cdfs: *mut core::ffi::c_void,
    pub error: [u8; 256],
}

/// av1g_ref_planes: one reference slot for av1g_encode_ex, the decoder's output of the frame
/// that refreshed it (av1g_output.recon: Y width x height, U / V ((width + 1) / 2) x ((height +
/// 1) / 2), post-filter). A null `plane[0]` is an empty slot.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct RefPlanesC {
    pub plane: [*const u8; 3],
    pub stride: [i32; 3],
    /// the frame's saved CDFs (av1g_output.cdfs), or null
    pub cdfs: *const core::ffi::c_void,
}

/// av1g_tiles
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Tiles {
    pub cols_log2: i32,
    pub rows_log2: i32,
    pub cols: u32,
    pub rows: u32,
    pub mi_col_starts: [u32; 65],
    pub mi_row_starts: [u32; 65],
}

/// av1g_parsed
#[repr(C)]
pub struct Parsed {
    pub rec: DecisionRecord,
    pub seq_level_idx: u32,
    pub n_tiles: u32,
    pub tile_bytes: *const u32,
    pub tile_offsets: *const u64,
    pub error: [u8; 256],
    pub priv_: *mut core::ffi::c_void,
}

/// av1g_avif_meta
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct AvifMeta {
    pub icc: *const u8,
    pub icc_size: usize,
    pub irot: i32,
    pub imir: i32,
}

// ---- av1enc.h ----

/// GaPfAddrs: GPU addresses of the post-filters' planes and maps.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct GaPfAddrs {
    pub plane: [u64; 3],
    pub stride: [i32; 3],
    pub skip: u64,
    pub lf_tx: [u64; 3],
    pub cdef_idx: u64,
    pub cdef_dir_var: u64,
}

/// GaTuneiqFrame: libaom tune=iq's frame-level loop-filter decisions.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GaTuneiqFrame {
    pub lf_level: i32,
    pub lf_sharpness: i32,
    pub cdef_damping: i32,
    pub cdef_mode: i32,
    pub rdmult: i32,
}

/// GaCdefCand: CDEF candidate strengths.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GaCdefCand {
    pub pri: [i32; 16],
    pub sec: [i32; 4],
    pub npri: i32,
    pub nsec: i32,
}

// ---- av1enc/ent.h ----

pub const GA_ENT_MAX_TILES: usize = 4096;

/// GaEntFrame: one picture's frame table for the GPU entropy kernels.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GaEntFrame {
    pub w: i32,
    pub h: i32,
    pub mi_cols: i32,
    pub mi_rows: i32,
    pub mono: i32,
    pub qidx: i32,
    pub reduced: i32,
    pub txsel: i32,
    pub sct: i32,
    pub dq: i32,
    pub dq_res: i32,
    pub fi: i32,
    pub cdef_bits: i32,
    pub ctx_base: [u32; 3],
    pub ctx_stride: [i32; 3],
    pub ctx_rows: [i32; 3],
    pub ctx_total: u32,
    pub mi_total: u32,
    pub n_blocks: u32,
    pub n_txb: u32,
    pub n_sb: u32,
    pub n_tiles: u32,
    pub tile_cols: i32,
    pub tile_rows: i32,
    pub tile_wsb: i32,
    pub tile_hsb: i32,
    pub sym_cap: u32,
}

/// GaEntTile
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GaEntTile {
    pub mi_row_start: i32,
    pub mi_row_end: i32,
    pub mi_col_start: i32,
    pub mi_col_end: i32,
    pub first_block: u32,
    pub end_block: u32,
    pub sb_base: u32,
    pub n_sb: u32,
    pub sb_row0: i32,
    pub sb_col0: i32,
    pub sb_cols: i32,
}

const _: () = {
    assert!(size_of::<Block>() == 16);
    assert!(size_of::<Txb>() == 16);
    assert!(size_of::<BlockInter>() == 8);
};

#[cfg(all(test, feature = "oracle"))]
mod tests {
    use super::*;
    use core::mem::{offset_of, size_of};

    unsafe extern "C" {
        // oracle/layout.cpp: sizeof / offsetof of the C structures, by name ("Block", "Block.skip", ...)
        fn oracle_layout(what: *const core::ffi::c_char) -> i64;
    }
    fn c(what: &str) -> i64 {
        let s = std::ffi::CString::new(what).unwrap();
        let v = unsafe { oracle_layout(s.as_ptr()) };
        assert!(v >= 0, "oracle_layout doesn't know {what}");
        v
    }

    macro_rules! check {
        ($t:ty, $name:literal, $($f:ident : $cf:literal),*) => {
            assert_eq!(size_of::<$t>() as i64, c($name), "sizeof {}", $name);
            $(assert_eq!(offset_of!($t, $f) as i64, c(concat!($name, ".", $cf)), "{}.{}", $name, $cf);)*
        };
    }

    #[test]
    fn layouts_match_c() {
        check!(Block, "Block", mi_row: "mi_row", bsize: "bsize", cdef_idx: "cdef_idx", sb_qindex: "sb_qindex");
        check!(Txb, "Txb", coeff_off: "coeff_off", x4: "x4", eob: "eob");
        check!(FrameParams, "FrameParams", width: "width", monochrome: "monochrome", loop_filter_level: "loop_filter_level",
               cdef_y_pri: "cdef_y_pri", cdef_uv_sec: "cdef_uv_sec", allow_screen_content_tools: "allow_screen_content_tools");
        check!(FrameParams, "FrameParams", video: "video", frame_type: "frame_type", ref_slot: "ref_slot",
               refresh_frame_flags: "refresh_frame_flags", error_resilient_mode: "error_resilient_mode", reserved: "reserved");
        check!(FrameParams, "FrameParams", lf_inter_off: "lf_inter_off", cdf_from_ref: "cdf_from_ref",
               mv_precision: "mv_precision");
        check!(BlockInter, "BlockInter", mv_row: "mv_row", mv_col: "mv_col", is_inter: "is_inter", reserved: "reserved");
        check!(DecisionRecord, "DecisionRecord", n_blocks: "n_blocks", n_coeffs: "n_coeffs", blocks: "blocks", coeffs: "coeffs",
               inter: "inter");
        check!(RefPlanesC, "RefPlanes", plane: "plane", stride: "stride", cdfs: "cdfs");
        check!(EncodeOpts, "EncodeOpts", seq_level_idx: "seq_level_idx");
        check!(Output, "Output", obu_size: "obu_size", recon: "recon", recon_h: "recon_h", tile_bytes: "tile_bytes",
               n_symbols: "n_symbols", n_fixed_txb: "n_fixed_txb", cdfs: "cdfs", error: "error");
        check!(Tiles, "Tiles", cols: "cols", mi_col_starts: "mi_col_starts", mi_row_starts: "mi_row_starts");
        check!(Parsed, "Parsed", seq_level_idx: "seq_level_idx", tile_bytes: "tile_bytes", error: "error", priv_: "priv");
        check!(AvifMeta, "AvifMeta", icc_size: "icc_size", imir: "imir");
        check!(GaPfAddrs, "GaPfAddrs", stride: "stride", skip: "skip", lf_tx: "lfTx", cdef_dir_var: "cdefDirVar");
        check!(GaTuneiqFrame, "GaTuneiqFrame", rdmult: "rdmult");
        check!(GaCdefCand, "GaCdefCand", sec: "sec", nsec: "nsec");
        check!(GaEntFrame, "GaEntFrame", cdef_bits: "cdefBits", ctx_base: "ctxBase", ctx_total: "ctxTotal", tile_hsb: "tileHsb", sym_cap: "symCap");
        check!(GaEntTile, "GaEntTile", first_block: "firstBlock", sb_cols: "sbCols");
    }
}
