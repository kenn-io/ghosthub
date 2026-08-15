from __future__ import annotations

import json
import re
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from .model import IMAGE_REPOSITORY, ImageReference
from .process import CommandError, Runner


@dataclass(frozen=True)
class ImageInputs:
    base_digest: str
    apt_snapshot: str
    source_revision: str
    image_version: str


@dataclass(frozen=True)
class BuiltImage:
    platform: str
    archive: Path
    local_tag: str


def build_local_image(
    root: Path,
    inputs: ImageInputs,
    runner: Runner,
    *,
    output: Literal["docker", "oci"] = "oci",
    tag: str | None = None,
    no_cache: bool = False,
) -> BuiltImage:
    runner.run(("docker", "buildx", "version"))
    distribution = root / ".dist" / "sandbox-image"
    distribution.mkdir(parents=True, exist_ok=True)
    archive = distribution / f"sandbox-image.{output}.tar"
    archive.unlink(missing_ok=True)
    local_tag = tag or (
        f"ghosthub-sandbox:check-{inputs.source_revision[:12]}-{secrets.token_hex(3)}"
    )
    argv = [
        "docker",
        "buildx",
        "build",
        "--platform",
        "linux/arm64",
        "--build-arg",
        f"UBUNTU_BASE={inputs.base_digest}",
        "--build-arg",
        f"APT_SNAPSHOT={inputs.apt_snapshot}",
        "--build-arg",
        f"SOURCE_DATE_EPOCH={_source_date_epoch(inputs.apt_snapshot)}",
        "--build-arg",
        f"SOURCE_REVISION={inputs.source_revision}",
        "--build-arg",
        f"IMAGE_VERSION={inputs.image_version}",
        "--tag",
        local_tag,
    ]
    if no_cache:
        argv.append("--no-cache")
    if output == "docker":
        argv.extend(
            (
                "--output",
                f"type=docker,dest={archive},rewrite-timestamp=true",
            )
        )
    else:
        argv.extend(
            ("--output", f"type=oci,dest={archive},rewrite-timestamp=true")
        )
    argv.append(str(root / "images" / "sandbox"))
    runner.run(argv)
    if output == "docker":
        runner.run(("docker", "image", "load", "--input", str(archive)))
    return BuiltImage("linux/arm64", archive, local_tag)


def _source_date_epoch(snapshot: str) -> int:
    try:
        parsed = datetime.strptime(snapshot, "%Y%m%dT%H%M%SZ").replace(tzinfo=UTC)
    except ValueError as error:
        raise ValueError("APT snapshot must be a UTC timestamp") from error
    return int(parsed.timestamp())


def verify_image_contract(image: BuiltImage, runner: Runner) -> None:
    runner.run(("docker", "image", "load", "--input", str(image.archive)))
    runner.run(
        (
            "docker",
            "run",
            "--rm",
            "--platform",
            image.platform,
            image.local_tag,
            "/opt/ghosthub/image-contract.sh",
        )
    )


def resolve_tag(reference: str, runner: Runner) -> ImageReference:
    result = runner.run(
        (
            "docker",
            "buildx",
            "imagetools",
            "inspect",
            reference,
            "--format",
            "{{json .}}",
        )
    )
    try:
        payload = json.loads(result.stdout)
        digest = payload["manifest"]["digest"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise ValueError(
            f"registry did not return a manifest digest for {reference}"
        ) from error
    return ImageReference.parse(f"{reference}@{digest}")


def resolve_optional_tag(reference: str, runner: Runner) -> ImageReference | None:
    result = runner.run(
        (
            "docker",
            "buildx",
            "imagetools",
            "inspect",
            reference,
            "--format",
            "{{json .}}",
        ),
        check=False,
    )
    if result.returncode != 0:
        if result.stderr.strip() == f"ERROR: {reference}: not found":
            return None
        raise CommandError(result)
    try:
        payload = json.loads(result.stdout)
        digest = payload["manifest"]["digest"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise ValueError(
            f"registry returned invalid manifest metadata for {reference}"
        ) from error
    return ImageReference.parse(f"{reference}@{digest}")


def image_content_digest(reference: str, runner: Runner) -> str:
    result = runner.run(
        ("docker", "image", "inspect", "--format", "{{json .Id}}", reference)
    )
    try:
        digest = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("Docker returned invalid local image metadata") from error
    if (
        not isinstance(digest, str)
        or re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is None
    ):
        raise ValueError("Docker returned an invalid image content digest")
    return digest


def assert_tag_available(
    tag: str,
    digest: str,
    runner: Runner,
) -> Literal["create", "already-correct"]:
    if not tag.startswith(IMAGE_REPOSITORY + ":"):
        raise ValueError("sandbox image tag uses the wrong repository")
    resolved = resolve_optional_tag(tag, runner)
    if resolved is None:
        return "create"
    if resolved.digest != digest:
        raise ValueError(f"refusing to replace existing tag: {tag}")
    return "already-correct"
