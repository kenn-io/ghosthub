#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import plistlib
import re
import shutil
import sys
from dataclasses import dataclass
from datetime import date
from enum import Enum
from pathlib import Path
from urllib.parse import urlparse

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from libghostty_bootstrap import share_tree_problem
from stage_release_app_bundles import stage_bundles


STABLE_SPARKLE_FEED_URL = (
    "https://github.com/kenn-io/ghosthub/releases/latest/download/appcast.xml"
)
STABLE_SPARKLE_PUBLIC_ED_KEY = "MKL5y44upnEoZrnm3VLLDocsBTD+3DgnH161eEQPhMQ="
FULL_SHA_RE = re.compile(r"[0-9a-f]{40}\Z")


class ReleaseChannel(str, Enum):
    DEVELOPMENT = "development"
    STABLE = "stable"
    NIGHTLY = "nightly"


@dataclass(frozen=True)
class ReleaseMetadata:
    display_name: str
    channel: ReleaseChannel
    development_version: str | None
    feed_url: str | None
    public_key: str | None
    source_revision: str | None


def require_value(field: str, value: str | None) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} is required")
    return value


def reject_present(
    values: dict[str, str | None],
    channel: ReleaseChannel,
) -> None:
    for field, value in values.items():
        if value is not None:
            raise ValueError(f"{field} is not valid for {channel.value}")


def require_https_url(field: str, value: str | None) -> str:
    resolved = require_value(field, value)
    parsed = urlparse(resolved)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError(f"{field} must be an HTTPS URL")
    return resolved


def require_public_key(value: str | None) -> str:
    resolved = require_value("nightly_public_key", value)
    try:
        decoded = base64.b64decode(resolved, validate=True)
    except ValueError as error:
        raise ValueError(
            "nightly_public_key must be valid Base64"
        ) from error
    if len(decoded) != 32:
        raise ValueError("nightly_public_key must decode to 32 bytes")
    return resolved


def require_full_sha(value: str | None) -> str:
    resolved = require_value("source_revision", value)
    if FULL_SHA_RE.fullmatch(resolved) is None:
        raise ValueError("source_revision must be a full lowercase Git SHA")
    return resolved


def resolve_release_metadata(
    *,
    channel: ReleaseChannel,
    display_name: str,
    development_version: str | None,
    nightly_feed_url: str | None,
    nightly_public_key: str | None,
    source_revision: str | None,
    build_date: str | None,
) -> ReleaseMetadata:
    nightly_inputs = {
        "nightly_feed_url": nightly_feed_url,
        "nightly_public_key": nightly_public_key,
        "source_revision": source_revision,
        "build_date": build_date,
    }

    if channel is ReleaseChannel.DEVELOPMENT:
        reject_present(nightly_inputs, channel)
        return ReleaseMetadata(
            display_name, channel, development_version, None, None, None
        )
    if channel is ReleaseChannel.STABLE:
        reject_present(nightly_inputs, channel)
        return ReleaseMetadata(
            display_name,
            channel,
            None,
            STABLE_SPARKLE_FEED_URL,
            STABLE_SPARKLE_PUBLIC_ED_KEY,
            None,
        )

    if development_version is not None:
        raise ValueError("nightly derives its development version")
    feed = require_https_url("nightly_feed_url", nightly_feed_url)
    key = require_public_key(nightly_public_key)
    revision = require_full_sha(source_revision)
    date_value = require_value("build_date", build_date)
    try:
        parsed_date = date.fromisoformat(date_value)
    except ValueError as error:
        raise ValueError("build_date must be an ISO date") from error
    return ReleaseMetadata(
        f"{display_name} Nightly",
        channel,
        f"Nightly · {parsed_date.isoformat()} · {revision[:8]}",
        feed,
        key,
        revision,
    )

# libghostty locates its resources by climbing from the running executable and
# looking for compiled terminfo beside them, so both trees must land directly
# under Contents/Resources with their emitted names. Without `ghostty/themes`
# every `theme = <name>` resolves only against ~/.config/ghostty/themes.
LIBGHOSTTY_RESOURCE_TREES = ("ghostty", "terminfo")


def resolve_libghostty_resource_trees(share_dir: Path) -> dict[str, Path]:
    """Validate the emitted libghostty `share` tree before staging it."""
    problem = share_tree_problem(share_dir)
    if problem is not None:
        raise ValueError(f"libghostty share directory is incomplete: {problem}")
    return {name: share_dir / name for name in LIBGHOSTTY_RESOURCE_TREES}


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
    parser.add_argument(
        "--release-channel",
        required=True,
        choices=[channel.value for channel in ReleaseChannel],
    )
    parser.add_argument("--development-version")
    parser.add_argument("--nightly-feed-url")
    parser.add_argument("--nightly-public-ed-key")
    parser.add_argument("--source-revision")
    parser.add_argument("--build-date")
    parser.add_argument("--min-macos", required=True)
    parser.add_argument("--icon-path", required=True, type=Path)
    parser.add_argument("--app-license-path", required=True, type=Path)
    parser.add_argument("--kwt-binary", required=True, type=Path)
    parser.add_argument("--kwt-variants-dir", required=True, type=Path)
    parser.add_argument("--libghostty-share-dir", required=True, type=Path)
    parser.add_argument(
        "--third-party-licenses-dir", required=True, type=Path
    )
    parser.add_argument("--copyright", required=True)
    parser.add_argument("--kwt-version", required=True)
    parser.add_argument("--kwt-source-revision", required=True)
    parser.add_argument("--remote-kwt-source-revision", required=True)
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
    kwt_variants_dir: Path,
    libghostty_share_dir: Path,
    third_party_licenses_dir: Path,
    copyright: str,
    kwt_version: str,
    kwt_source_revision: str,
    remote_kwt_source_revision: str,
    release_channel: ReleaseChannel,
    development_version: str | None = None,
    nightly_feed_url: str | None = None,
    nightly_public_key: str | None = None,
    source_revision: str | None = None,
    build_date: str | None = None,
) -> Path:
    release_metadata = resolve_release_metadata(
        channel=release_channel,
        display_name=display_name,
        development_version=development_version,
        nightly_feed_url=nightly_feed_url,
        nightly_public_key=nightly_public_key,
        source_revision=source_revision,
        build_date=build_date,
    )
    if not kwt_binary.is_file() or not kwt_binary.stat().st_mode & 0o111:
        raise ValueError(f"kwt binary is missing or not executable: {kwt_binary}")
    remote_targets = (
        "darwin-amd64",
        "darwin-arm64",
        "linux-amd64",
        "linux-arm64",
        "windows-amd64",
        "windows-arm64",
    )
    remote_helpers = {
        target: kwt_variants_dir / target / "kwt"
        for target in remote_targets
    }
    missing_remote_helpers = [
        str(path) for path in remote_helpers.values() if not path.is_file()
    ]
    if missing_remote_helpers:
        raise ValueError(
            "kwt variants directory is incomplete: "
            + ", ".join(missing_remote_helpers)
        )
    libghostty_resource_trees = resolve_libghostty_resource_trees(
        libghostty_share_dir
    )
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

    remote_helpers_dir = resources_dir / "KwtRemote"
    for target, source in remote_helpers.items():
        destination = remote_helpers_dir / target / "kwt"
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        # These are sealed app resources, not code loaded by macOS. Keeping
        # them non-executable avoids treating foreign ELF and Mach-O payloads
        # as nested app code; the remote installer applies mode 0755.
        destination.chmod(0o644)

    for name, source in libghostty_resource_trees.items():
        # tic can emit terminfo aliases as symlinks, so preserve links rather
        # than fanning them out into duplicate sealed resources.
        shutil.copytree(source, resources_dir / name, symlinks=True)

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
        "CFBundleDisplayName": release_metadata.display_name,
        "CFBundleExecutable": app_binary.name,
        "CFBundleIconFile": bundled_icon.name,
        "CFBundleIdentifier": bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": release_metadata.display_name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_version,
        "LSMinimumSystemVersion": min_macos,
        "GhosthubKwtVersion": kwt_version,
        "GhosthubKwtSourceRevision": kwt_source_revision,
        "GhosthubRemoteKwtSourceRevision": remote_kwt_source_revision,
        "GhosthubReleaseChannel": release_metadata.channel.value,
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": copyright,
        "NSPrincipalClass": "NSApplication",
    }
    if release_metadata.development_version is not None:
        plist["GhosthubDevelopmentVersion"] = (
            release_metadata.development_version
        )
    if release_metadata.source_revision is not None:
        plist["GhosthubSourceRevision"] = release_metadata.source_revision
    if (
        release_metadata.feed_url is not None
        and release_metadata.public_key is not None
    ):
        plist.update(
            {
                "SUAllowsAutomaticUpdates": True,
                "SUEnableAutomaticChecks": True,
                "SUFeedURL": release_metadata.feed_url,
                "SUPublicEDKey": release_metadata.public_key,
                "SURequireSignedFeed": True,
                # This exact key is declared by Sparkle 2.9.4 as
                # SUSignedFeedFailureExpirationIntervalKey.
                "SUSignedFeedFailureExpirationInterval": 0,
                "SUVerifyUpdateBeforeExtraction": True,
            }
        )
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
        release_channel=ReleaseChannel(args.release_channel),
        development_version=args.development_version,
        nightly_feed_url=args.nightly_feed_url,
        nightly_public_key=args.nightly_public_ed_key,
        source_revision=args.source_revision,
        build_date=args.build_date,
        min_macos=args.min_macos,
        icon_path=args.icon_path,
        app_license_path=args.app_license_path,
        kwt_binary=args.kwt_binary,
        kwt_variants_dir=args.kwt_variants_dir,
        libghostty_share_dir=args.libghostty_share_dir,
        third_party_licenses_dir=args.third_party_licenses_dir,
        copyright=args.copyright,
        kwt_version=args.kwt_version,
        kwt_source_revision=args.kwt_source_revision,
        remote_kwt_source_revision=args.remote_kwt_source_revision,
    )
    print(app_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
