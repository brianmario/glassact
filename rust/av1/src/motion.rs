//! Motion for screen content, from the source alone: candidate shifts (scrolling, dragging) and
//! exact copies.
//!
//! Screen content moves rigidly. A scrolled or dragged region is the previous picture's pixels at a
//! whole-pixel offset, and most of a screen doesn't change at all. A superblock that equals the
//! previous source at some offset can be coded as an inter block with that motion vector and no
//! residual: its picture is then the previous reconstruction moved, as good as it was. That covers
//! unchanged content, scrolling and window drags at a few bits a superblock.
//!
//! - [`ShiftFinder`] proposes candidate offsets from per-band row and column hashes.
//! - [`sb_matches`] checks that a superblock is an exact copy at an offset.
//! - [`inter_sb_cover`] covers a superblock with the largest legal blocks.
use crate::types::{Block, BlockInter};

/// A whole-pixel offset into the previous picture: the superblock at (x, y) copies (x + dx, y + dy).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Shift {
    pub dx: i32,
    pub dy: i32,
}

/// A plane: samples `stride` apart per row, `width` x `height` of them in use.
#[derive(Clone, Copy, Debug)]
pub struct Plane<'a> {
    pub data: &'a [u8],
    pub stride: usize,
    pub width: usize,
    pub height: usize,
}

/// Whether the 64x64 superblock (luma 64 x 64 at sb_x * 64, sb_y * 64; chroma 32 x 32 for 4:2:0,
/// `planes` 1 or 3) of `cur` equals `prev` at `shift`, over the part inside the picture. The
/// displaced area must lie inside `prev` (no edge extension). Chroma shifts are half the luma ones,
/// so an odd luma shift can't be an exact chroma copy and doesn't match.
pub fn sb_matches(cur: &[Plane; 3], prev: &[Plane; 3], planes: usize, sb_x: usize, sb_y: usize, shift: Shift) -> bool {
    if planes == 3 && (shift.dx & 1 != 0 || shift.dy & 1 != 0) {
        return false;
    }
    for p in 0..planes {
        let (side, sub) = if p == 0 { (64, 0) } else { (32, 1) };
        let (c, q) = (&cur[p], &prev[p]);
        let x0 = sb_x * side;
        let y0 = sb_y * side;
        if x0 >= c.width || y0 >= c.height {
            continue;
        }
        let w = side.min(c.width - x0);
        let h = side.min(c.height - y0);
        let (dx, dy) = (shift.dx >> sub, shift.dy >> sub);
        let (px, py) = (x0 as i64 + dx as i64, y0 as i64 + dy as i64);
        if px < 0 || py < 0 || px as usize + w > q.width || py as usize + h > q.height {
            return false;
        }
        let (px, py) = (px as usize, py as usize);
        for row in 0..h {
            let a = &c.data[(y0 + row) * c.stride + x0..][..w];
            let b = &q.data[(py + row) * q.stride + px..][..w];
            if a != b {
                return false;
            }
        }
    }
    true
}

/// The blocks that cover superblock (sb_row, sb_col) with the largest legal partition (decisions.h's
/// rules): NONE where it fits, HORZ / VERT where only the top / left half is inside the coded area,
/// SPLIT where neither is. Every block is 8x8 or larger (MiCols and MiRows are even). Fields other
/// than the position and size are left at `template`'s values.
pub fn inter_sb_cover(mi_rows: i32, mi_cols: i32, sb_row: i32, sb_col: i32, template: &Block, out: &mut Vec<Block>) {
    fn bsize(w4: i32, h4: i32) -> u8 {
        use crate::tables::*;
        (match (w4, h4) {
            (16, 16) => BLOCK_64X64,
            (16, 8) => BLOCK_64X32,
            (8, 16) => BLOCK_32X64,
            (8, 8) => BLOCK_32X32,
            (8, 4) => BLOCK_32X16,
            (4, 8) => BLOCK_16X32,
            (4, 4) => BLOCK_16X16,
            (4, 2) => BLOCK_16X8,
            (2, 4) => BLOCK_8X16,
            (2, 2) => BLOCK_8X8,
            _ => unreachable!("no {w4}x{h4} (4x4 units) block in the cover"),
        }) as u8
    }
    fn node(mi_rows: i32, mi_cols: i32, r: i32, c: i32, n: i32, t: &Block, out: &mut Vec<Block>) {
        if r >= mi_rows || c >= mi_cols {
            return;
        }
        let half = n / 2;
        let below = r + half >= mi_rows;
        let right = c + half >= mi_cols;
        let mut emit = |w4: i32, h4: i32| {
            out.push(Block {
                mi_row: r as u16,
                mi_col: c as u16,
                bsize: bsize(w4, h4),
                ..*t
            });
        };
        match (below, right) {
            (false, false) => emit(n, n),
            (true, false) => emit(n, half),
            (false, true) => emit(half, n),
            (true, true) => {
                for (dr, dc) in [(0, 0), (0, half), (half, 0), (half, half)] {
                    node(mi_rows, mi_cols, r + dr, c + dc, half, t, out);
                }
            }
        }
    }
    node(mi_rows, mi_cols, sb_row * 16, sb_col * 16, 16, template, out);
}

/// Candidate shifts from the previous picture to this one, from 64-sample bands: per band of
/// columns, row hashes (vertical motion), and per band of rows, column hashes (horizontal motion).
/// Each band votes for the offsets at which its rows (columns) reappear; offsets that enough rows
/// agree on, in some band, are proposed. Only bands with a changed superblock are hashed, in both
/// pictures, on up to `threads` threads.
pub struct ShiftFinder {
    threads: usize,
}

impl Default for ShiftFinder {
    fn default() -> Self {
        Self::new()
    }
}

/// One thread's buffers for [`ShiftFinder`].
#[derive(Default)]
struct BandScratch {
    now: Vec<u64>,
    before: Vec<u64>,
    index: Vec<(u64, u32)>,
    votes: Vec<(i32, u32)>,
    col_hash: Vec<u32>,
}

impl ShiftFinder {
    pub fn new() -> ShiftFinder {
        ShiftFinder {
            threads: std::thread::available_parallelism().map_or(1, |n| n.get()).min(8),
        }
    }

    /// Up to `max` candidate shifts from `prev` to `cur` (luma planes of one size), best supported
    /// first, excluding no motion. Bands where `changed` (per 64x64, raster, `sb_cols` wide) is all
    /// zero are skipped.
    pub fn candidates(&mut self, cur: &Plane, prev: &Plane, changed: &[u8], sb_cols: usize, max: usize) -> Vec<Shift> {
        let (w, h) = (cur.width, cur.height);
        if prev.width != w || prev.height != h {
            return Vec::new();
        }
        let sb_rows = changed.len() / sb_cols.max(1);
        let at = |r: usize, c: usize| changed.get(r * sb_cols + c).copied().unwrap_or(0) != 0;
        // (vertical, band): bands of columns vote for vertical shifts, bands of rows horizontal ones
        let mut bands: Vec<(bool, usize)> = (0..w.div_ceil(64))
            .filter(|&b| (0..sb_rows).any(|r| at(r, b)))
            .map(|b| (true, b))
            .collect();
        bands.extend(
            (0..h.div_ceil(64))
                .filter(|&b| (0..sb_cols).any(|c| at(b, c)))
                .map(|b| (false, b)),
        );
        let per = bands.len().div_ceil(self.threads.max(1)).max(1);
        let mut found: Vec<(Shift, u32)> = std::thread::scope(|sc| {
            let jobs: Vec<_> = bands
                .chunks(per)
                .map(|part| {
                    sc.spawn(move || {
                        let mut t = BandScratch::default();
                        let mut out = Vec::new();
                        for &(vertical, b) in part {
                            if vertical {
                                let (x0, x1) = (b * 64, w.min(b * 64 + 64));
                                t.now.clear();
                                t.now.extend((0..h).map(|r| hash(&cur.data[r * cur.stride..][x0..x1])));
                                t.before.clear();
                                t.before
                                    .extend((0..h).map(|r| hash(&prev.data[r * prev.stride..][x0..x1])));
                                out.extend(t.vote().into_iter().map(|(s, n)| (Shift { dx: 0, dy: s }, n)));
                            } else {
                                let (y0, y1) = (b * 64, h.min(b * 64 + 64));
                                t.col_hashes(cur, y0, y1);
                                t.now.clear();
                                t.now.extend(t.col_hash.iter().map(|&k| k as u64));
                                t.col_hashes(prev, y0, y1);
                                t.before.clear();
                                t.before.extend(t.col_hash.iter().map(|&k| k as u64));
                                out.extend(t.vote().into_iter().map(|(s, n)| (Shift { dx: s, dy: 0 }, n)));
                            }
                        }
                        out
                    })
                })
                .collect();
            jobs.into_iter().flat_map(|j| j.join().unwrap()).collect()
        });
        // merge: total support per shift, best first
        found.sort_by_key(|&(s, _)| (s.dx, s.dy));
        let mut merged: Vec<(Shift, u32)> = Vec::new();
        for (s, n) in found {
            match merged.last_mut() {
                Some((t, m)) if *t == s => *m += n,
                _ => merged.push((s, n)),
            }
        }
        merged.sort_by(|a, b| b.1.cmp(&a.1).then((a.0.dx, a.0.dy).cmp(&(b.0.dx, b.0.dy))));
        merged.into_iter().take(max).map(|(s, _)| s).collect()
    }
}

impl BandScratch {
    /// FNV-1a (32-bit) down each column of rows y0..y1, all columns at once (it vectorizes).
    fn col_hashes(&mut self, y: &Plane, y0: usize, y1: usize) {
        let w = y.width;
        self.col_hash.clear();
        self.col_hash.resize(w, 0x811c_9dc5);
        for row in y0..y1 {
            let line = &y.data[row * y.stride..][..w];
            for (k, &v) in self.col_hash.iter_mut().zip(line) {
                *k = (*k ^ v as u32).wrapping_mul(0x0100_0193);
            }
        }
    }

    /// Offsets d (now[i] == before[i + d], d != 0) supported by at least 8 lines, each with its
    /// count. Lines that repeat (blank rows) don't vote.
    fn vote(&mut self) -> Vec<(i32, u32)> {
        let (now, before) = (&self.now, &self.before);
        self.index.clear();
        self.index
            .extend(before.iter().enumerate().map(|(i, &k)| (k, i as u32)));
        self.index.sort_unstable();
        self.votes.clear();
        for (i, &k) in now.iter().enumerate() {
            if before[i] == k {
                continue; // unchanged line
            }
            let lo = self.index.partition_point(|&(x, _)| x < k);
            let hi = self.index.partition_point(|&(x, _)| x <= k);
            if hi - lo != 1 {
                continue; // absent, or not distinctive
            }
            let d = self.index[lo].1 as i32 - i as i32;
            match self.votes.iter_mut().find(|(s, _)| *s == d) {
                Some((_, c)) => *c += 1,
                None => self.votes.push((d, 1)),
            }
        }
        self.votes.iter().copied().filter(|&(d, c)| d != 0 && c >= 8).collect()
    }
}

/// The largest shift (each way, in luma samples) a copy uses: every motion vector, and its
/// difference from any candidate the writer codes it against, stays in AV1's range.
pub const MAX_SHIFT: i32 = 1000;

/// A superblock's decision: copied from the previous picture at `shift` (no motion: unchanged), or
/// coded.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SbMotion {
    pub copy: bool,
    pub shift: Shift,
}

/// Exact copies for a picture (av1enc_motion): which superblocks equal the previous source,
/// unchanged or at a shift ([`Motion::classify`]), and the picture's blocks with those superblocks
/// made inter blocks ([`Motion::apply`]).
pub struct Motion {
    finder: ShiftFinder,
    /// per 64x64, raster: the last [`Motion::classify`]'s
    pub sbs: Vec<SbMotion>,
    pub sb_cols: usize,
    pub sb_rows: usize,
    pub blocks: Vec<Block>,
    pub inter: Vec<BlockInter>,
    pub luma_tx: Vec<u8>,
    /// the last [`Motion::classify`]'s shift candidates (usable ones, best first)
    pub candidates: Vec<Shift>,
    threads: usize,
}

impl Default for Motion {
    fn default() -> Self {
        Self::new()
    }
}

impl Motion {
    pub fn new() -> Motion {
        Motion {
            finder: ShiftFinder::new(),
            sbs: Vec::new(),
            sb_cols: 0,
            sb_rows: 0,
            blocks: Vec::new(),
            inter: Vec::new(),
            luma_tx: Vec::new(),
            candidates: Vec::new(),
            threads: std::thread::available_parallelism().map_or(1, |n| n.get()).min(8),
        }
    }

    /// Per 64x64 of `cur`: whether it equals `prev` ([`sb_matches`]) unchanged, or else at a
    /// candidate shift: its left or upper neighbour's, or one of up to `max_candidates` from
    /// [`ShiftFinder`]. Returns how many are copies.
    pub fn classify(&mut self, cur: &[Plane; 3], prev: &[Plane; 3], planes: usize, max_candidates: usize) -> usize {
        let (sb_cols, sb_rows) = (cur[0].width.div_ceil(64), cur[0].height.div_ceil(64));
        (self.sb_cols, self.sb_rows) = (sb_cols, sb_rows);
        self.sbs.clear();
        self.sbs.resize(sb_cols * sb_rows, SbMotion::default());
        self.candidates.clear();
        let same = cur[0].width == prev[0].width && cur[0].height == prev[0].height;
        if !same {
            return 0;
        }
        // unchanged, rows of superblocks on several threads
        let rows_per = sb_rows.div_ceil(self.threads.max(1)).max(1);
        std::thread::scope(|sc| {
            for (k, part) in self.sbs.chunks_mut(rows_per * sb_cols).enumerate() {
                sc.spawn(move || {
                    for (i, m) in part.iter_mut().enumerate() {
                        let s = k * rows_per * sb_cols + i;
                        m.copy = sb_matches(cur, prev, planes, s % sb_cols, s / sb_cols, Shift::default());
                    }
                });
            }
        });
        let changed: Vec<u8> = self.sbs.iter().map(|m| !m.copy as u8).collect();
        if changed.iter().all(|&c| c == 0) {
            return self.sbs.len();
        }
        let usable = |s: &Shift| {
            s.dx.abs() <= MAX_SHIFT && s.dy.abs() <= MAX_SHIFT && (planes == 1 || (s.dx & 1 == 0 && s.dy & 1 == 0))
        };
        let cands: Vec<Shift> = self
            .finder
            .candidates(&cur[0], &prev[0], &changed, sb_cols, max_candidates)
            .into_iter()
            .filter(usable)
            .collect();
        self.candidates.clone_from(&cands);
        for s in 0..self.sbs.len() {
            if self.sbs[s].copy {
                continue;
            }
            let (x, y) = (s % sb_cols, s / sb_cols);
            let moved = |m: SbMotion| (m.copy && m.shift != Shift::default()).then_some(m.shift);
            let left = if x > 0 { moved(self.sbs[s - 1]) } else { None };
            let up = if y > 0 { moved(self.sbs[s - sb_cols]) } else { None };
            let found = up
                .into_iter()
                .chain(left)
                .chain(cands.iter().copied())
                .find(|&d| sb_matches(cur, prev, planes, x, y, d));
            if let Some(d) = found {
                self.sbs[s] = SbMotion { copy: true, shift: d };
            }
        }
        self.sbs.iter().filter(|m| m.copy).count()
    }

    /// `blocks` (a partition in coding order; with `luma_tx`, their luma tx types, and with
    /// `inter`, their motion) with every superblock `sbs` copies (per 64x64, raster, `sb_cols`
    /// wide) replaced by its [`inter_sb_cover`]: skip inter blocks at its shift, intra fields 0,
    /// luma tx type 0. Into [`Motion::blocks`], [`Motion::inter`] (one per block) and
    /// [`Motion::luma_tx`].
    #[allow(clippy::too_many_arguments)]
    pub fn apply(
        &mut self,
        sbs: &[SbMotion],
        sb_cols: usize,
        blocks: &[Block],
        luma_tx: Option<&[u8]>,
        inter: Option<&[BlockInter]>,
        mi_rows: i32,
        mi_cols: i32,
    ) {
        self.blocks.clear();
        self.inter.clear();
        self.luma_tx.clear();
        let template = Block {
            skip: 1,
            ..Default::default()
        };
        let mut last = usize::MAX;
        for (i, b) in blocks.iter().enumerate() {
            let (sr, sc) = (b.mi_row as usize >> 4, b.mi_col as usize >> 4);
            let s = sr * sb_cols + sc;
            match sbs.get(s) {
                Some(m) if m.copy => {
                    if s != last {
                        let n0 = self.blocks.len();
                        inter_sb_cover(mi_rows, mi_cols, sr as i32, sc as i32, &template, &mut self.blocks);
                        let mv = BlockInter {
                            mv_row: (m.shift.dy * 8) as i16,
                            mv_col: (m.shift.dx * 8) as i16,
                            is_inter: 1,
                            ..Default::default()
                        };
                        self.inter.resize(self.blocks.len(), mv);
                        self.luma_tx.resize(self.blocks.len(), 0);
                        debug_assert!(self.blocks.len() > n0);
                    }
                }
                _ => {
                    self.blocks.push(*b);
                    self.inter.push(inter.map_or(BlockInter::default(), |v| v[i]));
                    self.luma_tx.push(luma_tx.map_or(0, |l| l[i]));
                }
            }
            last = s;
        }
    }
}

#[inline]
fn hash(b: &[u8]) -> u64 {
    let mut k = 0x9e37_79b9_7f4a_7c15u64 ^ b.len() as u64;
    let (chunks, rest) = b.as_chunks::<8>();
    for c in chunks {
        let v = u64::from_le_bytes(*c);
        k = (k ^ v).wrapping_mul(0xff51_afd7_ed55_8ccd).rotate_left(29);
    }
    for &v in rest {
        k = (k ^ v as u64).wrapping_mul(0xc4ce_b9fe_1a85_ec53);
    }
    k ^ (k >> 32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tables::*;

    fn rng(s: &mut u64) -> u64 {
        *s ^= *s << 13;
        *s ^= *s >> 7;
        *s ^= *s << 17;
        *s
    }

    #[test]
    fn cover_is_a_legal_partition() {
        // the writer's own validation of a record made of the cover's blocks (as intra blocks)
        for (w, h) in [
            (64, 64),
            (100, 70),
            (333, 201),
            (1280, 720),
            (8, 8),
            (72, 136),
            (1920, 1080),
        ] {
            let mut fp = crate::types::FrameParams {
                version: 1,
                width: w,
                height: h,
                base_q_idx: 100,
                ..Default::default()
            };
            fp.tile_cols_log2 = -1;
            fp.tile_rows_log2 = -1;
            let (mi_cols, mi_rows) = (crate::blockinfo::mi_cols(w as i32), crate::blockinfo::mi_rows(h as i32));
            let mut blocks = Vec::new();
            let t = Block {
                skip: 1,
                ..Default::default()
            };
            for sr in 0..(mi_rows + 15) / 16 {
                for sc in 0..(mi_cols + 15) / 16 {
                    inter_sb_cover(mi_rows, mi_cols, sr, sc, &t, &mut blocks);
                }
            }
            assert!(
                blocks
                    .iter()
                    .all(|b| b.bsize as i32 != BLOCK_4X4 && b.bsize as i32 != BLOCK_4X8 && b.bsize as i32 != BLOCK_8X4)
            );
            let mut rec = crate::writer::Record::new(fp, blocks);
            rec.layout().unwrap();
            crate::writer::validate(rec.as_mut()).unwrap_or_else(|e| panic!("{w}x{h}: {e}"));
        }
    }

    fn plane(d: &[u8], w: usize, h: usize) -> Plane<'_> {
        Plane {
            data: d,
            stride: w,
            width: w,
            height: h,
        }
    }

    #[test]
    fn finds_a_scroll_and_matches_it() {
        let (w, h) = (640usize, 384usize);
        let mut s = 7u64;
        let page: Vec<u8> = (0..w * (h + 200)).map(|_| (rng(&mut s) & 0xff) as u8).collect();
        let frame = |top: usize| -> Vec<u8> { page[top * w..(top + h) * w].to_vec() };
        let (a, b) = (frame(0), frame(37 * 2)); // scrolled down by 74 rows
        let changed = vec![1u8; w.div_ceil(64) * h.div_ceil(64)];
        let mut f = ShiftFinder::new();
        let c = f.candidates(&plane(&b, w, h), &plane(&a, w, h), &changed, w.div_ceil(64), 4);
        assert_eq!(c.first(), Some(&Shift { dx: 0, dy: 74 }), "{c:?}");
        let (pa, pb) = (plane(&a, w, h), plane(&b, w, h));
        let y = [pb, pb, pb];
        let prev = [pa, pa, pa];
        assert!(sb_matches(&y, &prev, 1, 2, 1, Shift { dx: 0, dy: 74 }));
        assert!(!sb_matches(&y, &prev, 1, 2, 1, Shift { dx: 0, dy: 72 }));
        // the bottom superblocks read past the previous picture: no match
        assert!(!sb_matches(&y, &prev, 1, 2, 5, Shift { dx: 0, dy: 74 }));
    }
}
