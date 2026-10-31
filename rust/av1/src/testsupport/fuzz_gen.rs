//! Random-decision fuzzer for av1core: the generator of random *legal* DecisionRecords (random
//! sizes, partitions, modes, angle deltas, CFL alphas, tx sizes/types, sparse coefficients incl.
//! Golomb-range magnitudes, skip blocks, tiles, delta-q, QM, filter intra, edge filter, deblocking
//! and CDEF). Sources/AV1CoreTestSupport/fuzz_gen.cpp, from av1gpu's tests/fuzz.cpp (BSD-2): Rng,
//! Gen, make_case. Every seed gives the same record as the C++.
//!
//! The C++ also counts what it generated (a thread_local `Coverage`); nothing reads the counts
//! back, so they don't shape the record and aren't ported. The C++'s `m2` mode (DC-only records)
//! is never used by av1t_case_make and isn't ported either.
use crate::blockinfo::{bh4, bw4, cfl_allowed, has_chroma, max_tx_depth, mi_cols, mi_rows, tx_coeffs};
use crate::dsp::{chroma_tx_type, get_scan, get_tx_set_intra, is_directional, tx_type_in_set_intra};
use crate::tables::*;
use crate::types::{Block, DECISIONS_VERSION, DecisionRecord, FrameParams, Tiles, Txb};
use crate::writer::{apply_sb_qindex, layout, layout_counts, legalize_sb_qindex, tile_layout};

/// splitmix64, with the seed hashed so that streams of consecutive seeds are not shifted copies.
struct Rng {
    s: u64,
}

impl Rng {
    fn mix(mut z: u64) -> u64 {
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
    fn new(seed: u64) -> Self {
        let mut r = Rng {
            s: Self::mix(Self::mix(seed.wrapping_add(0x632BE59BD9B4E019))),
        };
        r.next();
        r
    }
    fn next(&mut self) -> u64 {
        self.s = self.s.wrapping_add(0x9E3779B97F4A7C15);
        Self::mix(self.s)
    }
    /// inclusive
    fn range(&mut self, lo: i32, hi: i32) -> i32 {
        lo + (self.next() % (hi - lo + 1) as u64) as i32
    }
    fn chance(&mut self, pct: i32) -> bool {
        ((self.next() % 100) as i32) < pct
    }
}

struct Gen<'a> {
    rng: &'a mut Rng,
    mi_cols: i32,
    mi_rows: i32,
    mono: bool,
    tx_select: bool,
    blocks: Vec<Block>,
    max_depth_bias: i32,
    dq_bias: bool,
    /// post-filter cases: more skip blocks (flat areas reach the wide filters)
    pf_smooth: bool,
    /// enable_filter_intra
    fi: bool,
}

impl Gen<'_> {
    fn make_block(&mut self, r: i32, c: i32, bs: i32) {
        let rng = &mut *self.rng;
        let mut b = Block {
            mi_row: r as u16,
            mi_col: c as u16,
            bsize: bs as u8,
            ..Block::default()
        };
        b.skip = rng.chance(if bs == BLOCK_64X64 && self.dq_bias {
            60
        } else if self.pf_smooth {
            45
        } else {
            15
        }) as u8;
        b.y_mode = rng.range(0, 12) as u8;
        if bs >= BLOCK_8X8 && is_directional(b.y_mode as i32) && rng.chance(70) {
            b.angle_delta_y = rng.range(-3, 3) as i8;
        }
        if self.tx_select && bs > BLOCK_4X4 {
            b.tx_depth = rng.range(0, max_tx_depth(bs)) as u8;
        }
        if has_chroma(bs, r, c, self.mono) {
            let maxuv = if cfl_allowed(bs) { 13 } else { 12 };
            b.uv_mode = rng.range(0, maxuv) as u8;
            if cfl_allowed(bs) && rng.chance(20) {
                b.uv_mode = UV_CFL_PRED as u8;
            }
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
        self.blocks.push(b);
    }

    fn pick_partition(&mut self, bs: i32, has_rows: bool, has_cols: bool) -> i32 {
        let rng = &mut *self.rng;
        if has_rows && has_cols {
            if bs == BLOCK_8X8 {
                return rng.range(0, 3);
            }
            if bs == BLOCK_64X64 && self.dq_bias && rng.chance(25) {
                return PARTITION_NONE;
            }
            // bias: split often at large sizes, use every type
            let p_split = match bs {
                BLOCK_64X64 => 55,
                BLOCK_32X32 => 40,
                _ => 25,
            } * self.max_depth_bias
                / 2;
            if rng.chance(p_split) {
                return PARTITION_SPLIT;
            }
            return rng.range(0, 9);
        }
        if has_cols {
            return if rng.chance(50) {
                PARTITION_HORZ
            } else {
                PARTITION_SPLIT
            };
        }
        if has_rows {
            return if rng.chance(50) {
                PARTITION_VERT
            } else {
                PARTITION_SPLIT
            };
        }
        PARTITION_SPLIT
    }

    fn partition(&mut self, r: i32, c: i32, b_size: i32) {
        if r >= self.mi_rows || c >= self.mi_cols {
            return;
        }
        let num4x4 = bw4(b_size);
        let half = num4x4 >> 1;
        let quarter = half >> 1;
        let has_rows = (r + half) < self.mi_rows;
        let has_cols = (c + half) < self.mi_cols;
        let p = if b_size < BLOCK_8X8 {
            PARTITION_NONE
        } else {
            self.pick_partition(b_size, has_rows, has_cols)
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

    fn gen_blocks(&mut self, tiles: &Tiles) {
        for tr in 0..tiles.rows as usize {
            for tc in 0..tiles.cols as usize {
                for r in (tiles.mi_row_starts[tr]..tiles.mi_row_starts[tr + 1]).step_by(16) {
                    for c in (tiles.mi_col_starts[tc]..tiles.mi_col_starts[tc + 1]).step_by(16) {
                        self.partition(r as i32, c as i32, BLOCK_64X64);
                    }
                }
            }
        }
    }
}

/// Random sparse coefficients for one tx block (`q` zeroed, tx_coeffs(tx_sz) long).
fn fill_coeffs(rng: &mut Rng, q: &mut [i16], tx_sz: i32, tx_type: i32, style: i32) {
    let n = tx_coeffs(tx_sz) as i32;
    if rng.chance(25) {
        return; // all zero
    }
    let scan = get_scan(tx_sz, tx_type);
    let r = rng.range(0, 99);
    let eob = if r < 30 {
        rng.range(1, n.min(4))
    } else if r < 70 {
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
        let mut mag = if m < 600 {
            1
        } else if m < 800 {
            rng.range(2, 3)
        } else if m < 920 {
            rng.range(4, 15)
        } else if m < 985 {
            rng.range(16, 300)
        } else if m < 997 {
            rng.range(300, 5000)
        } else {
            rng.range(5000, 32767)
        };
        if style == 1 && mag > 40 {
            mag = 40;
        }
        q[scan[c as usize] as usize] = if rng.chance(50) { -mag } else { mag } as i16;
    }
}

/// A random legal record and the storage its [`DecisionRecord`] points into (av1t_case).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FuzzCase {
    pub fp: FrameParams,
    pub blocks: Vec<Block>,
    /// n_blocks + 1 entries
    pub block_txb: Vec<u32>,
    pub txb: Vec<Txb>,
    /// n_coeffs + 1 entries (the C++'s allocation; the last is always 0)
    pub coeffs: Vec<i16>,
    pub n_coeffs: u64,
}

impl FuzzCase {
    /// make_case: the random legal record of `seed` (deterministic), as av1gpu's fuzzer makes it:
    /// sides up to `maxdim` (>= 1), `big_pct` percent of cases wide enough to force several tiles.
    /// Laid out and ready for av1g_encode. `None` where the C++ returns null (a layout failure).
    pub fn make(seed: u64, maxdim: i32, big_pct: i32) -> Option<FuzzCase> {
        let mut rng = Rng::new(seed);
        // ---- frame parameters ----
        const SPECIAL: [(i32, i32); 10] = [
            (1, 1),
            (7, 13),
            (65, 65),
            (64, 64),
            (8, 8),
            (2, 3),
            (13, 7),
            (16, 16),
            (72, 40),
            (129, 1),
        ];
        let sz = rng.range(0, 99);
        let (width, height) = if sz < 10 {
            SPECIAL[rng.range(0, 9) as usize]
        } else if sz < 30 {
            let w = rng.range(1, 40);
            (w, rng.range(1, 40))
        } else if sz < 100 - big_pct {
            let w = rng.range(1, maxdim);
            (w, rng.range(1, maxdim))
        } else if rng.chance(70) {
            // forced tiles: wider than 4096 or area > 4096*2304
            let w = rng.range(4097, 9000);
            (w, rng.range(1, 80))
        } else {
            let w = rng.range(3000, 4096);
            (w, rng.range(2400, 2600))
        };
        let mut fp = FrameParams {
            version: DECISIONS_VERSION,
            width: width as u32,
            height: height as u32,
            ..FrameParams::default()
        };
        fp.monochrome = rng.chance(15) as u8;
        fp.base_q_idx = rng.range(1, 255) as u8;
        fp.tx_mode_select = rng.chance(60) as u8;
        fp.reduced_tx_set = rng.chance(30) as u8;
        fp.tile_cols_log2 = -1;
        fp.tile_rows_log2 = -1;
        fp.allow_screen_content_tools = rng.chance(15) as u8;
        if rng.chance(15) {
            fp.delta_q_y_dc = rng.range(-20, 20) as i8;
            fp.delta_q_u_dc = rng.range(-20, 20) as i8;
            fp.delta_q_u_ac = rng.range(-20, 20) as i8;
            if rng.chance(50) {
                fp.delta_q_v_dc = rng.range(-20, 20) as i8;
                fp.delta_q_v_ac = rng.range(-20, 20) as i8;
            } else {
                fp.delta_q_v_dc = fp.delta_q_u_dc;
                fp.delta_q_v_ac = fp.delta_q_u_ac;
            }
        }
        if rng.chance(30) {
            fp.using_qmatrix = 1;
            fp.qm_y = rng.range(0, 15) as u8;
            fp.qm_u = rng.range(0, 15) as u8;
            fp.qm_v = if rng.chance(50) {
                fp.qm_u
            } else {
                rng.range(0, 15) as u8
            };
        }
        if rng.chance(35) {
            fp.enable_filter_intra = 1;
        }
        if rng.chance(35) {
            fp.enable_intra_edge_filter = 1;
        }
        if rng.chance(30) {
            fp.delta_q_present = 1;
            fp.delta_q_res = rng.range(0, 3) as u8;
        }
        // optional extra tiles for moderately sized pictures
        let (uw, uh) = (width as u32, height as u32);
        let mt = tile_layout(uw, uh, -1, -1).ok()?;
        if rng.chance(15) {
            let cl = mt.cols_log2 + rng.range(0, 2);
            let rl = rng.range(0, 2);
            if tile_layout(uw, uh, cl, rl).is_ok() {
                fp.tile_cols_log2 = cl as i8;
                fp.tile_rows_log2 = rl as i8;
            }
        }
        let tiles = tile_layout(uw, uh, fp.tile_cols_log2 as i32, fp.tile_rows_log2 as i32).ok()?;
        // deblocking / CDEF parameters from their own stream (keeps the pre-M5.5 cases of each seed)
        let mut prng = Rng::new(seed ^ 0x5DEECE66D);
        if prng.chance(45) {
            const HI: [u8; 8] = [63, 50, 40, 32, 24, 16, 8, 4];
            let lf = &mut fp.loop_filter_level;
            lf[0] = if prng.chance(50) {
                HI[prng.range(0, 7) as usize]
            } else {
                prng.range(0, 63) as u8
            };
            lf[1] = if prng.chance(20) {
                0
            } else if prng.chance(50) {
                lf[0]
            } else {
                prng.range(0, 63) as u8
            };
            if lf[0] == 0 && lf[1] == 0 {
                lf[1] = 1;
            }
            if fp.monochrome == 0 {
                lf[2] = if prng.chance(15) { 0 } else { prng.range(0, 63) as u8 };
                lf[3] = if prng.chance(15) { 0 } else { prng.range(0, 63) as u8 };
            }
            fp.loop_filter_sharpness = if prng.chance(50) { 0 } else { prng.range(0, 7) as u8 };
        }
        if prng.chance(45) {
            const SEC: [u8; 4] = [0, 1, 2, 4];
            fp.enable_cdef = 1;
            fp.cdef_damping_minus_3 = prng.range(0, 3) as u8;
            fp.cdef_bits = prng.range(0, 3) as u8;
            for i in 0..1usize << fp.cdef_bits {
                fp.cdef_y_pri[i] = prng.range(0, 15) as u8;
                fp.cdef_y_sec[i] = SEC[prng.range(0, 3) as usize];
                if fp.monochrome == 0 {
                    fp.cdef_uv_pri[i] = prng.range(0, 15) as u8;
                    fp.cdef_uv_sec[i] = SEC[prng.range(0, 3) as usize];
                }
            }
        }
        let lf = fp.loop_filter_level;
        let pf_smooth = (lf[0] != 0 || lf[1] != 0 || fp.enable_cdef != 0) && prng.chance(50);
        let (mi_c, mi_r) = (mi_cols(width), mi_rows(height));
        let max_depth_bias = rng.range(1, 3);
        let mut g = Gen {
            rng: &mut rng,
            mi_cols: mi_c,
            mi_rows: mi_r,
            mono: fp.monochrome != 0,
            tx_select: fp.tx_mode_select != 0,
            blocks: Vec::new(),
            max_depth_bias,
            dq_bias: fp.delta_q_present != 0,
            pf_smooth,
            fi: fp.enable_filter_intra != 0,
        };
        g.gen_blocks(&tiles);
        let mut blocks = g.blocks;
        let counts = layout_counts(&fp, &blocks).ok()?;
        let mut block_txb = vec![0u32; blocks.len() + 1];
        let mut txb = vec![Txb::default(); counts.n_txb as usize];
        layout(&fp, &blocks, &mut block_txb, &mut txb).ok()?;
        let n_coeffs = counts.n_coeffs;
        let mut coeffs = vec![0i16; n_coeffs as usize + 1];
        let sb_cols = ((mi_c + 15) >> 4) as usize;
        let sb_rows = ((mi_r + 15) >> 4) as usize;
        if fp.delta_q_present != 0 {
            // random per-SB qindex map, legalized
            let base = fp.base_q_idx as i32;
            let mode = rng.range(0, 2);
            let target: Vec<u8> = (0..sb_cols * sb_rows)
                .map(|_| {
                    (match mode {
                        0 => rng.range(1, 255),
                        1 => (base + rng.range(-12, 12)).clamp(1, 255),
                        _ => {
                            if rng.chance(80) {
                                base
                            } else {
                                rng.range(1, 255)
                            }
                        }
                    }) as u8
                })
                .collect();
            let mut legal = vec![0u8; target.len()];
            legalize_sb_qindex(base, fp.delta_q_res as i32, &target, &mut legal);
            // every block's SB is in the map (the C++ ignores the result too)
            let _ = apply_sb_qindex(&fp, &mut blocks, &legal);
        }
        if fp.enable_cdef != 0 {
            // one random cdef_idx per 64x64 (all blocks of an SB share it)
            let sbc: Vec<i8> = (0..sb_cols * sb_rows)
                .map(|_| prng.range(0, (1 << fp.cdef_bits) - 1) as i8)
                .collect();
            for b in &mut blocks {
                b.cdef_idx = sbc[(b.mi_row as usize >> 4) * sb_cols + (b.mi_col as usize >> 4)];
            }
        }
        let style = rng.chance(50) as i32;
        let reduced = fp.reduced_tx_set != 0;
        for (b, blk) in blocks.iter().enumerate() {
            for x in &mut txb[block_txb[b] as usize..block_txb[b + 1] as usize] {
                let mut tx_type = DCT_DCT;
                let tx_sz = x.tx_size as i32;
                if x.plane == 0 {
                    let set = get_tx_set_intra(tx_sz, reduced);
                    if set > 0 {
                        loop {
                            tx_type = rng.range(0, 15);
                            if tx_type_in_set_intra(set, tx_type) {
                                break;
                            }
                        }
                    }
                    x.tx_type = tx_type as u8;
                } else {
                    tx_type = chroma_tx_type(tx_sz, blk.uv_mode as i32, reduced);
                }
                let off = x.coeff_off as usize;
                fill_coeffs(
                    &mut rng,
                    &mut coeffs[off..off + tx_coeffs(tx_sz)],
                    tx_sz,
                    tx_type,
                    style,
                );
            }
        }
        Some(FuzzCase {
            fp,
            blocks,
            block_txb,
            txb,
            coeffs,
            n_coeffs,
        })
    }

    /// av1t_case_record: the laid-out record, pointing into the vectors (valid while `self` is
    /// neither moved nor resized).
    pub fn record(&mut self) -> DecisionRecord {
        DecisionRecord {
            fp: self.fp,
            n_blocks: self.blocks.len() as u32,
            n_txb: self.txb.len() as u32,
            n_coeffs: self.n_coeffs,
            blocks: self.blocks.as_mut_ptr(),
            block_txb: self.block_txb.as_mut_ptr(),
            txb: self.txb.as_mut_ptr(),
            coeffs: self.coeffs.as_mut_ptr(),
        }
    }
}

/// av1t_case_make: [`FuzzCase::make`].
pub fn case_make(seed: u64, maxdim: i32, big_pct: i32) -> Option<FuzzCase> {
    FuzzCase::make(seed, maxdim, big_pct)
}
