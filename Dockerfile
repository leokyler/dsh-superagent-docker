# syntax=docker/dockerfile:1
#
# dsh-superagent in a container.
#
# The upstream project ships no image and no Dockerfile, so this builds one from
# its published source and works around the two things that do not survive
# containerization on their own: a panel that only listens on loopback, and a
# one-time interactive setup.
#
# Build:  docker build -t dsh-superagent:local .

FROM node:24-bookworm

ARG DSH_VERSION=0.2.1-rc.3
ARG SUPERAGENT_REPO=https://github.com/deepseek-ai/dsh-superagent-prototype.git
ARG SUPERAGENT_REF=main
ARG WITH_GIT_LFS=0

ENV DEBIAN_FRONTEND=noninteractive \
    TMUX_TMPDIR=/home/node/.tmux
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Prerequisites from docs/006-deployment.md. The distro's gh is too old for
# dsh-superagent (it needs 2.48+), so gh comes from GitHub's own apt repository.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git python3 tmux jq socat tini \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && { [ "$WITH_GIT_LFS" = "1" ] && apt-get install -y --no-install-recommends git-lfs || true; } \
 && rm -rf /var/lib/apt/lists/*

# The pinned DSH must satisfy engines.dsh (^0.2.1-alpha.2) in the bundle.
RUN corepack enable && npm install -g "pnpm@11" "@deepseek-ai/dsh@${DSH_VERSION}"

WORKDIR /opt
COPY patches/ /tmp/patches/
RUN git clone --depth 1 --branch "${SUPERAGENT_REF}" "${SUPERAGENT_REPO}" dsh-superagent \
 && cd dsh-superagent \
 && for patch in /tmp/patches/*.patch; do [ -e "$patch" ] || continue; git apply "$patch" || exit 1; done \
 && pnpm install \
 && pnpm build \
 && rm -rf /tmp/patches

# Directories a mounted volume inherits ownership from, so a fresh named volume
# is writable by `node` instead of being created root-owned.
RUN mkdir -p /home/node/.dsh /home/node/.config/gh-agent /home/node/.local/bin \
             /home/node/src /home/node/.tmux \
 && chown -R node:node /home/node

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER node
WORKDIR /opt/dsh-superagent

# 3082: the DSH webserver (loopback only). 13082: the socat proxy the
# entrypoint publishes to the container's network interface.
EXPOSE 3082 13082

# Runs without a ready model provider too: the API answers with setup pending,
# which is what the panel needs to show.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD curl -fsS -H 'x-orchestrator-request: 1' \
      "http://127.0.0.1:${DSH_SUPERAGENT_PORT:-3082}/orchestrator/api/state" > /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
