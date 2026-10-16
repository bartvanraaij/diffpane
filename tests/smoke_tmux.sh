#!/usr/bin/env bash
# Smoke test: the README's tmux bindings (toggle, layout), on private servers.
# Bindings only fire through an attached client, so an outer server's pane runs
# a client of the inner server; keys sent to that pane reach the bindings.
. "$(dirname "$0")/helpers.sh"
O="tmux -L crtest-outer -f /dev/null"
I="tmux -L crtest-inner -f /dev/null"
trap '$O kill-server 2>/dev/null; $I kill-server 2>/dev/null; rm -rf "$TMPROOT"' EXIT

wait_panes() { # <target> <count>: poll up to 5s for the pane count
  local i
  for i in $(seq 50); do
    [ "$($I list-panes -t "$1" 2>/dev/null | wc -l | tr -d ' ')" = "$2" ] && return 0
    sleep 0.1
  done
  return 1
}

left_title() { # <target>: title of the leftmost pane, once the viewer has set it (up to 5s)
  local i t
  for i in $(seq 50); do
    t=$($I list-panes -t "$1" -F '#{pane_left} #{pane_title}' | sort -n | head -1 | cut -d' ' -f2)
    [ "$t" = Diffpane ] && break
    sleep 0.1
  done
  echo "$t"
}

# The README's ```tmux block, pointed at this checkout; `cat` stands in for claude.
awk '/^```tmux$/ { on = 1; next } on && /^```$/ { exit } on' "$DP_HOME/README.md" |
  sed -e "s|~/.local/bin/diffpane|$DP_HOME/bin/diffpane|g" -e 's/ claude$/ cat/' > "$TMPROOT/bindings.conf"

r=$(mkrepo tmux)
$I new-session -d -s s -x 200 -y 50 -c "$r"
$I source-file "$TMPROOT/bindings.conf"
p=$($I display -p -t s '#{pane_id}')
$O new-session -d -s o -x 200 -y 52 "TMUX= $I attach -t s"
sleep 0.5

$O send-keys -t o C-b g
wait_panes s 2
assert_eq "Diffpane" "$(left_title s)" \
  "prefix g: viewer pane on the left, found by its title"
w=$($I list-panes -t s -F '#{pane_title} #{pane_width}' | awk '$1 == "Diffpane" { print $2 }')
assert_eq "yes" "$([ "$w" -ge 125 ] && [ "$w" -le 140 ] && echo yes)" "viewer pane ~67% wide (got $w)"
assert_eq "$p" "$($I display -p -t s '#{pane_id}')" "focus stays on the original pane"

$O send-keys -t o C-b g
wait_panes s 1
assert_eq "$p" "$($I list-panes -t s -F '#{pane_id}')" "prefix g again: viewer closed, original pane kept"

$O send-keys -t o C-b C
wait_panes s 2
assert_eq "tmux" "$($I display -p -t s '#{window_name}')" "prefix C: window named after the repo dir"
assert_eq "Diffpane" "$(left_title s)" \
  "prefix C: viewer left"
assert_eq "cat" "$($I list-panes -t s -F '#{pane_left} #{pane_current_command}' | sort -n | tail -1 | cut -d' ' -f2)" \
  "prefix C: claude right"

finish
