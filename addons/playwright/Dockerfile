# syntax=docker/dockerfile:1
#
# Playwright MCP add-on: a browser an agent can drive through MCP - open a
# page, click, fill in a form, read the accessibility tree, take a screenshot.
# Built on top of the base by `devenv --build --with playwright` and used with
# `devenv --with playwright <agent>`; the agent's MCP config starts it as
# `playwright-mcp`.
#
# Sessions run behind the egress filter, so everything is installed here, at
# build time. Nothing is downloaded while a session runs.

# The launcher always passes the image to build on. The default only gives a
# plain `docker build` of this directory a valid FROM, which BuildKit otherwise
# warns about (InvalidDefaultArgInFrom).
ARG BASE_IMAGE=devenv:local
FROM ${BASE_IMAGE}

# Pinned, where the agents in the base track their latest release: this is the
# server an agent drives a browser through, chosen rather than kept current.
# When moving it, take a release that has been public for at least two weeks -
# a fresh one can carry a compromised dependency before anyone has noticed.
# 0.0.83 was published on 2026-09-28.
ARG PLAYWRIGHT_MCP_VERSION=0.0.83

# At a fixed path outside any home directory, so the session finds the browser
# whichever uid it runs as.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

# The base ends as root, so this runs as root - with HOME pointed at root's own.
# The base sets HOME=/home/node for every later stage, and npm would otherwise
# leave a root-owned ~/.npm there that breaks npm for the session.
#
# --ignore-scripts: neither @playwright/mcp nor the playwright packages it pins
# have install scripts, so it costs nothing, and one appearing in a later
# release would not get to run as root at build time.
#
# The browser is installed by the playwright CLI from @playwright/mcp's own
# dependency tree rather than by `npx playwright@...`. The server pins an exact,
# often pre-release playwright build, and each build expects one browser
# revision; a playwright picked separately installs a revision the server then
# cannot find. Resolving from the server's directory finds the copy it loads,
# and the check fails the build if that CLI would read a different
# playwright-core from the server's.
#
# --no-shell: --browser chromium maps to the chrome-for-testing channel, which
# runs the full chromium build even headless. The separate headless shell is
# never launched, so it is not worth its size.
#
# Running chrome --version once fails the build if a library it needs did not
# come with --with-deps, rather than leaving that to the first session.
#
# The versions are appended to the base's record, so
# `devenv --versions --with playwright` shows what this image added.
#
# The browsers directory ends up root-owned and read-only for everyone else, for
# the reason the agents' install directories are: a session runs what the image
# was built with.
RUN export HOME=/root \
    && npm install -g --ignore-scripts "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" \
    && mcp_dir=/usr/local/lib/node_modules/@playwright/mcp \
    && test -f "${mcp_dir}/cli.js" \
    && resolve() { \
           node -p "require('path').dirname(require.resolve(process.argv[1] + '/package.json', {paths: [process.argv[2]]}))" "$1" "$2"; \
       } \
    && pw_dir="$(resolve playwright "${mcp_dir}")" \
    && core_dir="$(resolve playwright-core "${mcp_dir}")" \
    && if [ "$(resolve playwright-core "${pw_dir}")" != "${core_dir}" ]; then \
           echo "playwright's CLI and @playwright/mcp resolve different playwright-core" >&2; \
           exit 1; \
       fi \
    && node "${pw_dir}/cli.js" install --with-deps --no-shell chromium \
    && chrome="$(find "${PLAYWRIGHT_BROWSERS_PATH}" -path '*/chromium-*/chrome-linux*/chrome' -type f | head -n 1)" \
    && test -n "${chrome}" \
    && "${chrome}" --version \
    && { \
         echo "playwright-mcp: $(node -p "require(process.argv[1]).version" "${mcp_dir}/package.json")"; \
         echo "playwright:     $(node -p "require(process.argv[1]).version" "${pw_dir}/package.json")"; \
         echo "chromium:       $(node -p "const b = require(process.argv[1]).browsers.find(b => b.name === 'chromium'); b.browserVersion + ' (r' + b.revision + ')'" "${core_dir}/browsers.json")"; \
       } >> /opt/devenv/versions.txt \
    && rm -rf /var/lib/apt/lists/* \
    && npm cache clean --force \
    && rm -rf /root/.npm \
    && chown -R root:root "${PLAYWRIGHT_BROWSERS_PATH}" \
    && chmod -R a+rX,go-w "${PLAYWRIGHT_BROWSERS_PATH}"

# Where the base puts the agents' wrappers: first in PATH, root-owned and
# unwritable, so nothing in a session can replace it or put another
# playwright-mcp ahead of it.
COPY playwright-mcp /opt/devenv/bin/playwright-mcp
RUN chown root:root /opt/devenv/bin/playwright-mcp \
    && chmod 0555 /opt/devenv/bin/playwright-mcp
