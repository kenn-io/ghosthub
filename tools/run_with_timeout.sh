#!/bin/sh
# run_with_timeout.sh <seconds> <command...>
#
# Runs the command with a hard wall-clock timeout and one retry. Used by
# the W1 essential-workflows smoke to guard against the SwiftPM
# `swift test` <-> testing-helper IPC hang (kata g6ra): both processes
# park in their run loops before any test executes, silently eating 20+
# minutes. A timed-out or failed attempt is retried once; a second
# failure fails the gate.
#
# macOS ships no GNU timeout or setsid, so the command runs in its own
# process group via python3 and the watchdog kills the whole group —
# including any orphaned testing helpers holding the output pipes.

set -u

seconds="$1"
shift

# Forward INT/TERM/HUP to the child's process group so cancelling the
# caller (e.g. Ctrl-C on make) does not orphan a detached swift-test
# group, then re-raise to preserve the signal exit status.
terminate() {
    sig="$1"
    if [ -n "${cmd_pid:-}" ]; then
        kill -"$sig" -- -"$cmd_pid" 2>/dev/null
    fi
    if [ -n "${watchdog_pid:-}" ]; then
        kill -TERM "$watchdog_pid" 2>/dev/null
    fi
    trap - "$sig"
    kill -"$sig" $$
}
trap 'terminate INT' INT
trap 'terminate TERM' TERM
trap 'terminate HUP' HUP

attempt() {
    python3 -c 'import os, sys
os.setpgid(0, 0)
os.execvp(sys.argv[1], sys.argv[1:])' "$@" &
    cmd_pid=$!
    # The watchdog detaches from stdout/stderr so a leftover sleep child
    # (it dies with the subshell only after its current sleep ends)
    # cannot hold the caller's output pipes open.
    (
        sleep "$seconds"
        kill -TERM -"$cmd_pid" 2>/dev/null
        sleep 5
        kill -KILL -"$cmd_pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    watchdog_pid=$!
    wait "$cmd_pid"
    status=$?
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null
    return "$status"
}

if attempt "$@"; then
    exit 0
fi

echo "run_with_timeout: '$*' failed or timed out; retrying once" >&2

attempt "$@"
