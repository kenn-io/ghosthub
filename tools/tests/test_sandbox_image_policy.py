import json
from datetime import date
from pathlib import Path

import pytest
from sandbox_image.model import Disposition, Finding
from sandbox_image.policy import evaluate_findings, load_dispositions

TODAY = date(2026, 8, 13)


def disposition(expires: date = date(2026, 9, 1)) -> Disposition:
    return Disposition(
        vulnerability_id="CVE-2026-1",
        package="libexample",
        result_class="os-pkgs",
        result_type="ubuntu",
        target="ubuntu",
        rationale="No upstream fix",
        owner="security",
        expires=expires,
    )


def finding(*, fixed: str | None = None, severity: str = "High") -> Finding:
    return Finding(
        vulnerability_id="CVE-2026-1",
        package="libexample",
        result_class="os-pkgs",
        result_type="ubuntu",
        target="ubuntu",
        severity=severity,
        fixed_version=fixed,
    )


def test_fixable_high_blocks_even_with_disposition() -> None:
    result = evaluate_findings((finding(fixed="2.0"),), (disposition(),), TODAY)
    assert not result.accepted
    assert result.blocking == (finding(fixed="2.0"),)


def test_unfixed_high_requires_current_exact_disposition() -> None:
    accepted = evaluate_findings((finding(),), (disposition(),), TODAY)
    assert accepted.accepted
    assert accepted.disposed == ((finding(), disposition()),)

    rejected = evaluate_findings((finding(),), (), TODAY)
    assert not rejected.accepted
    assert rejected.blocking == (finding(),)


def test_disposition_does_not_authorize_another_trivy_target() -> None:
    vulnerable_binary = Finding(
        vulnerability_id="CVE-2026-1",
        package="stdlib",
        severity="HIGH",
        fixed_version=None,
        result_class="lang-pkgs",
        result_type="gobinary",
        target="usr/bin/active-tool",
    )
    unrelated_disposition = Disposition(
        vulnerability_id="CVE-2026-1",
        package="stdlib",
        rationale="The unused helper is removed",
        owner="security",
        expires=date(2026, 9, 1),
        result_class="lang-pkgs",
        result_type="gobinary",
        target="usr/bin/unused-helper",
    )

    with pytest.raises(ValueError, match="does not match"):
        evaluate_findings((vulnerable_binary,), (unrelated_disposition,), TODAY)


def test_medium_and_low_remain_visible_without_blocking() -> None:
    findings = (finding(severity="Medium"), finding(severity="Low"))
    result = evaluate_findings(findings, (), TODAY)
    assert result.accepted
    assert result.visible == findings


def test_unmatched_disposition_is_rejected() -> None:
    with pytest.raises(ValueError, match="does not match"):
        evaluate_findings((), (disposition(),), TODAY)


@pytest.mark.parametrize("expires", ["not-a-date", "2026-08-12"])
def test_disposition_file_rejects_bad_or_expired_dates(
    tmp_path: Path, expires: str
) -> None:
    path = tmp_path / "dispositions.json"
    path.write_text(
        json.dumps(
            [
                {
                    "vulnerability_id": "CVE-2026-1",
                    "package": "libexample",
                    "result_class": "os-pkgs",
                    "result_type": "ubuntu",
                    "target": "ubuntu",
                    "rationale": "No upstream fix",
                    "owner": "security",
                    "expires": expires,
                }
            ]
        ),
        encoding="utf-8",
    )
    with pytest.raises(ValueError):
        load_dispositions(path, TODAY)


def test_disposition_file_rejects_duplicates_and_unknown_keys(tmp_path: Path) -> None:
    record = {
        "vulnerability_id": "CVE-2026-1",
        "package": "libexample",
        "result_class": "os-pkgs",
        "result_type": "ubuntu",
        "target": "ubuntu",
        "rationale": "No upstream fix",
        "owner": "security",
        "expires": "2026-09-01",
    }
    for records in ([record, record], [{**record, "ticket": "SEC-1"}]):
        path = tmp_path / f"dispositions-{len(records)}.json"
        path.write_text(json.dumps(records), encoding="utf-8")
        with pytest.raises(ValueError):
            load_dispositions(path, TODAY)


def test_unknown_vulnerability_severity_fails_closed() -> None:
    with pytest.raises(ValueError, match="severity"):
        evaluate_findings(
            (
                Finding(
                    "CVE-1",
                    "openssl",
                    "os-pkgs",
                    "ubuntu",
                    "ubuntu",
                    "Hihg",
                    None,
                ),
            ),
            (),
            TODAY,
        )
