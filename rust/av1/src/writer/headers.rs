//! The sequence header and frame header (a reduced still picture, or a frame of a video stream:
//! decisions.h "Video mode"), and the OBUs around the tile payloads.
use super::TileInfo;
use crate::tables::{ALTREF_FRAME, EIGHTTAP, LAST_FRAME, PRIMARY_REF_NONE, REFS_PER_FRAME};
use crate::types::FrameParams;

/// MSB-first bit writer (av1g::BitWriter).
#[derive(Clone, Debug, Default)]
pub(crate) struct BitWriter {
    pub buf: Vec<u8>,
    pos: u64,
}

impl BitWriter {
    pub fn clear(&mut self) {
        self.buf.clear();
        self.pos = 0;
    }
    #[inline]
    pub fn bit(&mut self, b: u32) {
        if self.pos & 7 == 0 {
            self.buf.push(0);
        }
        if b != 0 {
            *self.buf.last_mut().unwrap() |= 0x80 >> (self.pos & 7);
        }
        self.pos += 1;
    }
    /// f(n): the low `n` bits of `v`, MSB first.
    pub fn put(&mut self, v: u32, n: i32) {
        for i in (0..n).rev() {
            self.bit((v >> i) & 1);
        }
    }
    /// su(n)
    pub fn su(&mut self, v: i32, n: i32) {
        self.put((v as u32) & ((1u32 << n) - 1), n);
    }
    pub fn byte_align(&mut self) {
        while self.pos & 7 != 0 {
            self.bit(0);
        }
    }
    pub fn trailing_bits(&mut self) {
        self.bit(1);
        self.byte_align();
    }
}

pub(crate) fn put_leb128(o: &mut Vec<u8>, mut v: u64) {
    loop {
        let mut b = (v & 0x7f) as u8;
        v >>= 7;
        if v != 0 {
            b |= 0x80;
        }
        o.push(b);
        if v == 0 {
            break;
        }
    }
}

/// sequence_header_obu and uncompressed_header of a record's frame parameters: a reduced still
/// picture, as Encoder::write_headers (and av1enc's copy, which is the same), or with `fp.video`
/// a key or inter frame of a stream (the sequence header is the same for every frame of a stream).
pub(crate) fn write_headers(
    fp: &FrameParams,
    tiles: &TileInfo,
    context_tile: u32,
    level: i32,
    seq: &mut BitWriter,
    fh: &mut BitWriter,
) {
    let (w, h) = (fp.width as i32, fp.height as i32);
    let mono = fp.monochrome as u32;
    let video = fp.video != 0;
    let inter = video && fp.frame_type == crate::types::FRAME_INTER;
    let diff_uv = (fp.delta_q_v_dc != fp.delta_q_u_dc || fp.delta_q_v_ac != fp.delta_q_u_ac) as u32;
    let separate_uv = (mono == 0 && (diff_uv != 0 || (fp.using_qmatrix != 0 && fp.qm_v != fp.qm_u))) as u32;
    seq.put(0, 3); // seq_profile = Main
    if video {
        seq.put(0, 1); // still_picture
        seq.put(0, 1); // reduced_still_picture_header
        seq.put(0, 1); // timing_info_present_flag
        seq.put(0, 1); // initial_display_delay_present_flag
        seq.put(0, 5); // operating_points_cnt_minus_1
        seq.put(0, 12); // operating_point_idc[0]
        seq.put(level as u32, 5); // seq_level_idx[0]
        if level > 7 {
            seq.put(0, 1); // seq_tier[0]
        }
    } else {
        seq.put(1, 1); // still_picture
        seq.put(1, 1); // reduced_still_picture_header
        seq.put(level as u32, 5); // seq_level_idx[0]
    }
    let (mut wb, mut hb) = (1, 1);
    while wb < 32 && ((w - 1) as u32) >> wb != 0 {
        wb += 1;
    }
    while hb < 32 && ((h - 1) as u32) >> hb != 0 {
        hb += 1;
    }
    seq.put((wb - 1) as u32, 4); // frame_width_bits_minus_1
    seq.put((hb - 1) as u32, 4);
    seq.put((w - 1) as u32, wb); // max_frame_width_minus_1
    seq.put((h - 1) as u32, hb);
    if video {
        seq.put(0, 1); // frame_id_numbers_present_flag
    }
    seq.put(0, 1); // use_128x128_superblock
    seq.put(fp.enable_filter_intra as u32, 1);
    seq.put(fp.enable_intra_edge_filter as u32, 1);
    if video {
        seq.put(0, 1); // enable_interintra_compound
        seq.put(0, 1); // enable_masked_compound
        seq.put(0, 1); // enable_warped_motion
        seq.put(0, 1); // enable_dual_filter
        seq.put(0, 1); // enable_order_hint (so no jnt_comp, ref-frame MVs, order hints)
        // Screen content tools are chosen per frame, so that a key frame codes exactly a still
        // picture's tile data; with them (every inter frame), force_integer_mv = 1.
        seq.put(1, 1); // seq_choose_screen_content_tools: SELECT_SCREEN_CONTENT_TOOLS
        seq.put(0, 1); // seq_choose_integer_mv
        seq.put(1, 1); // seq_force_integer_mv
    }
    seq.put(0, 1); // enable_superres
    seq.put(fp.enable_cdef as u32, 1);
    seq.put(0, 1); // enable_restoration
    // color_config
    seq.put(0, 1); // high_bitdepth
    seq.put(mono, 1); // mono_chrome
    seq.put(1, 1); // color_description_present_flag
    seq.put(1, 8); // color_primaries = CP_BT_709
    seq.put(13, 8); // transfer_characteristics = TC_SRGB
    seq.put(6, 8); // matrix_coefficients = MC_BT_601
    seq.put(1, 1); // color_range = full
    if mono == 0 {
        seq.put(0, 2); // chroma_sample_position = CSP_UNKNOWN
        seq.put(separate_uv, 1); // separate_uv_delta_q
    }
    seq.put(0, 1); // film_grain_params_present
    seq.trailing_bits();

    // ---- uncompressed_header ----
    let sct = fp.allow_screen_content_tools as u32;
    if video {
        fh.put(0, 1); // show_existing_frame
        fh.put(inter as u32, 2); // frame_type: KEY_FRAME / INTER_FRAME
        fh.put(1, 1); // show_frame (showable_frame = frame_type != KEY_FRAME)
        if inter {
            fh.put(fp.error_resilient_mode as u32, 1); // (key frames shown: 1)
        }
        fh.put(0, 1); // disable_cdf_update
        fh.put(sct, 1); // allow_screen_content_tools (SELECT); force_integer_mv = seq's 1
        fh.put(0, 1); // frame_size_override_flag
        if inter {
            if fp.error_resilient_mode == 0 {
                // primary_ref_frame: LAST_FRAME (ref_frame_idx[0]) for its saved CDFs, or NONE
                fh.put(
                    if fp.cdf_from_ref != 0 {
                        0
                    } else {
                        PRIMARY_REF_NONE as u32
                    },
                    3,
                );
            }
            fh.put(fp.refresh_frame_flags as u32, 8);
            for _ in 0..REFS_PER_FRAME {
                fh.put(fp.ref_slot as u32, 3); // ref_frame_idx[i]
            }
            fh.put(0, 1); // render_and_frame_size_different
            // force_integer_mv: no allow_high_precision_mv
            fh.put(0, 1); // is_filter_switchable
            fh.put(EIGHTTAP as u32, 2); // interpolation_filter
            fh.put(0, 1); // is_motion_mode_switchable
        } else {
            // key frame: refresh_frame_flags = allFrames, primary_ref_frame = NONE
            fh.put(0, 1); // render_and_frame_size_different
            if sct != 0 {
                fh.put(0, 1); // allow_intrabc
            }
        }
        fh.put(0, 1); // disable_frame_end_update_cdf: every frame saves its CDFs
    } else {
        fh.put(0, 1); // disable_cdf_update
        fh.put(sct, 1); // allow_screen_content_tools
        if sct != 0 {
            fh.put(0, 1); // force_integer_mv (overridden to 1 for intra frames)
        }
        fh.put(0, 1); // render_and_frame_size_different
        if sct != 0 {
            fh.put(0, 1); // allow_intrabc
        }
    }
    // tile_info
    fh.put(1, 1); // uniform_tile_spacing_flag
    for k in tiles.min_log2_tile_cols..tiles.max_log2_tile_cols {
        if k < tiles.cols_log2 {
            fh.put(1, 1);
        } else {
            fh.put(0, 1);
            break;
        }
    }
    for k in tiles.min_log2_tile_rows..tiles.max_log2_tile_rows {
        if k < tiles.rows_log2 {
            fh.put(1, 1);
        } else {
            fh.put(0, 1);
            break;
        }
    }
    if tiles.cols_log2 > 0 || tiles.rows_log2 > 0 {
        fh.put(context_tile, tiles.cols_log2 + tiles.rows_log2); // context_update_tile_id
        fh.put((tiles.tile_size_bytes - 1) as u32, 2); // tile_size_bytes_minus_1
    }
    // quantization_params
    fh.put(fp.base_q_idx as u32, 8);
    let delta_q = |fh: &mut BitWriter, v: i8| {
        if v != 0 {
            fh.put(1, 1);
            fh.su(v as i32, 7);
        } else {
            fh.put(0, 1);
        }
    };
    delta_q(fh, fp.delta_q_y_dc);
    if mono == 0 {
        if separate_uv != 0 {
            fh.put(diff_uv, 1); // diff_uv_delta
        }
        delta_q(fh, fp.delta_q_u_dc);
        delta_q(fh, fp.delta_q_u_ac);
        if diff_uv != 0 {
            delta_q(fh, fp.delta_q_v_dc);
            delta_q(fh, fp.delta_q_v_ac);
        }
    }
    fh.put(fp.using_qmatrix as u32, 1);
    if fp.using_qmatrix != 0 {
        fh.put(fp.qm_y as u32, 4);
        fh.put(fp.qm_u as u32, 4);
        if separate_uv != 0 {
            fh.put(fp.qm_v as u32, 4);
        }
    }
    fh.put(0, 1); // segmentation_enabled
    fh.put(fp.delta_q_present as u32, 1); // delta_q_present (base_q_idx > 0)
    if fp.delta_q_present != 0 {
        fh.put(fp.delta_q_res as u32, 2);
        fh.put(0, 1); // delta_lf_present
    }
    // loop_filter_params (effective levels; ref deltas off)
    let lf = fp.loop_filter_level;
    fh.put(lf[0] as u32, 6);
    fh.put(lf[1] as u32, 6);
    if mono == 0 && (lf[0] != 0 || lf[1] != 0) {
        fh.put(lf[2] as u32, 6);
        fh.put(lf[3] as u32, 6);
    }
    fh.put(fp.loop_filter_sharpness as u32, 3);
    if fp.lf_inter_off != 0 {
        // loop_filter_delta_enabled, _update; from setup_past_independence's ref deltas
        // (INTRA_FRAME 1, LAST_FRAME 0): INTRA_FRAME 0 (the levels as given), LAST_FRAME -63
        // (inter blocks at level 0); the mode deltas stay 0
        fh.put(1, 1);
        fh.put(1, 1);
        for i in 0..8 {
            match i {
                0 => {
                    fh.put(1, 1);
                    fh.su(0, 7);
                }
                1 => {
                    fh.put(1, 1);
                    fh.su(-63, 7);
                }
                _ => fh.put(0, 1),
            }
        }
        fh.put(0, 1);
        fh.put(0, 1);
    } else {
        fh.put(0, 1); // loop_filter_delta_enabled
    }
    if fp.enable_cdef != 0 {
        // cdef_params
        fh.put(fp.cdef_damping_minus_3 as u32, 2);
        fh.put(fp.cdef_bits as u32, 2);
        let sec = |v: u8| if v == 4 { 3 } else { v as u32 };
        for i in 0..(1usize << fp.cdef_bits) {
            fh.put(fp.cdef_y_pri[i] as u32, 4);
            fh.put(sec(fp.cdef_y_sec[i]), 2);
            if mono == 0 {
                fh.put(fp.cdef_uv_pri[i] as u32, 4);
                fh.put(sec(fp.cdef_uv_sec[i]), 2);
            }
        }
    }
    // lr_params: disabled in the sequence header
    fh.put((fp.tx_mode_select != 0) as u32, 1);
    if inter {
        fh.put(0, 1); // reference_select (frame_reference_mode); no skip mode, no warped motion
    }
    fh.put((fp.reduced_tx_set != 0) as u32, 1);
    if inter {
        for _ in LAST_FRAME..=ALTREF_FRAME {
            fh.put(0, 1); // is_global (global_motion_params)
        }
    }
    fh.byte_align();
}

/// The OBUs of a picture around its tile payloads (tile raster order): [TD] + sequence header +
/// OBU_FRAME, into `out` (cleared). Sets `tiles.tile_size_bytes` from the payloads. `seq` / `fh` are
/// scratch. `level`: seq_level_idx, or None for the smallest that fits. Returns the sum of the
/// payload sizes and the level.
pub(crate) fn frame_obus<P: AsRef<[u8]>>(
    fp: &FrameParams,
    tiles: &mut TileInfo,
    context_tile: u32,
    level: Option<i32>,
    payloads: &[P],
    temporal_delimiter: bool,
    seq: &mut BitWriter,
    fh: &mut BitWriter,
    out: &mut Vec<u8>,
) -> (u64, i32) {
    let n = payloads.len();
    // TileSizeBytes: the smallest that holds every tile_size_minus_1 except the last tile's
    let max_sz = payloads[..n.saturating_sub(1)]
        .iter()
        .map(|p| (p.as_ref().len() as u64).wrapping_sub(1))
        .max()
        .unwrap_or(0);
    tiles.tile_size_bytes = if max_sz < 1 << 8 {
        1
    } else if max_sz < 1 << 16 {
        2
    } else if max_sz < 1 << 24 {
        3
    } else {
        4
    };
    let level = level.unwrap_or_else(|| super::choose_level(fp.width, fp.height, n as i32, tiles.cols as i32));
    seq.clear();
    fh.clear();
    write_headers(fp, tiles, context_tile, level, seq, fh);
    let tile_bytes: u64 = payloads.iter().map(|p| p.as_ref().len() as u64).sum();
    let tsb = tiles.tile_size_bytes as usize;
    let frame_len = fh.buf.len() + (n > 1) as usize + tile_bytes as usize + n.saturating_sub(1) * tsb;
    out.clear();
    out.reserve(frame_len + seq.buf.len() + 24);
    if temporal_delimiter {
        out.extend_from_slice(&[0x12, 0x00]);
    }
    out.push(0x0A); // OBU_SEQUENCE_HEADER, has_size_field
    put_leb128(out, seq.buf.len() as u64);
    out.extend_from_slice(&seq.buf);
    out.push(0x32); // OBU_FRAME, has_size_field
    put_leb128(out, frame_len as u64);
    out.extend_from_slice(&fh.buf);
    if n > 1 {
        out.push(0); // tile_start_and_end_present_flag = 0 + byte_alignment
    }
    for (i, p) in payloads.iter().enumerate() {
        let p = p.as_ref();
        if i + 1 < n {
            let v = (p.len() as u64).wrapping_sub(1);
            for k in 0..tsb {
                out.push((v >> (8 * k)) as u8);
            }
        }
        out.extend_from_slice(p);
    }
    (tile_bytes, level)
}
