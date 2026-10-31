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

    /// Every CDF's adaptation counter (its last element) set to 0, as the frame-end CDF update
    /// leaves the saved CDFs.
    pub fn clear_counters(&mut self) {
        let w = self.words_mut();
        for (id, len, n) in Cdfs::arrays() {
            for k in 0..n {
                w[id + k * len + len - 1] = 0;
            }
        }
    }

    /// The cdf id (u16 offset in the struct) of `cdf`, a CDF inside the Cdfs at `base`
    /// (`self as *const Cdfs as usize`, taken before borrowing the field).
    #[inline(always)]
    pub fn cdf_id(base: usize, cdf: &[u16]) -> u32 {
        ((cdf.as_ptr() as usize - base) / 2) as u32
    }
}

/// The CDFs inter frames add (spec init_non_coeff_cdfs; MvCtx 0 only: no intra block copy). Not
/// part of [`Cdfs`], whose layout the GPU entropy kernels share: inter frames aren't coded there.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InterCdfs {
    /// YModeCdf (intra blocks of inter frames), by Size_Group
    pub y_mode: [[u16; 14]; 4],
    pub is_inter: [[u16; 3]; 4],
    /// SingleRefCdf[ctx][p - 1]
    pub single_ref: [[[u16; 3]; 6]; 3],
    pub new_mv: [[u16; 3]; 6],
    pub zero_mv: [[u16; 3]; 2],
    pub ref_mv: [[u16; 3]; 6],
    pub drl_mode: [[u16; 3]; 3],
    pub txfm_split: [[u16; 3]; 21],
    pub mv_joint: [u16; 5],
    /// per component (0: row, 1: col)
    pub mv_class: [[u16; 12]; 2],
    pub mv_class0_bit: [[u16; 3]; 2],
    pub mv_sign: [[u16; 3]; 2],
    pub mv_bit: [[[u16; 3]; 10]; 2],
    /// InterTxTypeSet1Cdf[Tx_Size_Sqr], Set2, Set3Cdf[Tx_Size_Sqr]
    pub inter_tx_set1: [[u16; 17]; 2],
    pub inter_tx_set2: [u16; 13],
    pub inter_tx_set3: [[u16; 3]; 4],
}

impl Default for InterCdfs {
    fn default() -> Self {
        InterCdfs {
            y_mode: Default_Y_Mode_Cdf,
            is_inter: Default_Is_Inter_Cdf,
            single_ref: Default_Single_Ref_Cdf,
            new_mv: Default_New_Mv_Cdf,
            zero_mv: Default_Zero_Mv_Cdf,
            ref_mv: Default_Ref_Mv_Cdf,
            drl_mode: Default_Drl_Mode_Cdf,
            txfm_split: Default_Txfm_Split_Cdf,
            mv_joint: Default_Mv_Joint_Cdf,
            mv_class: Default_Mv_Class_Cdf,
            mv_class0_bit: [Default_Mv_Class0_Bit_Cdf; 2],
            mv_sign: [Default_Mv_Sign_Cdf; 2],
            mv_bit: [Default_Mv_Bit_Cdf; 2],
            inter_tx_set1: Default_Inter_Tx_Type_Set1_Cdf,
            inter_tx_set2: Default_Inter_Tx_Type_Set2_Cdf,
            inter_tx_set3: Default_Inter_Tx_Type_Set3_Cdf,
        }
    }
}

impl InterCdfs {
    /// The defaults, in place.
    pub fn init(&mut self) {
        *self = Self::default();
    }

    /// [`Cdfs::clear_counters`].
    pub fn clear_counters(&mut self) {
        fn clear<const L: usize>(cdfs: &mut [[u16; L]]) {
            for c in cdfs {
                c[L - 1] = 0;
            }
        }
        clear(&mut self.y_mode);
        clear(&mut self.is_inter);
        clear(self.single_ref.as_flattened_mut());
        clear(&mut self.new_mv);
        clear(&mut self.zero_mv);
        clear(&mut self.ref_mv);
        clear(&mut self.drl_mode);
        clear(&mut self.txfm_split);
        clear(core::slice::from_mut(&mut self.mv_joint));
        clear(&mut self.mv_class);
        clear(&mut self.mv_class0_bit);
        clear(&mut self.mv_sign);
        clear(self.mv_bit.as_flattened_mut());
        clear(&mut self.inter_tx_set1);
        clear(core::slice::from_mut(&mut self.inter_tx_set2));
        clear(&mut self.inter_tx_set3);
    }
}

/// A frame's saved CDFs (the spec's save_cdfs / load_cdfs, per reference slot): what a later frame
/// whose primary_ref_frame names the slot starts from. Every CDF the writer codes: the end of the
/// frame's context_update_tile_id tile, counters cleared.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrameCdfs {
    pub cdf: Cdfs,
    pub icdf: InterCdfs,
}

impl FrameCdfs {
    /// The defaults (a frame with primary_ref_frame NONE starts there), coefficient CDFs for
    /// `base_q_idx`.
    pub fn new(base_q_idx: i32) -> FrameCdfs {
        FrameCdfs {
            cdf: Cdfs::new(base_q_idx),
            icdf: InterCdfs::default(),
        }
    }

    pub fn clear_counters(&mut self) {
        self.cdf.clear_counters();
        self.icdf.clear_counters();
    }
}
