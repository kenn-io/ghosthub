import hashlib
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "tools" / "verify_release_candidate.sh"
DMG = "Ghosthub_1.2.3_macos_arm64.dmg"


def run(artifacts: Path, version: str = "1.2.3") -> subprocess.CompletedProcess:
    return subprocess.run(
        ["/bin/sh", SCRIPT, artifacts, version],
        capture_output=True,
        text=True,
        check=False,
    )


def write_artifacts(directory: Path, recorded_digest: str) -> Path:
    dmg = directory / DMG
    dmg.write_bytes(b"not a disk image")
    line = f"{recorded_digest}  {DMG}\n"
    (directory / f"{DMG}.sha256").write_text(line)
    (directory / "SHA256SUMS").write_text(line)
    return dmg


def test_rejects_a_dmg_whose_checksum_does_not_match(tmp_path):
    dmg = write_artifacts(tmp_path, "0" * 64)

    result = run(tmp_path)

    assert result.returncode == 1
    assert f"FAIL: {DMG}.sha256 does not match" in result.stderr
    # Rejected before the file is quarantined, mounted, or assessed.
    assert "com.apple.quarantine" not in subprocess.run(
        ["xattr", dmg], capture_output=True, text=True, check=False
    ).stdout


def test_rejects_a_dmg_without_a_notarization_ticket(tmp_path):
    payload_digest = hashlib.sha256(b"not a disk image").hexdigest()
    write_artifacts(tmp_path, payload_digest)

    result = run(tmp_path)

    assert result.returncode == 1
    assert "FAIL: the DMG has no valid notarization ticket" in result.stderr


def test_rejects_a_missing_dmg_for_the_requested_version(tmp_path):
    write_artifacts(tmp_path, "0" * 64)

    result = run(tmp_path, version="9.9.9")

    assert result.returncode == 1
    assert "Ghosthub_9.9.9_macos_arm64.dmg is missing" in result.stderr
