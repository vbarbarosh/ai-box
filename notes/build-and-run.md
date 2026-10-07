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

## Why

The CLIs move daily and everything else weekly or slower. A daily update has
to cost what changed, the CLIs, and not what did not: with the CLIs in the
image, a new Claude made a new image id, and podman copied the whole 6 GB image
for it (see
[idmap-2026-09-04](idmap-2026-09-04.md), [audit-2026-10-07](audit-2026-10-07.md)
BOX-01).

## Where it stands today

Built 2026-10-07, not yet run on the host: the CLIs, browsers, model and
Chrome live in `data/extras` ([extras](extras.md)). A daily `bin/build`
should find every image layer cached, so the image id stays and nothing is
copied (to confirm on the first weekday build); the fill installs the new
CLIs beside the old ones. The weekly refresh
rebuilds the image (one ~2.6 GB copy) and also takes a new Chrome.
