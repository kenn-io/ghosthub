use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

fn validate_linux_helper(bytes: &[u8], architecture: &str, revision: &str) -> Result<(), String> {
    if bytes.len() < 20 || bytes[..4] != *b"\x7fELF" || bytes[4] != 2 || bytes[5] != 1 {
        return Err("staged KWT helper is not a 64-bit little-endian ELF".to_owned());
    }
    let expected_machine = match architecture {
        "amd64" => 62_u16,
        "arm64" => 183_u16,
        _ => {
            return Err(format!(
                "unsupported KWT helper architecture: {architecture}"
            ));
        }
    };
    let actual_machine = u16::from_le_bytes([bytes[18], bytes[19]]);
    if actual_machine != expected_machine {
        return Err(format!(
            "staged KWT helper does not match linux-{architecture}"
        ));
    }
    if !bytes
        .windows(revision.len())
        .any(|window| window == revision.as_bytes())
    {
        return Err(format!(
            "staged KWT helper does not contain pinned revision {revision}"
        ));
    }
    Ok(())
}

fn main() {
    println!("cargo:rerun-if-env-changed=GHOSTHUB_KWT_BUNDLE");
    println!("cargo:rerun-if-env-changed=GHOSTHUB_REQUIRE_KWT_BUNDLE");

    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("manifest directory"));
    let repo = manifest
        .parent()
        .and_then(Path::parent)
        .expect("app crate is nested under rust/");
    let revision_path = repo.join("KWT_REVISION");
    println!("cargo:rerun-if-changed={}", revision_path.display());
    let revision = fs::read_to_string(&revision_path)
        .expect("read KWT_REVISION")
        .trim()
        .to_owned();
    assert!(
        revision.len() == 40
            && revision
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()),
        "KWT_REVISION must contain one 40-character Git revision"
    );

    let target_os = env::var("CARGO_CFG_TARGET_OS").expect("target OS");
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").expect("target architecture");
    let architecture = match target_arch.as_str() {
        "aarch64" => Some("arm64"),
        "x86_64" => Some("amd64"),
        _ => None,
    };
    let configured = env::var_os("GHOSTHUB_KWT_BUNDLE").map(PathBuf::from);
    let candidate = configured.or_else(|| {
        (target_os == "windows").then(|| {
            repo.join(".build")
                .join("kwt")
                .join("variants")
                .join(format!("linux-{}", architecture.unwrap_or("unsupported")))
                .join("kwt")
        })
    });
    if let Some(path) = &candidate {
        println!("cargo:rerun-if-changed={}", path.display());
    }

    let out = PathBuf::from(env::var_os("OUT_DIR").expect("build output directory"));
    let bundled = out.join("kwt");
    let (available, digest) = candidate
        .as_ref()
        .filter(|path| path.is_file() && architecture.is_some())
        .map_or_else(
            || {
                fs::write(&bundled, []).expect("write empty KWT bundle marker");
                (false, String::new())
            },
            |path| {
                let bytes = fs::read(path).expect("read staged KWT helper");
                validate_linux_helper(
                    &bytes,
                    architecture.expect("candidate architecture was filtered"),
                    &revision,
                )
                .unwrap_or_else(|error| panic!("reject staged KWT helper: {error}"));
                fs::write(&bundled, &bytes).expect("stage KWT helper in Cargo output");
                let digest = hex::encode(Sha256::digest(&bytes));
                (true, digest)
            },
        );

    let release_windows =
        target_os == "windows" && env::var("PROFILE").is_ok_and(|profile| profile == "release");
    assert!(
        available || !(release_windows || env::var_os("GHOSTHUB_REQUIRE_KWT_BUNDLE").is_some()),
        "a pinned KWT helper is required; run tools/build_rust_kwt.ps1 or set GHOSTHUB_KWT_BUNDLE"
    );
    if !available && target_os == "windows" {
        println!("cargo:warning=pinned KWT helper is not staged; run tools/build_rust_kwt.ps1");
    }
    println!("cargo:rustc-env=GHOSTHUB_KWT_AVAILABLE={available}");
    println!("cargo:rustc-env=GHOSTHUB_KWT_REVISION={revision}");
    println!("cargo:rustc-env=GHOSTHUB_KWT_SHA256={digest}");
}
