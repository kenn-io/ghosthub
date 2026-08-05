# shellcheck shell=bash
# Track only the demo process we launched. Process-table regex searches are
# unsafe because custom scratch paths can contain regex metacharacters.
demo_pid_value() {
  local record="$1" pid
  if [[ ! -f "$record" || -L "$record" ]]; then
    echo "error: demo PID record is missing or invalid: $record" >&2
    return 1
  fi
  pid="$(cat "$record")"
  if [[ ! "$pid" =~ ^[0-9]+$ || "$pid" == 0 ]]; then
    echo "error: invalid demo PID in $record" >&2
    return 1
  fi
  printf '%s\n' "$pid"
}

demo_pid_executable() {
  local pid="$1"
  /usr/bin/swift - "$pid" <<'SWIFT'
import Darwin

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1])
else { exit(1) }
var buffer = [CChar](repeating: 0, count: 4096)
guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { exit(1) }
print(String(cString: buffer))
SWIFT
}

demo_require_recorded_process() {
  local record="$1" expected="$2" pid actual
  expected="$(realpath "$expected" 2>/dev/null)" || {
    echo "error: cannot resolve expected demo executable: $expected" >&2
    return 1
  }
  pid="$(demo_pid_value "$record")" || return 1
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "error: recorded demo process $pid is not running" >&2
    return 1
  fi
  actual="$(demo_pid_executable "$pid")" || {
    echo "error: cannot inspect recorded demo process $pid" >&2
    return 1
  }
  if [[ "$actual" != "$expected" ]]; then
    echo "error: PID $pid runs $actual, expected $expected; refusing" >&2
    return 1
  fi
  printf '%s\n' "$pid"
}

demo_record_process() {
  local pid="$1" record="$2" expected="$3" tmp actual
  expected="$(realpath "$expected" 2>/dev/null)" || return 1
  actual=""
  for _ in $(seq 1 20); do
    actual="$(demo_pid_executable "$pid" 2>/dev/null)" || true
    [[ "$actual" == "$expected" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  [[ -n "$actual" ]] || {
    echo "error: launched demo process $pid exited before it could be recorded" >&2
    return 1
  }
  if [[ "$actual" != "$expected" ]]; then
    echo "error: launched PID $pid runs $actual, expected $expected; refusing" >&2
    return 1
  fi
  tmp="$(mktemp "$record.tmp.XXXXXX")" || return 1
  printf '%s\n' "$pid" > "$tmp"
  mv -f "$tmp" "$record"
}

demo_stop_recorded_process() {
  local record="$1" expected="$2" pid actual
  [[ -e "$record" || -L "$record" ]] || return 0
  expected="$(realpath "$expected" 2>/dev/null)" || {
    echo "error: cannot resolve expected demo executable: $expected" >&2
    return 1
  }
  pid="$(demo_pid_value "$record")" || return 1
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$record"
    return 0
  fi
  actual="$(demo_pid_executable "$pid")" || {
    echo "error: cannot inspect recorded demo process $pid; refusing to signal it" >&2
    return 1
  }
  if [[ "$actual" != "$expected" ]]; then
    echo "error: PID $pid runs $actual, expected $expected; refusing to signal it" >&2
    return 1
  fi
  kill "$pid"
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$record"
      return 0
    fi
    sleep 0.1
  done
  echo "error: demo process $pid did not exit; preserving PID record and scratch" >&2
  return 1
}

demo_stop_retained_launches() {
  local scratch="$1" expected="$2" launch_dir record
  local launch_dirs=("$scratch"/.launch.*)
  for launch_dir in "${launch_dirs[@]}"; do
    [[ -e "$launch_dir" || -L "$launch_dir" ]] || continue
    if [[ ! -d "$launch_dir" || -L "$launch_dir" ]]; then
      echo "error: invalid retained launch directory: $launch_dir" >&2
      return 1
    fi
    record="$launch_dir/app.pid"
    demo_stop_recorded_process "$record" "$expected" || return 1
    if ! rmdir "$launch_dir"; then
      echo "error: retained launch state remains in $launch_dir; preserving scratch" >&2
      return 1
    fi
  done
}
