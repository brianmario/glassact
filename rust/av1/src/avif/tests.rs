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

struct Bits {
    v: Vec<u8>,
    n: usize,
}
impl Bits {
    fn put(&mut self, x: u32, k: u32) {
        for i in (0..k).rev() {
            if self.n.is_multiple_of(8) {
                self.v.push(0);
            }
            *self.v.last_mut().unwrap() |= (((x >> i) & 1) as u8) << (7 - self.n % 8);
            self.n += 1;
        }
    }
}

/// A random sequence header payload: mostly reduced_still_picture_header ones of every colour
/// configuration, sometimes truncated or not reduced.
fn random_seq_header(rnd: &mut Rng) -> Vec<u8> {
    let mut b = Bits { v: Vec::new(), n: 0 };
    let profile = if rnd.below(8) == 0 { rnd.below(8) } else { rnd.below(3) };
    b.put(profile, 3);
    b.put(rnd.below(2), 1);
    b.put((rnd.below(10) != 0) as u32, 1); // reduced_still_picture_header
    b.put(rnd.below(32), 5);
    let (wb, hb) = (rnd.below(16) + 1, rnd.below(16) + 1);
    b.put(wb - 1, 4);
    b.put(hb - 1, 4);
    b.put(rnd.next(), wb);
    b.put(rnd.next(), hb);
    b.put(rnd.below(64), 6);
    let hbd = rnd.below(2);
    b.put(hbd, 1);
    if profile == 2 && hbd != 0 {
        b.put(rnd.below(2), 1);
    }
    if profile != 1 {
        b.put((rnd.below(3) == 0) as u32, 1);
    }
    if rnd.below(2) != 0 {
        b.put(1, 1);
        if rnd.below(3) == 0 {
            b.put(1, 8);
            b.put(13, 8);
            b.put(0, 8);
        } else {
            b.put(rnd.below(256), 8);
            b.put(rnd.below(256), 8);
            b.put(rnd.below(256), 8);
        }
    } else {
        b.put(0, 1);
    }
    b.put(rnd.next(), 3 + rnd.below(20)); // color range, csp, the rest
    let mut v = b.v;
    if rnd.below(8) == 0 {
        v.truncate(rnd.below(v.len() as u32 + 1) as usize);
    }
    v
}

fn leb128(out: &mut Vec<u8>, mut v: u64, pad: u32) {
    let mut bytes = Vec::new();
    loop {
        bytes.push((v & 0x7f) as u8);
        v >>= 7;
        if v == 0 {
            break;
        }
    }
    bytes.resize(bytes.len() + pad as usize, 0);
    let n = bytes.len();
    for (i, b) in bytes.iter_mut().enumerate() {
        if i + 1 < n {
            *b |= 0x80;
        }
    }
    out.extend_from_slice(&bytes);
}

fn obu(out: &mut Vec<u8>, rnd: &mut Rng, kind: u32, payload: &[u8], sized: bool) {
    let ext = rnd.below(4) == 0;
    out.push(((kind << 3) | ((ext as u32) << 2) | ((sized as u32) << 1)) as u8);
    if ext {
        out.push(rnd.next() as u8);
    }
    if sized {
        leb128(
            out,
            payload.len() as u64,
            if rnd.below(6) == 0 { rnd.below(3) } else { 0 },
        );
    }
    out.extend_from_slice(payload);
}

/// A random OBU stream: other OBUs, then (usually) a sequence header, then a frame; sometimes
/// random bytes or a truncation.
fn random_stream(rnd: &mut Rng) -> Vec<u8> {
    let mut s = Vec::new();
    if rnd.below(16) == 0 {
        return (0..rnd.below(64)).map(|_| rnd.next() as u8).collect();
    }
    if rnd.below(2) != 0 {
        obu(&mut s, rnd, 2, &[], true); // temporal delimiter
    }
    for _ in 0..rnd.below(3) {
        let k = [3, 4, 5, 6, 7, 8, 15][rnd.below(7) as usize];
        let p: Vec<u8> = (0..rnd.below(40)).map(|_| rnd.next() as u8).collect();
        obu(&mut s, rnd, k, &p, true);
    }
    if rnd.below(10) != 0 {
        let sh = random_seq_header(rnd);
        let sized = rnd.below(8) != 0;
        obu(&mut s, rnd, 1, &sh, sized);
        if sized {
            let p: Vec<u8> = (0..rnd.below(200)).map(|_| rnd.next() as u8).collect();
            let sized = rnd.below(2) != 0;
            obu(&mut s, rnd, 6, &p, sized);
        }
    }
    if rnd.below(10) == 0 {
        s.truncate(rnd.below(s.len() as u32 + 1) as usize);
    }
    s
}

#[test]
fn exif_orientations() {
    let want = [
        (-1, -1),
        (-1, -1),
        (-1, 1),
        (2, -1),
        (-1, 0),
        (1, 0),
        (3, -1),
        (3, 0),
        (1, -1),
        (-1, -1),
    ];
    for (o, w) in want.iter().enumerate() {
        assert_eq!(exif_orientation_to_irot_imir(o as i32), *w);
    }
}

#[test]
fn rejects_streams_without_a_still_sequence_header() {
    assert_eq!(mux_avif(&[], 16, 16), Err(ERR_INVALID));
    assert_eq!(mux_avif(&[0x12, 0x00], 16, 16), Err(ERR_INVALID));
}

/// The top-level boxes tile the file, mdat holds the OBUs, and iloc points at them.
#[test]
fn boxes_are_consistent() {
    let mut rnd = Rng(0x0a1f_0002);
    let mut n_ok = 0;
    for _ in 0..2000 {
        let obus = random_stream(&mut rnd);
        let icc: Vec<u8> = (0..rnd.below(50)).map(|_| rnd.next() as u8).collect();
        let md = Meta {
            icc: &icc,
            irot: rnd.below(5) as i32 - 1,
            imir: rnd.below(3) as i32 - 1,
        };
        let Ok(f) = mux_avif_ex(&obus, 64, 48, Some(&md)) else {
            continue;
        };
        n_ok += 1;
        let be32 = |p: usize| u32::from_be_bytes(f[p..p + 4].try_into().unwrap()) as usize;
        let mut at = 0;
        let mut kinds = Vec::new();
        while at < f.len() {
            kinds.push(f[at + 4..at + 8].to_vec());
            at += be32(at);
        }
        assert_eq!(at, f.len());
        assert_eq!(kinds, [b"ftyp".to_vec(), b"meta".to_vec(), b"mdat".to_vec()]);
        assert!(f.ends_with(&obus));
        let iloc = f.windows(4).position(|w| w == b"iloc").unwrap() - 4;
        assert_eq!(be32(iloc + 22), f.len() - obus.len());
        assert_eq!(be32(iloc + 26), obus.len());
    }
    assert!(n_ok > 1000);
}

#[cfg(feature = "oracle")]
mod oracle {
    use super::*;
    use crate::types::AvifMeta;

    unsafe extern "C" {
        fn av1g_mux_avif(obus: *const u8, n: usize, w: u32, h: u32, avif: *mut *mut u8, size: *mut usize) -> i32;
        fn av1g_mux_avif_ex(
            obus: *const u8,
            n: usize,
            w: u32,
            h: u32,
            md: *const AvifMeta,
            avif: *mut *mut u8,
            size: *mut usize,
        ) -> i32;
        fn av1g_exif_orientation_to_irot_imir(orientation: i32, irot: *mut i32, imir: *mut i32);
        fn free(p: *mut core::ffi::c_void);
    }

    /// Where the C++ would read past the end of `obus` (an OBU header with an extension flag as
    /// the stream's last byte, no size field, sequence header type): not a comparable case.
    fn c_overreads(obus: &[u8]) -> bool {
        let n = obus.len();
        let mut pos = 0usize;
        while pos < n {
            let h = obus[pos];
            pos += 1;
            if (h >> 2) & 1 != 0 {
                pos += 1;
            }
            let mut sz = n.wrapping_sub(pos) as u64;
            if (h >> 1) & 1 != 0 {
                match read_leb128(obus, &mut pos) {
                    Some(v) => sz = v,
                    None => return false,
                }
            }
            if (pos as u64).wrapping_add(sz) > n as u64 {
                return false;
            }
            if (h >> 3) & 15 == 1 {
                return pos > n;
            }
            pos = pos.wrapping_add(sz as usize);
        }
        false
    }

    fn c_mux(obus: &[u8], w: u32, h: u32, md: Option<&Meta>) -> Result<Vec<u8>, i32> {
        let mut p = core::ptr::null_mut();
        let mut size = 0usize;
        let cm = md.map(|m| AvifMeta {
            icc: if m.icc.is_empty() {
                core::ptr::null()
            } else {
                m.icc.as_ptr()
            },
            icc_size: m.icc.len(),
            irot: m.irot,
            imir: m.imir,
        });
        // SAFETY: valid buffers; the C++ mallocs the result, freed below.
        unsafe {
            let r = match &cm {
                None => av1g_mux_avif(obus.as_ptr(), obus.len(), w, h, &mut p, &mut size),
                Some(m) => av1g_mux_avif_ex(obus.as_ptr(), obus.len(), w, h, m, &mut p, &mut size),
            };
            if r != 0 {
                return Err(r);
            }
            let v = core::slice::from_raw_parts(p, size).to_vec();
            free(p.cast());
            Ok(v)
        }
    }

    #[test]
    fn exif_orientations_match_c() {
        for o in -3..12 {
            let (mut r, mut m) = (0, 0);
            unsafe { av1g_exif_orientation_to_irot_imir(o, &mut r, &mut m) };
            assert_eq!(exif_orientation_to_irot_imir(o), (r, m));
        }
    }

    /// Random streams, with and without ICC, for every irot and imir (and out-of-range ones).
    #[test]
    fn mux_matches_c() {
        let mut rnd = Rng(0x0a1f_0001);
        let (mut ok, mut compared) = (0, 0);
        for case in 0..3000 {
            let obus = random_stream(&mut rnd);
            if c_overreads(&obus) {
                continue;
            }
            let (w, h) = (rnd.next(), rnd.next());
            let icc: Vec<u8> = (0..if rnd.below(2) != 0 { rnd.below(600) } else { 0 })
                .map(|_| rnd.next() as u8)
                .collect();
            let mut metas = vec![None];
            for irot in -1..=3 {
                for imir in -1..=1 {
                    metas.push(Some(Meta { icc: &icc, irot, imir }));
                }
            }
            metas.push(Some(Meta {
                icc: &icc,
                irot: 6 + rnd.below(100) as i32,
                imir: 2 + rnd.below(100) as i32,
            }));
            metas.push(Some(Meta {
                icc: &icc,
                irot: -2 - rnd.below(100) as i32,
                imir: -2 - rnd.below(100) as i32,
            }));
            for md in &metas {
                let ours = if md.is_none() {
                    mux_avif(&obus, w, h)
                } else {
                    mux_avif_ex(&obus, w, h, md.as_ref())
                };
                let want = c_mux(&obus, w, h, md.as_ref());
                assert!(ours == want, "case {case} meta {md:?}");
                ok += want.is_ok() as u32;
                compared += 1;
            }
        }
        assert!(ok > compared / 2, "{ok} of {compared} valid");
    }
}
