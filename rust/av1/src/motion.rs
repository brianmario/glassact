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
use crate::types::Block;

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
/// agree on, in some band, are proposed. Keeps the previous picture's hashes between calls.
#[derive(Default)]
pub struct ShiftFinder {
    rows: Vec<u64>,
    cols: Vec<u64>,
    prev_rows: Vec<u64>,
    prev_cols: Vec<u64>,
    width: usize,
    height: usize,
    index: Vec<(u64, u32)>,
    votes: Vec<(i32, u32)>,
}

impl ShiftFinder {
    pub fn new() -> ShiftFinder {
        ShiftFinder::default()
    }

    /// Hashes `y` (the luma plane) and returns up to `max` candidate shifts, best supported first,
    /// excluding no motion. Bands where `changed` (per 64x64, raster, `sb_cols` wide) is all zero
    /// are skipped. The first call, or one with a new size, returns none.
    pub fn candidates(&mut self, y: &Plane, changed: &[u8], sb_cols: usize, max: usize) -> Vec<Shift> {
        let (w, h) = (y.width, y.height);
        let bands_x = w.div_ceil(64);
        let bands_y = h.div_ceil(64);
        std::mem::swap(&mut self.rows, &mut self.prev_rows);
        std::mem::swap(&mut self.cols, &mut self.prev_cols);
        self.rows.resize(bands_x * h, 0);
        self.cols.resize(bands_y * w, 0);
        // row hashes per band of columns, column hashes per band of rows
        for row in 0..h {
            let line = &y.data[row * y.stride..][..w];
            for b in 0..bands_x {
                self.rows[b * h + row] = hash(&line[b * 64..w.min(b * 64 + 64)]);
            }
        }
        for b in 0..bands_y {
            let r1 = h.min(b * 64 + 64);
            for col in 0..w {
                let mut k = 0xcbf2_9ce4_8422_2325u64;
                for row in b * 64..r1 {
                    k = (k ^ y.data[row * y.stride + col] as u64).wrapping_mul(0x100_0000_01b3);
                }
                self.cols[b * w + col] = k;
            }
        }
        let fresh = self.width != w || self.height != h;
        self.width = w;
        self.height = h;
        if fresh {
            return Vec::new();
        }
        let sb_rows = changed.len() / sb_cols.max(1);
        let mut found: Vec<(Shift, u32)> = Vec::new();
        // vertical: band of columns b, its rows now against before
        for b in 0..bands_x {
            if !(0..sb_rows).any(|r| changed.get(r * sb_cols + b).copied().unwrap_or(0) != 0) {
                continue;
            }
            for (s, n) in self.vote(b * h, h, true) {
                found.push((Shift { dx: 0, dy: s }, n));
            }
        }
        for b in 0..bands_y {
            if !(0..sb_cols).any(|c| changed.get(b * sb_cols + c).copied().unwrap_or(0) != 0) {
                continue;
            }
            for (s, n) in self.vote(b * w, w, false) {
                found.push((Shift { dx: s, dy: 0 }, n));
            }
        }
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

    /// For one band (`n` hashes at `base`): offsets d (now[i] == before[i + d], d != 0) supported by
    /// at least 8 lines, each with its count. Lines that repeat (blank rows) don't vote.
    fn vote(&mut self, base: usize, n: usize, rows: bool) -> Vec<(i32, u32)> {
        let (now, before) = if rows {
            (&self.rows[base..base + n], &self.prev_rows[base..base + n])
        } else {
            (&self.cols[base..base + n], &self.prev_cols[base..base + n])
        };
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

#[inline]
fn hash(b: &[u8]) -> u64 {
    let mut k = 0x9e37_79b9_7f4a_7c15u64 ^ b.len() as u64;
    let mut chunks = b.chunks_exact(8);
    for c in &mut chunks {
        let v = u64::from_le_bytes(c.try_into().unwrap());
        k = (k ^ v).wrapping_mul(0xff51_afd7_ed55_8ccd).rotate_left(29);
    }
    for &v in chunks.remainder() {
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
        assert!(f.candidates(&plane(&a, w, h), &changed, w.div_ceil(64), 4).is_empty());
        let c = f.candidates(&plane(&b, w, h), &changed, w.div_ceil(64), 4);
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
