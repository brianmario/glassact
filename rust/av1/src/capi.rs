//! The C API Swift links (Sources/AV1Core/include/av1g/av1g.h, Sources/AV1Encoder/include/av1enc.h,
//! Sources/AV1CoreTestSupport/include/av1core_test.h), over the safe Rust API.
//!
//! The boundary's rules, as the C++ had them:
//! - Buffers handed to the caller are `malloc`'d: Swift frees them with `free` (or the API's
//!   `*_free`).
//! - Errors are return codes with a message in the output struct. Nothing unwinds into Swift: the
//!   release profile aborts on panic.
//! - Pointers are checked for null where the C++ checked them. Beyond that the caller's pointers
//!   and counts are trusted, as C's are.
#![allow(clippy::missing_safety_doc)]

use crate::types::*;
use crate::writer::{self, Error, RecordMut};
use core::ffi::{c_char, c_int, c_void};
use core::{ptr, slice};

unsafe extern "C" {
    fn malloc(n: usize) -> *mut c_void;
    fn free(p: *mut c_void);
}

/// `v` copied into a fresh `malloc` block (null for an empty `v`, as the C++ left it).
fn malloc_copy(v: &[u8]) -> *mut u8 {
    if v.is_empty() {
        return ptr::null_mut();
    }
    // SAFETY: malloc returns a block of at least v.len() bytes (or null, checked).
    unsafe {
        let p = malloc(v.len()) as *mut u8;
        assert!(!p.is_null(), "out of memory");
        ptr::copy_nonoverlapping(v.as_ptr(), p, v.len());
        p
    }
}

/// `msg` into a fixed C error buffer, truncated and NUL-terminated.
fn set_error(buf: &mut [u8], msg: &str) {
    let n = msg.len().min(buf.len() - 1);
    buf[..n].copy_from_slice(&msg.as_bytes()[..n]);
    buf[n] = 0;
}

/// `msg` into a caller's (err, errlen) buffer, if it has one.
unsafe fn set_error_raw(err: *mut c_char, errlen: usize, msg: &str) {
    if !err.is_null() && errlen > 0 {
        // SAFETY: the caller's buffer holds errlen bytes.
        set_error(unsafe { slice::from_raw_parts_mut(err as *mut u8, errlen) }, msg);
    }
}

unsafe fn opt_slice<'a, T>(p: *const T, n: usize) -> &'a [T] {
    if n == 0 || p.is_null() {
        &[]
    } else {
        unsafe { slice::from_raw_parts(p, n) }
    }
}

// ---- av1g.h ----

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_tile_layout(
    width: u32,
    height: u32,
    cols_log2: c_int,
    rows_log2: c_int,
    out: *mut Tiles,
) -> c_int {
    match writer::tile_layout(width, height, cols_log2, rows_log2) {
        Ok(t) => {
            // SAFETY: out is the caller's av1g_tiles.
            unsafe { *out = t };
            OK
        }
        Err(e) => e,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_layout(rec: *mut DecisionRecord, txb_cap: u32, coeff_cap: u64) -> c_int {
    // SAFETY: rec is the caller's record, its arrays valid for n_blocks (+ 1) and the capacities.
    let rec = unsafe { &mut *rec };
    let blocks = unsafe { opt_slice(rec.blocks, rec.n_blocks as usize) };
    let counts = match writer::layout_counts(&rec.fp, blocks) {
        Ok(c) => c,
        Err(e) => return e,
    };
    rec.n_txb = counts.n_txb;
    rec.n_coeffs = counts.n_coeffs;
    if rec.txb.is_null() || rec.block_txb.is_null() || txb_cap < counts.n_txb || coeff_cap < counts.n_coeffs {
        return ERR_CAPACITY;
    }
    let block_txb = unsafe { slice::from_raw_parts_mut(rec.block_txb, rec.n_blocks as usize + 1) };
    let txb = unsafe { slice::from_raw_parts_mut(rec.txb, counts.n_txb as usize) };
    match writer::layout(&rec.fp, blocks, block_txb, txb) {
        Ok(_) => OK,
        Err(e) => e,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_legalize_sb_qindex(
    base_q_idx: c_int,
    delta_q_res: c_int,
    target: *const u8,
    n: usize,
    legal: *mut u8,
) {
    // SAFETY: both arrays hold n values.
    let (target, legal) = unsafe { (opt_slice(target, n), slice::from_raw_parts_mut(legal, n)) };
    writer::legalize_sb_qindex(base_q_idx, delta_q_res, target, legal);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_apply_sb_qindex(rec: *mut DecisionRecord, sb_map: *const u8) -> c_int {
    // SAFETY: the record's blocks, and a map covering its SB grid.
    let rec = unsafe { &mut *rec };
    let blocks = unsafe { slice::from_raw_parts_mut(rec.blocks, rec.n_blocks as usize) };
    let sb_cols = (crate::blockinfo::mi_cols(rec.fp.width as i32) as usize + 15) >> 4;
    let sb_rows = (crate::blockinfo::mi_rows(rec.fp.height as i32) as usize + 15) >> 4;
    let map = unsafe { slice::from_raw_parts(sb_map, sb_cols * sb_rows) };
    match writer::apply_sb_qindex(&rec.fp, blocks, map) {
        Ok(()) => OK,
        Err(e) => e,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_postfilter(
    rec: *const DecisionRecord,
    planes: *const *mut u8,
    stride: *const c_int,
) -> c_int {
    if rec.is_null() || planes.is_null() || stride.is_null() {
        return ERR_INVALID;
    }
    // SAFETY: the record, and planes of at least MiCols*4 x MiRows*4 (chroma half) at their strides.
    let rec = unsafe { &*rec };
    let blocks = unsafe { opt_slice(rec.blocks, rec.n_blocks as usize) };
    let nplanes = if rec.fp.monochrome != 0 { 1 } else { 3 };
    let mi_rows = crate::blockinfo::mi_rows(rec.fp.height as i32) as usize;
    let mut views: [&mut [u8]; 3] = [&mut [], &mut [], &mut []];
    let mut strides = [0usize; 3];
    for p in 0..nplanes {
        let s = unsafe { *stride.add(p) } as usize;
        let h = (mi_rows * 4) >> (p > 0) as usize;
        strides[p] = s;
        views[p] = unsafe { slice::from_raw_parts_mut(*planes.add(p), s * h) };
    }
    crate::postfilter::postfilter(&rec.fp, blocks, &mut views, &strides);
    OK
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_validate(rec: *const DecisionRecord, err: *mut c_char, errlen: usize) -> c_int {
    // SAFETY: the record's arrays (validation writes back eob and the derived chroma types, as
    // av1g_validate's encode does).
    let mut r = unsafe { *rec };
    let res = match unsafe { RecordMut::from_c(&mut r) } {
        Ok(view) => writer::validate(view),
        Err(e) => Err(e),
    };
    match res {
        Ok(()) => OK,
        Err(e) => {
            unsafe { set_error_raw(err, errlen, &e.msg) };
            e.code
        }
    }
}

fn zero_output() -> Output {
    // SAFETY: av1g_output is plain data; all zero is its empty state.
    unsafe { core::mem::zeroed() }
}

/// av1g_output from the writer's Output (buffers copied into malloc'd blocks).
fn to_c_output(o: &writer::Output, out: &mut Output) {
    out.obu = malloc_copy(&o.obu);
    out.obu_size = o.obu.len();
    out.avif = malloc_copy(&o.avif);
    out.avif_size = o.avif.len();
    for p in 0..3 {
        out.recon[p] = malloc_copy(&o.recon[p]);
        out.recon_w[p] = o.recon_w[p];
        out.recon_h[p] = o.recon_h[p];
    }
    out.seq_level_idx = o.seq_level_idx;
    out.tile_cols = o.tile_cols;
    out.tile_rows = o.tile_rows;
    out.header_bytes = o.header_bytes;
    out.tile_bytes = o.tile_bytes;
    out.n_symbols = o.n_symbols;
    out.n_fixed_txb = o.n_fixed_txb;
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_encode(rec: *mut DecisionRecord, opts: *const EncodeOpts, out: *mut Output) -> c_int {
    // SAFETY: out is the caller's av1g_output; rec's arrays are valid for its counts.
    let out = unsafe { &mut *out };
    *out = zero_output();
    let opts = if opts.is_null() {
        EncodeOpts {
            flags: 0,
            seq_level_idx: -1,
        }
    } else {
        unsafe { *opts }
    };
    let res: Result<writer::Output, Error> = match unsafe { RecordMut::from_c(&mut *rec) } {
        Ok(view) => writer::encode(view, &opts),
        Err(e) => Err(e),
    };
    match res {
        Ok(o) => {
            to_c_output(&o, out);
            OK
        }
        Err(e) => {
            set_error(&mut out.error, &e.msg);
            e.code
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_output_free(out: *mut Output) {
    // SAFETY: the buffers were malloc'd by av1g_encode (or are null).
    let out = unsafe { &mut *out };
    unsafe {
        free(out.obu as *mut c_void);
        free(out.avif as *mut c_void);
        for p in out.recon {
            free(p as *mut c_void);
        }
    }
    out.obu = ptr::null_mut();
    out.avif = ptr::null_mut();
    out.recon = [ptr::null_mut(); 3];
    out.obu_size = 0;
    out.avif_size = 0;
}

/// What av1g_parsed's `priv` keeps alive: the vectors its record and tile tables point into.
struct ParsedPriv {
    parsed: writer::Parsed,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_parse(obus: *const u8, size: usize, out: *mut *mut Parsed) -> c_int {
    // SAFETY: obus holds size bytes; out receives a calloc'd-equivalent av1g_parsed.
    let data = unsafe { opt_slice(obus, size) };
    let p = Box::into_raw(Box::new(Parsed {
        // SAFETY: plain data, all zero is empty
        rec: unsafe { core::mem::zeroed() },
        seq_level_idx: 0,
        n_tiles: 0,
        tile_bytes: ptr::null(),
        tile_offsets: ptr::null(),
        error: [0; 256],
        priv_: ptr::null_mut(),
    }));
    // SAFETY: p was just allocated.
    let parsed = unsafe { &mut *p };
    let rc = match writer::parse(data) {
        Ok(r) => {
            let pr = Box::into_raw(Box::new(ParsedPriv { parsed: r }));
            // SAFETY: pr lives until av1g_parsed_free.
            let r = unsafe { &mut (*pr).parsed };
            parsed.rec = r.rec.as_c();
            parsed.seq_level_idx = r.seq_level_idx;
            parsed.n_tiles = r.tile_bytes.len() as u32;
            parsed.tile_bytes = if r.tile_bytes.is_empty() {
                ptr::null()
            } else {
                r.tile_bytes.as_ptr()
            };
            parsed.tile_offsets = if r.tile_offsets.is_empty() {
                ptr::null()
            } else {
                r.tile_offsets.as_ptr()
            };
            parsed.priv_ = pr as *mut c_void;
            OK
        }
        Err(e) => {
            set_error(&mut parsed.error, &e.msg);
            e.code
        }
    };
    unsafe { *out = p };
    rc
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_parsed_free(p: *mut Parsed) {
    if p.is_null() {
        return;
    }
    // SAFETY: p and its priv came from av1g_parse.
    unsafe {
        let b = Box::from_raw(p);
        if !b.priv_.is_null() {
            drop(Box::from_raw(b.priv_ as *mut ParsedPriv));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_mux_avif(
    obus: *const u8,
    obu_size: usize,
    width: u32,
    height: u32,
    avif: *mut *mut u8,
    avif_size: *mut usize,
) -> c_int {
    unsafe { av1g_mux_avif_ex(obus, obu_size, width, height, ptr::null(), avif, avif_size) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_mux_avif_ex(
    obus: *const u8,
    obu_size: usize,
    width: u32,
    height: u32,
    meta: *const AvifMeta,
    avif: *mut *mut u8,
    avif_size: *mut usize,
) -> c_int {
    // SAFETY: obus holds obu_size bytes; meta (optional) and its ICC are the caller's.
    let data = unsafe { opt_slice(obus, obu_size) };
    let md = if meta.is_null() {
        None
    } else {
        let m = unsafe { &*meta };
        Some(crate::avif::Meta {
            icc: unsafe { opt_slice(m.icc, m.icc_size) },
            irot: m.irot,
            imir: m.imir,
        })
    };
    match crate::avif::mux_avif_ex(data, width, height, md.as_ref()) {
        Ok(v) => {
            unsafe {
                *avif = malloc_copy(&v);
                *avif_size = v.len();
            }
            OK
        }
        Err(e) => e,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1g_exif_orientation_to_irot_imir(orientation: c_int, irot: *mut i32, imir: *mut i32) {
    let (r, m) = crate::avif::exif_orientation_to_irot_imir(orientation);
    // SAFETY: the caller's outputs.
    unsafe {
        *irot = r;
        *imir = m;
    }
}

// ---- av1enc.h (the hybrid encoder's part is in capi_hybrid) ----

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_tables_msl(length: *mut usize) -> *mut c_char {
    let s = crate::enc::tables_msl();
    let mut bytes = s.into_bytes();
    if !length.is_null() {
        // SAFETY: the caller's length
        unsafe { *length = bytes.len() };
    }
    bytes.push(0);
    malloc_copy(&bytes) as *mut c_char
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_ent_plan(
    fp: *const FrameParams,
    n_blocks: u32,
    n_txb: u32,
    frame: *mut GaEntFrame,
    tiles: *mut GaEntTile,
) -> u32 {
    // SAFETY: tiles holds GA_ENT_MAX_TILES entries (av1enc.h).
    unsafe {
        crate::enc::ent_plan(
            &*fp,
            n_blocks,
            n_txb,
            &mut *frame,
            slice::from_raw_parts_mut(tiles, GA_ENT_MAX_TILES),
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_assemble_obus(
    fp: *const FrameParams,
    tile_data: *const *const u8,
    tile_sizes: *const usize,
    n_tiles: u32,
    temporal_delimiter: c_int,
    out: *mut *mut u8,
    out_size: *mut usize,
) -> c_int {
    // SAFETY: n_tiles payloads of the given sizes.
    let tiles: Vec<&[u8]> = (0..n_tiles as usize)
        .map(|i| unsafe { opt_slice(*tile_data.add(i), *tile_sizes.add(i)) })
        .collect();
    match crate::enc::assemble_obus(unsafe { &*fp }, &tiles, temporal_delimiter != 0) {
        Ok(v) => {
            unsafe {
                *out = malloc_copy(&v);
                *out_size = v.len();
            }
            0
        }
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_pf_frame(
    fp: *const FrameParams,
    addrs: *const GaPfAddrs,
    out: *mut c_void,
    cap: usize,
) -> usize {
    // SAFETY: fp and addrs are the caller's; out holds cap bytes.
    let f = crate::enc::pf_frame(unsafe { &*fp }, unsafe { &*addrs });
    let bytes = f.as_bytes();
    if !out.is_null() && cap >= bytes.len() {
        unsafe { ptr::copy_nonoverlapping(bytes.as_ptr(), out as *mut u8, bytes.len()) };
    }
    bytes.len()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_tuneiq_frame(base_q_idx: c_int, mono: c_int, out: *mut GaTuneiqFrame) {
    // SAFETY: the caller's output.
    unsafe { *out = crate::enc::tuneiq_frame(base_q_idx, mono != 0) };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_cdef_bits(
    tots: *const u64,
    max_bits: c_int,
    n_active: c_int,
    mono: c_int,
    rdmult: c_int,
) -> c_int {
    // SAFETY: tots holds max_bits + 1 totals.
    let tots = unsafe { slice::from_raw_parts(tots, max_bits.max(0) as usize + 1) };
    crate::enc::cdef_bits(tots, max_bits, n_active, mono != 0, rdmult)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_cdef_presets(
    lev: *const i32,
    bits: c_int,
    cdef_mode: c_int,
    cd: *const GaCdefCand,
    fp: *mut FrameParams,
) {
    // SAFETY: lev holds 16 values; cd and fp are the caller's.
    unsafe { crate::enc::cdef_presets(&*(lev as *const [i32; 16]), bits, cdef_mode, &*cd, &mut *fp) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_cdef_select_cpu(
    my: *const u32,
    muv: *const u32,
    nc: c_int,
    nsb: c_int,
    mono: c_int,
    max_bits: c_int,
    refine: c_int,
    fast_mono: c_int,
    lev_out: *mut i32,
    tot_out: *mut u64,
) {
    let (nc, nsb, max_bits) = (nc as usize, nsb as usize, max_bits as usize);
    // SAFETY: [nsb][nc] tables (muv unused for mono); (max_bits + 1) x 16 levels, max_bits + 1 totals.
    unsafe {
        let my = slice::from_raw_parts(my, nsb * nc);
        let muv = if mono != 0 {
            &[][..]
        } else {
            slice::from_raw_parts(muv, nsb * nc)
        };
        let lev = slice::from_raw_parts_mut(lev_out, (max_bits + 1) * 16);
        let tot = slice::from_raw_parts_mut(tot_out, max_bits + 1);
        crate::enc::cdef_select_cpu(
            my,
            muv,
            nc,
            nsb,
            mono != 0,
            max_bits,
            refine as usize,
            fast_mono != 0,
            lev,
            tot,
        );
    }
}
