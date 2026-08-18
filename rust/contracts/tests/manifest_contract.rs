use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

use contracts::{ErrorKind, Manifest, PlatformTag};

static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

struct ContractRoot(PathBuf);

impl ContractRoot {
    fn new(manifest: &str, files: &[(&str, &str)]) -> Self {
        let suffix = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "ghosthub-contract-test-{}-{suffix}",
            std::process::id()
        ));
        fs::create_dir_all(&root).expect("create contract test root");
        fs::write(root.join("manifest.json"), manifest).expect("write manifest");

        for (relative, contents) in files {
            let path = root.join(relative);
            fs::create_dir_all(path.parent().expect("fixture parent"))
                .expect("create fixture parent");
            fs::write(path, contents).expect("write fixture");
        }

        Self(root)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for ContractRoot {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).expect("remove contract test root");
    }
}

fn entry(id: &str, suite: &str, platform: &str, path: &str) -> String {
    format!(
        r#"{{"id":"{id}","suite":"{suite}","schema_version":1,"platforms":["{platform}"],"path":"{path}"}}"#
    )
}

fn manifest(entries: &[String]) -> String {
    format!(
        r#"{{"schema_version":1,"fixtures":[{}]}}"#,
        entries.join(",")
    )
}

#[test]
fn rejects_duplicate_fixture_ids() {
    let root = ContractRoot::new(
        &manifest(&[
            entry("paths.same.v1", "paths", "posix", "one.json"),
            entry("paths.same.v1", "paths", "windows", "two.json"),
        ]),
        &[("one.json", "{}"), ("two.json", "{}")],
    );

    let error = Manifest::load(root.path()).expect_err("duplicate ID must fail");

    assert_eq!(error.kind(), ErrorKind::DuplicateId);
    assert_eq!(error.subject(), "paths.same.v1");
}

#[test]
fn rejects_duplicate_fixture_paths() {
    let root = ContractRoot::new(
        &manifest(&[
            entry("paths.one.v1", "paths", "posix", "same.json"),
            entry("paths.two.v1", "paths", "windows", "same.json"),
        ]),
        &[("same.json", "{}")],
    );

    let error = Manifest::load(root.path()).expect_err("duplicate path must fail");

    assert_eq!(error.kind(), ErrorKind::DuplicatePath);
    assert_eq!(error.subject(), "same.json");
}

#[test]
fn rejects_missing_fixture_files() {
    let root = ContractRoot::new(
        &manifest(&[entry("paths.missing.v1", "paths", "posix", "missing.json")]),
        &[],
    );

    let error = Manifest::load(root.path()).expect_err("missing fixture must fail");

    assert_eq!(error.kind(), ErrorKind::MissingFixture);
    assert_eq!(error.subject(), "paths.missing.v1");
}

#[test]
fn rejects_unknown_manifest_fields() {
    let root = ContractRoot::new(r#"{"schema_version":1,"fixtures":[],"surprise":true}"#, &[]);

    let error = Manifest::load(root.path()).expect_err("unknown field must fail");

    assert_eq!(error.kind(), ErrorKind::InvalidManifest);
    assert_eq!(error.subject(), "manifest.json");
}

#[test]
fn rejects_unsupported_manifest_schema() {
    let root = ContractRoot::new(r#"{"schema_version":2,"fixtures":[]}"#, &[]);

    let error = Manifest::load(root.path()).expect_err("unknown schema must fail");

    assert_eq!(error.kind(), ErrorKind::UnsupportedSchema);
    assert_eq!(error.subject(), "manifest.json");
}

#[test]
fn rejects_unsupported_fixture_schema() {
    let fixture = r#"{"id":"paths.future.v1","suite":"paths","schema_version":2,"platforms":["posix"],"path":"future.json"}"#;
    let root = ContractRoot::new(
        &format!(r#"{{"schema_version":1,"fixtures":[{fixture}]}}"#),
        &[("future.json", "{}")],
    );

    let error = Manifest::load(root.path()).expect_err("unknown schema must fail");

    assert_eq!(error.kind(), ErrorKind::UnsupportedSchema);
    assert_eq!(error.subject(), "paths.future.v1");
}

#[test]
fn rejects_fixtures_without_a_platform() {
    let fixture = r#"{"id":"paths.nowhere.v1","suite":"paths","schema_version":1,"platforms":[],"path":"nowhere.json"}"#;
    let root = ContractRoot::new(
        &format!(r#"{{"schema_version":1,"fixtures":[{fixture}]}}"#),
        &[("nowhere.json", "{}")],
    );

    let error = Manifest::load(root.path()).expect_err("empty platforms must fail");

    assert_eq!(error.kind(), ErrorKind::MissingPlatforms);
    assert_eq!(error.subject(), "paths.nowhere.v1");
}

#[test]
fn rejects_a_suite_without_a_registered_consumer() {
    let root = ContractRoot::new(
        &manifest(&[entry("paths.typo.v1", "pathz", "posix", "typo.json")]),
        &[("typo.json", "{}")],
    );

    let error = Manifest::load(root.path()).expect_err("unknown suite must fail");

    assert_eq!(error.kind(), ErrorKind::UnregisteredConsumer);
    assert_eq!(error.subject(), "paths.typo.v1");
}

#[test]
fn rejects_a_platform_without_a_registered_consumer() {
    let root = ContractRoot::new(
        &manifest(&[entry("mux.posix.v1", "mux-resolver", "posix", "mux.json")]),
        &[("mux.json", "{}")],
    );

    let error = Manifest::load(root.path()).expect_err("unsupported platform must fail");

    assert_eq!(error.kind(), ErrorKind::UnregisteredConsumer);
    assert_eq!(error.subject(), "mux.posix.v1");
}

#[test]
fn rejects_fixture_paths_outside_the_contract_root() {
    let parent = ContractRoot::new(r#"{"schema_version":1,"fixtures":[]}"#, &[]);
    let escaped = parent.path().join("escaped.json");
    fs::write(&escaped, "{}").expect("write escaped fixture");
    let root = ContractRoot::new(
        &manifest(&[entry(
            "paths.escape.v1",
            "paths",
            "posix",
            "../escaped.json",
        )]),
        &[],
    );

    let error = Manifest::load(root.path()).expect_err("parent traversal must fail");

    assert_eq!(error.kind(), ErrorKind::InvalidFixturePath);
    assert_eq!(error.subject(), "paths.escape.v1");
}

#[cfg(unix)]
#[test]
fn rejects_fixture_symlinks_outside_the_contract_root() {
    use std::os::unix::fs::symlink;

    let outside = ContractRoot::new(r#"{"schema_version":1,"fixtures":[]}"#, &[]);
    let escaped = outside.path().join("escaped.json");
    fs::write(&escaped, "{}").expect("write escaped fixture");
    let root = ContractRoot::new(
        &manifest(&[entry(
            "paths.symlink-escape.v1",
            "paths",
            "posix",
            "linked.json",
        )]),
        &[],
    );
    symlink(&escaped, root.path().join("linked.json")).expect("link escaped fixture");

    let error = Manifest::load(root.path()).expect_err("symlink escape must fail");

    assert_eq!(error.kind(), ErrorKind::InvalidFixturePath);
    assert_eq!(error.subject(), "paths.symlink-escape.v1");
}

#[test]
fn rejects_unknown_consumed_ids() {
    let root = ContractRoot::new(r#"{"schema_version":1,"fixtures":[]}"#, &[]);
    let manifest = Manifest::load(root.path()).expect("valid manifest");
    let mut run = manifest.suite("paths", &[PlatformTag::Posix]);

    let error = run
        .consume("paths.unknown.v1")
        .expect_err("unknown ID must fail");

    assert_eq!(error.kind(), ErrorKind::UnknownFixture);
    assert_eq!(error.subject(), "paths.unknown.v1");
}

#[test]
fn reports_unconsumed_applicable_fixtures() {
    let root = ContractRoot::new(
        &manifest(&[entry("paths.posix.v1", "paths", "posix", "posix.json")]),
        &[("posix.json", "{}")],
    );
    let manifest = Manifest::load(root.path()).expect("valid manifest");
    let run = manifest.suite("paths", &[PlatformTag::Posix]);

    let error = run.finish().expect_err("unconsumed fixture must fail");

    assert_eq!(error.kind(), ErrorKind::UnconsumedFixtures);
    assert_eq!(error.subject(), "paths.posix.v1");
}

#[test]
fn ignores_other_suites_and_platforms() {
    let root = ContractRoot::new(
        &manifest(&[
            entry("paths.posix.v1", "paths", "posix", "posix.json"),
            entry("paths.windows.v1", "paths", "windows", "windows.json"),
            entry("host.windows.v1", "wsl-host", "windows", "host.json"),
        ]),
        &[
            ("posix.json", "{}"),
            ("windows.json", "{}"),
            ("host.json", "{}"),
        ],
    );
    let manifest = Manifest::load(root.path()).expect("valid manifest");
    let mut run = manifest.suite("paths", &[PlatformTag::Posix]);

    let path = run
        .consume("paths.posix.v1")
        .expect("consume applicable fixture");

    assert_eq!(
        path,
        fs::canonicalize(root.path().join("posix.json")).expect("canonical fixture path")
    );
    run.finish().expect("all applicable fixtures consumed");
}
