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

# rows <repo>: list paths (field 1) in display order, turn title rows left out.
rows() { (cd "$1" && "$CR_HOME/lib/list") | cut -f1 | grep -v '^$'; }

# display <repo>: list display column without ANSI codes and the 1-space left padding.
display() { (cd "$1" && "$CR_HOME/lib/list") | cut -f2 | sed $'s/\033\\[[0-9;]*m//g' | sed 's/^ //'; }

finish() {
  if [ "$FAILS" -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
}
