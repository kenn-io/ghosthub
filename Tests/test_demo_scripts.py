from __future__ import annotations

import hashlib
import os
import pwd
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest


ROOT = Path(__file__).parents[1]
DEMO = ROOT / "website" / "demo"
WEBSITE_ASSET_NAMES = (
    "hero.png",
    "guide-sessions.png",
    "guide-hosts.png",
    "guide-worktree.png",
    "guide-quick-launch.png",
    "guide-terminal.png",
    "guide-command-center.png",
)


def run_bash(script: str, *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


@pytest.mark.skipif(sys.platform != "darwin", reason="demo scripts target macOS stat")
def test_scratch_guard_rejects_missing_path_under_unsafe_ancestor(tmp_path: Path) -> None:
    unsafe = tmp_path / "unsafe"
    unsafe.mkdir(mode=0o700)
    unsafe.chmod(0o777)
    scratch = unsafe / "not-created-yet"

    result = subprocess.run(
        ["bash", str(DEMO / "stage.sh")],
        cwd=ROOT,
        env={**os.environ, "GHOSTHUB_DEMO_SCRATCH": str(scratch)},
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode != 0
    assert "writable by other users" in result.stderr
    assert not scratch.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="demo scripts target macOS stat")
def test_scratch_guard_requires_creation_after_allow_missing_check(tmp_path: Path) -> None:
    scratch = tmp_path / "scratch"
    env = {**os.environ, "GUARD": str(DEMO / "scratch-guard.sh"), "SCRATCH": str(scratch)}

    allowed = run_bash(
        'source "$GUARD"; demo_scratch_guard "$SCRATCH" allow-missing', env=env
    )
    required = run_bash('source "$GUARD"; demo_scratch_guard "$SCRATCH"', env=env)

    assert allowed.returncode == 0
    assert required.returncode != 0
    assert "disappeared or was never created" in required.stderr


@pytest.mark.skipif(sys.platform != "darwin", reason="demo scripts target macOS stat")
def test_private_directory_prepare_creates_owner_only_output(tmp_path: Path) -> None:
    output = tmp_path / "screenshots"
    env = {
        **os.environ,
        "GUARD": str(DEMO / "scratch-guard.sh"),
        "OUTPUT": str(output),
    }

    result = run_bash(
        'source "$GUARD"; '
        'demo_private_directory_prepare '
        '"$OUTPUT" "screenshot output" "replace screenshots"',
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert output.stat().st_mode & 0o777 == 0o700


@pytest.mark.skipif(sys.platform != "darwin", reason="demo scripts target macOS stat")
@pytest.mark.parametrize("unsafe_kind", ["shared", "symlink"])
def test_private_directory_prepare_rejects_unsafe_output(
    tmp_path: Path, unsafe_kind: str
) -> None:
    output = tmp_path / "screenshots"
    if unsafe_kind == "shared":
        output.mkdir(mode=0o700)
        output.chmod(0o755)
    else:
        target = tmp_path / "target"
        target.mkdir(mode=0o700)
        output.symlink_to(target, target_is_directory=True)
    env = {
        **os.environ,
        "GUARD": str(DEMO / "scratch-guard.sh"),
        "OUTPUT": str(output),
    }

    result = run_bash(
        'source "$GUARD"; '
        'demo_private_directory_prepare '
        '"$OUTPUT" "screenshot output" "replace screenshots"',
        env=env,
    )

    assert result.returncode != 0


def test_stage_uses_a_curated_account_free_agent_session() -> None:
    stage = (DEMO / "stage.sh").read_text()

    assert 'cat > "$scratch/agent-transcript.txt"' in stage
    assert "Ghosthub opens the same tmux client locally and remotely." in stage
    assert '"clear; cat $(printf \'%q\' "$scratch/agent-transcript.txt")"' in stage


def test_stage_stops_live_consumers_before_replacing_scratch_state() -> None:
    stage = (DEMO / "stage.sh").read_text()
    first_replacement = stage.index('rm -rf "$scratch/repos"')

    assert stage.index("demo_stop_recorded_process") < first_replacement
    assert stage.index("demo_stop_tmux_server") < first_replacement
    assert stage.index("demo_stop_recorded_process") < stage.index(
        'rm -rf "$scratch/app"'
    )


def test_stage_uses_immutable_docker_image_id_without_a_shared_tag() -> None:
    stage = (DEMO / "stage.sh").read_text()

    assert 'image_id="$(docker build -q "$demo_root/remote")"' in stage
    assert "docker build -q -t" not in stage
    assert '-p 127.0.0.1:2201:22 "$image_id"' in stage


def test_stage_builds_ghosthub_from_synthetic_history() -> None:
    stage = (DEMO / "stage.sh").read_text()

    ghosthub_fixture = stage[
        stage.index("make_repo ghosthub") : stage.index("make_repo agentsview")
    ]
    assert "Initial native workspace" in ghosthub_fixture
    assert "Attach ordinary tmux clients" in ghosthub_fixture
    assert "Reconnect remote sessions" in ghosthub_fixture


def test_demo_git_ignores_url_rewrites_and_hooks(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    hooks = tmp_path / "hooks"
    hooks.mkdir()
    hook_marker = tmp_path / "hook-ran"
    hook = hooks / "pre-commit"
    hook.write_text(
        "#!/usr/bin/env bash\n"
        'printf hook-ran > "$HOOK_MARKER"\n'
    )
    hook.chmod(0o755)
    global_config = tmp_path / "gitconfig"
    global_config.write_text(
        '[url "file:///private/unpublished"]\n'
        "    insteadOf = https://github.com/kenn-io/\n"
        "[core]\n"
        f"    hooksPath = {hooks}\n"
    )
    public_url = "https://github.com/kenn-io/ghosthub.git"
    env = {
        **os.environ,
        "GIT_CONFIG_GLOBAL": str(global_config),
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "core.hooksPath",
        "GIT_CONFIG_VALUE_0": str(hooks),
        "HOOK_MARKER": str(hook_marker),
        "HELPER": str(DEMO / "git.sh"),
        "REPO": str(repo),
        "PUBLIC_URL": public_url,
    }

    result = run_bash(
        'source "$HELPER"; '
        'demo_git -C "$REPO" init -q -b main; '
        'printf fixture > "$REPO/file"; '
        'demo_git -C "$REPO" add file; '
        'demo_git -C "$REPO" -c user.name=demo -c user.email=demo@ghosthub.ai '
        'commit -q -m fixture; '
        'demo_git -C "$REPO" remote add origin "$PUBLIC_URL"; '
        'demo_git -C "$REPO" remote get-url origin',
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == public_url
    assert not hook_marker.exists()


def test_demo_ssh_uses_only_scratch_configuration(tmp_path: Path) -> None:
    ssh_dir = tmp_path / "ssh"
    ssh_dir.mkdir()
    config = ssh_dir / "config"
    shutil.copy2(DEMO / "ssh-config", config)
    known_hosts = ssh_dir / "known_hosts"
    known_hosts.touch()

    result = subprocess.run(
        [
            "/usr/bin/ssh",
            "-G",
            "-F",
            str(config),
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ProxyCommand=none",
            "-o",
            "ProxyJump=none",
            "ghosthub-demo-remote",
        ],
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    settings = dict(
        line.split(None, maxsplit=1)
        for line in result.stdout.splitlines()
        if len(line.split(None, maxsplit=1)) == 2
    )
    assert settings["hostname"] == "127.0.0.1"
    assert settings["port"] == "2201"
    assert settings["user"] == "demo"
    assert settings["hostkeyalias"] == "ghosthub-demo-remote"
    assert settings["userknownhostsfile"] == str(known_hosts)
    assert settings["globalknownhostsfile"] == "/dev/null"
    assert settings["stricthostkeychecking"] == "true"
    assert settings.get("proxycommand", "none") == "none"
    assert settings.get("proxyjump", "none") == "none"

    stage = (DEMO / "stage.sh").read_text()
    teardown = (DEMO / "teardown.sh").read_text()
    run = (DEMO / "run.sh").read_text()
    assert 'GHOSTHUB_DEMO_SSH_DIR="$scratch/ssh"' in run
    assert "known_hosts.saved" not in stage
    assert "known_hosts.saved" not in teardown


@pytest.mark.parametrize(
    ("launcher_shell", "launcher_zdotdir"),
    [
        ("/bin/zsh", "/tmp/personal-zdotdir"),
        ("/opt/homebrew/bin/fish", ""),
    ],
)
def test_demo_session_ignores_launcher_shell_configuration(
    tmp_path: Path, launcher_shell: str, launcher_zdotdir: str
) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    capture = tmp_path / "tmux-args"
    tmux = bin_dir / "tmux"
    tmux.write_text(
        "#!/usr/bin/env bash\n"
        "printf 'CALL\\n' >> \"$CAPTURE\"\n"
        "printf '%s\\n' \"$@\" >> \"$CAPTURE\"\n"
    )
    tmux.chmod(0o755)
    scratch = tmp_path / "scratch"
    (scratch / "home").mkdir(parents=True)
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "SHELL": launcher_shell,
        "ZDOTDIR": launcher_zdotdir,
        "CAPTURE": str(capture),
        "HELPER": str(DEMO / "shell.sh"),
        "SCRATCH": str(scratch),
    }

    result = run_bash(
        'source "$HELPER"; demo_new_session "$SCRATCH" demo /tmp "printf demo-ready"',
        env=env,
    )

    assert result.returncode == 0, result.stderr
    calls = [call.splitlines() for call in capture.read_text().split("CALL\n")[1:]]
    new_session, send_keys = calls
    assert f"HOME={scratch}/home" in new_session
    assert f"ZDOTDIR={scratch}/home" in new_session
    assert "SHELL=/bin/zsh" in new_session
    assert new_session[-1] == "/bin/zsh -l"
    assert send_keys == ["send-keys", "-t", "demo", "printf demo-ready", "Enter"]
    if launcher_zdotdir:
        assert launcher_zdotdir not in new_session
    if launcher_shell != "/bin/zsh":
        assert launcher_shell not in new_session


@pytest.mark.skipif(sys.platform != "darwin", reason="ACL coverage targets macOS")
@pytest.mark.parametrize("acl_target", ["ancestor", "scratch"])
def test_scratch_guard_rejects_non_owner_write_acl(
    tmp_path: Path, acl_target: str
) -> None:
    parent = tmp_path / "parent"
    parent.mkdir(mode=0o700)
    scratch = parent / "scratch"
    if acl_target == "scratch":
        scratch.mkdir(mode=0o700)
        target = scratch
        allow_missing = ""
    else:
        target = parent
        allow_missing = "allow-missing"
    subprocess.run(
        ["chmod", "+a", "user:nobody allow add_file,delete_child", str(target)],
        check=True,
    )
    env = {
        **os.environ,
        "GUARD": str(DEMO / "scratch-guard.sh"),
        "SCRATCH": str(scratch),
        "ALLOW_MISSING": allow_missing,
    }

    result = run_bash(
        'source "$GUARD"; demo_scratch_guard "$SCRATCH" "$ALLOW_MISSING"', env=env
    )

    assert result.returncode != 0
    assert "write-capable ACL rights" in result.stderr


def write_fake_docker(bin_dir: Path) -> None:
    docker = bin_dir / "docker"
    docker.write_text(
        "#!/usr/bin/env bash\n"
        "case ${DOCKER_RESULT:?} in\n"
        "  success) echo \"$3\"; exit 0 ;;\n"
        "  missing) echo \"Error response from daemon: No such container: $3\" >&2; exit 1 ;;\n"
        "  failure) echo \"Cannot connect to the Docker daemon\" >&2; exit 1 ;;\n"
        "esac\n"
    )
    docker.chmod(0o755)


@pytest.mark.parametrize(
    ("docker_result", "record_exists"),
    [("success", False), ("missing", False), ("failure", True)],
)
def test_container_record_is_removed_only_after_confirmed_cleanup(
    tmp_path: Path, docker_result: str, record_exists: bool
) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    write_fake_docker(bin_dir)
    record = tmp_path / "remote.cid"
    record.write_text("a" * 64 + "\n")
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "DOCKER_RESULT": docker_result,
        "HELPER": str(DEMO / "docker-cleanup.sh"),
        "RECORD": str(record),
    }

    result = run_bash(
        'source "$HELPER"; demo_remove_recorded_container "$RECORD"', env=env
    )

    assert result.returncode == (1 if docker_result == "failure" else 0)
    assert record.exists() is record_exists


def test_failed_container_start_preserves_created_container_id(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    cid = "c" * 64
    docker = bin_dir / "docker"
    docker.write_text(
        "#!/usr/bin/env bash\n"
        "case $1 in\n"
        "  create)\n"
        "    while [[ $# -gt 0 ]]; do\n"
        "      if [[ $1 == --cidfile ]]; then printf '%s\\n' \"$CID\" > \"$2\"; fi\n"
        "      shift\n"
        "    done\n"
        "    exit 0 ;;\n"
        "  start) echo 'container failed to start' >&2; exit 1 ;;\n"
        "esac\n"
    )
    docker.chmod(0o755)
    record = tmp_path / "remote.cid"
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "CID": cid,
        "HELPER": str(DEMO / "docker-cleanup.sh"),
        "RECORD": str(record),
    }

    result = run_bash(
        'source "$HELPER"; demo_create_recorded_container "$RECORD" image-name',
        env=env,
    )

    assert result.returncode != 0
    assert record.read_text().strip() == cid


def test_ambiguous_container_create_preserves_empty_record(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    docker = bin_dir / "docker"
    docker.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ $1 == create ]]; then exit 1; fi\n"
        "if [[ $1 == container && $2 == ls ]]; then exit 1; fi\n"
        "exit 1\n"
    )
    docker.chmod(0o755)
    record = tmp_path / "remote.cid"
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "HELPER": str(DEMO / "docker-cleanup.sh"),
        "RECORD": str(record),
    }

    created = run_bash(
        'source "$HELPER"; demo_create_recorded_container "$RECORD" image-name',
        env=env,
    )
    removed = run_bash(
        'source "$HELPER"; demo_remove_recorded_container "$RECORD"', env=env
    )

    assert created.returncode != 0
    assert removed.returncode != 0
    assert record.exists()
    assert record.read_text() == ""
    assert "ambiguous" in removed.stderr


@pytest.mark.skipif(sys.platform != "darwin", reason="demo scripts target macOS stat")
def test_teardown_preserves_scratch_when_docker_cleanup_fails(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    write_fake_docker(bin_dir)
    scratch = tmp_path / "scratch"
    scratch.mkdir(mode=0o700)
    (scratch / ".ghosthub-demo-scratch").touch()
    (scratch / "remote.cid").write_text("b" * 64 + "\n")
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "DOCKER_RESULT": "failure",
        "GHOSTHUB_DEMO_SCRATCH": str(scratch),
    }

    result = subprocess.run(
        ["bash", str(DEMO / "teardown.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode != 0
    assert scratch.is_dir()
    assert (scratch / "remote.cid").is_file()


@pytest.mark.skipif(sys.platform != "darwin", reason="demo scripts target macOS")
def test_teardown_preserves_scratch_when_tmux_shutdown_is_unconfirmed(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    tmux = bin_dir / "tmux"
    tmux.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ $3 == kill-server ]]; then echo 'kill failed' >&2; exit 1; fi\n"
        "if [[ $3 == list-sessions ]]; then echo 'demo: 1 windows'; exit 0; fi\n"
        "exit 1\n"
    )
    tmux.chmod(0o755)
    with tempfile.TemporaryDirectory(prefix="ghosthub-", dir="/tmp") as short_root:
        scratch = Path(short_root) / "scratch"
        socket_path = scratch / "tmux" / f"tmux-{os.getuid()}" / "default"
        socket_path.parent.mkdir(parents=True)
        scratch.chmod(0o700)
        (scratch / ".ghosthub-demo-scratch").touch()
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(socket_path))
        try:
            env = {
                **os.environ,
                "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                "GHOSTHUB_DEMO_SCRATCH": str(scratch),
                "GHOSTHUB_DEMO_TMUX_STOP_ATTEMPTS": "2",
                "GHOSTHUB_DEMO_TMUX_STOP_DELAY": "0",
            }
            result = subprocess.run(
                ["bash", str(DEMO / "teardown.sh")],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
        finally:
            listener.close()

        assert result.returncode != 0
        assert "remains active" in result.stderr
        assert scratch.is_dir()


@pytest.mark.skipif(sys.platform != "darwin", reason="demo scripts target macOS")
def test_tmux_kill_error_is_ignored_only_after_no_server_probe(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    tmux = bin_dir / "tmux"
    tmux.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ $3 == kill-server ]]; then echo 'kill raced with exit' >&2; exit 1; fi\n"
        "if [[ $3 == list-sessions ]]; then echo \"no server running on $2\" >&2; exit 1; fi\n"
        "exit 1\n"
    )
    tmux.chmod(0o755)
    with tempfile.TemporaryDirectory(prefix="ghosthub-", dir="/tmp") as short_root:
        socket_path = Path(short_root) / "tmux.sock"
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(socket_path))
        try:
            env = {
                **os.environ,
                "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                "HELPER": str(DEMO / "tmux.sh"),
                "SOCKET": str(socket_path),
            }
            result = run_bash(
                'source "$HELPER"; demo_stop_tmux_server "$SOCKET"', env=env
            )
        finally:
            listener.close()

        assert result.returncode == 0, result.stderr


@pytest.mark.skipif(shutil.which("ssh-keygen") is None, reason="ssh-keygen unavailable")
def test_known_hosts_replacement_does_not_touch_real_old_backup(tmp_path: Path) -> None:
    ssh_dir = tmp_path / ".ssh"
    ssh_dir.mkdir(mode=0o700)
    first_key = tmp_path / "first"
    second_key = tmp_path / "second"
    for key in (first_key, second_key):
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
            check=True,
        )
    first_public = first_key.with_suffix(".pub").read_text().split()
    second_public = second_key.with_suffix(".pub").read_text().split()
    host = "[127.0.0.1]:2201"
    known_hosts = ssh_dir / "known_hosts"
    known_hosts.write_text(
        f"{host} {first_public[0]} {first_public[1]}\n"
        f"example.test {first_public[0]} {first_public[1]}\n"
    )
    old_backup = ssh_dir / "known_hosts.old"
    old_backup.write_text("user backup must survive\n")
    additions = tmp_path / "additions"
    additions.write_text(f"{host} {second_public[0]} {second_public[1]}\n")
    env = {
        **os.environ,
        "HELPER": str(DEMO / "known-hosts.sh"),
        "HOST_ENTRY": host,
        "ADDITIONS": str(additions),
        "KNOWN_HOSTS": str(known_hosts),
    }

    result = run_bash(
        'source "$HELPER"; demo_known_hosts_replace "$HOST_ENTRY" "$ADDITIONS" "$KNOWN_HOSTS"',
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert old_backup.read_text() == "user backup must survive\n"
    contents = known_hosts.read_text()
    assert f"example.test {first_public[0]} {first_public[1]}" in contents
    assert f"{host} {first_public[0]} {first_public[1]}" not in contents
    assert f"{host} {second_public[0]} {second_public[1]}" in contents
    assert not list(ssh_dir.glob(".ghosthub-known-hosts.*"))


@pytest.mark.skipif(shutil.which("ssh-keygen") is None, reason="ssh-keygen unavailable")
def test_known_hosts_addition_gets_separator_after_unterminated_line(tmp_path: Path) -> None:
    ssh_dir = tmp_path / ".ssh"
    ssh_dir.mkdir(mode=0o700)
    key = tmp_path / "key"
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
        check=True,
    )
    public = key.with_suffix(".pub").read_text().split()
    existing = f"example.test {public[0]} {public[1]}"
    addition = f"[127.0.0.1]:2201 {public[0]} {public[1]}\n"
    known_hosts = ssh_dir / "known_hosts"
    known_hosts.write_text(existing)
    additions = tmp_path / "additions"
    additions.write_text(addition)
    env = {
        **os.environ,
        "HELPER": str(DEMO / "known-hosts.sh"),
        "ADDITIONS": str(additions),
        "KNOWN_HOSTS": str(known_hosts),
    }

    result = run_bash(
        'source "$HELPER"; demo_known_hosts_replace host "$ADDITIONS" "$KNOWN_HOSTS"',
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert known_hosts.read_text() == f"{existing}\n{addition}"


@pytest.mark.skipif(sys.platform != "darwin", reason="process path coverage targets macOS")
def test_recorded_process_uses_literal_executable_path(tmp_path: Path) -> None:
    scratch = tmp_path / "demo[+].path"
    scratch.mkdir()
    source = tmp_path / "sleeper.c"
    source.write_text("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n")
    executable = scratch / "Ghosthub"
    subprocess.run(["cc", "-o", str(executable), str(source)], check=True)
    other_executable = scratch / "OtherGhosthub"
    shutil.copy2(executable, other_executable)
    record = scratch / "app.pid"
    env = {
        **os.environ,
        "HELPER": str(DEMO / "process.sh"),
        "EXECUTABLE": str(executable),
        "OTHER_EXECUTABLE": str(other_executable),
        "RECORD": str(record),
    }

    result = run_bash(
        'source "$HELPER"; '
        '"$EXECUTABLE" & pid=$!; '
        'demo_record_process "$pid" "$RECORD" "$EXECUTABLE"; '
        '[[ "$(demo_require_recorded_process "$RECORD" "$EXECUTABLE")" == "$pid" ]]; '
        'if demo_stop_recorded_process "$RECORD" "$OTHER_EXECUTABLE" 2>/dev/null; then exit 1; fi; '
        'kill -0 "$pid"; '
        'demo_stop_recorded_process "$RECORD" "$EXECUTABLE"; '
        'wait "$pid" 2>/dev/null || true',
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert not record.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="process path coverage targets macOS")
def test_run_reaps_app_when_pid_recording_fails(tmp_path: Path) -> None:
    scratch = tmp_path / "scratch"
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake_mktemp = bin_dir / "mktemp"
    fake_mktemp.write_text("#!/usr/bin/env bash\nexit 1\n")
    fake_mktemp.chmod(0o755)
    executable = scratch / "app/Ghosthub.app/Contents/MacOS/Ghosthub"
    executable.parent.mkdir(parents=True)
    home = scratch / "home"
    home.mkdir()
    (scratch / "ghosthub-config").mkdir()
    (scratch / "ghosthub-state").mkdir()
    (scratch / ".ghosthub-demo-scratch").touch()
    scratch.chmod(0o700)
    state = scratch / "child-state"
    source = tmp_path / "app.c"
    source.write_text(
        "#include <stdio.h>\n"
        "#include <stdlib.h>\n"
        "#include <unistd.h>\n"
        "int main(void) {\n"
        "  FILE *f = fopen(getenv(\"CHILD_STATE\"), \"w\");\n"
        "  fprintf(f, \"%d\\n%s\\n%s\\n\", getpid(), getenv(\"SHELL\"),\n"
        "          getenv(\"ZDOTDIR\"));\n"
        "  fclose(f);\n"
        "  sleep(30);\n"
        "  return 0;\n"
        "}\n"
    )
    subprocess.run(["cc", "-o", str(executable), str(source)], check=True)
    dylib_source = tmp_path / "demohost.c"
    dylib_source.write_text("void ghosthub_demo_test(void) {}\n")
    subprocess.run(
        [
            "cc",
            "-dynamiclib",
            "-o",
            str(scratch / "libdemohost.dylib"),
            str(dylib_source),
        ],
        check=True,
    )
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "SHELL": "/opt/homebrew/bin/fish",
        "ZDOTDIR": "/tmp/personal-zdotdir",
        "CHILD_STATE": str(state),
        "GHOSTHUB_DEMO_SCRATCH": str(scratch),
    }

    result = subprocess.run(
        ["bash", str(DEMO / "run.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode != 0
    child_pid, child_shell, child_zdotdir = state.read_text().splitlines()
    assert child_shell == "/bin/zsh"
    assert child_zdotdir == str(home)
    with pytest.raises(ProcessLookupError):
        os.kill(int(child_pid), 0)
    assert not (scratch / "app.pid").exists()


@pytest.mark.parametrize(
    ("behavior", "expected_code", "expected_backup"),
    [
        ("match", 0, "host-key-line\n"),
        ("no_match", 0, ""),
        ("partial_failure", 1, None),
        ("interrupted", 1, None),
    ],
)
def test_known_hosts_backup_is_published_only_after_successful_query(
    tmp_path: Path,
    behavior: str,
    expected_code: int,
    expected_backup: str | None,
) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    ssh_keygen = bin_dir / "ssh-keygen"
    ssh_keygen.write_text(
        "#!/usr/bin/env bash\n"
        "case $BACKUP_BEHAVIOR in\n"
        "  match) printf '# Host found\\nhost-key-line\\n'; exit 0 ;;\n"
        "  no_match) exit 1 ;;\n"
        "  partial_failure) echo host-key-line; echo 'read failed' >&2; exit 1 ;;\n"
        "  interrupted) echo host-key-line; exit 130 ;;\n"
        "esac\n"
    )
    ssh_keygen.chmod(0o755)
    known_hosts = tmp_path / "known_hosts"
    known_hosts.write_text("original contents\n")
    backup = tmp_path / "known_hosts.saved"
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "BACKUP_BEHAVIOR": behavior,
        "HELPER": str(DEMO / "known-hosts.sh"),
        "KNOWN_HOSTS": str(known_hosts),
        "BACKUP": str(backup),
    }

    result = run_bash(
        'source "$HELPER"; demo_known_hosts_save host "$BACKUP" "$KNOWN_HOSTS"',
        env=env,
    )

    assert result.returncode == expected_code
    if expected_backup is None:
        assert not backup.exists()
    else:
        assert backup.read_text() == expected_backup


@pytest.mark.skipif(sys.platform != "darwin", reason="metadata coverage targets macOS")
@pytest.mark.parametrize("target_mode", [0o640, 0o400])
def test_known_hosts_symlink_and_target_metadata_are_preserved(
    tmp_path: Path, target_mode: int
) -> None:
    ssh_dir = tmp_path / ".ssh"
    target_dir = tmp_path / "shared-ssh"
    ssh_dir.mkdir(mode=0o700)
    target_dir.mkdir(mode=0o700)
    key = tmp_path / "key"
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
        check=True,
    )
    public = key.with_suffix(".pub").read_text().split()
    host = "[127.0.0.1]:2201"
    target = target_dir / "known_hosts"
    target.write_text(f"{host} {public[0]} {public[1]}\n")
    subprocess.run(
        ["xattr", "-w", "com.ghosthub.demo-test", "preserve me", str(target)],
        check=True,
    )
    username = pwd.getpwuid(os.getuid()).pw_name
    subprocess.run(
        ["chmod", "+a", f"user:{username} allow read", str(target)],
        check=True,
    )
    target.chmod(target_mode)
    acl_before = subprocess.run(
        ["ls", "-le", str(target)], text=True, capture_output=True, check=True
    ).stdout.splitlines()[1:]
    known_hosts = ssh_dir / "known_hosts"
    link_target = Path("..") / target_dir.name / target.name
    known_hosts.symlink_to(link_target)
    additions = tmp_path / "empty-additions"
    additions.touch()
    env = {
        **os.environ,
        "HELPER": str(DEMO / "known-hosts.sh"),
        "HOST_ENTRY": host,
        "ADDITIONS": str(additions),
        "KNOWN_HOSTS": str(known_hosts),
    }

    result = run_bash(
        'source "$HELPER"; demo_known_hosts_replace "$HOST_ENTRY" "$ADDITIONS" "$KNOWN_HOSTS"',
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert known_hosts.is_symlink()
    assert os.readlink(known_hosts) == str(link_target)
    assert target.read_text() == ""
    assert target.stat().st_mode & 0o777 == target_mode
    attribute = subprocess.run(
        ["xattr", "-p", "com.ghosthub.demo-test", str(target)],
        text=True,
        capture_output=True,
        check=True,
    ).stdout
    assert attribute.rstrip("\n") == "preserve me"
    acl_after = subprocess.run(
        ["ls", "-le", str(target)], text=True, capture_output=True, check=True
    ).stdout.splitlines()[1:]
    assert acl_after == acl_before
    assert not list(target_dir.glob(".ghosthub-known-hosts.*"))


@pytest.mark.skipif(sys.platform != "darwin", reason="ACL coverage targets macOS")
def test_known_hosts_rejects_acl_writable_target_directory(tmp_path: Path) -> None:
    ssh_dir = tmp_path / ".ssh"
    ssh_dir.mkdir(mode=0o700)
    subprocess.run(
        ["chmod", "+a", "user:nobody allow add_file,delete_child", str(ssh_dir)],
        check=True,
    )
    known_hosts = ssh_dir / "known_hosts"
    known_hosts.touch(mode=0o600)
    additions = tmp_path / "additions"
    additions.touch()
    env = {
        **os.environ,
        "HELPER": str(DEMO / "known-hosts.sh"),
        "ADDITIONS": str(additions),
        "KNOWN_HOSTS": str(known_hosts),
    }

    result = run_bash(
        'source "$HELPER"; demo_known_hosts_replace host "$ADDITIONS" "$KNOWN_HOSTS"',
        env=env,
    )

    assert result.returncode != 0
    assert "write-capable ACL rights" in result.stderr
    assert not list(ssh_dir.glob(".ghosthub-known-hosts*"))


def make_offline_asset_tree(tmp_path: Path, *, trusted: bool) -> tuple[Path, dict[str, str]]:
    website = tmp_path / "website"
    scripts = website / "scripts"
    assets = website / "src" / "assets"
    fake_bin = tmp_path / "bin"
    scripts.mkdir(parents=True)
    assets.mkdir(parents=True)
    fake_bin.mkdir()
    shutil.copy2(ROOT / "website" / "scripts" / "sync-assets.sh", scripts)
    manifest = []
    for asset_name in WEBSITE_ASSET_NAMES:
        asset = assets / asset_name
        asset.write_bytes(f"unverified-{asset_name}".encode())
        if trusted:
            digest = hashlib.sha256(asset.read_bytes()).hexdigest()
            manifest.append(f"{digest}  src/assets/{asset_name}\n")
    if trusted:
        (assets / ".website-assets.synced").write_text("".join(manifest))
    for command in ("git", "curl"):
        path = fake_bin / command
        path.write_text("#!/usr/bin/env bash\nexit 1\n")
        path.chmod(0o755)
    env = {**os.environ, "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}"}
    return scripts / "sync-assets.sh", env


@pytest.mark.parametrize(("trusted", "expected_code"), [(False, 1), (True, 0)])
def test_offline_asset_reuse_requires_synced_provenance(
    tmp_path: Path, trusted: bool, expected_code: int
) -> None:
    script, env = make_offline_asset_tree(tmp_path, trusted=trusted)

    result = subprocess.run(
        ["bash", str(script)], env=env, text=True, capture_output=True, check=False
    )

    assert result.returncode == expected_code
    if not trusted:
        assert "is missing or stale" in result.stderr


def test_fetched_asset_ref_is_authoritative_and_atomic(tmp_path: Path) -> None:
    website = tmp_path / "website"
    scripts = website / "scripts"
    assets = website / "src" / "assets"
    fake_bin = tmp_path / "bin"
    scripts.mkdir(parents=True)
    assets.mkdir(parents=True)
    fake_bin.mkdir()
    shutil.copy2(ROOT / "website" / "scripts" / "sync-assets.sh", scripts)
    originals = {}
    for asset_name in WEBSITE_ASSET_NAMES:
        content = f"original-{asset_name}".encode()
        originals[asset_name] = content
        (assets / asset_name).write_bytes(content)

    git = fake_bin / "git"
    git.write_text(
        "#!/usr/bin/env bash\n"
        "case \"$1\" in\n"
        "  fetch) exit 0 ;;\n"
        "  cat-file)\n"
        "    [[ \"$3\" == \"FETCH_HEAD:guide-worktree.png\" ]] && exit 1\n"
        "    exit 0\n"
        "    ;;\n"
        "  show) printf 'fetched-%s' \"${2#*:}\"; exit 0 ;;\n"
        "esac\n"
        "exit 1\n"
    )
    git.chmod(0o755)
    curl_marker = tmp_path / "curl-called"
    curl = fake_bin / "curl"
    curl.write_text(
        "#!/usr/bin/env bash\n"
        "touch \"$CURL_MARKER\"\n"
        "exit 0\n"
    )
    curl.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        "CURL_MARKER": str(curl_marker),
    }

    result = subprocess.run(
        ["bash", str(scripts / "sync-assets.sh")],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode != 0
    assert "fetched website-assets is incomplete" in result.stderr
    assert not curl_marker.exists()
    assert {
        asset_name: (assets / asset_name).read_bytes()
        for asset_name in WEBSITE_ASSET_NAMES
    } == originals


def test_interrupted_asset_publication_invalidates_generation(
    tmp_path: Path,
) -> None:
    website = tmp_path / "website"
    scripts = website / "scripts"
    assets = website / "src" / "assets"
    fake_bin = tmp_path / "bin"
    scripts.mkdir(parents=True)
    assets.mkdir(parents=True)
    fake_bin.mkdir()
    shutil.copy2(ROOT / "website" / "scripts" / "sync-assets.sh", scripts)

    manifest = []
    for asset_name in WEBSITE_ASSET_NAMES:
        asset = assets / asset_name
        asset.write_bytes(f"original-{asset_name}".encode())
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()
        manifest.append(f"{digest}  src/assets/{asset_name}\n")
    generation = assets / ".website-assets.synced"
    generation.write_text("".join(manifest))

    git = fake_bin / "git"
    git.write_text(
        "#!/usr/bin/env bash\n"
        "case \"$1\" in\n"
        "  fetch|cat-file) exit 0 ;;\n"
        "  show) printf 'fetched-%s' \"${2#*:}\"; exit 0 ;;\n"
        "esac\n"
        "exit 1\n"
    )
    git.chmod(0o755)
    move_count = tmp_path / "move-count"
    move = fake_bin / "mv"
    move.write_text(
        "#!/usr/bin/env bash\n"
        "count=$(cat \"$MOVE_COUNT\" 2>/dev/null || printf 0)\n"
        "count=$((count + 1))\n"
        "printf '%s' \"$count\" > \"$MOVE_COUNT\"\n"
        "[[ \"$count\" -eq 4 ]] && exit 1\n"
        "exec /bin/mv \"$@\"\n"
    )
    move.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        "MOVE_COUNT": str(move_count),
    }

    result = subprocess.run(
        ["bash", str(scripts / "sync-assets.sh")],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode != 0
    assert not generation.exists()
