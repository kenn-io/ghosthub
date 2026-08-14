import os
import plistlib
import stat
import subprocess
import sys
from pathlib import Path

import pytest


TOOLS_DIR = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS_DIR))

from nightly_release_notes import render_notes  # noqa: E402


PUBLIC_KEY = "MKL5y44upnEoZrnm3VLLDocsBTD+3DgnH161eEQPhMQ="


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", repo, *args],
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


def make_git_history(tmp_path: Path) -> tuple[Path, str, str, str]:
    repo = tmp_path / "repository"
    repo.mkdir()
    git(repo, "init")
    git(repo, "config", "user.name", "Nightly Test")
    git(repo, "config", "user.email", "nightly@example.test")
    commits = []
    for index, subject in enumerate(
        ("Initial source", "Fix attachment", "Reduce refresh work")
    ):
        (repo / "source.txt").write_text(str(index), encoding="utf-8")
        git(repo, "add", "source.txt")
        git(repo, "commit", "-m", subject)
        commits.append(git(repo, "rev-parse", "HEAD"))
    return repo, commits[0], commits[1], commits[2]


def test_notes_cover_each_commit_after_the_previous_nightly(tmp_path):
    repo, previous_sha, _, source_sha = make_git_history(tmp_path)

    notes = render_notes(
        repository="kenn-io/ghosthub",
        source_sha=source_sha,
        previous_source_sha=previous_sha,
        built_at="2026-08-13T08:00:00Z",
        repo_path=repo,
    )

    assert f"Ghosthub Nightly · 2026-08-13 · {source_sha[:8]}" in notes
    assert "Fix attachment" in notes
    assert "Reduce refresh work" in notes
    assert "Initial source" not in notes
    assert (
        f"https://github.com/kenn-io/ghosthub/compare/"
        f"{previous_sha}...{source_sha}"
    ) in notes


def test_notes_fall_back_to_the_source_commit_without_an_ancestor(tmp_path):
    repo, previous_sha, _, source_sha = make_git_history(tmp_path)
    git(repo, "checkout", "--detach", previous_sha)
    (repo / "side.txt").write_text("side", encoding="utf-8")
    git(repo, "add", "side.txt")
    git(repo, "commit", "-m", "Side branch only")
    side_sha = git(repo, "rev-parse", "HEAD")

    without_previous = render_notes(
        repository="kenn-io/ghosthub",
        source_sha=source_sha,
        previous_source_sha=None,
        built_at="2026-08-13T08:00:00Z",
        repo_path=repo,
    )
    unrelated_previous = render_notes(
        repository="kenn-io/ghosthub",
        source_sha=source_sha,
        previous_source_sha=side_sha,
        built_at="2026-08-13T08:00:00Z",
        repo_path=repo,
    )

    for notes in (without_previous, unrelated_previous):
        assert "Reduce refresh work" in notes
        assert "Fix attachment" not in notes
        assert (
            f"https://github.com/kenn-io/ghosthub/commit/{source_sha}"
        ) in notes


def test_notes_reject_a_malformed_source_revision(tmp_path):
    repo, _, _, _ = make_git_history(tmp_path)

    with pytest.raises(ValueError, match="source_sha"):
        render_notes(
            repository="kenn-io/ghosthub",
            source_sha="abc123",
            previous_source_sha=None,
            built_at="2026-08-13T08:00:00Z",
            repo_path=repo,
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
notes = archive.with_suffix(".md")
assert notes.is_file()
(release_root / "captured-release-notes.md").write_text(notes.read_text())
(release_root / "appcast.xml").write_text(
    '<?xml version="1.0"?>'
    '<rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle">'
    '<channel><item><enclosure url="'
    + prefix
    + archive.name
    + '" sparkle:version="123" sparkle:edSignature="signed" />'
    '</item></channel></rss>'
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

assert sys.stdin.read() == "private-seed"
print("{PUBLIC_KEY}")
""",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@pytest.mark.parametrize("same_source_recovery", [False, True])
def test_nightly_wrapper_uses_an_immutable_attempt_url_without_key_leaks(
    tmp_path,
    same_source_recovery,
):
    repo_root = Path(__file__).resolve().parents[1]
    git_repo, previous_sha, _, source_sha = make_git_history(tmp_path)
    release_root = tmp_path / "release"
    app_path = release_root / "Ghosthub.app"
    contents = app_path / "Contents"
    contents.mkdir(parents=True)
    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump(
            {"CFBundleVersion": "123", "SUPublicEDKey": PUBLIC_KEY},
            handle,
        )
    dmg_name = "Ghosthub_Nightly_2026-08-13_deadbeef_macos_arm64.dmg"
    (release_root / dmg_name).write_bytes(b"dmg")
    generator = tmp_path / "generate_appcast"
    write_fake_generator(generator)
    deriver = tmp_path / "derive_public_key"
    write_fake_deriver(deriver)
    env = {
        **os.environ,
        "RELEASE_ROOT": str(release_root),
        "RELEASE_APP_PATH": str(app_path),
        "RELEASE_DMG_NAME": dmg_name,
        "NIGHTLY_PUBLIC_BASE_URL": (
            "https://github.com/kenn-io/ghosthub-nightly/releases"
        ),
        "NIGHTLY_SOURCE_SHA": source_sha,
        "NIGHTLY_PREVIOUS_SOURCE_SHA": (
            source_sha if same_source_recovery else previous_sha
        ),
        "NIGHTLY_BUILD_AT": "2026-08-13T08:00:00Z",
        "NIGHTLY_BUILD_VERSION": "123",
        "NIGHTLY_REPOSITORY_PATH": str(git_repo),
        "GITHUB_RUN_ID": "7",
        "GITHUB_RUN_ATTEMPT": "1",
        "SPARKLE_GENERATE_APPCAST": str(generator),
        "SPARKLE_DERIVE_PUBLIC_KEY": str(deriver),
        "SPARKLE_PUBLIC_ED_KEY": PUBLIC_KEY,
        "SPARKLE_ED_PRIVATE_KEY": "private-seed",
    }

    result = subprocess.run(
        [repo_root / "tools" / "generate_nightly_update_appcast.sh"],
        cwd=repo_root,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    appcast = (release_root / "appcast.xml").read_text(encoding="utf-8")
    notes = (release_root / "captured-release-notes.md").read_text(
        encoding="utf-8"
    )
    assert (
        "https://github.com/kenn-io/ghosthub-nightly/releases/download/"
        "nightly-123-7-1/"
        f"{dmg_name}"
    ) in appcast
    assert source_sha[:8] in notes
    assert "Reduce refresh work" in notes
    for output in (result.stdout, result.stderr, appcast, notes):
        assert "private-seed" not in output
