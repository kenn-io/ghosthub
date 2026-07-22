from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "run_with_timeout.sh"


def run(seconds: str, *command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(SCRIPT), seconds, *command],
        capture_output=True,
        text=True,
        timeout=60,
    )


def test_fast_command_passes_through() -> None:
    result = run("30", "true")
    assert result.returncode == 0


def test_failing_command_is_retried_once_then_fails(tmp_path: Path) -> None:
    counter = tmp_path / "attempts"
    script = tmp_path / "fail.sh"
    script.write_text(
        f'#!/bin/sh\necho x >> "{counter}"\nexit 7\n'
    )
    script.chmod(0o755)

    result = run("30", str(script))

    assert result.returncode != 0
    assert counter.read_text().count("x") == 2, "one retry, then give up"


def test_hung_command_is_killed_and_retried(tmp_path: Path) -> None:
    counter = tmp_path / "attempts"
    script = tmp_path / "hang.sh"
    # First attempt hangs (killed by the watchdog); the retry exits 0.
    script.write_text(
        "#!/bin/sh\n"
        f'echo x >> "{counter}"\n'
        f'if [ "$(wc -l < "{counter}")" -le 1 ]; then sleep 30; fi\n'
        "exit 0\n"
    )
    script.chmod(0o755)

    started = time.monotonic()
    result = run("2", str(script))
    elapsed = time.monotonic() - started

    assert result.returncode == 0, result.stderr
    assert counter.read_text().count("x") == 2
    assert elapsed < 30, "the watchdog must kill the hung attempt"


def test_terminating_wrapper_kills_child_group(tmp_path: Path) -> None:
    pid_file = tmp_path / "child.pid"
    script = tmp_path / "hang.sh"
    script.write_text(
        "#!/bin/sh\n"
        f'echo $$ > "{pid_file}"\n'
        "sleep 30\n"
    )
    script.chmod(0o755)

    wrapper = subprocess.Popen(
        ["sh", str(SCRIPT), "25", str(script)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + 10
    while not pid_file.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    child_pid = int(pid_file.read_text().strip())

    wrapper.terminate()
    wrapper.wait(timeout=10)

    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            import os

            os.kill(child_pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    pytest.fail(
        "child process group survived the wrapper's termination"
    )


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
