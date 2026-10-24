#!/bin/bash
set -euo pipefail

# Apple's ticket service can drop a request even after notarization succeeds.
for attempt in 1 2 3; do
  if xcrun stapler "$@"; then
    exit 0
  else
    status=$?
  fi
  if [[ "$status" -ne 68 || "$attempt" -eq 3 ]]; then
    exit "$status"
  fi
  printf 'Stapler %s failed (exit %s); retrying in %s seconds.\n' \
    "$1" "$status" "$((attempt * 10))" >&2
  sleep "$((attempt * 10))"
done
