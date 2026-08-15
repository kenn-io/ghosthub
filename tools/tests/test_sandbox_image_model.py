import json
from dataclasses import replace
from datetime import UTC, date, datetime
from pathlib import Path

import pytest
from sandbox_image.model import CheckResult, ImageReference
from sandbox_image.report import (
    REQUIRED_CHECKS,
    VettingReport,
    validate_report,
    validate_report_freshness,
)

DIGEST = "sha256:" + "b" * 64
CANDIDATE = "candidate-" + "a" * 40
REPOSITORY = "ghcr.io/kenn-io/ghosthub-sandbox"


def valid_report_payload() -> dict[str, object]:
    return {
        "schema_version": 1,
        "repository": REPOSITORY,
        "digest": DIGEST,
        "candidate_tag": CANDIDATE,
        "image_version": "0.1.0",
        "source_commit": "a" * 40,
        "provider_version": "1.2.2",
        "macos_version": "26.0",
        "architecture": "arm64",
        "attestations": [
            "https://slsa.dev/provenance/v0.2",
            "https://spdx.dev/Document/v2.3",
        ],
        "checks": [
            {"name": name, "status": "pass", "detail": "verified"}
            for name in sorted(REQUIRED_CHECKS)
        ],
        "scan_database_timestamp": "2026-08-13T00:00:00Z",
        "findings": [],
        "dispositions": [],
        "status": "pass",
        "completed_at": "2026-08-13T01:00:00Z",
    }


def load_report(tmp_path: Path, payload: dict[str, object]) -> VettingReport:
    path = tmp_path / "report.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return VettingReport.load(path)


@pytest.mark.parametrize(
    "missing_check",
    ["stop-start-git-standard", "stop-start-git-linked"],
)
def test_report_requires_git_commits_after_restart(
    tmp_path: Path, missing_check: str
) -> None:
    payload = valid_report_payload()
    checks = payload["checks"]
    assert isinstance(checks, list)
    payload["checks"] = [
        check
        for check in checks
        if isinstance(check, dict) and check["name"] != missing_check
    ]

    with pytest.raises(ValueError, match="exact required checks"):
        validate_report(
            load_report(tmp_path, payload),
            ImageReference.parse(f"{REPOSITORY}:{CANDIDATE}@{DIGEST}"),
            "0.1.0",
            today=date(2026, 8, 13),
        )


def test_runtime_pin_normalizes_candidate_to_tag_free_digest() -> None:
    ref = ImageReference.parse(f"{REPOSITORY}:{CANDIDATE}@{DIGEST}")
    assert ref.runtime_pin == f"{REPOSITORY}@{DIGEST}"


@pytest.mark.parametrize(
    "value",
    [
        f"{REPOSITORY}:latest",
        f"{REPOSITORY}:v0.1.0",
        "docker.io/kenn-io/ghosthub-sandbox@" + DIGEST,
        f"{REPOSITORY}@sha256:ABC",
    ],
)
def test_runtime_pin_rejects_non_authoritative_references(value: str) -> None:
    with pytest.raises(ValueError):
        ImageReference.parse_runtime_pin(value)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("digest", "sha256:" + "c" * 64),
        ("image_version", "0.2.0"),
        ("provider_version", "1.2.1"),
        ("architecture", "x86_64"),
    ],
)
def test_report_validation_rejects_identity_mismatch(
    tmp_path: Path, field: str, value: str
) -> None:
    payload = valid_report_payload()
    payload[field] = value
    report = load_report(tmp_path, payload)
    with pytest.raises(ValueError):
        validate_report(
            report,
            ImageReference.parse(f"{REPOSITORY}:{CANDIDATE}@{DIGEST}"),
            "0.1.0",
            today=date(2026, 8, 13),
        )


def test_report_validation_rejects_failed_or_missing_checks(tmp_path: Path) -> None:
    for mutation in ("fail", "missing"):
        payload = valid_report_payload()
        checks = payload["checks"]
        assert isinstance(checks, list)
        if mutation == "fail":
            checks[0]["status"] = "fail"
        else:
            checks.pop()
        report = load_report(tmp_path, payload)
        with pytest.raises(ValueError):
            validate_report(
                report,
                ImageReference.parse(f"{REPOSITORY}:{CANDIDATE}@{DIGEST}"),
                "0.1.0",
                today=date(2026, 8, 13),
            )


@pytest.mark.parametrize(
    ("key", "value"),
    [("home", "/Users/alice"), ("environment", {"TOKEN": "secret"})],
)
def test_report_rejects_sensitive_or_unbounded_fields(
    tmp_path: Path, key: str, value: object
) -> None:
    payload = valid_report_payload()
    payload[key] = value
    with pytest.raises(ValueError):
        load_report(tmp_path, payload)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("attestations", []),
        ("attestations", ["provenance", "sbom"]),
        ("source_commit", "not-a-commit"),
        ("source_commit", "c" * 40),
    ],
)
def test_report_rejects_unbound_supply_chain_identity(
    tmp_path: Path, field: str, value: object
) -> None:
    payload = valid_report_payload()
    payload[field] = value
    with pytest.raises(ValueError):
        load_report(tmp_path, payload)


def test_report_rejects_embedded_home_path(tmp_path: Path) -> None:
    payload = valid_report_payload()
    checks = payload["checks"]
    assert isinstance(checks, list)
    checks[0]["detail"] = "failed with HOME=/Users/alice"
    with pytest.raises(ValueError):
        load_report(tmp_path, payload)


def test_report_write_rejects_sensitive_tuple_detail(tmp_path: Path) -> None:
    report = load_report(tmp_path, valid_report_payload())
    checks = list(report.checks)
    checks[0] = CheckResult(checks[0].name, "pass", "path=/Users/alice/repo")
    with pytest.raises(ValueError):
        replace(report, checks=tuple(checks)).write(tmp_path / "written.json")


def test_report_validation_uses_current_disposition_date(tmp_path: Path) -> None:
    payload = valid_report_payload()
    payload["findings"] = [
        {
            "vulnerability_id": "CVE-1",
            "package": "openssl",
            "result_class": "os-pkgs",
            "result_type": "ubuntu",
            "target": "ubuntu",
            "severity": "HIGH",
            "fixed_version": None,
        }
    ]
    payload["dispositions"] = [
        {
            "vulnerability_id": "CVE-1",
            "package": "openssl",
            "result_class": "os-pkgs",
            "result_type": "ubuntu",
            "target": "ubuntu",
            "rationale": "No fix",
            "owner": "security",
            "expires": "2026-08-13",
        }
    ]
    report = load_report(tmp_path, payload)
    with pytest.raises(ValueError, match="expired"):
        validate_report(
            report,
            ImageReference.parse(f"{REPOSITORY}:{CANDIDATE}@{DIGEST}"),
            "0.1.0",
            today=date(2026, 8, 14),
        )


@pytest.mark.parametrize(
    ("completed_at", "scan_database_timestamp", "now"),
    [
        (
            "2026-08-05T23:59:59Z",
            "2026-08-13T00:00:00Z",
            datetime(2026, 8, 13, tzinfo=UTC),
        ),
        (
            "2026-08-13T00:00:00Z",
            "2026-08-05T23:59:59Z",
            datetime(2026, 8, 13, tzinfo=UTC),
        ),
        (
            "2026-08-13T00:00:01Z",
            "2026-08-13T00:00:00Z",
            datetime(2026, 8, 13, tzinfo=UTC),
        ),
    ],
)
def test_report_validation_rejects_stale_or_future_evidence(
    tmp_path: Path,
    completed_at: str,
    scan_database_timestamp: str,
    now: datetime,
) -> None:
    payload = valid_report_payload()
    payload["completed_at"] = completed_at
    payload["scan_database_timestamp"] = scan_database_timestamp
    report = load_report(tmp_path, payload)

    with pytest.raises(ValueError, match="fresh"):
        validate_report_freshness(report, now=now)


def test_report_validation_accepts_old_production_evidence(tmp_path: Path) -> None:
    report = load_report(tmp_path, valid_report_payload())

    validate_report(
        report,
        ImageReference.parse(f"{REPOSITORY}:{CANDIDATE}@{DIGEST}"),
        "0.1.0",
        today=date(2026, 8, 21),
    )
