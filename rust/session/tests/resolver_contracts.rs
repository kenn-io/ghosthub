use std::{fs, path::Path};

use contracts::{Manifest, PlatformTag};
use serde::Deserialize;
use session::{ExecutablePlatform, ProbeObservation, resolve_tmux_binary};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fixture {
    schema_version: u32,
    cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Case {
    id: String,
    platform: ExecutablePlatform,
    path: String,
    version_output: String,
    observations: Vec<ProbeObservation>,
    expected: Option<Expected>,
    expected_error: Option<ExpectedError>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Expected {
    version: String,
    implementation_revision: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ExpectedError {
    kind: session::ResolveErrorKind,
    subject: String,
}

#[test]
fn resolves_every_psmux_contract() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("contracts");
    let manifest = Manifest::load(&root).expect("load contract manifest");
    let mut run = manifest.suite("mux-resolver", &[PlatformTag::Windows]);
    let path = run
        .consume("mux.psmux.resolver.v1")
        .expect("consume fixture");
    let fixture: Fixture = serde_json::from_str(&fs::read_to_string(path).expect("read fixture"))
        .expect("parse fixture");
    assert_eq!(fixture.schema_version, 1);

    for case in fixture.cases {
        let actual = resolve_tmux_binary(
            case.platform,
            &case.path,
            &case.version_output,
            &case.observations,
        );
        match (case.expected, case.expected_error) {
            (Some(expected), None) => {
                let actual = actual.unwrap_or_else(|error| panic!("{}: {error}", case.id));
                assert_eq!(
                    actual.version().to_string(),
                    expected.version,
                    "{}",
                    case.id
                );
                assert_eq!(
                    actual.implementation_revision(),
                    Some(expected.implementation_revision.as_str()),
                    "{}",
                    case.id
                );
                assert!(actual.capabilities().all_required(), "{}", case.id);
            }
            (None, Some(expected)) => {
                let actual = actual.expect_err(&case.id);
                assert_eq!(actual.kind(), expected.kind, "{}", case.id);
                assert_eq!(actual.subject(), expected.subject, "{}", case.id);
            }
            _ => panic!("{} must define exactly one outcome", case.id),
        }
    }
    run.finish().expect("consume all mux resolver fixtures");
}
