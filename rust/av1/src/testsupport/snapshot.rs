//! Snapshot tests' hashes: FNV-1a 64 of a test's outputs on fixed seeds, per family of outputs
//! (bytes, reconstructions, decisions, DSP results), compared with constants recorded in the test.
//! A test fails when an output that is still valid AV1 changes: an optimization that moves a hash
//! is a format change, not an optimization (README "Exact").
//!
//! Values feed in a fixed little-endian byte order, slices with their length, so a hash depends on
//! the values alone (not on padding, pointers, threads or the platform). Tests that run cases on
//! several threads hash each case on its own and fold the cases' hashes in case order
//! ([`Snapshot::absorb`]).
//!
//! Recording: a test whose constants are missing or stale fails with every family's hash, in a
//! line to paste into the test. Record from a tree whose outputs are known good.
use crate::testsupport::{FuzzCase, ItxCase, PredCase, Sym};
use crate::types::*;

/// FNV-1a, 64 bits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fnv(pub u64);

impl Default for Fnv {
    fn default() -> Self {
        Fnv(0xcbf2_9ce4_8422_2325)
    }
}

impl Fnv {
    #[inline]
    pub fn bytes(&mut self, b: &[u8]) {
        let mut h = self.0;
        for &x in b {
            h ^= x as u64;
            h = h.wrapping_mul(0x0100_0000_01b3);
        }
        self.0 = h;
    }
    /// Feeds `v`; chains.
    #[inline]
    pub fn put<T: Snap + ?Sized>(&mut self, v: &T) -> &mut Self {
        v.snap(self);
        self
    }
}

/// A value a snapshot hashes.
pub trait Snap {
    fn snap(&self, h: &mut Fnv);
}

macro_rules! snap_int {
    ($($t:ty),*) => {$(
        impl Snap for $t {
            #[inline]
            fn snap(&self, h: &mut Fnv) {
                h.bytes(&self.to_le_bytes());
            }
        }
    )*};
}
snap_int!(u8, i8, u16, i16, u32, i32, u64, i64);

impl Snap for usize {
    fn snap(&self, h: &mut Fnv) {
        (*self as u64).snap(h)
    }
}
impl Snap for isize {
    fn snap(&self, h: &mut Fnv) {
        (*self as i64).snap(h)
    }
}
impl Snap for bool {
    fn snap(&self, h: &mut Fnv) {
        (*self as u8).snap(h)
    }
}
impl Snap for f32 {
    fn snap(&self, h: &mut Fnv) {
        self.to_bits().snap(h)
    }
}
impl Snap for f64 {
    fn snap(&self, h: &mut Fnv) {
        self.to_bits().snap(h)
    }
}
impl Snap for str {
    fn snap(&self, h: &mut Fnv) {
        self.as_bytes().snap(h)
    }
}
impl Snap for String {
    fn snap(&self, h: &mut Fnv) {
        self.as_str().snap(h)
    }
}
impl<T: Snap> Snap for [T] {
    fn snap(&self, h: &mut Fnv) {
        self.len().snap(h);
        for v in self {
            v.snap(h);
        }
    }
}
impl<T: Snap, const N: usize> Snap for [T; N] {
    fn snap(&self, h: &mut Fnv) {
        for v in self {
            v.snap(h);
        }
    }
}
impl<T: Snap> Snap for Vec<T> {
    fn snap(&self, h: &mut Fnv) {
        self[..].snap(h)
    }
}
impl<T: Snap + ?Sized> Snap for &T {
    fn snap(&self, h: &mut Fnv) {
        (**self).snap(h)
    }
}
impl<T: Snap + ?Sized> Snap for Box<T> {
    fn snap(&self, h: &mut Fnv) {
        (**self).snap(h)
    }
}
impl<T: Snap> Snap for Option<T> {
    fn snap(&self, h: &mut Fnv) {
        match self {
            None => 0u8.snap(h),
            Some(v) => {
                1u8.snap(h);
                v.snap(h)
            }
        }
    }
}
impl<T: Snap, E: Snap> Snap for Result<T, E> {
    fn snap(&self, h: &mut Fnv) {
        match self {
            Ok(v) => {
                0u8.snap(h);
                v.snap(h)
            }
            Err(e) => {
                1u8.snap(h);
                e.snap(h)
            }
        }
    }
}
impl Snap for () {
    fn snap(&self, _: &mut Fnv) {}
}
macro_rules! snap_tuple {
    ($(($($n:tt $t:ident),*)),*) => {$(
        impl<$($t: Snap),*> Snap for ($($t,)*) {
            fn snap(&self, h: &mut Fnv) {
                $(self.$n.snap(h);)*
            }
        }
    )*};
}
snap_tuple!((0 A), (0 A, 1 B), (0 A, 1 B, 2 C), (0 A, 1 B, 2 C, 3 D), (0 A, 1 B, 2 C, 3 D, 4 E),
    (0 A, 1 B, 2 C, 3 D, 4 E, 5 F), (0 A, 1 B, 2 C, 3 D, 4 E, 5 F, 6 G), (0 A, 1 B, 2 C, 3 D, 4 E, 5 F, 6 G, 7 H));

/// `Snap` for a struct, field by field in declaration order. The pattern names every field, so a
/// new field doesn't compile until it's added here.
macro_rules! snap_struct {
    ($t:ident { $($f:ident),* $(,)? }) => {
        impl Snap for $t {
            fn snap(&self, h: &mut Fnv) {
                let $t { $($f),* } = self;
                $($f.snap(h);)*
            }
        }
    };
}

snap_struct!(Block {
    mi_row,
    mi_col,
    bsize,
    skip,
    tx_depth,
    y_mode,
    angle_delta_y,
    uv_mode,
    angle_delta_uv,
    cfl_alpha_u,
    cfl_alpha_v,
    filter_intra,
    cdef_idx,
    sb_qindex,
});
snap_struct!(Txb {
    coeff_off,
    x4,
    y4,
    plane,
    tx_size,
    tx_type,
    flags,
    eob,
    reserved,
});
snap_struct!(FrameParams {
    version,
    width,
    height,
    monochrome,
    base_q_idx,
    tx_mode_select,
    reduced_tx_set,
    tile_cols_log2,
    tile_rows_log2,
    delta_q_y_dc,
    delta_q_u_dc,
    delta_q_u_ac,
    delta_q_v_dc,
    delta_q_v_ac,
    enable_filter_intra,
    enable_intra_edge_filter,
    delta_q_present,
    delta_q_res,
    using_qmatrix,
    qm_y,
    qm_u,
    qm_v,
    loop_filter_level,
    loop_filter_sharpness,
    enable_cdef,
    cdef_damping_minus_3,
    cdef_bits,
    cdef_y_pri,
    cdef_y_sec,
    cdef_uv_pri,
    cdef_uv_sec,
    allow_screen_content_tools,
    video,
    frame_type,
    ref_slot,
    refresh_frame_flags,
    error_resilient_mode,
    lf_inter_off,
    cdf_from_ref,
    mv_precision,
    sb128,
    allow_intrabc,
    stream_width,
    stream_height,
    golden_slot,
    chroma_format,
});
snap_struct!(BlockPalette {
    size_y,
    size_uv,
    reserved,
    map_off,
    colors,
});
snap_struct!(BlockInter {
    mv_row,
    mv_col,
    is_inter,
    reserved,
});
snap_struct!(Tiles {
    cols_log2,
    rows_log2,
    cols,
    rows,
    mi_col_starts,
    mi_row_starts,
});
snap_struct!(GaPfAddrs {
    plane,
    stride,
    skip,
    lf_tx,
    cdef_idx,
    cdef_dir_var,
});
snap_struct!(GaTuneiqFrame {
    lf_level,
    lf_sharpness,
    cdef_damping,
    cdef_mode,
    rdmult,
});
snap_struct!(GaCdefCand { pri, sec, npri, nsec });
snap_struct!(GaEntFrame {
    w,
    h,
    mi_cols,
    mi_rows,
    mono,
    qidx,
    reduced,
    txsel,
    sct,
    dq,
    dq_res,
    fi,
    cdef_bits,
    ctx_base,
    ctx_stride,
    ctx_rows,
    ctx_total,
    mi_total,
    n_blocks,
    n_txb,
    n_sb,
    n_tiles,
    tile_cols,
    tile_rows,
    tile_wsb,
    tile_hsb,
    sym_cap,
});
snap_struct!(GaEntTile {
    mi_row_start,
    mi_row_end,
    mi_col_start,
    mi_col_end,
    first_block,
    end_block,
    sb_base,
    n_sb,
    sb_row0,
    sb_col0,
    sb_cols,
});
use crate::writer::LayoutCounts;
snap_struct!(LayoutCounts { n_txb, n_coeffs });
snap_struct!(FuzzCase {
    fp,
    blocks,
    block_txb,
    txb,
    coeffs,
    n_coeffs,
});
snap_struct!(ItxCase {
    tx_sz,
    tx_type,
    dc_q,
    ac_q,
    qm_level,
    plane,
});
snap_struct!(PredCase {
    mode,
    delta,
    log2w,
    log2h,
    have_left,
    have_above,
    have_ar,
    have_bl,
    x,
    y,
    max_x,
    max_y,
    cfl,
    alpha,
    edge_filter,
    filter_type,
    fi_mode,
});
snap_struct!(Sym { cdf_off, s, n, is_bool });

/// The random legal record of av1gpu's fuzzer for (seed, maxdim, big_pct) ([`FuzzCase::make`]) as
/// a writer record (coefficients without the C++'s extra trailing zero).
pub fn fuzz_record(seed: u64, maxdim: i32, big_pct: i32) -> Option<crate::writer::Record> {
    let c = FuzzCase::make(seed, maxdim, big_pct)?;
    Some(crate::writer::Record {
        fp: c.fp,
        blocks: c.blocks,
        block_txb: c.block_txb,
        txb: c.txb,
        coeffs: c.coeffs[..c.n_coeffs as usize].to_vec(),
        inter: Vec::new(),
        palette: Vec::new(),
        palette_map: Vec::new(),
    })
}

impl Snap for crate::writer::Record {
    fn snap(&self, h: &mut Fnv) {
        let crate::writer::Record {
            fp,
            blocks,
            block_txb,
            txb,
            coeffs,
            inter,
            palette,
            palette_map,
        } = self;
        h.put(fp)
            .put(blocks)
            .put(block_txb)
            .put(txb)
            .put(coeffs)
            .put(inter)
            .put(palette)
            .put(palette_map);
    }
}

/// The families of a writer output: "obu", "avif", "recon" (the planes and their sizes) and
/// "stats" (the rest; of the saved CDFs, whether there are any).
pub const OUTPUT: [&str; 4] = ["obu", "avif", "recon", "stats"];

/// Feeds a writer output to the [`OUTPUT`] families of `s`.
pub fn put_output(s: &mut Snapshot, o: &crate::writer::Output) {
    let crate::writer::Output {
        obu,
        avif,
        recon,
        recon_w,
        recon_h,
        seq_level_idx,
        tile_cols,
        tile_rows,
        header_bytes,
        tile_bytes,
        n_symbols,
        n_fixed_txb,
        saved_cdfs,
    } = o;
    s.put("obu", obu);
    s.put("avif", avif);
    s.put("recon", &(recon, recon_w, recon_h));
    s.put(
        "stats",
        &(
            (seq_level_idx, tile_cols, tile_rows, header_bytes),
            (tile_bytes, n_symbols, n_fixed_txb, saved_cdfs.is_some()),
        ),
    );
}

/// Hashes per family of outputs, in a fixed order.
#[derive(Clone, Debug)]
pub struct Snapshot {
    fams: Vec<(&'static str, Fnv, u64)>,
}

impl Snapshot {
    pub fn new(names: &[&'static str]) -> Snapshot {
        Snapshot {
            fams: names.iter().map(|&n| (n, Fnv::default(), 0)).collect(),
        }
    }
    /// The family `name`'s hash, to feed (counts one item).
    pub fn f(&mut self, name: &str) -> &mut Fnv {
        let Some(e) = self.fams.iter_mut().find(|e| e.0 == name) else {
            panic!("snapshot has no family {name:?}");
        };
        e.2 += 1;
        &mut e.1
    }
    /// Feeds `v` to the family `name`.
    pub fn put<T: Snap + ?Sized>(&mut self, name: &str, v: &T) {
        self.f(name).put(v);
    }
    /// Folds a case's snapshot (the same families) into this one: each family takes the case's
    /// hash and item count.
    pub fn absorb(&mut self, case: &Snapshot) {
        assert_eq!(self.fams.len(), case.fams.len());
        for (a, b) in self.fams.iter_mut().zip(&case.fams) {
            assert_eq!(a.0, b.0);
            a.1.put(&b.1.0).put(&b.2);
            a.2 += b.2;
        }
    }
    pub fn hashes(&self) -> Vec<(&'static str, u64)> {
        self.fams.iter().map(|e| (e.0, e.1.0)).collect()
    }
    /// [`Snapshot::check`] with constants by architecture (`aarch64`, else `x86_64`): the hybrid's
    /// and tune=iq's floating-point code contracts `a * b + c` into a fused multiply-add on aarch64
    /// and not on x86_64, as the C++ it was ported from did ([`crate::enc::fmac`]), so their
    /// decisions differ between the two.
    #[track_caller]
    pub fn check_arch(&self, aarch64: &[(&str, u64)], x86_64: &[(&str, u64)]) {
        self.check(if cfg!(target_arch = "x86_64") { x86_64 } else { aarch64 })
    }
    /// Compares every family's hash with `want` (recorded constants: (family, hash) for every
    /// family). Panics naming the families that moved, with the line to paste when re-recording.
    #[track_caller]
    pub fn check(&self, want: &[(&str, u64)]) {
        let got = self.hashes();
        let mut moved = Vec::new();
        for &(name, h) in &got {
            match want.iter().find(|w| w.0 == name) {
                Some(&(_, w)) if w == h => {}
                Some(&(_, w)) => moved.push(format!("{name} (recorded {w:#018x}, now {h:#018x})")),
                None => moved.push(format!("{name} (not recorded, now {h:#018x})")),
            }
        }
        for w in want {
            if !got.iter().any(|g| g.0 == w.0) {
                moved.push(format!("{} (recorded, but the test has no such family)", w.0));
            }
        }
        if !moved.is_empty() {
            let line: Vec<String> = got.iter().map(|(n, h)| format!("(\"{n}\", {h:#018x})")).collect();
            let counts: Vec<String> = self.fams.iter().map(|e| format!("{} {}", e.0, e.2)).collect();
            panic!(
                "snapshot moved: {}\n  items: {}\n  now: &[{}]",
                moved.join(", "),
                counts.join(", "),
                line.join(", ")
            );
        }
    }
}

/// `$rust`, fed to the family `$fam` of the snapshot `$s` (and returned); with the oracle feature,
/// asserted equal to `$c` first.
macro_rules! same {
    ($s:expr, $fam:expr, $rust:expr, $c:expr $(, $($msg:tt)+)?) => {{
        let v = $rust;
        #[cfg(feature = "oracle")]
        assert_eq!(v, $c $(, $($msg)+)?);
        $s.put($fam, &v);
        v
    }};
}
pub(crate) use same;

/// Collects per-case snapshots from threads; [`Cases::fold`] folds them in case order.
pub struct Cases {
    names: &'static [&'static str],
    cases: std::sync::Mutex<Vec<(u64, Snapshot)>>,
}

impl Cases {
    pub fn new(names: &'static [&'static str]) -> Cases {
        Cases {
            names,
            cases: std::sync::Mutex::new(Vec::new()),
        }
    }
    /// A fresh snapshot for one case.
    pub fn case(&self) -> Snapshot {
        Snapshot::new(self.names)
    }
    pub fn add(&self, key: u64, s: Snapshot) {
        self.cases.lock().unwrap().push((key, s));
    }
    pub fn fold(self) -> Snapshot {
        let mut v = self.cases.into_inner().unwrap();
        v.sort_by_key(|c| c.0);
        let mut all = Snapshot::new(self.names);
        for (i, c) in v.iter().enumerate() {
            assert!(i == 0 || v[i - 1].0 != c.0, "case {} twice", c.0);
            all.absorb(&c.1);
        }
        all
    }
}

#[test]
fn fnv_is_fnv1a_64() {
    // the reference vectors of FNV-1a 64
    let h = |s: &str| {
        let mut f = Fnv::default();
        f.bytes(s.as_bytes());
        f.0
    };
    assert_eq!(h(""), 0xcbf2_9ce4_8422_2325);
    assert_eq!(h("a"), 0xaf63_dc4c_8601_ec8c);
    assert_eq!(h("foobar"), 0x8594_4171_f739_67e8);
    // slices with their length, arrays without
    let (mut a, mut b) = (Fnv::default(), Fnv::default());
    a.put(&[1u8, 2][..]);
    b.put(&2u64).put(&[1u8, 2]);
    assert_eq!(a, b);
}
