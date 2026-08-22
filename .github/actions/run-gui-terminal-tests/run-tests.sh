#!/bin/bash
set -uo pipefail

ready_file=$1
shift
result_file=$1
launcher_output=$2
workspace=$3
runner_path=$4
runner_home=$5
runner_tmpdir=$6
fixed_user_home=$7
developer_dir=$8
state_root=$9
xcframework_target=${10}
zig=${11}
runner_environment=${12}
runner_temp=${13}
runner_shell=${14}
ci=${15}
github_actions=${16}
shift 16

test_pid=
pending_signal=
signal_status=
forward_signal() {
  local signal=$1
  pending_signal=$signal
  case "$signal" in
    INT) signal_status=130 ;;
    TERM) signal_status=143 ;;
    HUP) signal_status=129 ;;
  esac
  if [[ -n "$test_pid" ]]; then
    kill -"$signal" "$test_pid" 2>/dev/null || true
  fi
}
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM
trap 'forward_signal HUP' HUP

while [[ ! -e "$ready_file" ]]; do
  sleep 0.01
done
if [[ -n "$signal_status" ]]; then
  printf '%s\n' "$signal_status" > "$result_file.tmp"
  mv -- "$result_file.tmp" "$result_file"
  exit "$signal_status"
fi

export PATH=$runner_path
export HOME=$runner_home
export TMPDIR=$runner_tmpdir
export CFFIXED_USER_HOME=$fixed_user_home
export DEVELOPER_DIR=$developer_dir
export GHOSTHUB_CI_STATE_ROOT=$state_root
export LIBGHOSTTY_XCFRAMEWORK_TARGET=$xcframework_target
export LIBGHOSTTY_ZIG=$zig
export RUNNER_ENVIRONMENT=$runner_environment
export RUNNER_TEMP=$runner_temp
export SHELL=$runner_shell
export CI=$ci
export GITHUB_ACTIONS=$github_actions
export GHOSTHUB_TEST_STOP_GRACE=2

cd -- "$workspace"
sh tools/run_swift_tests.sh "$@" > "$launcher_output" 2>&1 &
test_pid=$!
if [[ -n "$signal_status" ]]; then
  forward_signal "$pending_signal"
fi

set +e
while :; do
  wait "$test_pid"
  test_status=$?
  if ! kill -0 "$test_pid" 2>/dev/null; then
    break
  fi
done
set -e
if [[ -n "$signal_status" ]]; then
  test_status=$signal_status
fi
printf '%s\n' "$test_status" > "$result_file.tmp"
mv -- "$result_file.tmp" "$result_file"
exit "$test_status"
