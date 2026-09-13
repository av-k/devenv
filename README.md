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
- **Versions** — pinned in the image, so a rebuild is the only thing that
  changes what runs. Install directories are read-only, which also stops the
  agents' own background self-updaters.
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
chmod +x devenv entrypoint.sh init-firewall.sh
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

| Flag | Effect |
| --- | --- |
| `--build` | Build the image and exit |
| `--update` | Rebuild without cache to pick up newer agent versions, then exit |
| `--open` | Start without the egress filter |
| `--versions` | Print the tool versions baked into the image |

Anything after `--` is passed through untouched:

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

Versions are build arguments. Edit the defaults in the Dockerfile or pass them
in:

```bash
docker build --build-arg CLAUDE_CODE_VERSION=2.1.263 -t devenv:local .
```

`./devenv --update` rebuilds from scratch and prints what landed in the image.

**Antigravity CLI cannot be pinned.** Its installer only fetches the manifest's
latest build, so a rebuild may produce a different version than the last one.
The resolved version is recorded at `/opt/devenv/versions.txt` inside the
image; `./devenv --versions` prints it.

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
- `LANG=C.UTF-8`, so text handling is not ASCII-only. Note what that does and
  does not buy: the encoding is UTF-8, but collation and case conversion stay
  C-locale, so `sort` orders by byte value and `tr '[:lower:]' '[:upper:]'`
  leaves non-ASCII alone. Locale-aware sorting or case folding needs a real
  locale — `apt-get install locales` and `locale-gen`, which the image
  deliberately does not carry

The container starts as root only long enough to apply the filter, then
`setpriv` drops to `node` for the session. There is no `sudo` in the image.

---

## Portability

Built and run on WSL2 with Docker CE. This section is what is known about
running it elsewhere, including the parts that have not been tested.

### SELinux (Fedora, RHEL, and relatives)

With SELinux enforcing, a bind mount without a relabel option is unreadable to
the container: the host's labels stay on the files and the container process is
denied. Docker's answer is the `:z` (shared) or `:Z` (private) mount option, so
the launcher will take one:

```
DEVENV_MOUNT_SUFFIX=:z
```

It is appended to the project mount and folded into the allowlist mount, where
docker separates options with commas rather than colons (`:ro,z`). It has to
begin with a colon — without one the launcher stops instead of quietly
mounting your project at `/appz`. Empty is the default, and leaves both mount
strings byte-for-byte as they were.

**This is not verified on an SELinux system.** What has been checked is that
the launcher emits the intended mount strings, and that a container still
starts and can read and write `/app` with the option set. Whether the
relabelling then satisfies an enforcing policy is untested: this machine runs
WSL2, which has no SELinux to test against. If it does not work on Fedora,
treat it as a bug here rather than as something you have configured wrongly.

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
- **Podman is untested.** See [Portability](#portability).
- **Antigravity version cannot be pinned** (see above).
- **A CPU limit does not change what `nproc` reports**, so a project that
  parallelises from it will over-subscribe a limited session. See
  [Resource limits](#resource-limits).
- **SELinux relabelling is untested.** See [Portability](#portability).
- **Browser-based login flows need a device-code path.** There is no browser in
  the container. All three agents support this; for Codex it must be enabled in
  your ChatGPT security settings first.
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
