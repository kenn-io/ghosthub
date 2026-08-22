#!/bin/bash
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: run.sh test-filter" >&2
  exit 2
fi
gui_test_filter=$1

: "${RUNNER_TEMP:?}"
: "${GITHUB_WORKSPACE:?}"
: "${HOME:?}"
: "${TMPDIR:?}"
: "${CFFIXED_USER_HOME:?}"
: "${DEVELOPER_DIR:?}"
: "${GHOSTHUB_CI_STATE_ROOT:?}"
: "${LIBGHOSTTY_XCFRAMEWORK_TARGET:?}"
: "${LIBGHOSTTY_ZIG:?}"
: "${SHELL:?}"

action_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
launcher_root="$(mktemp -d "$RUNNER_TEMP/ghosthub-gui-launcher.XXXXXX")"
launcher_app="$launcher_root/GhosthubGUITestLauncher.app"
launcher_executable="$launcher_app/Contents/MacOS/launcher"
launcher_info="$launcher_app/Contents/Info.plist"
launcher_script="$action_root/run-tests.sh"
launch_controller="$launcher_root/launch-controller"
launcher_bundle_identifier="io.kenn.ghosthub-ci-gui-launcher.$(/usr/bin/uuidgen)"
launcher_pid_file="$launcher_root/launcher.pid"
launcher_output="$launcher_root/test-output.log"
launcher_stdout="$launcher_root/stdout.log"
launcher_stderr="$launcher_root/stderr.log"
result_file="$launcher_root/result"
controller_pid=
controller_starting=0
cleanup_started=0
signal_status=

test_arguments=(
  swift test --skip-build --disable-swift-testing
  --filter "$gui_test_filter" --no-parallel
)

# shellcheck disable=SC2329  # invoked by stop_launcher below
verified_launcher_signal() {
  local launcher_pid=$1
  local signal_number=$2
  "$launch_controller" signal-launcher \
    "$launcher_bundle_identifier" "$launcher_app" \
    "$launcher_pid" "$signal_number"
}

# shellcheck disable=SC2329  # invoked by cleanup_launcher below
stop_launcher() {
  if [[ ! -s "$launcher_pid_file" ]]; then
    return 0
  fi

  local launcher_pid
  launcher_pid="$(< "$launcher_pid_file")"
  if [[ ! "$launcher_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "Serialized GUI test launcher reported an invalid PID." >&2
    return 1
  fi
  local launcher_signal_status
  if verified_launcher_signal "$launcher_pid" 0; then
    :
  else
    launcher_signal_status=$?
    if (( launcher_signal_status == 3 )); then
      rm -f -- "$launcher_pid_file"
      return 0
    fi
    echo "Could not authenticate the serialized GUI test launcher." >&2
    return 1
  fi

  if verified_launcher_signal "$launcher_pid" 15; then
    :
  else
    launcher_signal_status=$?
    if (( launcher_signal_status == 3 )); then
      rm -f -- "$launcher_pid_file"
      return 0
    fi
    echo "Could not stop the serialized GUI test launcher." >&2
    return 1
  fi
  for _ in {1..10}; do
    if verified_launcher_signal "$launcher_pid" 0; then
      sleep 0.1
      continue
    fi
    launcher_signal_status=$?
    if (( launcher_signal_status == 3 )); then
      rm -f -- "$launcher_pid_file"
      return 0
    fi
    echo "Could not authenticate the serialized GUI test launcher." >&2
    return 1
  done
  if verified_launcher_signal "$launcher_pid" 9; then
    :
  else
    launcher_signal_status=$?
    if (( launcher_signal_status == 3 )); then
      rm -f -- "$launcher_pid_file"
      return 0
    fi
    echo "Could not kill the serialized GUI test launcher." >&2
    return 1
  fi
  for _ in {1..5}; do
    if verified_launcher_signal "$launcher_pid" 0; then
      sleep 0.1
      continue
    fi
    launcher_signal_status=$?
    if (( launcher_signal_status == 3 )); then
      rm -f -- "$launcher_pid_file"
      return 0
    fi
    echo "Could not authenticate the serialized GUI test launcher." >&2
    return 1
  done
  echo "Serialized GUI test launcher did not stop." >&2
  return 1
}

# shellcheck disable=SC2329  # invoked by cleanup_launcher below
stop_controller() {
  if [[ -z "$controller_pid" ]]; then
    return 0
  fi
  if kill -0 "$controller_pid" 2>/dev/null; then
    kill -TERM "$controller_pid" 2>/dev/null || true
    local published_grace=0
    while kill -0 "$controller_pid" 2>/dev/null; do
      # LaunchServices owns the request until its completion callback.
      # Do not abandon the controller before it publishes an identity.
      if [[ -s "$launcher_pid_file" ]]; then
        published_grace=$((published_grace + 1))
        if (( published_grace >= 40 )); then
          break
        fi
      fi
      sleep 0.1
    done
  fi
  if kill -0 "$controller_pid" 2>/dev/null; then
    if [[ ! -s "$launcher_pid_file" ]]; then
      echo "GUI launch completion returned without an identity." >&2
      return 1
    fi
    kill -KILL -- -"$controller_pid" 2>/dev/null ||
      kill -KILL "$controller_pid" 2>/dev/null || true
    for _ in {1..10}; do
      if ! kill -0 "$controller_pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
  fi
  wait "$controller_pid" 2>/dev/null || true
  controller_pid=
}

# shellcheck disable=SC2329  # invoked by the signal traps below
handle_signal() {
  local status=$1
  if [[ -z "$signal_status" ]]; then
    signal_status=$status
  fi
  if (( cleanup_started == 0 && controller_starting == 0 )); then
    exit "$signal_status"
  fi
}

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup_launcher() {
  local status=$?
  local stop_status=0
  cleanup_started=1
  set +e
  if [[ -n "$signal_status" ]]; then
    status=$signal_status
  fi
  stop_controller
  stop_launcher || stop_status=$?
  case "$launcher_root" in
    "$RUNNER_TEMP"/ghosthub-gui-launcher.*)
      rm -rf -- "$launcher_root"
      ;;
  esac
  if (( status == 0 && stop_status != 0 )); then
    status=$stop_status
  fi
  trap - EXIT INT TERM HUP
  exit "$status"
}
trap cleanup_launcher EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
trap 'handle_signal 129' HUP

mkdir -p "$launcher_app/Contents/MacOS"
plutil -create xml1 "$launcher_info"
plutil -insert CFBundleExecutable -string launcher "$launcher_info"
plutil -insert CFBundleIdentifier \
  -string "$launcher_bundle_identifier" "$launcher_info"
plutil -insert CFBundleName \
  -string GhosthubGUITestLauncher "$launcher_info"
plutil -insert CFBundlePackageType -string APPL "$launcher_info"

# The launcher is a real AppKit application so the LaunchServices completion
# callback returns its authenticated running identity.
/usr/bin/xcrun swiftc -O -framework AppKit \
  "$action_root/LaunchApp.swift" -o "$launcher_executable"
chmod 700 "$launcher_executable"
codesign --force --sign - "$launcher_app"

# The controller owns the LaunchServices completion callback and retains the
# application identity until authenticated termination.
/usr/bin/xcrun swiftc -O -framework AppKit \
  "$action_root/LaunchController.swift" -o "$launch_controller"
chmod 700 "$launch_controller"

: > "$launcher_output"
: > "$launcher_stdout"
: > "$launcher_stderr"

controller_starting=1
set -m
"$launch_controller" \
  "$launcher_bundle_identifier" \
  "$launcher_app" \
  "$launcher_pid_file" \
  "$launcher_stdout" \
  "$launcher_stderr" \
  "$launcher_script" \
  "$result_file" \
  "$launcher_output" \
  "$GITHUB_WORKSPACE" \
  "$PATH" \
  "$HOME" \
  "$TMPDIR" \
  "$CFFIXED_USER_HOME" \
  "$DEVELOPER_DIR" \
  "$GHOSTHUB_CI_STATE_ROOT" \
  "$LIBGHOSTTY_XCFRAMEWORK_TARGET" \
  "$LIBGHOSTTY_ZIG" \
  "${RUNNER_ENVIRONMENT:-}" \
  "$RUNNER_TEMP" \
  "$SHELL" \
  "${CI:-}" \
  "${GITHUB_ACTIONS:-}" \
  "${test_arguments[@]}" &
controller_pid=$!
set +m
controller_starting=0
if [[ -n "$signal_status" ]]; then
  exit "$signal_status"
fi
set +e
wait "$controller_pid"
controller_status=$?
set -e
controller_pid=
tee -a "$RUNNER_TEMP/gui-tests.log" < "$launcher_output"
cat "$launcher_stdout"
cat "$launcher_stderr" >&2
if (( controller_status != 0 )); then
  echo "Could not launch serialized GUI tests in the Aqua session." >&2
  exit "$controller_status"
fi
if [[ ! -f "$result_file" ]]; then
  echo "Serialized GUI test launcher did not report a result." >&2
  exit 1
fi
test_status="$(< "$result_file")"
if [[ ! "$test_status" =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]; then
  echo "Serialized GUI test launcher reported an invalid result." >&2
  exit 1
fi
exit "$test_status"
