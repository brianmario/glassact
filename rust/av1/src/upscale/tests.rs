//! The upscaler: SIMD against the scalar reference (exactly), flat pictures stay flat, extremes
//! stay in i16, close to the filter in floating point, the snapshot, and the timing (ignored).
use super::*;
use crate::testsupport::snapshot::Snapshot;

/// splitmix64
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
}

const FILTERS: [Filter; 5] = [Filter::Lanczos3, Filter::Lanczos2, Filter::Lanczos4, Filter::CatmullRom, Filter::Lanczos5];

/// A picture's kind of samples: random, a 0/255 checkerboard (the largest overshoot), stripes of
/// one of them, smooth.
fn picture(rng: &mut Rng, kind: u64, w: usize, h: usize, stride: usize, ch: usize) -> Vec<u8> {
    let mut p = vec![0u8; (h - 1) * stride + w * ch];
    // the padding between rows: anything (the upscaler must not read it into a picture)
    for b in p.iter_mut() {
        *b = rng.next() as u8;
    }
    for y in 0..h {
        for x in 0..w {
            for c in 0..ch {
                p[y * stride + x * ch + c] = match kind {
                    0 => rng.next() as u8,
                    1 => (((x + y) & 1) * 255) as u8,
                    2 => ((x & 1) * 255) as u8,
                    3 => ((y & 1) * 255) as u8,
                    4 => ((x * 7 + y * 3 + c * 50) % 256) as u8,
                    _ => {
                        if c == 3 {
                            255
                        } else {
                            rng.next() as u8
                        }
                    }
                };
            }
        }
    }
    p
}

/// `src` upscaled by `path`, into a fresh buffer of `dst_stride` rows (padding 0xA5).
#[allow(clippy::too_many_arguments)]
fn upscale(
    u: &mut Upscaler,
    path: Path,
    src: &[u8],
    (sw, sh, ss): (usize, usize, usize),
    ch: usize,
    (dw, dh, ds): (usize, usize, usize),
) -> Vec<u8> {
    u.set_path(path);
    let mut out = vec![0xA5u8; (dh - 1) * ds + dw * ch];
    u.scale(src, sw, sh, ss, ch, &mut out, dw, dh, ds).unwrap();
    for y in 0..dh.saturating_sub(1) {
        assert!(out[y * ds + dw * ch..(y + 1) * ds].iter().all(|&b| b == 0xA5), "wrote past a row");
    }
    out
}

/// The sizes the tests try: exactly twice, a little over (a side not a multiple of 4: the Host's
/// `(n / 2) & !1`), the same, tiny ones (no SIMD interior), and odd ones.
fn sizes() -> Vec<(usize, usize, usize, usize)> {
    let mut v = vec![
        (1, 1, 1, 1),
        (1, 1, 2, 2),
        (1, 1, 7, 3),
        (2, 2, 4, 4),
        (3, 3, 6, 6),
        (3, 2, 7, 5),
        (5, 4, 10, 8),
        (7, 7, 14, 14),
        (9, 5, 18, 10),
        (16, 9, 32, 18),
        (17, 9, 34, 18),
        (40, 23, 80, 46),
        (41, 23, 83, 47),
        (64, 36, 128, 72),
        (734, 4, 1470, 9),
        (366, 6, 735, 13),
        (100, 7, 100, 7),
        (99, 8, 200, 17),
        (33, 12, 99, 25),
        (257, 3, 514, 6),
    ];
    // and Host-like pairs: n -> max(2, (n / 2) & !1)
    for n in [6usize, 9, 10, 15, 22, 31, 64, 70, 101, 130] {
        let c = ((n / 2) & !1).max(2);
        v.push((c, c.min(9), n, (2 * c.min(9)).max(c.min(9))));
    }
    v
}

#[test]
fn simd_matches_scalar() {
    let mut rng = Rng(7);
    for filter in FILTERS {
        for threads in [1, 3] {
            let mut u = Upscaler::new(threads, filter);
            for (sw, sh, dw, dh) in sizes() {
                for ch in [1, 4] {
                    for kind in 0..6 {
                        let ss = sw * ch + rng.below(3) as usize * 7;
                        let ds = dw * ch + rng.below(3) as usize * 5;
                        let src = picture(&mut rng, kind, sw, sh, ss, ch);
                        let a = upscale(&mut u, Path::Scalar, &src, (sw, sh, ss), ch, (dw, dh, ds));
                        let b = upscale(&mut u, Path::Simd, &src, (sw, sh, ss), ch, (dw, dh, ds));
                        assert!(a == b, "{filter:?} {sw}x{sh} -> {dw}x{dh} ch {ch} kind {kind}: SIMD != scalar");
                    }
                }
            }
        }
    }
}

#[test]
fn flat_stays_flat_and_alpha_255() {
    for filter in FILTERS {
        let mut u = Upscaler::new(2, filter);
        for (sw, sh, dw, dh) in [(5, 3, 10, 6), (40, 9, 80, 18), (41, 9, 83, 19), (734, 3, 1470, 7)] {
            for ch in [1, 4] {
                for v in 0..=255u8 {
                    let src = vec![v; sw * sh * ch];
                    for path in [Path::Scalar, Path::Simd] {
                        let out = upscale(&mut u, path, &src, (sw, sh, sw * ch), ch, (dw, dh, dw * ch));
                        assert!(out.iter().all(|&o| o == v), "{filter:?} {sw}x{sh} ch {ch}: {v} not flat");
                    }
                }
            }
            // random colours, alpha 255
            let mut rng = Rng(3);
            let src = picture(&mut rng, 5, sw, sh, sw * 4, 4);
            let out = upscale(&mut u, Path::Simd, &src, (sw, sh, sw * 4), 4, (dw, dh, dw * 4));
            assert!(out.chunks(4).all(|p| p[3] == 255), "{filter:?}: alpha moved");
        }
    }
}

/// The filter in f64 (the same tables' positions and kernel, no rounding until the end).
fn float_reference(src: &[u8], (sw, sh): (usize, usize), ch: usize, (dw, dh): (usize, usize), f: Filter) -> Vec<f64> {
    let taps = |n: usize, d: usize| -> Vec<Vec<(usize, f64)>> {
        (0..d)
            .map(|x| {
                let pos = (x as f64 + 0.5) * n as f64 / d as f64 - 0.5;
                let fl = pos.floor();
                let r = f.radius() as i64;
                let mut t: Vec<(usize, f64)> = (fl as i64 - r + 1..=fl as i64 + r)
                    .map(|j| (j.clamp(0, n as i64 - 1) as usize, f.kernel(j as f64 - pos)))
                    .collect();
                let s: f64 = t.iter().map(|e| e.1).sum();
                t.iter_mut().for_each(|e| e.1 /= s);
                t
            })
            .collect()
    };
    let (th, tv) = (taps(sw, dw), taps(sh, dh));
    let mut out = vec![0.0; dw * dh * ch];
    for y in 0..dh {
        for x in 0..dw {
            for c in 0..ch {
                let mut s = 0.0;
                for &(j, wy) in &tv[y] {
                    for &(i, wx) in &th[x] {
                        s += wy * wx * src[(j * sw + i) * ch + c] as f64;
                    }
                }
                out[(y * dw + x) * ch + c] = s.clamp(0.0, 255.0);
            }
        }
    }
    out
}

#[test]
fn close_to_the_filter_in_floating_point() {
    let mut rng = Rng(11);
    for filter in FILTERS {
        let mut u = Upscaler::new(1, filter);
        for (sw, sh, dw, dh) in [(24, 16, 48, 32), (23, 15, 50, 34)] {
            for kind in [0, 1, 4] {
                let src = picture(&mut rng, kind, sw, sh, sw * 4, 4);
                let out = upscale(&mut u, Path::Simd, &src, (sw, sh, sw * 4), 4, (dw, dh, dw * 4));
                let want = float_reference(&src, (sw, sh), 4, (dw, dh), filter);
                let (mut worst, mut se) = (0.0f64, 0.0);
                for (&o, &w) in out.iter().zip(&want) {
                    let d = (o as f64 - w).abs();
                    worst = worst.max(d);
                    se += d * d;
                }
                let rmse = (se / out.len() as f64).sqrt();
                // the output's rounding, and each product's and weight's
                assert!(worst <= 1.0 && rmse <= 0.35, "{filter:?} {sw}x{sh} kind {kind}: worst {worst:.2}, rmse {rmse:.3}");
            }
        }
    }
}

#[test]
fn sinpi_is_sin() {
    for i in -4000..4000 {
        let x = i as f64 / 997.0;
        assert!((sinpi(x) - (core::f64::consts::PI * x).sin()).abs() < 1e-14, "{x}");
    }
    assert_eq!(sinpi(0.0), 0.0);
}

#[test]
fn refuses_what_it_cannot_scale() {
    let mut u = Upscaler::new(1, Filter::Lanczos3);
    let src = vec![0u8; 64];
    let mut dst = vec![0u8; 256];
    assert!(u.scale(&src, 4, 4, 4, 2, &mut dst, 8, 8, 8).is_err(), "channels");
    assert!(u.scale(&src, 4, 4, 4, 1, &mut dst, 3, 8, 8).is_err(), "smaller");
    assert!(u.scale(&src, 0, 4, 4, 1, &mut dst, 8, 8, 8).is_err(), "empty");
    assert!(u.scale(&src, 4, 4, 3, 1, &mut dst, 8, 8, 8).is_err(), "stride");
    assert!(u.scale(&src, 4, 17, 4, 1, &mut dst, 8, 32, 8).is_err(), "source buffer");
    assert!(u.scale(&src, 4, 4, 4, 1, &mut dst, 16, 17, 16).is_err(), "destination buffer");
    assert!(u.scale(&src, 4, 4, 4, 1, &mut dst, 8, 8, 8).is_ok());
}

/// The outputs on fixed seeds, per filter: the same on aarch64 and x86_64 (the tables use no libm).
#[test]
fn snapshot() {
    let mut s = Snapshot::new(&["tables", "lanczos3", "lanczos2", "lanczos4", "catmull_rom", "lanczos5"]);
    let names = ["lanczos3", "lanczos2", "lanczos4", "catmull_rom", "lanczos5"];
    for (filter, name) in FILTERS.iter().zip(names) {
        for (n, d) in [(2560usize, 5120usize), (734, 1470), (5, 11)] {
            let a = Axis::new(n, d, *filter, ONE);
            s.put("tables", &a.w);
            s.put("tables", &a.idx);
        }
        let mut rng = Rng(5);
        let mut u = Upscaler::new(2, *filter);
        for (sw, sh, dw, dh) in [(40, 23, 80, 46), (41, 23, 83, 47), (64, 36, 128, 72)] {
            for ch in [1, 4] {
                for kind in [0, 1, 4] {
                    let src = picture(&mut rng, kind, sw, sh, sw * ch, ch);
                    let out = upscale(&mut u, Path::Simd, &src, (sw, sh, sw * ch), ch, (dw, dh, dw * ch));
                    s.put(name, &out);
                }
            }
        }
    }
    // (recorded on aarch64; x86_64 gives the same)
    s.check(&[
        ("tables", 0x5714f90b4ef77660),
        ("lanczos3", 0xf70a95d859e5c532),
        ("lanczos2", 0x18cfa4a6c65df5de),
        ("lanczos4", 0xeff8f392fdb0d6ee),
        ("catmull_rom", 0xfaf23a9226dd5143),
        ("lanczos5", 0xc91c677ac823dd42),
    ]);
}

/// Times 5K: BGRA at half size to full, the 4:2:0 planes the same; and a side not a multiple of 4
/// (1470 × 956 from the Host's 734 × 478: the table's path across, twice the size down), planes
/// and BGRA; and BGRA a little over twice the size both ways at 5K (the table's path at 5K).
///   cargo test --release -- --ignored --nocapture bench_upscale
#[test]
#[ignore]
fn bench_upscale() {
    let mut rng = Rng(1);
    let time = |u: &mut Upscaler, src: &[u8], (sw, sh): (usize, usize), ch: usize, (dw, dh): (usize, usize)| -> f64 {
        let mut out = vec![0u8; dw * dh * ch];
        let mut best = f64::MAX;
        for _ in 0..40 {
            let t = std::time::Instant::now();
            u.scale(src, sw, sh, sw * ch, ch, &mut out, dw, dh, dw * ch).unwrap();
            best = best.min(t.elapsed().as_secs_f64() * 1e3);
        }
        best
    };
    for filter in FILTERS {
        for threads in [1, 4, 8, 0] {
            let mut u = Upscaler::new(threads, filter);
            let bgra = picture(&mut rng, 5, 2560, 1440, 2560 * 4, 4);
            let y = picture(&mut rng, 0, 2560, 1440, 2560, 1);
            let c = picture(&mut rng, 0, 1280, 720, 1280, 1);
            let t_bgra = time(&mut u, &bgra, (2560, 1440), 4, (5120, 2880));
            let t_y = time(&mut u, &y, (2560, 1440), 1, (5120, 2880));
            let t_c = time(&mut u, &c, (1280, 720), 1, (2560, 1440));
            let odd = picture(&mut rng, 5, 734, 478, 734 * 4, 4);
            let t_odd = time(&mut u, &odd, (734, 478), 4, (1470, 956));
            let t_oy = time(&mut u, &odd[..734 * 478], (734, 478), 1, (1470, 956));
            let t_oc = time(&mut u, &odd[..367 * 239], (367, 239), 1, (735, 478));
            let t_odd5k = time(&mut u, &bgra[..2558 * 4 * 1438], (2558, 1438), 4, (5118, 2878));
            println!(
                "{filter:?} threads {threads}: 5K BGRA {t_bgra:.2} ms · planes {:.2} ms (Y {t_y:.2}, U+V {:.2}) · 1470x956 planes {:.2}, BGRA {t_odd:.2} · 5118x2878 BGRA {t_odd5k:.2}",
                t_y + 2.0 * t_c,
                2.0 * t_c,
                t_oy + 2.0 * t_oc
            );
        }
    }
}
