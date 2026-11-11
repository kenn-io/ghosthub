import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "tools" / "verify_release_candidate.sh"
DMG = "Ghosthub_1.2.3_macos_arm64.dmg"
PAYLOAD = b"not a disk image"


def run(
    artifacts: Path, version: str = "1.2.3", env: dict | None = None
) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["/bin/sh", SCRIPT, artifacts, version],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


def write_artifacts(directory: Path, recorded_digest: str) -> Path:
    dmg = directory / DMG
    dmg.write_bytes(PAYLOAD)
    line = f"{recorded_digest}  {DMG}\n"
    (directory / f"{DMG}.sha256").write_text(line)
    (directory / "SHA256SUMS").write_text(line)
    return dmg


def test_rejects_a_dmg_whose_checksum_does_not_match(tmp_path):
    dmg = write_artifacts(tmp_path, "0" * 64)

    result = run(tmp_path)

    assert result.returncode == 1
    assert f"FAIL: {DMG}.sha256 does not match" in result.stderr
    if sys.platform == "darwin":
        # Rejected before the file is quarantined, mounted, or assessed.
        assert "com.apple.quarantine" not in subprocess.run(
            ["xattr", dmg], capture_output=True, text=True, check=False
        ).stdout


def test_rejects_a_missing_dmg_for_the_requested_version(tmp_path):
    write_artifacts(tmp_path, "0" * 64)

    result = run(tmp_path, version="9.9.9")

    assert result.returncode == 1
    assert "Ghosthub_9.9.9_macos_arm64.dmg is missing" in result.stderr


def test_reports_missing_developer_tools_instead_of_a_bad_ticket(tmp_path):
    artifacts = tmp_path / "artifacts"
    artifacts.mkdir()
    write_artifacts(artifacts, hashlib.sha256(PAYLOAD).hexdigest())
    # A PATH with the checksum tool but no xcrun, as on a Mac without Xcode
    # or the Command Line Tools.
    tools = tmp_path / "bin"
    tools.mkdir()
    (tools / "shasum").symlink_to(shutil.which("shasum"))

    result = run(artifacts, env={**os.environ, "PATH": str(tools)})

    assert result.returncode == 1
    assert "FAIL: stapler is unavailable" in result.stderr
    assert "notarization ticket" not in result.stderr


@pytest.mark.skipif(sys.platform != "darwin", reason="needs Apple's stapler")
def test_rejects_a_dmg_without_a_notarization_ticket(tmp_path):
    write_artifacts(tmp_path, hashlib.sha256(PAYLOAD).hexdigest())

    result = run(tmp_path)

    assert result.returncode == 1
    assert "FAIL: the DMG has no valid notarization ticket" in result.stderr
