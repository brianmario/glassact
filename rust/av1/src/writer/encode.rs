//! The encoder (Encoder::run, av1g::encode_with_hook): frame checks, tiles on parallel threads,
//! the OBUs, the post-filters of the reconstruction and the outputs.
use super::headers::{BitWriter, frame_obus};
use super::recon::{Ready, ReconBufs, ReconRec, ReconTile, TilePlan, recon_block};
use super::sink::{EcSink, NullSink, TeeSink};
use super::walk::{Frame, Rec, TileBufs, TileState, Walk};
use super::*;
use crate::blockinfo::{mi_cols, mi_rows};
use crate::dsp::{RefPlane, tx_coeffs, tx_h, tx_w};
use crate::entropy::{Ec, FrameCdfs};
use crate::postfilter::{PF_BLK_INTER, PF_BLK_LF_ZERO, PfFrame, PfMaps, cdef_frame, deblock_frame, pf_skip_value};
use crate::tables::{LAST_FRAME, TX_SIZES_ALL};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU32, AtomicU64, AtomicUsize, Ordering};

/// Symbol coding only (validation): AV1G_ENC_SKIP_RECON.
pub const ENC_SKIP_RECON: u32 = ENC_BITSTREAM_ONLY;
/// Internal: cross-check [`crate::blockinfo::txb_edges`] against BlockDecoded (AV1G_ENC_CHECK_EDGES; 64x64
/// superblocks only, as txb_edges: ignored with fp.sb128).
pub const ENC_CHECK_EDGES: u32 = 0x20000;
/// Internal: reconstruct each tile in its coding walk, even on several threads (where the blocks
/// are otherwise reconstructed on all of them, apart from their coding: [`super::recon`]).
pub const ENC_ONE_PASS: u32 = 0x40000;
/// Internal: count each block's bits ([`Writer::block_bits`]; the partition symbols before it
/// aren't its).
pub const ENC_BLOCK_BITS: u32 = 0x80000;
/// Internal: with the blocks reconstructed on several threads, the tiles aren't coded after them
/// (no payloads, saved CDFs or symbols): the hybrid's closed loop, which codes the frame again
/// once its filters are chosen. A tile reconstructed in its coding walk is coded as ever.
pub const ENC_NO_CODE: u32 = 0x100000;

/// One tile thread's state. Reused.
#[derive(Default)]
struct Worker {
    st: Box<TileState>,
    ec: Ec,
    /// for blocks' reconstructions ([`super::recon`])
    rb: ReconBufs,
}

/// The frame-level buffers the post-filters run on when a picture has several tiles (one tile's
/// own buffers are frame-shaped).
#[derive(Default)]
struct FrameBufs {
    plane: [Vec<u8>; 3],
    skip: Vec<u8>,
    /// the post-filters' skip map with fp.lf_inter_off (postfilter::LF_ZERO on inter blocks)
    pf_skip: Vec<u8>,
    tx: Vec<u8>,
    lf_uv: [Vec<u8>; 2],
    sb_cdef: Vec<i8>,
}

/// Optional inputs and outputs of [`Writer::encode_with_hook`].
#[derive(Clone, Copy, Debug, Default)]
pub struct Extras<'a> {
    /// one entry per tile (raster order): tiles the caller already has
    pub tile_skip: Option<&'a [TileSkip<'a>]>,
    /// record every coded tile's packed symbol stream ([`Writer::tile_syms`]; intra frames only:
    /// the GPU entropy coder's symbol streams have no inter syntax)
    pub record_syms: bool,
    /// the reference pictures by slot (video mode): an inter frame predicts from
    /// `refs[fp.ref_slot]`, which must be present unless the reconstruction is skipped
    pub refs: Option<&'a RefSlots<'a>>,
}

/// The DecisionRecord writer with its scratch: per-thread tile state, per-tile reconstruction
/// buffers and payloads, the post-filters' frame. One per stream: once its buffers have grown, a
/// writer encoding same-sized pictures doesn't allocate in the walk.
pub struct Writer {
    workers: Vec<Worker>,
    tiles: Vec<TileBufs>,
    payloads: Vec<Vec<u8>>,
    syms: Vec<Vec<u32>>,
    ordmap: [Vec<u32>; 3],
    tile_first: Vec<u32>,
    ranges: Vec<(usize, usize, usize, usize)>,
    frame: FrameBufs,
    cdef_out: [Vec<u8>; 3],
    seq: BitWriter,
    fh: BitWriter,
    threads: usize,
    /// the context tile's saved CDFs, as its worker leaves them (captured, CDFs)
    saved: Mutex<(bool, Box<FrameCdfs>)>,
    /// tiles by block count, for the context tile
    tile_order: Vec<(u32, usize)>,
    /// the tiles' reconstruction plans and the split pictures' task queue
    plans: Vec<TilePlan>,
    ready: Ready,
    /// [`ENC_BLOCK_BITS`]
    block_bits: Vec<AtomicU32>,
}

impl Default for Writer {
    fn default() -> Self {
        Self::new()
    }
}

/// One tile's work for a thread.
struct TileTask<'a> {
    rec: Rec<'a>,
    bufs: &'a mut TileBufs,
    payload: &'a mut Vec<u8>,
    syms: Option<&'a mut Vec<u32>>,
    plan: Option<&'a mut TilePlan>,
    nsym: u64,
    nfixed: u64,
    err: Option<Box<Error>>,
}

/// Codes tile `i` (raster order) of the frame into `payload`, its tile buffers' planes sized when
/// `planes`; with `plan`, plans its reconstruction instead (nothing coded). Returns (symbols,
/// repaired tx blocks).
#[allow(clippy::too_many_arguments)]
fn code_tile<H: TxbHook>(
    w: &mut Worker,
    f: &Frame,
    rec: &mut Rec,
    bufs: &mut TileBufs,
    payload: &mut Vec<u8>,
    syms: Option<&mut Vec<u32>>,
    hook: Option<&H>,
    hs: &mut H::Scratch,
    i: usize,
    first: u32,
    end: u32,
    plan: Option<&mut TilePlan>,
    planes: bool,
) -> Res<(u64, u64)> {
    let cols = f.tiles.cols as usize;
    let (tr, tc) = (i / cols, i % cols);
    bufs.setup(f, tr, tc, planes);
    w.st.cursor = first;
    w.st.tile_end = end;
    w.st.n_fixed = 0;
    w.ec.reset();
    let nsym = match (plan, syms) {
        (Some(p), _) => {
            let Rec::Write { block_txb, .. } = rec else {
                unreachable!()
            };
            let (t0, t1) = (block_txb[first as usize] as usize, block_txb[end as usize] as usize);
            p.setup(bufs, first as usize, end as usize, t0, t1);
            let mut walk = Walk {
                st: &mut w.st,
                sk: NullSink,
                f,
                bufs,
                hook,
                hs,
                plan: Some(&mut *p),
            };
            walk.tile(rec, tr, tc)?;
            p.finish();
            0
        }
        (None, Some(out)) => {
            out.clear();
            let base = &w.st.cdf as *const _ as usize;
            let sk = TeeSink {
                ec: EcSink { ec: &mut w.ec, nsym: 0 },
                base,
                out,
            };
            let mut walk = Walk {
                st: &mut w.st,
                sk,
                f,
                bufs,
                hook,
                hs,
                plan: None,
            };
            walk.tile(rec, tr, tc)?;
            walk.sk.ec.nsym
        }
        (None, None) => {
            let sk = EcSink { ec: &mut w.ec, nsym: 0 };
            let mut walk = Walk {
                st: &mut w.st,
                sk,
                f,
                bufs,
                hook,
                hs,
                plan: None,
            };
            walk.tile(rec, tr, tc)?;
            walk.sk.nsym
        }
    };
    payload.clear();
    w.ec.finish(payload);
    if w.st.cursor != w.st.tile_end {
        fail!(
            ERR_INVALID,
            "tile {tr},{tc}: block {} not consumed by the partition walk",
            w.st.cursor
        );
    }
    Ok((nsym, w.st.n_fixed))
}

/// Codes (or with `plans`, plans) the tiles not `skipped`, on the workers in parallel with the
/// record's `ranges` (tile_ranges), else one after the other. Returns (symbols, repaired tx
/// blocks); the first error in tile order.
#[allow(clippy::too_many_arguments)]
fn code_tiles<H: TxbHook>(
    workers: &mut [Worker],
    tiles: &mut [TileBufs],
    payloads: &mut [Vec<u8>],
    syms: &mut [Vec<u32>],
    mut plans: Option<&mut [TilePlan]>,
    ranges: Option<&[(usize, usize, usize, usize)]>,
    tile_first: &[u32],
    rec: &mut RecordMut,
    f: &Frame,
    hook: Option<&H>,
    skipped: &(impl Fn(usize) -> bool + Sync),
    planes: bool,
) -> Res<(u64, u64)> {
    let (mut nsym, mut nfixed) = (0u64, 0u64);
    let Some(ranges) = ranges else {
        let mut r = Rec::Write {
            blocks: rec.blocks,
            inter: rec.inter,
            palette: rec.palette,
            palette_map: rec.palette_map,
            block_txb: rec.block_txb,
            txb: &mut *rec.txb,
            txb_base: 0,
            coeffs: &mut *rec.coeffs,
            coeff_base: 0,
        };
        let mut hs = H::Scratch::default();
        let w = &mut workers[0];
        for (i, (bufs, payload)) in tiles.iter_mut().zip(payloads.iter_mut()).enumerate() {
            if skipped(i) {
                continue;
            }
            let plan = plans.as_deref_mut().map(|p| &mut p[i]);
            let (s, x) = code_tile(
                w,
                f,
                &mut r,
                bufs,
                payload,
                syms.get_mut(i),
                hook,
                &mut hs,
                i,
                tile_first[i],
                tile_first[i + 1],
                plan,
                planes,
            )?;
            nsym += s;
            nfixed += x;
        }
        return Ok((nsym, nfixed));
    };
    // the tiles' parts of the record, buffers and outputs
    let mut txb_rest: &mut [Txb] = &mut *rec.txb;
    let mut coeff_rest: &mut [i16] = &mut *rec.coeffs;
    let (mut txb_at, mut coeff_at) = (0usize, 0usize);
    let mut tasks = Vec::with_capacity(tiles.len());
    let mut syms_iter = syms.iter_mut();
    let mut plans_iter = plans.into_iter().flatten();
    for (i, ((bufs, payload), &(t0, t1, c0, c1))) in tiles.iter_mut().zip(payloads.iter_mut()).zip(ranges).enumerate() {
        let (_, rest) = core::mem::take(&mut txb_rest).split_at_mut(t0 - txb_at);
        let (tx, rest) = rest.split_at_mut(t1 - t0);
        txb_rest = rest;
        txb_at = t1;
        let (_, rest) = core::mem::take(&mut coeff_rest).split_at_mut(c0 - coeff_at);
        let (co, rest) = rest.split_at_mut(c1 - c0);
        coeff_rest = rest;
        coeff_at = c1;
        let syms = syms_iter.next();
        let plan = plans_iter.next();
        if skipped(i) {
            continue;
        }
        tasks.push((
            i,
            Mutex::new(TileTask {
                rec: Rec::Write {
                    blocks: rec.blocks,
                    inter: rec.inter,
                    palette: rec.palette,
                    palette_map: rec.palette_map,
                    block_txb: rec.block_txb,
                    txb: tx,
                    txb_base: t0,
                    coeffs: co,
                    coeff_base: c0,
                },
                bufs,
                payload,
                syms,
                plan,
                nsym: 0,
                nfixed: 0,
                err: None,
            }),
        ));
    }
    let next = AtomicUsize::new(0);
    let stop = AtomicBool::new(false);
    let work = |w: &mut Worker| {
        let mut hs = H::Scratch::default();
        loop {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            let k = next.fetch_add(1, Ordering::Relaxed);
            let Some((i, task)) = tasks.get(k) else { break };
            let mut guard = task.lock().unwrap();
            let t = &mut *guard;
            match code_tile(
                w,
                f,
                &mut t.rec,
                t.bufs,
                t.payload,
                t.syms.as_deref_mut(),
                hook,
                &mut hs,
                *i,
                tile_first[*i],
                tile_first[*i + 1],
                t.plan.as_deref_mut(),
                planes,
            ) {
                Ok((s, x)) => {
                    t.nsym = s;
                    t.nfixed = x;
                }
                Err(e) => {
                    t.err = Some(e);
                    stop.store(true, Ordering::Relaxed);
                }
            }
        }
    };
    crate::pool::each(workers, work);
    // the first error in tile order: every tile before an erroneous one was taken (and
    // completed), so it is the one sequential coding reports
    for (_, task) in tasks {
        let t = task.into_inner().unwrap();
        if let Some(e) = t.err {
            return Err(e);
        }
        nsym += t.nsym;
        nfixed += t.nfixed;
    }
    Ok((nsym, nfixed))
}

/// A coded tile's work in a split picture ([`super::recon`]), which its tasks share: its parts of
/// the record and of the writer's buffers, each used by one task at a time (its plan, then its
/// blocks' reconstructions, which only read the plan and the maps, then its coding; or a one-pass
/// walk), its progress and its results.
struct TileJob {
    first: u32,
    end: u32,
    bufs: *mut TileBufs,
    plan: *mut TilePlan,
    payload: *mut Vec<u8>,
    /// null: no symbol stream
    syms: *mut Vec<u32>,
    /// the tile's tx blocks and coefficients: record ranges
    txb: (usize, usize),
    coeffs: (usize, usize),
    /// the tile's planes, once planned
    planes: [AtomicPtr<u8>; 3],
    lens: [AtomicUsize; 3],
    /// blocks not reconstructed yet
    left: AtomicU32,
    /// symbols, repaired tx blocks, the error
    out: Mutex<(u64, u64, Option<Box<Error>>)>,
}

/// A split picture's tasks: blocks by record index, then three per tile.
const TASK_PLAN: usize = 0;
const TASK_CODE: usize = 1;
const TASK_ONE_PASS: usize = 2;

/// A split picture: its tiles' tasks on every thread. A tile's plan queues its blocks that read
/// no other; a block queues the readers it was the last wait of (taking one on itself); a tile's
/// last block queues its coding. A tile the plan rejects is coded in one pass instead.
struct Split<'a, H: TxbHook> {
    /// the reconstruction's (and one-pass walks')
    f: Frame<'a>,
    plan_f: Frame<'a>,
    code_f: Frame<'a>,
    hook: Option<&'a H>,
    blocks: &'a [Block],
    inter: &'a [BlockInter],
    palette: &'a [BlockPalette],
    palette_map: &'a [u8],
    block_txb: &'a [u32],
    txb: *mut Txb,
    coeffs: *mut i16,
    /// per tile: Some if coded
    jobs: &'a [Option<TileJob>],
    tile_first: &'a [u32],
    n_blocks: usize,
    ready: &'a Ready,
    /// coded tiles not finished
    left: AtomicUsize,
    n_fixed: AtomicU64,
    /// [`ENC_NO_CODE`]
    no_code: bool,
    /// GA_CRIT: per task its start and end (ns from t0), or empty
    prof: &'a [AtomicU64],
    t0: std::time::Instant,
    /// GA_CRIT: the workers' thread CPU time (ns) in plans, blocks, codings, and in all
    cpu: [AtomicU64; 4],
}

/// GA_CRIT: this thread's CPU time in ns (0 where there's no such clock).
fn thread_cpu_ns() -> u64 {
    #[cfg(target_vendor = "apple")]
    {
        unsafe extern "C" {
            fn clock_gettime_nsec_np(clock: u32) -> u64;
        }
        // SAFETY: a libc call with no pointers; 16 is CLOCK_THREAD_CPUTIME_ID
        unsafe { clock_gettime_nsec_np(16) }
    }
    #[cfg(not(target_vendor = "apple"))]
    0
}

// SAFETY: the raw pointers are the record's and the writer's buffers, which the tasks' order keeps
// apart: a tile's plan, coding or one-pass walk is the only task using its parts then, and its
// blocks' reconstructions touch only their own tx blocks, coefficients and samples (and read
// finished ones), between its plan and its coding.
unsafe impl<H: TxbHook> Sync for Split<'_, H> {}

impl<H: TxbHook> Split<'_, H> {
    fn task(&self, tile: usize, kind: usize) -> u32 {
        (self.n_blocks + 3 * tile + kind) as u32
    }

    /// The tile's part of the record.
    ///
    /// # Safety
    ///
    /// Only for the tile's plan, coding or one-pass walk, which nothing else runs alongside.
    unsafe fn rec(&self, j: &TileJob) -> Rec<'_> {
        Rec::Write {
            blocks: self.blocks,
            inter: self.inter,
            palette: self.palette,
            palette_map: self.palette_map,
            block_txb: self.block_txb,
            // SAFETY: (the caller's) the tile's ranges, inside the record (tile_ranges)
            txb: unsafe { core::slice::from_raw_parts_mut(self.txb.add(j.txb.0), j.txb.1 - j.txb.0) },
            txb_base: j.txb.0,
            coeffs: unsafe { core::slice::from_raw_parts_mut(self.coeffs.add(j.coeffs.0), j.coeffs.1 - j.coeffs.0) },
            coeff_base: j.coeffs.0,
        }
    }

    /// Runs tasks until every tile is coded.
    fn work(&self, w: &mut Worker) {
        let c0 = if self.prof.is_empty() { 0 } else { thread_cpu_ns() };
        let mut hs = H::Scratch::default();
        let (mut next, mut idle, mut n_fixed) = (None, 0u32, 0u64);
        let done = || self.left.load(Ordering::SeqCst) == 0;
        loop {
            let Some(task) = next.take().or_else(|| self.ready.pop()) else {
                if done() {
                    break;
                }
                idle += 1;
                self.ready.idle(idle, done);
                if idle >= 96 {
                    idle = 0;
                }
                continue;
            };
            idle = 0;
            let k = task as usize;
            let mut tc = 0;
            if !self.prof.is_empty() {
                self.prof[2 * k].store(self.t0.elapsed().as_nanos() as u64, Ordering::Relaxed);
                tc = thread_cpu_ns();
            }
            self.task_run(w, k, &mut hs, &mut n_fixed, &mut next);
            if !self.prof.is_empty() {
                self.prof[2 * k + 1].store(self.t0.elapsed().as_nanos() as u64, Ordering::Relaxed);
                let kind = if k < self.n_blocks {
                    1
                } else if (k - self.n_blocks) % 3 == TASK_PLAN {
                    0
                } else {
                    2
                };
                self.cpu[kind].fetch_add(thread_cpu_ns() - tc, Ordering::Relaxed);
            }
        }
        if !self.prof.is_empty() {
            self.cpu[3].fetch_add(thread_cpu_ns() - c0, Ordering::Relaxed);
        }
        self.n_fixed.fetch_add(n_fixed, Ordering::Relaxed);
    }

    /// One task: a block's reconstruction, a tile's plan, or its coding or one-pass walk.
    fn task_run(&self, w: &mut Worker, k: usize, hs: &mut H::Scratch, n_fixed: &mut u64, next: &mut Option<u32>) {
        if k < self.n_blocks {
            self.block(w, k, hs, n_fixed, next);
            return;
        }
        let (i, kind) = ((k - self.n_blocks) / 3, (k - self.n_blocks) % 3);
        let j = self.jobs[i].as_ref().unwrap();
        if kind == TASK_PLAN {
            self.plan(w, i, j, hs);
            return;
        }
        // SAFETY: the tile's coding or one-pass walk: its other tasks are done
        let (bufs, payload) = unsafe { (&mut *j.bufs, &mut *j.payload) };
        let syms = (!j.syms.is_null()).then(|| unsafe { &mut *j.syms });
        let mut rec = unsafe { self.rec(j) };
        let one_pass = kind == TASK_ONE_PASS;
        let f = if one_pass { &self.f } else { &self.code_f };
        let r = if self.no_code && !one_pass {
            payload.clear();
            Ok((0, 0))
        } else {
            code_tile(
                w, f, &mut rec, bufs, payload, syms, self.hook, hs, i, j.first, j.end, None, one_pass,
            )
        };
        let mut out = j.out.lock().unwrap_or_else(|e| e.into_inner());
        match r {
            Ok((s, x)) => (out.0, out.1) = (s, x),
            Err(e) => out.2 = out.2.take().or(Some(e)),
        }
        drop(out);
        if self.left.fetch_sub(1, Ordering::SeqCst) == 1 {
            self.ready.wake_all();
        }
    }

    /// Tile i's plan: its first blocks queued, or (rejected) its one-pass walk.
    fn plan(&self, w: &mut Worker, i: usize, j: &TileJob, hs: &mut H::Scratch) {
        // SAFETY: the tile's plan: its first task
        let (bufs, plan, payload) = unsafe { (&mut *j.bufs, &mut *j.plan, &mut *j.payload) };
        let mut rec = unsafe { self.rec(j) };
        let planned = code_tile(
            w,
            &self.plan_f,
            &mut rec,
            bufs,
            payload,
            None,
            self.hook,
            hs,
            i,
            j.first,
            j.end,
            Some(&mut *plan),
            true,
        );
        // a tile the plan rejects, or whose tx blocks can't own their coefficients, is coded in
        // one pass (which fails where the walk does)
        if planned.is_err() || !plan.ok {
            self.ready.push(self.task(i, TASK_ONE_PASS));
            return;
        }
        #[cfg(test)]
        super::recon::SPLIT.fetch_add(1, Ordering::Relaxed);
        for (p, v) in bufs.plane.iter_mut().enumerate() {
            j.planes[p].store(v.as_mut_ptr(), Ordering::Relaxed);
            j.lens[p].store(v.len(), Ordering::Relaxed);
        }
        let n = j.end - j.first;
        j.left.store(n, Ordering::Relaxed);
        if n == 0 {
            self.ready.push(self.task(i, TASK_CODE));
        }
        for &b in &plan.roots {
            self.ready.push(j.first + b);
        }
    }

    /// Block k's reconstruction; the readers it was the last wait of queued (one into `next`),
    /// and after the tile's last block its coding.
    fn block(&self, w: &mut Worker, k: usize, hs: &mut H::Scratch, n_fixed: &mut u64, next: &mut Option<u32>) {
        let i = self.tile_first.partition_point(|&s| s as usize <= k) - 1;
        let j = self.jobs[i].as_ref().unwrap();
        // SAFETY: planned (the plan queued the tile's first blocks after it finished), and nothing
        // writes the plan or the maps until the tile's coding, after its last block
        let (bufs, plan) = unsafe { (&*j.bufs, &*j.plan) };
        let t = ReconTile {
            planes: core::array::from_fn(|p| j.planes[p].load(Ordering::Relaxed)),
            lens: core::array::from_fn(|p| j.lens[p].load(Ordering::Relaxed)),
            bufs,
            plan,
        };
        let rec = ReconRec {
            blocks: self.blocks,
            palette: self.palette,
            palette_map: self.palette_map,
            block_txb: self.block_txb,
            txb: self.txb,
            coeffs: self.coeffs,
        };
        // SAFETY: block k is queued once, after the blocks it reads (their waits' AcqRel
        // decrements and the queue order their writes before this); its tx blocks, coefficients
        // and samples are its own; the plan's walk checked them
        let r = unsafe { recon_block(&self.f, self.hook, rec, t, k, &mut w.rb, hs, n_fixed) };
        if let Err(e) = r {
            // (not reached: a split tile's reconstruction can't fail)
            let mut out = j.out.lock().unwrap_or_else(|e| e.into_inner());
            out.2 = out.2.take().or(Some(e));
        }
        for &m in plan.readers(k - plan.first) {
            if plan.waits[m as usize].fetch_sub(1, Ordering::AcqRel) == 1 {
                let m = j.first + m;
                match next {
                    None => *next = Some(m),
                    Some(_) => self.ready.push(m),
                }
            }
        }
        if j.left.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.ready.push(self.task(i, TASK_CODE));
        }
    }
}

/// GA_CRIT: the split picture's wall time, work and critical path (plan, then its blocks by their
/// reads, then its coding), on stderr.
fn crit_report<H: TxbHook>(sp: &Split<'_, H>, prof: &[AtomicU64], ntiles: usize) {
    let t = |k: usize| {
        (
            prof[2 * k].load(Ordering::Relaxed),
            prof[2 * k + 1].load(Ordering::Relaxed),
        )
    };
    let d = |k: usize| {
        let (a, b) = t(k);
        b.saturating_sub(a)
    };
    let (mut lo, mut hi, mut work) = (u64::MAX, 0u64, 0u64);
    let (mut wplan, mut wblk, mut wcode) = (0u64, 0u64, 0u64);
    let mut cp = 0u64;
    let (mut cp_plan, mut cp_rec, mut cp_code) = (0u64, 0u64, 0u64);
    let mut longest_block = 0u64;
    for i in 0..ntiles {
        let Some(j) = sp.jobs[i].as_ref() else { continue };
        // SAFETY: every task is done (the pool returned), so nothing writes the plan
        let plan = unsafe { &*j.plan };
        let tp = sp.task(i, TASK_PLAN) as usize;
        let tc = sp.task(i, TASK_CODE) as usize;
        for k in [tp, tc] {
            let (a, b) = t(k);
            if b > 0 {
                lo = lo.min(a);
                hi = hi.max(b);
            }
        }
        let (pd, cd) = (d(tp), d(tc));
        wplan += pd;
        wcode += cd;
        let (first, n) = (j.first as usize, (j.end - j.first) as usize);
        let mut es = vec![pd; n];
        let mut rmax = pd;
        for b in 0..n {
            let k = first + b;
            let (a, e) = t(k);
            lo = lo.min(a);
            hi = hi.max(e);
            let bd = e.saturating_sub(a);
            wblk += bd;
            longest_block = longest_block.max(bd);
            let ef = es[b] + bd;
            rmax = rmax.max(ef);
            for &m in plan.readers(b) {
                let m = m as usize;
                es[m] = es[m].max(ef);
            }
        }
        let tcp = rmax + cd;
        if tcp > cp {
            cp = tcp;
            cp_plan = pd;
            cp_rec = rmax - pd;
            cp_code = cd;
        }
    }
    work += wplan + wblk + wcode;
    let wall = hi.saturating_sub(lo);
    let ms = |x: u64| x as f64 / 1e6;
    let cpu = |k: usize| ms(sp.cpu[k].load(Ordering::Relaxed));
    eprintln!(
        "cpu: plan {:.2} blocks {:.2} code {:.2} all {:.2} (ms of thread CPU)",
        cpu(0),
        cpu(1),
        cpu(2),
        cpu(3)
    );
    eprintln!(
        "crit: wall {:.2} ms, work {:.2} (plan {:.2} blocks {:.2} code {:.2}), {:.1} busy, critical path {:.2} (plan {:.2} + blocks {:.2} + code {:.2}), longest block {:.3}, tiles {}",
        ms(wall),
        ms(work),
        ms(wplan),
        ms(wblk),
        ms(wcode),
        work as f64 / wall.max(1) as f64,
        ms(cp),
        ms(cp_plan),
        ms(cp_rec),
        ms(cp_code),
        ms(longest_block),
        ntiles
    );
}

fn check_frame(fp: &FrameParams) -> Res<()> {
    if fp.version != DECISIONS_VERSION && fp.version != 1 {
        fail!(ERR_INVALID, "record version {} (1 or {DECISIONS_VERSION})", fp.version);
    }
    if fp.width < 1 || fp.height < 1 || fp.width > 65535 || fp.height > 65535 {
        fail!(ERR_INVALID, "bad size {}x{}", fp.width, fp.height);
    }
    if fp.base_q_idx < 1 {
        fail!(ERR_INVALID, "base_q_idx must be >= 1 (lossless unsupported)");
    }
    if fp.monochrome > 1 || fp.tx_mode_select > 1 || fp.reduced_tx_set > 1 {
        fail!(ERR_INVALID, "bad frame flags");
    }
    let dqs = [
        fp.delta_q_y_dc,
        fp.delta_q_u_dc,
        fp.delta_q_u_ac,
        fp.delta_q_v_dc,
        fp.delta_q_v_ac,
    ];
    if dqs.iter().any(|&d| !(-64..=63).contains(&d)) {
        fail!(ERR_INVALID, "delta_q out of range");
    }
    if fp.enable_filter_intra > 1 || fp.enable_intra_edge_filter > 1 {
        fail!(
            ERR_INVALID,
            "enable_filter_intra / enable_intra_edge_filter must be 0/1"
        );
    }
    if fp.loop_filter_level.iter().any(|&l| l > 63) {
        fail!(ERR_INVALID, "loop_filter_level > 63");
    }
    if fp.loop_filter_sharpness > 7 {
        fail!(ERR_INVALID, "loop_filter_sharpness > 7");
    }
    let lf = fp.loop_filter_level;
    if lf[0] == 0 && lf[1] == 0 && (lf[2] != 0 || lf[3] != 0) {
        fail!(
            ERR_INVALID,
            "chroma loop filter levels need a nonzero luma level (spec loop_filter_params)"
        );
    }
    if fp.enable_cdef > 1 || fp.cdef_damping_minus_3 > 3 || fp.cdef_bits > 3 {
        fail!(ERR_INVALID, "bad CDEF parameters");
    }
    let sec_ok = |v: u8| matches!(v, 0 | 1 | 2 | 4);
    for i in 0..8 {
        if fp.cdef_y_pri[i] > 15 || fp.cdef_uv_pri[i] > 15 || !sec_ok(fp.cdef_y_sec[i]) || !sec_ok(fp.cdef_uv_sec[i]) {
            fail!(ERR_INVALID, "CDEF strengths: pri 0..15, sec 0/1/2/4");
        }
    }
    if fp.delta_q_present > 1
        || fp.delta_q_res > 3
        || fp.using_qmatrix > 1
        || fp.qm_y > 15
        || fp.qm_u > 15
        || fp.qm_v > 15
    {
        fail!(ERR_INVALID, "bad delta_q / quantizer matrix parameters");
    }
    if fp.allow_screen_content_tools > 1 {
        fail!(ERR_INVALID, "allow_screen_content_tools must be 0/1");
    }
    if fp.allow_intrabc > 1
        || (fp.allow_intrabc != 0
            && (fp.frame_type != FRAME_KEY || fp.allow_screen_content_tools != 1 || fp.loop_filter_level != [0; 4]))
    {
        fail!(
            ERR_INVALID,
            "allow_intrabc must be 0/1, and 1 only in a key frame with allow_screen_content_tools and no deblocking"
        );
    }
    // v2: video mode (in v1 these were reserved bytes, which must be 0)
    let v2 = [
        fp.video,
        fp.frame_type,
        fp.ref_slot,
        fp.refresh_frame_flags,
        fp.error_resilient_mode,
        fp.lf_inter_off,
        fp.cdf_from_ref,
        fp.mv_precision,
        fp.sb128,
        (fp.stream_width | fp.stream_height != 0) as u8,
        fp.golden_slot,
    ];
    if fp.version == 1 && v2.iter().any(|&r| r != 0) {
        fail!(ERR_INVALID, "reserved frame_params fields must be 0 in interface v1");
    }
    if fp.video > 1 || fp.frame_type > FRAME_INTER {
        fail!(ERR_INVALID, "video must be 0/1, frame_type key or inter");
    }
    if fp.sb128 > 1 {
        fail!(ERR_INVALID, "sb128 must be 0/1");
    }
    if fp.video == 0 && fp.frame_type != FRAME_KEY {
        fail!(ERR_INVALID, "inter frames need video mode");
    }
    if (fp.stream_width != 0 || fp.stream_height != 0)
        && (fp.video == 0
            || (fp.stream_width as u32) < fp.width
            || (fp.stream_height as u32) < fp.height)
    {
        fail!(
            ERR_INVALID,
            "stream_width/height (reduced frames) need video mode and a stream at least the frame's size"
        );
    }
    if fp.frame_type == FRAME_KEY {
        if fp.ref_slot != 0
            || fp.refresh_frame_flags != 0
            || fp.error_resilient_mode != 0
            || fp.lf_inter_off != 0
            || fp.cdf_from_ref != 0
            || fp.mv_precision != 0
            || fp.golden_slot != 0
        {
            fail!(
                ERR_INVALID,
                "key frames refresh every slot: ref_slot, refresh_frame_flags, error_resilient_mode, lf_inter_off, cdf_from_ref, mv_precision and golden_slot must be 0"
            );
        }
    } else {
        if fp.ref_slot > 7
            || fp.golden_slot > 8
            || fp.error_resilient_mode > 1
            || fp.lf_inter_off > 1
            || fp.cdf_from_ref > 1
            || fp.mv_precision > 2
        {
            fail!(
                ERR_INVALID,
                "ref_slot must be 0..7, golden_slot 0..8, error_resilient_mode, lf_inter_off and cdf_from_ref 0/1, mv_precision 0..2"
            );
        }
        if fp.cdf_from_ref != 0 && fp.error_resilient_mode != 0 {
            fail!(
                ERR_INVALID,
                "cdf_from_ref needs error_resilient_mode 0 (which codes primary_ref_frame NONE)"
            );
        }
        if fp.mv_precision == 0 && fp.allow_screen_content_tools != 1 {
            fail!(
                ERR_INVALID,
                "whole-sample inter frames (mv_precision 0) need allow_screen_content_tools = 1 (it carries force_integer_mv)"
            );
        }
    }
    Ok(())
}

/// A reference's planes for an inter frame: slot `slot`'s, checked against the picture size.
fn ref_planes<'a>(fp: &FrameParams, refs: Option<&RefSlots<'a>>, slot: u8) -> Res<[RefPlane<'a>; 3]> {
    let Some(r) = refs.and_then(|r| r[slot as usize]) else {
        fail!(ERR_INVALID, "inter frame: reference slot {slot} is empty");
    };
    let mut out = [RefPlane {
        data: &[],
        stride: 0,
        w: 0,
        h: 0,
    }; 3];
    for p in 0..if fp.monochrome != 0 { 1 } else { 3 } {
        let sub = (p != 0) as u32;
        let (w, h) = ((fp.width + sub) >> sub, (fp.height + sub) >> sub);
        let (data, stride) = (r.plane[p], r.stride[p]);
        if stride < w as usize || data.len() < (h as usize - 1) * stride + w as usize {
            fail!(
                ERR_INVALID,
                "reference slot {slot} plane {p}: {} samples at stride {stride} don't hold {w}x{h}",
                data.len()
            );
        }
        out[p] = RefPlane {
            data,
            stride,
            w: w as i32,
            h: h as i32,
        };
    }
    Ok(out)
}

/// The tx-block and coefficient ranges of each tile, if they are ordered and disjoint (always so
/// for a layout from [`super::layout`]): then the tiles can own their parts of the record's arrays
/// and run in parallel, exactly as they run one after the other. Per tile: (txb start, txb end,
/// coefficient start, coefficient end).
fn tile_ranges(
    block_txb: &[u32],
    tile_first: &[u32],
    txb: &[Txb],
    n_coeffs: usize,
    coded: impl Fn(usize) -> bool,
    out: &mut Vec<(usize, usize, usize, usize)>,
) -> bool {
    out.clear();
    // every block's tx blocks inside its tile's
    if block_txb.windows(2).any(|w| w[1] < w[0]) || *block_txb.last().unwrap() as usize > txb.len() {
        return false;
    }
    let mut prev_c = 0usize;
    for i in 0..tile_first.len() - 1 {
        let (t0, t1) = (
            block_txb[tile_first[i] as usize] as usize,
            block_txb[tile_first[i + 1] as usize] as usize,
        );
        let (mut lo, mut hi) = (usize::MAX, 0usize);
        if coded(i) {
            for t in &txb[t0..t1] {
                if (t.tx_size as i32) < TX_SIZES_ALL {
                    let o = t.coeff_off as usize;
                    lo = lo.min(o);
                    hi = hi.max(o + tx_coeffs(t.tx_size as i32));
                }
            }
        }
        if lo == usize::MAX {
            (lo, hi) = (prev_c, prev_c);
        }
        if lo < prev_c || hi > n_coeffs {
            return false;
        }
        prev_c = hi;
        out.push((t0, t1, lo, hi));
    }
    true
}

impl Writer {
    pub fn new() -> Writer {
        Self::with_threads(0)
    }

    /// A writer coding tiles on at most `threads` threads (0: the available parallelism).
    pub fn with_threads(threads: usize) -> Writer {
        let threads = if threads == 0 {
            std::thread::available_parallelism().map_or(1, |n| n.get())
        } else {
            threads
        };
        Writer {
            workers: Vec::new(),
            tiles: Vec::new(),
            payloads: Vec::new(),
            syms: Vec::new(),
            ordmap: Default::default(),
            tile_first: Vec::new(),
            ranges: Vec::new(),
            frame: FrameBufs::default(),
            cdef_out: Default::default(),
            saved: Mutex::new((false, Box::new(FrameCdfs::new(0)))),
            tile_order: Vec::new(),
            plans: Vec::new(),
            ready: Ready::default(),
            block_bits: Vec::new(),
            seq: BitWriter::default(),
            fh: BitWriter::default(),
            threads,
        }
    }

    /// Block `k`'s bits in the last encode with [`ENC_BLOCK_BITS`].
    pub fn block_bits(&self, k: usize) -> f32 {
        f32::from_bits(self.block_bits[k].load(Ordering::Relaxed))
    }

    /// The tile payloads of the last successful encode (raster order; a skipped tile's as given).
    pub fn tile_payloads(&self) -> &[Vec<u8>] {
        &self.payloads
    }

    /// The packed symbol streams (symstream) of the last encode with [`Extras::record_syms`] (raster
    /// order; empty for skipped tiles).
    pub fn tile_syms(&self) -> &[Vec<u32>] {
        &self.syms
    }

    /// av1g_encode: the record must have a valid layout ([`super::layout`]). On success the record's
    /// txb eob and chroma tx_type are written (the luma tx_type of all-zero tx blocks becomes
    /// DCT_DCT, as the spec has it); with [`ENC_FIX_RANGE`] offending coefficients are halved in
    /// place. `out` is overwritten (cleared on error).
    pub fn encode(&mut self, rec: RecordMut, opts: &EncodeOpts, out: &mut Output) -> Result<(), Error> {
        self.encode_with_hook::<NoHook>(rec, opts, None, &Extras::default(), out)
    }

    /// av1g_encode_ex: [`Writer::encode`] with the reference pictures (inter frames).
    pub fn encode_ex(
        &mut self,
        rec: RecordMut,
        opts: &EncodeOpts,
        refs: &RefSlots,
        out: &mut Output,
    ) -> Result<(), Error> {
        let extras = Extras {
            refs: Some(refs),
            ..Extras::default()
        };
        self.encode_with_hook::<NoHook>(rec, opts, None, &extras, out)
    }

    /// av1g::encode_with_hook: [`Writer::encode`] with the closed-loop hook, tile skips and the
    /// per-tile symbol streams.
    pub fn encode_with_hook<H: TxbHook>(
        &mut self,
        rec: RecordMut,
        opts: &EncodeOpts,
        hook: Option<&H>,
        extras: &Extras,
        out: &mut Output,
    ) -> Result<(), Error> {
        self.encode_into(rec, opts, hook, extras, None, out)
    }

    /// [`Writer::encode_with_hook`] with [`ENC_PREFILTER_RECON`]'s reconstruction written into
    /// the caller's planes (`recon_into`: each at least MiCols * 4 x MiRows * 4 samples, chroma half
    /// each way, rows that wide), not `out.recon`, which stays empty (`recon_w` and `recon_h` are
    /// set). The samples outside the decoded area are left as they were.
    pub fn encode_into<H: TxbHook>(
        &mut self,
        mut rec: RecordMut,
        opts: &EncodeOpts,
        hook: Option<&H>,
        extras: &Extras,
        recon_into: Option<[&mut [u8]; 3]>,
        out: &mut Output,
    ) -> Result<(), Error> {
        out.clear();
        let r = self.run(&mut rec, opts, hook, extras, recon_into, out);
        r.map_err(|e| {
            out.clear();
            *e
        })
    }

    fn run<H: TxbHook>(
        &mut self,
        rec: &mut RecordMut,
        opts: &EncodeOpts,
        hook: Option<&H>,
        extras: &Extras,
        recon_into: Option<[&mut [u8]; 3]>,
        out: &mut Output,
    ) -> Res<()> {
        let fp = rec.fp;
        check_frame(&fp)?;
        let do_recon = opts.flags & ENC_SKIP_RECON == 0;
        let fix_range = opts.flags & ENC_FIX_RANGE != 0;
        let n_blocks = rec.blocks.len();
        if rec.block_txb.len() < n_blocks + 1 {
            fail!(ERR_INVALID, "record arrays missing");
        }
        if rec.block_txb[n_blocks] as usize != rec.txb.len() {
            fail!(ERR_INVALID, "layout stale (call av1g_layout)");
        }
        if !rec.inter.is_empty() && rec.inter.len() != n_blocks {
            fail!(ERR_INVALID, "{} inter entries for {n_blocks} blocks", rec.inter.len());
        }
        if !rec.palette.is_empty() && rec.palette.len() != n_blocks {
            fail!(
                ERR_INVALID,
                "{} palette entries for {n_blocks} blocks",
                rec.palette.len()
            );
        }
        let inter = fp.frame_type == FRAME_INTER;
        let intrabc = fp.allow_intrabc != 0;
        if (inter || intrabc) && extras.record_syms {
            fail!(
                ERR_INVALID,
                "symbol streams are for intra frames without intra block copy only"
            );
        }
        if extras.record_syms && rec.palette.iter().any(|p| p.size_y != 0 || p.size_uv != 0) {
            fail!(
                ERR_INVALID,
                "symbol streams have no palette syntax (the GPU entropy coder's)"
            );
        }
        let sb128 = fp.sb128 != 0;
        if sb128 && extras.record_syms {
            fail!(
                ERR_INVALID,
                "symbol streams are for 64x64 superblocks only (the GPU entropy coder's)"
            );
        }
        let seq_header = opts.flags & ENC_NO_SEQ_HEADER == 0;
        if !seq_header && (fp.video == 0 || opts.flags & ENC_AVIF != 0) {
            fail!(
                ERR_INVALID,
                "ENC_NO_SEQ_HEADER is for frames of a video stream (not still pictures or AVIF)"
            );
        }
        let refs = if inter && do_recon {
            Some(ref_planes(&fp, extras.refs, fp.ref_slot)?)
        } else {
            None
        };
        // GOLDEN_FRAME's: its own slot's, or LAST_FRAME's
        let refs_golden = if inter && do_recon && fp.golden_slot != 0 {
            Some(ref_planes(&fp, extras.refs, fp.golden_slot - 1)?)
        } else {
            refs
        };
        let (w, h) = (fp.width, fp.height);
        let mono = fp.monochrome != 0;
        let (mi_cols, mi_rows) = (mi_cols(w as i32), mi_rows(h as i32));
        let (sb_cols, sb_rows) = ((mi_cols + 15) >> 4, (mi_rows + 15) >> 4);
        let mut tiles = TileInfo::default();
        if !compute_tiles(
            w,
            h,
            fp.tile_cols_log2 as i32,
            fp.tile_rows_log2 as i32,
            sb128,
            &mut tiles,
        ) {
            fail!(
                ERR_INVALID,
                "illegal tiling {}/{} for {w}x{h}",
                fp.tile_cols_log2,
                fp.tile_rows_log2
            );
        }
        let nplanes = if mono { 1 } else { 3 };
        // (txb_edges models 64x64 superblocks: the GPU's)
        let check_edges = opts.flags & ENC_CHECK_EDGES != 0 && !sb128;
        if check_edges {
            for p in 0..nplanes {
                let sub = (p != 0) as i32;
                let (stride, rows) = (((sb_cols * 16) >> sub) as usize, ((sb_rows * 16) >> sub) as usize);
                self.ordmap[p].clear();
                self.ordmap[p].resize(stride * rows, u32::MAX);
            }
            for (i, x) in rec.txb.iter().enumerate() {
                if x.plane as usize >= nplanes || x.tx_size as i32 >= TX_SIZES_ALL {
                    continue;
                }
                let sub = (x.plane != 0) as i32;
                let (stride, rows) = (((sb_cols * 16) >> sub) as usize, ((sb_rows * 16) >> sub) as usize);
                let (w4, h4) = (
                    tx_w(x.tx_size as i32) as usize >> 2,
                    tx_h(x.tx_size as i32) as usize >> 2,
                );
                let m = &mut self.ordmap[x.plane as usize];
                for yy in 0..h4 {
                    let y = x.y4 as usize + yy;
                    if y >= rows {
                        break;
                    }
                    for xx in 0..w4 {
                        let xp = x.x4 as usize + xx;
                        if xp >= stride {
                            break;
                        }
                        m[y * stride + xp] = i as u32;
                    }
                }
            }
        }
        let qm_level = [
            fp.qm_y as i32,
            fp.qm_u as i32,
            if !mono && fp.using_qmatrix != 0 {
                fp.qm_v
            } else {
                fp.qm_u
            } as i32,
        ];

        // ---- tiles ----
        // Every tile's blocks: all blocks whose position is inside it, contiguous in tile order.
        let ntiles = (tiles.rows * tiles.cols) as usize;
        self.tile_first.clear();
        let mut cursor = 0usize;
        for tr in 0..tiles.rows as usize {
            for tc in 0..tiles.cols as usize {
                self.tile_first.push(cursor as u32);
                let (r0, r1) = (tiles.mi_row_starts[tr], tiles.mi_row_starts[tr + 1]);
                let (c0, c1) = (tiles.mi_col_starts[tc], tiles.mi_col_starts[tc + 1]);
                while cursor < n_blocks {
                    let b = &rec.blocks[cursor];
                    let (br, bc) = (b.mi_row as u32, b.mi_col as u32);
                    if br < r0 || br >= r1 || bc < c0 || bc >= c1 {
                        break;
                    }
                    cursor += 1;
                }
            }
        }
        self.tile_first.push(cursor as u32);
        if cursor != n_blocks {
            fail!(ERR_INVALID, "block {cursor} is outside the expected tile order");
        }
        let skip = extras.tile_skip;
        if let Some(s) = skip
            && s.len() != ntiles
        {
            fail!(ERR_INVALID, "tile skip list of {} for {ntiles} tiles", s.len());
        }
        let skipped = |i: usize| skip.is_some_and(|s| s[i].skip);
        let ncoded = (0..ntiles).filter(|&i| !skipped(i)).count();
        // the frame's CDFs: its reference's saved ones, or the defaults
        let cdfs_in = if inter && fp.cdf_from_ref != 0 {
            match extras.refs.and_then(|r| r[fp.ref_slot as usize]).and_then(|r| r.cdfs) {
                Some(c) => Some(c),
                None => fail!(
                    ERR_INVALID,
                    "cdf_from_ref: reference slot {} has no saved CDFs",
                    fp.ref_slot
                ),
            }
        } else {
            None
        };
        // In video mode the frame saves the CDFs of its median tile by block count (ties: the lower
        // index), which on screen content is neither an all-skip tile nor the busiest: smaller inter
        // frames than libaom's largest tile, by up to 22 % at 5K (BENCHMARKS). Whether tiles are
        // reused doesn't change it: a reused tile's CDFs aren't known, and none are saved then. A still
        // picture names tile 0.
        let mut context_tile = 0usize;
        if fp.video != 0 {
            let order = &mut self.tile_order;
            order.clear();
            order.extend((0..ntiles).map(|i| (self.tile_first[i + 1] - self.tile_first[i], i)));
            order.sort_unstable();
            context_tile = order[ntiles / 2].1;
        }
        self.saved.get_mut().unwrap().0 = false;
        let f = Frame {
            fp,
            mi_cols,
            mi_rows,
            mono,
            sb_cols,
            sb_rows,
            tiles,
            qm_level,
            do_recon,
            fix_range,
            check_edges,
            ordmap: &self.ordmap,
            inter,
            intrabc,
            refs,
            refs_golden,
            cdfs_in,
            cdfs_out: (fp.video != 0).then_some(&self.saved),
            context_tile,
            sb128,
            palettes: !rec.palette.is_empty(),
            block_bits: (opts.flags & ENC_BLOCK_BITS != 0).then(|| {
                if self.block_bits.len() < n_blocks {
                    self.block_bits.resize_with(n_blocks, || AtomicU32::new(0));
                }
                &self.block_bits[..n_blocks]
            }),
        };

        if self.tiles.len() < ntiles {
            self.tiles.resize_with(ntiles, TileBufs::default);
        }
        self.payloads.resize_with(ntiles.max(self.payloads.len()), Vec::new);
        self.payloads.truncate(ntiles);
        self.syms.resize_with(ntiles.max(self.syms.len()), Vec::new);
        self.syms.truncate(if extras.record_syms { ntiles } else { 0 });
        for s in &mut self.syms {
            s.clear();
        }
        let need_planes = do_recon && opts.flags & ENC_NO_RECON == 0;
        for i in 0..ntiles {
            if let Some(s) = skip
                && s[i].skip
            {
                // the caller has this tile
                self.payloads[i].clear();
                if let Some(p) = s[i].payload {
                    self.payloads[i].extend_from_slice(p);
                }
                let cols = tiles.cols as usize;
                self.tiles[i].setup(&f, i / cols, i % cols, need_planes);
                self.tiles[i].zero_planes(nplanes);
            }
        }

        let nworkers = if ntiles > 1 { ncoded.min(self.threads).max(1) } else { 1 };
        if self.workers.len() < nworkers {
            self.workers.resize_with(nworkers, Worker::default);
        }
        for w in &mut self.workers[..nworkers] {
            w.st.setup(mi_cols, mi_rows);
        }
        let ordered = tile_ranges(
            rec.block_txb,
            &self.tile_first,
            rec.txb,
            rec.coeffs.len(),
            |i| !skipped(i),
            &mut self.ranges,
        );
        let parallel = nworkers > 1 && ordered;
        let ranges = parallel.then_some(&self.ranges[..]);
        // With a reconstruction on several threads, the blocks are reconstructed on all of them
        // apart from their coding ([`super::recon`]): plan, reconstruct, code.
        let split = do_recon
            && fix_range
            && H::KEEPS_TX_SETS
            && ordered
            && self.threads > 1
            && opts.flags & ENC_ONE_PASS == 0
            && ncoded > 0;
        let coded = if split {
            // every coded tile planned, its blocks reconstructed, coded, on every thread
            let nthreads = self.threads;
            if self.workers.len() < nthreads {
                self.workers.resize_with(nthreads, Worker::default);
            }
            for w in &mut self.workers[nworkers..nthreads] {
                w.st.setup(mi_cols, mi_rows);
            }
            self.plans.resize_with(ntiles.max(self.plans.len()), TilePlan::default);
            self.ready.reset(n_blocks + 3 * ntiles);
            let (txb, coeffs) = (rec.txb.as_mut_ptr(), rec.coeffs.as_mut_ptr());
            let mut syms = self.syms.iter_mut();
            let jobs: Vec<Option<TileJob>> = self
                .tiles
                .iter_mut()
                .zip(&mut self.plans)
                .zip(&mut self.payloads)
                .zip(&self.ranges)
                .take(ntiles)
                .enumerate()
                .map(|(i, (((bufs, plan), payload), &(t0, t1, c0, c1)))| {
                    let syms = syms.next();
                    (!skipped(i)).then(|| TileJob {
                        first: self.tile_first[i],
                        end: self.tile_first[i + 1],
                        bufs,
                        plan,
                        payload,
                        syms: syms.map_or(core::ptr::null_mut(), |s| s as *mut _),
                        txb: (t0, t1),
                        coeffs: (c0, c1),
                        planes: Default::default(),
                        lens: Default::default(),
                        left: AtomicU32::new(0),
                        out: Mutex::new((0, 0, None)),
                    })
                })
                .collect();
            // GA_CRIT: each split picture's critical path on stderr (diagnostics)
            static CRIT: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
            let crit = *CRIT.get_or_init(|| std::env::var_os("GA_CRIT").is_some());
            let prof: Vec<AtomicU64> = if crit {
                (0..2 * (n_blocks + 3 * ntiles)).map(|_| AtomicU64::new(0)).collect()
            } else {
                Vec::new()
            };
            let sp = Split {
                f,
                plan_f: Frame {
                    do_recon: false,
                    cdfs_out: None,
                    ..f
                },
                code_f: Frame { do_recon: false, ..f },
                hook,
                blocks: rec.blocks,
                inter: rec.inter,
                palette: rec.palette,
                palette_map: rec.palette_map,
                block_txb: rec.block_txb,
                txb,
                coeffs,
                jobs: &jobs,
                tile_first: &self.tile_first,
                n_blocks,
                ready: &self.ready,
                left: AtomicUsize::new(ncoded),
                n_fixed: AtomicU64::new(0),
                no_code: opts.flags & ENC_NO_CODE != 0,
                prof: &prof,
                t0: std::time::Instant::now(),
                cpu: Default::default(),
            };
            for i in 0..ntiles {
                if !skipped(i) {
                    sp.ready.push(sp.task(i, TASK_PLAN));
                }
            }
            crate::pool::each(&mut self.workers[..nthreads], |w| sp.work(w));
            if crit {
                crit_report(&sp, &prof, ntiles);
            }
            // the first error in tile order, as sequential coding reports
            let (mut nsym, mut nfixed) = (0, sp.n_fixed.into_inner());
            for j in jobs.into_iter().flatten() {
                let (s, x, e) = j.out.into_inner().unwrap_or_else(|e| e.into_inner());
                if let Some(e) = e {
                    return Err(e);
                }
                nsym += s;
                nfixed += x;
            }
            Some((nsym, nfixed))
        } else {
            None
        };
        let (nsym, nfixed) = match coded {
            Some(c) => c,
            None => code_tiles(
                &mut self.workers[..nworkers],
                &mut self.tiles[..ntiles],
                &mut self.payloads,
                &mut self.syms,
                None,
                ranges,
                &self.tile_first,
                rec,
                &f,
                hook,
                &skipped,
                f.do_recon,
            )?,
        };

        let level = (opts.seq_level_idx >= 0).then_some(opts.seq_level_idx);
        let mut tiles_hdr = tiles;
        let context_tile = f.context_tile as u32;
        {
            let g = self.saved.lock().unwrap();
            match (g.0, &mut out.saved_cdfs) {
                (true, Some(b)) => b.clone_from(&g.1),
                (true, o) => *o = Some(g.1.clone()),
                (false, o) => *o = None,
            }
        }
        let (tile_bytes, level) = frame_obus(
            &fp,
            &mut tiles_hdr,
            context_tile,
            level,
            &self.payloads,
            opts.flags & ENC_TD != 0,
            seq_header,
            &mut self.seq,
            &mut self.fh,
            &mut out.obu,
        );
        out.seq_level_idx = level as u32;
        out.tile_cols = tiles.cols;
        out.tile_rows = tiles.rows;
        out.tile_bytes = tile_bytes;
        out.header_bytes = (out.obu.len() as u64 - tile_bytes) as u32;
        out.n_symbols = nsym;
        out.n_fixed_txb = nfixed as u32;
        if opts.flags & ENC_AVIF != 0 {
            // AVIF item data never carries a temporal delimiter
            let skip = if opts.flags & ENC_TD != 0 { 2 } else { 0 };
            match crate::avif::mux_avif(&out.obu[skip..], w, h) {
                Ok(a) => out.avif = a,
                Err(_) => fail!(ERR_INTERNAL, "AVIF mux failed"),
            }
        }
        if need_planes {
            recon(
                &mut self.tiles,
                &mut self.frame,
                &mut self.cdef_out,
                &f,
                ntiles,
                opts.flags & ENC_PREFILTER_RECON != 0,
                self.threads,
                recon_into,
                out,
            );
        }
        Ok(())
    }
}

/// The reconstruction outputs: the padded pre-filter frame, or the post-filtered, cropped one.
fn recon(
    tiles: &mut [TileBufs],
    frame: &mut FrameBufs,
    cdef_out: &mut [Vec<u8>; 3],
    f: &Frame,
    ntiles: usize,
    prefilter: bool,
    threads: usize,
    recon_into: Option<[&mut [u8]; 3]>,
    out: &mut Output,
) {
    let fp = &f.fp;
    let nplanes = if f.mono { 1 } else { 3 };
    if prefilter {
        // straight from the tiles: the decoded area up to MiCols * 4 x MiRows * 4 (the filters
        // read it), in bands of rows on several threads (22 MB at 5K: 1.3 ms on one), into
        // `out.recon` or the caller's planes
        let tiles = &tiles[..ntiles];
        let mut bands: Vec<(usize, usize, &mut [u8])> = Vec::new();
        let mut into = recon_into.map(|p| p.into_iter());
        for (p, o) in out.recon.iter_mut().enumerate().take(nplanes) {
            let sub = (p != 0) as usize;
            let (w, h) = ((f.mi_cols as usize * 4) >> sub, (f.mi_rows as usize * 4) >> sub);
            out.recon_w[p] = w as u32;
            out.recon_h[p] = h as u32;
            let plane: &mut [u8] = match into.as_mut().and_then(Iterator::next) {
                Some(d) => &mut d[..w * h],
                None => {
                    o.resize(w * h, 0);
                    o
                }
            };
            let rows = h.div_ceil(threads.clamp(1, 8)).max(16);
            for (k, band) in plane.chunks_mut(rows * w).enumerate() {
                bands.push((p, k * rows, band));
            }
        }
        let copy = |(p, y0, band): &mut (usize, usize, &mut [u8])| {
            let sub = (*p != 0) as usize;
            let w = (f.mi_cols as usize * 4) >> sub;
            let (b0, b1) = (*y0, *y0 + band.len() / w);
            for t in tiles {
                let (x0, ty0) = ((t.c0 as usize * 4) >> sub, (t.r0 as usize * 4) >> sub);
                let (tw, th) = ((t.mw as usize * 4) >> sub, (t.mh as usize * 4) >> sub);
                let s = t.stride[*p];
                for y in b0.max(ty0)..b1.min(ty0 + th) {
                    band[(y - b0) * w + x0..][..tw].copy_from_slice(&t.plane[*p][(y - ty0) * s..][..tw]);
                }
            }
        };
        if threads <= 1 || bands.len() <= 1 {
            bands.iter_mut().for_each(copy);
        } else {
            crate::pool::each(&mut bands, copy);
        }
        return;
    }
    let pstride: [usize; 3] = core::array::from_fn(|p| ((f.sb_cols as usize) * 64) >> (p != 0) as usize);
    let pheight: [usize; 3] = core::array::from_fn(|p| ((f.sb_rows as usize) * 64) >> (p != 0) as usize);
    let (mc, mr) = (f.mi_cols as usize, f.mi_rows as usize);
    // the post-filters' skip map: with lf_inter_off, inter blocks' level is 0; with 128x128
    // superblocks, skipped inter blocks larger than 64x64 have unfiltered tx edges inside
    let lf_off = f.inter && fp.lf_inter_off != 0;
    let inner = f.inter && f.sb128;
    let mut pf_skip = core::mem::take(&mut frame.pf_skip);
    if lf_off || inner {
        pf_skip.clear();
        pf_skip.resize(mr * mc, 0);
        let flags = if lf_off {
            PF_BLK_LF_ZERO | PF_BLK_INTER
        } else {
            PF_BLK_INTER
        };
        for t in &tiles[..ntiles] {
            let (c0, r0, mw, mh) = (t.c0 as usize, t.r0 as usize, t.mw as usize, t.mh as usize);
            for y in 0..mh {
                for (x, d) in pf_skip[(r0 + y) * mc + c0..][..mw].iter_mut().enumerate() {
                    let k = y * mw + x;
                    *d = if t.ref0[k] as i32 == LAST_FRAME || t.ref0[k] == crate::types::GOLDEN {
                        pf_skip_value(t.skip[k] != 0, flags, t.mi_size[k] as i32)
                    } else {
                        t.skip[k]
                    };
                }
            }
        }
    }
    // the frame: one tile's buffers are it; several tiles' are merged
    let (planes, skip, tx, lf_uv, sb_cdef) = if ntiles == 1 {
        let t = &mut tiles[0];
        (&mut t.plane, &t.skip, &t.tx_size, &t.lf_uv, &t.sb_cdef)
    } else {
        let fb = &mut *frame;
        fb.skip.resize(mr * mc, 0);
        fb.tx.resize(mr * mc, 0);
        for m in &mut fb.lf_uv {
            m.resize((mr >> 1) * (mc >> 1), 0);
        }
        fb.sb_cdef.resize((f.sb_cols * f.sb_rows) as usize, -1);
        for p in 0..nplanes {
            fb.plane[p].resize(pstride[p] * pheight[p], 0);
        }
        for t in &tiles[..ntiles] {
            let (c0, r0, mw, mh) = (t.c0 as usize, t.r0 as usize, t.mw as usize, t.mh as usize);
            for y in 0..mh {
                fb.skip[(r0 + y) * mc + c0..][..mw].copy_from_slice(&t.skip[y * mw..][..mw]);
                fb.tx[(r0 + y) * mc + c0..][..mw].copy_from_slice(&t.tx_size[y * mw..][..mw]);
            }
            let (cc, cw) = (mc >> 1, mw >> 1);
            for k in 0..2 {
                for y in 0..mh >> 1 {
                    fb.lf_uv[k][((r0 >> 1) + y) * cc + (c0 >> 1)..][..cw].copy_from_slice(&t.lf_uv[k][y * cw..][..cw]);
                }
            }
            let (sc0, sr0, tsc) = (c0 >> 4, r0 >> 4, t.sb_cols as usize);
            for y in 0..t.sb_rows as usize {
                fb.sb_cdef[(sr0 + y) * f.sb_cols as usize + sc0..][..tsc].copy_from_slice(&t.sb_cdef[y * tsc..][..tsc]);
            }
            for p in 0..nplanes {
                let sub = (p != 0) as usize;
                let (x0, y0) = ((c0 * 4) >> sub, (r0 * 4) >> sub);
                let (tw, th) = ((mw * 4) >> sub, (mh * 4) >> sub);
                let s = t.stride[p];
                for y in 0..th {
                    fb.plane[p][(y0 + y) * pstride[p] + x0..][..tw].copy_from_slice(&t.plane[p][y * s..][..tw]);
                }
            }
        }
        (&mut fb.plane, &fb.skip, &fb.tx, &fb.lf_uv, &fb.sb_cdef)
    };
    let skip: &[u8] = if lf_off || inner { &pf_skip } else { skip };
    // Deblocking (spec 7.14) then CDEF (7.15): the decoder's output frame. The maps come from
    // the walk.
    let pf = PfFrame::new(fp);
    let m = PfMaps {
        skip,
        lf_tx: [tx, &lf_uv[0], &lf_uv[1]],
        cdef_idx: sb_cdef,
    };
    {
        let [p0, p1, p2] = &mut *planes;
        let mut pl: [&mut [u8]; 3] = [p0, p1, p2];
        deblock_frame(&pf, &m, &mut pl, &pstride);
    }
    let result: &[Vec<u8>; 3] = if fp.enable_cdef != 0 && fp.allow_intrabc == 0 {
        for p in 0..nplanes {
            cdef_out[p].resize(planes[p].len(), 0);
        }
        let [d0, d1, d2] = cdef_out;
        let mut dst: [&mut [u8]; 3] = [d0, d1, d2];
        let src: [&[u8]; 3] = [&planes[0], &planes[1], &planes[2]];
        cdef_frame(&pf, &m, &src, &pstride, &mut dst, &pstride);
        cdef_out
    } else {
        planes
    };
    for p in 0..nplanes {
        let sub = (p != 0) as u32;
        let (w, h) = ((fp.width + sub) >> sub, (fp.height + sub) >> sub);
        let o = &mut out.recon[p];
        o.resize((w * h) as usize, 0);
        for y in 0..h as usize {
            o[y * w as usize..][..w as usize].copy_from_slice(&result[p][y * pstride[p]..][..w as usize]);
        }
        out.recon_w[p] = w;
        out.recon_h[p] = h;
    }
    frame.pf_skip = pf_skip;
}

/// av1g_encode with a fresh [`Writer`].
pub fn encode(rec: RecordMut, opts: &EncodeOpts) -> Result<Output, Error> {
    let mut out = Output::default();
    Writer::new().encode(rec, opts, &mut out)?;
    Ok(out)
}

/// av1g_validate: block sequence / partition derivation and field ranges, by coding the symbols
/// without a reconstruction. As av1g_validate, it writes the tx blocks' eob and chroma tx_type.
pub fn validate(rec: RecordMut) -> Result<(), Error> {
    let opts = EncodeOpts {
        flags: ENC_SKIP_RECON | ENC_NO_RECON,
        seq_level_idx: -1,
    };
    Writer::with_threads(1).encode(rec, &opts, &mut Output::default())
}
