# shellcheck shell=bash
# Sourced by stage.sh, run.sh, and teardown.sh. The scratch path is
# predictable (/tmp/ghosthub-demo) and run.sh loads a dylib from it via
# DYLD_INSERT_LIBRARIES, so a directory another local user controls would
# let them run code as us. Refuse anything that is not an owner-only
# directory we own.
# shellcheck source=SCRIPTDIR/path-guard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/path-guard.sh"

demo_scratch_guard() {
  local scratch="$1"
  local allow_missing="${2:-}"
  if [[ "$scratch" != /* ]]; then
    echo "error: demo scratch must be an absolute path; refusing $scratch" >&2
    return 1
  fi
  # -L before -e: -e follows symlinks and reports false for a dangling
  # one, which would let a planted symlink pass as "nothing there" and
  # have its target raced into existence later.
  if [[ -L "$scratch" ]]; then
    echo "error: $scratch is a symlink; refusing" >&2
    return 1
  fi
  # Validate lexical components before resolving them. realpath alone would
  # hide a planted symlink. (/tmp is a root-owned symlink on macOS.)
  local parent
  parent="$(dirname "$scratch")"
  demo_lexical_ancestry_guard \
    "$parent" allow-sticky "scratch ancestor" || return 1

  # Also validate the physical hierarchy reached through trusted symlinks.
  demo_directory_ancestry_guard "$parent" allow-sticky "scratch ancestor" || return 1
  if [[ ! -e "$scratch" ]]; then
    if [[ "$allow_missing" == "allow-missing" ]]; then
      return 0
    fi
    echo "error: $scratch disappeared or was never created; refusing" >&2
    return 1
  fi
  if [[ ! -d "$scratch" ]]; then
    echo "error: $scratch is not a plain directory; refusing" >&2
    return 1
  fi
  local owner mode
  owner="$(stat -f %u "$scratch")"
  mode="$(stat -f %Lp "$scratch")"
  if [[ "$owner" != "$(id -u)" ]]; then
    echo "error: $scratch is owned by uid $owner, not uid $(id -u); refusing" >&2
    return 1
  fi
  if [[ "$mode" != 700 ]]; then
    echo "error: $scratch has mode $mode, expected 700; refusing" >&2
    echo "       (another local user may be able to modify demo binaries)" >&2
    return 1
  fi
  demo_acl_write_guard "$scratch" "scratch directory" || return 1
}
