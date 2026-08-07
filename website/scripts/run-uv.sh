#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
website_root="$(cd "$script_dir/.." && pwd)"
uv_version="0.9.5"
uv_cache="$website_root/.cache/uv-$uv_version"
uv_bin="$uv_cache/bin/uv"
installer="$uv_cache/install.sh"
installer_sha256="8402ab80d2ef54d7044a71ea4e4e1e8db3b20c87c7bffbc30bff59f1e80ebbd5"

if [[ -x "$uv_bin" ]]; then
  exec "$uv_bin" "$@"
fi

mkdir -p "$uv_cache"
curl \
  --proto '=https' \
  --tlsv1.2 \
  --fail \
  --location \
  --silent \
  --show-error \
  "https://astral.sh/uv/$uv_version/install.sh" \
  --output "$installer"

if command -v shasum >/dev/null 2>&1; then
  printf '%s  %s\n' "$installer_sha256" "$installer" \
    | shasum -a 256 --check --status
elif command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$installer_sha256" "$installer" \
    | sha256sum --check --status
else
  printf 'a SHA-256 checksum tool is required to bootstrap uv\n' >&2
  exit 1
fi
env UV_UNMANAGED_INSTALL="$uv_cache/bin" sh "$installer" >/dev/null

if [[ ! -x "$uv_bin" ]]; then
  printf 'uv installer did not create the expected executable: %s\n' "$uv_bin" >&2
  exit 1
fi

exec "$uv_bin" "$@"
