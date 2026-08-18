use std::{fs, path::Path};

use contracts::{Manifest, PlatformTag};
use serde::Deserialize;
use session::{ExecutablePlatform, ProbeObservation, resolve_tmux_binary};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fixture {
    schema_version: u32,
    required_capabilities: Vec<String>,
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

    for missing in &fixture.required_capabilities {
        let observations = fixture
            .required_capabilities
            .iter()
            .filter(|capability| *capability != missing)
            .map(|capability| ProbeObservation {
                name: capability.clone(),
                exit_code: 0,
                stdout: "supported".to_owned(),
                stderr: String::new(),
            })
            .collect::<Vec<_>>();
        let actual = resolve_tmux_binary(
            ExecutablePlatform::Windows,
            r"C:\Tools\psmux.exe",
            "tmux 3.3.7\npsmux 3.3.7 (05cc5d4 2026-07-20)",
            &observations,
        )
        .expect_err(missing);
        assert_eq!(actual.kind(), session::ResolveErrorKind::MissingCapability);
        assert_eq!(actual.subject(), missing);
    }

    run.finish().expect("consume all mux resolver fixtures");
}
