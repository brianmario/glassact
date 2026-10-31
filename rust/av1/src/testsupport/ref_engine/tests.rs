//! The reference engine against the C++ (av1t_ref_encode, and ref_engine_encode with every option
//! through oracle/testsupport.cpp): the OBUs, the AVIF, the reconstruction and the stats.
use super::*;
use crate::dsp::Rng;
use crate::hybrid::tests::{Pic, screen_pic};
use core::ffi::c_int;

/// ref_engine_encode's options as the shim takes them (oracle/testsupport.cpp oracle_ref_opts).
#[repr(C)]
struct OracleRefOpts {
    qindex: i32,
    min_block: i32,
    max_block: i32,
    angle_deltas: i32,
    cfl: i32,
    tx_types: i32,
    reduced_tx_set: i32,
    split_bias: f64,
    qm_level: i32,
    qm_level_uv: i32,
    deltaq: i32,
    deltaq_res: i32,
    deltaq_strength: f64,
    edge_filter: i32,
    lf_level: i32,
    lf_sharpness: i32,
    cdef: i32,
    cdef_y_pri: i32,
    cdef_y_sec: i32,
    cdef_uv_pri: i32,
    cdef_uv_sec: i32,
    cdef_damping: i32,
}

unsafe extern "C" {
    fn av1t_ref_encode(
        y: *const u8,
        u: *const u8,
        v: *const u8,
        w: u32,
        h: u32,
        opts: *const RefOpts,
        out: *mut crate::types::Output,
    ) -> c_int;
    fn oracle_testsupport_ref_encode(
        y: *const u8,
        u: *const u8,
        v: *const u8,
        w: u32,
        h: u32,
        mono: c_int,
        o: *const OracleRefOpts,
        out: *mut crate::types::Output,
    ) -> c_int;
    fn av1g_output_free(out: *mut crate::types::Output);
}

/// An av1g_output's contents, freed.
fn take(rc: c_int, o: &mut crate::types::Output) -> Result<Output, i32> {
    // SAFETY: av1g_output's buffers, sized by its fields; freed once.
    unsafe {
        let v = |p: *mut u8, n: usize| {
            if p.is_null() {
                Vec::new()
            } else {
                core::slice::from_raw_parts(p, n).to_vec()
            }
        };
        let r = Output {
            obu: v(o.obu, o.obu_size),
            avif: v(o.avif, o.avif_size),
            recon: core::array::from_fn(|p| v(o.recon[p], (o.recon_w[p] * o.recon_h[p]) as usize)),
            recon_w: o.recon_w,
            recon_h: o.recon_h,
            seq_level_idx: o.seq_level_idx,
            tile_cols: o.tile_cols,
            tile_rows: o.tile_rows,
            header_bytes: o.header_bytes,
            tile_bytes: o.tile_bytes,
            n_symbols: o.n_symbols,
            n_fixed_txb: o.n_fixed_txb,
        };
        av1g_output_free(o);
        if rc == OK { Ok(r) } else { Err(rc) }
    }
}

fn c_ref_encode(p: &Pic, o: &RefOpts) -> Result<Output, i32> {
    // SAFETY: the planes are w x h and half chroma; av1g_output is plain data.
    unsafe {
        let mut out: crate::types::Output = core::mem::zeroed();
        let rc = av1t_ref_encode(
            p.y.as_ptr(),
            p.u.as_ptr(),
            p.v.as_ptr(),
            p.w as u32,
            p.h as u32,
            o,
            &mut out,
        );
        take(rc, &mut out)
    }
}

fn c_ref_engine(p: &Pic, mono: bool, o: &RefEngineOpts) -> Result<Output, i32> {
    let co = OracleRefOpts {
        qindex: o.qindex,
        min_block: o.min_block,
        max_block: o.max_block,
        angle_deltas: o.angle_deltas as i32,
        cfl: o.cfl as i32,
        tx_types: o.tx_types as i32,
        reduced_tx_set: o.reduced_tx_set as i32,
        split_bias: o.split_bias,
        qm_level: o.qm_level,
        qm_level_uv: o.qm_level_uv,
        deltaq: o.deltaq as i32,
        deltaq_res: o.deltaq_res,
        deltaq_strength: o.deltaq_strength,
        edge_filter: o.edge_filter as i32,
        lf_level: o.lf_level,
        lf_sharpness: o.lf_sharpness,
        cdef: o.cdef as i32,
        cdef_y_pri: o.cdef_y_pri,
        cdef_y_sec: o.cdef_y_sec,
        cdef_uv_pri: o.cdef_uv_pri,
        cdef_uv_sec: o.cdef_uv_sec,
        cdef_damping: o.cdef_damping,
    };
    // SAFETY: as c_ref_encode.
    unsafe {
        let mut out: crate::types::Output = core::mem::zeroed();
        let rc = oracle_testsupport_ref_encode(
            p.y.as_ptr(),
            p.u.as_ptr(),
            p.v.as_ptr(),
            p.w as u32,
            p.h as u32,
            mono as c_int,
            &co,
            &mut out,
        );
        take(rc, &mut out)
    }
}

fn picture(r: &mut Rng, big: bool) -> Pic {
    let (w, h) = if big {
        (r.range(4097, 4400) as usize, r.range(8, 48) as usize)
    } else {
        match r.below(6) {
            0 => (r.range(1, 20) as usize, r.range(1, 20) as usize),
            _ => (r.range(16, 420) as usize, r.range(16, 300) as usize),
        }
    };
    let seed = r.next() as u64;
    let mut p = screen_pic(w, h, seed, r.below(2) == 0);
    if r.below(5) == 0 {
        let mut rr = Rng(seed | 1);
        p.noise(&mut rr, 0, 0, w, h, r.range(4, 127));
    }
    p
}

fn same(a: &Result<Output, Error>, b: &Result<Output, i32>) -> Result<(), String> {
    match (a, b) {
        (Ok(a), Ok(b)) => {
            if a.obu != b.obu {
                return Err(format!("OBUs differ ({} vs {} bytes)", a.obu.len(), b.obu.len()));
            }
            if a.recon != b.recon || a.recon_w != b.recon_w || a.recon_h != b.recon_h {
                return Err("reconstruction".into());
            }
            if a != b {
                return Err(format!("outputs\n rust {a:?}\n c++  {b:?}"));
            }
            Ok(())
        }
        (Err(e), Err(c)) if e.code == *c => Ok(()),
        _ => Err(format!(
            "rust {:?}, c++ {:?}",
            a.as_ref().map(|o| o.obu.len()),
            b.as_ref().map(|o| o.obu.len())
        )),
    }
}

#[test]
fn ref_encode_matches_cpp() {
    let mut r = Rng(0xAB_CDEF_0123);
    for case in 0..400 {
        let p = picture(&mut r, case % 40 == 39);
        let o = RefOpts {
            qindex: match r.below(4) {
                0 => r.range(1, 10),
                1 => 80,
                _ => r.range(1, 255),
            },
            min_block: [4, 8][r.below(2) as usize],
            max_block: [8, 16, 32, 64][r.below(4) as usize],
            lf_level: [-1, 0, r.range(1, 70)][r.below(3) as usize],
            cdef: r.below(2) as i32,
            edge_filter: r.below(2) as i32,
        };
        let a = ref_encode(&p.y, &p.u, &p.v, p.w as u32, p.h as u32, &o);
        let b = c_ref_encode(&p, &o);
        same(&a, &b).unwrap_or_else(|e| panic!("case {case} ({}x{}, {o:?}): {e}", p.w, p.h));
        assert!(a.is_ok(), "case {case}: failed");
    }
}

#[test]
fn ref_engine_options_match_cpp() {
    let mut r = Rng(0x7777_1234_ABCD);
    for case in 0..240 {
        let p = picture(&mut r, false);
        let mono = r.below(5) == 0;
        let o = RefEngineOpts {
            qindex: r.range(1, 255),
            min_block: [4, 8][r.below(2) as usize],
            max_block: [8, 16, 32, 64][r.below(4) as usize],
            angle_deltas: r.below(4) != 0,
            cfl: r.below(4) != 0,
            tx_types: r.below(4) != 0,
            reduced_tx_set: r.below(3) == 0,
            split_bias: [1.0, 0.8, 1.3][r.below(3) as usize],
            qm_level: [-1, -2, r.range(0, 15)][r.below(3) as usize],
            qm_level_uv: [-1, r.range(0, 15)][r.below(2) as usize],
            deltaq: r.below(2) == 0,
            deltaq_res: r.range(0, 3),
            deltaq_strength: [6.0, 2.5, 12.0][r.below(3) as usize],
            edge_filter: r.below(2) == 0,
            lf_level: [-1, r.range(1, 63)][r.below(2) as usize],
            lf_sharpness: r.range(0, 7),
            cdef: r.below(2) == 0,
            cdef_y_pri: r.range(0, 15),
            cdef_y_sec: [0, 1, 2, 4][r.below(4) as usize],
            cdef_uv_pri: r.range(0, 15),
            cdef_uv_sec: [0, 1, 2, 4][r.below(4) as usize],
            cdef_damping: r.range(3, 6),
        };
        let img = Image {
            w: p.w as u32,
            h: p.h as u32,
            mono,
            planes: [&p.y, &p.u, &p.v],
        };
        let mut rec = Record::default();
        let mut stats = RefEngineStats::default();
        let a = ref_engine_encode(&img, &o, &mut rec, Some(&mut stats));
        let b = c_ref_engine(&p, mono, &o);
        same(&a, &b).unwrap_or_else(|e| panic!("case {case} ({}x{}, mono {mono}, {o:?}): {e}", p.w, p.h));
        assert!(a.is_ok(), "case {case}: failed");
        assert_eq!(stats.blocks as usize, rec.blocks.len());
    }
}

#[test]
fn ref_encode_errors_match_cpp() {
    let p = screen_pic(40, 30, 1, false);
    let o = RefOpts {
        qindex: 0,
        min_block: 8,
        max_block: 64,
        lf_level: -1,
        cdef: 0,
        edge_filter: 0,
    };
    let a = ref_encode(&p.y, &p.u, &p.v, 40, 30, &o);
    same(&a, &c_ref_encode(&p, &o)).unwrap();
    assert!(a.is_err());
}
