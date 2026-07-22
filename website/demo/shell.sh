# shellcheck shell=bash
# Launch demo panes through a known shell and configuration directory. tmux's
# default-shell may come from the user's account and ZDOTDIR may be inherited
# from the launcher, so setting HOME alone is not an isolation boundary.
demo_new_session() {
  local scratch="$1" name="$2" dir="$3"
  shift 3
  if (( $# > 1 )); then
    echo "error: demo session commands must be passed as one shell string" >&2
    return 1
  fi

  tmux new-session -d -x 210 -y 55 -s "$name" -c "$dir" \
    -e HOME="$scratch/home" \
    -e ZDOTDIR="$scratch/home" \
    -e SHELL=/bin/zsh \
    "/bin/zsh -l"
  if (( $# == 1 )); then
    tmux send-keys -t "$name" "$1" Enter
  fi
}
