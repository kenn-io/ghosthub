use std::{collections::BTreeMap, fs, path::Path};

use contracts::{Manifest, PlatformTag};
use serde::Deserialize;
use surface::GridSize;
use terminal::{ClipboardPolicy, ClipboardTarget, EngineOutput, TerminalEngine};

const FIXTURE_ID: &str = "clipboard.osc52.policy.v1";
const CONSUMER: &str = "ghosthub-terminal";
const BASE64_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fixture {
    schema_version: u32,
    notes: String,
    max_clipboard_bytes: usize,
    cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Case {
    id: String,
    selection: String,
    #[serde(default)]
    payload: Option<String>,
    #[serde(default)]
    payload_text: Option<RepeatedText>,
    expected: Expected,
    #[serde(default)]
    known_gaps: BTreeMap<String, String>,
    #[serde(default)]
    notes: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RepeatedText {
    text: String,
    repeat: usize,
}

impl RepeatedText {
    fn resolve(&self) -> String {
        self.text.repeat(self.repeat)
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "kebab-case")]
enum Expected {
    Accept {
        #[serde(default)]
        text: Option<String>,
        #[serde(default)]
        text_repeat: Option<RepeatedText>,
    },
    Reject {
        reason: String,
    },
    DenyRead,
}

fn base64_encode(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let group = chunk.iter().enumerate().fold(0_u32, |bits, (index, byte)| {
            bits | u32::from(*byte) << (16 - 8 * index)
        });
        for position in 0..=chunk.len() {
            let symbol = usize::try_from((group >> (18 - 6 * position)) & 0x3f)
                .expect("six bits fit in usize");
            encoded.push(char::from(BASE64_ALPHABET[symbol]));
        }
        for _ in chunk.len()..3 {
            encoded.push('=');
        }
    }
    encoded
}

fn osc52_sequence(case: &Case) -> Vec<u8> {
    let mut sequence = format!("\x1b]52;{}", case.selection).into_bytes();
    let payload = match (&case.payload, &case.payload_text) {
        (Some(payload), None) => Some(payload.clone()),
        (None, Some(repeated)) => Some(base64_encode(repeated.resolve().as_bytes())),
        (None, None) => None,
        (Some(_), Some(_)) => panic!("case {} declares two payload forms", case.id),
    };
    if let Some(payload) = payload {
        sequence.push(b';');
        sequence.extend_from_slice(payload.as_bytes());
    }
    sequence.push(0x07);
    sequence
}

/// Whether a PTY response carries no clipboard contents: the base64 payload
/// field is empty, immediately followed by the BEL or ST terminator.
fn response_has_no_contents(bytes: &[u8]) -> bool {
    let Some(rest) = bytes.strip_prefix(b"\x1b]52;") else {
        return false;
    };
    let Some(separator) = rest.iter().position(|byte| *byte == b';') else {
        return false;
    };
    matches!(rest.get(separator + 1), Some(0x07 | 0x1b))
}

fn satisfies_contract(expected: &Expected, output: &EngineOutput) -> bool {
    match expected {
        Expected::Accept { text, text_repeat } => {
            let expected_text = match (text, text_repeat) {
                (Some(text), None) => text.clone(),
                (None, Some(repeated)) => repeated.resolve(),
                _ => panic!("accept cases declare exactly one expected text form"),
            };
            output.clipboard_reads().is_empty()
                && output.pty_writes().is_empty()
                && matches!(
                    output.clipboard_writes(),
                    [write] if write.target == ClipboardTarget::Clipboard
                        && write.text == expected_text
                )
        }
        Expected::Reject { reason } => {
            assert!(
                matches!(
                    reason.as_str(),
                    "unsupported-selection" | "malformed" | "too-large" | "invalid-utf8"
                ),
                "unknown rejection reason {reason}"
            );
            output.clipboard_writes().is_empty()
                && output.clipboard_reads().is_empty()
                && output.pty_writes().is_empty()
        }
        Expected::DenyRead => {
            output.clipboard_writes().is_empty()
                && output.clipboard_reads().is_empty()
                && output
                    .pty_writes()
                    .iter()
                    .all(|response| response_has_no_contents(response))
        }
    }
}

#[test]
fn parsed_engine_satisfies_the_shared_osc52_contract() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("contracts");
    let manifest = Manifest::load(&root).expect("load contract manifest");
    let mut run = manifest.suite(
        "clipboard-osc52",
        &[PlatformTag::Posix, PlatformTag::Windows],
    );
    let path = run.consume(FIXTURE_ID).expect("consume OSC 52 fixture");
    let fixture: Fixture = serde_json::from_str(&fs::read_to_string(path).expect("read fixture"))
        .expect("parse strict OSC 52 fixture");
    assert_eq!(fixture.schema_version, 1);
    assert!(!fixture.notes.is_empty());
    assert_eq!(fixture.max_clipboard_bytes, 1_048_576);

    for case in fixture.cases {
        let size = GridSize::new(80, 24).expect("valid grid");
        let mut engine = TerminalEngine::with_clipboard_policy(size, ClipboardPolicy::remote(true));
        let output = engine.process(&osc52_sequence(&case));
        let satisfied = satisfies_contract(&case.expected, &output);

        if case.known_gaps.contains_key(CONSUMER) {
            assert!(
                !satisfied,
                "case {} is marked as a known gap for {CONSUMER} but now satisfies the \
                 contract; remove its known_gaps entry from the fixture",
                case.id,
            );
        } else {
            assert!(
                satisfied,
                "case {} violates the shared OSC 52 clipboard contract; expected {:?} ({})",
                case.id,
                case.expected,
                case.notes.as_deref().unwrap_or("no case notes"),
            );
        }
    }

    run.finish().expect("all OSC 52 fixtures consumed");
}
