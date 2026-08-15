from __future__ import annotations

import os
import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True)
class CompletedCommand:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str


class CommandError(RuntimeError):
    def __init__(self, command: CompletedCommand) -> None:
        self.command = command
        self.stdout = command.stdout
        self.stderr = command.stderr
        rendered = " ".join(command.argv)
        detail = command.stderr or command.stdout or "no diagnostic output"
        super().__init__(
            f"command failed with exit {command.returncode}: {rendered}\n{detail}"
        )


class Runner(Protocol):
    def run(
        self,
        argv: Sequence[str],
        *,
        check: bool = True,
        capture: bool = True,
    ) -> CompletedCommand: ...


class SecretRunner(Runner, Protocol):
    def run_secret(
        self, argv: Sequence[str], input_text: str
    ) -> CompletedCommand: ...


class AuthenticatedRunner(SecretRunner, Protocol):
    def run_with_bearer(
        self,
        argv: Sequence[str],
        token: str,
        *,
        check: bool = True,
    ) -> CompletedCommand: ...

    def run_with_token(
        self,
        argv: Sequence[str],
        token: str,
        *,
        input_text: str | None = None,
        check: bool = True,
    ) -> CompletedCommand: ...


class CommandRunner:
    def __init__(
        self,
        *,
        secrets: Sequence[str] = (),
        redacted_prefixes: Sequence[Path] = (),
        output_limit: int = 16_000,
    ) -> None:
        self._secrets = tuple(value for value in secrets if value)
        self._redacted_prefixes = tuple(
            str(path.resolve()) for path in redacted_prefixes
        )
        self._output_limit = output_limit

    def run(
        self,
        argv: Sequence[str],
        *,
        check: bool = True,
        capture: bool = True,
        input_text: str | None = None,
    ) -> CompletedCommand:
        return self._run(
            argv,
            check=check,
            capture=capture,
            input_text=input_text,
            environment=os.environ.copy(),
        )

    def run_with_token(
        self,
        argv: Sequence[str],
        token: str,
        *,
        input_text: str | None = None,
        check: bool = True,
    ) -> CompletedCommand:
        environment = os.environ.copy()
        environment["GH_TOKEN"] = token
        environment["GH_HOST"] = "github.com"
        environment.pop("GITHUB_TOKEN", None)
        return self._run(
            argv,
            check=check,
            capture=True,
            input_text=input_text,
            environment=environment,
        )

    def run_with_bearer(
        self,
        argv: Sequence[str],
        token: str,
        *,
        check: bool = True,
    ) -> CompletedCommand:
        if not token or any(character in token for character in ('"', "\r", "\n")):
            raise ValueError("bearer token contains unsupported characters")
        return self._run(
            argv,
            check=check,
            capture=True,
            input_text=f'header = "Authorization: Bearer {token}"\n',
            environment=os.environ.copy(),
            transient_secrets=(token,),
        )

    def _run(
        self,
        argv: Sequence[str],
        *,
        check: bool,
        capture: bool,
        input_text: str | None,
        environment: dict[str, str],
        transient_secrets: Sequence[str] = (),
    ) -> CompletedCommand:
        if isinstance(argv, (str, bytes)):
            raise TypeError("commands must be passed as argument arrays")
        raw = subprocess.run(
            list(argv),
            text=True,
            capture_output=capture,
            check=False,
            env=environment,
            input=input_text,
        )
        command = CompletedCommand(
            argv=tuple(argv),
            returncode=raw.returncode,
            stdout=raw.stdout or "",
            stderr=raw.stderr or "",
        )
        if check and command.returncode != 0:
            raise CommandError(
                CompletedCommand(
                    argv=tuple(
                        self._redact(value, transient_secrets) for value in argv
                    ),
                    returncode=command.returncode,
                    stdout=self._bounded_redacted(
                        command.stdout, transient_secrets
                    ),
                    stderr=self._bounded_redacted(
                        command.stderr, transient_secrets
                    ),
                )
            )
        return command

    def run_secret(
        self, argv: Sequence[str], input_text: str
    ) -> CompletedCommand:
        return self._run(
            argv,
            check=True,
            capture=True,
            input_text=input_text,
            environment=os.environ.copy(),
            transient_secrets=(input_text,),
        )

    def _bounded_redacted(
        self, value: str, transient_secrets: Sequence[str] = ()
    ) -> str:
        redacted = self._redact(value, transient_secrets)
        return redacted[-self._output_limit :]

    def _redact(
        self, value: str, transient_secrets: Sequence[str] = ()
    ) -> str:
        result = value
        for secret in (*self._secrets, *transient_secrets):
            result = result.replace(secret, "<redacted>")
        for prefix in self._redacted_prefixes:
            result = result.replace(prefix, "<redacted>")
        home = str(Path.home())
        return result.replace(home, "<redacted>")
