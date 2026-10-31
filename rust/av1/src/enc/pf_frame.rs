//! The post-filters' frame for the Metal kernels (Sources/AV1Encoder/src/postfilter.cpp,
//! Shaders/postfilter.metal), as av1gpu's av1g_gpu_pf_prepare sets it up.
use crate::postfilter::PfFrame;
use crate::types::{FrameParams, GaPfAddrs};

/// av1g_pf_frame (av1g/postfilter.h) as the kernels read it: the device addresses as u64, with the
/// C layout's padding spelled out (zero), so its bytes are the C++'s.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GpuPfFrame {
    pub w: i32,
    pub h: i32,
    pub mi_rows: i32,
    pub mi_cols: i32,
    pub mono: i32,
    pub _pad0: i32,
    pub plane: [u64; 3],
    pub stride: [i32; 3],
    pub _pad1: i32,
    pub skip: u64,
    pub lf_tx: [u64; 3],
    pub cdef_idx: u64,
    pub cdef_dir_var: u64,
    pub sb_cols: i32,
    pub sb_rows: i32,
    pub lf_level: [i32; 4],
    pub sharpness: i32,
    pub enable_cdef: i32,
    pub cdef_damping: i32,
    pub cdef_y_pri: [i32; 8],
    pub cdef_y_sec: [i32; 8],
    pub cdef_uv_pri: [i32; 8],
    pub cdef_uv_sec: [i32; 8],
    pub _pad2: i32,
}

const _: () = assert!(size_of::<GpuPfFrame>() == 280);

impl GpuPfFrame {
    /// The struct's bytes (every byte is a field: no implicit padding).
    pub fn as_bytes(&self) -> &[u8] {
        // SAFETY: repr(C), only i32 / u64 fields laid out without implicit padding (the size assert
        // and the layout test), so every byte is initialized.
        unsafe { core::slice::from_raw_parts(self as *const Self as *const u8, size_of::<Self>()) }
    }
}

/// av1enc_pf_frame: av1g_pf_frame_init of the frame parameters with the GPU addresses of the planes
/// and maps.
pub fn pf_frame(fp: &FrameParams, a: &GaPfAddrs) -> GpuPfFrame {
    let f = PfFrame::new(fp);
    GpuPfFrame {
        w: f.w,
        h: f.h,
        mi_rows: f.mi_rows,
        mi_cols: f.mi_cols,
        mono: fp.monochrome as i32,
        plane: a.plane,
        stride: a.stride,
        skip: a.skip,
        lf_tx: a.lf_tx,
        cdef_idx: a.cdef_idx,
        cdef_dir_var: a.cdef_dir_var,
        sb_cols: f.sb_cols,
        sb_rows: f.sb_rows,
        lf_level: f.lf_level,
        sharpness: f.sharpness,
        enable_cdef: fp.enable_cdef as i32,
        cdef_damping: f.cdef_damping,
        cdef_y_pri: f.cdef_y_pri,
        cdef_y_sec: f.cdef_y_sec,
        cdef_uv_pri: f.cdef_uv_pri,
        cdef_uv_sec: f.cdef_uv_sec,
        ..Default::default()
    }
}
