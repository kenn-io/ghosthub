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


def test_matching_cached_build_does_not_require_zig(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    target = "x86_64-unknown-linux-gnu"
    pin = json.loads(build.PIN.read_text())
    prefix = tmp_path / ".build/libghostty-vt" / target
    (prefix / "lib").mkdir(parents=True)
    (prefix / "include/ghostty").mkdir(parents=True)
    (prefix / "lib/libghostty-vt.a").write_bytes(b"library")
    (prefix / "include/ghostty/vt.h").write_bytes(b"header")
    (prefix / "ghosthub-build.json").write_text(
        json.dumps(
            {
                **pin,
                "target": target,
                "recipe": hashlib.sha256(Path(build.__file__).read_bytes()).hexdigest(),
            }
        )
    )

    def fail_if_called(*args: object, **kwargs: object) -> object:
        raise AssertionError(f"unexpected call: {args} {kwargs}")

    monkeypatch.setattr(build, "ROOT", tmp_path)
    monkeypatch.setattr(build, "install_zig", fail_if_called)
    monkeypatch.setattr(build, "fetch_archive", fail_if_called)
    monkeypatch.setattr(build.subprocess, "check_output", fail_if_called)
    monkeypatch.setattr(build.subprocess, "run", fail_if_called)

    assert build.build(target, tmp_path / ".build/libghostty-vt", "zig") == prefix
    build.main(["--target", target, "--install-zig"])
    assert capsys.readouterr().out.strip() == str(prefix)


def test_main_installs_zig_and_rebuilds_when_cached_build_is_stale(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    target = "x86_64-unknown-linux-gnu"
    pin = json.loads(build.PIN.read_text())
    prefix = tmp_path / ".build/libghostty-vt" / target
    (prefix / "lib").mkdir(parents=True)
    (prefix / "include/ghostty").mkdir(parents=True)
    (prefix / "lib/libghostty-vt.a").write_bytes(b"stale")
    (prefix / "include/ghostty/vt.h").write_bytes(b"header")
    (prefix / "ghosthub-build.json").write_text(
        json.dumps({**pin, "target": target, "recipe": "stale"})
    )

    fake_zig = tmp_path / ".build/zig/zig-linux/zig"
    github_path = tmp_path / "github_path"
    installed: list[tuple[Path, str]] = []
    source, dependencies = tmp_path / "source", tmp_path / "deps"
    source.mkdir()
    dependencies.mkdir()

    def fake_install_zig(cache: Path, version: str) -> Path:
        installed.append((cache, version))
        return fake_zig

    def compile_library(command: list[str], **kwargs: object) -> None:
        assert command[0] == str(fake_zig)
        out = Path(command[command.index("--prefix") + 1])
        (out / "lib/libghostty-vt.a").write_bytes(b"fresh")

    monkeypatch.setattr(build, "ROOT", tmp_path)
    monkeypatch.setenv("GITHUB_PATH", str(github_path))
    monkeypatch.setattr(build, "install_zig", fake_install_zig)
    monkeypatch.setattr(
        build,
        "fetch_archive",
        lambda url, *args: dependencies if "-deps" in url else source,
    )
    monkeypatch.setattr(
        build.subprocess, "check_output", lambda *args, **kwargs: pin["zig"] + "\n"
    )
    monkeypatch.setattr(build.subprocess, "run", compile_library)

    build.main(["--target", target, "--install-zig"])
    assert installed == [(tmp_path / ".build/zig", pin["zig"])]
    assert github_path.read_text().strip() == str(fake_zig.parent)
    assert (prefix / "lib/libghostty-vt.a").read_bytes() == b"fresh"
    assert capsys.readouterr().out.strip() == str(prefix)
