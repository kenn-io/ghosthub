# shellcheck shell=bash
# Shared macOS ownership, mode, and ACL checks for directories that hold
# security-sensitive demo state.
demo_acl_write_guard() {
  local guarded="$1" label="$2"
  local username uid listing line subject action rights acl_pattern
  username="$(id -un)"
  uid="$(id -u)"
  listing="$(LC_ALL=C ls -lde "$guarded" 2>/dev/null)" || {
    echo "error: cannot inspect ACLs on $label $guarded; refusing" >&2
    return 1
  }
  acl_pattern='^[[:space:]]*[0-9]+:[[:space:]]+([^[:space:]]+)[[:space:]]+(inherited[[:space:]]+)?(allow|deny)[[:space:]]+(.+)$'
  while IFS= read -r line; do
    if [[ ! "$line" =~ ^[[:space:]]*[0-9]+: ]]; then
      continue
    fi
    if [[ ! "$line" =~ $acl_pattern ]]; then
      echo "error: cannot parse ACL on $label $guarded; refusing" >&2
      return 1
    fi
    subject="${BASH_REMATCH[1]}"
    action="${BASH_REMATCH[3]}"
    rights="${BASH_REMATCH[4]}"
    [[ "$action" == "allow" ]] || continue
    case "$subject" in
      "user:$username" | "user:$uid" | "user:root" | "user:0")
        continue
        ;;
    esac
    if [[ "$rights" =~ (^|,)(write|append|delete|writeattr|writeextattr|writesecurity|chown|add_file|add_subdirectory|delete_child)(,|$) ]]; then
      echo "error: $label $guarded grants $subject write-capable ACL rights;" >&2
      echo "       another user could replace demo state; refusing" >&2
      return 1
    fi
  done <<< "$listing"
}

demo_lexical_ancestry_guard() {
  local start="$1" sticky_policy="$2" label="$3"
  local rest component current uid owner mode group_w other_w dtype
  [[ "$start" == /* ]] || {
    echo "error: $label must be an absolute path: $start; refusing" >&2
    return 1
  }
  uid="$(id -u)"
  rest="${start#/}"
  current="/"
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
    [[ -z "$component" ]] && continue
    if [[ "$component" == "." || "$component" == ".." ]]; then
      echo "error: $label contains $component; refusing" >&2
      return 1
    fi
    if [[ "$current" == "/" ]]; then
      current="/$component"
    else
      current="$current/$component"
    fi
    if [[ ! -e "$current" && ! -L "$current" ]]; then
      echo "error: $label $current does not exist; refusing" >&2
      return 1
    fi
    owner="$(stat -f %u "$current")"
    dtype="$(stat -f %HT "$current")"
    if [[ "$owner" != 0 && "$owner" != "$uid" ]]; then
      echo "error: $label $current is owned by uid $owner; refusing" >&2
      return 1
    fi
    if [[ "$dtype" != "Directory" && "$dtype" != "Symbolic Link" ]]; then
      echo "error: $label $current is not a directory or symlink; refusing" >&2
      return 1
    fi
    demo_acl_write_guard "$current" "$label" || return 1
    if [[ "$dtype" == "Directory" ]]; then
      mode="$(stat -f %Lp "$current")"
      group_w="${mode: -2:1}"
      other_w="${mode: -1}"
      if [[ "$group_w" == [2367] || "$other_w" == [2367] ]]; then
        if [[ "$sticky_policy" != "allow-sticky" || ! -k "$current" ]]; then
          echo "error: $label $current is writable by other users; refusing" >&2
          return 1
        fi
      fi
    fi
  done
}

demo_directory_ancestry_guard() {
  local start="$1" sticky_policy="$2" label="$3"
  local dir uid owner mode group_w other_w
  uid="$(id -u)"
  dir="$(realpath "$start" 2>/dev/null)" || {
    echo "error: cannot resolve $label $start; refusing" >&2
    return 1
  }
  while :; do
    if [[ ! -d "$dir" ]]; then
      echo "error: $label $dir is not a directory; refusing" >&2
      return 1
    fi
    owner="$(stat -f %u "$dir")"
    mode="$(stat -f %Lp "$dir")"
    if [[ "$owner" != 0 && "$owner" != "$uid" ]]; then
      echo "error: $label $dir is owned by uid $owner; refusing" >&2
      return 1
    fi
    group_w="${mode: -2:1}"
    other_w="${mode: -1}"
    if [[ "$group_w" == [2367] || "$other_w" == [2367] ]]; then
      if [[ "$sticky_policy" != "allow-sticky" || ! -k "$dir" ]]; then
        echo "error: $label $dir is writable by other users; refusing" >&2
        return 1
      fi
    fi
    demo_acl_write_guard "$dir" "$label" || return 1
    [[ "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
}

demo_owner_file_guard() {
  local guarded="$1" label="$2"
  local uid owner mode group_w other_w
  [[ -f "$guarded" ]] || {
    echo "error: $label $guarded is not a regular file; refusing" >&2
    return 1
  }
  uid="$(id -u)"
  owner="$(stat -f %u "$guarded")"
  mode="$(stat -f %Lp "$guarded")"
  if [[ "$owner" != "$uid" ]]; then
    echo "error: $label $guarded is owned by uid $owner, not uid $uid; refusing" >&2
    return 1
  fi
  group_w="${mode: -2:1}"
  other_w="${mode: -1}"
  if [[ "$group_w" == [2367] || "$other_w" == [2367] ]]; then
    echo "error: $label $guarded is writable by other users; refusing" >&2
    return 1
  fi
  demo_acl_write_guard "$guarded" "$label" || return 1
}
