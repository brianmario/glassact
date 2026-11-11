//! Palette blocks (spec palette_mode_info, get_palette_cache, palette_tokens,
//! get_palette_color_context and the palette prediction process): with allow_screen_content_tools,
//! an intra block of 8x8 to 64x64 whose luma (y_mode DC_PRED) or chroma (uv_mode DC_PRED) is a few
//! colours and a colour index map, coded in anti-diagonal order with contexts from the map itself.
use super::*;

/// The current block's colour index maps, as the decoder has them: luma `w x h` (row-major), chroma
/// half each way. Only the on-screen part is coded; the prediction repeats its last column and
/// row past it.
pub(crate) struct PaletteMaps {
    pub map: [[u8; 64 * 64]; 2],
}

impl Default for PaletteMaps {
    fn default() -> Self {
        PaletteMaps { map: [[0; 64 * 64]; 2] }
    }
}

/// A plane type's palette geometry for a block: map stride (the block's width) and height, and the
/// on-screen width and height.
#[derive(Clone, Copy, Debug)]
pub(crate) struct MapDims {
    pub w: usize,
    pub h: usize,
    pub ow: usize,
    pub oh: usize,
}

/// The block's map geometry for plane type `uv` (spec palette_tokens; 4:2:0 or monochrome): a
/// chroma map narrower or shorter than 4 (of a 4x16 or 16x4 block) is 2 more, the chroma of its
/// 8x8, which starts at [`map_origin`].
pub(crate) fn map_dims(bsize: i32, mi_row: i32, mi_col: i32, mi_rows: i32, mi_cols: i32, uv: bool) -> MapDims {
    let (w, h) = ((4 * bw4(bsize)) as usize, (4 * bh4(bsize)) as usize);
    let ow = w.min(((mi_cols - mi_col) * 4) as usize);
    let oh = h.min(((mi_rows - mi_row) * 4) as usize);
    if !uv {
        return MapDims { w, h, ow, oh };
    }
    let (mut d, wide, tall) = (
        MapDims {
            w: w >> 1,
            h: h >> 1,
            ow: ow >> 1,
            oh: oh >> 1,
        },
        w >> 1 >= 4,
        h >> 1 >= 4,
    );
    if !wide {
        (d.w, d.ow) = (d.w + 2, d.ow + 2);
    }
    if !tall {
        (d.h, d.oh) = (d.h + 2, d.oh + 2);
    }
    d
}

/// Where a block's map of plane `sub` (0 luma, 1 chroma) starts, in that plane's samples.
pub(crate) fn map_origin(mi_row: i32, mi_col: i32, sub: i32) -> (i32, i32) {
    ((mi_col >> sub) * 4, (mi_row >> sub) * 4)
}

/// The palette prediction of a tx block at (x0, y0) inside its block (plane samples), `tw x th`,
/// into `cur` at offset `off` (rows `stride` apart).
#[allow(clippy::too_many_arguments)]
pub(crate) fn predict_palette(
    cur: &mut [u8],
    off: usize,
    stride: usize,
    (tw, th): (usize, usize),
    (x0, y0): (usize, usize),
    colors: &[u8; 8],
    map: &[u8],
    d: MapDims,
) {
    for i in 0..th {
        let mrow = &map[(y0 + i).min(d.oh - 1) * d.w..];
        let row = &mut cur[off + i * stride..][..tw];
        for (j, v) in row.iter_mut().enumerate() {
            *v = colors[mrow[(x0 + j).min(d.ow - 1)] as usize];
        }
    }
}

/// get_palette_color_context: the colours ranked by the scores of the left, above-left and above
/// neighbours (2, 1, 2), and the context of that ranking.
pub(crate) fn color_context(map: &[u8], stride: usize, r: usize, c: usize, n: usize) -> ([u8; 8], usize) {
    let mut scores = [0u8; 8];
    let mut order = [0u8, 1, 2, 3, 4, 5, 6, 7];
    if c > 0 {
        scores[map[r * stride + c - 1] as usize] += 2;
    }
    if r > 0 && c > 0 {
        scores[map[(r - 1) * stride + c - 1] as usize] += 1;
    }
    if r > 0 {
        scores[map[(r - 1) * stride + c] as usize] += 2;
    }
    for i in 0..PALETTE_NUM_NEIGHBORS as usize {
        let (mut max_score, mut max_idx) = (scores[i], i);
        for (j, &s) in scores.iter().enumerate().take(n).skip(i + 1) {
            if s > max_score {
                (max_score, max_idx) = (s, j);
            }
        }
        if max_idx != i {
            let o = order[max_idx];
            for k in (i + 1..=max_idx).rev() {
                scores[k] = scores[k - 1];
                order[k] = order[k - 1];
            }
            scores[i] = max_score;
            order[i] = o;
        }
    }
    let hash: usize = (0..PALETTE_NUM_NEIGHBORS as usize)
        .map(|i| scores[i] as usize * Palette_Color_Hash_Multipliers[i] as usize)
        .sum();
    (order, Palette_Color_Context[hash] as usize)
}

/// The bits a delta of `v` needs (0 for 0).
fn bits_for(v: u32) -> i32 {
    32 - v.leading_zeros() as i32
}

/// CeilLog2 (spec 4.7): 0 for x < 2.
fn ceil_log2(x: i32) -> i32 {
    if x < 2 {
        0
    } else {
        32 - ((x - 1) as u32).leading_zeros() as i32
    }
}

impl<S: Sink, H: TxbHook> Walk<'_, S, H> {
    /// NS(n): a value below n with the fewest bits.
    fn ns(&mut self, v_w: i32, n: i32) -> i32 {
        let w = 32 - (n as u32).leading_zeros() as i32;
        let m = (1 << w) - n;
        let t = if S::WRITE && v_w >= m { (v_w + m) >> 1 } else { v_w };
        let v = self.lit(t, w - 1);
        if v < m {
            return v;
        }
        let extra = self.lit((v_w + m) & 1, 1);
        (v << 1) - m + extra
    }

    /// get_palette_cache: the above (inside the same 64-row) and left blocks' colours of plane
    /// type `uv`, merged in order without repeats.
    fn palette_cache(&self, uv: usize) -> ([u8; 16], usize) {
        let (st, bufs) = (&*self.st, &*self.bufs);
        let (r, c) = (st.mi_row, st.mi_col);
        let colors = |k: u32| {
            if k == NO_PALETTE {
                return &[][..];
            }
            let p = &bufs.pals[k as usize];
            let n = if uv == 0 { p.size_y } else { p.size_uv } as usize;
            &p.colors[uv][..n]
        };
        let at = |y: i32, x: i32| bufs.pal_at.get(bufs.mi(y, x)).copied().unwrap_or(NO_PALETTE);
        let above = if (r * 4) % 64 != 0 { colors(at(r - 1, c)) } else { &[] };
        let left = if st.avail_l { colors(at(r, c - 1)) } else { &[] };
        let mut cache = [0u8; 16];
        let mut n = 0;
        let (mut a, mut l) = (0, 0);
        let mut put = |v: u8, n: &mut usize| {
            if *n == 0 || cache[*n - 1] != v {
                cache[*n] = v;
                *n += 1;
            }
        };
        while a < above.len() && l < left.len() {
            let (ac, lc) = (above[a], left[l]);
            if lc < ac {
                put(lc, &mut n);
                l += 1;
            } else {
                put(ac, &mut n);
                a += 1;
                if lc == ac {
                    l += 1;
                }
            }
        }
        for &v in &above[a..] {
            put(v, &mut n);
        }
        for &v in &left[l..] {
            put(v, &mut n);
        }
        (cache, n)
    }

    /// The colours of a luma (`uv` 0) or U palette of `n` (write: `colors`, sorted; parse:
    /// decoded into it): those of the cache it uses, then the rest from a literal and deltas
    /// (luma: increasing, each at least 1; U: non-decreasing).
    fn palette_colors(&mut self, uv: usize, n: usize, colors: &mut [u8; 8]) {
        let (cache, cache_n) = self.palette_cache(uv);
        let mut got = [0u8; 8];
        let mut idx = 0;
        // write: what the cache doesn't give, in order
        let mut rest = [0u8; 8];
        let mut nrest = 0;
        if S::WRITE {
            let mut used = [false; 8];
            for &cv in &cache[..cache_n] {
                if let Some(k) = (0..n).find(|&k| !used[k] && colors[k] == cv) {
                    used[k] = true;
                }
            }
            // the cache entries are taken in cache order while idx < n: every used colour is one
            for k in 0..n {
                if !used[k] {
                    rest[nrest] = colors[k];
                    nrest += 1;
                }
            }
        }
        for &cv in &cache[..cache_n] {
            if idx >= n {
                break;
            }
            let use_w = S::WRITE && colors[..n].contains(&cv);
            if self.lit(use_w as i32, 1) != 0 {
                got[idx] = cv;
                idx += 1;
            }
        }
        let mut k = 0;
        if idx < n {
            got[idx] = self.lit(rest[k] as i32, 8) as u8;
            idx += 1;
            k += 1;
        }
        if idx < n {
            let min_bits = 8 - 3;
            let (minus, mut bits) = (if uv == 0 { 1 } else { 0 }, 0);
            if S::WRITE {
                let max_delta = (1..nrest)
                    .map(|i| (rest[i] - rest[i - 1]) as u32 - minus)
                    .max()
                    .unwrap_or(0);
                bits = (bits_for(max_delta) - min_bits).clamp(0, 3);
            }
            let extra = self.lit(bits, 2);
            let mut palette_bits = min_bits + extra;
            while idx < n {
                let d_w = if S::WRITE {
                    (rest[k] - rest[k - 1]) as i32 - minus as i32
                } else {
                    0
                };
                let d = self.lit(d_w, palette_bits) + minus as i32;
                got[idx] = (got[idx - 1] as i32 + d).min(255) as u8;
                let range = 256 - got[idx] as i32 - minus as i32;
                palette_bits = palette_bits.min(ceil_log2(range));
                idx += 1;
                k += 1;
            }
        }
        got[..n].sort_unstable();
        colors[..n].copy_from_slice(&got[..n]);
    }

    /// The V palette of `n`: deltas from each previous colour (wrapping) or literals, whichever is
    /// shorter (write: `colors`; parse: decoded into it).
    fn palette_colors_v(&mut self, n: usize, colors: &mut [u8; 8]) {
        let min_bits = 8 - 4;
        let (mut use_delta, mut extra_w) = (false, 0);
        let mut deltas = [0i32; 8];
        if S::WRITE {
            for i in 1..n {
                let mut d = colors[i] as i32 - colors[i - 1] as i32;
                if d > 128 {
                    d -= 256;
                } else if d < -128 {
                    d += 256;
                }
                deltas[i] = d;
            }
            let max = deltas[1..n].iter().map(|d| d.unsigned_abs()).max().unwrap_or(0);
            let bits = bits_for(max).max(min_bits);
            if bits <= min_bits + 3 {
                let cost = 2 + 8 + deltas[1..n].iter().map(|&d| bits + (d != 0) as i32).sum::<i32>();
                use_delta = cost < 8 * n as i32;
                extra_w = bits - min_bits;
            }
        }
        if self.lit(use_delta as i32, 1) != 0 {
            let extra = self.lit(extra_w, 2);
            let bits = min_bits + extra;
            colors[0] = self.lit(colors[0] as i32, 8) as u8;
            for i in 1..n {
                let mut d = self.lit(deltas[i].abs(), bits);
                if d != 0 && self.lit((deltas[i] < 0) as i32, 1) != 0 {
                    d = -d;
                }
                let mut v = colors[i - 1] as i32 + d;
                if v < 0 {
                    v += 256;
                }
                if v >= 256 {
                    v -= 256;
                }
                colors[i] = v as u8;
            }
        } else {
            for c in colors.iter_mut().take(n) {
                *c = self.lit(*c as i32, 8) as u8;
            }
        }
    }

    /// palette_mode_info, for the block in `self.st.pal` (write: the record's; parse: decoded).
    pub(super) fn palette_mode_info(&mut self, b: &Block, bsize: i32) -> Res<()> {
        let bsize_ctx = (t8(&Mi_Width_Log2, bsize) + t8(&Mi_Height_Log2, bsize) - 2) as usize;
        let mut p = self.st.pal;
        if b.y_mode as i32 == DC_PRED {
            let ctx = {
                let (st, bufs) = (&*self.st, &*self.bufs);
                let has = |y: i32, x: i32| {
                    let k = bufs.pal_at.get(bufs.mi(y, x)).copied().unwrap_or(NO_PALETTE);
                    k != NO_PALETTE && bufs.pals[k as usize].size_y > 0
                };
                (st.avail_u && has(st.mi_row - 1, st.mi_col)) as usize
                    + (st.avail_l && has(st.mi_row, st.mi_col - 1)) as usize
            };
            if self
                .sk
                .sym(&mut self.st.cdf.palette_y_mode[bsize_ctx][ctx], (p.size_y > 0) as i32)
                != 0
            {
                p.size_y = (self
                    .sk
                    .sym(&mut self.st.icdf.palette_y_size[bsize_ctx], p.size_y as i32 - 2)
                    + 2) as u8;
                self.palette_colors(0, p.size_y as usize, &mut p.colors[0]);
            }
        }
        if self.st.has_chroma && b.uv_mode as i32 == DC_PRED {
            let ctx = (p.size_y > 0) as usize;
            if self
                .sk
                .sym(&mut self.st.cdf.palette_uv_mode[ctx], (p.size_uv > 0) as i32)
                != 0
            {
                p.size_uv = (self
                    .sk
                    .sym(&mut self.st.icdf.palette_uv_size[bsize_ctx], p.size_uv as i32 - 2)
                    + 2) as u8;
                let n = p.size_uv as usize;
                self.palette_colors(1, n, &mut p.colors[1]);
                self.palette_colors_v(n, &mut p.colors[2]);
            }
        }
        self.st.pal = p;
        Ok(())
    }

    /// One colour index (the colour's rank `v` in ColorOrder) of an n-colour palette.
    fn color_idx(&mut self, uv: bool, n: usize, ctx: usize, v: i32) -> i32 {
        let c = if uv {
            &mut self.st.icdf.palette_uv_color
        } else {
            &mut self.st.icdf.palette_y_color
        };
        match n {
            2 => self.sk.sym(&mut c.c2[ctx], v),
            3 => self.sk.sym(&mut c.c3[ctx], v),
            4 => self.sk.sym(&mut c.c4[ctx], v),
            5 => self.sk.sym(&mut c.c5[ctx], v),
            6 => self.sk.sym(&mut c.c6[ctx], v),
            7 => self.sk.sym(&mut c.c7[ctx], v),
            _ => self.sk.sym(&mut c.c8[ctx], v),
        }
    }

    /// palette_tokens: the block's colour index maps into `self.st.maps` (write: from `given`, the
    /// record's maps, on-screen part checked; parse: decoded).
    pub(super) fn palette_tokens(&mut self, bsize: i32, given: &[u8]) -> Res<()> {
        let f = self.f;
        let p = self.st.pal;
        let mut at = 0;
        for (uv, n) in [(false, p.size_y as usize), (true, p.size_uv as usize)] {
            if n == 0 {
                continue;
            }
            let d = map_dims(bsize, self.st.mi_row, self.st.mi_col, f.mi_rows, f.mi_cols, uv);
            let mut maps = self.st.maps.take().unwrap_or_default();
            let map = &mut maps.map[uv as usize];
            if S::WRITE {
                let src = &given[at..at + d.w * d.h];
                at += d.w * d.h;
                for y in 0..d.oh {
                    let row = &src[y * d.w..][..d.ow];
                    if let Some(&bad) = row.iter().find(|&&v| v as usize >= n) {
                        self.st.maps = Some(maps);
                        fail!(
                            ERR_INVALID,
                            "block {}: colour index {bad} of a {n}-colour palette",
                            self.st.b_idx
                        );
                    }
                    map[y * d.w..][..d.ow].copy_from_slice(row);
                }
            }
            map[0] = self.ns(map[0] as i32, n as i32) as u8;
            for i in 1..d.oh + d.ow - 1 {
                for j in (i.saturating_sub(d.oh - 1)..=i.min(d.ow - 1)).rev() {
                    let r = i - j;
                    let (order, ctx) = color_context(map, d.w, r, j, n);
                    let v_w = if S::WRITE {
                        order.iter().position(|&o| o == map[r * d.w + j]).unwrap_or(0) as i32
                    } else {
                        0
                    };
                    let k = self.color_idx(uv, n, ctx, v_w);
                    map[r * d.w + j] = order[k as usize];
                }
            }
            // the maps past the visible part repeat its last column and row (as the prediction
            // reads them)
            for y in 0..d.h {
                let sy = y.min(d.oh - 1);
                for x in 0..d.w {
                    if y >= d.oh || x >= d.ow {
                        map[y * d.w + x] = map[sy * d.w + x.min(d.ow - 1)];
                    }
                }
            }
            self.st.maps = Some(maps);
        }
        Ok(())
    }
}
