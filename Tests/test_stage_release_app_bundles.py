import importlib.util
import sys
from pathlib import Path


def load_module():
    repo_root = Path(__file__).resolve().parents[1]
    module_path = repo_root / "tools" / "stage_release_app_bundles.py"
    spec = importlib.util.spec_from_file_location(
        "stage_release_app_bundles",
        module_path,
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


stage = load_module()


def write_bundle(source_bin_dir: Path, name: str, files: dict[str, str]) -> Path:
    bundle_dir = source_bin_dir / name
    bundle_dir.mkdir()
    for relative_path, contents in files.items():
        file_path = bundle_dir / relative_path
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(contents, encoding="utf-8")
    return bundle_dir


def test_stage_bundles_copies_resources_inside_contents(tmp_path):
    source_bin_dir = tmp_path / "bin"
    app_root = tmp_path / "Ghosthub.app"
    resources_dir = app_root / "Contents" / "Resources"
    source_bin_dir.mkdir(parents=True)
    resources_dir.mkdir(parents=True)

    write_bundle(
        source_bin_dir,
        "Ghosthub_GhosthubUI.bundle",
        {"claude.pdf": "pdf"},
    )
    write_bundle(
        source_bin_dir,
        "GRDB_GRDB.bundle",
        {"Info.plist": "plist"},
    )

    staged = stage.stage_bundles(
        source_bin_dir=source_bin_dir,
        resources_dir=resources_dir,
    )

    staged_bundle = resources_dir / "Ghosthub_GhosthubUI.bundle"

    assert staged == [
        resources_dir / "GRDB_GRDB.bundle",
        staged_bundle,
    ]
    assert (staged_bundle / "claude.pdf").read_text(encoding="utf-8") == "pdf"
    assert list(app_root.iterdir()) == [app_root / "Contents"]


def test_stage_bundles_replaces_existing_resource_bundle(tmp_path):
    source_bin_dir = tmp_path / "bin"
    app_root = tmp_path / "Ghosthub.app"
    resources_dir = app_root / "Contents" / "Resources"
    source_bin_dir.mkdir(parents=True)
    resources_dir.mkdir(parents=True)

    write_bundle(
        source_bin_dir,
        "GRDB_GRDB.bundle",
        {"Info.plist": "new"},
    )
    write_bundle(
        source_bin_dir,
        "Ghosthub_GhosthubUI.bundle",
        {"claude.pdf": "pdf"},
    )

    existing_bundle = resources_dir / "GRDB_GRDB.bundle"
    existing_bundle.mkdir()
    (existing_bundle / "Info.plist").write_text("old", encoding="utf-8")

    stage.stage_bundles(
        source_bin_dir=source_bin_dir,
        resources_dir=resources_dir,
    )

    assert (existing_bundle / "Info.plist").read_text(encoding="utf-8") == "new"
    assert list(app_root.iterdir()) == [app_root / "Contents"]


def test_stage_bundles_fails_when_expected_bundle_is_missing(tmp_path):
    source_bin_dir = tmp_path / "bin"
    app_root = tmp_path / "Ghosthub.app"
    resources_dir = app_root / "Contents" / "Resources"
    source_bin_dir.mkdir(parents=True)
    resources_dir.mkdir(parents=True)

    write_bundle(
        source_bin_dir,
        "Ghosthub_GhosthubUI.bundle",
        {"claude.pdf": "pdf"},
    )

    try:
        stage.stage_bundles(
            source_bin_dir=source_bin_dir,
            resources_dir=resources_dir,
        )
    except FileNotFoundError as error:
        assert "GRDB_GRDB.bundle" in str(error)
    else:
        raise AssertionError("Expected stage_bundles to fail for a missing bundle.")
