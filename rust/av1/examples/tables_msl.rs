//! The encoder's derived tables as Metal source (`enc::tables_msl`, the `av1enc_tables.h` the
//! kernels include), written to a file: the apps' build compiles the kernels into metallibs with
//! it (`scripts/build-rust --metallib`). At run time `AV1ShaderSource` gets the same text from
//! `av1enc_tables_msl`.
//!
//!   cargo run --release --example tables_msl -- <out.h>
fn main() {
    let Some(out) = std::env::args().nth(1) else {
        eprintln!("usage: tables_msl <out.h>");
        std::process::exit(2);
    };
    if let Err(e) = std::fs::write(&out, glassact_av1::enc::tables_msl()) {
        eprintln!("tables_msl: {out}: {e}");
        std::process::exit(1);
    }
}
