use super::*;

const ALL_TX: core::ops::Range<i32> = 0..TX_SIZES_ALL;

fn random_edge(r: &mut Rng, smooth: bool) -> Edge {
    let mut e = [0u8; EDGE_LEN];
    let mut v = r.below(256) as i32;
    for x in e.iter_mut() {
        if smooth {
            v = clip1(v + r.range(-6, 6));
            *x = v as u8;
        } else {
            *x = r.next() as u8;
        }
    }
    e
}

/// Dequantized-coefficient patterns: sparse low-frequency, dense, near the 16-bit limits, and (with
/// `wild`) beyond them.
fn random_dq(r: &mut Rng, n: usize, wild: bool) -> Vec<i32> {
    let mut dq = vec![0i32; n];
    match r.below(if wild { 5 } else { 4 }) {
        0 => {
            for _ in 0..1 + r.below(12) {
                let pos = if r.below(3) == 0 {
                    r.below(n as u32)
                } else {
                    r.below(n.min(16) as u32)
                } as usize;
                dq[pos] = r.range(-3000, 3000);
            }
        }
        1 => {
            for v in dq.iter_mut() {
                *v = if r.below(4) == 0 { r.range(-400, 400) } else { 0 };
            }
        }
        2 => {
            for v in dq.iter_mut() {
                *v = r.range(-32768, 32767);
            }
        }
        3 => {
            for _ in 0..1 + r.below(4) {
                dq[r.below(n as u32) as usize] = if r.below(2) == 0 { -32768 } else { 32767 };
            }
        }
        _ => {
            for v in dq.iter_mut().take(1 + r.below(n as u32) as usize) {
                *v = (r.next() as i32) >> r.below(16);
            }
        }
    }
    dq
}

#[test]
fn inv_txfm2d_simd_matches_scalar() {
    let mut r = Rng(0x1234_5678_9abc_def1);
    let (mut res_a, mut res_b) = (vec![0i32; 4096], vec![0i32; 4096]);
    let mut flagged = 0;
    for _ in 0..40 {
        for tx_sz in ALL_TX {
            for tx_type in 0..TX_TYPES {
                let dq = random_dq(&mut r, tx_coeffs(tx_sz), true);
                let fa = inv_txfm2d(&dq, tx_sz, tx_type, &mut res_a);
                let fb = inv_txfm2d_scalar(&dq, tx_sz, tx_type, &mut res_b);
                let n = (tx_w(tx_sz) * tx_h(tx_sz)) as usize;
                assert_eq!(fa, fb, "flags tx {tx_sz} type {tx_type}");
                assert_eq!(res_a[..n], res_b[..n], "residual tx {tx_sz} type {tx_type}");
                flagged += (fb != 0) as u32;
            }
        }
    }
    assert!(flagged > 100, "only {flagged} non-conformant cases");
}

#[test]
fn dequant_matches_per_coefficient() {
    let mut r = Rng(6);
    let mut out = vec![0i32; 1024];
    for _ in 0..200 {
        for tx_sz in ALL_TX {
            let n = tx_coeffs(tx_sz);
            let q: Vec<i16> = (0..n)
                .map(|_| match r.below(3) {
                    0 => 0,
                    1 => r.range(-32768, 32767) as i16,
                    _ => r.range(-60, 60) as i16,
                })
                .collect();
            let qi = r.range(0, 255);
            let (dcq, acq) = (dc_q(qi), ac_q(qi));
            let m = qm(r.below(2) == 0, r.range(0, 15), r.range(0, 2), tx_sz, DCT_DCT);
            dequant(&q, &mut out, tx_sz, dcq, acq, m);
            for i in 0..n {
                let want = if q[i] != 0 {
                    dequant_coef(
                        q[i] as i32,
                        qm_step(if i == 0 { dcq } else { acq }, m, i),
                        dq_denom(tx_sz),
                    )
                } else {
                    0
                };
                assert_eq!(out[i], want, "tx {tx_sz} coef {i}");
            }
        }
    }
}

#[test]
fn block_predictors_match_per_pixel() {
    let mut r = Rng(77);
    let mut d1 = vec![0u8; 64 * 80];
    let mut d2 = vec![0u8; 64 * 80];
    for tx_sz in ALL_TX {
        let (lw, lh) = (
            Tx_Width_Log2[tx_sz as usize] as i32,
            Tx_Height_Log2[tx_sz as usize] as i32,
        );
        for mode in 0..INTRA_MODES {
            for delta in -3..=3 {
                if delta != 0 && !is_directional(mode) {
                    continue;
                }
                for k in 0..4 {
                    let (above, left) = (random_edge(&mut r, k & 2 != 0), random_edge(&mut r, k & 2 != 0));
                    let (hl, ha) = (r.below(2) == 0, r.below(2) == 0);
                    predict_intra(mode, delta, hl, ha, lw, lh, &above, &left, &mut d1, 80);
                    predict_intra_ref(mode, delta, hl, ha, lw, lh, &above, &left, &mut d2, 80);
                    assert_eq!(d1, d2, "tx {tx_sz} mode {mode} delta {delta}");
                    // with the edge filter (and upsampling)
                    let (ft, x, y) = (r.below(2) as i32, r.range(0, 8), r.range(0, 8));
                    let (mx, my) = (x + (1 << lw) + r.range(-1, 40), y + (1 << lh) + r.range(-1, 40));
                    let fi = if mode == DC_PRED && lw <= 5 && lh <= 5 && r.below(2) == 0 {
                        r.range(0, 4)
                    } else {
                        -1
                    };
                    let (mut a1, mut l1, mut a2, mut l2) = (above, left, above, left);
                    predict_intra_ex(
                        mode, delta, fi, true, ft, hl, ha, lw, lh, x, y, mx, my, &mut a1, &mut l1, &mut d1, 80,
                    );
                    predict_intra_ex_ref(
                        mode, delta, fi, true, ft, hl, ha, lw, lh, x, y, mx, my, &mut a2, &mut l2, &mut d2, 80,
                    );
                    assert_eq!(d1, d2, "ex tx {tx_sz} mode {mode} delta {delta}");
                    assert!(a1 == a2 && l1 == l2);
                }
            }
        }
    }
}

#[test]
fn nondirectional_simd_matches_scalar() {
    let mut r = Rng(5);
    let (mut d1, mut d2) = (vec![0u8; 64 * 64], vec![0u8; 64 * 64]);
    for _ in 0..50 {
        for tx_sz in ALL_TX {
            let (lw, lh) = (
                Tx_Width_Log2[tx_sz as usize] as i32,
                Tx_Height_Log2[tx_sz as usize] as i32,
            );
            for mode in [SMOOTH_PRED, SMOOTH_V_PRED, SMOOTH_H_PRED, PAETH_PRED] {
                let (a, l) = (random_edge(&mut r, false), random_edge(&mut r, false));
                nondirectional(mode, lw, lh, &a, &l, &mut d1, 64);
                nondirectional_scalar(mode, lw, lh, &a, &l, &mut d2, 64);
                assert_eq!(d1, d2, "tx {tx_sz} mode {mode}");
            }
        }
    }
}

#[test]
fn interp_row_simd_matches_scalar() {
    let mut r = Rng(9);
    for n in 0..70 {
        for extra in [1, 9, 17] {
            let e: Vec<u8> = (0..n + extra).map(|_| r.next() as u8).collect();
            for shift in 0..32 {
                let (mut a, mut b) = (vec![0u8; n], vec![0u8; n]);
                interp_row(&mut a, &e, shift);
                interp_row_scalar(&mut b, &e, shift);
                assert_eq!(a, b);
            }
        }
    }
}

// ---- micro-benchmarks: cargo test --release dsp::tests::bench -- --ignored --nocapture ----

fn time_ns(iters: u32, mut f: impl FnMut()) -> f64 {
    for _ in 0..iters / 10 + 1 {
        f();
    }
    let t = std::time::Instant::now();
    for _ in 0..iters {
        f();
    }
    t.elapsed().as_nanos() as f64 / iters as f64
}

#[test]
#[ignore]
fn bench_inv_txfm2d() {
    let mut r = Rng(1);
    let mut res = vec![0i32; 4096];
    for (tx_sz, ty) in [
        (TX_4X4, DCT_DCT),
        (TX_4X4, ADST_ADST),
        (TX_8X8, DCT_DCT),
        (TX_8X8, ADST_DCT),
        (TX_16X16, DCT_DCT),
        (TX_16X16, ADST_ADST),
        (TX_16X8, DCT_DCT),
        (TX_32X32, DCT_DCT),
        (TX_32X32, IDTX),
        (TX_64X64, DCT_DCT),
    ] {
        // a typical quantized block: the low-frequency quarter populated
        let (tw, th) = (tx_w(tx_sz).min(32) as usize, tx_h(tx_sz).min(32) as usize);
        let mut dq = vec![0i32; tw * th];
        for i in 0..th.div_ceil(2) {
            for j in 0..tw.div_ceil(2) {
                dq[i * tw + j] = r.range(-600, 600);
            }
        }
        let s = time_ns(20000, || {
            std::hint::black_box(inv_txfm2d_scalar(std::hint::black_box(&dq), tx_sz, ty, &mut res));
        });
        let v = time_ns(20000, || {
            std::hint::black_box(inv_txfm2d(std::hint::black_box(&dq), tx_sz, ty, &mut res));
        });
        println!(
            "inv_txfm2d {}x{} type {ty:2}: scalar {s:8.1} ns  simd {v:8.1} ns  ({:.1}x)",
            tw.max(tx_w(tx_sz) as usize),
            tx_h(tx_sz),
            s / v
        );
    }
}

#[test]
#[ignore]
fn bench_dequant_add_residual_edges() {
    let mut r = Rng(4);
    let mut out = vec![0i32; 1024];
    let mut pl: Vec<u8> = (0..80 * 80).map(|_| r.next() as u8).collect();
    for (tx_sz, name) in [
        (TX_4X4, "4x4"),
        (TX_8X8, "8x8"),
        (TX_16X16, "16x16"),
        (TX_32X32, "32x32"),
    ] {
        let n = tx_coeffs(tx_sz);
        let q: Vec<i16> = (0..n)
            .map(|i| if i < n / 4 { r.range(-20, 20) as i16 } else { 0 })
            .collect();
        let m = qm(true, 8, 0, tx_sz, DCT_DCT);
        let a = time_ns(50000, || {
            dequant(std::hint::black_box(&q), &mut out, tx_sz, 40, 48, None)
        });
        let b = time_ns(50000, || dequant(std::hint::black_box(&q), &mut out, tx_sz, 40, 48, m));
        let res: Vec<i32> = (0..tx_w(tx_sz) * tx_h(tx_sz)).map(|_| r.range(-40, 40)).collect();
        let c = time_ns(50000, || {
            add_residual(&mut pl[81..], 80, std::hint::black_box(&res), tx_sz, DCT_DCT)
        });
        let d = time_ns(50000, || {
            add_residual(&mut pl[81..], 80, std::hint::black_box(&res), tx_sz, FLIPADST_FLIPADST)
        });
        let (lw, lh) = (
            Tx_Width_Log2[tx_sz as usize] as i32,
            Tx_Height_Log2[tx_sz as usize] as i32,
        );
        let (mut ea, mut el) = ([0u8; EDGE_LEN], [0u8; EDGE_LEN]);
        let e = time_ns(50000, || {
            build_edges(
                std::hint::black_box(&pl),
                80,
                8,
                8,
                lw,
                lh,
                true,
                true,
                true,
                true,
                79,
                79,
                &mut ea,
                &mut el,
            )
        });
        println!(
            "{name:5}: dequant {a:6.1} ns (qm {b:6.1})  add_residual {c:6.1} ns (flipped {d:6.1})  build_edges {e:6.1} ns"
        );
    }
}

#[test]
#[ignore]
fn bench_predict_intra() {
    let mut r = Rng(2);
    let (above, left) = (random_edge(&mut r, true), random_edge(&mut r, true));
    let mut dst = vec![0u8; 64 * 64];
    for (tx_sz, name) in [
        (TX_4X4, "4x4"),
        (TX_8X8, "8x8"),
        (TX_16X16, "16x16"),
        (TX_32X32, "32x32"),
        (TX_64X64, "64x64"),
    ] {
        let (lw, lh) = (
            Tx_Width_Log2[tx_sz as usize] as i32,
            Tx_Height_Log2[tx_sz as usize] as i32,
        );
        for (mode, delta, mname) in [
            (DC_PRED, 0, "DC"),
            (V_PRED, 0, "V"),
            (D45_PRED, 1, "D45+1"),
            (D135_PRED, -2, "D135-2"),
            (D203_PRED, 2, "D203+2"),
            (SMOOTH_PRED, 0, "SMOOTH"),
            (SMOOTH_V_PRED, 0, "SMOOTH_V"),
            (PAETH_PRED, 0, "PAETH"),
        ] {
            let s = time_ns(20000, || {
                predict_intra_ref(mode, delta, true, true, lw, lh, &above, &left, &mut dst, 64);
                std::hint::black_box(&dst);
            });
            let v = time_ns(20000, || {
                predict_intra(mode, delta, true, true, lw, lh, &above, &left, &mut dst, 64);
                std::hint::black_box(&dst);
            });
            println!(
                "predict {name:5} {mname:8}: per-pixel {s:8.1} ns  block {v:8.1} ns  ({:.1}x)",
                s / v
            );
        }
    }
}

#[test]
#[ignore]
fn bench_nondirectional_scalar_vs_neon() {
    let mut r = Rng(3);
    let (above, left) = (random_edge(&mut r, true), random_edge(&mut r, true));
    let mut dst = vec![0u8; 64 * 64];
    for (tx_sz, name) in [(TX_8X8, "8x8"), (TX_16X16, "16x16"), (TX_32X32, "32x32")] {
        let (lw, lh) = (
            Tx_Width_Log2[tx_sz as usize] as i32,
            Tx_Height_Log2[tx_sz as usize] as i32,
        );
        for (mode, mname) in [
            (SMOOTH_PRED, "SMOOTH"),
            (SMOOTH_H_PRED, "SMOOTH_H"),
            (PAETH_PRED, "PAETH"),
        ] {
            let s = time_ns(50000, || {
                nondirectional_scalar(mode, lw, lh, &above, &left, &mut dst, 64);
                std::hint::black_box(&dst);
            });
            let v = time_ns(50000, || {
                nondirectional(mode, lw, lh, &above, &left, &mut dst, 64);
                std::hint::black_box(&dst);
            });
            println!(
                "{mname:8} {name:5}: scalar {s:7.1} ns  simd {v:7.1} ns  ({:.1}x)",
                s / v
            );
        }
    }
}

// ---- differential tests against the C++ (oracle/dsp.cpp, av1core_test.h) ----

#[cfg(feature = "oracle")]
mod oracle {
    use super::*;
    use core::ffi::{c_char, c_int};

    unsafe extern "C" {
        fn oracle_dsp_int(what: *const c_char, a: c_int, b: c_int, c: c_int, d: c_int) -> i64;
        fn oracle_dsp_get_scan(tx_sz: c_int, tx_type: c_int) -> *const u16;
        fn oracle_dsp_qm(using: c_int, level: c_int, plane: c_int, tx_sz: c_int, tx_type: c_int) -> *const u8;
        fn oracle_dsp_dequant(
            q: *const i16,
            out: *mut i32,
            tx_sz: c_int,
            dcq: c_int,
            acq: c_int,
            using: c_int,
            level: c_int,
            plane: c_int,
            tx_type: c_int,
        );
        fn oracle_dsp_inv_1d(t: *mut i32, kind: c_int, n: c_int, r: c_int, err: *mut u32);
        fn oracle_dsp_add_residual(dst: *mut u8, stride: c_int, res: *const i32, tx_sz: c_int, tx_type: c_int);
        fn oracle_dsp_build_edges(
            plane: *const u8,
            stride: c_int,
            x: c_int,
            y: c_int,
            lw: c_int,
            lh: c_int,
            hl: c_int,
            ha: c_int,
            har: c_int,
            hbl: c_int,
            mx: c_int,
            my: c_int,
            above: *mut u8,
            left: *mut u8,
        );
        fn oracle_dsp_dc_value(above: *const u8, left: *const u8, hl: c_int, ha: c_int, lw: c_int, lh: c_int) -> c_int;
        fn oracle_dsp_pred_pixel_up(
            mode: c_int,
            p_angle: c_int,
            i: c_int,
            j: c_int,
            lw: c_int,
            lh: c_int,
            above: *const u8,
            left: *const u8,
            up_a: c_int,
            up_l: c_int,
        ) -> c_int;
        fn oracle_dsp_edge_filter(buf: *mut u8, sz: c_int, strength: c_int);
        fn oracle_dsp_edge_upsample(buf: *mut u8, num_px: c_int);
        fn oracle_dsp_edge_prepare(
            p_angle: c_int,
            lw: c_int,
            lh: c_int,
            ft: c_int,
            hl: c_int,
            ha: c_int,
            x: c_int,
            y: c_int,
            mx: c_int,
            my: c_int,
            above: *mut u8,
            left: *mut u8,
            up_a: *mut c_int,
            up_l: *mut c_int,
        );
        fn oracle_dsp_predict_filter_intra(
            mode: c_int,
            lw: c_int,
            lh: c_int,
            above: *const u8,
            left: *const u8,
            dst: *mut u8,
            stride: c_int,
        );
        fn oracle_dsp_predict_intra(
            mode: c_int,
            delta: c_int,
            hl: c_int,
            ha: c_int,
            lw: c_int,
            lh: c_int,
            above: *const u8,
            left: *const u8,
            dst: *mut u8,
            stride: c_int,
        );
        fn oracle_dsp_predict_intra_ex(
            mode: c_int,
            delta: c_int,
            fi: c_int,
            ef: c_int,
            ft: c_int,
            hl: c_int,
            ha: c_int,
            lw: c_int,
            lh: c_int,
            x: c_int,
            y: c_int,
            mx: c_int,
            my: c_int,
            above: *mut u8,
            left: *mut u8,
            dst: *mut u8,
            stride: c_int,
        );
        fn oracle_dsp_cfl_predict(
            chroma: *mut u8,
            cstride: c_int,
            luma: *const u8,
            lstride: c_int,
            sx: c_int,
            sy: c_int,
            tx_sz: c_int,
            subx: c_int,
            suby: c_int,
            mlw: c_int,
            mlh: c_int,
            alpha: c_int,
        );
        // Sources/AV1CoreTestSupport (av1core_test.h)
        fn av1t_inverse_transform(tx_sz: i32, tx_type: i32, dq: *const i32, res: *mut i32) -> u32;
        fn av1t_dsp_set_make(seed: u64) -> *const DspSet;
        fn av1t_dsp_set_free(set: *const DspSet);
    }

    fn ci(what: &str, a: i32, b: i32, c: i32, d: i32) -> i64 {
        let s = std::ffi::CString::new(what).unwrap();
        // SAFETY: plain ints; the shim knows `what` or returns a sentinel.
        let v = unsafe { oracle_dsp_int(s.as_ptr(), a, b, c, d) };
        assert_ne!(v, -999999, "oracle_dsp_int doesn't know {what}");
        v
    }

    #[test]
    fn helpers_match() {
        for t in ALL_TX {
            for red in 0..2 {
                assert_eq!(
                    get_tx_set_intra(t, red != 0) as i64,
                    ci("get_tx_set_intra", t, red, 0, 0)
                );
                for m in 0..UV_INTRA_MODES_CFL_ALLOWED {
                    assert_eq!(
                        chroma_tx_type(t, m, red != 0) as i64,
                        ci("chroma_tx_type", t, m, red, 0)
                    );
                }
            }
            assert_eq!(dq_denom(t) as i64, ci("dq_denom", t, 0, 0, 0));
            for ty in 0..TX_TYPES {
                let s = get_scan(t, ty);
                // illegal combinations (a V_* type on 32x32) get a shorter table, as in the C++
                let n = s.len().min(tx_coeffs(t));
                // SAFETY: the C table is the same one, with at least n entries.
                let c = unsafe { core::slice::from_raw_parts(oracle_dsp_get_scan(t, ty), n) };
                assert_eq!(&s[..n], c, "scan {t} {ty}");
                for level in 0..17 {
                    for plane in 0..3 {
                        for using in 0..2 {
                            // SAFETY: plain ints; a null or a table pointer comes back.
                            let p = unsafe { oracle_dsp_qm(using, level, plane, t, ty) };
                            match qm(using != 0, level, plane, t, ty) {
                                None => assert!(p.is_null()),
                                // SAFETY: a non-null av1g_qm points at tx_coeffs weights.
                                Some(m) => assert_eq!(m, unsafe { core::slice::from_raw_parts(p, tx_coeffs(t)) }),
                            }
                        }
                    }
                }
            }
        }
        for ty in 0..TX_TYPES {
            assert_eq!(tx_class(ty) as i64, ci("tx_class", ty, 0, 0, 0));
            assert_eq!(row_kind(ty) as i64, ci("row_kind", ty, 0, 0, 0));
            assert_eq!(col_kind(ty) as i64, ci("col_kind", ty, 0, 0, 0));
            assert_eq!(flip_ud(ty) as i64, ci("flip_ud", ty, 0, 0, 0));
            assert_eq!(flip_lr(ty) as i64, ci("flip_lr", ty, 0, 0, 0));
        }
        for q in -20..300 {
            assert_eq!(dc_q(q) as i64, ci("dc_q", q, 0, 0, 0));
            assert_eq!(ac_q(q) as i64, ci("ac_q", q, 0, 0, 0));
            assert_eq!(qm_level_allintra(q) as i64, ci("qm_level_allintra", q, 0, 0, 0));
        }
        let mut r = Rng(3);
        for _ in 0..20000 {
            let (qv, q, den) = (
                r.range(-32768, 32767),
                r.range(4, 20000),
                [1, 2, 4][r.below(3) as usize],
            );
            assert_eq!(dequant_coef(qv, q, den) as i64, ci("dequant_coef", qv, q, den, 0));
            let (x, n) = (r.next() as i32 >> r.below(20), r.range(0, 12));
            assert_eq!(round2signed(x, n) as i64, ci("round2signed", x, n, 0, 0));
        }
        for w in [4, 8, 16, 32, 64] {
            for h in [4, 8, 16, 32, 64] {
                for ft in 0..2 {
                    for d in -100..100 {
                        assert_eq!(edge_strength(w, h, ft, d) as i64, ci("edge_strength", w, h, ft, d));
                        assert_eq!(
                            edge_use_upsample(w, h, ft, d) as i64,
                            ci("edge_use_upsample", w, h, ft, d)
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn dequant_matches() {
        let mut r = Rng(11);
        let (mut a, mut b) = (vec![0i32; 1024], vec![0i32; 1024]);
        for _ in 0..30 {
            for t in ALL_TX {
                for ty in [DCT_DCT, ADST_ADST, FLIPADST_DCT, IDTX, V_DCT] {
                    let n = tx_coeffs(t);
                    let quant: Vec<i16> = (0..n)
                        .map(|_| match r.below(4) {
                            0 => 0,
                            1 => r.range(-32768, 32767) as i16,
                            _ => r.range(-50, 50) as i16,
                        })
                        .collect();
                    let qi = r.range(0, 255);
                    let (dcq, acq) = (dc_q(qi), ac_q(qi));
                    let (using, level, plane) = (r.below(2) as i32, r.range(0, 15), r.range(0, 2));
                    dequant(&quant, &mut a, t, dcq, acq, qm(using != 0, level, plane, t, ty));
                    // SAFETY: n coefficients in and out.
                    unsafe { oracle_dsp_dequant(quant.as_ptr(), b.as_mut_ptr(), t, dcq, acq, using, level, plane, ty) };
                    assert_eq!(a[..n], b[..n], "tx {t} type {ty} qm {using} {level}");
                }
            }
        }
    }

    #[test]
    fn inv_1d_matches() {
        let mut r = Rng(12);
        for _ in 0..3000 {
            let kind = r.range(0, 2);
            let n = r.range(2, 6);
            let rr = [16, 16, 31, r.range(8, 31)][r.below(4) as usize];
            let mut t = [0i32; 64];
            let lim = r.below(31);
            for v in t.iter_mut().take(1 << n) {
                *v = (r.next() as i32) >> lim;
            }
            let mut c = t;
            let (mut e1, mut e2) = (0u32, 0u32);
            inv_1d(&mut t, kind, n, rr, &mut e1);
            // SAFETY: 64 entries.
            unsafe { oracle_dsp_inv_1d(c.as_mut_ptr(), kind, n, rr, &mut e2) };
            assert_eq!(t, c, "kind {kind} n {n} r {rr}");
            assert_eq!(e1, e2);
        }
    }

    #[test]
    fn inv_txfm2d_matches() {
        let mut r = Rng(13);
        let (mut a, mut b) = (vec![0i32; 4096], vec![0i32; 4096]);
        let mut flagged = [0u32; 3];
        for _ in 0..60 {
            for t in ALL_TX {
                for ty in 0..TX_TYPES {
                    let dq = random_dq(&mut r, tx_coeffs(t), true);
                    let n = (tx_w(t) * tx_h(t)) as usize;
                    let fa = inv_txfm2d(&dq, t, ty, &mut a);
                    // SAFETY: tx_coeffs in, w * h out.
                    let fb = unsafe { av1t_inverse_transform(t, ty, dq.as_ptr(), b.as_mut_ptr()) };
                    assert_eq!(fa, fb, "flags tx {t} type {ty}");
                    assert_eq!(a[..n], b[..n], "tx {t} type {ty}");
                    flagged[fb as usize & 1] += 1;
                    flagged[2] += (fb & 2 != 0) as u32;
                }
            }
        }
        assert!(flagged[1] > 100 && flagged[2] > 10, "flag coverage {flagged:?}");
    }

    #[test]
    fn add_residual_matches() {
        let mut r = Rng(14);
        for t in ALL_TX {
            for ty in 0..TX_TYPES {
                let (w, h) = (tx_w(t) as usize, tx_h(t) as usize);
                let res: Vec<i32> = (0..w * h).map(|_| r.range(-300, 300)).collect();
                let mut p: Vec<u8> = (0..72 * 70).map(|_| r.next() as u8).collect();
                let mut q = p.clone();
                add_residual(&mut p[72 + 3..], 72, &res, t, ty);
                // SAFETY: the block fits the 72 x 70 buffer at (3, 1).
                unsafe { oracle_dsp_add_residual(q.as_mut_ptr().add(72 + 3), 72, res.as_ptr(), t, ty) };
                assert_eq!(p, q, "tx {t} type {ty}");
            }
        }
    }

    const PW: usize = 160;

    /// A random av1t_pred_case-like setup: (x, y, maxX, maxY) within a PW x PW plane.
    fn edge_case(r: &mut Rng, lw: i32, lh: i32, hl: bool, ha: bool) -> (i32, i32, i32, i32) {
        let x = if hl { 1 + r.range(0, 7) } else { 0 };
        let y = if ha { 1 + r.range(0, 7) } else { 0 };
        let mx = (x + (1 << lw) + r.range(0, 63) - 1).min(PW as i32 - 1);
        let my = (y + (1 << lh) + r.range(0, 63) - 1).min(PW as i32 - 1);
        (x, y, mx, my)
    }

    #[test]
    fn build_edges_and_dc_match() {
        let mut r = Rng(15);
        let plane: Vec<u8> = (0..PW * PW).map(|_| r.next() as u8).collect();
        for _ in 0..20 {
            for t in ALL_TX {
                let (lw, lh) = (Tx_Width_Log2[t as usize] as i32, Tx_Height_Log2[t as usize] as i32);
                for k in 0..16 {
                    let (hl, ha, har, hbl) = (k & 1 != 0, k & 2 != 0, k & 4 != 0, k & 8 != 0);
                    let (x, y, mx, my) = edge_case(&mut r, lw, lh, hl, ha);
                    let fill = r.next() as u8;
                    let (mut a1, mut l1) = ([fill; EDGE_LEN], [fill; EDGE_LEN]);
                    let (mut a2, mut l2) = (a1, l1);
                    build_edges(&plane, PW, x, y, lw, lh, hl, ha, har, hbl, mx, my, &mut a1, &mut l1);
                    // SAFETY: the plane and EDGE_LEN-byte arrays the C function indexes.
                    unsafe {
                        oracle_dsp_build_edges(
                            plane.as_ptr(),
                            PW as i32,
                            x,
                            y,
                            lw,
                            lh,
                            hl as i32,
                            ha as i32,
                            har as i32,
                            hbl as i32,
                            mx,
                            my,
                            a2.as_mut_ptr(),
                            l2.as_mut_ptr(),
                        )
                    };
                    assert!(a1 == a2 && l1 == l2, "tx {t} flags {k}");
                    // SAFETY: EDGE_LEN-byte arrays.
                    let dc = unsafe { oracle_dsp_dc_value(a1.as_ptr(), l1.as_ptr(), hl as i32, ha as i32, lw, lh) };
                    assert_eq!(dc_value(&a1, &l1, hl, ha, lw, lh), dc);
                }
            }
        }
    }

    #[test]
    fn edge_filter_upsample_prepare_match() {
        let mut r = Rng(16);
        for _ in 0..3000 {
            let smooth = r.below(2) == 0;
            let e = random_edge(&mut r, smooth);
            let (sz, strength) = (r.range(1, 129), r.range(0, 3));
            let (mut a, mut b) = (e, e);
            edge_filter(&mut a, sz, strength);
            // SAFETY: an EDGE_LEN-byte array; sz <= 129.
            unsafe { oracle_dsp_edge_filter(b.as_mut_ptr(), sz, strength) };
            assert_eq!(a, b, "edge_filter {sz} {strength}");
            let n = r.range(1, 24);
            let (mut a, mut b) = (e, e);
            edge_upsample(&mut a, n);
            // SAFETY: an EDGE_LEN-byte array; numPx <= 24.
            unsafe { oracle_dsp_edge_upsample(b.as_mut_ptr(), n) };
            assert_eq!(a, b, "edge_upsample {n}");
        }
        for _ in 0..20 {
            for t in ALL_TX {
                let (lw, lh) = (Tx_Width_Log2[t as usize] as i32, Tx_Height_Log2[t as usize] as i32);
                for mode in V_PRED..=D67_PRED {
                    for delta in -3..=3 {
                        let p_angle = Mode_To_Angle[mode as usize] as i32 + delta * ANGLE_STEP;
                        let (hl, ha, ft) = (r.below(2) == 0, r.below(2) == 0, r.below(2) as i32);
                        let (x, y, mx, my) = edge_case(&mut r, lw, lh, hl, ha);
                        let (mut a1, mut l1) = (random_edge(&mut r, true), random_edge(&mut r, true));
                        let (mut a2, mut l2) = (a1, l1);
                        let up = edge_prepare(p_angle, lw, lh, ft, hl, ha, x, y, mx, my, &mut a1, &mut l1);
                        let (mut ua, mut ul) = (0, 0);
                        // SAFETY: EDGE_LEN-byte arrays.
                        unsafe {
                            oracle_dsp_edge_prepare(
                                p_angle,
                                lw,
                                lh,
                                ft,
                                hl as i32,
                                ha as i32,
                                x,
                                y,
                                mx,
                                my,
                                a2.as_mut_ptr(),
                                l2.as_mut_ptr(),
                                &mut ua,
                                &mut ul,
                            )
                        };
                        assert_eq!(up, (ua, ul));
                        assert!(a1 == a2 && l1 == l2, "edge_prepare tx {t} angle {p_angle}");
                        // the per-pixel predictor on the (possibly upsampled) edges
                        for i in 0..1 << lh {
                            for j in 0..1 << lw {
                                let v = pred_pixel_up(mode, p_angle, i, j, lw, lh, &a1, &l1, ua, ul);
                                // SAFETY: EDGE_LEN-byte arrays.
                                let c = unsafe {
                                    oracle_dsp_pred_pixel_up(
                                        mode,
                                        p_angle,
                                        i,
                                        j,
                                        lw,
                                        lh,
                                        a1.as_ptr(),
                                        l1.as_ptr(),
                                        ua,
                                        ul,
                                    )
                                };
                                assert_eq!(v, c);
                            }
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn predict_intra_matches() {
        let mut r = Rng(17);
        let (mut d1, mut d2) = (vec![0u8; 80 * 70], vec![0u8; 80 * 70]);
        for rep in 0..4 {
            for t in ALL_TX {
                let (lw, lh) = (Tx_Width_Log2[t as usize] as i32, Tx_Height_Log2[t as usize] as i32);
                for mode in 0..INTRA_MODES {
                    for delta in -3..=3 {
                        for k in 0..4 {
                            let (hl, ha) = (k & 1 != 0, k & 2 != 0);
                            let (above, left) = (random_edge(&mut r, rep & 1 == 0), random_edge(&mut r, rep & 1 == 0));
                            d1.fill(7);
                            d2.fill(7);
                            predict_intra(mode, delta, hl, ha, lw, lh, &above, &left, &mut d1[80 + 1..], 80);
                            // SAFETY: EDGE_LEN-byte arrays; the block fits d2 at (1, 1).
                            unsafe {
                                oracle_dsp_predict_intra(
                                    mode,
                                    delta,
                                    hl as i32,
                                    ha as i32,
                                    lw,
                                    lh,
                                    above.as_ptr(),
                                    left.as_ptr(),
                                    d2.as_mut_ptr().add(80 + 1),
                                    80,
                                )
                            };
                            assert_eq!(d1, d2, "tx {t} mode {mode} delta {delta} flags {k}");
                            // with the edge filter / upsampling / filter intra
                            let (x, y, mx, my) = edge_case(&mut r, lw, lh, hl, ha);
                            let fi = if lw <= 5 && lh <= 5 && r.below(3) == 0 {
                                r.range(0, 4)
                            } else {
                                -1
                            };
                            let (ef, ft) = (r.below(4) != 0, r.below(2) as i32);
                            let (mut a1, mut l1, mut a2, mut l2) = (above, left, above, left);
                            predict_intra_ex(
                                mode,
                                delta,
                                fi,
                                ef,
                                ft,
                                hl,
                                ha,
                                lw,
                                lh,
                                x,
                                y,
                                mx,
                                my,
                                &mut a1,
                                &mut l1,
                                &mut d1[80 + 1..],
                                80,
                            );
                            // SAFETY: as above.
                            unsafe {
                                oracle_dsp_predict_intra_ex(
                                    mode,
                                    delta,
                                    fi,
                                    ef as i32,
                                    ft,
                                    hl as i32,
                                    ha as i32,
                                    lw,
                                    lh,
                                    x,
                                    y,
                                    mx,
                                    my,
                                    a2.as_mut_ptr(),
                                    l2.as_mut_ptr(),
                                    d2.as_mut_ptr().add(80 + 1),
                                    80,
                                )
                            };
                            assert_eq!(d1, d2, "ex tx {t} mode {mode} delta {delta} fi {fi} ef {ef}");
                            assert!(a1 == a2 && l1 == l2);
                        }
                    }
                }
                if lw <= 5 && lh <= 5 {
                    for mode in 0..5 {
                        let (above, left) = (random_edge(&mut r, true), random_edge(&mut r, true));
                        predict_filter_intra(mode, lw, lh, &above, &left, &mut d1, 80);
                        // SAFETY: as above.
                        unsafe {
                            oracle_dsp_predict_filter_intra(
                                mode,
                                lw,
                                lh,
                                above.as_ptr(),
                                left.as_ptr(),
                                d2.as_mut_ptr(),
                                80,
                            )
                        };
                        assert_eq!(d1, d2, "filter intra tx {t} mode {mode}");
                    }
                }
            }
        }
    }

    #[test]
    fn cfl_predict_matches() {
        let mut r = Rng(18);
        let luma: Vec<u8> = (0..2 * PW * 2 * PW).map(|_| r.next() as u8).collect();
        for _ in 0..30 {
            for t in ALL_TX {
                let (lw, lh) = (Tx_Width_Log2[t as usize] as i32, Tx_Height_Log2[t as usize] as i32);
                if lw > 5 || lh > 5 {
                    continue;
                }
                let (x, y) = (r.range(0, 60), r.range(0, 60));
                let (subx, suby) = (r.range(0, 1), r.range(0, 1));
                let mlw = ((x + (1 << lw)) << subx) - r.range(0, 3) * 4;
                let mlh = ((y + (1 << lh)) << suby) - r.range(0, 3) * 4;
                let (mlw, mlh) = (mlw.max(4), mlh.max(4));
                let alpha = r.range(-16, 16);
                let mut c1: Vec<u8> = (0..PW * PW).map(|_| r.next() as u8).collect();
                let mut c2 = c1.clone();
                cfl_predict(&mut c1, PW, &luma, 2 * PW, x, y, t, subx, suby, mlw, mlh, alpha);
                // SAFETY: the planes cover every sample the C function reads or writes.
                unsafe {
                    oracle_dsp_cfl_predict(
                        c2.as_mut_ptr(),
                        PW as i32,
                        luma.as_ptr(),
                        2 * PW as i32,
                        x,
                        y,
                        t,
                        subx,
                        suby,
                        mlw,
                        mlh,
                        alpha,
                    )
                };
                assert_eq!(c1, c2, "tx {t} sub {subx}{suby}");
            }
        }
    }

    // av1g_test/dsp_cases.h: the cases the GPU equivalence tests run, with the CPU's results
    #[repr(C)]
    struct DspSet {
        itx_count: i32,
        itx_flagged_count: i32,
        itx_cases: *const ItxCase,
        itx_case_size: u32,
        itx_coeffs_per_case: u32,
        itx_residual_per_case: u32,
        itx_coeffs: *const i16,
        itx_residual: *const i32,
        itx_flags: *const u32,
        pred_count: i32,
        pred_cfl_count: i32,
        pred_side: i32,
        pred_cases: *const PredCase,
        pred_case_size: u32,
        pred_luma_size: u32,
        pred_planes: *const u8,
        pred_luma: *const u8,
        pred_out: *const u8,
    }
    #[repr(C)]
    struct ItxCase {
        tx_sz: i32,
        tx_type: i32,
        dcq: i32,
        acq: i32,
        qm_level: i32,
        plane: i32,
    }
    #[repr(C)]
    struct PredCase {
        mode: i32,
        delta: i32,
        log2w: i32,
        log2h: i32,
        have_left: i32,
        have_above: i32,
        have_ar: i32,
        have_bl: i32,
        x: i32,
        y: i32,
        max_x: i32,
        max_y: i32,
        cfl: i32,
        alpha: i32,
        edge_filter: i32,
        filter_type: i32,
        fi_mode: i32,
    }

    #[test]
    fn dsp_cases_match() {
        for seed in [1u64, 0xfeed] {
            // SAFETY: the set stays alive until av1t_dsp_set_free; the arrays have the sizes it reports.
            unsafe {
                let s = &*av1t_dsp_set_make(seed);
                assert_eq!(s.itx_case_size as usize, size_of::<ItxCase>());
                assert_eq!(s.pred_case_size as usize, size_of::<PredCase>());
                let mut dq = vec![0i32; 1024];
                let mut res = vec![0i32; 4096];
                for i in 0..s.itx_count as usize {
                    let c = &*s.itx_cases.add(i);
                    let q = core::slice::from_raw_parts(s.itx_coeffs.add(i * s.itx_coeffs_per_case as usize), 1024);
                    let want =
                        core::slice::from_raw_parts(s.itx_residual.add(i * s.itx_residual_per_case as usize), 4096);
                    dequant(
                        q,
                        &mut dq,
                        c.tx_sz,
                        c.dcq,
                        c.acq,
                        qm(c.qm_level >= 0, c.qm_level, c.plane, c.tx_sz, c.tx_type),
                    );
                    let f = inv_txfm2d(&dq, c.tx_sz, c.tx_type, &mut res);
                    let n = (tx_w(c.tx_sz) * tx_h(c.tx_sz)) as usize;
                    assert_eq!(f, *s.itx_flags.add(i), "itx case {i}");
                    assert_eq!(res[..n], want[..n], "itx case {i}");
                }
                let pw = s.pred_side as usize;
                assert_eq!(pw, PW);
                let luma = core::slice::from_raw_parts(s.pred_luma, s.pred_luma_size as usize);
                for i in 0..s.pred_count as usize {
                    let c = &*s.pred_cases.add(i);
                    let mut out = core::slice::from_raw_parts(s.pred_planes.add(i * pw * pw), pw * pw).to_vec();
                    let want = core::slice::from_raw_parts(s.pred_out.add(i * pw * pw), pw * pw);
                    let (mut a, mut l) = ([0u8; EDGE_LEN], [0u8; EDGE_LEN]);
                    build_edges(
                        &out,
                        pw,
                        c.x,
                        c.y,
                        c.log2w,
                        c.log2h,
                        c.have_left != 0,
                        c.have_above != 0,
                        c.have_ar != 0,
                        c.have_bl != 0,
                        c.max_x,
                        c.max_y,
                        &mut a,
                        &mut l,
                    );
                    let o = c.y as usize * pw + c.x as usize;
                    predict_intra_ex(
                        c.mode,
                        c.delta,
                        c.fi_mode,
                        c.edge_filter != 0,
                        c.filter_type,
                        c.have_left != 0,
                        c.have_above != 0,
                        c.log2w,
                        c.log2h,
                        c.x,
                        c.y,
                        c.max_x,
                        c.max_y,
                        &mut a,
                        &mut l,
                        &mut out[o..],
                        pw,
                    );
                    if c.cfl != 0 {
                        let t = (0..TX_SIZES_ALL)
                            .rfind(|&t| {
                                Tx_Width_Log2[t as usize] as i32 == c.log2w
                                    && Tx_Height_Log2[t as usize] as i32 == c.log2h
                            })
                            .unwrap();
                        cfl_predict(
                            &mut out,
                            pw,
                            luma,
                            2 * pw,
                            c.x,
                            c.y,
                            t,
                            1,
                            1,
                            2 * (c.x + (1 << c.log2w)),
                            2 * (c.y + (1 << c.log2h)),
                            c.alpha,
                        );
                    }
                    assert_eq!(out, want, "pred case {i}");
                }
                av1t_dsp_set_free(s);
            }
        }
    }
}
