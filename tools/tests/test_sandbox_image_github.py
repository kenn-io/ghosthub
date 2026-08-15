from collections.abc import Sequence
from datetime import UTC, date, datetime
from pathlib import Path
from types import SimpleNamespace

import pytest
import sandbox_image.github as github
from sandbox_image.docker import BuiltImage, ImageInputs
from sandbox_image.model import Disposition, ImageReference
from sandbox_image.process import CompletedCommand
from sandbox_image.report import EXPECTED_ATTESTATIONS, VettingReport
from sandbox_image.trivy import ScanArtifacts

DIGEST = "sha256:" + "a" * 64
SOURCE = "b" * 40


def test_promotion_deadline_covers_entire_authorization_window() -> None:
    now = datetime(2026, 8, 13, 2, tzinfo=UTC)
    report = VettingReport(
        schema_version=1,
        repository="ghcr.io/kenn-io/ghosthub-sandbox",
        digest=DIGEST,
        candidate_tag=f"candidate-{SOURCE}",
        image_version="0.1.0",
        source_commit=SOURCE,
        provider_version="1.2.2",
        macos_version="26.0",
        architecture="arm64",
        attestations=tuple(EXPECTED_ATTESTATIONS),
        checks=(),
        scan_database_timestamp="2026-08-13T00:00:00Z",
        findings=(),
        dispositions=(),
        status="pass",
        completed_at="2026-08-13T01:00:00Z",
    )

    assert github.promotion_deadline(report, now=now) == datetime(
        2026, 8, 14, 1, tzinfo=UTC
    )


@pytest.mark.parametrize(
    ("now", "completed_at", "scan_timestamp", "dispositions"),
    [
        (
            datetime(2026, 8, 19, 1, 30, tzinfo=UTC),
            "2026-08-13T01:00:00Z",
            "2026-08-13T01:00:00Z",
            (),
        ),
        (
            datetime(2026, 8, 19, 23, 30, tzinfo=UTC),
            "2026-08-13T01:00:00Z",
            "2026-08-13T00:00:00Z",
            (),
        ),
        (
            datetime(2026, 8, 13, 23, 30, tzinfo=UTC),
            "2026-08-13T23:00:00Z",
            "2026-08-13T23:00:00Z",
            (
                Disposition(
                    vulnerability_id="CVE-1",
                    package="openssl",
                    result_class="os-pkgs",
                    result_type="ubuntu",
                    target="rootfs",
                    rationale="No fix is available",
                    owner="security",
                    expires=date(2026, 8, 13),
                ),
            ),
        ),
    ],
)
def test_promotion_deadline_rejects_evidence_expiring_during_authorization(
    now: datetime,
    completed_at: str,
    scan_timestamp: str,
    dispositions: tuple[Disposition, ...],
) -> None:
    report = VettingReport(
        schema_version=1,
        repository="ghcr.io/kenn-io/ghosthub-sandbox",
        digest=DIGEST,
        candidate_tag=f"candidate-{SOURCE}",
        image_version="0.1.0",
        source_commit=SOURCE,
        provider_version="1.2.2",
        macos_version="26.0",
        architecture="arm64",
        attestations=tuple(EXPECTED_ATTESTATIONS),
        checks=(),
        scan_database_timestamp=scan_timestamp,
        findings=(),
        dispositions=dispositions,
        status="pass",
        completed_at=completed_at,
    )

    with pytest.raises(ValueError, match="full authorization window"):
        github.promotion_deadline(report, now=now)


class RecordingRunner:
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []

    def run(
        self,
        argv: Sequence[str],
        *,
        check: bool = True,
        capture: bool = True,
    ) -> CompletedCommand:
        del check, capture
        call = tuple(argv)
        self.calls.append(call)
        return CompletedCommand(call, 0, "", "")


def test_candidate_preparation_builds_scans_and_writes_attestation_artifacts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    image_dir = tmp_path / "images/sandbox"
    image_dir.mkdir(parents=True)
    (image_dir / "vulnerability-dispositions.json").write_text("[]\n")
    inputs = ImageInputs(DIGEST, "20260812T000000Z", SOURCE, "0.1.0")
    local = BuiltImage(
        "linux/arm64",
        tmp_path / ".dist/sandbox-image/local.docker.tar",
        f"ghcr.io/kenn-io/ghosthub-sandbox:candidate-{SOURCE}",
    )
    contracts: list[BuiltImage] = []
    scanned: list[Path] = []

    monkeypatch.setattr(github, "build_local_image", lambda *_args, **_kwargs: local)
    monkeypatch.setattr(github, "image_content_digest", lambda *_: DIGEST)
    monkeypatch.setattr(github, "image_inputs_digest", lambda *_: DIGEST)
    monkeypatch.setattr(
        github, "verify_image_contract", lambda image, _runner: contracts.append(image)
    )
    def fake_scan(_root: Path, archive: Path, _runner: object) -> ScanArtifacts:
        scanned.append(archive)
        return ScanArtifacts(
            tmp_path / "sbom.json",
            tmp_path / "vulnerabilities.json",
            (),
            "2026-08-13T00:00:00Z",
        )

    monkeypatch.setattr(github, "scan_image", fake_scan)
    runner = RecordingRunner()

    result = github.prepare_candidate(
        tmp_path,
        inputs,
        runner,
        today=datetime(2026, 8, 13, tzinfo=UTC).date(),
    )

    assert result.tag == f"ghcr.io/kenn-io/ghosthub-sandbox:candidate-{SOURCE}"
    assert result.local_content_digest == DIGEST
    assert result.archive == Path(".dist/sandbox-image/local.docker.tar")
    assert result.image_version == "0.1.0"
    assert contracts == [local]
    assert scanned == [local.archive]
    assert not [call for call in runner.calls if call[:2] == ("docker", "push")]
    provenance = tmp_path / ".dist/sandbox-image/candidate-provenance.json"
    assert provenance.exists()


def test_trusted_promotion_plan_performs_checks_without_registry_mutation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[str] = []
    candidate = ImageReference.parse(
        f"ghcr.io/kenn-io/ghosthub-sandbox:candidate-{SOURCE}@{DIGEST}"
    )
    report = SimpleNamespace(
        candidate_tag=f"candidate-{SOURCE}",
        source_commit=SOURCE,
        image_version="0.1.0",
        completed_at="2026-08-13T01:00:00Z",
        scan_database_timestamp="2026-08-13T00:00:00Z",
        dispositions=(),
    )
    evidence = SimpleNamespace(report=report)

    monkeypatch.setenv("SANDBOX_PROMOTION_APP_ID", "424242")
    monkeypatch.setattr(
        github,
        "verify_production_environment",
        lambda *_, **_kwargs: "c" * 64,
    )
    monkeypatch.setattr(
        github, "verify_promotion_status_environment", lambda *_: "d" * 64
    )
    monkeypatch.setattr(github, "verify_package_writer_environment", lambda *_: None)
    monkeypatch.setattr(github, "verify_required_promotion_status", lambda *_: None)
    monkeypatch.setattr(github, "verify_required_merge_signal", lambda *_: None)

    def verify_evidence(*_args: object, **kwargs: object) -> object:
        assert kwargs["now"] == datetime(2026, 8, 13, 2, tzinfo=UTC)
        events.append("evidence")
        return evidence

    monkeypatch.setattr(github, "verify_promotion_evidence", verify_evidence)
    monkeypatch.setattr(github, "resolve_tag", lambda *_: candidate)
    monkeypatch.setattr(github, "verify_candidate_identity", lambda *_: None)
    monkeypatch.setattr(github, "verify_candidate_attestations", lambda *_: None)
    monkeypatch.setattr(github, "image_inputs_digest", lambda *_: DIGEST)
    monkeypatch.setattr(github, "verify_current_candidate_policy", lambda *_: None)

    def available(*_args: object) -> str:
        events.append("available")
        return "create"

    monkeypatch.setattr(github, "assert_tag_available", available)
    result = github.trusted_promotion_plan(
        tmp_path,
        SOURCE,
        DIGEST,
        "0.1.0",
        RecordingRunner(),
        now=datetime(2026, 8, 13, 2, tzinfo=UTC),
    )

    assert result.candidate == candidate
    assert result.production_tag == "ghcr.io/kenn-io/ghosthub-sandbox:v0.1.0"
    assert result.action == "create"
    assert result.expires_at == datetime(2026, 8, 14, 1, tzinfo=UTC)
    assert result.production_environment_fingerprint == "c" * 64
    assert result.status_environment_fingerprint == "d" * 64
    assert events == [
        "evidence",
        "evidence",
        "available",
    ]
