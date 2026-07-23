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
