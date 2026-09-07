#!/bin/sh
# Gives each agent its own git identity, so history says which agent wrote
# what (the AGENTS.md convention one level up from a cloned project).
#
# Reached as /opt/devenv/bin/{claude,codex,agy} - symlinks to this script that
# sit ahead of the real binaries in PATH. The identity is therefore a property
# of the agent process, not of how the container was started: launching an
# agent from a shell inside the container attributes its commits the same way,
# and every git the agent runs inherits the identity, however deeply nested
# behind scripts of its own.
#
# Identity is agent-<DEVENV_AGENT or the agent's own name>. Set DEVENV_AGENT
# to tell two sessions of the same agent apart.
set -eu

name="${0##*/}"
target="/home/node/.local/bin/${name}"

if [ ! -x "$target" ]; then
    echo "devenv: no agent named '${name}' in the image (looked for ${target})" >&2
    exit 127
fi

slug="agent-${DEVENV_AGENT:-$name}"

GIT_AUTHOR_NAME="$slug"
GIT_AUTHOR_EMAIL="${slug}@devenv.local"
GIT_COMMITTER_NAME="$slug"
GIT_COMMITTER_EMAIL="${slug}@devenv.local"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

exec "$target" "$@"
