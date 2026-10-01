from __future__ import annotations

import pytest
from development_version import bundle_versions_from_git_describe


@pytest.mark.parametrize(
    ("description", "expected_short", "expected_display", "expected_local"),
    [
        ("v0.3.0-0-g0123abc", "0.3.0", "0.3.0", "0.3.0-0-g0123abc"),
        (
            "v0.3.0-8-g3c67741",
            "0.3.0",
            "0.3.0-8-g3c67741",
            "0.3.0-8-g3c67741",
        ),
        (
            "v0.3.0-8-g3c67741-dirty",
            "0.3.0",
            "0.3.0-8-g3c67741-dirty",
            "0.3.0-8-g3c67741-dirty",
        ),
        ("3c67741", "0.0.0", "0.0.0-0-g3c67741", "0.0.0-0-g3c67741"),
    ],
)
def test_version_tracks_the_nearest_release_tag(
    description: str,
    expected_short: str,
    expected_display: str,
    expected_local: str,
) -> None:
    versions = bundle_versions_from_git_describe(description)

    assert versions.short == expected_short
    assert versions.display == expected_display
    assert versions.local == expected_local
