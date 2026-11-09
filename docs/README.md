# ai-box

An ephemeral environment for coding agents. It carries the toolchain they
reach for -- Node, Python, Chrome, Playwright, ImageMagick, whisper -- and it
can run containers inside itself, so an agent can `docker build` and
`docker compose up` the project it is working on without any of it touching the
host. Everything it creates is discarded when you leave.

**The safest way is the default.** What protects the host is on without
being asked for: `.git` is read-only, the `.env` files are hidden, a folder
that is no repository does not become one in the box, no hook runs for the
box. What gives the box more (`GIT=commit`, `AGENTDIR`, a wider `REPOS`) is
what you name when you start it.

## What the host needs

No Docker, no root daemon, no `/dev/kvm`. The environment runs under **rootless
Podman**, so the host needs Podman and the pieces rootless mode depends on:

```bash
sudo apt install -y podman uidmap passt slirp4netns crun catatonit socat git
```

Podman has to be **4.3 or newer**: `bin/run` starts the box with
`--userns=keep-id:uid=1000,gid=1000`. That is Ubuntu 24.04 (podman 4.9);
Ubuntu 22.04 has podman 3.4.4 and no `passt`, so upgrade it first
(`sudo do-release-upgrade`). `bin/configure` and `bin/self-check` say so.

Plus, from the kernel and your user account:

| requirement | why |
|---|---|
| cgroup v2 | Podman's rootless mode; default on any current distro |
| unprivileged user namespaces enabled | the whole sandbox is one |
| `/dev/fuse` (`modprobe fuse`) | passed in, so the inner engine can stack an overlay on the sandbox's own overlay |
| `/dev/net/tun` (`modprobe tun`) | passed in, for the inner network namespace's uplink |
| **at least 65536 subuids/subgids** for your user in `/etc/subuid` and `/etc/subgid` | the inner engine carves its own range out of the one the sandbox is given. A short range is the one host-side setting that quietly breaks nesting |

Rather than checking by hand:

```bash
bin/configure      # installs the packages, loads fuse/tun, grants the subuids
                   # you lack (a range that is too short it names, for you)
bin/self-check     # or just tell me what is missing, change nothing
```

`bin/configure` is idempotent -- every step checks first, so re-running it is a
no-op that reports what is already in place. `bin/configure --dry-run` prints
what it would do. Both are safe under `sudo`: the subordinate range is granted
to `$SUDO_USER`, not to root.

Verified on Ubuntu 26.04, kernel 7.0, Podman 5.7 on the host. The image is
x86_64 only; `bin/build` says so on another machine. And ai-box itself must
lie in a path with no space in it: its scripts start from the rulebook's
header, which does not quote its own path. A workspace may have spaces.

If Podman prints `OCI Runtime crun is in use by a container, but is not
available` on every command, `crun` is missing while existing containers still
name it. Install it first, then clear the stale records:

```bash
sudo apt install -y crun
podman rm -af
```

## Usage

```bash
bin/configure      # install what the host is missing (idempotent)
bin/self-check     # report what is here and what is not; --deep also starts
                   # boxes: a container inside one, and the boundary tried
                   # from inside (.git, the masks, the relay, the end)
bin/build          # build the image (tag: ai-box), fill data/extras, check it
                   # with self-check --deep; a build that does not finish
                   # leaves the previous image as it was
bin/images         # list the shared image store; add: bin/images mysql:8.0

bin/run            # open the box on the current directory
bin/run claude     # ...and go straight into an agent
bin/run make test  # ...or run one command and exit
bin/run-fresh      # programs only: no workspace, saved settings or login
bin/run-fresh codex
FRESH=1 bin/run    # the same fresh mode through the ordinary launcher
FRESH=app bin/run-fresh
                   # fresh settings, with the current folder at /app
AGENTDIR=~/agents/<id> bin/run claude
                   # ...with an agent's folder of Visual Agency at /agentdir
AGENTS=~/agents bin/run claude
                   # ...with every agent's folder at /agents, read only
REPOS=~/w bin/run claude
                   # ...with ~/w at /repos instead of ~/repos; REPOS= for none
REPOS_PICK='rules infra' bin/run claude
                   # ...with only those two at /repos; REPOS_PICK= for none
SOCKETS=~/w/sockets bin/run claude
                   # ...with ~/w/sockets at /sockets instead of ~/sockets;
                   # SOCKETS= for none
GIT=commit bin/run claude
                   # ...letting the agent commit, tag, push and pull the
                   # branch you are on, through the host; see Commit, push
                   # and pull
CLAUDE_CODE_OAUTH_TOKEN=... bin/run claude
                   # ...signed in to that account instead of the shared one;
                   # CODEX_API_KEY for codex; see Its own sign-in

bin/usage          # rate-limit usage of the agents the box is logged in to,
                   # Claude and GPT side by side; reads data/, starts nothing
bin/run --help     # what a command takes; each one here answers -h and --help
```

`bin/run` refuses to start from `$HOME`, from any directory that contains it,
or from `/`, because `$PWD` is handed to the box read-write and from there
that would be every dotfile and key at once. Paths are resolved first, so a
symlink does not get around it.

Your ssh-agent stays outside too. `SSH_AUTH_SOCK` is not passed into the box,
and `bin/run` refuses to start when the workspace, `REPOS`, `SOCKETS`,
`AGENTDIR` or `AGENTS` holds the agent's socket (a box started from `/tmp`
would see `/tmp/ssh-*/agent.*` and could use every key in it). `pull` and
`push` use the agent on the host.

### A fresh environment

`bin/run-fresh` is a shortcut for `FRESH=1 bin/run`. It keeps the installed
programs, but starts without your workspace, saved Claude/Codex settings or
logins, repositories, service sockets, agentdir, other agents' notes, Git
relays or shared image store. `/app` is an empty writable temporary
filesystem. The image's defaults stay in place, network access stays on, and
the box's files disappear on exit. No image rebuild is needed.

`FRESH=app bin/run` (or `FRESH=app bin/run-fresh`) also mounts the current
folder. This keeps the ordinary home-directory and ssh-agent checks, read-only
`.git` and secret-file masks. Without that mount, the workspace checks are
skipped, so a fresh box may start from your home directory or `/`. When the
workspace contains ai-box's `data/`, an empty temporary mount hides that state;
a workspace inside `data/` is refused. Files written to the mounted workspace
stay on the host; the fresh home and temporary files disappear on exit.

The one host directory still mounted is `data/extras`, at `/opt/extras` with
the ordinary temporary overlay: the agents and browsers live there, and the
box cannot change the host copy. This is not a zero-mount image. The launcher
still writes its command to `data/logs/run.log`, outside the box.

Fresh mode refuses nonempty `GIT`, `REPOS`, `REPOS_PICK`, `SOCKETS`, `AGENTDIR`
or `AGENTS` rather than silently dropping a request to mount something.
`MASK` is allowed only with `FRESH=app`. Unset or empty `FRESH` keeps
`bin/run`'s ordinary behavior; other values are errors. `bin/run-fresh`
defaults an unset or empty `FRESH` to `1` and passes commands and their
arguments to `bin/run` unchanged.

Fresh mode forwards nonempty `CLAUDE_CODE_OAUTH_TOKEN`, `CODEX_API_KEY` and
`OPENAI_API_KEY`, just like ordinary mode. They are passed by name, so their
values do not appear in the launch command or its log. Saved sign-ins stay
outside the box. For example, with the variable already exported:

```bash
bin/run-fresh claude    # uses CLAUDE_CODE_OAUTH_TOKEN
bin/run-fresh codex     # uses CODEX_API_KEY
```

Unset or empty credentials leave the fresh box signed out. To test a token
entered inside the box, unset any exported credentials first:

```bash
env -u CLAUDE_CODE_OAUTH_TOKEN -u CODEX_API_KEY -u OPENAI_API_KEY bin/run-fresh
```

Then enter the token **inside that shell**:

```bash
read -rsp 'Access token: ' test_token; echo
printf '%s' "$test_token" | codex login --with-access-token
unset test_token
codex exec --skip-git-repo-check 'Reply with OK.'
```

For an API key use `codex login --with-api-key` in place of
`--with-access-token`. Stay in the same box for login and the request: a new
`bin/run-fresh` invocation starts clean again. A login-status check only shows
that credentials are present; a successful request verifies access for that
request. Authentication, quota, model access and network failures are distinct.
See [the official Codex login reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli#codex-login).

### What `bin/run` gives the box

| path | mode | |
|---|---|---|
| `$PWD` → `/app` | rw | the project |
| `$PWD/.git` | **ro** | mounted over the writable workspace, always. Where the workspace has none, an empty read-only folder stands there, so the box cannot make a repository of it: `git init` is yours, on the host. The folder is empty and gone when the box ends |
| `.env`, `.env.*` in `$PWD`, at any depth | hidden | each replaced with `/dev/null`, so they never enter the box; not searched for under `node_modules`, `vendor` and `.git`, and taken at the start: one made later is in sight. `.env.example`, `.sample`, `.template` and `.dist` stay, as templates. `MASK="a.pem keys"` hides more, files and folders, patterns too: a folder reads as empty. A name it cannot hide (not there, outside the workspace) gets a line on stderr and the box starts without it |
| `~/repos` → `/repos` | ro | or `$REPOS` when set; set but empty, no `/repos`. `REPOS_PICK="a b"` mounts only those repositories of it, each at `/repos/<name>`, a missing or symlinked one skipped with a line on stderr; set but empty, no `/repos`. The `.env` and `.env.*` of each repository in it are hidden as the workspace's are, at any depth; a workspace inside it is hidden there as at `/app`, `MASK` included |
| `~/sockets` → `/sockets` | ro | or `$SOCKETS` when set; set but empty, no `/sockets`. The host's sockets for the box to talk to: read-only still connects, and the folder is mounted rather than each socket, so a service that starts again with a new socket is still reached |
| `$AGENTDIR` → `/agentdir` | rw | an agent's folder of Visual Agency, when `AGENTDIR` is set |
| `$AGENTS` → `/agents` | ro | the app's folder of agents, each by its id, when `AGENTS` is set: one agent reads the others' conversations, plans and documents and changes none. Its own folder in it stays read-write at `/agentdir` and is read-only at `/agents/<id>` |
| `$READONLY` | ro | space-separated paths in the box, each a folder under `/agentdir` or `/app`, mounted again read-only after the other bind mounts |
| `data/claude{,.json}` → `~/.claude{,.json}` | rw | so the agent keeps its login and history |
| `data/codex{,.json}` → `~/.codex{,.json}` | rw | same |
| `data/images` → `/var/lib/shared` | rw | the shared image store, when it exists |
| `data/extras` → `/opt/extras` | overlay | browsers, whisper model, Chrome, `claude`, `codex`; writes end with the box. See [Browsers, model and agent CLIs](#browsers-model-and-agent-clis) |
| sockets → `/run/git` | ro | with `GIT=commit`: `commit`, `push` and `pull` ask the host |

Agent state is the box's own, kept out of your home dotfiles: the box logs in,
keeps its history and rewrites its config without touching the `~/.claude` or
`~/.codex` you use outside it. `bin/run` creates the two directories and the two JSON
files on first run, because a bind mount whose source does not exist would
otherwise be created as a directory and the agents want files there.

Those paths are relative to **this repo**, not to the directory you run from --
see [Where the box keeps its state](#where-the-box-keeps-its-state).

`READONLY='/agentdir/messages /app/reference' bin/run` makes those folders
read-only while their siblings stay writable. Host additions and renames
inside them remain visible immediately. Unset or empty, it adds no mounts;
missing folders, files and paths under an unset `AGENTDIR` are skipped.
Paths must name descendants of those two mounts: `/etc`, the mount roots,
`.` or `..` components, repeated slashes, colons and symlink paths are
refused. A trailing slash is allowed; duplicate paths add only one mount.
Spaces in folder names cannot be represented in this list.

A repository the box makes in a subfolder of the workspace cannot be stopped
by a mount: `git` run inside that subfolder reads the config the box wrote
and runs what it names. Look at a `.git` you did not make before you run git
beside it.

`FRESH=1` refuses nonempty `READONLY`, since it has no host workspace or
agent folder. `FRESH=app` allows workspace folders but refuses paths into
the saved state it hides. Existing `.git` protection and secret-file masks
still apply. Protection is at the named mount path; another writable mount
of the same host folder would still allow writes through that other path.

#### Its own sign-in

A box can sign in to an account of its own instead of the shared one in
`data/`. Both ordinary and fresh modes pass each of these into the box when
it is set and not empty, by name only (`--env NAME`), so the value never
appears on a command line or in `data/`. In ordinary mode, the shared sign-in
keeps renewing itself:

| variable | for | |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude` | the long-lived token of `claude setup-token`; `claude auth status` inside says `oauth_token` |
| `CODEX_API_KEY` | `codex` | an API key; `codex doctor` inside says auth mode `api_key` |
| `OPENAI_API_KEY` | other tools | passed as it is; codex 0.163 does not sign in with it, alone or beside the shared sign-in |

Unset or empty, the agent uses the shared sign-in in ordinary mode; a fresh
box has no shared sign-in. `bin/self-check` says which are set, never their
values.

`--shm-size=2g` is set for Chrome/Playwright. `$PWD/.git`, `$PWD/.env`,
`~/repos` and `~/sockets` are mounted only when they exist, so a bind mount
never silently creates an empty directory in your home.

### Commit, push and pull

```bash
GIT=commit bin/run claude
```

`.git` stays read-only. A box that could write it could rewrite history, move
or delete any branch and drop your stashes, and an agent did: it rewrote
commits you had already pushed. So the host does the git work, and the box
asks. `commit`, `tag`, `push` and `pull` inside the box each connect to a
relay `bin/run` starts beside it, and the host runs a fixed script in the
workspace, for the branch checked out when the box started:

| in the box | on the host |
|---|---|
| `commit <file.patch>` | the patch applied on `HEAD` and committed; a `git format-patch` email brings its message, a plain diff takes `-m <message>` |
| `commit -m <message> <path>...` | the same, with the patch made in the box from those files; a `.patch` or `.diff` inside `/app` is such a file, and a folder is refused |
| `tag <name>` | a new tag on `HEAD`; `tag -m <message> <name>` makes an annotated one |
| `push` | `git push --no-follow-tags origin refs/heads/<branch>:refs/heads/<branch>`, and with it the tags `tag` made in this box |
| `pull` | `git fetch` of `<branch>` into `origin/<branch>`, then `git merge` |

One patch, one commit. The host applies it to a scratch index on `HEAD`, so
your working tree is not changed, and of your staging only the paths of the
commit, which are set to it: the files
already hold the change, and the patch is what gets recorded. Commits are
yours: your `user.name`. Your hooks do not run, for `commit`, `push` or
`pull`: a hook is a file of the work tree (husky's `.husky/`) or runs one
(`npm test`), the box writes the work tree, and the host would run the box's
code as you. What a hook checks, the agent runs in the box, or you run before
you take its work. A patch that does not apply to `HEAD` as it is now is
refused, and so is one touching a file the box sees masked (`.env`, `MASK`),
or one that adds or changes a submodule entry or `.gitmodules`: the folder of
a submodule is a repository the box writes, and your git would read its
config. Submodules are yours to commit.
From paths, the agent names every file, new, changed or deleted; no globs, no
`-a`. No force, no other branch, no amend, rebase or reset: there is no
command for them. If you switch the branch on the host, `commit`, `tag` and
`pull` refuse until you switch back.

`tag` puts a new tag on the commit the branch is at, and the next `push` sends
it to origin with the branch: `commit`, `tag v1.2.3`, `push` is a release from
the box. A name that is taken on another commit is refused, and there is no
way to move or delete a tag. `push` sends the tags made by `tag` in this box
and no others: a tag you made yourself stays yours to push. Where a pushed tag
starts a release in CI, the agent can start one: that is what `tag` is for.

`pull` merges on the host: a fast-forward or a merge commit goes through. A
conflict does not. `pull` undoes the merge, lists the files, tells the agent
to stop and ask you, and exits 2. A rejected push (the remote moved on) comes
back to the agent as git printed it; `pull` and a second `push` follow.

`git commit`, `git push` and `git pull` in the box say which command to run
instead, and so does `git tag` when it would make or delete one; listing tags
is plain git. The relays end with the box; after a bare `kill -9` of
`bin/run` they stay, as the box does.

What it needs:

- a branch checked out on the host; `bin/run` stops on a detached HEAD;
- `socat` and `git` on the host (`bin/configure` installs them);
- `.git` as a folder of the workspace, not the file of a linked worktree or
  a submodule checkout, and a remote named `origin`;
- a push and a fetch that work from your terminal with no passphrase typed:
  the relays have no terminal to ask on. ssh-agent covers it.

### Where the box keeps its state

Everything the box keeps between runs lives in this repo, under `data/`:

```
data/claude/  data/claude.json     the agents' state and logins
data/codex/   data/codex.json
data/images/                       shared image store, for inner docker run
data/extras/                       browsers, whisper model, Chrome, agent CLIs
data/refresh                       the ISO week of the last image build
data/logs/                         each build's output; run.log, every bin/run's podman command
```

The names lose their leading dots on this side of the mount -- nothing here is
hidden from the person who owns it, and `ls data/` should show what the box is
keeping. They arrive as `~/.claude` and `~/.codex` inside the box.

This is not an app you install once. You pull the repo and rebuild it, often
more than once a day, so its state belongs beside the tree it was built from:
one directory holds all of it, `rm -rf data` is the whole reset, and it leaves
nothing anywhere else on the host. `data/` is gitignored, and `.dockerignore`
keeps it out of the build context.

The path is anchored to the scripts, not to `$PWD`, so `bin/run` from any
workspace finds the same state. Two clones are two boxes: separate logins,
separate image stores. The image is one for both: each builds and starts
`ai-box`. Deleting a clone deletes its state with it -- and a
fresh clone starts logged out, so keep the clone you use.

The other side of state living in an ignored directory: `git clean -xdf` in
this repo takes the logins and the image store with it, and `data/extras`,
which the next `bin/build` downloads again (about 4 GB). `git pull` and a
rebuild, the daily path, leave `data/` alone.

### Browsers, model and agent CLIs

They are not in the image. Playwright's browsers, Cypress's Electron, the
whisper model, Chrome and the two agent CLIs are 3.5 GB of the 6 the image
used to be, and they change at their own pace: the CLIs daily, the rest
weekly or less. So they live in `data/extras`, each under its version:

```
data/extras/
  versions          what is here, name=version, as in /etc/ai-box/versions
  ms-playwright/    chromium-1234/, firefox-1538/, webkit-2336/, and 1.61.1's
                    chromium-1228/ with its headless shell
  cypress/          14.5.4/
  huggingface/      the whisper model
  chrome/           155.0.8059.39-1/, current -> 155.0.8059.39-1
  npm/              2.1.292-0.160.1/ (claude-code-codex), current -> ...
```

- **`bin/build` fills it**, at the end, by running `extras-fill` in the new
  image, and writes its whole output to `data/logs/build-<time>.log`. What
  is there at the right version costs nothing: a daily build installs a new
  Claude or Codex beside the old ones and moves `npm/current`, and the image
  itself, unchanged, is not copied again. The first build of a week also
  takes a new Chrome. Each entry is checked (a real launch, a real
  transcription, `--version`): the agent CLIs and Chrome before they are
  renamed into place, the browsers and the model right after their own
  tools have put them there.
- **`bin/run` mounts it** at `/opt/extras` as an overlay (`:O`): the host's
  folder is not written through it, and what a box writes there -- a
  project's own `npx playwright install` -- ends with it. Without the agent
  CLIs `bin/run` stops and says to run `bin/build`; without the rest it starts
  with a warning, since the fill installs the agents first. A box sees the
  folder as it was when it started: what a later fill adds is listed but
  cannot be opened, so `bin/build` names the running boxes to restart.
- **Inside, nothing moved.** `claude` and `codex` are on the `PATH`;
  `PLAYWRIGHT_BROWSERS_PATH`, `CYPRESS_CACHE_FOLDER` and `HF_HOME` point into
  `/opt/extras`; `/opt/google/chrome` and `/usr/bin/google-chrome` lead there.
  `google-chrome` and `transcribe` say "run bin/build" when their part is
  missing.
- **Old versions** stay three days after they stop being current, for boxes
  started before the fill (`KEEP_DAYS`), then the next fill removes them.

The design and its reasons: [notes/extras.md](../notes/extras.md).

### Limits on the box

The inner engine has no cgroups of its own, so nothing inside the box can
limit itself. `bin/run` limits the box as a whole instead, through whatever
cgroup controllers systemd has delegated to your session (`bin/self-check`
reports which):

| variable | default | |
|---|---|---|
| `PIDS` | 4096 | `--pids-limit`; a fork bomb inside stops here |
| `MEMORY` | three quarters of the host's RAM | `--memory`; the box is OOM-killed, the host is not |
| `CPUS` | unlimited | `--cpus` |

Set one to `0` to lift it. `bin/run` also puts a real init at PID 1
(`--init`, Podman's own `catatonit`) whenever the host has it, so orphaned
processes are reaped and `podman stop` ends the box at once.

### The box ends with `bin/run`

`podman run` is only a client: the container runs under `conmon`, and a
`podman run` that is killed leaves it running. So `bin/run` keeps podman in
the background and, on SIGHUP, SIGTERM or SIGINT (the terminal closed, a
`kill`, Visual Agency ending an agent), stops the container: SIGTERM to its
init, SIGKILL 3 s later. The stop is detached from `bin/run`, so it finishes
even when `bin/run` is killed meanwhile, as Visual Agency does 3 s after its
SIGTERM. The box's exit status is `bin/run`'s. Only a signal `bin/run` cannot
catch, a bare SIGKILL above all, leaves the box running; `podman ps` and
`podman stop` then.

### Helpers on the `PATH`

`files/bin/` is installed to `~/bin` inside the box, so these are just there:

| | |
|---|---|
| `hwdata` | CPU, memory and disks of the host underneath |
| `diskusage` | one CSV row per real filesystem: inodes, bytes, percentages |
| `diskusage-warn` | the same, filtered to whatever is over 85% |
| `now` | timestamp, for pasting into notes |
| `diskperf` | how fast the disk under `$PWD` writes: two 400 MB files, removed after |
| `showhomedir` | what the box's home holds |
| `g` | recursive `ag` search: `g pattern` |
| `templ` | the skeleton these scripts start from: `templ > new && vi new` |
| `extras-fill` | fills `/opt/extras`; `bin/build` runs it with `data/extras` mounted writable |
| `commit` | one patch, one commit, through the host: `commit <file.patch>` or `commit -m <message> <path>...`; a `GIT=commit` box only |
| `tag` | a new tag on the commit the branch is at, through the host: `tag <name>` or `tag -m <message> <name>`; a `GIT=commit` box only |
| `push` | push the branch the box was started on, and the tags made by `tag`, through the host; a `GIT=commit` box only |
| `pull` | fetch that branch and merge it, on the host; stops on a conflict; a `GIT=commit` box only |
| `git` | git itself, except that `git commit`, `push`, `pull` and a `git tag` that makes one point at the four above in a `GIT=commit` box |

`hwdata` reports what it can: `parted` is not in the image, so the partition
table check is skipped. `g` with no argument wants an X clipboard the image does
not have and says so. Scripts that only make sense on a real host -- `netdata`,
`osdata`, `showmyip`, `showufw` -- live in `files/bin.host/` and are not copied
into the image.

Two more, from `files/bin.ai/`, are in `/usr/local/bin`: `tts [--voice NAME]
<out.mp3> <text|->` speaks a text into a file through the Edge voices (it
needs the network), and `transcribe <file>...` turns the speech of an audio or
video file into text, with `--plain`, `--lang` and `--model`.

There is no database server in the image. MySQL, Redis and MinIO run as
containers, and `bin/images mysql:8.0 redis:7 minio/minio` on the host puts
their images in the shared store so `docker run` inside needs no pull.

## Running containers inside it

`bin/run` used to be `docker run --rm -it a`, and `docker` inside it did not
work: the image installs `dockerd`, but `dockerd` needs `--privileged`, and
`--privileged` is host-root-equivalent. Binding `/var/run/docker.sock` was the
other usual answer, and that is worse — the containers are then siblings on the
host, they outlive the environment, and `--rm` stops meaning anything.

The environment now runs under **rootless Podman** and the engine *inside* it is
Podman too -- Ubuntu 24.04's `podman` 4.9 and `podman-compose` 1.0.6, not the
5.x on the host, so do not expect 5.x-only features or the newest compose-spec
keys inside. `podman-docker` provides a real `docker` command, so nothing you
type changes.

## Why this clears every constraint at once

The decisive property is that **Podman has no daemon**. Docker-in-Docker spends
its first second booting `dockerd` — the old entrypoint polled for it for up to
ten seconds. With nothing to boot, that whole phase disappears, which is how the
environment opens in a quarter of a second while still giving you a working
`docker`.

| requirement | result |
|---|---|
| `docker run` inside | works |
| `docker build` inside | works |
| `docker compose` inside | works — services up, published ports reachable, and services resolve each other by name |
| opens in < 1 s | **0.25–0.40 s** (5-run spread on a from-scratch build), well under budget |
| terminated ⇒ environment gone | SIGKILL with 2 inner containers, 3 inner images and 220 MB of nested state: host storage byte-identical, no stray mounts, no leftover netns, no held ports, workspace untouched |
| no `--privileged`, no docker socket | neither appears; the sandbox is rootless and unprivileged, and no capabilities are added |

Bonus: files you create in `/app` come back owned by **you**, not by `root`.
`ubuntu` inside is your own uid outside.

## What had to change

**`Dockerfile`** — `docker-ce`/`containerd.io` out, `podman` + `podman-docker` +
`podman-compose` in, plus four things that are easy to miss:

- `netavark`, `aardvark-dns`, `nftables` are **Recommends**. The image builds
  with `--no-install-recommends`, so they were silently absent, and the failure
  mode is not obvious: compose comes up and published ports work, but services
  cannot resolve each other by name. `aardvark-dns` is that resolver; netavark
  shells out to `nft`.
- `setcap cap_setuid+ep` on `newuidmap` and `cap_setgid+ep` on `newgidmap`. Ubuntu ships them
  setuid-root, Fedora ships them with file capabilities, and **only the
  capability form can write a nested `uid_map`**. Without it the inner `docker`
  dies with `newuidmap: ... Operation not permitted`.
- `/etc/subuid` + `/etc/subgid` for `ubuntu`, carved out of the range the outer
  rootless container already maps.
- The nesting config goes in `/etc/containers/containers.conf.d/`, **not** over
  `/etc/containers/containers.conf` — replacing that file discards the distro's
  own settings, including where Podman looks for `netavark`.

`usermod -aG docker ubuntu` is gone: there is no daemon and no socket, and
membership in a `docker` group was itself root-equivalent.

**`files/docker-entrypoint`** — nothing to start and no poll loop to wait
through; `DOCKER_DIND` is gone. It now creates `/run/user/1000` before dropping
privileges, because an inner engine with no runtime directory of its own drops
a pause-process file into `$PWD` — straight into your mounted workspace.

**`bin/run`** — `podman run` with the flags that make nesting work. Each is
there for one specific reason; see the comments in the script.

**`bin/build`** — `docker build` → `podman build`. All 12 `--mount=type=cache`
BuildKit cache mounts work unchanged.

## Two things that behave differently

- **No cgroup limits inside.** `docker run --memory=...` in the environment is a
  no-op, because the sandbox's `/sys/fs/cgroup` is read-only. Limit the
  environment as a whole from outside instead.
- **`docker buildx` is gone.** It was only ever called to print its version.
  `docker build` and `docker compose` are unaffected.

## One of each

There used to be four Chromiums in the image and two ImageMagicks. Now:

- **One Chrome.** `google-chrome-stable`, unpacked into `data/extras/chrome`,
  is it. Puppeteer is pointed at it with
  `PUPPETEER_EXECUTABLE_PATH` instead of downloading its own copy, which is the
  same browser a couple of patch releases behind. `puppeteer.launch()` needs no
  argument; `extras-fill` asserts `executablePath()` resolves there.
- **One Chromium for Playwright**, installed with `--no-shell`. A headless
  launch asks for the full browser's headless mode with `channel: 'chromium'`
  rather than a second 262 MB build whose only job is to be the headless one;
  a plain `chromium.launch()` looks for that build and fails.
- **One older Chromium, for a project with its own Playwright.** A suite that
  runs the `@playwright/test` its lockfile pins needs that release's Chromium
  (`PLAYWRIGHT_PINNED_VERSION`): the full browser for `channel: 'chromium'`,
  379 MB, and the headless shell for a plain launch, 262 MB.
- **One ImageMagick, version 7.** The apt package (version 6) is gone. `magick`
  is the AppImage; the legacy names — `convert`, `identify`, `mogrify`,
  `composite`, `montage`, `compare` — are a wrapper that runs `magick <name>`,
  so each is the same ImageMagick as `magick`. `convert` still works, with
  upstream's one-line deprecation warning on stderr. (The AppImage's own
  launcher only tells the names apart under FUSE, which the box does not have.)

That was 925 MB measured — 652 + 262 + 11 — off the image as it then was.
Since then all the browsers have left it: with Cypress's Electron (679 MB),
Firefox and WebKit (595 MB) and the whisper model they live in `data/extras`
([Browsers, model and agent CLIs](#browsers-model-and-agent-clis)), so none
of them is in the copy `bin/build` makes of the image.

`seccomp=unconfined` on the sandbox is worth knowing about: the inner runtime
calls `sethostname(2)`, which the default profile blocks. It widens the syscall
surface, but the sandbox is still rootless and user-namespaced — this is not
host root. A narrow custom profile adding just `sethostname` would recover most
of it. `unmask=ALL` is in the same category: the inner runtime mounts a fresh
`/proc` for every container it starts, and the kernel refuses that while any
part of the box's own `/proc` is masked, so a narrower unmask is not enough.
The box also has full outbound network; the agent needs registries and APIs.
That reaches the host's own services too, those that listen beyond
127.0.0.1 (`host.containers.internal`), your LAN, and on a cloud machine its
metadata address.

### What the image was built with

Six versions are pinned as build arguments (Node, Playwright, Puppeteer,
Cypress, ImageMagick, oxipng), and a seventh in the Dockerfile itself: the
older Playwright whose Chromium is kept for projects that pin it
(`PLAYWRIGHT_PINNED_VERSION`). Everything else -- the Python and npm libraries,
phpredis, Composer, yt-dlp, Chrome, and the two agent CLIs -- asks its
upstream for the current release at build time, so two builds a week apart
differ. Each layer records what it resolved in `/etc/ai-box/versions`;
`extras-fill` records Chrome, the browsers, the model and the CLIs in
`/opt/extras/versions`, in the same format. `bin/self-check --versions` prints
both. Every download the Dockerfile and the fill make themselves is
checksum-verified (Node, Composer, yt-dlp, oxipng, ImageMagick, Chrome);
phpredis, Playwright's browsers, Cypress and the model come by their own
tools. The checksum comes from the same publisher as the artifact: that guards against corruption and torn releases, not against a
compromised upstream. npm, pip and apt add their own registry-side integrity
checks on top.

## Faster inner runs

Inner `docker run <image>` pulls by default. Pre-seed a read-only store on the
host and `bin/run` mounts it automatically:

```bash
podman --root "$PWD/data/images" pull alpine:latest python:3.12-slim
```

(from the root of this repo -- `--root` wants an absolute path)

Inner containers then start with no pull and no network.

The store is mounted read-write, not read-only. Building FROM an image that
lives only in it makes the inner engine create and remove a transient
mountpoint inside the store, and read-only turns every such `docker build` into
`removing mount point ...: read-only file system`. Only those transient
mountpoints are written -- the images themselves are untouched.
