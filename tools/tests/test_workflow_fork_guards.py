"""Sensitive GitHub Actions jobs must not be runnable in a fork.

Forks inherit scheduled and tag-push workflows but do not have Ghosthub's
signing, notarization, or publishing authority. Validation lanes remain
available so forks can still build and test their own work.
"""

from __future__ import annotations

import pathlib
import re

import pytest
import yaml
from workflow_guards import overrides_implicit_success, requires

CANONICAL_GUARD = "github.repository == 'kenn-io/ghosthub'"
SECRET_CONTEXT = re.compile(r"\bsecrets\b", re.IGNORECASE)
WORKFLOWS = pathlib.Path(__file__).resolve().parents[2] / ".github" / "workflows"


def load(path: pathlib.Path) -> dict:
    workflow = yaml.safe_load(path.read_text())
    # PyYAML reads the bare `on` key as the YAML 1.1 boolean True. Normalize it
    # once so mutated workflow fixtures serialize back to valid Actions YAML.
    if True in workflow and "on" not in workflow:
        workflow["on"] = workflow.pop(True)
    return workflow


def triggers(workflow: dict) -> dict:
    raw = workflow.get("on") or {}
    return raw if isinstance(raw, dict) else dict.fromkeys(raw)


def guarded(job_name: str, jobs: dict, seen: frozenset[str] = frozenset()) -> bool:
    """A job is guarded directly, or by a dependency that must be skipped."""
    if job_name in seen:
        return False
    job = jobs[job_name]
    condition = str(job.get("if", ""))
    if requires(condition, CANONICAL_GUARD):
        return True
    if overrides_implicit_success(condition):
        return False
    needs = job.get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    return bool(needs) and all(
        need in jobs and guarded(need, jobs, seen | {job_name}) for need in needs
    )


def action_expression_bodies(text: str) -> list[str]:
    """Return expression bodies with quoted strings replaced by spaces."""
    expressions = []
    search_from = 0
    while True:
        start = text.find("${{", search_from)
        if start == -1:
            return expressions

        body = []
        index = start + 3
        quoted = False
        while index < len(text):
            char = text[index]
            if char == "'":
                if quoted and text[index : index + 2] == "''":
                    body.extend((" ", " "))
                    index += 2
                    continue
                quoted = not quoted
                body.append(" ")
                index += 1
                continue
            if not quoted and text[index : index + 2] == "}}":
                expressions.append("".join(body))
                search_from = index + 2
                break
            body.append(" " if quoted else char)
            index += 1
        else:
            return expressions


def references_secret_context(value: object) -> bool:
    if isinstance(value, str):
        return any(
            SECRET_CONTEXT.search(expression)
            for expression in action_expression_bodies(value)
        )
    if isinstance(value, dict):
        return any(references_secret_context(item) for item in value.values())
    if isinstance(value, list):
        return any(references_secret_context(item) for item in value)
    return False


def consumes_secrets(workflow: dict, job: dict) -> bool:
    return (
        "secrets" in job
        or references_secret_context(workflow.get("env"))
        or references_secret_context(job)
    )


def grants_write_access(workflow: dict, job: dict) -> bool:
    permissions = job.get("permissions", workflow.get("permissions"))
    if permissions == "write-all":
        return True
    return isinstance(permissions, dict) and "write" in permissions.values()


def workflow_files(root: pathlib.Path) -> list[pathlib.Path]:
    return sorted((*root.glob("*.yml"), *root.glob("*.yaml")))


def fork_runnable_sensitive_jobs(root: pathlib.Path) -> list[str]:
    offenders = []
    for path in workflow_files(root):
        workflow = load(path)
        jobs = workflow.get("jobs") or {}
        scheduled = "schedule" in triggers(workflow)
        for name, job in jobs.items():
            sensitive = (
                scheduled
                or consumes_secrets(workflow, job)
                or grants_write_access(workflow, job)
            )
            if sensitive and not guarded(name, jobs):
                offenders.append(f"{path.name}:{name}")
    return offenders


def test_sensitive_jobs_cannot_run_in_forks() -> None:
    assert fork_runnable_sensitive_jobs(WORKFLOWS) == []


@pytest.mark.parametrize(
    ("workflow_name", "job_name", "mutation", "expected"),
    [
        pytest.param(
            "nightly.yml",
            "eligibility",
            "remove",
            "nightly.yml:eligibility",
            id="scheduled-job-loses-guard",
        ),
        pytest.param(
            "release.yml",
            "macos-release",
            "optional",
            "release.yml:macos-release",
            id="signing-job-makes-guard-optional",
        ),
        pytest.param(
            "release.yml",
            "publish-release",
            "override",
            "release.yml:publish-release",
            id="write-enabled-job-bypasses-skipped-dependency",
        ),
        pytest.param(
            "sandbox-image-maintenance.yml",
            "inspect",
            "negate",
            "sandbox-image-maintenance.yml:inspect",
            id="scheduled-job-negates-guard",
        ),
        pytest.param(
            "nightly.yml",
            "eligibility",
            "unary-not-precedence",
            "nightly.yml:eligibility",
            id="unary-not-binds-before-equality",
        ),
        pytest.param(
            "sandbox-image-publish.yml",
            "prepare",
            "override",
            "sandbox-image-publish.yml:publish",
            id="publishing-job-bypasses-skipped-dependency",
        ),
        pytest.param(
            "sandbox-image-publish.yml",
            "prepare",
            "not-cancelled",
            "sandbox-image-publish.yml:publish",
            id="publishing-job-replaces-implicit-success-check",
        ),
        pytest.param(
            "website.yml",
            "build",
            "workflow-secret-env",
            "website.yml:build",
            id="job-inherits-workflow-secret-context",
        ),
        pytest.param(
            "website.yml",
            "build",
            "whole-secret-context",
            "website.yml:build",
            id="job-uses-whole-secret-context",
        ),
        pytest.param(
            "website.yml",
            "build",
            "formatted-secret-context",
            "website.yml:build",
            id="secret-follows-braces-in-format-string",
        ),
    ],
)
def test_audit_catches_jobs_that_a_fork_could_run(
    tmp_path: pathlib.Path,
    workflow_name: str,
    job_name: str,
    mutation: str,
    expected: str,
) -> None:
    workflow = load(WORKFLOWS / workflow_name)
    job = workflow["jobs"][job_name]
    if mutation == "remove":
        job.pop("if", None)
    elif mutation == "optional":
        job["if"] = f"{job['if']} || github.event_name == 'push'"
    elif mutation == "negate":
        job["if"] = f"!({job['if']})"
    elif mutation == "unary-not-precedence":
        job["if"] = "!(!github.repository == 'kenn-io/ghosthub')"
    elif mutation == "override":
        job["if"] = "always()"
    elif mutation == "not-cancelled":
        job["if"] = "!cancelled()"
    elif mutation == "workflow-secret-env":
        workflow["env"] = {"TEST_TOKEN": "${{ secrets.TEST_TOKEN }}"}
    elif mutation == "whole-secret-context":
        job.setdefault("env", {})["SECRET_CONTEXT"] = "${{ toJSON(Secrets) }}"
    elif mutation == "formatted-secret-context":
        job.setdefault("env", {})["SECRET_CONTEXT"] = (
            "${{ format('{{{0}}}', secrets.TEST_TOKEN) }}"
        )
    else:
        raise AssertionError(f"unknown workflow mutation: {mutation}")

    (tmp_path / workflow_name).write_text(yaml.safe_dump(workflow, sort_keys=False))

    assert fork_runnable_sensitive_jobs(tmp_path) == [expected]


def test_audit_checks_yaml_workflows(tmp_path: pathlib.Path) -> None:
    workflow = load(WORKFLOWS / "sandbox-image-maintenance.yml")
    workflow["jobs"]["inspect"].pop("if")
    (tmp_path / "sandbox-image-maintenance.yaml").write_text(
        yaml.safe_dump(workflow, sort_keys=False)
    )

    assert fork_runnable_sensitive_jobs(tmp_path) == [
        "sandbox-image-maintenance.yaml:inspect"
    ]


@pytest.mark.parametrize(
    ("workflow_name", "job_name"),
    [
        pytest.param("ci-pr.yml", "run", id="pull-request-dispatch"),
        pytest.param("ci.yml", "macos-arm64", id="hosted-macos-validation"),
        pytest.param("sandbox-image.yml", "check", id="sandbox-image-validation"),
    ],
)
def test_validation_entry_jobs_do_not_require_the_canonical_repository(
    workflow_name: str, job_name: str
) -> None:
    workflow = load(WORKFLOWS / workflow_name)

    assert not guarded(job_name, workflow["jobs"])
