//! The adaptive CDF state of one tile (av1g/cdfctx.h): the intra-only subset of the spec's Tile*
//! arrays as one flat struct of u16, so that a CDF is named by its u16 offset inside it (the
//! "cdf id" of the symbol streams, [`super::symstream`]). The GPU kernels use the same layout.
use crate::tables::*;
use core::mem::offset_of;

/// av1g_cdfs. `#[repr(C)]` and made of u16 arrays only, so it has the C layout with no padding.
#[repr(C)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cdfs {
    // non-coefficient CDFs (init_non_coeff_cdfs)
    pub y_mode: [[[u16; 14]; 5]; 5], // TileIntraFrameYModeCdf
    pub uv_mode_cfl_not_allowed: [[u16; 14]; 13],
    pub uv_mode_cfl_allowed: [[u16; 15]; 13],
    pub angle_delta: [[u16; 8]; 8],
    pub partition_w8: [[u16; 5]; 4],
    pub partition_w16: [[u16; 11]; 4],
    pub partition_w32: [[u16; 11]; 4],
    pub partition_w64: [[u16; 11]; 4],
    pub tx_8x8: [[u16; 3]; 3],
    pub tx_16x16: [[u16; 4]; 3],
    pub tx_32x32: [[u16; 4]; 3],
    pub tx_64x64: [[u16; 4]; 3],
    pub skip: [[u16; 3]; 3],
    pub filter_intra_mode: [u16; 6],
    pub filter_intra: [[u16; 3]; 22],
    pub delta_q: [u16; 5],
    pub delta_lf: [u16; 5],
    pub delta_lf_multi: [[u16; 5]; 4],
    pub intra_tx_set1: [[[u16; 8]; 13]; 2],
    pub intra_tx_set2: [[[u16; 6]; 13]; 3],
    pub cfl_sign: [u16; 9],
    pub cfl_alpha: [[u16; 17]; 6],
    pub palette_y_mode: [[[u16; 3]; 3]; 7], // has_palette_y (only with allow_screen_content_tools)
    pub palette_uv_mode: [[u16; 3]; 2],     // has_palette_uv
    // coefficient CDFs (init_coeff_cdfs, one quantizer context)
    pub txb_skip: [[[u16; 3]; 13]; 5],
    pub eob_pt_16: [[[u16; 6]; 2]; 2],
    pub eob_pt_32: [[[u16; 7]; 2]; 2],
    pub eob_pt_64: [[[u16; 8]; 2]; 2],
    pub eob_pt_128: [[[u16; 9]; 2]; 2],
    pub eob_pt_256: [[[u16; 10]; 2]; 2],
    pub eob_pt_512: [[u16; 11]; 2],
    pub eob_pt_1024: [[u16; 12]; 2],
    pub eob_extra: [[[[u16; 3]; 9]; 2]; 5],
    pub dc_sign: [[[u16; 3]; 3]; 2],
    pub coeff_base_eob: [[[[u16; 4]; 4]; 2]; 5],
    pub coeff_base: [[[[u16; 5]; 42]; 2]; 5],
    pub coeff_br: [[[[u16; 5]; 21]; 2]; 5],
}

/// The number of u16 in [`Cdfs`] (GP_NCDF).
pub const NCDF: usize = size_of::<Cdfs>() / 2;

const _: () = {
    assert!(size_of::<Cdfs>() == 11_440); // sizeof(av1g_cdfs), AV1MetalEntropy.cdfBytes
    assert!(align_of::<Cdfs>() == 2);
};

/// av1g_coeff_cdf_q_ctx: the quantizer context of init_coeff_cdfs.
#[inline]
pub fn coeff_cdf_q_ctx(base_q_idx: i32) -> usize {
    if base_q_idx <= 20 {
        0
    } else if base_q_idx <= 60 {
        1
    } else if base_q_idx <= 120 {
        2
    } else {
        3
    }
}

impl Cdfs {
    /// av1g_cdfs_init: the default CDFs, the coefficient ones for `base_q_idx`'s q context.
    pub fn new(base_q_idx: i32) -> Self {
        let q = coeff_cdf_q_ctx(base_q_idx);
        Cdfs {
            y_mode: Default_Intra_Frame_Y_Mode_Cdf,
            uv_mode_cfl_not_allowed: Default_Uv_Mode_Cfl_Not_Allowed_Cdf,
            uv_mode_cfl_allowed: Default_Uv_Mode_Cfl_Allowed_Cdf,
            angle_delta: Default_Angle_Delta_Cdf,
            partition_w8: Default_Partition_W8_Cdf,
            partition_w16: Default_Partition_W16_Cdf,
            partition_w32: Default_Partition_W32_Cdf,
            partition_w64: Default_Partition_W64_Cdf,
            tx_8x8: Default_Tx_8x8_Cdf,
            tx_16x16: Default_Tx_16x16_Cdf,
            tx_32x32: Default_Tx_32x32_Cdf,
            tx_64x64: Default_Tx_64x64_Cdf,
            skip: Default_Skip_Cdf,
            filter_intra_mode: Default_Filter_Intra_Mode_Cdf,
            filter_intra: Default_Filter_Intra_Cdf,
            delta_q: Default_Delta_Q_Cdf,
            delta_lf: Default_Delta_Lf_Cdf,
            delta_lf_multi: [Default_Delta_Lf_Cdf; 4],
            intra_tx_set1: Default_Intra_Tx_Type_Set1_Cdf,
            intra_tx_set2: Default_Intra_Tx_Type_Set2_Cdf,
            cfl_sign: Default_Cfl_Sign_Cdf,
            cfl_alpha: Default_Cfl_Alpha_Cdf,
            palette_y_mode: Default_Palette_Y_Mode_Cdf,
            palette_uv_mode: Default_Palette_Uv_Mode_Cdf,
            txb_skip: Default_Txb_Skip_Cdf[q],
            eob_pt_16: Default_Eob_Pt_16_Cdf[q],
            eob_pt_32: Default_Eob_Pt_32_Cdf[q],
            eob_pt_64: Default_Eob_Pt_64_Cdf[q],
            eob_pt_128: Default_Eob_Pt_128_Cdf[q],
            eob_pt_256: Default_Eob_Pt_256_Cdf[q],
            eob_pt_512: Default_Eob_Pt_512_Cdf[q],
            eob_pt_1024: Default_Eob_Pt_1024_Cdf[q],
            eob_extra: Default_Eob_Extra_Cdf[q],
            dc_sign: Default_Dc_Sign_Cdf[q],
            coeff_base_eob: Default_Coeff_Base_Eob_Cdf[q],
            coeff_base: Default_Coeff_Base_Cdf[q],
            coeff_br: Default_Coeff_Br_Cdf[q],
        }
    }

    /// av1g_cdfs_init in place.
    pub fn init(&mut self, base_q_idx: i32) {
        *self = Self::new(base_q_idx);
    }

    /// The struct as its u16 words, which cdf ids index.
    #[inline(always)]
    pub fn words(&self) -> &[u16; NCDF] {
        // SAFETY: Cdfs is repr(C), made only of u16 arrays (no padding, align 2), NCDF words long.
        unsafe { &*(self as *const Cdfs as *const [u16; NCDF]) }
    }

    #[inline(always)]
    pub fn words_mut(&mut self) -> &mut [u16; NCDF] {
        // SAFETY: as in words(); every u16 bit pattern is a valid Cdfs.
        unsafe { &mut *(self as *mut Cdfs as *mut [u16; NCDF]) }
    }

    /// Every CDF array, in field order: (cdf id of its first CDF, CDF length N + 1, number of CDFs).
    pub fn arrays() -> [(usize, usize, usize); 37] {
        let c = Cdfs::new(0);
        macro_rules! f {
            ($($f:ident : $l:literal),*) => {
                [$((offset_of!(Cdfs, $f) / 2, $l, size_of_val(&c.$f) / 2 / $l)),*]
            };
        }
        f!(y_mode: 14, uv_mode_cfl_not_allowed: 14, uv_mode_cfl_allowed: 15, angle_delta: 8, partition_w8: 5,
           partition_w16: 11, partition_w32: 11, partition_w64: 11, tx_8x8: 3, tx_16x16: 4, tx_32x32: 4,
           tx_64x64: 4, skip: 3, filter_intra_mode: 6, filter_intra: 3, delta_q: 5, delta_lf: 5, delta_lf_multi: 5,
           intra_tx_set1: 8, intra_tx_set2: 6, cfl_sign: 9, cfl_alpha: 17, palette_y_mode: 3, palette_uv_mode: 3,
           txb_skip: 3, eob_pt_16: 6, eob_pt_32: 7, eob_pt_64: 8, eob_pt_128: 9, eob_pt_256: 10, eob_pt_512: 11,
           eob_pt_1024: 12, eob_extra: 3, dc_sign: 3, coeff_base_eob: 4, coeff_base: 5, coeff_br: 5)
    }

    /// The cdf id (u16 offset in the struct) of `cdf`, a CDF inside the Cdfs at `base`
    /// (`self as *const Cdfs as usize`, taken before borrowing the field).
    #[inline(always)]
    pub fn cdf_id(base: usize, cdf: &[u16]) -> u32 {
        ((cdf.as_ptr() as usize - base) / 2) as u32
    }
}
