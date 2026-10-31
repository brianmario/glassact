// With the `oracle` feature, compiles the C++ original and the test shims (oracle/*.cpp) into a
// static library the differential tests link. Without it, nothing to do.
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var_os("CARGO_FEATURE_ORACLE").is_none() {
        return;
    }
    let crate_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let root = crate_dir.join("../..");
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let src_dirs = ["Sources/AV1Core/src", "Sources/AV1Encoder/src", "Sources/AV1CoreTestSupport"];
    let includes = [
        root.join("Sources/AV1Core/include"),
        root.join("Sources/AV1Encoder/include"),
        root.join("Sources/AV1CoreTestSupport/include"),
        root.join("Sources/AV1CoreTestSupport"),
    ];
    let mut sources: Vec<PathBuf> = Vec::new();
    for d in src_dirs.iter().map(|d| root.join(d)).chain([crate_dir.join("oracle")]) {
        println!("cargo:rerun-if-changed={}", d.display());
        for e in std::fs::read_dir(&d).unwrap() {
            let p = e.unwrap().path();
            if p.extension().is_some_and(|x| x == "cpp") {
                sources.push(p);
            }
        }
    }
    for i in &includes {
        println!("cargo:rerun-if-changed={}", i.display());
    }
    let objects: Vec<PathBuf> = std::thread::scope(|s| {
        let jobs: Vec<_> = sources
            .iter()
            .enumerate()
            .map(|(n, src)| {
                let obj = out.join(format!("{n}_{}.o", src.file_stem().unwrap().to_string_lossy()));
                let includes = &includes;
                s.spawn(move || {
                    compile(src, &obj, includes);
                    obj
                })
            })
            .collect();
        jobs.into_iter().map(|j| j.join().unwrap()).collect()
    });
    let lib = out.join("liboracle.a");
    let _ = std::fs::remove_file(&lib);
    let status = Command::new("xcrun").arg("ar").arg("crs").arg(&lib).args(&objects).status().unwrap();
    assert!(status.success(), "ar failed");
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=oracle");
    println!("cargo:rustc-link-lib=dylib=c++");
}

fn compile(src: &Path, obj: &Path, includes: &[PathBuf]) {
    let mut cmd = Command::new("xcrun");
    cmd.args(["clang++", "-std=c++17", "-O2", "-w", "-c"]);
    for i in includes {
        cmd.arg(format!("-I{}", i.display()));
    }
    let status = cmd.arg(src).arg("-o").arg(obj).status().unwrap();
    assert!(status.success(), "compiling {} failed", src.display());
}
