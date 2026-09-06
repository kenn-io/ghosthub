#!/usr/bin/env bash
# Builds the faux environment for marketing screenshots: staged git repos and
# worktrees for kenn-io OSS projects, a dedicated local tmux server with bound
# and raw sessions, and a docker "remote" box (sshd + tmux) on 127.0.0.1:2201.
set -euo pipefail

demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The demo lives at <repo>/website/demo; default the clone source and the
# app build to this repo so the workflow works from any checkout.
repo_root="$(cd "$demo_root/../.." && pwd)"
release_version="$(tr -d '[:space:]' < "$repo_root/RELEASE_VERSION")"
# Short path required: tmux unix sockets cap out near 104 characters.
scratch="${GHOSTHUB_DEMO_SCRATCH:-/tmp/ghosthub-demo}"

# Staging recreates directories under $scratch with rm -rf. Refuse to
# operate anywhere we did not create: a sentinel marks demo-owned scratch.
sentinel="$scratch/.ghosthub-demo-scratch"
case "$scratch" in
  "" | "/" | "$HOME" | "$HOME/")
    echo "error: refusing to use '$scratch' as demo scratch" >&2
    exit 1
    ;;
esac
# shellcheck source=SCRIPTDIR/scratch-guard.sh
source "$demo_root/scratch-guard.sh"
# Validate ancestry before creation, including a nonexistent scratch beneath
# an unsafe parent. The strict second check confirms mkdir's result and makes
# disappearance after a failed mkdir an error.
demo_scratch_guard "$scratch" allow-missing
if [[ -e "$scratch" && ! -f "$sentinel" ]]; then
  echo "error: $scratch exists but was not created by stage.sh" >&2
  echo "       (missing $sentinel); refusing to delete inside it" >&2
  exit 1
fi
# Attempt creation atomically with owner-only mode, then validate
# unconditionally. A failed mkdir is acceptable only when the strict guard
# confirms that the existing directory is still ours.
scratch_created=""
if mkdir -m 700 "$scratch" 2>/dev/null; then
  scratch_created=1
fi
if [[ -n "$scratch_created" ]]; then
  # A parent default ACL can be inherited despite mode 0700. Remove it before
  # creating any executable or dylib-bearing state, then verify below.
  chmod -N "$scratch"
  chmod 700 "$scratch"
fi
demo_scratch_guard "$scratch"
touch "$sentinel"

# Restaging must stop every consumer of the old files before replacing them.
# If either identity cannot be confirmed, preserve the complete scratch tree
# so teardown can still recover through the original executable and socket.
# shellcheck source=SCRIPTDIR/process.sh
source "$demo_root/process.sh"
demo_stop_retained_launches \
  "$scratch" "$scratch/app/Ghosthub.app/Contents/MacOS/Ghosthub"
demo_stop_recorded_process \
  "$scratch/app.pid" "$scratch/app/Ghosthub.app/Contents/MacOS/Ghosthub"
# The staged bundle uses this demo-only defaults domain. Clear it between
# passes so window layout and disclosure state never depend on an earlier
# capture while leaving every real Ghosthub preference untouched.
defaults delete com.ghosthub.demo 2>/dev/null || true
demo_socket="$scratch/tmux/tmux-$(id -u)/default"
# shellcheck source=SCRIPTDIR/tmux.sh
source "$demo_root/tmux.sh"
demo_stop_tmux_server "$demo_socket"

export GHOSTHUB_DEMO_ROOT="$demo_root"
export GHOSTHUB_DEMO_SCRATCH="$scratch"
export TMUX_TMPDIR="$scratch/tmux"
# An inherited $TMUX (stage.sh launched from inside tmux) would override
# TMUX_TMPDIR and point every unqualified tmux command at the REAL
# enclosing server. All demo tmux traffic must stay on the demo socket.
unset TMUX

# Synthetic history must not inherit developer Git rewrites, hooks,
# templates, transports, or configuration.
# shellcheck source=SCRIPTDIR/git.sh
source "$demo_root/git.sh"
git_c=(
  demo_git
  -c user.name=demo
  -c user.email=demo@ghosthub.ai
  -c commit.gpgsign=false
)

make_repo() {
  local name="$1"
  shift
  local repo="$scratch/repos/$name"
  [[ -d "$repo/.git" ]] && return 0
  mkdir -p "$repo"
  "${git_c[@]}" -C "$repo" init -q -b main
  printf '# %s\n' "$name" > "$repo/README.md"
  mkdir -p "$repo/src"
  printf '// %s\n' "$name" > "$repo/src/main.swift"
  "${git_c[@]}" -C "$repo" add -A
  local msg
  for msg in "$@"; do
    "${git_c[@]}" -C "$repo" commit -q -m "$msg" --allow-empty
  done
}

make_worktree() {
  local name="$1" branch="$2"
  local repo="$scratch/repos/$name"
  local path="$scratch/worktrees/$name/$branch"
  [[ -d "$path" ]] && return 0
  mkdir -p "$(dirname "$path")"
  "${git_c[@]}" -C "$repo" worktree add -q -b "$branch" "$path" main
}

echo "==> staging repos and worktrees"
rm -rf "$scratch/repos" "$scratch/worktrees" "$scratch/ghosthub-state"
mkdir -p "$scratch"/{repos,worktrees,tmux,home,ssh,ghosthub-config,ghosthub-state}
cp "$demo_root/home/zprofile" "$scratch/home/.zprofile"
cp "$demo_root/home/zshrc" "$scratch/home/.zshrc"
cp "$demo_root/ssh-config" "$scratch/ssh/config"
cat > "$scratch/ghosthub-config/ghostty.conf" <<'EOF'
# Isolated marketing-demo terminal configuration.
font-family = Menlo
font-size = 13
background = 282c34
foreground = abb2bf
cursor-color = abb2bf
selection-background = 3e4451
selection-foreground = ffffff
scrollback-limit = 50000000
term = xterm-256color
cursor-style = block
mouse-hide-while-typing = true
copy-on-select = clipboard
macos-option-as-alt = true
shell-integration = detect
EOF
chmod 700 "$scratch/ssh"
chmod 600 "$scratch/ssh/config"

make_repo ghosthub \
  "Initial native workspace" \
  "Attach ordinary tmux clients" \
  "Reconnect remote sessions"
make_repo agentsview \
  "Initial import" \
  "Add live session table" \
  "Group sessions by host"
make_repo msgvault \
  "Initial import" \
  "Add IMAP source connector" \
  "Index attachments for full-text search"

make_worktree ghosthub fix-reconnect-backoff
make_worktree ghosthub pr-142-fleet-sidebar
make_worktree agentsview add-session-filters
make_worktree msgvault pr-87-imap-sync

changes_worktree="$scratch/worktrees/ghosthub/fix-reconnect-backoff"
printf '\nDocument the reconnect fallback.\n' >> "$changes_worktree/README.md"
mkdir -p "$changes_worktree/Tests"
printf '// Reconnect backoff coverage\n' > "$changes_worktree/Tests/ReconnectBackoffTests.swift"
"${git_c[@]}" -C "$changes_worktree" add Tests/ReconnectBackoffTests.swift
printf '# Reconnect notes\n' > "$changes_worktree/reconnect-notes.md"

echo "==> staging local tmux sessions (socket dir: $TMUX_TMPDIR)"

# Pane shells use an explicit zsh with both HOME and ZDOTDIR isolated so the
# account shell and launcher environment cannot load personal configuration.
# shellcheck source=SCRIPTDIR/shell.sh
source "$demo_root/shell.sh"
new_session() {
  demo_new_session "$scratch" "$@"
}

# Bound sessions: names must match the kwt shim's session_name values. The
# hero pane uses a curated agent investigation so captures never depend on an
# account, a network service, unpublished source, or nondeterministic output.
cat > "$scratch/agent-transcript.txt" <<'EOF'
● Read Sources/Tmux/TmuxAttachmentInfo.swift
● Read Sources/App/NativeTmuxSessionCoordinator.swift
● Search reconnect | ServerAliveInterval | ConnectTimeout

I traced the remote attachment path from host discovery through the ordinary
tmux client. The important boundaries are:

1. Attachment
   Ghosthub opens the same tmux client locally and remotely. Tmux continues to
   own windows, panes, layout, history, and process lifetime.

2. Keepalive
   SSH uses a short connection timeout plus server keepalives, so a dead link
   exits instead of leaving the terminal surface hung indefinitely.

3. Reconnect
   Transport failures restart the SSH client with bounded backoff. A clean
   detach remains clean and never destroys the tmux session.

The coordinator owns presentation lifecycle, while the reconnecting shell owns
transport recovery inside the still-running terminal surface. That separation
is why closing Ghosthub detaches without becoming session authority.

Fragile point

The user-visible reconnect state should always come from the transport process,
not a second Swift-side timer. Two clocks would drift and report false health.

Ready to turn this into a focused regression test and implementation plan.
EOF
cat > "$scratch/session-transcript.txt" <<'EOF'
$ git status --short --branch
## add-session-filters
 M Sources/SessionTable.swift
 M Sources/SessionFilter.swift
?? Tests/SessionFilterTests.swift

$ swift test --filter SessionFilterTests
Building for debugging...
Build complete! (1.8s)
Test Suite 'Selected tests' started
  ✓ filters sessions by host
  ✓ matches project and worktree names
  ✓ keeps active agents visible
  ✓ clears the query without changing selection
Test Suite 'Selected tests' passed
Executed 4 tests, with 0 failures in 0.09 seconds

$ git diff --stat
 Sources/SessionFilter.swift      | 42 +++++++++++++++++++++
 Sources/SessionTable.swift       | 18 ++++++++-
 Tests/SessionFilterTests.swift   | 35 +++++++++++++++++
 3 files changed, 94 insertions(+), 1 deletion(-)
EOF
new_session ghosthub--fix-reconnect-backoff \
  "$scratch/worktrees/ghosthub/fix-reconnect-backoff" \
  "clear; cat $(printf '%q' "$scratch/agent-transcript.txt")"

# The default status-right renders the pane title, which carries the real
# hostname. Same for anything else the shell stuffs into titles.
tmux set -g status-right '"studio.local"'
tmux set -g set-titles off

new_session agentsview--add-session-filters \
  "$scratch/worktrees/agentsview/add-session-filters" \
  "clear; cat $(printf '%q' "$scratch/session-transcript.txt")"

# Raw local sessions (unbound: not in any kwt inventory).
new_session scratch "$scratch/repos/msgvault" \
  "clear; git log --oneline -4"
new_session docbank-export "$scratch" \
  "clear; echo 'exported 4,812 threads (2.1 GiB) in 96s'; echo done."
new_session release-watch "$scratch/repos/ghosthub" \
  "clear; printf 'release v${release_version}\\n\\n  ✓ build\\n  ✓ swift tests\\n  ✓ notarization\\n  ● publish\\n'"
new_session test-matrix "$scratch/repos/agentsview" \
  "clear; printf 'test matrix\\n\\nmacOS 26 arm64     ✓ 680 passed\\nUbuntu 24.04       ✓ 149 passed\\nSSH integration    ✓  42 passed\\n'"

echo "==> staging patched app copy"
# Build the release app first (make release-app in the app repo) or point
# GHOSTHUB_DEMO_APP at an existing Ghosthub.app.
app_src="${GHOSTHUB_DEMO_APP:-$repo_root/dist/release/Ghosthub.app}"
if [[ ! -d "$app_src" ]]; then
  echo "error: no app bundle at $app_src; build one or set GHOSTHUB_DEMO_APP" >&2
  exit 1
fi
app_copy="$scratch/app/Ghosthub.app"
rm -rf "$scratch/app"
mkdir -p "$scratch/app"
cp -RX "$app_src" "$app_copy"
# The packaged app pins kwt to Contents/Helpers/kwt (no PATH fallback), so
# the faux inventory has to be installed inside the bundle. Helpers/ is
# absent when the bundle was built without a packaged kwt.
mkdir -p "$app_copy/Contents/Helpers"
cp -f "$demo_root/bin/kwt" "$app_copy/Contents/Helpers/kwt"
chmod +x "$app_copy/Contents/Helpers/kwt"
# Preferences flow through cfprefsd keyed by bundle identifier, so HOME
# and GHOSTHUB_* overrides alone do not isolate UserDefaults. A demo-only
# identifier keeps the staged copy out of the real app's domain entirely.
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.ghosthub.demo' \
  "$app_copy/Contents/Info.plist"
# Re-sign ad hoc without the hardened runtime so DYLD_INSERT_LIBRARIES (the
# hostname override in run.sh) takes effect.
codesign --force --deep -s - "$app_copy" 2>/dev/null
# Files produced from toolchains downloaded by a browser can inherit macOS
# provenance metadata even when cp omits extended attributes. The isolated,
# ad-hoc-signed demo copy is not a downloaded release artifact, so remove that
# metadata after signing to keep Gatekeeper from terminating the injected
# capture process before its first window opens.
xattr -dr com.apple.provenance "$app_copy" 2>/dev/null || true

cc -dynamiclib -fobjc-arc -framework AppKit -framework ImageIO \
  -o "$scratch/libdemohost.dylib" "$demo_root/assets/demohost.m"

echo "==> staging docker remote (127.0.0.1:2201)"
# shellcheck source=SCRIPTDIR/docker-cleanup.sh
source "$demo_root/docker-cleanup.sh"
# Remove only a container this scratch recorded; a name-only match may
# belong to another invocation, so collide loudly instead of deleting it.
demo_remove_recorded_container "$scratch/remote.cid"
if docker container inspect ghosthub-demo-remote >/dev/null 2>&1; then
  echo "error: container ghosthub-demo-remote already exists but was not" >&2
  echo "       created by this scratch dir; remove it manually to restage" >&2
  exit 1
fi
# Use the immutable build result directly. A fixed tag is global Docker state
# and could silently replace an unrelated image owned by the developer.
image_id="$(docker build -q "$demo_root/remote")"
if [[ ! "$image_id" =~ ^(sha256:)?[0-9a-fA-F]{64}$ ]]; then
  echo "error: docker build returned an invalid image ID" >&2
  exit 1
fi
auth_keys="$(cat "$HOME"/.ssh/id_*.pub 2>/dev/null || true)"
if [[ -z "$auth_keys" ]]; then
  echo "error: no public key found in ~/.ssh; create one with ssh-keygen" >&2
  exit 1
fi
# Create first so the ownership record is durable even when startup fails.
# teardown.sh can then remove the stopped container on the next attempt.
demo_create_recorded_container "$scratch/remote.cid" \
  --name ghosthub-demo-remote --hostname gpu-01 \
  -e AUTHORIZED_KEYS="$auth_keys" \
  -p 127.0.0.1:2201:22 "$image_id"

echo "==> waiting for sshd"
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 2201 2>/dev/null; then break; fi
  sleep 0.5
done
keys_file="$scratch/ssh/known_hosts"
: > "$keys_file"
chmod 600 "$keys_file"
for _ in $(seq 1 20); do
  keys="$(ssh-keyscan -p 2201 127.0.0.1 2>/dev/null || true)"
  if [[ -n "$keys" ]]; then
    while read -r _ key_type key_data; do
      printf 'ghosthub-demo-remote %s %s\n' "$key_type" "$key_data"
    done <<< "$keys" > "$keys_file"
    break
  fi
  sleep 0.5
done
if [[ -z "${keys:-}" ]]; then
  echo "error: ssh-keyscan never returned a host key from 127.0.0.1:2201" >&2
  exit 1
fi

echo "==> demo environment ready"
tmux list-sessions
