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
build_identity_schema=3
stamp_value="${revision} identity=${build_identity_schema}"
if [[ "$targeted" == true ]]; then
  stamp_value="${revision} ${goos}/${goarch} identity=${build_identity_schema}"
fi

# The stamp records intent; only the binary can say which revision it is.
reported_version() {
  "$output" --version 2>&1 || true
}

validate_native_identity() (
  helper="$1"
  validation_prefix="${2:-$helper}"
  validation_root="$(mktemp -d "${validation_prefix}.identity.XXXXXX")"
  validation_home="${validation_root}/home"
  validation_kwt_home="${validation_root}/kwt-home"
  validation_config_home="${validation_root}/config"
  mkdir -p \
    "$validation_home" \
    "$validation_kwt_home" \
    "$validation_config_home"

  run_isolated_helper() {
    HOME="$validation_home" \
      KWT_HOME="$validation_kwt_home" \
      XDG_CONFIG_HOME="$validation_config_home" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_SYSTEM=/dev/null \
      "$helper" "$@"
  }
  daemon_started=false
  cleanup_validation() {
    if [[ "$daemon_started" == true ]]; then
      run_isolated_helper daemon stop >/dev/null 2>&1 || return
      daemon_started=false
    fi
    find "$validation_root" -depth -delete
  }
  trap cleanup_validation EXIT

  daemon_started=true
  run_isolated_helper daemon start >/dev/null
  identity="$(run_isolated_helper daemon status --json)"
  if [[ "$identity" != *'"version":"'"$revision"'"'* ]] \
    || [[ "$identity" != *'"revision":"'"$revision"'"'* ]] \
    || [[ "$identity" != *'"revision_time":"'"$kwt_revision_time"'"'* ]]; then
    printf 'Built kwt daemon reports an incomplete pinned identity.\n' >&2
    printf 'Expected version and revision %s at %s; received %s.\n' \
      "$revision" "$kwt_revision_time" "${identity:-no daemon status}" >&2
    return 1
  fi

  if ! run_isolated_helper daemon stop >/dev/null 2>&1; then
    printf 'Built kwt validation daemon could not be stopped.\n' >&2
    return 1
  fi
  daemon_started=false
  find "$validation_root" -depth -delete
  trap - EXIT
)

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

  current_revision="$(git -C "$source_dir" rev-parse HEAD)"
  requested_revision="$(
    git -C "$source_dir" rev-parse --verify "${revision}^{commit}" 2>/dev/null \
      || true
  )"
  if [[ -z "$requested_revision" || "$current_revision" != "$requested_revision" ]]; then
    git -C "$source_dir" fetch --no-tags origin "$revision"
    git -C "$source_dir" checkout --detach "$revision"
  fi
fi

mkdir -p "$(dirname "$output")"
kwt_revision_time="$(
  TZ=UTC git -C "$source_dir" show -s \
    --date=format-local:'%Y-%m-%dT%H:%M:%SZ' \
    --format='%cd' \
    "$revision"
)"
kwt_build_ldflags="-s -w"
kwt_build_ldflags+=" -X go.kenn.io/kwt/internal/cmd.version=${revision}"
kwt_build_ldflags+=" -X go.kenn.io/kwt/internal/cmd.commit=${revision}"
kwt_build_ldflags+=" -X go.kenn.io/kwt/internal/cmd.revisionTime=${kwt_revision_time}"
build_helper() (
  helper_output="$1"
  helper_goos="${2:-}"
  helper_goarch="${3:-}"
  cd "$source_dir"
  if [[ -n "$helper_goos" && -n "$helper_goarch" ]]; then
    CGO_ENABLED=0 GOOS="$helper_goos" GOARCH="$helper_goarch" go build \
      -trimpath \
      -ldflags "$kwt_build_ldflags" \
      -o "$helper_output" \
      cmd/kwt/main.go
  else
    CGO_ENABLED=0 go build \
      -trimpath \
      -ldflags "$kwt_build_ldflags" \
      -o "$helper_output" \
      cmd/kwt/main.go
  fi
)

if [[ "$targeted" == true ]]; then
  build_helper "$output" "$goos" "$goarch"
else
  build_helper "$output"
fi

# The linker silently ignores -X for a symbol it cannot find. Exercise the
# native helper's isolated daemon interface before asserting that the cache
# contains the full replacement identity. Cross-compiled variants first build
# a native probe from the same source and linker flags, then retain their
# format-specific validation.
if [[ "$targeted" == false ]]; then
  chmod 0755 "$output"
  if ! validate_native_identity "$output"; then
    rm -f "$output" "$stamp"
    exit 1
  fi
else
  if ! target_metadata_matches; then
    printf 'Built kwt does not match %s/%s at revision %s.\n' \
      "$goos" "$goarch" "$revision" >&2
    rm -f "$output" "$stamp"
    exit 1
  fi

  native_probe_root="$(mktemp -d "${output}.native.XXXXXX")"
  native_probe="${native_probe_root}/kwt"
  cleanup_native_probe() {
    find "$native_probe_root" -depth -delete
  }
  trap cleanup_native_probe EXIT
  build_helper "$native_probe"
  chmod 0755 "$native_probe"
  if ! validate_native_identity "$native_probe" "$output"; then
    rm -f "$output" "$stamp"
    exit 1
  fi
  cleanup_native_probe
  trap - EXIT
fi

printf '%s' "$stamp_value" >"$stamp"
