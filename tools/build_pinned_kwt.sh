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

if [[ -x "$output" && -f "$stamp" ]] \
  && [[ "$(<"$stamp")" == "$revision" ]]; then
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
  mkdir -p "$(dirname "$source_dir")"
  git clone --filter=blob:none --no-checkout "$repository" "$source_dir"
fi

if [[ -n "$(git -C "$source_dir" status --porcelain)" ]]; then
  printf '%s has uncommitted changes; refusing to replace them.\n' \
    "$source_dir" >&2
  exit 1
fi

git -C "$source_dir" fetch --no-tags origin "$revision"
git -C "$source_dir" checkout --detach "$revision"

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
version_output="$("$output" --version 2>&1 || true)"
if [[ "$version_output" != *"$revision"* ]]; then
  printf 'Built kwt reports %s instead of the pinned revision %s.\n' \
    "${version_output:-no version output}" "$revision" >&2
  printf 'Update the -X version symbol in %s to match kwt.\n' "$0" >&2
  rm -f "$output"
  exit 1
fi

printf '%s' "$revision" >"$stamp"
