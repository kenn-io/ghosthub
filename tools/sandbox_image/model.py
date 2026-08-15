from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date
from typing import Literal

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
    def parse(cls, value: str) -> ImageReference:
        match = REFERENCE.fullmatch(value)
        if match is None:
            raise ValueError(f"invalid Ghosthub sandbox image reference: {value}")
        return cls(
            repository=match.group("repository"),
            digest=match.group("digest"),
            tag=match.group("tag"),
        )

    @classmethod
    def parse_runtime_pin(cls, value: str) -> ImageReference:
        reference = cls.parse(value)
        if reference.tag is not None:
            raise ValueError("SANDBOX_IMAGE must be tag-free")
        return reference

    @property
    def runtime_pin(self) -> str:
        return f"{self.repository}@{self.digest}"

    @property
    def canonical(self) -> str:
        tag = f":{self.tag}" if self.tag else ""
        return f"{self.repository}{tag}@{self.digest}"


@dataclass(frozen=True)
class Disposition:
    vulnerability_id: str
    package: str
    result_class: str
    result_type: str
    target: str
    rationale: str
    owner: str
    expires: date


@dataclass(frozen=True)
class Finding:
    vulnerability_id: str
    package: str
    result_class: str
    result_type: str
    target: str
    severity: str
    fixed_version: str | None


@dataclass(frozen=True)
class CheckResult:
    name: str
    status: Literal["pass", "fail"]
    detail: str
