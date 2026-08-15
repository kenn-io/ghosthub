from __future__ import annotations

import json
import re
import shutil
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, date, datetime
from pathlib import Path

from .apple import (
    AppleProviderInfo,
    AppleVettingHarness,
    canonical_report_path,
    cleanup_fixture,
)
from .docker import (
    BuiltImage,
    ImageInputs,
    build_local_image,
    image_content_digest,
    resolve_tag,
    verify_image_contract,
)
from .github import (
    CandidatePlan,
    PromotionPlan,
    dispatch_promotion,
    image_inputs_digest,
    prepare_candidate,
    trusted_promotion_plan,
    verify_candidate_attestations,
    verify_promotion_evidence,
)
from .model import (
    IMAGE_REPOSITORY,
    CheckResult,
    Finding,
    ImageReference,
    read_regular_text,
)
from .policy import evaluate_findings, load_dispositions
from .process import Runner
from .report import (
    REQUIRED_CHECKS,
    VettingReport,
    validate_report,
    validate_report_freshness,
)
from .trivy import scan_image, scan_reference

DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}")
VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
SNAPSHOT_PATTERN = re.compile(r"[0-9]{8}T[0-9]{6}Z")


@dataclass(frozen=True)
class ImageStatus:
    source_version: str
    pin: str
    candidate: str
    production: str
    report: str
    setup: str


def _read_exact(path: Path, pattern: re.Pattern[str], label: str) -> str:
    value = read_regular_text(path, label).strip()
    if pattern.fullmatch(value) is None:
        raise ValueError(f"invalid {label}: {value}")
    return value


def load_inputs(root: Path, runner: Runner) -> ImageInputs:
    image = root / "images" / "sandbox"
    version = _read_exact(image / "VERSION", VERSION_PATTERN, "image version")
    base = _read_exact(image / "UBUNTU_BASE", DIGEST_PATTERN, "Ubuntu base digest")
    snapshot = _read_exact(image / "APT_SNAPSHOT", SNAPSHOT_PATTERN, "APT snapshot")
    revision = runner.run(("git", "-C", str(root), "rev-parse", "HEAD")).stdout.strip()
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("git did not return a full source commit")
    return ImageInputs(base, snapshot, revision, version)


def check_image(
    root: Path,
    *,
    runner: Runner,
    scan: bool = True,
) -> BuiltImage:
    inputs = load_inputs(root, runner)
    built = build_local_image(
        root, inputs, runner, output="docker", no_cache=True
    )
    verify_image_contract(built, runner)
    if scan:
        artifacts = scan_image(root, built.archive, runner)
        policy_date = datetime.now(UTC).date()
        dispositions = load_dispositions(
            root / "images/sandbox/vulnerability-dispositions.json", policy_date
        )
        policy = evaluate_findings(artifacts.findings, dispositions, policy_date)
        if not policy.accepted:
            raise ValueError("sandbox image vulnerability policy did not pass")
    rebuilt = build_local_image(
        root, inputs, runner, output="docker", no_cache=True
    )
    if image_content_digest(built.local_tag, runner) != image_content_digest(
        rebuilt.local_tag, runner
    ):
        raise ValueError("sandbox image build is not reproducible")
    return built


def prepare_candidate_image(root: Path, *, runner: Runner) -> CandidatePlan:
    inputs = load_inputs(root, runner)
    return prepare_candidate(root, inputs, runner)


def promote_image(root: Path, image: str, version: str, *, runner: Runner) -> str:
    return dispatch_promotion(root, ImageReference.parse(image), version, runner)


def verify_promotion(
    root: Path,
    evidence_commit: str,
    digest: str,
    version: str,
    *,
    runner: Runner,
) -> None:
    verify_promotion_evidence(root, evidence_commit, digest, version, runner)


def prepare_promotion(
    root: Path,
    evidence_commit: str,
    digest: str,
    version: str,
    *,
    runner: Runner,
) -> PromotionPlan:
    return trusted_promotion_plan(
        root,
        evidence_commit,
        digest,
        version,
        runner,
    )


def refresh_image(
    root: Path,
    *,
    version: str,
    runner: Runner,
    snapshot: str | None = None,
) -> None:
    if VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError("sandbox image version must be X.Y.Z")
    resolved_snapshot = snapshot or datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    if SNAPSHOT_PATTERN.fullmatch(resolved_snapshot) is None:
        raise ValueError("APT snapshot must be YYYYMMDDTHHMMSSZ")
    inspected = runner.run(
        ("docker", "buildx", "imagetools", "inspect", "ubuntu:26.04", "--raw")
    )
    try:
        payload = json.loads(inspected.stdout)
        manifests = payload["manifests"]
        base = next(
            item["digest"]
            for item in manifests
            if item["platform"].get("os") == "linux"
            and item["platform"].get("architecture") == "arm64"
        )
    except (json.JSONDecodeError, KeyError, StopIteration, TypeError) as error:
        raise ValueError("cannot resolve the official Ubuntu arm64 manifest") from error
    if DIGEST_PATTERN.fullmatch(base) is None:
        raise ValueError("Ubuntu registry returned an invalid manifest digest")
    image = root / "images" / "sandbox"
    (image / "VERSION").write_text(version + "\n", encoding="utf-8")
    (image / "UBUNTU_BASE").write_text(base + "\n", encoding="utf-8")
    (image / "APT_SNAPSHOT").write_text(resolved_snapshot + "\n", encoding="utf-8")


def status_image(root: Path, *, runner: Runner) -> ImageStatus:
    version = _read_exact(
        root / "images/sandbox/VERSION", VERSION_PATTERN, "image version"
    )
    pin_path = root / "SANDBOX_IMAGE"
    package = runner.run(
        (
            "gh",
            "api",
            "/orgs/kenn-io/packages/container/ghosthub-sandbox",
        ),
        check=False,
    )
    setup = "package pending"
    if package.returncode == 0:
        try:
            visibility = json.loads(package.stdout)["visibility"]
        except (json.JSONDecodeError, KeyError, TypeError):
            visibility = "unknown"
        if visibility == "public":
            setup = "public package ready"
        else:
            setup = (
                "blocked: make the first package public at "
                "https://github.com/orgs/kenn-io/packages/container/"
                "ghosthub-sandbox/settings"
            )
    if not pin_path.exists():
        return ImageStatus(
            version, "pending", "pending", "pending", "pending", setup
        )
    pin = ImageReference.parse_runtime_pin(
        read_regular_text(pin_path, "SANDBOX_IMAGE").strip()
    )
    report = root / "images/sandbox/reports" / f"{pin.digest.replace(':', '-')}.json"
    candidate = "unknown"
    production = "unknown"
    report_state = "missing"
    if report.exists():
        try:
            evidence = VettingReport.load(report)
            expected = ImageReference.parse(
                f"{pin.repository}:{evidence.candidate_tag}@{pin.digest}"
            )
            policy_date = datetime.now(UTC).date()
            validate_report(evidence, expected, version, today=policy_date)
            current = load_dispositions(
                root / "images/sandbox/vulnerability-dispositions.json", policy_date
            )
            if evidence.dispositions != current:
                raise ValueError("report dispositions do not match current policy")
            report_state = "valid"
            candidate = _registry_alias_status(
                f"{IMAGE_REPOSITORY}:{evidence.candidate_tag}", pin.digest, runner
            )
            production = _registry_alias_status(
                f"{IMAGE_REPOSITORY}:v{evidence.image_version}", pin.digest, runner
            )
        except ValueError:
            report_state = "invalid"
    return ImageStatus(
        version,
        pin.runtime_pin,
        candidate,
        production,
        report_state,
        setup,
    )


def _registry_alias_status(tag: str, digest: str, runner: Runner) -> str:
    result = runner.run(
        (
            "docker",
            "buildx",
            "imagetools",
            "inspect",
            tag,
            "--format",
            "{{json .}}",
        ),
        check=False,
    )
    if result.returncode != 0:
        return "unavailable"
    try:
        resolved = json.loads(result.stdout)["manifest"]["digest"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return "invalid response"
    return "matches pin" if resolved == digest else "conflicts with pin"


def maintenance_image(root: Path, *, runner: Runner) -> tuple[str, bool]:
    pin_path = root / "SANDBOX_IMAGE"
    if not pin_path.exists():
        return "Sandbox image not initialized", False
    pin = ImageReference.parse_runtime_pin(
        read_regular_text(pin_path, "SANDBOX_IMAGE").strip()
    )
    report = VettingReport.load(canonical_report_path(root, pin.digest))
    expected = ImageReference.parse(
        f"{pin.repository}:{report.candidate_tag}@{pin.digest}"
    )
    policy_date = datetime.now(UTC).date()
    validate_report(report, expected, report.image_version, today=policy_date)
    dispositions = load_dispositions(
        root / "images/sandbox/vulnerability-dispositions.json", policy_date
    )
    if report.dispositions != dispositions:
        raise ValueError("production report dispositions do not match main")
    production = resolve_tag(f"{IMAGE_REPOSITORY}:v{report.image_version}", runner)
    if production.digest != pin.digest:
        raise ValueError("production tag does not match SANDBOX_IMAGE")
    verify_candidate_attestations(
        production,
        report.source_commit,
        image_inputs_digest(root),
        runner,
    )
    artifacts = scan_reference(root, pin.runtime_pin, runner)
    policy = evaluate_findings(artifacts.findings, dispositions, policy_date)
    inspected = runner.run(
        ("docker", "buildx", "imagetools", "inspect", "ubuntu:26.04", "--raw")
    )
    try:
        payload = json.loads(inspected.stdout)
        current_base = next(
            item["digest"]
            for item in payload["manifests"]
            if item["platform"].get("os") == "linux"
            and item["platform"].get("architecture") == "arm64"
        )
    except (json.JSONDecodeError, KeyError, StopIteration, TypeError) as error:
        raise ValueError("cannot resolve current Ubuntu arm64 base") from error
    pinned_base = _read_exact(
        root / "images/sandbox/UBUNTU_BASE", DIGEST_PATTERN, "Ubuntu base digest"
    )
    base_state = (
        "new Ubuntu base available"
        if current_base != pinned_base
        else "Ubuntu base current"
    )
    if policy.accepted:
        return f"Production scan passed; {base_state}", False
    snapshot = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    refreshable: list[str] = []
    apt_probe = (
        "pkg=$1; fixed=$2; snapshot=$3; "
        "apt-get update -o APT::Snapshot=$snapshot "
        "-o Acquire::Snapshots::URI::Host::ports.ubuntu.com="
        "https://snapshot.ubuntu.com/ubuntu/@SNAPSHOTID@/ >/dev/null; "
        "candidate=$(apt-cache policy \"$pkg\" | awk '/Candidate:/ {print $2}'); "
        'test -n "$candidate"; test "$candidate" != \'(none)\'; '
        'dpkg --compare-versions "$candidate" ge "$fixed"'
    )
    for finding in policy.blocking:
        if finding.fixed_version is None:
            continue
        result = runner.run(
            (
                "docker",
                "run",
                "--rm",
                "--platform",
                "linux/arm64",
                "--user",
                "root",
                pin.runtime_pin,
                "bash",
                "-lc",
                apt_probe,
                "--",
                finding.package,
                finding.fixed_version,
                snapshot,
            ),
            check=False,
        )
        if result.returncode == 0:
            refreshable.append(_finding_label(finding))
    blocking = ", ".join(_finding_label(finding) for finding in policy.blocking)
    refresh = (
        "; current snapshot offers fixes for " + ", ".join(refreshable)
        if refreshable
        else ""
    )
    return f"Production scan requires action: {blocking}; {base_state}{refresh}", True


def _finding_label(finding: Finding) -> str:
    return (
        f"{finding.vulnerability_id}/{finding.package} "
        f"[{finding.result_class}:{finding.result_type} {finding.target}]"
    )


def pin_image(root: Path, image: str) -> None:
    reference = ImageReference.parse(image)
    if reference.tag is not None and not reference.tag.startswith("candidate-"):
        raise ValueError("only a candidate image can be pinned")
    path = canonical_report_path(root, reference.digest)
    if not path.is_file():
        raise ValueError("canonical sandbox image report is missing")
    report = VettingReport.load(path)
    expected = reference
    if expected.tag is None:
        expected = ImageReference.parse(
            f"{IMAGE_REPOSITORY}:{report.candidate_tag}@{reference.digest}"
        )
    version = _read_exact(
        root / "images/sandbox/VERSION", VERSION_PATTERN, "image version"
    )
    now = datetime.now(UTC)
    policy_date = now.date()
    validate_report(report, expected, version, today=policy_date)
    validate_report_freshness(report, now=now)
    if report.source_commit != report.candidate_tag.removeprefix("candidate-"):
        raise ValueError("vetting report source commit does not match candidate tag")
    dispositions = load_dispositions(
        root / "images/sandbox/vulnerability-dispositions.json", policy_date
    )
    if report.dispositions != dispositions:
        raise ValueError("vetting report vulnerability dispositions are stale")
    pin = root / "SANDBOX_IMAGE"
    pin.write_text(reference.runtime_pin + "\n", encoding="utf-8")


def _utc_timestamp(value: datetime) -> str:
    if value.tzinfo is None:
        raise ValueError("sandbox image clock must return a timezone-aware value")
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _utc_date(value: datetime) -> date:
    if value.tzinfo is None:
        raise ValueError("sandbox image clock must return a timezone-aware value")
    return value.astimezone(UTC).date()


def vet_image(
    root: Path,
    image: str,
    *,
    runner: Runner,
    clock: Callable[[], datetime] = lambda: datetime.now(UTC),
) -> VettingReport:
    reference = ImageReference.parse(image)
    if reference.tag is not None and not reference.tag.startswith("candidate-"):
        raise ValueError("vetting requires a candidate or tag-free digest")
    version = _read_exact(
        root / "images/sandbox/VERSION", VERSION_PATTERN, "image version"
    )
    source_commit = (
        reference.tag.removeprefix("candidate-")
        if reference.tag is not None
        else "0" * 40
    )
    candidate_tag = reference.tag or ("candidate-" + source_commit)
    dispositions = load_dispositions(
        root / "images/sandbox/vulnerability-dispositions.json", _utc_date(clock())
    )
    report_path = canonical_report_path(root, reference.digest)
    state_path = (
        root / ".dist/sandbox-image/vet" / f"{reference.digest.replace(':', '-')}.json"
    )
    if state_path.exists():
        raise ValueError("managed Apple vet fixture already needs cleanup")

    provider = AppleProviderInfo("unavailable", "unavailable", "unavailable")
    check_by_name = {
        name: CheckResult(name, "fail", "not reached") for name in REQUIRED_CHECKS
    }
    attestations: tuple[str, ...] = ()
    findings = ()
    scan_timestamp = _utc_timestamp(clock())
    failure: Exception | None = None
    active_check = "architecture"
    fixture_root = state_path.parent / (state_path.stem + "-repos")
    try:
        harness = AppleVettingHarness(root, runner)
        provider, identity, checks, attestations = harness.exercise_candidate(
            reference, state_path
        )
        source_commit = identity.source_commit
        candidate_tag = "candidate-" + source_commit
        if reference.tag is not None and reference.tag != candidate_tag:
            raise ValueError("candidate tag does not match image source revision")
        if identity.image_version != version:
            raise ValueError("candidate image version does not match source version")
        check_by_name.update({check.name: check for check in checks})
        active_check = "vulnerability-scan"
        artifacts = scan_reference(root, reference.canonical, runner)
        findings = artifacts.findings
        scan_timestamp = artifacts.database_timestamp
        check_by_name[active_check] = CheckResult(
            active_check, "pass", "candidate digest scanned"
        )
        active_check = "vulnerability-policy"
        policy = evaluate_findings(findings, dispositions, _utc_date(clock()))
        if not policy.accepted:
            raise ValueError("candidate vulnerability policy did not pass")
        check_by_name[active_check] = CheckResult(
            active_check, "pass", "current dispositions accepted"
        )
    except Exception as error:
        failure = error
        detail = str(error).replace(str(root), "<repo>")[:2_000]
        check_by_name[active_check] = CheckResult(
            active_check, "fail", detail or "failed"
        )
    finally:
        try:
            if state_path.exists():
                cleanup_fixture(state_path, runner)
            check_by_name["cleanup"] = CheckResult(
                "cleanup", "pass", "managed fixture removed"
            )
        except Exception as cleanup_error:
            check_by_name["cleanup"] = CheckResult(
                "cleanup",
                "fail",
                str(cleanup_error).replace(str(root), "<repo>")[:2_000],
            )
            if failure is None:
                failure = cleanup_error
        shutil.rmtree(fixture_root, ignore_errors=True)

    status = "fail" if failure is not None else "pass"
    report = VettingReport(
        schema_version=1,
        repository=reference.repository,
        digest=reference.digest,
        candidate_tag=candidate_tag,
        image_version=version,
        source_commit=source_commit,
        provider_version=provider.provider_version,
        macos_version=provider.macos_version,
        architecture=provider.architecture,
        attestations=attestations,
        checks=tuple(check_by_name[name] for name in sorted(REQUIRED_CHECKS)),
        scan_database_timestamp=scan_timestamp,
        findings=findings,
        dispositions=dispositions,
        status=status,
        completed_at=_utc_timestamp(clock()),
    )
    report.write(report_path)
    if failure is not None:
        raise ValueError(
            f"sandbox image vetting failed; report: {report_path}"
        ) from failure
    expected = ImageReference.parse(
        f"{reference.repository}:{candidate_tag}@{reference.digest}"
    )
    validate_report(report, expected, version, today=_utc_date(clock()))
    return report
