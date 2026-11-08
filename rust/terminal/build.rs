use std::{env, path::PathBuf};

fn main() {
    let target = env::var("TARGET").expect("Cargo target");
    let root =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("crate directory")).join("../..");
    let prefix = root.join(".build/libghostty-vt").join(&target);
    let pin: serde_json::Value =
        serde_json::from_str(include_str!("../../Vendor/libghostty-vt.version.json"))
            .expect("libghostty-vt pin");
    let stamp = std::fs::read_to_string(prefix.join("ghosthub-build.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok());
    assert!(
        stamp.as_ref().is_some_and(|stamp| stamp["target"] == target
            && pin
                .as_object()
                .expect("pin object")
                .iter()
                .all(|(key, value)| stamp.get(key) == Some(value))),
        "From the repository root, run: make bootstrap-libghostty-vt RUST_TARGET={target}"
    );
    println!("cargo:rerun-if-changed=src/vt.c");
    println!(
        "cargo:rerun-if-changed={}",
        root.join("Vendor/libghostty-vt.version.json").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        prefix.join("ghosthub-build.json").display()
    );
    cc::Build::new()
        .file("src/vt.c")
        .std("c11")
        .include(prefix.join("include"))
        .warnings_into_errors(true)
        .compile("terminal-vt");
    println!(
        "cargo:rustc-link-search=native={}",
        prefix.join("lib").display()
    );
    if target.contains("windows") {
        println!("cargo:rustc-link-lib=dylib=ghostty-vt");
        // Test executables live in deps; the app lives one directory above.
        let out = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo output"));
        let profile = out.ancestors().nth(3).expect("Cargo profile directory");
        for directory in [
            profile.to_path_buf(),
            profile.join("deps"),
            profile.join("examples"),
        ] {
            std::fs::create_dir_all(&directory).expect("create DLL directory");
            std::fs::copy(
                prefix.join("bin/ghostty-vt.dll"),
                directory.join("ghostty-vt.dll"),
            )
            .expect("stage libghostty-vt beside Windows executable");
        }
    } else {
        println!("cargo:rustc-link-lib=static=ghostty-vt");
    }
}
