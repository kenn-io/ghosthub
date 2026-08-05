use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

use config::{Platform, ResolveErrorKind, ResolveInput, resolve_roots};
use contracts::{Manifest, PlatformTag};
use serde::Deserialize;

const POSIX_FIXTURE_ID: &str = "paths.posix.roots.v1";
const WINDOWS_FIXTURE_ID: &str = "paths.windows.roots.v1";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PathFixture {
    schema_version: u32,
    platform: Platform,
    cases: Vec<PathCase>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PathCase {
    id: String,
    user_home: String,
    environment: BTreeMap<String, String>,
    expected: Option<ExpectedRoots>,
    expected_error: Option<ExpectedError>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ExpectedRoots {
    ghosthub_home: String,
    config: String,
    state: String,
    helpers: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ExpectedError {
    input: String,
    kind: ResolveErrorKind,
}

fn contract_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("contracts")
}

fn load_fixture(path: &Path) -> PathFixture {
    let contents = fs::read_to_string(path).expect("read path fixture");
    serde_json::from_str(&contents).expect("parse strict path fixture")
}

fn assert_case(platform: Platform, case: PathCase) {
    let input = ResolveInput {
        platform,
        user_home: case.user_home,
        environment: case.environment,
    };
    let actual = resolve_roots(&input);

    match (case.expected, case.expected_error) {
        (Some(expected), None) => {
            let actual = actual
                .unwrap_or_else(|error| panic!("case {} unexpectedly failed: {error}", case.id));
            assert_eq!(actual.ghosthub_home, expected.ghosthub_home, "{}", case.id);
            assert_eq!(actual.config, expected.config, "{}", case.id);
            assert_eq!(actual.state, expected.state, "{}", case.id);
            assert_eq!(actual.helpers, expected.helpers, "{}", case.id);
        }
        (None, Some(expected)) => {
            let actual = actual.expect_err(&case.id);
            assert_eq!(actual.input(), expected.input, "{}", case.id);
            assert_eq!(actual.kind(), expected.kind, "{}", case.id);
        }
        _ => panic!("case {} must define exactly one expected outcome", case.id),
    }
}

#[test]
fn resolves_every_declared_path_contract() {
    let root = contract_root();
    let manifest = Manifest::load(&root).expect("load repository contract manifest");
    let mut run = manifest.suite("paths", &[PlatformTag::Posix, PlatformTag::Windows]);

    for id in [POSIX_FIXTURE_ID, WINDOWS_FIXTURE_ID] {
        let fixture = load_fixture(&run.consume(id).expect("consume declared fixture"));
        assert_eq!(fixture.schema_version, 1, "{id}");
        for case in fixture.cases {
            assert_case(fixture.platform, case);
        }
    }

    run.finish().expect("all path fixtures consumed");
}
