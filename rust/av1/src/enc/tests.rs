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

#[cfg(feature = "oracle")]
mod oracle {
    use super::*;

    unsafe extern "C" {
        fn oracle_enc_qindex_for_quality(q: i32) -> i32;
        fn oracle_enc_chroma_delta_q(base: i32, ssx: i32, ssy: i32, out: *mut i32);
        fn oracle_enc_qm_level_allintra(q: i32, first: i32, last: i32) -> i32;
        fn oracle_enc_qm_level_444_chroma(q: i32, first: i32, last: i32) -> i32;
        fn oracle_enc_delta_q_res(base: i32) -> i32;
        fn oracle_enc_log2i(v: i32) -> i32;
        fn oracle_enc_adjust_q(res: i32, prev: i32, cur: i32) -> i32;
        fn oracle_enc_varboost_qindex(base: i32, variance: u32, pct: i32) -> i32;
        fn oracle_enc_sb_variance(v: *mut u32) -> u32;
        fn oracle_enc_var8x8_from_sums(sum: i32, sse: u32) -> u32;
        fn oracle_enc_frame_rdmult(base: i32) -> i32;
        fn oracle_enc_dc_q(q: i32) -> i32;
        fn oracle_enc_ac_q(q: i32) -> i32;
        fn oracle_enc_tuneiq_frame_init(base: i32, ssx: i32, ssy: i32, mono: i32, out: *mut i32);
        fn oracle_enc_tuneiq_fill_fp(fp: *mut FrameParams, base: i32, mono: i32);
        fn av1enc_tuneiq_frame(base: i32, mono: i32, out: *mut GaTuneiqFrame);
        fn av1enc_cdef_bits(tots: *const u64, max_bits: i32, n_active: i32, mono: i32, rdmult: i32) -> i32;
        fn av1enc_cdef_presets(lev: *const i32, bits: i32, mode: i32, cd: *const GaCdefCand, fp: *mut FrameParams);
        fn av1enc_cdef_select_cpu(
            my: *const u32,
            muv: *const u32,
            nc: i32,
            nsb: i32,
            mono: i32,
            max_bits: i32,
            refine: i32,
            fast_mono: i32,
            lev_out: *mut i32,
            tot_out: *mut u64,
        );
        fn av1enc_tables_msl(length: *mut usize) -> *mut core::ffi::c_char;
        fn free(p: *mut core::ffi::c_void);
    }
    use crate::types::{FrameParams, GaCdefCand, GaTuneiqFrame};

    fn random_fp(rnd: &mut Rng) -> FrameParams {
        let mut b = [0u8; size_of::<FrameParams>()];
        b.iter_mut().for_each(|x| *x = rnd.next() as u8);
        // SAFETY: FrameParams is repr(C) of integers only; any bit pattern is valid.
        unsafe { core::mem::transmute(b) }
    }

    #[test]
    fn tuneiq_frame_matches_c_for_every_qindex() {
        let mut rnd = Rng(0x7e1a);
        for base in (-8..=263).chain([1000, -1000]) {
            for mono in [false, true] {
                for (ssx, ssy) in [(1, 1), (1, 0), (0, 0), (0, 1)] {
                    let mut c = [0i32; 14];
                    unsafe { oracle_enc_tuneiq_frame_init(base, ssx, ssy, mono as i32, c.as_mut_ptr()) };
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
                    assert_eq!(ours, c, "base {base} mono {mono} ss {ssx}{ssy}");
                }
                let mut g = GaTuneiqFrame::default();
                unsafe { av1enc_tuneiq_frame(base, mono as i32, &mut g) };
                assert_eq!(tuneiq_frame(base, mono), g, "base {base}");
                if (0..=255).contains(&base) {
                    let mut a = random_fp(&mut rnd);
                    let mut b = a;
                    tuneiq_fill_fp(&mut a, base, mono);
                    unsafe { oracle_enc_tuneiq_fill_fp(&mut b, base, mono as i32) };
                    assert_eq!(a, b, "base {base}");
                }
                assert_eq!(frame_rdmult(base), unsafe { oracle_enc_frame_rdmult(base) });
                assert_eq!(dc_q(base), unsafe { oracle_enc_dc_q(base) });
                assert_eq!(ac_q(base), unsafe { oracle_enc_ac_q(base) });
                assert_eq!(delta_q_res(base), unsafe { oracle_enc_delta_q_res(base) });
            }
        }
    }

    #[test]
    fn tuneiq_helpers_match_c() {
        let mut rnd = Rng(0x7e1b);
        for q in -5..=105 {
            assert_eq!(qindex_for_quality(q), unsafe { oracle_enc_qindex_for_quality(q) });
        }
        for base in -20..=300 {
            for (ssx, ssy) in [(1, 1), (1, 0), (0, 0), (0, 1), (2, 2)] {
                let mut c = [0i32; 4];
                unsafe { oracle_enc_chroma_delta_q(base, ssx, ssy, c.as_mut_ptr()) };
                assert_eq!(chroma_delta_q(base, ssx, ssy), c);
            }
            for _ in 0..8 {
                let (first, last) = (rnd.below(12) as i32, rnd.below(16) as i32);
                assert_eq!(qm_level_allintra(base, first, last), unsafe {
                    oracle_enc_qm_level_allintra(base, first, last)
                });
                assert_eq!(qm_level_444_chroma(base, first, last), unsafe {
                    oracle_enc_qm_level_444_chroma(base, first, last)
                });
            }
        }
        for _ in 0..100_000 {
            let v = rnd.next() as i32 >> rnd.below(32);
            assert_eq!(log2i(v), unsafe { oracle_enc_log2i(v) });
            let res = 1 << rnd.below(4);
            let (prev, cur) = (rnd.below(300) as i32 - 20, rnd.below(300) as i32 - 20);
            assert_eq!(adjust_q(res, prev, cur), unsafe { oracle_enc_adjust_q(res, prev, cur) });
            let (sum, sse) = (rnd.below(64 * 255 * 2) as i32 - 64 * 255, rnd.next());
            assert_eq!(var8x8_from_sums(sum, sse), unsafe {
                oracle_enc_var8x8_from_sums(sum, sse)
            });
        }
        for _ in 0..20_000 {
            let mut v = [0u32; 64];
            let sh = rnd.below(31);
            let m = 1 + rnd.below(1 << sh);
            v.iter_mut().for_each(|x| *x = rnd.next() % m);
            let mut c = v;
            assert_eq!(sb_variance(&mut v), unsafe { oracle_enc_sb_variance(c.as_mut_ptr()) });
            assert_eq!(v, c);
        }
    }

    /// Every (base, variance < 1024) pair, as the C++ checks the GPU, for several strengths, and
    /// large variances.
    #[test]
    fn varboost_matches_c() {
        let mut rnd = Rng(0x7e1c);
        for pct in [0, 25, 50, 100, 150, 200, 300, -10] {
            for base in 0..=255 {
                for var in 0..1024 {
                    assert_eq!(varboost_qindex(base, var, pct), unsafe {
                        oracle_enc_varboost_qindex(base, var, pct)
                    });
                }
                for _ in 0..64 {
                    let var = rnd.next() >> rnd.below(32);
                    assert_eq!(varboost_qindex(base, var, pct), unsafe {
                        oracle_enc_varboost_qindex(base, var, pct)
                    });
                }
            }
        }
    }

    #[test]
    fn cdef_bits_matches_c() {
        let mut rnd = Rng(0xcdef_0001);
        for _ in 0..200_000 {
            let max_bits = rnd.below(4) as i32;
            let scale = rnd.below(40);
            let tots: Vec<u64> = (0..=max_bits)
                .map(|_| ((rnd.next() as u64) << 8 | rnd.below(256) as u64) >> scale)
                .collect();
            let (n_active, mono) = (rnd.below(20_000) as i32, rnd.below(2) != 0);
            let rdmult = frame_rdmult(rnd.below(256) as i32);
            assert_eq!(cdef_bits(&tots, max_bits, n_active, mono, rdmult), unsafe {
                av1enc_cdef_bits(tots.as_ptr(), max_bits, n_active, mono as i32, rdmult)
            });
        }
    }

    #[test]
    fn cdef_presets_match_c() {
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
            let mut b = a;
            cdef_presets(&lev, bits, mode, &cd, &mut a);
            unsafe { av1enc_cdef_presets(lev.as_ptr(), bits, mode, &cd, &mut b) };
            assert_eq!(a, b);
        }
    }

    #[test]
    fn cdef_select_matches_c() {
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
            let (mut clev, mut ctot) = (lev.clone(), tot.clone());
            let muv_r: &[u32] = if mono && rnd.below(2) == 0 { &[] } else { &muv };
            cdef_select_cpu(
                &my, muv_r, nc, nsb, mono, max_bits, refine, fast_mono, &mut lev, &mut tot,
            );
            unsafe {
                av1enc_cdef_select_cpu(
                    my.as_ptr(),
                    muv.as_ptr(),
                    nc as i32,
                    nsb as i32,
                    mono as i32,
                    max_bits as i32,
                    refine as i32,
                    fast_mono as i32,
                    clev.as_mut_ptr(),
                    ctot.as_mut_ptr(),
                )
            };
            assert_eq!(lev, clev, "case {case}");
            assert_eq!(tot, ctot, "case {case}");
        }
    }

    #[test]
    fn tables_msl_matches_c() {
        let mut n = 0usize;
        let want = unsafe {
            let p = av1enc_tables_msl(&mut n);
            assert!(!p.is_null());
            let v = core::slice::from_raw_parts(p as *const u8, n).to_vec();
            assert_eq!(*p.add(n), 0);
            free(p.cast());
            v
        };
        let ours = tables_msl();
        if ours.as_bytes() != want {
            let at = ours
                .bytes()
                .zip(&want)
                .position(|(a, b)| a != *b)
                .unwrap_or(ours.len().min(want.len()));
            let ctx =
                |s: &[u8]| String::from_utf8_lossy(&s[at.saturating_sub(80)..(at + 80).min(s.len())]).into_owned();
            panic!(
                "differ at byte {at} (lengths {} {}):\n ours {}\n C++  {}",
                ours.len(),
                want.len(),
                ctx(ours.as_bytes()),
                ctx(&want)
            );
        }
    }
}
