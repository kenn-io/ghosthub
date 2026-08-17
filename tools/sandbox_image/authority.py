from __future__ import annotations

import base64
import copy
import json
import os
import tempfile
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .github import (
    list_ruleset_summaries,
    verify_package_writer_environment,
    verify_production_environment,
    verify_promotion_status_environment,
    verify_required_merge_signal,
    verify_required_promotion_status,
)
from .process import AuthenticatedRunner, Runner, SecretRunner

ENVIRONMENT = "sandbox-image-promotion-status"
PRODUCTION_ENVIRONMENT = "sandbox-image-production"
CANONICAL_REPOSITORY = "kenn-io/ghosthub"
APP_ID_VARIABLE = "SANDBOX_PROMOTION_APP_ID"
CLIENT_ID_VARIABLE = "SANDBOX_PROMOTION_APP_CLIENT_ID"
PRIVATE_KEY_SECRET = "SANDBOX_PROMOTION_APP_PRIVATE_KEY"
RULESET_NAME = "Sandbox image promotion authority"
APP_OWNER = "kenn-io"
APP_SLUG = "ghosthub-sandbox-promotion"
APP_PERMISSIONS = {
    "actions": "read",
    "administration": "read",
    "attestations": "read",
    "contents": "read",
    "environments": "read",
    "metadata": "read",
    "pull_requests": "read",
    "statuses": "write",
}


def _api_json(runner: Runner, endpoint: str) -> object:
    try:
        return json.loads(runner.run(("gh", "api", endpoint)).stdout)
    except json.JSONDecodeError as error:
        raise ValueError("GitHub API returned invalid JSON") from error


def _app_id(value: str) -> int:
    if not value.isdecimal() or int(value) <= 0:
        raise ValueError("promotion app ID must be a positive integer")
    return int(value)


def _require_canonical_repository(root: Path, runner: Runner) -> None:
    remote = runner.run(
        ("git", "-C", str(root), "remote", "get-url", "origin")
    ).stdout.strip()
    canonical_urls = {
        "https://github.com/kenn-io/ghosthub",
        "https://github.com/kenn-io/ghosthub.git",
        "git@github.com:kenn-io/ghosthub",
        "git@github.com:kenn-io/ghosthub.git",
        "ssh://git@github.com/kenn-io/ghosthub",
        "ssh://git@github.com/kenn-io/ghosthub.git",
    }
    if remote not in canonical_urls:
        raise ValueError(
            "promotion authority mutations require a canonical repository checkout"
        )


def _encoded_json(value: dict[str, object]) -> str:
    raw = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _token_api_json(
    runner: AuthenticatedRunner,
    token: str,
    argv: tuple[str, ...],
    *,
    input_text: str | None = None,
) -> object:
    try:
        return json.loads(
            runner.run_with_token(
                argv,
                token,
                input_text=input_text,
            ).stdout
        )
    except json.JSONDecodeError as error:
        raise ValueError("GitHub App API returned invalid JSON") from error


def _bearer_api_json(
    runner: AuthenticatedRunner,
    token: str,
    path: str,
    *,
    method: str = "GET",
    input_text: str | None = None,
) -> object:
    argv = [
        "curl",
        "--disable",
        "--silent",
        "--show-error",
        "--fail-with-body",
        "--config",
        "-",
        "--header",
        "Accept: application/vnd.github+json",
        "--header",
        "X-GitHub-Api-Version: 2022-11-28",
    ]
    if method != "GET":
        argv.extend(("--request", method))
    if input_text is not None:
        argv.extend(
            ("--header", "Content-Type: application/json", "--data", input_text)
        )
    argv.append("https://api.github.com" + path)
    try:
        return json.loads(runner.run_with_bearer(tuple(argv), token).stdout)
    except json.JSONDecodeError as error:
        raise ValueError("GitHub App API returned invalid JSON") from error


def verify_promotion_app_key(
    private_key: str,
    app_id: int,
    client_id: str,
    runner: AuthenticatedRunner,
) -> None:
    issued_at = datetime.now(UTC) - timedelta(seconds=60)
    header = _encoded_json({"alg": "RS256", "typ": "JWT"})
    payload = _encoded_json(
        {
            "iat": int(issued_at.timestamp()),
            "exp": int((issued_at + timedelta(minutes=9)).timestamp()),
            "iss": client_id,
        }
    )
    unsigned = f"{header}.{payload}"
    with tempfile.TemporaryDirectory(prefix="ghosthub-promotion-app-") as temporary:
        directory = Path(temporary)
        key_path = directory / "key.pem"
        signature_path = directory / "signature"
        descriptor = os.open(
            key_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as key_file:
            key_file.write(private_key)
        runner.run_secret(
            (
                "openssl",
                "dgst",
                "-sha256",
                "-sign",
                str(key_path),
                "-out",
                str(signature_path),
            ),
            unsigned,
        )
        signature = base64.urlsafe_b64encode(signature_path.read_bytes()).rstrip(b"=")
    app_jwt = unsigned + "." + signature.decode()

    app = _bearer_api_json(runner, app_jwt, "/app")
    owner = app.get("owner") if isinstance(app, dict) else None
    if not isinstance(app, dict) or any(
        (
            app.get("id") != app_id,
            app.get("slug") != APP_SLUG,
            app.get("client_id") != client_id,
            app.get("installations_count") != 1,
            not isinstance(owner, dict),
            isinstance(owner, dict) and owner.get("login") != APP_OWNER,
            isinstance(owner, dict) and owner.get("type") != "Organization",
            app.get("permissions") != APP_PERMISSIONS,
        )
    ):
        raise ValueError("promotion app key or permissions do not match authority")

    installations = _bearer_api_json(
        runner,
        app_jwt,
        "/app/installations?per_page=100",
    )
    if not isinstance(installations, list):
        raise ValueError("promotion app installation list is invalid")
    installation = installations[0] if len(installations) == 1 else None
    account = installation.get("account") if isinstance(installation, dict) else None
    if (
        len(installations) != 1
        or not isinstance(installation, dict)
        or not isinstance(installation.get("id"), int)
        or installation.get("app_id") != app_id
        or installation.get("app_slug") != APP_SLUG
        or not isinstance(account, dict)
        or account.get("login") != APP_OWNER
        or account.get("type") != "Organization"
        or installation.get("repository_selection") != "selected"
        or installation.get("permissions") != APP_PERMISSIONS
    ):
        raise ValueError("promotion app installation authority drifted")
    installation_id = installation["id"]
    token_payload = json.dumps(
        {"permissions": {"statuses": "write"}}, separators=(",", ":")
    )
    token_response = _bearer_api_json(
        runner,
        app_jwt,
        f"/app/installations/{installation_id}/access_tokens",
        method="POST",
        input_text=token_payload,
    )
    if not isinstance(token_response, dict) or not isinstance(
        token_response.get("token"), str
    ):
        raise ValueError("promotion app did not mint an installation token")
    installation_token = token_response["token"]
    try:
        repository_pages = _token_api_json(
            runner,
            installation_token,
            (
                "gh",
                "api",
                "--paginate",
                "--slurp",
                "/installation/repositories?per_page=100",
            ),
        )
        if not isinstance(repository_pages, list) or not repository_pages:
            raise ValueError("promotion app repository scope is invalid")
        repositories: list[object] = []
        for page in repository_pages:
            if not isinstance(page, dict) or not isinstance(
                page.get("repositories"), list
            ):
                raise ValueError("promotion app repository scope is invalid")
            repositories.extend(page["repositories"])
        repository_names = [
            repository.get("full_name")
            for repository in repositories
            if isinstance(repository, dict)
        ]
        if repository_pages[0].get("total_count") != 1 or repository_names != [
            CANONICAL_REPOSITORY
        ]:
            raise ValueError("promotion app must be installed only on Ghosthub")
    finally:
        runner.run_with_token(
            ("gh", "api", "--method", "DELETE", "/installation/token"),
            installation_token,
            check=False,
        )


def promotion_ruleset_payload(value: object, app_id: int) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("default branch ruleset is invalid")
    conditions = value.get("conditions")
    ref_name = conditions.get("ref_name") if isinstance(conditions, dict) else None
    rules = value.get("rules")
    if (
        value.get("target") != "branch"
        or value.get("enforcement") != "active"
        or value.get("bypass_actors") != []
        or not isinstance(ref_name, dict)
        or "~DEFAULT_BRANCH" not in ref_name.get("include", [])
        or ref_name.get("exclude") != []
        or not isinstance(rules, list)
        or not any(
            isinstance(rule, dict) and rule.get("type") == "pull_request"
            for rule in rules
        )
    ):
        raise ValueError("default branch pull request policy is not strict enough")

    pull_request = next(
        rule
        for rule in rules
        if isinstance(rule, dict) and rule.get("type") == "pull_request"
    )
    required = {
        "context": "sandbox-image-promotion",
        "integration_id": app_id,
    }
    return {
        "name": RULESET_NAME,
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {
            "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}
        },
        "rules": [
            copy.deepcopy(pull_request),
            {
                "type": "required_status_checks",
                "parameters": {
                    "strict_required_status_checks_policy": False,
                    "do_not_enforce_on_create": False,
                    "required_status_checks": [required],
                },
            },
        ],
    }


def configure_promotion_authority(
    root: Path,
    app_id: str,
    client_id: str,
    private_key_path: Path,
    runner: AuthenticatedRunner,
) -> None:
    numeric_id = _app_id(app_id)
    if not client_id or any(character.isspace() for character in client_id):
        raise ValueError("promotion app client ID is invalid")
    try:
        private_key = private_key_path.read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError("cannot read promotion app private key") from error
    lines = private_key.splitlines()
    if (
        len(lines) < 3
        or not lines[0].startswith("-----BEGIN ")
        or not lines[0].endswith(" PRIVATE KEY-----")
        or lines[-1] != lines[0].replace("BEGIN", "END", 1)
    ):
        raise ValueError("promotion app private key is not a PEM private key")
    _require_canonical_repository(root, runner)
    verify_promotion_app_key(private_key, numeric_id, client_id, runner)
    verify_production_environment(runner, require_credentials=False)

    endpoint = f"repos/kenn-io/ghosthub/environments/{ENVIRONMENT}"
    environment = {
        "wait_timer": 0,
        "prevent_self_review": False,
        "reviewers": [],
        "deployment_branch_policy": {
            "protected_branches": False,
            "custom_branch_policies": True,
        },
    }
    runner.run_secret(
        ("gh", "api", "--method", "PUT", endpoint, "--input", "-"),
        json.dumps(environment),
    )
    policies = _api_json(runner, endpoint + "/deployment-branch-policies")
    if not isinstance(policies, dict) or not isinstance(
        policies.get("branch_policies"), list
    ):
        raise ValueError("promotion environment branch policies are invalid")
    for policy in policies["branch_policies"]:
        if not isinstance(policy, dict) or not isinstance(policy.get("id"), int):
            raise ValueError("promotion environment branch policy is invalid")
        runner.run(
            (
                "gh",
                "api",
                "--method",
                "DELETE",
                endpoint + f"/deployment-branch-policies/{policy['id']}",
            )
        )
    runner.run(
        (
            "gh",
            "api",
            "--method",
            "POST",
            endpoint + "/deployment-branch-policies",
            "-f",
            "name=main",
            "-f",
            "type=branch",
        )
    )
    for environment_name in (ENVIRONMENT, PRODUCTION_ENVIRONMENT):
        for name, value in (
            (APP_ID_VARIABLE, str(numeric_id)),
            (CLIENT_ID_VARIABLE, client_id),
        ):
            runner.run(
                (
                    "gh",
                    "variable",
                    "set",
                    name,
                    "--env",
                    environment_name,
                    "--body",
                    value,
                    "--repo",
                    CANONICAL_REPOSITORY,
                )
            )
        runner.run_secret(
            (
                "gh",
                "secret",
                "set",
                PRIVATE_KEY_SECRET,
                "--env",
                environment_name,
                "--repo",
                CANONICAL_REPOSITORY,
            ),
            private_key,
        )
    verify_promotion_status_environment(root, runner, numeric_id)
    verify_production_environment(runner, expected_app_id=numeric_id)
    runner.run(
        (
            "gh",
            "variable",
            "set",
            APP_ID_VARIABLE,
            "--body",
            str(numeric_id),
            "--repo",
            CANONICAL_REPOSITORY,
        )
    )


def enable_promotion_authority(root: Path, runner: SecretRunner) -> int:
    _require_canonical_repository(root, runner)
    app_id = _app_id(
        runner.run(
            (
                "gh",
                "variable",
                "get",
                APP_ID_VARIABLE,
                "--repo",
                CANONICAL_REPOSITORY,
            )
        ).stdout.strip()
    )
    summaries = list_ruleset_summaries(runner)
    candidates: list[dict[str, object]] = []
    managed_ids: list[int] = []
    for summary in summaries:
        if not isinstance(summary, dict) or not isinstance(summary.get("id"), int):
            raise ValueError("repository ruleset configuration is invalid")
        if (
            summary.get("source_type") == "Repository"
            and summary.get("name") == RULESET_NAME
        ):
            managed_ids.append(summary["id"])
            continue
        detail = _api_json(runner, f"repos/kenn-io/ghosthub/rulesets/{summary['id']}")
        try:
            payload = promotion_ruleset_payload(detail, app_id)
        except ValueError:
            continue
        candidates.append(payload)
    if len(candidates) != 1:
        raise ValueError("expected exactly one default branch pull request ruleset")
    if len(managed_ids) > 1:
        raise ValueError("expected at most one managed promotion ruleset")
    payload = candidates[0]
    method = "POST" if not managed_ids else "PUT"
    endpoint = "repos/kenn-io/ghosthub/rulesets"
    if managed_ids:
        endpoint += f"/{managed_ids[0]}"
    runner.run_secret(
        (
            "gh",
            "api",
            "--method",
            method,
            endpoint,
            "--input",
            "-",
        ),
        json.dumps(payload),
    )
    audit_promotion_authority(root, runner, app_id)
    return app_id


def audit_promotion_authority(
    root: Path,
    runner: Runner,
    app_id: int | None = None,
    *,
    workflow_root: Path | None = None,
) -> int:
    expected = app_id or _app_id(
        runner.run(
            (
                "gh",
                "variable",
                "get",
                APP_ID_VARIABLE,
                "--repo",
                CANONICAL_REPOSITORY,
            )
        ).stdout.strip()
    )
    verify_promotion_status_environment(
        root,
        runner,
        expected,
        workflow_root=workflow_root,
    )
    verify_package_writer_environment(runner)
    verify_production_environment(runner, expected_app_id=expected)
    verify_required_promotion_status(runner, expected)
    verify_required_merge_signal(runner)
    return expected


def promotion_authority_status(root: Path, runner: Runner) -> str:
    result = runner.run(
        (
            "gh",
            "variable",
            "get",
            APP_ID_VARIABLE,
            "--repo",
            CANONICAL_REPOSITORY,
        ),
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return "pending setup"
    try:
        audit_promotion_authority(root, runner, _app_id(result.stdout.strip()))
    except ValueError:
        return "invalid"
    return "valid"
