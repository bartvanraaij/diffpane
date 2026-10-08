# Shared helpers for claude-diff. Sourced, not executed. Bash 3.2 compatible.

CDIFF_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CDIFF_LIB="$CDIFF_HOME/lib"
export CDIFF_HOME CDIFF_LIB

# cdiff_init <dir>: resolve repo root and state dir. Returns 1 outside a git work tree.
cdiff_init() {
  local dir="${1:-$PWD}" out gitdir
  # One git spawn (~7ms each) for root, git dir and HEAD; a repo without commits fails on HEAD.
  out=$(git -C "$dir" rev-parse --show-toplevel --absolute-git-dir HEAD 2>/dev/null) ||
    out=$(git -C "$dir" rev-parse --show-toplevel --absolute-git-dir 2>/dev/null) || return 1
  CDIFF_HEAD=""
  { read -r CDIFF_ROOT; read -r gitdir; read -r CDIFF_HEAD; } <<EOF
$out
EOF
  CDIFF_HEAD=${CDIFF_HEAD:-none}
  CDIFF_STATE="$gitdir/claude-diff"
  CDIFF_REAL_INDEX="$gitdir/index"
  mkdir -p "$CDIFF_STATE/pre" || return 1
  export CDIFF_ROOT CDIFF_STATE CDIFF_REAL_INDEX CDIFF_HEAD
}

# Literal pathspecs: names like app/[id]/page.tsx must not act as globs.
cdiff_git() { git --literal-pathspecs -C "$CDIFF_ROOT" -c core.quotepath=off "$@"; }

# Diff base: HEAD, or the empty tree in a repo without commits.
cdiff_base() {
  cdiff_git rev-parse -q --verify HEAD 2>/dev/null || cdiff_git hash-object -t tree /dev/null
}

# mkdir lock (macOS has no flock). A lock held for ~3s is assumed stale.
cdiff_lock() {
  local i=0
  until mkdir "$CDIFF_STATE/lock" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
      rm -rf "$CDIFF_STATE/lock"
      i=0
    fi
    sleep 0.05
  done
}

cdiff_unlock() { rmdir "$CDIFF_STATE/lock" 2>/dev/null; }

# Reset the list when HEAD moved (commit, amend, checkout). Call with the lock held.
# Uses the HEAD that cdiff_init resolved. Snapshots (pre/*, t0) are tree shas that
# don't depend on HEAD, so in-flight tool calls keep them; only orphans (a Pre
# whose Post never came, e.g. a denied permission prompt) are pruned.
cdiff_sync_head() {
  local head="$CDIFF_HEAD"
  [ "$(cat "$CDIFF_STATE/head" 2>/dev/null)" = "$head" ] && return 0
  rm -f "$CDIFF_STATE/touched" "$CDIFF_STATE/seen"
  find "$CDIFF_STATE/pre" -type f -mmin +60 -delete 2>/dev/null
  # Seed the private index from the real one so the first snapshot reuses its stat cache.
  [ -f "$CDIFF_REAL_INDEX" ] && cp "$CDIFF_REAL_INDEX" "$CDIFF_STATE/index"
  echo "$head" > "$CDIFF_STATE/head"
}

# Print a tree sha fingerprinting the working tree. Respects .gitignore.
cdiff_snapshot() {
  GIT_INDEX_FILE="$CDIFF_STATE/index" cdiff_git add -A >/dev/null 2>&1 &&
    GIT_INDEX_FILE="$CDIFF_STATE/index" cdiff_git write-tree 2>/dev/null
}

cdiff_turn() { cat "$CDIFF_STATE/turn" 2>/dev/null || echo 0; }

# Append NUL-separated paths from stdin to the touched log for turn $1.
cdiff_record() {
  local turn="$1" path
  while IFS= read -r -d '' path; do
    printf '%s\t%s\n' "$turn" "$path" >> "$CDIFF_STATE/touched"
  done
}

# Like cdiff_record, but skips paths already logged in turn $1.
cdiff_record_new() {
  local turn="$1" path
  while IFS= read -r -d '' path; do
    grep -qxF "$(printf '%s\t%s' "$turn" "$path")" "$CDIFF_STATE/touched" 2>/dev/null && continue
    printf '%s\t%s\n' "$turn" "$path" >> "$CDIFF_STATE/touched"
  done
}

# Viewer socket path. Kept short: macOS caps unix socket paths at 104 bytes,
# which a deep repo path under .git would exceed.
# Hot path (every hook): no mkdir, cheap cksum. The viewer creates the dir.
cdiff_sock() {
  echo "/tmp/claude-diff-$UID/$(printf '%s' "$CDIFF_STATE" | cksum | cut -d' ' -f1).sock"
}

# Ask a running viewer to refresh. Never blocks. $CDIFF_LIB and {1} expand inside fzf.
cdiff_ping() {
  local sock
  sock=$(cdiff_sock)
  [ -S "$sock" ] || return 0
  ( curl -s --max-time 1 --unix-socket "$sock" http://localhost \
      -d 'transform($CDIFF_LIB/on-change {1})' >/dev/null 2>&1 & )
}

# light|dark for the diff and list colors. delta and fzf can't detect the
# terminal background inside fzf (no tty), so it is configured:
#   CLAUDE_DIFF_THEME=light|dark   fixed
#   CLAUDE_DIFF_THEME_CMD='...'    command printing light or dark, run on every
#                                  redraw (the viewer restyles on a switch)
# either in the environment or in ${XDG_CONFIG_HOME:-~/.config}/claude-diff/config
# (a shell snippet). Default dark.
cdiff_theme() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-diff/config" theme="$CLAUDE_DIFF_THEME" cmd="$CLAUDE_DIFF_THEME_CMD"
  if [ -z "$theme" ] && [ -f "$cfg" ]; then  # environment wins over the file
    local file
    file=$(unset CLAUDE_DIFF_THEME CLAUDE_DIFF_THEME_CMD; . "$cfg" >/dev/null 2>&1
      printf '%s\n%s' "$CLAUDE_DIFF_THEME" "$CLAUDE_DIFF_THEME_CMD")
    theme=${file%%$'\n'*}
    [ -n "$cmd" ] || cmd=${file#*$'\n'}
  fi
  [ -z "$theme" ] && [ -n "$cmd" ] && theme=$(sh -c "$cmd" 2>/dev/null)
  [ "$theme" = light ] && echo light || echo dark
}

# Usable width of the viewer's list column, one column kept free before the
# preview border. Inside fzf the preview's real left edge (it can be dragged);
# before fzf starts, the 70% preview split.
cdiff_list_width() {
  if [ -n "$FZF_PREVIEW_LEFT" ]; then echo $((FZF_PREVIEW_LEFT - 3)); return; fi
  local cols=${FZF_COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
  echo $((cols - cols * 70 / 100 - 1))
}
