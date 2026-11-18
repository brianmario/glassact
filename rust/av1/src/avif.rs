//! The AVIF (ISOBMFF) writer for still images (Sources/AV1Core/src/avif.cpp): a byte-exact port of
//! avif_conversion/hybrid_nvenc_libavif/avif_muxer.py:mux_avif(). av1C is derived from the
//! sequence header OBU in the stream.
use crate::types::ERR_INVALID;

/// av1g_avif_meta, safe: optional ICC profile and orientation (libavif-compatible boxes).
#[derive(Clone, Copy, Debug, Default)]
pub struct Meta<'a> {
    /// colr 'prof' property when not empty (the nclx colr is always written as well)
    pub icc: &'a [u8],
    /// -1: none, else 0..3 = anti-clockwise rotation by 90 * irot degrees ('irot')
    pub irot: i32,
    /// -1: none, else 0/1 = mirror axis ('imir'; applied after irot)
    pub imir: i32,
}

fn be32(b: &mut Vec<u8>, v: u32) {
    b.extend_from_slice(&v.to_be_bytes());
}

fn be16(b: &mut Vec<u8>, v: u32) {
    b.extend_from_slice(&(v as u16).to_be_bytes());
}

/// box()
fn bx(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut b = Vec::with_capacity(8 + data.len());
    be32(&mut b, (8 + data.len()) as u32);
    b.extend_from_slice(kind);
    b.extend_from_slice(data);
    b
}

fn fullbox(kind: &[u8; 4], version: u32, flags: u32, data: &[u8]) -> Vec<u8> {
    let mut b = Vec::with_capacity(12 + data.len());
    be32(&mut b, (12 + data.len()) as u32);
    b.extend_from_slice(kind);
    be32(&mut b, (version << 24) | (flags & 0xFFFFFF));
    b.extend_from_slice(data);
    b
}

/// MSB-first bit reader; past the end, get() returns the bits it has read.
struct BitReader<'a> {
    d: &'a [u8],
    pos: usize,
}

impl BitReader<'_> {
    fn get(&mut self, k: u32) -> u32 {
        let mut v = 0u32;
        for _ in 0..k {
            if (self.pos >> 3) >= self.d.len() {
                return v;
            }
            v = (v << 1) | ((self.d[self.pos >> 3] >> (7 - (self.pos & 7))) & 1) as u32;
            self.pos += 1;
        }
        v
    }
}

#[derive(Clone, Copy, Debug)]
struct Cfg {
    profile: u32,
    level: u32,
    tier: u32,
    hbd: u32,
    twelve: u32,
    mono: u32,
    ssx: u32,
    ssy: u32,
    csp: u32,
}

fn read_leb128(p: &[u8], pos: &mut usize) -> Option<u64> {
    let mut v = 0u64;
    for i in 0..8 {
        let b = *p.get(*pos)?;
        *pos += 1;
        v |= ((b & 0x7f) as u64) << (7 * i);
        if b & 0x80 == 0 {
            return Some(v);
        }
    }
    Some(v)
}

/// The av1C fields from the first sequence header OBU (reduced_still_picture_header only).
fn parse_seq(obus: &[u8]) -> Option<Cfg> {
    let n = obus.len();
    let mut pos = 0usize;
    while pos < n {
        let h = obus[pos];
        pos += 1;
        let (kind, ext, has_size) = ((h >> 3) & 15, (h >> 2) & 1, (h >> 1) & 1);
        if ext != 0 {
            pos += 1;
        }
        // the C++ computes n - pos in size_t; pos > n (an extension byte missing) only reads
        // past the end there, so it is invalid here
        let mut sz = n.wrapping_sub(pos) as u64;
        if has_size != 0 {
            sz = read_leb128(obus, &mut pos)?;
        }
        if (pos as u64).wrapping_add(sz) > n as u64 {
            return None;
        }
        if kind == 1 {
            if pos > n {
                return None;
            }
            let mut br = BitReader {
                d: &obus[pos..pos + sz as usize],
                pos: 0,
            };
            let mut c = Cfg {
                profile: br.get(3),
                level: 0,
                tier: 0,
                hbd: 0,
                twelve: 0,
                mono: 0,
                ssx: 1,
                ssy: 1,
                csp: 0,
            };
            br.get(1); // still_picture
            if br.get(1) == 0 {
                return None; // only reduced_still_picture_header streams
            }
            c.level = br.get(5);
            let wb = br.get(4) + 1;
            let hb = br.get(4) + 1;
            br.get(wb);
            br.get(hb);
            br.get(1); // 128 sb
            br.get(1); // filter intra
            br.get(1); // edge filter
            br.get(1); // superres
            br.get(1); // cdef
            br.get(1); // restoration
            c.hbd = br.get(1);
            if c.profile == 2 && c.hbd != 0 {
                c.twelve = br.get(1);
            }
            c.mono = if c.profile == 1 { 0 } else { br.get(1) };
            let (mut cp, mut tc, mut mc) = (2, 2, 2);
            if br.get(1) != 0 {
                cp = br.get(8);
                tc = br.get(8);
                mc = br.get(8);
            }
            if c.mono != 0 {
                (c.ssx, c.ssy, c.csp) = (1, 1, 0);
            } else if cp == 1 && tc == 13 && mc == 0 {
                (c.ssx, c.ssy, c.csp) = (0, 0, 0);
            } else {
                br.get(1); // color_range
                (c.ssx, c.ssy) = match c.profile {
                    0 => (1, 1),
                    1 => (0, 0),
                    _ => (1, 0),
                };
                c.csp = if c.ssx != 0 && c.ssy != 0 { br.get(2) } else { 0 };
            }
            return Some(c);
        }
        pos = pos.wrapping_add(sz as usize);
    }
    None
}

/// av1g_exif_orientation_to_irot_imir: EXIF orientation (1..8, JEITA CP-3451C) to (irot, imir),
/// exactly as libavif (avifImageExtractExifOrientationToIrotImir); 1 or invalid: (-1, -1).
pub fn exif_orientation_to_irot_imir(orientation: i32) -> (i32, i32) {
    match orientation {
        2 => (-1, 1),
        3 => (2, -1),
        4 => (-1, 0),
        5 => (1, 0),
        6 => (3, -1),
        7 => (3, 0),
        8 => (1, -1),
        _ => (-1, -1), // 1 = identity, others reserved
    }
}

/// av1g_mux_avif: the AVIF file of a still picture's OBUs.
pub fn mux_avif(obus: &[u8], width: u32, height: u32) -> Result<Vec<u8>, i32> {
    mux_avif_ex(obus, width, height, None)
}

/// av1g_mux_avif_ex: with an optional ICC profile and orientation. ispe stays the coded size;
/// irot and imir are essential transformative properties. Errors: [`ERR_INVALID`] when the stream
/// has no reduced_still_picture_header sequence header.
pub fn mux_avif_ex(obus: &[u8], width: u32, height: u32, md: Option<&Meta>) -> Result<Vec<u8>, i32> {
    let cfg = parse_seq(obus).ok_or(ERR_INVALID)?;
    let mut hdlr_d = vec![0, 0, 0, 0];
    hdlr_d.extend_from_slice(b"pict");
    hdlr_d.resize(hdlr_d.len() + 12, 0);
    hdlr_d.push(0);
    let hdlr = fullbox(b"hdlr", 0, 0, &hdlr_d);
    let mut pitm_d = Vec::new();
    be16(&mut pitm_d, 1);
    let pitm = fullbox(b"pitm", 0, 0, &pitm_d);
    let mut ispe_d = Vec::new();
    be32(&mut ispe_d, width);
    be32(&mut ispe_d, height);
    let ispe = fullbox(b"ispe", 0, 0, &ispe_d);
    let av1c_d = [
        0x81,
        (((cfg.profile & 7) << 5) | (cfg.level & 31)) as u8,
        (((cfg.tier & 1) << 7)
            | ((cfg.hbd & 1) << 6)
            | ((cfg.twelve & 1) << 5)
            | ((cfg.mono & 1) << 4)
            | ((cfg.ssx & 1) << 3)
            | ((cfg.ssy & 1) << 2)
            | (cfg.csp & 3)) as u8,
        0x00,
    ];
    let av1c = bx(b"av1C", &av1c_d);
    let pixi_d: &[u8] = if cfg.mono != 0 { &[1, 8] } else { &[3, 8, 8, 8] };
    let pixi = fullbox(b"pixi", 0, 0, pixi_d);
    let mut colr_d = b"nclx".to_vec();
    be16(&mut colr_d, 1); // BT.709 primaries
    be16(&mut colr_d, 13); // sRGB TC
    be16(&mut colr_d, 6); // BT.601 matrix
    colr_d.push(0x80); // full range
    let colr = bx(b"colr", &colr_d);
    // property order: ispe, av1C, pixi, [colr prof], colr nclx, [irot], [imir]
    // (descriptive before transformative; irot before imir as in libavif)
    let mut ipco_d = [ispe, av1c, pixi].concat();
    let mut assoc: Vec<u8> = vec![0x81, 0x82, 0x03]; // essential bit | 1-based index
    let mut idx = 3u8;
    if let Some(md) = md.filter(|m| !m.icc.is_empty()) {
        let mut prof_d = b"prof".to_vec();
        prof_d.extend_from_slice(md.icc);
        ipco_d.extend_from_slice(&bx(b"colr", &prof_d));
        idx += 1;
        assoc.push(idx);
    }
    ipco_d.extend_from_slice(&colr);
    idx += 1;
    assoc.push(idx);
    if let Some(md) = md.filter(|m| m.irot >= 0) {
        ipco_d.extend_from_slice(&bx(b"irot", &[(md.irot & 3) as u8]));
        idx += 1;
        assoc.push(0x80 | idx);
    }
    if let Some(md) = md.filter(|m| m.imir >= 0) {
        ipco_d.extend_from_slice(&bx(b"imir", &[(md.imir != 0) as u8]));
        idx += 1;
        assoc.push(0x80 | idx);
    }
    let ipco = bx(b"ipco", &ipco_d);
    let mut ipma_d = Vec::new();
    be32(&mut ipma_d, 1);
    be16(&mut ipma_d, 1);
    ipma_d.push(assoc.len() as u8);
    ipma_d.extend_from_slice(&assoc);
    let ipma = fullbox(b"ipma", 0, 0, &ipma_d);
    let iprp = bx(b"iprp", &[ipco, ipma].concat());
    let mut infe_d = Vec::new();
    be16(&mut infe_d, 1);
    be16(&mut infe_d, 0);
    infe_d.extend_from_slice(b"av01");
    infe_d.push(0);
    let infe = fullbox(b"infe", 2, 0, &infe_d);
    let mut iinf_d = Vec::new();
    be16(&mut iinf_d, 1);
    iinf_d.extend_from_slice(&infe);
    let iinf = fullbox(b"iinf", 0, 0, &iinf_d);
    let mut ftyp_d = b"avif".to_vec();
    be32(&mut ftyp_d, 0);
    ftyp_d.extend_from_slice(b"avifmif1");
    let ftyp = bx(b"ftyp", &ftyp_d);
    let iloc = |off: u32| {
        let mut d = vec![0x44, 0x00];
        for v in [1, 1, 0, 1] {
            be16(&mut d, v);
        }
        be32(&mut d, off);
        be32(&mut d, obus.len() as u32);
        fullbox(b"iloc", 0, 0, &d)
    };
    let meta_of = |off: u32| fullbox(b"meta", 0, 0, &[&hdlr[..], &pitm, &iinf, &iloc(off), &iprp].concat());
    let off = (ftyp.len() + meta_of(0).len() + 8) as u32;
    let meta = meta_of(off);
    let mut file = Vec::with_capacity(ftyp.len() + meta.len() + 8 + obus.len());
    file.extend_from_slice(&ftyp);
    file.extend_from_slice(&meta);
    be32(&mut file, (8 + obus.len()) as u32);
    file.extend_from_slice(b"mdat");
    file.extend_from_slice(obus);
    Ok(file)
}

#[cfg(test)]
mod tests;
