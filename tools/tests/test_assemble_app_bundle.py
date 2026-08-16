import base64
import importlib.util
import plistlib
import shutil
import stat
import sys
from pathlib import Path

import pytest

COPYRIGHT_NOTICE = (
    "Copyright © 2026 Kenn Software LLC. "
    "Licensed under the GNU AGPL v3.0 or later."
)


def load_module():
    repo_root = Path(__file__).resolve().parents[2]
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


def make_libghostty_share_dir(tmp_path: Path) -> Path:
    share_dir = tmp_path / "libghostty-share"
    themes = share_dir / "ghostty" / "themes"
    themes.mkdir(parents=True)
    (themes / "Catppuccin Macchiato").write_text(
        "background = 24273a\n", encoding="utf-8"
    )
    shell_integration = share_dir / "ghostty" / "shell-integration" / "zsh"
    shell_integration.mkdir(parents=True)
    (shell_integration / "ghostty-integration").write_text(
        "# integration\n", encoding="utf-8"
    )
    terminfo = share_dir / "terminfo" / "78"
    terminfo.mkdir(parents=True)
    (terminfo / "xterm-ghostty").write_bytes(b"terminfo")
    (terminfo / "xterm-ghostty-alias").symlink_to("xterm-ghostty")
    return share_dir


def make_release_inputs(
    tmp_path: Path,
    source_bin_dir: Path,
) -> tuple[Path, Path, Path, Path]:
    app_license = tmp_path / "Ghosthub-LICENSE"
    app_license.write_text("GNU AGPL version 3", encoding="utf-8")
    kwt_binary = make_executable(tmp_path / "kwt")
    kwt_variants_dir = tmp_path / "kwt-variants"
    for target in (
        "darwin-amd64",
        "darwin-arm64",
        "linux-amd64",
        "linux-arm64",
        "windows-amd64",
        "windows-arm64",
    ):
        make_executable(kwt_variants_dir / target / "kwt")
    licenses_dir = tmp_path / "Licenses"
    licenses_dir.mkdir()
    kwt_license = licenses_dir / "kwt-Apache-2.0.txt"
    kwt_notice = licenses_dir / "kwt-NOTICE.txt"
    fantastty_license = licenses_dir / "fantastty-MIT.txt"
    ghostty_license = licenses_dir / "ghostty-MIT.txt"
    grdb_license = licenses_dir / "GRDB-MIT.txt"
    inventory = licenses_dir / "THIRD-PARTY-NOTICES.md"
    marked_license = licenses_dir / "Marked-MIT.txt"
    sparkle_license = licenses_dir / "Sparkle-LICENSE.txt"
    kwt_license.write_text("Apache License 2.0", encoding="utf-8")
    kwt_notice.write_text("Copyright 2026 Kenn Software LLC", encoding="utf-8")
    fantastty_license.write_text("MIT License", encoding="utf-8")
    ghostty_license.write_text("Ghostty MIT License", encoding="utf-8")
    grdb_license.write_text("GRDB MIT License", encoding="utf-8")
    inventory.write_text("# Third-party notices", encoding="utf-8")
    marked_license.write_text("Marked MIT License", encoding="utf-8")
    sparkle_license.write_text("Sparkle licenses", encoding="utf-8")

    sparkle_version = (
        source_bin_dir / "Sparkle.framework" / "Versions" / "B"
    )
    sparkle_binary = make_executable(sparkle_version / "Sparkle")
    current = sparkle_version.parent / "Current"
    current.symlink_to("B")
    (source_bin_dir / "Sparkle.framework" / "Sparkle").symlink_to(
        "Versions/Current/Sparkle"
    )
    assert sparkle_binary.exists()
    return app_license, kwt_binary, kwt_variants_dir, licenses_dir


def test_release_license_inventory_covers_compiled_dependencies():
    repo_root = Path(__file__).resolve().parents[2]
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
        "iTerm2-Color-Schemes-MIT.txt",
        "kwt-Apache-2.0.txt",
        "kwt-NOTICE.txt",
        "fantastty-MIT.txt",
        "Marked-MIT.txt",
        "Sparkle-LICENSE.txt",
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
    app_license, kwt_binary, kwt_variants_dir, licenses_dir = make_release_inputs(
        tmp_path,
        source_bin_dir,
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
        version="0.3.0",
        build_version="123",
        development_version="0.3.0-8-g3c67741-dirty",
        min_macos="14.0",
        icon_path=icon_path,
        app_license_path=app_license,
        kwt_binary=kwt_binary,
        kwt_variants_dir=kwt_variants_dir,
        libghostty_share_dir=make_libghostty_share_dir(tmp_path),
        third_party_licenses_dir=licenses_dir,
        copyright=COPYRIGHT_NOTICE,
        kwt_version="0.1.0",
        kwt_source_revision="abc123",
        remote_kwt_source_revision="def456",
        release_channel=assemble.ReleaseChannel.DEVELOPMENT,
    )

    assert built_root == app_root
    assert (app_root / "Contents" / "MacOS" / "Ghosthub").exists()
    bundled_kwt = app_root / "Contents" / "Helpers" / "kwt"
    assert bundled_kwt.exists()
    assert stat.S_IMODE(bundled_kwt.stat().st_mode) == 0o755
    remote_helpers = app_root / "Contents" / "Resources" / "KwtRemote"
    for target in (
        "darwin-amd64",
        "darwin-arm64",
        "linux-amd64",
        "linux-arm64",
        "windows-amd64",
        "windows-arm64",
    ):
        helper = remote_helpers / target / "kwt"
        assert helper.is_file()
        assert stat.S_IMODE(helper.stat().st_mode) == 0o644
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
    assert (licenses / "Sparkle-LICENSE.txt").read_text() == (
        "Sparkle licenses"
    )
    assert (
        app_root / "Contents" / "Resources" / "Ghosthub.icns"
    ).read_bytes() == b"icns"
    # libghostty finds these by climbing from the bundled executable, so the
    # emitted names and their position under Resources are the contract.
    resources = app_root / "Contents" / "Resources"
    assert (
        resources / "ghostty" / "themes" / "Catppuccin Macchiato"
    ).read_text() == "background = 24273a\n"
    assert (
        resources / "ghostty" / "shell-integration" / "zsh" / "ghostty-integration"
    ).is_file()
    assert (resources / "terminfo" / "78" / "xterm-ghostty").is_file()
    assert (resources / "terminfo" / "78" / "xterm-ghostty-alias").is_symlink()
    assert {path.name for path in app_root.iterdir()} == {"Contents"}
    assert (
        app_root
        / "Contents"
        / "Resources"
        / "Ghosthub_GhosthubUI.bundle"
        / "Assets"
        / "example.txt"
    ).read_text() == "ui"
    sparkle = app_root / "Contents" / "Frameworks" / "Sparkle.framework"
    assert (sparkle / "Sparkle").is_symlink()
    assert (sparkle / "Versions" / "Current").is_symlink()
    assert (sparkle / "Versions" / "B" / "Sparkle").exists()
    plist = plistlib.loads(
        (app_root / "Contents" / "Info.plist").read_bytes()
    )
    update_keys = {
        "SUAllowsAutomaticUpdates",
        "SUEnableAutomaticChecks",
        "SUFeedURL",
        "SUPublicEDKey",
        "SURequireSignedFeed",
        "SUSignedFeedFailureExpirationInterval",
        "SUVerifyUpdateBeforeExtraction",
    }
    assert update_keys.isdisjoint(plist)
    assert plist["CFBundleShortVersionString"] == "0.3.0"
    assert plist["CFBundleVersion"] == "123"
    assert plist["GhosthubDevelopmentVersion"] == (
        "0.3.0-8-g3c67741-dirty"
    )
    assert plist["GhosthubReleaseChannel"] == "development"
    assert plist["GhosthubRemoteKwtSourceRevision"] == "def456"


def test_release_info_plist_contains_update_configuration(tmp_path):
    assemble = load_module()
    source_bin_dir = tmp_path / "bin"
    app_binary = make_executable(source_bin_dir / "Ghosthub")
    app_root = tmp_path / "Ghosthub.app"
    icon_path = tmp_path / "Ghosthub.icns"
    icon_path.write_bytes(b"icns")
    app_license, kwt_binary, kwt_variants_dir, licenses_dir = make_release_inputs(
        tmp_path,
        source_bin_dir,
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
        kwt_variants_dir=kwt_variants_dir,
        libghostty_share_dir=make_libghostty_share_dir(tmp_path),
        third_party_licenses_dir=licenses_dir,
        copyright=COPYRIGHT_NOTICE,
        kwt_version="0.1.0",
        kwt_source_revision="abc123",
        remote_kwt_source_revision="def456",
        release_channel=assemble.ReleaseChannel.STABLE,
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
    assert plist["NSHumanReadableCopyright"] == COPYRIGHT_NOTICE
    privacy_usage_keys = {
        "NSAppleEventsUsageDescription",
        "NSBluetoothAlwaysUsageDescription",
        "NSCalendarsUsageDescription",
        "NSCameraUsageDescription",
        "NSContactsUsageDescription",
        "NSLocalNetworkUsageDescription",
        "NSLocationUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSMotionUsageDescription",
        "NSPhotoLibraryUsageDescription",
        "NSRemindersUsageDescription",
        "NSSpeechRecognitionUsageDescription",
        "NSSystemAdministrationUsageDescription",
    }
    assert privacy_usage_keys <= plist.keys()
    assert plist["NSPhotoLibraryUsageDescription"] == (
        "A program running within Ghosthub would like to access your Photo Library."
    )
    assert all(
        plist[key].startswith("A program running within Ghosthub")
        for key in privacy_usage_keys
    )
    assert plist["GhosthubKwtVersion"] == "0.1.0"
    assert plist["GhosthubKwtSourceRevision"] == "abc123"
    assert plist["GhosthubReleaseChannel"] == "stable"
    assert plist["SUFeedURL"] == assemble.STABLE_SPARKLE_FEED_URL
    assert plist["SUPublicEDKey"] == assemble.STABLE_SPARKLE_PUBLIC_ED_KEY
    assert plist["SUEnableAutomaticChecks"] is True
    assert plist["SUAllowsAutomaticUpdates"] is True
    assert plist["SUVerifyUpdateBeforeExtraction"] is True
    assert plist["SURequireSignedFeed"] is True
    assert plist["SUSignedFeedFailureExpirationInterval"] == 0


def test_nightly_info_plist_uses_nightly_update_configuration(tmp_path):
    assemble = load_module()
    source_bin_dir = tmp_path / "bin"
    app_binary = make_executable(source_bin_dir / "Ghosthub")
    app_root = tmp_path / "Ghosthub.app"
    icon_path = tmp_path / "Ghosthub.icns"
    icon_path.write_bytes(b"icns")
    app_license, kwt_binary, kwt_variants_dir, licenses_dir = make_release_inputs(
        tmp_path,
        source_bin_dir,
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
    nightly_key = base64.b64encode(bytes(range(32))).decode()

    assemble.assemble_app_bundle(
        source_bin_dir=source_bin_dir,
        app_binary=app_binary,
        app_root=app_root,
        bundle_id="com.ghosthub",
        display_name="Ghosthub",
        version="1.2.3",
        build_version="123",
        min_macos="26.0",
        icon_path=icon_path,
        app_license_path=app_license,
        kwt_binary=kwt_binary,
        kwt_variants_dir=kwt_variants_dir,
        libghostty_share_dir=make_libghostty_share_dir(tmp_path),
        third_party_licenses_dir=licenses_dir,
        copyright=COPYRIGHT_NOTICE,
        kwt_version="test",
        kwt_source_revision="a" * 40,
        remote_kwt_source_revision="b" * 40,
        release_channel=assemble.ReleaseChannel.NIGHTLY,
        nightly_feed_url=(
            "https://github.com/kenn-io/ghosthub-nightly/releases/"
            "latest/download/appcast.xml"
        ),
        nightly_public_key=nightly_key,
        source_revision="c" * 40,
        build_date="2026-08-13",
    )

    plist = plistlib.loads(
        (app_root / "Contents" / "Info.plist").read_bytes()
    )
    assert plist["CFBundleIdentifier"] == "com.ghosthub"
    assert plist["CFBundleDisplayName"] == "Ghosthub Nightly"
    assert plist["CFBundleName"] == "Ghosthub Nightly"
    assert plist["CFBundleShortVersionString"] == "1.2.3"
    assert plist["CFBundleVersion"] == "123"
    assert plist["GhosthubReleaseChannel"] == "nightly"
    assert plist["GhosthubSourceRevision"] == "c" * 40
    assert plist["GhosthubDevelopmentVersion"] == (
        "Nightly · 2026-08-13 · cccccccc"
    )
    assert plist["SUFeedURL"] == (
        "https://github.com/kenn-io/ghosthub-nightly/releases/"
        "latest/download/appcast.xml"
    )
    assert plist["SUPublicEDKey"] == nightly_key


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("nightly_feed_url", "http://nightly.example/appcast.xml"),
        ("nightly_public_key", "not-base64"),
        ("source_revision", "abc123"),
        ("build_date", "August 13, 2026"),
        ("nightly_feed_url", None),
        ("nightly_public_key", None),
        ("source_revision", None),
        ("build_date", None),
    ],
)
def test_nightly_metadata_rejects_invalid_inputs(field, value):
    assemble = load_module()
    inputs = {
        "nightly_feed_url": (
            "https://github.com/kenn-io/ghosthub-nightly/releases/"
            "latest/download/appcast.xml"
        ),
        "nightly_public_key": base64.b64encode(bytes(range(32))).decode(),
        "source_revision": "c" * 40,
        "build_date": "2026-08-13",
    }
    inputs[field] = value

    with pytest.raises(ValueError, match=field):
        assemble.resolve_release_metadata(
            channel=assemble.ReleaseChannel.NIGHTLY,
            display_name="Ghosthub",
            development_version=None,
            **inputs,
        )


@pytest.mark.parametrize(
    "channel",
    [
        "development",
        "stable",
    ],
)
@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("nightly_feed_url", "https://nightly.example/appcast.xml"),
        ("nightly_public_key", base64.b64encode(bytes(range(32))).decode()),
        ("source_revision", "c" * 40),
        ("build_date", "2026-08-13"),
    ],
)
def test_non_nightly_metadata_rejects_nightly_inputs(channel, field, value):
    assemble = load_module()
    inputs = {
        "nightly_feed_url": None,
        "nightly_public_key": None,
        "source_revision": None,
        "build_date": None,
    }
    inputs[field] = value

    with pytest.raises(ValueError, match=field):
        assemble.resolve_release_metadata(
            channel=assemble.ReleaseChannel(channel),
            display_name="Ghosthub",
            development_version=None,
            **inputs,
        )


def test_assemble_app_bundle_replaces_existing_bundle_contents(tmp_path):
    assemble = load_module()
    source_bin_dir = tmp_path / "bin"
    app_binary = make_executable(source_bin_dir / "Ghosthub")
    app_root = tmp_path / "Ghosthub.app"
    icon_path = tmp_path / "Ghosthub.icns"
    icon_path.write_bytes(b"new-icon")
    app_license, kwt_binary, kwt_variants_dir, licenses_dir = make_release_inputs(
        tmp_path,
        source_bin_dir,
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
        kwt_variants_dir=kwt_variants_dir,
        libghostty_share_dir=make_libghostty_share_dir(tmp_path),
        third_party_licenses_dir=licenses_dir,
        copyright=COPYRIGHT_NOTICE,
        kwt_version="0.1.0",
        kwt_source_revision="abc123",
        remote_kwt_source_revision="def456",
        release_channel=assemble.ReleaseChannel.DEVELOPMENT,
    )

    assert not stale_dir.exists()
    assert (
        app_root / "Contents" / "Resources" / "Ghosthub.icns"
    ).read_bytes() == b"new-icon"


def remove_theme_corpus(share_dir: Path) -> None:
    shutil.rmtree(share_dir / "ghostty" / "themes")


def empty_theme_corpus(share_dir: Path) -> None:
    for theme in (share_dir / "ghostty" / "themes").iterdir():
        theme.unlink()


def replace_theme_corpus_with_a_file(share_dir: Path) -> None:
    themes = share_dir / "ghostty" / "themes"
    shutil.rmtree(themes)
    themes.write_text("not a directory\n", encoding="utf-8")


def replace_terminfo_sentinel_with_a_directory(share_dir: Path) -> None:
    sentinel = share_dir / "terminfo" / "78" / "xterm-ghostty"
    sentinel.unlink()
    sentinel.mkdir()


@pytest.mark.parametrize(
    "corrupt",
    [
        remove_theme_corpus,
        empty_theme_corpus,
        replace_theme_corpus_with_a_file,
        replace_terminfo_sentinel_with_a_directory,
    ],
)
def test_assemble_app_bundle_rejects_an_unusable_share_dir(tmp_path, corrupt):
    assemble = load_module()
    source_bin_dir = tmp_path / "bin"
    app_binary = make_executable(source_bin_dir / "Ghosthub")
    app_root = tmp_path / "Ghosthub.app"
    icon_path = tmp_path / "Ghosthub.icns"
    icon_path.write_bytes(b"icns")
    app_license, kwt_binary, kwt_variants_dir, licenses_dir = make_release_inputs(
        tmp_path,
        source_bin_dir,
    )
    share_dir = make_libghostty_share_dir(tmp_path)
    corrupt(share_dir)

    with pytest.raises(ValueError, match="libghostty share directory"):
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
            kwt_variants_dir=kwt_variants_dir,
            libghostty_share_dir=share_dir,
            third_party_licenses_dir=licenses_dir,
            copyright=COPYRIGHT_NOTICE,
            kwt_version="0.1.0",
            kwt_source_revision="abc123",
            remote_kwt_source_revision="def456",
            release_channel=assemble.ReleaseChannel.STABLE,
        )

    assert not app_root.exists()
