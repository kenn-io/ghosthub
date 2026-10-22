#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
website_root="$(cd "$script_dir/.." && pwd)"
uv_version="0.13.4"

os_name="$(uname -s)"
machine_arch="$(uname -m)"
case "$os_name:$machine_arch" in
  Darwin:arm64)
    uv_target="uv-aarch64-apple-darwin"
    archive_sha256="e0b1d4743ce64c55d9f0f4a444afa6b81125680070ee04e853fcd0f6c1ebf8f1"
    binary_sha256="cd510bf93fddcbf0799eb0b7bd9aae87e850a5596aeb4594c12aba72fd4e388b"
    ;;
  Linux:aarch64 | Linux:arm64)
    uv_target="uv-aarch64-unknown-linux-gnu"
    archive_sha256="1ae72b4718729e2ccc4f1ae2c6d1e531ca8467800e0546e9130b3886023a60ab"
    binary_sha256="7ecaf349a12fb60c605c1848e8e1bbd313bbf9a362a6c3043c8f786ec570c491"
    ;;
  Linux:x86_64 | Linux:amd64)
    uv_target="uv-x86_64-unknown-linux-gnu"
    archive_sha256="2b428396f12572d4429cf210ca234dd599a33b3af0958a4d5ed569d63e3f344f"
    binary_sha256="5b2a2df4ef04c5d778d50702d6e1d1ff22909fc883086b4ef406a4f115e3c4fb"
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
