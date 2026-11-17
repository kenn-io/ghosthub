ARG UBUNTU_BASE=sha256:7e7957462d7b6db141de67623f46135d82a6bc131bc2ff369aedfccfa91c0a1b
FROM ubuntu@${UBUNTU_BASE}

ARG APT_SNAPSHOT=20261112T021708Z

RUN set -eux; \
    printf '%s\n' \
      "APT::Snapshot \"$APT_SNAPSHOT\";" \
      'Acquire::Snapshots::URI::Host::ports.ubuntu.com "https://snapshot.ubuntu.com/ubuntu/@SNAPSHOTID@/";' \
      'Acquire::https::snapshot.ubuntu.com::Verify-Peer "false";' \
      > /etc/apt/apt.conf.d/99ghosthub-snapshot; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends openssh-server; \
    useradd --no-log-init --create-home --shell /bin/sh ghosthub; \
    passwd -d ghosthub; \
    mkdir -p /run/sshd; \
    rm -f /etc/apt/apt.conf.d/99ghosthub-snapshot \
      /var/log/alternatives.log /var/log/dpkg.log; \
    rm -rf /var/log/apt /var/lib/apt/lists/*

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D", "-e", "-f", "/fixture/sshd_config"]
