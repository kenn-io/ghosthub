#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from sandbox_image.apple import clean_managed_fixtures
from sandbox_image.authority import (
    audit_promotion_authority,
    configure_promotion_authority,
    enable_promotion_authority,
    promotion_authority_status,
    verify_promotion_app_key,
)
from sandbox_image.commands import (
    check_image,
    maintenance_image,
    pin_image,
    prepare_candidate_image,
    prepare_promotion,
    promote_image,
    refresh_image,
    status_image,
    verify_promotion,
    vet_image,
)
from sandbox_image.process import CommandRunner

ROOT = Path(__file__).resolve().parents[1]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("check")
    subcommands.add_parser("prepare-candidate")
    refresh = subcommands.add_parser("refresh")
    refresh.add_argument("--version", required=True)
    vet = subcommands.add_parser("vet")
    vet.add_argument("--image", required=True)
    pin = subcommands.add_parser("pin")
    pin.add_argument("--image", required=True)
    promote = subcommands.add_parser("promote")
    promote.add_argument("--image", required=True)
    promote.add_argument("--version", required=True)
    for command in ("verify-promotion", "prepare-promotion"):
        trusted = subcommands.add_parser(command)
        trusted.add_argument("--evidence-commit", required=True)
        trusted.add_argument("--digest", required=True)
        trusted.add_argument("--version", required=True)
    subcommands.add_parser("clean")
    subcommands.add_parser("maintenance")
    subcommands.add_parser("status")
    authority = subcommands.add_parser("authority-configure")
    authority.add_argument("--app-id", required=True)
    authority.add_argument("--client-id", required=True)
    authority.add_argument("--private-key", required=True, type=Path)
    subcommands.add_parser("authority-enable")
    authority_audit = subcommands.add_parser("authority-audit")
    authority_audit.add_argument("--app-id", type=int)
    authority_audit.add_argument("--workflow-root", type=Path)
    verify_app = subcommands.add_parser("authority-verify-app")
    verify_app.add_argument("--app-id", required=True, type=int)
    verify_app.add_argument("--client-id", required=True)
    arguments = parser.parse_args(argv)
    runner = CommandRunner(redacted_prefixes=(ROOT,))
    if arguments.command == "check":
        check_image(ROOT, runner=runner)
        return 0
    if arguments.command == "prepare-candidate":
        plan = prepare_candidate_image(ROOT, runner=runner)
        print(f"tag={plan.tag}")
        print(f"local_content_digest={plan.local_content_digest}")
        print(f"archive={plan.archive}")
        print(f"image_version={plan.image_version}")
        return 0
    if arguments.command == "refresh":
        refresh_image(ROOT, version=arguments.version, runner=runner)
        return 0
    if arguments.command == "vet":
        vet_image(ROOT, arguments.image, runner=runner)
        return 0
    if arguments.command == "pin":
        pin_image(ROOT, arguments.image)
        return 0
    if arguments.command == "promote":
        commit = promote_image(ROOT, arguments.image, arguments.version, runner=runner)
        print(f"Dispatched promotion for {commit}")
        return 0
    if arguments.command == "verify-promotion":
        verify_promotion(
            ROOT,
            arguments.evidence_commit,
            arguments.digest,
            arguments.version,
            runner=runner,
        )
        return 0
    if arguments.command == "prepare-promotion":
        plan = prepare_promotion(
            ROOT,
            arguments.evidence_commit,
            arguments.digest,
            arguments.version,
            runner=runner,
        )
        print(f"candidate={plan.candidate.canonical}")
        print(f"production_tag={plan.production_tag}")
        print(f"action={plan.action}")
        print(f"expires_at={plan.expires_at.strftime('%Y-%m-%dT%H:%M:%SZ')}")
        print(
            "production_environment_fingerprint="
            f"{plan.production_environment_fingerprint}"
        )
        print(f"status_environment_fingerprint={plan.status_environment_fingerprint}")
        return 0
    if arguments.command == "clean":
        cleaned = clean_managed_fixtures(ROOT, runner)
        print(f"Cleaned fixtures: {cleaned}")
        return 0
    if arguments.command == "maintenance":
        message, action_required = maintenance_image(ROOT, runner=runner)
        print(message)
        return 1 if action_required else 0
    if arguments.command == "authority-configure":
        configure_promotion_authority(
            ROOT,
            arguments.app_id,
            arguments.client_id,
            arguments.private_key,
            runner,
        )
        print("Promotion authority credentials configured")
        return 0
    if arguments.command == "authority-enable":
        app_id = enable_promotion_authority(ROOT, runner)
        print(f"Promotion authority enabled for app {app_id}")
        return 0
    if arguments.command == "authority-audit":
        app_id = audit_promotion_authority(
            ROOT,
            runner,
            app_id=arguments.app_id,
            workflow_root=arguments.workflow_root,
        )
        print(f"Promotion authority valid for app {app_id}")
        return 0
    if arguments.command == "authority-verify-app":
        private_key = sys.stdin.read()
        if not private_key:
            raise ValueError("promotion app private key is required on standard input")
        verify_promotion_app_key(
            private_key,
            arguments.app_id,
            arguments.client_id,
            runner,
        )
        print("Promotion App identity verified")
        return 0
    status = status_image(ROOT, runner=runner)
    print(f"Image version: {status.source_version}")
    print(f"Runtime pin: {status.pin}")
    print(f"Candidate: {status.candidate}")
    print(f"Production: {status.production}")
    print(f"Vetting report: {status.report}")
    print(f"Setup: {status.setup}")
    print(f"Promotion authority: {promotion_authority_status(ROOT, runner)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
