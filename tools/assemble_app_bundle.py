#!/usr/bin/env python3

from __future__ import annotations

import argparse
import plistlib
import shutil
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from stage_release_app_bundles import stage_bundles


SPARKLE_FEED_URL = (
    "https://github.com/kenn-io/ghosthub/releases/latest/download/appcast.xml"
)
SPARKLE_PUBLIC_ED_KEY = "MKL5y44upnEoZrnm3VLLDocsBTD+3DgnH161eEQPhMQ="


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Assemble a Ghosthub.app bundle with icon, plist, and SwiftPM resources."
    )
    parser.add_argument("--source-bin-dir", required=True, type=Path)
    parser.add_argument("--app-binary", required=True, type=Path)
    parser.add_argument("--app-root", required=True, type=Path)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--display-name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-version", required=True)
    parser.add_argument("--min-macos", required=True)
    parser.add_argument("--icon-path", required=True, type=Path)
    parser.add_argument("--app-license-path", required=True, type=Path)
    parser.add_argument("--kwt-binary", required=True, type=Path)
    parser.add_argument(
        "--third-party-licenses-dir", required=True, type=Path
    )
    parser.add_argument("--copyright", required=True)
    parser.add_argument("--kwt-version", required=True)
    parser.add_argument("--kwt-source-revision", required=True)
    return parser.parse_args()


def assemble_app_bundle(
    *,
    source_bin_dir: Path,
    app_binary: Path,
    app_root: Path,
    bundle_id: str,
    display_name: str,
    version: str,
    build_version: str,
    min_macos: str,
    icon_path: Path,
    app_license_path: Path,
    kwt_binary: Path,
    third_party_licenses_dir: Path,
    copyright: str,
    kwt_version: str,
    kwt_source_revision: str,
) -> Path:
    if not kwt_binary.is_file() or not kwt_binary.stat().st_mode & 0o111:
        raise ValueError(f"kwt binary is missing or not executable: {kwt_binary}")
    third_party_license_paths = sorted(
        path for path in third_party_licenses_dir.iterdir() if path.is_file()
    )
    if not third_party_license_paths:
        raise ValueError(
            "third-party licenses directory contains no files: "
            f"{third_party_licenses_dir}"
        )

    if app_root.exists():
        shutil.rmtree(app_root)

    contents_dir = app_root / "Contents"
    macos_dir = contents_dir / "MacOS"
    resources_dir = contents_dir / "Resources"
    helpers_dir = contents_dir / "Helpers"
    frameworks_dir = contents_dir / "Frameworks"
    licenses_dir = resources_dir / "Licenses"
    macos_dir.mkdir(parents=True, exist_ok=True)
    helpers_dir.mkdir(parents=True, exist_ok=True)
    frameworks_dir.mkdir(parents=True, exist_ok=True)
    licenses_dir.mkdir(parents=True, exist_ok=True)

    bundled_binary = macos_dir / app_binary.name
    shutil.copy2(app_binary, bundled_binary)
    bundled_binary.chmod(app_binary.stat().st_mode)

    bundled_icon = resources_dir / icon_path.name
    shutil.copy2(icon_path, bundled_icon)

    bundled_kwt = helpers_dir / "kwt"
    shutil.copy2(kwt_binary, bundled_kwt)
    bundled_kwt.chmod(0o755)

    sparkle_framework = source_bin_dir / "Sparkle.framework"
    if not sparkle_framework.is_dir():
        raise FileNotFoundError(
            f"missing expected Sparkle framework: {sparkle_framework}"
        )
    shutil.copytree(
        sparkle_framework,
        frameworks_dir / sparkle_framework.name,
        symlinks=True,
    )

    shutil.copy2(app_license_path, licenses_dir / "Ghosthub-AGPL-3.0.txt")
    for license_path in third_party_license_paths:
        shutil.copy2(license_path, licenses_dir / license_path.name)

    plist_path = contents_dir / "Info.plist"
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": display_name,
        "CFBundleExecutable": app_binary.name,
        "CFBundleIconFile": bundled_icon.name,
        "CFBundleIdentifier": bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": display_name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_version,
        "LSMinimumSystemVersion": min_macos,
        "GhosthubKwtVersion": kwt_version,
        "GhosthubKwtSourceRevision": kwt_source_revision,
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": copyright,
        "NSPrincipalClass": "NSApplication",
        "SUAllowsAutomaticUpdates": True,
        "SUEnableAutomaticChecks": True,
        "SUFeedURL": SPARKLE_FEED_URL,
        "SUPublicEDKey": SPARKLE_PUBLIC_ED_KEY,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
    }
    with plist_path.open("wb") as handle:
        plistlib.dump(plist, handle, sort_keys=False)

    stage_bundles(
        source_bin_dir=source_bin_dir,
        resources_dir=resources_dir,
    )
    return app_root


def main() -> int:
    args = parse_args()
    app_root = assemble_app_bundle(
        source_bin_dir=args.source_bin_dir,
        app_binary=args.app_binary,
        app_root=args.app_root,
        bundle_id=args.bundle_id,
        display_name=args.display_name,
        version=args.version,
        build_version=args.build_version,
        min_macos=args.min_macos,
        icon_path=args.icon_path,
        app_license_path=args.app_license_path,
        kwt_binary=args.kwt_binary,
        third_party_licenses_dir=args.third_party_licenses_dir,
        copyright=args.copyright,
        kwt_version=args.kwt_version,
        kwt_source_revision=args.kwt_source_revision,
    )
    print(app_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
