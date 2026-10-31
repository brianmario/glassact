use super::*;
use crate::dsp::Rng;

/// A random frame: legal-looking block tilings (random partitions of every 64x64), random filter
/// parameters, and planes of piecewise-smooth content (flat areas, small steps, noise, edges), so
/// every filter path runs.
pub(crate) struct Case {
    pub fp: FrameParams,
    pub blocks: Vec<Block>,
    pub planes: [Vec<u8>; 3],
    pub stride: [usize; 3],
}

fn partition(r: &mut Rng, row: i32, col: i32, log2: i32, mr: i32, mc: i32, out: &mut Vec<Block>) {
    if row >= mr || col >= mc {
        return;
    }
    let sq = [BLOCK_4X4, BLOCK_8X8, BLOCK_16X16, BLOCK_32X32, BLOCK_64X64][(log2 - 2) as usize];
    let n4 = 1 << (log2 - 2);
    let k = if log2 == 2 {
        0
    } else {
        r.below(if log2 == 6 { 6 } else { 4 })
    };
    let mut push = |bs: i32, row: i32, col: i32, r: &mut Rng| {
        if row < mr && col < mc {
            let tx_depth = r.range(0, max_tx_depth(bs)) as u8;
            out.push(Block {
                mi_row: row as u16,
                mi_col: col as u16,
                bsize: bs as u8,
                tx_depth,
                skip: (r.below(3) == 0) as u8,
                ..Default::default()
            });
        }
    };
    match k {
        0 => push(sq, row, col, r),
        1 if log2 > 2 => {
            // horizontal halves
            let bs = Partition_Subsize[PARTITION_HORZ as usize][sq as usize] as i32;
            push(bs, row, col, r);
            push(bs, row + n4 / 2, col, r);
        }
        2 if log2 > 2 => {
            let bs = Partition_Subsize[PARTITION_VERT as usize][sq as usize] as i32;
            push(bs, row, col, r);
            push(bs, row, col + n4 / 2, r);
        }
        4 if log2 >= 4 => {
            // 4-way horizontal (16x4 .. 64x16)
            let bs = Partition_Subsize[PARTITION_HORZ_4 as usize][sq as usize] as i32;
            for i in 0..4 {
                push(bs, row + i * n4 / 4, col, r);
            }
        }
        _ => {
            for (dr, dc) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                partition(r, row + dr * n4 / 2, col + dc * n4 / 2, log2 - 1, mr, mc, out);
            }
        }
    }
}

pub(crate) fn random_case(r: &mut Rng, max_dim: i32) -> Case {
    let mut fp = FrameParams {
        width: r.range(1, max_dim) as u32,
        height: r.range(1, max_dim) as u32,
        ..Default::default()
    };
    fp.monochrome = (r.below(6) == 0) as u8;
    let lv = |r: &mut Rng| if r.below(6) == 0 { 0 } else if r.below(2) == 0 { r.range(0, 63) } else { r.range(20, 63) } as u8;
    fp.loop_filter_level = [lv(r), lv(r), lv(r), lv(r)];
    fp.loop_filter_sharpness = if r.below(2) == 0 { 0 } else { r.range(0, 7) as u8 };
    fp.enable_cdef = (r.below(5) != 0) as u8;
    fp.cdef_damping_minus_3 = r.range(0, 3) as u8;
    fp.cdef_bits = 3;
    for i in 0..8 {
        fp.cdef_y_pri[i] = r.range(0, 15) as u8;
        fp.cdef_y_sec[i] = [0, 1, 2, 4][r.below(4) as usize];
        fp.cdef_uv_pri[i] = r.range(0, 15) as u8;
        fp.cdef_uv_sec[i] = [0, 1, 2, 4][r.below(4) as usize];
    }
    let (mr, mc) = (mi_rows(fp.height as i32), mi_cols(fp.width as i32));
    let mut blocks = Vec::new();
    for sr in (0..mr).step_by(16) {
        for sc in (0..mc).step_by(16) {
            let n0 = blocks.len();
            partition(r, sr, sc, 6, mr, mc, &mut blocks);
            let idx = r.range(0, 7) as i8;
            for b in &mut blocks[n0..] {
                b.cdef_idx = idx;
            }
        }
    }
    let mut planes: [Vec<u8>; 3] = Default::default();
    let mut stride = [0usize; 3];
    for p in 0..3 {
        let sub = (p != 0) as i32;
        let (w, h) = (((mc * 4) >> sub) as usize, ((mr * 4) >> sub) as usize);
        stride[p] = w + r.below(3) as usize * 8;
        let mut v = vec![0u8; stride[p] * h];
        // piecewise smooth: a base level per 8x8 area (mostly close to its neighbour), plus noise
        let mut base = r.range(30, 220);
        for by in (0..h).step_by(8) {
            for bx in (0..w).step_by(8) {
                base = match r.below(10) {
                    0 => r.range(0, 255),
                    1..=3 => clip3(0, 255, base + r.range(-12, 12)),
                    _ => clip3(0, 255, base + r.range(-2, 2)),
                };
                let noise = [0, 1, 2, 6][r.below(4) as usize];
                let grad = r.range(-1, 1);
                for y in by..(by + 8).min(h) {
                    for x in bx..(bx + 8).min(w) {
                        let g = grad * ((x - bx) as i32 + (y - by) as i32) / 4;
                        v[y * stride[p] + x] = clip3(0, 255, base + g + r.range(-noise, noise)) as u8;
                    }
                }
            }
        }
        planes[p] = v;
    }
    Case {
        fp,
        blocks,
        planes,
        stride,
    }
}

fn split(p: &mut [Vec<u8>; 3]) -> [&mut [u8]; 3] {
    let [a, b, c] = p;
    [a, b, c]
}

#[test]
fn deblock_simd_matches_scalar() {
    let mut r = Rng(31);
    let mut changed = 0;
    for _ in 0..300 {
        let c = random_case(&mut r, 200);
        let f = PfFrame::new(&c.fp);
        let mut mb = PfMapsBuf::new(&f);
        for b in &c.blocks {
            mb.mark_block(&f, b);
        }
        let m = mb.maps();
        let (mut a, mut b) = (c.planes.clone(), c.planes.clone());
        deblock_frame(&f, &m, &mut split(&mut a), &c.stride);
        deblock_frame_scalar(&f, &m, &mut split(&mut b), &c.stride);
        assert!(a == b, "{:?}", c.fp);
        changed += (a != c.planes) as u32;
    }
    assert!(changed > 200);
}

#[test]
fn cdef_simd_matches_scalar() {
    let mut r = Rng(32);
    for _ in 0..60 {
        let c = random_case(&mut r, 200);
        let mut fp = c.fp;
        fp.enable_cdef = 1;
        let f = PfFrame::new(&fp);
        let mut mb = PfMapsBuf::new(&f);
        for b in &c.blocks {
            mb.mark_block(&f, b);
        }
        let m = mb.maps();
        let src: [&[u8]; 3] = [&c.planes[0], &c.planes[1], &c.planes[2]];
        let (mut a, mut b) = (c.planes.clone(), c.planes.clone());
        for p in 0..3 {
            a[p].fill(0);
            b[p].fill(0);
        }
        cdef_frame(&f, &m, &src, &c.stride, &mut split(&mut a), &c.stride);
        cdef_frame_scalar(&f, &m, &src, &c.stride, &mut split(&mut b), &c.stride);
        assert!(a == b, "{fp:?}");
    }
}

#[cfg(target_arch = "aarch64")]
#[test]
fn cdef_direction_simd_matches_scalar() {
    let mut r = Rng(35);
    for k in 0..200000 {
        let blk: Vec<u8> = match k % 4 {
            0 => (0..64).map(|_| r.next() as u8).collect(),
            1 => (0..64).map(|_| [0u8, 255][r.below(2) as usize]).collect(),
            2 => {
                let (a, b, c) = (r.range(-30, 30), r.range(-30, 30), r.range(0, 255));
                (0..64)
                    .map(|i| clip3(0, 255, c + a * (i % 8) / 4 + b * (i / 8) / 4 + r.range(-2, 2)) as u8)
                    .collect()
            }
            _ => (0..64).map(|_| r.range(120, 136) as u8).collect(),
        };
        assert_eq!(neon::cdef_direction_neon(&blk, 8), cdef_direction(&blk, 8), "{blk:?}");
    }
}

#[cfg(target_arch = "aarch64")]
#[test]
#[ignore]
fn bench_cdef_direction() {
    let mut r = Rng(36);
    let blk: Vec<u8> = (0..64 * 8).map(|_| r.range(100, 160) as u8).collect();
    let n = 200000;
    let t = std::time::Instant::now();
    for i in 0..n {
        std::hint::black_box(cdef_direction(std::hint::black_box(&blk[(i % 8) * 8..]), 64));
    }
    let s = t.elapsed().as_nanos() as f64 / n as f64;
    let t = std::time::Instant::now();
    for i in 0..n {
        std::hint::black_box(neon::cdef_direction_neon(std::hint::black_box(&blk[(i % 8) * 8..]), 64));
    }
    let v = t.elapsed().as_nanos() as f64 / n as f64;
    println!("cdef_direction: scalar {s:.1} ns  neon {v:.1} ns  ({:.1}x)", s / v);
}

#[test]
fn filter_paths_covered() {
    let mut r = Rng(34);
    for _ in 0..30 {
        let c = random_case(&mut r, 200);
        let mut fp = c.fp;
        fp.enable_cdef = 1;
        let f = PfFrame::new(&fp);
        let mut mb = PfMapsBuf::new(&f);
        for b in &c.blocks {
            mb.mark_block(&f, b);
        }
        let m = mb.maps();
        let mut a = c.planes.clone();
        deblock_frame_scalar(&f, &m, &mut split(&mut a), &c.stride);
        let src: [&[u8]; 3] = [&c.planes[0], &c.planes[1], &c.planes[2]];
        cdef_frame_scalar(&f, &m, &src, &c.stride, &mut split(&mut a), &c.stride);
    }
    let n: Vec<u64> = PF_STAT
        .iter()
        .map(|v| v.load(std::sync::atomic::Ordering::Relaxed))
        .collect();
    assert!(n.iter().all(|&v| v > 20), "filter paths {n:?}");
}

// ---- micro-benchmarks: cargo test --release postfilter::tests::bench -- --ignored --nocapture ----

#[test]
#[ignore]
fn bench_postfilter() {
    let mut r = Rng(33);
    let mut c = random_case(&mut r, 8);
    // a 1920 x 1088 frame of the same content generator
    while c.fp.width != 1920 {
        c = random_case(&mut r, 1920);
        if c.fp.width > 1800 {
            c.fp.width = 1920;
            c.fp.height = 1080;
            let (mr, mc) = (mi_rows(1080), mi_cols(1920));
            let mut blocks = Vec::new();
            for sr in (0..mr).step_by(16) {
                for sc in (0..mc).step_by(16) {
                    partition(&mut r, sr, sc, 6, mr, mc, &mut blocks);
                }
            }
            c.blocks = blocks;
            for p in 0..3 {
                let sub = (p != 0) as i32;
                c.stride[p] = ((mc * 4) >> sub) as usize;
                c.planes[p] = (0..c.stride[p] * ((mr * 4) >> sub) as usize)
                    .map(|i| (128 + ((i / 7) % 9) as i32 - 4 + r.range(-1, 1)) as u8)
                    .collect();
            }
        }
    }
    let mut fp = c.fp;
    fp.loop_filter_level = [30, 30, 20, 20];
    fp.enable_cdef = 1;
    fp.cdef_y_pri = [6; 8];
    fp.cdef_y_sec = [2; 8];
    fp.cdef_uv_pri = [3; 8];
    fp.cdef_uv_sec = [1; 8];
    let f = PfFrame::new(&fp);
    let mut mb = PfMapsBuf::new(&f);
    for b in &c.blocks {
        mb.mark_block(&f, b);
    }
    let m = mb.maps();
    let time = |name: &str, g: &mut dyn FnMut()| {
        g();
        let t = std::time::Instant::now();
        for _ in 0..5 {
            g();
        }
        let ns = t.elapsed().as_nanos() as f64 / 5.0;
        println!("{name}: {:.2} ms per 1080p frame", ns / 1e6);
        ns
    };
    let mut a = c.planes.clone();
    let s = time("deblock scalar", &mut || {
        a = c.planes.clone();
        deblock_frame_scalar(&f, &m, &mut split(&mut a), &c.stride)
    });
    let v = time("deblock simd  ", &mut || {
        a = c.planes.clone();
        deblock_frame(&f, &m, &mut split(&mut a), &c.stride)
    });
    println!("  deblock {:.1}x", s / v);
    let src: [&[u8]; 3] = [&c.planes[0], &c.planes[1], &c.planes[2]];
    let mut d = c.planes.clone();
    let s = time("cdef scalar   ", &mut || {
        cdef_frame_scalar(&f, &m, &src, &c.stride, &mut split(&mut d), &c.stride)
    });
    let v = time("cdef simd     ", &mut || {
        cdef_frame(&f, &m, &src, &c.stride, &mut split(&mut d), &c.stride)
    });
    println!("  cdef {:.1}x", s / v);
}

#[cfg(feature = "oracle")]
mod oracle {
    use super::*;
    use crate::types::DecisionRecord;
    use core::ffi::{c_int, c_long, c_void};

    unsafe extern "C" {
        fn oracle_pf_frame(fp: *const FrameParams, out: *mut c_int);
        fn oracle_pf_maps(
            fp: *const FrameParams,
            blocks: *const Block,
            n: u32,
            skip: *mut u8,
            ty: *mut u8,
            tu: *mut u8,
            tv: *mut u8,
            cdef: *mut i8,
        );
        fn oracle_pf_lf_line(
            buf: *mut u8,
            q0: c_long,
            step: c_long,
            plane: c_int,
            fs: c_int,
            limit: c_int,
            blimit: c_int,
            thresh: c_int,
        );
        fn oracle_pf_deblock(
            fp: *const FrameParams,
            blocks: *const Block,
            n: u32,
            planes: *const *mut u8,
            stride: *const c_int,
        );
        fn oracle_pf_cdef(
            fp: *const FrameParams,
            blocks: *const Block,
            n: u32,
            src: *const *mut u8,
            dst: *const *mut u8,
            stride: *const c_int,
        );
        fn oracle_pf_cdef_direction(src: *const u8, stride: c_int, y_dir: *mut c_int, var: *mut c_int);
        fn oracle_pf_cdef_constrain(diff: c_int, threshold: c_int, damping: c_int) -> c_int;
        fn oracle_pf_cdef_pixel(
            mi_rows: c_int,
            mi_cols: c_int,
            src: *const u8,
            sstride: c_int,
            plane: c_int,
            x: c_int,
            y: c_int,
            pri: c_int,
            sec: c_int,
            damping: c_int,
            dir: c_int,
        ) -> c_int;
        // Sources/AV1Core (av1g.h) and Sources/AV1CoreTestSupport (av1core_test.h)
        fn av1g_postfilter(rec: *const DecisionRecord, planes: *const *mut u8, stride: *const c_int) -> c_int;
        fn av1t_case_make(seed: u64, maxdim: c_int, big_pct: c_int) -> *mut c_void;
        fn av1t_case_record(c: *mut c_void) -> *mut DecisionRecord;
        fn av1t_case_free(c: *mut c_void);
    }

    /// The fuzzer's random legal records (av1t_case_make), with this case's planes and random
    /// filter parameters on top of the record's.
    fn fuzz_case(r: &mut Rng, seed: u64) -> Case {
        // SAFETY: the record and its arrays live until av1t_case_free; they are copied out first.
        let (mut fp, blocks) = unsafe {
            let k = av1t_case_make(seed, 160, 10);
            let rec = &*av1t_case_record(k);
            let blocks = core::slice::from_raw_parts(rec.blocks, rec.n_blocks as usize).to_vec();
            let fp = rec.fp;
            av1t_case_free(k);
            (fp, blocks)
        };
        let mut c = random_case(r, 8);
        let keep = r.below(2) == 0; // the fuzzer's own filter parameters, or the random ones
        let (w, h, mono) = (fp.width, fp.height, fp.monochrome);
        if !keep {
            let cdef_bits = fp.cdef_bits;
            fp = c.fp;
            fp.cdef_bits = cdef_bits;
            (fp.width, fp.height, fp.monochrome) = (w, h, mono);
        }
        let (mr, mc) = (mi_rows(h as i32), mi_cols(w as i32));
        for p in 0..3 {
            let sub = (p != 0) as i32;
            let (pw, ph) = (((mc * 4) >> sub) as usize, ((mr * 4) >> sub) as usize);
            c.stride[p] = pw + 8;
            let mut v = vec![0u8; c.stride[p] * ph];
            let mut base = r.range(0, 255);
            for (i, x) in v.iter_mut().enumerate() {
                if i % 8 == 0 && r.below(4) == 0 {
                    base = clip3(0, 255, base + r.range(-8, 8));
                }
                *x = clip3(0, 255, base + r.range(-1, 1)) as u8;
            }
            c.planes[p] = v;
        }
        c.fp = fp;
        c.blocks = blocks;
        c
    }

    fn cases(r: &mut Rng) -> Vec<Case> {
        let mut v: Vec<Case> = (0..40).map(|_| random_case(r, 220)).collect();
        for seed in 1..40 {
            v.push(fuzz_case(r, seed));
        }
        v
    }

    fn ptrs(p: &mut [Vec<u8>; 3]) -> [*mut u8; 3] {
        [p[0].as_mut_ptr(), p[1].as_mut_ptr(), p[2].as_mut_ptr()]
    }

    #[test]
    fn frame_and_maps_match() {
        let mut r = Rng(41);
        for c in cases(&mut r) {
            let f = PfFrame::new(&c.fp);
            let mut o = [0i32; 46];
            // SAFETY: 46 ints out.
            unsafe { oracle_pf_frame(&c.fp, o.as_mut_ptr()) };
            let mut mine = vec![f.w, f.h, f.mi_rows, f.mi_cols, f.mono as i32, f.sb_cols, f.sb_rows];
            mine.extend(f.lf_level);
            mine.extend([f.sharpness, f.enable_cdef as i32, f.cdef_damping]);
            for a in [f.cdef_y_pri, f.cdef_y_sec, f.cdef_uv_pri, f.cdef_uv_sec] {
                mine.extend(a);
            }
            assert_eq!(mine, o);
            let mut mb = PfMapsBuf::new(&f);
            for b in &c.blocks {
                mb.mark_block(&f, b);
            }
            let mut cm = PfMapsBuf::new(&f);
            // SAFETY: the buffers have PfMapsBuf::new's sizes, as the shim's maps.
            unsafe {
                oracle_pf_maps(
                    &c.fp,
                    c.blocks.as_ptr(),
                    c.blocks.len() as u32,
                    cm.skip.as_mut_ptr(),
                    cm.lf_tx[0].as_mut_ptr(),
                    cm.lf_tx[1].as_mut_ptr(),
                    cm.lf_tx[2].as_mut_ptr(),
                    cm.cdef_idx.as_mut_ptr(),
                )
            };
            assert!(mb.skip == cm.skip && mb.lf_tx == cm.lf_tx && mb.cdef_idx == cm.cdef_idx);
        }
    }

    #[test]
    fn lf_line_matches() {
        let mut r = Rng(42);
        for _ in 0..200000 {
            // one line of 16 samples across the edge at index 8, step 1 or 3
            let step = [1usize, 3][r.below(2) as usize];
            let mut buf = vec![0u8; 16 * step];
            let base = r.range(0, 255);
            let (dp, dq) = (r.range(-3, 3), r.range(-3, 3));
            let jump = if r.below(3) == 0 {
                r.range(-40, 40)
            } else {
                r.range(-3, 3)
            };
            let noise = r.range(0, 2);
            for k in 0..16 {
                let v = base
                    + if k < 8 {
                        dp * (8 - k as i32) / 4
                    } else {
                        jump + dq * (k as i32 - 8) / 4
                    };
                buf[k * step] = clip3(0, 255, v + r.range(-noise, noise)) as u8;
            }
            if r.below(10) == 0 {
                for k in 0..16 {
                    buf[k * step] = r.next() as u8;
                }
            }
            let plane = r.range(0, 2) as usize;
            let fs = if plane == 0 {
                [4, 8, 16][r.below(3) as usize]
            } else {
                [4, 8][r.below(2) as usize]
            };
            let lvl = r.range(1, 63);
            let sharp = r.range(0, 7);
            let f = PfFrame {
                lf_level: [lvl; 4],
                sharpness: sharp,
                ..Default::default()
            };
            let (limit, blimit, thresh) = lf_limits(&f, plane, 0).unwrap();
            let mut c = buf.clone();
            lf_line(&mut buf, 8 * step, step, plane, fs, limit, blimit, thresh);
            // SAFETY: the C function reads and writes within 7 samples of q0.
            unsafe {
                oracle_pf_lf_line(
                    c.as_mut_ptr(),
                    8 * step as c_long,
                    step as c_long,
                    plane as c_int,
                    fs,
                    limit,
                    blimit,
                    thresh,
                )
            };
            assert_eq!(buf, c);
        }
    }

    #[test]
    fn deblock_matches() {
        let mut r = Rng(43);
        for mut c in cases(&mut r) {
            let f = PfFrame::new(&c.fp);
            let mut mb = PfMapsBuf::new(&f);
            for b in &c.blocks {
                mb.mark_block(&f, b);
            }
            let mut mine = c.planes.clone();
            deblock_frame(&f, &mb.maps(), &mut split(&mut mine), &c.stride);
            let st = c.stride.map(|s| s as c_int);
            // SAFETY: the planes cover the coded area at these strides.
            unsafe {
                oracle_pf_deblock(
                    &c.fp,
                    c.blocks.as_ptr(),
                    c.blocks.len() as u32,
                    ptrs(&mut c.planes).as_ptr(),
                    st.as_ptr(),
                )
            };
            assert!(mine == c.planes, "{:?}", c.fp);
        }
    }

    #[test]
    fn cdef_matches() {
        let mut r = Rng(44);
        for c in cases(&mut r) {
            let mut fp = c.fp;
            fp.enable_cdef = 1;
            let f = PfFrame::new(&fp);
            let mut mb = PfMapsBuf::new(&f);
            for b in &c.blocks {
                mb.mark_block(&f, b);
            }
            let src: [&[u8]; 3] = [&c.planes[0], &c.planes[1], &c.planes[2]];
            let mut mine = c.planes.clone();
            cdef_frame(&f, &mb.maps(), &src, &c.stride, &mut split(&mut mine), &c.stride);
            let mut theirs = c.planes.clone();
            let mut s = c.planes.clone();
            let st = c.stride.map(|s| s as c_int);
            // SAFETY: the planes cover the coded area at these strides.
            unsafe {
                oracle_pf_cdef(
                    &fp,
                    c.blocks.as_ptr(),
                    c.blocks.len() as u32,
                    ptrs(&mut s).as_ptr(),
                    ptrs(&mut theirs).as_ptr(),
                    st.as_ptr(),
                )
            };
            assert!(mine == theirs, "{fp:?}");
        }
    }

    #[test]
    fn postfilter_matches() {
        let mut r = Rng(45);
        for mut c in cases(&mut r) {
            let mut mine = c.planes.clone();
            postfilter(&c.fp, &c.blocks, &mut split(&mut mine), &c.stride);
            let rec = DecisionRecord {
                fp: c.fp,
                n_blocks: c.blocks.len() as u32,
                n_txb: 0,
                n_coeffs: 0,
                blocks: c.blocks.as_mut_ptr(),
                block_txb: core::ptr::null_mut(),
                txb: core::ptr::null_mut(),
                coeffs: core::ptr::null_mut(),
                inter: core::ptr::null_mut(),
            };
            let st = c.stride.map(|s| s as c_int);
            // SAFETY: the record's blocks and the planes outlive the call.
            let rc = unsafe { av1g_postfilter(&rec, ptrs(&mut c.planes).as_ptr(), st.as_ptr()) };
            assert_eq!(rc, 0);
            assert!(mine == c.planes, "{:?}", c.fp);
        }
    }

    #[test]
    fn cdef_pieces_match() {
        let mut r = Rng(46);
        let src: Vec<u8> = (0..64 * 64).map(|_| r.next() as u8).collect();
        for _ in 0..20000 {
            let (x, y) = (r.range(0, 56) as usize, r.range(0, 56) as usize);
            let smooth: Vec<u8> = (0..64)
                .map(|i| (src[i] / 16).wrapping_add(100 + (i % 8) as u8 * 3))
                .collect();
            let (blk, stride): (&[u8], usize) = if r.below(2) == 0 {
                (&src[y * 64 + x..], 64)
            } else {
                (&smooth, 8)
            };
            let (d, v) = cdef_direction(blk, stride);
            let (mut cd, mut cv) = (0, 0);
            // SAFETY: an 8x8 block at this stride.
            unsafe { oracle_pf_cdef_direction(blk.as_ptr(), stride as c_int, &mut cd, &mut cv) };
            assert_eq!((d, v), (cd, cv));
            let (diff, th, damp) = (r.range(-255, 255), r.range(0, 20), r.range(2, 7));
            // SAFETY: plain ints.
            assert_eq!(cdef_constrain(diff, th, damp), unsafe {
                oracle_pf_cdef_constrain(diff, th, damp)
            });
            // a pixel near the frame's edges: MiRows x MiCols cut the 64 x 64 plane
            let (mr, mc) = (r.range(1, 16), r.range(1, 16));
            let plane = r.range(0, 2) as usize;
            let sub = (plane != 0) as i32;
            let (px, py) = (r.range(0, ((mc * 4) >> sub) - 1), r.range(0, ((mr * 4) >> sub) - 1));
            let (pri, sec, dmp, dir) = (
                r.range(0, 15),
                [0, 1, 2, 4][r.below(4) as usize],
                r.range(2, 6),
                r.range(0, 7),
            );
            let f = PfFrame {
                mi_rows: mr,
                mi_cols: mc,
                ..Default::default()
            };
            let v = cdef_pixel(&f, &src, 64, plane, px, py, pri, sec, dmp, dir);
            // SAFETY: the plane is 64 x 64; taps stay inside the MiRows x MiCols region.
            let cv =
                unsafe { oracle_pf_cdef_pixel(mr, mc, src.as_ptr(), 64, plane as c_int, px, py, pri, sec, dmp, dir) };
            assert_eq!(v, cv);
        }
    }
}
