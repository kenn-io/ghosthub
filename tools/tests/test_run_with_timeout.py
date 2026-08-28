from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "run_with_timeout.sh"


def run(seconds: str, *command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(SCRIPT), seconds, *command],
        capture_output=True,
        text=True,
        timeout=60,
    )


def descendant_pids(root_pid: int) -> set[int]:
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid="],
        capture_output=True,
        check=True,
        text=True,
    )
    children: dict[int, set[int]] = {}
    for line in result.stdout.splitlines():
        pid, parent_pid = (int(value) for value in line.split())
        children.setdefault(parent_pid, set()).add(pid)

    descendants: set[int] = set()
    pending = list(children.get(root_pid, set()))
    while pending:
        pid = pending.pop()
        if pid in descendants:
            continue
        descendants.add(pid)
        pending.extend(children.get(pid, set()))
    return descendants


def test_fast_command_passes_through() -> None:
    result = run("30", "true")
    assert result.returncode == 0


def test_fast_command_does_not_leave_watchdog_timer() -> None:
    wrapper = subprocess.Popen(
        ["sh", str(SCRIPT), "60421", "sleep", "1"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    observed_descendants: set[int] = set()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        observed_descendants.update(descendant_pids(wrapper.pid))
        if len(observed_descendants) >= 2:
            break
        time.sleep(0.01)

    _, stderr = wrapper.communicate(timeout=10)
    leaked = {
        pid
        for pid in observed_descendants
        if not _process_has_exited(pid)
    }
    try:
        assert wrapper.returncode == 0, stderr
        assert len(observed_descendants) >= 2, (
            "did not observe the command and watchdog"
        )
        assert not leaked, "wrapper descendants remained after a fast command"
    finally:
        for pid in leaked:
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGKILL)


def _process_has_exited(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


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
            os.kill(child_pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    pytest.fail(
        "child process group survived the wrapper's termination"
    )


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
