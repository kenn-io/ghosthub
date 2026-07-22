# shellcheck shell=bash
# Replace one host's entries through a same-directory temporary file so
# ssh-keygen can create its automatic .old beside the temporary copy, never
# over the user's real known_hosts.old. The final rename is atomic.
# shellcheck source=SCRIPTDIR/path-guard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/path-guard.sh"

demo_known_hosts_save() {
  local host="$1" backup="$2"
  local known_hosts="${3:-$HOME/.ssh/known_hosts}"
  local tmp errors output status
  if [[ -e "$backup" || -L "$backup" ]]; then
    echo "error: known_hosts backup already exists: $backup" >&2
    return 1
  fi
  tmp="$(mktemp "$backup.tmp.XXXXXX")" || return 1
  errors="$tmp.errors"
  : > "$errors"

  if [[ ! -e "$known_hosts" ]]; then
    : > "$tmp"
  else
    if [[ ! -f "$known_hosts" || ! -r "$known_hosts" ]]; then
      echo "error: cannot read known_hosts for backup: $known_hosts" >&2
      rm -f "$tmp" "$errors"
      return 1
    fi
    status=0
    output="$(ssh-keygen -F "$host" -f "$known_hosts" 2>"$errors")" || status=$?
    if [[ "$status" != 0 ]]; then
      # OpenSSH uses 1 for a clean no-match. Any diagnostic, partial output,
      # or other status means the backup query itself failed.
      if [[ "$status" != 1 || -s "$errors" || -n "$output" ]]; then
        echo "error: failed to query $known_hosts for $host; backup not published" >&2
        [[ -s "$errors" ]] && sed 's/^/       /' "$errors" >&2
        rm -f "$tmp" "$errors"
        return 1
      fi
    fi
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output" | sed '/^#/d' > "$tmp"
    else
      : > "$tmp"
    fi
  fi

  rm -f "$errors"
  if ! mv -f "$tmp" "$backup"; then
    rm -f "$tmp"
    return 1
  fi
}

demo_known_hosts_replace() {
  local host="$1"
  local additions="$2"
  local known_hosts="${3:-$HOME/.ssh/known_hosts}"
  local destination configured_dir ssh_dir tmp work work_old owner uid original_mode last_byte
  if [[ "$known_hosts" != /* ]]; then
    echo "error: known_hosts must be an absolute path: $known_hosts" >&2
    return 1
  fi
  demo_lexical_ancestry_guard \
    "$(dirname "$known_hosts")" reject-writable "known_hosts ancestor" || return 1
  configured_dir="$(realpath "$(dirname "$known_hosts")" 2>/dev/null)" || {
    echo "error: cannot resolve known_hosts directory: $known_hosts" >&2
    return 1
  }
  demo_directory_ancestry_guard \
    "$configured_dir" reject-writable "known_hosts ancestor" || return 1

  destination="$known_hosts"
  if [[ -L "$known_hosts" ]]; then
    uid="$(id -u)"
    owner="$(stat -f %u "$known_hosts")"
    if [[ "$owner" != "$uid" ]]; then
      echo "error: known_hosts symlink is owned by uid $owner, not uid $uid; refusing" >&2
      return 1
    fi
    demo_acl_write_guard "$known_hosts" "known_hosts symlink" || return 1
    destination="$(realpath "$known_hosts" 2>/dev/null)" || {
      echo "error: known_hosts symlink has no regular-file target: $known_hosts" >&2
      return 1
    }
    if [[ ! -f "$destination" ]]; then
      echo "error: known_hosts symlink target is not a file: $destination" >&2
      return 1
    fi
  else
    destination="$configured_dir/$(basename "$known_hosts")"
  fi

  # Create beside the resolved target: mv then replaces that file atomically
  # without replacing the user's symlink.
  ssh_dir="$(dirname "$destination")"
  if [[ ! -d "$ssh_dir" ]]; then
    echo "error: SSH directory $ssh_dir does not exist" >&2
    return 1
  fi
  # Every later operation reopens a temporary file by pathname. That is safe
  # only when no other account can replace directory entries anywhere in the
  # resolved hierarchy.
  demo_directory_ancestry_guard \
    "$ssh_dir" reject-writable "known_hosts ancestor" || return 1
  if [[ -e "$destination" ]]; then
    demo_owner_file_guard "$destination" "known_hosts target" || return 1
  fi

  tmp="$(mktemp "$ssh_dir/.ghosthub-known-hosts.XXXXXX")" || return 1
  # -p preserves the existing target's mode, ownership, flags, ACLs, and
  # extended attributes on macOS. Keep the copy owner-writable while building
  # new contents, then restore its original mode immediately before rename.
  if [[ -f "$destination" ]] && ! cp -p "$destination" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -f "$destination" ]]; then
    original_mode="$(stat -f %Lp "$destination")"
    if ! chmod u+w "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  fi
  work="$(mktemp "$ssh_dir/.ghosthub-known-hosts-work.XXXXXX")" || {
    rm -f "$tmp"
    return 1
  }
  work_old="$work.old"
  if ! cat "$tmp" > "$work"; then
    rm -f "$tmp" "$work"
    return 1
  fi
  # ssh-keygen rewrites its input and can strip metadata, so let it mutate the
  # disposable work file and copy only the resulting bytes back into tmp.
  if ! ssh-keygen -R "$host" -f "$work" >/dev/null 2>&1; then
    rm -f "$tmp" "$work" "$work_old"
    return 1
  fi
  rm -f "$work_old"
  if ! cat "$work" > "$tmp"; then
    rm -f "$tmp" "$work"
    return 1
  fi
  rm -f "$work"
  if [[ -s "$additions" ]]; then
    if [[ -s "$tmp" ]]; then
      last_byte="$(tail -c 1 "$tmp" | od -An -tuC | tr -d '[:space:]')"
      [[ "$last_byte" == 10 ]] || printf '\n' >> "$tmp"
    fi
    if ! cat "$additions" >> "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  fi
  if [[ -n "${original_mode:-}" ]] && ! chmod "$original_mode" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi
}
