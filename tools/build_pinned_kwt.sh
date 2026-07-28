#!/usr/bin/env bash
set -euo pipefail

locked=false
if [[ $# -eq 5 && "$5" == "--locked" ]]; then
  locked=true
  set -- "$1" "$2" "$3" "$4"
elif [[ $# -eq 7 && "$7" == "--locked" ]]; then
  locked=true
  set -- "$1" "$2" "$3" "$4" "$5" "$6"
fi

if [[ $# -ne 4 && $# -ne 6 ]]; then
  printf 'usage: %s <repository> <revision> <source-dir> <output> [<goos> <goarch>]\n' \
    "$0" >&2
  exit 2
fi

repository="$1"
revision="$2"
source_dir="$3"
output="$4"
targeted=false
goos=""
goarch=""
if [[ $# -eq 6 ]]; then
  targeted=true
  goos="$5"
  goarch="$6"
fi
stamp="${output}.revision"
stamp_value="$revision"
if [[ "$targeted" == true ]]; then
  stamp_value="${revision} ${goos}/${goarch}"
fi

# The stamp records intent; only the binary can say which revision it is.
reported_version() {
  "$output" --version 2>&1 || true
}

target_metadata_matches() {
  [[ "$targeted" == true && -f "$output" ]] || return 1
  metadata="$(go version -m "$output" 2>/dev/null)" || return 1
  grep -F $'\tbuild\tGOOS='"$goos" <<<"$metadata" >/dev/null \
    || return 1
  grep -F $'\tbuild\tGOARCH='"$goarch" <<<"$metadata" >/dev/null \
    || return 1
  LC_ALL=C grep -a -F "$revision" "$output" >/dev/null
}

if [[ "$locked" == false ]]; then
  command -v lockf >/dev/null || {
    printf 'lockf is required to build the pinned kwt helper.\n' >&2
    exit 1
  }
  mkdir -p "$(dirname "$source_dir")"
  exec lockf -k "${source_dir}.lock" "$0" "$@" --locked
fi

if [[ -f "$output" && -f "$stamp" ]] \
  && [[ "$(<"$stamp")" == "$stamp_value" ]]; then
  if [[ "$targeted" == true ]] && target_metadata_matches; then
    exit 0
  fi
  if [[ "$targeted" == false && -x "$output" ]] \
    && [[ "$(reported_version)" == *"$revision"* ]]; then
    exit 0
  fi
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
  if [[ "$targeted" == true ]]; then
    CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" go build \
      -trimpath \
      -ldflags "-s -w -X go.kenn.io/kwt/internal/cmd.version=${revision}" \
      -o "$output" \
      cmd/kwt/main.go
  else
    CGO_ENABLED=0 go build \
      -trimpath \
      -ldflags "-s -w -X go.kenn.io/kwt/internal/cmd.version=${revision}" \
      -o "$output" \
      cmd/kwt/main.go
  fi
)

# The linker silently ignores -X for a symbol it cannot find, so an unstamped
# native binary is the only evidence that kwt has moved its version variable.
# Every cross-compiled variant uses the same source and linker symbol.
if [[ "$targeted" == false ]]; then
  chmod 0755 "$output"
  version_output="$(reported_version)"
  if [[ "$version_output" != *"$revision"* ]]; then
    printf 'Built kwt reports %s instead of the pinned revision %s.\n' \
      "${version_output:-no version output}" "$revision" >&2
    printf 'Update the -X version symbol in %s to match kwt.\n' "$0" >&2
    rm -f "$output"
    exit 1
  fi
elif ! target_metadata_matches; then
  printf 'Built kwt does not match %s/%s at revision %s.\n' \
    "$goos" "$goarch" "$revision" >&2
  rm -f "$output"
  exit 1
fi

printf '%s' "$stamp_value" >"$stamp"
