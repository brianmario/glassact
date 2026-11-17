//! What the decoder allocates once it's warm: a counting allocator (this test binary's own) over
//! a second pass of the same streams. The frame buffers, reference pictures and CDFs are the
//! decoder's from the first pass; what remains is the worker pool's job for each parallel stage
//! and the lock of each stage's queue (about 17 allocations, 1.3 KB, a 5K frame). With
//! $OWNDEC_DIR set, its 5K streams too.
use glassact_av1::decoder::Decoder;
use glassact_av1::testsupport::inter_gen::InterSeq;
use glassact_av1::types::{ENC_FIX_RANGE, ENC_NO_SEQ_HEADER, ENC_TD, EncodeOpts, FRAME_KEY};
use glassact_av1::writer::{Output, RefPicture, RefSlots, Writer};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};

struct Counting;
static ON: AtomicBool = AtomicBool::new(false);
static ALLOCS: AtomicU64 = AtomicU64::new(0);
static BYTES: AtomicU64 = AtomicU64::new(0);

// SAFETY: forwards to the system allocator, counting while ON.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        if ON.load(Relaxed) {
            ALLOCS.fetch_add(1, Relaxed);
            BYTES.fetch_add(l.size() as u64, Relaxed);
        }
        // SAFETY: the caller's layout.
        unsafe { System.alloc(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        // SAFETY: p came from alloc with l.
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        if ON.load(Relaxed) {
            ALLOCS.fetch_add(1, Relaxed);
            BYTES.fetch_add(n as u64, Relaxed);
        }
        // SAFETY: as GlobalAlloc::realloc.
        unsafe { System.realloc(p, l, n) }
    }
}

#[global_allocator]
static A: Counting = Counting;

/// Random sequence `seed`'s temporal units, as the writer codes them.
fn stream(seed: u64) -> Vec<Vec<u8>> {
    let mut seq = InterSeq::make(seed, 300, 10).unwrap();
    let mut w = Writer::with_threads(2);
    let mut outs: Vec<Output> = Vec::new();
    let mut slot_of = [usize::MAX; 8];
    for (k, rec) in seq.frames.iter_mut().enumerate() {
        let refs: RefSlots =
            core::array::from_fn(|s| (slot_of[s] != usize::MAX).then(|| RefPicture::from_output(&outs[slot_of[s]])));
        let mut out = Output::default();
        let flags = ENC_FIX_RANGE | ENC_TD | (seq.flags[k] & ENC_NO_SEQ_HEADER);
        w.encode_ex(
            rec.as_mut(),
            &EncodeOpts {
                flags,
                seq_level_idx: -1,
            },
            &refs,
            &mut out,
        )
        .unwrap();
        let refresh = if rec.fp.frame_type == FRAME_KEY {
            0xFF
        } else {
            rec.fp.refresh_frame_flags
        };
        for (s, slot) in slot_of.iter_mut().enumerate() {
            if refresh >> s & 1 != 0 {
                *slot = k;
            }
        }
        outs.push(out);
    }
    outs.into_iter().map(|o| o.obu).collect()
}

/// The temporal units of the IVF files in $OWNDEC_DIR.
fn ivf_streams() -> Vec<(String, Vec<Vec<u8>>)> {
    let Ok(dir) = std::env::var("OWNDEC_DIR") else {
        return Vec::new();
    };
    let mut v = Vec::new();
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        if p.extension().is_some_and(|x| x == "ivf") {
            let ivf = std::fs::read(&p).unwrap();
            let mut tus = Vec::new();
            let mut at = 32;
            while at + 12 <= ivf.len() {
                let size = u32::from_le_bytes(ivf[at..at + 4].try_into().unwrap()) as usize;
                tus.push(ivf[at + 12..at + 12 + size].to_vec());
                at += 12 + size;
            }
            v.push((p.display().to_string(), tus));
        }
    }
    v.sort();
    v
}

#[test]
fn warm_decoder_allocates_little() {
    let mut streams: Vec<(String, Vec<Vec<u8>>)> = (0..6).map(|s| (format!("random {s}"), stream(s))).collect();
    streams.extend(ivf_streams());
    for (name, tus) in &streams {
        let mut d = Decoder::new(8);
        let mut counts = Vec::new();
        for pass in 0..2 {
            d.reset();
            for tu in tus {
                ALLOCS.store(0, Relaxed);
                BYTES.store(0, Relaxed);
                ON.store(pass == 1, Relaxed);
                let r = d.decode(tu).map(|_| ());
                ON.store(false, Relaxed);
                r.unwrap_or_else(|e| panic!("{name}: {e}"));
                if pass == 1 {
                    counts.push((ALLOCS.load(Relaxed), BYTES.load(Relaxed)));
                }
            }
        }
        let n = counts.len() as u64;
        let (a, b): (u64, u64) = counts.iter().fold((0, 0), |s, c| (s.0 + c.0, s.1 + c.1));
        let (amax, bmax) = counts.iter().fold((0, 0), |s, c| (s.0.max(c.0), s.1.max(c.1)));
        eprintln!(
            "{name}: {n} frames warm: {:.1} allocations, {:.0} bytes a frame on average; at most {amax}, {bmax} bytes",
            a as f64 / n as f64,
            b as f64 / n as f64
        );
        assert!(
            amax < 64 && bmax < 8 << 10,
            "{name}: {amax} allocations, {bmax} bytes in a frame"
        );
    }
}
