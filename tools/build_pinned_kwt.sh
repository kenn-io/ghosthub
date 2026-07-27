#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  printf 'usage: %s <repository> <revision> <source-dir> <output>\n' "$0" >&2
  exit 2
fi

repository="$1"
revision="$2"
source_dir="$3"
output="$4"
stamp="${output}.revision"

# The stamp records intent; only the binary can say which revision it is.
reported_version() {
  "$output" --version 2>&1 || true
}

command -v lockf >/dev/null || {
  printf 'lockf is required to build the pinned kwt helper.\n' >&2
  exit 1
}
mkdir -p "$(dirname "$source_dir")"
exec 9>"${source_dir}.lock"
lockf 9

if [[ -x "$output" && -f "$stamp" ]] \
  && [[ "$(<"$stamp")" == "$revision" ]] \
  && [[ "$(reported_version)" == *"$revision"* ]]; then
  exit 0
fi

command -v git >/dev/null || {
  printf 'git is required to build the pinned kwt helper.\n' >&2
  exit 1
}
command -v go >/dev/null || {
  printf 'Go is required to build the pinned kwt helper.\n' >&2
  exit 1
}

if [[ -e "$source_dir" && ! -d "$source_dir/.git" ]]; then
  printf '%s exists but is not a Git checkout; refusing to replace it.\n' \
    "$source_dir" >&2
  exit 1
fi

if [[ ! -d "$source_dir/.git" ]]; then
  staging_dir=""
  cleanup_staging() {
    if [[ -n "$staging_dir" && -d "$staging_dir" ]]; then
      rm -rf "$staging_dir"
    fi
  }
  trap cleanup_staging EXIT

  staging_dir="$(mktemp -d "${source_dir}.tmp.XXXXXX")"
  git clone --filter=blob:none --no-checkout "$repository" "$staging_dir"
  git -C "$staging_dir" fetch --no-tags origin "$revision"
  git -C "$staging_dir" checkout --detach "$revision"
  mv "$staging_dir" "$source_dir"
  staging_dir=""
  trap - EXIT
else
  if [[ -n "$(git -C "$source_dir" status --porcelain)" ]]; then
    printf '%s has uncommitted changes; refusing to replace them.\n' \
      "$source_dir" >&2
    exit 1
  fi

  git -C "$source_dir" fetch --no-tags origin "$revision"
  git -C "$source_dir" checkout --detach "$revision"
fi

mkdir -p "$(dirname "$output")"
(
  cd "$source_dir"
  go build \
    -trimpath \
    -ldflags "-s -w -X go.kenn.io/kwt/internal/cmd.version=${revision}" \
    -o "$output" \
    cmd/kwt/main.go
)

# The linker silently ignores -X for a symbol it cannot find, so an unstamped
# binary is the only evidence that kwt has moved its version variable.
version_output="$(reported_version)"
if [[ "$version_output" != *"$revision"* ]]; then
  printf 'Built kwt reports %s instead of the pinned revision %s.\n' \
    "${version_output:-no version output}" "$revision" >&2
  printf 'Update the -X version symbol in %s to match kwt.\n' "$0" >&2
  rm -f "$output"
  exit 1
fi

printf '%s' "$revision" >"$stamp"
