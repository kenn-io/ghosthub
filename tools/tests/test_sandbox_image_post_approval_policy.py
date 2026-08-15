import json
import subprocess
from pathlib import Path

import pytest

POLICY = Path(__file__).parents[1] / "sandbox_image/post_approval_policy.jq"
TODAY = "2026-08-15"


def evaluate(
    tmp_path: Path,
    scan: object,
    dispositions: object,
) -> subprocess.CompletedProcess[str]:
    scan_path = tmp_path / "scan.json"
    dispositions_path = tmp_path / "dispositions.json"
    scan_path.write_text(json.dumps(scan), encoding="utf-8")
    dispositions_path.write_text(json.dumps(dispositions), encoding="utf-8")
    return subprocess.run(
        (
            "jq",
            "-en",
            "--arg",
            "today",
            TODAY,
            "--slurpfile",
            "scan",
            str(scan_path),
            "--slurpfile",
            "disposition_documents",
            str(dispositions_path),
            "-f",
            str(POLICY),
        ),
        capture_output=True,
        text=True,
        check=False,
    )


def trivy_report(
    *,
    severity: str = "HIGH",
    fixed_version: str | None = None,
) -> dict[str, object]:
    vulnerability: dict[str, object] = {
        "VulnerabilityID": "CVE-2026-1",
        "PkgName": "libexample",
        "Severity": severity,
    }
    if fixed_version is not None:
        vulnerability["FixedVersion"] = fixed_version
    return {
        "Results": [
            {
                "Class": "os-pkgs",
                "Type": "ubuntu",
                "Target": "ubuntu:26.04",
                "Vulnerabilities": [vulnerability],
            }
        ]
    }


def disposition(*, expires: str = "2026-09-01") -> dict[str, str]:
    return {
        "vulnerability_id": "CVE-2026-1",
        "package": "libexample",
        "result_class": "os-pkgs",
        "result_type": "ubuntu",
        "target": "rootfs",
        "rationale": "No upstream fix is available",
        "owner": "security",
        "expires": expires,
    }


def test_current_disposition_accepts_an_unfixed_high(
    tmp_path: Path,
) -> None:
    result = evaluate(tmp_path, trivy_report(), [disposition()])

    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("severity", ["HIGH", "CRITICAL"])
def test_fixable_severe_finding_is_rejected_even_when_disposed(
    tmp_path: Path,
    severity: str,
) -> None:
    result = evaluate(
        tmp_path,
        trivy_report(severity=severity, fixed_version="2.0"),
        [disposition()],
    )

    assert result.returncode != 0


def test_expired_disposition_is_rejected(tmp_path: Path) -> None:
    result = evaluate(
        tmp_path,
        trivy_report(),
        [disposition(expires="2026-08-14")],
    )

    assert result.returncode != 0


def test_disposition_without_a_matching_finding_is_rejected(
    tmp_path: Path,
) -> None:
    result = evaluate(
        tmp_path,
        {
            "Results": [
                {
                    "Class": "os-pkgs",
                    "Type": "ubuntu",
                    "Target": "ubuntu:26.04",
                    "Vulnerabilities": [],
                }
            ]
        },
        [disposition()],
    )

    assert result.returncode != 0


def test_malformed_trivy_report_is_rejected(tmp_path: Path) -> None:
    result = evaluate(tmp_path, {"Results": []}, [])

    assert result.returncode != 0
