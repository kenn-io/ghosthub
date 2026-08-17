from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import stat
from collections.abc import Collection
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from pathlib import Path
from typing import Literal

import yaml

from .docker import (
    ImageInputs,
    assert_tag_available,
    build_local_image,
    image_content_digest,
    resolve_tag,
    verify_image_contract,
)
from .model import IMAGE_REPOSITORY, ImageReference, read_regular_text
from .policy import evaluate_findings, load_dispositions
from .process import Runner
from .report import (
    EXPECTED_ATTESTATIONS,
    VettingReport,
    validate_report,
    validate_report_freshness,
)
from .trivy import scan_image, scan_reference

MERGE_QUEUE_PARAMETERS = {
    "check_response_timeout_minutes": 60,
    "grouping_strategy": "ALLGREEN",
    "max_entries_to_build": 1,
    "max_entries_to_merge": 1,
    "merge_method": "SQUASH",
    "min_entries_to_merge": 1,
    "min_entries_to_merge_wait_minutes": 0,
}
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
REVIEWED_IMAGE_INPUTS = (
    Path("APT_SNAPSHOT"),
    Path("Dockerfile"),
    Path("UBUNTU_BASE"),
    Path("VERSION"),
    Path("packages.txt"),
    Path("tests/image-contract.sh"),
    Path("vulnerability-dispositions.json"),
)
PROMOTION_STATUS_ENVIRONMENT = "sandbox-image-promotion-status"
PROMOTION_STATUS_WORKFLOW = "sandbox-image-promotion-gate.yml"
PROMOTION_WORKFLOW = "sandbox-image-promote.yml"
POST_APPROVAL_POLICY = Path("tools/sandbox_image/post_approval_policy.jq")
PACKAGE_WRITER_ENVIRONMENT = "sandbox-image-package-writer"
PACKAGE_WRITER_WORKFLOW = "sandbox-image-publish.yml"
PRODUCTION_ENVIRONMENT = "sandbox-image-production"
MERGE_SIGNAL_WORKFLOW = ".github/workflows/sandbox-image-merge-signal.yml"
MERGE_SIGNAL_NAME = "Sandbox image merge signal"
MERGE_SIGNAL_REPOSITORY = "kenn-io/ghosthub-nightly"
ALLOWED_REUSABLE_WORKFLOWS = {
    "kenn-io/ghosthub/.github/workflows/ci.yml@main",
}
MERGE_SIGNAL_REPOSITORY_ID = 1_334_318_821
MERGE_SIGNAL_REF = "refs/tags/sandbox-merge-signal-v1"
MERGE_SIGNAL_COMMIT = "9c5afce214433bc642802220402a2e4ec4055f5d"
MERGE_SIGNAL_TAG = "sandbox-merge-signal-v1"
PROMOTION_AUTHORIZATION_WINDOW = timedelta(hours=23)
PROMOTION_EVIDENCE_COVERAGE = timedelta(hours=24)


@dataclass(frozen=True)
class PromotionEvidence:
    commit: str
    pull_request: int
    image: ImageReference
    version: str
    report: VettingReport


@dataclass(frozen=True)
class CandidatePlan:
    tag: str
    local_content_digest: str
    archive: Path
    image_version: str


@dataclass(frozen=True)
class PromotionPlan:
    candidate: ImageReference
    production_tag: str
    action: Literal["create", "already-correct"]
    expires_at: datetime
    production_environment_fingerprint: str
    status_environment_fingerprint: str


def promotion_deadline(report: VettingReport, *, now: datetime) -> datetime:
    if now.tzinfo is None:
        raise ValueError("promotion clock must be timezone-aware")
    current = now.astimezone(UTC)
    evidence_deadlines = (
        datetime.fromisoformat(report.completed_at.removesuffix("Z") + "+00:00")
        + timedelta(days=7),
        datetime.fromisoformat(
            report.scan_database_timestamp.removesuffix("Z") + "+00:00"
        )
        + timedelta(days=7),
    )
    disposition_deadlines = tuple(
        datetime.combine(disposition.expires + timedelta(days=1), time.min, UTC)
        for disposition in report.dispositions
    )
    authorization_deadline = current + PROMOTION_AUTHORIZATION_WINDOW
    evidence_coverage_deadline = current + PROMOTION_EVIDENCE_COVERAGE
    evidence_deadline = min(
        *evidence_deadlines,
        *disposition_deadlines,
    )
    if evidence_deadline < evidence_coverage_deadline:
        raise ValueError(
            "promotion evidence must remain valid for the full authorization window"
        )
    return authorization_deadline


def candidate_action(
    event: str, ref: str, changed_paths: Collection[Path]
) -> Literal["check-only", "publish", "skip"]:
    watched = any(
        path.is_relative_to("images/sandbox")
        or path == Path("tools/sandbox_image.py")
        or path.is_relative_to("tools/sandbox_image")
        or (
            path.parent == Path("tools/tests")
            and path.name.startswith("test_sandbox_image_")
        )
        or (path.name.startswith("sandbox-image") and path.suffix == ".yml")
        for path in changed_paths
    )
    if not watched:
        return "skip"
    if event == "pull_request":
        return "check-only"
    if (
        event == "push"
        and ref == "refs/heads/main"
        and any(path.is_relative_to("images/sandbox") for path in changed_paths)
    ):
        return "publish"
    return "skip"


def promotion_gate_action(
    changed_paths: Collection[Path], current_state: str
) -> Literal["pending", "success"]:
    relevant = any(
        path == Path("SANDBOX_IMAGE") or path.is_relative_to("images/sandbox/reports")
        for path in changed_paths
    )
    if relevant and current_state != "success":
        return "pending"
    return "success"


def promotion_evidence_paths(digest: str) -> set[Path]:
    if not digest.startswith("sha256:") or len(digest) != 71:
        raise ValueError("promotion digest is invalid")
    return {
        Path("SANDBOX_IMAGE"),
        Path("images/sandbox/reports") / f"{digest.replace(':', '-')}.json",
    }


def promotion_changed_paths(files: Collection[object]) -> set[Path]:
    changed: set[Path] = set()
    for item in files:
        if not isinstance(item, dict) or not isinstance(item.get("filename"), str):
            raise ValueError("pull request file evidence is invalid")
        changed.add(Path(item["filename"]))
        previous = item.get("previous_filename")
        if previous is not None:
            if not isinstance(previous, str):
                raise ValueError("pull request file evidence is invalid")
            changed.add(Path(previous))
    return changed


def promotion_pull_request(
    pulls: object,
    evidence_commit: str,
    trusted_base: str,
) -> int:
    if not isinstance(pulls, list):
        raise ValueError("GitHub pull request evidence is invalid")
    matches = [
        item
        for item in pulls
        if isinstance(item, dict)
        and item.get("state") == "open"
        and isinstance(item.get("base"), dict)
        and item["base"].get("ref") == "main"
        and item["base"].get("sha") == trusted_base
        and isinstance(item.get("head"), dict)
        and item["head"].get("sha") == evidence_commit
    ]
    if len(matches) != 1 or not isinstance(matches[0].get("number"), int):
        raise ValueError(
            "evidence must be one open pull request at the trusted main revision"
        )
    return matches[0]["number"]


def verify_candidate_attestations(
    image: ImageReference,
    source: str,
    expected_inputs_digest: str,
    runner: Runner,
) -> None:
    for predicate in sorted(EXPECTED_ATTESTATIONS):
        result = runner.run(
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
        if predicate == "https://slsa.dev/provenance/v0.2":
            _verify_provenance_inputs(result.stdout, expected_inputs_digest)


def image_inputs_digest(root: Path) -> str:
    digest = hashlib.sha256()
    image = root / "images/sandbox"
    for relative in REVIEWED_IMAGE_INPUTS:
        try:
            content = (image / relative).read_bytes()
        except OSError as error:
            raise ValueError(f"cannot read reviewed image input: {relative}") from error
        name = relative.as_posix().encode()
        digest.update(len(name).to_bytes(4, "big"))
        digest.update(name)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return "sha256:" + digest.hexdigest()


def _verify_provenance_inputs(output: str, expected: str) -> None:
    try:
        attestations = json.loads(output)
    except json.JSONDecodeError as error:
        raise ValueError(
            "candidate provenance verification output is invalid"
        ) from error
    if not isinstance(attestations, list) or not any(
        _attested_inputs_digest(item) == expected for item in attestations
    ):
        raise ValueError("candidate provenance does not match reviewed inputs")


def _attested_inputs_digest(value: object) -> str | None:
    current = value
    for key in (
        "verificationResult",
        "statement",
        "predicate",
        "invocation",
        "parameters",
    ):
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    if not isinstance(current, dict):
        return None
    result = current.get("image_inputs_digest")
    return result if isinstance(result, str) else None


def verify_current_candidate_policy(
    root: Path,
    candidate: ImageReference,
    runner: Runner,
) -> None:
    policy_date = datetime.now(UTC).date()
    artifacts = scan_reference(root, candidate.canonical, runner)
    dispositions = load_dispositions(
        root / "images/sandbox/vulnerability-dispositions.json", policy_date
    )
    if not evaluate_findings(
        artifacts.findings, dispositions, policy_date
    ).accepted:
        raise ValueError("current candidate vulnerability policy did not pass")


def local_promotion_head(root: Path, runner: Runner) -> str:
    status = runner.run(("git", "-C", str(root), "status", "--porcelain")).stdout
    if status:
        raise ValueError("promotion requires a clean worktree")
    branch = runner.run(
        ("git", "-C", str(root), "symbolic-ref", "--short", "HEAD")
    ).stdout.strip()
    if not branch or branch in {"main", "master"}:
        raise ValueError("promotion requires a pushed task branch")
    head = runner.run(("git", "-C", str(root), "rev-parse", "HEAD")).stdout.strip()
    upstream = runner.run(
        ("git", "-C", str(root), "rev-parse", "@{upstream}")
    ).stdout.strip()
    if COMMIT_PATTERN.fullmatch(head) is None or head != upstream:
        raise ValueError("promotion branch HEAD must equal its upstream")
    return head


def dispatch_promotion(
    root: Path,
    image: ImageReference,
    version: str,
    runner: Runner,
) -> str:
    if VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError("promotion version must be X.Y.Z")
    head = local_promotion_head(root, runner)
    pin = ImageReference.parse_runtime_pin(
        read_regular_text(root / "SANDBOX_IMAGE", "SANDBOX_IMAGE").strip()
    )
    if pin.digest != image.digest:
        raise ValueError("promotion image does not match SANDBOX_IMAGE")
    runner.run(
        (
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
            f"client_payload[digest]={image.digest}",
            "-f",
            f"client_payload[version]={version}",
        )
    )
    return head


def _api_json(runner: Runner, endpoint: str) -> object:
    try:
        return json.loads(runner.run(("gh", "api", endpoint)).stdout)
    except json.JSONDecodeError as error:
        raise ValueError("GitHub API returned invalid JSON") from error


def list_ruleset_summaries(runner: Runner) -> list[object]:
    try:
        pages = json.loads(
            runner.run(
                (
                    "gh",
                    "api",
                    "--paginate",
                    "--slurp",
                    "repos/kenn-io/ghosthub/rulesets?per_page=100",
                )
            ).stdout
        )
    except json.JSONDecodeError as error:
        raise ValueError("GitHub API returned invalid JSON") from error
    if not isinstance(pages, list) or not all(
        isinstance(page, list) for page in pages
    ):
        raise ValueError("repository ruleset configuration is invalid")
    return [summary for page in pages for summary in page]


def _evidence_blob(runner: Runner, path: Path, commit: str) -> bytes:
    tree_endpoint = f"repos/kenn-io/ghosthub/git/trees/{commit}?recursive=1"
    tree_payload = _api_json(runner, tree_endpoint)
    if (
        not isinstance(tree_payload, dict)
        or tree_payload.get("truncated") is not False
        or not isinstance(tree_payload.get("tree"), list)
    ):
        raise ValueError("GitHub evidence tree has an invalid response")
    matches = [
        entry
        for entry in tree_payload["tree"]
        if isinstance(entry, dict) and entry.get("path") == path.as_posix()
    ]
    if len(matches) != 1:
        raise ValueError("GitHub evidence path is missing or ambiguous")
    entry = matches[0]
    blob_sha = entry.get("sha")
    if (
        entry.get("type") != "blob"
        or entry.get("mode") != "100644"
        or not isinstance(blob_sha, str)
        or COMMIT_PATTERN.fullmatch(blob_sha) is None
    ):
        raise ValueError("GitHub evidence path must be a regular Git blob")
    payload = _api_json(runner, f"repos/kenn-io/ghosthub/git/blobs/{blob_sha}")
    if (
        not isinstance(payload, dict)
        or payload.get("sha") != blob_sha
        or payload.get("encoding") != "base64"
    ):
        raise ValueError("GitHub evidence blob has an invalid response")
    content = payload.get("content")
    size = payload.get("size")
    if (
        not isinstance(content, str)
        or not isinstance(size, int)
        or size < 0
        or size > 3_000_000
        or len(content) > 4_000_000
    ):
        raise ValueError("GitHub evidence blob is missing or too large")
    try:
        decoded = base64.b64decode("".join(content.split()), validate=True)
    except ValueError as error:
        raise ValueError("GitHub evidence blob is not valid base64") from error
    if len(decoded) != size:
        raise ValueError("GitHub evidence blob size does not match")
    return decoded


def verify_production_environment(
    runner: Runner,
    *,
    expected_app_id: int | None = None,
    require_credentials: bool = True,
) -> str:
    endpoint = f"repos/kenn-io/ghosthub/environments/{PRODUCTION_ENVIRONMENT}"
    environment = _api_json(runner, endpoint)
    if not isinstance(environment, dict):
        raise ValueError("production environment configuration is invalid")
    rules = environment.get("protection_rules")
    if not isinstance(rules, list) or not any(
        isinstance(rule, dict)
        and rule.get("type") == "required_reviewers"
        and isinstance(rule.get("reviewers"), list)
        and bool(rule["reviewers"])
        for rule in rules
    ):
        raise ValueError("production environment requires a reviewer")
    policy = environment.get("deployment_branch_policy")
    if policy != {
        "protected_branches": False,
        "custom_branch_policies": True,
    }:
        raise ValueError("production environment must use custom branch policy")
    policies = _api_json(runner, endpoint + "/deployment-branch-policies")
    if (
        not isinstance(policies, dict)
        or policies.get("total_count") != 1
        or not isinstance(policies.get("branch_policies"), list)
        or len(policies["branch_policies"]) != 1
        or not isinstance(policies["branch_policies"][0], dict)
        or policies["branch_policies"][0].get("name") != "main"
        or policies["branch_policies"][0].get("type") != "branch"
    ):
        raise ValueError("production environment must admit only main")
    reviewer_rules = [
        rule
        for rule in rules
        if isinstance(rule, dict) and rule.get("type") == "required_reviewers"
    ]
    policy_evidence = {
        "branch_policies": policies["branch_policies"],
        "deployment_branch_policy": policy,
        "reviewer_rules": reviewer_rules,
    }
    if not require_credentials:
        canonical = json.dumps(
            policy_evidence, sort_keys=True, separators=(",", ":")
        )
        return hashlib.sha256(canonical.encode()).hexdigest()
    variables = _api_json(runner, endpoint + "/variables")
    if not isinstance(variables, dict) or not isinstance(
        variables.get("variables"), list
    ):
        raise ValueError("production environment credential set is invalid")
    values = {
        item.get("name"): item.get("value")
        for item in variables["variables"]
        if isinstance(item, dict)
    }
    if set(values) != {
        "SANDBOX_PROMOTION_APP_ID",
        "SANDBOX_PROMOTION_APP_CLIENT_ID",
    }:
        raise ValueError("production environment credential set is invalid")
    app_id = values["SANDBOX_PROMOTION_APP_ID"]
    client_id = values["SANDBOX_PROMOTION_APP_CLIENT_ID"]
    if (
        not isinstance(app_id, str)
        or not app_id.isdecimal()
        or int(app_id) <= 0
        or (expected_app_id is not None and int(app_id) != expected_app_id)
        or not isinstance(client_id, str)
        or not client_id
    ):
        raise ValueError("production environment credential set is invalid")
    secrets = _api_json(runner, endpoint + "/secrets")
    if not isinstance(secrets, dict) or not isinstance(secrets.get("secrets"), list):
        raise ValueError("production environment credential set is invalid")
    secret_metadata = _secret_metadata(
        secrets["secrets"], "production environment"
    )
    secret_names = [item["name"] for item in secret_metadata]
    if secret_names != [
        "SANDBOX_PACKAGE_WRITER_TOKEN",
        "SANDBOX_PACKAGE_WRITER_USERNAME",
        "SANDBOX_PROMOTION_APP_PRIVATE_KEY",
    ]:
        raise ValueError("production environment credential set is invalid")
    canonical = json.dumps(
        {
            **policy_evidence,
            "secrets": secret_metadata,
            "variables": values,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def _grants_status_write(value: object) -> bool:
    if value == "write-all":
        return True
    if not isinstance(value, dict):
        return False
    status = value.get("statuses")
    return status not in {None, "none", "read"}


def _grants_package_write(value: object) -> bool:
    if value == "write-all":
        return True
    if not isinstance(value, dict):
        return False
    packages = value.get("packages")
    return packages not in {None, "none", "read"}


def _secret_metadata(value: object, label: str) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise ValueError(f"{label} secrets are invalid")
    metadata: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, dict) or any(
            not isinstance(item.get(key), str) or not item[key]
            for key in ("name", "created_at", "updated_at")
        ):
            raise ValueError(f"{label} secrets are invalid")
        metadata.append(
            {
                "name": item["name"],
                "created_at": item["created_at"],
                "updated_at": item["updated_at"],
            }
        )
    return sorted(metadata, key=lambda item: item["name"])


def _environment_name(value: object, path: Path) -> str | None:
    if value is None:
        return None
    name = value.get("name") if isinstance(value, dict) else value
    if not isinstance(name, str) or "${{" in name:
        raise ValueError(f"workflow uses a dynamic environment: {path.name}")
    return name


def _verify_workflow_root(path: Path) -> None:
    for component in (path.parent, path):
        try:
            mode = component.lstat().st_mode
        except OSError as error:
            raise ValueError("cannot audit workflow root") from error
        if stat.S_ISLNK(mode):
            raise ValueError("workflow path must not contain a symlink")
        if not stat.S_ISDIR(mode):
            raise ValueError("workflow path component must be a directory")


def _read_regular_workflow(path: Path) -> bytes:
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        raise ValueError(f"cannot audit workflow: {path.name}") from error
    if stat.S_ISLNK(mode):
        raise ValueError(f"workflow must not be a symlink: {path.name}")
    if not stat.S_ISREG(mode):
        raise ValueError(f"workflow must be a regular file: {path.name}")
    try:
        return path.read_bytes()
    except OSError as error:
        raise ValueError(f"cannot audit workflow: {path.name}") from error


def _read_regular_authority_file(root: Path, relative_path: Path) -> bytes:
    current = root
    directories = [root]
    for part in relative_path.parts[:-1]:
        current /= part
        directories.append(current)
    for directory in directories:
        try:
            mode = directory.lstat().st_mode
        except OSError as error:
            raise ValueError("cannot audit promotion authority path") from error
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise ValueError("promotion authority path must contain directories")
    path = current / relative_path.name
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        raise ValueError("cannot audit promotion authority file") from error
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise ValueError("promotion authority file must be a regular file")
    try:
        return path.read_bytes()
    except OSError as error:
        raise ValueError("cannot audit promotion authority file") from error


def verify_promotion_workflows(
    workflow_root: Path,
    *,
    trusted_workflow_root: Path | None = None,
    repository_root: Path | None = None,
    trusted_repository_root: Path | None = None,
) -> None:
    status_references: set[str] = set()
    package_references: set[str] = set()
    production_references: set[str] = set()
    _verify_workflow_root(workflow_root)
    if trusted_workflow_root is not None:
        _verify_workflow_root(trusted_workflow_root)
    workflow_paths = set(workflow_root.glob("*.yml")) | set(
        workflow_root.glob("*.yaml")
    )
    for path in sorted(workflow_paths):
        try:
            content = _read_regular_workflow(path).decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValueError(f"cannot audit workflow: {path.name}") from error
        try:
            workflow = yaml.safe_load(content)
        except yaml.YAMLError as error:
            raise ValueError(f"cannot parse workflow: {path.name}") from error
        if not isinstance(workflow, dict):
            raise ValueError(f"workflow structure is invalid: {path.name}")
        if (
            path.name == Path(MERGE_SIGNAL_WORKFLOW).name
            or workflow.get("name") == MERGE_SIGNAL_NAME
        ):
            raise ValueError(
                "merge-signal workflow identity is reserved for external authority"
            )
        if "permissions" not in workflow or workflow["permissions"] is None:
            raise ValueError(
                f"workflow must declare explicit top-level permissions: {path.name}"
            )
        if _grants_status_write(workflow.get("permissions")):
            raise ValueError("GITHUB_TOKEN must not receive status-write authority")
        if _grants_package_write(workflow.get("permissions")):
            raise ValueError("GITHUB_TOKEN must not receive package-write authority")
        jobs = workflow.get("jobs")
        if not isinstance(jobs, dict):
            raise ValueError(f"workflow jobs are invalid: {path.name}")
        for job in jobs.values():
            if not isinstance(job, dict):
                raise ValueError(f"workflow job is invalid: {path.name}")
            reusable_workflow = job.get("uses")
            if (
                reusable_workflow is not None
                and reusable_workflow not in ALLOWED_REUSABLE_WORKFLOWS
            ):
                raise ValueError(
                    f"workflow invokes an unapproved reusable workflow: {path.name}"
                )
            if _grants_status_write(job.get("permissions")):
                raise ValueError(
                    "GITHUB_TOKEN must not receive status-write authority"
                )
            if _grants_package_write(job.get("permissions")):
                raise ValueError(
                    "GITHUB_TOKEN must not receive package-write authority"
                )
            environment_name = _environment_name(job.get("environment"), path)
            if environment_name is not None and environment_name.casefold() == (
                PROMOTION_STATUS_ENVIRONMENT.casefold()
            ):
                status_references.add(path.name)
            if environment_name is not None and environment_name.casefold() == (
                PACKAGE_WRITER_ENVIRONMENT.casefold()
            ):
                package_references.add(path.name)
            if environment_name is not None and environment_name.casefold() == (
                PRODUCTION_ENVIRONMENT.casefold()
            ):
                production_references.add(path.name)
    if status_references != {PROMOTION_STATUS_WORKFLOW, PROMOTION_WORKFLOW}:
        raise ValueError(
            "promotion status environment must have exactly the trusted workflows"
        )
    if package_references != {PACKAGE_WRITER_WORKFLOW}:
        raise ValueError(
            "package writer environment must have exactly one trusted workflow"
        )
    if production_references != {PROMOTION_WORKFLOW}:
        raise ValueError(
            "production environment must have exactly one trusted workflow"
        )
    if trusted_workflow_root is not None:
        for name, label in (
            (PROMOTION_STATUS_WORKFLOW, "status"),
            (PROMOTION_WORKFLOW, "promotion"),
            (PACKAGE_WRITER_WORKFLOW, "package writer"),
        ):
            trusted = trusted_workflow_root / name
            proposed = workflow_root / name
            try:
                trusted_content = _read_regular_workflow(trusted)
                proposed_content = _read_regular_workflow(proposed)
            except ValueError as error:
                raise ValueError(f"cannot compare trusted {label} workflow") from error
            if trusted_content != proposed_content:
                raise ValueError(f"trusted {label} workflow changed in proposed tree")
        if repository_root is not None or trusted_repository_root is not None:
            if repository_root is None or trusted_repository_root is None:
                raise ValueError(
                    "repository roots are required for proposed authority"
                )
            trusted_policy = _read_regular_authority_file(
                trusted_repository_root,
                POST_APPROVAL_POLICY,
            )
            proposed_policy = _read_regular_authority_file(
                repository_root,
                POST_APPROVAL_POLICY,
            )
            if trusted_policy != proposed_policy:
                raise ValueError(
                    "trusted post-approval policy changed in proposed tree"
                )


def verify_package_writer_environment(runner: Runner) -> None:
    endpoint = f"repos/kenn-io/ghosthub/environments/{PACKAGE_WRITER_ENVIRONMENT}"
    environment = _api_json(runner, endpoint)
    if not isinstance(environment, dict):
        raise ValueError("package writer environment configuration is invalid")
    rules = environment.get("protection_rules")
    if not isinstance(rules, list) or [
        rule.get("type") for rule in rules if isinstance(rule, dict)
    ] != ["branch_policy"]:
        raise ValueError("package writer environment must not require reviewers")
    if environment.get("deployment_branch_policy") != {
        "protected_branches": False,
        "custom_branch_policies": True,
    }:
        raise ValueError("package writer environment must use custom branch policy")
    policies = _api_json(runner, endpoint + "/deployment-branch-policies")
    if (
        not isinstance(policies, dict)
        or policies.get("total_count") != 1
        or not isinstance(policies.get("branch_policies"), list)
        or len(policies["branch_policies"]) != 1
        or not isinstance(policies["branch_policies"][0], dict)
        or policies["branch_policies"][0].get("name") != "main"
        or policies["branch_policies"][0].get("type") != "branch"
    ):
        raise ValueError("package writer environment must admit only main")
    secrets = _api_json(runner, endpoint + "/secrets")
    if not isinstance(secrets, dict) or not isinstance(secrets.get("secrets"), list):
        raise ValueError("package writer environment secrets are invalid")
    names = {
        item.get("name") for item in secrets["secrets"] if isinstance(item, dict)
    }
    if names != {
        "SANDBOX_PACKAGE_WRITER_USERNAME",
        "SANDBOX_PACKAGE_WRITER_TOKEN",
    }:
        raise ValueError("package writer environment secret set is invalid")


def verify_promotion_status_environment(
    root: Path,
    runner: Runner,
    expected_app_id: int,
    *,
    workflow_root: Path | None = None,
) -> str:
    proposed_workflows = workflow_root or root / ".github/workflows"
    trusted_workflows = (
        root / ".github/workflows" if workflow_root is not None else None
    )
    verify_promotion_workflows(
        proposed_workflows,
        trusted_workflow_root=trusted_workflows,
        repository_root=(
            workflow_root.parent.parent if workflow_root is not None else None
        ),
        trusted_repository_root=(root if workflow_root is not None else None),
    )

    endpoint = f"repos/kenn-io/ghosthub/environments/{PROMOTION_STATUS_ENVIRONMENT}"
    environment = _api_json(runner, endpoint)
    if not isinstance(environment, dict):
        raise ValueError("promotion status environment configuration is invalid")
    rules = environment.get("protection_rules")
    if not isinstance(rules, list) or [
        rule.get("type") for rule in rules if isinstance(rule, dict)
    ] != ["branch_policy"]:
        raise ValueError("promotion status environment must not require reviewers")
    if environment.get("deployment_branch_policy") != {
        "protected_branches": False,
        "custom_branch_policies": True,
    }:
        raise ValueError("promotion status environment must use custom branch policy")
    policies = _api_json(runner, endpoint + "/deployment-branch-policies")
    if (
        not isinstance(policies, dict)
        or policies.get("total_count") != 1
        or not isinstance(policies.get("branch_policies"), list)
        or len(policies["branch_policies"]) != 1
        or not isinstance(policies["branch_policies"][0], dict)
        or policies["branch_policies"][0].get("name") != "main"
        or policies["branch_policies"][0].get("type") != "branch"
    ):
        raise ValueError("promotion status environment must admit only main")
    variables = _api_json(runner, endpoint + "/variables")
    if not isinstance(variables, dict) or not isinstance(
        variables.get("variables"), list
    ):
        raise ValueError("promotion status environment variables are invalid")
    values = {
        item.get("name"): item.get("value")
        for item in variables["variables"]
        if isinstance(item, dict)
    }
    if set(values) != {
        "SANDBOX_PROMOTION_APP_ID",
        "SANDBOX_PROMOTION_APP_CLIENT_ID",
    } or values["SANDBOX_PROMOTION_APP_ID"] != str(expected_app_id):
        raise ValueError("promotion status app variables do not match authority")
    client_id = values["SANDBOX_PROMOTION_APP_CLIENT_ID"]
    if not isinstance(client_id, str) or not client_id:
        raise ValueError("promotion status app client ID is missing")
    secrets = _api_json(runner, endpoint + "/secrets")
    if not isinstance(secrets, dict) or not isinstance(secrets.get("secrets"), list):
        raise ValueError("promotion status environment secrets are invalid")
    secret_metadata = _secret_metadata(
        secrets["secrets"], "promotion status environment"
    )
    names = {item["name"] for item in secret_metadata}
    if names != {"SANDBOX_PROMOTION_APP_PRIVATE_KEY"}:
        raise ValueError("promotion status environment secret set is invalid")
    canonical = json.dumps(
        {
            "branch_policies": policies["branch_policies"],
            "deployment_branch_policy": environment["deployment_branch_policy"],
            "secrets": secret_metadata,
            "variables": values,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def verify_required_promotion_status(
    runner: Runner, expected_integration_id: int
) -> None:
    summaries = list_ruleset_summaries(runner)
    for summary in summaries:
        if not isinstance(summary, dict) or not isinstance(summary.get("id"), int):
            raise ValueError("repository ruleset configuration is invalid")
        ruleset = _api_json(
            runner, f"repos/kenn-io/ghosthub/rulesets/{summary['id']}"
        )
        if _ruleset_requires_promotion_status(ruleset, expected_integration_id):
            return
    raise ValueError("main must require the strict sandbox-image-promotion check")


def verify_required_merge_signal(runner: Runner) -> None:
    summaries = list_ruleset_summaries(runner)
    for summary in summaries:
        if not isinstance(summary, dict) or not isinstance(summary.get("id"), int):
            raise ValueError("repository ruleset configuration is invalid")
        ruleset = _api_json(
            runner, f"repos/kenn-io/ghosthub/rulesets/{summary['id']}"
        )
        if _ruleset_requires_merge_signal(ruleset):
            _verify_merge_signal_revision(runner)
            _verify_merge_signal_workflow(runner)
            return
    raise ValueError("main must require the trusted merge-signal workflow")


def _verify_merge_signal_workflow(runner: Runner) -> None:
    endpoint = (
        f"repos/{MERGE_SIGNAL_REPOSITORY}/contents/{MERGE_SIGNAL_WORKFLOW}"
        f"?ref={MERGE_SIGNAL_COMMIT}"
    )
    payload = _api_json(runner, endpoint)
    if (
        not isinstance(payload, dict)
        or payload.get("type") != "file"
        or payload.get("path") != MERGE_SIGNAL_WORKFLOW
        or payload.get("encoding") != "base64"
    ):
        raise ValueError("trusted merge-signal workflow source is invalid")
    content = payload.get("content")
    size = payload.get("size")
    if (
        not isinstance(content, str)
        or not isinstance(size, int)
        or size < 0
        or size > 64_000
        or len(content) > 100_000
    ):
        raise ValueError("trusted merge-signal workflow source is invalid")
    try:
        decoded = base64.b64decode("".join(content.split()), validate=True)
        text = decoded.decode("utf-8")
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("trusted merge-signal workflow source is invalid") from error
    if len(decoded) != size:
        raise ValueError("trusted merge-signal workflow source is invalid")
    try:
        workflow = yaml.safe_load(text)
    except yaml.YAMLError as error:
        raise ValueError("trusted merge-signal workflow source is invalid") from error
    if not isinstance(workflow, dict):
        raise ValueError("trusted merge-signal workflow source is invalid")
    if workflow.get("name") != MERGE_SIGNAL_NAME:
        raise ValueError("trusted merge-signal workflow name is invalid")
    trigger = workflow.get("on", workflow.get(True))
    if trigger != {
        "pull_request": None,
        "merge_group": {"types": ["checks_requested"]},
    }:
        raise ValueError("trusted merge-signal workflow trigger is invalid")
    if workflow.get("permissions") != {}:
        raise ValueError("trusted merge-signal workflow permissions are invalid")
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        raise ValueError("trusted merge-signal workflow jobs are invalid")
    for job in jobs.values():
        if (
            not isinstance(job, dict)
            or job.get("environment") is not None
            or job.get("uses") is not None
            or job.get("permissions") not in (None, {})
        ):
            raise ValueError("trusted merge-signal workflow job authority is invalid")


def _verify_merge_signal_revision(runner: Runner) -> None:
    reference = _api_json(
        runner,
        f"repos/{MERGE_SIGNAL_REPOSITORY}/git/ref/tags/{MERGE_SIGNAL_TAG}",
    )
    target = reference.get("object") if isinstance(reference, dict) else None
    if (
        not isinstance(target, dict)
        or target.get("type") != "commit"
        or target.get("sha") != MERGE_SIGNAL_COMMIT
    ):
        raise ValueError("trusted merge-signal tag does not resolve to reviewed source")


def _ruleset_requires_merge_signal(value: object) -> bool:
    if not isinstance(value, dict):
        return False
    conditions = value.get("conditions")
    ref_name = conditions.get("ref_name") if isinstance(conditions, dict) else None
    rules = value.get("rules")
    if (
        value.get("source_type") != "Organization"
        or value.get("source") != "kenn-io"
        or value.get("target") != "branch"
        or value.get("enforcement") != "active"
        or value.get("bypass_actors") != []
        or not isinstance(ref_name, dict)
        or "~DEFAULT_BRANCH" not in ref_name.get("include", [])
        or ref_name.get("exclude") != []
        or not isinstance(rules, list)
    ):
        return False
    for rule in rules:
        if not isinstance(rule, dict) or rule.get("type") != "workflows":
            continue
        parameters = rule.get("parameters")
        workflows = (
            parameters.get("workflows") if isinstance(parameters, dict) else None
        )
        if not isinstance(workflows, list):
            continue
        if any(
            isinstance(workflow, dict)
            and workflow.get("path") == MERGE_SIGNAL_WORKFLOW
            and workflow.get("ref") == MERGE_SIGNAL_REF
            and workflow.get("repository_id") == MERGE_SIGNAL_REPOSITORY_ID
            for workflow in workflows
        ):
            return True
    return False


def _ruleset_requires_promotion_status(
    value: object, expected_integration_id: int
) -> bool:
    if not isinstance(value, dict):
        return False
    conditions = value.get("conditions")
    if not isinstance(conditions, dict):
        return False
    ref_name = conditions.get("ref_name")
    if not isinstance(ref_name, dict):
        return False
    includes = ref_name.get("include")
    excludes = ref_name.get("exclude")
    if not isinstance(includes, list) or excludes != []:
        return False
    rules = value.get("rules")
    if not isinstance(rules, list):
        return False
    requires_status = (
        value.get("target") == "branch"
        and value.get("enforcement") == "active"
        and value.get("bypass_actors") == []
        and "~DEFAULT_BRANCH" in includes
        and any(
            _rule_requires_promotion_status(rule, expected_integration_id)
            for rule in rules
        )
    )
    requires_merge_queue = any(
        isinstance(rule, dict)
        and rule.get("type") == "merge_queue"
        and rule.get("parameters") == MERGE_QUEUE_PARAMETERS
        for rule in rules
    )
    requires_pull_request = any(
        isinstance(rule, dict) and rule.get("type") == "pull_request"
        for rule in rules
    )
    return requires_status and requires_merge_queue and requires_pull_request


def _rule_requires_promotion_status(
    value: object, expected_integration_id: int
) -> bool:
    if not isinstance(value, dict) or value.get("type") != "required_status_checks":
        return False
    parameters = value.get("parameters")
    if not isinstance(parameters, dict):
        return False
    checks = parameters.get("required_status_checks")
    return (
        parameters.get("strict_required_status_checks_policy") is True
        and isinstance(checks, list)
        and any(
            isinstance(check, dict)
            and check.get("context") == "sandbox-image-promotion"
            and check.get("integration_id") == expected_integration_id
            for check in checks
        )
    )


def verify_promotion_evidence(
    root: Path,
    evidence_commit: str,
    digest: str,
    version: str,
    runner: Runner,
    *,
    now: datetime | None = None,
) -> PromotionEvidence:
    if COMMIT_PATTERN.fullmatch(evidence_commit) is None:
        raise ValueError("evidence commit is invalid")
    image = ImageReference.parse(f"{IMAGE_REPOSITORY}@{digest}")
    if VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError("promotion version must be X.Y.Z")
    trusted_base = runner.run(
        ("git", "-C", str(root), "rev-parse", "HEAD")
    ).stdout.strip()
    if COMMIT_PATTERN.fullmatch(trusted_base) is None:
        raise ValueError("trusted main revision is invalid")
    pulls = _api_json(runner, f"repos/kenn-io/ghosthub/commits/{evidence_commit}/pulls")
    number = promotion_pull_request(pulls, evidence_commit, trusted_base)
    try:
        pages = json.loads(
            runner.run(
                (
                    "gh",
                    "api",
                    "--paginate",
                    "--slurp",
                    f"repos/kenn-io/ghosthub/pulls/{number}/files?per_page=100",
                )
            ).stdout
        )
    except json.JSONDecodeError as error:
        raise ValueError("pull request file evidence is invalid") from error
    if not isinstance(pages, list) or not all(isinstance(page, list) for page in pages):
        raise ValueError("pull request file evidence is invalid")
    files = [item for page in pages for item in page]
    if not all(isinstance(item, dict) for item in files):
        raise ValueError("pull request file evidence is invalid")
    changed = promotion_changed_paths(files)
    if changed != promotion_evidence_paths(digest):
        raise ValueError("evidence diff must contain only the pin and canonical report")
    pin_value = _evidence_blob(runner, Path("SANDBOX_IMAGE"), evidence_commit)
    try:
        pin = ImageReference.parse_runtime_pin(pin_value.decode().strip())
    except UnicodeDecodeError as error:
        raise ValueError("SANDBOX_IMAGE evidence is not UTF-8") from error
    if pin != image:
        raise ValueError("SANDBOX_IMAGE evidence does not match the requested digest")
    report_path = next(path for path in changed if path != Path("SANDBOX_IMAGE"))
    try:
        report_payload = json.loads(
            _evidence_blob(runner, report_path, evidence_commit)
        )
    except json.JSONDecodeError as error:
        raise ValueError("canonical report evidence is not JSON") from error
    report = VettingReport.from_json(report_payload)
    expected = ImageReference.parse(
        f"{IMAGE_REPOSITORY}:{report.candidate_tag}@{digest}"
    )
    current = now or datetime.now(UTC)
    if current.tzinfo is None:
        raise ValueError("promotion clock must be timezone-aware")
    current = current.astimezone(UTC)
    policy_date = current.date()
    validate_report(report, expected, version, today=policy_date)
    validate_report_freshness(report, now=current)
    current_dispositions = load_dispositions(
        root / "images/sandbox/vulnerability-dispositions.json", policy_date
    )
    if report.dispositions != current_dispositions:
        raise ValueError("canonical report dispositions do not match trusted main")
    return PromotionEvidence(evidence_commit, number, expected, version, report)


def trusted_promotion_plan(
    root: Path,
    evidence_commit: str,
    digest: str,
    version: str,
    runner: Runner,
    *,
    now: datetime | None = None,
) -> PromotionPlan:
    current = now or datetime.now(UTC)
    if current.tzinfo is None:
        raise ValueError("promotion clock must be timezone-aware")
    current = current.astimezone(UTC)
    raw_app_id = os.environ.get("SANDBOX_PROMOTION_APP_ID", "")
    if not raw_app_id.isdecimal() or int(raw_app_id) <= 0:
        raise ValueError("SANDBOX_PROMOTION_APP_ID must be a positive integer")
    app_id = int(raw_app_id)
    production_environment_fingerprint = verify_production_environment(
        runner, expected_app_id=app_id
    )
    status_environment_fingerprint = verify_promotion_status_environment(
        root, runner, app_id
    )
    verify_package_writer_environment(runner)
    verify_required_promotion_status(runner, app_id)
    verify_required_merge_signal(runner)
    evidence = verify_promotion_evidence(
        root, evidence_commit, digest, version, runner, now=current
    )
    candidate = resolve_tag(
        f"{IMAGE_REPOSITORY}:{evidence.report.candidate_tag}", runner
    )
    if candidate.digest != digest:
        raise ValueError("candidate tag no longer resolves to the evidence digest")
    verify_candidate_identity(
        candidate, evidence.report.source_commit, evidence.report.image_version, runner
    )
    verify_candidate_attestations(
        candidate,
        evidence.report.source_commit,
        image_inputs_digest(root),
        runner,
    )
    verify_current_candidate_policy(root, candidate, runner)
    production_tag = f"{IMAGE_REPOSITORY}:v{version}"
    current_evidence = verify_promotion_evidence(
        root, evidence_commit, digest, version, runner, now=current
    )
    if current_evidence != evidence:
        raise ValueError("promotion evidence changed during security checks")
    action = assert_tag_available(production_tag, digest, runner)
    return PromotionPlan(
        candidate,
        production_tag,
        action,
        promotion_deadline(evidence.report, now=current),
        production_environment_fingerprint,
        status_environment_fingerprint,
    )


def prepare_candidate(
    root: Path,
    inputs: ImageInputs,
    runner: Runner,
    *,
    today: date | None = None,
) -> CandidatePlan:
    tag = f"{IMAGE_REPOSITORY}:candidate-{inputs.source_revision}"
    distribution = root / ".dist/sandbox-image"
    distribution.mkdir(parents=True, exist_ok=True)
    policy_date = today or datetime.now(UTC).date()
    dispositions = load_dispositions(
        root / "images/sandbox/vulnerability-dispositions.json", policy_date
    )
    built = build_local_image(root, inputs, runner, output="docker", tag=tag)
    verify_image_contract(built, runner)
    preflight = scan_image(root, built.archive, runner)
    if not evaluate_findings(
        preflight.findings, dispositions, policy_date
    ).accepted:
        raise ValueError("candidate vulnerability policy did not pass")
    local_content = image_content_digest(built.local_tag, runner)
    provenance = {
        "buildType": "https://mobyproject.org/buildkit@v1",
        "builder": {"id": "https://github.com/kenn-io/ghosthub/actions"},
        "invocation": {
            "configSource": {
                "uri": "https://github.com/kenn-io/ghosthub",
                "digest": {"sha1": inputs.source_revision},
                "entryPoint": "images/sandbox/Dockerfile",
            },
            "parameters": {
                "platform": "linux/arm64",
                "base_digest": inputs.base_digest,
                "apt_snapshot": inputs.apt_snapshot,
                "image_version": inputs.image_version,
                "image_inputs_digest": image_inputs_digest(root),
            },
        },
        "materials": [
            {
                "uri": "pkg:docker/ubuntu",
                "digest": {"sha256": inputs.base_digest.removeprefix("sha256:")},
            }
        ],
    }
    (distribution / "candidate-provenance.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    archive = built.archive.relative_to(root)
    return CandidatePlan(tag, local_content, archive, inputs.image_version)


def verify_candidate_identity(
    image: ImageReference,
    source: str,
    version: str,
    runner: Runner,
) -> None:
    if image.tag != f"candidate-{source}":
        raise ValueError("candidate tag does not match source commit")
    result = runner.run(
        (
            "docker",
            "buildx",
            "imagetools",
            "inspect",
            image.canonical,
            "--format",
            "{{json .Image}}",
        )
    )
    try:
        payload = json.loads(result.stdout)
        if set(payload) not in ({"linux/arm64"}, {"linux/arm64/v8"}):
            raise ValueError("candidate image must contain only linux/arm64")
        config = next(iter(payload.values()))["config"]
        labels = config["Labels"]
    except (json.JSONDecodeError, KeyError, StopIteration, TypeError) as error:
        raise ValueError("candidate image metadata is invalid") from error
    expected = {
        "org.opencontainers.image.url": "https://github.com/kenn-io/ghosthub",
        "org.opencontainers.image.revision": source,
        "org.opencontainers.image.version": version,
    }
    if not isinstance(labels, dict) or any(
        labels.get(key) != value for key, value in expected.items()
    ):
        raise ValueError("candidate image labels do not match source identity")
