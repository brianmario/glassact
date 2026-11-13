//! The reconstruction of a picture's blocks on every thread, apart from its symbol coding.
//!
//! A tile's walk codes its blocks one after another: every symbol's context comes from the ones
//! before it, and an intra block predicts from its decoded neighbours. But only the second chain
//! orders the reconstruction, and the closed-loop hook reads no symbol state, so with a
//! reconstruction a tile is coded in three passes:
//!
//! - **plan**: the walk with nothing coded and nothing reconstructed records what the
//!   reconstruction needs that only the walk knows: each block's quantizer, each intra tx block's
//!   [`TxbEdges`] (BlockDecoded, the edge filter's type), and the earlier blocks each intra block
//!   may read (the row above it to twice its width, the column left of it to twice its height,
//!   and those of its 8x8's chroma), or an intra block copy block copies (its source area). It
//!   also checks the record as coding does.
//! - **reconstruct**: the tile's blocks on every thread in groups (the blocks of a 32x32, or one
//!   larger block: [`TilePlan`]), each group once the groups its blocks read are done, its blocks
//!   in walk order: prediction, the hook, the inverse transform, the final levels and tx types
//!   into the record. A one-superblock-wide strip of intra blocks, which a tile codes alone, is a
//!   wavefront here.
//! - **code**: the walk again with the final levels, without a reconstruction (as
//!   ENC_SKIP_RECON), after the tile's last group.
//!
//! The plan hands each group on as its walk closes it, so a tile's first groups are reconstructed
//! while the rest is planned. That needs a tile its plan accepts, which `encode::Split` checks
//! before the walk (the coefficients' order, the luma tx types' sets); a tile it can't vouch for
//! hands its groups on after the walk, and a walk that fails waits for the groups it handed on
//! before the one-pass walk reports the failure.
//!
//! A picture's tiles are one task graph on the worker pool (`encode::Split`): one tile plans while
//! another reconstructs.
//!
//! The results are the one-pass walk's, bit for bit. Only a reconstruction that can't fail is
//! split: with ENC_FIX_RANGE, a hook that [`TxbHook::KEEPS_TX_SETS`], and a record the plan
//! accepts; anything else is coded in one pass, which fails where the walk would (and leaves the
//! record as it does).
use super::walk::{
    Frame, InterMaps, TileBufs, TxbEdges, levels, map_dims, map_origin, predict_inter_block, predict_intra_txb,
    predict_intrabc_block, predict_palette,
};
use super::{Res, TxbCtx, TxbHook};
use crate::blockinfo::{bh4, bw4};
use crate::dsp::{McScratch, ac_q, add_residual, chroma_tx_type, chroma_tx_type_inter, dc_q, tx_coeffs, tx_h, tx_w};
use crate::tables::DCT_DCT;
use crate::types::{Block, BlockPalette, Txb};
use std::sync::atomic::{AtomicU8, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex};

/// [`TilePlan::flags`]: an inter block
pub(super) const PLAN_INTER: u8 = 1;
/// [`TilePlan::flags`]: the block has chroma
pub(super) const PLAN_CHROMA: u8 = 2;

const NONE: u32 = u32::MAX;

/// Tiles reconstructed apart from their coding, for the tests.
#[cfg(test)]
pub(crate) static SPLIT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// What a tile's reconstruction reads of its plan: written by the plan's walk, read by the tile's
/// groups once published (the publication orders the writes before the reads). Reused.
#[derive(Default)]
pub(crate) struct PlanOut {
    /// per block (tile-local): PLAN_* flags
    pub flags: Vec<AtomicU8>,
    /// per block: its quantizer index
    pub q: Vec<AtomicU8>,
    /// per tx block (tile-local): an intra one's [`TxbEdges::pack`]
    pub edges: Vec<AtomicU8>,
    /// per group: its first block (tile-local); group g is blocks first[g]..first[g + 1]
    pub group_first: Vec<AtomicU32>,
    /// which groups are done and which wait for them
    pub order: Mutex<Order>,
    /// the tile's buffers as the plan set them up
    pub view: Mutex<TileView>,
}

/// Where a tile's buffers are while it is planned and reconstructed (addresses), and its geometry.
#[derive(Clone, Copy, Default)]
pub(crate) struct TileView {
    pub planes: [usize; 3],
    pub lens: [usize; 3],
    pub r0: i32,
    pub c0: i32,
    pub mw: i32,
    pub stride: [usize; 3],
    pub ref0: (usize, usize),
    pub mvs: (usize, usize),
    pub first: usize,
    pub txb_base: usize,
}

/// A tile's groups: which are done, how many groups each waits for, and the later groups reading
/// each (a list from `head[d]` through `nodes`).
#[derive(Default)]
pub(crate) struct Order {
    pub done: Vec<bool>,
    pub waits: Vec<u32>,
    pub head: Vec<u32>,
    /// (a reader, the next node)
    pub nodes: Vec<(u32, u32)>,
}

impl PlanOut {
    /// Sized for a tile of `n` blocks and `ntxb` tx blocks, no group done.
    pub fn setup(&mut self, n: usize, ntxb: usize) {
        grow(&mut self.flags, n);
        grow(&mut self.q, n);
        grow(&mut self.edges, ntxb);
        if self.group_first.len() < n + 1 {
            self.group_first.resize_with(n + 1, Default::default);
        }
        let o = self.order.get_mut().unwrap_or_else(|e| e.into_inner());
        o.done.clear();
        o.done.resize(n, false);
        o.waits.clear();
        o.waits.resize(n, 0);
        o.head.clear();
        o.head.resize(n, NONE);
        o.nodes.clear();
    }

    /// Group g's blocks (tile-local).
    #[inline]
    pub fn group(&self, g: usize) -> core::ops::Range<usize> {
        self.group_first[g].load(Ordering::Relaxed) as usize..self.group_first[g + 1].load(Ordering::Relaxed) as usize
    }
}

fn grow(v: &mut Vec<AtomicU8>, n: usize) {
    if v.len() < n {
        v.resize_with(n, Default::default);
    }
}

/// What the plan's walk keeps to itself: the group covering each 4x4 so far, and the groups each
/// group reads. A group is a run of blocks in walk order: those of one `unit` x `unit` square
/// (4x4s) of the tile, or one block covering several. Its blocks are reconstructed in order on one
/// thread, so it waits only for the earlier groups its blocks read. Reused.
#[derive(Default)]
pub(crate) struct TilePlan {
    /// the tile's first block and first tx block (record indices)
    pub first: usize,
    pub txb_base: usize,
    r0: i32,
    c0: i32,
    mw: i32,
    mh: i32,
    /// blocks in the tile
    n: usize,
    /// the group covering each 4x4 so far (tile-local, mh x mw)
    owner: Vec<u32>,
    /// groups started; the last is open
    pub n_groups: usize,
    /// per group: the earlier groups it reads, deps[deps_at[g]..deps_at[g + 1]]
    deps: Vec<u32>,
    deps_at: Vec<u32>,
    /// per group: the last group that listed it
    seen: Vec<u32>,
    near: Vec<u32>,
    /// where the tile's coefficients end so far
    coeff_end: usize,
    /// the tile can be reconstructed apart from its coding: its tx blocks' coefficients are in
    /// order and disjoint (as from av1g_layout), and its coded luma tx types in their sets
    pub ok: bool,
    /// the group square's side in 4x4s (a power of two)
    pub unit: i32,
}

impl TilePlan {
    /// Sizes the plan for a tile of `bufs`'s geometry, its blocks first..end and their tx blocks
    /// txb0..txb1, in groups of `unit` x `unit` 4x4s.
    #[allow(clippy::too_many_arguments)]
    pub fn setup(
        &mut self,
        out: &mut PlanOut,
        bufs: &mut TileBufs,
        first: usize,
        end: usize,
        txb0: usize,
        txb1: usize,
        unit: i32,
    ) {
        (self.r0, self.c0, self.mw, self.mh) = (bufs.r0, bufs.c0, bufs.mw, bufs.mh);
        *out.view.get_mut().unwrap_or_else(|e| e.into_inner()) = TileView {
            planes: core::array::from_fn(|p| bufs.plane[p].as_mut_ptr() as usize),
            lens: core::array::from_fn(|p| bufs.plane[p].len()),
            r0: bufs.r0,
            c0: bufs.c0,
            mw: bufs.mw,
            stride: bufs.stride,
            ref0: (bufs.ref0.as_ptr() as usize, bufs.ref0.len()),
            mvs: (bufs.mvs.as_ptr() as usize, bufs.mvs.len()),
            first,
            txb_base: txb0,
        };
        self.first = first;
        self.txb_base = txb0;
        self.n = end - first;
        self.unit = unit;
        out.setup(self.n, txb1 - txb0);
        self.owner.clear();
        self.owner.resize((self.mw * self.mh) as usize, NONE);
        self.seen.clear();
        self.seen.resize(self.n, NONE);
        self.deps.clear();
        self.deps_at.clear();
        self.deps_at.push(0);
        self.n_groups = 0;
        self.coeff_end = 0;
        self.ok = true;
    }

    /// The earlier groups group g reads.
    pub fn deps(&self, g: usize) -> &[u32] {
        &self.deps[self.deps_at[g] as usize..self.deps_at[g + 1] as usize]
    }

    /// The walk's tx block coefficients at `off..off + n` (tile-relative).
    #[inline]
    pub fn coeffs_at(&mut self, off: usize, n: usize) {
        self.ok &= off >= self.coeff_end;
        self.coeff_end = off + n;
    }

    /// Closes the open group, whose blocks end at `end` (tile-local).
    fn close(&mut self, out: &PlanOut, end: usize) -> u32 {
        let g = self.n_groups - 1;
        self.deps_at.push(self.deps.len() as u32);
        out.group_first[g + 1].store(end as u32, Ordering::Relaxed);
        g as u32
    }

    /// Block `b_idx` (a record index) of the walk at mi (r, c): its flags, quantizer and the
    /// earlier groups an intra one reads, or an intra block copy block at displacement `dv` (1/8
    /// luma sample, whole samples) copies. Returns the group it closed, if it starts one.
    #[allow(clippy::too_many_arguments)]
    pub fn block(
        &mut self,
        out: &PlanOut,
        b_idx: u32,
        r: i32,
        c: i32,
        bsize: i32,
        is_inter: bool,
        has_chroma: bool,
        q: i32,
        dv: Option<[i32; 2]>,
    ) -> Option<u32> {
        let j = b_idx as usize - self.first;
        out.flags[j].store(
            if is_inter { PLAN_INTER } else { 0 } | if has_chroma { PLAN_CHROMA } else { 0 },
            Ordering::Relaxed,
        );
        out.q[j].store(q as u8, Ordering::Relaxed);
        let mut closed = None;
        if self.n_groups == 0 || ((r - self.r0) | (c - self.c0)) & (self.unit - 1) == 0 {
            if self.n_groups > 0 {
                closed = Some(self.close(out, j));
            }
            out.group_first[self.n_groups].store(j as u32, Ordering::Relaxed);
            self.n_groups += 1;
        }
        let g = (self.n_groups - 1) as u32;
        let (bw, bh) = (bw4(bsize), bh4(bsize));
        if !is_inter {
            self.near.clear();
            self.ring(r, c, bh, bw);
            if has_chroma && (bw == 1 || bh == 1) {
                // the chroma of a sub-8x8 block covers its 8x8
                self.ring(r & !1, c & !1, bh.max(2), bw.max(2));
            }
            self.add_deps(g);
        } else if let Some(dv) = dv {
            // the source's 4x4s, which is_mv_valid keeps inside the tile and before the block, to
            // whole 8x8s: a sub-8x8 block's chroma is its 8x8's last block's
            let (y0, x0) = (r * 4 + (dv[0] >> 3), c * 4 + (dv[1] >> 3));
            // (and 2 luma samples more along an odd component: the bilinear chroma reads them)
            let (y1, x1) = (
                y0 + 4 * bh + 2 * ((dv[0] >> 3) & 1),
                x0 + 4 * bw + 2 * ((dv[1] >> 3) & 1),
            );
            let ((ry0, ry1), (rx0, rx1)) = (
                ((y0 >> 3) << 1, (((y1 + 7) >> 3) << 1).min(self.r0 + self.mh)),
                ((x0 >> 3) << 1, (((x1 + 7) >> 3) << 1).min(self.c0 + self.mw)),
            );
            self.near.clear();
            for y in ry0..ry1 {
                let row = ((y - self.r0) * self.mw - self.c0) as isize;
                for x in rx0..rx1 {
                    let o = self.owner[(row + x as isize) as usize];
                    if o != NONE && self.near.last() != Some(&o) {
                        self.near.push(o);
                    }
                }
            }
            self.add_deps(g);
        }
        let (r1, c1) = ((r + bh).min(self.r0 + self.mh), (c + bw).min(self.c0 + self.mw));
        for y in r..r1 {
            let k = ((y - self.r0) * self.mw + c - self.c0) as usize;
            self.owner[k..k + (c1 - c) as usize].fill(g);
        }
        closed
    }

    /// The groups in `near` other than g and not listed yet, into g's.
    fn add_deps(&mut self, g: u32) {
        for &d in &self.near {
            if d != g && self.seen[d as usize] != g {
                self.seen[d as usize] = g;
                self.deps.push(d);
            }
        }
    }

    /// The groups covering the 4x4s an intra prediction of the h x w (4x4s) area at (r, c) may
    /// read: the row above from the above-left 4x4 to twice the width, the column left to twice
    /// the height (inside the tile), into `near`.
    fn ring(&mut self, r: i32, c: i32, h: i32, w: i32) {
        let (r0, c0, mw) = (self.r0, self.c0, self.mw);
        let (tr1, tc1) = (r0 + self.mh, c0 + mw);
        let (owner, near) = (&self.owner, &mut self.near);
        let mut add = |y: i32, x: i32| {
            let o = owner[((y - r0) * mw + x - c0) as usize];
            if o != NONE && near.last() != Some(&o) {
                near.push(o);
            }
        };
        if r > r0 {
            for x in (c - 1).max(c0)..(c + 2 * w).min(tc1) {
                add(r - 1, x);
            }
        }
        if c > c0 {
            for y in r.max(r0)..(r + 2 * h).min(tr1) {
                add(y, c - 1);
            }
        }
    }

    /// After the walk: closes the last group. Returns it, if there is one.
    pub fn end(&mut self, out: &PlanOut) -> Option<u32> {
        (self.n_groups > 0).then(|| self.close(out, self.n))
    }
}

/// The plan as the walk sees it: its own part, what the reconstruction reads, and with streaming,
/// where each group goes as the walk closes it (while the plan still accepts the tile).
pub(crate) struct PlanCtx<'a> {
    pub plan: &'a mut TilePlan,
    pub out: &'a PlanOut,
    pub publish: Option<&'a dyn Fn(&TilePlan, u32)>,
}

impl PlanCtx<'_> {
    /// [`TilePlan::block`], publishing the group it closes.
    #[allow(clippy::too_many_arguments)]
    #[inline]
    pub fn block(
        &mut self,
        b_idx: u32,
        r: i32,
        c: i32,
        bsize: i32,
        is_inter: bool,
        has_chroma: bool,
        q: i32,
        dv: Option<[i32; 2]>,
    ) {
        let closed = self
            .plan
            .block(self.out, b_idx, r, c, bsize, is_inter, has_chroma, q, dv);
        if let (Some(g), Some(p)) = (closed, self.publish)
            && self.plan.ok
        {
            p(self.plan, g);
        }
    }

    /// Tx block `ti`'s (a record index) edges.
    #[inline]
    pub fn set_edges(&self, ti: usize, e: u8) {
        self.out.edges[ti - self.plan.txb_base].store(e, Ordering::Relaxed);
    }
}

/// One reconstruction thread's scratch. Reused.
pub(super) struct ReconBufs {
    mc: Box<McScratch>,
    dq: Box<[i32; 1024]>,
    res: Box<[i32; 4096]>,
    /// the current inter block's luma TxTypes (its chroma derives from them), block-relative 4x4s
    tx_types: [[u8; 32]; 32],
}

impl Default for ReconBufs {
    fn default() -> Self {
        ReconBufs {
            mc: Box::default(),
            dq: Box::new([0; 1024]),
            res: Box::new([0; 4096]),
            tx_types: [[0; 32]; 32],
        }
    }
}

/// A planned tile as its blocks' reconstructions share it.
#[derive(Clone, Copy)]
pub(super) struct ReconTile<'a> {
    /// the tile's planes (its `TileBufs`', which nothing else touches while they are
    /// reconstructed)
    pub planes: [*mut u8; 3],
    pub lens: [usize; 3],
    /// its geometry, and its RefFrames and Mvs maps, which the plan's walk fills in walk order:
    /// a published block's entries, and those of the blocks before it, are final
    pub r0: i32,
    pub c0: i32,
    pub mw: i32,
    pub stride: [usize; 3],
    pub ref0: (*const u8, usize),
    pub mvs: (*const [i16; 2], usize),
    pub out: &'a PlanOut,
    /// the tile's first block and first tx block (record indices)
    pub first: usize,
    pub txb_base: usize,
}

impl ReconTile<'_> {
    /// A published group's view of its tile.
    pub fn new(out: &PlanOut) -> ReconTile<'_> {
        let v = *out.view.lock().unwrap_or_else(|e| e.into_inner());
        ReconTile {
            planes: core::array::from_fn(|p| v.planes[p] as *mut u8),
            lens: v.lens,
            r0: v.r0,
            c0: v.c0,
            mw: v.mw,
            stride: v.stride,
            ref0: (v.ref0.0 as *const u8, v.ref0.1),
            mvs: (v.mvs.0 as *const [i16; 2], v.mvs.1),
            out,
            first: v.first,
            txb_base: v.txb_base,
        }
    }
}

/// The record as the blocks' reconstructions share it: each block writes only its own tx blocks
/// and their coefficients.
#[derive(Clone, Copy)]
pub(super) struct ReconRec<'a> {
    pub blocks: &'a [Block],
    /// one per block, or empty; the colour index maps
    pub palette: &'a [BlockPalette],
    pub palette_map: &'a [u8],
    pub block_txb: &'a [u32],
    pub txb: *mut Txb,
    pub coeffs: *mut i16,
}

/// Block `k`'s reconstruction: its prediction, and with a residual the hook, the inverse transform,
/// its tx blocks' final levels, tx types and eobs. As the walk's (`walk::txb`).
///
/// # Safety
///
/// Nothing else may access block k's tx blocks and coefficients meanwhile, nor its area of the
/// tile's planes (of its 8x8 for sub-8x8 chroma), and the earlier blocks its plan says it reads
/// must be reconstructed, their writes ordered before this call. The planes, tx blocks and
/// coefficients must be the ones the plan's walk checked.
#[allow(clippy::too_many_arguments)]
pub(super) unsafe fn recon_block<H: TxbHook>(
    f: &Frame,
    hook: Option<&H>,
    rec: ReconRec,
    t: ReconTile,
    k: usize,
    ws: &mut ReconBufs,
    hs: &mut H::Scratch,
    n_fixed: &mut u64,
) -> Res<()> {
    let fp = &f.fp;
    let j = k - t.first;
    let b = &rec.blocks[k];
    let flags = t.out.flags[j].load(Ordering::Relaxed);
    let is_inter = flags & PLAN_INTER != 0;
    let has_chroma = flags & PLAN_CHROMA != 0;
    let (r, c, bsize) = (b.mi_row as i32, b.mi_col as i32, b.bsize as i32);
    let qidx = t.out.q[j].load(Ordering::Relaxed) as i32;
    let dcq = [
        dc_q(qidx + fp.delta_q_y_dc as i32),
        dc_q(qidx + fp.delta_q_u_dc as i32),
        dc_q(qidx + fp.delta_q_v_dc as i32),
    ];
    let acq = [
        ac_q(qidx),
        ac_q(qidx + fp.delta_q_u_ac as i32),
        ac_q(qidx + fp.delta_q_v_ac as i32),
    ];
    // SAFETY: (the caller's) block k reads and writes only samples no running reconstruction
    // writes. Other threads' slices of the same planes overlap these, but no sample is accessed
    // through two at once.
    let mut planes: [&mut [u8]; 3] =
        core::array::from_fn(|p| unsafe { core::slice::from_raw_parts_mut(t.planes[p], t.lens[p]) });
    // SAFETY: (the caller's) the maps' entries block k reads are its own and its 8x8's earlier
    // blocks', which the plan's walk wrote before it published k; it writes only later blocks'
    // entries meanwhile, so no entry read here is written while it is read
    let (ref0, mvs) = unsafe {
        (
            core::slice::from_raw_parts(t.ref0.0, t.ref0.1),
            core::slice::from_raw_parts(t.mvs.0, t.mvs.1),
        )
    };
    if is_inter && f.intrabc {
        let dv = mvs[((r - t.r0) * t.mw + c - t.c0) as usize];
        let dv = [dv[0] as i32, dv[1] as i32];
        predict_intrabc_block(&mut planes, t.stride, t.r0, t.c0, r, c, bsize, has_chroma, dv);
    } else if is_inter && f.refs.is_some() {
        let maps = InterMaps {
            ref0,
            mvs,
            r0: t.r0,
            c0: t.c0,
            mw: t.mw,
            stride: t.stride,
        };
        predict_inter_block(f, &maps, &mut planes, r, c, bsize, has_chroma, &mut ws.mc);
    }
    let mut max_luma = (0, 0);
    for ti in rec.block_txb[k] as usize..rec.block_txb[k + 1] as usize {
        // SAFETY: tx block ti is block k's, which (the caller's) nothing else touches.
        let tx = unsafe { &mut *rec.txb.add(ti) };
        let plane = tx.plane as usize;
        let tx_sz = tx.tx_size as i32;
        let sub = (plane != 0) as i32;
        let (ox, oy) = ((t.c0 * 4) >> sub, (t.r0 * 4) >> sub);
        let (lx, ly) = (tx.x4 as i32 * 4 - ox, tx.y4 as i32 * 4 - oy);
        let stride = t.stride[plane];
        let off = ly as usize * stride + lx as usize;
        let pal = rec.palette.get(k).copied().unwrap_or_default();
        let pal_n = [pal.size_y, pal.size_uv][(plane > 0) as usize];
        if !is_inter && pal_n != 0 {
            // the maps start at map_off: luma, then chroma (the plan's walk checked them)
            let d = map_dims(bsize, r, c, f.mi_rows, f.mi_cols, plane > 0);
            let at = pal.map_off as usize
                + if plane > 0 && pal.size_y != 0 {
                    let l = map_dims(bsize, r, c, f.mi_rows, f.mi_cols, false);
                    l.w * l.h
                } else {
                    0
                };
            let (bx, by) = map_origin(r, c, sub);
            predict_palette(
                planes[plane],
                off,
                stride,
                (tx_w(tx_sz) as usize, tx_h(tx_sz) as usize),
                ((tx.x4 as i32 * 4 - bx) as usize, (tx.y4 as i32 * 4 - by) as usize),
                &pal.colors[plane],
                &rec.palette_map[at..],
                d,
            );
        } else if !is_inter {
            let e = TxbEdges::unpack(t.out.edges[ti - t.txb_base].load(Ordering::Relaxed));
            let max = (((f.mi_cols * 4) >> sub) - 1 - ox, ((f.mi_rows * 4) >> sub) - 1 - oy);
            let [l, u, v] = &mut planes;
            let (cur, luma): (&mut [u8], &[u8]) = match plane {
                0 => (l, &[]),
                1 => (u, l),
                _ => (v, l),
            };
            predict_intra_txb(
                fp,
                b,
                plane,
                tx_sz,
                e,
                (lx, ly),
                max,
                cur,
                stride,
                luma,
                t.stride[0],
                max_luma,
            );
        }
        if !is_inter && plane == 0 {
            max_luma = (lx + tx_w(tx_sz), ly + tx_h(tx_sz));
        }
        if b.skip != 0 {
            continue;
        }
        tx.eob = 0;
        let mut tx_type = if plane == 0 {
            tx.tx_type as i32
        } else {
            let tt = if is_inter {
                let (y4, x4) = (((tx.y4 as i32) << 1).max(r) - r, ((tx.x4 as i32) << 1).max(c) - c);
                chroma_tx_type_inter(
                    tx_sz,
                    ws.tx_types[y4 as usize][x4 as usize] as i32,
                    fp.reduced_tx_set != 0,
                )
            } else {
                chroma_tx_type(tx_sz, b.uv_mode as i32, fp.reduced_tx_set != 0)
            };
            tx.tx_type = tt as u8;
            tt
        };
        let n = tx_coeffs(tx_sz);
        // SAFETY: (the caller's) these are tx block ti's coefficients, inside the record, which
        // nothing else touches.
        let q = unsafe { core::slice::from_raw_parts_mut(rec.coeffs.add(tx.coeff_off as usize), n) };
        let ctx = TxbCtx {
            block: b,
            block_idx: k as u32,
            recon: &planes[plane][off..],
            recon_stride: stride,
            dc_q: dcq[plane],
            ac_q: acq[plane],
            derived_tx_type: tx_type,
            qm_level: if fp.using_qmatrix != 0 { f.qm_level[plane] } else { 15 },
            is_inter,
        };
        let hook = hook.map(|h| (h, &mut *hs));
        let eob = levels(f, hook, &ctx, tx, q, &mut tx_type, &mut ws.dq, &mut ws.res, n_fixed)?;
        if plane == 0 {
            // coeffs(): an all-zero luma tx block's type is DCT_DCT
            if eob == 0 {
                tx_type = DCT_DCT;
            }
            tx.tx_type = tx_type as u8;
            if is_inter {
                let (y0, x0) = ((tx.y4 as i32 - r) as usize, (tx.x4 as i32 - c) as usize);
                let (h4, w4) = (tx_h(tx_sz) as usize >> 2, tx_w(tx_sz) as usize >> 2);
                for row in &mut ws.tx_types[y0..(y0 + h4).min(32)] {
                    row[x0..(x0 + w4).min(32)].fill(tx_type as u8);
                }
            }
        }
        tx.eob = eob as u16;
        if eob > 0 {
            add_residual(&mut planes[plane][off..], stride, &ws.res[..], tx_sz, tx_type);
        }
    }
    Ok(())
}

/// How many empty pops spin, and up to how many yield, before a thread sleeps (diagnostics:
/// GA_IDLE=spin,yield).
pub(super) fn idle_limits() -> (u32, u32) {
    static L: std::sync::OnceLock<(u32, u32)> = std::sync::OnceLock::new();
    *L.get_or_init(|| {
        std::env::var("GA_IDLE")
            .ok()
            .and_then(|v| {
                let (a, b) = v.split_once(',')?;
                Some((a.parse().ok()?, b.parse().ok()?))
            })
            .unwrap_or((64, 96))
    })
}

/// The tasks ready to run, each pushed once a picture: a slot per task (every one [`Ready::EMPTY`]
/// between pictures), and the threads waiting for one.
#[derive(Default)]
pub(super) struct Ready {
    slots: Vec<AtomicU32>,
    head: AtomicUsize,
    tail: AtomicUsize,
    sleepers: AtomicUsize,
    lock: Mutex<()>,
    wake: Condvar,
}

impl Ready {
    pub const EMPTY: u32 = u32::MAX;

    /// Empty, for a picture of up to `n` tasks.
    pub fn reset(&mut self, n: usize) {
        if self.slots.len() < n {
            self.slots.resize_with(n, || AtomicU32::new(Self::EMPTY));
        }
        *self.head.get_mut() = 0;
        *self.tail.get_mut() = 0;
    }

    pub fn push(&self, k: u32) {
        let i = self.tail.fetch_add(1, Ordering::SeqCst);
        self.slots[i].store(k, Ordering::Release);
        if self.sleepers.load(Ordering::SeqCst) > 0 {
            drop(self.lock.lock().unwrap_or_else(|e| e.into_inner()));
            self.wake.notify_one();
        }
    }

    pub fn pop(&self) -> Option<u32> {
        loop {
            let h = self.head.load(Ordering::SeqCst);
            if h >= self.tail.load(Ordering::SeqCst) {
                return None;
            }
            if self
                .head
                .compare_exchange_weak(h, h + 1, Ordering::SeqCst, Ordering::Relaxed)
                .is_ok()
            {
                // the pusher has claimed slot h; its store may still be on the way
                loop {
                    let k = self.slots[h].swap(Self::EMPTY, Ordering::Acquire);
                    if k != Self::EMPTY {
                        return Some(k);
                    }
                    std::hint::spin_loop();
                }
            }
        }
    }

    /// After `idle` empty pops in a row: spins, then yields, then sleeps until a push or
    /// [`Ready::wake_all`] (when `done` says nothing will come).
    pub fn idle(&self, idle: u32, done: impl Fn() -> bool) {
        let (spin, yields) = idle_limits();
        if idle < spin {
            std::hint::spin_loop();
        } else if idle < yields {
            std::thread::yield_now();
        } else {
            let g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
            self.sleepers.fetch_add(1, Ordering::SeqCst);
            if self.head.load(Ordering::SeqCst) >= self.tail.load(Ordering::SeqCst) && !done() {
                drop(self.wake.wait(g).unwrap_or_else(|e| e.into_inner()));
            } else {
                drop(g);
            }
            self.sleepers.fetch_sub(1, Ordering::SeqCst);
        }
    }

    pub fn wake_all(&self) {
        drop(self.lock.lock().unwrap_or_else(|e| e.into_inner()));
        self.wake.notify_all();
    }
}
