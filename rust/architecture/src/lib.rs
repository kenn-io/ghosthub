//! Enforce structural dependency constraints in the Rust workspace.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use cargo_metadata::Metadata;

pub type Graph = BTreeMap<String, BTreeSet<String>>;

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
