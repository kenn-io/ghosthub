from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path


def test_failed_initial_clone_does_not_block_retry(tmp_path: Path) -> None:
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

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_go = fake_bin / "go"
    fake_go.write_text(
        """#!/bin/sh
set -eu
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
    assert main.relative_to(repository).as_posix() in subprocess.run(
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
