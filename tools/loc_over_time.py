#!/usr/bin/env python3
# /// script
# requires-python = ">=3.13"
# dependencies = ["matplotlib"]
# ///
"""Plot Swift and Go lines of code over time using scc."""

import json
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def get_commits(repo_dir: str) -> list[tuple[str, datetime]]:
    """Get all commits with dates, oldest first."""
    result = subprocess.run(
        ["git", "log", "--first-parent", "--format=%H %aI", "--reverse"],
        cwd=repo_dir,
        capture_output=True,
        text=True,
        check=True,
    )
    commits = []
    for line in result.stdout.strip().splitlines():
        sha, date_str = line.split(" ", 1)
        dt = datetime.fromisoformat(date_str)
        commits.append((sha, dt))
    return commits


def sample_commits(
    commits: list[tuple[str, datetime]],
    max_points: int = 500,
) -> list[tuple[str, datetime]]:
    """Evenly sample commits, always including first and last."""
    if len(commits) <= max_points:
        return commits
    step = (len(commits) - 1) / (max_points - 1)
    indices = {round(i * step) for i in range(max_points)}
    indices.add(0)
    indices.add(len(commits) - 1)
    return [commits[i] for i in sorted(indices)]


def run_scc(repo_dir: str, sha: str) -> dict[str, int] | None:
    """Checkout sha in repo_dir, run scc, return {lang: code_lines}."""
    subprocess.run(
        ["git", "checkout", "--force", sha],
        cwd=repo_dir,
        capture_output=True,
        check=True,
    )
    subprocess.run(
        ["git", "clean", "-fdx"],
        cwd=repo_dir,
        capture_output=True,
        check=True,
    )
    result = subprocess.run(
        ["scc", "--format", "json", "--no-cocomo", "--no-complexity"],
        cwd=repo_dir,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(
            f"  WARNING: scc failed for {sha[:12]}"
            f" (exit {result.returncode}), skipping",
            file=sys.stderr,
        )
        return None
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        print(
            f"  WARNING: scc returned invalid JSON"
            f" for {sha[:12]}, skipping",
            file=sys.stderr,
        )
        return None
    return {
        entry["Name"]: entry["Code"]
        for entry in data
        if entry["Name"] in ("Swift", "Go")
    }


def main() -> None:
    repo_dir = str(Path(__file__).resolve().parent.parent)

    print("Collecting commit history...")
    commits = get_commits(repo_dir)
    sampled = sample_commits(commits)
    print(f"{len(commits)} total commits, sampling {len(sampled)}")

    dates: list[datetime] = []
    swift_loc: list[int] = []
    go_loc: list[int] = []

    with tempfile.TemporaryDirectory() as tmp:
        clone_dir = str(Path(tmp) / "repo")
        print("Cloning into temp directory...")
        subprocess.run(
            ["git", "clone", "--no-checkout", repo_dir, clone_dir],
            capture_output=True,
            check=True,
        )

        for i, (sha, dt) in enumerate(sampled):
            counts = run_scc(clone_dir, sha)
            if counts is None:
                continue
            dates.append(dt)
            swift_loc.append(counts.get("Swift", 0))
            go_loc.append(counts.get("Go", 0))
            pct = (i + 1) / len(sampled) * 100
            print(
                f"  [{i + 1}/{len(sampled)}] {pct:5.1f}%  "
                f"{dt.strftime('%Y-%m-%d')}  "
                f"Swift={swift_loc[-1]:>6,}  Go={go_loc[-1]:>6,}",
            )

    print("Generating plot...")
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
    import matplotlib.ticker as ticker

    fig, ax = plt.subplots(figsize=(14, 6))
    ax.stackplot(
        dates,
        swift_loc,
        go_loc,
        labels=["Swift", "Go"],
        colors=["#F05138", "#00ADD8"],
        alpha=0.85,
    )
    ax.set_title("Ghosthub — Lines of Code Over Time")
    ax.set_xlabel("Date")
    ax.set_ylabel("Lines of Code")
    ax.legend(loc="upper left")
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))
    ax.xaxis.set_major_locator(mdates.MonthLocator())
    ax.yaxis.set_major_formatter(
        ticker.FuncFormatter(lambda x, _: f"{x / 1000:.0f}k")
    )
    fig.autofmt_xdate()
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()

    out_path = Path(repo_dir) / "loc_over_time.png"
    fig.savefig(out_path, dpi=150)
    print(f"Saved to {out_path}")


if __name__ == "__main__":
    main()
