from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "run_swift_tests.sh"
TIMEOUT_SCRIPT = SCRIPT.with_name("run_with_timeout.sh")


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


def test_outer_timeout_leaves_inner_wrapper_time_to_cleanup(
    tmp_path: Path,
) -> None:
    pid_file = tmp_path / "command-pids"
    tmux_dirs_file = tmp_path / "tmux-dirs"
    command = tmp_path / "ignore-term.sh"
    command.write_text(
        "#!/bin/sh\n"
        "trap '' TERM\n"
        f'echo $$ >> "{pid_file}"\n'
        f'echo "$TMUX_TMPDIR" >> "{tmux_dirs_file}"\n'
        "sleep 30\n"
    )
    command.chmod(0o755)

    result = subprocess.run(
        [
            "sh",
            str(TIMEOUT_SCRIPT),
            "1",
            "sh",
            str(SCRIPT),
            str(command),
        ],
        capture_output=True,
        text=True,
        timeout=15,
    )

    assert result.returncode != 0
    command_pids = [
        int(value) for value in pid_file.read_text().splitlines()
    ]
    tmux_dirs = [
        Path(value) for value in tmux_dirs_file.read_text().splitlines()
    ]
    assert len(command_pids) == 2
    assert len(tmux_dirs) == 2

    alive = []
    for pid in command_pids:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        alive.append(pid)
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    assert not alive, "nested timeout left a test command running"
    assert not any(directory.exists() for directory in tmux_dirs)


def test_cleanup_stops_every_socket_in_private_run_directory(
    tmp_path: Path,
) -> None:
    if shutil.which("tmux") is None:
        pytest.skip("tmux is unavailable")

    server_pid_file = tmp_path / "server.pid"
    command = tmp_path / "start-unexpected-server.sh"
    command.write_text(
        "#!/bin/sh\n"
        'socket="$TMUX_TMPDIR/unexpected-socket"\n'
        'tmux -S "$socket" new-session -d\n'
        f'tmux -S "$socket" display-message -p "#{{pid}}" > "{server_pid_file}"\n'
    )
    command.chmod(0o755)

    result = subprocess.run(
        ["sh", str(SCRIPT), str(command)],
        capture_output=True,
        text=True,
        timeout=10,
    )

    assert result.returncode == 0, result.stderr
    server_pid = int(server_pid_file.read_text().strip())
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(server_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    else:
        os.kill(server_pid, signal.SIGKILL)
        pytest.fail("tmux server on an unexpected test socket survived cleanup")


def test_cleanup_bounds_a_stalled_tmux_client(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_pid_file = tmp_path / "fake-tmux.pid"
    fake_tmux = fake_bin / "tmux"
    fake_tmux.write_text(
        "#!/bin/sh\n"
        f'echo $$ > "{fake_pid_file}"\n'
        "trap '' TERM\n"
        "sleep 30\n"
    )
    fake_tmux.chmod(0o755)

    socket_writer = tmp_path / "write-socket.py"
    socket_writer.write_text(
        "import socket\n"
        "import sys\n"
        "sock = socket.socket(socket.AF_UNIX)\n"
        "sock.bind(sys.argv[1])\n"
        "sock.close()\n"
    )
    tmux_dir_file = tmp_path / "tmux-dir"
    command = tmp_path / "create-socket.sh"
    command.write_text(
        "#!/bin/sh\n"
        f'echo "$TMUX_TMPDIR" > "{tmux_dir_file}"\n'
        f'"{sys.executable}" "{socket_writer}" '
        '"$TMUX_TMPDIR/stalled-socket"\n'
    )
    command.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"

    result = subprocess.run(
        ["sh", str(SCRIPT), str(command)],
        capture_output=True,
        text=True,
        timeout=5,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    fake_pid = int(fake_pid_file.read_text().strip())
    try:
        os.kill(fake_pid, 0)
    except ProcessLookupError:
        pass
    else:
        os.killpg(fake_pid, signal.SIGKILL)
        pytest.fail("stalled tmux client survived its cleanup deadline")
    assert not Path(tmux_dir_file.read_text().strip()).exists()
