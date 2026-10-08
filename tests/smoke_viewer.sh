#!/usr/bin/env bash
# Smoke test: viewer starts, shows header, picks up a hook-driven change live.
. "$(dirname "$0")/helpers.sh"
T="tmux -L crtest -f /dev/null"
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
# Fake editor: records the argument it was opened with.
printf '#!/bin/sh\nprintf "%%s" "$1" > "%s/opened"\n' "$TMPROOT" > "$TMPROOT/ed"
chmod +x "$TMPROOT/ed"
# Own config whose theme command reads a file the test can switch.
cfg="$TMPROOT/cfg"; mkdir -p "$cfg/claude-diff"
echo dark > "$TMPROOT/mode"
echo "CLAUDE_DIFF_THEME_CMD='cat $TMPROOT/mode'" > "$cfg/claude-diff/config"
$T new-session -d -s crtest -x 160 -y 40 -c "$r" "XDG_CONFIG_HOME=$cfg EDITOR=$TMPROOT/ed $CDIFF_HOME/bin/claude-diff"
wait_for "No Claude changes since" && assert_eq ok ok "header shows empty state" || assert_eq ok fail "header shows empty state"
assert_eq "Claude Diff" "$($T display -p -t crtest '#{pane_title}')" "pane title"

hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "live-change\n" >> a.txt'
wait_for "a.txt" && assert_eq ok ok "hook ping shows a.txt" || assert_eq ok fail "hook ping shows a.txt"
wait_for "live-change" && assert_eq ok ok "preview shows the diff" || assert_eq ok fail "preview shows the diff"
assert_eq "0" "$($T capture-pane -p -t crtest | grep -c '▌')" "no pointer/gutter rail"

# Installed as a symlink on PATH: must still find its lib/.
ln -s "$CDIFF_HOME/bin/claude-diff" "$TMPROOT/claude-diff-link"
out=$(cd "$r" && "$TMPROOT/claude-diff-link" 2>&1; echo "rc=$?")
assert_eq "yes" "$(echo "$out" | grep -q 'already running' && echo yes)" "second viewer refuses to start"

hook "$r" UserPromptSubmit >/dev/null   # second turn: a divider between posts and a.txt
tool "$r" t2 sh -c 'seq 60 > "posts.\$id.txt"'
wait_for 'posts.\$id.txt' || true
$T send-keys -t crtest Enter
for i in $(seq 30); do [ -s "$TMPROOT/opened" ] && break; sleep 0.1; done
assert_eq 'posts.$id.txt' "$(cat "$TMPROOT/opened" 2>/dev/null)" "enter opens a file with \$ in its name"

# fzf's selected-row background: 236 in the dark scheme, #eaeef2 in light.
sel() { $T capture-pane -p -e -t crtest | grep -c -- "$1"; }
assert_eq "yes" "$([ "$(sel '48;5;236')" -gt 0 ] && echo yes)" "dark theme: dark selected row"
echo light > "$TMPROOT/mode"
for i in $(seq 60); do [ "$(sel '48;2;234;238;242')" -gt 0 ] && break; sleep 0.1; done
assert_eq "yes" "$([ "$(sel '48;2;234;238;242')" -gt 0 ] && [ "$(sel '48;5;236')" -eq 0 ] && echo yes)" "theme switch restyles the list live"
wait_for '1/6[0-9]' || true  # preview scroll indicator rendered
assert_eq "0" "$($T capture-pane -p -e -t crtest | grep -c '38;5;101')" "light: no olive scroll indicator"
wait_for 'posts.\$id.txt' && assert_eq ok ok "list survives the restart" || assert_eq ok fail "list survives the restart"
# Paused follow: the file the user moved to stays selected across a restart.
$T send-keys -t crtest j
wait_for '⏸' || true
focused() { $T capture-pane -p -e -t crtest | grep -- "$1" | grep -o 'a\.txt\|posts\.\$id\.txt' | head -1; }
echo dark > "$TMPROOT/mode"
# The new fzf focuses row 1 first, then the refocus lands: wait for the end state.
for i in $(seq 60); do [ "$(focused '48;5;236')" = a.txt ] && break; sleep 0.1; done
assert_eq "a.txt" "$(focused '48;5;236')" "paused follow keeps the selected file across a theme switch"

# j above went posts -> divider -> a.txt; k goes back over the divider.
$T send-keys -t crtest k; sleep 0.5
assert_eq 'posts.$id.txt' "$(focused '48;5;236')" "divider is skipped going up"

git -C "$r" add -A && git -C "$r" commit -qm done
wait_for "No Claude changes since" && assert_eq ok ok "ticker picks up user commit" || assert_eq ok fail "ticker picks up user commit"

finish
