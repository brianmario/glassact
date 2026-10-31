//! Random legal *inter sequences* (video mode, decisions.h): a key frame, then frames that are
//! mostly inter frames (now and then another key frame), deterministic per seed. Each sequence
//! fixes what the sequence header carries (size, odd ones included; monochrome; filter intra; the
//! intra edge filter; CDEF on or off; separate U / V quantizers; the tiling) and each frame draws
//! the rest: quantizer, tx mode and set, delta-q, deblocking and CDEF strengths, screen content
//! tools on key frames, the reference slot, the refresh flags and error resilience; partitions of
//! every kind; inter blocks (by a per-frame share, 0 to 100 %) with whole-sample motion vectors
//! (zero, repeated so that the candidate stack finds them, small, and far outside the frame),
//! skip and non-skip, uniform var-tx depths, luma tx types of the inter sets; intra blocks with
//! every mode, angle, CfL and filter intra; sparse random coefficients up to the Golomb range.
//!
//! The records are laid out and ready for [`crate::writer::Writer::encode_ex`]: frame k's
//! reference pictures are the reconstructions of the frames that last refreshed each slot (a key
//! frame refreshes all of them), which the caller tracks.
use crate::blockinfo::{bh4, bw4, cfl_allowed, has_chroma, max_tx_depth, mi_cols, mi_rows, tx_coeffs};
use crate::dsp::{
    get_scan, get_tx_set_inter, get_tx_set_intra, is_directional, tx_type_in_set_inter, tx_type_in_set_intra,
};
use crate::tables::*;
use crate::types::{Block, BlockInter, DECISIONS_VERSION, FRAME_INTER, FRAME_KEY, FrameParams};
use crate::writer::{Record, apply_sb_qindex, legalize_sb_qindex, tile_layout};

/// splitmix64 (as fuzz_gen's, its own stream)
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
    /// inclusive
    fn range(&mut self, lo: i32, hi: i32) -> i32 {
        lo + (self.next() % (hi - lo + 1) as u64) as i32
    }
    fn chance(&mut self, pct: i32) -> bool {
        ((self.next() % 100) as i32) < pct
    }
}

/// A random legal inter sequence: its frames' records, in coding order.
#[derive(Clone, Debug)]
pub struct InterSeq {
    pub frames: Vec<Record>,
}

/// What a frame's blocks are drawn from.
struct Gen<'a> {
    rng: &'a mut Rng,
    mi_cols: i32,
    mi_rows: i32,
    mono: bool,
    tx_select: bool,
    inter_frame: bool,
    inter_pct: i32,
    skip_pct: i32,
    fi: bool,
    /// motion vectors this frame reuses (so that neighbours share them: NEAREST / NEAR modes)
    mv_pool: Vec<[i16; 2]>,
    /// the largest motion, in samples
    mv_far: i32,
    blocks: Vec<Block>,
    inter: Vec<BlockInter>,
}

impl Gen<'_> {
    fn mv(&mut self) -> [i16; 2] {
        let rng = &mut *self.rng;
        let k = rng.range(0, 99);
        let s = if k < 15 {
            [0, 0]
        } else if k < 55 && !self.mv_pool.is_empty() {
            let i = rng.range(0, self.mv_pool.len() as i32 - 1) as usize;
            let mut m = self.mv_pool[i];
            if rng.chance(20) {
                m[rng.range(0, 1) as usize] += 8 * rng.range(-2, 2) as i16;
            }
            return m;
        } else if k < 85 {
            [8 * rng.range(-24, 24), 8 * rng.range(-24, 24)]
        } else {
            let f = self.mv_far;
            [8 * rng.range(-f, f), 8 * rng.range(-f, f)]
        };
        let m = [s[0] as i16, s[1] as i16];
        if self.mv_pool.len() < 6 && m != [0, 0] {
            self.mv_pool.push(m);
        }
        m
    }

    fn make_block(&mut self, r: i32, c: i32, bs: i32) {
        let inter = self.inter_frame && self.rng.chance(self.inter_pct);
        let mut b = Block {
            mi_row: r as u16,
            mi_col: c as u16,
            bsize: bs as u8,
            ..Block::default()
        };
        let mut bi = BlockInter::default();
        b.skip = self.rng.chance(self.skip_pct) as u8;
        if inter {
            bi.is_inter = 1;
            [bi.mv_row, bi.mv_col] = self.mv();
            if self.tx_select && bs > BLOCK_4X4 && b.skip == 0 {
                b.tx_depth = self.rng.range(0, max_tx_depth(bs)) as u8;
            }
        } else {
            let rng = &mut *self.rng;
            b.y_mode = rng.range(0, 12) as u8;
            if bs >= BLOCK_8X8 && is_directional(b.y_mode as i32) && rng.chance(70) {
                b.angle_delta_y = rng.range(-3, 3) as i8;
            }
            if self.tx_select && bs > BLOCK_4X4 {
                b.tx_depth = rng.range(0, max_tx_depth(bs)) as u8;
            }
            if has_chroma(bs, r, c, self.mono) {
                b.uv_mode = rng.range(0, if cfl_allowed(bs) { 13 } else { 12 }) as u8;
                if b.uv_mode as i32 == UV_CFL_PRED {
                    loop {
                        b.cfl_alpha_u = if rng.chance(25) { 0 } else { rng.range(-16, 16) as i8 };
                        b.cfl_alpha_v = if rng.chance(25) { 0 } else { rng.range(-16, 16) as i8 };
                        if b.cfl_alpha_u != 0 || b.cfl_alpha_v != 0 {
                            break;
                        }
                    }
                }
                if bs >= BLOCK_8X8 && is_directional(b.uv_mode as i32) && rng.chance(70) {
                    b.angle_delta_uv = rng.range(-3, 3) as i8;
                }
            }
            if self.fi && b.y_mode as i32 == DC_PRED && bw4(bs) <= 8 && bh4(bs) <= 8 && rng.chance(50) {
                b.filter_intra = rng.range(1, 5) as u8;
            }
        }
        self.blocks.push(b);
        self.inter.push(bi);
    }

    fn partition(&mut self, r: i32, c: i32, b_size: i32) {
        if r >= self.mi_rows || c >= self.mi_cols {
            return;
        }
        let half = bw4(b_size) >> 1;
        let quarter = half >> 1;
        let has_rows = (r + half) < self.mi_rows;
        let has_cols = (c + half) < self.mi_cols;
        let rng = &mut *self.rng;
        let p = if b_size < BLOCK_8X8 {
            PARTITION_NONE
        } else if has_rows && has_cols {
            if b_size == BLOCK_8X8 {
                rng.range(0, 3)
            } else if rng.chance(if b_size == BLOCK_64X64 { 45 } else { 30 }) {
                PARTITION_SPLIT
            } else {
                rng.range(0, 9)
            }
        } else if has_cols {
            if rng.chance(50) {
                PARTITION_HORZ
            } else {
                PARTITION_SPLIT
            }
        } else if has_rows {
            if rng.chance(50) {
                PARTITION_VERT
            } else {
                PARTITION_SPLIT
            }
        } else {
            PARTITION_SPLIT
        };
        let sub = Partition_Subsize[p as usize][b_size as usize] as i32;
        let sp = Partition_Subsize[PARTITION_SPLIT as usize][b_size as usize] as i32;
        match p {
            PARTITION_NONE => self.make_block(r, c, sub),
            PARTITION_HORZ => {
                self.make_block(r, c, sub);
                if has_rows {
                    self.make_block(r + half, c, sub);
                }
            }
            PARTITION_VERT => {
                self.make_block(r, c, sub);
                if has_cols {
                    self.make_block(r, c + half, sub);
                }
            }
            PARTITION_SPLIT => {
                self.partition(r, c, sub);
                self.partition(r, c + half, sub);
                self.partition(r + half, c, sub);
                self.partition(r + half, c + half, sub);
            }
            PARTITION_HORZ_A => {
                self.make_block(r, c, sp);
                self.make_block(r, c + half, sp);
                self.make_block(r + half, c, sub);
            }
            PARTITION_HORZ_B => {
                self.make_block(r, c, sub);
                self.make_block(r + half, c, sp);
                self.make_block(r + half, c + half, sp);
            }
            PARTITION_VERT_A => {
                self.make_block(r, c, sp);
                self.make_block(r + half, c, sp);
                self.make_block(r, c + half, sub);
            }
            PARTITION_VERT_B => {
                self.make_block(r, c, sub);
                self.make_block(r, c + half, sp);
                self.make_block(r + half, c + half, sp);
            }
            PARTITION_HORZ_4 => {
                for i in 0..4 {
                    if i < 3 || r + quarter * 3 < self.mi_rows {
                        self.make_block(r + quarter * i, c, sub);
                    }
                }
            }
            _ => {
                for i in 0..4 {
                    if i < 3 || c + quarter * 3 < self.mi_cols {
                        self.make_block(r, c + quarter * i, sub);
                    }
                }
            }
        }
    }
}

/// Random sparse coefficients for one tx block (as fuzz_gen's, smaller magnitudes more often).
fn fill_coeffs(rng: &mut Rng, q: &mut [i16], tx_sz: i32, tx_type: i32) {
    let n = tx_coeffs(tx_sz) as i32;
    if rng.chance(30) {
        return;
    }
    let scan = get_scan(tx_sz, tx_type);
    let r = rng.range(0, 99);
    let eob = if r < 40 {
        rng.range(1, n.min(4))
    } else if r < 80 {
        rng.range(1, n.min(32))
    } else {
        rng.range(1, n)
    };
    let density = rng.range(5, 100);
    for c in 0..eob {
        if c != eob - 1 && !rng.chance(density) {
            continue;
        }
        let m = rng.range(0, 999);
        let mag = if m < 650 {
            1
        } else if m < 850 {
            rng.range(2, 3)
        } else if m < 950 {
            rng.range(4, 15)
        } else if m < 990 {
            rng.range(16, 300)
        } else if m < 998 {
            rng.range(300, 5000)
        } else {
            rng.range(5000, 32767)
        };
        q[scan[c as usize] as usize] = if rng.chance(50) { -mag } else { mag } as i16;
    }
}

impl InterSeq {
    /// The sequence of `seed`: sides up to `maxdim` (>= 8), `nframes` frames (>= 1). None if the
    /// drawn size can't be tiled (never for sides <= 4096).
    pub fn make(seed: u64, maxdim: i32, nframes: usize) -> Option<InterSeq> {
        let mut rng = Rng(seed.wrapping_mul(0x2545F4914F6CDD1D) ^ 0x1D872B41);
        rng.next();
        const SPECIAL: [(i32, i32); 8] = [(1, 1), (7, 13), (65, 65), (64, 64), (8, 8), (13, 7), (72, 40), (129, 3)];
        let (w, h) = if rng.chance(15) {
            SPECIAL[rng.range(0, 7) as usize]
        } else if rng.chance(35) {
            (rng.range(1, 48), rng.range(1, 48))
        } else {
            (rng.range(1, maxdim.max(8)), rng.range(1, maxdim.max(8)))
        };
        // what the sequence header carries: fixed for the stream
        let mut base = FrameParams {
            version: DECISIONS_VERSION,
            width: w as u32,
            height: h as u32,
            video: 1,
            tile_cols_log2: -1,
            tile_rows_log2: -1,
            ..FrameParams::default()
        };
        base.monochrome = rng.chance(15) as u8;
        base.enable_filter_intra = rng.chance(40) as u8;
        base.enable_intra_edge_filter = rng.chance(50) as u8;
        base.enable_cdef = rng.chance(50) as u8;
        let mono = base.monochrome != 0;
        if rng.chance(20) {
            base.delta_q_y_dc = rng.range(-15, 15) as i8;
        }
        if !mono && rng.chance(20) {
            base.delta_q_u_dc = rng.range(-15, 15) as i8;
            base.delta_q_u_ac = rng.range(-15, 15) as i8;
            (base.delta_q_v_dc, base.delta_q_v_ac) = if rng.chance(50) {
                (rng.range(-15, 15) as i8, rng.range(-15, 15) as i8)
            } else {
                (base.delta_q_u_dc, base.delta_q_u_ac)
            };
        }
        let qm = rng.chance(25);
        let (qm_u, qm_v) = {
            let u = rng.range(0, 15) as u8;
            (
                u,
                if mono || rng.chance(50) {
                    u
                } else {
                    rng.range(0, 15) as u8
                },
            )
        };
        let mt = tile_layout(w as u32, h as u32, -1, -1).ok()?;
        if rng.chance(20) {
            let (cl, rl) = (mt.cols_log2 + rng.range(0, 2), rng.range(0, 2));
            if tile_layout(w as u32, h as u32, cl, rl).is_ok() {
                (base.tile_cols_log2, base.tile_rows_log2) = (cl as i8, rl as i8);
            }
        }
        let tiles = tile_layout(
            w as u32,
            h as u32,
            base.tile_cols_log2 as i32,
            base.tile_rows_log2 as i32,
        )
        .ok()?;
        let (mi_c, mi_r) = (mi_cols(w), mi_rows(h));
        let (sb_cols, sb_rows) = (((mi_c + 15) >> 4) as usize, ((mi_r + 15) >> 4) as usize);
        let mut frames = Vec::with_capacity(nframes);
        for k in 0..nframes {
            let mut fp = base;
            let key = k == 0 || rng.chance(8);
            fp.base_q_idx = rng.range(1, 255) as u8;
            fp.tx_mode_select = rng.chance(65) as u8;
            fp.reduced_tx_set = rng.chance(25) as u8;
            if qm {
                fp.using_qmatrix = 1;
                fp.qm_y = rng.range(0, 15) as u8;
                (fp.qm_u, fp.qm_v) = (qm_u, qm_v);
            }
            if rng.chance(25) {
                fp.delta_q_present = 1;
                fp.delta_q_res = rng.range(0, 3) as u8;
            }
            if rng.chance(55) {
                let lf = &mut fp.loop_filter_level;
                lf[0] = rng.range(0, 63) as u8;
                lf[1] = if rng.chance(50) { lf[0] } else { rng.range(0, 63) as u8 };
                if lf[0] == 0 && lf[1] == 0 {
                    lf[0] = 1;
                }
                if fp.monochrome == 0 {
                    lf[2] = rng.range(0, 63) as u8;
                    lf[3] = rng.range(0, 63) as u8;
                }
                fp.loop_filter_sharpness = rng.range(0, 7) as u8;
            }
            if fp.enable_cdef != 0 {
                // on in the sequence; a frame may still filter nothing (cdef_bits 0, strengths 0)
                const SEC: [u8; 4] = [0, 1, 2, 4];
                fp.cdef_damping_minus_3 = rng.range(0, 3) as u8;
                if rng.chance(80) {
                    fp.cdef_bits = rng.range(0, 3) as u8;
                    for i in 0..1usize << fp.cdef_bits {
                        fp.cdef_y_pri[i] = rng.range(0, 15) as u8;
                        fp.cdef_y_sec[i] = SEC[rng.range(0, 3) as usize];
                        if fp.monochrome == 0 {
                            fp.cdef_uv_pri[i] = rng.range(0, 15) as u8;
                            fp.cdef_uv_sec[i] = SEC[rng.range(0, 3) as usize];
                        }
                    }
                }
            }
            if key {
                fp.frame_type = FRAME_KEY;
                fp.allow_screen_content_tools = rng.chance(30) as u8;
            } else {
                fp.frame_type = FRAME_INTER;
                fp.allow_screen_content_tools = 1;
                fp.ref_slot = rng.range(0, 7) as u8;
                fp.refresh_frame_flags = if rng.chance(15) {
                    0
                } else if rng.chance(30) {
                    0xFF
                } else {
                    rng.range(1, 255) as u8
                };
                fp.error_resilient_mode = rng.chance(30) as u8;
                fp.lf_inter_off = rng.chance(50) as u8;
                fp.cdf_from_ref = (fp.error_resilient_mode == 0 && rng.chance(60)) as u8;
            }
            let inter_pct = [0, 30, 60, 85, 100][rng.range(0, 4) as usize];
            let skip_pct = [5, 20, 50, 80][rng.range(0, 3) as usize];
            let mv_far = [24, 96, (w.max(h) + 80).min(1000)][rng.range(0, 2) as usize];
            let mut g = Gen {
                rng: &mut rng,
                mi_cols: mi_c,
                mi_rows: mi_r,
                mono: fp.monochrome != 0,
                tx_select: fp.tx_mode_select != 0,
                inter_frame: !key,
                inter_pct,
                skip_pct,
                fi: fp.enable_filter_intra != 0,
                mv_pool: Vec::new(),
                mv_far,
                blocks: Vec::new(),
                inter: Vec::new(),
            };
            for tr in 0..tiles.rows as usize {
                for tc in 0..tiles.cols as usize {
                    for r in (tiles.mi_row_starts[tr]..tiles.mi_row_starts[tr + 1]).step_by(16) {
                        for c in (tiles.mi_col_starts[tc]..tiles.mi_col_starts[tc + 1]).step_by(16) {
                            g.partition(r as i32, c as i32, BLOCK_64X64);
                        }
                    }
                }
            }
            let (mut blocks, inter) = (g.blocks, g.inter);
            if fp.delta_q_present != 0 {
                let b = fp.base_q_idx as i32;
                let target: Vec<u8> = (0..sb_cols * sb_rows)
                    .map(|_| (b + rng.range(-30, 30)).clamp(1, 255) as u8)
                    .collect();
                let mut legal = vec![0u8; target.len()];
                legalize_sb_qindex(b, fp.delta_q_res as i32, &target, &mut legal);
                apply_sb_qindex(&fp, &mut blocks, &legal).ok()?;
            }
            if fp.enable_cdef != 0 {
                let sbc: Vec<i8> = (0..sb_cols * sb_rows)
                    .map(|_| rng.range(0, (1 << fp.cdef_bits) - 1) as i8)
                    .collect();
                for b in &mut blocks {
                    b.cdef_idx = sbc[(b.mi_row as usize >> 4) * sb_cols + (b.mi_col as usize >> 4)];
                }
            }
            let mut rec = Record {
                fp,
                blocks,
                inter: if key { Vec::new() } else { inter },
                ..Default::default()
            };
            rec.layout().ok()?;
            let reduced = fp.reduced_tx_set != 0;
            for b in 0..rec.blocks.len() {
                let is_inter = rec.inter.get(b).is_some_and(|i| i.is_inter != 0);
                for t in rec.block_txb[b] as usize..rec.block_txb[b + 1] as usize {
                    let x = rec.txb[t];
                    let tx_sz = x.tx_size as i32;
                    let mut tx_type = DCT_DCT;
                    if x.plane == 0 {
                        let ok = |ty: i32| {
                            if is_inter {
                                tx_type_in_set_inter(get_tx_set_inter(tx_sz, reduced), ty)
                            } else {
                                tx_type_in_set_intra(get_tx_set_intra(tx_sz, reduced), ty)
                            }
                        };
                        if rng.chance(70) {
                            loop {
                                tx_type = rng.range(0, 15);
                                if ok(tx_type) {
                                    break;
                                }
                            }
                        }
                        rec.txb[t].tx_type = tx_type as u8;
                    }
                    let off = x.coeff_off as usize;
                    fill_coeffs(&mut rng, &mut rec.coeffs[off..off + tx_coeffs(tx_sz)], tx_sz, tx_type);
                }
            }
            frames.push(rec);
        }
        Some(InterSeq { frames })
    }
}

/// av1t_inter_case_make: [`InterSeq::make`].
pub fn inter_seq_make(seed: u64, maxdim: i32, nframes: usize) -> Option<InterSeq> {
    InterSeq::make(seed, maxdim, nframes)
}
