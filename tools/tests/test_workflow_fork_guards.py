"""Publishing and scheduled workflow jobs must not run outside kenn-io/ghosthub.

Forks inherit `schedule` and tag-push triggers but have none of the signing,
notarization, or registry credentials, so unguarded jobs fail on every run in
every fork. Validation lanes (`pull_request`, branch pushes) stay unguarded so
forks can still build and test their own work.
"""

from __future__ import annotations

import pathlib

import pytest
import yaml

CANONICAL_GUARD = "github.repository == 'kenn-io/ghosthub'"
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
    if CANONICAL_GUARD in str(job.get("if", "")):
        return True
    needs = job.get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    return bool(needs) and all(
        guarded(need, jobs, seen | {job_name}) for need in needs if need in jobs
    )


def workflow_files() -> list[pathlib.Path]:
    return sorted(WORKFLOWS.glob("*.yml"))


def unguarded_jobs(path: pathlib.Path, *, secrets_only: bool) -> list[str]:
    workflow = load(path)
    jobs = workflow.get("jobs") or {}
    if not secrets_only and "schedule" not in triggers(workflow):
        return []
    offenders = []
    for name, job in jobs.items():
        if secrets_only and "secrets." not in yaml.safe_dump(job):
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
