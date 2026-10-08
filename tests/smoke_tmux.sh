#!/usr/bin/env bash
# Smoke test: toggle and layout against a private tmux server, never the default one.
. "$(dirname "$0")/helpers.sh"
T="tmux -L crtest -f /dev/null"
trap '$T kill-server 2>/dev/null; rm -rf "$TMPROOT"' EXIT

r=$(mkrepo tmux)
$T new-session -d -s crtest -x 200 -y 50 -c "$r"
p=$($T display -p -t crtest '#{pane_id}')
# toggle/layout call plain `tmux`; point it at the private server.
export TMUX="$($T display -p '#{socket_path}'),0,0"

"$CDIFF_HOME/bin/claude-diff" toggle "$p"
panes=$($T list-panes -t crtest -F '#{@claude-diff}' | sort | tr '\n' ' ')
assert_eq " 1 " "$panes" "toggle adds one flagged viewer pane"
w=$($T list-panes -t crtest -F '#{@claude-diff} #{pane_width}' | awk '$1 == 1 { print $2 }')
assert_eq "yes" "$([ "$w" -ge 125 ] && [ "$w" -le 140 ] && echo yes)" "viewer pane ~67% wide (got $w)"
assert_eq "$p" "$($T display -p -t crtest '#{pane_id}')" "focus stays on original pane"

"$CDIFF_HOME/bin/claude-diff" toggle "$p"
assert_eq "1" "$($T list-panes -t crtest | wc -l | tr -d ' ')" "second toggle removes viewer"

"$CDIFF_HOME/bin/claude-diff" layout "$r"
win=$($T display -p -t crtest '#{window_index}')
assert_eq "2" "$($T list-panes -t "crtest:$win" | wc -l | tr -d ' ')" "layout window has two panes"
left=$($T list-panes -t "crtest:$win" -F '#{pane_left} #{@claude-diff}' | sort -n | head -1 | cut -d' ' -f2)
assert_eq "1" "$left" "left pane is the viewer"
assert_eq "tmux" "$($T display -p -t "crtest:$win" '#{window_name}')" "window named after repo dir"

finish
