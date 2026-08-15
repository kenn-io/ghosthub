# check=skip=InvalidDefaultArgInFrom
ARG UBUNTU_BASE
FROM ubuntu@${UBUNTU_BASE}

ARG APT_SNAPSHOT
ARG SOURCE_DATE_EPOCH
ARG SOURCE_REVISION
ARG IMAGE_VERSION

ENV LANG=C.UTF-8

LABEL org.opencontainers.image.url="https://github.com/kenn-io/ghosthub" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.description="Lean Linux environment for Ghosthub worktree sandboxes"

COPY packages.txt /tmp/ghosthub-packages.txt
COPY tests/image-contract.sh /opt/ghosthub/image-contract.sh

# The Ubuntu base carries Pebble as an optional service manager. Ghosthub uses
# the provider's init and its own keepalive process, so Pebble is unused.
# The minimal base has no CA bundle. APT still verifies the signed Ubuntu
# metadata and package hashes while the snapshot installs ca-certificates.
RUN set -eux; \
    printf '%s\n' \
      "APT::Snapshot \"$APT_SNAPSHOT\";" \
      'Acquire::Snapshots::URI::Host::ports.ubuntu.com "https://snapshot.ubuntu.com/ubuntu/@SNAPSHOTID@/";' \
      'Acquire::https::snapshot.ubuntu.com::Verify-Peer "false";' \
      > /etc/apt/apt.conf.d/99ghosthub-snapshot; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    xargs apt-get install -y --no-install-recommends \
      < /tmp/ghosthub-packages.txt; \
    useradd --no-log-init --create-home --shell /bin/bash ghosthub; \
    chage --lastday "$((SOURCE_DATE_EPOCH / 86400))" ghosthub; \
    printf 'ghosthub ALL=(ALL) NOPASSWD: ALL\n' \
      > /etc/sudoers.d/ghosthub; \
    chmod 0440 /etc/sudoers.d/ghosthub; \
    chmod 0755 /opt/ghosthub/image-contract.sh; \
    rm -rf /usr/bin/pebble /var/lib/pebble; \
    rm -f /etc/apt/apt.conf.d/99ghosthub-snapshot \
      /etc/group- /etc/gshadow- /etc/passwd- /etc/shadow- \
      /tmp/ghosthub-packages.txt \
      /var/cache/ldconfig/aux-cache \
      /var/log/alternatives.log /var/log/dpkg.log; \
    rm -rf /var/log/apt; \
    rm -rf /var/lib/apt/lists/*

USER ghosthub
WORKDIR /home/ghosthub
CMD ["/bin/sleep", "infinity"]
