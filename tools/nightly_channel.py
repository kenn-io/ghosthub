#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
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
IMMUTABLE_CACHE_CONTROL = "public,max-age=31536000,immutable"
MUTABLE_CACHE_CONTROL = "no-cache"
DMG_CONTENT_TYPE = "application/x-apple-diskimage"
TEXT_CONTENT_TYPE = "text/plain; charset=utf-8"
XML_CONTENT_TYPE = "application/xml"
JSON_CONTENT_TYPE = "application/json"
LATEST_DMG_KEY = "Ghosthub_Nightly_latest_macos_arm64.dmg"


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
        f"{base_path}/builds/{build}/runs/{workflow_run_id}/attempts/"
        f"{workflow_run_attempt}/"
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
        try:
            root = ElementTree.fromstring(data)
        except ElementTree.ParseError as error:
            raise ValueError("appcast is not valid XML") from error
        enclosures = root.findall(".//enclosure")
        if len(enclosures) != 1:
            raise ValueError("appcast must contain exactly one enclosure")
        enclosure = enclosures[0]
        dmg_url = require_https_url("appcast enclosure URL", enclosure.get("url"))
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


class ObjectStore(Protocol):
    def put_file(
        self,
        key: str,
        path: Path,
        cache_control: str,
        content_type: str,
    ) -> None: ...

    def put_bytes(
        self,
        key: str,
        data: bytes,
        cache_control: str,
        content_type: str,
    ) -> None: ...

    def list_keys(self, prefix: str) -> list[str]: ...

    def delete_keys(self, keys: list[str]) -> None: ...


class AwsCliObjectStore:
    def __init__(
        self,
        *,
        bucket: str,
        endpoint_url: str,
        region: str,
    ) -> None:
        self.bucket = require_string("bucket", bucket)
        self.endpoint_url = require_https_url("endpoint_url", endpoint_url)
        self.region = require_string("region", region)

    def base_command(self, operation: str) -> list[str]:
        return [
            "aws",
            "s3api",
            operation,
            "--bucket",
            self.bucket,
        ]

    def common_arguments(self) -> list[str]:
        return [
            "--endpoint-url",
            self.endpoint_url,
            "--region",
            self.region,
            "--no-cli-pager",
        ]

    def put_file(
        self,
        key: str,
        path: Path,
        cache_control: str,
        content_type: str,
    ) -> None:
        command = self.base_command("put-object")
        command.extend(
            [
                "--key",
                key,
                "--body",
                str(path),
                "--content-type",
                content_type,
                "--cache-control",
                cache_control,
                *self.common_arguments(),
            ]
        )
        subprocess.run(command, check=True, text=True, capture_output=True)

    def put_bytes(
        self,
        key: str,
        data: bytes,
        cache_control: str,
        content_type: str,
    ) -> None:
        temp_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(delete=False) as handle:
                handle.write(data)
                temp_path = Path(handle.name)
            self.put_file(key, temp_path, cache_control, content_type)
        finally:
            if temp_path is not None:
                temp_path.unlink(missing_ok=True)

    def list_keys(self, prefix: str) -> list[str]:
        keys: list[str] = []
        continuation_token: str | None = None
        while True:
            command = self.base_command("list-objects-v2")
            command.extend(["--prefix", prefix, "--output", "json"])
            if continuation_token is not None:
                command.extend(["--continuation-token", continuation_token])
            command.extend(self.common_arguments())
            result = subprocess.run(
                command,
                check=True,
                text=True,
                capture_output=True,
            )
            response = json.loads(result.stdout)
            contents = response.get("Contents", [])
            if not isinstance(contents, list):
                raise ValueError("object-store listing has invalid Contents")
            for item in contents:
                if not isinstance(item, dict) or not isinstance(
                    item.get("Key"), str
                ):
                    raise ValueError("object-store listing contains an invalid key")
                keys.append(item["Key"])
            if not response.get("IsTruncated"):
                return keys
            continuation_token = response.get("NextContinuationToken")
            if not isinstance(continuation_token, str) or not continuation_token:
                raise ValueError("object-store listing is missing its continuation token")

    def delete_keys(self, keys: list[str]) -> None:
        for start in range(0, len(keys), 1000):
            batch = keys[start : start + 1000]
            temp_path: Path | None = None
            try:
                with tempfile.NamedTemporaryFile(
                    mode="w",
                    encoding="utf-8",
                    delete=False,
                ) as handle:
                    json.dump(
                        {
                            "Objects": [{"Key": key} for key in batch],
                            "Quiet": True,
                        },
                        handle,
                    )
                    temp_path = Path(handle.name)
                command = self.base_command("delete-objects")
                command.extend(
                    [
                        "--delete",
                        f"file://{temp_path}",
                        "--output",
                        "json",
                        *self.common_arguments(),
                    ]
                )
                result = subprocess.run(
                    command,
                    check=True,
                    text=True,
                    capture_output=True,
                )
                response = (
                    json.loads(result.stdout) if result.stdout.strip() else {}
                )
                if not isinstance(response, dict):
                    raise ValueError("object-store deletion returned invalid JSON")
                errors = response.get("Errors", [])
                if not isinstance(errors, list):
                    raise ValueError("object-store deletion returned invalid Errors")
                if errors:
                    first = errors[0] if isinstance(errors[0], dict) else {}
                    key = first.get("Key", "unknown key")
                    code = first.get("Code", "unknown error")
                    raise ValueError(
                        f"object-store deletion failed for {key}: {code}"
                    )
            finally:
                if temp_path is not None:
                    temp_path.unlink(missing_ok=True)


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
    def immutable_prefix(self) -> str:
        return (
            f"builds/{self.build}/runs/{self.workflow_run_id}/attempts/"
            f"{self.workflow_run_attempt}/"
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
    store: ObjectStore,
    inputs: PublicationInputs,
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
    immutable_dmg_key = f"{inputs.immutable_prefix}{inputs.dmg_name}"
    immutable_digest_key = f"{inputs.immutable_prefix}{inputs.dmg_name}.sha256"
    immutable_sums_key = f"{inputs.immutable_prefix}SHA256SUMS"

    store.put_file(
        immutable_dmg_key,
        inputs.dmg_path,
        IMMUTABLE_CACHE_CONTROL,
        DMG_CONTENT_TYPE,
    )
    store.put_file(
        immutable_digest_key,
        inputs.digest_path,
        IMMUTABLE_CACHE_CONTROL,
        TEXT_CONTENT_TYPE,
    )
    store.put_file(
        immutable_sums_key,
        inputs.sums_path,
        IMMUTABLE_CACHE_CONTROL,
        TEXT_CONTENT_TYPE,
    )
    store.put_file(
        "appcast.xml",
        inputs.appcast_path,
        MUTABLE_CACHE_CONTROL,
        XML_CONTENT_TYPE,
    )
    store.put_file(
        LATEST_DMG_KEY,
        inputs.dmg_path,
        MUTABLE_CACHE_CONTROL,
        DMG_CONTENT_TYPE,
    )
    store.put_bytes(
        "channel.json",
        manifest.to_json(),
        MUTABLE_CACHE_CONTROL,
        JSON_CONTENT_TYPE,
    )
    cleanup_old_builds(store, manifest, retain_builds=30)
    return manifest


def cleanup_old_builds(
    store: ObjectStore,
    manifest: ChannelManifest,
    *,
    retain_builds: int,
) -> None:
    retain_builds = require_positive_integer("retain_builds", retain_builds)
    keys = store.list_keys("builds/")
    valid_keys: dict[int, list[str]] = {}
    unsafe_builds: set[int] = set()
    for key in keys:
        parts = key.split("/")
        if len(parts) < 7 or parts[0] != "builds":
            continue
        if ASCII_NUMBER_RE.fullmatch(parts[1]) is None:
            continue
        build = int(parts[1])
        if (
            parts[2] != "runs"
            or ASCII_NUMBER_RE.fullmatch(parts[3]) is None
            or parts[4] != "attempts"
            or ASCII_NUMBER_RE.fullmatch(parts[5]) is None
            or not parts[6]
        ):
            unsafe_builds.add(build)
            continue
        valid_keys.setdefault(build, []).append(key)

    lower_builds = sorted(
        (build for build in valid_keys if build < manifest.build),
        reverse=True,
    )
    retained_lower = set(lower_builds[: retain_builds - 1])
    deletable = set(lower_builds) - retained_lower - unsafe_builds
    keys_to_delete = sorted(
        key
        for build in deletable
        for key in valid_keys.get(build, [])
    )
    if keys_to_delete:
        store.delete_keys(keys_to_delete)


def public_base_from_channel_url(channel_url: str) -> str:
    parsed = urlparse(require_https_url("channel_url", channel_url))
    if not parsed.path.endswith("/channel.json") or parsed.query or parsed.fragment:
        raise ValueError("channel_url must end with /channel.json")
    base_path = parsed.path[: -len("/channel.json")]
    return urlunparse((parsed.scheme, parsed.netloc, base_path, "", "", ""))


def write_eligibility_outputs(
    path: Path,
    *,
    eligible: bool,
    source_sha: str | None,
    previous_build: int | None,
    build: int,
) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"eligible={str(eligible).lower()}\n")
        handle.write(f"previous_source_sha={source_sha or ''}\n")
        handle.write(
            f"previous_build={previous_build if previous_build is not None else ''}\n"
        )
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
    publish.add_argument("--bucket", required=True)
    publish.add_argument("--endpoint-url", required=True)
    publish.add_argument("--region", required=True)
    publish.add_argument("--source-sha", required=True)
    publish.add_argument("--build", required=True, type=int)
    publish.add_argument("--built-at", required=True)
    publish.add_argument("--workflow-run-id", required=True, type=int)
    publish.add_argument("--workflow-run-attempt", required=True, type=int)
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
                previous_build=(published.build if published else None),
                build=args.build,
            )
            print("Nightly build is eligible." if eligible else "Nightly is current.")
            return 0

        store = AwsCliObjectStore(
            bucket=args.bucket,
            endpoint_url=args.endpoint_url,
            region=args.region,
        )
        inputs = PublicationInputs(
            release_root=args.release_root,
            dmg_name=args.dmg_name,
            public_base_url=args.public_base_url,
            source_sha=args.source_sha,
            build=args.build,
            built_at=args.built_at,
            workflow_run_id=args.workflow_run_id,
            workflow_run_attempt=args.workflow_run_attempt,
        )
        manifest = publish_nightly(store, inputs)
        print(f"Published nightly build {manifest.build}: {manifest.dmg_url}")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Nightly channel failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
