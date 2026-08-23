from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path


LAUNCH_BOOTSTRAP = (
    Path(__file__).resolve().parents[2]
    / ".github/actions/run-gui-terminal-tests/LaunchBootstrap.swift"
)


def test_launcher_survives_term_until_its_process_group_is_drained(
    tmp_path: Path,
) -> None:
    launcher = tmp_path / "launcher"
    library = tmp_path / "test-launcher.dylib"
    child_pid_file = tmp_path / "child.pid"
    output = tmp_path / "output.log"
    home = tmp_path / "home"
    temporary = tmp_path / "tmp"
    home.mkdir()
    temporary.mkdir()
    output.touch()
    fixture = tmp_path / "fixture.c"
    fixture.write_text(
        """
        #include <signal.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <unistd.h>

        int32_t ghosthub_run_gui_tests(void) {
            pid_t child_pid = fork();
            if (child_pid < 0) return 1;
            if (child_pid == 0) {
                signal(SIGTERM, SIG_IGN);
                while (1) pause();
            }
            FILE *pid_file = fopen(getenv("GHOSTHUB_TEST_CHILD_PID_FILE"), "w");
            if (pid_file == NULL) return 1;
            fprintf(pid_file, "%d\\n", child_pid);
            if (fclose(pid_file) != 0) return 1;
            while (1) pause();
        }
        """
    )
    subprocess.run(
        [
            "/usr/bin/xcrun",
            "swiftc",
            "-O",
            "-framework",
            "AppKit",
            str(LAUNCH_BOOTSTRAP),
            "-o",
            str(launcher),
        ],
        check=True,
    )
    subprocess.run(
        [
            "/usr/bin/xcrun",
            "clang",
            "-O2",
            "-dynamiclib",
            str(fixture),
            "-o",
            str(library),
        ],
        check=True,
    )

    environment = {
        "PATH": os.environ["PATH"],
        "HOME": str(home),
        "TMPDIR": f"{temporary}/",
        "CFFIXED_USER_HOME": str(home),
        "GHOSTHUB_TEST_CHILD_PID_FILE": str(child_pid_file),
    }
    process = subprocess.Popen(
        [
            str(launcher),
            str(child_pid_file),
            str(tmp_path / "result"),
            str(output),
            str(tmp_path / "unused.xctest"),
            "unused-filter",
            str(tmp_path),
        ],
        env=environment,
    )
    child_pid: int | None = None
    try:
        deadline = time.monotonic() + 5
        while not child_pid_file.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert child_pid_file.exists(), output.read_text()
        child_pid = int(child_pid_file.read_text().strip())
        assert os.getpgid(process.pid) == process.pid

        os.killpg(process.pid, signal.SIGTERM)
        time.sleep(0.2)
        assert process.poll() is None
        os.kill(child_pid, 0)

        os.killpg(process.pid, signal.SIGKILL)
        assert process.wait(timeout=5) == -signal.SIGKILL
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            raise AssertionError("launcher child survived process-group cleanup")
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
