from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path

import pytest


LAUNCH_BOOTSTRAP = (
    Path(__file__).resolve().parents[2]
    / ".github/actions/run-gui-terminal-tests/LaunchBootstrap.swift"
)
ACTIVATION_POLICY = (
    Path(__file__).resolve().parents[2]
    / ".github/actions/run-gui-terminal-tests/ActivationPolicy.swift"
)
LAUNCH_CONTROLLER = (
    Path(__file__).resolve().parents[2]
    / ".github/actions/run-gui-terminal-tests/LaunchController.swift"
)


def test_already_regular_activation_policy_is_accepted(tmp_path: Path) -> None:
    probe_source = tmp_path / "ActivationPolicyProbe.swift"
    probe = tmp_path / "activation-policy-probe"
    probe_source.write_text(
        """
        import AppKit
        import Darwin

        @main
        enum ActivationPolicyProbe {
            static func main() {
                var transitionAttempted = false
                let ready = ensureRegularActivationPolicy(
                    currentPolicy: .regular
                ) {
                    transitionAttempted = true
                    return false
                }
                guard ready, !transitionAttempted else {
                    exit(1)
                }
            }
        }
        """
    )
    compilation = subprocess.run(
        [
            "/usr/bin/xcrun",
            "swiftc",
            "-O",
            "-framework",
            "AppKit",
            str(ACTIVATION_POLICY),
            str(probe_source),
            "-o",
            str(probe),
        ],
        capture_output=True,
        text=True,
    )
    assert compilation.returncode == 0, compilation.stderr
    subprocess.run([str(probe)], check=True)


@pytest.mark.parametrize(
    "runner_returns",
    [False, True],
    ids=["runner-active", "runner-returned"],
)
def test_launcher_anchors_its_process_group_until_cleanup(
    tmp_path: Path,
    runner_returns: bool,
) -> None:
    launcher = tmp_path / "launcher"
    controller = tmp_path / "controller"
    library = tmp_path / "test-launcher.dylib"
    child_pid_file = tmp_path / "child.pid"
    completion_file = tmp_path / "completion"
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
            if (getenv("GHOSTHUB_TEST_RUNNER_RETURNS") != NULL) return 0;
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
            "swiftc",
            "-O",
            "-framework",
            "AppKit",
            str(LAUNCH_CONTROLLER),
            "-o",
            str(controller),
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
    if runner_returns:
        environment["GHOSTHUB_TEST_RUNNER_RETURNS"] = "1"
    process = subprocess.Popen(
        [
            str(launcher),
            str(child_pid_file),
            str(tmp_path / "result"),
            str(output),
            str(tmp_path / "unused.xctest"),
            "unused-filter",
            str(tmp_path),
            str(completion_file),
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
        if runner_returns:
            deadline = time.monotonic() + 5
            while not completion_file.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            assert completion_file.read_text().strip() == "0"
        time.sleep(0.1)
        assert process.poll() is None

        if runner_returns:
            os.kill(process.pid, signal.SIGKILL)
            assert process.wait(timeout=5) == -signal.SIGKILL
            subprocess.run(
                [str(controller), "signal-process-group", str(process.pid), "0"],
                check=True,
            )

        subprocess.run(
            [
                str(controller),
                "signal-process-group",
                str(process.pid),
                str(signal.SIGTERM),
            ],
            check=True,
        )
        time.sleep(0.2)
        if not runner_returns:
            assert process.poll() is None
        os.kill(child_pid, 0)

        subprocess.run(
            [
                str(controller),
                "signal-process-group",
                str(process.pid),
                str(signal.SIGKILL),
            ],
            check=True,
        )
        if not runner_returns:
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
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            process.wait(timeout=5)
