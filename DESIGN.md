# diffpane — design

Date: 2026-10-08

## Goal

While Claude Code works in a tmux pane, show a live, navigable view of every
file Claude changed, with its diff against HEAD. The view accumulates across
turns and resets when HEAD changes (commit by Claude or the user).

Success: the user never has to hunt for what Claude changed. They glance
left, see the newest change, and can step through all changed files with
keyboard or mouse.

## Decisions (from brainstorm)

- No editor integration. Read-only TUI built from `fzf` (0.74) + `delta`.
- Baseline is HEAD. Diff = working tree vs HEAD, per file.
- Scope is files Claude changed, not all dirty files.
- Detection is tool-agnostic. Claude often edits through Bash (sed, awk,
  python, echo, mv, rm), so tracking only Edit/Write is not acceptable.
- List on the left, inline (unified) diff on the right. No side-by-side.
- Order: newest turn first; within a turn, most recently changed first.
- Follow mode: on by default, toggleable.
- Assume a normal git repo. Bare repos (dotfiles setups) are out of scope.

## Architecture

```
UserPromptSubmit ─► turn++ ; snapshot T0
PreToolUse       ─► snapshot A
PostToolUse      ─► snapshot B ; changed = diff(A, B) ; record ; ping viewer
Stop             ─► snapshot T1 ; changed = diff(T0, T1) − already recorded ; record ; ping viewer

viewer (fzf):  list  = `list` script output
               preview = git diff HEAD -- <file> | delta
```

### Snapshot mechanism

A private git index at `$GIT_DIR/diffpane/index`:

```
GIT_INDEX_FILE=$GIT_DIR/diffpane/index git add -A
GIT_INDEX_FILE=$GIT_DIR/diffpane/index git write-tree   # -> tree sha
```

- Never touches the user's real index or staging.
- Respects `.gitignore`, so build output and `node_modules` stay out.
- The stat cache in the private index makes repeated snapshots incremental.
- Changed paths between two snapshots: `git diff --name-only <treeA> <treeB>`.
  This covers modifications, new files and deletions regardless of how they
  were made.

Attribution window is the duration of each tool call, so concurrent edits by
the user in other files are mostly excluded. The Stop-level diff catches
leftovers (background jobs, writes after a tool returned) and may occasionally
attribute a user edit made mid-turn. Accepted trade-off.

Read-only tools skip Pre/Post snapshots to halve overhead: Read, Grep, Glob,
WebFetch, WebSearch, TodoWrite, and similar. All other tools, including Bash,
Edit, Write, MultiEdit, NotebookEdit and Agent, snapshot.

### State

Per repo in `$(git rev-parse --git-dir)/diffpane/` (worktrees get their
own):

| File      | Content                                             |
|-----------|-----------------------------------------------------|
| `index`   | private git index for snapshots                     |
| `head`    | HEAD sha the state belongs to                       |
| `turn`    | current turn number                                 |
| `touched` | append-only log: `<epoch> <turn> <path>` per change |
| `pre`     | tree sha from the last PreToolUse                   |
| `t0`      | tree sha from turn start                            |
| `turns`   | append-only log: `<turn> start|end <tree>`          |
| `turnstat/<turn>` | cached numstat of a finished turn           |
| `view`    | `turns` or `files` (viewer, see Views)              |

Reset rule: whenever any script runs and `HEAD` differs from `head`, wipe
`touched`, reset `turn` to 0 and store the new sha. Covers commit, amend,
rebase, checkout.

## Components

A Claude Code plugin repo: `hooks/`, `bin/`, `lib/`, `themes/`, `tests/`.

1. **`hooks/record`** — the single hook entry point. Reads hook JSON on stdin
   (`hook_event_name`, `tool_name`, `cwd`). Dispatches on event as in the
   architecture diagram. Pings the viewer after recording. Must never block or
   fail Claude: exits 0 always, swallows errors, guards with a timeout.
   No-op outside a git work tree.
2. **`lib/list`** — prints the viewer rows for the current view (see Views).
   Applies the reset rule. Turns view: one row per file per turn, turns
   separated by divider rows (empty path, skipped when navigating). Files
   view: `touched` deduped by path keeping the newest entry. Both sort newest
   first and drop rows whose diff is now empty (reverted). File rows:
   `<M|A|D> +<add> −<del>  <name>[ ●]  <dir>`, stat columns right-aligned.
   Untracked new files are diffed against `/dev/null`.
3. **`bin/diffpane`** — the viewer. Runs fzf with:
   - list left (~30%), preview right (`--preview-window=right,70%`)
   - preview: `git diff HEAD -- <file> | delta` (or `--no-index /dev/null`
     for untracked), using the user's delta config plus fixed diff colors
   - `--listen` on a socket derived from the repo root, so viewers in
     different repos don't cross
   - periodic reload fallback (a few seconds) to catch commits made outside
     Claude
   - header: `<repo>  ↩|≡ ●|⏸|○` (view Turns, Files; follow on, paused, off) / `<t> turns  <n> files changed`,
     counts right-aligned; diff pane has no file header (the list shows it)
   - tmux pane title `Diffpane`
   - empty state: `No Claude changes since`, short sha, relative time, full
     subject and body (no trailers), wrapped to the list column
4. **`diffpane layout`** (`lib/layout`) — tmux helper: opens a new window in the current pane's
   directory with `diffpane` in the left 67% and `claude` in the right
   33% pane. A new window, not a split of the current one, so whatever runs
   in the current pane is left alone.
5. **`diffpane toggle`** (`lib/toggle`) — tmux helper: create the viewer pane left of the current
   pane if missing, kill it if present.

## Viewer behaviour

- On reload, selection stays on the same file (by path), not reset to top.
- Unseen changes get a `●` marker until that file is selected.
- **Follow mode** (default on): on each ping, select the newest changed file
  and show its diff.
  - Manual navigation (`j/k`, arrows, mouse click) while following pauses
    follow (`⏸`). `f` resumes.
  - `f` while off/paused turns follow on; `f` while on turns it off (`○`).
  - Paused follow turns back on when a later turn changes files; follow
    switched off with `f` stays off.
- Light/dark from `DIFFPANE_THEME` or the output of `DIFFPANE_THEME_CMD`
  (environment or `~/.config/diffpane/config`), default dark.
  fzf can't recolor live, so the ticker restarts fzf within ~3s of a switch,
  keeping the selected file when follow is off.

### Views: Turns and Files

Two lists over the same `touched` log. `v` switches; Turns is the default at
startup. The view is kept across the fzf restart on a theme switch.

- **Turns** — one row per file per turn, under plain turn dividers, newest
  turn first. A file changed in 10 turns has 10 rows. A row's diff and stats
  are that turn's change only: turn start tree → turn end tree, or → working
  tree for the turn still running. User edits made between turns fall
  outside every turn and don't show.
- **Files** — one row per file, newest change first, no dividers. Diff and
  stats against HEAD (the original list, without the dividers).

Per-turn snapshots: `record` appends `<turn> start <tree>` on
`UserPromptSubmit` and `<turn> end <tree>` on `Stop` to `turns`. Both trees are
already computed there, so the hook does no extra git work. A turn's last
`end` wins (Stop can fire more than once).

Rules:
- Turns without a `start` tree (recorded before this feature, or pruned by
  `git gc` after two weeks without a commit) are left out of Turns view;
  Files view still shows their files.
- A row whose turn diff is empty (changed and changed back within the turn)
  is left out.
- Stats per turn need one `git diff --numstat` per turn. A finished turn's
  trees never change, so its numstat is cached in `turnstat/<turn>`; only the
  running turn is computed on each reload.
- Rows carry the turn in a hidden third field (`<path>\t<display>\t<turn>`,
  empty in Files view); preview, refocus and `seen` key on path + turn.
- Unseen `●` is per row: each turn's change of a file is marked until that
  row is selected.
- Follow selects the first row in both views.
- Header line 1 shows the view as a symbol left of the follow state:
  `↩` Turns, `≡` Files (`<repo>  ↩ ●`). Line 2 stays
  `<t> turns  <n> files changed`; in Turns view `<t>` counts the turns shown.

### Keys

| Key              | Action                                            |
|------------------|---------------------------------------------------|
| `j` / `k`, click | select file                                       |
| `ctrl-d/u`, wheel| scroll diff                                       |
| `enter`          | open file in `$EDITOR` in a new tmux window       |
| `f`              | toggle follow                                     |
| `w`              | toggle word wrap in the diff                      |
| `v`              | switch view: Turns / Files                        |
| `r`              | manual reload                                     |
| `q`              | quit                                              |

No search. fzf runs with the query input disabled so `j/k` navigate.

## Wiring

- The plugin's `hooks/hooks.json` hooks `UserPromptSubmit`, `PreToolUse`,
  `PostToolUse`, `PostToolUseFailure` and `Stop` to `hooks/record`. Global,
  so every repo records whether or not a viewer is open; a viewer started
  late still shows everything since the last commit.
- `bin/diffpane` is linked onto `PATH` by the user (see README); tmux key
  bindings call `diffpane layout` / `diffpane toggle`.

## Edge cases

- Not a git repo → hooks no-op, viewer says so.
- File touched then reverted to HEAD content → disappears from list.
- Deleted file → shown with deletion diff, tag `deleted`.
- Rename → shown as delete + new.
- Binary file → delta's "binary differs".
- Multiple Claude sessions in one repo → share state, one list. Accepted.

## Testing

- Scripted test in a scratch git repo feeding synthetic hook JSON to
  `record`: Edit-style change, Bash `sed` change, `rm`, new file, revert to
  HEAD, commit. Assert `list` output contents and order after each step.
- Measure Pre+Post hook time on a real project (`tests/bench.sh`). Target < 50 ms;
  measured ~100 ms per pair on macOS, bounded by git process startup.
- Viewer UI tested by eye by the user.

## Out of scope (for now)

- Bare repo support (dotfiles setups).
- Hunk revert/stage from the viewer.
- Side-by-side diff.
