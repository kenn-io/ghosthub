from __future__ import annotations

import hashlib
import json
import platform
import shutil
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from .model import Finding, ImageReference
from .policy import ALLOWED_SEVERITIES
from .process import Runner

TRIVY_VERSION = "0.73.0"
TRIVY_ASSET_SHA256 = {
    (
        "Darwin",
        "arm64",
    ): "80cc25faaf6378e37701202d0b4f9f43d9e413d198d594ba60fdf559fe44a683",
    (
        "Linux",
        "x86_64",
    ): "2edd39da482bb4e9831962487b68f68e3928ec3137794757f54d00383d79547b",
}


@dataclass(frozen=True)
class ScanArtifacts:
    sbom: Path
    vulnerabilities: Path
    findings: tuple[Finding, ...]
    database_timestamp: str


def install_trivy(root: Path) -> Path:
    system = platform.system()
    machine = platform.machine()
    key = (system, machine)
    expected = TRIVY_ASSET_SHA256.get(key)
    if expected is None:
        raise ValueError(f"Trivy is not pinned for {system}/{machine}")
    executable = root / ".build" / "tools" / "trivy" / TRIVY_VERSION / "trivy"
    if executable.is_file():
        return executable
    executable.parent.mkdir(parents=True, exist_ok=True)
    asset = trivy_asset(system, machine)
    url = f"https://github.com/aquasecurity/trivy/releases/download/v{TRIVY_VERSION}/{asset}"
    archive = executable.parent / asset
    with urllib.request.urlopen(url) as response, archive.open("wb") as output:
        shutil.copyfileobj(response, output)
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != expected:
        archive.unlink(missing_ok=True)
        raise ValueError("downloaded Trivy archive checksum does not match")
    with tarfile.open(archive, "r:gz") as package:
        member = package.getmember("trivy")
        package.extract(member, executable.parent, filter="data")
    archive.unlink()
    executable.chmod(0o755)
    return executable


def trivy_asset(system: str, machine: str) -> str:
    platform_name = "macOS" if system == "Darwin" else system
    architecture = "ARM64" if machine == "arm64" else "64bit"
    return f"trivy_{TRIVY_VERSION}_{platform_name}-{architecture}.tar.gz"


def scan_image(root: Path, image: Path, runner: Runner) -> ScanArtifacts:
    trivy = install_trivy(root)
    distribution = root / ".dist" / "sandbox-image"
    distribution.mkdir(parents=True, exist_ok=True)
    sbom = distribution / "sandbox-image.spdx.json"
    vulnerabilities = distribution / "sandbox-image.vulnerabilities.json"
    with tempfile.TemporaryDirectory(prefix="trivy-", dir=distribution) as temporary:
        scan_target = image
        with tarfile.open(image, "r") as package:
            members = {member.name for member in package.getmembers()}
        if "manifest.json" not in members:
            layout = Path(temporary)
            extract_oci_archive(image, layout)
            scan_target = layout
        runner.run(
            (
                str(trivy),
                "image",
                "--input",
                str(scan_target),
                "--format",
                "spdx-json",
                "--output",
                str(sbom),
            )
        )
        runner.run(
            (
                str(trivy),
                "image",
                "--input",
                str(scan_target),
                "--scanners",
                "vuln",
                "--format",
                "json",
                "--output",
                str(vulnerabilities),
            )
        )
    return ScanArtifacts(
        sbom,
        vulnerabilities,
        parse_findings(vulnerabilities),
        database_timestamp(trivy, runner),
    )


def scan_reference(root: Path, image: str, runner: Runner) -> ScanArtifacts:
    trivy = install_trivy(root)
    reference = ImageReference.parse(image)
    distribution = candidate_artifact_directory(root, reference)
    distribution.mkdir(parents=True, exist_ok=True)
    sbom = distribution / "candidate.spdx.json"
    vulnerabilities = distribution / "candidate.vulnerabilities.json"
    for output, arguments in (
        (sbom, ("--format", "spdx-json")),
        (
            vulnerabilities,
            ("--scanners", "vuln", "--format", "json"),
        ),
    ):
        runner.run(
            (
                str(trivy),
                "image",
                *arguments,
                "--output",
                str(output),
                image,
            )
        )
    return ScanArtifacts(
        sbom,
        vulnerabilities,
        parse_findings(vulnerabilities),
        database_timestamp(trivy, runner),
    )


def candidate_artifact_directory(root: Path, image: ImageReference) -> Path:
    return (
        root
        / ".dist"
        / "sandbox-image"
        / "candidates"
        / image.digest.removeprefix("sha256:")
    )


def database_timestamp(trivy: Path, runner: Runner) -> str:
    result = runner.run((str(trivy), "--version", "--format", "json"))
    try:
        payload = json.loads(result.stdout)
        timestamp = payload["VulnerabilityDB"]["UpdatedAt"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise ValueError(
            "Trivy did not report its vulnerability database time"
        ) from error
    if not isinstance(timestamp, str) or not timestamp.endswith("Z"):
        raise ValueError("Trivy vulnerability database time is invalid")
    return timestamp


def extract_oci_archive(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r") as package:
        package.extractall(destination, filter="data")
    if (
        not (destination / "oci-layout").is_file()
        or not (destination / "index.json").is_file()
    ):
        raise ValueError("image archive is not an OCI layout")


def parse_findings(path: Path) -> tuple[Finding, ...]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("cannot load Trivy vulnerability report") from error
    if not isinstance(payload, dict) or not isinstance(payload.get("Results"), list):
        raise ValueError("Trivy vulnerability report has an invalid schema")
    package_results: list[tuple[dict[str, object], str, str, str]] = []
    has_os_result = False
    for result in payload["Results"]:
        if not isinstance(result, dict):
            raise ValueError("Trivy vulnerability result is invalid")
        result_class = result.get("Class")
        if result_class not in {"os-pkgs", "lang-pkgs"}:
            raise ValueError("Trivy vulnerability result class is unsupported")
        result_type = result.get("Type")
        target = result.get("Target")
        if (
            not isinstance(result_type, str)
            or not result_type
            or not isinstance(target, str)
            or not target
        ):
            raise ValueError("Trivy vulnerability result identity is invalid")
        vulnerabilities = result.get("Vulnerabilities")
        if vulnerabilities is None:
            vulnerabilities = []
        if not isinstance(vulnerabilities, list):
            raise ValueError("Trivy package findings must be an array")
        if result_class == "os-pkgs":
            has_os_result = True
        package_results.append((result, result_class, result_type, target))
    if not has_os_result:
        raise ValueError("Trivy vulnerability report has no OS package result")
    findings: list[Finding] = []
    for result, result_class, result_type, target in package_results:
        vulnerabilities = result.get("Vulnerabilities")
        if vulnerabilities is None:
            vulnerabilities = []
        if not isinstance(vulnerabilities, list):
            raise ValueError("Trivy package findings must be an array")
        for item in vulnerabilities:
            if not isinstance(item, dict):
                raise ValueError("Trivy vulnerability finding is invalid")
            vulnerability_id = item.get("VulnerabilityID")
            package = item.get("PkgName")
            severity = item.get("Severity")
            fixed_version = item.get("FixedVersion") or None
            if (
                not isinstance(vulnerability_id, str)
                or not vulnerability_id
                or not isinstance(package, str)
                or not package
                or not isinstance(severity, str)
                or severity.upper() not in ALLOWED_SEVERITIES
                or (fixed_version is not None and not isinstance(fixed_version, str))
            ):
                raise ValueError("Trivy vulnerability finding is invalid")
            findings.append(
                Finding(
                    vulnerability_id=vulnerability_id,
                    package=package,
                    result_class=result_class,
                    result_type=result_type,
                    target="rootfs" if result_class == "os-pkgs" else target,
                    severity=severity,
                    fixed_version=fixed_version,
                )
            )
    return tuple(findings)
