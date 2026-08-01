#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
    echo "usage: $0 command [arguments...]" >&2
    exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_root=/tmp/ghosthub-tmux-tests
sh "$script_dir/purge_test_tmux.sh" --stale
mkdir -p "$test_root"
tmux_tmpdir=$(mktemp -d "$test_root/run.XXXXXX")
printf '%s\n' "$$" >"$tmux_tmpdir/owner.pid"
run_id=${tmux_tmpdir##*.}

cleanup() {
    status=$1
    trap - EXIT INT TERM HUP
    sh "$script_dir/purge_test_tmux.sh" "$tmux_tmpdir" || true
    exit "$status"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

export TMUX_TMPDIR="$tmux_tmpdir"
export GHOSTHUB_TEST_TMUX_RUN_ID="$run_id"
"$@"
