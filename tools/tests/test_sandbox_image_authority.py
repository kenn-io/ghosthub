import json
from collections.abc import Sequence
from pathlib import Path

import pytest
from sandbox_image import authority
from sandbox_image.authority import promotion_ruleset_payload
from sandbox_image.process import CompletedCommand


class VariableRunner:
    def __init__(self, value: str, returncode: int = 0) -> None:
        self.value = value
        self.returncode = returncode
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
        return CompletedCommand(call, self.returncode, self.value, "")


class ForkRunner:
    def __init__(self, root: Path) -> None:
        self.root = str(root)
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
        if call == ("git", "-C", self.root, "remote", "get-url", "origin"):
            return CompletedCommand(
                call, 0, "https://github.com/someone/ghosthub.git\n", ""
            )
        raise AssertionError(f"mutation attempted from fork context: {call}")

    def run_secret(
        self, argv: Sequence[str], input_text: str
    ) -> CompletedCommand:
        del input_text
        raise AssertionError(f"mutation attempted from fork context: {tuple(argv)}")

    def run_with_bearer(
        self,
        argv: Sequence[str],
        token: str,
        *,
        check: bool = True,
    ) -> CompletedCommand:
        del token, check
        raise AssertionError(f"mutation attempted from fork context: {tuple(argv)}")

    def run_with_token(
        self,
        argv: Sequence[str],
        token: str,
        *,
        input_text: str | None = None,
        check: bool = True,
    ) -> CompletedCommand:
        del token, input_text, check
        raise AssertionError(f"mutation attempted from fork context: {tuple(argv)}")


class AppValidationRunner:
    def __init__(
        self,
        *,
        app_id: int = 424242,
        app_slug: str = "ghosthub-sandbox-promotion",
        owner_login: str = "kenn-io",
    ) -> None:
        self.app_id = app_id
        self.app_slug = app_slug
        self.owner_login = owner_login
        self.calls: list[tuple[str, ...]] = []
        self.authenticated_calls: list[tuple[tuple[str, ...], str | None, bool]] = []

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
        if len(call) == 6 and call[:2] == ("git", "-C") and call[3:] == (
            "remote",
            "get-url",
            "origin",
        ):
            return CompletedCommand(
                call, 0, "git@github.com:kenn-io/ghosthub.git\n", ""
            )
        if call[:4] == ("openssl", "dgst", "-sha256", "-sign"):
            output = Path(call[call.index("-out") + 1])
            output.write_bytes(b"signature")
            return CompletedCommand(call, 0, "", "")
        raise AssertionError(f"unexpected command: {call}")

    def run_secret(
        self, argv: Sequence[str], input_text: str
    ) -> CompletedCommand:
        del input_text
        return self.run(argv)

    def run_with_token(
        self,
        argv: Sequence[str],
        token: str,
        *,
        input_text: str | None = None,
        check: bool = True,
    ) -> CompletedCommand:
        call = tuple(argv)
        assert token == "installation-token"
        self.authenticated_calls.append((call, input_text, check))
        if call == ("gh", "api", "/installation"):
            payload = {
                "app_id": 424242,
                "app_slug": self.app_slug,
                "account": {
                    "login": self.owner_login,
                    "type": "Organization",
                },
                "repository_selection": "selected",
                "permissions": {
                    "actions": "read",
                    "administration": "read",
                    "attestations": "read",
                    "contents": "read",
                    "environments": "read",
                    "metadata": "read",
                    "pull_requests": "read",
                    "statuses": "write",
                },
            }
        elif call == (
            "gh",
            "api",
            "--paginate",
            "--slurp",
            "/installation/repositories?per_page=100",
        ):
            payload = [
                {
                    "total_count": 1,
                    "repositories": [
                        {
                            "full_name": "kenn-io/ghosthub",
                            "private": False,
                        }
                    ],
                }
            ]
        elif call == ("gh", "api", "--method", "DELETE", "/installation/token"):
            return CompletedCommand(call, 0, "", "")
        else:
            raise AssertionError(f"unexpected authenticated command: {call}")
        return CompletedCommand(call, 0, json.dumps(payload), "")

    def run_with_bearer(
        self,
        argv: Sequence[str],
        token: str,
        *,
        check: bool = True,
    ) -> CompletedCommand:
        call = tuple(argv)
        assert token.count(".") == 2
        self.authenticated_calls.append((call, None, check))
        url = call[-1]
        if url == "https://api.github.com/app":
            payload: object = {
                "id": self.app_id,
                "slug": self.app_slug,
                "client_id": "Iv1.example",
                "installations_count": 1,
                "owner": {
                    "login": self.owner_login,
                    "type": "Organization",
                },
                "permissions": {
                    "actions": "read",
                    "administration": "read",
                    "attestations": "read",
                    "contents": "read",
                    "environments": "read",
                    "metadata": "read",
                    "pull_requests": "read",
                    "statuses": "write",
                },
            }
        elif url == "https://api.github.com/app/installations?per_page=100":
            payload = [
                {
                    "id": 77,
                    "account": {
                        "login": "kenn-io",
                        "type": "Organization",
                    },
                    "repository_selection": "selected",
                }
            ]
        elif url == "https://api.github.com/app/installations/77/access_tokens":
            body = call[call.index("--data") + 1]
            assert body == json.dumps(
                {"permissions": {"statuses": "write"}}, separators=(",", ":")
            )
            payload = {"token": "installation-token"}
        else:
            raise AssertionError(f"unexpected bearer command: {call}")
        return CompletedCommand(call, 0, json.dumps(payload), "")


def test_promotion_ruleset_is_narrow_and_pins_app() -> None:
    ruleset = {
        "name": "Default branch pull request policy",
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {
            "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}
        },
        "rules": [
            {"type": "pull_request", "parameters": {"required_approvals": 0}},
            {
                "type": "required_status_checks",
                "parameters": {
                    "strict_required_status_checks_policy": False,
                    "do_not_enforce_on_create": False,
                    "required_status_checks": [
                        {"context": "another-check", "integration_id": 9},
                        {"context": "sandbox-image-promotion"},
                    ],
                },
            },
        ],
    }

    payload = promotion_ruleset_payload(ruleset, 424242)

    rules = payload["rules"]
    assert isinstance(rules, list)
    assert payload["name"] == "Sandbox image promotion authority"
    assert rules[0] == ruleset["rules"][0]
    required_rule = rules[1]
    assert isinstance(required_rule, dict)
    required = required_rule["parameters"]
    assert isinstance(required, dict)
    assert required["strict_required_status_checks_policy"] is True
    assert required["required_status_checks"] == [
        {
            "context": "sandbox-image-promotion",
            "integration_id": 424242,
        }
    ]
    assert rules[2] == {
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


@pytest.mark.parametrize("existing_id", [None, 99])
def test_promotion_authority_owns_a_repository_ruleset(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    existing_id: int | None,
) -> None:
    base = {
        "name": "Default branch pull request policy",
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {
            "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}
        },
        "rules": [{"type": "pull_request", "parameters": {}}],
    }

    class Runner:
        def __init__(self) -> None:
            self.mutations: list[tuple[tuple[str, ...], str]] = []

        def run(
            self,
            argv: Sequence[str],
            *,
            check: bool = True,
            capture: bool = True,
        ) -> CompletedCommand:
            del check, capture
            call = tuple(argv)
            if call == (
                "git",
                "-C",
                str(tmp_path),
                "remote",
                "get-url",
                "origin",
            ):
                output = "https://github.com/kenn-io/ghosthub.git\n"
            elif call[:4] == ("gh", "variable", "get", authority.APP_ID_VARIABLE):
                output = "424242\n"
            elif call == (
                "gh",
                "api",
                "--paginate",
                "--slurp",
                "repos/kenn-io/ghosthub/rulesets?per_page=100",
            ):
                summaries: list[list[dict[str, object]]] = [[
                    {"id": 42, "name": "Default", "source_type": "Organization"}
                ]]
                if existing_id is not None:
                    summaries.append(
                        [{
                            "id": existing_id,
                            "name": authority.RULESET_NAME,
                            "source_type": "Repository",
                        }]
                    )
                output = json.dumps(summaries)
            elif call == ("gh", "api", "repos/kenn-io/ghosthub/rulesets/42"):
                output = json.dumps(base)
            elif existing_id is not None and call == (
                "gh",
                "api",
                f"repos/kenn-io/ghosthub/rulesets/{existing_id}",
            ):
                output = json.dumps({"name": authority.RULESET_NAME})
            else:
                raise AssertionError(f"unexpected command: {call}")
            return CompletedCommand(call, 0, output, "")

        def run_secret(
            self, argv: Sequence[str], input_text: str
        ) -> CompletedCommand:
            call = tuple(argv)
            self.mutations.append((call, input_text))
            return CompletedCommand(call, 0, "", "")

    monkeypatch.setattr(authority, "audit_promotion_authority", lambda *_args: 424242)
    runner = Runner()

    assert authority.enable_promotion_authority(tmp_path, runner) == 424242

    method = "POST" if existing_id is None else "PUT"
    endpoint = (
        "repos/kenn-io/ghosthub/rulesets"
        if existing_id is None
        else f"repos/kenn-io/ghosthub/rulesets/{existing_id}"
    )
    assert runner.mutations[0][0] == (
        "gh",
        "api",
        "--method",
        method,
        endpoint,
        "--input",
        "-",
    )


def test_promotion_authority_status_reports_pending_without_app() -> None:
    runner = VariableRunner("", returncode=1)

    assert authority.promotion_authority_status(Path("."), runner) == "pending setup"
    assert runner.calls == [
        (
            "gh",
            "variable",
            "get",
            authority.APP_ID_VARIABLE,
            "--repo",
            "kenn-io/ghosthub",
        )
    ]


def test_promotion_authority_configuration_refuses_fork_context_before_mutation(
    tmp_path: Path,
) -> None:
    key = tmp_path / "promotion.pem"
    key.write_text(
        "-----BEGIN " + "PRIVATE KEY-----\nvalue\n-----END " + "PRIVATE KEY-----\n",
        encoding="utf-8",
    )
    runner = ForkRunner(tmp_path)

    with pytest.raises(ValueError, match="canonical repository"):
        authority.configure_promotion_authority(
            tmp_path,
            "424242",
            "Iv1.example",
            key,
            runner,
        )

    assert runner.calls == [
        (
            "git",
            "-C",
            str(tmp_path),
            "remote",
            "get-url",
            "origin",
        )
    ]


def test_promotion_app_key_mints_and_audits_full_installation_token() -> None:
    runner = AppValidationRunner()

    authority.verify_promotion_app_key(
        "inert-test-key-material",
        424242,
        "Iv1.example",
        runner,
    )

    assert all(
        "installation-token" not in argument
        for call, _input_text, _check in runner.authenticated_calls
        for argument in call
    )
    bearer_calls = [
        call
        for call, input_text, _check in runner.authenticated_calls
        if input_text is None and call[0] == "curl"
    ]
    assert bearer_calls
    assert all(call[:2] == ("curl", "--disable") for call in bearer_calls)


@pytest.mark.parametrize(
    ("app_slug", "owner_login"),
    [
        ("lookalike-promotion", "kenn-io"),
        ("ghosthub-sandbox-promotion", "third-party"),
    ],
)
def test_promotion_app_key_rejects_wrong_app_identity(
    app_slug: str,
    owner_login: str,
) -> None:
    runner = AppValidationRunner(app_slug=app_slug, owner_login=owner_login)

    with pytest.raises(ValueError, match="key or permissions"):
        authority.verify_promotion_app_key(
            "inert-test-key-material",
            424242,
            "Iv1.example",
            runner,
        )


def test_promotion_authority_configuration_validates_key_before_mutation(
    tmp_path: Path,
) -> None:
    key = tmp_path / "promotion.pem"
    key.write_text(
        "-----BEGIN " + "PRIVATE KEY-----\nvalue\n-----END " + "PRIVATE KEY-----\n",
        encoding="utf-8",
    )
    runner = AppValidationRunner(app_id=7)

    with pytest.raises(ValueError, match="key or permissions"):
        authority.configure_promotion_authority(
            tmp_path,
            "424242",
            "Iv1.example",
            key,
            runner,
        )

    assert not [call for call in runner.calls if call[0] == "gh"]


def test_promotion_authority_configuration_checks_production_before_mutation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    key = tmp_path / "promotion.pem"
    key.write_text(
        "-----BEGIN " + "PRIVATE KEY-----\nvalue\n-----END " + "PRIVATE KEY-----\n",
        encoding="utf-8",
    )
    runner = AppValidationRunner()

    def reject_unprotected_production(
        _runner: object, **_kwargs: object
    ) -> None:
        raise ValueError("production environment requires a reviewer")

    monkeypatch.setattr(
        authority,
        "verify_production_environment",
        reject_unprotected_production,
        raising=False,
    )

    with pytest.raises(ValueError, match="requires a reviewer"):
        authority.configure_promotion_authority(
            tmp_path,
            "424242",
            "Iv1.example",
            key,
            runner,
        )

    assert not [call for call in runner.calls if call[0] == "gh"]


def test_promotion_authority_rotation_updates_both_credential_environments(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    key = tmp_path / "promotion.pem"
    private_key = (
        "-----BEGIN " + "PRIVATE KEY-----\nvalue\n-----END " + "PRIVATE KEY-----\n"
    )
    key.write_text(private_key, encoding="utf-8")

    class Runner:
        def __init__(self) -> None:
            self.calls: list[tuple[str, ...]] = []
            self.secret_calls: list[tuple[tuple[str, ...], str]] = []

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
            if call == (
                "git",
                "-C",
                str(tmp_path),
                "remote",
                "get-url",
                "origin",
            ):
                output = "https://github.com/kenn-io/ghosthub.git\n"
            elif call == (
                "gh",
                "api",
                "repos/kenn-io/ghosthub/environments/"
                "sandbox-image-promotion-status/deployment-branch-policies",
            ):
                output = json.dumps({"branch_policies": []})
            else:
                output = ""
            return CompletedCommand(call, 0, output, "")

        def run_secret(
            self, argv: Sequence[str], input_text: str
        ) -> CompletedCommand:
            call = tuple(argv)
            self.secret_calls.append((call, input_text))
            return CompletedCommand(call, 0, "", "")

        def run_with_bearer(
            self,
            argv: Sequence[str],
            token: str,
            *,
            check: bool = True,
        ) -> CompletedCommand:
            del token, check
            raise AssertionError(f"unexpected bearer command: {tuple(argv)}")

        def run_with_token(
            self,
            argv: Sequence[str],
            token: str,
            *,
            input_text: str | None = None,
            check: bool = True,
        ) -> CompletedCommand:
            del token, input_text, check
            raise AssertionError(f"unexpected token command: {tuple(argv)}")

    monkeypatch.setattr(authority, "verify_promotion_app_key", lambda *_args: None)
    monkeypatch.setattr(
        authority,
        "verify_production_environment",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        authority, "verify_promotion_status_environment", lambda *_args: None
    )
    runner = Runner()

    authority.configure_promotion_authority(
        tmp_path,
        "424242",
        "Iv1.example",
        key,
        runner,
    )

    for environment in (
        "sandbox-image-promotion-status",
        "sandbox-image-production",
    ):
        assert (
            "gh",
            "variable",
            "set",
            authority.APP_ID_VARIABLE,
            "--env",
            environment,
            "--body",
            "424242",
            "--repo",
            "kenn-io/ghosthub",
        ) in runner.calls
        assert (
            "gh",
            "variable",
            "set",
            authority.CLIENT_ID_VARIABLE,
            "--env",
            environment,
            "--body",
            "Iv1.example",
            "--repo",
            "kenn-io/ghosthub",
        ) in runner.calls
        assert (
            (
                "gh",
                "secret",
                "set",
                authority.PRIVATE_KEY_SECRET,
                "--env",
                environment,
                "--repo",
                "kenn-io/ghosthub",
            ),
            private_key,
        ) in runner.secret_calls


def test_promotion_authority_status_reports_drift(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fail_audit(*_args: object) -> int:
        raise ValueError("drift")

    monkeypatch.setattr(authority, "audit_promotion_authority", fail_audit)

    assert authority.promotion_authority_status(
        Path("."), VariableRunner("424242\n")
    ) == "invalid"


@pytest.mark.parametrize(
    "mutation",
    [
        {"bypass_actors": [{"actor_id": 1}]},
        {
            "conditions": {
                "ref_name": {
                    "include": ["~DEFAULT_BRANCH"],
                    "exclude": ["refs/heads/main"],
                }
            }
        },
    ],
)
def test_promotion_ruleset_refuses_weak_base_policy(
    mutation: dict[str, object],
) -> None:
    ruleset = {
        "name": "Default branch pull request policy",
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {
            "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}
        },
        "rules": [{"type": "pull_request", "parameters": {}}],
    }
    ruleset.update(mutation)

    with pytest.raises(ValueError, match="default branch"):
        promotion_ruleset_payload(ruleset, 424242)
