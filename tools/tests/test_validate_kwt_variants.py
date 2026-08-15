from __future__ import annotations

import struct
from pathlib import Path

import pytest
from validate_kwt_variants import TARGETS, validate_variant


@pytest.mark.parametrize("target", TARGETS)
def test_variant_validation_accepts_exact_target_and_revision(
    tmp_path: Path,
    target: str,
) -> None:
    revision = "a" * 40
    binary_format, cpu = TARGETS[target]
    if binary_format == "mach-o":
        header = b"\xcf\xfa\xed\xfe" + struct.pack("<I", cpu)
    elif binary_format == "elf":
        header = (
            b"\x7fELF"
            + bytes([2, 1])
            + bytes(12)
            + struct.pack("<H", cpu)
        )
    else:
        header = bytearray(128)
        header[:2] = b"MZ"
        struct.pack_into("<I", header, 0x3C, 64)
        header[64:68] = b"PE\0\0"
        struct.pack_into("<H", header, 68, cpu)
    helper = tmp_path / "kwt"
    helper.write_bytes(header + bytes(32) + revision.encode())

    validate_variant(helper, target, revision)


def test_variant_validation_rejects_wrong_target_or_revision(
    tmp_path: Path,
) -> None:
    revision = "a" * 40
    helper = tmp_path / "kwt"
    helper.write_bytes(
        b"\x7fELF"
        + bytes([2, 1])
        + bytes(12)
        + struct.pack("<H", TARGETS["linux-arm64"][1])
        + bytes(32)
        + ("b" * 40).encode()
    )

    with pytest.raises(ValueError, match="does not match target"):
        validate_variant(helper, "linux-amd64", revision)
    with pytest.raises(ValueError, match="does not contain pinned revision"):
        validate_variant(helper, "linux-arm64", revision)
