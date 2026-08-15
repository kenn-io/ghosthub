from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any, Literal

from .model import IMAGE_REPOSITORY, CheckResult, Disposition, Finding, ImageReference
from .policy import evaluate_findings

EXPECTED_ATTESTATIONS = frozenset(
    {
        "https://slsa.dev/provenance/v0.2",
        "https://spdx.dev/Document/v2.3",
    }
)

REQUIRED_CHECKS = frozenset(
    {
        "architecture",
        "provider-version",
        "digest",
        "attestations",
        "ordinary-user",
        "sudo",
        "locale",
        "terminfo",
        "https",
        "ssh-client",
        "git-standard",
        "git-linked",
        "live-apt",
        "stop-start-home",
        "stop-start-git-linked",
        "stop-start-git-standard",
        "stop-start-package",
        "init",
        "explicit-exec-user",
        "mount-protection",
        "stop-start-mount-protection",
        "vulnerability-scan",
        "vulnerability-policy",
        "cleanup",
    }
)
REPORT_KEYS = {
    "schema_version",
    "repository",
    "digest",
    "candidate_tag",
    "image_version",
    "source_commit",
    "provider_version",
    "macos_version",
    "architecture",
    "attestations",
    "checks",
    "scan_database_timestamp",
    "findings",
    "dispositions",
    "status",
    "completed_at",
}


@dataclass(frozen=True)
class VettingReport:
    schema_version: int
    repository: str
    digest: str
    candidate_tag: str
    image_version: str
    source_commit: str
    provider_version: str
    macos_version: str
    architecture: str
    attestations: tuple[str, ...]
    checks: tuple[CheckResult, ...]
    scan_database_timestamp: str
    findings: tuple[Finding, ...]
    dispositions: tuple[Disposition, ...]
    status: Literal["pass", "fail"]
    completed_at: str

    @classmethod
    def load(cls, path: Path) -> VettingReport:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(f"cannot load sandbox image report: {path}") from error
        return cls.from_json(payload)

    @classmethod
    def from_json(cls, payload: Any) -> VettingReport:
        if not isinstance(payload, dict) or set(payload) != REPORT_KEYS:
            raise ValueError("sandbox image report must use the exact schema")
        _reject_sensitive_values(payload)
        try:
            checks = tuple(_check_from_json(value) for value in payload["checks"])
            findings = tuple(_finding_from_json(value) for value in payload["findings"])
            dispositions = tuple(
                _report_disposition_from_json(value)
                for value in payload["dispositions"]
            )
            attestations = tuple(payload["attestations"])
            report = cls(
                schema_version=payload["schema_version"],
                repository=payload["repository"],
                digest=payload["digest"],
                candidate_tag=payload["candidate_tag"],
                image_version=payload["image_version"],
                source_commit=payload["source_commit"],
                provider_version=payload["provider_version"],
                macos_version=payload["macos_version"],
                architecture=payload["architecture"],
                attestations=attestations,
                checks=checks,
                scan_database_timestamp=payload["scan_database_timestamp"],
                findings=findings,
                dispositions=dispositions,
                status=payload["status"],
                completed_at=payload["completed_at"],
            )
        except (KeyError, TypeError) as error:
            raise ValueError("sandbox image report contains invalid values") from error
        _validate_report_shape(report)
        return report

    def write(self, path: Path) -> None:
        _validate_report_shape(self)
        payload = asdict(self)
        for disposition in payload["dispositions"]:
            disposition["expires"] = disposition["expires"].isoformat()
        _reject_sensitive_values(payload)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


def validate_report(
    report: VettingReport,
    expected_image: ImageReference,
    expected_version: str,
    *,
    today: date | None = None,
) -> None:
    _validate_report_shape(report)
    policy_date = today or datetime.now(UTC).date()
    if (
        report.repository != expected_image.repository
        or report.digest != expected_image.digest
    ):
        raise ValueError("vetting report image does not match")
    if report.candidate_tag != expected_image.tag:
        raise ValueError("vetting report candidate tag does not match")
    if report.image_version != expected_version:
        raise ValueError("vetting report image version does not match")
    if report.provider_version != "1.2.2":
        raise ValueError("vetting report provider version is not allowlisted")
    if report.architecture != "arm64":
        raise ValueError("vetting report architecture must be arm64")
    check_by_name = {check.name: check for check in report.checks}
    if set(check_by_name) != REQUIRED_CHECKS:
        raise ValueError("vetting report does not contain the exact required checks")
    if report.status != "pass" or any(
        check.status != "pass" for check in check_by_name.values()
    ):
        raise ValueError("vetting report did not pass")
    evaluated = evaluate_findings(
        report.findings,
        report.dispositions,
        policy_date,
    )
    if not evaluated.accepted:
        raise ValueError("vetting report vulnerability policy did not pass")


def validate_report_freshness(
    report: VettingReport,
    *,
    now: datetime | None = None,
) -> None:
    current = now or datetime.now(UTC)
    if current.tzinfo is None:
        raise ValueError("vetting freshness clock must be timezone-aware")
    current = current.astimezone(UTC)
    for timestamp in (report.completed_at, report.scan_database_timestamp):
        evidence_time = _parse_timestamp(timestamp)
        if evidence_time > current or current - evidence_time > timedelta(days=7):
            raise ValueError("vetting report evidence is not fresh")


def _validate_report_shape(report: VettingReport) -> None:
    if report.schema_version != 1:
        raise ValueError("unsupported sandbox image report schema")
    if report.repository != IMAGE_REPOSITORY:
        raise ValueError("sandbox image report repository does not match")
    ImageReference.parse(f"{report.repository}:{report.candidate_tag}@{report.digest}")
    if report.status not in {"pass", "fail"}:
        raise ValueError("sandbox image report status is invalid")
    if re.fullmatch(r"[0-9a-f]{40}", report.source_commit) is None:
        raise ValueError("sandbox image report source commit is invalid")
    if report.candidate_tag != f"candidate-{report.source_commit}":
        raise ValueError("sandbox image report candidate tag does not match source")
    if report.status == "pass" and (
        len(report.attestations) != len(EXPECTED_ATTESTATIONS)
        or set(report.attestations) != EXPECTED_ATTESTATIONS
        or not all(isinstance(value, str) for value in report.attestations)
    ):
        raise ValueError("sandbox image report attestations are invalid")
    if len({check.name for check in report.checks}) != len(report.checks):
        raise ValueError("sandbox image report has duplicate checks")
    _parse_timestamp(report.completed_at)
    _parse_timestamp(report.scan_database_timestamp)


def _parse_timestamp(value: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValueError("report timestamps must be UTC ISO timestamps")
    try:
        return datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError as error:
        raise ValueError("report timestamp is invalid") from error


def _check_from_json(value: Any) -> CheckResult:
    if not isinstance(value, dict) or set(value) != {"name", "status", "detail"}:
        raise ValueError("report check must use the exact schema")
    if value["status"] not in {"pass", "fail"}:
        raise ValueError("report check status is invalid")
    if not all(isinstance(value[key], str) for key in value):
        raise ValueError("report check values must be strings")
    if len(value["detail"]) > 2_000:
        raise ValueError("report check detail exceeds the size limit")
    return CheckResult(value["name"], value["status"], value["detail"])


def _finding_from_json(value: Any) -> Finding:
    keys = {
        "vulnerability_id",
        "package",
        "result_class",
        "result_type",
        "target",
        "severity",
        "fixed_version",
    }
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError("report finding must use the exact schema")
    return Finding(**value)


def _report_disposition_from_json(value: Any) -> Disposition:
    keys = {
        "vulnerability_id",
        "package",
        "result_class",
        "result_type",
        "target",
        "rationale",
        "owner",
        "expires",
    }
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError("report disposition must use the exact schema")
    try:
        expires = date.fromisoformat(value["expires"])
    except (TypeError, ValueError) as error:
        raise ValueError("report disposition expiry is invalid") from error
    return Disposition(
        vulnerability_id=value["vulnerability_id"],
        package=value["package"],
        result_class=value["result_class"],
        result_type=value["result_type"],
        target=value["target"],
        rationale=value["rationale"],
        owner=value["owner"],
        expires=expires,
    )


def _reject_sensitive_values(value: Any, key: str = "") -> None:
    forbidden_keys = {"environment", "env", "home", "username", "credentials"}
    if key.lower() in forbidden_keys:
        raise ValueError(f"sandbox image report contains forbidden field: {key}")
    if isinstance(value, dict):
        for child_key, child_value in value.items():
            _reject_sensitive_values(child_value, str(child_key))
    elif isinstance(value, (list, tuple)):
        for child in value:
            _reject_sensitive_values(child, key)
    elif isinstance(value, str):
        if "/Users/" in value or "/home/" in value:
            raise ValueError("sandbox image report contains an absolute home path")
        if re.search(
            r"(?:^|\s)(?:HOME|USER|USERNAME|TOKEN|SECRET|PASSWORD|CREDENTIALS?)=",
            value,
        ):
            raise ValueError("sandbox image report contains environment data")
