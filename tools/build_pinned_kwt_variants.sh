#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  printf 'usage: %s <repository> <revision> <source-dir> <output-dir> <builder>\n' \
    "$0" >&2
  exit 2
fi

repository="$1"
revision="$2"
source_dir="$3"
output_dir="$4"
builder="$5"

for target in \
  darwin-amd64 \
  darwin-arm64 \
  linux-amd64 \
  linux-arm64 \
  windows-amd64 \
  windows-arm64
do
  goos="${target%-*}"
  goarch="${target#*-}"
  "$builder" \
    "$repository" \
    "$revision" \
    "$source_dir" \
    "$output_dir/$target/kwt" \
    "$goos" \
    "$goarch"
done
