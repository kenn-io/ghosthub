import base64
import os
import plistlib
import stat
import subprocess
from pathlib import Path


PUBLIC_KEY = "MKL5y44upnEoZrnm3VLLDocsBTD+3DgnH161eEQPhMQ="


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
