FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends openssh-server tmux procps \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /run/sshd \
  && useradd -m -s /bin/bash demo

COPY entry.sh /usr/local/bin/entry.sh
COPY zellij /usr/local/bin/zellij
RUN chmod +x /usr/local/bin/entry.sh /usr/local/bin/zellij

EXPOSE 22
CMD ["/usr/local/bin/entry.sh"]
