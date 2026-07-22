# shellcheck shell=bash
# Remove a container only through the CID recorded by this demo scratch.
# Keep that record whenever Docker cannot confirm the container is gone.
demo_create_recorded_container() {
  local record="$1"
  shift
  local cidfile="$record.created" label cid recovered
  label="com.ghosthub.demo.record=$record"
  if [[ -e "$record" || -e "$cidfile" ]]; then
    echo "error: container ownership record already exists; preserving demo state" >&2
    return 1
  fi

  # The empty record is an intentional pending marker. If this process is
  # interrupted after the daemon creates the container but before --cidfile
  # is populated, teardown must preserve scratch rather than lose ownership.
  : > "$record"
  if ! docker create --cidfile "$cidfile" --label "$label" "$@" >/dev/null; then
    # Recover a daemon-created container when the CLI failed after creation.
    # A confirmed empty result means creation did not happen; any ambiguous
    # query leaves the empty record in place for manual recovery.
    if recovered="$(docker container ls -aq --filter "label=$label" 2>/dev/null)"; then
      recovered="$(printf '%s\n' "$recovered" | sed '/^$/d')"
      if [[ -z "$recovered" ]]; then
        rm -f "$record" "$cidfile"
      elif [[ "$recovered" != *$'\n'* && "$recovered" =~ ^[0-9a-fA-F]{12,64}$ ]]; then
        printf '%s\n' "$recovered" > "$record"
        rm -f "$cidfile"
      fi
    fi
    return 1
  fi
  if [[ ! -s "$cidfile" ]]; then
    echo "error: docker create did not write a container ID; preserving $record" >&2
    return 1
  fi
  cid="$(cat "$cidfile")"
  if [[ ! "$cid" =~ ^[0-9a-fA-F]{12,64}$ ]]; then
    echo "error: docker create returned an invalid container ID; preserving $record" >&2
    return 1
  fi
  mv -f "$cidfile" "$record"
  docker start "$cid" >/dev/null
}

demo_remove_recorded_container() {
  local record="$1"
  [[ -e "$record" ]] || return 0
  if [[ ! -s "$record" ]]; then
    echo "error: container creation is ambiguous; preserving $record and scratch" >&2
    return 1
  fi

  local cid output
  cid="$(cat "$record")"
  if [[ ! "$cid" =~ ^[0-9a-fA-F]{12,64}$ ]]; then
    echo "error: invalid container ID in $record; preserving demo state" >&2
    return 1
  fi
  if output="$(docker rm -f "$cid" 2>&1)"; then
    rm -f "$record"
    return 0
  fi
  if grep -qiE '(^|: )no such (container|object)(:| |$)' <<<"$output"; then
    rm -f "$record"
    return 0
  fi

  echo "error: could not remove demo container $cid; preserving $record" >&2
  [[ -n "$output" ]] && echo "       $output" >&2
  return 1
}
