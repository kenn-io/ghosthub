import importlib.util
import plistlib
import stat
import sys
from pathlib import Path

import pytest


def load_module():
    repo_root = Path(__file__).resolve().parents[1]
    module_path = repo_root / "tools" / "assemble_app_bundle.py"
    if not module_path.exists():
        pytest.fail(f"Missing expected helper: {module_path}")

    spec = importlib.util.spec_from_file_location(
        "assemble_app_bundle",
        module_path,
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write_bundle(source_bin_dir: Path, name: str, files: dict[str, str]) -> Path:
    bundle_dir = source_bin_dir / name
    bundle_dir.mkdir(parents=True)
    for relative_path, contents in files.items():
        file_path = bundle_dir / relative_path
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(contents, encoding="utf-8")
    return bundle_dir


def make_executable(path: Path, contents: str = "#!/bin/sh\nexit 0\n") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def make_release_inputs(tmp_path: Path) -> tuple[Path, Path, Path]:
    app_license = tmp_path / "Ghosthub-LICENSE"
    app_license.write_text("GNU AGPL version 3", encoding="utf-8")
    kwt_binary = make_executable(tmp_path / "kwt")
    licenses_dir = tmp_path / "Licenses"
    licenses_dir.mkdir()
    kwt_license = licenses_dir / "kwt-Apache-2.0.txt"
    kwt_notice = licenses_dir / "kwt-NOTICE.txt"
    fantastty_license = licenses_dir / "fantastty-MIT.txt"
    ghostty_license = licenses_dir / "ghostty-MIT.txt"
    grdb_license = licenses_dir / "GRDB-MIT.txt"
    inventory = licenses_dir / "THIRD-PARTY-NOTICES.md"
    marked_license = licenses_dir / "Marked-MIT.txt"
    kwt_license.write_text("Apache License 2.0", encoding="utf-8")
    kwt_notice.write_text("Copyright 2026 Kenn Software LLC", encoding="utf-8")
    fantastty_license.write_text("MIT License", encoding="utf-8")
    ghostty_license.write_text("Ghostty MIT License", encoding="utf-8")
    grdb_license.write_text("GRDB MIT License", encoding="utf-8")
    inventory.write_text("# Third-party notices", encoding="utf-8")
    marked_license.write_text("Marked MIT License", encoding="utf-8")
    return app_license, kwt_binary, licenses_dir


def test_release_license_inventory_covers_compiled_dependencies():
    repo_root = Path(__file__).resolve().parents[1]
    licenses_dir = repo_root / "LICENSES"
    required = {
        "THIRD-PARTY-NOTICES.md",
        "ghostty-MIT.txt",
        "GRDB-MIT.txt",
        "Zig-MIT.txt",
        "zlib.txt",
        "libpng.txt",
        "FreeType.txt",
        "FreeType-FTL.txt",
        "FreeType-BDF.txt",
        "FreeType-PCF.txt",
        "FreeType-HarfBuzz-Old-MIT.txt",
        "Oniguruma-BSD.txt",
        "glslang.txt",
        "SPIRV-Cross.txt",
        "Highway-Apache-2.0.txt",
        "Highway-BSD-3-Clause.txt",
        "simdutf-Apache-2.0.txt",
        "simdutf-MIT.txt",
        "utfcpp-BSL-1.0.txt",
        "Wuffs.txt",
        "stb-MIT.txt",
        "Dear-ImGui-MIT.txt",
        "Dear-Bindings.txt",
        "libxev-MIT.txt",
        "z2d-MPL-2.0.txt",
        "z2d-NOTICE.txt",
        "zf-MIT.txt",
        "zig-objc-MIT.txt",
        "uucode-MIT.txt",
        "uucode-Bjoern-Hoehrmann-MIT.txt",
        "Unicode-Data.txt",
        "Symbols-Nerd-Font-MIT.txt",
        "JetBrains-Mono-OFL-1.1.txt",
        "kwt-Apache-2.0.txt",
        "kwt-NOTICE.txt",
        "fantastty-MIT.txt",
        "Marked-MIT.txt",
    }

    missing = required - {path.name for path in licenses_dir.iterdir()}
    assert not missing, f"Missing release license notices: {sorted(missing)}"

    inventory = (licenses_dir / "THIRD-PARTY-NOTICES.md").read_text()
    unlisted = {name for name in required if name != "THIRD-PARTY-NOTICES.md" and name not in inventory}
    assert not unlisted, f"Unlisted release license notices: {sorted(unlisted)}"


def test_assemble_app_bundle_stages_icon_and_binary(tmp_path):
    assemble = load_module()
    source_bin_dir = tmp_path / "bin"
    app_binary = make_executable(source_bin_dir / "Ghosthub")
    app_root = tmp_path / "Ghosthub.app"
    icon_path = tmp_path / "Ghosthub.icns"
    icon_path.write_bytes(b"icns")
    app_license, kwt_binary, licenses_dir = make_release_inputs(
        tmp_path
    )

    write_bundle(
        source_bin_dir,
        "Ghosthub_GhosthubUI.bundle",
        {"Assets/example.txt": "ui"},
    )
    write_bundle(
        source_bin_dir,
        "GRDB_GRDB.bundle",
        {"Info.plist": "grdb"},
    )

    built_root = assemble.assemble_app_bundle(
        source_bin_dir=source_bin_dir,
        app_binary=app_binary,
        app_root=app_root,
        bundle_id="com.ghosthub",
        display_name="Ghosthub",
        version="0.1.0",
        build_version="123",
        min_macos="14.0",
        icon_path=icon_path,
        app_license_path=app_license,
        kwt_binary=kwt_binary,
        third_party_licenses_dir=licenses_dir,
        copyright="Copyright © 2026 Kenn Software LLC. All rights reserved.",
        kwt_version="0.1.0",
        kwt_source_revision="abc123",
    )

    assert built_root == app_root
    assert (app_root / "Contents" / "MacOS" / "Ghosthub").exists()
    bundled_kwt = app_root / "Contents" / "Helpers" / "kwt"
    assert bundled_kwt.exists()
    assert stat.S_IMODE(bundled_kwt.stat().st_mode) == 0o755
    licenses = app_root / "Contents" / "Resources" / "Licenses"
    assert (licenses / "Ghosthub-AGPL-3.0.txt").read_text() == (
        "GNU AGPL version 3"
    )
    assert (licenses / "kwt-Apache-2.0.txt").read_text() == "Apache License 2.0"
    assert (licenses / "kwt-NOTICE.txt").read_text() == (
        "Copyright 2026 Kenn Software LLC"
    )
    assert (licenses / "fantastty-MIT.txt").read_text() == "MIT License"
    assert (licenses / "ghostty-MIT.txt").read_text() == "Ghostty MIT License"
    assert (licenses / "GRDB-MIT.txt").read_text() == "GRDB MIT License"
    assert (licenses / "THIRD-PARTY-NOTICES.md").read_text() == (
        "# Third-party notices"
    )
    assert (licenses / "Marked-MIT.txt").read_text() == "Marked MIT License"
    assert (
        app_root / "Contents" / "Resources" / "Ghosthub.icns"
    ).read_bytes() == b"icns"
    assert {path.name for path in app_root.iterdir()} == {"Contents"}
    assert (
        app_root
        / "Contents"
        / "Resources"
        / "Ghosthub_GhosthubUI.bundle"
        / "Assets"
        / "example.txt"
    ).read_text() == "ui"


def test_info_plist_contains_icon_key_and_bundle_metadata(tmp_path):
    assemble = load_module()
    source_bin_dir = tmp_path / "bin"
    app_binary = make_executable(source_bin_dir / "Ghosthub")
    app_root = tmp_path / "Ghosthub.app"
    icon_path = tmp_path / "Ghosthub.icns"
    icon_path.write_bytes(b"icns")
    app_license, kwt_binary, licenses_dir = make_release_inputs(
        tmp_path
    )

    write_bundle(
        source_bin_dir,
        "Ghosthub_GhosthubUI.bundle",
        {"Assets/example.txt": "ui"},
    )
    write_bundle(
        source_bin_dir,
        "GRDB_GRDB.bundle",
        {"Info.plist": "grdb"},
    )

    assemble.assemble_app_bundle(
        source_bin_dir=source_bin_dir,
        app_binary=app_binary,
        app_root=app_root,
        bundle_id="com.ghosthub",
        display_name="Ghosthub",
        version="0.1.0",
        build_version="123",
        min_macos="14.0",
        icon_path=icon_path,
        app_license_path=app_license,
        kwt_binary=kwt_binary,
        third_party_licenses_dir=licenses_dir,
        copyright="Copyright © 2026 Kenn Software LLC. All rights reserved.",
        kwt_version="0.1.0",
        kwt_source_revision="abc123",
    )

    plist = plistlib.loads(
        (app_root / "Contents" / "Info.plist").read_bytes()
    )
    assert plist["CFBundleIdentifier"] == "com.ghosthub"
    assert plist["CFBundleDisplayName"] == "Ghosthub"
    assert plist["CFBundleExecutable"] == "Ghosthub"
    assert plist["CFBundleShortVersionString"] == "0.1.0"
    assert plist["CFBundleVersion"] == "123"
    assert plist["CFBundleIconFile"] == "Ghosthub.icns"
    assert plist["NSHumanReadableCopyright"] == (
        "Copyright © 2026 Kenn Software LLC. All rights reserved."
    )
    assert plist["GhosthubKwtVersion"] == "0.1.0"
    assert plist["GhosthubKwtSourceRevision"] == "abc123"


def test_assemble_app_bundle_replaces_existing_bundle_contents(tmp_path):
    assemble = load_module()
    source_bin_dir = tmp_path / "bin"
    app_binary = make_executable(source_bin_dir / "Ghosthub")
    app_root = tmp_path / "Ghosthub.app"
    icon_path = tmp_path / "Ghosthub.icns"
    icon_path.write_bytes(b"new-icon")
    app_license, kwt_binary, licenses_dir = make_release_inputs(
        tmp_path
    )

    write_bundle(
        source_bin_dir,
        "Ghosthub_GhosthubUI.bundle",
        {"Assets/example.txt": "ui"},
    )
    write_bundle(
        source_bin_dir,
        "GRDB_GRDB.bundle",
        {"Info.plist": "grdb"},
    )

    stale_dir = app_root / "Contents" / "Resources" / "Stale.bundle"
    stale_dir.mkdir(parents=True, exist_ok=True)
    (stale_dir / "stale").write_text("stale", encoding="utf-8")

    assemble.assemble_app_bundle(
        source_bin_dir=source_bin_dir,
        app_binary=app_binary,
        app_root=app_root,
        bundle_id="com.ghosthub",
        display_name="Ghosthub",
        version="0.1.0",
        build_version="123",
        min_macos="14.0",
        icon_path=icon_path,
        app_license_path=app_license,
        kwt_binary=kwt_binary,
        third_party_licenses_dir=licenses_dir,
        copyright="Copyright © 2026 Kenn Software LLC. All rights reserved.",
        kwt_version="0.1.0",
        kwt_source_revision="abc123",
    )

    assert not stale_dir.exists()
    assert (
        app_root / "Contents" / "Resources" / "Ghosthub.icns"
    ).read_bytes() == b"new-icon"
