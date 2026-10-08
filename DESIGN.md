# claude-review — design

Date: 2026-10-08

## Goal

While Claude Code works in a tmux pane, show a live, navigable view of every
file Claude changed, with its diff against HEAD. The view accumulates across
turns and resets when HEAD changes (commit by Claude or the user).

Success: the user never has to hunt for what Claude changed. They glance
left, see the newest change, and can step through all changed files with
keyboard or mouse.

## Decisions (from brainstorm)

- No nvim. Read-only TUI built from `fzf` (>= 0.36, have 0.74) + `delta`.
- Baseline is HEAD. Diff = working tree vs HEAD, per file.
- Scope is files Claude changed, not all dirty files.
- Detection is tool-agnostic. Claude often edits through Bash (sed, awk,
  python, echo, mv, rm), so tracking only Edit/Write is not acceptable.
- List on the left, inline (unified) diff on the right. No side-by-side.
- Order: newest turn first; within a turn, most recently changed first.
- Follow mode: on by default, toggleable.
- Assume a normal git repo. Dotfiles bare repo is out of scope.

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

A private git index at `$GIT_DIR/claude-review/index`:

```
GIT_INDEX_FILE=$GIT_DIR/claude-review/index git add -A
GIT_INDEX_FILE=$GIT_DIR/claude-review/index git write-tree   # -> tree sha
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

Per repo in `$(git rev-parse --git-dir)/claude-review/` (worktrees get their
own):

| File      | Content                                             |
|-----------|-----------------------------------------------------|
| `index`   | private git index for snapshots                     |
| `head`    | HEAD sha the state belongs to                       |
| `turn`    | current turn number                                 |
| `touched` | append-only log: `<epoch> <turn> <path>` per change |
| `pre`     | tree sha from the last PreToolUse                   |
| `t0`      | tree sha from turn start                            |

Reset rule: whenever any script runs and `HEAD` differs from `head`, wipe
`touched`, reset `turn` to 0 and store the new sha. Covers commit, amend,
rebase, checkout.

## Components

All under `~/.config/claude-review/`, tracked in dotfiles.

1. **`record`** — the single hook entry point. Reads hook JSON on stdin
   (`hook_event_name`, `tool_name`, `cwd`). Dispatches on event as in the
   architecture diagram. Pings the viewer after recording. Must never block or
   fail Claude: exits 0 always, swallows errors, guards with a timeout.
   No-op outside a git work tree.
2. **`list`** — prints the viewer rows. Applies the reset rule. Dedups
   `touched` by path keeping the newest entry, sorts newest first, and drops
   paths whose diff vs HEAD is now empty (reverted). Row format:
   `<marker> <turn>  <path>  +<add> −<del>  [new|deleted]`.
   Untracked new files are diffed against `/dev/null`.
3. **`claude-review`** — the viewer. Runs fzf with:
   - list left (~30%), preview right (`--preview-window=right,70%`)
   - preview: `git diff HEAD -- <file> | delta` (or `--no-index /dev/null`
     for untracked), using the user's existing delta config/theme
   - `--listen` on a socket derived from the repo root, so viewers in
     different repos don't cross
   - periodic reload fallback (a few seconds) to catch commits made outside
     Claude
   - header: `claude-review · <repo> · <n> files · turn <t> · follow ●|⏸|○`
   - empty state: `No Claude changes since <short sha> <subject>`
4. **`layout`** — tmux helper: opens a new window in the current pane's
   directory with `claude-review` in the left 67% and `claude` in the right
   33% pane. A new window, not a split of the current one, so whatever runs
   in the current pane is left alone.
5. **`toggle`** — tmux helper: create the viewer pane left of the current
   pane if missing, kill it if present.

## Viewer behaviour

- On reload, selection stays on the same file (by path), not reset to top.
- Unseen changes get a `●` marker until that file is selected.
- **Follow mode** (default on): on each ping, select the newest changed file
  and show its diff.
  - Manual navigation (`j/k`, arrows, mouse click) while following pauses
    follow (`⏸`). `f` resumes.
  - `f` while off/paused turns follow on; `f` while on turns it off (`○`).
- Light/dark follows the `theme` tool's Ghostty file (`CR_THEME` overrides).
  fzf can't recolor live, so the ticker restarts fzf within ~3s of a switch,
  keeping the selected file when follow is off.

### Keys

| Key              | Action                                            |
|------------------|---------------------------------------------------|
| `j` / `k`, click | select file                                       |
| `ctrl-d/u`, wheel| scroll diff                                       |
| `enter`          | open file in `$EDITOR` in a new tmux window       |
| `f`              | toggle follow                                     |
| `r`              | manual reload                                     |
| `q`              | quit                                              |

No search. fzf runs with the query input disabled so `j/k` navigate.

## Wiring

- `~/.claude/settings.json`: hooks `UserPromptSubmit`, `PreToolUse`,
  `PostToolUse`, `Stop` all call `~/.config/claude-review/record`. Global, so
  every repo records whether or not a viewer is open; a viewer started late
  still shows everything since the last commit.
- `~/.config/tmux/tmux.conf`:
  - `prefix + C` → `layout` (overrides default customize-mode)
  - `prefix + g` → `toggle`
- Plain command `claude-review` usable in any pane.

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
- Measure Pre+Post hook time on a real project (my-app). Target < 50 ms.
- Viewer UI tested by eye by the user.

## Out of scope (for now)

- Dotfiles bare repo support.
- Per-turn diffs (design keeps snapshot shas, so possible later).
- Hunk revert/stage from the viewer.
- Side-by-side diff.
