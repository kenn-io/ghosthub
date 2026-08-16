import base64
import json
import sys
from collections.abc import Sequence
from datetime import UTC, date, datetime, timedelta, timezone
from pathlib import Path

import pytest
import sandbox_image.commands as commands_module
import sandbox_image.github as github_module
from sandbox_image.commands import (
    _utc_date,
    check_image,
    maintenance_image,
    pin_image,
    refresh_image,
    status_image,
    vet_image,
)
from sandbox_image.docker import (
    ImageInputs,
    assert_tag_available,
    build_local_image,
    resolve_optional_tag,
)
from sandbox_image.github import (
    candidate_action,
    dispatch_promotion,
    image_inputs_digest,
    local_promotion_head,
    promotion_changed_paths,
    promotion_evidence_paths,
    promotion_gate_action,
    promotion_pull_request,
    verify_candidate_attestations,
    verify_current_candidate_policy,
    verify_production_environment,
    verify_promotion_evidence,
    verify_promotion_status_environment,
    verify_required_merge_signal,
    verify_required_promotion_status,
)
from sandbox_image.model import ImageReference
from sandbox_image.process import (
    CommandError,
    CommandRunner,
    CompletedCommand,
)

ARM64_DIGEST = "sha256:" + "a" * 64
REFRESHED_ARM64_DIGEST = "sha256:" + "c" * 64


def test_policy_date_is_normalized_to_utc() -> None:
    chicago = timezone(-timedelta(hours=5))

    assert _utc_date(datetime(2026, 8, 12, 20, tzinfo=chicago)) == date(2026, 8, 13)


class FakeRunner:
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []

    def run(
        self,
        argv: Sequence[str],
        *,
        check: bool = True,
        capture: bool = True,
    ) -> CompletedCommand:
        call = tuple(argv)
        self.calls.append(call)
        if call[:4] == ("docker", "buildx", "imagetools", "inspect"):
            payload = {
                "manifests": [
                    {
                        "digest": REFRESHED_ARM64_DIGEST,
                        "platform": {"os": "linux", "architecture": "arm64"},
                    }
                ]
            }
            return CompletedCommand(call, 0, json.dumps(payload), "")
        if call[:4] == ("docker", "image", "inspect", "--format"):
            return CompletedCommand(call, 0, json.dumps(ARM64_DIGEST), "")
        if (
            len(call) >= 5
            and call[:2] == ("git", "-C")
            and call[-2:]
            == (
                "rev-parse",
                "HEAD",
            )
        ):
            return CompletedCommand(call, 0, "b" * 40 + "\n", "")
        return CompletedCommand(call, 0, "", "")


class ScriptedRunner:
    def __init__(self, responses: dict[tuple[str, ...], str]) -> None:
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
        if call not in self.responses:
            raise AssertionError(f"unexpected command: {call}")
        return CompletedCommand(call, 0, self.responses[call], "")


def production_credential_responses(
    endpoint: str,
    *,
    secret_updated_at: str = "2026-08-13T00:00:00Z",
) -> dict[tuple[str, ...], str]:
    return {
        ("gh", "api", endpoint + "/variables"): json.dumps(
            {
                "variables": [
                    {"name": "SANDBOX_PROMOTION_APP_ID", "value": "424242"},
                    {
                        "name": "SANDBOX_PROMOTION_APP_CLIENT_ID",
                        "value": "Iv1.example",
                    },
                ]
            }
        ),
        ("gh", "api", endpoint + "/secrets"): json.dumps(
            {
                "secrets": [
                    {
                        "name": "SANDBOX_PROMOTION_APP_PRIVATE_KEY",
                        "created_at": "2026-08-12T00:00:00Z",
                        "updated_at": secret_updated_at,
                    },
                    {
                        "name": "SANDBOX_PACKAGE_WRITER_USERNAME",
                        "created_at": "2026-08-12T00:00:00Z",
                        "updated_at": "2026-08-13T00:00:00Z",
                    },
                    {
                        "name": "SANDBOX_PACKAGE_WRITER_TOKEN",
                        "created_at": "2026-08-12T00:00:00Z",
                        "updated_at": "2026-08-13T00:00:00Z",
                    },
                ]
            }
        ),
    }


MERGE_SIGNAL_WORKFLOW = (
    "name: Sandbox image merge signal\n"
    "on:\n"
    "  merge_group:\n"
    "    types: [checks_requested]\n"
    "permissions: {}\n"
    "jobs:\n"
    "  signal:\n"
    "    runs-on: ubuntu-24.04\n"
)


class UnavailableRegistryRunner:
    def run(
        self,
        argv: Sequence[str],
        *,
        check: bool = True,
        capture: bool = True,
    ) -> CompletedCommand:
        del check, capture
        call = tuple(argv)
        if call[:2] == ("gh", "api"):
            return CompletedCommand(call, 0, json.dumps({"visibility": "public"}), "")
        return CompletedCommand(call, 1, "", "registry unavailable")


class RegistryInspectRunner:
    def __init__(self, stderr: str) -> None:
        self.stderr = stderr

    def run(
        self,
        argv: Sequence[str],
        *,
        check: bool = True,
        capture: bool = True,
    ) -> CompletedCommand:
        del check, capture
        call = tuple(argv)
        return CompletedCommand(call, 1, "", self.stderr)


def write_inputs(root: Path) -> None:
    image = root / "images" / "sandbox"
    image.mkdir(parents=True)
    (image / "VERSION").write_text("0.1.0\n", encoding="utf-8")
    (image / "UBUNTU_BASE").write_text(ARM64_DIGEST + "\n", encoding="utf-8")
    (image / "APT_SNAPSHOT").write_text("20260812T000000Z\n", encoding="utf-8")
    (image / "vulnerability-dispositions.json").write_text("[]\n", encoding="utf-8")


def test_check_builds_arm64_from_all_four_pinned_inputs(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    runner = FakeRunner()
    result = check_image(tmp_path, runner=runner, scan=False)
    builds = [
        call for call in runner.calls if call[:3] == ("docker", "buildx", "build")
    ]
    assert len(builds) == 2
    build = builds[0]
    assert result.platform == "linux/arm64"
    assert "linux/arm64" in build
    assert f"UBUNTU_BASE={ARM64_DIGEST}" in build
    assert "APT_SNAPSHOT=20260812T000000Z" in build
    assert "SOURCE_REVISION=" + "b" * 40 in build
    assert "IMAGE_VERSION=0.1.0" in build
    assert "--no-cache" in build
    assert "SOURCE_DATE_EPOCH=" + str(
        int(datetime(2026, 8, 12, tzinfo=UTC).timestamp())
    ) in build
    assert any(
        argument.startswith("type=docker,dest=")
        and argument.endswith(",rewrite-timestamp=true")
        for argument in build
    )
    assert result.archive.name == "sandbox-image.docker.tar"
    assert ("git", "-C", str(tmp_path), "rev-parse", "HEAD") in runner.calls
    contract = next(call for call in runner.calls if call[:2] == ("docker", "run"))
    assert "--platform" in contract
    assert "linux/arm64" in contract
    assert "/opt/ghosthub/image-contract.sh" in contract
    assert not any(call[:2] == ("docker", "login") for call in runner.calls)
    assert not any("push" in call for call in runner.calls)


def test_check_rejects_non_reproducible_image_content(tmp_path: Path) -> None:
    class DivergentRunner(FakeRunner):
        def __init__(self) -> None:
            super().__init__()
            self.identities = iter((ARM64_DIGEST, REFRESHED_ARM64_DIGEST))

        def run(
            self,
            argv: Sequence[str],
            *,
            check: bool = True,
            capture: bool = True,
        ) -> CompletedCommand:
            call = tuple(argv)
            if call[:4] == ("docker", "image", "inspect", "--format"):
                self.calls.append(call)
                return CompletedCommand(call, 0, json.dumps(next(self.identities)), "")
            return super().run(argv, check=check, capture=capture)

    write_inputs(tmp_path)

    with pytest.raises(ValueError, match="reproducible"):
        check_image(tmp_path, runner=DivergentRunner(), scan=False)


def test_malformed_input_fails_before_subprocess(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    (tmp_path / "images/sandbox/VERSION").write_text("next\n", encoding="utf-8")
    runner = FakeRunner()
    with pytest.raises(ValueError):
        check_image(tmp_path, runner=runner, scan=False)
    assert runner.calls == []


def test_registry_only_treats_exact_manifest_not_found_as_an_absent_tag() -> None:
    tag = "ghcr.io/kenn-io/ghosthub-sandbox:v0.1.0"
    missing = RegistryInspectRunner(f"ERROR: {tag}: not found\n")

    assert resolve_optional_tag(tag, missing) is None
    assert assert_tag_available(tag, ARM64_DIGEST, missing) == "create"


@pytest.mark.parametrize(
    "diagnostic",
    [
        "ERROR: failed to authorize: denied\n",
        "ERROR: failed to do request: dial tcp: network is unreachable\n",
        "ERROR: registry rate limit exceeded\n",
    ],
)
def test_registry_inspection_errors_fail_closed(diagnostic: str) -> None:
    tag = "ghcr.io/kenn-io/ghosthub-sandbox:v0.1.0"
    runner = RegistryInspectRunner(diagnostic)

    with pytest.raises(CommandError):
        resolve_optional_tag(tag, runner)
    with pytest.raises(CommandError):
        assert_tag_available(tag, ARM64_DIGEST, runner)


def test_refresh_changes_only_three_reviewed_input_files(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    before = {
        path.relative_to(tmp_path): path.read_bytes()
        for path in tmp_path.rglob("*")
        if path.is_file()
    }
    runner = FakeRunner()
    refresh_image(
        tmp_path,
        version="0.2.0",
        runner=runner,
        snapshot="20260813T000000Z",
    )
    after = {
        path.relative_to(tmp_path): path.read_bytes()
        for path in tmp_path.rglob("*")
        if path.is_file()
    }
    assert {path for path in after if before.get(path) != after[path]} == {
        Path("images/sandbox/VERSION"),
        Path("images/sandbox/UBUNTU_BASE"),
        Path("images/sandbox/APT_SNAPSHOT"),
    }


def test_refresh_rejects_invalid_version_without_mutation(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    runner = FakeRunner()
    with pytest.raises(ValueError):
        refresh_image(tmp_path, version="v1", runner=runner)
    assert runner.calls == []


def test_status_without_pin_is_read_only(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    runner = FakeRunner()
    status = status_image(tmp_path, runner=runner)
    assert status.pin == "pending"
    assert status.candidate == "pending"
    assert runner.calls == [
        ("gh", "api", "/orgs/kenn-io/packages/container/ghosthub-sandbox")
    ]


def test_maintenance_before_first_pin_is_read_only(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    runner = FakeRunner()
    message, action_required = maintenance_image(tmp_path, runner=runner)
    assert message == "Sandbox image not initialized"
    assert not action_required
    assert runner.calls == []


def test_command_error_redacts_secrets_paths_and_bounds_output(tmp_path: Path) -> None:
    runner = CommandRunner(
        secrets=("top-secret",),
        redacted_prefixes=(tmp_path,),
        output_limit=80,
    )
    command = (
        sys.executable,
        "-c",
        "import sys; "
        f"sys.stderr.write({'x' * 200!r} + ' top-secret {tmp_path}') ; sys.exit(7)",
    )
    with pytest.raises(CommandError) as caught:
        runner.run(command)
    message = str(caught.value)
    assert "top-secret" not in message
    assert str(tmp_path) not in message
    assert "<redacted>" in message
    assert len(caught.value.stderr) <= 80


def test_successful_command_output_remains_exact_for_parsers(tmp_path: Path) -> None:
    runner = CommandRunner(redacted_prefixes=(tmp_path,))
    result = runner.run((sys.executable, "-c", f"print({str(tmp_path)!r})"))
    assert result.stdout.strip() == str(tmp_path)


def test_command_runner_can_supply_secret_input_without_putting_it_in_argv() -> None:
    runner = CommandRunner(secrets=("private-key",))
    result = runner.run_secret(
        (
            sys.executable,
            "-c",
            "import sys; print(len(sys.stdin.read()))",
        ),
        "private-key",
    )

    assert result.stdout.strip() == "11"
    assert "private-key" not in result.argv


def test_secret_command_error_redacts_transient_standard_input() -> None:
    runner = CommandRunner()
    private_key = (
        "-----BEGIN " + "PRIVATE KEY-----\n"
        "secret-material\n"
        "-----END " + "PRIVATE KEY-----"
    )
    command = (
        sys.executable,
        "-c",
        "import sys; print(sys.stdin.read(), file=sys.stderr); raise SystemExit(7)",
    )

    with pytest.raises(CommandError) as caught:
        runner.run_secret(command, private_key)

    assert private_key not in str(caught.value)
    assert "secret-material" not in str(caught.value)
    assert "<redacted>" in str(caught.value)


def test_authenticated_command_error_redacts_transient_bearer_token() -> None:
    runner = CommandRunner()
    token = "short-lived.jwt.token"
    command = (
        sys.executable,
        "-c",
        "import sys; print(sys.stdin.read()); raise SystemExit(7)",
    )

    with pytest.raises(CommandError) as caught:
        runner.run_with_bearer(command, token)

    assert token not in str(caught.value)
    assert "<redacted>" in str(caught.value)


def write_report(
    root: Path,
    *,
    status: str = "pass",
    digest: str = ARM64_DIGEST,
    timestamp: str | None = None,
) -> Path:
    from sandbox_image.report import REQUIRED_CHECKS

    path = root / "images/sandbox/reports" / f"{digest.replace(':', '-')}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    report_timestamp = timestamp or datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    payload = {
        "schema_version": 1,
        "repository": "ghcr.io/kenn-io/ghosthub-sandbox",
        "digest": digest,
        "candidate_tag": "candidate-" + "b" * 40,
        "image_version": "0.1.0",
        "source_commit": "b" * 40,
        "provider_version": "1.2.2",
        "macos_version": "26.0",
        "architecture": "arm64",
        "attestations": [
            "https://slsa.dev/provenance/v0.2",
            "https://spdx.dev/Document/v2.3",
        ],
        "checks": [
            {"name": name, "status": status, "detail": "verified"}
            for name in sorted(REQUIRED_CHECKS)
        ],
        "scan_database_timestamp": report_timestamp,
        "findings": [],
        "dispositions": [],
        "status": status,
        "completed_at": report_timestamp,
    }
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def test_status_validates_the_report_and_registry_aliases(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    write_report(tmp_path, timestamp="2026-01-01T00:00:00Z")
    (tmp_path / "SANDBOX_IMAGE").write_text(
        f"ghcr.io/kenn-io/ghosthub-sandbox@{ARM64_DIGEST}\n",
        encoding="utf-8",
    )
    metadata = json.dumps({"manifest": {"digest": ARM64_DIGEST}})
    candidate = "ghcr.io/kenn-io/ghosthub-sandbox:candidate-" + "b" * 40
    runner = ScriptedRunner(
        {
            (
                "gh",
                "api",
                "/orgs/kenn-io/packages/container/ghosthub-sandbox",
            ): json.dumps({"visibility": "public"}),
            (
                "docker",
                "buildx",
                "imagetools",
                "inspect",
                candidate,
                "--format",
                "{{json .}}",
            ): metadata,
            (
                "docker",
                "buildx",
                "imagetools",
                "inspect",
                "ghcr.io/kenn-io/ghosthub-sandbox:v0.1.0",
                "--format",
                "{{json .}}",
            ): metadata,
        }
    )

    status = status_image(tmp_path, runner=runner)

    assert status.setup == "public package ready"
    assert status.report == "valid"
    assert status.candidate == "matches pin"
    assert status.production == "matches pin"


def test_maintenance_rescans_an_old_production_report(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write_inputs(tmp_path)
    write_report(tmp_path, timestamp="2026-01-01T00:00:00Z")
    (tmp_path / "SANDBOX_IMAGE").write_text(
        f"ghcr.io/kenn-io/ghosthub-sandbox@{ARM64_DIGEST}\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(
        commands_module,
        "scan_reference",
        lambda *_args: type("Scan", (), {"findings": ()})(),
    )
    attestation_checks: list[tuple[ImageReference, str, str]] = []

    def verify_attestations(
        image: ImageReference,
        source: str,
        inputs_digest: str,
        _runner: object,
    ) -> None:
        attestation_checks.append((image, source, inputs_digest))

    monkeypatch.setattr(
        commands_module, "verify_candidate_attestations", verify_attestations
    )
    monkeypatch.setattr(commands_module, "image_inputs_digest", lambda _root: "inputs")
    production = "ghcr.io/kenn-io/ghosthub-sandbox:v0.1.0"
    responses = {
        (
            "docker",
            "buildx",
            "imagetools",
            "inspect",
            production,
            "--format",
            "{{json .}}",
        ): json.dumps({"manifest": {"digest": ARM64_DIGEST}}),
        (
            "docker",
            "buildx",
            "imagetools",
            "inspect",
            "ubuntu:26.04",
            "--raw",
        ): json.dumps(
            {
                "manifests": [
                    {
                        "digest": ARM64_DIGEST,
                        "platform": {"os": "linux", "architecture": "arm64"},
                    }
                ]
            }
        ),
    }
    for predicate in (
        "https://slsa.dev/provenance/v0.2",
        "https://spdx.dev/Document/v2.3",
    ):
        responses[
            (
                "gh",
                "attestation",
                "verify",
                f"oci://ghcr.io/kenn-io/ghosthub-sandbox@{ARM64_DIGEST}",
                "--repo",
                "kenn-io/ghosthub",
                "--predicate-type",
                predicate,
            )
        ] = ""
    runner = ScriptedRunner(responses)

    message, action_required = maintenance_image(tmp_path, runner=runner)

    assert message == "Production scan passed; Ubuntu base current"
    assert not action_required
    assert attestation_checks == [
        (
            ImageReference.parse(
                f"ghcr.io/kenn-io/ghosthub-sandbox:v0.1.0@{ARM64_DIGEST}"
            ),
            "b" * 40,
            "inputs",
        )
    ]


def test_status_rejects_a_report_with_stale_dispositions(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    path = write_report(tmp_path)
    payload = json.loads(path.read_text())
    payload["dispositions"] = [
        {
            "vulnerability_id": "CVE-1",
            "package": "openssl",
            "result_class": "os-pkgs",
            "result_type": "ubuntu",
            "target": "ubuntu",
            "rationale": "temporary",
            "owner": "security",
            "expires": "2026-08-20",
        }
    ]
    path.write_text(json.dumps(payload), encoding="utf-8")
    (tmp_path / "SANDBOX_IMAGE").write_text(
        f"ghcr.io/kenn-io/ghosthub-sandbox@{ARM64_DIGEST}\n",
        encoding="utf-8",
    )
    runner = ScriptedRunner(
        {
            (
                "gh",
                "api",
                "/orgs/kenn-io/packages/container/ghosthub-sandbox",
            ): json.dumps({"visibility": "public"})
        }
    )

    status = status_image(tmp_path, runner=runner)

    assert status.report == "invalid"
    assert status.candidate == "unknown"


def test_status_does_not_report_registry_errors_as_pending(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    write_report(tmp_path)
    (tmp_path / "SANDBOX_IMAGE").write_text(
        f"ghcr.io/kenn-io/ghosthub-sandbox@{ARM64_DIGEST}\n",
        encoding="utf-8",
    )

    status = status_image(tmp_path, runner=UnavailableRegistryRunner())

    assert status.report == "valid"
    assert status.candidate == "unavailable"
    assert status.production == "unavailable"


def test_pin_requires_canonical_passing_report_and_writes_tag_free_digest(
    tmp_path: Path,
) -> None:
    write_inputs(tmp_path)
    write_report(tmp_path)
    candidate = (
        "ghcr.io/kenn-io/ghosthub-sandbox:candidate-" + "b" * 40 + "@" + ARM64_DIGEST
    )

    pin_image(tmp_path, candidate)

    assert (tmp_path / "SANDBOX_IMAGE").read_text() == (
        "ghcr.io/kenn-io/ghosthub-sandbox@" + ARM64_DIGEST + "\n"
    )


@pytest.mark.parametrize("mutation", ["failed", "mismatched", "noncanonical"])
def test_pin_refuses_invalid_report_without_mutation(
    tmp_path: Path, mutation: str
) -> None:
    write_inputs(tmp_path)
    digest = ARM64_DIGEST if mutation != "mismatched" else REFRESHED_ARM64_DIGEST
    path = write_report(
        tmp_path, status="fail" if mutation == "failed" else "pass", digest=digest
    )
    if mutation == "noncanonical":
        moved = tmp_path / "report.json"
        path.rename(moved)
    candidate = (
        "ghcr.io/kenn-io/ghosthub-sandbox:candidate-" + "b" * 40 + "@" + ARM64_DIGEST
    )

    with pytest.raises(ValueError):
        pin_image(tmp_path, candidate)

    assert not (tmp_path / "SANDBOX_IMAGE").exists()


def test_pin_rejects_symlinked_canonical_report(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    report = write_report(tmp_path)
    target = tmp_path / "report-target.json"
    report.rename(target)
    report.symlink_to(target)
    candidate = (
        "ghcr.io/kenn-io/ghosthub-sandbox:candidate-" + "b" * 40 + "@" + ARM64_DIGEST
    )

    with pytest.raises(ValueError, match="regular file"):
        pin_image(tmp_path, candidate)

    assert not (tmp_path / "SANDBOX_IMAGE").exists()


def test_pin_reevaluates_report_findings(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    path = write_report(tmp_path)
    payload = json.loads(path.read_text())
    payload["findings"] = [
        {
            "vulnerability_id": "CVE-1",
            "package": "openssl",
            "result_class": "os-pkgs",
            "result_type": "ubuntu",
            "target": "ubuntu",
            "severity": "HIGH",
            "fixed_version": "2.0",
        }
    ]
    path.write_text(json.dumps(payload), encoding="utf-8")
    candidate = (
        "ghcr.io/kenn-io/ghosthub-sandbox:candidate-" + "b" * 40 + "@" + ARM64_DIGEST
    )
    with pytest.raises(ValueError, match="vulnerability"):
        pin_image(tmp_path, candidate)
    assert not (tmp_path / "SANDBOX_IMAGE").exists()


def test_local_check_tags_are_unique_per_invocation(tmp_path: Path) -> None:
    runner = FakeRunner()
    inputs = ImageInputs(ARM64_DIGEST, "20260812T000000Z", "b" * 40, "0.1.0")
    first = build_local_image(tmp_path, inputs, runner)
    second = build_local_image(tmp_path, inputs, runner)
    assert first.local_tag != second.local_tag


def test_vet_preflight_failure_still_writes_canonical_report(
    tmp_path: Path,
) -> None:
    write_inputs(tmp_path)
    runner = FakeRunner()
    candidate = (
        "ghcr.io/kenn-io/ghosthub-sandbox:candidate-" + "b" * 40 + "@" + ARM64_DIGEST
    )

    with pytest.raises(ValueError):
        vet_image(
            tmp_path,
            candidate,
            runner=runner,
            clock=lambda: datetime(2026, 8, 13, 1, tzinfo=UTC),
        )

    canonical = (
        tmp_path / "images/sandbox/reports" / (ARM64_DIGEST.replace(":", "-") + ".json")
    )
    payload = json.loads(canonical.read_text())
    assert payload["status"] == "fail"
    assert payload["digest"] == ARM64_DIGEST
    assert any(check["status"] == "fail" for check in payload["checks"])


@pytest.mark.parametrize(
    ("event", "ref", "paths", "expected"),
    [
        (
            "pull_request",
            "refs/pull/1/merge",
            ["images/sandbox/Dockerfile"],
            "check-only",
        ),
        ("pull_request", "refs/pull/1/merge", ["tools/sandbox_image.py"], "check-only"),
        ("push", "refs/heads/main", ["images/sandbox/packages.txt"], "publish"),
        (
            "pull_request",
            "refs/pull/1/merge",
            ["tools/tests/test_sandbox_image_policy.py"],
            "check-only",
        ),
        ("push", "refs/heads/main", ["README.md"], "skip"),
        ("pull_request", "refs/pull/1/merge", ["README.md"], "skip"),
        ("push", "refs/heads/topic", ["images/sandbox/Dockerfile"], "skip"),
    ],
)
def test_candidate_action(
    event: str, ref: str, paths: list[str], expected: str
) -> None:
    assert candidate_action(event, ref, [Path(path) for path in paths]) == expected


def test_promotion_gate_uses_complete_relevant_path_set() -> None:
    assert promotion_gate_action([Path("SANDBOX_IMAGE")], "missing") == "pending"
    assert (
        promotion_gate_action(
            [Path("images/sandbox/reports/sha256-" + "a" * 64 + ".json")],
            "pending",
        )
        == "pending"
    )
    assert promotion_gate_action([Path("README.md")], "missing") == "success"
    assert promotion_gate_action([Path("SANDBOX_IMAGE")], "success") == "success"


def test_promotion_evidence_paths_are_exact_for_digest() -> None:
    assert promotion_evidence_paths(ARM64_DIGEST) == {
        Path("SANDBOX_IMAGE"),
        Path("images/sandbox/reports/sha256-" + "a" * 64 + ".json"),
    }


def test_promotion_pull_request_must_target_the_trusted_base_revision() -> None:
    evidence_commit = "d" * 40
    pulls = [
        {
            "number": 42,
            "state": "open",
            "base": {"ref": "main", "sha": "a" * 40},
            "head": {"sha": evidence_commit},
        }
    ]

    with pytest.raises(ValueError, match="trusted main revision"):
        promotion_pull_request(pulls, evidence_commit, "c" * 40)


def test_promotion_changed_paths_include_rename_sources() -> None:
    assert promotion_changed_paths(
        [
            {
                "filename": "images/sandbox/reports/sha256-" + "a" * 64 + ".json",
                "previous_filename": "README.md",
            }
        ]
    ) == {
        Path("README.md"),
        Path("images/sandbox/reports/sha256-" + "a" * 64 + ".json"),
    }


def test_candidate_attestations_are_verified_against_trusted_main_workflow() -> None:
    image = ImageReference.parse(
        "ghcr.io/kenn-io/ghosthub-sandbox:candidate-"
        + "b" * 40
        + "@"
        + ARM64_DIGEST
    )
    source = "b" * 40
    provenance = {
        "verificationResult": {
            "statement": {
                "predicate": {
                    "invocation": {
                        "parameters": {"image_inputs_digest": "sha256:" + "c" * 64}
                    }
                }
            }
        }
    }
    calls: list[tuple[str, ...]] = []
    for predicate in (
        "https://slsa.dev/provenance/v0.2",
        "https://spdx.dev/Document/v2.3",
    ):
        calls.append(
            (
                "gh",
                "attestation",
                "verify",
                f"oci://{image.canonical}",
                "--repo",
                "kenn-io/ghosthub",
                "--signer-workflow",
                "kenn-io/ghosthub/.github/workflows/sandbox-image-publish.yml",
                "--source-ref",
                "refs/heads/main",
                "--source-digest",
                source,
                "--predicate-type",
                predicate,
                "--deny-self-hosted-runners",
                "--format",
                "json",
            )
        )
    responses: dict[tuple[str, ...], str] = {
        call: json.dumps([provenance]) for call in calls
    }
    runner = ScriptedRunner(responses)

    verify_candidate_attestations(
        image, source, "sha256:" + "c" * 64, runner
    )

    assert runner.calls == calls


def test_candidate_provenance_must_match_current_image_inputs() -> None:
    image = ImageReference.parse(
        "ghcr.io/kenn-io/ghosthub-sandbox:candidate-"
        + "b" * 40
        + "@"
        + ARM64_DIGEST
    )
    call = (
        "gh",
        "attestation",
        "verify",
        f"oci://{image.canonical}",
        "--repo",
        "kenn-io/ghosthub",
        "--signer-workflow",
        "kenn-io/ghosthub/.github/workflows/sandbox-image-publish.yml",
        "--source-ref",
        "refs/heads/main",
        "--source-digest",
        "b" * 40,
        "--predicate-type",
        "https://slsa.dev/provenance/v0.2",
        "--deny-self-hosted-runners",
        "--format",
        "json",
    )
    output = json.dumps(
        [
            {
                "verificationResult": {
                    "statement": {
                        "predicate": {
                            "invocation": {
                                "parameters": {
                                    "image_inputs_digest": "sha256:" + "d" * 64
                                }
                            }
                        }
                    }
                }
            }
        ]
    )

    with pytest.raises(ValueError, match="reviewed inputs"):
        verify_candidate_attestations(
            image,
            "b" * 40,
            "sha256:" + "c" * 64,
            ScriptedRunner({call: output}),
        )


def test_image_inputs_digest_covers_every_reviewed_input(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    image = tmp_path / "images/sandbox"
    (image / "Dockerfile").write_text("FROM scratch\n")
    (image / "packages.txt").write_text("bash\n")
    (image / "tests").mkdir()
    (image / "tests/image-contract.sh").write_text("#!/bin/sh\n")
    inputs = (
        image / "APT_SNAPSHOT",
        image / "Dockerfile",
        image / "UBUNTU_BASE",
        image / "VERSION",
        image / "packages.txt",
        image / "tests/image-contract.sh",
        image / "vulnerability-dispositions.json",
    )
    original = image_inputs_digest(tmp_path)

    for path in inputs:
        before = path.read_bytes()
        path.write_bytes(before + b"changed\n")
        assert image_inputs_digest(tmp_path) != original
        path.write_bytes(before)


def test_required_promotion_status_is_strict_and_bound_to_dedicated_app() -> None:
    ruleset_pages = [[{"id": 41}], [{"id": 42}]]
    detail = {
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
        "rules": [
            {"type": "pull_request", "parameters": {}},
            {
                "type": "merge_queue",
                "parameters": {
                    "check_response_timeout_minutes": 60,
                    "grouping_strategy": "ALLGREEN",
                    "max_entries_to_build": 1,
                    "max_entries_to_merge": 1,
                    "merge_method": "SQUASH",
                    "min_entries_to_merge": 1,
                    "min_entries_to_merge_wait_minutes": 0,
                },
            },
            {
                "type": "required_status_checks",
                "parameters": {
                    "strict_required_status_checks_policy": True,
                    "required_status_checks": [
                        {
                            "context": "sandbox-image-promotion",
                            "integration_id": 424242,
                        }
                    ],
                },
            }
        ],
    }
    runner = ScriptedRunner(
        {
            (
                "gh",
                "api",
                "--paginate",
                "--slurp",
                "repos/kenn-io/ghosthub/rulesets?per_page=100",
            ): json.dumps(ruleset_pages),
            ("gh", "api", "repos/kenn-io/ghosthub/rulesets/41"): "{}",
            ("gh", "api", "repos/kenn-io/ghosthub/rulesets/42"): json.dumps(detail),
        }
    )

    verify_required_promotion_status(runner, 424242)


@pytest.mark.parametrize(
    ("strict", "integration_id", "exclude", "include_queue"),
    [
        (False, 424242, [], True),
        (True, None, [], True),
        (True, 424242, ["refs/heads/main"], True),
        (True, 424242, [], False),
    ],
)
def test_required_promotion_status_rejects_weak_policy(
    strict: bool,
    integration_id: int | None,
    exclude: list[str],
    include_queue: bool,
) -> None:
    rules: list[dict[str, object]] = [
        {"type": "pull_request", "parameters": {}},
        {
            "type": "required_status_checks",
            "parameters": {
                "strict_required_status_checks_policy": strict,
                "required_status_checks": [
                    {
                        "context": "sandbox-image-promotion",
                        "integration_id": integration_id,
                    }
                ],
            },
        }
    ]
    if include_queue:
        rules.append(
            {
                "type": "merge_queue",
                "parameters": {
                    "check_response_timeout_minutes": 60,
                    "grouping_strategy": "ALLGREEN",
                    "max_entries_to_build": 1,
                    "max_entries_to_merge": 1,
                    "merge_method": "SQUASH",
                    "min_entries_to_merge": 1,
                    "min_entries_to_merge_wait_minutes": 0,
                },
            }
        )
    runner = ScriptedRunner(
        {
            (
                "gh",
                "api",
                "--paginate",
                "--slurp",
                "repos/kenn-io/ghosthub/rulesets?per_page=100",
            ): json.dumps([[{"id": 42}]]),
            ("gh", "api", "repos/kenn-io/ghosthub/rulesets/42"): json.dumps(
                {
                    "target": "branch",
                    "enforcement": "active",
                    "bypass_actors": [],
                    "conditions": {
                        "ref_name": {
                            "include": ["~DEFAULT_BRANCH"],
                            "exclude": exclude,
                        }
                    },
                    "rules": rules,
                }
            ),
        }
    )

    with pytest.raises(ValueError, match="strict.*check"):
        verify_required_promotion_status(runner, 424242)


def test_required_merge_signal_is_organization_owned_and_pinned_to_main() -> None:
    rulesets = [{"id": 42}]
    detail = {
        "source_type": "Organization",
        "source": "kenn-io",
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
        "rules": [
            {
                "type": "workflows",
                "parameters": {
                    "do_not_enforce_on_create": False,
                    "workflows": [
                        {
                            "path": ".github/workflows/sandbox-image-merge-signal.yml",
                            "ref": "refs/heads/main",
                            "repository_id": 1_308_876_468,
                        }
                    ],
                },
            }
        ],
    }
    runner = ScriptedRunner(
        {
            (
                "gh",
                "api",
                "--paginate",
                "--slurp",
                "repos/kenn-io/ghosthub/rulesets?per_page=100",
            ): json.dumps([rulesets]),
            ("gh", "api", "repos/kenn-io/ghosthub/rulesets/42"): json.dumps(detail),
        }
    )

    verify_required_merge_signal(runner)


def test_required_merge_signal_accepts_pinned_external_authority() -> None:
    commit = github_module.MERGE_SIGNAL_COMMIT
    workflow_content = (
        "name: Sandbox image merge signal\n"
        "on:\n"
        "  merge_group:\n"
        "    types: [checks_requested]\n"
        "permissions: {}\n"
        "jobs:\n"
        "  signal:\n"
        "    runs-on: ubuntu-24.04\n"
        "    steps:\n"
        "      - run: 'true'\n"
    )
    detail = {
        "source_type": "Organization",
        "source": "kenn-io",
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
        "rules": [
            {
                "type": "workflows",
                "parameters": {
                    "do_not_enforce_on_create": False,
                    "workflows": [
                        {
                            "path": github_module.MERGE_SIGNAL_WORKFLOW,
                            "ref": commit,
                            "sha": commit,
                            "repository_id": (
                                github_module.MERGE_SIGNAL_REPOSITORY_ID
                            ),
                        }
                    ],
                },
            }
        ],
    }
    runner = ScriptedRunner(
        {
            (
                "gh",
                "api",
                "--paginate",
                "--slurp",
                "repos/kenn-io/ghosthub/rulesets?per_page=100",
            ): json.dumps([[{"id": 42}]]),
            ("gh", "api", "repos/kenn-io/ghosthub/rulesets/42"): json.dumps(detail),
            (
                "gh",
                "api",
                "repos/kenn-io/ghosthub-nightly/contents/"
                ".github/workflows/sandbox-image-merge-signal.yml"
                f"?ref={commit}",
            ): json.dumps(
                {
                    "type": "file",
                    "path": github_module.MERGE_SIGNAL_WORKFLOW,
                    "encoding": "base64",
                    "size": len(workflow_content.encode()),
                    "content": base64.b64encode(workflow_content.encode()).decode(),
                }
            ),
        }
    )

    verify_required_merge_signal(runner)


@pytest.mark.parametrize(
    ("source_type", "ref", "repository_id"),
    [
        ("Repository", "refs/heads/main", 1_308_876_468),
        ("Organization", "refs/heads/task", 1_308_876_468),
        ("Organization", "refs/heads/main", 7),
    ],
)
def test_required_merge_signal_rejects_branch_controlled_authority(
    source_type: str,
    ref: str,
    repository_id: int,
) -> None:
    detail = {
        "source_type": source_type,
        "source": "kenn-io",
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
        "rules": [
            {
                "type": "workflows",
                "parameters": {
                    "do_not_enforce_on_create": False,
                    "workflows": [
                        {
                            "path": ".github/workflows/sandbox-image-merge-signal.yml",
                            "ref": ref,
                            "repository_id": repository_id,
                        }
                    ],
                },
            }
        ],
    }
    runner = ScriptedRunner(
        {
            (
                "gh",
                "api",
                "--paginate",
                "--slurp",
                "repos/kenn-io/ghosthub/rulesets?per_page=100",
            ): json.dumps([[{"id": 42}]]),
            ("gh", "api", "repos/kenn-io/ghosthub/rulesets/42"): json.dumps(detail),
        }
    )

    with pytest.raises(ValueError, match="trusted merge-signal"):
        verify_required_merge_signal(runner)


@pytest.mark.parametrize(
    ("branch_policy", "error"),
    [
        ({"name": "main", "type": "branch"}, None),
        ({"name": "main", "type": "tag"}, "admit only main"),
    ],
)
def test_promotion_status_environment_is_main_branch_only_and_narrow(
    tmp_path: Path,
    branch_policy: dict[str, str],
    error: str | None,
) -> None:
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "sandbox-image-promotion-gate.yml").write_text(
        "permissions: {}\njobs:\n"
        "  reconcile:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    (workflows / "sandbox-image-promote.yml").write_text(
        "permissions: {}\njobs:\n"
        "  plan:\n"
        "    environment: sandbox-image-promotion-status\n"
        "  retag:\n"
        "    environment: sandbox-image-production\n"
    )
    (workflows / "sandbox-image-publish.yml").write_text(
        "permissions: {}\njobs:\n"
        "  publish:\n"
        "    environment: sandbox-image-package-writer\n"
    )
    endpoint = "repos/kenn-io/ghosthub/environments/sandbox-image-promotion-status"
    runner = ScriptedRunner(
        {
            ("gh", "api", endpoint): json.dumps(
                {
                    "protection_rules": [{"type": "branch_policy"}],
                    "deployment_branch_policy": {
                        "protected_branches": False,
                        "custom_branch_policies": True,
                    },
                }
            ),
            ("gh", "api", endpoint + "/deployment-branch-policies"): json.dumps(
                {
                    "total_count": 1,
                    "branch_policies": [branch_policy],
                }
            ),
            ("gh", "api", endpoint + "/variables"): json.dumps(
                {
                    "total_count": 2,
                    "variables": [
                        {"name": "SANDBOX_PROMOTION_APP_ID", "value": "424242"},
                        {
                            "name": "SANDBOX_PROMOTION_APP_CLIENT_ID",
                            "value": "Iv1.example",
                        },
                    ],
                }
            ),
            ("gh", "api", endpoint + "/secrets"): json.dumps(
                {
                    "total_count": 1,
                    "secrets": [
                        {
                            "name": "SANDBOX_PROMOTION_APP_PRIVATE_KEY",
                            "created_at": "2026-08-12T00:00:00Z",
                            "updated_at": "2026-08-13T00:00:00Z",
                        }
                    ],
                }
            ),
        }
    )

    if error is None:
        fingerprint = verify_promotion_status_environment(tmp_path, runner, 424242)
        rotated_responses = dict(runner.responses)
        rotated_responses[("gh", "api", endpoint + "/secrets")] = json.dumps(
            {
                "total_count": 1,
                "secrets": [
                    {
                        "name": "SANDBOX_PROMOTION_APP_PRIVATE_KEY",
                        "created_at": "2026-08-12T00:00:00Z",
                        "updated_at": "2026-08-14T00:00:00Z",
                    }
                ],
            }
        )
        assert verify_promotion_status_environment(
            tmp_path, ScriptedRunner(rotated_responses), 424242
        ) != fingerprint
    else:
        with pytest.raises(ValueError, match=error):
            verify_promotion_status_environment(tmp_path, runner, 424242)


def test_promotion_workflow_audit_allows_trusted_read_only_planner(
    tmp_path: Path,
) -> None:
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "sandbox-image-promotion-gate.yml").write_text(
        "permissions: {}\njobs:\n"
        "  audit:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    (workflows / "sandbox-image-promote.yml").write_text(
        "permissions: {}\njobs:\n"
        "  audit:\n"
        "    environment: sandbox-image-promotion-status\n"
        "  retag:\n"
        "    environment: sandbox-image-production\n"
    )
    (workflows / "sandbox-image-publish.yml").write_text(
        "permissions: {}\njobs:\n"
        "  publish:\n"
        "    environment: sandbox-image-package-writer\n"
    )

    github_module.verify_promotion_workflows(workflows)


@pytest.mark.parametrize("other_name", ["other.yml", "other.yaml"])
def test_promotion_status_environment_rejects_a_second_workflow(
    tmp_path: Path, other_name: str
) -> None:
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    for name in ("sandbox-image-promotion-gate.yml", other_name):
        (workflows / name).write_text(
            "permissions: {}\njobs:\n"
            "  reconcile:\n"
            "    environment: sandbox-image-promotion-status\n"
        )
    (workflows / "sandbox-image-promote.yml").write_text(
        "permissions: {}\njobs:\n"
        "  plan:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    (workflows / "sandbox-image-publish.yml").write_text(
        "permissions: {}\njobs:\n"
        "  publish:\n"
        "    environment: sandbox-image-package-writer\n"
    )

    with pytest.raises(ValueError, match="exactly the trusted workflows"):
        verify_promotion_status_environment(tmp_path, FakeRunner(), 424242)


@pytest.mark.parametrize(
    "unsafe_workflow, message",
    [
        (
            "permissions: {}\njobs:\n"
            "  unsafe:\n    environment: ${{ inputs.environment }}\n",
            "dynamic environment",
        ),
        (
            "permissions: {statuses: write}\n"
            "jobs:\n  unsafe:\n    runs-on: ubuntu-latest\n",
            "status-write authority",
        ),
        (
            "permissions: write-all\njobs:\n  unsafe:\n    runs-on: ubuntu-latest\n",
            "status-write authority",
        ),
        (
            "permissions: {}\njobs:\n"
            "  unsafe:\n"
            "    permissions: {packages: write}\n"
            "    runs-on: ubuntu-latest\n",
            "package-write authority",
        ),
        (
            "permissions: {}\njobs:\n"
            "  unsafe:\n"
            "    environment: SANDBOX-IMAGE-PROMOTION-STATUS\n",
            "exactly the trusted workflows",
        ),
        (
            "permissions: {}\njobs:\n"
            "  unsafe:\n"
            "    uses: example/actions/.github/workflows/unsafe.yml@main\n",
            "reusable workflow",
        ),
    ],
)
def test_promotion_workflow_audit_rejects_implicit_authority(
    tmp_path: Path,
    unsafe_workflow: str,
    message: str,
) -> None:
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "sandbox-image-promotion-gate.yml").write_text(
        "permissions: {}\njobs:\n"
        "  reconcile:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    (workflows / "sandbox-image-promote.yml").write_text(
        "permissions: {}\njobs:\n"
        "  plan:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    (workflows / "sandbox-image-publish.yml").write_text(
        "permissions: {}\njobs:\n"
        "  publish:\n"
        "    environment: sandbox-image-package-writer\n"
    )
    (workflows / "unsafe.yaml").write_text(unsafe_workflow)

    with pytest.raises(ValueError, match=message):
        github_module.verify_promotion_workflows(workflows)


def test_promotion_workflow_audit_requires_explicit_top_level_permissions(
    tmp_path: Path,
) -> None:
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "sandbox-image-promotion-gate.yml").write_text(
        "permissions: {}\njobs:\n"
        "  reconcile:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    (workflows / "sandbox-image-promote.yml").write_text(
        "permissions: {}\njobs:\n"
        "  plan:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    (workflows / "sandbox-image-publish.yml").write_text(
        "permissions: {}\njobs:\n"
        "  publish:\n"
        "    environment: sandbox-image-package-writer\n"
    )
    (workflows / "unsafe.yml").write_text(
        "jobs:\n  check:\n    runs-on: ubuntu-latest\n"
    )

    with pytest.raises(ValueError, match="explicit top-level permissions"):
        github_module.verify_promotion_workflows(workflows)


def test_promotion_workflow_audit_rejects_a_second_package_writer(
    tmp_path: Path,
) -> None:
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "sandbox-image-promotion-gate.yml").write_text(
        "permissions: {}\njobs:\n"
        "  reconcile:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    (workflows / "sandbox-image-promote.yml").write_text(
        "permissions: {}\njobs:\n"
        "  plan:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    for name in ("sandbox-image-publish.yml", "unsafe.yml"):
        (workflows / name).write_text(
            "permissions: {}\njobs:\n"
            "  publish:\n"
            "    environment: sandbox-image-package-writer\n"
        )

    with pytest.raises(ValueError, match="package writer environment"):
        github_module.verify_promotion_workflows(workflows)


def test_promotion_workflow_audit_rejects_a_second_production_workflow(
    tmp_path: Path,
) -> None:
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "sandbox-image-promotion-gate.yml").write_text(
        "permissions: {}\njobs:\n"
        "  reconcile:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    (workflows / "sandbox-image-promote.yml").write_text(
        "permissions: {}\njobs:\n"
        "  plan:\n"
        "    environment: sandbox-image-promotion-status\n"
        "  retag:\n"
        "    environment: sandbox-image-production\n"
    )
    (workflows / "sandbox-image-publish.yml").write_text(
        "permissions: {}\njobs:\n"
        "  publish:\n"
        "    environment: sandbox-image-package-writer\n"
    )
    (workflows / "unsafe.yaml").write_text(
        "permissions: {}\njobs:\n"
        "  publish:\n"
        "    environment: SANDBOX-IMAGE-PRODUCTION\n"
    )

    with pytest.raises(ValueError, match="production environment"):
        github_module.verify_promotion_workflows(workflows)


def test_proposed_workflow_audit_rejects_changes_to_the_status_writer(
    tmp_path: Path,
) -> None:
    trusted = tmp_path / "trusted"
    proposed = tmp_path / "proposed"
    trusted.mkdir()
    proposed.mkdir()
    trusted_content = (
        "permissions: {}\njobs:\n"
        "  reconcile:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    promotion = (
        trusted_content
        + "  retag:\n"
        "    environment: sandbox-image-production\n"
    )
    publisher = (
        "permissions: {}\njobs:\n"
        "  publish:\n"
        "    environment: sandbox-image-package-writer\n"
    )
    (trusted / "sandbox-image-promotion-gate.yml").write_text(trusted_content)
    (trusted / "sandbox-image-promote.yml").write_text(promotion)
    (trusted / "sandbox-image-publish.yml").write_text(publisher)
    (trusted / "sandbox-image-merge-signal.yml").write_text(MERGE_SIGNAL_WORKFLOW)
    (proposed / "sandbox-image-publish.yml").write_text(publisher)
    (proposed / "sandbox-image-promote.yml").write_text(promotion)
    (proposed / "sandbox-image-merge-signal.yml").write_text(MERGE_SIGNAL_WORKFLOW)
    (proposed / "sandbox-image-promotion-gate.yml").write_text(
        trusted_content + "    steps:\n      - run: printenv\n"
    )

    with pytest.raises(ValueError, match="trusted status workflow changed"):
        github_module.verify_promotion_workflows(
            proposed,
            trusted_workflow_root=trusted,
        )


def test_proposed_workflow_audit_rejects_merge_signal_changes(
    tmp_path: Path,
) -> None:
    trusted = tmp_path / "trusted"
    proposed = tmp_path / "proposed"
    trusted.mkdir()
    proposed.mkdir()
    status = (
        "permissions: {}\njobs:\n"
        "  reconcile:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    promotion = (
        status
        + "  retag:\n"
        "    environment: sandbox-image-production\n"
    )
    publisher = (
        "permissions: {}\njobs:\n"
        "  publish:\n"
        "    environment: sandbox-image-package-writer\n"
    )
    for root in (trusted, proposed):
        (root / "sandbox-image-promotion-gate.yml").write_text(status)
        (root / "sandbox-image-promote.yml").write_text(promotion)
        (root / "sandbox-image-publish.yml").write_text(publisher)
    (trusted / "sandbox-image-merge-signal.yml").write_text(MERGE_SIGNAL_WORKFLOW)
    (proposed / "sandbox-image-merge-signal.yml").write_text(
        MERGE_SIGNAL_WORKFLOW + "    timeout-minutes: 5\n"
    )

    with pytest.raises(ValueError, match="trusted merge signal workflow changed"):
        github_module.verify_promotion_workflows(
            proposed,
            trusted_workflow_root=trusted,
        )


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        ("identical", None),
        ("changed", "trusted post-approval policy changed"),
        ("missing", "cannot audit promotion authority file"),
        ("symlink", "promotion authority file must be a regular file"),
        ("directory", "promotion authority file must be a regular file"),
    ],
)
def test_proposed_authority_audit_rejects_policy_tampering(
    tmp_path: Path,
    mutation: str,
    message: str | None,
) -> None:
    trusted_root = tmp_path / "trusted"
    proposed_root = tmp_path / "proposed"
    status = (
        "permissions: {}\njobs:\n"
        "  reconcile:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    workflows = {
        "sandbox-image-promotion-gate.yml": status,
        "sandbox-image-promote.yml": (
            status
            + "  retag:\n"
            "    environment: sandbox-image-production\n"
        ),
        "sandbox-image-publish.yml": (
            "permissions: {}\njobs:\n"
            "  publish:\n"
            "    environment: sandbox-image-package-writer\n"
        ),
        "sandbox-image-merge-signal.yml": MERGE_SIGNAL_WORKFLOW,
    }
    for root in (trusted_root, proposed_root):
        workflow_root = root / ".github/workflows"
        workflow_root.mkdir(parents=True)
        for name, content in workflows.items():
            (workflow_root / name).write_text(content)
        policy = root / github_module.POST_APPROVAL_POLICY
        policy.parent.mkdir(parents=True)
        policy.write_text("allow\n")

    proposed_policy = proposed_root / github_module.POST_APPROVAL_POLICY
    if mutation == "changed":
        proposed_policy.write_text("deny\n")
    elif mutation == "missing":
        proposed_policy.unlink()
    elif mutation == "symlink":
        proposed_policy.unlink()
        proposed_policy.symlink_to(
            trusted_root / github_module.POST_APPROVAL_POLICY
        )
    elif mutation == "directory":
        proposed_policy.unlink()
        proposed_policy.mkdir()

    if message is None:
        github_module.verify_promotion_workflows(
            proposed_root / ".github/workflows",
            trusted_workflow_root=trusted_root / ".github/workflows",
            repository_root=proposed_root,
            trusted_repository_root=trusted_root,
        )
    else:
        with pytest.raises(ValueError, match=message):
            github_module.verify_promotion_workflows(
                proposed_root / ".github/workflows",
                trusted_workflow_root=trusted_root / ".github/workflows",
                repository_root=proposed_root,
                trusted_repository_root=trusted_root,
            )


@pytest.mark.parametrize("link_kind", ["workflow-file", "workflow-root", "parent"])
def test_proposed_workflow_audit_rejects_symlinked_authority(
    tmp_path: Path,
    link_kind: str,
) -> None:
    trusted = tmp_path / "trusted/.github/workflows"
    proposed = tmp_path / "proposed/.github/workflows"
    trusted.mkdir(parents=True)
    status = (
        "permissions: {}\njobs:\n"
        "  reconcile:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    workflows = {
        "sandbox-image-promotion-gate.yml": status,
        "sandbox-image-promote.yml": (
            status
            + "  retag:\n"
            "    environment: sandbox-image-production\n"
        ),
        "sandbox-image-publish.yml": (
            "permissions: {}\njobs:\n"
            "  publish:\n"
            "    environment: sandbox-image-package-writer\n"
        ),
        "sandbox-image-merge-signal.yml": MERGE_SIGNAL_WORKFLOW,
    }
    for name, content in workflows.items():
        (trusted / name).write_text(content)

    if link_kind == "parent":
        proposed.parent.parent.mkdir()
        proposed.parent.symlink_to(trusted.parent, target_is_directory=True)
    elif link_kind == "workflow-root":
        proposed.parent.mkdir(parents=True)
        proposed.symlink_to(trusted, target_is_directory=True)
    else:
        proposed.mkdir(parents=True)
        for name, content in workflows.items():
            (proposed / name).write_text(content)
        linked = proposed / "sandbox-image-promotion-gate.yml"
        linked.unlink()
        linked.symlink_to(trusted / linked.name)

    with pytest.raises(ValueError, match="symlink"):
        github_module.verify_promotion_workflows(
            proposed,
            trusted_workflow_root=trusted,
        )


@pytest.mark.parametrize(
    "signal",
    [
        MERGE_SIGNAL_WORKFLOW.replace(
            "name: Sandbox image merge signal",
            "name: Different workflow",
        ),
        MERGE_SIGNAL_WORKFLOW.replace("merge_group", "pull_request"),
    ],
)
def test_promotion_workflow_audit_rejects_invalid_merge_signal(
    tmp_path: Path,
    signal: str,
) -> None:
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "sandbox-image-promotion-gate.yml").write_text(
        "permissions: {}\njobs:\n"
        "  reconcile:\n"
        "    environment: sandbox-image-promotion-status\n"
    )
    (workflows / "sandbox-image-promote.yml").write_text(
        "permissions: {}\njobs:\n"
        "  plan:\n"
        "    environment: sandbox-image-promotion-status\n"
        "  retag:\n"
        "    environment: sandbox-image-production\n"
    )
    (workflows / "sandbox-image-publish.yml").write_text(
        "permissions: {}\njobs:\n"
        "  publish:\n"
        "    environment: sandbox-image-package-writer\n"
    )
    (workflows / "sandbox-image-merge-signal.yml").write_text(signal)

    with pytest.raises(ValueError, match="merge signal workflow"):
        github_module.verify_promotion_workflows(workflows)


def test_production_environment_requires_reviewers_and_only_main() -> None:
    environment_endpoint = (
        "repos/kenn-io/ghosthub/environments/sandbox-image-production"
    )
    policies_endpoint = environment_endpoint + "/deployment-branch-policies"
    runner = ScriptedRunner(
        {
            ("gh", "api", environment_endpoint): json.dumps(
                {
                    "protection_rules": [
                        {
                            "type": "required_reviewers",
                            "reviewers": [{"type": "User"}],
                        }
                    ],
                    "deployment_branch_policy": {
                        "protected_branches": False,
                        "custom_branch_policies": True,
                    },
                }
            ),
            ("gh", "api", policies_endpoint): json.dumps(
                {
                    "total_count": 1,
                    "branch_policies": [{"name": "main", "type": "branch"}],
                }
            ),
            **production_credential_responses(environment_endpoint),
        }
    )

    verify_production_environment(runner)


def test_production_environment_rejects_missing_approval() -> None:
    endpoint = "repos/kenn-io/ghosthub/environments/sandbox-image-production"
    runner = ScriptedRunner(
        {
            ("gh", "api", endpoint): json.dumps(
                {
                    "protection_rules": [],
                    "deployment_branch_policy": {
                        "protected_branches": False,
                        "custom_branch_policies": True,
                    },
                }
            )
        }
    )

    with pytest.raises(ValueError, match="reviewer"):
        verify_production_environment(runner)


def test_production_environment_rejects_main_tag_policy() -> None:
    endpoint = "repos/kenn-io/ghosthub/environments/sandbox-image-production"
    runner = ScriptedRunner(
        {
            ("gh", "api", endpoint): json.dumps(
                {
                    "protection_rules": [
                        {
                            "type": "required_reviewers",
                            "reviewers": [{"type": "User"}],
                        }
                    ],
                    "deployment_branch_policy": {
                        "protected_branches": False,
                        "custom_branch_policies": True,
                    },
                }
            ),
            ("gh", "api", endpoint + "/deployment-branch-policies"): json.dumps(
                {
                    "total_count": 1,
                    "branch_policies": [{"name": "main", "type": "tag"}],
                }
            ),
        }
    )

    with pytest.raises(ValueError, match="only main"):
        verify_production_environment(runner)


def test_production_environment_fingerprint_changes_with_reviewers() -> None:
    endpoint = "repos/kenn-io/ghosthub/environments/sandbox-image-production"
    policies = json.dumps(
        {
            "total_count": 1,
            "branch_policies": [{"name": "main", "type": "branch"}],
        }
    )
    responses: list[ScriptedRunner] = []
    for login in ("reviewer-a", "reviewer-b"):
        responses.append(
            ScriptedRunner(
                {
                    ("gh", "api", endpoint): json.dumps(
                        {
                            "protection_rules": [
                                {
                                    "type": "required_reviewers",
                                    "reviewers": [
                                        {
                                            "type": "User",
                                            "reviewer": {"login": login, "id": 42},
                                        }
                                    ],
                                }
                            ],
                            "deployment_branch_policy": {
                                "protected_branches": False,
                                "custom_branch_policies": True,
                            },
                        }
                    ),
                    (
                        "gh",
                        "api",
                        endpoint + "/deployment-branch-policies",
                    ): policies,
                    **production_credential_responses(endpoint),
                }
            )
        )

    assert verify_production_environment(responses[0]) != verify_production_environment(
        responses[1]
    )


def test_production_environment_fingerprint_changes_after_secret_rotation() -> None:
    endpoint = "repos/kenn-io/ghosthub/environments/sandbox-image-production"
    policy_responses = {
        ("gh", "api", endpoint): json.dumps(
            {
                "protection_rules": [
                    {
                        "type": "required_reviewers",
                        "reviewers": [{"type": "User", "reviewer": {"id": 42}}],
                    }
                ],
                "deployment_branch_policy": {
                    "protected_branches": False,
                    "custom_branch_policies": True,
                },
            }
        ),
        ("gh", "api", endpoint + "/deployment-branch-policies"): json.dumps(
            {
                "total_count": 1,
                "branch_policies": [{"name": "main", "type": "branch"}],
            }
        ),
    }
    before = ScriptedRunner(
        {
            **policy_responses,
            **production_credential_responses(endpoint),
        }
    )
    after = ScriptedRunner(
        {
            **policy_responses,
            **production_credential_responses(
                endpoint, secret_updated_at="2026-08-14T00:00:00Z"
            ),
        }
    )

    assert verify_production_environment(before) != verify_production_environment(after)


def test_production_environment_rejects_unexpected_credentials() -> None:
    endpoint = "repos/kenn-io/ghosthub/environments/sandbox-image-production"
    runner = ScriptedRunner(
        {
            ("gh", "api", endpoint): json.dumps(
                {
                    "protection_rules": [
                        {
                            "type": "required_reviewers",
                            "reviewers": [{"type": "User"}],
                        }
                    ],
                    "deployment_branch_policy": {
                        "protected_branches": False,
                        "custom_branch_policies": True,
                    },
                }
            ),
            ("gh", "api", endpoint + "/deployment-branch-policies"): json.dumps(
                {
                    "total_count": 1,
                    "branch_policies": [{"name": "main", "type": "branch"}],
                }
            ),
            ("gh", "api", endpoint + "/variables"): json.dumps(
                {
                    "variables": [
                        {"name": "SANDBOX_PROMOTION_APP_ID", "value": "424242"},
                        {
                            "name": "SANDBOX_PROMOTION_APP_CLIENT_ID",
                            "value": "Iv1.example",
                        },
                    ]
                }
            ),
            ("gh", "api", endpoint + "/secrets"): json.dumps(
                {
                    "secrets": [
                        {
                            "name": name,
                            "created_at": "2026-08-12T00:00:00Z",
                            "updated_at": "2026-08-13T00:00:00Z",
                        }
                        for name in (
                            "SANDBOX_PROMOTION_APP_PRIVATE_KEY",
                            "SANDBOX_PACKAGE_WRITER_USERNAME",
                            "SANDBOX_PACKAGE_WRITER_TOKEN",
                            "UNEXPECTED_SECRET",
                        )
                    ]
                }
            ),
        }
    )

    with pytest.raises(ValueError, match="credential set"):
        verify_production_environment(runner, expected_app_id=424242)


def test_package_writer_environment_is_main_only_with_exact_secrets() -> None:
    endpoint = "repos/kenn-io/ghosthub/environments/sandbox-image-package-writer"
    runner = ScriptedRunner(
        {
            ("gh", "api", endpoint): json.dumps(
                {
                    "protection_rules": [{"type": "branch_policy"}],
                    "deployment_branch_policy": {
                        "protected_branches": False,
                        "custom_branch_policies": True,
                    },
                }
            ),
            ("gh", "api", endpoint + "/deployment-branch-policies"): json.dumps(
                {
                    "total_count": 1,
                    "branch_policies": [{"name": "main", "type": "branch"}],
                }
            ),
            ("gh", "api", endpoint + "/secrets"): json.dumps(
                {
                    "total_count": 2,
                    "secrets": [
                        {"name": "SANDBOX_PACKAGE_WRITER_USERNAME"},
                        {"name": "SANDBOX_PACKAGE_WRITER_TOKEN"},
                    ],
                }
            ),
        }
    )

    github_module.verify_package_writer_environment(runner)


def test_promotion_rescans_the_exact_candidate_digest(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write_inputs(tmp_path)
    candidate = ImageReference.parse(
        "ghcr.io/kenn-io/ghosthub-sandbox:candidate-"
        + "b" * 40
        + "@"
        + ARM64_DIGEST
    )
    scanned: list[str] = []

    def scan_reference(root: Path, image: str, runner: object) -> object:
        del root, runner
        scanned.append(image)
        return type("Artifacts", (), {"findings": ()})()

    monkeypatch.setattr(github_module, "scan_reference", scan_reference)

    verify_current_candidate_policy(tmp_path, candidate, FakeRunner())

    assert scanned == [candidate.canonical]


@pytest.mark.parametrize("failure", ["dirty", "default", "unpushed"])
def test_local_promotion_head_rejects_unsafe_branch_state(
    tmp_path: Path, failure: str
) -> None:
    head = "d" * 40
    responses = {
        ("git", "-C", str(tmp_path), "status", "--porcelain"): (
            " M file\n" if failure == "dirty" else ""
        ),
        ("git", "-C", str(tmp_path), "symbolic-ref", "--short", "HEAD"): (
            "main\n" if failure == "default" else "sandbox-pin\n"
        ),
        ("git", "-C", str(tmp_path), "rev-parse", "HEAD"): head + "\n",
        ("git", "-C", str(tmp_path), "rev-parse", "@{upstream}"): (
            ("e" * 40 if failure == "unpushed" else head) + "\n"
        ),
    }
    with pytest.raises(ValueError):
        local_promotion_head(tmp_path, ScriptedRunner(responses))


def test_dispatch_promotion_uses_default_branch_code_and_exact_head(
    tmp_path: Path,
) -> None:
    head = "d" * 40
    image = "ghcr.io/kenn-io/ghosthub-sandbox@" + ARM64_DIGEST
    (tmp_path / "SANDBOX_IMAGE").write_text(image + "\n")
    responses = {
        ("git", "-C", str(tmp_path), "status", "--porcelain"): "",
        (
            "git",
            "-C",
            str(tmp_path),
            "symbolic-ref",
            "--short",
            "HEAD",
        ): "sandbox-pin\n",
        ("git", "-C", str(tmp_path), "rev-parse", "HEAD"): head + "\n",
        ("git", "-C", str(tmp_path), "rev-parse", "@{upstream}"): head + "\n",
    }
    dispatch = (
        "gh",
        "api",
        "--method",
        "POST",
        "repos/kenn-io/ghosthub/dispatches",
        "-f",
        "event_type=sandbox-image-promote",
        "-f",
        f"client_payload[evidence_commit]={head}",
        "-f",
        f"client_payload[digest]={ARM64_DIGEST}",
        "-f",
        "client_payload[version]=0.1.0",
    )
    responses[dispatch] = ""
    runner = ScriptedRunner(responses)
    assert (
        dispatch_promotion(tmp_path, ImageReference.parse(image), "0.1.0", runner)
        == head
    )
    assert dispatch in runner.calls


def test_dispatch_promotion_rejects_symlinked_pin(tmp_path: Path) -> None:
    head = "d" * 40
    image = "ghcr.io/kenn-io/ghosthub-sandbox@" + ARM64_DIGEST
    target = tmp_path / "pin-target"
    target.write_text(image + "\n")
    (tmp_path / "SANDBOX_IMAGE").symlink_to(target)
    responses = {
        ("git", "-C", str(tmp_path), "status", "--porcelain"): "",
        (
            "git",
            "-C",
            str(tmp_path),
            "symbolic-ref",
            "--short",
            "HEAD",
        ): "sandbox-pin\n",
        ("git", "-C", str(tmp_path), "rev-parse", "HEAD"): head + "\n",
        ("git", "-C", str(tmp_path), "rev-parse", "@{upstream}"): head + "\n",
    }

    with pytest.raises(ValueError, match="regular file"):
        dispatch_promotion(
            tmp_path,
            ImageReference.parse(image),
            "0.1.0",
            ScriptedRunner(responses),
        )


def test_trusted_evidence_requires_exact_open_pull_request_diff(tmp_path: Path) -> None:
    write_inputs(tmp_path)
    report_path = write_report(tmp_path)
    report_bytes = report_path.read_bytes()
    commit = "d" * 40
    report_name = report_path.relative_to(tmp_path).as_posix()
    pin_bytes = ("ghcr.io/kenn-io/ghosthub-sandbox@" + ARM64_DIGEST + "\n").encode()
    pin_blob = "e" * 40
    report_blob = "f" * 40
    pulls_endpoint = f"repos/kenn-io/ghosthub/commits/{commit}/pulls"
    files_endpoint = "repos/kenn-io/ghosthub/pulls/42/files?per_page=100"
    tree_endpoint = f"repos/kenn-io/ghosthub/git/trees/{commit}?recursive=1"
    responses = {
        ("git", "-C", str(tmp_path), "rev-parse", "HEAD"): "a" * 40 + "\n",
        ("gh", "api", pulls_endpoint): json.dumps(
            [
                {
                    "number": 42,
                    "state": "open",
                    "base": {"ref": "main", "sha": "a" * 40},
                    "head": {"sha": commit},
                }
            ]
        ),
        ("gh", "api", "--paginate", "--slurp", files_endpoint): json.dumps(
            [[{"filename": "SANDBOX_IMAGE"}, {"filename": report_name}]]
        ),
        ("gh", "api", tree_endpoint): json.dumps(
            {
                "sha": "0" * 40,
                "url": "https://api.github.com/repos/kenn-io/ghosthub/git/trees/"
                + "0" * 40,
                "tree": [
                    {
                        "path": "SANDBOX_IMAGE",
                        "mode": "100644",
                        "type": "blob",
                        "sha": pin_blob,
                        "size": len(pin_bytes),
                        "url": "https://api.github.com/repos/kenn-io/ghosthub/git/blobs/"
                        + pin_blob,
                    },
                    {
                        "path": report_name,
                        "mode": "100644",
                        "type": "blob",
                        "sha": report_blob,
                        "size": len(report_bytes),
                        "url": "https://api.github.com/repos/kenn-io/ghosthub/git/blobs/"
                        + report_blob,
                    },
                ],
                "truncated": False,
            }
        ),
        ("gh", "api", f"repos/kenn-io/ghosthub/git/blobs/{pin_blob}"): json.dumps(
            {
                "sha": pin_blob,
                "encoding": "base64",
                "content": base64.b64encode(pin_bytes).decode(),
                "size": len(pin_bytes),
                "url": "https://api.github.com/repos/kenn-io/ghosthub/git/blobs/"
                + pin_blob,
            }
        ),
        (
            "gh",
            "api",
            f"repos/kenn-io/ghosthub/git/blobs/{report_blob}",
        ): json.dumps(
            {
                "sha": report_blob,
                "encoding": "base64",
                "content": base64.b64encode(report_bytes).decode(),
                "size": len(report_bytes),
                "url": "https://api.github.com/repos/kenn-io/ghosthub/git/blobs/"
                + report_blob,
            }
        ),
    }
    evidence = verify_promotion_evidence(
        tmp_path,
        commit,
        ARM64_DIGEST,
        "0.1.0",
        ScriptedRunner(responses),
        now=datetime.now(UTC),
    )
    assert evidence.commit == commit
    assert evidence.pull_request == 42
