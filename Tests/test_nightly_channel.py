import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError

import pytest

TOOLS_DIR = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS_DIR))

from nightly_channel import (  # noqa: E402
    IMMUTABLE_CACHE_CONTROL,
    MUTABLE_CACHE_CONTROL,
    AppcastPointer,
    ChannelManifest,
    PublicationInputs,
    cleanup_old_builds,
    decide_eligibility,
    fetch_appcast,
    fetch_manifest,
    publish_nightly,
)


PUBLIC_BASE_URL = "https://nightly-downloads.ghosthub.ai"
SOURCE_99 = "a" * 40
SOURCE_100 = "b" * 40
DIGEST = "c" * 64


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
            f"{PUBLIC_BASE_URL}/builds/{build}/runs/{run_id}/attempts/"
            f"{attempt}/Ghosthub_Nightly.dmg"
        ),
        "sha256": digest,
    }


def appcast_data(url: str, build: int) -> bytes:
    return (
        '<rss xmlns:sparkle="https://sparkle-project.org/'
        'xml-namespaces/sparkle"><channel><item><enclosure '
        f'url="{url}" sparkle:version="{build}" />'
        '</item></channel></rss>'
    ).encode()


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
        b"not XML",
        b"<rss><channel /></rss>",
        (
            b'<rss xmlns:sparkle="https://sparkle-project.org/'
            b'xml-namespaces/sparkle"><channel><item>'
            b'<enclosure url="https://example.test/one.dmg" '
            b'sparkle:version="1" /><enclosure '
            b'url="https://example.test/two.dmg" sparkle:version="2" />'
            b"</item></channel></rss>"
        ),
        (
            b'<rss xmlns:sparkle="https://sparkle-project.org/'
            b'xml-namespaces/sparkle"><channel><item><enclosure '
            b'url="http://example.test/build.dmg" sparkle:version="1" />'
            b"</item></channel></rss>"
        ),
        (
            b'<rss xmlns:sparkle="https://sparkle-project.org/'
            b'xml-namespaces/sparkle"><channel><item><enclosure '
            b'url="https://example.test/build.dmg" sparkle:version="zero" />'
            b"</item></channel></rss>"
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
    manifest_url = f"{PUBLIC_BASE_URL}/channel.json"
    appcast_url = f"{PUBLIC_BASE_URL}/appcast.xml"
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


@dataclass(frozen=True)
class Operation:
    kind: str
    key: str
    data: bytes | None
    cache_control: str | None
    content_type: str | None


class MemoryObjectStore:
    def __init__(self, *, fail_at: int | None = None):
        self.objects: dict[str, bytes] = {}
        self.operations: list[Operation] = []
        self.fail_at = fail_at

    def record(self, operation: Operation) -> None:
        if self.fail_at == len(self.operations) + 1:
            raise RuntimeError("injected object-store failure")
        self.operations.append(operation)

    def put_file(
        self,
        key: str,
        path: Path,
        cache_control: str,
        content_type: str,
    ) -> None:
        data = path.read_bytes()
        self.record(Operation("put", key, data, cache_control, content_type))
        self.objects[key] = data

    def put_bytes(
        self,
        key: str,
        data: bytes,
        cache_control: str,
        content_type: str,
    ) -> None:
        self.record(Operation("put", key, data, cache_control, content_type))
        self.objects[key] = data

    def list_keys(self, prefix: str) -> list[str]:
        return sorted(key for key in self.objects if key.startswith(prefix))

    def delete_keys(self, keys: list[str]) -> None:
        self.record(Operation("delete", "\n".join(keys), None, None, None))
        for key in keys:
            self.objects.pop(key, None)


def make_publication(
    tmp_path: Path,
    *,
    source_sha: str = SOURCE_99,
    build: int = 99,
    run_id: int = 7,
    attempt: int = 1,
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
        f"{PUBLIC_BASE_URL}/builds/{build}/runs/{run_id}/attempts/"
        f"{attempt}/{dmg_name}"
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
    )


def test_publication_advances_mutable_pointers_only_after_immutable_objects(
    tmp_path,
):
    store = MemoryObjectStore()

    manifest = publish_nightly(store, make_publication(tmp_path))

    assert [operation.key for operation in store.operations[:6]] == [
        "builds/99/runs/7/attempts/1/Ghosthub_Nightly.dmg",
        "builds/99/runs/7/attempts/1/Ghosthub_Nightly.dmg.sha256",
        "builds/99/runs/7/attempts/1/SHA256SUMS",
        "appcast.xml",
        "Ghosthub_Nightly_latest_macos_arm64.dmg",
        "channel.json",
    ]
    assert all(
        operation.cache_control == IMMUTABLE_CACHE_CONTROL
        for operation in store.operations[:3]
    )
    assert all(
        operation.cache_control == MUTABLE_CACHE_CONTROL
        for operation in store.operations[3:6]
    )
    assert ChannelManifest.from_json(
        store.objects["channel.json"], PUBLIC_BASE_URL
    ) == manifest


def test_failure_before_appcast_leaves_mutable_objects_absent(tmp_path):
    store = MemoryObjectStore(fail_at=3)

    with pytest.raises(RuntimeError, match="injected"):
        publish_nightly(store, make_publication(tmp_path))

    assert "appcast.xml" not in store.objects
    assert "Ghosthub_Nightly_latest_macos_arm64.dmg" not in store.objects
    assert "channel.json" not in store.objects


def test_publication_rejects_a_checksum_mismatch_before_upload(tmp_path):
    store = MemoryObjectStore()
    inputs = make_publication(tmp_path)
    inputs.digest_path.write_text(
        f"{'0' * 64}  {inputs.dmg_name}\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="checksum"):
        publish_nightly(store, inputs)

    assert store.operations == []


def test_partial_recovery_is_eligible_and_retries_at_a_fresh_attempt(tmp_path):
    original = ChannelManifest.from_json(
        json.dumps(manifest_data()).encode(), PUBLIC_BASE_URL
    )
    store = MemoryObjectStore(fail_at=5)
    store.objects["channel.json"] = original.to_json()
    store.objects["appcast.xml"] = appcast_data(original.dmg_url, original.build)
    attempt_two = make_publication(tmp_path, attempt=2)

    with pytest.raises(RuntimeError, match="injected"):
        publish_nightly(store, attempt_two)

    still_published = ChannelManifest.from_json(
        store.objects["channel.json"], PUBLIC_BASE_URL
    )
    advanced_appcast = AppcastPointer.from_xml(store.objects["appcast.xml"])
    assert still_published == original
    assert decide_eligibility(
        SOURCE_99,
        99,
        still_published,
        advanced_appcast,
        force=False,
    )

    store.fail_at = None
    attempt_three = make_publication(tmp_path, attempt=3)
    recovered = publish_nightly(store, attempt_three)

    assert "/attempts/3/" in recovered.dmg_url
    assert "builds/99/runs/7/attempts/2/Ghosthub_Nightly.dmg" in store.objects
    assert "builds/99/runs/7/attempts/3/Ghosthub_Nightly.dmg" in store.objects


def test_cleanup_keeps_all_attempts_for_thirty_numeric_builds():
    store = MemoryObjectStore()
    for build in range(1, 36):
        for attempt in (1, 2):
            key = f"builds/{build}/runs/7/attempts/{attempt}/artifact.dmg"
            store.objects[key] = b"artifact"
    store.objects["builds/36/runs/7/attempts/1/future.dmg"] = b"future"
    invalid_key = "builds/not-a-build/runs/7/attempts/1/artifact.dmg"
    store.objects[invalid_key] = b"do not delete"
    current = ChannelManifest.from_json(
        json.dumps(manifest_data(build=35)).encode(), PUBLIC_BASE_URL
    )

    cleanup_old_builds(store, current, retain_builds=30)

    remaining = set(store.objects)
    assert not any(key.startswith("builds/1/") for key in remaining)
    assert not any(key.startswith("builds/5/") for key in remaining)
    for build in range(6, 36):
        assert f"builds/{build}/runs/7/attempts/1/artifact.dmg" in remaining
        assert f"builds/{build}/runs/7/attempts/2/artifact.dmg" in remaining
    assert "builds/36/runs/7/attempts/1/future.dmg" in remaining
    assert invalid_key in remaining
