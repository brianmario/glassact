//! The reference engine's snapshots (ref_encode, and ref_engine_encode with every option): the
//! OBUs, the AVIF, the reconstruction and the stats, as the C++ (av1t_ref_encode) had them where
//! they were recorded.
use super::*;
use crate::dsp::Rng;
use crate::hybrid::tests::{Pic, screen_pic};
use crate::testsupport::snapshot::{OUTPUT, Snapshot, put_output};

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

/// The families of an encode's result: the error code ("rc", 0 when it succeeds) and the output's.
const FAMS: [&str; 5] = ["rc", OUTPUT[0], OUTPUT[1], OUTPUT[2], OUTPUT[3]];

fn put_result(s: &mut Snapshot, a: &Result<Output, Error>) {
    match a {
        Ok(o) => {
            s.put("rc", &OK);
            put_output(s, o);
        }
        Err(e) => s.put("rc", &e.code),
    }
}

#[test]
fn ref_encode_snapshot() {
    let mut s = Snapshot::new(&FAMS);
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
        assert!(a.is_ok(), "case {case}: failed");
        put_result(&mut s, &a);
    }
    s.check_arch(
        &[
            ("rc", 0xa947e50590de8025),
            ("obu", 0x4f9b06a5285c3ed5),
            ("avif", 0x121b7f07c69f787c),
            ("recon", 0x955296a0b37bd35f),
            ("stats", 0xa03edb6e7289c5b4),
        ],
        &[
            ("rc", 0xa947e50590de8025),
            ("obu", 0x461d54e22300a5e3),
            ("avif", 0x0b92b139e73b479c),
            ("recon", 0x0d2946f2ccb07502),
            ("stats", 0x3fcdca7723aa381f),
        ],
    );
}

#[test]
fn ref_engine_options_snapshot() {
    let mut s = Snapshot::new(&FAMS);
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
        assert!(a.is_ok(), "case {case}: failed");
        assert_eq!(stats.blocks as usize, rec.blocks.len());
        put_result(&mut s, &a);
    }
    s.check_arch(
        &[
            ("rc", 0xc42a06f7e7a28e25),
            ("obu", 0x268d9959e5c79123),
            ("avif", 0x632b6466cd94b68a),
            ("recon", 0x5ad686ac51f175b7),
            ("stats", 0xe084efabd8b0d734),
        ],
        &[
            ("rc", 0xc42a06f7e7a28e25),
            ("obu", 0xcf371ff80736629e),
            ("avif", 0x361645bd2653449d),
            ("recon", 0x937e6e0852154343),
            ("stats", 0xa42b405f454c91d9),
        ],
    );
}

#[test]
fn ref_encode_errors_snapshot() {
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
    assert!(a.is_err());
    let mut s = Snapshot::new(&FAMS);
    put_result(&mut s, &a);
    s.check(&[
        ("rc", 0x994f76653e2a3951),
        ("obu", 0xcbf29ce484222325),
        ("avif", 0xcbf29ce484222325),
        ("recon", 0xcbf29ce484222325),
        ("stats", 0xcbf29ce484222325),
    ]);
}
