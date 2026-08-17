from __future__ import annotations

import json
import re
import secrets
import shlex
import shutil
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .model import CheckResult, ImageReference
from .process import Runner

PURPOSE_LABEL = "io.ghosthub.purpose"
DIGEST_LABEL = "io.ghosthub.digest"
VET_PURPOSE = "sandbox-image-vet"
PROVIDER_VERSION = "1.2.2"
PROVIDER_PATTERN = re.compile(
    r"^container CLI version ([0-9]+\.[0-9]+\.[0-9]+)(?=\s|$)"
)
DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}")
NAME_PATTERN = re.compile(r"ghosthub-vet-[0-9a-f]{12}-[0-9a-f]{6}")


@dataclass(frozen=True)
class AppleProviderInfo:
    macos_version: str
    architecture: str
    provider_version: str


@dataclass(frozen=True)
class AppleImageIdentity:
    digest: str
    source_commit: str
    image_version: str


@dataclass(frozen=True)
class ManagedFixture:
    name: str
    digest: str
    purpose: str = VET_PURPOSE
    schema_version: int = 1

    def __post_init__(self) -> None:
        if NAME_PATTERN.fullmatch(self.name) is None:
            raise ValueError("invalid Apple vet fixture name")
        if DIGEST_PATTERN.fullmatch(self.digest) is None:
            raise ValueError("invalid Apple vet fixture digest")
        if self.purpose != VET_PURPOSE or self.schema_version != 1:
            raise ValueError("invalid Apple vet fixture identity")

    @classmethod
    def load(cls, path: Path) -> ManagedFixture:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(
                f"cannot load Apple vet fixture identity: {path}"
            ) from error
        if not isinstance(payload, dict) or set(payload) != {
            "name",
            "digest",
            "purpose",
            "schema_version",
        }:
            raise ValueError("Apple vet fixture identity uses an invalid schema")
        try:
            return cls(**payload)
        except TypeError as error:
            raise ValueError("Apple vet fixture identity has invalid values") from error

    def write(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(asdict(self), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


def canonical_report_path(root: Path, digest: str) -> Path:
    if DIGEST_PATTERN.fullmatch(digest) is None:
        raise ValueError("invalid report digest")
    return root / "images/sandbox/reports" / f"{digest.replace(':', '-')}.json"


def require_supported_apple_provider(runner: Runner) -> AppleProviderInfo:
    system = runner.run(("uname", "-s")).stdout.strip()
    if system != "Darwin":
        raise ValueError("Apple sandbox image vetting requires macOS")
    architecture = runner.run(("uname", "-m")).stdout.strip()
    if architecture != "arm64":
        raise ValueError("Apple sandbox image vetting requires Apple silicon")
    macos_version = runner.run(("sw_vers", "-productVersion")).stdout.strip()
    version_output = runner.run(("container", "--version")).stdout.strip()
    match = PROVIDER_PATTERN.match(version_output)
    if match is None or match.group(1) != PROVIDER_VERSION:
        raise ValueError(f"Apple container {PROVIDER_VERSION} is required")
    return AppleProviderInfo(macos_version, architecture, match.group(1))


class AppleVettingHarness:
    def __init__(self, root: Path, runner: Runner) -> None:
        self.root = root
        self.runner = runner

    def create_fixture(
        self,
        image: str,
        digest: str,
        state_path: Path,
        *,
        extra_arguments: tuple[str, ...] = (),
    ) -> ManagedFixture:
        require_supported_apple_provider(self.runner)
        suffix = secrets.token_hex(3)
        fixture = ManagedFixture(
            f"ghosthub-vet-{digest.removeprefix('sha256:')[:12]}-{suffix}", digest
        )
        fixture.write(state_path)
        self.runner.run(
            (
                "container",
                "create",
                "--name",
                fixture.name,
                "--label",
                f"{PURPOSE_LABEL}={fixture.purpose}",
                "--label",
                f"{DIGEST_LABEL}={fixture.digest}",
                "--platform",
                "linux/arm64",
                "--init",
                "--user",
                "ghosthub",
                "--env",
                "LANG=C.UTF-8",
                *extra_arguments,
                image,
            )
        )
        return fixture

    def exercise_candidate(
        self,
        image: ImageReference,
        state_path: Path,
        *,
        pull: bool = True,
        verify_attestations: bool = True,
        runtime_image: str | None = None,
    ) -> tuple[
        AppleProviderInfo,
        AppleImageIdentity,
        tuple[CheckResult, ...],
        tuple[str, ...],
    ]:
        provider = require_supported_apple_provider(self.runner)
        checks: list[CheckResult] = [
            CheckResult("architecture", "pass", "Apple silicon arm64"),
            CheckResult(
                "provider-version", "pass", f"Apple container {PROVIDER_VERSION}"
            ),
            CheckResult("digest", "pass", "exact digest reference accepted"),
        ]
        attestations: tuple[str, ...] = ()
        if verify_attestations:
            attestations = self._verify_attestations(image)
            checks.append(
                CheckResult("attestations", "pass", "provenance and SBOM verified")
            )
        else:
            checks.append(
                CheckResult("attestations", "pass", "local smoke; not canonical")
            )
        selected_image = runtime_image or image.canonical
        if pull:
            self.runner.run(
                (
                    "container",
                    "image",
                    "pull",
                    "--platform",
                    "linux/arm64",
                    selected_image,
                )
            )
        identity = self._inspect_image_identity(selected_image)
        if identity.digest != image.digest:
            raise ValueError("Apple image digest does not match requested digest")

        fixture_root = state_path.parent / (state_path.stem + "-repos")
        fixture_root.mkdir(parents=True, exist_ok=False)
        try:
            mount_arguments, paths = self._prepare_git_fixtures(fixture_root)
            fixture = self.create_fixture(
                selected_image,
                image.digest,
                state_path,
                extra_arguments=mount_arguments,
            )
            self.runner.run(("container", "start", fixture.name))
            self._exec(fixture, "/opt/ghosthub/image-contract.sh")
            checks.extend(
                (
                    CheckResult("ordinary-user", "pass", "default user is ghosthub"),
                    CheckResult("sudo", "pass", "passwordless sudo works"),
                    CheckResult("locale", "pass", "default locale is UTF-8"),
                    CheckResult("terminfo", "pass", "tmux-256color is installed"),
                    CheckResult("ssh-client", "pass", "OpenSSH client is installed"),
                )
            )
            user = self._exec(fixture, "id -un", user="ghosthub").strip()
            if user != "ghosthub":
                raise ValueError("explicit Apple exec user was not honored")
            checks.append(
                CheckResult("explicit-exec-user", "pass", "exec user is ghosthub")
            )
            self._exec(
                fixture,
                "curl -fsS https://api.github.com/zen >/dev/null",
            )
            checks.append(CheckResult("https", "pass", "HTTPS request succeeded"))
            self._exec(
                fixture,
                'touch "$HOME"/.ghosthub-vet-home && '
                "sudo apt-get update >/dev/null && "
                "sudo apt-get install -y --no-install-recommends bc >/dev/null",
            )
            checks.append(CheckResult("live-apt", "pass", "live APT install succeeded"))
            self._exec(
                fixture,
                "bash -c 'sleep 1 & echo $! > \"$HOME\"/.ghosthub-vet-orphan'",
            )
            self._exec(
                fixture,
                'sleep 2; pid=$(cat "$HOME"/.ghosthub-vet-orphan); '
                "test ! -e /proc/$pid",
            )
            checks.append(CheckResult("init", "pass", "PID 1 reaped an orphan"))
            self._assert_git_contract(fixture, paths, checks)
            self.runner.run(("container", "stop", fixture.name))
            self.runner.run(("container", "start", fixture.name))
            self._exec(fixture, 'test -f "$HOME/.ghosthub-vet-home"')
            checks.append(
                CheckResult("stop-start-home", "pass", "home marker survived restart")
            )
            self._exec(fixture, "command -v bc >/dev/null")
            checks.append(
                CheckResult(
                    "stop-start-package", "pass", "installed package survived restart"
                )
            )
            self._assert_git_contract(
                fixture,
                paths,
                checks,
                phase="stop-start",
            )
            inspected = _inspect_fixture(fixture, self.runner)
            configuration = inspected.get("configuration")
            if (
                not isinstance(configuration, dict)
                or configuration.get("useInit") is not True
            ):
                raise ValueError("Apple container did not retain --init")
            return provider, identity, tuple(checks), attestations
        finally:
            if not state_path.exists():
                shutil.rmtree(fixture_root, ignore_errors=True)

    def _verify_attestations(self, image: ImageReference) -> tuple[str, ...]:
        identities = (
            "https://slsa.dev/provenance/v0.2",
            "https://spdx.dev/Document/v2.3",
        )
        for predicate in identities:
            self.runner.run(
                (
                    "gh",
                    "attestation",
                    "verify",
                    f"oci://{image.canonical}",
                    "--repo",
                    "kenn-io/ghosthub",
                    "--predicate-type",
                    predicate,
                )
            )
        return identities

    def _inspect_image_identity(self, image: str) -> AppleImageIdentity:
        try:
            values = _object_list(
                json.loads(
                    self.runner.run(("container", "image", "inspect", image)).stdout
                ),
                "image inspect",
            )
            if len(values) != 1:
                raise ValueError("Apple image inspect identity is ambiguous")
            variants = values[0]["variants"]
            arm64 = next(
                variant
                for variant in variants
                if variant["config"]["architecture"] == "arm64"
                and variant["config"]["os"] == "linux"
            )
            digest = arm64["digest"]
            labels = arm64["config"]["config"]["Labels"]
            source_commit = labels["org.opencontainers.image.revision"]
            image_version = labels["org.opencontainers.image.version"]
        except (
            json.JSONDecodeError,
            KeyError,
            StopIteration,
            TypeError,
        ) as error:
            raise ValueError("Apple image identity is invalid") from error
        if DIGEST_PATTERN.fullmatch(digest) is None:
            raise ValueError("Apple image digest is invalid")
        if re.fullmatch(r"[0-9a-f]{40}", source_commit) is None:
            raise ValueError("Apple image source revision is invalid")
        if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", image_version) is None:
            raise ValueError("Apple image version is invalid")
        return AppleImageIdentity(digest, source_commit, image_version)

    def _prepare_git_fixtures(
        self, fixture_root: Path
    ) -> tuple[tuple[str, ...], dict[str, Path]]:
        standard = fixture_root / "standard"
        linked_main = fixture_root / "linked-main"
        linked = fixture_root / "linked"
        for repository in (standard, linked_main):
            self.runner.run(
                ("git", "init", "--initial-branch", "main", str(repository))
            )
            marker = repository / "README.md"
            marker.write_text("sandbox image vet\n", encoding="utf-8")
            self.runner.run(("git", "-C", str(repository), "add", "README.md"))
            self.runner.run(
                ("git", "-C", str(repository), "config", "user.name", "Ghosthub Vet")
            )
            self.runner.run(
                (
                    "git",
                    "-C",
                    str(repository),
                    "config",
                    "user.email",
                    "sandbox-vet@ghosthub.invalid",
                )
            )
            self.runner.run(
                ("git", "-C", str(repository), "commit", "-m", "Initialize fixture")
            )
        self.runner.run(
            (
                "git",
                "-C",
                str(linked_main),
                "worktree",
                "add",
                "-b",
                "linked",
                str(linked),
            )
        )
        common = linked_main / ".git"
        gitdir_output = self.runner.run(
            ("git", "-C", str(linked), "rev-parse", "--absolute-git-dir")
        ).stdout.strip()
        linked_gitdir = Path(gitdir_output)
        paths = {
            "standard": standard,
            "standard_git": standard / ".git",
            "linked": linked,
            "linked_gitfile": linked / ".git",
            "common": common,
            "linked_gitdir": linked_gitdir,
        }
        mount_paths = (
            standard,
            standard / ".git",
            linked,
            common,
            common / "worktrees",
            linked_gitdir,
        )
        read_only = (
            standard / ".git/config",
            standard / ".git/hooks",
            linked / ".git",
            common / "config",
            common / "hooks",
            linked_gitdir / "commondir",
            linked_gitdir / "gitdir",
        )
        arguments: list[str] = []
        for path in mount_paths:
            arguments.extend(("--mount", f"type=bind,source={path},target={path}"))
        for path in read_only:
            if not path.exists():
                raise ValueError(f"Git mount protection target is missing: {path}")
            arguments.extend(("--read-only-path", str(path)))
        return tuple(arguments), paths

    def _assert_git_contract(
        self,
        fixture: ManagedFixture,
        paths: dict[str, Path],
        checks: list[CheckResult],
        *,
        phase: str = "initial",
    ) -> None:
        after_restart = phase == "stop-start"
        commit_message = (
            "Vetted after restart" if after_restart else "Vetted in sandbox"
        )
        check_prefix = "stop-start-git" if after_restart else "git"
        detail = (
            "shared commit succeeded after restart"
            if after_restart
            else "shared commit succeeded"
        )
        for name in ("standard", "linked"):
            repository = paths[name]
            script = (
                f"cd {shlex.quote(str(repository))} && "
                f"printf '%s\\n' {shlex.quote(name)} >> README.md && "
                "git add README.md && "
                f"git commit -m {shlex.quote(commit_message)} >/dev/null"
            )
            self._exec(fixture, script)
            subject = self.runner.run(
                ("git", "-C", str(repository), "log", "-1", "--format=%s")
            ).stdout.strip()
            if subject != commit_message:
                raise ValueError(f"{name} sandbox commit was not visible on the host")
            checks.append(CheckResult(f"{check_prefix}-{name}", "pass", detail))
        self._assert_mount_protection(
            fixture,
            paths,
            checks,
            check_name=(
                "stop-start-mount-protection" if after_restart else "mount-protection"
            ),
            detail=(
                "Git protection attempts failed after restart"
                if after_restart
                else "Git protection attempts failed"
            ),
        )

    def _assert_mount_protection(
        self,
        fixture: ManagedFixture,
        paths: dict[str, Path],
        checks: list[CheckResult],
        *,
        check_name: str,
        detail: str,
    ) -> None:
        protected_files = (
            paths["standard_git"] / "config",
            paths["linked_gitfile"],
            paths["common"] / "config",
            paths["linked_gitdir"] / "commondir",
            paths["linked_gitdir"] / "gitdir",
        )
        for path in protected_files:
            quoted = shlex.quote(str(path))
            self._exec(
                fixture,
                f"if printf x >> {quoted} 2>/dev/null; then exit 1; fi",
            )
        for hooks in (
            paths["standard_git"] / "hooks",
            paths["common"] / "hooks",
        ):
            probe = shlex.quote(str(hooks / ".ghosthub-vet-write"))
            self._exec(
                fixture,
                f"if printf x > {probe} 2>/dev/null; then exit 1; fi",
            )
        for path in (
            paths["standard_git"],
            paths["common"] / "worktrees",
            paths["linked_gitdir"],
        ):
            quoted = shlex.quote(str(path))
            self._exec(
                fixture,
                f"if mv {quoted} {quoted}.moved 2>/dev/null; then exit 1; fi",
            )
        checks.append(CheckResult(check_name, "pass", detail))

    def _exec(
        self, fixture: ManagedFixture, script: str, *, user: str = "ghosthub"
    ) -> str:
        return self.runner.run(
            (
                "container",
                "exec",
                "--user",
                user,
                fixture.name,
                "bash",
                "-lc",
                script,
            )
        ).stdout


def _object_list(value: Any, label: str) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise ValueError(f"Apple container returned invalid {label} JSON")
    return value


def _inspect_fixture(fixture: ManagedFixture, runner: Runner) -> dict[str, Any]:
    try:
        inspected = _object_list(
            json.loads(runner.run(("container", "inspect", fixture.name)).stdout),
            "inspect",
        )
    except json.JSONDecodeError as error:
        raise ValueError("Apple container returned invalid inspect JSON") from error
    if len(inspected) != 1:
        raise ValueError("Apple vet fixture inspect identity is ambiguous")
    return inspected[0]


def cleanup_fixture(state_path: Path, runner: Runner) -> None:
    fixture = ManagedFixture.load(state_path)
    try:
        inventory = _object_list(
            json.loads(
                runner.run(("container", "list", "--all", "--format", "json")).stdout
            ),
            "inventory",
        )
    except json.JSONDecodeError as error:
        raise ValueError("Apple container returned invalid inventory JSON") from error
    matches = [item for item in inventory if item.get("id") == fixture.name]
    if not matches:
        state_path.unlink()
        return
    if len(matches) != 1:
        raise ValueError("Apple vet fixture inventory identity is ambiguous")
    item = _inspect_fixture(fixture, runner)
    configuration = item.get("configuration")
    labels = configuration.get("labels") if isinstance(configuration, dict) else None
    identity_matches = (
        item.get("id") == fixture.name
        and isinstance(configuration, dict)
        and configuration.get("id") == fixture.name
        and isinstance(labels, dict)
        and labels.get(PURPOSE_LABEL) == fixture.purpose
        and labels.get(DIGEST_LABEL) == fixture.digest
    )
    if not identity_matches:
        raise ValueError(
            "refusing cleanup because Apple vet fixture identity mismatched"
        )
    status = item.get("status")
    if isinstance(status, dict) and status.get("state") == "running":
        runner.run(("container", "stop", fixture.name))
    runner.run(("container", "delete", fixture.name))
    state_path.unlink()


def clean_managed_fixtures(root: Path, runner: Runner) -> int:
    state_directory = root / ".dist/sandbox-image/vet"
    state_paths = sorted(state_directory.glob("sha256-*.json"))
    fixtures = {ManagedFixture.load(path).name: path for path in state_paths}
    try:
        inventory = _object_list(
            json.loads(
                runner.run(("container", "list", "--all", "--format", "json")).stdout
            ),
            "inventory",
        )
    except json.JSONDecodeError as error:
        raise ValueError("Apple container returned invalid inventory JSON") from error
    unrecorded = sorted(
        name
        for item in inventory
        if isinstance(name := item.get("id"), str)
        and name.startswith("ghosthub-vet-")
        and name not in fixtures
    )
    if unrecorded:
        raise ValueError(
            "refusing to delete unrecorded Apple vet fixture: " + ", ".join(unrecorded)
        )
    for path in state_paths:
        cleanup_fixture(path, runner)
        fixture_root = path.parent / (path.stem + "-repos")
        shutil.rmtree(fixture_root, ignore_errors=True)
    return len(state_paths)
