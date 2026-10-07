# Extras: big tools in a folder beside the image

Built 2026-10-07 (`files/bin/extras-fill`, `bin/build`, `bin/run`); not yet
run on the host. It serves [build-and-run](build-and-run.md): the image
keeps what changes weekly, a host folder keeps the browsers, the speech model
and the two CLIs. Sizes are from [audit-2026-10-07](audit-2026-10-07.md).

## The folder

`data/extras/` in the ai-box clone, next to `data/claude` and `data/images`.
Every entry is named by its version, so a new version is a new folder beside
the old one, never a change inside it:

```
data/extras/
  versions                     what is here, one name=version a line
  ms-playwright/
    chromium-1234/             Playwright 1.62.1's revisions, as Playwright names them
    firefox-1538/
    webkit-2336/
    chromium_headless_shell-1228/
  cypress/14.5.4/
  huggingface/                 faster-whisper-small, in Hugging Face's own layout
  chrome/
    154.0.8037.97/             unpacked from the .deb
    current -> 154.0.8037.97
  npm/
    2.1.292-0.160.1/           claude-code + codex, installed together
    current -> 2.1.292-0.160.1
```

1.25 + 0.68 + 0.46 + 0.44 + 0.67 = 3.5 GB, stored once on the host for every
box. The image goes from 6.1 to ~2.6 GB.

## Filling it

`bin/build` fills the folder after the image, by running the new image with
the folder mounted writable and one script in it, `extras-fill`:

| entry | how | downloads when |
|---|---|---|
| Playwright browsers | `playwright install --no-shell chromium firefox webkit`, plus the pinned shell | `PLAYWRIGHT_VERSION` changes |
| Cypress | `cypress install` | `CYPRESS_VERSION` changes |
| Whisper model | `WhisperModel(...)` once, as the build does today | `WHISPER_MODEL` changes |
| Chrome | the .deb from Google's repository, checksum as today, `dpkg-deb -x` | weekly, with the full refresh |
| CLIs | `npm install` into a new `npm/<claude>-<codex>/` | daily, when either releases |

Each step looks for its version first and does nothing when it is there.
So the daily build is: no image rebuild, a CLI install into a new folder,
`current` moved. The weekly build is the image, then the same fill, which then
also fetches Chrome.

A step installs into a temporary name and renames it when its check passed
(`claude --version`, `cypress verify`, a real Chrome launch), so a failed or
interrupted fill leaves the previous version in place. Playwright's own
clean-up is off (`PLAYWRIGHT_SKIP_BROWSER_GC`): it would delete the headless
shell, whose Playwright is a throwaway npx copy. Instead `.wanted` records
when each entry was last current, and an entry is removed three days after
that (`KEEP_DAYS`), so a box started before the fill still finds the version
it started with.

## Mounting it

`bin/run` mounts it once, `-v data/extras:/opt/extras:O`:

- the host folder is the lower layer and is never written by a box;
- a box may write there (a project's own `npx playwright install`); the
  writes go to a throwaway layer that ends with the box, as writes into the
  image do today. Tested with the nested podman; not yet on the host.

No folder, or no `versions` file in it: `bin/run` stops with
"data/extras is empty: run bin/build".

## How the agent knows

Mostly it does not have to: **every tool stays where it is today.** The agent
types the same commands and finds the same paths; only the bytes behind them
moved. That is the point of doing it by convention: nothing new to learn,
nothing to tell it.

| the agent uses | today | with extras |
|---|---|---|
| `claude`, `codex` | `~/.local/bin` | `/opt/extras/npm/current/bin`, on `PATH` before `~/.local/bin` |
| Playwright | `PLAYWRIGHT_BROWSERS_PATH=~/.cache/ms-playwright` | the same variable, `=/opt/extras/ms-playwright` |
| Cypress | `CYPRESS_CACHE_FOLDER=~/.cache/Cypress` | `=/opt/extras/cypress` |
| `transcribe`, faster-whisper | `HF_HOME=~/.cache/huggingface` | `=/opt/extras/huggingface` |
| `google-chrome`, Puppeteer | `/opt/google/chrome` | `/opt/google/chrome` is a link to `/opt/extras/chrome/current` |

Three places cover the rest:

1. **What is installed: `/etc/ai-box/versions`.** It is the file an agent
   (or `bin/missings --versions`) already reads for the image's versions.
   Its last line becomes `# browsers, speech model, claude, codex:
   /opt/extras/versions`, and that file has the same format, written by the
   fill. One `cat` and the agent sees both halves.
2. **When something is missing, the error says where and why.** Playwright
   and Cypress print their own "run npx playwright install", which works
   (into the throwaway layer). `google-chrome` and `transcribe` check their
   folder first and say: "Chrome lives in /opt/extras/chrome, which has no
   version: run bin/build on the host". The agent learns about extras the
   moment it matters, and not before.
3. **Writes do not last**, the same as anywhere outside `/app` today. Not new,
   so nothing to say.

Not proposed: an instructions file for agents in the box (Claude Code reads a
machine-wide `/etc/claude-code/CLAUDE.md`). It would be the first such file
ai-box puts in front of the agent, and it would repeat what the paths and the
errors already say.

## Decisions

- Chrome's libraries stay in the image: it installs the
  `google-chrome-stable` package's `Depends` with `apt-get satisfy`, not the
  package. The package's own extras, an apt source and a daily cron job, are
  of no use in a box. Its `chrome-sandbox` loses the setuid bit: in the box
  Chrome sandboxes itself with user namespaces ("adequately sandboxed" on
  chrome://sandbox with the setuid helper disabled).
- Chrome moves on weekly, with the image's libraries: `bin/build` passes
  `REFRESH=1` to the first fill of a week (`data/extras/refresh`).

## Open

- The `:O` mount on the host's native overlay, rootless: tested only with the
  nested podman. The kernel calls changes to an overlay's lower folder while
  it is mounted undefined; the fill only adds folders, moves `current` links
  and removes what has been unused for three days.
