#!/usr/bin/env python3

from __future__ import annotations

import argparse
import shutil
import stat
from pathlib import Path

REQUIRED_BUNDLE_NAMES = frozenset(
    {
        "Ghosthub_GhosthubUI.bundle",
        "GRDB_GRDB.bundle",
    }
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stage SwiftPM resource bundles into a packaged Ghosthub.app."
    )
    parser.add_argument(
        "--source-bin-dir",
        required=True,
        type=Path,
        help="SwiftPM release bin directory that contains *.bundle outputs.",
    )
    parser.add_argument(
        "--resources-dir",
        required=True,
        type=Path,
        help="Ghosthub.app/Contents/Resources directory.",
    )
    return parser.parse_args()


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def stage_bundles(
    source_bin_dir: Path,
    resources_dir: Path,
    required_bundle_names: frozenset[str] = REQUIRED_BUNDLE_NAMES,
) -> list[Path]:
    resources_dir.mkdir(parents=True, exist_ok=True)

    discovered_bundle_paths = sorted(source_bin_dir.glob("*.bundle"))
    discovered_bundle_names = {path.name for path in discovered_bundle_paths}
    missing_bundle_names = sorted(
        required_bundle_names - discovered_bundle_names
    )
    if missing_bundle_names:
        missing = ", ".join(missing_bundle_names)
        raise FileNotFoundError(
            f"missing expected SwiftPM resource bundles in {source_bin_dir}: {missing}"
        )

    staged: list[Path] = []
    for bundle_path in discovered_bundle_paths:
        destination = resources_dir / bundle_path.name
        if destination.exists() or destination.is_symlink():
            remove_path(destination)
        shutil.copytree(bundle_path, destination)
        for copied_path in destination.rglob("*"):
            if not copied_path.is_symlink():
                copied_path.chmod(
                    stat.S_IMODE(copied_path.stat().st_mode) | stat.S_IWUSR
                )
        staged.append(destination)

    return staged


def main() -> int:
    args = parse_args()
    staged = stage_bundles(
        source_bin_dir=args.source_bin_dir,
        resources_dir=args.resources_dir,
    )
    for path in staged:
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
