# claude-review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tmux pane that live-lists every file Claude Code changed since HEAD (newest first) with an inline delta diff of the selected file.

**Architecture:** A single Claude Code hook script snapshots the working tree into a private git index before and after every non-read-only tool call; the paths that differ between the two tree shas are appended to a log in `$GIT_DIR/claude-review/`. An fzf-based viewer reads that log through small helper scripts, renders diffs with delta, and is refreshed by the hook through fzf's `--listen` unix socket plus a 3-second ticker.

**Tech Stack:** bash 3.2 (macOS `/bin/bash`), git, jq, curl, fzf 0.74, delta 0.20, tmux 3.7.

**Spec:** `~/.config/claude-review/DESIGN.md`

## Global Constraints

- Scripts must run on macOS `/bin/bash` 3.2: no associative arrays, no `mapfile`, no `${var,,}`. BSD tools: `sed -i ''`, no `date +%N`.
- `record` must never print to stdout or stderr and must always exit 0 (UserPromptSubmit hook stdout is injected into Claude's context).
- All state lives in `$(git rev-parse --absolute-git-dir)/claude-review/`. Nothing is written into the work tree. The user's real index is never modified.
- Diff base is HEAD; in a repo without commits it is the empty tree.
- Inline (unified) diff only, rendered by `delta` with the user's git config.
- No search in the viewer (`--no-input`).
- Follow mode defaults to on.
- Any tmux test uses the private socket `tmux -L crtest`. Never run `kill-server` on the default tmux server.
- Dotfiles are a bare repo. In scripts use `DOT="git --git-dir=$HOME/.dot --work-tree=$HOME"` and always commit with explicit paths.

## Review Focus

- Parallel tool calls (Pre A, Pre B, Post A, Post B) must not lose or corrupt entries: snapshots are keyed by `tool_use_id` and guarded by a lock. Test in Task 1.
- Paths containing spaces must work end to end. Test in Tasks 1 and 2.
- `record` printing anything would pollute Claude's context. Test in Task 1.
- A rename (`mv`, `git mv`) must show as delete + new, not just the new name (`--no-renames`). Test in Task 1.
- A repo without any commits must still list and diff new files. Test in Tasks 2 and 3.

---

## File structure

```
~/.config/claude-review/
  DESIGN.md            spec
  PLAN.md              this plan
  record               Claude Code hook entry point
  claude-review        the viewer (fzf)
  layout               tmux: new window, viewer left 67%, claude right 33%
  toggle               tmux: toggle viewer pane left of a pane
  lib/common.sh        shared helpers (sourced)
  lib/list             viewer rows
  lib/preview          delta diff for one file
  lib/header           header text
  lib/on-change        fzf transform: refresh when list changed
  lib/on-focus         fzf transform: pause follow, mark seen
  lib/toggle-follow    fzf transform: 'f' key
  tests/helpers.sh     assert + fixtures
  tests/run.sh         runs every tests/test_*.sh
  tests/test_record.sh
  tests/test_list.sh
  tests/test_preview_header.sh
  tests/test_actions.sh
  tests/smoke_viewer.sh
  tests/bench.sh
```

State files in `$GIT_DIR/claude-review/`:

| File        | Written by        | Content                                          |
|-------------|-------------------|--------------------------------------------------|
| `index`     | record            | private git index                                |
| `head`      | common.sh         | HEAD sha (or `none`) the state belongs to        |
| `turn`      | record            | current turn number                              |
| `t0`        | record            | tree sha at turn start / last Stop               |
| `pre/<id>`  | record            | tree sha from PreToolUse for tool call `<id>`    |
| `touched`   | record            | log lines `<turn>\t<path>`; line number = order  |
| `seen`      | lib/on-focus      | lines `<touched line count>\t<path>`             |
| `follow`    | viewer, actions   | `on`, `paused` or `off`                          |
| `view.list` | viewer, on-change | last rows shown in fzf                           |
| `fzf.sock`  | fzf               | `--listen` socket                                |
| `lock/`     | common.sh         | mkdir lock                                       |

---

### Task 1: Hook recorder

**Files:**
- Create: `~/.config/claude-review/lib/common.sh`
- Create: `~/.config/claude-review/record`
- Create: `~/.config/claude-review/tests/helpers.sh`
- Create: `~/.config/claude-review/tests/run.sh`
- Test: `~/.config/claude-review/tests/test_record.sh`

**Interfaces:**
- Produces (common.sh, sourced): `CR_HOME`, `CR_LIB`; `cr_init <dir>` sets/exports `CR_ROOT`, `CR_STATE`, `CR_REAL_INDEX`, returns 1 outside a work tree; `cr_git <args>` (git in repo root, quotepath off); `cr_base` prints HEAD sha or empty tree sha; `cr_lock` / `cr_unlock`; `cr_sync_head` (call with lock held); `cr_snapshot` prints a tree sha; `cr_turn` prints current turn; `cr_record <turn>` and `cr_record_new <turn>` read NUL-separated paths on stdin; `cr_ping`.
- Produces (record): reads hook JSON on stdin, fields `hook_event_name`, `tool_name`, `tool_use_id`, `cwd`. Silent, exit 0.
- Produces (helpers.sh): `assert_eq <expected> <actual> <msg>`, `mkrepo <name> [--empty]`, `hook <repo> <event> [tool] [id]`, `tool <repo> <id> <cmd...>`, `touched <repo>`, `rows <repo>`, `display <repo>`, `state <repo>`, `finish`.

- [ ] **Step 1: Write test helpers and runner**

`tests/helpers.sh`:

```bash
# Tiny assert lib and fixtures for claude-review tests. Bash 3.2.
CR_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

assert_eq() { # <expected> <actual> <msg>
  if [ "$1" = "$2" ]; then
    printf '  ok   %s\n' "$3"
  else
    printf '  FAIL %s\n    expected: %q\n    actual:   %q\n' "$3" "$1" "$2"
    FAILS=$((FAILS + 1))
  fi
}

# mkrepo <name> [--empty]: repo with a.txt b.txt c.txt committed (or no commits). Prints path.
mkrepo() {
  local r="$TMPROOT/$1"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email t@t
  git -C "$r" config user.name t
  if [ "$2" != --empty ]; then
    printf 'a\n' > "$r/a.txt"; printf 'b\n' > "$r/b.txt"; printf 'c\n' > "$r/c.txt"
    git -C "$r" add -A && git -C "$r" commit -qm init
  fi
  echo "$r"
}

# hook <repo> <event> [tool] [tool_use_id]: feed synthetic hook JSON to record, print its stdout.
hook() {
  jq -nc --arg e "$2" --arg t "${3:-}" --arg i "${4:-}" --arg c "$1" \
    '{hook_event_name: $e, cwd: $c}
     + (if $t != "" then {tool_name: $t} else {} end)
     + (if $i != "" then {tool_use_id: $i} else {} end)' |
    "$CR_HOME/record"
}

# tool <repo> <id> <cmd...>: run cmd in repo wrapped in Pre/PostToolUse, like a Bash tool call.
tool() {
  local repo="$1" id="$2"
  shift 2
  hook "$repo" PreToolUse Bash "$id" >/dev/null
  (cd "$repo" && "$@")
  hook "$repo" PostToolUse Bash "$id" >/dev/null
}

state() { echo "$(git -C "$1" rev-parse --absolute-git-dir)/claude-review"; }

# touched <repo>: paths in the touched log, in log order.
touched() { cut -f2 "$(state "$1")/touched" 2>/dev/null; }

# rows <repo>: list paths (field 1) in display order.
rows() { (cd "$1" && "$CR_HOME/lib/list") | cut -f1; }

# display <repo>: list display column without ANSI codes.
display() { (cd "$1" && "$CR_HOME/lib/list") | cut -f2 | sed $'s/\033\\[[0-9;]*m//g'; }

finish() {
  if [ "$FAILS" -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
}
```

`tests/run.sh`:

```bash
#!/usr/bin/env bash
# Run every tests/test_*.sh; exit non-zero if any fails.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test_*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
exit $rc
```

- [ ] **Step 2: Write the failing record tests**

`tests/test_record.sh`:

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"

echo "record: tool-agnostic capture"
r=$(mkrepo basic)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "a2\n" >> a.txt'
assert_eq "a.txt" "$(touched "$r")" "edit inside a tool call is recorded"
tool "$r" t2 sed -i '' 's/b/B/' b.txt
assert_eq $'a.txt\nb.txt' "$(touched "$r")" "sed edit is recorded"
tool "$r" t3 rm c.txt
tool "$r" t4 sh -c 'printf "n\n" > "new file.txt"'
assert_eq $'a.txt\nb.txt\nc.txt\nnew file.txt' "$(touched "$r")" "delete and new file with space are recorded"
assert_eq "1" "$(cat "$(state "$r")/turn")" "turn counter is 1"

echo "record: rename shows both paths"
r=$(mkrepo rename)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 git mv a.txt z.txt
assert_eq $'a.txt\nz.txt' "$(touched "$r" | sort)" "git mv records old and new path"

echo "record: user edits outside tool calls are ignored"
r=$(mkrepo user)
hook "$r" UserPromptSubmit >/dev/null
printf 'mine\n' >> "$r/a.txt"
tool "$r" t1 sh -c 'printf "x\n" >> b.txt'
assert_eq "b.txt" "$(touched "$r")" "user edit before tool call is not attributed"

echo "record: Stop catches late changes, not edits between turns"
r=$(mkrepo stop)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "x\n" >> a.txt'
printf 'late\n' >> "$r/b.txt"   # e.g. a background job finishing after its tool call returned
hook "$r" Stop >/dev/null
assert_eq $'a.txt\nb.txt' "$(touched "$r")" "Stop adds late change and does not repeat a.txt"
printf 'between turns\n' >> "$r/c.txt"
hook "$r" UserPromptSubmit >/dev/null
hook "$r" Stop >/dev/null
assert_eq $'a.txt\nb.txt' "$(touched "$r")" "edit between turns is not attributed"

echo "record: parallel and failed tool calls"
r=$(mkrepo parallel)
hook "$r" UserPromptSubmit >/dev/null
hook "$r" PreToolUse Bash p1 >/dev/null
hook "$r" PreToolUse Edit p2 >/dev/null
printf 'x\n' >> "$r/a.txt"
hook "$r" PostToolUse Bash p1 >/dev/null
printf 'y\n' >> "$r/b.txt"
hook "$r" PostToolUse Edit p2 >/dev/null
assert_eq $'a.txt\nb.txt' "$(touched "$r" | sort -u)" "interleaved parallel calls capture both files"
assert_eq "" "$(ls "$(state "$r")/pre")" "pre snapshots are cleaned up"
hook "$r" PreToolUse Bash f1 >/dev/null
printf 'z\n' >> "$r/c.txt"
hook "$r" PostToolUseFailure Bash f1 >/dev/null
assert_eq "c.txt" "$(touched "$r" | tail -1)" "PostToolUseFailure records changes"
hook "$r" PreToolUse Bash >/dev/null
printf 'w\n' >> "$r/a.txt"
hook "$r" PostToolUse Bash >/dev/null
assert_eq "a.txt" "$(touched "$r" | tail -1)" "missing tool_use_id still works"

echo "record: read-only tools skip snapshots"
hook "$r" PreToolUse Read r1 >/dev/null
assert_eq "no" "$([ -e "$(state "$r")/pre/r1" ] && echo yes || echo no)" "Read creates no pre snapshot"

echo "record: commit wipes the list"
r=$(mkrepo commit)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "x\n" >> a.txt'
tool "$r" t2 sh -c 'git add -A && git commit -qm wip'
assert_eq "" "$(touched "$r")" "commit inside a tool call empties the log"

echo "record: silent and safe"
r=$(mkrepo silent)
out=$(hook "$r" UserPromptSubmit; hook "$r" PreToolUse Bash s1; hook "$r" PostToolUse Bash s1; hook "$r" Stop)
assert_eq "" "$out" "record prints nothing"
mkdir -p "$TMPROOT/plain"
out=$(hook "$TMPROOT/plain" PostToolUse Bash x; echo "rc=$?")
assert_eq "rc=0" "$out" "outside a git repo: silent, exit 0"
out=$(echo 'not json' | "$CR_HOME/record"; echo "rc=$?")
assert_eq "rc=0" "$out" "garbage input: silent, exit 0"

finish
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash ~/.config/claude-review/tests/test_record.sh`
Expected: FAIL lines (record does not exist yet), ending in `N failed`.

- [ ] **Step 4: Write `lib/common.sh`**

```bash
# Shared helpers for claude-review. Sourced, not executed. Bash 3.2 compatible.

CR_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CR_LIB="$CR_HOME/lib"
export CR_HOME CR_LIB

# cr_init <dir>: resolve repo root and state dir. Returns 1 outside a git work tree.
cr_init() {
  local dir="${1:-$PWD}" gitdir
  CR_ROOT=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  CR_STATE="$gitdir/claude-review"
  CR_REAL_INDEX="$gitdir/index"
  mkdir -p "$CR_STATE/pre" || return 1
  export CR_ROOT CR_STATE CR_REAL_INDEX
}

cr_git() { git -C "$CR_ROOT" -c core.quotepath=off "$@"; }

# Diff base: HEAD, or the empty tree in a repo without commits.
cr_base() {
  cr_git rev-parse -q --verify HEAD 2>/dev/null || cr_git hash-object -t tree /dev/null
}

# mkdir lock (macOS has no flock). A lock held for ~3s is assumed stale.
cr_lock() {
  local i=0
  until mkdir "$CR_STATE/lock" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
      rm -rf "$CR_STATE/lock"
      i=0
    fi
    sleep 0.05
  done
}

cr_unlock() { rmdir "$CR_STATE/lock" 2>/dev/null; }

# Wipe state when HEAD moved (commit, amend, checkout). Call with the lock held.
cr_sync_head() {
  local head
  head=$(cr_git rev-parse -q --verify HEAD 2>/dev/null || echo none)
  [ "$(cat "$CR_STATE/head" 2>/dev/null)" = "$head" ] && return 0
  rm -f "$CR_STATE/touched" "$CR_STATE/seen" "$CR_STATE/turn" "$CR_STATE/t0" "$CR_STATE"/pre/*
  # Seed the private index from the real one so the first snapshot reuses its stat cache.
  [ -f "$CR_REAL_INDEX" ] && cp "$CR_REAL_INDEX" "$CR_STATE/index"
  echo "$head" > "$CR_STATE/head"
}

# Print a tree sha fingerprinting the working tree. Respects .gitignore.
cr_snapshot() {
  GIT_INDEX_FILE="$CR_STATE/index" cr_git add -A >/dev/null 2>&1 &&
    GIT_INDEX_FILE="$CR_STATE/index" cr_git write-tree 2>/dev/null
}

cr_turn() { cat "$CR_STATE/turn" 2>/dev/null || echo 0; }

# Append NUL-separated paths from stdin to the touched log for turn $1.
cr_record() {
  local turn="$1" path
  while IFS= read -r -d '' path; do
    printf '%s\t%s\n' "$turn" "$path" >> "$CR_STATE/touched"
  done
}

# Like cr_record, but skips paths already logged in turn $1.
cr_record_new() {
  local turn="$1" path
  while IFS= read -r -d '' path; do
    grep -qxF "$(printf '%s\t%s' "$turn" "$path")" "$CR_STATE/touched" 2>/dev/null && continue
    printf '%s\t%s\n' "$turn" "$path" >> "$CR_STATE/touched"
  done
}

# Ask a running viewer to refresh. Never blocks. $CR_LIB and {1} expand inside fzf.
cr_ping() {
  [ -S "$CR_STATE/fzf.sock" ] || return 0
  ( curl -s --max-time 1 --unix-socket "$CR_STATE/fzf.sock" http://localhost \
      -d 'transform($CR_LIB/on-change {1})' >/dev/null 2>&1 & )
}
```

- [ ] **Step 5: Write `record`**

```bash
#!/usr/bin/env bash
# Claude Code hook entry point: UserPromptSubmit, PreToolUse, PostToolUse,
# PostToolUseFailure, Stop. Records which files Claude changed, however it
# changed them. Must never block, fail or print.
. "$(dirname "$0")/lib/common.sh"

READONLY_TOOLS=" Read Grep Glob LS WebFetch WebSearch TodoWrite ToolSearch Skill AskUserQuestion TaskCreate TaskGet TaskList TaskUpdate TaskOutput "

main() {
  local event tool id cwd pre tree
  # "-" placeholders: tab is IFS whitespace, so empty fields would collapse.
  IFS=$'\t' read -r event tool id cwd <<EOF
$(jq -r '[.hook_event_name // "-", .tool_name // "-", .tool_use_id // "-", .cwd // "-"] | @tsv')
EOF
  case "$READONLY_TOOLS" in *" $tool "*) return 0 ;; esac
  # Bad input must not fall back to the hook's own cwd (`git -C ""` is a no-op).
  [ -n "$cwd" ] && [ "$cwd" != - ] && [ -d "$cwd" ] || return 0
  cr_init "$cwd" || return 0

  cr_lock
  cr_sync_head
  case "$event" in
    UserPromptSubmit)
      echo $(($(cr_turn) + 1)) > "$CR_STATE/turn"
      cr_snapshot > "$CR_STATE/t0"
      ;;
    PreToolUse)
      cr_snapshot > "$CR_STATE/pre/$id"
      ;;
    PostToolUse | PostToolUseFailure)
      if [ -s "$CR_STATE/pre/$id" ]; then
        pre=$(cat "$CR_STATE/pre/$id")
        tree=$(cr_snapshot)
        [ -n "$tree" ] && cr_git diff --name-only --no-renames -z "$pre" "$tree" | cr_record "$(cr_turn)"
      fi
      rm -f "$CR_STATE/pre/$id"
      ;;
    Stop)
      tree=$(cr_snapshot)
      if [ -s "$CR_STATE/t0" ] && [ -n "$tree" ]; then
        cr_git diff --name-only --no-renames -z "$(cat "$CR_STATE/t0")" "$tree" | cr_record_new "$(cr_turn)"
      fi
      [ -n "$tree" ] && echo "$tree" > "$CR_STATE/t0"
      ;;
  esac
  cr_unlock

  case "$event" in PostToolUse | PostToolUseFailure | Stop) cr_ping ;; esac
}

main >/dev/null 2>&1
exit 0
```

Run: `chmod +x ~/.config/claude-review/record ~/.config/claude-review/tests/run.sh`

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash ~/.config/claude-review/tests/test_record.sh`
Expected: every line `ok`, last line `all passed`.

- [ ] **Step 7: Commit**

```bash
DOT="git --git-dir=$HOME/.dot --work-tree=$HOME"
cd ~ && $DOT add .config/claude-review/record .config/claude-review/lib/common.sh .config/claude-review/tests
$DOT commit -m "feat(claude-review): hook recorder with git tree snapshots" -- .config/claude-review/record .config/claude-review/lib/common.sh .config/claude-review/tests
```

---

### Task 2: List rows

**Files:**
- Create: `~/.config/claude-review/lib/list`
- Test: `~/.config/claude-review/tests/test_list.sh`

**Interfaces:**
- Consumes: everything common.sh produces; `touched` and `seen` file formats from the state table.
- Produces: `lib/list`, run with cwd inside the repo, prints rows `<path>\t<display>` newest first. Display, without ANSI: `<mark> <turn>  <path>  +<add> −<del>[  new|  deleted]`, where `<mark>` is `●` (unseen) or a space. Prints nothing when there are no rows.

- [ ] **Step 1: Write the failing tests**

`tests/test_list.sh`:

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"

echo "list: order, stats, tags"
r=$(mkrepo list)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "a2\n" >> a.txt'
hook "$r" Stop >/dev/null
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t2 rm c.txt
tool "$r" t3 sh -c 'printf "1\n2\n3\n" > "new file.txt"'
tool "$r" t4 sh -c 'printf "b2\n" >> b.txt'
assert_eq $'b.txt\nnew file.txt\nc.txt\na.txt' "$(rows "$r")" "newest first"
assert_eq $'● 2  b.txt  +1 −0\n● 2  new file.txt  +3 −0  new\n● 2  c.txt  +0 −1  deleted\n● 1  a.txt  +1 −0' \
  "$(display "$r")" "display format"

echo "list: reverted files drop, re-edits move to top"
tool "$r" t5 git checkout -- b.txt
assert_eq $'new file.txt\nc.txt\na.txt' "$(rows "$r")" "reverted b.txt is gone"
tool "$r" t6 sh -c 'printf "a3\n" >> a.txt'
assert_eq "a.txt" "$(rows "$r" | head -1)" "re-edited a.txt moves to top"
tool "$r" t7 sh -c 'printf "x\n" > tmp.txt && rm tmp.txt'
assert_eq "" "$(rows "$r" | grep -x tmp.txt)" "file created and deleted is not listed"

echo "list: seen marker"
total=$(wc -l < "$(state "$r")/touched" | tr -d ' ')
printf '%s\t%s\n' "$total" a.txt >> "$(state "$r")/seen"
assert_eq "  2  a.txt  +2 −0" "$(display "$r" | head -1)" "seen file has no marker"

echo "list: commit outside Claude resets"
git -C "$r" add -A && git -C "$r" commit -qm user
assert_eq "" "$(rows "$r")" "list empty after user commit"

echo "list: repo without commits"
r=$(mkrepo empty --empty)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "x\n" > x.txt'
assert_eq "● 1  x.txt  +1 −0  new" "$(display "$r")" "new file listed in fresh repo"

finish
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash ~/.config/claude-review/tests/test_list.sh`
Expected: FAIL lines (lib/list missing), ending in `N failed`.

- [ ] **Step 3: Write `lib/list`**

```bash
#!/usr/bin/env bash
# Print viewer rows "<path>\t<display>", newest change first.
# Files that no longer differ from HEAD are skipped.
. "$(dirname "$0")/common.sh"

cr_init "$PWD" || exit 0
cr_lock; cr_sync_head; cr_unlock
[ -s "$CR_STATE/touched" ] || exit 0

base=$(cr_base)
TAB=$(printf '\t')
Y=$'\033[33m' G=$'\033[32m' R=$'\033[31m' C=$'\033[36m' D=$'\033[2m' N=$'\033[0m'

# Newest log line per path, newest first: "<line>\t<turn>\t<path>".
awk -F'\t' '{ line[$2] = NR; turn[$2] = $1 }
  END { for (p in line) printf "%d\t%s\t%s\n", line[p], turn[p], p }' "$CR_STATE/touched" |
  sort -t "$TAB" -k1,1nr |
  while IFS="$TAB" read -r line turn path; do
    tag=""
    if cr_git cat-file -e "$base:$path" 2>/dev/null; then
      [ -e "$CR_ROOT/$path" ] || [ -L "$CR_ROOT/$path" ] || tag=deleted
      stat=$(cr_git diff --numstat "$base" -- "$path")
      [ -n "$stat" ] || continue
      add=$(printf '%s' "$stat" | cut -f1)
      del=$(printf '%s' "$stat" | cut -f2)
    else
      [ -f "$CR_ROOT/$path" ] || continue
      tag=new
      add=$(wc -l < "$CR_ROOT/$path" | tr -d ' ')
      del=0
    fi
    seen=$(awk -F'\t' -v p="$path" '$2 == p { s = $1 } END { print s + 0 }' "$CR_STATE/seen" 2>/dev/null)
    mark=" "
    [ "$line" -gt "${seen:-0}" ] && mark="${Y}●${N}"
    printf '%s\t%s %s%s%s  %s  %s+%s%s %s−%s%s%s\n' \
      "$path" "$mark" "$D" "$turn" "$N" "$path" "$G" "$add" "$N" "$R" "$del" "$N" "${tag:+  $C$tag$N}"
  done
```

Run: `chmod +x ~/.config/claude-review/lib/list`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash ~/.config/claude-review/tests/run.sh`
Expected: both test files end with `all passed`.

- [ ] **Step 5: Commit**

```bash
DOT="git --git-dir=$HOME/.dot --work-tree=$HOME"
cd ~ && $DOT add .config/claude-review/lib/list .config/claude-review/tests/test_list.sh
$DOT commit -m "feat(claude-review): list rows newest first with stats and seen markers" -- .config/claude-review/lib/list .config/claude-review/tests/test_list.sh
```

---

### Task 3: Preview and header

**Files:**
- Create: `~/.config/claude-review/lib/preview`
- Create: `~/.config/claude-review/lib/header`
- Test: `~/.config/claude-review/tests/test_preview_header.sh`

**Interfaces:**
- Consumes: `cr_init`, `cr_git`, `cr_base`, `cr_turn`; `follow` and `view.list` state files.
- Produces: `lib/preview <path>` prints a delta-rendered inline diff of `<path>` vs base (untracked/new files diffed against `/dev/null`), width `$FZF_PREVIEW_COLUMNS` (default 80). `lib/header` prints line 1 `claude-review · <repo> · <n> files · turn <t> · follow ●|⏸|○` and, when n is 0, line 2 `No Claude changes since <short sha> <subject>`.

- [ ] **Step 1: Write the failing tests**

`tests/test_preview_header.sh`:

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
strip() { sed $'s/\033\\[[0-9;]*m//g'; }

echo "preview"
r=$(mkrepo prev)
printf 'modified-line\n' >> "$r/a.txt"
printf 'brand-new-line\n' > "$r/fresh.txt"
rm "$r/c.txt"
out=$(cd "$r" && "$CR_HOME/lib/preview" a.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q modified-line && echo yes)" "modified file shows added line"
out=$(cd "$r" && "$CR_HOME/lib/preview" fresh.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q brand-new-line && echo yes)" "untracked file shows content"
out=$(cd "$r" && "$CR_HOME/lib/preview" c.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q c.txt && echo yes)" "deleted file shows a diff"
r2=$(mkrepo prevempty --empty)
printf 'first-ever\n' > "$r2/x.txt"
out=$(cd "$r2" && "$CR_HOME/lib/preview" x.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q first-ever && echo yes)" "repo without commits shows new file"
assert_eq "" "$(cd "$r" && "$CR_HOME/lib/preview" '')" "empty path prints nothing"

echo "header"
r=$(mkrepo head)
st=$(state "$r"); mkdir -p "$st"
: > "$st/view.list"
sha=$(git -C "$r" rev-parse --short HEAD)
assert_eq "claude-review · head · 0 files · turn 0 · follow ○
No Claude changes since $sha init" "$(cd "$r" && "$CR_HOME/lib/header")" "empty state"
printf 'a.txt\tx\nb.txt\ty\n' > "$st/view.list"
echo on > "$st/follow"; echo 3 > "$st/turn"
assert_eq "claude-review · head · 2 files · turn 3 · follow ●" "$(cd "$r" && "$CR_HOME/lib/header")" "with files, follow on"
echo paused > "$st/follow"
assert_eq "yes" "$(cd "$r" && "$CR_HOME/lib/header" | grep -q 'follow ⏸' && echo yes)" "paused symbol"

finish
```

Note: the header test writes `turn` without a `head` file; `lib/header` must not call `cr_sync_head` (it would wipe `turn`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash ~/.config/claude-review/tests/test_preview_header.sh`
Expected: FAIL lines, ending in `N failed`.

- [ ] **Step 3: Write `lib/preview`**

```bash
#!/usr/bin/env bash
# Inline diff of one file against HEAD, rendered by delta. Usage: preview <path>
. "$(dirname "$0")/common.sh"

cr_init "$PWD" || exit 0
path="$1"
[ -n "$path" ] || exit 0
base=$(cr_base)

{
  if cr_git cat-file -e "$base:$path" 2>/dev/null; then
    cr_git --no-pager diff "$base" -- "$path"
  else
    cr_git --no-pager diff --no-index -- /dev/null "$path"
  fi
} | delta --paging=never --width="${FZF_PREVIEW_COLUMNS:-80}"
```

- [ ] **Step 4: Write `lib/header`**

```bash
#!/usr/bin/env bash
# Viewer header: repo, file count, turn, follow state; empty-state hint.
. "$(dirname "$0")/common.sh"

cr_init "$PWD" || exit 0
n=$(grep -c . < "$CR_STATE/view.list" 2>/dev/null)
n=${n:-0}
case "$(cat "$CR_STATE/follow" 2>/dev/null)" in
  on) follow="follow ●" ;;
  paused) follow="follow ⏸" ;;
  *) follow="follow ○" ;;
esac
printf 'claude-review · %s · %s files · turn %s · %s\n' "$(basename "$CR_ROOT")" "$n" "$(cr_turn)" "$follow"
if [ "$n" -eq 0 ]; then
  printf 'No Claude changes since %s\n' "$(cr_git log -1 --format='%h %s' 2>/dev/null || echo 'repo start')"
fi
```

Run: `chmod +x ~/.config/claude-review/lib/preview ~/.config/claude-review/lib/header`

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash ~/.config/claude-review/tests/run.sh`
Expected: all three test files end with `all passed`.

- [ ] **Step 6: Commit**

```bash
DOT="git --git-dir=$HOME/.dot --work-tree=$HOME"
cd ~ && $DOT add .config/claude-review/lib/preview .config/claude-review/lib/header .config/claude-review/tests/test_preview_header.sh
$DOT commit -m "feat(claude-review): delta preview and viewer header" -- .config/claude-review/lib/preview .config/claude-review/lib/header .config/claude-review/tests/test_preview_header.sh
```

---

### Task 4: Viewer actions (follow, refresh, seen)

**Files:**
- Create: `~/.config/claude-review/lib/on-change`
- Create: `~/.config/claude-review/lib/on-focus`
- Create: `~/.config/claude-review/lib/toggle-follow`
- Test: `~/.config/claude-review/tests/test_actions.sh`

**Interfaces:**
- Consumes: `lib/list`, `lib/header`, `cr_init`; `follow`, `view.list`, `touched`, `seen` state files.
- Produces (all print fzf action strings for `transform`, or nothing):
  - `lib/on-change <focused-path> [--force]`: if list output equals `view.list` (and no `--force`) print nothing; else write `view.list` and print `reload-sync(cat "$CR_STATE/view.list")+first` when follow is `on`, otherwise `...+pos(<1-based index of focused path>)` (or `+first` if gone). `$CR_STATE` is printed literally; fzf's shell expands it.
  - `lib/on-focus <index> <path>`: index is fzf's zero-based `{n}`. If follow is `on` and index ≠ 0, set follow `paused` and emit `transform-header($CR_LIB/header)`. If the focused row in `view.list` contains `●`, append `<touched line count>\t<path>` to `seen` and emit on-change's output. Joins actions with `+`.
  - `lib/toggle-follow`: `on` → `off`, print `transform-header($CR_LIB/header)`; `off`/`paused` → `on`, print `first+transform-header($CR_LIB/header)`.

- [ ] **Step 1: Write the failing tests**

`tests/test_actions.sh`:

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
run() { (cd "$r" && "$CR_HOME/lib/$@"); }
RELOAD='reload-sync(cat "$CR_STATE/view.list")'
HEADER='transform-header($CR_LIB/header)'

r=$(mkrepo act)
st=$(state "$r")
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "x\n" >> a.txt'
tool "$r" t2 sh -c 'printf "x\n" >> b.txt'

echo "on-change"
echo on > "$st/follow"
assert_eq "$RELOAD+first" "$(run on-change b.txt)" "first change with follow on jumps to top"
assert_eq "" "$(run on-change b.txt)" "unchanged list prints nothing"
assert_eq "$RELOAD+first" "$(run on-change b.txt --force)" "--force reloads anyway"
echo off > "$st/follow"
tool "$r" t3 sh -c 'printf "x\n" >> c.txt'
assert_eq "$RELOAD+pos(3)" "$(run on-change a.txt)" "follow off keeps focus on a.txt (now row 3)"
tool "$r" t4 git checkout -- a.txt
assert_eq "$RELOAD+first" "$(run on-change a.txt)" "focused file gone falls back to first"

echo "on-focus"
echo on > "$st/follow"
run on-change c.txt --force >/dev/null
out=$(run on-focus 0 c.txt)
assert_eq "on" "$(cat "$st/follow")" "focus on top row keeps follow on"
assert_eq "$RELOAD+first" "$out" "focusing unseen top row marks it seen and reloads"
assert_eq "" "$(run on-focus 0 c.txt)" "already seen row: no actions"
out=$(run on-focus 1 b.txt)
assert_eq "paused" "$(cat "$st/follow")" "moving off top row pauses follow"
assert_eq "$HEADER+$RELOAD+pos(2)" "$out" "pause updates header, marks b.txt seen keeping focus"
assert_eq "" "$(run on-focus '' '')" "empty list: no actions"

echo "toggle-follow"
assert_eq "first+$HEADER" "$(run toggle-follow)" "paused -> on jumps to newest"
assert_eq "on" "$(cat "$st/follow")" "state on"
assert_eq "$HEADER" "$(run toggle-follow)" "on -> off"
assert_eq "off" "$(cat "$st/follow")" "state off"
assert_eq "first+$HEADER" "$(run toggle-follow)" "off -> on"

finish
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash ~/.config/claude-review/tests/test_actions.sh`
Expected: FAIL lines, ending in `N failed`.

- [ ] **Step 3: Write `lib/on-change`**

```bash
#!/usr/bin/env bash
# fzf transform: reload the list if it changed. Usage: on-change <focused-path> [--force]
# Follow on: jump to newest. Otherwise keep focus on the same file.
. "$(dirname "$0")/common.sh"

cr_init "$PWD" || exit 0
focused="$1"
new=$("$CR_LIB/list")
if [ "$2" != --force ] && [ "$new" = "$(cat "$CR_STATE/view.list" 2>/dev/null)" ]; then
  exit 0
fi
if [ -n "$new" ]; then printf '%s\n' "$new" > "$CR_STATE/view.list"; else : > "$CR_STATE/view.list"; fi

reload='reload-sync(cat "$CR_STATE/view.list")'
if [ "$(cat "$CR_STATE/follow" 2>/dev/null)" = on ]; then
  echo "$reload+first"
  exit 0
fi
idx=$(cut -f1 "$CR_STATE/view.list" | grep -nxF -- "$focused" | head -1 | cut -d: -f1)
if [ -n "$idx" ]; then echo "$reload+pos($idx)"; else echo "$reload+first"; fi
```

- [ ] **Step 4: Write `lib/on-focus`**

```bash
#!/usr/bin/env bash
# fzf focus handler. Usage: on-focus <index> <path>  (index = fzf's zero-based {n})
# Pauses follow when the user moves off the newest row; marks the focused file seen.
. "$(dirname "$0")/common.sh"

cr_init "$PWD" || exit 0
n="$1" path="$2"
[ -n "$path" ] || exit 0
actions=""

if [ "$(cat "$CR_STATE/follow" 2>/dev/null)" = on ] && [ "$n" != 0 ]; then
  echo paused > "$CR_STATE/follow"
  actions='transform-header($CR_LIB/header)'
fi

row=$(awk -F'\t' -v p="$path" '$1 == p' "$CR_STATE/view.list" 2>/dev/null)
case "$row" in
  *●*)
    total=$(wc -l < "$CR_STATE/touched" 2>/dev/null | tr -d ' ')
    printf '%s\t%s\n' "${total:-0}" "$path" >> "$CR_STATE/seen"
    more=$("$CR_LIB/on-change" "$path")
    [ -n "$more" ] && actions="${actions:+$actions+}$more"
    ;;
esac

[ -n "$actions" ] && echo "$actions"
exit 0
```

- [ ] **Step 5: Write `lib/toggle-follow`**

```bash
#!/usr/bin/env bash
# fzf 'f' key: follow on -> off; off or paused -> on (and jump to newest).
. "$(dirname "$0")/common.sh"

cr_init "$PWD" || exit 0
if [ "$(cat "$CR_STATE/follow" 2>/dev/null)" = on ]; then
  echo off > "$CR_STATE/follow"
  echo 'transform-header($CR_LIB/header)'
else
  echo on > "$CR_STATE/follow"
  echo 'first+transform-header($CR_LIB/header)'
fi
```

Run: `chmod +x ~/.config/claude-review/lib/on-change ~/.config/claude-review/lib/on-focus ~/.config/claude-review/lib/toggle-follow`

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash ~/.config/claude-review/tests/run.sh`
Expected: all four test files end with `all passed`.

- [ ] **Step 7: Commit**

```bash
DOT="git --git-dir=$HOME/.dot --work-tree=$HOME"
cd ~ && $DOT add .config/claude-review/lib/on-change .config/claude-review/lib/on-focus .config/claude-review/lib/toggle-follow .config/claude-review/tests/test_actions.sh
$DOT commit -m "feat(claude-review): follow mode, refresh and seen-marker actions" -- .config/claude-review/lib/on-change .config/claude-review/lib/on-focus .config/claude-review/lib/toggle-follow .config/claude-review/tests/test_actions.sh
```

---

### Task 5: The viewer

**Files:**
- Create: `~/.config/claude-review/claude-review`
- Modify: `~/.config/zsh/aliases.zsh` (add one alias)
- Test: `~/.config/claude-review/tests/smoke_viewer.sh`

**Interfaces:**
- Consumes: `lib/list`, `lib/preview`, `lib/header`, `lib/on-change`, `lib/on-focus`, `lib/toggle-follow`; `cr_ping` posts `transform($CR_LIB/on-change {1})` to `$CR_STATE/fzf.sock`.
- Produces: `claude-review` command (run inside a repo). Exits 1 with a message outside a git work tree or when a viewer for the repo is already running. Keys: `j/k` move, `ctrl-d/u` scroll diff, `enter` opens the file in `$EDITOR` in a new tmux window, `f` follow, `r` reload, `q` quit.

- [ ] **Step 1: Write the smoke test**

`tests/smoke_viewer.sh` (runs the viewer in a private tmux server, never the default one):

```bash
#!/usr/bin/env bash
# Smoke test: viewer starts, shows header, picks up a hook-driven change live.
. "$(dirname "$0")/helpers.sh"
T="tmux -L crtest"
trap '$T kill-server 2>/dev/null; rm -rf "$TMPROOT"' EXIT

wait_for() { # <pattern>: poll the pane for up to 5s
  local i
  for i in $(seq 50); do
    $T capture-pane -p -t crtest | grep -q -- "$1" && return 0
    sleep 0.1
  done
  return 1
}

r=$(mkrepo smoke)
$T new-session -d -s crtest -x 160 -y 40 -c "$r" "$CR_HOME/claude-review"
wait_for "claude-review · smoke · 0 files" && assert_eq ok ok "header shows empty state" || assert_eq ok fail "header shows empty state"

hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "live-change\n" >> a.txt'
wait_for "a.txt" && assert_eq ok ok "hook ping shows a.txt" || assert_eq ok fail "hook ping shows a.txt"
wait_for "live-change" && assert_eq ok ok "preview shows the diff" || assert_eq ok fail "preview shows the diff"

out=$(cd "$r" && "$CR_HOME/claude-review" 2>&1; echo "rc=$?")
assert_eq "yes" "$(echo "$out" | grep -q 'already running' && echo yes)" "second viewer refuses to start"

git -C "$r" add -A && git -C "$r" commit -qm done
wait_for "0 files" && assert_eq ok ok "ticker picks up user commit" || assert_eq ok fail "ticker picks up user commit"

finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash ~/.config/claude-review/tests/smoke_viewer.sh`
Expected: FAIL lines (viewer missing), ending in `N failed`.

- [ ] **Step 3: Write `claude-review`**

```bash
#!/usr/bin/env bash
# claude-review: live list + inline diff of files Claude changed since HEAD.
# See ~/.config/claude-review/DESIGN.md.
. "$(dirname "$0")/lib/common.sh"

cr_init "$PWD" || { echo "claude-review: not inside a git work tree" >&2; exit 1; }
cd "$CR_ROOT" || exit 1
sock="$CR_STATE/fzf.sock"

if [ -S "$sock" ] && curl -s --max-time 1 --unix-socket "$sock" http://localhost >/dev/null 2>&1; then
  echo "claude-review: already running for $CR_ROOT" >&2
  exit 1
fi

echo on > "$CR_STATE/follow"
rows=$("$CR_LIB/list")
if [ -n "$rows" ]; then printf '%s\n' "$rows" > "$CR_STATE/view.list"; else : > "$CR_STATE/view.list"; fi

# Ticker: catches commits and edits made outside Claude. Stops when this script exits.
(
  while sleep 3 && kill -0 $$ 2>/dev/null; do
    curl -s --max-time 1 --unix-socket "$sock" http://localhost \
      -d 'transform($CR_LIB/on-change {1})' >/dev/null 2>&1
  done
) &
ticker=$!
trap 'kill $ticker 2>/dev/null' EXIT

if [ -n "$TMUX" ]; then
  open='execute-silent(tmux new-window -c "$CR_ROOT" "${EDITOR:-nvim} {1}")'
else
  open='execute(${EDITOR:-nvim} {1})'
fi

fzf < "$CR_STATE/view.list" \
  --listen="$sock" \
  --ansi --no-input --no-sort --layout=reverse --info=hidden \
  --delimiter='\t' --with-nth=2 \
  --preview '$CR_LIB/preview {1}' \
  --preview-window 'right,70%,border-left' \
  --bind 'start:transform-header($CR_LIB/header)' \
  --bind 'result:transform-header($CR_LIB/header)' \
  --bind 'focus:transform($CR_LIB/on-focus {n} {1})' \
  --bind 'j:down,k:up' \
  --bind 'ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up' \
  --bind 'f:transform($CR_LIB/toggle-follow)' \
  --bind 'r:transform($CR_LIB/on-change {1} --force)' \
  --bind "enter:$open" \
  --bind 'q:abort'
```

Run: `chmod +x ~/.config/claude-review/claude-review`

- [ ] **Step 4: Run the smoke test**

Run: `bash ~/.config/claude-review/tests/smoke_viewer.sh`
Expected: all `ok`, `all passed`. If a step fails, inspect with `tmux -L crtest capture-pane -p -t crtest` before the trap fires (temporarily comment out the trap's kill-server).

- [ ] **Step 5: Add the alias**

Append to `~/.config/zsh/aliases.zsh` next to the other aliases:

```zsh
alias claude-review='~/.config/claude-review/claude-review'
```

- [ ] **Step 6: Ask the user to try it by eye**

Ask the user to run `claude-review` in a repo with uncommitted changes made through Claude, and check: list left / diff right, mouse click and wheel, `j/k`, `ctrl-d/u`, `f` toggles header symbol, `enter` opens nvim in a new window, `q` quits.

- [ ] **Step 7: Commit**

```bash
DOT="git --git-dir=$HOME/.dot --work-tree=$HOME"
cd ~ && $DOT add .config/claude-review/claude-review .config/claude-review/tests/smoke_viewer.sh .config/zsh/aliases.zsh
$DOT commit -m "feat(claude-review): fzf viewer with live reload" -- .config/claude-review/claude-review .config/claude-review/tests/smoke_viewer.sh .config/zsh/aliases.zsh
```

---

### Task 6: Wire hooks into Claude Code

**Files:**
- Modify: `~/.claude/settings.json` (add `hooks`)
- Create: `~/.config/claude-review/tests/bench.sh`

**Interfaces:**
- Consumes: `record`.
- Produces: global hooks for `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`, each running `~/.config/claude-review/record` with a 10s timeout.

- [ ] **Step 1: Write the benchmark**

`tests/bench.sh`:

```bash
#!/usr/bin/env bash
# Average Pre+Post hook time in a real repo. Usage: bench.sh <repo>
. "$(dirname "$0")/helpers.sh"
repo="${1:?usage: bench.sh <repo>}"
hook "$repo" PreToolUse Bash warm >/dev/null; hook "$repo" PostToolUse Bash warm >/dev/null
TIMEFORMAT='%R'
total=$( { time (for i in 1 2 3 4 5 6 7 8 9 10; do
  hook "$repo" PreToolUse Bash "b$i" >/dev/null
  hook "$repo" PostToolUse Bash "b$i" >/dev/null
done) ; } 2>&1 )
echo "10 Pre+Post pairs: ${total}s total (target < 0.5s, i.e. < 50ms per pair)"
```

- [ ] **Step 2: Run the benchmark on my-app**

Run: `bash ~/.config/claude-review/tests/bench.sh ~/Dev/my-app`
Expected: total under 0.5s. The benchmark changes no files; it only creates `.git/claude-review/` in my-app, which the live hooks would create anyway. If over target, stop and report the number to the user before wiring hooks.

- [ ] **Step 3: Back up and add hooks to settings.json**

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak-claude-review
h='{"type":"command","command":"~/.config/claude-review/record","timeout":10}'
jq --argjson h "$h" '.hooks = (.hooks // {}) + {
  UserPromptSubmit:   [{hooks: [$h]}],
  PreToolUse:         [{matcher: "*", hooks: [$h]}],
  PostToolUse:        [{matcher: "*", hooks: [$h]}],
  PostToolUseFailure: [{matcher: "*", hooks: [$h]}],
  Stop:               [{hooks: [$h]}]
}' ~/.claude/settings.json > ~/.claude/settings.json.tmp && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
jq .hooks ~/.claude/settings.json
```

Expected: the printed `hooks` object contains the five events. `.hooks` is `null` today, so nothing is overwritten.

- [ ] **Step 4: Verify live**

Ask the user to start a fresh `claude` session in my-app with `claude-review` open in a pane next to it, and ask Claude to make one edit with Edit and one with `sed`. Both files must appear in the viewer within a second, newest on top. Confirm `/hooks` in Claude Code lists the five hooks.

- [ ] **Step 5: Commit**

```bash
DOT="git --git-dir=$HOME/.dot --work-tree=$HOME"
cd ~ && $DOT add .config/claude-review/tests/bench.sh
$DOT ls-files --error-unmatch .claude/settings.json >/dev/null 2>&1 && $DOT add .claude/settings.json
$DOT commit -m "feat(claude-review): wire Claude Code hooks" -- .config/claude-review/tests/bench.sh $($DOT ls-files .claude/settings.json)
```

`settings.json` is committed only if the dotfiles repo already tracks it.

---

### Task 7: tmux layout and toggle

**Files:**
- Create: `~/.config/claude-review/layout`
- Create: `~/.config/claude-review/toggle`
- Modify: `~/.config/tmux/tmux.conf` (two bindings)
- Modify: `~/.config/claude-review/DESIGN.md` (layout opens a new window)

**Interfaces:**
- Consumes: `claude-review`.
- Produces: `layout <dir>` opens a new tmux window in `<dir>`: viewer left, shell running `claude` right at 33%, focus on Claude. `toggle <pane_id>` kills the viewer pane (tmux pane option `@claude-review` = 1) in that pane's window if present, otherwise splits a 67% viewer pane to the left of `<pane_id>` without moving focus.

Design deviation, to record in DESIGN.md: the spec says `prefix + C` splits the *current* window. Doing that would kill or crowd whatever runs in the current pane, so `layout` opens a new window instead.

- [ ] **Step 1: Write `layout`**

```bash
#!/usr/bin/env bash
# tmux: new window with claude-review left (67%) and claude right (33%). Usage: layout <dir>
dir="${1:-$PWD}"
viewer=$(tmux new-window -c "$dir" -n "$(basename "$dir")" -P -F '#{pane_id}')
tmux set -p -t "$viewer" @claude-review 1
tmux send-keys -t "$viewer" "$HOME/.config/claude-review/claude-review" Enter
claude=$(tmux split-window -h -l 33% -t "$viewer" -c "$dir" -P -F '#{pane_id}')
tmux send-keys -t "$claude" claude Enter
```

- [ ] **Step 2: Write `toggle`**

```bash
#!/usr/bin/env bash
# tmux: toggle the claude-review pane left of a pane. Usage: toggle <pane_id>
pane="${1:-$TMUX_PANE}"
existing=$(tmux list-panes -t "$pane" -F '#{pane_id} #{@claude-review}' | awk '$2 == 1 { print $1; exit }')
if [ -n "$existing" ]; then
  tmux kill-pane -t "$existing"
  exit 0
fi
dir=$(tmux display -p -t "$pane" '#{pane_current_path}')
new=$(tmux split-window -hbd -l 67% -t "$pane" -c "$dir" -P -F '#{pane_id}' \
  "$HOME/.config/claude-review/claude-review || sleep 3")
tmux set -p -t "$new" @claude-review 1
```

Run: `chmod +x ~/.config/claude-review/layout ~/.config/claude-review/toggle`

- [ ] **Step 3: Test both on the private tmux server**

```bash
T="tmux -L crtest"
r=$(mktemp -d) && git -C "$r" init -q
$T new-session -d -s crtest -x 200 -y 50 -c "$r"
p=$($T display -p -t crtest '#{pane_id}')
```

`toggle` and `layout` call plain `tmux`, which talks to the default server. To test them against `crtest` without touching the default server, run them with `TMUX` pointed at the crtest socket:

```bash
sock=$($T display -p '#{socket_path}')
TMUX="$sock,0,0" ~/.config/claude-review/toggle "$p"
$T list-panes -t crtest -F '#{pane_id} #{@claude-review} #{pane_width}'
```

Expected: two panes; the new one has `@claude-review` = 1 and ~67% of the width.

```bash
TMUX="$sock,0,0" ~/.config/claude-review/toggle "$p"
$T list-panes -t crtest -F '#{pane_id} #{@claude-review}'
```

Expected: one pane left (viewer killed).

```bash
TMUX="$sock,0,0" ~/.config/claude-review/layout "$r"
$T list-panes -t crtest:2 -F '#{pane_id} #{@claude-review} #{pane_width}'
$T kill-server
rm -rf "$r"
```

Expected: window 2 with two panes, the left one flagged and ~67% wide. (`claude` is typed into the right pane; it may start or fail inside the test server, either is fine.) Only the `crtest` server is killed.

- [ ] **Step 4: Add bindings to tmux.conf**

Add after the split bindings in `~/.config/tmux/tmux.conf`:

```tmux
# claude-review: live view of files Claude changed (~/.config/claude-review)
bind C run-shell -b '~/.config/claude-review/layout "#{pane_current_path}"'
bind g run-shell -b '~/.config/claude-review/toggle "#{pane_id}"'
```

Ask the user to reload tmux config (`prefix + R`) and try `prefix + C` and `prefix + g`.

- [ ] **Step 5: Update DESIGN.md**

In `DESIGN.md`, replace the `layout` component description:

```markdown
4. **`layout`** — tmux helper: opens a new window in the current pane's
   directory with `claude-review` in the left 67% and `claude` in the right
   33% pane. A new window, not a split of the current one, so whatever runs
   in the current pane is left alone.
```

- [ ] **Step 6: Commit**

```bash
DOT="git --git-dir=$HOME/.dot --work-tree=$HOME"
cd ~ && $DOT add .config/claude-review/layout .config/claude-review/toggle .config/tmux/tmux.conf .config/claude-review/DESIGN.md
$DOT commit -m "feat(claude-review): tmux layout and toggle bindings" -- .config/claude-review/layout .config/claude-review/toggle .config/tmux/tmux.conf .config/claude-review/DESIGN.md
```
