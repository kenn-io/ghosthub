from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1] / "tools"))

from development_version import version_from_git_describe


@pytest.mark.parametrize(
    ("description", "expected"),
    [
        ("v0.3.0-0-g0123abc", "0.3.0"),
        ("v0.3.0-8-g3c67741", "0.3.0-8-g3c67741"),
        (
            "v0.3.0-8-g3c67741-dirty",
            "0.3.0-8-g3c67741-dirty",
        ),
        ("3c67741", "0.0.0-0-g3c67741"),
    ],
)
def test_version_tracks_the_nearest_release_tag(
    description: str,
    expected: str,
) -> None:
    assert version_from_git_describe(description) == expected
