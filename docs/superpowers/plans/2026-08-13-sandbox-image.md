# Sandbox Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish and vet the lean Ghosthub-owned Apple sandbox image, then land its exact digest as the build-time runtime authority consumed by later provider work.

**Architecture:** A repository-owned Python CLI owns validation, reports, registry orchestration, and local Apple vetting behind short Make targets. BuildKit produces one `linux/arm64` OCI digest, Trivy 0.73.0 produces the SPDX JSON software bill of materials (SBOM) and vulnerability report, and protected GitHub workflows attest and retag that same digest without rebuilding. The implementation is intentionally split by a merge boundary: changeset one lands the publishing machinery and emits a candidate; changeset two commits the candidate's local vetting report plus the tag-free `SANDBOX_IMAGE` digest, then asks the `main`-pinned promotion implementation to consume that exact task-branch commit only as inert evidence.

**Tech Stack:** Python 3.11+, pytest 8.4.1, ruff 0.16.3, ty 0.0.71, Docker Buildx/BuildKit, Ubuntu 26.04 LTS, Trivy 0.73.0, GitHub Container Registry (GHCR), GitHub artifact attestations, Apple `container` 1.2.2, Make, Zensical, zizmor 1.29.0.

## Global Constraints

- Version 1 is local Apple silicon only and accepts exactly Apple `container` 1.2.2 for vetting.
- The image is `linux/arm64`, based on Ubuntu 26.04 LTS, and published as `ghcr.io/kenn-io/ghosthub-sandbox`.
- The reviewed direct package list is exactly `bash`, `git`, `ca-certificates`, `curl`, `openssh-client`, `sudo`, `unzip`, and `xz-utils`; do not add an agent, compiler, language runtime, editor, Docker CLI, credential helper, Git configuration, or Git identity.
- The ordinary user is `ghosthub` with a private persistent home and passwordless `sudo`; this is ergonomics, not privilege separation.
- Set `LANG=C.UTF-8`; require `tmux-256color` terminfo; do not add `ncurses-term` unless the pinned candidate proves it is needed.
- Use `/bin/sleep infinity` as the inert image command. Apple provider creation supplies `--init`; interactive exec supplies `--user ghosthub`.
- `SANDBOX_IMAGE` contains only `ghcr.io/kenn-io/ghosthub-sandbox@sha256:<64 lowercase hex>`; no tag or duplicated Swift/workflow literal is runtime authority.
- Candidate tags are `candidate-<full-source-commit>`, production tags are `vX.Y.Z`, and no `latest` tag exists. The scripts refuse to replace any existing tag that names another digest.
- Every candidate or production writer uses the same repository-wide `sandbox-image-package-writer` concurrency group with `cancel-in-progress: false` and `queue: max`; it rechecks the target tag inside that lock immediately before mutation and verifies it afterward.
- GHCR creates the first package as private. After the first candidate publish,
  an organization owner must perform the one-time, irreversible **Change
  visibility → Public** action in package settings. `status` detects private or
  missing visibility and prints the exact settings URL. No candidate may be
  vetted or pinned until anonymous digest pull succeeds. This bootstrap action
  is separate from the one approval required by each production promotion.
- Pull requests publish nothing. Only an `images/sandbox/**` change merged to `main` publishes a candidate. Promotion retags the vetted digest and never rebuilds it.
- Promotion dispatches the workflow from `main`. Its exact task-branch input is data only: no privileged job checks out, imports, sources, or executes code from that commit.
- A `pull_request_target` gate from `main` sets `sandbox-image-promotion` pending on report/pin pull-request heads and success on unrelated pull-request heads without checking out branch code. Promotion grants success only after the production alias is verified. The context is required by the default-branch ruleset, so a later push has no promotion success and cannot merge while ordinary pull requests remain frictionless.
- Fixable Critical or High findings block. An unfixed Critical or High requires an unexpired reviewed entry in `images/sandbox/vulnerability-dispositions.json`. Medium and Low remain visible.
- No lifecycle command commits, pushes, merges, approves an environment, changes app release version, or mutates unrelated provider resources.
- Provider/registry/scanner behavior is exercised at the live seams. Unit tests cover only Ghosthub-owned parsing, binding, policy, report, and orchestration decisions.
- Use `uv`, Make targets, SHA-pinned GitHub Actions, `persist-credentials: false`, minimal job permissions, and `id-token: write` only for attestation jobs.
- Do not create a database migration. Do not add user-facing Swift UI or screenshots in changeset one or two.
- Before any implementation push or pull-request update, remove this plan and its approved design from the task branch. Planning artifacts under `docs/superpowers/` must never appear in a pull request.
- Before every commit, invoke `kenn:commit`; before claiming a task or changeset complete, invoke `superpowers:verification-before-completion`.

## File Map

### Changeset one

- Create `images/sandbox/Dockerfile`: Ubuntu image construction and `ghosthub` user.
- Create `images/sandbox/VERSION`: independent image release version, initially `0.1.0`.
- Create `images/sandbox/UBUNTU_BASE`: official Ubuntu 26.04 arm64 manifest digest resolved during Task 2.
- Create `images/sandbox/APT_SNAPSHOT`: UTC Ubuntu snapshot ID in `YYYYMMDDTHHMMSSZ` form resolved during Task 2.
- Create `images/sandbox/packages.txt`: reviewed direct package inventory.
- Create `images/sandbox/vulnerability-dispositions.json`: committed structured exception array, initially empty.
- Create `images/sandbox/tests/image-contract.sh`: observable in-image contract assertions.
- Create `tools/sandbox_image/__init__.py`: package marker.
- Create `tools/sandbox_image/model.py`: image-reference, report, finding, and disposition value types.
- Create `tools/sandbox_image/policy.py`: pin/report/disposition/tag policy.
- Create `tools/sandbox_image/process.py`: bounded subprocess runner and redaction.
- Create `tools/sandbox_image/docker.py`: Buildx and registry command construction.
- Create `tools/sandbox_image/trivy.py`: pinned Trivy installation, SBOM, scan, and scan parsing.
- Create `tools/sandbox_image/apple.py`: Apple `container` fixture lifecycle and runtime vetting.
- Create `tools/sandbox_image/github.py`: attestation verification, trusted-main promotion dispatch, pull-request-head binding, and exact-head status publication.
- Create `tools/sandbox_image/report.py`: canonical report creation, loading, and validation.
- Create `tools/sandbox_image/commands.py`: `check`, `refresh`, `vet`, `pin`, `promote`, `status`, and `clean` orchestration.
- Create `tools/sandbox_image.py`: stable command-line entry point.
- Create `Tests/test_sandbox_image_model.py`: reference and schema behavior.
- Create `Tests/test_sandbox_image_policy.py`: disposition and tag decisions.
- Create `Tests/test_sandbox_image_commands.py`: owned command-orchestration behavior.
- Create `.github/workflows/sandbox-image.yml`: publish-nothing pull-request check and candidate publication.
- Create `.github/workflows/sandbox-image-promotion-gate.yml`: trusted exact-head promotion status gate.
- Create `.github/workflows/sandbox-image-promote.yml`: protected exact-digest retag.
- Create `.github/workflows/sandbox-image-maintenance.yml`: scheduled/manual rescan and drift report.
- Modify `pyproject.toml`: pin ruff and ty in the development dependency group and configure both.
- Modify `uv.lock`: lock ruff and ty.
- Modify `Makefile`: stable lifecycle and Python quality targets.
- Modify `prek.toml`: run Python formatting/lint/type checks for Python changes.
- Create `docs/sandbox-image.md`: human operator guide.
- Modify `docs/zensical.toml`: add the operator guide navigation entry.
- Modify `docs/README.md`: describe the new operator guide.
- Modify `docs/sandboxes.md`: canonical image selection, digest, persistence, and update contract.
- Modify `docs/threat-model.md`: image/user boundary and supply-chain authority.
- Modify `docs/release.md`: image release and build-time embedding contract.
- Delete `docs/superpowers/specs/2026-08-13-sandbox-image-design.md`: keep the approved design out of the pull request.
- Delete `docs/superpowers/plans/2026-08-13-sandbox-image.md`: keep this plan out of the pull request; use the committed copy from the `sandboxing` handoff branch while executing.

### Changeset two

- Create `SANDBOX_IMAGE`: the vetted tag-free production repository digest.
- Create `images/sandbox/reports/sha256-<digest>.json`: canonical passing Apple vet report.

### `3ed9` handoff

The provider-contract issue, not `8ems`, embeds and consumes the pin. Its
implementation plan must:

- modify `Makefile` so both packaged app targets read root `SANDBOX_IMAGE` and
  pass it to bundle assembly;
- modify `tools/assemble_app_bundle.py` and
  `Tests/test_assemble_app_bundle.py` so bundle assembly validates the
  tag-free repository digest and writes `GhosthubSandboxImage` to
  `Info.plist`;
- modify `.github/workflows/release.yml` to pass the value derived from the
  file without a digest literal;
- add `SandboxImageReference.packaged(bundle: Bundle = .main) throws ->
  SandboxImageReference`, reading
  `Bundle.main.object(forInfoDictionaryKey: "GhosthubSandboxImage")`;
- add Swift and packaging tests for missing, malformed, tagged, wrong-repository,
  and valid values; and
- update `docs/release.md` for the packaged key and single-source rule.

No Swift source, test fixture, Make recipe, or workflow YAML may duplicate the
digest literal.

---

## Phase A: Changeset One — Source and Machinery

### Task 1: Remove Local Planning Artifacts and Pin Python Quality Tools

**Files:**
- Delete: `docs/superpowers/specs/2026-08-13-sandbox-image-design.md`
- Delete: `docs/superpowers/plans/2026-08-13-sandbox-image.md`
- Modify: `pyproject.toml`
- Modify: `uv.lock`

**Interfaces:**
- Consumes: the approved plan from commit `e37dd98` and this file on the `sandboxing` handoff branch.
- Produces: exact ruff and ty dependencies for the scoped gates added after the
  sandbox Python paths exist in Task 3.

- [ ] **Step 1: Create the implementation branch and remove planning artifacts before its first push**

Run from this linked worktree:

```bash
git switch -c sandbox-image
git rm docs/superpowers/specs/2026-08-13-sandbox-image-design.md
git rm docs/superpowers/plans/2026-08-13-sandbox-image.md
```

Expected: the task branch is not `main` or `master`; both planning documents are staged for deletion. Keep the approved plan open from commit `e37dd98` or another local view while executing it.

- [ ] **Step 2: Add pinned Python developer tools**

Edit `pyproject.toml` so the development group is:

```toml
[dependency-groups]
dev = [
  "pytest==8.4.1",
  "ruff==0.16.3",
  "ty==0.0.71",
]

[tool.ruff]
target-version = "py311"
line-length = 88

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]

[tool.ty.environment]
python-version = "3.11"
```

Then run:

```bash
uv lock
```

Expected: `uv.lock` contains the exact ruff and ty releases.

- [ ] **Step 3: Verify the pinned tools and unchanged Python suite**

Run:

```bash
uv run --frozen --group dev ruff --version
uv run --frozen --group dev ty --version
make python-test
```

Expected: the exact tool versions print and the unchanged full Python suite
passes. Do not modify unrelated Python files to satisfy the new scoped gates.

- [ ] **Step 4: Commit the branch hygiene and pinned tools**

Invoke `kenn:commit`, then commit only the planning-document deletions and quality-gate files with subject:

```text
Pin sandbox image Python quality tools
```

Do not push yet unless this commit is part of the final changeset-one branch update.

### Task 2: Add Pinned Image Inputs and the Image Contract

**Files:**
- Create: `images/sandbox/Dockerfile`
- Create: `images/sandbox/VERSION`
- Create: `images/sandbox/UBUNTU_BASE`
- Create: `images/sandbox/APT_SNAPSHOT`
- Create: `images/sandbox/packages.txt`
- Create: `images/sandbox/vulnerability-dispositions.json`
- Create: `images/sandbox/tests/image-contract.sh`

**Interfaces:**
- Consumes: BuildKit build arguments `UBUNTU_BASE`, `APT_SNAPSHOT`, `SOURCE_REVISION`, and `IMAGE_VERSION`.
- Produces: a `linux/arm64` image whose command is `/bin/sleep infinity` and whose ordinary account is `ghosthub`.

- [ ] **Step 1: Resolve the official arm64 base digest and snapshot**

Run the real registry inspection rather than copying a digest from this plan:

```bash
docker buildx imagetools inspect ubuntu:26.04 --raw > /tmp/ghosthub-ubuntu-index.json
jq -er '.manifests[] | select(.platform.os == "linux" and .platform.architecture == "arm64") | .digest' /tmp/ghosthub-ubuntu-index.json
date -u +%Y%m%dT%H%M%SZ
```

Write the selected `sha256:<64 lowercase hex>` to `UBUNTU_BASE` and a UTC snapshot supported by Ubuntu's snapshot service to `APT_SNAPSHOT`. Verify the digest is the arm64 manifest by inspecting `ubuntu@<digest>` with Buildx.

- [ ] **Step 2: Write the reviewed source files**

Write:

```text
# images/sandbox/VERSION
0.1.0
```

```text
# images/sandbox/packages.txt
bash
ca-certificates
curl
git
openssh-client
sudo
unzip
xz-utils
```

```json
[]
```

for `vulnerability-dispositions.json`.

- [ ] **Step 3: Write the Dockerfile**

Implement these exact behaviors:

```dockerfile
ARG UBUNTU_BASE
FROM ubuntu@${UBUNTU_BASE}

ARG APT_SNAPSHOT
ARG SOURCE_REVISION
ARG IMAGE_VERSION
ENV LANG=C.UTF-8
```

Copy `packages.txt` and `tests/image-contract.sh`. During the installation
layer, write `APT::Snapshot "$APT_SNAPSHOT";` to the temporary file
`/etc/apt/apt.conf.d/99ghosthub-snapshot`, run noninteractive `apt-get update`
and `apt-get install --no-install-recommends` for the package file, then remove
that snapshot config and APT indexes in the same layer. Install the executable
contract as `/opt/ghosthub/image-contract.sh`. The completed image must leave
`/etc/apt/sources.list.d/ubuntu.sources` without a `Snapshot:` entry and no
global `APT::Snapshot` config. Create `ghosthub` with a real
`/home/ghosthub`, shell `/bin/bash`, and a mode-0440 sudoers file granting
`NOPASSWD: ALL`. Set OCI labels for source repository, revision, version, and
description. End with:

```dockerfile
USER ghosthub
WORKDIR /home/ghosthub
CMD ["/bin/sleep", "infinity"]
```

- [ ] **Step 4: Write the executable image contract**

`images/sandbox/tests/image-contract.sh` must run inside the built image and fail on the first broken observable contract. It must check:

```bash
test "$(id -un)" = ghosthub
test "$HOME" = /home/ghosthub
test -w "$HOME"
sudo -n true
locale charmap | grep -qx UTF-8
TERM=tmux-256color infocmp tmux-256color >/dev/null
git --version
curl --version
ssh -V
unzip -v >/dev/null
xz --version
test ! -e "$HOME/.gitconfig"
test ! -e "$HOME/.ssh"
```

Also assert the intentional exclusions with `command -v` for `docker`, `node`,
`python`, `python3`, `ruby`, `go`, `rustc`, `cargo`, `swift`, `clang`, `gcc`,
`vim`, `nvim`, `emacs`, `code`, `claude`, `codex`, and `opencode`. Assert that
APT has no configured snapshot after build and that `apt-get update` reaches
the live Ubuntu repositories.

- [ ] **Step 5: Build and run the contract locally**

Run a Buildx load for `linux/arm64`, deriving every argument from its file:

```bash
docker buildx build --platform linux/arm64 --load \
  --build-arg "UBUNTU_BASE=$(tr -d '[:space:]' < images/sandbox/UBUNTU_BASE)" \
  --build-arg "APT_SNAPSHOT=$(tr -d '[:space:]' < images/sandbox/APT_SNAPSHOT)" \
  --build-arg "SOURCE_REVISION=$(git rev-parse HEAD)" \
  --build-arg "IMAGE_VERSION=$(tr -d '[:space:]' < images/sandbox/VERSION)" \
  --tag ghosthub-sandbox:test images/sandbox
docker run --rm --platform linux/arm64 ghosthub-sandbox:test \
  bash /opt/ghosthub/image-contract.sh
```

Expected: the image contract passes. Inspect the image architecture and OCI labels with `docker image inspect`; do not add unit tests for Dockerfile text.

- [ ] **Step 6: Commit the vetted image source**

Invoke `kenn:commit`, then commit the image source and contract with subject:

```text
Define the lean sandbox environment
```

### Task 3: Implement Image References, Reports, and Vulnerability Policy

**Files:**
- Create: `tools/sandbox_image/__init__.py`
- Create: `tools/sandbox_image/model.py`
- Create: `tools/sandbox_image/policy.py`
- Create: `tools/sandbox_image/report.py`
- Create: `Tests/test_sandbox_image_model.py`
- Create: `Tests/test_sandbox_image_policy.py`

**Interfaces:**
- Produces: `ImageReference.parse(value: str) -> ImageReference`;
  `load_dispositions(path: Path, today: date) -> tuple[Disposition, ...]`;
  `evaluate_findings(findings, dispositions, today) -> PolicyResult`;
  `VettingReport.load(path: Path) -> VettingReport`; and
  `validate_report(report, expected_image, expected_version) -> None`.
- Consumes: Trivy findings normalized as `Finding(vulnerability_id, package, severity, fixed_version)` and report check records as `CheckResult(name, status, detail)`.

- [ ] **Step 1: Write failing image-reference and report tests**

Cover these cases in `Tests/test_sandbox_image_model.py`:

```python
def test_runtime_pin_normalizes_candidate_to_tag_free_digest() -> None:
    ref = ImageReference.parse(
        "ghcr.io/kenn-io/ghosthub-sandbox:candidate-" + "a" * 40
        + "@sha256:" + "b" * 64
    )
    assert ref.runtime_pin == (
        "ghcr.io/kenn-io/ghosthub-sandbox@sha256:" + "b" * 64
    )


@pytest.mark.parametrize("value", [
    "ghcr.io/kenn-io/ghosthub-sandbox:latest",
    "ghcr.io/kenn-io/ghosthub-sandbox:v0.1.0",
    "docker.io/kenn-io/ghosthub-sandbox@sha256:" + "b" * 64,
    "ghcr.io/kenn-io/ghosthub-sandbox@sha256:ABC",
])
def test_runtime_pin_rejects_non_authoritative_references(value: str) -> None:
    with pytest.raises(ValueError):
        ImageReference.parse_runtime_pin(value)
```

Add report tests that reject a digest mismatch, image-version mismatch, non-1.2.2 provider, non-arm64 host, failed check, missing required check, expired disposition, absolute home path, and environment dump key.

- [ ] **Step 2: Run the tests and confirm the missing-module failure**

Run:

```bash
uv run --frozen --group dev pytest Tests/test_sandbox_image_model.py -v
```

Expected: collection fails because `sandbox_image.model` and `sandbox_image.report` do not exist.

- [ ] **Step 3: Implement focused immutable value types**

Use frozen dataclasses and enums. The essential shapes are:

```python
IMAGE_REPOSITORY = "ghcr.io/kenn-io/ghosthub-sandbox"
REFERENCE = re.compile(
    rf"^(?P<repository>{re.escape(IMAGE_REPOSITORY)})"
    r"(?::(?P<tag>candidate-[0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+))?"
    r"@(?P<digest>sha256:[0-9a-f]{64})$"
)


@dataclass(frozen=True)
class ImageReference:
    repository: str
    digest: str
    tag: str | None

    @classmethod
    def parse(cls, value: str) -> "ImageReference":
        match = REFERENCE.fullmatch(value)
        if match is None:
            raise ValueError(f"invalid Ghosthub sandbox image reference: {value}")
        return cls(
            repository=match.group("repository"),
            digest=match.group("digest"),
            tag=match.group("tag"),
        )

    @classmethod
    def parse_runtime_pin(cls, value: str) -> "ImageReference":
        reference = cls.parse(value)
        if reference.tag is not None:
            raise ValueError("SANDBOX_IMAGE must be tag-free")
        return reference

    @property
    def runtime_pin(self) -> str:
        return f"{self.repository}@{self.digest}"


@dataclass(frozen=True)
class Disposition:
    vulnerability_id: str
    package: str
    rationale: str
    owner: str
    expires: date


@dataclass(frozen=True)
class Finding:
    vulnerability_id: str
    package: str
    severity: str
    fixed_version: str | None


@dataclass(frozen=True)
class CheckResult:
    name: str
    status: Literal["pass", "fail"]
    detail: str
```

Reject unknown JSON keys, duplicate dispositions, empty rationale/owner, non-ISO dates, and repository/digest forms outside the global contract.

- [ ] **Step 4: Write failing disposition-policy tests**

Cover:

- fixable Critical/High blocks even if a disposition exists;
- unfixed Critical/High passes only with one current exact vulnerability/package disposition;
- missing, expired, duplicate, and unmatched dispositions fail;
- Medium/Low findings are returned as visible nonblocking findings;
- extending an expiry changes policy only through the committed disposition input.

Run:

```bash
uv run --frozen --group dev pytest Tests/test_sandbox_image_policy.py -v
```

Expected: failures identify the not-yet-implemented evaluator.

- [ ] **Step 5: Implement policy and report validation**

`evaluate_findings` returns:

```python
@dataclass(frozen=True)
class PolicyResult:
    blocking: tuple[Finding, ...]
    disposed: tuple[tuple[Finding, Disposition], ...]
    visible: tuple[Finding, ...]

    @property
    def accepted(self) -> bool:
        return not self.blocking
```

The canonical report schema is version `1` and uses sorted JSON keys, UTF-8,
two-space indentation, and a trailing newline. Require checks named
`architecture`, `provider-version`, `digest`, `attestations`, `ordinary-user`,
`sudo`, `locale`, `terminfo`, `https`, `ssh-client`, `git-standard`,
`git-linked`, `live-apt`, `stop-start-home`, `stop-start-package`, `init`,
`explicit-exec-user`, `mount-protection`, and `cleanup`.

- [ ] **Step 6: Run focused and global behavior tests**

Run:

```bash
uv run --frozen --group dev pytest \
  Tests/test_sandbox_image_model.py Tests/test_sandbox_image_policy.py -v
make python-test
```

Expected: all pass.

- [ ] **Step 7: Commit the identity and policy core**

Invoke `kenn:commit`, then commit with subject:

```text
Validate sandbox image evidence
```

### Task 4: Implement Safe Process, Build, Scan, and Check Orchestration

**Files:**
- Create: `tools/sandbox_image/process.py`
- Create: `tools/sandbox_image/docker.py`
- Create: `tools/sandbox_image/trivy.py`
- Create: `tools/sandbox_image/commands.py`
- Create: `tools/sandbox_image.py`
- Create: `Tests/test_sandbox_image_commands.py`
- Modify: `Makefile`
- Modify: `prek.toml`

**Interfaces:**
- Consumes: Task 3 value types and policy functions.
- Produces: CLI subcommands `check`, `refresh`, and `status`; `CommandRunner.run(argv, *, check=True, capture=True) -> CompletedCommand`; `build_local_image(inputs) -> BuiltImage`; `scan_image(image) -> ScanArtifacts`.

- [ ] **Step 1: Write failing orchestration tests**

Use a small fake `CommandRunner` at the owned process boundary. Test observable command decisions, not Docker or Trivy themselves:

```python
def test_check_builds_arm64_from_all_four_pinned_inputs(fake_runner) -> None:
    result = check_image(REPO_ROOT, runner=fake_runner)
    assert result.platform == "linux/arm64"
    assert fake_runner.one_call_starting_with("docker", "buildx", "build")


def test_refresh_changes_only_three_reviewed_input_files(tmp_repo, fake_runner) -> None:
    refresh_image(tmp_repo, version="0.2.0", runner=fake_runner)
    assert changed_paths(tmp_repo) == {
        Path("images/sandbox/VERSION"),
        Path("images/sandbox/UBUNTU_BASE"),
        Path("images/sandbox/APT_SNAPSHOT"),
    }
```

Also cover: malformed input files fail before subprocess calls; `check` never logs in or pushes; `refresh` rejects non-`X.Y.Z`; status is read-only; command failures redact configured secrets and bound output size.

- [ ] **Step 2: Run the focused test and confirm failure**

Run:

```bash
uv run --frozen --group dev pytest Tests/test_sandbox_image_commands.py -v
```

Expected: imports or assertions fail because orchestration is absent.

- [ ] **Step 3: Implement the process and Buildx boundaries**

`CommandRunner` accepts argument arrays only, never shell strings. It records a bounded stdout/stderr tail and replaces every configured secret plus absolute repository and home prefixes with `<redacted>`. `docker.py` must:

- require `docker buildx version`;
- build `linux/arm64` from the four pinned inputs;
- use an OCI archive under `.dist/sandbox-image/` for CI/check output;
- inspect manifest architecture, labels, command, and user;
- resolve tags to manifest digests before returning an `ImageReference`;
- reject existing tag/digest conflicts.

- [ ] **Step 4: Implement pinned Trivy acquisition and scanning**

Pin:

```python
TRIVY_VERSION = "0.73.0"
TRIVY_ASSET_SHA256 = {
    ("Darwin", "arm64"): "80cc25faaf6378e37701202d0b4f9f43d9e413d198d594ba60fdf559fe44a683",
    ("Linux", "x86_64"): "2edd39da482bb4e9831962487b68f68e3928ec3137794757f54d00383d79547b",
}
```

Download the matching official release archive into `.build/tools/trivy/0.73.0/`, verify its SHA-256 before extraction, and never use `latest` or the compromised setup action. Generate SPDX JSON and vulnerability JSON under `.dist/sandbox-image/`. Normalize only OS-package findings into Task 3 `Finding` values and evaluate them against the committed dispositions.

- [ ] **Step 5: Implement `check`, `refresh`, and `status` CLI routes**

The entry point shape is:

```python
def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("check")
    refresh = subcommands.add_parser("refresh")
    refresh.add_argument("--version", required=True)
    subcommands.add_parser("status")
    arguments = parser.parse_args(argv)
    if arguments.command == "check":
        return run_check()
    if arguments.command == "refresh":
        return run_refresh(arguments.version)
    return run_status()
```

`check` builds, runs the real image contract as `ghosthub`, creates SBOM and vulnerability artifacts, and applies policy. `refresh` resolves the current official Ubuntu 26.04 arm64 manifest and a current UTC snapshot, validates both, and edits only the three input files. `status` prints one concise table and exits nonzero only when operator action is required.

Once a production alias exists, `status` also reads the active default-branch
ruleset and fails with the exact settings URL unless
`sandbox-image-promotion` is required from GitHub Actions. While a pin pull
request is open, it reports whether that exact head has promotion success.

- [ ] **Step 6: Add lifecycle and scoped Python quality gates**

Add `.PHONY`, help, and recipes:

```make
sandbox-image-check:
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py check

sandbox-image-refresh:
	@test -n "$(VERSION)" || { echo 'Set VERSION=X.Y.Z' >&2; exit 2; }
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py refresh --version "$(VERSION)"

sandbox-image-status:
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py status

sandbox-image-python-lint:
	@$(UV) run --frozen --group dev ruff check \
		tools/sandbox_image.py tools/sandbox_image Tests/test_sandbox_image_*.py

sandbox-image-python-typecheck:
	@$(UV) run --frozen --group dev ty check \
		tools/sandbox_image.py tools/sandbox_image Tests/test_sandbox_image_*.py
```

Add matching local hooks to `prek.toml`, both with
`pass_filenames = false` and:

```toml
files = "^tools/sandbox_image(\\.py|/.*\\.py)$|^Tests/test_sandbox_image_.*\\.py$"
```

Use entries `make sandbox-image-python-lint` and
`make sandbox-image-python-typecheck`. The narrow paths are deliberate:
repository-wide dry runs currently report unrelated legacy lint and
optional-dependency type findings.

- [ ] **Step 7: Verify the real local check and focused tests**

Run:

```bash
make sandbox-image-check
make sandbox-image-status
make sandbox-image-python-lint
make sandbox-image-python-typecheck
make python-test
```

Expected: check creates an OCI archive, SPDX JSON, and vulnerability JSON only under ignored build directories; it publishes nothing. Status accurately reports that no candidate or app pin exists yet.

- [ ] **Step 8: Commit the local build and scan lifecycle**

Invoke `kenn:commit`, then commit with subject:

```text
Automate sandbox image checks
```

### Task 5: Implement Apple Vetting, Canonical Reports, and Managed Cleanup

**Files:**
- Create: `tools/sandbox_image/apple.py`
- Modify: `tools/sandbox_image/report.py`
- Modify: `tools/sandbox_image/commands.py`
- Modify: `tools/sandbox_image.py`
- Modify: `Tests/test_sandbox_image_commands.py`
- Modify: `Makefile`

**Interfaces:**
- Consumes: exact public `ImageReference`, report/policy types, and the existing `docs/sandboxes.md` Git preflight contract.
- Produces: `vet_image(image, runner, clock) -> VettingReport`; CLI commands `vet`, `pin`, and `clean`; provider resource names `ghosthub-vet-<12 digest hex>-<random suffix>` with label `io.ghosthub.purpose=sandbox-image-vet` and full digest label.

- [ ] **Step 1: Write failing managed-identity and report tests**

Add tests that prove:

- vet rejects non-Darwin, non-arm64, and any `container --version` other than 1.2.2 before resource creation;
- cleanup is registered before the first create call;
- a fixture is deletable only when exact name and both labels match;
- a mismatch is reported and never passed to `container delete`;
- failure still writes a canonical failed report;
- report paths use `images/sandbox/reports/sha256-<hex>.json`;
- pin refuses a failed, stale, mismatched, or noncanonical report and writes only a tag-free digest.

- [ ] **Step 2: Implement Apple preflight and managed resource inventory**

Require these real commands and parse their output:

```text
uname -s
uname -m
sw_vers -productVersion
container --version
container list --all --format json
container inspect <exact-name>
```

Generate the fixture identity before create, persist it in a temporary state file under `.dist/sandbox-image/vet/`, and add both labels to `container create`. `clean` reads provider inventory, requires exact label/name/digest agreement, stops a running matching fixture, and deletes it. It refuses every unknown or partially matching resource.

- [ ] **Step 3: Implement the exact-digest runtime checks**

Vetting must pull with:

```text
container image pull --platform linux/arm64 <repository@digest>
```

Create with `--init`, `--user ghosthub`, `--env LANG=C.UTF-8`, and the managed labels. Run the Task 2 image contract, then check:

- explicit `exec --user ghosthub` reports `ghosthub`;
- a child orphaned under the init is reaped and termination reaches the long-running process;
- a home marker and an installed marker package absent from the base survive `container stop` followed by `container start`;
- HTTPS, live APT, and repository-local Git identity work;
- standard and linked throwaway repositories satisfy the Apple mount preflight and protection assertions in `docs/sandboxes.md` without touching a real repository.

Reuse shared Git-layout/preflight code from `3ed9` when it exists. If Task 5 is implemented first, keep the image-vet fixture builder isolated behind `AppleVettingHarness` so `3ed9` can extract or call it rather than duplicate mount semantics.

- [ ] **Step 4: Write and validate the canonical report**

Record schema `1`, repository/digest, image version, source commit, candidate tag, attestation identities, macOS version, architecture, exact provider version, bounded check results, scan database timestamp, findings/dispositions, overall status, and UTC completion time. Do not record username, absolute home/repository paths, credentials, environment dictionaries, Git contents, or unbounded command output.

Always attempt cleanup and add the `cleanup` result after provider termination. A cleanup failure makes the overall report fail and leaves the exact managed residue visible to `status` and `clean`.

- [ ] **Step 5: Add `vet`, `pin`, and `clean` Make targets**

```make
sandbox-image-vet:
	@test -n "$(IMAGE)" || { echo 'Set IMAGE=<candidate@digest>' >&2; exit 2; }
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py vet --image "$(IMAGE)"

sandbox-image-pin:
	@test -n "$(IMAGE)" || { echo 'Set IMAGE=<candidate@digest>' >&2; exit 2; }
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py pin --image "$(IMAGE)"

sandbox-image-clean:
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py clean
```

- [ ] **Step 6: Run focused tests and a disposable local-image smoke**

Run unit tests first:

```bash
uv run --frozen --group dev pytest Tests/test_sandbox_image_commands.py -v
make sandbox-image-python-lint
make sandbox-image-python-typecheck
make python-test
```

Before a public candidate exists, run `container image load --input
<Task-4-OCI-archive>` only to smoke the fixture lifecycle. Do not create a
canonical passing production report from the local archive; canonical vetting
in Phase B must pull the public candidate digest.

- [ ] **Step 7: Commit the Apple vetting lifecycle**

Invoke `kenn:commit`, then commit with subject:

```text
Vet sandbox images on Apple silicon
```

### Task 6: Add Publish-Nothing Checks and Candidate Publication

**Files:**
- Create: `.github/workflows/sandbox-image.yml`
- Modify: `tools/sandbox_image/github.py`
- Modify: `tools/sandbox_image/commands.py`
- Modify: `Tests/test_sandbox_image_commands.py`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `make sandbox-image-check`, candidate tag policy, SPDX JSON, and exact manifest digest.
- Produces: public `candidate-<full-source-commit>` plus GitHub provenance and SPDX SBOM attestations for that digest.

- [ ] **Step 1: Write failing candidate-decision tests**

Test a pure function:

```python
def candidate_action(event: str, ref: str, changed_paths: Collection[Path]) -> Literal[
    "check-only", "publish", "skip"
]:
    watched = any(
        path.is_relative_to("images/sandbox")
        or path == Path("tools/sandbox_image.py")
        or path.is_relative_to("tools/sandbox_image")
        or path.name.startswith("test_sandbox_image_")
        or path.name.startswith("sandbox-image") and path.suffix == ".yml"
        for path in changed_paths
    )
    if not watched:
        return "skip"
    if event == "pull_request":
        return "check-only"
    if event == "push" and ref == "refs/heads/main" and any(
        path.is_relative_to("images/sandbox") for path in changed_paths
    ):
        return "publish"
    return "skip"
```

Expected decisions:

- pull request touching image/tool/workflow paths: `check-only`;
- `main` push touching `images/sandbox/**`: `publish`;
- unrelated pull request or `main` push: `skip`;
- any other ref: `skip`.

- [ ] **Step 2: Implement candidate inspection and idempotent publication helpers**

`github.py` exposes `verify_candidate_identity(image: ImageReference, source:
str, version: str) -> None`; `docker.py` exposes `assert_tag_available(tag:
str, digest: str) -> Literal["create", "already-correct"]`.

Require candidate tag, OCI source/revision/version labels, source commit, and
manifest digest to agree. Call `assert_tag_available` once during preflight and
again inside the writer lock immediately before publication, then resolve the
published candidate tag and require the registry-reported digest afterward.
The publish path logs into GHCR only inside CI and never prints the token.
After first publication, `status` reads package metadata through
`gh api /orgs/kenn-io/packages/container/ghosthub-sandbox`.
If visibility is not `public`, it reports a blocked bootstrap state and prints
`https://github.com/orgs/kenn-io/packages/container/ghosthub-sandbox/settings`.
The workflow does not attempt to bypass GitHub's owner-controlled,
irreversible visibility decision.

- [ ] **Step 3: Write the least-privilege workflow**

`.github/workflows/sandbox-image.yml` has `pull_request`, filtered `push` to `main`, and manual dispatch. Use SHA-pinned `actions/checkout`, Docker QEMU/Buildx/login actions, and `actions/attest`. The pull-request job has only `contents: read`, builds/checks/scans, uploads the SBOM and scan artifact, and never receives `packages: write` or `id-token: write`.

Use these reviewed action revisions, with their release names as comments:

```text
actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1       # v7.0.1
astral-sh/setup-uv@ae62891fec2bb8e7d6c99fc78c9fec3a63790f8d       # v10.0.0
docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8 # v4.2.0
docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0
docker/login-action@dbcb813823bdd20940b903addbd779551569679f       # v4.6.0
actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6         # v4.2.2
actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
```

Resolve and review a new immutable commit only when deliberately updating an
action; never replace these with a moving major tag.

The `main` publication job has only:

```yaml
permissions:
  contents: read
  packages: write
  id-token: write
  attestations: write
```

The publication job, rather than the pull-request check job, uses the same
cross-workflow writer lock as promotion:

```yaml
concurrency:
  group: sandbox-image-package-writer
  cancel-in-progress: false
  queue: max
```

Do not prefix the group with the workflow name: candidate and production
writers must contend on one repository-wide lock. The tag availability check
runs again after this job acquires the lock and immediately before the push;
the job resolves the candidate tag back to the registry-reported digest before
attesting or succeeding.

It logs into `ghcr.io` with `github.actor` and `GITHUB_TOKEN`, invokes the same Python/Make build path with candidate tag `candidate-${{ github.sha }}`, captures the registry-reported digest, and uses SHA-pinned `actions/attest` twice:

```yaml
with:
  subject-name: ghcr.io/kenn-io/ghosthub-sandbox
  subject-digest: ${{ steps.publish.outputs.digest }}
  push-to-registry: true
```

The SBOM attestation additionally supplies `sbom-path`. Do not use the deprecated `actions/attest-sbom` wrapper.

- [ ] **Step 4: Add a workflow audit target and execute real validation**

Add:

```make
zizmor:
	@$(UV) tool run --from zizmor==1.29.0 zizmor --pedantic .github/workflows
```

Run:

```bash
make sandbox-image-check
make zizmor
make sandbox-image-python-lint
make sandbox-image-python-typecheck
make python-test
```

Expected: all pass; `git diff` shows no mutable action tags and no PR job with
write permissions. For the first candidate only, the eventual post-merge
status remains blocked until an organization owner makes the new GHCR package
public.

- [ ] **Step 5: Commit candidate publication**

Invoke `kenn:commit`, then commit with subject:

```text
Publish attested sandbox candidates
```

### Task 7: Add Exact-Commit Promotion and Weekly Maintenance

**Files:**
- Create: `.github/workflows/sandbox-image-promotion-gate.yml`
- Create: `.github/workflows/sandbox-image-promote.yml`
- Create: `.github/workflows/sandbox-image-maintenance.yml`
- Modify: `tools/sandbox_image/github.py`
- Modify: `tools/sandbox_image/commands.py`
- Modify: `tools/sandbox_image.py`
- Modify: `Tests/test_sandbox_image_commands.py`
- Modify: `Makefile`

**Interfaces:**
- Consumes: a pushed task-branch commit containing matching `SANDBOX_IMAGE` and canonical report, plus `VERSION` and candidate digest, as inert evidence for the `main`-pinned workflow and tooling.
- Produces: `vX.Y.Z` alias on that digest, required `sandbox-image-promotion` success on the exact pull-request head, and scheduled/manual read-only production-health results.

- [ ] **Step 1: Write failing promotion-preflight tests**

Cover:

- dirty worktree rejection;
- detached/default branch rejection;
- local HEAD not equal to its upstream rejection;
- dispatch ref other than `main` rejection;
- evidence commit not equal to the current head of exactly one open pull request targeting `main` rejection;
- evidence diff containing anything except `SANDBOX_IMAGE` and its canonical report rejection;
- promotion-gate path decisions from the pull request's complete changed-file set: pending for a pin or report change, success otherwise;
- report, pin, version, source commit, candidate digest, and candidate tag mismatch rejection;
- an existing correct production tag is idempotent;
- an existing conflicting production tag is never replaced;
- a post-promotion report/pin commit change has no promotion status and requires a new version;
- status success targets the exact evidence commit only after the production tag verifies.

- [ ] **Step 2: Implement `promote` and the promotion workflow**

Add the CLI route and Make target:

```make
sandbox-image-promote:
	@test -n "$(IMAGE)" || { echo 'Set IMAGE=<candidate@digest>' >&2; exit 2; }
	@test -n "$(VERSION)" || { echo 'Set VERSION=X.Y.Z' >&2; exit 2; }
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py promote \
		--image "$(IMAGE)" --version "$(VERSION)"
```

The command runs local preflight and dispatches
`sandbox-image-promote.yml --ref main` with explicit
`evidence_commit=<exact-task-HEAD>`, digest, and version inputs. The workflow
checks out only its triggering `main` commit and executes only that trusted
Python implementation. It uses the GitHub API and Git object reads to require
that `evidence_commit` is still the current head of exactly one open pull
request targeting `main`, that the pull request diff contains exactly
`SANDBOX_IMAGE` and the canonical report for the input digest, and that the
two blobs match every identity and policy binding. Never check out, import,
source, or invoke a path from `evidence_commit`.

The trusted pull-request gate has already recorded
`sandbox-image-promotion` as pending on `evidence_commit`. After environment
approval, promotion rechecks the pull-request head and evidence bindings. Only
the retag job receives `packages: write` and `statuses: write`; it uses the
same repository-wide lock as candidate publication:

```yaml
concurrency:
  group: sandbox-image-package-writer
  cancel-in-progress: false
  queue: max
```

Inside the lock it logs into GHCR, rechecks both candidate and production tag
state immediately before mutation, refuses conflicts, adds `vX.Y.Z` to the
existing digest without a build, and resolves both aliases back to the pin.
Only after those checks pass does it set `sandbox-image-promotion` success on
the exact `evidence_commit`; failures set that same context to failure. The
default-branch ruleset requires this status for the report-and-pin pull
request, so any subsequent push is a new head without promotion success and
cannot merge. On the first release, configure the required context after the
first successful promotion status and before merging the pin, binding its
expected source to GitHub Actions. Later promotion preflight and `status`
require that protection to remain active.

`.github/workflows/sandbox-image-promotion-gate.yml` uses
`pull_request_target` and the trusted default-branch workflow definition. Give
it only `contents: read`, `pull-requests: read`, and `statuses: write`. It
queries the pull request's complete paginated changed-file list through the
GitHub API and never checks out or executes pull-request content. If any path is
`SANDBOX_IMAGE` or below `images/sandbox/reports/`, it sets
`sandbox-image-promotion` pending on the exact head SHA unless that same SHA
already carries success; otherwise it sets the context success immediately.
Preserving success makes close/reopen and other no-new-commit events
idempotent. This lets the context be required globally without adding a
sandbox-image action to ordinary pull requests. Promotion is the only trusted
workflow path that changes a relevant head from pending to success.

- [ ] **Step 3: Implement read-only weekly maintenance**

`.github/workflows/sandbox-image-maintenance.yml` runs weekly and through
`workflow_dispatch`. It has `contents: read`, `packages: read`, and
`attestations: read` only. Before the first production pin exists, it exits
successfully with **Sandbox image not initialized** and performs no registry
operation. After initialization it checks out `main`, loads `SANDBOX_IMAGE`,
validates the canonical report and `vX.Y.Z` alias, verifies provenance and
SBOM, downloads the current Trivy database, rescans the digest, and applies
current dispositions.

To identify refresh work without rebuilding, it resolves the current official
Ubuntu 26.04 arm64 base digest and compares it with `UBUNTU_BASE`. For a
Critical/High finding whose Trivy record names a fixed version, it starts a
throwaway instance of the pinned production image, points APT at the current
Ubuntu snapshot only for that process, runs `apt-cache policy <package>`, and
reports refresh available when the fixed-or-newer version is offered. It then
removes the throwaway resource. It does not create an OCI image, push a tag, or
change the source pins.

It writes a concise `$GITHUB_STEP_SUMMARY`, uploads vulnerability JSON, and exits nonzero when action is required. It never calls build, push, retag, refresh, pin, or repository-write code.

- [ ] **Step 4: Verify policy and workflow gates**

Run:

```bash
uv run --frozen --group dev pytest Tests/test_sandbox_image_commands.py -v
make zizmor
make sandbox-image-python-lint
make sandbox-image-python-typecheck
make python-test
```

Expected: all pass. Inspect permissions with
`rg -n 'permissions:|id-token:|packages:|statuses:|concurrency:|queue:'
.github/workflows/sandbox-image*.yml` and confirm the narrow scopes and shared
writer group above. Confirm the promotion workflow dispatch ref is `main` and
that no command executes a file from the evidence commit.

- [ ] **Step 5: Commit promotion and maintenance**

Invoke `kenn:commit`, then commit with subject:

```text
Protect sandbox image promotion
```

### Task 8: Document the Canonical Product and Operator Contracts

**Files:**
- Create: `docs/sandbox-image.md`
- Modify: `docs/zensical.toml`
- Modify: `docs/README.md`
- Modify: `docs/sandboxes.md`
- Modify: `docs/threat-model.md`
- Modify: `docs/release.md`

**Interfaces:**
- Consumes: all changeset-one Make commands and pipeline behavior.
- Produces: one canonical product contract in `docs/sandboxes.md` and one lifecycle runbook in `docs/sandbox-image.md`.

- [ ] **Step 1: Update the canonical sandbox contract**

Add an **Image Identity and Updates** section to `docs/sandboxes.md` that states:

- v1 Apple creation always uses the vetted digest in `SANDBOX_IMAGE`; there is no custom-image picker;
- pulling is lazy on first Create and never occurs during ordinary navigation;
- each sandbox persists its creation digest;
- a different packaged pin produces passive **Update Available** state;
- existing resources remain startable at their creation digest;
- confirmed Delete and Recreate is the only update path and destroys private home/root state;
- non-root user and package choices are ergonomic, while the VM and validated mounts remain the boundary.

Cross-reference `docs/sandbox-image.md` for developer operations.

- [ ] **Step 2: Update the threat and release sources of truth**

In `docs/threat-model.md`, describe digest authority, attestation/report validation, and the fact that `ghosthub` plus passwordless sudo supplies no in-VM privilege boundary.

In `docs/release.md`, document image source pins, candidate/promotion ordering,
the protected environment, weekly maintenance, and the `3ed9` packaging
contract: packaged apps will embed `SANDBOX_IMAGE` from the root file into
`GhosthubSandboxImage` without duplicating the digest.

- [ ] **Step 3: Write the streamlined human runbook**

`docs/sandbox-image.md` must lead with the normal operator sequence:

```text
make sandbox-image-status
make sandbox-image-refresh VERSION=X.Y.Z
make sandbox-image-check
# merge changeset one and obtain the emitted candidate digest
make sandbox-image-vet IMAGE=<candidate@digest>
make sandbox-image-pin IMAGE=<candidate@digest>
# commit and push the report-and-pin task branch
make sandbox-image-promote IMAGE=<candidate@digest> VERSION=X.Y.Z
# approve sandbox-image-production once, verify status, merge the pin PR
```

Document prerequisites, what each command changes, report/disposition review,
failure recovery through `status` and `clean`, the non-repointable-tag rule,
anonymous pull verification, and manual first maintenance dispatch. Include the
one-time first-package visibility action, its irreversible nature, and the
exact settings link printed by `status`. Do not require ad hoc lifecycle
commands.

- [ ] **Step 4: Link and build documentation**

Add **Sandbox Image Operations** to `docs/zensical.toml` beside Worktree Sandboxes and describe it in `docs/README.md`. Run:

```bash
make docs-build
```

Expected: no broken links or warnings.

- [ ] **Step 5: Commit the durable contracts**

Invoke `kenn:commit`, then commit with subject:

```text
Document sandbox image operations
```

### Task 9: Verify and Land Changeset One

**Files:**
- Review: all changeset-one files

**Interfaces:**
- Consumes: Tasks 1–8.
- Produces: a clean task branch ready for human review and merge, after which `main` publishes the first candidate.

- [ ] **Step 1: Run the complete changeset-one gate**

Invoke `superpowers:verification-before-completion`, then run fresh:

```bash
make sandbox-image-check
make sandbox-image-status
make sandbox-image-python-lint
make sandbox-image-python-typecheck
make python-test
make zizmor
make docs-build
git diff --check origin/main...HEAD
```

Expected: all pass. `status` may report that candidate, report, production alias, and app pin are pending; that is the correct pre-merge state.

- [ ] **Step 2: Review scope and exclude planning files**

Run:

```bash
git status --short
git diff --stat origin/main...HEAD
git diff --name-only origin/main...HEAD
```

Expected: no `docs/superpowers/` file appears, no Swift/UI/persistence file appears, and no unrelated user change is included.

- [ ] **Step 3: Push and request review**

Push the task branch. Open a pull request only if the user explicitly requests it. Follow the repository's concise rationale-first pull-request format and do not include the planning documents.

- [ ] **Step 4: Merge through the normal human review path**

Do not merge unless the user authorizes it. Once changeset one reaches `main`,
record its exact full commit and wait for `.github/workflows/sandbox-image.yml`
to publish `candidate-<commit>`. Do not poll GitHub Actions unless the user
explicitly asks; use the candidate digest supplied by the workflow or user for
Phase B. On the first publication, Phase B also waits for the organization
owner to make the GHCR package public and for `status` to prove anonymous
digest access.

---

## Phase B: Changeset Two — Evidence, Promotion, and Runtime Pin

### Task 10: Vet the First Public Candidate and Prepare the Pin Pull Request

**Files:**
- Create: `SANDBOX_IMAGE`
- Create: `images/sandbox/reports/sha256-<candidate-digest>.json`

**Interfaces:**
- Consumes: the public candidate digest emitted from the merged changeset-one commit.
- Produces: a task-branch commit binding a passing Apple report to a tag-free runtime pin.

- [ ] **Step 1: Create a fresh task branch from updated `main`**

Use the repository's preferred branch/worktree workflow. Confirm:

```bash
git branch --show-current
git status --short
```

Expected: a clean non-default task branch based on the merged changeset-one
commit. For the first release, run `make sandbox-image-status`, follow its
one-time GHCR package-settings link, choose **Public**, and confirm an anonymous
digest pull before continuing.

- [ ] **Step 2: Vet the exact public candidate digest**

Run:

```bash
make sandbox-image-vet IMAGE=ghcr.io/kenn-io/ghosthub-sandbox:candidate-<full-source-commit>@sha256:<digest>
```

Expected: the public image is pulled anonymously by digest, attestations verify against `kenn-io/ghosthub` and the candidate workflow, all runtime and mount checks pass on Apple silicon with `container` 1.2.2, Stop/Start preserves both markers, and cleanup leaves no managed fixtures.

- [ ] **Step 3: Prepare the tag-free app pin**

Run:

```bash
make sandbox-image-pin IMAGE=ghcr.io/kenn-io/ghosthub-sandbox:candidate-<full-source-commit>@sha256:<digest>
```

Expected: `SANDBOX_IMAGE` contains only `ghcr.io/kenn-io/ghosthub-sandbox@sha256:<digest>` and its canonical report is the only new report file. Run `make sandbox-image-status`; it reports vetting complete and promotion pending.

- [ ] **Step 4: Review and commit evidence plus pin together**

Inspect the report for provider/macOS identity, required checks, scan summary, and dispositions. Confirm it contains no username, host paths, credentials, environment dump, or Git content. Invoke `kenn:commit`, then commit exactly the report and pin with subject:

```text
Pin the vetted sandbox image
```

- [ ] **Step 5: Push the exact task-branch commit**

Push the branch and open/update its pull request only with explicit user authorization. Do not change the report, pin, image version, or source after this push unless you are prepared to advance `VERSION` and repeat candidate vetting and promotion.

### Task 11: Promote the Exact Digest and Exercise Maintenance

**Files:**
- No source edits expected; any fix requires a new normal commit and re-running affected gates.

**Interfaces:**
- Consumes: exact pushed task-branch HEAD, candidate digest, image `VERSION`, report, pin, and attestations.
- Produces: workflow-enforced immutable `vX.Y.Z` alias, required promotion status on the exact pin pull-request head, and one trusted weekly-maintenance run.

- [ ] **Step 1: Verify the task branch is promotion-eligible**

Run:

```bash
git status --short
test "$(git rev-parse HEAD)" = "$(git rev-parse '@{upstream}')"
make sandbox-image-status
```

Expected: clean tree, HEAD equals upstream, report and pin match, candidate attestations pass, and production alias is pending.

- [ ] **Step 2: Dispatch promotion through the supported command**

Run:

```bash
make sandbox-image-promote \
  IMAGE=ghcr.io/kenn-io/ghosthub-sandbox:candidate-<full-source-commit>@sha256:<digest> \
  VERSION=$(tr -d '[:space:]' < images/sandbox/VERSION)
```

Expected: the command dispatches the trusted workflow from `main`, passes exact
`HEAD` as inert evidence, and prints the single `sandbox-image-production`
approval action. Perform that human environment approval. Confirm the workflow
still identifies exact `HEAD` as the pull request head after approval. Do not
run registry retag commands manually.

- [ ] **Step 3: Require the exact-head promotion status**

On the first release, after promotion has reported
`sandbox-image-promotion` success, add that context to the active
default-branch ruleset and bind its expected source to GitHub Actions. This is
a one-time repository setting, not a per-release click. On every release,
verify the current pull-request head shows that required success before
continuing; a newer head must remain pending until promoted independently.

Expected: this exact task-branch HEAD is mergeable with respect to
`sandbox-image-promotion`, while an unrelated pull request receives immediate
success from the trusted gate and requires no sandbox-image operator action.

- [ ] **Step 4: Verify production identity and anonymous consumption**

After the workflow completes, run:

```bash
make sandbox-image-status
docker logout ghcr.io || true
container image pull --platform linux/arm64 "$(tr -d '[:space:]' < SANDBOX_IMAGE)"
```

Expected: candidate and `vX.Y.Z` resolve to the pin, both attestations verify, and anonymous digest pull succeeds.

- [ ] **Step 5: Manually dispatch weekly maintenance before trusting the schedule**

Run the repository-owned status/promote tooling's printed workflow command or the documented GitHub UI action for `sandbox-image-maintenance.yml` against the freshly pinned digest. This is the one allowed human workflow dispatch at acceptance; no source mutation occurs.

Expected: the real pinned digest either passes or fails loudly with the documented job summary and retained vulnerability JSON. If an alarm condition is tested synthetically, use a workflow input that alters policy evaluation only; never retag or publish a synthetic image.

- [ ] **Step 6: Run the final changeset-two gate**

Invoke `superpowers:verification-before-completion`, then run fresh:

```bash
make sandbox-image-status
make sandbox-image-python-lint
make sandbox-image-python-typecheck
make python-test
make zizmor
make docs-build
git diff --check origin/main...HEAD
git diff --name-only origin/main...HEAD | rg 'docs/superpowers/' && exit 1 || true
```

Expected: all gates pass, status reports a fully promoted current image and an
active required promotion context for exact `HEAD`, and no planning artifact
is in the pull-request diff.

- [ ] **Step 7: Merge the pin pull request through the human review path**

Do not merge unless the user authorizes it. Immediately before merge, require
`sandbox-image-promotion` success on the current head. After merge, verify
`main` contains the same `SANDBOX_IMAGE` and report that were promoted. If the
pull request changed after promotion, do not merge it under the existing
`vX.Y.Z`; advance `VERSION` and repeat Phase B.

- [ ] **Step 8: Update Kata without closing provider work**

Comment on `8ems` with the candidate tag/digest, production tag, report path, promotion run, maintenance run, and verification results. Close `8ems` only when both changesets are merged and the production pin is on `main`. Leave `3ed9` open and unblocked for provider implementation; do not mark the sandbox epic complete.
