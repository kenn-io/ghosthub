import json
import tarfile
from pathlib import Path

import pytest
from sandbox_image.model import ImageReference
from sandbox_image.trivy import (
    candidate_artifact_directory,
    extract_oci_archive,
    parse_findings,
    trivy_asset,
)


def test_trivy_asset_uses_upstream_platform_names() -> None:
    assert trivy_asset("Darwin", "arm64") == "trivy_0.73.0_macOS-ARM64.tar.gz"
    assert trivy_asset("Linux", "x86_64") == "trivy_0.73.0_Linux-64bit.tar.gz"


def test_extract_oci_archive_produces_layout_directory(tmp_path: Path) -> None:
    source = tmp_path / "source"
    source.mkdir()
    (source / "oci-layout").write_text('{"imageLayoutVersion":"1.0.0"}\n')
    (source / "index.json").write_text("{}\n")
    archive = tmp_path / "image.tar"
    with tarfile.open(archive, "w") as package:
        package.add(source / "oci-layout", arcname="oci-layout")
        package.add(source / "index.json", arcname="index.json")
    destination = tmp_path / "layout"

    extract_oci_archive(archive, destination)

    assert (destination / "oci-layout").is_file()
    assert (destination / "index.json").is_file()


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"Results": []},
        {"Results": [{"Class": "lang-pkgs", "Vulnerabilities": []}]},
        {
            "Results": [
                {"Class": "os-pkgs", "Vulnerabilities": []},
                {"Class": "unknown", "Vulnerabilities": []},
            ]
        },
        {
            "Results": [
                {"Class": "os-pkgs", "Vulnerabilities": []},
                "malformed",
            ]
        },
        {
            "Results": [
                {
                    "Class": "os-pkgs",
                    "Vulnerabilities": [
                        {
                            "VulnerabilityID": "CVE-1",
                            "PkgName": "openssl",
                            "Severity": "Hihg",
                        }
                    ],
                }
            ]
        },
    ],
)
def test_trivy_parser_rejects_missing_or_malformed_os_results(
    tmp_path: Path, payload: object
) -> None:
    report = tmp_path / "trivy.json"
    report.write_text(json.dumps(payload), encoding="utf-8")
    with pytest.raises(ValueError):
        parse_findings(report)


def test_candidate_scan_artifacts_are_digest_scoped(tmp_path: Path) -> None:
    first = ImageReference.parse("ghcr.io/kenn-io/ghosthub-sandbox@sha256:" + "a" * 64)
    second = ImageReference.parse("ghcr.io/kenn-io/ghosthub-sandbox@sha256:" + "b" * 64)
    assert candidate_artifact_directory(tmp_path, first) != (
        candidate_artifact_directory(tmp_path, second)
    )


def test_trivy_parser_includes_language_package_findings(tmp_path: Path) -> None:
    report = tmp_path / "trivy.json"
    report.write_text(
        json.dumps(
            {
                "Results": [
                    {
                        "Class": "os-pkgs",
                        "Type": "ubuntu",
                        "Target": "ubuntu",
                        "Vulnerabilities": [],
                    },
                    {
                        "Class": "lang-pkgs",
                        "Type": "gobinary",
                        "Target": "usr/bin/pebble",
                        "Vulnerabilities": [
                            {
                                "VulnerabilityID": "CVE-2026-39821",
                                "PkgName": "stdlib",
                                "Severity": "HIGH",
                                "FixedVersion": "1.26.6",
                            }
                        ],
                    },
                ]
            }
        ),
        encoding="utf-8",
    )

    findings = parse_findings(report)

    assert len(findings) == 1
    assert findings[0].vulnerability_id == "CVE-2026-39821"
    assert findings[0].package == "stdlib"
    assert findings[0].result_class == "lang-pkgs"
    assert findings[0].result_type == "gobinary"
    assert findings[0].target == "usr/bin/pebble"
    assert findings[0].severity == "HIGH"
    assert findings[0].fixed_version == "1.26.6"


@pytest.mark.parametrize("os_target", ["ubuntu", "sandbox-image.tar", "random:tag"])
def test_trivy_parser_uses_stable_os_target_identity(
    tmp_path: Path, os_target: str
) -> None:
    report = tmp_path / "trivy.json"
    report.write_text(
        json.dumps(
            {
                "Results": [
                    {
                        "Class": "os-pkgs",
                        "Type": "ubuntu",
                        "Target": os_target,
                        "Vulnerabilities": [
                            {
                                "VulnerabilityID": "CVE-2026-1",
                                "PkgName": "openssl",
                                "Severity": "HIGH",
                            }
                        ],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )

    assert parse_findings(report)[0].target == "rootfs"
