# devenv

A disposable, network-restricted sandbox for coding agents.

Runs **Claude Code**, **Codex CLI**, and **Antigravity CLI** as an unprivileged
user inside a container whose only writable window into your machine is the
directory you launch it from. Agent versions are fixed by the image; outbound
traffic is limited to an allowlist you control.

Built for a Node/TypeScript/MongoDB stack, but the toolchain is a few lines in
the Dockerfile.

---

## Why

Coding agents are useful in proportion to how much they are allowed to do,
which is also the problem. Run one directly on your machine and it can read
your SSH keys, your cloud credentials, and every file you own. Most of the time
that is fine. The times it is not are expensive.

This puts a boundary around the agent instead of relying on it to stay
in bounds:

- **Filesystem** — only the launch directory is mounted. Nothing else exists.
- **Privileges** — no root, no sudo binary in the image.
- **Network** — outbound traffic restricted to hosts you list.
- **Versions** — fixed in the image, so `devenv --update` is the only thing
  that changes what runs. Install directories are read-only, which also stops
  the agents' own background self-updaters.
- **Disposable** — `--rm`. Nothing survives except the project and your login.

---

## Requirements

Docker and bash. Nothing else — no Node, no agent installed on the host.

On Windows, use WSL2 with Docker CE **inside the distribution** rather than
Docker Desktop, so `wsl --shutdown` returns the machine to zero background
usage.

---

## Install

```bash
git clone https://github.com/<you>/devenv.git
cd devenv
./devenv --build
```

Optionally put the launcher on your `PATH`. The symlink is followed back to the
clone, so `allowlist.txt`, `.env.local` and the `Dockerfile` are still found
there, and the directory you launch from stays whatever you happen to be in:

```bash
ln -s "$PWD/devenv" ~/.local/bin/devenv
```

To keep the allowlist somewhere else — shared between checkouts, or under your
own config directory — name it explicitly. Everything else still comes from the
clone:

```bash
# in .env.local next to the launcher, or exported in your shell
DEVENV_ALLOWLIST_FILE=$HOME/.config/devenv/allowlist.txt
```

---

## Use

Run it from the project you want to work on:

```bash
cd ~/projects/my-service
devenv claude          # Claude Code, scoped to this directory
devenv codex
devenv agy
devenv                 # plain shell
```

First run of each agent prompts for login. Credentials are stored in Docker
named volumes (`devenv-claude`, `devenv-codex`, `devenv-gemini`), so the login
survives container recreation and never touches your project directory.

**Only the named agent's volume is mounted.** `devenv codex` sees
`devenv-codex` and neither of the others, so one agent cannot read another's
token. Starting without naming an agent — a plain shell, or any other command —
mounts all three, because an agent started from that shell would otherwise walk
into a login whose result dies with the container. The launcher says which case
you are in.

| Flag | Effect |
| --- | --- |
| `--build` | Build the image and exit |
| `--update` | Rebuild the agents at their latest versions, then exit |
| `--open` | Start without the egress filter |
| `--nested-sandbox` | Allow user namespaces, so an agent's own sandbox can run — see [An agent's own sandbox](#an-agents-own-sandbox) |
| `--versions` | Print the tool versions baked into the image |
| `--with NAME` | Run on top of the add-on in `addons/NAME`, for this run only. Repeatable; with `--build` or `--update`, builds it — see [Add-ons](#add-ons) |
| `--host-port PORT` | Let the session reach this TCP port on the host, as `host.docker.internal`. Repeatable, for this run only — see [Reaching services on the host](#reaching-services-on-the-host) |

**devenv's flags go before the command.** The launcher reads flags until the
first word that is not one, and everything from there on is the command run
in the container, flags included:

```bash
devenv --host-port 3005 claude      # right: devenv opens port 3005
devenv claude --host-port 3005      # wrong: Claude Code gets --host-port and rejects it
```

The same goes for `--with`, `--open` and the rest. Anything after `--` is
passed through untouched as well:

```bash
devenv -- claude --version
```

Only one session runs per directory; a second launch in the same directory is
refused. See [Working with more than one agent](#working-with-more-than-one-agent).

---

## Working with more than one agent

The sandbox draws a boundary around one agent. Running several is a matter of
convention, and nothing in here enforces it — what follows are the conventions
this setup is built around. `AGENTS.md.example` is a starting point you can
copy into your own project so the agents read them too. Each agent picks up its
own context file; `AGENTS.md` is the common name, and Claude Code's is
`CLAUDE.md`, so a one-line `CLAUDE.md` containing `@AGENTS.md` keeps every
agent on one copy.

### One session per directory

The launcher labels each container `devenv=<launch directory>` and refuses to
start a second one for a directory that already has a session.

This is not caution about a rare race. Two agents in one working tree lose each
other's work as a matter of course: editing a file is read-modify-write and
nothing about it is transactional, so the second agent's write lands on top of
a file it read before the first agent touched it. Add a formatter, or a test
runner writing snapshots, and it gets worse. One tree, one agent.

### One working tree per agent

Which means that running agents in parallel is a question of giving each its
own directory.

**A clone per agent** is what fits the sandbox. It is self-contained, so
mounting it needs nothing else:

```bash
git clone ~/dev/project ~/dev/project-claude
cd ~/dev/project-claude && devenv claude
```

The branch comes back by fetching it out of the clone. No GitHub in the loop,
no push credentials in the container:

```bash
cd ~/dev/project
git fetch ../project-claude agent/claude/topic:agent/claude/topic
```

`git push` from inside the container does not work here, and that is not a
misconfiguration to fix: a local clone records `origin` as an absolute host
path, and that path is not mounted. Fetching from the host is the same
operation with the direction reversed. Having the agent do the pushing means
mounting the main repository too — the cost of which is described next.

**A `git worktree` per agent** is the more common habit. It works, but not by
mounting the worktree alone: a worktree's `.git` is a file pointing into the
main repository's `.git/worktrees/<name>`, which sits outside the directory
being mounted, so git in the container says

```
fatal: not a git repository: <main repo>/.git/worktrees/<name>
```

Mounting the main repository's `.git` at the same absolute path fixes it:

```bash
docker run ... -v "$HOME/dev/project/.git:$HOME/dev/project/.git" ...
```

The cost, plainly: the agent gets write access to the entire shared repository
— other branches, other agents' worktrees, and `.git/hooks`, from where a hook
it writes runs on **your** machine the next time you use git. The host's
directory layout ends up inside the container as well. The launcher has no flag
for this on purpose; choosing it should take deliberate effort.

### Branches and review

Branch names carry the agent: `agent/<name>/<topic>`, using the same slug as
the commit identity, so `git log` and `git branch` agree about who did what —
`agent-claude` commits on `agent/claude/…`.

Nothing reaches `main` except through a pull request a human has read. The
container holds no push credentials and no SSH agent, which makes that the path
of least resistance rather than a rule to remember: the branch reaches the
host, you read the diff, you open the PR.

### Handing work over

An agent that stops mid-task leaves a note at `docs/agent-notes/<branch>.md` —
what it did, what is unfinished, where it is unsure — and the next agent reads
the matching note before continuing. Agents reconstruct intent from a diff
easily and reconstruct what was already tried and rejected not at all.

### How many at once

Fewer than the core count suggests. An agent on a heavy task is not one
process: `tsc`, a test runner's workers, a bundler and an install step each
parallelise on their own, so one agent can occupy several cores for minutes at
a time. Budget roughly four cores per agent doing build-heavy work — two agents
on an eight-core machine. A third mostly buys context switching, and every
agent gets slower, including the one you are watching.
[Resource limits](#resource-limits) cap what a single session may take, so one
agent cannot starve the others.

---

## Git identity

`git` in a fresh container has no identity, so a commit would simply fail. Each
agent gets one, and it belongs to the agent process rather than to the
container: `/opt/devenv/bin` holds wrappers named `claude`, `codex` and `agy`
that sit ahead of the real binaries in `PATH`, export `GIT_AUTHOR_*` and
`GIT_COMMITTER_*`, and hand over to the real thing. Starting an agent from a
shell inside the container is therefore attributed exactly like launching it
directly, and every `git` the agent runs inherits the identity, however deeply
nested behind scripts of its own.

| Launched | Commits as |
| --- | --- |
| `claude` | `agent-claude <agent-claude@devenv.local>` |
| `codex` | `agent-codex <agent-codex@devenv.local>` |
| `agy` | `agent-agy <agent-agy@devenv.local>` |
| plain shell | `devenv <devenv@devenv.local>` |

`.local` is reserved for mDNS and is never routable, so none of these addresses
can receive anything. Set `DEVENV_AGENT` in `.env.local` to tell two sessions
of the same agent apart — `DEVENV_AGENT=claude-review` commits as
`agent-claude-review`.

The config lives at `/etc/devenv/gitconfig`, regenerated on every start and
pointed at by `GIT_CONFIG_GLOBAL`. It is deliberately not in the home
directory, whose owner changes with `DEVENV_UID`. It also marks `/app` as a
safe directory: the mount's owner is the host's business, and without that
entry git refuses to work in a directory owned by another uid. Only the mount
point itself is listed — git supports no globbing there, and the blanket `*`
would turn the check off entirely — so on a host where the uid cannot be
aligned, a repository in a *subdirectory* of `/app` needs its own
`safe.directory` entry. git prints the exact command when that happens.

Push credentials are yours, not the container's. There is no SSH agent and no
token inside; a push happens from the host, after you have read the diff.

---

## Updating agents

Every agent installs its latest release when the image is built, and the image
keeps that version until you ask for another:

```bash
./devenv --update
```

It reinstalls the three agents and prints what landed in the image;
`./devenv --versions` prints the same later, from
`/opt/devenv/versions.txt`. The layers below the agents — Debian packages,
mongosh — come from the build cache unless the base image has changed. To
rebuild those as well, run `docker build --no-cache -t devenv:local .`.

`./devenv --build` does not move the versions. With "latest" as the version
nothing in the Dockerfile changes between builds, so it keeps the agents of the
image it replaces — as long as their layers are still in the build cache. Once
they have been pruned, it installs whatever is latest at that moment.

What this costs: builds are not reproducible. Two machines that last updated on
different days run different versions, and a release with a regression reaches
you as soon as you update. To hold an agent back, pin it with a build argument:

```bash
docker build --build-arg CLAUDE_CODE_VERSION=2.1.263 \
             --build-arg CODEX_VERSION=0.153.4 -t devenv:local .
```

Claude Code also accepts `stable`, a release about a week old that skips
releases with major regressions. **Antigravity CLI cannot be pinned**: its
installer takes no version and only fetches the manifest's current build.

---

## The egress filter

Domains in `allowlist.txt` are resolved when the container starts and pinned as
addresses. Everything else is rejected. Denied attempts are logged with the
prefix `devenv-deny:`.

Editing the list needs no rebuild — change the file, restart the container.

**What this is not.** It is a speed bump, not a wall:

- Large CDNs rotate addresses. A long session may start seeing denials for
  hosts that worked earlier. Restart to re-resolve.
- Anything reachable is a potential exfiltration channel, and development
  requires reaching a git host. An allowlist containing GitHub does not prevent
  a determined agent from pushing data to it.

The protections that actually matter are procedural: keep production
credentials out of the container, and review diffs before merging.

Use `--open` when you are fighting a dependency and need the filter out of the
way. It prints a warning; that is deliberate.

---

## Reaching services on the host

A dev server, a database in a docker container on the host, an API the project
talks to locally — the egress filter blocks all of them, since the host is just
another address. `--host-port` opens one TCP port on the host for one session:

```bash
devenv --host-port 3000 claude
devenv --host-port 3000 --host-port 27017 claude    # repeatable
```

```
devenv: host ports open this session: 3000 27017 (host.docker.internal)
...
devenv: host access: 172.17.0.1 tcp/3000 tcp/27017
```

Inside the session the host is `host.docker.internal` —
`http://host.docker.internal:3000`, `mongodb://host.docker.internal:27017`.

**What it opens, exactly.** The launcher checks each port (a number from 1 to
65535, no leading zero), drops duplicates, adds
`--add-host=host.docker.internal:host-gateway` and hands the ports to the
container. The filter then adds one rule per port: TCP to that port on the
host's gateway address, nothing else. Every other port on the host stays
closed, and so does UDP. Like `--nested-sandbox`, it is a flag only, with no
setting in `.env.local`: a hole in the filter is chosen per session, not once
and forgotten. With `--open` there is no filter to open, and the launcher says
so; `host.docker.internal` is still added.

**Why not put the gateway in `allowlist.txt`.** The allowlist matches
addresses, not ports. Listing the host's address would open every service on
it — sshd, every database, a docker API listening on TCP — to the session.

**Where the address comes from.** Only from the container's `/etc/hosts`, the
entry docker writes for `--add-host=host.docker.internal:host-gateway`. DNS is
never asked: on Docker Desktop and WSL the host's resolver answers for
`host.docker.internal` by itself — a container started without `--add-host`
got `127.0.0.1` that way — and whatever address DNS returned, the ports would
be opened to it. The address must also be private (10/8, 172.16/12,
192.168/16): `host-gateway` is the address of docker's bridge, which always is,
so loopback, `0.0.0.0` or a public address means the entry did not come from
`--add-host`. In any of these cases — no entry, two different addresses, an
address that is not private, a malformed port — the container refuses to start
rather than open anything. The ports are checked again inside the container
for the same reason: the filter runs as root, and its input is an environment
variable anything starting the container could set.

### The service has to listen where the container can reach it

Traffic from the container arrives on the docker bridge, not on the host's
loopback. **A service bound only to `127.0.0.1` on the host is unreachable**
from the session, port open or not.

- A process you run yourself: bind it to `0.0.0.0` (`--host 0.0.0.0`,
  `HOST=0.0.0.0`, whatever its option is called). That also exposes it to your
  local network, which is fine on a laptop at home and worth a thought
  elsewhere.
- A service in docker on the host: keep the loopback publication and add one on
  the bridge address. The service is then visible to containers, and still not
  to your network:

  ```bash
  docker run -p 127.0.0.1:27017:27017 -p 172.17.0.1:27017:27017 mongo
  ```

  ```yaml
  # compose
  ports:
    - "127.0.0.1:27017:27017"
    - "172.17.0.1:27017:27017"
  ```

  `172.17.0.1` is the address of the default bridge. If yours differs, the
  `host access:` line at session start prints the one in use.

If the port is open and the service listens on the right address but the
connection still times out, look at the host's own firewall (firewalld, ufw):
traffic from the bridge to the host goes through it.

---

## An agent's own sandbox

Codex sandboxes the shell commands it runs, with bubblewrap and user
namespaces. Neither works in here by default: docker's seccomp profile denies
unprivileged user namespaces, so every command Codex attempts fails with

```
bwrap: No permissions to create a new namespace
```

after which Codex asks you to approve the command and runs it with no sandbox
at all. Nothing is broken — commands do run — but the `Workspace (Ask for
approval)` in its header only delivers the second half, and you approve every
command by hand.

Installing the `bubblewrap` package does not help. Debian's binary is not
setuid and fails identically; what blocks it is the seccomp profile, not the
missing package.

`--nested-sandbox` lifts that:

```bash
devenv --nested-sandbox codex
```

Measured with it on: user namespaces work, `codex sandbox` runs commands
instead of failing, writes outside the workspace are refused, and network from
a sandboxed command is blocked. The egress filter is unaffected — the allowlist
still applies to the session as a whole. Whether it also stops the per-command
approval prompts is Codex's own policy rather than something this flag decides.

**What it costs.** The session runs with docker's seccomp filter off, widening
the set of syscalls reachable from inside the container. The session's process
is unprivileged and holds no capabilities, which limits what that is worth to
an attacker, but the reduction is real. It is a per-session flag with no
environment variable behind it on purpose: this should not be something set
once in `.env.local` and forgotten. `--cap-add=SYS_ADMIN` would work too, and
is worse — a capability that is itself a way out of a container.

**What it does not fix.** Codex's sandbox restricts writes and network, not
reads: a sandboxed command can still read anything in the container, mounted
credential volumes included. That is why only the launched agent's volume is
mounted at all.

Claude Code and Antigravity CLI do not sandbox their own commands, so the flag
changes nothing for them.

---

## Resource limits

Nothing is limited by default. A session may use every core and all the memory
on the machine, which is what you want while you are watching it and the wrong
thing as soon as a second agent — or you — needs the machine to stay
responsive. Set these in `.env.local`; unset means unlimited.

| Variable | docker flag | Effect |
| --- | --- | --- |
| `DEVENV_CPUS` | `--cpus` | CPU share. Read the next section before picking a number |
| `DEVENV_MEMORY` | `--memory` | Memory ceiling for the session |
| `DEVENV_MEMORY_SWAP` | `--memory-swap` | Total of memory plus swap. Defaults to `DEVENV_MEMORY`, which means no swap |
| `DEVENV_PIDS` | `--pids-limit` | Cap on processes and threads |

`DEVENV_PIDS` earns its place. A runaway install or test runner multiplies
processes faster than it burns CPU, and without a cap it takes the host down
rather than the session. Exceeding it looks like `sh: 0: Cannot fork`.

### `--cpus` is a quota, and your build tools disagree about what it means

Worth knowing before you pick a number, because it can make a limited session
slower than an unlimited one: **`--cpus` caps the CPU share, not the number of
cores the container can see.** Measured in this image:

| `docker run` | `nproc` | Node's `os.availableParallelism()` |
| --- | --- | --- |
| `--cpus=4` | **16** | 4 |
| `--cpus=2.5` | **16** | 2 |
| `--cpuset-cpus=0-1` | 2 | 2 |

Node reads the cgroup quota, so Node-based tooling sizes its worker pools
correctly. `nproc` reads the CPU affinity mask, which a quota does not touch,
so it goes on reporting the host's core count. Anything built on it —
`make -j$(nproc)`, `pytest -n $(nproc)`, a `Makefile` written years before
containers — will start sixteen jobs to share four cores and thrash the
scheduler. If your project does that, pass the job count explicitly, or use
docker's `--cpuset-cpus`, which does change `nproc` because it changes the
mask.

Whole numbers are worth preferring as well: `availableParallelism()` floors the
quota, so `--cpus=2.5` gives Node the same 2 as `--cpus=2`.

### A memory limit is only as hard as its swap limit

`--memory` on its own is not a ceiling. Measured on cgroup v2: with
`--memory=128m` and nothing else, `memory.swap.max` is a further 128 MiB, and a
container allocating 200 MiB carries on quite happily — by swapping. Docker's
default turns `8g` into 8 GiB of RAM plus 8 GiB of disk.

So `DEVENV_MEMORY_SWAP` defaults to whatever `DEVENV_MEMORY` is. That sets the
total to the memory limit, which leaves nothing for swap:

```
DEVENV_MEMORY=8g          # → --memory=8g --memory-swap=8g
```

The trade is real. With swap off, a build that overshoots is killed — SIGKILL,
exit 137, `Killed` in the output — rather than slowed down. That is the
intended behaviour: a dead agent is obvious and restartable, while a machine
paging 8 GiB to an SSD is neither, and it drags down everything else on the
host. If you would rather have the slowdown, ask for it:

```
DEVENV_MEMORY=8g
DEVENV_MEMORY_SWAP=12g    # 8 GiB of RAM plus 4 of swap
#DEVENV_MEMORY_SWAP=-1    # unlimited swap
```

Because the value is a *total*, it can never be less than `DEVENV_MEMORY`. The
launcher checks that before it starts anything and names the variable at fault;
docker's own message here is `Minimum memoryswap limit should be larger than
memory limit`, which is vague and, on the "larger" part, wrong — equal values
are allowed and are the whole point.

### Checking that a limit is real

Docker accepts `--memory` on systems where the cgroup memory controller is
unavailable: it prints a warning, and the limit does nothing. From inside:

```bash
devenv -- cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max
```

Numbers are limits; `max` means there is none. On cgroup v1 the files are
`memory.limit_in_bytes` and `memory.memsw.limit_in_bytes` under
`/sys/fs/cgroup/memory/`.

---

## What is in the image

Base `node:24-slim`, running as user `node`, working directory `/app`.

- Claude Code, Codex CLI, Antigravity CLI — native installers, in `~/.local/bin`
- Node.js and npm from the base image
- `mongosh`
- `git`, `curl`, `jq`, `zstd`
- `iptables`, `ipset` for the egress filter
- Python 3, with a virtualenv on `PATH` — see [Python](#python)
- `LANG=C.UTF-8`, so text handling is not ASCII-only. Note what that does and
  does not buy: the encoding is UTF-8, but collation and case conversion stay
  C-locale, so `sort` orders by byte value and `tr '[:lower:]' '[:upper:]'`
  leaves non-ASCII alone. Locale-aware sorting or case folding needs a real
  locale — `apt-get install locales` and `locale-gen`, which the image
  deliberately does not carry

More goes on top per session with add-ons — a browser for MCP, for one. See
[Add-ons](#add-ons).

The container starts as root only long enough to apply the filter, then
`setpriv` drops to `node` for the session. There is no `sudo` in the image.

---

## Python

`python3`, `python` and `pip` all resolve to a virtualenv at
`/opt/devenv/venv`, which is on `PATH`. Installing a library takes no flags and
no environment variables:

```bash
pip install requests
```

The indirection is there because a plain Debian `python3` is a dead end. pip is
not installed alongside it (`No module named pip`), the interpreter is marked
externally-managed so pip would refuse to write into it in any case, and the
usual `pip install --user` escape lands in `~/.local`, which is read-only here
to keep the agent versions fixed. None of that applies inside a virtualenv.

The venv is writable — it has to be — but it sits *after* the agent
directories in `PATH`, so a package that installs a console script named
`claude` cannot shadow the real one.

**Packages do not survive the session.** The venv itself is part of the image
and is there at every start, but anything added to it lives in the container's
writable layer and goes with `--rm`. That is the same bargain as everything
else here: the project persists, the container does not. Dependencies that
belong to the project belong in a virtualenv inside it, which persists and
stays per-project:

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

`pypi.org` and `files.pythonhosted.org` are in `allowlist.txt` already, and
they are enough: wheels and builds from source both work through the egress
filter.

---

## Add-ons

Some sessions need tools the image should not carry for everyone — a browser
for end-to-end work is the first. An add-on is an image layered on top of the
base, chosen per run:

```bash
devenv --build --with playwright          # build the base, then the add-on on it
devenv --with playwright claude           # run on it
devenv --versions --with playwright       # what the add-on image contains
```

An add-on is a directory `addons/<name>/` with its own `Dockerfile`. Nothing
changes for a session started without `--with`; the add-on is part of the
session only when it is named.

**Names and tags.** A name is lowercase letters, digits and `-`, starting with
a letter or digit — no `/`, no `.`, since it becomes both a path and part of a
tag. `--with` is repeatable; the names are deduplicated and sorted, so the same
set is the same image whatever order the flags came in. The tag is the base's
with each name appended after `_`:

```
devenv:local                           base
devenv:local_playwright                --with playwright
devenv:local_a_b                       --with a --with b
devenv:local_a-b                       --with a-b
```

The separator is `_` because a name cannot contain it, so a tag maps back to
exactly one set of add-ons. With `-`, `--with a-b` and `--with a --with b`
would share a tag, and building one would silently replace the other.

**Building.** `--build --with x` builds the base as a plain `--build` would,
then each add-on in turn on top of the previous image. `--update --with x`
refreshes the agents in the base (with `--pull`) and rebuilds the add-ons on
it; `--pull` is for the base only, since an add-on's `FROM` is a local image
no registry has. Each add-on's build context is its own directory and nothing
else — no repository files, no `.env.local`.

**A stale add-on image.** `devenv --update` without `--with` rebuilds only the
base. The add-on images stay on the old base, with the old agents. Each add-on
image records the ID of the base it was built on, and a session with `--with`
compares it with the base as it is now:

```
devenv: devenv:local_playwright was built on an older devenv:local, so its
devenv: agents are the ones from before the base was last rebuilt.
devenv: rebuild it with: devenv --build --with playwright
```

The same warning, worded for the case, appears when the add-on image predates
the record or the base image is missing. It does not stop the session — the
image works, it is only older than expected. The suggested `--build` takes the
base from cache and rebuilds the add-ons on it.

### Writing an add-on

```dockerfile
ARG BASE_IMAGE=devenv:local
FROM ${BASE_IMAGE}
RUN ...
```

- **`ARG BASE_IMAGE=devenv:local` / `FROM ${BASE_IMAGE}`.** The launcher always
  passes the image to build on; the default only gives a plain `docker build`
  of the directory a valid `FROM`.
- **The build context is the add-on's directory.** `COPY` sees the files in it
  and nothing else.
- **The build runs as root; the session does not.** The base ends as root, and
  the entrypoint has to start as root to apply the filter before dropping to
  `node`. Do not set `USER` or override `ENTRYPOINT` — either breaks that.
- **Everything is installed at build time.** The session runs behind the
  egress filter, so an add-on that downloads at runtime would fail, or need its
  hosts in everyone's allowlist.
- **The base sets `HOME=/home/node` for every later stage.** A tool run as root
  that writes to `$HOME` (npm's cache, for one) leaves root-owned files in the
  session user's home. Run such steps with `HOME=/root`.
- **Commands go in `/opt/devenv/bin`**, root-owned and first on `PATH`, like
  the agents' wrappers. The writable virtualenv comes before `/usr/local/bin`,
  so a wrapper should call what it wraps by absolute path.
- **Append to `/opt/devenv/versions.txt`** to have `--versions` show what the
  add-on installed.

### `run.conf`

An add-on that needs something from `docker run` declares it in
`addons/<name>/run.conf`:

```ini
# comments and blank lines are ignored; spaces around key and value are trimmed
shm_size=1g
add_host=db.local:host-gateway
```

| Key | docker flag | Value |
| --- | --- | --- |
| `shm_size` | `--shm-size` | A size: a whole number with an optional unit — `1g`, `512m`. Once per file. Across add-ons the largest wins, and the launcher says which add-on set it |
| `add_host` | `--add-host` | `<hostname>:host-gateway` and nothing else. Repeatable; merged across add-ons without duplicates |

It is a declaration of values for a closed set of keys, not a list of flags,
and the launcher writes the flags itself. A pass-through, however filtered, is
a way to `--privileged`, `--cap-add`, `-v`, `--security-opt` or `--network`,
each of which undoes part of the sandbox from a file that looks like
configuration. New keys are added to the launcher one at a time, each with its
own check. `add_host` takes `host-gateway` only because an arbitrary address
would let an add-on point a name the allowlist trusts somewhere else — and it
names the host without opening it: reaching a port there is still
`--host-port`.

The file is read as data, never sourced or expanded. An unknown key, a value
that fails its check, a line without `=` or a second `shm_size` is an error
naming the add-on, the line number and the line, and it stops everything —
`--build` and `--update` included, before docker is called, so an add-on with a
broken `run.conf` cannot be built either. At session start each add-on prints
what it adds:

```
devenv: add-ons this session: playwright (image devenv:local_playwright)
devenv: add-on 'playwright' adds: --shm-size=1g
```

---

## The playwright add-on

A browser an agent can drive through MCP: open a page, click, fill in a form,
read the accessibility tree, take a screenshot.

```bash
devenv --build --with playwright
devenv --with playwright claude
```

| Component | Version | |
| --- | --- | --- |
| `@playwright/mcp` | 0.0.83 | Published 2026-09-28. `ARG PLAYWRIGHT_MCP_VERSION` in `addons/playwright/Dockerfile` |
| `playwright`, `playwright-core` | 1.64.0-alpha-1790635538000 | The exact build `@playwright/mcp` 0.0.83 depends on |
| Chromium | 155.0.8059.12 (r1247) | Chrome for Testing, the revision that playwright build expects, in `/opt/ms-playwright` |

`devenv --versions --with playwright` prints the three from the image.

- **Chromium is installed by the playwright from the server's own dependency
  tree**, not by a separately chosen `npx playwright@...`: each playwright build
  expects one browser revision, and the server pins a pre-release build. The
  build fails if the two would load different copies of `playwright-core`. The
  separate headless shell is not installed — the server runs the full Chromium
  even headless — and system libraries come with `--with-deps`.
- **`/opt/ms-playwright` is root-owned and read-only** to the session, as the
  agents' directories are.
- **`run.conf` asks for `shm_size=1g`.** Chromium keeps renderer memory in
  `/dev/shm`, and docker's default 64 MiB crashes tabs on heavier pages.
- **No other `docker run` changes**, and no `add_host`: a site on the host is
  reached with `--host-port`.

**Connecting an agent.** The command is `playwright-mcp`, on `PATH` in the
add-on image. For Claude Code, a `.mcp.json` in the project:

```json
{
  "mcpServers": {
    "playwright": { "command": "playwright-mcp", "args": [] }
  }
}
```

Other agents take the same command in their own MCP configuration. Started
without `--with playwright`, the session has no `playwright-mcp`, and the agent
reports the server as failed to start.

**What the wrapper passes.** `/opt/devenv/bin/playwright-mcp` sits ahead of the
package's own command of the same name and starts the server with:

| Flag | Why |
| --- | --- |
| `--headless` | The container has no display |
| `--browser chromium` | Without it the server asks for Google Chrome, which is not in the image |
| `--isolated` | The profile stays in memory; every start is a clean browser |
| `--no-sandbox` | Chromium's own sandbox needs user namespaces, which docker's seccomp profile denies. The container is the boundary: the renderer runs with the agent's rights, as `node`, behind the same filter |
| `--output-dir /tmp/playwright-mcp` | The server's default is `.playwright-mcp` in its working directory — `/app`, your project — where a snapshot and a console log land on nearly every call, one `git add -A` from a commit. `/tmp` goes with the container |
| `--file-paths absolute` | The server's default is paths relative to its working directory (`../tmp/playwright-mcp/...`), right only for an agent that resolves them from `/app`. Absolute paths work from any subdirectory |

The last two are defaults, left out when the project has chosen otherwise —
`--output-dir`/`--file-paths` among the arguments (`--x value` or
`--x=value`), `PLAYWRIGHT_MCP_OUTPUT_DIR`/`PLAYWRIGHT_MCP_FILE_PATHS`, or
`outputDir`/`filePaths` in the config file given by `--config` or
`PLAYWRIGHT_MCP_CONFIG`. The server ranks a flag above the environment and the
config file, so the wrapper looks for each rather than overriding it, and each
flag appears at most once. Any other arguments in the MCP config are passed
on. To keep the files in the project, pass the directory and ignore it:

```json
{ "command": "playwright-mcp", "args": ["--output-dir", ".playwright-mcp"] }
```

```bash
echo .playwright-mcp/ >> .gitignore
```

**What the browser can reach** is what the session can: hosts in
`allowlist.txt`, `localhost` inside the container, and ports opened with
`--host-port` as `host.docker.internal`.

**Moving to a newer `@playwright/mcp`.** Change `PLAYWRIGHT_MCP_VERSION` and
rebuild with `devenv --build --with playwright`. Take a release that has been
public for at least two weeks: a fresh one can carry a compromised dependency
before anyone has noticed. The browser follows the server's playwright on its
own.

---

## Portability

Built and run on WSL2 with Docker CE. This section is what is known about
running it elsewhere, including the parts that have not been tested.

### SELinux (Fedora, RHEL, and relatives)

Whether you need anything here depends on the container engine, not on what
`getenforce` says.

**Docker CE, default configuration: nothing to do.** The daemon's
`--selinux-enabled` is off unless you turn it on — verified against the daemon
binary, whose help prints `(default true)` for options that are on by default
and prints nothing for this one. With labelling off, containers get no SELinux
type or MCS category of their own and bind mounts are not relabelled, so
`DEVENV_MOUNT_SUFFIX` is unnecessary. Reported from a Fedora install running
`Enforcing` with no `/etc/docker/daemon.json`: the sandbox built and ran, and
`/app` was readable and writable. Check your own with:

```bash
getenforce                                         # Enforcing: SELinux is on
docker info --format '{{json .SecurityOptions}}'   # a selinux entry: docker uses it
```

**Where the option is needed:** with `"selinux-enabled": true` in
`daemon.json`, and on Podman, where labelling is on by default — upstream
`containers.conf` ships `label = true`. There an unlabelled bind mount is
unreadable to the container, and the launcher takes a relabel option:

```
DEVENV_MOUNT_SUFFIX=:z
```

`:z` labels the mount as shared, `:Z` as private to a single container. The
value is appended to the project mount and folded into the allowlist mount,
where docker separates options with commas rather than colons (`:ro,z`). It has
to begin with a colon — without one the launcher stops instead of quietly
mounting your project at `/appz`. Empty is the default, and leaves both mount
strings byte-for-byte as they were.

**That path is still untested.** What has been checked is that the launcher
emits the intended mount strings, and that a container starts and can read and
write `/app` with the option set. Whether the relabelling then satisfies an
enforcing policy with labelling switched on, nobody has exercised. If it does
not work, treat it as a bug here rather than as something you configured
wrongly.

**Worth knowing if you came here for the security.** With labelling off —
Docker's default — SELinux is not adding a layer on top of this sandbox. The
boundary is the one this README describes: one bind mount, an unprivileged
user, an egress filter. It is not being reinforced by the host's mandatory
access control, whatever `getenforce` reports. Podman's default labelling would
add that layer, at the cost of needing the option above. That is a fact about
how Docker ships rather than about this tool, and it is an easy one to assume
the other way.

### Podman

Untested here. The launcher calls `docker` by name and nothing abstracts the
engine, so the practical route is the `podman-docker` shim or a `docker`
symlink. Every flag the launcher uses — `--rm -it --init --label --hostname -v
-e --cap-add --cpus --memory --memory-swap --pids-limit` — exists in podman's
CLI, so the command line itself should carry over.

Two things are likely to need attention, both consequences of rootless podman's
user namespace rather than of anything in here:

- **A session runs as uid 1000 inside the container.** Rootless podman maps
  your host user to root in the container and container uid 1000 to a subuid,
  so the files you own look root-owned from inside and the agent cannot write
  to `/app`. `--userns=keep-id:uid=1000,gid=1000` is the flag that lines them
  up, and the launcher does not pass it.
- **The egress filter programs iptables inside the container's network
  namespace.** Whether `--cap-add=NET_ADMIN` is enough for that in a rootless
  netns depends on the network backend; rootful podman is the safer bet if the
  filter refuses to apply.
- **SELinux labelling is on by default**, which is the opposite of Docker, so
  bind mounts need `DEVENV_MOUNT_SUFFIX=:z` — see above.

If you get it working, the launcher change is small — the engine name appears
in one place.

### Kernel modules for the egress filter

`ipset` needs `ip_set` and `xt_set` in the **host** kernel; a container does
not have one of its own. The stock WSL2 kernel carries them — verified on this
setup, where `ip_set`, `xt_set` and `ip_set_hash_net` are all loaded — as do
mainstream desktop distributions. To check, and to load them where they are
built as modules:

```bash
lsmod | grep ip_set
sudo modprobe ip_set xt_set
```

Without them `init-firewall.sh` fails and the entrypoint refuses to start the
session rather than run it unfiltered. `--open` starts without the filter;
rewriting `init-firewall.sh` to use plain iptables rules instead of an ipset is
the other way out.

### A session always runs as uid 1000 — known limitation, not fixed

The image's user is `node`, uid 1000, and that is what a session runs as. If
your host account is not uid 1000, files created in `/app` come out owned by
1000, and the files you own look foreign to the agent — usually readable,
rarely writable.

`entrypoint.sh` reads `DEVENV_UID` and `DEVENV_GID`, which looks like the fix.
It is not one yet, in two separate ways:

- The launcher never passes them, so they are only reachable by running
  `docker run` by hand.
- Even passed, they only work for a uid that already exists in the image.
  `/etc/passwd` holds `root` and `node`, and the entrypoint drops privileges
  with `setpriv --init-groups`, which refuses a uid it cannot resolve —
  `setpriv: uid 1001 not found`. `DEVENV_UID=1000` and `DEVENV_UID=0` work
  because those two exist. Anything else stops the container before it starts.

Doing this properly means deciding who owns `/home/node` as well: the agents
keep their configuration there, and a session that can write `/app` but not its
own config directory is worse than one that refuses to start. That is the next
piece of work here, and it is not being papered over in the meantime.

Until then, run the sandbox from an account with uid 1000 — the first user
account on most Linux installs, and the default on WSL2.

---

## Known limitations

- **Requires `ip_set` and `xt_set` kernel modules** in the host kernel. Present
  in stock WSL2 and most desktop distributions; see
  [Portability](#portability).
- **A session always runs as uid 1000**, and `DEVENV_UID` does not yet make it
  otherwise. If your account is not uid 1000, see [Portability](#portability).
- **`docker exec` into a running session lands as root.** Privileges are
  dropped by the entrypoint, which `docker exec` bypasses, and the image
  carries no `USER` directive because the entrypoint has to start as root to
  apply the egress filter. Use `docker exec -u node <container> bash`, or files
  you create land in your project owned by root.
- **Podman is untested.** See [Portability](#portability).
- **An agent's own sandbox does not run without `--nested-sandbox`**, because
  docker's seccomp profile denies user namespaces. See
  [An agent's own sandbox](#an-agents-own-sandbox).
- **Agent versions are whatever was latest at the last `--update`**, so builds
  are not reproducible and Antigravity cannot be pinned at all. See
  [Updating agents](#updating-agents).
- **A CPU limit does not change what `nproc` reports**, so a project that
  parallelises from it will over-subscribe a limited session. See
  [Resource limits](#resource-limits).
- **SELinux relabelling is untested**, and is only needed where the engine
  labels containers at all — which Docker does not do by default, even with
  SELinux enforcing. See [Portability](#portability).
- **Browser-based login flows need a device-code path.** There is no browser in
  the container. All three agents support this; for Codex it must be enabled in
  your ChatGPT security settings first.
- **`--host-port` opens TCP only, and only to services listening on the
  bridge.** A host service bound to `127.0.0.1` stays unreachable. See
  [Reaching services on the host](#reaching-services-on-the-host).
- **Add-on images do not follow the base on their own.** After
  `devenv --update` without `--with`, a session with an add-on runs the old
  agents until the add-on is rebuilt; the launcher warns. See
  [Add-ons](#add-ons).
- **IPv6 egress is closed, not filtered.** The allowlist is resolved to IPv4
  addresses only, so outbound IPv6 is rejected wholesale rather than matched
  against the list. IPv6 loopback (`::1`) keeps working and inbound IPv6 is
  untouched, so a dev server in the container is still reachable. Reaching an
  external host over IPv6 requires a deliberate edit to `init-firewall.sh`.
  On a kernel without IPv6 the step is skipped; if IPv6 is present but
  `ip6tables` cannot be programmed, the container refuses to start when it has
  a route out and warns when it does not.

---

## License

MIT — see [LICENSE](LICENSE).
