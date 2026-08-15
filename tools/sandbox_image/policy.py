from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any

from .model import Disposition, Finding

DISPOSITION_KEYS = {
    "vulnerability_id",
    "package",
    "result_class",
    "result_type",
    "target",
    "rationale",
    "owner",
    "expires",
}
BLOCKING_SEVERITIES = {"CRITICAL", "HIGH"}
ALLOWED_SEVERITIES = {"UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"}


@dataclass(frozen=True)
class PolicyResult:
    blocking: tuple[Finding, ...]
    disposed: tuple[tuple[Finding, Disposition], ...]
    visible: tuple[Finding, ...]

    @property
    def accepted(self) -> bool:
        return not self.blocking


def _disposition_from_json(value: Any, today: date) -> Disposition:
    if not isinstance(value, dict) or set(value) != DISPOSITION_KEYS:
        raise ValueError("each vulnerability disposition must use the exact schema")
    if not all(isinstance(value[key], str) for key in DISPOSITION_KEYS):
        raise ValueError("vulnerability disposition values must be strings")
    identity_keys = {
        "vulnerability_id",
        "package",
        "result_class",
        "result_type",
        "target",
    }
    if any(not value[key] for key in identity_keys):
        raise ValueError("vulnerability disposition identity is required")
    if value["result_class"] not in {"os-pkgs", "lang-pkgs"}:
        raise ValueError("vulnerability disposition result class is unsupported")
    if not value["rationale"].strip() or not value["owner"].strip():
        raise ValueError("vulnerability disposition rationale and owner are required")
    try:
        expires = date.fromisoformat(value["expires"])
    except ValueError as error:
        raise ValueError(
            "vulnerability disposition expiry must be an ISO date"
        ) from error
    if expires < today:
        raise ValueError("vulnerability disposition is expired")
    return Disposition(
        vulnerability_id=value["vulnerability_id"],
        package=value["package"],
        result_class=value["result_class"],
        result_type=value["result_type"],
        target=value["target"],
        rationale=value["rationale"].strip(),
        owner=value["owner"].strip(),
        expires=expires,
    )


def load_dispositions(path: Path, today: date) -> tuple[Disposition, ...]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot load vulnerability dispositions: {path}") from error
    if not isinstance(payload, list):
        raise ValueError("vulnerability dispositions must be a JSON array")
    dispositions = tuple(_disposition_from_json(value, today) for value in payload)
    identities = [_disposition_identity(disposition) for disposition in dispositions]
    if len(identities) != len(set(identities)):
        raise ValueError("duplicate vulnerability disposition")
    return dispositions


def evaluate_findings(
    findings: tuple[Finding, ...],
    dispositions: tuple[Disposition, ...],
    today: date,
) -> PolicyResult:
    if any(not _valid_identity(disposition) for disposition in dispositions):
        raise ValueError("vulnerability disposition has an invalid identity")
    disposition_by_identity = {
        _disposition_identity(disposition): disposition
        for disposition in dispositions
    }
    if len(disposition_by_identity) != len(dispositions):
        raise ValueError("duplicate vulnerability disposition")
    if any(disposition.expires < today for disposition in dispositions):
        raise ValueError("vulnerability disposition is expired")

    blocking: list[Finding] = []
    disposed: list[tuple[Finding, Disposition]] = []
    visible: list[Finding] = []
    matched: set[tuple[str, str, str, str, str]] = set()
    for item in findings:
        if (
            not _valid_identity(item)
            or not isinstance(item.severity, str)
            or item.severity.upper() not in ALLOWED_SEVERITIES
        ):
            raise ValueError(
                "vulnerability finding has an invalid severity or identity"
            )
        if item.fixed_version is not None and not isinstance(item.fixed_version, str):
            raise ValueError("vulnerability finding has an invalid fixed version")
        identity = _finding_identity(item)
        disposition = disposition_by_identity.get(identity)
        if item.severity.upper() not in BLOCKING_SEVERITIES:
            visible.append(item)
        elif item.fixed_version:
            blocking.append(item)
            if disposition is not None:
                matched.add(identity)
        elif disposition is None:
            blocking.append(item)
        else:
            disposed.append((item, disposition))
            matched.add(identity)

    unmatched = set(disposition_by_identity) - matched
    if unmatched:
        identities = ", ".join("/".join(identity) for identity in sorted(unmatched))
        raise ValueError(
            f"vulnerability disposition does not match a finding: {identities}"
        )
    return PolicyResult(tuple(blocking), tuple(disposed), tuple(visible))


def _disposition_identity(
    disposition: Disposition,
) -> tuple[str, str, str, str, str]:
    return (
        disposition.vulnerability_id,
        disposition.package,
        disposition.result_class,
        disposition.result_type,
        disposition.target,
    )


def _finding_identity(finding: Finding) -> tuple[str, str, str, str, str]:
    return (
        finding.vulnerability_id,
        finding.package,
        finding.result_class,
        finding.result_type,
        finding.target,
    )


def _valid_identity(value: Finding | Disposition) -> bool:
    return (
        isinstance(value.vulnerability_id, str)
        and bool(value.vulnerability_id)
        and isinstance(value.package, str)
        and bool(value.package)
        and isinstance(value.result_class, str)
        and value.result_class in {"os-pkgs", "lang-pkgs"}
        and isinstance(value.result_type, str)
        and bool(value.result_type)
        and isinstance(value.target, str)
        and bool(value.target)
    )
