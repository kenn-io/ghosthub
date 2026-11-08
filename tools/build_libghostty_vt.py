"""Build the pinned libghostty-vt C library for Rust, including Windows cross builds."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / "Vendor/libghostty-vt.version.json"


def fetch_file(url: str, checksum: str, cache: Path) -> Path:
    archive = cache / url.rsplit("/", 1)[1]
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent": "Ghosthub-build"}
            )
            with (
                urllib.request.urlopen(request, timeout=60) as response,
                temporary.open("wb") as out,
            ):
                shutil.copyfileobj(response, out)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != checksum:
                raise ValueError(f"Checksum mismatch: {archive.name}")
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise ValueError(f"Checksum mismatch: {archive.name}")
    return archive


def fetch_archive(url: str, checksum: str, cache: Path) -> Path:
    archive = fetch_file(url, checksum, cache)
    directory = cache / archive.name.removesuffix(".tar.gz").removesuffix(
        ".tar.xz"
    ).removesuffix(".zip")
    if not directory.exists():
        with tempfile.TemporaryDirectory(dir=cache, prefix="extract-") as staging:
            if archive.suffix == ".zip":
                with zipfile.ZipFile(archive) as bundle:
                    bundle.extractall(staging)
            else:
                with tarfile.open(archive) as bundle:
                    bundle.extractall(staging, filter="data")
            (Path(staging) / directory.name).rename(directory)
    return directory


def install_zig(cache: Path, version: str) -> Path:
    architecture = {
        "amd64": "x86_64",
        "x86_64": "x86_64",
        "arm64": "aarch64",
        "aarch64": "aarch64",
    }[platform.machine().lower()]
    system = {"Windows": "windows", "Linux": "linux", "Darwin": "macos"}[
        platform.system()
    ]
    extension = "zip" if system == "windows" else "tar.xz"
    filename = f"zig-{architecture}-{system}-{version}.{extension}"
    checksums = dict(
        line.split()[::-1]
        for line in (ROOT / ".github/zig.sha256").read_text().splitlines()
    )
    cache.mkdir(parents=True, exist_ok=True)
    prefix = fetch_archive(
        f"https://ziglang.org/download/{version}/{filename}", checksums[filename], cache
    )
    return prefix / ("zig.exe" if system == "windows" else "zig")


def zig_target(target: str) -> str:
    architecture = target.split("-", 1)[0]
    if target in (
        "x86_64-pc-windows-msvc",
        "x86_64-pc-windows-gnu",
        "aarch64-pc-windows-msvc",
    ):
        return f"{architecture}-windows-gnu"
    if target in ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"):
        return f"{architecture}-linux-gnu.2.31"
    raise ValueError(f"Unsupported libghostty-vt target: {target}")


def build(target: str, cache: Path, zig: str) -> Path:
    pin = json.loads(PIN.read_text())
    version = subprocess.check_output([zig, "version"], text=True).strip()
    if version != pin["zig"]:
        raise ValueError(f"libghostty-vt requires Zig {pin['zig']}, found {version}")
    destination = cache / target
    stamp = destination / "ghosthub-build.json"
    identity = {
        **pin,
        "target": target,
        "recipe": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    library = destination / (
        "bin/ghostty-vt.dll" if "windows" in target else "lib/libghostty-vt.a"
    )
    required = [library, destination / "include/ghostty/vt.h"]
    if "windows" in target:
        required.append(destination / "lib/ghostty-vt.lib")
    if (
        stamp.exists()
        and all(path.is_file() for path in required)
        and json.loads(stamp.read_text()) == identity
    ):
        return destination
    cache.mkdir(parents=True, exist_ok=True)
    base = f"https://release.files.ghostty.org/libghostty-vt/{pin['version']}"
    name = f"libghostty-vt-{pin['version']}"
    source = fetch_archive(f"{base}/{name}.tar.gz", pin["source_sha256"], cache)
    dependencies = fetch_archive(
        f"{base}/{name}-deps.tar.gz", pin["dependencies_sha256"], cache
    )
    subprocess.run(
        [
            zig,
            "build",
            "--system",
            str(dependencies),
            "--prefix",
            str(destination),
            "--cache-dir",
            str(cache / f"cache-{target}"),
            "-Doptimize=ReleaseSafe",
            "-Dcpu=baseline",
            f"-Dtarget={zig_target(target)}",
        ],
        cwd=source,
        check=True,
        env={**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(cache / "zig-cache")},
    )
    stamp.write_text(json.dumps(identity, indent=2) + "\n")
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--target", help="Rust target triple; defaults to the rustc host"
    )
    parser.add_argument(
        "--install-zig",
        action="store_true",
        help="Stage checksum-pinned Zig under .build for CI",
    )
    args = parser.parse_args()
    target = args.target
    if target is None:
        version = subprocess.check_output(["rustc", "-vV"], text=True)
        target = next(
            line.removeprefix("host: ")
            for line in version.splitlines()
            if line.startswith("host: ")
        )
    zig = os.environ.get("ZIG", "zig")
    if args.install_zig:
        zig = str(install_zig(ROOT / ".build/zig", json.loads(PIN.read_text())["zig"]))
        if github_path := os.environ.get("GITHUB_PATH"):
            with Path(github_path).open("a", encoding="utf-8") as out:
                out.write(str(Path(zig).parent) + "\n")
    print(build(target, ROOT / ".build/libghostty-vt", zig))


if __name__ == "__main__":
    main()
