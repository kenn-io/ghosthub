from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "run_swift_tests.sh"


@pytest.mark.parametrize(
    "ignores_term",
    [False, True],
    ids=["handles-term", "ignores-term"],
)
def test_terminating_wrapper_stops_group_before_cleanup(
    tmp_path: Path,
    ignores_term: bool,
) -> None:
    child_pid_file = tmp_path / "child.pid"
    grandchild_pid_file = tmp_path / "grandchild.pid"
    tmux_dir_file = tmp_path / "tmux-dir"
    signal_marker = tmp_path / "signal-marker"
    command = tmp_path / "command.sh"
    if ignores_term:
        term_trap = "trap '' TERM\n"
    else:
        term_trap = (
            "trap 'if [ -d \"$TMUX_TMPDIR\" ]; then "
            f'echo present > "{signal_marker}"; '
            "else "
            f'echo missing > "{signal_marker}"; '
            "fi; wait \"$grandchild\" 2>/dev/null || true; exit 0' TERM\n"
        )
    command.write_text(
        "#!/bin/sh\n"
        f'echo $$ > "{child_pid_file}"\n'
        f'echo "$TMUX_TMPDIR" > "{tmux_dir_file}"\n'
        f"{term_trap}"
        "sleep 30 &\n"
        "grandchild=$!\n"
        f'echo "$grandchild" > "{grandchild_pid_file}"\n'
        "wait \"$grandchild\"\n"
    )
    command.chmod(0o755)

    wrapper = subprocess.Popen(
        ["sh", str(SCRIPT), str(command)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    required_files = [
        child_pid_file,
        grandchild_pid_file,
        tmux_dir_file,
    ]
    deadline = time.monotonic() + 10
    while (
        not all(path.exists() for path in required_files)
        and time.monotonic() < deadline
    ):
        time.sleep(0.05)
    if not all(path.exists() for path in required_files):
        wrapper.kill()
        wrapper.wait(timeout=10)
        pytest.fail("test command did not start")

    child_pids = [
        int(child_pid_file.read_text().strip()),
        int(grandchild_pid_file.read_text().strip()),
    ]
    tmux_dir = Path(tmux_dir_file.read_text().strip())

    wrapper.terminate()
    assert wrapper.wait(timeout=12) == 143

    deadline = time.monotonic() + 5
    alive = child_pids
    while alive and time.monotonic() < deadline:
        alive = []
        for pid in child_pids:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            alive.append(pid)
        if alive:
            time.sleep(0.05)

    assert not alive, "test process group survived wrapper termination"
    if not ignores_term:
        assert signal_marker.read_text().strip() == "present"
    assert not tmux_dir.exists()
