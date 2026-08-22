#!/bin/sh

set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(unset CDPATH; cd -- "$script_dir/.." && pwd)
fixture_source="$script_dir/ssh_fixture"
compose_file="$fixture_source/compose.yml"
kwt_binary=${GHOSTHUB_KWT_CONTRACT_BINARY:-}

if [ -z "$kwt_binary" ] || [ ! -x "$kwt_binary" ]; then
    echo "GHOSTHUB_KWT_CONTRACT_BINARY must name the pinned executable" >&2
    exit 2
fi
for executable in docker ssh ssh-keygen nc shasum; do
    command -v "$executable" >/dev/null 2>&1 || {
        echo "required executable is unavailable: $executable" >&2
        exit 2
    }
done
docker info >/dev/null 2>&1 || {
    echo "the Docker daemon is unavailable" >&2
    exit 2
}

scratch=
scratch_candidate=
kwt_home=
kwt_home_candidate=
ssh_trace=
compose_project=
cleanup() {
    status=$?
    trap - EXIT INT TERM HUP
    set +e
    if [ "$status" -ne 0 ] && [ -n "$kwt_home" ] \
        && [ -f "$kwt_home/daemon.log" ]; then
        echo "kwt daemon diagnostics:" >&2
        tail -n 80 "$kwt_home/daemon.log" >&2
    fi
    if [ "$status" -ne 0 ] && [ -n "$ssh_trace" ] \
        && [ -f "$ssh_trace" ]; then
        echo "OpenSSH diagnostics:" >&2
        tail -n 80 "$ssh_trace" >&2
    fi
    if [ -n "$compose_project" ]; then
        docker compose --project-name "$compose_project" \
            --file "$compose_file" down --volumes --remove-orphans \
            >/dev/null 2>&1
    fi
    cleanup_scratch=${scratch:-$scratch_candidate}
    case "$cleanup_scratch" in
        /tmp/ghosthub-ssh-fixture.??????)
            rm -rf -- "$cleanup_scratch"
            ;;
    esac
    cleanup_kwt_home=${kwt_home:-$kwt_home_candidate}
    case "$cleanup_kwt_home" in
        /private/tmp/k.??????)
            rm -rf -- "$cleanup_kwt_home"
            ;;
    esac
    exit "$status"
}
trap cleanup EXIT INT TERM HUP

umask 077
scratch_candidate=$(mktemp -d /tmp/ghosthub-ssh-fixture.XXXXXX)
case "$scratch_candidate" in
    /tmp/ghosthub-ssh-fixture.??????) ;;
    *) echo "unexpected SSH fixture directory" >&2; exit 1 ;;
esac
scratch=$scratch_candidate
fixture="$scratch/fixture"
bin_dir="$scratch/bin"
kwt_home_candidate=$(mktemp -d /private/tmp/k.XXXXXX)
case "$kwt_home_candidate" in
    /private/tmp/k.??????) ;;
    *) echo "unexpected kwt fixture directory" >&2; exit 1 ;;
esac
kwt_home=$kwt_home_candidate
ssh_trace="$scratch/ssh.log"
mkdir -m 700 "$fixture" "$bin_dir"
project_suffix=$(printf '%s' "${scratch##*.}" | tr '[:upper:]' '[:lower:]')
compose_project="ghosthub-ssh-$project_suffix"
image_inputs=$(shasum -a 256 \
    "$fixture_source/Dockerfile" \
    "$repo_root/images/sandbox/UBUNTU_BASE" \
    "$repo_root/images/sandbox/APT_SNAPSHOT" | shasum -a 256)
image_tag="ghosthub-ssh-fixture:${image_inputs%% *}"

export GHOSTHUB_SSH_FIXTURE_DIR="$fixture"
export GHOSTHUB_SSH_FIXTURE_IMAGE="$image_tag"

ssh-keygen -q -t ed25519 -N '' -f "$fixture/client_key"
ssh-keygen -q -t ed25519 -N 'ghosthub-fixture-passphrase' \
    -f "$fixture/interactive_key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host_key"
cp -f "$fixture/client_key.pub" "$fixture/authorized_keys"
printf '%s\n' "$(cat "$fixture/interactive_key.pub")" \
    >> "$fixture/authorized_keys"
: > "$fixture/interactive_known_hosts"
: > "$fixture/unattended_known_hosts"
chmod 600 "$fixture/client_key" "$fixture/host_key" \
    "$fixture/interactive_key" "$fixture/authorized_keys" \
    "$fixture/interactive_known_hosts" "$fixture/unattended_known_hosts"
cat > "$fixture/sshd_config" <<'EOF'
Port 22
ListenAddress 0.0.0.0
HostKey /fixture/host_key
AuthorizedKeysFile /fixture/authorized_keys
PidFile /tmp/sshd.pid
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers ghosthub
AllowTcpForwarding yes
PermitOpen any
PrintMotd no
LogLevel ERROR
EOF
chmod 600 "$fixture/sshd_config"

ubuntu_base=$(tr -d '\n' < "$repo_root/images/sandbox/UBUNTU_BASE")
apt_snapshot=$(tr -d '\n' < "$repo_root/images/sandbox/APT_SNAPSHOT")
docker build \
    --build-arg "UBUNTU_BASE=$ubuntu_base" \
    --build-arg "APT_SNAPSHOT=$apt_snapshot" \
    --file "$fixture_source/Dockerfile" \
    --tag "$image_tag" \
    "$fixture_source"
docker compose --project-name "$compose_project" \
    --file "$compose_file" up --detach --wait

target_port=$(docker compose --project-name "$compose_project" \
    --file "$compose_file" port target 22)
target_port=${target_port##*:}
relay_port=$(docker compose --project-name "$compose_project" \
    --file "$compose_file" port relay 22)
relay_port=${relay_port##*:}
for port in "$target_port" "$relay_port"; do
    attempts=0
    until nc -z -w 1 127.0.0.1 "$port"; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 30 ]; then
            echo "SSH fixture did not become ready" >&2
            exit 1
        fi
        sleep 0.1
    done
done

host_key=$(awk 'NR == 1 { print $1 " " $2 }' "$fixture/host_key.pub")
cat > "$fixture/known_hosts" <<EOF
[127.0.0.1]:$target_port $host_key
[127.0.0.1]:$relay_port $host_key
ghosthub-target $host_key
EOF
cat > "$fixture/ssh_config" <<EOF
Host ghosthub-direct
  HostName 127.0.0.1
  User ghosthub
  Port $target_port
  IdentityFile $fixture/client_key
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $fixture/known_hosts
  GlobalKnownHostsFile /dev/null
  BatchMode yes

Host ghosthub-relay
  HostName 127.0.0.1
  User ghosthub
  Port $relay_port
  IdentityFile $fixture/client_key
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $fixture/known_hosts
  GlobalKnownHostsFile /dev/null
  BatchMode yes

Host ghosthub-jumped
  HostName target
  HostKeyAlias ghosthub-target
  User ghosthub
  Port 22
  IdentityFile $fixture/client_key
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $fixture/known_hosts
  GlobalKnownHostsFile /dev/null
  BatchMode yes
  ProxyJump ghosthub-relay

Host ghosthub-unattended
  HostName 127.0.0.1
  HostKeyAlias ghosthub-unattended-target
  User ghosthub
  Port $target_port
  IdentityFile $fixture/client_key
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $fixture/unattended_known_hosts
  GlobalKnownHostsFile /dev/null
  BatchMode yes

Host ghosthub-interactive-relay
  HostName 127.0.0.1
  User ghosthub
  Port $relay_port
  IdentityFile $fixture/interactive_key
  IdentitiesOnly yes
  StrictHostKeyChecking ask
  UserKnownHostsFile $fixture/interactive_known_hosts
  GlobalKnownHostsFile /dev/null
  PreferredAuthentications publickey
  BatchMode no

Host ghosthub-interactive-jumped
  HostName target
  HostKeyAlias ghosthub-interactive-target
  User ghosthub
  Port 22
  IdentityFile $fixture/interactive_key
  IdentitiesOnly yes
  StrictHostKeyChecking ask
  UserKnownHostsFile $fixture/interactive_known_hosts
  GlobalKnownHostsFile /dev/null
  PreferredAuthentications publickey
  BatchMode no
  ProxyJump ghosthub-interactive-relay
EOF
chmod 600 "$fixture/known_hosts" "$fixture/ssh_config"

cat > "$bin_dir/ssh" <<'EOF'
#!/bin/sh
for argument do
    if [ "$argument" = "-G" ]; then
        exec /usr/bin/ssh -F "$GHOSTHUB_TEST_SSH_CONFIG" "$@"
    fi
    if [ "$argument" = "-V" ]; then
        exec /usr/bin/ssh "$@"
    fi
done
exec /usr/bin/ssh "$@" 2>> "$GHOSTHUB_TEST_SSH_TRACE"
EOF
chmod 700 "$bin_dir/ssh"

export GHOSTHUB_TEST_SSH_CONFIG="$fixture/ssh_config"
export GHOSTHUB_TEST_SSH_TRACE="$ssh_trace"
export PATH="$bin_dir:$PATH"
unset SSH_AUTH_SOCK GIT_DIR GIT_WORK_TREE GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

ssh -F "$fixture/ssh_config" ghosthub-direct printf fixture-ready \
    | grep -qx fixture-ready
ssh -F "$fixture/ssh_config" ghosthub-jumped printf fixture-ready \
    | grep -qx fixture-ready

GHOSTHUB_RUN_LIVE_INTEGRATION_TESTS=1 \
GHOSTHUB_REQUIRE_SSH_INTERACTION_FIXTURE=1 \
GHOSTHUB_SSH_INTEGRATION_DESTINATION=ghosthub-direct \
GHOSTHUB_SSH_PROXYJUMP_INTEGRATION_DESTINATION=ghosthub-jumped \
GHOSTHUB_SSH_INTERACTIVE_INTEGRATION_DESTINATION=ghosthub-interactive-jumped \
GHOSTHUB_SSH_UNATTENDED_INTEGRATION_DESTINATION=ghosthub-unattended \
GHOSTHUB_SSH_UNATTENDED_KNOWN_HOSTS="$fixture/unattended_known_hosts" \
GHOSTHUB_SSH_INTEGRATION_KWT_HOME="$kwt_home" \
GHOSTHUB_KWT_CONTRACT_BINARY="$kwt_binary" \
    sh "$repo_root/tools/run_swift_tests.sh" \
        swift test --filter KwtSSHLiveIntegrationTests
