//! Content-hash the embedded frontend assets at build time.
//!
//! Each static asset gets a content-derived filename (`app.<hash>.js`), so
//! the server can serve it `immutable` and a stale reference fails as a 404
//! instead of silently loading the wrong bytes. `index.html` is rewritten to
//! point at the hashed names and stays unhashed and `no-store`. The hash is a
//! non-cryptographic content digest — it only needs to change when the bytes
//! change — so no build dependency is pulled into the crate's linked graph.

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;

/// FNV-1a 64-bit, rendered as zero-padded hex. Enough to bust caches on any
/// content change; not a security primitive.
fn content_hash(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &byte in bytes {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

fn main() {
    let manifest = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let out_dir = env::var("OUT_DIR").expect("OUT_DIR");

    // (served file name, source path under the crate, content type). The
    // served name is flat even for vendored sources, matching the routes the
    // page requests.
    let assets = [
        ("app.css", "assets/app.css", "text/css; charset=utf-8"),
        ("app.js", "assets/app.js", "text/javascript; charset=utf-8"),
        (
            "xterm.css",
            "assets/vendor/xterm.css",
            "text/css; charset=utf-8",
        ),
        (
            "xterm.js",
            "assets/vendor/xterm.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "addon-fit.js",
            "assets/vendor/addon-fit.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "addon-unicode11.js",
            "assets/vendor/addon-unicode11.js",
            "text/javascript; charset=utf-8",
        ),
    ];

    println!("cargo:rerun-if-changed=assets/index.html");

    let mut index = fs::read_to_string(Path::new(&manifest).join("assets/index.html"))
        .expect("read index.html");
    let mut entries = String::new();

    for (file, source, content_type) in assets {
        println!("cargo:rerun-if-changed={source}");
        let path = Path::new(&manifest).join(source);
        let bytes = fs::read(&path).unwrap_or_else(|error| panic!("read {source}: {error}"));
        let hash = content_hash(&bytes);
        let (stem, ext) = file.rsplit_once('.').expect("asset name has an extension");
        let hashed = format!("{stem}.{hash}.{ext}");

        // Rewrite the page's reference. The quotes anchor the match so one
        // asset name is never a prefix of another's replacement.
        index = index.replace(
            &format!("\"/assets/{file}\""),
            &format!("\"/assets/{hashed}\""),
        );

        // `include_bytes!` accepts forward slashes on every platform.
        let include_path = path.to_string_lossy().replace('\\', "/");
        writeln!(
            entries,
            "    EmbeddedAsset {{ file: \"{hashed}\", content_type: \"{content_type}\", \
             body: include_bytes!(\"{include_path}\") }},"
        )
        .expect("write asset table entry");
    }

    let index_out = Path::new(&out_dir).join("index.html");
    fs::write(&index_out, index).expect("write rewritten index.html");
    let index_include = index_out.to_string_lossy().replace('\\', "/");

    let generated = format!(
        "pub(crate) struct EmbeddedAsset {{\n\
         \x20   pub(crate) file: &'static str,\n\
         \x20   pub(crate) content_type: &'static str,\n\
         \x20   pub(crate) body: &'static [u8],\n\
         }}\n\
         \n\
         pub(crate) static EMBEDDED_ASSETS: &[EmbeddedAsset] = &[\n\
         {entries}\
         ];\n\
         \n\
         pub(crate) const INDEX_PAGE: &str = include_str!(\"{index_include}\");\n"
    );
    fs::write(Path::new(&out_dir).join("assets.rs"), generated).expect("write assets.rs");
}
