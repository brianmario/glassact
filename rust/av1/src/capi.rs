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
    let inter = if rec.fp.version >= 2 {
        unsafe { opt_slice(rec.inter, rec.n_blocks as usize) }
    } else {
        &[]
    };
    let counts = match writer::layout_counts_ex(&rec.fp, blocks, inter) {
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
    match writer::layout_ex(&rec.fp, blocks, inter, block_txb, txb) {
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
pub unsafe extern "C" fn av1g_encode_ex(
    rec: *mut DecisionRecord,
    opts: *const EncodeOpts,
    refs: *const RefPlanesC,
    out: *mut Output,
) -> c_int {
    // SAFETY: out is the caller's av1g_output; rec's arrays are valid for its counts; refs, if not
    // null, holds 8 slots whose non-null planes hold the picture's size at their strides.
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
    let fp = unsafe { (*rec).fp };
    let mut slots: writer::RefSlots = [None; 8];
    if !refs.is_null() {
        for (i, slot) in slots.iter_mut().enumerate() {
            let r = unsafe { &*refs.add(i) };
            if r.plane[0].is_null() {
                continue;
            }
            let mut pic = writer::RefPicture::default();
            for p in 0..if fp.monochrome != 0 { 1 } else { 3 } {
                let sub = (p != 0) as u32;
                let (w, h) = ((fp.width + sub) >> sub, (fp.height + sub) >> sub);
                let stride = r.stride[p].max(0) as usize;
                if r.plane[p].is_null() || h == 0 || stride < w as usize {
                    set_error(
                        &mut out.error,
                        &format!("reference slot {i} plane {p}: missing or stride too small"),
                    );
                    return ERR_INVALID;
                }
                pic.plane[p] = unsafe { slice::from_raw_parts(r.plane[p], (h as usize - 1) * stride + w as usize) };
                pic.stride[p] = stride;
            }
            *slot = Some(pic);
        }
    }
    let res: Result<(), Error> = match unsafe { RecordMut::from_c(&mut *rec) } {
        Ok(view) => {
            let mut o = writer::Output::default();
            writer::Writer::new()
                .encode_ex(view, &opts, &slots, &mut o)
                .map(|_| to_c_output(&o, out))
        }
        Err(e) => Err(e),
    };
    match res {
        Ok(()) => OK,
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
    if fp.is_null() || addrs.is_null() {
        return size_of::<crate::enc::GpuPfFrame>(); // a size query
    }
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

// ---- av1enc.h: the hybrid encoder ----

/// av1enc_hybrid: the encoder and the C view of its record, which Swift holds a pointer to.
pub struct HybridHandle {
    h: crate::hybrid::Hybrid,
    rec: DecisionRecord,
}

#[unsafe(no_mangle)]
pub extern "C" fn av1enc_hybrid_create() -> *mut HybridHandle {
    // SAFETY: plain data, all zero is empty
    let rec = unsafe { core::mem::zeroed() };
    Box::into_raw(Box::new(HybridHandle {
        h: crate::hybrid::Hybrid::new(),
        rec,
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_destroy(h: *mut HybridHandle) {
    if !h.is_null() {
        // SAFETY: h came from av1enc_hybrid_create
        drop(unsafe { Box::from_raw(h) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_closed_loop(
    h: *mut HybridHandle,
    y: *const u8,
    u: *const u8,
    v: *const u8,
    w: u32,
    hgt: u32,
    blocks: *const Block,
    n: u32,
    luma_tx: *const u8,
    flags: c_int,
    qindex: c_int,
    tile_cols_log2: c_int,
    tile_rows_log2: c_int,
    err: *mut c_char,
    errlen: usize,
) -> c_int {
    if h.is_null() || y.is_null() || u.is_null() || v.is_null() || blocks.is_null() || n == 0 || w < 1 || hgt < 1 {
        unsafe { set_error_raw(err, errlen, "bad arguments") };
        return ERR_INVALID;
    }
    // SAFETY: tight 4:2:0 planes, n blocks, and n luma tx types when given (av1enc.h).
    let hh = unsafe { &mut *h };
    let (cw, ch) = (w.div_ceil(2) as usize, hgt.div_ceil(2) as usize);
    let (y, u, v, blocks) = unsafe {
        (
            slice::from_raw_parts(y, w as usize * hgt as usize),
            slice::from_raw_parts(u, cw * ch),
            slice::from_raw_parts(v, cw * ch),
            slice::from_raw_parts(blocks, n as usize),
        )
    };
    let luma_tx = (!luma_tx.is_null()).then(|| unsafe { slice::from_raw_parts(luma_tx, n as usize) });
    let r = hh.h.closed_loop(
        y,
        u,
        v,
        w,
        hgt,
        blocks,
        luma_tx,
        flags,
        qindex,
        tile_cols_log2,
        tile_rows_log2,
    );
    hh.rec = hh.h.record_c();
    match r {
        Ok(()) => OK,
        Err(e) => {
            unsafe { set_error_raw(err, errlen, &e.msg) };
            e.code
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_closed_loop_ex(
    h: *mut HybridHandle,
    y: *const u8,
    u: *const u8,
    v: *const u8,
    w: u32,
    hgt: u32,
    blocks: *const Block,
    n: u32,
    luma_tx: *const u8,
    flags: c_int,
    qindex: c_int,
    tile_cols_log2: c_int,
    tile_rows_log2: c_int,
    video: *const FrameParams,
    inter: *const BlockInter,
    reference: *const RefPlanesC,
    err: *mut c_char,
    errlen: usize,
) -> c_int {
    if h.is_null() || y.is_null() || u.is_null() || v.is_null() || blocks.is_null() || n == 0 || w < 1 || hgt < 1 {
        unsafe { set_error_raw(err, errlen, "bad arguments") };
        return ERR_INVALID;
    }
    // SAFETY: tight 4:2:0 planes, n blocks, n luma tx types and n inter entries when given, and
    // the reference's planes of the picture's size at their strides (av1enc.h).
    let hh = unsafe { &mut *h };
    let (cw, ch) = (w.div_ceil(2) as usize, hgt.div_ceil(2) as usize);
    let (y, u, v, blocks) = unsafe {
        (
            slice::from_raw_parts(y, w as usize * hgt as usize),
            slice::from_raw_parts(u, cw * ch),
            slice::from_raw_parts(v, cw * ch),
            slice::from_raw_parts(blocks, n as usize),
        )
    };
    let luma_tx = (!luma_tx.is_null()).then(|| unsafe { slice::from_raw_parts(luma_tx, n as usize) });
    let inter: &[BlockInter] = if inter.is_null() {
        &[]
    } else {
        unsafe { slice::from_raw_parts(inter, n as usize) }
    };
    let mut pic = None;
    if !reference.is_null() {
        let r = unsafe { &*reference };
        let mut p = writer::RefPicture::default();
        for k in 0..3 {
            let sub = (k != 0) as u32;
            let (pw, ph) = ((w + sub) >> sub, (hgt + sub) >> sub);
            let stride = r.stride[k].max(0) as usize;
            if r.plane[k].is_null() || stride < pw as usize {
                unsafe { set_error_raw(err, errlen, "reference: a plane is missing or its stride too small") };
                return ERR_INVALID;
            }
            p.plane[k] = unsafe { slice::from_raw_parts(r.plane[k], (ph as usize - 1) * stride + pw as usize) };
            p.stride[k] = stride;
        }
        pic = Some(p);
    }
    let vid = (!video.is_null()).then(|| crate::hybrid::Video {
        fp: unsafe { *video },
        inter,
        reference: pic,
    });
    let r = hh.h.closed_loop_ex(
        y,
        u,
        v,
        w,
        hgt,
        blocks,
        luma_tx,
        flags,
        qindex,
        tile_cols_log2,
        tile_rows_log2,
        vid.as_ref(),
    );
    hh.rec = hh.h.record_c();
    match r {
        Ok(()) => OK,
        Err(e) => {
            unsafe { set_error_raw(err, errlen, &e.msg) };
            e.code
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_record(h: *mut HybridHandle) -> *mut DecisionRecord {
    // SAFETY: h came from av1enc_hybrid_create; the view stays valid until the next call.
    unsafe { &mut (*h).rec }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_write(
    h: *mut HybridHandle,
    fp: *const FrameParams,
    sb_cdef: *const i8,
    sb_cols: c_int,
    obu: *mut *mut u8,
    size: *mut usize,
    err: *mut c_char,
    errlen: usize,
) -> c_int {
    if h.is_null() || fp.is_null() || obu.is_null() || size.is_null() {
        return ERR_INVALID;
    }
    // SAFETY: the handle, fp, and a per-SB cdef map covering the picture (sb_cols wide) when given.
    let hh = unsafe { &mut *h };
    let fp = unsafe { &*fp };
    let sb_cdef = (!sb_cdef.is_null()).then(|| {
        let rows = (crate::blockinfo::mi_rows(fp.height as i32) as usize + 15) >> 4;
        unsafe { slice::from_raw_parts(sb_cdef, rows * sb_cols.max(0) as usize) }
    });
    let r = hh.h.write(fp, sb_cdef, sb_cols.max(0) as usize).map(|b| b.to_vec());
    hh.rec = hh.h.record_c();
    match r {
        Ok(bytes) => {
            unsafe {
                *obu = malloc_copy(&bytes);
                *size = bytes.len();
            }
            OK
        }
        Err(e) => {
            unsafe { set_error_raw(err, errlen, &e.msg) };
            e.code
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_set_reuse(h: *mut HybridHandle, on: c_int) {
    // SAFETY: the handle
    unsafe { (*h).h.set_reuse(on != 0) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_reused_tiles(h: *const HybridHandle) -> u32 {
    // SAFETY: the handle
    unsafe { (*h).h.reused_tiles() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_changed_superblocks(
    h: *const HybridHandle,
    out: *mut u8,
    sb_cols: c_int,
    sb_rows: c_int,
) -> c_int {
    if h.is_null() || out.is_null() || sb_cols < 0 || sb_rows < 0 {
        return 0;
    }
    // SAFETY: the handle, and sb_cols x sb_rows bytes at out.
    let out = unsafe { slice::from_raw_parts_mut(out, sb_cols as usize * sb_rows as usize) };
    unsafe { (*h).h.changed_superblocks(out, sb_cols as usize, sb_rows as usize) as c_int }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_recon(h: *const HybridHandle, plane: c_int) -> *const u8 {
    if plane < 0 {
        return ptr::null();
    }
    // SAFETY: the handle; the plane stays valid until the next call.
    match unsafe { (*h).h.recon(plane as usize) } {
        Some(p) if !p.is_empty() => p.as_ptr(),
        _ => ptr::null(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_source(h: *const HybridHandle, plane: c_int, stride: *mut c_int) -> *const u8 {
    if plane < 0 {
        return ptr::null();
    }
    // SAFETY: the handle; the plane stays valid until the next call.
    match unsafe { (*h).h.source(plane as usize) } {
        Some((p, s)) => {
            if !stride.is_null() {
                unsafe { *stride = s as c_int };
            }
            p.as_ptr()
        }
        None => ptr::null(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_hybrid_seconds(h: *const HybridHandle, which: c_int) -> f64 {
    // SAFETY: the handle
    unsafe { (*h).h.seconds(which as usize) }
}

// ---- av1core_test.h ----

/// av1t_case: a random legal record and the C view Swift holds a pointer to.
pub struct CaseHandle {
    #[allow(dead_code)] // owns the vectors `rec` points into
    case: crate::testsupport::FuzzCase,
    rec: DecisionRecord,
}

#[unsafe(no_mangle)]
pub extern "C" fn av1t_case_make(seed: u64, maxdim: c_int, big_pct: c_int) -> *mut CaseHandle {
    match crate::testsupport::case_make(seed, maxdim, big_pct) {
        Some(mut case) => {
            let rec = case.record();
            Box::into_raw(Box::new(CaseHandle { case, rec }))
        }
        None => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1t_case_record(c: *mut CaseHandle) -> *mut DecisionRecord {
    // SAFETY: c came from av1t_case_make; the record points into its vectors.
    unsafe { &mut (*c).rec }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1t_case_free(c: *mut CaseHandle) {
    if !c.is_null() {
        // SAFETY: c came from av1t_case_make
        drop(unsafe { Box::from_raw(c) });
    }
}

/// av1t_inter_case: a random legal inter sequence and the C views of its frames' records.
pub struct InterCaseHandle {
    #[allow(dead_code)] // owns the vectors the views point into
    seq: crate::testsupport::InterSeq,
    recs: Vec<DecisionRecord>,
}

#[unsafe(no_mangle)]
pub extern "C" fn av1t_inter_case_make(seed: u64, maxdim: c_int, nframes: c_int) -> *mut InterCaseHandle {
    match crate::testsupport::inter_seq_make(seed, maxdim, nframes.max(1) as usize) {
        Some(mut seq) => {
            let recs = seq.frames.iter_mut().map(|r| r.as_c()).collect();
            Box::into_raw(Box::new(InterCaseHandle { seq, recs }))
        }
        None => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1t_inter_case_frames(c: *const InterCaseHandle) -> c_int {
    // SAFETY: c came from av1t_inter_case_make
    unsafe { (*c).recs.len() as c_int }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1t_inter_case_record(c: *mut InterCaseHandle, frame: c_int) -> *mut DecisionRecord {
    // SAFETY: c came from av1t_inter_case_make; the records point into its vectors.
    let c = unsafe { &mut *c };
    match c.recs.get_mut(frame.max(0) as usize) {
        Some(r) => r,
        None => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1t_inter_case_free(c: *mut InterCaseHandle) {
    if !c.is_null() {
        // SAFETY: c came from av1t_inter_case_make
        drop(unsafe { Box::from_raw(c) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1t_ref_encode(
    y: *const u8,
    u: *const u8,
    v: *const u8,
    w: u32,
    h: u32,
    opts: *const crate::testsupport::RefOpts,
    out: *mut Output,
) -> c_int {
    // SAFETY: tight 4:2:0 planes; opts and out are the caller's.
    let out = unsafe { &mut *out };
    *out = zero_output();
    let (cw, ch) = (w.div_ceil(2) as usize, h.div_ceil(2) as usize);
    let (y, u, v) = unsafe {
        (
            opt_slice(y, w as usize * h as usize),
            opt_slice(u, cw * ch),
            opt_slice(v, cw * ch),
        )
    };
    match crate::testsupport::ref_encode(y, u, v, w, h, unsafe { &*opts }) {
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

/// av1t_dsp_set: the C view first, so the pointer Swift holds is the box's.
#[repr(C)]
pub struct DspSetHandle {
    view: crate::testsupport::DspSetC,
    set: crate::testsupport::DspSet,
}

#[unsafe(no_mangle)]
pub extern "C" fn av1t_dsp_set_make(seed: u64) -> *const crate::testsupport::DspSetC {
    let set = crate::testsupport::DspSet::make(seed);
    let view = set.c_view();
    let b = Box::into_raw(Box::new(DspSetHandle { view, set }));
    // SAFETY: b was just allocated; the view's arrays point into the boxed set, which doesn't move.
    unsafe {
        (*b).view.priv_ = b as *mut c_void;
        &(*b).view
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1t_dsp_set_free(p: *const crate::testsupport::DspSetC) {
    if !p.is_null() {
        // SAFETY: p is the view of a set from av1t_dsp_set_make.
        drop(unsafe { Box::from_raw((*p).priv_ as *mut DspSetHandle) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1t_inverse_transform(tx_sz: i32, tx_type: i32, dq: *const i32, residual: *mut i32) -> u32 {
    // SAFETY: dq holds th x tw (<= 32x32) values, residual W x H (<= 64x64) (av1core_test.h).
    let n = crate::dsp::tx_coeffs(tx_sz);
    let (wd, ht) = (crate::dsp::tx_w(tx_sz) as usize, crate::dsp::tx_h(tx_sz) as usize);
    let (dq, res) = unsafe {
        (
            slice::from_raw_parts(dq, n),
            slice::from_raw_parts_mut(residual, wd * ht),
        )
    };
    crate::testsupport::inverse_transform(tx_sz, tx_type, dq, res)
}

#[unsafe(no_mangle)]
pub extern "C" fn av1t_tx_type_allowed(tx_sz: i32, tx_type: i32) -> i32 {
    crate::testsupport::tx_type_allowed(tx_sz, tx_type) as i32
}

// ---- av1enc.h: motion for screen content (crate::motion) ----

#[unsafe(no_mangle)]
pub extern "C" fn av1enc_motion_create() -> *mut crate::motion::Motion {
    Box::into_raw(Box::new(crate::motion::Motion::new()))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_motion_destroy(m: *mut crate::motion::Motion) {
    if !m.is_null() {
        // SAFETY: m came from av1enc_motion_create
        drop(unsafe { Box::from_raw(m) });
    }
}

/// `planes` planes (Y w x h, chroma half, rounded up) at their strides.
unsafe fn motion_planes<'a>(
    p: *const *const u8,
    s: *const c_int,
    width: c_int,
    height: c_int,
    planes: c_int,
) -> [crate::motion::Plane<'a>; 3] {
    let mk = |i: usize| {
        let (w, h) = if i == 0 {
            (width as usize, height as usize)
        } else {
            ((width as usize).div_ceil(2), (height as usize).div_ceil(2))
        };
        // SAFETY: the caller's planes
        unsafe {
            let st = *s.add(i) as usize;
            crate::motion::Plane {
                data: slice::from_raw_parts(*p.add(i), st * (h - 1) + w),
                stride: st,
                width: w,
                height: h,
            }
        }
    };
    let three = planes == 3;
    [mk(0), mk(if three { 1 } else { 0 }), mk(if three { 2 } else { 0 })]
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_motion_classify(
    m: *mut crate::motion::Motion,
    cur: *const *const u8,
    cur_stride: *const c_int,
    prev: *const *const u8,
    prev_stride: *const c_int,
    width: c_int,
    height: c_int,
    planes: c_int,
    max_candidates: c_int,
    out: *mut i32,
) -> c_int {
    if m.is_null() || width < 1 || height < 1 || (planes != 1 && planes != 3) {
        return -1;
    }
    // SAFETY: the handle; both pictures' planes; out holds 3 ints per 64x64 (av1enc.h)
    let (c, q) = unsafe {
        (
            motion_planes(cur, cur_stride, width, height, planes),
            motion_planes(prev, prev_stride, width, height, planes),
        )
    };
    let m = unsafe { &mut *m };
    let n = m.classify(&c, &q, planes as usize, max_candidates.max(0) as usize);
    if !out.is_null() {
        let o = unsafe { slice::from_raw_parts_mut(out, 3 * m.sbs.len()) };
        for (k, s) in m.sbs.iter().enumerate() {
            o[3 * k..3 * k + 3].copy_from_slice(&[s.copy as i32, s.shift.dx, s.shift.dy]);
        }
    }
    n as c_int
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn av1enc_motion_apply(
    m: *mut crate::motion::Motion,
    sb_motion: *const i32,
    blocks: *const Block,
    n: u32,
    luma_tx: *const u8,
    width: c_int,
    height: c_int,
    out_blocks: *mut *const Block,
    out_inter: *mut *const BlockInter,
    out_luma_tx: *mut *const u8,
) -> c_int {
    if m.is_null() || blocks.is_null() || width < 1 || height < 1 {
        return -1;
    }
    // SAFETY: the handle; 3 ints per 64x64 when given; n blocks and n luma tx types when given;
    // the outputs point into the handle until its next call (av1enc.h)
    let m = unsafe { &mut *m };
    let b = unsafe { slice::from_raw_parts(blocks, n as usize) };
    let l = (!luma_tx.is_null()).then(|| unsafe { slice::from_raw_parts(luma_tx, n as usize) });
    let sb_cols = (width as usize).div_ceil(64);
    let nsb = sb_cols * (height as usize).div_ceil(64);
    let sbs: Vec<crate::motion::SbMotion> = if sb_motion.is_null() {
        Vec::new()
    } else {
        let t = unsafe { slice::from_raw_parts(sb_motion, 3 * nsb) };
        t.as_chunks::<3>()
            .0
            .iter()
            .map(|c| crate::motion::SbMotion {
                copy: c[0] != 0,
                shift: crate::motion::Shift { dx: c[1], dy: c[2] },
            })
            .collect()
    };
    m.apply(
        &sbs,
        sb_cols,
        b,
        l,
        crate::blockinfo::mi_rows(height),
        crate::blockinfo::mi_cols(width),
    );
    unsafe {
        *out_blocks = m.blocks.as_ptr();
        *out_inter = m.inter.as_ptr();
        *out_luma_tx = m.luma_tx.as_ptr();
    }
    m.blocks.len() as c_int
}
