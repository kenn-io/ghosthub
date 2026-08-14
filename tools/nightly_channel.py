#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, ContextManager, Protocol
from urllib.error import HTTPError
from urllib.parse import urlparse, urlunparse
from urllib.request import urlopen
from xml.etree import ElementTree


SPARKLE_NAMESPACE = "https://sparkle-project.org/xml-namespaces/sparkle"
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
DIGEST_RE = re.compile(r"[0-9a-f]{64}\Z")
ASCII_NUMBER_RE = re.compile(r"[0-9]+\Z")
LATEST_DMG_KEY = "Ghosthub_Nightly_latest_macos_arm64.dmg"
ABSENT_CHANNEL_VERSION = "absent"
SIGNED_FEED_PREFIX = b"<!-- sparkle-signatures:\n"
SIGNED_FEED_SUFFIX = b"-->"
RELEASE_TAG_RE = re.compile(r"nightly-([0-9]+)-([0-9]+)-([0-9]+)\Z")
REPOSITORY_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")


def require_string(field: str, value: object) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a nonempty string")
    return value


def require_positive_integer(field: str, value: object) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ValueError(f"{field} must be a positive integer")
    return value


def require_sha(field: str, value: object) -> str:
    resolved = require_string(field, value)
    if SHA_RE.fullmatch(resolved) is None:
        raise ValueError(f"{field} must be a full lowercase Git SHA")
    return resolved


def require_digest(field: str, value: object) -> str:
    resolved = require_string(field, value)
    if DIGEST_RE.fullmatch(resolved) is None:
        raise ValueError(f"{field} must be a lowercase SHA-256 digest")
    return resolved


def require_channel_version(value: object) -> str:
    if value == ABSENT_CHANNEL_VERSION:
        return ABSENT_CHANNEL_VERSION
    return require_digest("expected_channel_version", value)


def require_timestamp(field: str, value: object) -> str:
    resolved = require_string(field, value)
    try:
        parsed = datetime.fromisoformat(resolved.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"{field} must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise ValueError(f"{field} must include a timezone")
    return resolved


def require_https_url(field: str, value: object) -> str:
    resolved = require_string(field, value)
    parsed = urlparse(resolved)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError(f"{field} must be an HTTPS URL")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError(f"{field} must not contain credentials")
    return resolved


def require_ed25519_signature(field: str, value: object) -> str:
    resolved = require_string(field, value)
    try:
        decoded = base64.b64decode(resolved, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError(f"{field} must be a base64 Ed25519 signature") from error
    if len(decoded) != 64:
        raise ValueError(f"{field} must be a base64 Ed25519 signature")
    return resolved


def signed_feed_content(data: bytes) -> bytes:
    marker_index = data.rfind(SIGNED_FEED_PREFIX)
    if marker_index < 0:
        raise ValueError("appcast is missing its signed-feed signature")
    marker_end = data.find(SIGNED_FEED_SUFFIX, marker_index)
    if marker_end < 0 or data[marker_end + len(SIGNED_FEED_SUFFIX) :].strip():
        raise ValueError("appcast has an incomplete signed-feed signature")
    try:
        lines = data[
            marker_index + len(SIGNED_FEED_PREFIX) : marker_end
        ].decode("ascii").splitlines()
    except UnicodeDecodeError as error:
        raise ValueError("appcast has an invalid signed-feed signature") from error

    signature: str | None = None
    signed_length: int | None = None
    for line in lines:
        if line.startswith("edSignature: "):
            if signature is not None:
                raise ValueError("appcast has duplicate signed-feed signatures")
            signature = require_ed25519_signature(
                "appcast signed-feed signature",
                line.removeprefix("edSignature: "),
            )
        elif line.startswith("length: "):
            if signed_length is not None:
                raise ValueError("appcast has duplicate signed-feed lengths")
            raw_length = line.removeprefix("length: ")
            if ASCII_NUMBER_RE.fullmatch(raw_length) is None:
                raise ValueError("appcast signed-feed length must be an integer")
            signed_length = int(raw_length)

    content = data[:marker_index]
    if signature is None or signed_length != len(content):
        raise ValueError("appcast has an incomplete signed-feed signature")
    return content


@dataclass(frozen=True)
class ChannelManifest:
    channel: str
    source_sha: str
    build: int
    workflow_run_id: int
    workflow_run_attempt: int
    built_at: str
    dmg_url: str
    sha256: str

    @classmethod
    def from_json(
        cls,
        data: bytes,
        public_base_url: str,
    ) -> ChannelManifest:
        try:
            raw = json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("channel manifest is not valid JSON") from error
        if not isinstance(raw, dict):
            raise ValueError("channel manifest must be a JSON object")
        try:
            channel = raw["channel"]
            source_sha = raw["source_sha"]
            build = raw["build"]
            workflow_run_id = raw["workflow_run_id"]
            workflow_run_attempt = raw["workflow_run_attempt"]
            built_at = raw["built_at"]
            dmg_url = raw["dmg_url"]
            digest = raw["sha256"]
        except KeyError as error:
            raise ValueError(f"channel manifest is missing {error.args[0]}") from error

        if channel != "nightly":
            raise ValueError("channel must be nightly")
        source_sha = require_sha("source_sha", source_sha)
        build = require_positive_integer("build", build)
        workflow_run_id = require_positive_integer(
            "workflow_run_id", workflow_run_id
        )
        workflow_run_attempt = require_positive_integer(
            "workflow_run_attempt", workflow_run_attempt
        )
        built_at = require_timestamp("built_at", built_at)
        dmg_url = require_https_url("dmg_url", dmg_url)
        digest = require_digest("sha256", digest)
        validate_manifest_url(
            dmg_url,
            public_base_url,
            build,
            workflow_run_id,
            workflow_run_attempt,
        )
        return cls(
            channel="nightly",
            source_sha=source_sha,
            build=build,
            workflow_run_id=workflow_run_id,
            workflow_run_attempt=workflow_run_attempt,
            built_at=built_at,
            dmg_url=dmg_url,
            sha256=digest,
        )

    def to_json(self) -> bytes:
        payload = {
            "build": self.build,
            "built_at": self.built_at,
            "channel": self.channel,
            "dmg_url": self.dmg_url,
            "sha256": self.sha256,
            "source_sha": self.source_sha,
            "workflow_run_attempt": self.workflow_run_attempt,
            "workflow_run_id": self.workflow_run_id,
        }
        return (json.dumps(payload, sort_keys=True) + "\n").encode()


def channel_version(manifest: ChannelManifest | None) -> str:
    if manifest is None:
        return ABSENT_CHANNEL_VERSION
    return hashlib.sha256(manifest.to_json()).hexdigest()


def validate_manifest_url(
    dmg_url: str,
    public_base_url: str,
    build: int,
    workflow_run_id: int,
    workflow_run_attempt: int,
) -> None:
    base = urlparse(require_https_url("public_base_url", public_base_url))
    candidate = urlparse(dmg_url)
    if (candidate.scheme, candidate.netloc) != (base.scheme, base.netloc):
        raise ValueError("dmg_url must use the configured public_base_url")
    base_path = base.path.rstrip("/")
    expected_prefix = (
        f"{base_path}/download/"
        f"nightly-{build}-{workflow_run_id}-{workflow_run_attempt}/"
    )
    if (
        not candidate.path.startswith(expected_prefix)
        or candidate.path == expected_prefix
        or candidate.query
        or candidate.fragment
    ):
        raise ValueError("dmg_url must match its build, run, and attempt")


@dataclass(frozen=True)
class AppcastPointer:
    dmg_url: str
    build: int

    @classmethod
    def from_xml(cls, data: bytes) -> AppcastPointer:
        content = signed_feed_content(data)
        try:
            root = ElementTree.fromstring(content)
        except ElementTree.ParseError as error:
            raise ValueError("appcast is not valid XML") from error
        enclosures = root.findall(".//enclosure")
        if len(enclosures) != 1:
            raise ValueError("appcast must contain exactly one enclosure")
        enclosure = enclosures[0]
        dmg_url = require_https_url("appcast enclosure URL", enclosure.get("url"))
        require_ed25519_signature(
            "appcast enclosure signature",
            enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature"),
        )
        raw_build = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}version")
        try:
            build = int(raw_build) if raw_build is not None else 0
        except ValueError as error:
            raise ValueError("appcast sparkle:version must be an integer") from error
        build = require_positive_integer("appcast sparkle:version", build)
        return cls(dmg_url=dmg_url, build=build)


ResponseOpener = Callable[[str], ContextManager[object]]


def fetch_manifest(
    channel_url: str,
    public_base_url: str,
    *,
    opener: ResponseOpener = urlopen,
) -> ChannelManifest | None:
    try:
        with opener(channel_url) as response:
            data = response.read()
    except HTTPError as error:
        if error.code == 404:
            return None
        raise
    if not isinstance(data, bytes):
        raise ValueError("channel manifest response must contain bytes")
    return ChannelManifest.from_json(data, public_base_url)


def fetch_appcast(
    appcast_url: str,
    *,
    opener: ResponseOpener = urlopen,
) -> AppcastPointer | None:
    try:
        with opener(appcast_url) as response:
            data = response.read()
    except HTTPError as error:
        if error.code == 404:
            return None
        raise
    if not isinstance(data, bytes):
        raise ValueError("appcast response must contain bytes")
    return AppcastPointer.from_xml(data)


def decide_eligibility(
    source_sha: str,
    build: int,
    published: ChannelManifest | None,
    appcast: AppcastPointer | None,
    force: bool,
) -> bool:
    source_sha = require_sha("source_sha", source_sha)
    build = require_positive_integer("build", build)
    if published is None:
        return True
    if build < published.build:
        raise ValueError("candidate build is lower than the published build")
    if build == published.build and source_sha != published.source_sha:
        raise ValueError("the published build belongs to a different source")
    if build > published.build:
        return True
    if force:
        return True
    if appcast is None:
        return True
    return (
        appcast.dmg_url != published.dmg_url
        or appcast.build != published.build
    )


@dataclass(frozen=True)
class ReleaseInfo:
    tag: str
    draft: bool
    prerelease: bool


class ReleaseClient(Protocol):
    def get_release(self, tag: str) -> ReleaseInfo | None: ...

    def create_draft(
        self,
        tag: str,
        title: str,
        notes: str,
        assets: list[Path],
    ) -> None: ...

    def list_releases(self) -> list[ReleaseInfo]: ...

    def publish(self, tag: str) -> None: ...

    def delete(self, tag: str) -> None: ...


class GitHubCliReleaseClient:
    def __init__(self, repository: str) -> None:
        self.repository = require_string("repository", repository)
        if REPOSITORY_RE.fullmatch(self.repository) is None:
            raise ValueError("repository must be a GitHub owner/name")

    @staticmethod
    def parse_release(value: object) -> ReleaseInfo:
        if not isinstance(value, dict):
            raise ValueError("GitHub release response must be an object")
        tag = require_string("release tag_name", value.get("tag_name"))
        draft = value.get("draft")
        prerelease = value.get("prerelease")
        if not isinstance(draft, bool) or not isinstance(prerelease, bool):
            raise ValueError("GitHub release response has invalid state")
        return ReleaseInfo(tag=tag, draft=draft, prerelease=prerelease)

    def get_release(self, tag: str) -> ReleaseInfo | None:
        tag = require_string("tag", tag)
        command = [
            "gh",
            "api",
            f"repos/{self.repository}/releases/tags/{tag}",
        ]
        result = subprocess.run(
            command,
            check=False,
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            if "HTTP 404" in result.stderr:
                return None
            raise subprocess.CalledProcessError(
                result.returncode,
                command,
                output=result.stdout,
                stderr=result.stderr,
            )
        return self.parse_release(json.loads(result.stdout))

    def create_draft(
        self,
        tag: str,
        title: str,
        notes: str,
        assets: list[Path],
    ) -> None:
        command = [
            "gh",
            "release",
            "create",
            require_string("tag", tag),
            "--repo",
            self.repository,
            "--draft",
            "--target",
            "main",
            "--title",
            require_string("title", title),
            "--notes",
            require_string("notes", notes),
            *[str(path) for path in assets],
        ]
        subprocess.run(command, check=True, text=True, capture_output=True)

    def list_releases(self) -> list[ReleaseInfo]:
        command = [
            "gh",
            "api",
            "--paginate",
            "--slurp",
            "--method",
            "GET",
            f"repos/{self.repository}/releases",
            "-f",
            "per_page=100",
        ]
        result = subprocess.run(
            command,
            check=True,
            text=True,
            capture_output=True,
        )
        pages = json.loads(result.stdout)
        if not isinstance(pages, list) or any(
            not isinstance(page, list) for page in pages
        ):
            raise ValueError("GitHub release listing must contain pages")
        return [
            self.parse_release(release)
            for page in pages
            for release in page
        ]

    def publish(self, tag: str) -> None:
        command = [
            "gh",
            "release",
            "edit",
            require_string("tag", tag),
            "--repo",
            self.repository,
            "--draft=false",
            "--latest",
        ]
        subprocess.run(command, check=True, text=True, capture_output=True)

    def delete(self, tag: str) -> None:
        command = [
            "gh",
            "release",
            "delete",
            require_string("tag", tag),
            "--repo",
            self.repository,
            "--cleanup-tag",
            "--yes",
        ]
        subprocess.run(command, check=True, text=True, capture_output=True)


@dataclass(frozen=True)
class PublicationInputs:
    release_root: Path
    dmg_name: str
    public_base_url: str
    source_sha: str
    build: int
    built_at: str
    workflow_run_id: int
    workflow_run_attempt: int
    expected_channel_version: str = ABSENT_CHANNEL_VERSION

    def __post_init__(self) -> None:
        if Path(self.dmg_name).name != self.dmg_name or not self.dmg_name.endswith(
            ".dmg"
        ):
            raise ValueError("dmg_name must be a DMG filename")
        require_https_url("public_base_url", self.public_base_url)
        require_sha("source_sha", self.source_sha)
        require_positive_integer("build", self.build)
        require_timestamp("built_at", self.built_at)
        require_positive_integer("workflow_run_id", self.workflow_run_id)
        require_positive_integer(
            "workflow_run_attempt", self.workflow_run_attempt
        )
        require_channel_version(self.expected_channel_version)

    @property
    def dmg_path(self) -> Path:
        return self.release_root / self.dmg_name

    @property
    def digest_path(self) -> Path:
        return self.release_root / f"{self.dmg_name}.sha256"

    @property
    def sums_path(self) -> Path:
        return self.release_root / "SHA256SUMS"

    @property
    def appcast_path(self) -> Path:
        return self.release_root / "appcast.xml"

    @property
    def manifest_path(self) -> Path:
        return self.release_root / "channel.json"

    @property
    def bootstrap_path(self) -> Path:
        return self.release_root / LATEST_DMG_KEY

    @property
    def channel_url(self) -> str:
        return f"{self.public_base_url.rstrip('/')}/latest/download/channel.json"

    @property
    def immutable_prefix(self) -> str:
        return f"download/{self.release_tag}/"

    @property
    def release_tag(self) -> str:
        return (
            f"nightly-{self.build}-{self.workflow_run_id}-"
            f"{self.workflow_run_attempt}"
        )

    @property
    def immutable_dmg_url(self) -> str:
        return f"{self.public_base_url.rstrip('/')}/{self.immutable_prefix}{self.dmg_name}"


def digest_for_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def digest_for_name(path: Path, filename: str) -> str:
    matches: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            continue
        digest, named_file = parts
        if named_file.lstrip("* ") == filename:
            matches.append(digest)
    if len(matches) != 1 or DIGEST_RE.fullmatch(matches[0]) is None:
        raise ValueError(f"{path.name} must contain one valid checksum for {filename}")
    return matches[0]


def publish_nightly(
    client: ReleaseClient,
    inputs: PublicationInputs,
    *,
    opener: ResponseOpener = urlopen,
) -> ChannelManifest:
    for path in (
        inputs.dmg_path,
        inputs.digest_path,
        inputs.sums_path,
        inputs.appcast_path,
    ):
        if not path.is_file():
            raise ValueError(f"publication artifact is missing: {path}")
    digest = digest_for_file(inputs.dmg_path)
    if digest_for_name(inputs.digest_path, inputs.dmg_name) != digest:
        raise ValueError("per-DMG checksum does not match the nightly DMG")
    if digest_for_name(inputs.sums_path, inputs.dmg_name) != digest:
        raise ValueError("SHA256SUMS does not match the nightly DMG")
    appcast = AppcastPointer.from_xml(inputs.appcast_path.read_bytes())
    if appcast.dmg_url != inputs.immutable_dmg_url:
        raise ValueError("appcast does not name the immutable nightly DMG")
    if appcast.build != inputs.build:
        raise ValueError("appcast build does not match the nightly build")

    manifest = ChannelManifest(
        channel="nightly",
        source_sha=inputs.source_sha,
        build=inputs.build,
        workflow_run_id=inputs.workflow_run_id,
        workflow_run_attempt=inputs.workflow_run_attempt,
        built_at=inputs.built_at,
        dmg_url=inputs.immutable_dmg_url,
        sha256=digest,
    )
    published = fetch_manifest(
        inputs.channel_url,
        inputs.public_base_url,
        opener=opener,
    )
    if published is not None:
        if manifest.build < published.build:
            raise ValueError("candidate build is lower than the published build")
        if manifest.build == published.build and (
            manifest.source_sha != published.source_sha
        ):
            raise ValueError("the published build belongs to a different source")

    existing = client.get_release(inputs.release_tag)
    if existing is not None:
        if not existing.draft:
            if published == manifest:
                return manifest
            raise ValueError("nightly release tag is already published")
    if channel_version(published) != inputs.expected_channel_version:
        raise ValueError("nightly channel changed since eligibility")
    if existing is not None:
        client.delete(inputs.release_tag)

    inputs.manifest_path.write_bytes(manifest.to_json())
    shutil.copyfile(inputs.dmg_path, inputs.bootstrap_path)
    assets = [
        inputs.dmg_path,
        inputs.digest_path,
        inputs.sums_path,
        inputs.appcast_path,
        inputs.manifest_path,
        inputs.bootstrap_path,
    ]
    try:
        client.create_draft(
            inputs.release_tag,
            f"Ghosthub Nightly build {inputs.build}",
            (
                "Automated nightly build from "
                f"https://github.com/kenn-io/ghosthub/commit/{inputs.source_sha}. "
                "This build is unsupported and may contain regressions."
            ),
            assets,
        )
        current = fetch_manifest(
            inputs.channel_url,
            inputs.public_base_url,
            opener=opener,
        )
        if channel_version(current) != inputs.expected_channel_version:
            raise ValueError("nightly channel changed during publication")
        cleanup_old_releases(client, inputs.build, retain_builds=30)
        client.publish(inputs.release_tag)
        return manifest
    except Exception:
        candidate = client.get_release(inputs.release_tag)
        if candidate is not None and candidate.draft:
            client.delete(inputs.release_tag)
        raise


def cleanup_old_releases(
    client: ReleaseClient,
    candidate_build: int,
    *,
    retain_builds: int,
) -> None:
    candidate_build = require_positive_integer("candidate_build", candidate_build)
    retain_builds = require_positive_integer("retain_builds", retain_builds)
    by_build: dict[int, list[str]] = {}
    for release in client.list_releases():
        match = RELEASE_TAG_RE.fullmatch(release.tag)
        if release.draft or release.prerelease or match is None:
            continue
        build = int(match.group(1))
        if build >= candidate_build:
            continue
        by_build.setdefault(build, []).append(release.tag)
    retained = set(sorted(by_build, reverse=True)[: retain_builds - 1])
    for build in sorted(set(by_build) - retained):
        for tag in sorted(by_build[build]):
            client.delete(tag)


def public_base_from_channel_url(channel_url: str) -> str:
    parsed = urlparse(require_https_url("channel_url", channel_url))
    suffix = "/latest/download/channel.json"
    if not parsed.path.endswith(suffix) or parsed.query or parsed.fragment:
        raise ValueError(
            "channel_url must end with /latest/download/channel.json"
        )
    base_path = parsed.path[: -len(suffix)]
    return urlunparse((parsed.scheme, parsed.netloc, base_path, "", "", ""))


def write_eligibility_outputs(
    path: Path,
    *,
    eligible: bool,
    source_sha: str | None,
    previous_channel_version: str,
    build: int,
) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"eligible={str(eligible).lower()}\n")
        handle.write(f"previous_source_sha={source_sha or ''}\n")
        handle.write(f"previous_channel_version={previous_channel_version}\n")
        handle.write(f"build={build}\n")


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    eligibility = subparsers.add_parser("eligibility")
    eligibility.add_argument("--channel-url", required=True)
    eligibility.add_argument("--appcast-url", required=True)
    eligibility.add_argument("--source-sha", required=True)
    eligibility.add_argument("--build", required=True, type=int)
    eligibility.add_argument("--github-output", required=True, type=Path)
    eligibility.add_argument("--force", action="store_true")

    publish = subparsers.add_parser("publish")
    publish.add_argument("--release-root", required=True, type=Path)
    publish.add_argument("--dmg-name", required=True)
    publish.add_argument("--public-base-url", required=True)
    publish.add_argument("--release-repository", required=True)
    publish.add_argument("--source-sha", required=True)
    publish.add_argument("--build", required=True, type=int)
    publish.add_argument("--built-at", required=True)
    publish.add_argument("--workflow-run-id", required=True, type=int)
    publish.add_argument("--workflow-run-attempt", required=True, type=int)
    publish.add_argument("--expected-channel-version", required=True)
    return parser


def main(
    argv: list[str] | None = None,
    *,
    opener: ResponseOpener = urlopen,
) -> int:
    args = create_parser().parse_args(argv)
    try:
        if args.command == "eligibility":
            public_base_url = public_base_from_channel_url(args.channel_url)
            published = fetch_manifest(
                args.channel_url,
                public_base_url,
                opener=opener,
            )
            try:
                appcast = fetch_appcast(args.appcast_url, opener=opener)
            except ValueError as error:
                print(
                    f"Nightly appcast is invalid and will be repaired: {error}",
                    file=sys.stderr,
                )
                appcast = None
            eligible = decide_eligibility(
                args.source_sha,
                args.build,
                published,
                appcast,
                args.force,
            )
            write_eligibility_outputs(
                args.github_output,
                eligible=eligible,
                source_sha=(published.source_sha if published else None),
                previous_channel_version=channel_version(published),
                build=args.build,
            )
            print("Nightly build is eligible." if eligible else "Nightly is current.")
            return 0

        client = GitHubCliReleaseClient(args.release_repository)
        inputs = PublicationInputs(
            release_root=args.release_root,
            dmg_name=args.dmg_name,
            public_base_url=args.public_base_url,
            source_sha=args.source_sha,
            build=args.build,
            built_at=args.built_at,
            workflow_run_id=args.workflow_run_id,
            workflow_run_attempt=args.workflow_run_attempt,
            expected_channel_version=args.expected_channel_version,
        )
        manifest = publish_nightly(client, inputs, opener=opener)
        print(f"Published nightly build {manifest.build}: {manifest.dmg_url}")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Nightly channel failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
