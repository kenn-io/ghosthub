#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
    echo "usage: $0 command [arguments...]" >&2
    exit 2
fi

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
current_uid=$(id -u)
# Keep this below tmux's Unix-socket path limit. The sticky /tmp parent and
# strict UID/mode checks in purge_test_tmux.sh protect the per-user hierarchy.
user_tmpdir="/tmp/ghosthub-$current_uid"
test_root="$user_tmpdir/tmux-tests"
umask 077
mkdir -m 700 "$user_tmpdir" 2>/dev/null || true
sh "$script_dir/purge_test_tmux.sh" --stale
mkdir -m 700 "$test_root" 2>/dev/null || true
sh "$script_dir/purge_test_tmux.sh" --stale
# Publishing the owner PID in the atomically created directory name lets
# concurrent stale sweeps distinguish active runs without a marker-file race.
tmux_tmpdir=$(mktemp -d "$test_root/run.$$.XXXXXX")
run_id=${tmux_tmpdir##*.}
child_pid=
deadline_marker="$tmux_tmpdir/stop-deadline"
deadline_pid=
pending_signal=
signal_status=

start_kill_deadline() {
    [ -z "$deadline_pid" ] || return 0

    set -m
    (
        # Leave ample time for run_with_timeout.sh to reap this wrapper and
        # purge its tmux directory before that outer guard escalates at 5s.
        sleep 2
        : > "$deadline_marker"
        kill -KILL -- -"$child_pid" 2>/dev/null ||
            kill -KILL "$child_pid" 2>/dev/null || true
    ) &
    deadline_pid=$!
    set +m
}

cancel_kill_deadline() {
    [ -n "$deadline_pid" ] || return 0

    kill -TERM -- -"$deadline_pid" 2>/dev/null || true
    wait "$deadline_pid" 2>/dev/null || true
    deadline_pid=
}

forward_signal() {
    signal=$1
    pending_signal=$signal
    case "$signal" in
        INT) signal_status=130 ;;
        TERM) signal_status=143 ;;
        HUP) signal_status=129 ;;
    esac
    if [ -n "$child_pid" ]; then
        kill -"$signal" -- -"$child_pid" 2>/dev/null || true
        start_kill_deadline
    fi
}

group_has_live_processes() {
    ps -axo pgid=,state= | awk -v pgid="$child_pid" '
        $1 == pgid && $2 !~ /^Z/ { found = 1; exit }
        END { exit found ? 0 : 1 }
    '
}

stop_child_group() {
    [ -n "$child_pid" ] || return 0

    if group_has_live_processes; then
        kill -TERM -- -"$child_pid" 2>/dev/null || true
    elif kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM "$child_pid" 2>/dev/null || true
    else
        cancel_kill_deadline
        wait "$child_pid" 2>/dev/null || true
        return 0
    fi

    start_kill_deadline
    while group_has_live_processes && [ ! -e "$deadline_marker" ]
    do
        sleep 0.1
    done
    if group_has_live_processes; then
        kill -KILL -- -"$child_pid" 2>/dev/null || true
    elif kill -0 "$child_pid" 2>/dev/null; then
        kill -KILL "$child_pid" 2>/dev/null || true
    fi
    cancel_kill_deadline
    wait "$child_pid" 2>/dev/null || true
}

cleanup() {
    status=$1
    trap - EXIT INT TERM HUP
    set +e
    stop_child_group
    sh "$script_dir/purge_test_tmux.sh" "$tmux_tmpdir" || true
    exit "$status"
}
trap 'cleanup $?' EXIT
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM
trap 'forward_signal HUP' HUP

export TMUX_TMPDIR="$tmux_tmpdir"
export GHOSTHUB_TEST_TMUX_RUN_ID="$run_id"

# Monitor mode places the background command in its own process group so
# cancellation reaches SwiftPM and every helper it launched.
set -m
"$@" &
child_pid=$!
set +m

# A signal may arrive between fork and setpgid. Keep the trap active during
# that window and deliver any pending signal once the group is published.
while kill -0 "$child_pid" 2>/dev/null &&
    ! kill -0 -- -"$child_pid" 2>/dev/null
do
    :
done
if [ -n "$signal_status" ]; then
    forward_signal "$pending_signal"
fi

set +e
while [ -z "$signal_status" ]; do
    wait "$child_pid"
    status=$?
    if ! kill -0 "$child_pid" 2>/dev/null; then
        break
    fi
done
set -e

# The test command may finish before one of its helpers. Do not remove the
# tmux directory until every process left in the test group has stopped.
stop_child_group
child_pid=
if [ -n "$signal_status" ]; then
    status=$signal_status
fi
exit "$status"
