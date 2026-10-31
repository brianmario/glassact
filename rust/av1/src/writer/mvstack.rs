//! The motion vector candidate stack (spec 7.10.2, find_mv_stack) for the writer's inter
//! toolset: single prediction from LAST_FRAME, identity global motion (GlobalMvs are 0),
//! force_integer_mv = 1, no reference-frame MVs (use_ref_frame_mvs = 0: no temporal scan, so
//! ZeroMvContext is 0), 64x64 superblocks. It reads only the tile's mode info of blocks already
//! coded, so the writer and the parser build the same stack.
//!
//! [`derive_mode`] is the writer's rule from a block's motion vector to its mode (decisions.h
//! "Inter blocks").
use crate::tables::*;

/// One tile's mode info at 4x4 granularity (tile-local, `mw` wide, origin (`r0`, `c0`)), as the
/// stack reads it.
pub(crate) struct MvMaps<'a> {
    /// RefFrames[.][.][0]: 0 intra, 1 LAST_FRAME, [`REF_UNSET`] not coded yet in this frame
    pub ref0: &'a [u8],
    /// Mvs[.][.][0] as [row, col] (1/8 sample), valid where ref0 is LAST_FRAME
    pub mvs: &'a [[i16; 2]],
    /// YModes (inter modes for inter blocks)
    pub y_mode: &'a [u8],
    pub mi_size: &'a [u8],
    pub r0: i32,
    pub c0: i32,
    pub mw: i32,
    /// the tile, for is_inside
    pub row_start: i32,
    pub row_end: i32,
    pub col_start: i32,
    pub col_end: i32,
    pub mi_rows: i32,
    pub mi_cols: i32,
}

/// RefFrames of a 4x4 not coded yet in this frame.
pub(crate) const REF_UNSET: u8 = 0xFF;

impl MvMaps<'_> {
    #[inline(always)]
    fn is_inside(&self, r: i32, c: i32) -> bool {
        c >= self.col_start && c < self.col_end && r >= self.row_start && r < self.row_end
    }
    #[inline(always)]
    fn at(&self, r: i32, c: i32) -> usize {
        ((r - self.r0) * self.mw + (c - self.c0)) as usize
    }
}

/// The stack and the contexts find_mv_stack prepares.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct MvStack {
    /// RefStackMv[idx][0] ([row, col]), clamped; entries NumMvFound..2 are the global MV (0)
    pub mv: [[i32; 2]; 8],
    pub weight: [u32; 8],
    /// NumMvFound
    pub num: usize,
    pub new_mv_ctx: usize,
    pub ref_mv_ctx: usize,
    pub drl_ctx: [usize; 8],
}

/// lower_mv_precision with force_integer_mv = 1 (allow_high_precision_mv = 0)
#[inline]
fn lower_precision(v: i32) -> i32 {
    let a = (v.abs() + 3) >> 3;
    if v > 0 { a << 3 } else { -(a << 3) }
}

struct Search<'a, 'b> {
    m: &'b MvMaps<'a>,
    mi_row: i32,
    mi_col: i32,
    bw4: i32,
    bh4: i32,
    s: MvStack,
    new_count: u32,
    found_match: bool,
}

impl Search<'_, '_> {
    /// add_ref_mv_candidate + search stack process (single prediction, candList 0: the second
    /// list is never LAST_FRAME here)
    fn add(&mut self, r: i32, c: i32, weight: u32) {
        let k = self.m.at(r, c);
        if self.m.ref0[k] != LAST_FRAME as u8 {
            return; // IsInters == 0 (or not LAST_FRAME)
        }
        let mv = self.m.mvs[k];
        let cand = [lower_precision(mv[0] as i32), lower_precision(mv[1] as i32)];
        if self.m.y_mode[k] as i32 == NEWMV {
            self.new_count += 1;
        }
        self.found_match = true;
        let s = &mut self.s;
        if let Some(i) = s.mv[..s.num].iter().position(|&m| m == cand) {
            s.weight[i] += weight;
        } else if s.num < MAX_REF_MV_STACK_SIZE as usize {
            s.mv[s.num] = cand;
            s.weight[s.num] = weight;
            s.num += 1;
        }
    }

    fn scan_row(&mut self, mut delta_row: i32) {
        let bw4 = self.bw4;
        let end4 = bw4.min(self.m.mi_cols - self.mi_col).min(16);
        let mut delta_col = 0;
        let use_step16 = bw4 >= 16;
        if delta_row.abs() > 1 {
            delta_row += self.mi_row & 1;
            delta_col = 1 - (self.mi_col & 1);
        }
        let mut i = 0;
        while i < end4 {
            let (r, c) = (self.mi_row + delta_row, self.mi_col + delta_col + i);
            if !self.m.is_inside(r, c) {
                break;
            }
            let mut len = bw4.min(Num_4x4_Blocks_Wide[self.m.mi_size[self.m.at(r, c)] as usize] as i32);
            if delta_row.abs() > 1 {
                len = len.max(2);
            }
            if use_step16 {
                len = len.max(4);
            }
            self.add(r, c, len as u32 * 2);
            i += len;
        }
    }

    fn scan_col(&mut self, mut delta_col: i32) {
        let bh4 = self.bh4;
        let end4 = bh4.min(self.m.mi_rows - self.mi_row).min(16);
        let mut delta_row = 0;
        let use_step16 = bh4 >= 16;
        if delta_col.abs() > 1 {
            delta_row = 1 - (self.mi_row & 1);
            delta_col += self.mi_col & 1;
        }
        let mut i = 0;
        while i < end4 {
            let (r, c) = (self.mi_row + delta_row + i, self.mi_col + delta_col);
            if !self.m.is_inside(r, c) {
                break;
            }
            let mut len = bh4.min(Num_4x4_Blocks_High[self.m.mi_size[self.m.at(r, c)] as usize] as i32);
            if delta_col.abs() > 1 {
                len = len.max(2);
            }
            if use_step16 {
                len = len.max(4);
            }
            self.add(r, c, len as u32 * 2);
            i += len;
        }
    }

    fn scan_point(&mut self, delta_row: i32, delta_col: i32) {
        let (r, c) = (self.mi_row + delta_row, self.mi_col + delta_col);
        if self.m.is_inside(r, c) && self.m.ref0[self.m.at(r, c)] != REF_UNSET {
            self.add(r, c, 4);
        }
    }

    /// the sorting process: a stable bubble sort by weight, descending
    fn sort(&mut self, start: usize, mut end: usize) {
        let s = &mut self.s;
        while end > start {
            let mut new_end = start;
            for idx in start + 1..end {
                if s.weight[idx - 1] < s.weight[idx] {
                    s.weight.swap(idx - 1, idx);
                    s.mv.swap(idx - 1, idx);
                    new_end = idx;
                }
            }
            end = new_end;
        }
    }

    /// the extra search process (single prediction)
    fn extra_search(&mut self) {
        let w4 = self.bw4.min(16).min(self.m.mi_cols - self.mi_col);
        let h4 = self.bh4.min(16).min(self.m.mi_rows - self.mi_row);
        let num4x4 = w4.min(h4);
        for pass in 0..2 {
            let mut idx = 0;
            while idx < num4x4 && self.s.num < 2 {
                let (r, c) = if pass == 0 {
                    (self.mi_row - 1, self.mi_col + idx)
                } else {
                    (self.mi_row + idx, self.mi_col - 1)
                };
                if !self.m.is_inside(r, c) {
                    break;
                }
                // add_extra_mv_candidate: RefFrameSignBias is 0 for every reference
                let k = self.m.at(r, c);
                if self.m.ref0[k] != REF_UNSET && self.m.ref0[k] as i32 > INTRA_FRAME {
                    let mv = self.m.mvs[k];
                    let cand = [mv[0] as i32, mv[1] as i32];
                    let s = &mut self.s;
                    if !s.mv[..s.num].contains(&cand) {
                        s.mv[s.num] = cand;
                        s.weight[s.num] = 2;
                        s.num += 1;
                    }
                }
                let sz = self.m.mi_size[k] as usize;
                idx += if pass == 0 {
                    Num_4x4_Blocks_Wide[sz]
                } else {
                    Num_4x4_Blocks_High[sz]
                } as i32;
            }
        }
        for idx in self.s.num..2 {
            self.s.mv[idx] = [0, 0]; // GlobalMvs[0]
        }
    }
}

/// find_mv_stack(0) for the block (mi_row, mi_col, bsize) of the tile `m`.
pub(crate) fn find_mv_stack(m: &MvMaps, mi_row: i32, mi_col: i32, bsize: i32) -> MvStack {
    let (bw4, bh4) = (
        Num_4x4_Blocks_Wide[bsize as usize] as i32,
        Num_4x4_Blocks_High[bsize as usize] as i32,
    );
    let mut q = Search {
        m,
        mi_row,
        mi_col,
        bw4,
        bh4,
        s: MvStack::default(),
        new_count: 0,
        found_match: false,
    };
    q.scan_row(-1);
    let mut found_above = q.found_match;
    q.found_match = false;
    q.scan_col(-1);
    let mut found_left = q.found_match;
    q.found_match = false;
    if bw4.max(bh4) <= 16 {
        q.scan_point(-1, bw4);
    }
    found_above |= q.found_match;
    let close_matches = found_above as usize + found_left as usize;
    let num_nearest = q.s.num;
    let num_new = q.new_count;
    for w in &mut q.s.weight[..num_nearest] {
        *w += REF_CAT_LEVEL as u32;
    }
    q.found_match = false;
    q.scan_point(-1, -1);
    found_above |= q.found_match;
    q.found_match = false;
    q.scan_row(-3);
    found_above |= q.found_match;
    q.found_match = false;
    q.scan_col(-3);
    found_left |= q.found_match;
    q.found_match = false;
    if bh4 > 1 {
        q.scan_row(-5);
    }
    found_above |= q.found_match;
    q.found_match = false;
    if bw4 > 1 {
        q.scan_col(-5);
    }
    found_left |= q.found_match;
    let total_matches = found_above as usize + found_left as usize;
    q.sort(0, num_nearest);
    let num = q.s.num;
    q.sort(num_nearest, num);
    if q.s.num < 2 {
        q.extra_search();
    }
    // context and clamping
    let mut s = q.s;
    for idx in 0..s.num {
        let mut z = 0;
        if idx + 1 < s.num {
            let (w0, w1) = (s.weight[idx], s.weight[idx + 1]);
            if w0 >= REF_CAT_LEVEL as u32 {
                if w1 < REF_CAT_LEVEL as u32 {
                    z = 1;
                }
            } else {
                z = 2;
            }
        }
        s.drl_ctx[idx] = z;
    }
    let (bw, bh) = (bw4 * 4, bh4 * 4);
    let mb_to_top = -(mi_row * 4 * 8);
    let mb_to_bottom = (m.mi_rows - bh4 - mi_row) * 4 * 8;
    let mb_to_left = -(mi_col * 4 * 8);
    let mb_to_right = (m.mi_cols - bw4 - mi_col) * 4 * 8;
    for mv in &mut s.mv[..s.num] {
        let (br, bc) = (MV_BORDER + bh * 8, MV_BORDER + bw * 8);
        mv[0] = mv[0].clamp(mb_to_top - br, mb_to_bottom + br);
        mv[1] = mv[1].clamp(mb_to_left - bc, mb_to_right + bc);
    }
    (s.new_mv_ctx, s.ref_mv_ctx) = match close_matches {
        0 => (total_matches.min(1), total_matches),
        1 => (3 - (num_new.min(1) as usize), 2 + total_matches),
        _ => (5 - (num_new.min(1) as usize), 5),
    };
    s
}

/// The MV-class bit cost the writer minimises for a NEWMV difference component (decisions.h): 0
/// for 0, else 2 + 2 * mv_class.
#[inline]
pub(crate) fn mv_comp_cost(d: i32) -> u32 {
    if d == 0 { 0 } else { 2 + 2 * mv_class(d.unsigned_abs()) }
}

/// The mv_class of a nonzero whole-sample difference magnitude `a` (1/8 sample, a multiple of 8,
/// <= 2^14): class 0 holds 1..2 samples, class c >= 1 holds 2^c + 1 .. 2^(c + 1).
#[inline]
pub(crate) fn mv_class(a: u32) -> u32 {
    let v = (a >> 3) - 1;
    if v < 2 { 0 } else { 31 - v.leading_zeros() }
}

/// The largest NEWMV difference component the syntax codes (class 10: 2^11 samples).
pub(crate) const MV_DIFF_MAX: i32 = 1 << 14;

/// A block's inter mode as the writer derives it from its MV: (YMode, RefMvIdx).
/// - mv == 0: GLOBALMV;
/// - mv == stack[0]: NEARESTMV;
/// - mv == stack[1], or stack[2] / stack[3] where NumMvFound > 2 / 3: NEARMV, drl index 1..3;
/// - otherwise NEWMV against stack[i], i in 0..=min(2, NumMvFound - 1) (0 when NumMvFound <= 1),
///   the index whose difference costs the fewest bits ([`mv_comp_cost`] + i), ties to the
///   lowest; None if no candidate's difference fits.
pub(crate) fn derive_mode(s: &MvStack, mv: [i32; 2]) -> Option<(i32, usize)> {
    if mv == [0, 0] {
        return Some((GLOBALMV, 0));
    }
    if mv == s.mv[0] {
        return Some((NEARESTMV, 0));
    }
    for idx in 1..4 {
        if (idx == 1 || s.num > idx) && mv == s.mv[idx] {
            return Some((NEARMV, idx));
        }
    }
    let n = if s.num <= 1 { 1 } else { s.num.min(3) };
    let mut best: Option<(u32, usize)> = None;
    for idx in 0..n {
        let d = [mv[0] - s.mv[idx][0], mv[1] - s.mv[idx][1]];
        if d[0].abs() > MV_DIFF_MAX || d[1].abs() > MV_DIFF_MAX {
            continue;
        }
        let cost = mv_comp_cost(d[0]) + mv_comp_cost(d[1]) + idx as u32;
        if best.is_none_or(|(c, _)| cost < c) {
            best = Some((cost, idx));
        }
    }
    best.map(|(_, idx)| (NEWMV, idx))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A mode-info grid filled block by block, for building stacks by hand.
    struct Grid {
        ref0: Vec<u8>,
        mvs: Vec<[i16; 2]>,
        y_mode: Vec<u8>,
        mi_size: Vec<u8>,
        mw: i32,
        mh: i32,
    }

    impl Grid {
        fn new(mw: i32, mh: i32) -> Grid {
            let n = (mw * mh) as usize;
            Grid {
                ref0: vec![REF_UNSET; n],
                mvs: vec![[0; 2]; n],
                y_mode: vec![0; n],
                mi_size: vec![0; n],
                mw,
                mh,
            }
        }
        fn put(&mut self, r: i32, c: i32, bs: i32, inter: Option<([i16; 2], i32)>) {
            for y in r..(r + Num_4x4_Blocks_High[bs as usize] as i32).min(self.mh) {
                for x in c..(c + Num_4x4_Blocks_Wide[bs as usize] as i32).min(self.mw) {
                    let k = (y * self.mw + x) as usize;
                    self.mi_size[k] = bs as u8;
                    match inter {
                        Some((mv, mode)) => {
                            self.ref0[k] = 1;
                            self.mvs[k] = mv;
                            self.y_mode[k] = mode as u8;
                        }
                        None => {
                            self.ref0[k] = 0;
                            self.y_mode[k] = 0;
                        }
                    }
                }
            }
        }
        fn maps(&self) -> MvMaps<'_> {
            MvMaps {
                ref0: &self.ref0,
                mvs: &self.mvs,
                y_mode: &self.y_mode,
                mi_size: &self.mi_size,
                r0: 0,
                c0: 0,
                mw: self.mw,
                row_start: 0,
                row_end: self.mh,
                col_start: 0,
                col_end: self.mw,
                mi_rows: self.mh,
                mi_cols: self.mw,
            }
        }
    }

    /// Hand-built neighbourhoods give the stacks, weights and contexts the spec's steps give.
    #[test]
    fn stack_by_hand() {
        // nothing coded: no candidates, globals, contexts 0
        let g = Grid::new(32, 32);
        let s = find_mv_stack(&g.maps(), 8, 8, BLOCK_16X16);
        assert_eq!(
            (s.num, s.mv[0], s.mv[1], s.new_mv_ctx, s.ref_mv_ctx),
            (0, [0, 0], [0, 0], 0, 0)
        );

        // the 16x16 at (8, 8): above it a 16x16 NEWMV block (rows 4..7, columns 8..11); left
        // of it (columns 4..7) two intra 8x8s on rows 8..9 and two NEARESTMV 8x8s on rows 10..11
        let mut g = Grid::new(32, 32);
        g.put(4, 8, BLOCK_16X16, Some(([8, -16], NEWMV)));
        g.put(8, 4, BLOCK_8X8, None);
        g.put(8, 6, BLOCK_8X8, None);
        g.put(10, 4, BLOCK_8X8, Some(([24, 8], NEARESTMV)));
        g.put(10, 6, BLOCK_8X8, Some(([24, 8], NEARESTMV)));
        let s = find_mv_stack(&g.maps(), 8, 8, BLOCK_16X16);
        // row -1: the 16x16 above, len min(4, 4) = 4, weight 8 (+ REF_CAT_LEVEL); col -1: rows 8..9
        // intra (len 2), rows 10..11 the 8x8 with [24, 8] (len 2, weight 4 + REF_CAT_LEVEL); the
        // top-right (row 7, column 12) isn't coded: no candidate.
        assert_eq!(s.num, 2);
        assert_eq!(s.mv[0], [8, -16]);
        assert_eq!(s.mv[1], [24, 8]);
        // row -3 (row 5, columns 9..): the same 16x16 again, len 4: weight 8; col -3 (column 5,
        // rows 9..): row 9 the intra 8x8 (len 2), row 11 the [24, 8] 8x8: weight 4. (-1, -1) isn't
        // coded.
        assert_eq!(s.weight[0], REF_CAT_LEVEL as u32 + 8 + 8);
        assert_eq!(s.weight[1], REF_CAT_LEVEL as u32 + 4 + 4);
        // close matches 2, a NEWMV among the nearest: NewMvContext 4, RefMvContext 5
        assert_eq!((s.new_mv_ctx, s.ref_mv_ctx), (4, 5));
        assert_eq!(s.drl_ctx[0], 0);

        // the modes the writer derives
        assert_eq!(derive_mode(&s, [0, 0]), Some((GLOBALMV, 0)));
        assert_eq!(derive_mode(&s, [8, -16]), Some((NEARESTMV, 0)));
        assert_eq!(derive_mode(&s, [24, 8]), Some((NEARMV, 1)));
        // [32, -16]: from stack[0] a row difference of 3 samples (class 1: cost 4), from stack[1]
        // 1 sample and 3 samples (class 0 + class 1: 2 + 4 + 1)
        assert_eq!(derive_mode(&s, [32, -16]), Some((NEWMV, 0)));
        assert_eq!(derive_mode(&s, [32, 8]), Some((NEWMV, 1)));
    }

    #[test]
    fn mv_classes() {
        let mag = |c: u32, d: u32| {
            if c == 0 {
                8 * (d + 1)
            } else {
                (1 << (c + 3)) + 8 * d + 8
            }
        };
        assert_eq!(mv_class(8), 0);
        assert_eq!(mv_class(16), 0);
        for c in 1..=10 {
            for d in [0, (1 << c) - 1] {
                assert_eq!(mv_class(mag(c, d)), c, "class {c} offset {d}");
            }
        }
        assert_eq!(mag(10, 1023), MV_DIFF_MAX as u32);
    }
}
