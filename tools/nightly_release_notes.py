#!/usr/bin/env python3

import argparse
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path


SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
MARKDOWN_SPECIAL_RE = re.compile(r"([\\`*_[\]()#])")


def require_sha(field: str, value: str) -> str:
    if SHA_RE.fullmatch(value) is None:
        raise ValueError(f"{field} must be a full lowercase Git SHA")
    return value


def is_ancestor(repo_path: Path, ancestor: str, descendant: str) -> bool:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repo_path),
            "merge-base",
            "--is-ancestor",
            ancestor,
            descendant,
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    raise ValueError(
        "could not compare nightly source revisions: "
        + result.stderr.strip()
    )


def commit_subjects(
    repo_path: Path,
    revision: str,
    *,
    maximum: int | None = None,
) -> list[str]:
    command = [
        "git",
        "-C",
        str(repo_path),
        "log",
        "--reverse",
        "--format=%h%x09%s",
    ]
    if maximum is not None:
        command.extend(["-n", str(maximum)])
    command.append(revision)
    result = subprocess.run(
        command,
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise ValueError(
            "could not read nightly source commits: " + result.stderr.strip()
        )
    commits = [line for line in result.stdout.splitlines() if line]
    if not commits:
        raise ValueError("nightly source range contains no commits")
    return commits


def escape_markdown(value: str) -> str:
    return MARKDOWN_SPECIAL_RE.sub(r"\\\1", value)


def render_notes(
    repository: str,
    source_sha: str,
    previous_source_sha: str | None,
    built_at: str,
    repo_path: Path,
) -> str:
    require_sha("source_sha", source_sha)
    if previous_source_sha is not None:
        require_sha("previous_source_sha", previous_source_sha)
    try:
        build_time = datetime.fromisoformat(built_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("built_at must be an ISO-8601 timestamp") from error
    if build_time.tzinfo is None:
        raise ValueError("built_at must include a timezone")

    if (
        previous_source_sha is not None
        and previous_source_sha != source_sha
        and is_ancestor(repo_path, previous_source_sha, source_sha)
    ):
        commits = commit_subjects(
            repo_path, f"{previous_source_sha}..{source_sha}"
        )
        link = (
            f"https://github.com/{repository}/compare/"
            f"{previous_source_sha}...{source_sha}"
        )
    else:
        commits = commit_subjects(repo_path, source_sha, maximum=1)
        link = f"https://github.com/{repository}/commit/{source_sha}"

    heading_date = build_time.date().isoformat()
    bullets = "\n".join(
        f"- {escape_markdown(commit)}" for commit in commits
    )
    return (
        f"# Ghosthub Nightly · {heading_date} · {source_sha[:8]}\n\n"
        f"[View source on GitHub]({link})\n\n"
        f"{bullets}\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--previous-source-sha")
    parser.add_argument("--built-at", required=True)
    parser.add_argument("--repo-path", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        notes = render_notes(
            repository=args.repository,
            source_sha=args.source_sha,
            previous_source_sha=args.previous_source_sha,
            built_at=args.built_at,
            repo_path=args.repo_path,
        )
        args.output.write_text(notes, encoding="utf-8")
    except (OSError, ValueError) as error:
        print(f"Could not generate nightly release notes: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
