import json
from collections.abc import Sequence
from pathlib import Path

import pytest
import sandbox_image.apple as apple_module
from sandbox_image.apple import (
    AppleImageIdentity,
    AppleProviderInfo,
    AppleVettingHarness,
    ManagedFixture,
    canonical_report_path,
    clean_managed_fixtures,
    cleanup_fixture,
    require_supported_apple_provider,
)
from sandbox_image.process import CompletedCommand

DIGEST = "sha256:" + "b" * 64


class ResponseRunner:
    def __init__(self, responses: dict[tuple[str, ...], CompletedCommand]) -> None:
        self.responses = responses
        self.calls: list[tuple[str, ...]] = []

    def run(
        self,
        argv: Sequence[str],
        *,
        check: bool = True,
        capture: bool = True,
    ) -> CompletedCommand:
        del check, capture
        call = tuple(argv)
        self.calls.append(call)
        return self.responses.get(call, CompletedCommand(call, 0, "", ""))


def response(argv: tuple[str, ...], stdout: str) -> CompletedCommand:
    return CompletedCommand(argv, 0, stdout, "")


def provider_responses(
    *, system: str = "Darwin", architecture: str = "arm64", version: str = "1.2.2"
) -> dict[tuple[str, ...], CompletedCommand]:
    values = {
        ("uname", "-s"): system + "\n",
        ("uname", "-m"): architecture + "\n",
        ("sw_vers", "-productVersion"): "26.0\n",
        (
            "container",
            "--version",
        ): f"container CLI version {version} (build: release)\n",
    }
    return {argv: response(argv, stdout) for argv, stdout in values.items()}


@pytest.mark.parametrize(
    ("system", "architecture", "version"),
    [
        ("Linux", "arm64", "1.2.2"),
        ("Darwin", "x86_64", "1.2.2"),
        ("Darwin", "arm64", "1.2.3"),
        ("Darwin", "arm64", "1.2.2-beta"),
        ("Darwin", "arm64", "1.2.2.1"),
    ],
)
def test_provider_rejects_unsupported_host_before_create(
    system: str, architecture: str, version: str
) -> None:
    runner = ResponseRunner(
        provider_responses(system=system, architecture=architecture, version=version)
    )
    with pytest.raises(ValueError):
        require_supported_apple_provider(runner)
    assert not any(call[:2] == ("container", "create") for call in runner.calls)


def test_fixture_identity_is_persisted_before_create(tmp_path: Path) -> None:
    state = tmp_path / "fixture.json"
    runner = ResponseRunner(provider_responses())
    harness = AppleVettingHarness(tmp_path, runner)

    harness.create_fixture("ghcr.io/kenn-io/ghosthub-sandbox@" + DIGEST, DIGEST, state)

    create_index = next(
        index
        for index, call in enumerate(runner.calls)
        if call[:2] == ("container", "create")
    )
    assert create_index >= 4
    fixture = ManagedFixture.load(state)
    assert fixture.name.startswith("ghosthub-vet-" + "b" * 12 + "-")
    create = runner.calls[create_index]
    assert f"io.ghosthub.digest={DIGEST}" in create
    assert "io.ghosthub.purpose=sandbox-image-vet" in create


def inspect_payload(fixture: ManagedFixture, *, digest: str | None = None) -> str:
    return json.dumps(
        [
            {
                "id": fixture.name,
                "configuration": {
                    "id": fixture.name,
                    "labels": {
                        "io.ghosthub.purpose": fixture.purpose,
                        "io.ghosthub.digest": digest or fixture.digest,
                    },
                },
                "status": {"state": "running"},
            }
        ]
    )


def test_cleanup_deletes_only_exact_managed_identity(tmp_path: Path) -> None:
    state = tmp_path / "fixture.json"
    fixture = ManagedFixture("ghosthub-vet-" + "b" * 12 + "-abc123", DIGEST)
    fixture.write(state)
    listed = json.dumps([{"id": fixture.name}])
    runner = ResponseRunner(
        {
            ("container", "list", "--all", "--format", "json"): response(
                ("container", "list", "--all", "--format", "json"), listed
            ),
            ("container", "inspect", fixture.name): response(
                ("container", "inspect", fixture.name), inspect_payload(fixture)
            ),
        }
    )

    cleanup_fixture(state, runner)

    assert ("container", "stop", fixture.name) in runner.calls
    assert ("container", "delete", fixture.name) in runner.calls
    assert not state.exists()


def test_cleanup_refuses_partial_identity_match(tmp_path: Path) -> None:
    state = tmp_path / "fixture.json"
    fixture = ManagedFixture("ghosthub-vet-" + "b" * 12 + "-abc123", DIGEST)
    fixture.write(state)
    runner = ResponseRunner(
        {
            ("container", "list", "--all", "--format", "json"): response(
                ("container", "list", "--all", "--format", "json"),
                json.dumps([{"id": fixture.name}]),
            ),
            ("container", "inspect", fixture.name): response(
                ("container", "inspect", fixture.name),
                inspect_payload(fixture, digest="sha256:" + "c" * 64),
            ),
        }
    )

    with pytest.raises(ValueError, match="identity"):
        cleanup_fixture(state, runner)

    assert not any(call[:2] == ("container", "delete") for call in runner.calls)
    assert state.exists()


def test_canonical_report_path_uses_digest_only(tmp_path: Path) -> None:
    assert canonical_report_path(tmp_path, DIGEST) == (
        tmp_path / "images/sandbox/reports" / ("sha256-" + "b" * 64 + ".json")
    )


def test_vetting_rechecks_mount_protection_after_restart(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = ResponseRunner({})
    harness = AppleVettingHarness(tmp_path, runner)
    state = tmp_path / "fixture.json"
    fixture = ManagedFixture("ghosthub-vet-" + "b" * 12 + "-abc123", DIGEST)
    fixture.write(state)
    image = apple_module.ImageReference.parse(
        "ghcr.io/kenn-io/ghosthub-sandbox@" + DIGEST
    )
    monkeypatch.setattr(
        apple_module,
        "require_supported_apple_provider",
        lambda _runner: AppleProviderInfo("26.0", "arm64", "1.2.2"),
    )
    monkeypatch.setattr(
        apple_module,
        "_inspect_fixture",
        lambda *_args: {"configuration": {"useInit": True}},
    )
    monkeypatch.setattr(
        harness,
        "_inspect_image_identity",
        lambda _image: AppleImageIdentity(DIGEST, "b" * 40, "0.1.0"),
    )
    monkeypatch.setattr(harness, "_prepare_git_fixtures", lambda _root: ((), {}))
    monkeypatch.setattr(harness, "create_fixture", lambda *_args, **_kwargs: fixture)
    contract_phases: list[str] = []

    def record_contract(*_args: object, **kwargs: object) -> None:
        contract_phases.append(str(kwargs.get("phase", "initial")))

    monkeypatch.setattr(harness, "_assert_git_contract", record_contract)
    monkeypatch.setattr(
        harness, "_assert_mount_protection", lambda *_args, **_kwargs: None
    )
    monkeypatch.setattr(
        harness,
        "_exec",
        lambda _fixture, script, **_kwargs: "ghosthub\n" if script == "id -un" else "",
    )
    _provider, _identity, _checks, _attestations = harness.exercise_candidate(
        image,
        state,
        pull=False,
        verify_attestations=False,
    )

    assert contract_phases == ["initial", "stop-start"]


def test_git_contract_requires_host_visible_commit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = {
        "standard": tmp_path / "standard",
        "linked": tmp_path / "linked",
    }
    responses: dict[tuple[str, ...], CompletedCommand] = {
        ("git", "-C", str(repository), "log", "-1", "--format=%s"): response(
            ("git", "-C", str(repository), "log", "-1", "--format=%s"),
            "Initialize fixture\n",
        )
        for repository in paths.values()
    }
    harness = AppleVettingHarness(tmp_path, ResponseRunner(responses))
    fixture = ManagedFixture("ghosthub-vet-" + "b" * 12 + "-abc123", DIGEST)
    monkeypatch.setattr(harness, "_exec", lambda *_args, **_kwargs: "")
    monkeypatch.setattr(
        harness, "_assert_mount_protection", lambda *_args, **_kwargs: None
    )

    with pytest.raises(ValueError, match="not visible on the host"):
        harness._assert_git_contract(fixture, paths, [])


def test_clean_refuses_unrecorded_prefixed_resource(tmp_path: Path) -> None:
    name = "ghosthub-vet-" + "b" * 12 + "-abc123"
    inventory_call = ("container", "list", "--all", "--format", "json")
    runner = ResponseRunner(
        {inventory_call: response(inventory_call, json.dumps([{"id": name}]))}
    )

    with pytest.raises(ValueError, match="unrecorded"):
        clean_managed_fixtures(tmp_path, runner)

    assert not any(call[:2] == ("container", "delete") for call in runner.calls)
