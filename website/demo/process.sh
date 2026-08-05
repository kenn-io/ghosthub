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

demo_pids_for_executable() {
  local expected="$1"
  /usr/bin/swift - "$expected" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(1) }
let expected = URL(fileURLWithPath: CommandLine.arguments[1])
    .resolvingSymlinksInPath().standardizedFileURL.path
for application in NSWorkspace.shared.runningApplications {
    guard let executable = application.executableURL?
        .resolvingSymlinksInPath().standardizedFileURL.path,
        executable == expected
    else { continue }
    print(application.processIdentifier)
}
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
