# Shared helpers for claude-review. Sourced, not executed. Bash 3.2 compatible.

CR_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CR_LIB="$CR_HOME/lib"
export CR_HOME CR_LIB

# cr_init <dir>: resolve repo root and state dir. Returns 1 outside a git work tree.
cr_init() {
  local dir="${1:-$PWD}" out gitdir
  # One git spawn (~7ms each) for root, git dir and HEAD; a repo without commits fails on HEAD.
  out=$(git -C "$dir" rev-parse --show-toplevel --absolute-git-dir HEAD 2>/dev/null) ||
    out=$(git -C "$dir" rev-parse --show-toplevel --absolute-git-dir 2>/dev/null) || return 1
  CR_HEAD=""
  { read -r CR_ROOT; read -r gitdir; read -r CR_HEAD; } <<EOF
$out
EOF
  CR_HEAD=${CR_HEAD:-none}
  CR_STATE="$gitdir/claude-review"
  CR_REAL_INDEX="$gitdir/index"
  mkdir -p "$CR_STATE/pre" || return 1
  export CR_ROOT CR_STATE CR_REAL_INDEX CR_HEAD
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
# Uses the HEAD that cr_init resolved.
cr_sync_head() {
  local head="$CR_HEAD"
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

# Viewer socket path. Kept short: macOS caps unix socket paths at 104 bytes,
# which a deep repo path under .git would exceed.
# Hot path (every hook): no mkdir, cheap cksum. The viewer creates the dir.
cr_sock() {
  echo "/tmp/claude-review-$UID/$(printf '%s' "$CR_STATE" | cksum | cut -d' ' -f1).sock"
}

# Ask a running viewer to refresh. Never blocks. $CR_LIB and {1} expand inside fzf.
cr_ping() {
  local sock
  sock=$(cr_sock)
  [ -S "$sock" ] || return 0
  ( curl -s --max-time 1 --unix-socket "$sock" http://localhost \
      -d 'transform($CR_LIB/on-change {1})' >/dev/null 2>&1 & )
}
