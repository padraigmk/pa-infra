FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git tmux cron \
      python3 python3-venv python3-pip \
      nodejs npm \
      ripgrep jq unzip zip less nano vim-tiny locales tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_GB.UTF-8

# London clock everywhere — session, cron jobs, subprocesses — regardless of
# env inheritance (Cal's 2026-08-10 BST bug: bare `date` ran an hour behind).
ENV TZ=Europe/London
RUN ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime \
    && echo Europe/London > /etc/timezone

# uid 1000 must match padraig on the host so the bind mounts are writable.
# Ubuntu's base image ships a stock 'ubuntu' user at uid 1000 — replace it.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash cal

# Tools installed system-wide (/usr/local), never into /home/cal — the home
# directory is a bind mount at runtime and would shadow anything put there.
RUN npm install -g @anthropic-ai/claude-code @tobilu/qmd
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
