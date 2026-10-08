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
$T new-session -d -s crtest -x 160 -y 40 -c "$r" "$CR_HOME/claude-review"
wait_for "smoke · 0 files" && assert_eq ok ok "header shows empty state" || assert_eq ok fail "header shows empty state"

hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "live-change\n" >> a.txt'
wait_for "a.txt" && assert_eq ok ok "hook ping shows a.txt" || assert_eq ok fail "hook ping shows a.txt"
wait_for "live-change" && assert_eq ok ok "preview shows the diff" || assert_eq ok fail "preview shows the diff"

out=$(cd "$r" && "$CR_HOME/claude-review" 2>&1; echo "rc=$?")
assert_eq "yes" "$(echo "$out" | grep -q 'already running' && echo yes)" "second viewer refuses to start"

git -C "$r" add -A && git -C "$r" commit -qm done
wait_for "0 files" && assert_eq ok ok "ticker picks up user commit" || assert_eq ok fail "ticker picks up user commit"

finish
