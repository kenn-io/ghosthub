import base64
import hashlib
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError

import pytest

TOOLS_DIR = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS_DIR))

import nightly_channel as nightly  # noqa: E402
from nightly_channel import (  # noqa: E402
    AppcastPointer,
    ChannelManifest,
    PublicationInputs,
    channel_version,
    cleanup_old_releases,
    decide_eligibility,
    fetch_appcast,
    fetch_manifest,
    main as nightly_main,
    publish_nightly,
)


PUBLIC_BASE_URL = "https://github.com/kenn-io/ghosthub-nightly/releases"
SOURCE_99 = "a" * 40
SOURCE_100 = "b" * 40
DIGEST = "c" * 64
ARCHIVE_SIGNATURE = base64.b64encode(
    b"archive-signature".ljust(64, b".")
).decode()
FEED_SIGNATURE = base64.b64encode(
    b"feed-signature".ljust(64, b".")
).decode()


def manifest_data(
    *,
    source_sha: str = SOURCE_99,
    build: int = 99,
    run_id: int = 7,
    attempt: int = 1,
    digest: str = DIGEST,
    channel: str = "nightly",
) -> dict[str, object]:
    return {
        "channel": channel,
        "source_sha": source_sha,
        "build": build,
        "workflow_run_id": run_id,
        "workflow_run_attempt": attempt,
        "built_at": "2026-08-13T08:00:00Z",
        "dmg_url": (
            f"{PUBLIC_BASE_URL}/download/"
            f"nightly-{build}-{run_id}-{attempt}/Ghosthub_Nightly.dmg"
        ),
        "sha256": digest,
    }


def signed_appcast(content: bytes) -> bytes:
    return content + (
        "<!-- sparkle-signatures:\n"
        f"edSignature: {FEED_SIGNATURE}\n"
        f"length: {len(content)}\n"
        "-->\n"
    ).encode()


def appcast_data(
    url: str,
    build: int,
    *,
    include_archive_signature: bool = True,
    include_feed_signature: bool = True,
) -> bytes:
    signature_attribute = (
        f' sparkle:edSignature="{ARCHIVE_SIGNATURE}"'
        if include_archive_signature
        else ""
    )
    content = (
        '<rss xmlns:sparkle="http://www.andymatuschak.org/'
        'xml-namespaces/sparkle"><channel><item>'
        f'<sparkle:version>{build}</sparkle:version><enclosure '
        f'url="{url}"{signature_attribute} />'
        '</item></channel></rss>'
    ).encode()
    if not include_feed_signature:
        return content
    return signed_appcast(content)


def test_manifest_and_appcast_describe_the_published_pointer():
    manifest = ChannelManifest.from_json(
        json.dumps(manifest_data()).encode(),
        PUBLIC_BASE_URL,
    )
    appcast = AppcastPointer.from_xml(
        appcast_data(manifest.dmg_url, manifest.build)
    )

    assert manifest.source_sha == SOURCE_99
    assert manifest.build == 99
    assert appcast.dmg_url == manifest.dmg_url
    assert appcast.build == manifest.build


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("channel", "stable"),
        ("source_sha", "abc123"),
        ("build", 0),
        ("workflow_run_id", "7"),
        ("workflow_run_attempt", 0),
        ("built_at", "2026-08-13"),
        ("dmg_url", "http://nightly-downloads.ghosthub.ai/build.dmg"),
        ("dmg_url", "https://example.test/build.dmg"),
        (
            "dmg_url",
            f"{PUBLIC_BASE_URL}/builds/99/runs/7/attempts/2/wrong.dmg",
        ),
        ("sha256", "not-a-digest"),
    ],
)
def test_manifest_rejects_invalid_published_metadata(field, value):
    data = manifest_data()
    data[field] = value

    with pytest.raises(ValueError, match=field):
        ChannelManifest.from_json(json.dumps(data).encode(), PUBLIC_BASE_URL)


@pytest.mark.parametrize(
    "data",
    [
        signed_appcast(b"not XML"),
        signed_appcast(b"<rss><channel /></rss>"),
        signed_appcast(
            (
                '<rss xmlns:sparkle="http://www.andymatuschak.org/'
                'xml-namespaces/sparkle"><channel><item>'
                '<sparkle:version>1</sparkle:version>'
                '<enclosure url="https://example.test/one.dmg" '
                f'sparkle:edSignature="{ARCHIVE_SIGNATURE}" />'
                '<enclosure url="https://example.test/two.dmg" '
                f'sparkle:edSignature="{ARCHIVE_SIGNATURE}" />'
                "</item></channel></rss>"
            ).encode()
        ),
        signed_appcast(
            (
                '<rss xmlns:sparkle="http://www.andymatuschak.org/'
                'xml-namespaces/sparkle"><channel><item>'
                '<sparkle:version>1</sparkle:version><enclosure '
                'url="http://example.test/build.dmg" '
                f'sparkle:edSignature="{ARCHIVE_SIGNATURE}" />'
                "</item></channel></rss>"
            ).encode()
        ),
        signed_appcast(
            (
                '<rss xmlns:sparkle="http://www.andymatuschak.org/'
                'xml-namespaces/sparkle"><channel><item>'
                '<sparkle:version>zero</sparkle:version><enclosure '
                'url="https://example.test/build.dmg" '
                f'sparkle:edSignature="{ARCHIVE_SIGNATURE}" />'
                "</item></channel></rss>"
            ).encode()
        ),
    ],
)
def test_appcast_rejects_an_unusable_pointer(data):
    with pytest.raises(ValueError):
        AppcastPointer.from_xml(data)


def test_eligibility_skips_only_a_complete_publication():
    published = ChannelManifest.from_json(
        json.dumps(manifest_data()).encode(), PUBLIC_BASE_URL
    )
    matching = AppcastPointer(published.dmg_url, published.build)
    mismatched = AppcastPointer(
        f"{PUBLIC_BASE_URL}/builds/99/runs/7/attempts/2/new.dmg",
        published.build,
    )

    assert decide_eligibility(
        SOURCE_100, 100, None, None, force=False
    )
    assert decide_eligibility(
        SOURCE_100, 100, published, matching, force=False
    )
    assert not decide_eligibility(
        SOURCE_99, 99, published, matching, force=False
    )
    assert decide_eligibility(
        SOURCE_99, 99, published, matching, force=True
    )
    assert decide_eligibility(
        SOURCE_99, 99, published, mismatched, force=False
    )
    assert decide_eligibility(
        SOURCE_99, 99, published, None, force=False
    )


def test_eligibility_rejects_rollback_and_build_identity_conflicts():
    published = ChannelManifest.from_json(
        json.dumps(manifest_data()).encode(), PUBLIC_BASE_URL
    )
    matching = AppcastPointer(published.dmg_url, published.build)

    with pytest.raises(ValueError, match="lower"):
        decide_eligibility(SOURCE_100, 98, published, matching, force=True)
    with pytest.raises(ValueError, match="different source"):
        decide_eligibility(SOURCE_100, 99, published, matching, force=True)
    with pytest.raises(ValueError, match="source_sha"):
        decide_eligibility("abc123", 100, published, matching, force=False)


class Response:
    def __init__(self, data: bytes):
        self.data = data

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self) -> bytes:
        return self.data


def test_fetches_validate_remote_metadata_and_only_tolerate_404():
    manifest_url = f"{PUBLIC_BASE_URL}/latest/download/channel.json"
    appcast_url = f"{PUBLIC_BASE_URL}/latest/download/appcast.xml"
    manifest_bytes = json.dumps(manifest_data()).encode()
    pointer_url = manifest_data()["dmg_url"]

    def opener(url):
        if url == manifest_url:
            return Response(manifest_bytes)
        if url == appcast_url:
            return Response(appcast_data(str(pointer_url), 99))
        raise AssertionError(url)

    assert fetch_manifest(
        manifest_url, PUBLIC_BASE_URL, opener=opener
    ).source_sha == SOURCE_99
    assert fetch_appcast(appcast_url, opener=opener).build == 99

    def not_found(url):
        raise HTTPError(url, 404, "not found", {}, None)

    assert fetch_manifest(
        manifest_url, PUBLIC_BASE_URL, opener=not_found
    ) is None
    assert fetch_appcast(appcast_url, opener=not_found) is None

    def server_error(url):
        raise HTTPError(url, 500, "server error", {}, None)

    with pytest.raises(HTTPError):
        fetch_manifest(manifest_url, PUBLIC_BASE_URL, opener=server_error)

    def transport_error(_url):
        raise URLError("offline")

    with pytest.raises(URLError):
        fetch_appcast(appcast_url, opener=transport_error)


@pytest.mark.parametrize(
    "remote_appcast",
    [
        b"truncated appcast",
        appcast_data(
            str(manifest_data()["dmg_url"]),
            99,
            include_archive_signature=False,
        ),
        appcast_data(
            str(manifest_data()["dmg_url"]),
            99,
            include_feed_signature=False,
        ),
    ],
    ids=["malformed-xml", "missing-archive-signature", "missing-feed-signature"],
)
def test_eligibility_command_repairs_an_incomplete_appcast(
    tmp_path,
    remote_appcast,
):
    manifest_url = f"{PUBLIC_BASE_URL}/latest/download/channel.json"
    appcast_url = f"{PUBLIC_BASE_URL}/latest/download/appcast.xml"
    output_path = tmp_path / "github-output"

    def opener(url):
        if url == manifest_url:
            return Response(json.dumps(manifest_data()).encode())
        if url == appcast_url:
            return Response(remote_appcast)
        raise AssertionError(url)

    exit_code = nightly_main(
        [
            "eligibility",
            "--channel-url",
            manifest_url,
            "--appcast-url",
            appcast_url,
            "--source-sha",
            SOURCE_99,
            "--build",
            "99",
            "--github-output",
            str(output_path),
        ],
        opener=opener,
    )

    assert exit_code == 0
    published = ChannelManifest.from_json(
        json.dumps(manifest_data()).encode(),
        PUBLIC_BASE_URL,
    )
    assert output_path.read_text(encoding="utf-8").splitlines() == [
        "eligible=true",
        f"previous_source_sha={SOURCE_99}",
        f"previous_channel_version={channel_version(published)}",
        "build=99",
    ]


def make_publication(
    tmp_path: Path,
    *,
    source_sha: str = SOURCE_99,
    build: int = 99,
    run_id: int = 7,
    attempt: int = 1,
    expected_manifest: ChannelManifest | None = None,
) -> PublicationInputs:
    release_root = tmp_path / f"release-{run_id}-{attempt}"
    release_root.mkdir()
    dmg_name = "Ghosthub_Nightly.dmg"
    dmg = b"signed notarized dmg"
    digest = hashlib.sha256(dmg).hexdigest()
    (release_root / dmg_name).write_bytes(dmg)
    (release_root / f"{dmg_name}.sha256").write_text(
        f"{digest}  {dmg_name}\n", encoding="utf-8"
    )
    (release_root / "SHA256SUMS").write_text(
        f"{digest}  {dmg_name}\n", encoding="utf-8"
    )
    immutable_url = (
        f"{PUBLIC_BASE_URL}/download/nightly-{build}-{run_id}-{attempt}/"
        f"{dmg_name}"
    )
    (release_root / "appcast.xml").write_bytes(
        appcast_data(immutable_url, build)
    )
    return PublicationInputs(
        release_root=release_root,
        dmg_name=dmg_name,
        public_base_url=PUBLIC_BASE_URL,
        source_sha=source_sha,
        build=build,
        built_at="2026-08-13T08:00:00Z",
        workflow_run_id=run_id,
        workflow_run_attempt=attempt,
        expected_channel_version=channel_version(expected_manifest),
    )


@dataclass
class MemoryRelease:
    tag: str
    draft: bool
    prerelease: bool
    assets: dict[str, bytes]


class MemoryReleaseClient:
    def __init__(self):
        self.releases: dict[str, MemoryRelease] = {}
        self.latest_tag: str | None = None
        self.events: list[tuple[str, str]] = []

    def get_release(self, tag: str):
        return self.releases.get(tag)

    def create_draft(
        self,
        tag: str,
        title: str,
        notes: str,
        assets: list[Path],
    ) -> None:
        assert title
        assert notes
        self.events.append(("create", tag))
        self.releases[tag] = MemoryRelease(
            tag=tag,
            draft=True,
            prerelease=False,
            assets={path.name: path.read_bytes() for path in assets},
        )

    def list_releases(self):
        self.events.append(("list", ""))
        return list(self.releases.values())

    def publish(self, tag: str) -> None:
        self.events.append(("publish", tag))
        self.releases[tag].draft = False
        self.latest_tag = tag

    def delete(self, tag: str) -> None:
        self.events.append(("delete", tag))
        self.releases.pop(tag, None)
        if self.latest_tag == tag:
            self.latest_tag = None


def manifest_opener(*states: ChannelManifest | None):
    remaining = list(states)

    def open_channel(url):
        assert url == f"{PUBLIC_BASE_URL}/latest/download/channel.json"
        if not remaining:
            raise AssertionError("unexpected channel read")
        manifest = remaining.pop(0)
        if manifest is None:
            raise HTTPError(url, 404, "not found", {}, None)
        return Response(manifest.to_json())

    return open_channel


def test_publication_exposes_complete_assets_in_one_release_transition(tmp_path):
    client = MemoryReleaseClient()
    channel_url = f"{PUBLIC_BASE_URL}/latest/download/channel.json"

    def empty_channel(url):
        assert url == channel_url
        raise HTTPError(url, 404, "not found", {}, None)

    inputs = make_publication(tmp_path)
    manifest = publish_nightly(client, inputs, opener=empty_channel)

    assert client.events[-1] == ("publish", inputs.release_tag)
    assert client.latest_tag == inputs.release_tag
    release = client.releases[inputs.release_tag]
    assert set(release.assets) == {
        inputs.dmg_name,
        f"{inputs.dmg_name}.sha256",
        "SHA256SUMS",
        "appcast.xml",
        "channel.json",
        "Ghosthub_Nightly_latest_macos_arm64.dmg",
    }
    assert ChannelManifest.from_json(
        release.assets["channel.json"],
        PUBLIC_BASE_URL,
    ) == manifest
    assert release.assets["Ghosthub_Nightly_latest_macos_arm64.dmg"] == (
        inputs.dmg_path.read_bytes()
    )


def test_failed_draft_upload_removes_the_partial_release(tmp_path):
    class PartialDraftClient(MemoryReleaseClient):
        def create_draft(
            self,
            tag: str,
            title: str,
            notes: str,
            assets: list[Path],
        ) -> None:
            super().create_draft(tag, title, notes, assets)
            raise RuntimeError("injected asset upload failure")

    client = PartialDraftClient()
    inputs = make_publication(tmp_path)

    with pytest.raises(RuntimeError, match="asset upload failure"):
        publish_nightly(client, inputs, opener=manifest_opener(None))

    assert inputs.release_tag not in client.releases


def test_older_retry_is_rejected_before_creating_a_release(tmp_path):
    client = MemoryReleaseClient()
    eligibility = ChannelManifest.from_json(
        json.dumps(manifest_data(build=98, run_id=6)).encode(),
        PUBLIC_BASE_URL,
    )
    current = ChannelManifest.from_json(
        json.dumps(
            manifest_data(source_sha=SOURCE_100, build=100, run_id=8)
        ).encode(),
        PUBLIC_BASE_URL,
    )

    with pytest.raises(ValueError, match="lower than the published build"):
        publish_nightly(
            client,
            make_publication(
                tmp_path,
                build=99,
                attempt=2,
                expected_manifest=eligibility,
            ),
            opener=manifest_opener(current),
        )

    assert client.events == []


def test_same_build_retry_requires_the_eligibility_manifest(tmp_path):
    client = MemoryReleaseClient()
    eligibility = ChannelManifest.from_json(
        json.dumps(manifest_data(run_id=6)).encode(),
        PUBLIC_BASE_URL,
    )
    current = ChannelManifest.from_json(
        json.dumps(manifest_data(run_id=8)).encode(),
        PUBLIC_BASE_URL,
    )

    with pytest.raises(ValueError, match="changed since eligibility"):
        publish_nightly(
            client,
            make_publication(
                tmp_path,
                attempt=2,
                expected_manifest=eligibility,
            ),
            opener=manifest_opener(current),
        )

    assert client.events == []


def test_publish_job_retry_accepts_its_already_completed_release(tmp_path):
    client = MemoryReleaseClient()
    inputs = make_publication(tmp_path)
    digest = hashlib.sha256(inputs.dmg_path.read_bytes()).hexdigest()
    completed = ChannelManifest(
        channel="nightly",
        source_sha=inputs.source_sha,
        build=inputs.build,
        workflow_run_id=inputs.workflow_run_id,
        workflow_run_attempt=inputs.workflow_run_attempt,
        built_at=inputs.built_at,
        dmg_url=inputs.immutable_dmg_url,
        sha256=digest,
    )
    client.releases[inputs.release_tag] = MemoryRelease(
        tag=inputs.release_tag,
        draft=False,
        prerelease=False,
        assets={"channel.json": completed.to_json()},
    )
    client.latest_tag = inputs.release_tag

    result = publish_nightly(
        client,
        inputs,
        opener=manifest_opener(completed),
    )

    assert result == completed
    assert client.latest_tag == inputs.release_tag
    assert client.events == []


def test_channel_change_discards_the_draft_without_changing_latest(tmp_path):
    client = MemoryReleaseClient()
    expected = ChannelManifest.from_json(
        json.dumps(manifest_data(build=98, run_id=6)).encode(),
        PUBLIC_BASE_URL,
    )
    concurrent = ChannelManifest.from_json(
        json.dumps(
            manifest_data(source_sha=SOURCE_100, build=100, run_id=8)
        ).encode(),
        PUBLIC_BASE_URL,
    )
    client.releases["nightly-98-6-1"] = MemoryRelease(
        tag="nightly-98-6-1",
        draft=False,
        prerelease=False,
        assets={"channel.json": expected.to_json()},
    )
    client.latest_tag = "nightly-98-6-1"
    inputs = make_publication(tmp_path, expected_manifest=expected)

    with pytest.raises(ValueError, match="changed during publication"):
        publish_nightly(
            client,
            inputs,
            opener=manifest_opener(expected, concurrent),
        )

    assert client.latest_tag == "nightly-98-6-1"
    assert inputs.release_tag not in client.releases
    assert ("publish", inputs.release_tag) not in client.events


def test_cleanup_retains_all_attempts_for_thirty_builds():
    client = MemoryReleaseClient()
    for build in range(1, 36):
        for attempt in (1, 2):
            tag = f"nightly-{build}-7-{attempt}"
            client.releases[tag] = MemoryRelease(tag, False, False, {})
    client.releases["manual-release"] = MemoryRelease(
        "manual-release", False, False, {}
    )
    client.releases["nightly-3-7-3"] = MemoryRelease(
        "nightly-3-7-3", True, False, {}
    )

    cleanup_old_releases(client, candidate_build=36, retain_builds=30)

    remaining = set(client.releases)
    for build in range(1, 7):
        assert f"nightly-{build}-7-1" not in remaining
        assert f"nightly-{build}-7-2" not in remaining
    for build in range(7, 36):
        assert f"nightly-{build}-7-1" in remaining
        assert f"nightly-{build}-7-2" in remaining
    assert "manual-release" in remaining
    assert "nightly-3-7-3" in remaining


def test_cleanup_failure_discards_the_unpublished_candidate(tmp_path):
    class CleanupFailingClient(MemoryReleaseClient):
        def delete(self, tag: str) -> None:
            if tag == "nightly-1-7-1":
                raise RuntimeError("injected cleanup failure")
            super().delete(tag)

    client = CleanupFailingClient()
    previous = ChannelManifest.from_json(
        json.dumps(manifest_data(build=35, run_id=6)).encode(),
        PUBLIC_BASE_URL,
    )
    for build in range(1, 36):
        tag = f"nightly-{build}-7-1"
        client.releases[tag] = MemoryRelease(tag, False, False, {})
    client.latest_tag = "nightly-35-7-1"
    inputs = make_publication(
        tmp_path,
        build=36,
        expected_manifest=previous,
    )

    with pytest.raises(RuntimeError, match="cleanup failure"):
        publish_nightly(
            client,
            inputs,
            opener=manifest_opener(previous, previous),
        )

    assert client.latest_tag == "nightly-35-7-1"
    assert inputs.release_tag not in client.releases


def test_checksum_mismatch_is_rejected_before_creating_a_draft(tmp_path):
    client = MemoryReleaseClient()
    inputs = make_publication(tmp_path)
    inputs.digest_path.write_text(
        f"{'0' * 64}  {inputs.dmg_name}\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="checksum"):
        publish_nightly(client, inputs, opener=manifest_opener(None))

    assert client.events == []


def test_github_cli_client_handles_release_lifecycle(tmp_path, monkeypatch):
    fake_gh = tmp_path / "gh"
    fake_gh.write_text(
        """#!/bin/sh
case "$*" in
  *releases/tags/missing*)
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  *releases/tags/nightly-1-2-3*)
    printf '%s\n' '{"tag_name":"nightly-1-2-3","draft":true,"prerelease":false}'
    ;;
  *api*--paginate*--slurp*)
    printf '%s\n' '[[{"tag_name":"nightly-1-2-3","draft":true,"prerelease":false},{"tag_name":"stable","draft":false,"prerelease":false}]]'
    ;;
  *)
    exit 0
    ;;
esac
""",
        encoding="utf-8",
    )
    fake_gh.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tmp_path}:{os.environ['PATH']}")
    client = nightly.GitHubCliReleaseClient("kenn-io/ghosthub-nightly")

    assert client.get_release("missing") is None
    assert client.get_release("nightly-1-2-3") == nightly.ReleaseInfo(
        tag="nightly-1-2-3",
        draft=True,
        prerelease=False,
    )
    assert [release.tag for release in client.list_releases()] == [
        "nightly-1-2-3",
        "stable",
    ]
    asset = tmp_path / "asset.txt"
    asset.write_text("artifact", encoding="utf-8")
    client.create_draft(
        "nightly-1-2-3",
        "Nightly",
        "Unsupported nightly",
        [asset],
    )
    client.publish("nightly-1-2-3")
    client.delete("nightly-1-2-3")
