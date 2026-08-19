"""Publishing and scheduled workflow jobs must not run outside kenn-io/ghosthub.

Forks inherit `schedule` and tag-push triggers but have none of the signing,
notarization, or registry credentials, so unguarded jobs fail on every run in
every fork. Validation lanes (`pull_request`, branch pushes) stay unguarded so
forks can still build and test their own work.
"""

from __future__ import annotations

import pathlib
import re

import pytest
import yaml
from workflow_guards import requires

CANONICAL_GUARD = "github.repository == 'kenn-io/ghosthub'"
# `secrets.NAME`, `secrets['NAME']`, and reusable-workflow secret forwarding.
SECRET_REFERENCE = re.compile(r"secrets\s*[.\[]")
# Any status check function in an `if` replaces the implicit success
# requirement, so the job can still run once a guarded dependency is skipped
# and cannot inherit that dependency's guard.
STATUS_OVERRIDE = re.compile(r"\b(always|success|failure|cancelled)\s*\(")
WORKFLOWS = pathlib.Path(__file__).resolve().parents[2] / ".github" / "workflows"


def load(path: pathlib.Path) -> dict:
    return yaml.safe_load(path.read_text())


def triggers(workflow: dict) -> dict:
    # PyYAML reads the bare `on` key as the YAML 1.1 boolean True.
    raw = workflow.get("on", workflow.get(True)) or {}
    return raw if isinstance(raw, dict) else dict.fromkeys(raw)


def guarded(job_name: str, jobs: dict, seen: frozenset[str] = frozenset()) -> bool:
    """A job is guarded directly, or because every job it needs is guarded."""
    if job_name in seen:
        return False
    job = jobs[job_name]
    condition = str(job.get("if", ""))
    if requires(condition, CANONICAL_GUARD):
        return True
    if STATUS_OVERRIDE.search(condition):
        return False
    needs = job.get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    return bool(needs) and all(
        guarded(need, jobs, seen | {job_name}) for need in needs if need in jobs
    )


def consumes_secrets(job: dict) -> bool:
    if "secrets" in job:  # reusable workflow call: `inherit` or an explicit map
        return True
    return bool(SECRET_REFERENCE.search(yaml.safe_dump(job)))


def workflow_files() -> list[pathlib.Path]:
    return sorted(WORKFLOWS.glob("*.yml"))


def unguarded_jobs(path: pathlib.Path, *, secrets_only: bool) -> list[str]:
    workflow = load(path)
    jobs = workflow.get("jobs") or {}
    if not secrets_only and "schedule" not in triggers(workflow):
        return []
    offenders = []
    for name, job in jobs.items():
        if secrets_only and not consumes_secrets(job):
            continue
        if not guarded(name, jobs):
            offenders.append(name)
    return offenders


@pytest.mark.parametrize("path", workflow_files(), ids=lambda p: p.name)
def test_scheduled_jobs_are_repository_guarded(path: pathlib.Path) -> None:
    assert unguarded_jobs(path, secrets_only=False) == []


@pytest.mark.parametrize("path", workflow_files(), ids=lambda p: p.name)
def test_secret_consuming_jobs_are_repository_guarded(path: pathlib.Path) -> None:
    assert unguarded_jobs(path, secrets_only=True) == []


@pytest.mark.parametrize(
    ("condition", "expected"),
    [
        (CANONICAL_GUARD, True),
        (f"{CANONICAL_GUARD} && github.ref == 'refs/heads/main'", True),
        (f"always() && {CANONICAL_GUARD}", True),
        (f"(github.event_name == 'push' || inputs.force) && {CANONICAL_GUARD}", True),
        ("'kenn-io/ghosthub' == github.repository", True),
        (f"{CANONICAL_GUARD} || github.event_name == 'push'", False),
        (f"!({CANONICAL_GUARD})", False),
        (
            f"github.ref == 'refs/heads/main' && !({CANONICAL_GUARD} && inputs.force)",
            False,
        ),
        ("github.repository == 'someone/ghosthub'", False),
        ("", False),
        (f"{CANONICAL_GUARD} &&", False),
    ],
)
def test_guard_must_be_mandatory_on_every_path(condition: str, expected: bool) -> None:
    assert requires(condition, CANONICAL_GUARD) is expected


@pytest.mark.parametrize(
    ("condition", "expected"),
    [
        ("", True),
        ("inputs.force", True),
        ("success()", False),
        ("success() || inputs.force", False),
        ("always()", False),
        ("failure()", False),
        ("cancelled()", False),
        (CANONICAL_GUARD, True),
        (f"always() && {CANONICAL_GUARD}", True),
    ],
)
def test_guard_inheritance_requires_the_implicit_success_check(
    condition: str, expected: bool
) -> None:
    jobs = {
        "upstream": {"if": CANONICAL_GUARD},
        "downstream": {"needs": "upstream", "if": condition},
    }
    assert guarded("downstream", jobs) is expected
