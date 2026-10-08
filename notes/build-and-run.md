# Build and run: the rule

The target for how ai-box is used. How it is built inside is open; whatever
the internals become, they serve this.

## The rule

1. **`bin/build` every day updates Claude and Codex, and nothing else.** They
   release almost daily; a build that only picks up new CLIs takes seconds and
   costs no more disk than the CLIs themselves.
2. **`bin/run` starts the newest build.** No flag, no version to name: the
   last finished `bin/build` is what the next box gets.
3. **Once a week, the full refresh.** Ubuntu packages, browsers, Python and
   npm libraries, everything else: `bin/build` does it itself on the first
   build of a new week (UTC ISO week), as it does today.
4. **The box ends with `bin/run`.** When the process that started the box
   ends, by any signal that can be caught (SIGHUP when its terminal closes,
   SIGTERM, SIGINT), no process of the box survives it: the container is
   stopped within seconds, its agent included. The one exception is a bare
   SIGKILL to `bin/run` with nothing before it, for nothing can run in a
   killed process. [goal.md](goal.md) asks it from the start: "when
   terminated - entire created environment should gone".

## Why

The CLIs move daily and everything else weekly or slower. A daily update has
to cost what changed, the CLIs, and not what did not: with the CLIs in the
image, a new Claude made a new image id, and podman copied the whole 6 GB image
for it (see
[idmap-2026-09-04](idmap-2026-09-04.md), [audit-2026-10-07](audit-2026-10-07.md)
BOX-01).

Rule 4 came from Visual Notes on 2026-10-08. It ends an agent by ending
its shell: SIGHUP to the shell, SIGTERM to the rest of the tree, SIGKILL 3 s
later. `bin/run` exec'd `podman run`, which is only a client of conmon, so
the container lived on, and the old agent kept writing to the note beside
the new one. Since then `bin/run` keeps podman in the background and stops
the container by its id on a signal, with the stop detached so it finishes
after the SIGKILL (README, "The box ends with `bin/run`").

## Where it stands today

Built 2026-10-07, not yet run on the host: the CLIs, browsers, model and
Chrome live in `data/extras` ([extras](extras.md)). A daily `bin/build`
should find every image layer cached, so the image id stays and nothing is
copied (to confirm on the first weekday build); the fill installs the new
CLIs beside the old ones. The weekly refresh
rebuilds the image (one ~2.6 GB copy) and also takes a new Chrome.
