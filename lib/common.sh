# Shared helpers for diffpane. Sourced, not executed. Bash 3.2 compatible.

DP_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DP_LIB="$DP_HOME/lib"
export DP_HOME DP_LIB

# dp_init <dir>: resolve repo root and state dir. Returns 1 outside a git work tree.
dp_init() {
  local dir="${1:-$PWD}" out gitdir
  # One git spawn (~7ms each) for root, git dir and HEAD; a repo without commits fails on HEAD.
  out=$(git -C "$dir" rev-parse --show-toplevel --absolute-git-dir HEAD 2>/dev/null) ||
    out=$(git -C "$dir" rev-parse --show-toplevel --absolute-git-dir 2>/dev/null) || return 1
  DP_HEAD=""
  { read -r DP_ROOT; read -r gitdir; read -r DP_HEAD; } <<EOF
$out
EOF
  DP_HEAD=${DP_HEAD:-none}
  DP_STATE="$gitdir/diffpane"
  DP_REAL_INDEX="$gitdir/index"
  mkdir -p "$DP_STATE/pre" || return 1
  export DP_ROOT DP_STATE DP_REAL_INDEX DP_HEAD
}

# Literal pathspecs: names like app/[id]/page.tsx must not act as globs.
dp_git() { git --literal-pathspecs -C "$DP_ROOT" -c core.quotepath=off "$@"; }

# Diff base: HEAD, or the empty tree in a repo without commits.
dp_base() {
  dp_git rev-parse -q --verify HEAD 2>/dev/null || dp_git hash-object -t tree /dev/null
}

# mkdir lock (macOS has no flock). A lock held for ~3s is assumed stale.
dp_lock() {
  local i=0
  until mkdir "$DP_STATE/lock" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
      rm -rf "$DP_STATE/lock"
      i=0
    fi
    sleep 0.05
  done
}

dp_unlock() { rmdir "$DP_STATE/lock" 2>/dev/null; }

# Reset the list when HEAD moved (commit, amend, checkout). Call with the lock held.
# Uses the HEAD that dp_init resolved. Snapshots (pre/*, t0) are tree shas that
# don't depend on HEAD, so in-flight tool calls keep them; only orphans (a Pre
# whose Post never came, e.g. a denied permission prompt) are pruned.
# The turn log restarts too; a turn already running continues from the new
# HEAD, so its later changes don't include what was just committed.
dp_sync_head() {
  local head="$DP_HEAD" turn
  [ "$(cat "$DP_STATE/head" 2>/dev/null)" = "$head" ] && return 0
  rm -f "$DP_STATE/touched" "$DP_STATE/seen" "$DP_STATE/turns" "$DP_STATE/ended"
  rm -rf "$DP_STATE/turnstat"
  turn=$(dp_turn)
  [ "$turn" -gt 0 ] 2>/dev/null &&
    dp_turn_log "$turn" start "$(dp_git rev-parse -q --verify "$(dp_base)^{tree}")"
  find "$DP_STATE/pre" -type f -mmin +60 -delete 2>/dev/null
  # Seed the private index from the real one so the first snapshot reuses its stat cache.
  [ -f "$DP_REAL_INDEX" ] && cp "$DP_REAL_INDEX" "$DP_STATE/index"
  echo "$head" > "$DP_STATE/head"
}

# Print a tree sha fingerprinting the working tree. Respects .gitignore.
dp_snapshot() {
  GIT_INDEX_FILE="$DP_STATE/index" dp_git add -A >/dev/null 2>&1 &&
    GIT_INDEX_FILE="$DP_STATE/index" dp_git write-tree 2>/dev/null
}

dp_turn() { cat "$DP_STATE/turn" 2>/dev/null || echo 0; }

# dp_turn_log <turn> start|end|resume <tree>: append to the turn log (no-op without a tree).
dp_turn_log() {
  [ -n "$3" ] && printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$DP_STATE/turns"
}

# Print "<turn>\t<start tree>\t<end tree>" for each turn with a start snapshot.
# End is the turn's own Stop snapshot, else the next turn's start (an
# interrupted turn fires no Stop), else empty: the turn is still running.
# A tool call after Stop (a Stop hook can send Claude back to work) logs
# "resume", which clears the end until the next Stop.
dp_turn_ranges() {
  [ -s "$DP_STATE/turns" ] || return 0
  awk -F'\t' '
    $2 == "start" { if (!($1 in start)) order[++n] = $1; start[$1] = $3; stop[$1] = "" }
    $2 == "end" && ($1 in start) { stop[$1] = $3 }
    $2 == "resume" && ($1 in start) { stop[$1] = "" }
    END {
      for (i = 1; i <= n; i++) {
        t = order[i]; e = stop[t]
        if (e == "" && i < n) e = start[order[i + 1]]
        printf "%s\t%s\t%s\n", t, start[t], e
      }
    }' "$DP_STATE/turns"
}

# Append NUL-separated paths from stdin to the touched log for turn $1.
dp_record() {
  local turn="$1" path
  while IFS= read -r -d '' path; do
    printf '%s\t%s\n' "$turn" "$path" >> "$DP_STATE/touched"
  done
}

# Like dp_record, but skips paths already logged in turn $1.
dp_record_new() {
  local turn="$1" path
  while IFS= read -r -d '' path; do
    grep -qxF "$(printf '%s\t%s' "$turn" "$path")" "$DP_STATE/touched" 2>/dev/null && continue
    printf '%s\t%s\n' "$turn" "$path" >> "$DP_STATE/touched"
  done
}

# Viewer socket path. Kept short: macOS caps unix socket paths at 104 bytes,
# which a deep repo path under .git would exceed.
# Hot path (every hook): no mkdir, cheap cksum. The viewer creates the dir.
dp_sock() {
  echo "/tmp/diffpane-$UID/$(printf '%s' "$DP_STATE" | cksum | cut -d' ' -f1).sock"
}

# Ask a running viewer to refresh. Never blocks. $DP_LIB, {1} and {3} expand inside fzf.
dp_ping() {
  local sock
  sock=$(dp_sock)
  [ -S "$sock" ] || return 0
  ( curl -s --max-time 1 --unix-socket "$sock" http://localhost \
      -d 'transform($DP_LIB/on-change {1} {3})' >/dev/null 2>&1 & )
}

# light|dark for the diff and list colors. delta and fzf can't detect the
# terminal background inside fzf (no tty), so it is configured:
#   DIFFPANE_THEME=light|dark   fixed
#   DIFFPANE_THEME_CMD='...'    command printing light or dark, run on every
#                                  redraw (the viewer restyles on a switch)
# either in the environment or in ${XDG_CONFIG_HOME:-~/.config}/diffpane/config
# (a shell snippet). Default dark.
dp_theme() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/diffpane/config" theme="$DIFFPANE_THEME" cmd="$DIFFPANE_THEME_CMD"
  if [ -z "$theme" ] && [ -f "$cfg" ]; then  # environment wins over the file
    local file
    file=$(unset DIFFPANE_THEME DIFFPANE_THEME_CMD; . "$cfg" >/dev/null 2>&1
      printf '%s\n%s' "$DIFFPANE_THEME" "$DIFFPANE_THEME_CMD")
    theme=${file%%$'\n'*}
    [ -n "$cmd" ] || cmd=${file#*$'\n'}
  fi
  [ -z "$theme" ] && [ -n "$cmd" ] && theme=$(sh -c "$cmd" 2>/dev/null)
  [ "$theme" = light ] && echo light || echo dark
}

# Usable width of the viewer's list column, one column kept free before the
# preview border. Inside fzf the preview's real left edge (it can be dragged);
# before fzf starts, the 70% preview split.
dp_list_width() {
  if [ -n "$FZF_PREVIEW_LEFT" ]; then echo $((FZF_PREVIEW_LEFT - 3)); return; fi
  local cols=${FZF_COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
  echo $((cols - cols * 70 / 100 - 1))
}
