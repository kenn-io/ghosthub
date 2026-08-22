from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

import pytest

SCRIPT = (
    Path(__file__).resolve().parents[2]
    / ".github/actions/run-gui-terminal-tests/run-tests.sh"
)


@pytest.fixture
def wrapper_environment(tmp_path: Path) -> dict[str, Path]:
    paths = {
        name: tmp_path / name
        for name in [
            "home",
            "output",
            "ready",
            "result",
            "runner-temp",
            "state",
            "tmp",
            "workspace",
        ]
    }
    for name in ["home", "runner-temp", "state", "tmp", "workspace"]:
        paths[name].mkdir()
    tools = paths["workspace"] / "tools"
    tools.mkdir()
    paths["test-runner"] = tools / "run_swift_tests.sh"
    return paths


def wrapper_command(paths: dict[str, Path]) -> list[str]:
    return [
        "/bin/bash",
        str(SCRIPT),
        str(paths["ready"]),
        str(paths["result"]),
        str(paths["output"]),
        str(paths["workspace"]),
        os.environ["PATH"],
        str(paths["home"]),
        f"{paths['tmp']}/",
        str(paths["home"]),
        "/Applications/Xcode.app/Contents/Developer",
        str(paths["state"]),
        "unused-target",
        "unused-zig",
        "self-hosted",
        str(paths["runner-temp"]),
        "/bin/bash",
        "true",
        "true",
        "swift",
        "test",
    ]


def test_wrapper_records_test_failure(
    wrapper_environment: dict[str, Path],
) -> None:
    paths = wrapper_environment
    paths["test-runner"].write_text("#!/bin/sh\nexit 23\n")
    paths["test-runner"].chmod(0o700)
    paths["ready"].touch()

    result = subprocess.run(wrapper_command(paths), check=False)

    assert result.returncode == 23
    assert paths["result"].read_text().strip() == "23"


def test_cancellation_before_readiness_does_not_start_tests(
    wrapper_environment: dict[str, Path],
) -> None:
    paths = wrapper_environment
    started = paths["workspace"] / "started"
    paths["test-runner"].write_text(f'#!/bin/sh\necho started > "{started}"\n')
    paths["test-runner"].chmod(0o700)

    wrapper = subprocess.Popen(wrapper_command(paths))
    time.sleep(0.1)
    wrapper.terminate()
    paths["ready"].touch()

    assert wrapper.wait(timeout=5) == 143
    assert paths["result"].read_text().strip() == "143"
    assert not started.exists()


def test_cancellation_forwards_to_running_test_wrapper(
    wrapper_environment: dict[str, Path],
) -> None:
    paths = wrapper_environment
    test_pid_file = paths["runner-temp"] / "test.pid"
    paths["test-runner"].write_text(
        "#!/bin/sh\n"
        "trap 'exit 0' TERM\n"
        f'echo $$ > "{test_pid_file}"\n'
        "while :; do sleep 1; done\n"
    )
    paths["test-runner"].chmod(0o700)
    paths["ready"].touch()

    wrapper = subprocess.Popen(wrapper_command(paths))
    deadline = time.monotonic() + 5
    while not test_pid_file.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    if not test_pid_file.exists():
        wrapper.kill()
        wrapper.wait(timeout=5)
        raise AssertionError("test wrapper did not start")
    test_pid = int(test_pid_file.read_text().strip())

    wrapper.terminate()
    assert wrapper.wait(timeout=5) == 143
    assert paths["result"].read_text().strip() == "143"
    with pytest.raises(ProcessLookupError):
        os.kill(test_pid, 0)
