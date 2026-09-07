# syntax=docker/dockerfile:1
#
# Sandboxed environment for coding agents: Claude Code, Codex CLI,
# Antigravity CLI. Agents run unprivileged; the only writable window into the
# host is the project directory bind-mounted at /app.

FROM node:24.20.0-slim

# Pinned tool versions. Override at build time with --build-arg.
# Antigravity CLI cannot be pinned: its installer only fetches the manifest's
# latest build. The resolved version is recorded in /opt/devenv/versions.txt.
ARG CLAUDE_CODE_VERSION=2.1.263
ARG CODEX_VERSION=0.153.4
ARG MONGOSH_VERSION=2.10.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        zstd \
        less \
        procps \
        util-linux \
        iptables \
        ipset \
        iproute2 \
        dnsutils \
    && rm -rf /var/lib/apt/lists/*

# MongoDB shell. Node is already present in the base image, so npm is the
# lightest route; no extra apt repository needed.
RUN npm install -g "mongosh@${MONGOSH_VERSION}" \
    && npm cache clean --force

# Codex installs its runtime under CODEX_HOME. At build time that points into
# the image so the binary is baked in; at run time CODEX_HOME is redirected to
# the credential volume. The launcher symlink stores an absolute path, so it
# keeps resolving into the image after the variable changes.
RUN mkdir -p /opt/codex /opt/devenv /etc/devenv \
    && chown -R node:node /opt/codex

# ---------------------------------------------------------------------------
# Agents, installed as the unprivileged user
# ---------------------------------------------------------------------------
USER node
ENV HOME=/home/node
ENV PATH=/home/node/.local/bin:${PATH}

RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"

RUN export CODEX_HOME=/opt/codex \
           CODEX_INSTALL_DIR=/home/node/.local/bin \
           CODEX_NON_INTERACTIVE=true \
           CODEX_RELEASE="${CODEX_VERSION}" \
    && curl -fsSL https://chatgpt.com/codex/install.sh | sh

RUN curl -fsSL https://antigravity.google/cli/install.sh | bash

# ---------------------------------------------------------------------------
# Runtime configuration
# ---------------------------------------------------------------------------
USER root

# Record what actually landed in the image. Antigravity is unpinnable, so this
# file is the only record of which build a given image contains.
RUN { \
      echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
      echo "claude: $(su node -c 'claude --version' 2>/dev/null || echo unknown)"; \
      echo "codex:  $(su node -c 'codex --version'  2>/dev/null || echo unknown)"; \
      echo "agy:    $(su node -c 'agy --version'    2>/dev/null || echo unknown)"; \
      echo "node:   $(node --version)"; \
    } > /opt/devenv/versions.txt

# Agents self-update by writing into their own install directory. Making it
# read-only pins the versions to the image, which is the point of baking them
# in. DISABLE_AUTOUPDATER stops Claude Code from trying in the first place.
RUN chown -R root:root /home/node/.local /opt/codex \
    && chmod -R a-w /home/node/.local /opt/codex

ENV DISABLE_AUTOUPDATER=1
ENV CODEX_HOME=/home/node/.codex

# UTF-8. The slim base ships no locales package and falls back to
# ANSI_X3.4-1968, where non-ASCII breaks in ways that are hard to attribute:
# `wc -m` counts bytes, case conversion and sorting mangle text, and anything
# that asks the locale for an encoding gets ASCII. C.UTF-8 is built into glibc,
# so this costs no package and no image size.
#
# Deliberately set here rather than before the installs: an earlier ENV would
# invalidate every layer after it, and since the Antigravity version cannot be
# pinned, a full rebuild can silently change which build is in the image. The
# build steps themselves are ASCII either way.
ENV LANG=C.UTF-8

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/init-firewall.sh

# Per-agent git identity. The wrappers shadow the real binaries in PATH, so an
# agent started from a shell inside the container is attributed the same way as
# one started by the launcher. The directory is root-owned and unwritable for
# the same reason ~/.local is: a writable wrapper would be a way around the
# pinned versions.
COPY agent-identity.sh /opt/devenv/bin/agent-identity
RUN chmod 0555 /opt/devenv/bin/agent-identity \
    && for agent in claude codex agy; do \
           ln -s agent-identity "/opt/devenv/bin/${agent}"; \
       done \
    && chown -R root:root /opt/devenv/bin \
    && chmod a-w /opt/devenv/bin

ENV PATH=/opt/devenv/bin:${PATH}

# git has no per-user config in this image and the home directory's owner
# varies with DEVENV_UID, so the global config lives outside it. entrypoint.sh
# regenerates the file on every start.
ENV GIT_CONFIG_GLOBAL=/etc/devenv/gitconfig

WORKDIR /app

# Starts as root only long enough to apply the egress filter, then drops to
# the node user for the actual session.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
