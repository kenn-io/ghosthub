use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
};

use architecture::{
    Graph, internal_dependency_path, internal_graph, unexpected_direct_internal_dependencies,
};
use cargo_metadata::MetadataCommand;

fn graph(entries: &[(&str, &[&str])]) -> Graph {
    entries
        .iter()
        .map(|(package, dependencies)| {
            (
                (*package).to_owned(),
                dependencies
                    .iter()
                    .map(|dependency| (*dependency).to_owned())
                    .collect(),
            )
        })
        .collect()
}

fn set(values: &[&str]) -> BTreeSet<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

fn workspace_manifest() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("Cargo.toml")
}

#[test]
fn finds_a_transitive_forbidden_path() {
    let graph = graph(&[
        ("ghosthub-store", &["ghosthub-bridge"]),
        ("ghosthub-bridge", &["ghosthub-session"]),
        ("ghosthub-session", &[]),
    ]);

    assert_eq!(
        internal_dependency_path(&graph, "ghosthub-store", "ghosthub-session"),
        Some(vec![
            "ghosthub-store".to_owned(),
            "ghosthub-bridge".to_owned(),
            "ghosthub-session".to_owned(),
        ]),
    );
}

#[test]
fn handles_cycles_without_losing_the_deterministic_path() {
    let graph = graph(&[
        ("ghosthub-store", &["ghosthub-a"]),
        ("ghosthub-a", &["ghosthub-b"]),
        ("ghosthub-b", &["ghosthub-a", "ghosthub-session"]),
        ("ghosthub-session", &[]),
    ]);

    assert_eq!(
        internal_dependency_path(&graph, "ghosthub-store", "ghosthub-session"),
        Some(vec![
            "ghosthub-store".to_owned(),
            "ghosthub-a".to_owned(),
            "ghosthub-b".to_owned(),
            "ghosthub-session".to_owned(),
        ]),
    );
}

#[test]
fn rejects_an_unapproved_direct_ui_crate() {
    let actual = set(&["ghosthub-model", "ghosthub-config"]);
    let allowed = set(&["ghosthub-model", "ghosthub-workspace", "ghosthub-surface"]);

    assert_eq!(
        unexpected_direct_internal_dependencies(&actual, &allowed),
        vec!["ghosthub-config".to_owned()],
    );
}

#[test]
fn accepts_the_locked_direct_ui_crates() {
    let actual = set(&["ghosthub-model", "ghosthub-workspace", "ghosthub-surface"]);
    let allowed = actual.clone();

    assert!(unexpected_direct_internal_dependencies(&actual, &allowed).is_empty());
}

#[test]
fn actual_workspace_satisfies_dependency_boundaries() {
    let metadata = MetadataCommand::new()
        .manifest_path(workspace_manifest())
        .exec()
        .expect("load workspace cargo metadata");
    let graph = internal_graph(&metadata);

    assert!(
        graph
            .get("ghosthub-config")
            .expect("config package in graph")
            .contains("ghosthub-contracts"),
        "dev dependencies must participate in the graph"
    );

    if graph.contains_key("ghosthub-store") && graph.contains_key("ghosthub-session") {
        assert_eq!(
            internal_dependency_path(&graph, "ghosthub-store", "ghosthub-session",),
            None,
            "store must not reach session through any dependency kind"
        );
    }

    let actual_ui = graph.get("ghosthub-ui").expect("UI package in graph");
    let allowed_ui = set(&["ghosthub-model", "ghosthub-workspace", "ghosthub-surface"]);
    assert!(
        unexpected_direct_internal_dependencies(actual_ui, &allowed_ui).is_empty(),
        "UI has an unapproved direct internal dependency"
    );
}
