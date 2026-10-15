#!/usr/bin/env bash
set -euo pipefail

test "$(id -un)" = ghosthub
test "$HOME" = /home/ghosthub
test -w "$HOME"
sudo -n true
last_change_day="$(sudo getent shadow ghosthub | cut -d: -f3)"
test "$last_change_day" -gt 0
locale charmap | grep -qx UTF-8
TERM=tmux-256color infocmp tmux-256color >/dev/null
git --version >/dev/null
curl --version >/dev/null
ssh -V
unzip -v >/dev/null
xz --version >/dev/null
test ! -e "$HOME/.gitconfig"
test ! -e "$HOME/.ssh"
test ! -e /usr/bin/pebble
test ! -e /var/lib/pebble

for excluded in \
  docker node python python3 ruby go rustc cargo swift clang gcc \
  vim nvim emacs code claude codex opencode
do
  if command -v "$excluded" >/dev/null 2>&1; then
    printf 'unexpected command in sandbox image: %s\n' "$excluded" >&2
    exit 1
  fi
done

test ! -e /etc/apt/apt.conf.d/99ghosthub-snapshot
if grep -R -E '^[[:space:]]*(Snapshot:|APT::Snapshot)' /etc/apt 2>/dev/null
then
  printf 'sandbox image retains a pinned APT snapshot\n' >&2
  exit 1
fi
sudo apt-get update >/dev/null
