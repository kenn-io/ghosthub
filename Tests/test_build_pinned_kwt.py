from __future__ import annotations

import os
import shutil
import stat
import subprocess
import time
from pathlib import Path


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
revision=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -ldflags)
      revision="${2##*=}"
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
printf '#!/bin/sh\\nprintf "kwt version %%s\\\\n" "%s"\\n' "$revision" >"$output"
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
    assert output.with_suffix(".revision").read_text() == second_revision
    assert second_revision in subprocess.run(
        [output, "--version"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
