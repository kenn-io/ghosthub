//! Enforce structural dependency constraints in the Rust workspace.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use cargo_metadata::Metadata;

pub type Graph = BTreeMap<String, BTreeSet<String>>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DependencyViolation {
    UnrecognizedPackage(String),
    UnexpectedDependency { package: String, dependency: String },
}

#[must_use]
pub fn locked_dependency_policy() -> Graph {
    [
        (
            "ghosthub-app",
            &[
                "ghosthub-config",
                "ghosthub-host",
                "ghosthub-model",
                "ghosthub-session",
                "ghosthub-store",
                "ghosthub-surface",
                "ghosthub-terminal",
                "ghosthub-ui",
                "ghosthub-workspace",
            ][..],
        ),
        ("ghosthub-architecture", &[][..]),
        (
            "ghosthub-config",
            &["ghosthub-contracts", "ghosthub-model"][..],
        ),
        ("ghosthub-contracts", &[][..]),
        (
            "ghosthub-host",
            &["ghosthub-config", "ghosthub-model", "ghosthub-session"][..],
        ),
        ("ghosthub-model", &[][..]),
        ("ghosthub-session", &["ghosthub-model"][..]),
        ("ghosthub-store", &["ghosthub-model"][..]),
        ("ghosthub-surface", &[][..]),
        (
            "ghosthub-terminal",
            &[
                "ghosthub-config",
                "ghosthub-model",
                "ghosthub-session",
                "ghosthub-surface",
            ][..],
        ),
        (
            "ghosthub-ui",
            &["ghosthub-model", "ghosthub-surface", "ghosthub-workspace"][..],
        ),
        (
            "ghosthub-workspace",
            &[
                "ghosthub-config",
                "ghosthub-host",
                "ghosthub-model",
                "ghosthub-session",
                "ghosthub-store",
                "ghosthub-surface",
                "ghosthub-terminal",
            ][..],
        ),
    ]
    .into_iter()
    .map(|(package, dependencies)| {
        (
            package.to_owned(),
            dependencies
                .iter()
                .map(|dependency| (*dependency).to_owned())
                .collect(),
        )
    })
    .collect()
}

#[must_use]
pub fn dependency_policy_violations(actual: &Graph, policy: &Graph) -> Vec<DependencyViolation> {
    let mut violations = Vec::new();

    for (package, dependencies) in actual {
        let Some(allowed) = policy.get(package) else {
            violations.push(DependencyViolation::UnrecognizedPackage(package.clone()));
            continue;
        };

        violations.extend(dependencies.difference(allowed).map(|dependency| {
            DependencyViolation::UnexpectedDependency {
                package: package.clone(),
                dependency: dependency.clone(),
            }
        }));
    }

    violations
}

#[must_use]
pub fn internal_graph(metadata: &Metadata) -> Graph {
    metadata
        .packages
        .iter()
        .filter(|package| package.name.as_str().starts_with("ghosthub-"))
        .map(|package| {
            let dependencies = package
                .dependencies
                .iter()
                .filter(|dependency| dependency.name.as_str().starts_with("ghosthub-"))
                .map(|dependency| dependency.name.clone())
                .collect();
            (package.name.to_string(), dependencies)
        })
        .collect()
}

#[must_use]
pub fn internal_dependency_path(graph: &Graph, from: &str, to: &str) -> Option<Vec<String>> {
    if !graph.contains_key(from) {
        return None;
    }

    let mut visited = BTreeSet::from([from.to_owned()]);
    let mut paths = VecDeque::from([vec![from.to_owned()]]);

    while let Some(path) = paths.pop_front() {
        let Some(package) = path.last() else {
            continue;
        };
        if package == to {
            return Some(path);
        }

        if let Some(dependencies) = graph.get(package) {
            for dependency in dependencies {
                if visited.insert(dependency.clone()) {
                    let mut next = path.clone();
                    next.push(dependency.clone());
                    paths.push_back(next);
                }
            }
        }
    }

    None
}

#[must_use]
pub fn unexpected_direct_internal_dependencies(
    actual: &BTreeSet<String>,
    allowed: &BTreeSet<String>,
) -> Vec<String> {
    actual.difference(allowed).cloned().collect()
}
