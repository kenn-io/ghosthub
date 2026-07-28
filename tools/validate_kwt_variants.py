#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path


TARGETS = {
    "darwin-amd64": ("mach-o", 0x01000007),
    "darwin-arm64": ("mach-o", 0x0100000C),
    "linux-amd64": ("elf", 62),
    "linux-arm64": ("elf", 183),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the packaged kwt target matrix."
    )
    parser.add_argument("--variants-dir", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    return parser.parse_args()


def validate_variant(path: Path, target: str, revision: str) -> None:
    if target not in TARGETS:
        raise ValueError(f"unsupported kwt target: {target}")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
        raise ValueError(f"invalid kwt revision: {revision}")
    try:
        contents = path.read_bytes()
    except FileNotFoundError as error:
        raise ValueError(f"kwt variant is missing: {path}") from error

    binary_format, expected_cpu = TARGETS[target]
    if binary_format == "mach-o":
        if len(contents) < 8 or contents[:4] != b"\xcf\xfa\xed\xfe":
            raise ValueError(f"{path} is not a 64-bit little-endian Mach-O")
        actual_cpu = struct.unpack_from("<I", contents, 4)[0]
    else:
        if (
            len(contents) < 20
            or contents[:4] != b"\x7fELF"
            or contents[4] != 2
            or contents[5] != 1
        ):
            raise ValueError(f"{path} is not a 64-bit little-endian ELF")
        actual_cpu = struct.unpack_from("<H", contents, 18)[0]

    if actual_cpu != expected_cpu:
        raise ValueError(f"{path} does not match target {target}")
    if revision.encode("ascii") not in contents:
        raise ValueError(
            f"{path} does not contain pinned revision {revision}"
        )


def validate_variants(variants_dir: Path, revision: str) -> None:
    failures: list[str] = []
    for target in TARGETS:
        try:
            validate_variant(variants_dir / target / "kwt", target, revision)
        except ValueError as error:
            failures.append(str(error))
    if failures:
        raise ValueError("\n".join(failures))


def main() -> int:
    arguments = parse_args()
    try:
        validate_variants(arguments.variants_dir, arguments.revision)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
