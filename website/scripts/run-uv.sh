#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
website_root="$(cd "$script_dir/.." && pwd)"
uv_version="0.9.5"

os_name="$(uname -s)"
machine_arch="$(uname -m)"
case "$os_name:$machine_arch" in
  Darwin:arm64)
    uv_target="uv-aarch64-apple-darwin"
    archive_sha256="dc098ff224d78ed418e121fd374f655949d2c7031a70f6f6604eaf016a130433"
    binary_sha256="d54989c0037e115f53c34a5658c2cc0ff5c44e35b5635ed9a5463b9caa364f81"
    ;;
  Linux:aarch64 | Linux:arm64)
    uv_target="uv-aarch64-unknown-linux-gnu"
    archive_sha256="9db0c2f6683099f86bfeea47f4134e915f382512278de95b2a0e625957594ff3"
    binary_sha256="b880aad13554f4eb7815f962b4f40e3f94fb2f86cae4b98afa0906324b61f754"
    ;;
  Linux:x86_64 | Linux:amd64)
    uv_target="uv-x86_64-unknown-linux-gnu"
    archive_sha256="2cf10babba653310606f8b49876cfb679928669e7ddaa1fb41fb00ce73e64f66"
    binary_sha256="d3dc3ca8e29337dd602a9a4df9e6edb15ebc52aed91461debeedb96939dc4ce0"
    ;;
  *)
    printf 'unsupported uv bootstrap platform: %s %s\n' "$os_name" "$machine_arch" >&2
    exit 1
    ;;
esac

verify_sha256() {
  local expected_sha="$1"
  local file_abs="$2"
  local checksum_line=""
  local actual_sha=""

  if command -v shasum >/dev/null 2>&1; then
    checksum_line="$(shasum -a 256 "$file_abs")"
  elif command -v sha256sum >/dev/null 2>&1; then
    checksum_line="$(sha256sum "$file_abs")"
  else
    printf 'a SHA-256 checksum tool is required to bootstrap uv\n' >&2
    return 1
  fi

  actual_sha="${checksum_line%% *}"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    printf 'SHA-256 mismatch for %s: expected %s, got %s\n' \
      "$file_abs" "$expected_sha" "$actual_sha" >&2
    return 1
  fi
}

uv_cache="$website_root/.cache/uv-$uv_version/$uv_target"
uv_bin="$uv_cache/uv"

if [[ -e "$uv_bin" ]]; then
  if [[ -L "$uv_bin" || ! -f "$uv_bin" || ! -x "$uv_bin" ]]; then
    printf 'cached uv is not a regular executable: %s\n' "$uv_bin" >&2
    exit 1
  fi
  verify_sha256 "$binary_sha256" "$uv_bin"
  exec "$uv_bin" "$@"
fi

mkdir -p "$uv_cache"
archive_abs="$(mktemp "$uv_cache/archive.XXXXXX")"
extract_abs="$(mktemp -d "$uv_cache/extract.XXXXXX")"
archive_name="$uv_target.tar.gz"
curl \
  --proto '=https' \
  --tlsv1.2 \
  --fail \
  --location \
  --silent \
  --show-error \
  "https://github.com/astral-sh/uv/releases/download/$uv_version/$archive_name" \
  --output "$archive_abs"

verify_sha256 "$archive_sha256" "$archive_abs"
tar -xzf "$archive_abs" -C "$extract_abs" "$uv_target/uv"

extracted_uv_abs="$extract_abs/$uv_target/uv"
if [[ -L "$extracted_uv_abs" || ! -f "$extracted_uv_abs" || ! -x "$extracted_uv_abs" ]]; then
  printf 'uv archive did not contain the expected executable: %s\n' "$extracted_uv_abs" >&2
  exit 1
fi
verify_sha256 "$binary_sha256" "$extracted_uv_abs"
mv -f "$extracted_uv_abs" "$uv_bin"

if [[ -L "$uv_bin" || ! -f "$uv_bin" || ! -x "$uv_bin" ]]; then
  printf 'uv bootstrap did not create the expected executable: %s\n' "$uv_bin" >&2
  exit 1
fi
verify_sha256 "$binary_sha256" "$uv_bin"

exec "$uv_bin" "$@"
