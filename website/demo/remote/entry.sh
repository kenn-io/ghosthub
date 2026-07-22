#!/usr/bin/env bash
# Container entrypoint: authorize the host user's key, start sshd, and stage
# raw tmux sessions that look like a busy remote GPU box.
set -euo pipefail

if [[ -n "${AUTHORIZED_KEYS:-}" ]]; then
  mkdir -p /home/demo/.ssh
  printf '%s\n' "$AUTHORIZED_KEYS" > /home/demo/.ssh/authorized_keys
  chown -R demo:demo /home/demo/.ssh
  chmod 700 /home/demo/.ssh
  chmod 600 /home/demo/.ssh/authorized_keys
fi

sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

mkdir -p /var/log/demo
cat > /usr/local/bin/serve-log.sh <<'EOF'
#!/usr/bin/env bash
i=1180
while true; do
  ms=$((28 + RANDOM % 90))
  tok=$((140 + RANDOM % 700))
  printf 'INFO %s   200 POST /v1/completions  req=%d  tokens=%d  %dms\n' \
    "$(date -u '+%H:%M:%S')" "$i" "$tok" "$ms" >> /var/log/demo/serve.log
  i=$((i + 1))
  sleep 2
done
EOF
cat > /usr/local/bin/train-log.sh <<'EOF'
#!/usr/bin/env bash
step=48210
loss=0.4137
while true; do
  loss=$(awk -v l="$loss" 'BEGIN { printf "%.4f", l * 0.99993 }')
  printf 'step %d | loss %s | lr 2.4e-5 | 8.1k tok/s | eta 3h12m\n' \
    "$step" "$loss" >> /var/log/demo/train.log
  step=$((step + 10))
  sleep 3
done
EOF
chmod +x /usr/local/bin/serve-log.sh /usr/local/bin/train-log.sh

# Ghosthub probes remote hosts with `command -v kwt`; without this shim the
# sidebar shows a "status 127" inventory error. No kwt projects remotely --
# the box only carries raw tmux sessions.
cat > /usr/local/bin/kwt <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  projects|list) echo "[]" ;;
  *) exit 64 ;;
esac
EOF
chmod +x /usr/local/bin/kwt
chown -R demo:demo /var/log/demo

su - demo -c '
  nohup /usr/local/bin/serve-log.sh >/dev/null 2>&1 &
  nohup /usr/local/bin/train-log.sh >/dev/null 2>&1 &
  sleep 1
  tmux new-session -d -s vllm-serve \
    "tail -n 40 -f /var/log/demo/serve.log"
  tmux new-session -d -s train-rl \
    "tail -n 40 -f /var/log/demo/train.log"
'

exec /usr/sbin/sshd -D -e
