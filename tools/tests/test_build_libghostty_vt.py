from __future__ import annotations

import hashlib
import io
import json
import tarfile
from pathlib import Path

import build_libghostty_vt as build
import pytest


def test_download_is_verified_before_extracting_and_bad_cache_is_rejected(
    tmp_path: Path,
) -> None:
    archive = tmp_path / "library.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        entry = tarfile.TarInfo("library/header.h")
        entry.size = 3
        bundle.addfile(entry, io.BytesIO(b"api"))
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    source = build.fetch_archive(
        "https://example.com/library.tar.gz", checksum, tmp_path
    )
    assert (source / "header.h").read_bytes() == b"api"
    archive.write_bytes(b"incomplete download")
    with pytest.raises(ValueError, match="Checksum mismatch"):
        build.fetch_archive("https://example.com/library.tar.gz", checksum, tmp_path)


@pytest.mark.parametrize(
    ("target", "zig_target", "artifact"),
    [
        ("x86_64-unknown-linux-gnu", "x86_64-linux-gnu.2.31", "lib/libghostty-vt.a"),
        ("x86_64-pc-windows-msvc", "x86_64-windows-gnu", "bin/ghostty-vt.dll"),
        ("aarch64-pc-windows-msvc", "aarch64-windows-gnu", "bin/ghostty-vt.dll"),
    ],
)
def test_build_targets_and_reuses_only_complete_matching_artifacts(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    target: str,
    zig_target: str,
    artifact: str,
) -> None:
    pin = json.loads(build.PIN.read_text())
    source, dependencies = tmp_path / "source", tmp_path / "deps"
    source.mkdir()
    dependencies.mkdir()
    monkeypatch.setattr(
        build.subprocess, "check_output", lambda *args, **kwargs: pin["zig"] + "\n"
    )
    monkeypatch.setattr(
        build,
        "fetch_archive",
        lambda url, *args: dependencies if "-deps" in url else source,
    )
    commands: list[list[str]] = []

    def compile_library(command: list[str], **kwargs: object) -> None:
        assert kwargs["cwd"] == source
        assert command[command.index("--system") + 1] == str(dependencies)
        assert f"-Dtarget={zig_target}" in command
        assert "-Dcpu=baseline" in command
        prefix = Path(command[command.index("--prefix") + 1])
        output = prefix / artifact
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(b"library")
        header = prefix / "include/ghostty/vt.h"
        header.parent.mkdir(parents=True, exist_ok=True)
        header.write_bytes(b"header")
        if "windows" in target:
            import_library = prefix / "lib/ghostty-vt.lib"
            import_library.parent.mkdir(parents=True, exist_ok=True)
            import_library.write_bytes(b"import library")
        commands.append(command)

    monkeypatch.setattr(build.subprocess, "run", compile_library)
    result = build.build(target, tmp_path, "zig")
    assert (result / artifact).read_bytes() == b"library"
    build.build(target, tmp_path, "zig")
    assert len(commands) == 1
    (result / "include/ghostty/vt.h").unlink()
    build.build(target, tmp_path, "zig")
    assert len(commands) == 2
    stamp = result / "ghosthub-build.json"
    previous = json.loads(stamp.read_text())
    previous["source_sha256"] = "stale"
    stamp.write_text(json.dumps(previous))
    build.build(target, tmp_path, "zig")
    assert len(commands) == 3


def test_wrong_zig_is_rejected_before_download(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(
        build.subprocess, "check_output", lambda *args, **kwargs: "0.1.0\n"
    )
    with pytest.raises(ValueError, match="requires Zig"):
        build.build("x86_64-unknown-linux-gnu", tmp_path, "zig")
    assert not list(tmp_path.iterdir())
