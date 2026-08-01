#!/bin/sh

set -eu

test_root=/tmp/ghosthub-tmux-tests
legacy_socket_root="/tmp/tmux-$(id -u)"
tmux_bin=$(command -v tmux || true)
mode=all
run_dir=

if [ -L "$test_root" ]; then
    echo "refusing to use symlinked tmux test root: $test_root" >&2
    exit 2
fi

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
            ! printf '%s\n' "$run_name" | grep -Eq '^run\.[A-Za-z0-9]{6}$'
        then
            echo "refusing to purge unexpected tmux test directory: $run_dir" >&2
            exit 2
        fi
    fi
fi

kill_socket() {
    socket=$1
    socket_name=$(basename -- "$socket")
    if [ -n "$tmux_bin" ]; then
        "$tmux_bin" -S "$socket" kill-server >/dev/null 2>&1 || true
    fi
    rm -f "$socket"
    kill_named_tmux_processes "$socket_name"
}

named_tmux_pids() {
    socket_name=$1
    ps -axo pid=,command= | awk -v socket_name="$socket_name" '
        /^[[:space:]]*[0-9]+[[:space:]]+([^[:space:]]*\/)?tmux[[:space:]]/ {
            for (field = 2; field < NF; field++) {
                if ($field == "-L" && $(field + 1) == socket_name) {
                    print $1
                    break
                }
            }
        }
    '
}

kill_named_tmux_processes() {
    socket_name=$1
    pids=$(named_tmux_pids "$socket_name")
    if [ -n "$pids" ]; then
        kill -TERM $pids 2>/dev/null || true
        sleep 1
    fi

    pids=$(named_tmux_pids "$socket_name")
    if [ -n "$pids" ]; then
        kill -KILL $pids 2>/dev/null || true
    fi
}

purge_run_directory() {
    directory=$1
    [ -d "$directory" ] || return 0
    find "$directory" -type s -print | while IFS= read -r socket; do
        kill_socket "$socket"
    done
    kill_run_tmux_processes "${directory##*.}"
    rm -rf "$directory"
}

run_tmux_pids() {
    run_id=$1
    ps -axo pid=,command= | awk -v run_id="$run_id" '
        BEGIN {
            socket_pattern = "^ghosthub-(test|kill|style|ready)-" run_id "$"
        }
        /^[[:space:]]*[0-9]+[[:space:]]+([^[:space:]]*\/)?tmux[[:space:]]/ {
            for (field = 2; field < NF; field++) {
                if ($field == "-L" && $(field + 1) ~ socket_pattern) {
                    print $1
                    break
                }
            }
        }
    '
}

kill_run_tmux_processes() {
    run_id=$1
    pids=$(run_tmux_pids "$run_id")
    if [ -n "$pids" ]; then
        kill -TERM $pids 2>/dev/null || true
        sleep 1
    fi

    pids=$(run_tmux_pids "$run_id")
    if [ -n "$pids" ]; then
        kill -KILL $pids 2>/dev/null || true
    fi
}

if [ "$mode" = run ]; then
    purge_run_directory "$run_dir"
    exit 0
fi

if [ -d "$test_root" ]; then
    find "$test_root" -mindepth 1 -maxdepth 1 -type d -name 'run.??????' -print |
        while IFS= read -r directory; do
            if [ "$mode" = stale ]; then
                owner_pid=$(cat "$directory/owner.pid" 2>/dev/null || true)
                case "$owner_pid" in
                    '' | *[!0-9]*) ;;
                    *)
                        if kill -0 "$owner_pid" 2>/dev/null; then
                            continue
                        fi
                        ;;
                esac
            fi
            purge_run_directory "$directory"
        done
    rmdir "$test_root" 2>/dev/null || true
fi

if [ "$mode" = stale ]; then
    exit 0
fi

if [ -d "$legacy_socket_root" ]; then
    find "$legacy_socket_root" -mindepth 1 -maxdepth 1 -type s -print |
        awk -F/ '
            $NF ~ /^ghosthub-(test|kill|style|ready)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
        ' |
        while IFS= read -r socket; do
            kill_socket "$socket"
        done
fi

test_tmux_pids() {
    ps -axo pid=,command= | awk '
        /^[[:space:]]*[0-9]+[[:space:]]+([^[:space:]]*\/)?tmux[[:space:]]/ &&
        /-L[[:space:]]+ghosthub-(test|kill|style|ready)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}([[:space:]]|$)/ {
            print $1
        }
    '
}

pids=$(test_tmux_pids)
if [ -n "$pids" ]; then
    kill -TERM $pids 2>/dev/null || true
    sleep 1
fi

pids=$(test_tmux_pids)
if [ -n "$pids" ]; then
    kill -KILL $pids 2>/dev/null || true
fi
