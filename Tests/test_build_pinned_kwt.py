from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import time
from pathlib import Path

import pytest


def bootstrap_fixture(tmp_path: Path) -> tuple[Path, str, str, Path]:
    repository = tmp_path / "repository"
    repository.mkdir()
    subprocess.run(["git", "init", "-q", repository], check=True)
    subprocess.run(
        ["git", "-C", repository, "config", "user.email", "test@example.com"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", repository, "config", "user.name", "Test"],
        check=True,
    )
    main = repository / "cmd" / "kwt" / "main.go"
    main.parent.mkdir(parents=True)
    main.write_text("package main\nfunc main() {}\n")
    subprocess.run(["git", "-C", repository, "add", "."], check=True)
    subprocess.run(
        ["git", "-C", repository, "commit", "-qm", "fixture"],
        check=True,
    )
    revision = subprocess.run(
        ["git", "-C", repository, "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    main.write_text("package main\nfunc main() { println(\"second\") }\n")
    subprocess.run(["git", "-C", repository, "add", "."], check=True)
    subprocess.run(
        ["git", "-C", repository, "commit", "-qm", "second fixture"],
        check=True,
    )
    second_revision = subprocess.run(
        ["git", "-C", repository, "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_go = fake_bin / "go"
    fake_go.write_text(
        """#!/bin/sh
set -eu
if [ "$#" -eq 2 ] && [ "$1" = "env" ]; then
  case "$2" in
    GOOS) printf 'darwin\\n' ;;
    GOARCH) printf 'arm64\\n' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [ "$#" -eq 3 ] && [ "$1" = "version" ] && [ "$2" = "-m" ]; then
  printf '%s: go1.test\\n' "$3"
  printf '\\tbuild\\tGOOS=darwin\\n'
  printf '\\tbuild\\tGOARCH=arm64\\n'
  exit 0
fi
output=
version=
commit=
revision_time=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -ldflags)
      for value in $2; do
        case "$value" in
          go.kenn.io/kwt/internal/cmd.version=*) version="${value#*=}" ;;
          go.kenn.io/kwt/internal/cmd.commit=*) commit="${value#*=}" ;;
          go.kenn.io/kwt/internal/cmd.revisionTime=*)
            revision_time="${value#*=}"
            ;;
        esac
      done
      shift 2
      ;;
    -o)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
case "${FAKE_KWT_IDENTITY_OMISSION:-}" in
  version) version=dev ;;
  revision) commit=none ;;
  revision_time) revision_time= ;;
esac
cat >"$output" <<EOF
#!/bin/sh
case "\\$*" in
  "--version")
    printf 'kwt version %s\\n' "$version"
    ;;
  "daemon start"|"daemon stop")
    exit 0
    ;;
  "daemon status --json")
    printf '%s\\n' '{"service":"kwt","state":"ready","home":"/tmp/fake-kwt","endpoint":"127.0.0.1:1","pid":1,"version":"$version","revision":"$commit","revision_time":"$revision_time","schema_major":1,"schema_version":"1.6.0","capabilities":[],"started_at":"2026-08-13T18:42:17Z","uptime_seconds":0,"active_work":0,"active_leases":0}'
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$output"
"""
    )
    fake_go.chmod(fake_go.stat().st_mode | stat.S_IXUSR)
    return repository, revision, second_revision, fake_bin


def test_failed_initial_clone_does_not_block_retry(tmp_path: Path) -> None:
    repository, revision, _, fake_bin = bootstrap_fixture(tmp_path)

    source = tmp_path / "source"
    output = tmp_path / "output" / "kwt"
    failed_result = subprocess.run(
        [
            "bash",
            "tools/build_pinned_kwt.sh",
            str(repository),
            "missing-revision",
            str(source),
            str(output),
        ],
        cwd=Path(__file__).parents[1],
        env={**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
    )

    assert failed_result.returncode != 0
    assert not source.exists()

    result = subprocess.run(
        [
            "bash",
            "tools/build_pinned_kwt.sh",
            str(repository),
            revision,
            str(source),
            str(output),
        ],
        cwd=Path(__file__).parents[1],
        env={**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert "cmd/kwt/main.go" in subprocess.run(
        ["git", "-C", source, "ls-files"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    assert (
        subprocess.run(
            ["git", "-C", source, "status", "--porcelain"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        == ""
    )
    assert output.read_text().startswith("#!/bin/sh")


def test_concurrent_initial_bootstraps_serialize_publication(
    tmp_path: Path,
) -> None:
    repository, revision, second_revision, fake_bin = bootstrap_fixture(tmp_path)
    real_git = shutil.which("git")
    assert real_git is not None

    checkout_ready = tmp_path / "checkout-ready"
    checkout_release = tmp_path / "checkout-release"
    checkout_claim = tmp_path / "checkout-claim"
    fake_git = fake_bin / "git"
    fake_git.write_text(
        f"""#!/bin/sh
set -eu
"{real_git}" "$@"
if [ "$#" -ge 3 ] && [ "$1" = "-C" ] && [ "$3" = "checkout" ]; then
  if mkdir "$CHECKOUT_CLAIM" 2>/dev/null; then
    : >"$CHECKOUT_READY"
    while [ ! -e "$CHECKOUT_RELEASE" ]; do
      sleep 0.01
    done
  fi
fi
"""
    )
    fake_git.chmod(fake_git.stat().st_mode | stat.S_IXUSR)

    source = tmp_path / "concurrent-source"
    output = tmp_path / "concurrent-output" / "kwt"
    environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "CHECKOUT_CLAIM": str(checkout_claim),
        "CHECKOUT_READY": str(checkout_ready),
        "CHECKOUT_RELEASE": str(checkout_release),
    }
    command = [
        "bash",
        "tools/build_pinned_kwt.sh",
        str(repository),
        revision,
        str(source),
        str(output),
    ]
    first = subprocess.Popen(
        command,
        cwd=Path(__file__).parents[1],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.monotonic() + 10
    while not checkout_ready.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert checkout_ready.exists()

    command[3] = second_revision
    second = subprocess.Popen(
        command,
        cwd=Path(__file__).parents[1],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    time.sleep(0.1)
    assert second.poll() is None

    checkout_release.touch()
    first_stdout, first_stderr = first.communicate(timeout=10)
    second_stdout, second_stderr = second.communicate(timeout=10)

    assert first.returncode == 0, first_stdout + first_stderr
    assert second.returncode == 0, second_stdout + second_stderr
    assert (
        subprocess.run(
            ["git", "-C", source, "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        == second_revision
    )
    assert (
        subprocess.run(
            ["git", "-C", source, "status", "--porcelain"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        == ""
    )
    assert (
        output.with_suffix(".revision").read_text()
        == f"{second_revision} identity=4"
    )
    assert second_revision in subprocess.run(
        [output, "--version"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def test_reuses_source_checkout_for_multiple_outputs(tmp_path: Path) -> None:
    repository, revision, _, fake_bin = bootstrap_fixture(tmp_path)
    real_git = shutil.which("git")
    assert real_git is not None

    fetch_log = tmp_path / "fetches"
    fake_git = fake_bin / "git"
    fake_git.write_text(
        f"""#!/bin/sh
set -eu
for argument in "$@"; do
  if [ "$argument" = "fetch" ]; then
    printf 'fetch\\n' >>"$GIT_FETCH_LOG"
  fi
done
exec "{real_git}" "$@"
"""
    )
    fake_git.chmod(fake_git.stat().st_mode | stat.S_IXUSR)

    source = tmp_path / "source"
    environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "GIT_FETCH_LOG": str(fetch_log),
    }
    for output_name in ("local-kwt", "variant-kwt"):
        result = subprocess.run(
            [
                "bash",
                "tools/build_pinned_kwt.sh",
                str(repository),
                revision,
                str(source),
                str(tmp_path / output_name),
            ],
            cwd=Path(__file__).parents[1],
            env=environment,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, result.stderr

    assert fetch_log.read_text().splitlines() == ["fetch"]


def test_rebuilds_helper_from_legacy_identity_stamp(tmp_path: Path) -> None:
    repository, revision, _, fake_bin = bootstrap_fixture(tmp_path)
    output = tmp_path / "output" / "kwt"
    output.parent.mkdir()
    stale_helper = (
        "#!/bin/sh\n"
        f"printf 'kwt version {revision}\\n'\n"
        "# missing daemon build identity\n"
    )
    output.write_text(stale_helper)
    output.chmod(output.stat().st_mode | stat.S_IXUSR)
    output.with_suffix(".revision").write_text(revision)

    result = subprocess.run(
        [
            "bash",
            "tools/build_pinned_kwt.sh",
            str(repository),
            revision,
            str(tmp_path / "source"),
            str(output),
        ],
        cwd=Path(__file__).parents[1],
        env={**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert output.read_text() != stale_helper


@pytest.mark.parametrize("targeted", [False, True])
@pytest.mark.parametrize("omission", ["version", "revision", "revision_time"])
def test_rejects_helper_without_complete_daemon_identity(
    tmp_path: Path,
    omission: str,
    targeted: bool,
) -> None:
    repository, revision, _, fake_bin = bootstrap_fixture(tmp_path)
    output = tmp_path / "output" / "kwt"
    command = [
        "bash",
        "tools/build_pinned_kwt.sh",
        str(repository),
        revision,
        str(tmp_path / "source"),
        str(output),
    ]
    if targeted:
        command.extend(["darwin", "arm64"])

    result = subprocess.run(
        command,
        cwd=Path(__file__).parents[1],
        env={
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "FAKE_KWT_IDENTITY_OMISSION": omission,
        },
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert not output.exists()
    assert not output.with_suffix(".revision").exists()


def identity_fixture(
    tmp_path: Path,
    *,
    omit_linux_revision_time: bool = False,
) -> tuple[Path, str]:
    repository = tmp_path / "repository"
    repository.mkdir()
    subprocess.run(["git", "init", "-q", repository], check=True)
    subprocess.run(
        ["git", "-C", repository, "config", "user.email", "test@example.com"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", repository, "config", "user.name", "Test"],
        check=True,
    )
    (repository / "go.mod").write_text("module go.kenn.io/kwt\n\ngo 1.25\n")
    command = repository / "internal" / "cmd" / "root.go"
    command.parent.mkdir(parents=True)
    command.write_text(
        """package cmd

import \"encoding/json\"
import \"os\"

var version = \"dev\"
var commit = \"none\"

func Execute() {
    _ = json.NewEncoder(os.Stdout).Encode(map[string]string{
        \"version\": version,
        \"revision\": commit,
        \"revision_time\": revisionTime,
    })
}
"""
    )
    if omit_linux_revision_time:
        (command.parent / "revision_time_default.go").write_text(
            """//go:build !linux

package cmd

var revisionTime = ""
"""
        )
        (command.parent / "revision_time_linux.go").write_text(
            """//go:build linux

package cmd

const revisionTime = ""
"""
        )
    else:
        (command.parent / "revision_time.go").write_text(
            """package cmd

var revisionTime = ""
"""
        )
    main = repository / "cmd" / "kwt" / "main.go"
    main.parent.mkdir(parents=True)
    main.write_text(
        """package main

import \"go.kenn.io/kwt/internal/cmd\"

func main() { cmd.Execute() }
"""
    )
    subprocess.run(["git", "-C", repository, "add", "."], check=True)
    commit_environment = {
        **os.environ,
        "GIT_AUTHOR_DATE": "2026-08-13T18:42:17Z",
        "GIT_COMMITTER_DATE": "2026-08-13T18:42:17Z",
    }
    subprocess.run(
        ["git", "-C", repository, "commit", "-qm", "fixture"],
        check=True,
        env=commit_environment,
    )
    revision = subprocess.run(
        ["git", "-C", repository, "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return repository, revision


def test_stamps_pinned_source_identity_for_daemon_replacement(
    tmp_path: Path,
) -> None:
    repository, revision = identity_fixture(tmp_path)
    output = tmp_path / "output" / "kwt"

    result = subprocess.run(
        [
            "bash",
            "tools/build_pinned_kwt.sh",
            str(repository),
            revision,
            str(tmp_path / "source"),
            str(output),
        ],
        cwd=Path(__file__).parents[1],
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    identity = json.loads(
        subprocess.run(
            [output, "--version"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    )
    assert identity == {
        "version": revision,
        "revision": revision,
        "revision_time": "2026-08-13T18:42:17Z",
    }


def test_rejects_target_that_omits_an_identity_symbol(tmp_path: Path) -> None:
    repository, revision = identity_fixture(
        tmp_path,
        omit_linux_revision_time=True,
    )
    output = tmp_path / "output" / "kwt"

    result = subprocess.run(
        [
            "bash",
            "tools/build_pinned_kwt.sh",
            str(repository),
            revision,
            str(tmp_path / "source"),
            str(output),
            "linux",
            "arm64",
        ],
        cwd=Path(__file__).parents[1],
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert not output.exists()
    assert not output.with_suffix(".revision").exists()
