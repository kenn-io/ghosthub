import argparse
import re
from pathlib import Path


class ChangelogError(ValueError):
    pass


def extract_release_notes(changelog: str, version: str, release_url: str) -> str:
    escaped = re.escape(version)
    exact_heading = re.compile(rf"^## \[{escaped}\] - \d{{4}}-\d{{2}}-\d{{2}}$")
    version_heading = re.compile(rf"^## \[{escaped}\](?:\s|$)")
    lines = changelog.splitlines()
    candidates = [
        index for index, line in enumerate(lines) if version_heading.match(line)
    ]
    if len(candidates) != 1 or not exact_heading.match(lines[candidates[0]]):
        raise ChangelogError(f"expected one dated changelog section for {version}")

    start = candidates[0] + 1
    end = next(
        (
            index
            for index in range(start, len(lines))
            if lines[index].startswith("## ")
        ),
        len(lines),
    )
    body = "\n".join(lines[start:end]).strip()
    if not body:
        raise ChangelogError(f"changelog section for {version} is empty")
    body_lines = body.splitlines()
    if not any(line.startswith("### ") for line in body_lines) or not any(
        line.startswith("- ") for line in body_lines
    ):
        raise ChangelogError(f"changelog section for {version} is malformed")

    return (
        f"# Ghosthub {version}\n\n"
        f"[View this release on GitHub]({release_url})\n\n"
        f"{body}\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--changelog", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--release-url", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    notes = extract_release_notes(
        args.changelog.read_text(encoding="utf-8"),
        args.version,
        args.release_url,
    )
    args.output.write_text(notes, encoding="utf-8")


if __name__ == "__main__":
    main()
