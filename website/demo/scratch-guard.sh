# shellcheck shell=bash
# Sourced by stage.sh, run.sh, and teardown.sh. The scratch path is
# predictable (/tmp/ghosthub-demo) and run.sh loads a dylib from it via
# DYLD_INSERT_LIBRARIES, so a directory another local user controls would
# let them run code as us. Refuse anything that is not an owner-only
# directory we own.
# shellcheck source=SCRIPTDIR/path-guard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/path-guard.sh"

demo_private_directory_guard() {
  local guarded="$1"
  local label="$2"
  local risk="$3"
  local allow_missing="${4:-}"
  if [[ "$guarded" != /* ]]; then
    echo "error: $label must be an absolute path; refusing $guarded" >&2
    return 1
  fi
  # -L before -e: -e follows symlinks and reports false for a dangling
  # one, which would let a planted symlink pass as "nothing there" and
  # have its target raced into existence later.
  if [[ -L "$guarded" ]]; then
    echo "error: $guarded is a symlink; refusing" >&2
    return 1
  fi
  # Validate lexical components before resolving them. realpath alone would
  # hide a planted symlink. (/tmp is a root-owned symlink on macOS.)
  local parent
  parent="$(dirname "$guarded")"
  demo_lexical_ancestry_guard \
    "$parent" allow-sticky "$label ancestor" || return 1

  # Also validate the physical hierarchy reached through trusted symlinks.
  demo_directory_ancestry_guard \
    "$parent" allow-sticky "$label ancestor" || return 1
  if [[ ! -e "$guarded" ]]; then
    if [[ "$allow_missing" == "allow-missing" ]]; then
      return 0
    fi
    echo "error: $guarded disappeared or was never created; refusing" >&2
    return 1
  fi
  if [[ ! -d "$guarded" ]]; then
    echo "error: $guarded is not a plain directory; refusing" >&2
    return 1
  fi
  local owner mode
  owner="$(stat -f %u "$guarded")"
  mode="$(stat -f %Lp "$guarded")"
  if [[ "$owner" != "$(id -u)" ]]; then
    echo "error: $guarded is owned by uid $owner, not uid $(id -u); refusing" >&2
    return 1
  fi
  if [[ "$mode" != 700 ]]; then
    echo "error: $guarded has mode $mode, expected 700; refusing" >&2
    echo "       (another local user may be able to $risk)" >&2
    return 1
  fi
  demo_acl_write_guard "$guarded" "$label" || return 1
}

demo_private_directory_prepare() {
  local guarded="$1"
  local label="$2"
  local risk="$3"
  demo_private_directory_guard \
    "$guarded" "$label" "$risk" allow-missing || return 1
  if [[ ! -e "$guarded" ]]; then
    if mkdir -m 700 "$guarded" 2>/dev/null; then
      chmod -N "$guarded"
      chmod 700 "$guarded"
    fi
  fi
  # If another process won the mkdir race, validate what it created rather
  # than accepting it. Sticky /tmp plus an owner-only directory prevents a
  # less-privileged user from replacing the entry after this check.
  demo_private_directory_guard "$guarded" "$label" "$risk"
}

demo_scratch_guard() {
  demo_private_directory_guard \
    "$1" "demo scratch" "modify demo binaries" "${2:-}"
}
