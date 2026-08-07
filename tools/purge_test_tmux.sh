#!/bin/sh

set -eu

current_uid=$(id -u)
user_tmpdir="/tmp/ghosthub-$current_uid"
test_root="$user_tmpdir/tmux-tests"
legacy_socket_root="/tmp/tmux-$current_uid"
tmux_bin=$(command -v tmux || true)
mode=all
run_dir=

directory_owner() {
    stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1"
}

directory_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

require_secure_directory() {
    directory=$1
    description=$2
    if [ ! -d "$directory" ] || [ -L "$directory" ] ||
        [ "$(directory_owner "$directory")" != "$current_uid" ] ||
        [ "$(directory_mode "$directory")" != 700 ]
    then
        echo "refusing insecure $description directory: $directory" >&2
        return 1
    fi
}

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [--stale | run-directory]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    if [ "$1" = --stale ]; then
        mode=stale
    else
        mode=run
        run_dir=$1
        run_name=$(basename -- "$run_dir")
        run_parent=$(dirname -- "$run_dir")
        if [ "$run_parent" != "$test_root" ] ||
            ! printf '%s\n' "$run_name" |
                grep -Eq '^run\.[0-9]+\.[A-Za-z0-9]{6}$'
        then
            echo "refusing unexpected tmux test directory: $run_dir" >&2
            exit 2
        fi
    fi
fi

kill_sockets() {
    socket_list=$1
    [ -n "$socket_list" ] || return 0
    if [ -n "$tmux_bin" ]; then
        # Stop every client concurrently under one shared deadline so purge
        # stays inside the outer watchdog's escalation window no matter how
        # many stalled sockets a run left behind.
        client_pids=
        set -m
        while IFS= read -r socket; do
            [ -n "$socket" ] || continue
            "$tmux_bin" -S "$socket" kill-server >/dev/null 2>&1 &
            client_pids="$client_pids $!"
        done <<EOF_SOCKETS
$socket_list
EOF_SOCKETS
        (
            sleep 1
            # shellcheck disable=SC2086  # deliberate PID list splitting
            for client in $client_pids; do
                kill -KILL -- -"$client" 2>/dev/null ||
                    kill -KILL "$client" 2>/dev/null || true
            done
        ) &
        socket_deadline_pid=$!
        set +m
        # shellcheck disable=SC2086  # deliberate PID list splitting
        for client in $client_pids; do
            wait "$client" 2>/dev/null || true
        done
        kill -TERM -- -"$socket_deadline_pid" 2>/dev/null || true
        wait "$socket_deadline_pid" 2>/dev/null || true
    fi
    printf '%s\n' "$socket_list" | while IFS= read -r socket; do
        [ -n "$socket" ] || continue
        rm -f "$socket"
    done
}

run_tmux_pids() {
    run_id=$1
    run_dir=$2
    ps -axo pid=,command= | awk -v run_id="$run_id" \
        -v run_dir="$run_dir" '
        BEGIN {
            socket_pattern = "^(ghosthub|gh)-[A-Za-z0-9-]+-" run_id "$"
        }
        /^[[:space:]]*[0-9]+[[:space:]]+([^[:space:]]*\/)?tmux[[:space:]]/ {
            for (field = 2; field < NF; field++) {
                socket_path = $(field + 1)
                if (($field == "-L" && $(field + 1) ~ socket_pattern) ||
                    ($field == "-S" &&
                     index(socket_path, run_dir "/") == 1 &&
                     socket_path !~ /(^|\/)\.\.(\/|$)/)) {
                    print $1
                    break
                }
            }
        }
    '
}

signal_pids() {
    signal=$1
    pid_list=$2
    printf '%s\n' "$pid_list" | while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        kill "-$signal" "$pid" 2>/dev/null || true
    done
}

kill_run_tmux_processes() {
    run_id=$1
    run_dir=$2
    pids=$(run_tmux_pids "$run_id" "$run_dir")
    if [ -n "$pids" ]; then
        signal_pids TERM "$pids"
        sleep 1
    fi

    pids=$(run_tmux_pids "$run_id" "$run_dir")
    if [ -n "$pids" ]; then
        signal_pids KILL "$pids"
    fi
}

purge_run_directory() {
    directory=$1
    run_id=${directory##*.}
    # A tmux server daemonizes outside the test process group and can
    # outlive an externally removed run directory, so process cleanup for
    # the validated run identity happens even when the directory is gone.
    if [ ! -d "$directory" ] && [ ! -L "$directory" ]; then
        kill_run_tmux_processes "$run_id" "$directory"
        return 0
    fi
    if ! require_secure_directory "$directory" "tmux test run" 2>/dev/null; then
        # A concurrent sweep may remove the same dead run directory at any
        # point during validation, while a directory that remains insecure
        # is still refused.
        if [ ! -d "$directory" ] && [ ! -L "$directory" ]; then
            kill_run_tmux_processes "$run_id" "$directory"
            return 0
        fi
        echo "refusing insecure tmux test run directory: $directory" >&2
        return 1
    fi
    run_sockets=$(find "$directory" -type s -print 2>/dev/null || true)
    kill_sockets "$run_sockets"
    kill_run_tmux_processes "$run_id" "$directory"
    rm -rf "$directory"
}

if [ "$mode" = run ]; then
    require_secure_directory "$user_tmpdir" "user temporary"
    require_secure_directory "$test_root" "tmux test root"
    purge_run_directory "$run_dir"
    exit 0
fi

if [ -e "$user_tmpdir" ] || [ -L "$user_tmpdir" ]; then
    require_secure_directory "$user_tmpdir" "user temporary"
fi

if [ -e "$test_root" ] || [ -L "$test_root" ]; then
    require_secure_directory "$test_root" "tmux test root"
    find "$test_root" -mindepth 1 -maxdepth 1 -type d \
        -name 'run.*.??????' -print |
        while IFS= read -r directory; do
            # A live owner PID marks an active run. Never purge one out from
            # under a concurrent test invocation, in any mode.
            run_name=$(basename -- "$directory")
            owner_pid=${run_name#run.}
            owner_pid=${owner_pid%%.*}
            case "$owner_pid" in
                '' | *[!0-9]*) continue ;;
                *)
                    if kill -0 "$owner_pid" 2>/dev/null; then
                        continue
                    fi
                    ;;
            esac
            purge_run_directory "$directory"
        done
fi

if [ "$mode" = stale ]; then
    exit 0
fi

if [ -e "$legacy_socket_root" ] || [ -L "$legacy_socket_root" ]; then
    require_secure_directory "$legacy_socket_root" "legacy tmux socket"
    legacy_sockets=$(
        find "$legacy_socket_root" -mindepth 1 -maxdepth 1 -type s -print \
            2>/dev/null |
            awk -F/ '
                $NF ~ /^ghosthub-(test|kill)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
            '
    )
    kill_sockets "$legacy_sockets"
fi

legacy_test_tmux_pids() {
    ps -axo pid=,command= | awk '
        /^[[:space:]]*[0-9]+[[:space:]]+([^[:space:]]*\/)?tmux[[:space:]]/ &&
        /-L[[:space:]]+ghosthub-(test|kill)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}([[:space:]]|$)/ {
            print $1
        }
    '
}

pids=$(legacy_test_tmux_pids)
if [ -n "$pids" ]; then
    signal_pids TERM "$pids"
    sleep 1
fi

pids=$(legacy_test_tmux_pids)
if [ -n "$pids" ]; then
    signal_pids KILL "$pids"
fi
