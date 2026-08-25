use std::{collections::BTreeMap, fs, path::Path};

use contracts::{Manifest, PlatformTag};
use input::{KeyInput, TerminalModes, encode_input};
use serde::Deserialize;

const FIXTURE_ID: &str = "clipboard.paste.sanitize.v1";
const CONSUMER: &str = "ghosthub-input";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fixture {
    schema_version: u32,
    notes: String,
    cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Case {
    id: String,
    input: String,
    bracketed_paste: bool,
    expected: String,
    #[serde(default)]
    known_gaps: BTreeMap<String, String>,
    #[serde(default)]
    notes: Option<String>,
}

#[test]
fn paste_encoding_satisfies_the_shared_sanitization_contract() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("contracts");
    let manifest = Manifest::load(&root).expect("load contract manifest");
    let mut run = manifest.suite(
        "clipboard-paste",
        &[PlatformTag::Posix, PlatformTag::Windows],
    );
    let path = run.consume(FIXTURE_ID).expect("consume paste fixture");
    let fixture: Fixture = serde_json::from_str(&fs::read_to_string(path).expect("read fixture"))
        .expect("parse strict paste fixture");
    assert_eq!(fixture.schema_version, 1);
    assert!(!fixture.notes.is_empty());

    for case in fixture.cases {
        let modes = TerminalModes {
            bracketed_paste: case.bracketed_paste,
            ..TerminalModes::default()
        };
        // The confirmation gate is a native approval layer on top of the
        // shared contract; the contract governs the bytes that reach the PTY
        // once the paste goes through.
        let actual = encode_input(&KeyInput::paste(case.input.clone()), modes).approve();

        if case.known_gaps.contains_key(CONSUMER) {
            assert_ne!(
                actual,
                case.expected.as_bytes(),
                "case {} is marked as a known gap for {CONSUMER} but now satisfies the \
                 contract; remove its known_gaps entry from the fixture",
                case.id,
            );
        } else {
            assert_eq!(
                actual,
                case.expected.as_bytes(),
                "case {} produced bytes that violate the shared paste contract ({})",
                case.id,
                case.notes.as_deref().unwrap_or("no case notes"),
            );
        }
    }

    run.finish().expect("all paste fixtures consumed");
}
