//! Builds the public-libproc routing adapter only for macOS targets.
use std::{env, path::PathBuf, process::Command};

/// Compiles the bounded process lookup shim with the target Apple SDK and links system frameworks.
fn main() {
    println!("cargo:rerun-if-changed=process_routing.c");
    let target = env::var("TARGET").unwrap();
    if !target.contains("apple-darwin") { return; }
    let output = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let arch = if target.starts_with("aarch64") { "arm64" } else { "x86_64" };
    let object = output.join("process_routing.o");
    assert!(Command::new("xcrun").args(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-target", &format!("{arch}-apple-macos14.0"), "-c", "process_routing.c", "-o"])
        .arg(&object).status().unwrap().success());
    let archive = output.join("libhy2_process_routing.a");
    assert!(Command::new("xcrun").args(["ar", "crs"]).arg(&archive).arg(&object).status().unwrap().success());
    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-lib=static=hy2_process_routing");
    println!("cargo:rustc-link-lib=framework=SystemConfiguration");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");
}
