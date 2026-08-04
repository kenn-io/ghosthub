from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def workflow_text(name: str) -> str:
    return (REPO_ROOT / ".github" / "workflows" / name).read_text()


def test_trusted_refs_select_the_self_hosted_runner():
    caller = workflow_text("ci-pr.yml")
    workflow = workflow_text("ci.yml")
    runner_selection = workflow.split("    runs-on: >-", 1)[1].split(
        "    timeout-minutes:", 1
    )[0]

    assert "kenn-macos-arm64-public" not in caller
    assert "github.repository == 'kenn-io/ghosthub'" in runner_selection
    assert "github.event_name == 'push'" in runner_selection
    assert "github.ref == 'refs/heads/main'" in runner_selection
    assert "github.event_name == 'pull_request'" in runner_selection
    assert (
        "github.event.pull_request.head.repo.full_name == github.repository"
        in runner_selection
    )
    assert (
        "github.event.pull_request.base.repo.full_name == github.repository"
        in runner_selection
    )
    assert "kenn-macos-arm64-public" in runner_selection
    assert "macos-26" in runner_selection
