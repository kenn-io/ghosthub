import base64
import os
import plistlib
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest


PUBLIC_KEY = "MKL5y44upnEoZrnm3VLLDocsBTD+3DgnH161eEQPhMQ="
LEGACY_PRIVATE_KEY = bytes(
    [
        200, 238, 135, 84, 10, 189, 3, 193,
        61, 208, 203, 30, 133, 47, 12, 22,
        19, 52, 252, 99, 110, 205, 209, 94,
        215, 144, 201, 70, 27, 162, 163, 108,
        0, 164, 68, 184, 226, 93, 121, 199,
        172, 17, 26, 64, 89, 68, 232, 41,
        2, 26, 245, 175, 158, 165, 42, 55,
        5, 97, 8, 243, 251, 164, 93, 9,
    ]
)
LEGACY_PUBLIC_KEY = bytes(
    [
        121, 17, 79, 45, 155, 141, 51, 169,
        188, 110, 91, 102, 182, 147, 215, 225,
        252, 202, 110, 231, 200, 215, 62, 171,
        40, 145, 237, 128, 130, 44, 150, 89,
    ]
)


def write_fake_generator(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import pathlib
import sys

assert sys.stdin.read() == "private-seed"
prefix = sys.argv[sys.argv.index("--download-url-prefix") + 1]
release_root = pathlib.Path(sys.argv[-1])
archive = next(release_root.glob("*.dmg"))
(release_root / "appcast.xml").write_text(
    '<?xml version="1.0"?>'
    '<rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle">'
    '<channel><item><enclosure url="'
    + prefix
    + archive.name
    + '" sparkle:edSignature="signed" /></item></channel></rss>'
    '<!-- sparkle-signatures: edSignature: signed-feed -->'
)
""",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def write_fake_deriver(path: Path) -> None:
    path.write_text(
        f"""#!/usr/bin/env python3
import sys

private_key = sys.stdin.read()
if private_key == "private-seed":
    print("{PUBLIC_KEY}")
else:
    print("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
""",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def make_release(tmp_path: Path, public_key: str = PUBLIC_KEY) -> dict[str, str]:
    release_root = tmp_path / "release"
    app_path = release_root / "Ghosthub.app"
    contents = app_path / "Contents"
    contents.mkdir(parents=True)
    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump({"SUPublicEDKey": public_key}, handle)

    dmg_name = "Ghosthub_0.1.2_macos_arm64.dmg"
    (release_root / dmg_name).write_bytes(b"dmg")
    generator = tmp_path / "generate_appcast"
    write_fake_generator(generator)
    deriver = tmp_path / "derive_public_key"
    write_fake_deriver(deriver)

    return {
        **os.environ,
        "RELEASE_ROOT": str(release_root),
        "RELEASE_APP_PATH": str(app_path),
        "RELEASE_APP_VERSION": "0.1.2",
        "RELEASE_ARCH": "arm64",
        "RELEASE_DMG_NAME": dmg_name,
        "RELEASE_DMG_PATH": str(release_root / dmg_name),
        "RELEASE_TAG": "v0.1.2",
        "SPARKLE_GENERATE_APPCAST": str(generator),
        "SPARKLE_DERIVE_PUBLIC_KEY": str(deriver),
        "SPARKLE_ED_PRIVATE_KEY": "private-seed",
        "SPARKLE_PUBLIC_ED_KEY": PUBLIC_KEY,
    }


def test_generates_signed_appcast_without_exposing_the_private_key(tmp_path):
    repo_root = Path(__file__).resolve().parents[1]
    result = subprocess.run(
        [repo_root / "tools" / "generate_update_appcast.sh"],
        cwd=repo_root,
        env=make_release(tmp_path),
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "private-seed" not in result.stdout
    assert "private-seed" not in result.stderr
    appcast = (tmp_path / "release" / "appcast.xml").read_text()
    assert "sparkle:edSignature=\"signed\"" in appcast
    assert "<!-- sparkle-signatures:" in appcast
    assert (
        "https://github.com/kenn-io/ghosthub/releases/download/v0.1.2/"
        "Ghosthub_0.1.2_macos_arm64.dmg"
    ) in appcast
    assert not (tmp_path / "release" / "Ghosthub_0.1.2_macos_arm64.md").exists()


def test_rejects_a_public_key_that_does_not_match_the_app(tmp_path):
    repo_root = Path(__file__).resolve().parents[1]
    result = subprocess.run(
        [repo_root / "tools" / "generate_update_appcast.sh"],
        cwd=repo_root,
        env=make_release(tmp_path, public_key="different-key"),
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode != 0
    assert "does not match the app bundle" in result.stderr


def test_rejects_a_private_key_that_does_not_match_the_app(tmp_path):
    repo_root = Path(__file__).resolve().parents[1]
    env = make_release(tmp_path)
    env["SPARKLE_ED_PRIVATE_KEY"] = "wrong-private-seed"
    result = subprocess.run(
        [repo_root / "tools" / "generate_update_appcast.sh"],
        cwd=repo_root,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode != 0
    assert "private key does not match the app bundle" in result.stderr


def test_public_key_derivation_matches_the_ed25519_test_vector():
    repo_root = Path(__file__).resolve().parents[1]
    seed = bytes.fromhex(
        "9d61b19deffd5a60ba844af492ec2cc4"
        "4449c5697b326919703bac031cae7f60"
    )
    expected_public_key = bytes.fromhex(
        "d75a980182b10ab7d54bfed3c964073a"
        "0ee172f3daa62325af021a68f707511a"
    )

    result = subprocess.run(
        ["swift", repo_root / "tools" / "derive_sparkle_public_key.swift"],
        cwd=repo_root,
        input=base64.b64encode(seed).decode(),
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == base64.b64encode(expected_public_key).decode()


def test_public_key_derivation_accepts_sparkles_legacy_export():
    repo_root = Path(__file__).resolve().parents[1]

    result = subprocess.run(
        ["swift", repo_root / "tools" / "derive_sparkle_public_key.swift"],
        cwd=repo_root,
        input=base64.b64encode(
            LEGACY_PRIVATE_KEY + LEGACY_PUBLIC_KEY
        ).decode(),
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == base64.b64encode(
        LEGACY_PUBLIC_KEY
    ).decode()


def test_public_key_derivation_rejects_a_mismatched_legacy_pair():
    repo_root = Path(__file__).resolve().parents[1]
    mismatched_public_key = bytes(32)

    result = subprocess.run(
        ["swift", repo_root / "tools" / "derive_sparkle_public_key.swift"],
        cwd=repo_root,
        input=base64.b64encode(
            LEGACY_PRIVATE_KEY + mismatched_public_key
        ).decode(),
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode != 0
    assert "do not match" in result.stderr


@pytest.mark.skipif(sys.platform != "darwin", reason="Sparkle tooling targets macOS")
def test_pinned_generate_appcast_accepts_the_standard_seed_export(tmp_path):
    repo_root = Path(__file__).resolve().parents[1]
    generator = (
        repo_root
        / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
    )
    if not generator.is_file():
        pytest.skip("Sparkle binary artifact is not resolved")

    seed = bytes.fromhex(
        "9d61b19deffd5a60ba844af492ec2cc4"
        "4449c5697b326919703bac031cae7f60"
    )
    public_key = base64.b64encode(
        bytes.fromhex(
            "d75a980182b10ab7d54bfed3c964073a"
            "0ee172f3daa62325af021a68f707511a"
        )
    ).decode()

    app = tmp_path / "Fixture.app"
    executable = app / "Contents/MacOS/Fixture"
    executable.parent.mkdir(parents=True)
    shutil.copyfile("/usr/bin/true", executable)
    executable.chmod(0o755)
    with (app / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleExecutable": "Fixture",
                "CFBundleIdentifier": "com.ghosthub.sparkle-fixture",
                "CFBundleName": "Fixture",
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "1",
                "SUPublicEDKey": public_key,
                "SURequireSignedFeed": True,
                "SUVerifyUpdateBeforeExtraction": True,
            },
            handle,
        )
    subprocess.run(
        ["codesign", "--force", "--deep", "--sign", "-", app],
        check=True,
        capture_output=True,
        text=True,
    )
    archive = tmp_path / "Fixture_1.0.0.zip"
    subprocess.run(
        ["ditto", "-c", "-k", "--keepParent", app, archive],
        check=True,
        capture_output=True,
        text=True,
    )

    result = subprocess.run(
        [
            generator,
            "--ed-key-file",
            "-",
            "--maximum-versions",
            "1",
            "--maximum-deltas",
            "0",
            tmp_path,
        ],
        input=base64.b64encode(seed).decode(),
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    appcast = (tmp_path / "appcast.xml").read_text()
    assert "sparkle:edSignature=" in appcast
    assert "<!-- sparkle-signatures:" in appcast
