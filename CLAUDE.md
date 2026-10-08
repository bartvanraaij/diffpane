# diffpane — notes for working on this repo

Claude Code plugin + fzf/delta viewer. Read `DESIGN.md` for how it works and
`README.md` for how it's installed and configured.

## Layout

- `hooks/record` — hook entry point (all five events, see `hooks/hooks.json`)
- `bin/diffpane` — viewer; dispatches `toggle` / `layout` to `lib/`
- `lib/common.sh` — shared helpers, prefix `dp_` / `DP_`
- `lib/*` — fzf actions (`list`, `preview`, `header`, `on-change`, `on-focus`, `toggle-follow`) and tmux helpers
- `.claude-plugin/` — plugin manifest and marketplace entry

## Constraints

- **bash 3.2** (macOS `/bin/bash`): no associative arrays, no `mapfile`, no
  `${var,,}`. A variable followed directly by a non-ASCII char needs braces:
  `"${G}●"`, not `"$G●"`.
- **BSD userland** on macOS: `sed -i ''`, awk counts bytes not characters
  (pad around multibyte symbols by hand), no `readlink -f`.
- **The hook must never print, block or fail Claude.** `UserPromptSubmit`
  stdout is injected into Claude's context. `record` runs `main >/dev/null 2>&1;
  exit 0`. Keep it fast: every tool call pays for it (~100 ms per Pre+Post
  pair today, mostly git process startup; `tests/bench.sh`).
- Unix socket paths max 104 bytes on macOS, hence `/tmp/diffpane-$UID/`.
- Git paths are literal (`--literal-pathspecs`): files like `app/[id]/page.tsx`.
- fzf has no event for dragging the preview border or for changing colors;
  the 3 s ticker (`on-change`) covers both.
- Plugin names may not start with `claude-` (reserved by Claude Code).

## Working on it

- Test first: write or adjust a test, watch it fail, then change the code.
- `tests/run.sh` — unit tests (fast). Run after every change.
- `tests/smoke_viewer.sh`, `tests/smoke_tmux.sh` — drive the real viewer in a
  **private** tmux server (`tmux -L <name> -f /dev/null`). Never touch the
  default tmux server.
- Smoke tests poll for end states (`wait_for`); don't assert on the first frame
  after an async fzf action.
- `claude plugin validate .` after touching `.claude-plugin/` or `hooks/`.
- With a local-directory marketplace, edits apply at the next Claude session
  or `/reload-plugins`.
