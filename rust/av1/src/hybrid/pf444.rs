//! The post-filters of a picture the GPU's filters don't take (4:4:4: theirs are 4:2:0's), on the
//! CPU: deblocking at tune=iq's level from the qindex, then CDEF with the GPU's search on the
//! crate's own filters ([`crate::postfilter`]) and its searches ([`crate::enc::lfsearch`]): SSE
//! tables per 64x64 and candidate (libaom's CDEF_FAST_SEARCH_LVL4: primary {0, 11} x secondary
//! {0, 2}), [`cdef_select_cpu`]'s presets, [`cdef_bits`]' RD choice of how many, every active 64x64
//! the cheapest of them. What [`crate::hybrid`]'s caller does on the GPU for 4:2:0
//! (`AV1MetalPostfilter.search`), as libaom's tune=iq frame decisions say.
use super::{Error, Hybrid, error};
use crate::blockinfo::chroma_ss;
use crate::enc::lfsearch::{cdef_bits, cdef_presets, cdef_select_cpu};
use crate::enc::tuneiq::tuneiq_frame_init;
use crate::postfilter::{PF_BLK_INTER, PF_BLK_LF_ZERO, PfFrame, PfMapsBuf, cdef_frame, deblock_frame};
use crate::types::{ERR_INVALID, FRAME_INTER, FrameParams, GaCdefCand};

/// libaom's fast CDEF candidates (CDEF_FAST_SEARCH_LVL4), the GPU search's
/// (`AV1MetalPostfilter.candidates`).
pub const CDEF_CANDIDATES: GaCdefCand = GaCdefCand {
    pri: [0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    sec: [0, 2, 0, 0],
    npri: 2,
    nsec: 2,
};
/// The presets' search: up to 2^3, refined 4 times (`AV1MetalPostfilter.maxCDEFBits`, `refinements`).
const MAX_CDEF_BITS: usize = 3;
const REFINEMENTS: usize = 4;

/// The filters' buffers, kept from picture to picture.
#[derive(Default)]
pub(super) struct PfBufs {
    deblocked: [Vec<u8>; 3],
    cdef: [Vec<u8>; 3],
    my: Vec<u32>,
    muv: Vec<u32>,
}

impl Hybrid {
    /// av1enc_hybrid_postfilter_cpu: the last closed loop's picture deblocked and CDEF-filtered on
    /// the CPU (module docs), into `out` (planes cropped to the picture, rows `out_stride` apart).
    /// Returns the frame's filter parameters (the record's with deblocking and CDEF set) for
    /// [`Hybrid::write`], and each 64x64's cdef_idx (raster, -1: none) into `sb_cdef`. The closed
    /// loop's own reconstruction is left as it was (the next picture's tiles are kept from it).
    /// Not for a frame with intra block copies (no post-filters), nor one whose reconstruction or
    /// source was its caller's.
    pub fn postfilter_cpu(
        &mut self,
        mut out: [&mut [u8]; 3],
        out_stride: [usize; 3],
        sb_cdef: &mut Vec<i8>,
    ) -> Result<FrameParams, Error> {
        if self.recon_given || self.src_given {
            return Err(error(
                ERR_INVALID,
                "postfilter_cpu: the reconstruction or source was the caller's",
            ));
        }
        let Hybrid {
            recs,
            outs,
            cur,
            src,
            pf,
            ..
        } = self;
        let (rec, o) = (&recs[*cur], &outs[*cur]);
        if rec.blocks.is_empty() || rec.fp.allow_intrabc != 0 || rec.fp.monochrome != 0 {
            return Err(error(
                ERR_INVALID,
                "postfilter_cpu: no picture, or one with intra block copies",
            ));
        }
        let ss = chroma_ss(&rec.fp);
        let (w, h) = (rec.fp.width as usize, rec.fp.height as usize);
        let cw = [w, (w + ss as usize) >> ss, (w + ss as usize) >> ss];
        let ch = [h, (h + ss as usize) >> ss, (h + ss as usize) >> ss];
        if (0..3).any(|p| out_stride[p] < cw[p] || out[p].len() < out_stride[p] * (ch[p] - 1) + cw[p]) {
            return Err(error(ERR_INVALID, "postfilter_cpu: output planes too small"));
        }
        let t = tuneiq_frame_init(rec.fp.base_q_idx as i32, ss, ss, false);
        let mut fp = rec.fp;
        let lvl = t.lf_level as u8;
        fp.loop_filter_level = [lvl; 4];
        fp.loop_filter_sharpness = t.lf_sharpness as u8;
        fp.enable_cdef = 1;
        fp.cdef_bits = 0;
        fp.cdef_damping_minus_3 = (t.cdef_damping - 3) as u8;
        (fp.cdef_y_pri, fp.cdef_y_sec, fp.cdef_uv_pri, fp.cdef_uv_sec) = ([0; 8], [0; 8], [0; 8], [0; 8]);
        // the maps: inter blocks (not deblocked with lf_inter_off), every active 64x64 preset 0
        let f = PfFrame::new(&fp);
        let mut maps = PfMapsBuf::new(&f);
        let lf_off = fp.frame_type == FRAME_INTER && fp.lf_inter_off != 0;
        for (i, b) in rec.blocks.iter().enumerate() {
            let inter = rec.inter.get(i).is_some_and(|x| x.is_inter != 0);
            let flags = match (inter, lf_off) {
                (false, _) => 0,
                (true, true) => PF_BLK_LF_ZERO | PF_BLK_INTER,
                (true, false) => PF_BLK_INTER,
            };
            maps.mark_block_flags(&f, b, flags);
        }
        for c in &mut maps.cdef_idx {
            *c = (*c).min(0);
        }
        // deblocked, in the filters' own copy of the reconstruction
        let stride: [usize; 3] = core::array::from_fn(|p| o.recon_w[p] as usize);
        for p in 0..3 {
            pf.deblocked[p].clear();
            pf.deblocked[p].extend_from_slice(&o.recon[p]);
            pf.cdef[p].resize(o.recon[p].len(), 0);
        }
        {
            let [a, b, c] = &mut pf.deblocked;
            deblock_frame(&f, &maps.maps(), &mut [a, b, c], &stride);
        }
        let nsb = (f.sb_cols * f.sb_rows) as usize;
        let sbc = f.sb_cols as usize;
        let src = src.view();
        let crop = |data: &[Vec<u8>; 3], out: &mut [&mut [u8]; 3]| {
            for p in 0..3 {
                for y in 0..ch[p] {
                    out[p][y * out_stride[p]..][..cw[p]].copy_from_slice(&data[p][y * stride[p]..][..cw[p]]);
                }
            }
        };
        if t.cdef_mode == 0 {
            // libaom at qindex 32 and under: one all-zero preset, signalled but inactive
            crop(&pf.deblocked, &mut out);
            sb_cdef.clear();
            sb_cdef.extend_from_slice(&maps.cdef_idx);
            return Ok(fp);
        }
        // each candidate's SSE per 64x64, luma and chroma (U and V)
        let cand = CDEF_CANDIDATES;
        let nc = (cand.npri * cand.nsec) as usize;
        pf.my.clear();
        pf.my.resize(nsb * nc, 0);
        pf.muv.clear();
        pf.muv.resize(nsb * nc, 0);
        let deb: [&[u8]; 3] = [&pf.deblocked[0], &pf.deblocked[1], &pf.deblocked[2]];
        let sub = |p: usize| if p == 0 { 0 } else { ss as usize };
        for c in 0..nc {
            let mut fc = fp;
            let mut lev = [0i32; 16];
            (lev[0], lev[8]) = (c as i32, c as i32);
            cdef_presets(&lev, 0, t.cdef_mode, &cand, &mut fc);
            let [a, b, d] = &mut pf.cdef;
            cdef_frame(&PfFrame::new(&fc), &maps.maps(), &deb, &stride, &mut [a, b, d], &stride);
            for p in 0..3 {
                let side = 64 >> sub(p);
                for s in 0..nsb {
                    let (x0, y0) = ((s % sbc) * side, (s / sbc) * side);
                    if x0 >= cw[p] || y0 >= ch[p] {
                        continue;
                    }
                    let mut e = 0u32;
                    for y in y0..(y0 + side).min(ch[p]) {
                        let (r, q) = (&pf.cdef[p][y * stride[p] + x0..], &src.p[p][y * src.stride[p] + x0..]);
                        for x in 0..side.min(cw[p] - x0) {
                            let d = r[x] as i32 - q[x] as i32;
                            e += (d * d) as u32;
                        }
                    }
                    if p == 0 {
                        pf.my[s * nc + c] = e;
                    } else {
                        pf.muv[s * nc + c] += e;
                    }
                }
            }
        }
        let mut levels = [0i32; 16 * (MAX_CDEF_BITS + 1)];
        let mut totals = [0u64; MAX_CDEF_BITS + 1];
        cdef_select_cpu(
            &pf.my,
            &pf.muv,
            nc,
            nsb,
            false,
            MAX_CDEF_BITS,
            REFINEMENTS,
            false,
            &mut levels,
            &mut totals,
        );
        let active = maps.cdef_idx.iter().filter(|&&c| c >= 0).count() as i32;
        let bits = cdef_bits(&totals, MAX_CDEF_BITS as i32, active, false, t.rdmult) as usize;
        let lev: [i32; 16] = core::array::from_fn(|j| levels[bits * 16 + j]);
        cdef_presets(&lev, bits as i32, t.cdef_mode, &cand, &mut fp);
        // every active 64x64 the cheapest preset (the first on ties)
        for (s, c) in maps.cdef_idx.iter_mut().enumerate() {
            if *c < 0 {
                continue;
            }
            let cost = |g: usize| pf.my[s * nc + lev[g] as usize] as u64 + pf.muv[s * nc + lev[8 + g] as usize] as u64;
            *c = (0..1usize << bits).min_by_key(|&g| (cost(g), g)).unwrap_or(0) as i8;
        }
        let [a, b, d] = &mut pf.cdef;
        cdef_frame(&PfFrame::new(&fp), &maps.maps(), &deb, &stride, &mut [a, b, d], &stride);
        crop(&pf.cdef, &mut out);
        sb_cdef.clear();
        sb_cdef.extend_from_slice(&maps.cdef_idx);
        Ok(fp)
    }
}
