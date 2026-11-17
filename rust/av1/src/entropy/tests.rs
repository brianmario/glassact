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

/// Symbol streams decode back to themselves, with the same final CDFs.
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

mod snapshots {
    use super::*;
    use crate::testsupport::snapshot::Snapshot;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct Op {
        kind: u32,
        a: u32,
        b: u32,
        c: u32,
    }

    #[test]
    fn cdfs_layout_snapshot() {
        let mut s = Snapshot::new(&["layout"]);
        let ours: Vec<i64> = cdfs_arrays().iter().map(|a| 2 * a.0 as i64).collect();
        s.put("layout", &(size_of::<Cdfs>() as i64, &ours, cdfs_arrays()));
        s.check(&[("layout", 0xda2dad485ea2dd20)]);
    }

    #[test]
    fn cdfs_init_snapshot_every_qindex() {
        let mut s = Snapshot::new(&["q_ctx", "init"]);
        for q in -1..=256 {
            s.put("q_ctx", &(coeff_cdf_q_ctx(q) as i32));
            let ours = Cdfs::new(q);
            s.put("init", &ours.words()[..]);
            let mut again = Cdfs::new(255 - q);
            again.init(q);
            assert_eq!(again, ours);
        }
        s.check(&[("q_ctx", 0x8a6605b526f8ce85), ("init", 0xd9920981252d9fc1)]);
    }

    #[test]
    fn update_cdf_snapshot() {
        let mut snap = Snapshot::new(&["update_cdf"]);
        let mut rnd = Rng(77);
        for _ in 0..100_000 {
            let n = 2 + rnd.below(15) as usize;
            let mut a = [0u16; 17];
            random_cdf(&mut rnd, n, &mut a);
            let s = rnd.below(n as u32);
            update_cdf(&mut a, s, n as u32);
            snap.put("update_cdf", &a);
        }
        snap.check(&[("update_cdf", 0x5b26227d7eaccefd)]);
    }

    #[test]
    fn split_or_psum_and_sym_pack_snapshot() {
        let mut snap = Snapshot::new(&["split_or_psum", "sym_pack"]);
        let mut rnd = Rng(5);
        for _ in 0..20_000 {
            let mut pc = [0u16; 11];
            random_cdf(&mut rnd, 10, &mut pc);
            for vert in [false, true] {
                snap.put("split_or_psum", &(split_or_psum(&pc, vert)));
            }
            let (k, id, s, n) = (rnd.below(4), rnd.next(), rnd.next(), rnd.next());
            snap.put("sym_pack", &(sym_pack(k, id, s, n)));
        }
        snap.check(&[("split_or_psum", 0xf98a343a823fe632), ("sym_pack", 0x25df9c2d4253ab04)]);
    }

    /// Random operation sequences over random CDFs of every size, every kind of operation, with
    /// both symbol paths, from empty streams to long ones; bytes and final CDFs must match.
    #[test]
    fn random_ops_snapshot() {
        let mut snap = Snapshot::new(&["bytes", "cdfs"]);
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
                let n = ec.finish(&mut out);
                assert_eq!(n, out.len() - 1);
                snap.put("bytes", &out[1..]);
                snap.put("cdfs", &w);
                assert!(ec.is_empty());
            }
        }
        snap.check(&[("bytes", 0x974addcab69a9529), ("cdfs", 0x3f2e7e2ba1d65b6d)]);
    }

    /// Symbol streams on the real CDF layout, for every coefficient q context.
    #[test]
    fn code_symbols_snapshot() {
        let mut snap = Snapshot::new(&["bytes", "cdfs"]);
        let mut rnd = Rng(0x5eed_0002);
        for case in 0..200 {
            let qidx = [0, 20, 21, 60, 61, 120, 121, 255][case % 8];
            let n = if case % 5 == 0 {
                rnd.below(100) as usize
            } else {
                rnd.below(300_000) as usize
            };
            let syms = random_symstream(&mut rnd, n);
            let mut cdf = Cdfs::new(qidx);
            let mut ec = Ec::new();
            let mut out = Vec::new();
            code_symbols(&syms, &mut cdf, &mut ec);
            ec.finish(&mut out);
            snap.put("bytes", &out);
            snap.put("cdfs", &cdf.words()[..]);
        }
        snap.check(&[("bytes", 0x4feaf66ef83f1621), ("cdfs", 0xa3d63afb950b70d1)]);
    }

    /// The range-coder cases the GPU is held to (av1t_dsp_set_make).
    #[test]
    fn dsp_set_ec_cases_snapshot() {
        let mut snap = Snapshot::new(&["bytes"]);
        for seed in [0u64, 1, 0x5eed] {
            // the set's streams (testsupport's dsp_sets_snapshot pins the set), hashed
            let set = crate::testsupport::DspSet::make(seed);
            let cap = set.ec_capacity as usize;
            let mut ec = Ec::new();
            let mut out = Vec::new();
            for i in 0..set.ec_offsets.len() {
                let mut cdf = Cdfs::new(set.ec_qindex);
                let w = cdf.words_mut();
                for s in &set.ec_symbols[set.ec_offsets[i] as usize..][..set.ec_counts[i] as usize] {
                    if s.is_bool != 0 {
                        ec.bool(s.s != 0);
                    } else {
                        ec.symbol_dyn(s.s as u32, &mut w[s.cdf_off as usize..], s.n as u32);
                    }
                }
                out.clear();
                let n = ec.finish(&mut out);
                assert_eq!(n, set.ec_sizes[i] as usize);
                assert!(out[..] == set.ec_bytes[i * cap..][..n], "seed {seed} stream {i}");
                snap.put("bytes", &out);
            }
        }
        snap.check(&[("bytes", 0x7bb99b42b8b5e390)]);
    }

    /// Random call-site ops: mostly coefficient symbols, as a tile's.
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

    #[test]
    fn fixed_call_sites_snapshot() {
        let mut snap = Snapshot::new(&["bytes"]);
        let mut rnd = Rng(0x5eed_0003);
        for _ in 0..50 {
            let n = rnd.below(200_000) as usize;
            let ops = random_sites(&mut rnd, n);
            let qidx = rnd.below(256) as i32;
            let mut c = Cdfs::new(qidx);
            let mut ec = Ec::new();
            for &op in &ops {
                rust_site(&mut ec, &mut c, op);
            }
            let mut out = Vec::new();
            ec.finish(&mut out);
            snap.put("bytes", &out);
        }
        snap.check(&[("bytes", 0xa0ef67171ac8fabf)]);
    }
}
