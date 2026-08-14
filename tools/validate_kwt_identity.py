#!/usr/bin/env python3

from __future__ import annotations

import argparse
import struct
import subprocess
import sys
from pathlib import Path


IDENTITY_SYMBOLS = {
    "version": "go.kenn.io/kwt/internal/cmd.version",
    "revision": "go.kenn.io/kwt/internal/cmd.commit",
    "revision_time": "go.kenn.io/kwt/internal/cmd.revisionTime",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate identity globals in a cross-compiled kwt helper."
    )
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--revision-time", required=True)
    return parser.parse_args()


def symbol_addresses(path: Path) -> dict[str, int]:
    result = subprocess.run(
        ["go", "tool", "nm", "-size", "-type", path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "symbol table is unavailable"
        raise ValueError(f"could not inspect {path}: {detail}")

    wanted = set(IDENTITY_SYMBOLS.values())
    addresses: dict[str, int] = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[-1] in wanted:
            addresses[fields[-1]] = int(fields[0], 16)
    return addresses


def file_offset(contents: bytes, address: int) -> int:
    if contents.startswith(b"\x7fELF"):
        return elf_file_offset(contents, address)
    if contents.startswith(b"\xcf\xfa\xed\xfe"):
        return macho_file_offset(contents, address)
    if contents.startswith(b"MZ"):
        return pe_file_offset(contents, address)
    raise ValueError("helper is not a supported 64-bit executable")


def elf_file_offset(contents: bytes, address: int) -> int:
    if len(contents) < 64 or contents[4:6] != b"\x02\x01":
        raise ValueError("helper is not a 64-bit little-endian ELF executable")
    program_offset = struct.unpack_from("<Q", contents, 32)[0]
    program_size = struct.unpack_from("<H", contents, 54)[0]
    program_count = struct.unpack_from("<H", contents, 56)[0]
    for index in range(program_count):
        offset = program_offset + index * program_size
        if offset + 56 > len(contents):
            break
        segment_type = struct.unpack_from("<I", contents, offset)[0]
        segment_file_offset = struct.unpack_from("<Q", contents, offset + 8)[0]
        virtual_address = struct.unpack_from("<Q", contents, offset + 16)[0]
        file_size = struct.unpack_from("<Q", contents, offset + 32)[0]
        if (
            segment_type == 1
            and virtual_address <= address < virtual_address + file_size
        ):
            return segment_file_offset + address - virtual_address
    raise ValueError(f"address 0x{address:x} is not backed by the ELF file")


def macho_file_offset(contents: bytes, address: int) -> int:
    if len(contents) < 32:
        raise ValueError("helper has a truncated Mach-O header")
    command_count = struct.unpack_from("<I", contents, 16)[0]
    offset = 32
    for _ in range(command_count):
        if offset + 8 > len(contents):
            break
        command, command_size = struct.unpack_from("<II", contents, offset)
        if command_size < 8 or offset + command_size > len(contents):
            break
        if command == 0x19 and command_size >= 72:
            virtual_address = struct.unpack_from("<Q", contents, offset + 24)[0]
            file_size = struct.unpack_from("<Q", contents, offset + 48)[0]
            segment_file_offset = struct.unpack_from(
                "<Q", contents, offset + 40
            )[0]
            if virtual_address <= address < virtual_address + file_size:
                return segment_file_offset + address - virtual_address
        offset += command_size
    raise ValueError(f"address 0x{address:x} is not backed by the Mach-O file")


def pe_file_offset(contents: bytes, address: int) -> int:
    if len(contents) < 64:
        raise ValueError("helper has a truncated PE header")
    pe_offset = struct.unpack_from("<I", contents, 0x3C)[0]
    if (
        pe_offset + 24 > len(contents)
        or contents[pe_offset : pe_offset + 4] != b"PE\0\0"
    ):
        raise ValueError("helper has an invalid PE header")
    section_count = struct.unpack_from("<H", contents, pe_offset + 6)[0]
    optional_size = struct.unpack_from("<H", contents, pe_offset + 20)[0]
    optional_offset = pe_offset + 24
    if (
        optional_offset + optional_size > len(contents)
        or optional_size < 32
        or struct.unpack_from("<H", contents, optional_offset)[0] != 0x20B
    ):
        raise ValueError("helper is not a 64-bit PE executable")
    image_base = struct.unpack_from("<Q", contents, optional_offset + 24)[0]
    relative_address = address - image_base if address >= image_base else address
    section_offset = optional_offset + optional_size
    for index in range(section_count):
        offset = section_offset + index * 40
        if offset + 40 > len(contents):
            break
        virtual_address = struct.unpack_from("<I", contents, offset + 12)[0]
        raw_size = struct.unpack_from("<I", contents, offset + 16)[0]
        raw_offset = struct.unpack_from("<I", contents, offset + 20)[0]
        if virtual_address <= relative_address < virtual_address + raw_size:
            return raw_offset + relative_address - virtual_address
    raise ValueError(f"address 0x{address:x} is not backed by the PE file")


def go_string(contents: bytes, address: int) -> str:
    header_offset = file_offset(contents, address)
    if header_offset + 16 > len(contents):
        raise ValueError(f"Go string header at 0x{address:x} is truncated")
    data_address, length = struct.unpack_from("<QQ", contents, header_offset)
    if length > 4096:
        raise ValueError(f"Go string at 0x{address:x} has invalid length {length}")
    data_offset = file_offset(contents, data_address)
    if data_offset + length > len(contents):
        raise ValueError(f"Go string data at 0x{data_address:x} is truncated")
    try:
        return contents[data_offset : data_offset + length].decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"Go string at 0x{address:x} is not UTF-8") from error


def validate_identity(path: Path, expected: dict[str, str]) -> None:
    try:
        contents = path.read_bytes()
    except FileNotFoundError as error:
        raise ValueError(f"kwt helper is missing: {path}") from error
    addresses = symbol_addresses(path)
    for field, symbol in IDENTITY_SYMBOLS.items():
        if symbol not in addresses:
            raise ValueError(f"{path} does not contain identity symbol {symbol}")
        actual = go_string(contents, addresses[symbol])
        if actual != expected[field]:
            raise ValueError(
                f"{path} has {field} {actual!r}; expected {expected[field]!r}"
            )


def main() -> int:
    arguments = parse_args()
    try:
        validate_identity(
            arguments.binary,
            {
                "version": arguments.version,
                "revision": arguments.revision,
                "revision_time": arguments.revision_time,
            },
        )
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
