import os
import subprocess
from pathlib import Path

import pytest


@pytest.mark.parametrize(
    ("staple_results", "validation_results", "expected_code", "expected_calls"),
    [
        ("0", "0", 0, ["submit", "staple", "validate", "assess"]),
        (
            "68 0",
            "0",
            0,
            ["submit", "staple", "sleep 10", "staple", "validate", "assess"],
        ),
        (
            "68 68 0",
            "0",
            0,
            [
                "submit",
                "staple",
                "sleep 10",
                "staple",
                "sleep 20",
                "staple",
                "validate",
                "assess",
            ],
        ),
        (
            "68 68 68",
            "0",
            68,
            ["submit", "staple", "sleep 10", "staple", "sleep 20", "staple"],
        ),
        ("0", "65", 65, ["submit", "staple", "validate"]),
        (
            "0",
            "68 0",
            0,
            ["submit", "staple", "validate", "sleep 10", "validate", "assess"],
        ),
        (
            "0",
            "68 68 68",
            68,
            ["submit", "staple", "validate", "sleep 10", "validate", "sleep 20", "validate"],
        ),
        ("65", "0", 65, ["submit", "staple"]),
    ],
)
def test_stapling_gates_release_checksum(
    tmp_path, staple_results, validation_results, expected_code, expected_calls
):
    """Exercise the real packaging script with Apple tools at a fixture boundary."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    release = tmp_path / "release"
    (release / "Fixture.app").mkdir(parents=True)
    (tmp_path / "staple-results").write_text(staple_results.replace(" ", "\n") + "\n")
    (tmp_path / "validate-results").write_text(validation_results.replace(" ", "\n") + "\n")
    commands = {
        "make": 'test "$1" = release-app',
        "xattr": 'test "$1" = -cr',
        "hdiutil": 'test "$1" = create; touch "${@: -1}"',
        "plutil": """case "$2" in
  id) echo fixture-submission ;;
  status) echo Accepted ;;
  *) exit 99 ;;
esac""",
        "xcrun": """case "$1 $2" in
  "notarytool submit")
    echo submit >> "$FIXTURE_ROOT/calls"
    echo '{"status":"Accepted","id":"fixture-submission"}' ;;
  "stapler staple"|"stapler validate")
    test "$3" = "$RELEASE_DMG_PATH"
    echo "$2" >> "$FIXTURE_ROOT/calls"
    result=$(head -n 1 "$FIXTURE_ROOT/$2-results")
    tail -n +2 "$FIXTURE_ROOT/$2-results" > "$FIXTURE_ROOT/remaining"
    mv "$FIXTURE_ROOT/remaining" "$FIXTURE_ROOT/$2-results"
    exit "${result:-99}" ;;
  *) exit 99 ;;
esac""",
        "spctl": 'echo assess >> "$FIXTURE_ROOT/calls"',
        "sleep": 'echo "sleep $*" >> "$FIXTURE_ROOT/calls"',
    }
    for name, body in commands.items():
        executable = fake_bin / name
        executable.write_text("#!/bin/bash\nset -euo pipefail\n" + body + "\n")
        executable.chmod(0o755)
    env = {
        **os.environ,
        "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
        "FIXTURE_ROOT": str(tmp_path),
        "GHOSTHUB_APP": "Fixture",
        "RELEASE_ROOT": str(release),
        "RELEASE_APP_PATH": str(release / "Fixture.app"),
        "RELEASE_DMG_PATH": str(release / "fixture.dmg"),
        "DMG_STAGING_DIR": str(release / "staging"),
        "RELEASE_BUILD_VERSION": "1",
        "APPLE_SIGNING_IDENTITY": "",
        "APPLE_NOTARY_KEY_FILE": str(tmp_path / "fixture-key"),
        "APPLE_NOTARY_KEY_ID": "fixture-key",
        "APPLE_NOTARY_ISSUER": "fixture-issuer",
        "TMPDIR": str(tmp_path),
    }
    result = subprocess.run(
        ["bash", str(Path(__file__).resolve().parents[1] / "build_release_dmg.sh")],
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
    )

    assert result.returncode == expected_code, result.stdout + result.stderr
    assert (tmp_path / "calls").read_text().splitlines() == expected_calls
    assert (release / "fixture.dmg.sha256").exists() == (expected_code == 0)
