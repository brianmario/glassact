use super::tuneiq::*;
use super::*;

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

unsafe extern "C" {
    fn snprintf(buf: *mut core::ffi::c_char, n: usize, fmt: *const core::ffi::c_char, ...) -> i32;
}

/// The hex float writer is printf's `%a` (the system's libc) for floats widened to double.
#[test]
fn hex_floats_are_printf_a() {
    let mut rnd = Rng(0x4e3f);
    let mut vals: Vec<f32> = vec![
        0.0, -0.0, 1.0, -1.0, 0.5, 2.0, 0.1, 1e-45, -1e-45, 1e-38, 3.4e38, 1.5, 0.75,
    ];
    vals.extend(
        (0..200_000)
            .map(|_| f32::from_bits(rnd.next()))
            .filter(|v| v.is_finite()),
    );
    vals.extend((0..20_000).map(|_| (rnd.next() as f32 / 1e6) * if rnd.below(2) == 0 { 1.0 } else { -1.0 }));
    for v in vals {
        let mut ours = String::new();
        tables::hexf(&mut ours, v as f64);
        let mut buf = [0u8; 64];
        let n = unsafe { snprintf(buf.as_mut_ptr().cast(), 64, c"%a".as_ptr(), v as f64) };
        assert_eq!(ours.as_bytes(), &buf[..n as usize], "{v:e}");
    }
}

#[test]
fn tuneiq_spot_values() {
    // libaom's tables at qindex 0: no deblocking, CDEF off
    let t = tuneiq_frame_init(0, 1, 1, false);
    assert_eq!((t.lf_level, t.cdef_mode, t.delta_q_res, t.qm_y), (0, 0, 1, 10));
    assert_eq!(qindex_for_quality(100), 0);
    assert_eq!(qindex_for_quality(0), 255);
    let mut v = [0u32; 64];
    for (i, x) in v.iter_mut().enumerate() {
        *x = 63 - i as u32;
    }
    assert_eq!(sb_variance(&mut v), (31 + 2 * 39 + 47 + 2) / 4);
}

mod snapshots {
    use super::*;
    use crate::testsupport::snapshot::Snapshot;

    use crate::types::{FrameParams, GaCdefCand};

    fn random_fp(rnd: &mut Rng) -> FrameParams {
        let mut b = [0u8; size_of::<FrameParams>()];
        b.iter_mut().for_each(|x| *x = rnd.next() as u8);
        // SAFETY: FrameParams is repr(C) of integers only; any bit pattern is valid.
        unsafe { core::mem::transmute(b) }
    }

    #[test]
    fn tuneiq_frame_snapshot_every_qindex() {
        let mut s = Snapshot::new(&["frame_init", "tuneiq_frame", "fill_fp", "rdmult_q"]);
        let mut rnd = Rng(0x7e1a);
        for base in (-8..=263).chain([1000, -1000]) {
            for mono in [false, true] {
                for (ssx, ssy) in [(1, 1), (1, 0), (0, 0), (0, 1)] {
                    let t = tuneiq_frame_init(base, ssx, ssy, mono);
                    let ours = [
                        t.base_q_idx,
                        t.dq_u_dc,
                        t.dq_u_ac,
                        t.dq_v_dc,
                        t.dq_v_ac,
                        t.qm_y,
                        t.qm_u,
                        t.qm_v,
                        t.delta_q_res,
                        t.lf_level,
                        t.lf_sharpness,
                        t.cdef_damping,
                        t.cdef_mode,
                        t.rdmult,
                    ];
                    s.put("frame_init", &ours);
                }
                s.put("tuneiq_frame", &(tuneiq_frame(base, mono)));
                if (0..=255).contains(&base) {
                    let mut a = random_fp(&mut rnd);
                    tuneiq_fill_fp(&mut a, base, mono);
                    s.put("fill_fp", &a);
                }
                s.put("rdmult_q", &(frame_rdmult(base)));
                s.put("rdmult_q", &(dc_q(base)));
                s.put("rdmult_q", &(ac_q(base)));
                s.put("rdmult_q", &(delta_q_res(base)));
            }
        }
        s.check_arch(
            &[
                ("frame_init", 0x27e2f8c740af2cf5),
                ("tuneiq_frame", 0xa3e20ba066099a25),
                ("fill_fp", 0x1f901f599e4e5ebd),
                ("rdmult_q", 0x07003bc3fbd256a1),
            ],
            &[
                ("frame_init", 0x4ae937f15171c005),
                ("tuneiq_frame", 0xa50192df7678e4f9),
                ("fill_fp", 0x1f901f599e4e5ebd),
                ("rdmult_q", 0x64330e6441014a2d),
            ],
        );
    }

    #[test]
    fn tuneiq_helpers_snapshot() {
        let mut s = Snapshot::new(&[
            "qindex_for_quality",
            "chroma_delta_q",
            "qm_level",
            "q_helpers",
            "sb_variance",
        ]);
        let mut rnd = Rng(0x7e1b);
        for q in -5..=105 {
            s.put("qindex_for_quality", &(qindex_for_quality(q)));
        }
        for base in -20..=300 {
            for (ssx, ssy) in [(1, 1), (1, 0), (0, 0), (0, 1), (2, 2)] {
                s.put("chroma_delta_q", &(chroma_delta_q(base, ssx, ssy)));
            }
            for _ in 0..8 {
                let (first, last) = (rnd.below(12) as i32, rnd.below(16) as i32);
                s.put("qm_level", &(qm_level_allintra(base, first, last)));
                s.put("qm_level", &(qm_level_444_chroma(base, first, last)));
            }
        }
        for _ in 0..100_000 {
            let v = rnd.next() as i32 >> rnd.below(32);
            s.put("q_helpers", &(log2i(v)));
            let res = 1 << rnd.below(4);
            let (prev, cur) = (rnd.below(300) as i32 - 20, rnd.below(300) as i32 - 20);
            s.put("q_helpers", &(adjust_q(res, prev, cur)));
            let (sum, sse) = (rnd.below(64 * 255 * 2) as i32 - 64 * 255, rnd.next());
            s.put("q_helpers", &(var8x8_from_sums(sum, sse)));
        }
        for _ in 0..20_000 {
            let mut v = [0u32; 64];
            let sh = rnd.below(31);
            let m = 1 + rnd.below(1 << sh);
            v.iter_mut().for_each(|x| *x = rnd.next() % m);
            s.put("sb_variance", &(sb_variance(&mut v)));
            s.put("sb_variance", &v);
        }
        s.check(&[
            ("qindex_for_quality", 0x16c2f85959c0cf6c),
            ("chroma_delta_q", 0x13b59f64e9a1afc5),
            ("qm_level", 0x656483f39f9c9c85),
            ("q_helpers", 0xb15fca98bbd55694),
            ("sb_variance", 0x1cd2af752f6b1967),
        ]);
    }

    /// Every (base, variance < 1024) pair, as the C++ checks the GPU, for several strengths, and
    /// large variances.
    #[test]
    fn varboost_snapshot() {
        let mut s = Snapshot::new(&["varboost"]);
        let mut rnd = Rng(0x7e1c);
        for pct in [0, 25, 50, 100, 150, 200, 300, -10] {
            for base in 0..=255 {
                for var in 0..1024 {
                    s.put("varboost", &(varboost_qindex(base, var, pct)));
                }
                for _ in 0..64 {
                    let var = rnd.next() >> rnd.below(32);
                    s.put("varboost", &(varboost_qindex(base, var, pct)));
                }
            }
        }
        s.check(&[("varboost", 0x9ed85a8c092e3e1e)]);
    }

    #[test]
    fn cdef_bits_snapshot() {
        let mut s = Snapshot::new(&["cdef_bits"]);
        let mut rnd = Rng(0xcdef_0001);
        for _ in 0..200_000 {
            let max_bits = rnd.below(4) as i32;
            let scale = rnd.below(40);
            let tots: Vec<u64> = (0..=max_bits)
                .map(|_| ((rnd.next() as u64) << 8 | rnd.below(256) as u64) >> scale)
                .collect();
            let (n_active, mono) = (rnd.below(20_000) as i32, rnd.below(2) != 0);
            let rdmult = frame_rdmult(rnd.below(256) as i32);
            s.put("cdef_bits", &(cdef_bits(&tots, max_bits, n_active, mono, rdmult)));
        }
        s.check(&[("cdef_bits", 0xfe19e29b0989fb45)]);
    }

    #[test]
    fn cdef_presets_snapshot() {
        let mut s = Snapshot::new(&["cdef_presets"]);
        let mut rnd = Rng(0xcdef_0002);
        for _ in 0..100_000 {
            let mut cd = GaCdefCand {
                npri: 1 + rnd.below(16) as i32,
                nsec: 1 + rnd.below(4) as i32,
                ..Default::default()
            };
            cd.pri.iter_mut().for_each(|p| *p = rnd.below(16) as i32);
            cd.sec.iter_mut().for_each(|s| *s = [0, 1, 2, 4][rnd.below(4) as usize]);
            let ncand = (cd.npri * cd.nsec) as u32;
            let mut lev = [0i32; 16];
            lev.iter_mut().for_each(|l| *l = rnd.below(ncand) as i32);
            let (bits, mode) = (rnd.below(4) as i32, rnd.below(3) as i32);
            let mut a = random_fp(&mut rnd);
            a.monochrome = rnd.below(2) as u8;
            cdef_presets(&lev, bits, mode, &cd, &mut a);
            s.put("cdef_presets", &a);
        }
        s.check(&[("cdef_presets", 0x734601277d2d1ec1)]);
    }

    #[test]
    fn cdef_select_snapshot() {
        let mut s = Snapshot::new(&["lev", "tot"]);
        let mut rnd = Rng(0xcdef_0003);
        for case in 0..600 {
            let nc = [1, 2, 4, 8, 16][rnd.below(5) as usize];
            let nsb = 1 + rnd.below(if case % 4 == 0 { 400 } else { 40 }) as usize;
            let mono = rnd.below(3) == 0;
            let (max_bits, refine, fast_mono) = (rnd.below(4) as usize, rnd.below(3) as usize, rnd.below(2) != 0);
            let shift = rnd.below(24);
            let my: Vec<u32> = (0..nsb * nc).map(|_| rnd.next() >> shift).collect();
            let muv: Vec<u32> = (0..nsb * nc).map(|_| rnd.next() >> shift).collect();
            let (mut lev, mut tot) = (vec![-1i32; (max_bits + 1) * 16], vec![0u64; max_bits + 1]);
            let muv_r: &[u32] = if mono && rnd.below(2) == 0 { &[] } else { &muv };
            cdef_select_cpu(
                &my, muv_r, nc, nsb, mono, max_bits, refine, fast_mono, &mut lev, &mut tot,
            );
            s.put("lev", &lev);
            s.put("tot", &tot);
        }
        s.check(&[("lev", 0xd86a70f165f3d2f5), ("tot", 0x50905a459c953060)]);
    }

    #[test]
    fn tables_msl_snapshot() {
        let mut s = Snapshot::new(&["msl"]);
        let ours = tables_msl();
        s.put("msl", ours.as_str());
        s.check(&[("msl", 0x0ab5c016d14c4785)]);
    }
}

/// The post-filters' frame says 4:4:4 (`chroma444`, in the C struct's padding after `mono`) for a
/// 4:4:4 record, and nothing new for a 4:2:0 one (pf_frame_snapshot pins 4:2:0's bytes).
#[test]
fn pf_frame_marks_444() {
    use crate::types::{CHROMA_444, DECISIONS_VERSION, FrameParams, GaPfAddrs};
    let mut fp = FrameParams {
        version: DECISIONS_VERSION,
        width: 640,
        height: 360,
        ..Default::default()
    };
    let a = GaPfAddrs::default();
    let f = pf_frame(&fp, &a);
    assert_eq!(f.chroma444, 0);
    assert_eq!(&f.as_bytes()[20..24], &[0; 4]);
    fp.chroma_format = CHROMA_444;
    let f = pf_frame(&fp, &a);
    assert_eq!(f.chroma444, 1);
    assert_eq!(&f.as_bytes()[20..24], &1i32.to_ne_bytes());
    // a version 1 record is 4:2:0 whatever its chroma_format
    fp.version = 1;
    assert_eq!(pf_frame(&fp, &a).chroma444, 0);
}
