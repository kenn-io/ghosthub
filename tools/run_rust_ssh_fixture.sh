#!/bin/sh

# Run a Linux client against disposable OpenSSH and multiplexer inventory.
set -eu

if [ "${GHOSTHUB_SSH_FIXTURE:-}" = "" ]; then
    test "$#" -gt 0 || { echo "usage: $0 executable [arguments...]" >&2; exit 2; }
    for tool in bwrap ssh ssh-keygen tmux; do
        command -v "$tool" >/dev/null
    done
    test -x /usr/sbin/sshd
    umask 077
    fixture=$(mktemp -d /tmp/gh-ssh.XXXXXX)
    trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM
    cp -f -- "$0" "$fixture/fixture.sh"
    cp -f -- "$1" "$fixture/client"
    if [ -n "${GHOSTHUB_HERDR_TEST:-}" ]; then
        mkdir -p "$fixture/bin"
        cp -f -- "$GHOSTHUB_HERDR_TEST" "$fixture/bin/herdr"
    fi
    if [ -n "${GHOSTHUB_ZELLIJ_TEST:-}" ]; then
        mkdir -p "$fixture/bin"
        cp -f -- "$GHOSTHUB_ZELLIJ_TEST" "$fixture/bin/zellij"
    fi
    shift
    printf 'ghosthub:x:%s:%s:Fixture:%s/home:/bin/sh\nsshd:x:65534:65534:SSH:/run/sshd:/usr/sbin/nologin\n' "$(id -u)" "$(id -g)" "$fixture" > "$fixture/passwd"
    printf 'ghosthub:x:%s:\nsshd:x:65534:\n' "$(id -g)" > "$fixture/group"
    printf 'ghosthub::20000:0:99999:7:::\nsshd:!:20000:0:99999:7:::\n' > "$fixture/shadow"
    : > "$fixture/ssh_system_config"

    # Rebind explicitly supplied library directories after hiding the host /tmp.
    # The client itself is staged so Cargo target directories under /tmp work.
    set -- -- /bin/sh "$fixture/fixture.sh" "$@"
    old_ifs=$IFS
    IFS=:
    for library in ${LD_LIBRARY_PATH:-}; do
        test -z "$library" && continue
        library=$(realpath -- "$library")
        set -- --ro-bind "$library" "$library" "$@"
    done
    IFS=$old_ifs
    env -i PATH=/usr/bin:/bin LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
        GHOSTHUB_SSH_FIXTURE="$fixture" \
        bwrap --unshare-user --unshare-pid --unshare-net \
        --unshare-uts --hostname ghosthub-fixture --die-with-parent \
        --ro-bind / / --tmpfs /tmp --bind "$fixture" "$fixture" \
        --tmpfs /run --proc /proc --dev /dev \
        --ro-bind "$fixture/passwd" /etc/passwd \
        --ro-bind "$fixture/group" /etc/group \
        --ro-bind "$fixture/shadow" /etc/shadow \
        --ro-bind "$fixture/ssh_system_config" /etc/ssh/ssh_config \
        --chdir "$fixture" "$@"
    exit
fi

root=$GHOSTHUB_SSH_FIXTURE
export HOME="$root/home" SHELL=/bin/sh LANG=C.UTF-8 TERM=xterm-256color
export KWT_HOME="$root/kwt" GHOSTHUB_HOME="$root/ghosthub"
export GHOSTHUB_CONFIG_HOME="$root/config" GHOSTHUB_STATE_HOME="$root/state with spaces"
export XDG_CONFIG_HOME="$root/xdg/config" XDG_STATE_HOME="$root/xdg/state"
export XDG_DATA_HOME="$root/xdg/data" XDG_CACHE_HOME="$root/xdg/cache"
export XDG_RUNTIME_DIR="$root/runtime" GIT_CONFIG_GLOBAL="$root/gitconfig" GIT_CONFIG_NOSYSTEM=1
umask 077
mkdir -p "$HOME/.ssh" "$KWT_HOME" "$GHOSTHUB_CONFIG_HOME" "$GHOSTHUB_STATE_HOME" \
    "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" \
    "$XDG_RUNTIME_DIR" "$root/tmux" /run/sshd
if [ -d "$root/bin" ]; then
    cat > "$HOME/.profile" <<EOF
export PATH="$root/bin:/usr/bin:/bin"
export XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME"
export XDG_DATA_HOME="$XDG_DATA_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME"
export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
export ZELLIJ_CONFIG_DIR="$XDG_CONFIG_HOME/zellij"
EOF
fi
if [ -x "$root/bin/herdr" ]; then
    mkdir -p "$XDG_CONFIG_HOME/herdr"
    cat > "$XDG_CONFIG_HOME/herdr/config.toml" <<EOF
onboarding = false
[terminal]
default_shell = '/bin/sh'
shell_mode = 'non_login'
EOF
fi
if [ -x "$root/bin/zellij" ]; then
    mkdir -p "$XDG_CONFIG_HOME/zellij/layouts"
    cat > "$XDG_CONFIG_HOME/zellij/config.kdl" <<EOF
default_shell "/bin/sh"
default_layout "test"
pane_frames false
show_release_notes false
show_startup_tips false
EOF
    printf 'layout { pane; }\n' > "$XDG_CONFIG_HOME/zellij/layouts/test.kdl"
fi
: > "$GIT_CONFIG_GLOBAL"
ssh-keygen -q -t ed25519 -N '' -f "$root/client_key"
ssh-keygen -q -t ed25519 -N '' -f "$root/host_key"
cp -f "$root/client_key.pub" "$root/authorized_keys"
cat > "$root/sshd_config" <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey $root/host_key
AuthorizedKeysFile $root/authorized_keys
# The read-only host root is owned by an unmapped UID in this namespace.
StrictModes no
PidFile $root/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PrintMotd no
LogLevel VERBOSE
EOF
cat > "$HOME/.ssh/config" <<EOF
Host studio.example
  HostName 127.0.0.1
  Port 2222
  User ghosthub
  IdentityFile $root/client_key
  IdentitiesOnly yes
  IdentityAgent none
  StrictHostKeyChecking ask
  UserKnownHostsFile $HOME/.ssh/known_hosts
  GlobalKnownHostsFile /dev/null
EOF
cat > "$GHOSTHUB_CONFIG_HOME/config.toml" <<EOF
[local]
socket-directory = "$root/local-tmux"

[[ssh-host]]
name = "Studio"
hostname = "studio.example"
tmux-binary = "/usr/bin/tmux"
socket-directory = "$root/tmux"
EOF
mkdir "$root/local-tmux"
TMUX_TMPDIR="$root/tmux" tmux -f /dev/null new-session -d -s review /bin/sh
TMUX_TMPDIR="$root/tmux" tmux new-session -d -s "notes 'one'" /bin/sh
/usr/sbin/sshd -D -e -f "$root/sshd_config" > "$root/sshd.log" 2>&1 &
sshd_pid=$!
trap 'if [ "$?" -ne 0 ]; then cat "$root/sshd.log" >&2; fi' EXIT
attempt=0
until test -s "$root/sshd.pid"; do
    kill -0 "$sshd_pid"
    attempt=$((attempt + 1))
    test "$attempt" -lt 100
    sleep 0.02
done
"$root/client" "$@"
