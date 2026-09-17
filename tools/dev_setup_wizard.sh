#!/usr/bin/env bash
#
# Walks a developer through every prerequisite for building Ghosthub locally:
# mise-managed tools, a supported Xcode, its first-launch setup, the libghostty
# bootstrap, and a first build. Each stage skips itself when already satisfied.
#
# Everything above the "STAGES" marker is the wizard library: do not hand-edit
# it. Author the per-step stages below the marker.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Wizard library — delightful, consistent UX. Identical across every wizard.
# ──────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

# Author sets this at the top of the stages section.
TOTAL_STAGES=0

_STAGE_INDEX=0
ENV_FILE="${ENV_FILE:-.env}"
WRITTEN_ENV=()    # KEYs written to ENV_FILE this run
WRITTEN_SECRET=() # secret NAMEs set this run
SKIPPED=()        # things we couldn't do (e.g. gh missing)

# _clear — wipe the terminal so only the current step is on screen. No-op when
# output isn't a terminal, so piped logs stay readable.
_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

# banner "Title" — opening frame: what this wizard does.
banner() {
  _clear
  printf '\n%s%s  %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
  printf '%s  %s stages%s\n\n' "$DIM" "$TOTAL_STAGES" "$RESET"
  printf '%s  You drive the browser; this wizard tells you exactly what to do and\n' "$DIM"
  printf '  captures the values you copy back. Stop any time with Ctrl-C and re-run\n'
  printf '  later — it remembers values already saved.%s\n' "$RESET"
  pause "Ready to start?"
}

# stage "Name" — clear the screen, then announce a stage and show progress.
# Clearing keeps only the current step on screen.
stage() {
  _clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ Stage %s/%s · %s%s\n' \
    "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

# say "..." — a plain instruction line.
say()  { printf '  %s\n' "$1"; }
# step "..." — a numbered-feeling action the human takes in the browser.
step() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s⚠ %s%s\n' "$YELLOW" "$1" "$RESET"; }

# open_url URL — open in the human's browser, cross-platform incl. WSL.
open_url() {
  local url="$1"
  printf '  %s↗ opening%s %s\n' "$GREEN" "$RESET" "$url"
  { if   command -v wslview     >/dev/null 2>&1; then wslview "$url"
    elif command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$url"
    elif command -v xdg-open    >/dev/null 2>&1; then xdg-open "$url"
    elif command -v open        >/dev/null 2>&1; then open "$url"
    else warn "couldn't open a browser — visit it manually: $url"; fi
  } >/dev/null 2>&1 || warn "couldn't open a browser — visit it manually: $url"
}

# pause "msg" — wait for the human to confirm they've done the manual part.
pause() {
  printf '  %s%s%s ' "$DIM" "${1:-Press Enter to continue}" "$RESET"
  read -r _ || true
}

# confirm "question" — y/N gate; returns success on yes.
confirm() {
  local reply=""
  printf '  %s? %s [y/N] ' "$YELLOW" "$1"
  read -r reply || true
  [[ "$reply" =~ ^[Yy] ]]
}

# _existing KEY — current value of KEY in ENV_FILE, if any.
_existing() {
  [[ -f "$ENV_FILE" ]] || return 1
  local line; line=$(grep -E "^${1}=" "$ENV_FILE" | tail -n1) || return 1
  printf '%s' "${line#*=}"
}

# ask KEY "Prompt" — read a value into $KEY. Offers the existing .env value as
# a default on re-runs (Enter keeps it). Visible input (non-secret).
ask() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps current]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -r input || true
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# ask_secret KEY "Prompt" — like ask, but input is hidden.
ask_secret() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps current]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -rs input || true
  printf '\n'
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# write_env KEY VALUE — upsert KEY=VALUE into ENV_FILE (creates it; replaces
# any existing line). Idempotent.
write_env() {
  local key="$1" value="$2" tmp
  touch "$ENV_FILE"
  tmp=$(mktemp)
  grep -vE "^${key}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  WRITTEN_ENV+=("$key")
  printf '  %s✓ wrote%s %s → %s\n' "$GREEN" "$RESET" "$key" "$ENV_FILE"
}

# set_secret NAME VALUE — set a GitHub Actions repo secret via gh. Falls back
# to a warning (and records it) if gh is unavailable or unauthenticated.
set_secret() {
  local name="$1" value="$2"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if printf '%s' "$value" | gh secret set "$name" >/dev/null 2>&1; then
      WRITTEN_SECRET+=("$name")
      printf '  %s✓ set%s GitHub secret %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("GitHub secret $name (set it manually: gh secret set $name)")
  warn "skipped GitHub secret $name — gh not ready; set it later"
}

# set_var NAME VALUE — set a GitHub Actions repo variable (non-secret).
set_var() {
  local name="$1" value="$2"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh variable set "$name" --body "$value" >/dev/null 2>&1; then
      printf '  %s✓ set%s GitHub variable %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("GitHub variable $name")
  warn "skipped GitHub variable $name — gh not ready; set it later"
}

# finish — clear, then a closing summary of everything configured.
finish() {
  _clear
  printf '\n%s%s  ✓ Setup complete%s\n' "$BOLD" "$GREEN" "$RESET"
  (( ${#WRITTEN_ENV[@]} ))    && note "wrote ${#WRITTEN_ENV[@]} value(s) to $ENV_FILE: ${WRITTEN_ENV[*]}"
  (( ${#WRITTEN_SECRET[@]} )) && note "set ${#WRITTEN_SECRET[@]} GitHub secret(s): ${WRITTEN_SECRET[*]}"
  if (( ${#SKIPPED[@]} )); then
    printf '\n'; warn "still to do by hand:"
    for s in "${SKIPPED[@]}"; do note "  - $s"; done
  fi
  printf '\n'
}

# ──────────────────────────────────────────────────────────────────────────
# STAGES
# ──────────────────────────────────────────────────────────────────────────

TOTAL_STAGES=5
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The Xcode release CI validates against; see .github/workflows/ci.yml.
XCODE_VERSION="26.0.1"
APPLICATIONS_DIR="/Applications"

# sdk_supports_arm64 SDK_PATH — true when the SDK's primary libSystem stub
# advertises plain arm64-macos, the same test tools/libghostty_bootstrap.py
# applies before letting Zig link against it.
sdk_supports_arm64() {
  local stub="$1/usr/lib/libSystem.B.tbd"
  [[ -f "$stub" ]] || return 1
  awk '/^targets:/ { print; exit }' "$stub" | grep -q '[[ ,]arm64-macos[],]'
}

# compatible_sdk — path of any installed SDK the bootstrap would accept.
compatible_sdk() {
  local sdk
  for sdk in "$APPLICATIONS_DIR"/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk \
             /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
    [[ -d "$sdk" ]] || continue
    if sdk_supports_arm64 "$sdk"; then printf '%s' "$sdk"; return 0; fi
  done
  return 1
}

xcode_version() {
  /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

# find_xcode VERSION — path of an installed Xcode with that marketing version.
find_xcode() {
  local app
  for app in "$APPLICATIONS_DIR"/Xcode*.app; do
    [[ -d "$app" ]] || continue
    if [[ "$(xcode_version "$app")" == "$1" ]]; then
      printf '%s' "$app"; return 0
    fi
  done
  return 1
}

mise_exec() (
  cd "$REPO_ROOT"
  mise exec -- "$@"
)

install_xcode_app() {
  local source="$1" destination="$2" parent
  parent=$(dirname "$destination")
  [[ "$(xcode_version "$source")" == "$XCODE_VERSION" ]] || {
    warn "The downloaded app is not Xcode $XCODE_VERSION. Download that exact release."
    return 1
  }
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    warn "$destination already exists. Move it aside before re-running setup."
    return 1
  }
  if [[ -w "$parent" && -x "$parent" ]]; then
    mv -f "$source" "$destination"
  else
    say "Your account cannot write to $parent. Moving Xcode there requires administrator access."
    if ! confirm "Move Xcode to $destination using sudo?"; then
      warn "Installation canceled. The expanded app remains at $source."
      return 1
    fi
    sudo mv -f "$source" "$destination"
  fi
}

main() {
  banner "Ghosthub developer setup"

  # ── 1. Command-line tools ────────────────────────────────────────────────
  stage "Command-line tools"
  say "Ghosthub needs git, xcodebuild, uv, Go, and the pinned Zig (mise.toml)."
  missing=()
  for tool in git xcodebuild xcrun uv; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]})); then
    warn "Not on PATH: ${missing[*]}"
    say "Install uv from https://docs.astral.sh/uv/ and Xcode from the App Store, then re-run."
    exit 1
  fi
  if command -v mise >/dev/null 2>&1; then
    say "Running mise install for the Zig and Go versions in mise.toml…"
    ( cd "$REPO_ROOT" && mise install )
  else
    warn "Install mise from https://mise.jdx.dev, then re-run this wizard."
    exit 1
  fi
  mise_exec go version
  mise_exec zig version
  say "✓ tools present."

  # ── 2. A supported Xcode ─────────────────────────────────────────────────
  stage "A supported Xcode"
  if ! XCODE=$(find_xcode "$XCODE_VERSION"); then
    say "Xcode $XCODE_VERSION is required to match CI, even if a compatible SDK is installed."
    say "It will be installed alongside other Xcode versions; xcode-select is not changed."
    if command -v xcodes >/dev/null 2>&1 && xcodes version >/dev/null 2>&1; then
      APPLE_ID=$(defaults read MobileMeAccounts Accounts 2>/dev/null | grep -m1 AccountID | sed 's/.*= "\{0,1\}\([^";]*\)"\{0,1\};/\1/' || true)
      if [[ -n "$APPLE_ID" ]]; then
        say "Apple ID: $APPLE_ID (this Mac's iCloud account)."
        export XCODES_USERNAME="$APPLE_ID"
        step "xcodes asks for that account's password and 2FA code, then downloads ~3 GB."
      else
        step "xcodes asks for your Apple ID, password, and 2FA code, then downloads ~3 GB."
      fi
      xcodes install "$XCODE_VERSION" --no-superuser || warn "xcodes failed — falling back to a manual download."
    else
      note "Tip: 'mise use -g xcodes@latest' automates this download next time."
    fi
    if ! find_xcode "$XCODE_VERSION" >/dev/null; then
      open_url "https://developer.apple.com/download/all/?q=Xcode%20$XCODE_VERSION"
      step "Sign in, download Xcode $XCODE_VERSION (.xip) to ~/Downloads."
      pause "Press Enter when the download has finished."
      XIP=$(ls -t "$HOME"/Downloads/Xcode*.xip 2>/dev/null | head -n1 || true)
      [[ -n "$XIP" ]] || { warn "No Xcode*.xip in ~/Downloads."; exit 1; }
      # xip always produces Xcode.app, which may already exist, so expand in a
      # scratch folder and move the result under its own name.
      EXPAND_DIR=$(mktemp -d "$HOME/xcode-expand.XXXXXX")
      say "Expanding $XIP in $EXPAND_DIR (several minutes)…"
      ( cd "$EXPAND_DIR" && xip -x "$XIP" )
      [[ -d "$EXPAND_DIR/Xcode.app" ]] || { warn "xip did not produce Xcode.app."; exit 1; }
      install_xcode_app "$EXPAND_DIR/Xcode.app" "$APPLICATIONS_DIR/Xcode_$XCODE_VERSION.app"
      rmdir "$EXPAND_DIR" 2>/dev/null || true
    fi
    XCODE=$(find_xcode "$XCODE_VERSION") || { warn "Xcode $XCODE_VERSION is still not installed."; exit 1; }
    say "✓ installed at $XCODE"
  fi
  # Scope the exact Xcode selection to this wizard and its child processes.
  export DEVELOPER_DIR="$XCODE/Contents/Developer"
  say "✓ remaining stages use Xcode $XCODE_VERSION at $XCODE."
  printf -v XCODE_EXPORT 'export DEVELOPER_DIR=%q' "$DEVELOPER_DIR"
  note "For later builds in your own shell: $XCODE_EXPORT"
  SKIPPED+=("$XCODE_EXPORT before mise exec -- make build / mise exec -- make swift-test")
  # SDK compatibility is a separate bootstrap requirement, not Xcode selection.
  if SDK=$(compatible_sdk); then
    say "✓ $SDK advertises arm64-macos; the bootstrap can use it."
  fi

  # ── 3. Xcode first launch and Metal toolchain ────────────────────────────
  stage "Xcode first launch and Metal toolchain"
  say "Accept licenses and install packages for every Xcode the bootstrap may use."
  for app in "$APPLICATIONS_DIR"/Xcode*.app; do
    [[ -d "$app" ]] || continue
    if ! DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
      step "$app needs its first-launch setup (sudo will prompt)."
      sudo DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -runFirstLaunch
    fi
  done
  # `xcrun --find metal` succeeds on a stub that refuses to run, so ask the
  # compiler for its version instead.
  if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    say "✓ Metal toolchain present for the selected Xcode."
  else
    say "Downloading the Metal toolchain for the selected Xcode…"
    xcodebuild -downloadComponent MetalToolchain
    xcrun --kill-cache
    xcrun --sdk macosx --find metal >/dev/null
  fi

  # ── 4. libghostty ────────────────────────────────────────────────────────
  stage "Bootstrap libghostty"
  say "mise exec -- make bootstrap-libghostty builds the pinned Ghostty source with Zig (several minutes)."
  mise_exec make bootstrap-libghostty
  mise_exec make check-libghostty
  say "✓ libghostty artifacts staged."

  # ── 5. Build ─────────────────────────────────────────────────────────────
  stage "Build Ghosthub"
  mise_exec make build
  say "✓ make build passed. Next: mise exec -- make run-app, mise exec -- make swift-test, mise exec -- make test-essential-workflows."

  finish
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
