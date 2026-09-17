"""Exercise setup decisions without installing tools or changing this Mac."""

import os
import subprocess
from pathlib import Path

import pytest

WIZARD = Path(__file__).resolve().parents[1] / "dev_setup_wizard.sh"


@pytest.fixture
def wizard(tmp_path):
    apps = tmp_path / "Applications with spaces"
    apps.mkdir()
    tools = tmp_path / "mise-tools"
    tools.mkdir()
    for tool in ("go", "zig"):
        executable = tools / tool
        executable.write_text(
            f'#!/bin/bash\necho "{tool} $*" >> "$WIZARD_LOG"\n'
            f'[[ "${{FAIL_TOOL:-}}" != "{tool}" ]]\n'
        )
        executable.chmod(0o755)
    log = tmp_path / "commands"
    env = {
        **os.environ,
        "PATH": "/usr/bin:/bin",
        "APPLICATIONS_FIXTURE": str(apps),
        "TOOLS_FIXTURE": str(tools),
        "WIZARD_LOG": str(log),
        "DEVELOPER_DIR": "/fixture/CommandLineTools",
    }
    # Stub only external boundaries. Tool discovery, Xcode version matching,
    # stage ordering, and permission decisions run the real wizard code.
    setup = r"""
source "$1"
APPLICATIONS_DIR="$APPLICATIONS_FIXTURE"
xcode_version() { cat "$1/version"; }
compatible_sdk() { echo /fixture/CommandLineTools/SDKs/MacOSX.sdk; }
git() { :; }
uv() { :; }
defaults() { return 1; }
xcrun() { :; }
xcodebuild() {
  if [[ "$1" == -version ]]; then
    printf 'Xcode %s\n' "$(xcode_version "${DEVELOPER_DIR%/Contents/Developer}")"
  fi
}
xcodes() {
  if [[ "$1" == install ]]; then
    echo "install Xcode $2" >> "$WIZARD_LOG"
    mkdir -p "$APPLICATIONS_DIR/Xcode_$2.app/Contents/Developer"
    echo "$2" > "$APPLICATIONS_DIR/Xcode_$2.app/version"
  fi
}
mise() (
  echo "mise $*" >> "$WIZARD_LOG"
  [[ "$PWD" == "$REPO_ROOT" ]] || exit 91
  [[ "$1" == install ]] && exit 0
  [[ "$1 $2" == 'exec --' ]] || exit 92
  shift 2
  export PATH="$TOOLS_FIXTURE:$PATH"
  "$@"
)
make() {
  command -v go >/dev/null && command -v zig >/dev/null || return 93
  version=$(xcode_version "${DEVELOPER_DIR%/Contents/Developer}")
  [[ "$version" == "$XCODE_VERSION" ]] || return 94
  echo "build $*" >> "$WIZARD_LOG"
}
sudo() { echo forbidden-sudo >> "$WIZARD_LOG"; return 95; }
xip() { return 95; }
open() { return 95; }
xcode-select() { echo forbidden-xcode-select >> "$WIZARD_LOG"; return 95; }
"""

    def run(script="main", *, input="", extra_env=None):
        result = subprocess.run(
            ["/bin/bash", "-c", setup + script, "wizard-test", str(WIZARD)],
            env={**env, **(extra_env or {})},
            input=input,
            text=True,
            capture_output=True,
            timeout=10,
        )
        commands = log.read_text().splitlines() if log.exists() else []
        return result, commands

    return apps, run


@pytest.mark.parametrize("installed_version", [None, "26.0", "26.0.1", "26.5"])
def test_build_uses_mise_tools_and_exact_xcode(wizard, installed_version):
    apps, run = wizard
    if installed_version:
        app = apps / "Xcode.app"
        (app / "Contents/Developer").mkdir(parents=True)
        (app / "version").write_text(installed_version)

    script = "main"
    if installed_version:
        script = (
            'export DEVELOPER_DIR="$APPLICATIONS_DIR/Xcode.app/Contents/Developer"\n'
            "main"
        )
    result, commands = run(script)

    assert result.returncode == 0, result.stdout + result.stderr
    assert ("install Xcode 26.0.1" in commands) == (installed_version != "26.0.1")
    assert [line for line in commands if line.startswith("build ")] == [
        "build bootstrap-libghostty",
        "build check-libghostty",
        "build build",
    ]
    for tool in ("go", "zig"):
        assert commands.index(f"{tool} version") < commands.index(
            "build bootstrap-libghostty"
        )
    assert not any(line.startswith("forbidden-") for line in commands)


@pytest.mark.parametrize("tool", ["go", "zig"])
def test_tool_version_failure_stops_setup(wizard, tool):
    _, run = wizard
    result, commands = run(extra_env={"FAIL_TOOL": tool})
    assert result.returncode != 0
    assert f"{tool} version" in commands
    assert not any(line.startswith(("install Xcode", "build ")) for line in commands)


@pytest.mark.parametrize(
    "writable, answer", [(True, ""), (False, "n\n"), (False, "y\n")]
)
def test_manual_install_requests_privileges_only_when_needed(wizard, writable, answer):
    apps, run = wizard
    source = apps.parent / "expanded" / "Xcode.app"
    source.mkdir(parents=True)
    (source / "version").write_text("26.0.1")
    if not writable:
        if os.geteuid() == 0:
            pytest.skip("root bypasses directory write permissions")
        apps.chmod(0o555)
    try:
        result, commands = run(
            r"""
sudo() {
  echo privileged-move >> "$WIZARD_LOG"
  chmod u+w "$APPLICATIONS_DIR"
  "$@"
}
install_xcode_app "$APPLICATIONS_DIR/../expanded/Xcode.app" \
  "$APPLICATIONS_DIR/Xcode_26.0.1.app"
""",
            input=answer,
        )
        accepted = writable or answer == "y\n"
        assert result.returncode == (0 if accepted else 1), (
            result.stdout + result.stderr
        )
        assert (apps / "Xcode_26.0.1.app/version").exists() == accepted
        assert source.exists() != accepted
        assert ("privileged-move" in commands) == (not writable and accepted)
    finally:
        apps.chmod(0o755)


@pytest.mark.parametrize("wrong_version", [True, False])
def test_manual_install_preserves_wrong_release_or_existing_destination(
    wizard, wrong_version
):
    apps, run = wizard
    source = apps.parent / "expanded" / "Xcode.app"
    source.mkdir(parents=True)
    (source / "version").write_text("26.0" if wrong_version else "26.0.1")
    destination = apps / "Xcode_26.0.1.app"
    if not wrong_version:
        destination.mkdir()
        (destination / "existing").touch()

    result, commands = run(
        'install_xcode_app "$APPLICATIONS_DIR/../expanded/Xcode.app" '
        '"$APPLICATIONS_DIR/Xcode_26.0.1.app"'
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert source.exists()
    assert not (destination / "version").exists()
    assert (destination / "existing").exists() != wrong_version
    assert "forbidden-sudo" not in commands
