#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


TAGGED_DESCRIPTION = re.compile(
    r"^v(?P<version>\d+\.\d+\.\d+)"
    r"-(?P<distance>\d+)-g(?P<revision>[0-9a-f]+)"
    r"(?P<dirty>-dirty)?$"
)
UNTAGGED_DESCRIPTION = re.compile(
    r"^(?P<revision>[0-9a-f]+)(?P<dirty>-dirty)?$"
)


@dataclass(frozen=True)
class BundleVersions:
    short: str
    display: str


def bundle_versions_from_git_describe(description: str) -> BundleVersions:
    description = description.strip()
    tagged = TAGGED_DESCRIPTION.fullmatch(description)
    if tagged:
        if tagged["distance"] == "0" and tagged["dirty"] is None:
            display = tagged["version"]
        else:
            display = description.removeprefix("v")
        return BundleVersions(short=tagged["version"], display=display)

    untagged = UNTAGGED_DESCRIPTION.fullmatch(description)
    if untagged:
        dirty = untagged["dirty"] or ""
        return BundleVersions(
            short="0.0.0",
            display=f"0.0.0-0-g{untagged['revision']}{dirty}",
        )

    raise ValueError(f"unsupported git description: {description}")


def development_versions(repository: Path) -> BundleVersions:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repository),
            "describe",
            "--tags",
            "--match",
            "v[0-9]*.[0-9]*.[0-9]*",
            "--long",
            "--always",
            "--dirty",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return bundle_versions_from_git_describe(result.stdout)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Derive a development app version from the nearest release tag."
    )
    parser.add_argument(
        "--repository",
        type=Path,
        default=Path.cwd(),
    )
    parser.add_argument(
        "--component",
        choices=("short", "display"),
        default="display",
    )
    arguments = parser.parse_args()
    versions = development_versions(arguments.repository)
    print(getattr(versions, arguments.component))


if __name__ == "__main__":
    main()
