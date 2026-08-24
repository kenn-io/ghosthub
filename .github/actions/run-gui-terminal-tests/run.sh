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
launcher_bootstrap="$launcher_app/Contents/MacOS/launcher"
launcher_library="$launcher_app/Contents/MacOS/test-launcher.dylib"
launcher_info="$launcher_app/Contents/Info.plist"
launch_controller="$launcher_root/launch-controller"
launcher_bundle_identifier="io.kenn.ghosthub-ci-gui-launcher.$(/usr/bin/uuidgen)"
launcher_pid_file="$launcher_root/launcher.pid"
launcher_output="$launcher_root/test-output.log"
result_file="$launcher_root/result"
completion_file="$launcher_root/completion"
xctest_frameworks="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
xctest_libraries="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"
test_bundle="$(swift build --show-bin-path)/GhosthubPackageTests.xctest"
ghostty_resources="$GITHUB_WORKSPACE/.build/libghostty/share/ghostty"
ghostty_terminfo="$GITHUB_WORKSPACE/.build/libghostty/share/terminfo/78/xterm-ghostty"
user_tmpdir="/tmp/ghosthub-$(id -u)"
test_root="$user_tmpdir/tmux-tests"
controller_pid=
controller_starting=0
cleanup_started=0
signal_status=
tmux_tmpdir=

if [[ ! -d "$test_bundle" ]]; then
  echo "The built XCTest bundle is unavailable: $test_bundle" >&2
  exit 1
fi
if [[ ! -d "$ghostty_resources" || ! -f "$ghostty_terminfo" ]]; then
  echo "The staged libghostty resources are unavailable." >&2
  exit 1
fi

umask 077
mkdir -m 700 "$user_tmpdir" 2>/dev/null || true
sh "$GITHUB_WORKSPACE/tools/purge_test_tmux.sh" --stale
mkdir -m 700 "$test_root" 2>/dev/null || true
sh "$GITHUB_WORKSPACE/tools/purge_test_tmux.sh" --stale
tmux_tmpdir="$(mktemp -d "$test_root/run.$$.XXXXXX")"
test_run_id=${tmux_tmpdir##*.}
export TMUX_TMPDIR="$tmux_tmpdir"
export GHOSTHUB_TEST_TMUX_RUN_ID="$test_run_id"
export GHOSTTY_RESOURCES_DIR="$ghostty_resources"

# shellcheck disable=SC2329  # invoked by stop_launcher below
verified_launcher_signal() {
  local launcher_pid=$1
  local signal_number=$2
  "$launch_controller" signal-launcher \
    "$launcher_bundle_identifier" "$launcher_app" \
    "$launcher_pid" "$signal_number"
}

# shellcheck disable=SC2329  # invoked by stop_launcher below
retained_group_signal() {
  local launcher_pid=$1
  local signal_number=$2
  "$launch_controller" signal-process-group "$launcher_pid" "$signal_number"
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
      if retained_group_signal "$launcher_pid" 0; then
        :
      else
        launcher_signal_status=$?
        if (( launcher_signal_status == 3 )); then
          rm -f -- "$launcher_pid_file"
          return 0
        fi
        echo "Could not inspect the serialized GUI test process group." >&2
        return 1
      fi
    else
      echo "Could not authenticate the serialized GUI test launcher." >&2
      return 1
    fi
  fi

  if retained_group_signal "$launcher_pid" 15; then
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
    if retained_group_signal "$launcher_pid" 0; then
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
  if retained_group_signal "$launcher_pid" 9; then
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
    if retained_group_signal "$launcher_pid" 0; then
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
  if [[ -n "$tmux_tmpdir" ]]; then
    sh "$GITHUB_WORKSPACE/tools/purge_test_tmux.sh" "$tmux_tmpdir" || true
  fi
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
plutil -insert CFBundleIdentifier -string "$launcher_bundle_identifier" "$launcher_info"
plutil -insert CFBundleName -string GhosthubGUITestLauncher "$launcher_info"
plutil -insert CFBundlePackageType -string APPL "$launcher_info"
plutil -insert NSPrincipalClass -string NSApplication "$launcher_info"

/usr/bin/xcrun swiftc -O \
  -framework AppKit \
  -F "$xctest_frameworks" -framework XCTest \
  -L "$xctest_libraries" \
  -Xlinker -rpath -Xlinker "$xctest_frameworks" \
  -Xlinker -rpath -Xlinker "$xctest_libraries" \
  -emit-library \
  "$action_root/ActivationPolicy.swift" \
  "$action_root/LaunchApp.swift" \
  -o "$launcher_library"
chmod 700 "$launcher_library"
/usr/bin/xcrun swiftc -O -framework AppKit \
  "$action_root/LaunchBootstrap.swift" -o "$launcher_bootstrap"
chmod 700 "$launcher_bootstrap"
codesign --force --sign - "$launcher_app"

/usr/bin/xcrun swiftc -O -framework AppKit \
  "$action_root/LauncherEnvironment.swift" \
  "$action_root/main.swift" \
  -o "$launch_controller"
chmod 700 "$launch_controller"

: > "$launcher_output"

controller_starting=1
set -m
"$launch_controller" \
  "$launcher_bundle_identifier" \
  "$launcher_app" \
  "$launcher_pid_file" \
  "$launcher_pid_file.ready" \
  "$result_file" \
  "$launcher_output" \
  "$test_bundle" \
  "$gui_test_filter" \
  "$GITHUB_WORKSPACE" \
  "$completion_file" &
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
