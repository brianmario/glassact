use super::*;
use core::mem::offset_of;

/// xorshift64, as the C++ test support's Rng.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 as u32
    }
    fn below(&mut self, n: u32) -> u32 {
        self.next() % n
    }
}

/// A random valid spec-format CDF of `n` symbols (non-decreasing, cdf[n - 1] = 32768) and counter.
fn random_cdf(rnd: &mut Rng, n: usize, out: &mut [u16]) {
    let mut v: Vec<u16> = (0..n - 1)
        .map(|_| {
            if rnd.below(8) == 0 {
                (1 + rnd.below(2) * 32766) as u16
            } else {
                1 + rnd.below(32767) as u16
            }
        })
        .collect();
    v.sort();
    out[..n - 1].copy_from_slice(&v);
    out[n - 1] = 32768;
    out[n] = rnd.below(36) as u16;
}

fn cdfs_arrays() -> Vec<(usize, usize, usize)> {
    Cdfs::arrays().to_vec()
}

/// The arrays tile the struct, each a whole number of CDFs.
#[test]
fn cdf_arrays_cover_cdfs() {
    let a = Cdfs::arrays();
    let mut at = 0;
    for (id, l, count) in a {
        assert_eq!(id, at);
        at += l * count;
    }
    assert_eq!(at, NCDF);
    assert_eq!(a[0], (0, 14, 25));
    assert_eq!(a[36], (offset_of!(Cdfs, coeff_br) / 2, 5, 5 * 2 * 21));
}

/// Calls `ec.symbol::<L>` on the CDF at `off` of `n` symbols.
fn symbol_fixed(ec: &mut Ec, s: u32, words: &mut [u16], off: usize, n: u32) {
    macro_rules! go {
        ($($n:literal => $l:literal),*) => {
            match n {
                $($n => ec.symbol::<$l>(s, (&mut words[off..off + $l]).try_into().unwrap()),)*
                _ => unreachable!(),
            }
        };
    }
    go!(2 => 3, 3 => 4, 4 => 5, 5 => 6, 6 => 7, 7 => 8, 8 => 9, 9 => 10, 10 => 11, 11 => 12, 12 => 13, 13 => 14,
        14 => 15, 15 => 16, 16 => 17)
}

/// A random spec-format symbol stream of `n` symbols on the real CDF layout: mostly coefficient
/// CDFs, as a tile's (bools, every array, split_or on the 16..64 partition CDFs).
fn random_symstream(rnd: &mut Rng, n: usize) -> Vec<u32> {
    let arrs = cdfs_arrays();
    let part: Vec<_> = arrs
        .iter()
        .copied()
        .filter(|a| a.0 >= offset_of!(Cdfs, partition_w16) / 2 && a.1 == 11)
        .collect();
    let coeff: Vec<_> = arrs
        .iter()
        .copied()
        .filter(|a| a.0 >= offset_of!(Cdfs, txb_skip) / 2)
        .collect();
    (0..n)
        .map(|_| {
            let k = rnd.below(16);
            if k == 0 {
                sym_pack(SYM_BOOL, 0, rnd.below(2), 2)
            } else if k == 1 {
                let a = part[rnd.below(part.len() as u32) as usize];
                let id = a.0 + a.1 * rnd.below(a.2 as u32) as usize;
                sym_pack(SYM_SPLIT_OR_HORZ + rnd.below(2), id as u32, rnd.below(2), 2)
            } else {
                let a = if k < 12 {
                    coeff[rnd.below(coeff.len() as u32) as usize]
                } else {
                    arrs[rnd.below(arrs.len() as u32) as usize]
                };
                let id = a.0 + a.1 * rnd.below(a.2 as u32) as usize;
                let nn = a.1 as u32 - 1;
                let s = if rnd.below(4) != 0 {
                    rnd.below(nn.min(3))
                } else {
                    rnd.below(nn)
                };
                sym_pack(SYM_ADAPT, id as u32, s, nn)
            }
        })
        .collect()
}

#[test]
fn coeff_cdf_q_ctx_bounds() {
    assert_eq!(
        [0, 20, 21, 60, 61, 120, 121, 255].map(coeff_cdf_q_ctx),
        [0, 0, 1, 1, 2, 2, 3, 3]
    );
}

#[test]
fn update_cdf_paths_agree() {
    let mut rnd = Rng(0x0123_4567_89ab_cdef);
    for _ in 0..200_000 {
        let n = 2 + rnd.below(15) as usize;
        let mut a = [0u16; 17];
        random_cdf(&mut rnd, n, &mut a);
        let s = rnd.below(n as u32);
        let (mut b, mut c, mut d) = (a, a, a);
        update_cdf_scalar(&mut a, s, n as u32);
        update_cdf(&mut b, s, n as u32); // whole vectors
        update_cdf(&mut d[..n + 1], s, n as u32); // just the CDF
        let mut ec = Ec::new();
        symbol_fixed(&mut ec, s, &mut c, 0, n as u32); // fixed size
        assert_eq!(a, b, "n {n} s {s}");
        assert_eq!(a, c, "n {n} s {s}");
        assert_eq!(a, d, "n {n} s {s}");
    }
}

/// The spec's symbol decoder (8.2.2 .. 8.2.6), as the C++ writer's DecSink.
struct Dec<'a> {
    data: &'a [u8],
    bitpos: usize,
    value: u32,
    range: u32,
    max_bits: i64,
}

impl<'a> Dec<'a> {
    fn f(&mut self, n: u32) -> u32 {
        let mut x = 0;
        for _ in 0..n {
            let b = self
                .data
                .get(self.bitpos >> 3)
                .map_or(0, |d| (d >> (7 - (self.bitpos & 7))) & 1);
            x = 2 * x + b as u32;
            self.bitpos += 1;
        }
        x
    }
    fn new(data: &'a [u8]) -> Self {
        let mut d = Dec {
            data,
            bitpos: 0,
            value: 0,
            range: 1 << 15,
            max_bits: 8 * data.len() as i64 - 15,
        };
        let num_bits = (data.len() * 8).min(15) as u32;
        let buf = d.f(num_bits);
        d.value = ((1 << 15) - 1) ^ (buf << (15 - num_bits));
        d
    }
    fn read(&mut self, cdf: &mut [u16], n: u32, adapt: bool) -> u32 {
        let (mut cur, mut prev);
        cur = self.range;
        let mut symbol = -1i32;
        loop {
            symbol += 1;
            prev = cur;
            let fq = (1u32 << 15) - cdf[symbol as usize] as u32;
            cur = ((self.range >> 8) * (fq >> 6)) >> 1;
            cur += 4 * (n - symbol as u32 - 1);
            if self.value >= cur {
                break;
            }
        }
        self.range = prev - cur;
        self.value -= cur;
        let bits = 15 - (31 - self.range.leading_zeros());
        self.range <<= bits;
        let num_bits = (bits as i64).min(self.max_bits.max(0)) as u32;
        let new_data = self.f(num_bits);
        let padded = new_data << (bits - num_bits);
        self.value = padded ^ (((self.value + 1) << bits) - 1);
        self.max_bits -= bits as i64;
        if adapt {
            update_cdf_scalar(cdf, symbol as u32, n);
        }
        symbol as u32
    }
}

/// Symbol streams decode back to themselves, with the same final CDFs (no oracle needed).
#[test]
fn symbol_streams_decode_back() {
    let mut rnd = Rng(0x5eed_0004);
    let mut ec = Ec::new();
    for case in 0..40 {
        let n = rnd.below(100_000) as usize;
        let syms = random_symstream(&mut rnd, n);
        let qidx = rnd.below(256) as i32;
        let mut cdf = Cdfs::new(qidx);
        code_symbols(&syms, &mut cdf, &mut ec);
        let mut out = Vec::new();
        ec.finish(&mut out);
        let mut dcdf = Cdfs::new(qidx);
        let w = dcdf.words_mut();
        let mut dec = Dec::new(&out);
        for (i, &x) in syms.iter().enumerate() {
            let (kind, s, n, off) = (x >> 24, (x >> 16) & 15, ((x >> 20) & 15) + 1, (x & 0xFFFF) as usize);
            let got = match kind {
                SYM_ADAPT => dec.read(&mut w[off..], n, true),
                SYM_BOOL => dec.read(&mut [16384, 32768, 0], 2, false),
                _ => {
                    let p = split_or_psum(&w[off..], kind == SYM_SPLIT_OR_VERT);
                    dec.read(&mut [(32768 - p) as u16, 32768, 0], 2, false)
                }
            };
            assert_eq!(got, s, "case {case} symbol {i}");
        }
        assert!(dcdf == cdf, "case {case}");
    }
}

#[cfg(feature = "oracle")]
mod oracle {
    use super::*;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct Op {
        kind: u32,
        a: u32,
        b: u32,
        c: u32,
    }

    unsafe extern "C" {
        fn oracle_entropy_cdfs_init(qidx: i32, out: *mut u16);
        fn oracle_entropy_coeff_cdf_q_ctx(qidx: i32) -> i32;
        fn oracle_entropy_cdfs_layout(out: *mut i64);
        fn oracle_entropy_update_cdf(cdf: *mut u16, s: i32, n: i32);
        fn oracle_entropy_ops(ops: *const Op, n: u32, words: *mut u16, out: *mut u8, cap: u32) -> i32;
        fn oracle_entropy_split_or_psum(pc: *const u16, vert: i32) -> u32;
        fn oracle_entropy_sym_pack(kind: u32, cdf: u32, s: u32, n: u32) -> u32;
        fn oracle_entropy_code_symbols(
            syms: *const u32,
            n: u32,
            qidx: i32,
            out: *mut u8,
            cap: u32,
            cdfs: *mut u16,
        ) -> i32;
        fn oracle_entropy_bench_code_symbols(
            syms: *const u32,
            n: u32,
            qidx: i32,
            reps: i32,
            out: *mut u8,
            cap: u32,
            bytes: *mut i32,
        ) -> u64;
        fn oracle_entropy_dsp_set_layout(out: *mut i64);
        fn av1t_dsp_set_make(seed: u64) -> *const DspSet;
        fn av1t_dsp_set_free(set: *const DspSet);
    }

    /// av1t_dsp_set (av1core_test.h)
    #[repr(C)]
    struct DspSet {
        itx_count: i32,
        itx_flagged_count: i32,
        itx_cases: *const u8,
        itx_case_size: u32,
        itx_coeffs_per_case: u32,
        itx_residual_per_case: u32,
        itx_coeffs: *const i16,
        itx_residual: *const i32,
        itx_flags: *const u32,
        pred_count: i32,
        pred_cfl_count: i32,
        pred_side: i32,
        pred_cases: *const u8,
        pred_case_size: u32,
        pred_luma_size: u32,
        pred_planes: *const u8,
        pred_luma: *const u8,
        pred_out: *const u8,
        ec_count: i32,
        ec_qindex: i32,
        ec_symbol_count: i32,
        ec_capacity: u32,
        ec_cdfs_size: u32,
        ec_symbol_size: u32,
        ec_symbols: *const u8,
        ec_offsets: *const i32,
        ec_counts: *const i32,
        ec_sizes: *const i32,
        ec_bytes: *const u8,
        priv_: *mut u8,
    }

    /// av1t_sym
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct DspSym {
        cdf_off: u16,
        s: u16,
        n: u16,
        is_bool: u16,
    }

    fn c_init(q: i32) -> Vec<u16> {
        let mut v = vec![0u16; NCDF];
        unsafe { oracle_entropy_cdfs_init(q, v.as_mut_ptr()) };
        v
    }

    fn c_ops(ops: &[Op], words: &mut [u16]) -> Vec<u8> {
        let cap = (ops.len() * 4 + 64) as u32;
        let mut out = vec![0u8; cap as usize + 8];
        let n = unsafe {
            oracle_entropy_ops(
                ops.as_ptr(),
                ops.len() as u32,
                words.as_mut_ptr(),
                out.as_mut_ptr(),
                cap,
            )
        };
        assert!(n >= 0);
        out.truncate(n as usize);
        out
    }

    fn c_code_symbols(syms: &[u32], qidx: i32) -> (Vec<u8>, Vec<u16>) {
        let cap = (syms.len() * 2 + 64) as u32;
        let mut out = vec![0u8; cap as usize + 8];
        let mut cdfs = vec![0u16; NCDF];
        let n = unsafe {
            oracle_entropy_code_symbols(
                syms.as_ptr(),
                syms.len() as u32,
                qidx,
                out.as_mut_ptr(),
                cap,
                cdfs.as_mut_ptr(),
            )
        };
        assert!(n >= 0);
        out.truncate(n as usize);
        (out, cdfs)
    }

    #[test]
    fn cdfs_layout_matches_c() {
        let mut c = [0i64; 38];
        unsafe { oracle_entropy_cdfs_layout(c.as_mut_ptr()) };
        assert_eq!(c[0], size_of::<Cdfs>() as i64);
        let ours: Vec<i64> = cdfs_arrays().iter().map(|a| 2 * a.0 as i64).collect();
        assert_eq!(&c[1..], &ours[..]);
    }

    #[test]
    fn cdfs_init_matches_c_for_every_qindex() {
        for q in -1..=256 {
            assert_eq!(coeff_cdf_q_ctx(q) as i32, unsafe { oracle_entropy_coeff_cdf_q_ctx(q) });
            let ours = Cdfs::new(q);
            assert_eq!(&ours.words()[..], &c_init(q)[..], "qidx {q}");
            let mut again = Cdfs::new(255 - q);
            again.init(q);
            assert_eq!(again, ours);
        }
    }

    #[test]
    fn update_cdf_matches_c() {
        let mut rnd = Rng(77);
        for _ in 0..100_000 {
            let n = 2 + rnd.below(15) as usize;
            let mut a = [0u16; 17];
            random_cdf(&mut rnd, n, &mut a);
            let s = rnd.below(n as u32);
            let mut c = a;
            update_cdf(&mut a, s, n as u32);
            unsafe { oracle_entropy_update_cdf(c.as_mut_ptr(), s as i32, n as i32) };
            assert_eq!(a, c);
        }
    }

    #[test]
    fn split_or_psum_and_sym_pack_match_c() {
        let mut rnd = Rng(5);
        for _ in 0..20_000 {
            let mut pc = [0u16; 11];
            random_cdf(&mut rnd, 10, &mut pc);
            for vert in [false, true] {
                assert_eq!(split_or_psum(&pc, vert), unsafe {
                    oracle_entropy_split_or_psum(pc.as_ptr(), vert as i32)
                });
            }
            let (k, id, s, n) = (rnd.below(4), rnd.next(), rnd.next(), rnd.next());
            assert_eq!(sym_pack(k, id, s, n), unsafe { oracle_entropy_sym_pack(k, id, s, n) });
        }
    }

    /// Random operation sequences over random CDFs of every size, every kind of operation, with
    /// both symbol paths, from empty streams to long ones; bytes and final CDFs must match.
    #[test]
    fn random_ops_match_c() {
        let mut rnd = Rng(0x5eed_0001);
        for case in 0..400 {
            // 4 CDFs of each size 2..=16, then 4 partition-like CDFs of 10 symbols
            let mut words = vec![0u16; 4 * (3..=17).sum::<usize>() + 4 * 11];
            let mut cdfs = Vec::new();
            let mut at = 0;
            for n in 2..=16 {
                for _ in 0..4 {
                    random_cdf(&mut rnd, n, &mut words[at..]);
                    cdfs.push((at, n));
                    at += n + 1;
                }
            }
            let mut parts = Vec::new();
            for _ in 0..4 {
                random_cdf(&mut rnd, 10, &mut words[at..]);
                parts.push(at);
                at += 11;
            }
            let len = match case % 4 {
                0 => rnd.below(16) as usize,
                1 => rnd.below(1000) as usize,
                2 => rnd.below(20_000) as usize,
                _ => 50_000 + rnd.below(150_000) as usize,
            };
            // biased towards low symbols, like real streams; some cases with skewed CDFs only
            let ops: Vec<Op> = (0..len)
                .map(|_| {
                    let k = rnd.below(10);
                    let (off, n) = cdfs[rnd.below(cdfs.len() as u32) as usize];
                    let n = n as u32;
                    let s = if rnd.below(3) != 0 {
                        rnd.below(n.min(2))
                    } else {
                        rnd.below(n)
                    };
                    match k {
                        0 => Op {
                            kind: 1,
                            a: 0,
                            b: rnd.below(2),
                            c: 0,
                        },
                        1 => {
                            let bits = rnd.below(33);
                            Op {
                                kind: 2,
                                a: rnd.next(),
                                b: 0,
                                c: bits,
                            }
                        }
                        2 => Op {
                            kind: 3,
                            a: off as u32,
                            b: s,
                            c: n,
                        },
                        3 => Op {
                            kind: 4,
                            a: parts[rnd.below(4) as usize] as u32,
                            b: rnd.below(2),
                            c: rnd.below(2),
                        },
                        _ => Op {
                            kind: 0,
                            a: off as u32,
                            b: s,
                            c: n,
                        },
                    }
                })
                .collect();
            let mut cw = words.clone();
            let want = c_ops(&ops, &mut cw);
            let mut ec = Ec::with_capacity(16);
            let mut out = vec![0xAB];
            for _ in 0..2 {
                // twice: the encoder and the output buffer are reused
                let mut w = words.clone();
                out.truncate(1);
                for o in &ops {
                    match o.kind {
                        0 if rnd.below(2) == 0 => ec.symbol_dyn(o.b, &mut w[o.a as usize..], o.c),
                        0 => symbol_fixed(&mut ec, o.b, &mut w, o.a as usize, o.c),
                        1 => ec.bool(o.b != 0),
                        2 => ec.literal(o.a, o.c),
                        3 => ec.encode_cdf(o.b, &w[o.a as usize..], o.c),
                        _ => ec.split_or(&w[o.a as usize..], o.c != 0, o.b != 0),
                    }
                }
                assert!(ec.len() <= want.len());
                let n = ec.finish(&mut out);
                assert_eq!(n, want.len(), "case {case}");
                assert!(out[1..] == want[..], "case {case}: bytes differ");
                assert!(w == cw, "case {case}: CDFs differ");
                assert!(ec.is_empty());
            }
        }
    }

    /// Symbol streams on the real CDF layout, for every coefficient q context.
    #[test]
    fn code_symbols_matches_c() {
        let mut rnd = Rng(0x5eed_0002);
        for case in 0..200 {
            let qidx = [0, 20, 21, 60, 61, 120, 121, 255][case % 8];
            let n = if case % 5 == 0 {
                rnd.below(100) as usize
            } else {
                rnd.below(300_000) as usize
            };
            let syms = random_symstream(&mut rnd, n);
            let (want, want_cdfs) = c_code_symbols(&syms, qidx);
            let mut cdf = Cdfs::new(qidx);
            let mut ec = Ec::new();
            let mut out = Vec::new();
            code_symbols(&syms, &mut cdf, &mut ec);
            ec.finish(&mut out);
            assert!(out == want, "case {case}");
            assert!(cdf.words()[..] == want_cdfs[..], "case {case}");
        }
    }

    /// The range-coder cases the GPU is held to (av1t_dsp_set_make).
    #[test]
    fn dsp_set_ec_cases_match() {
        let mut l = [0i64; 4];
        unsafe { oracle_entropy_dsp_set_layout(l.as_mut_ptr()) };
        assert_eq!(
            l,
            [
                size_of::<DspSet>() as i64,
                offset_of!(DspSet, ec_count) as i64,
                offset_of!(DspSet, ec_symbols) as i64,
                offset_of!(DspSet, ec_bytes) as i64
            ]
        );
        for seed in [0u64, 1, 0x5eed] {
            // SAFETY: the set lives until av1t_dsp_set_free; the sizes are the set's own.
            unsafe {
                let set = &*av1t_dsp_set_make(seed);
                assert_eq!(set.ec_symbol_size as usize, size_of::<DspSym>());
                assert_eq!(set.ec_cdfs_size as usize, size_of::<Cdfs>());
                let syms = core::slice::from_raw_parts(set.ec_symbols as *const DspSym, set.ec_symbol_count as usize);
                let nec = set.ec_count as usize;
                let offs = core::slice::from_raw_parts(set.ec_offsets, nec);
                let cnts = core::slice::from_raw_parts(set.ec_counts, nec);
                let sizes = core::slice::from_raw_parts(set.ec_sizes, nec);
                let cap = set.ec_capacity as usize;
                let bytes = core::slice::from_raw_parts(set.ec_bytes, nec * cap);
                let mut ec = Ec::new();
                let mut out = Vec::new();
                for i in 0..nec {
                    let mut cdf = Cdfs::new(set.ec_qindex);
                    let w = cdf.words_mut();
                    for s in &syms[offs[i] as usize..][..cnts[i] as usize] {
                        if s.is_bool != 0 {
                            ec.bool(s.s != 0);
                        } else {
                            ec.symbol_dyn(s.s as u32, &mut w[s.cdf_off as usize..], s.n as u32);
                        }
                    }
                    out.clear();
                    let n = ec.finish(&mut out);
                    assert!(sizes[i] >= 0);
                    assert_eq!(n, sizes[i] as usize);
                    assert!(out[..] == bytes[i * cap..][..n], "seed {seed} stream {i}");
                }
                av1t_dsp_set_free(set);
            }
        }
    }

    /// Symbols per second, Rust vs C++ (`cargo test --release --no-default-features --features
    /// oracle -- --ignored --nocapture bench`).
    #[test]
    #[ignore]
    fn bench_symbols() {
        let mut rnd = Rng(0xbe9c);
        let n = 4_000_000;
        let syms = random_symstream(&mut rnd, n);
        let reps = 5;
        let qidx = 100;
        let cap = (n * 2 + 64) as u32;
        let mut cout = vec![0u8; cap as usize + 8];
        let mut cbytes = 0;
        let mut best_c = u64::MAX;
        let mut best_r = u64::MAX;
        let mut ec = Ec::new();
        let mut out = Vec::new();
        for _ in 0..7 {
            let ns = unsafe {
                oracle_entropy_bench_code_symbols(
                    syms.as_ptr(),
                    n as u32,
                    qidx,
                    reps,
                    cout.as_mut_ptr(),
                    cap,
                    &mut cbytes,
                )
            };
            best_c = best_c.min(ns);
            let t0 = std::time::Instant::now();
            for _ in 0..reps {
                let mut cdf = Cdfs::new(qidx);
                out.clear();
                code_symbols(core::hint::black_box(&syms), &mut cdf, &mut ec);
                ec.finish(&mut out);
            }
            best_r = best_r.min(t0.elapsed().as_nanos() as u64);
        }
        assert_eq!(out[..], cout[..cbytes as usize]);
        let rate = |ns: u64| (n as f64 * reps as f64) / (ns as f64 * 1e-9) / 1e6;
        println!(
            "code_symbols, {n} symbols x {reps}, {} bytes: C++ {:.1} Msym/s, Rust {:.1} Msym/s",
            out.len(),
            rate(best_c),
            rate(best_r)
        );
    }

    /// Random call-site ops for oracle_entropy_sites: mostly coefficient symbols, as a tile's.
    fn random_sites(rnd: &mut Rng, n: usize) -> Vec<u32> {
        // (site, contexts, N)
        const SITES: [(u32, u32, u32); 9] = [
            (0, 65, 2),
            (1, 40, 3),
            (2, 420, 4),
            (3, 210, 4),
            (4, 6, 2),
            (5, 4, 9),
            (6, 25, 13),
            (7, 6, 16),
            (8, 1, 2),
        ];
        (0..n)
            .map(|_| {
                let k = rnd.below(32);
                let site = match k {
                    0..=3 => 0,
                    4..=6 => 1,
                    7..=17 => 2,
                    18..=22 => 3,
                    23..=24 => 4,
                    25 => 5,
                    26 => 6,
                    27 => 7,
                    _ => 8,
                };
                let (_, nctx, nn) = SITES[site];
                let s = if rnd.below(4) != 0 {
                    rnd.below(nn.min(2))
                } else {
                    rnd.below(nn)
                };
                (site as u32) << 24 | rnd.below(nctx) << 8 | s
            })
            .collect()
    }

    /// The writer's way of coding: fixed-size CDF arrays at fixed call sites.
    #[inline(always)]
    fn rust_site(ec: &mut Ec, c: &mut Cdfs, op: u32) {
        let ctx = ((op >> 8) & 0xFFFF) as usize;
        let s = op & 0xFF;
        match op >> 24 {
            0 => ec.symbol(s, &mut c.txb_skip.as_flattened_mut()[ctx]),
            1 => ec.symbol(s, &mut c.coeff_base_eob.as_flattened_mut().as_flattened_mut()[ctx]),
            2 => ec.symbol(s, &mut c.coeff_base.as_flattened_mut().as_flattened_mut()[ctx]),
            3 => ec.symbol(s, &mut c.coeff_br.as_flattened_mut().as_flattened_mut()[ctx]),
            4 => ec.symbol(s, &mut c.dc_sign.as_flattened_mut()[ctx]),
            5 => ec.symbol(s, &mut c.eob_pt_256.as_flattened_mut()[ctx]),
            6 => ec.symbol(s, &mut c.y_mode.as_flattened_mut()[ctx]),
            7 => ec.symbol(s, &mut c.cfl_alpha[ctx]),
            _ => ec.bool(s != 0),
        }
    }

    unsafe extern "C" {
        fn oracle_entropy_sites(ops: *const u32, n: u32, qidx: i32, out: *mut u8, cap: u32) -> i32;
        fn oracle_entropy_bench_sites(
            ops: *const u32,
            n: u32,
            qidx: i32,
            reps: i32,
            out: *mut u8,
            cap: u32,
            bytes: *mut i32,
        ) -> u64;
    }

    #[test]
    fn fixed_call_sites_match_c() {
        let mut rnd = Rng(0x5eed_0003);
        for case in 0..50 {
            let n = rnd.below(200_000) as usize;
            let ops = random_sites(&mut rnd, n);
            let qidx = rnd.below(256) as i32;
            let cap = (n * 2 + 64) as u32;
            let mut want = vec![0u8; cap as usize + 8];
            let len = unsafe { oracle_entropy_sites(ops.as_ptr(), n as u32, qidx, want.as_mut_ptr(), cap) };
            want.truncate(len as usize);
            let mut c = Cdfs::new(qidx);
            let mut ec = Ec::new();
            for &op in &ops {
                rust_site(&mut ec, &mut c, op);
            }
            let mut out = Vec::new();
            ec.finish(&mut out);
            assert!(out == want, "case {case}");
        }
    }

    /// The same at the writer's fixed call sites.
    #[test]
    #[ignore]
    fn bench_call_sites() {
        let mut rnd = Rng(0xbe9d);
        let n = 4_000_000;
        let ops = random_sites(&mut rnd, n);
        let (reps, qidx) = (5, 100);
        let cap = (n * 2 + 64) as u32;
        let mut cout = vec![0u8; cap as usize + 8];
        let mut cbytes = 0;
        let (mut best_c, mut best_r) = (u64::MAX, u64::MAX);
        let mut ec = Ec::new();
        let mut out = Vec::new();
        for _ in 0..7 {
            let ns = unsafe {
                oracle_entropy_bench_sites(ops.as_ptr(), n as u32, qidx, reps, cout.as_mut_ptr(), cap, &mut cbytes)
            };
            best_c = best_c.min(ns);
            let t0 = std::time::Instant::now();
            for _ in 0..reps {
                let mut c = Cdfs::new(qidx);
                out.clear();
                for &op in core::hint::black_box(&ops) {
                    rust_site(&mut ec, &mut c, op);
                }
                ec.finish(&mut out);
            }
            best_r = best_r.min(t0.elapsed().as_nanos() as u64);
        }
        assert_eq!(out[..], cout[..cbytes as usize]);
        let rate = |ns: u64| (n as f64 * reps as f64) / (ns as f64 * 1e-9) / 1e6;
        println!(
            "call sites, {n} symbols x {reps}, {} bytes: C++ {:.1} Msym/s, Rust {:.1} Msym/s",
            out.len(),
            rate(best_c),
            rate(best_r)
        );
    }
}
