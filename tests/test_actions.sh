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
assert_eq "$RELOAD" "$(run on-change b.txt --force)" "--force reloads anyway; same rows: cursor stays"
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
assert_eq "$RELOAD" "$out" "focusing unseen top row marks it seen, reloads without moving"
assert_eq "" "$(run on-focus 0 c.txt)" "already seen row: no actions"
out=$(run on-focus 1 b.txt)
assert_eq "paused" "$(cat "$st/follow")" "moving off top row pauses follow"
assert_eq "$HEADER+$RELOAD" "$out" "pause updates header, marks b.txt seen without moving"
assert_eq "" "$(run on-focus '' '')" "empty list: no actions"

echo "on-focus: dividers between turns are skipped in the direction of travel"
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t5 sh -c 'printf "x\n" >> d.txt'
run on-change d.txt --force >/dev/null   # rows: d.txt, divider, c.txt, b.txt
run on-focus 0 d.txt >/dev/null
assert_eq "down" "$(run on-focus 1 '')" "moving down onto a divider: down"
run on-focus 2 c.txt >/dev/null
assert_eq "up" "$(run on-focus 1 '')" "moving up onto a divider: up"

echo "on-change: list width change redraws list and header"
FZF_PREVIEW_LEFT=33 run on-change d.txt >/dev/null   # settle on a width
assert_eq "" "$(FZF_PREVIEW_LEFT=33 run on-change d.txt)" "same width, nothing changed"
assert_eq "$RELOAD+$HEADER" "$(FZF_PREVIEW_LEFT=43 run on-change d.txt)" "width changed: reload and redraw header"
assert_eq "" "$(FZF_PREVIEW_LEFT=43 run on-change d.txt)" "same width again: nothing"

echo "toggle-follow"
assert_eq "first+$HEADER" "$(run toggle-follow)" "paused -> on jumps to newest"
assert_eq "on" "$(cat "$st/follow")" "state on"
assert_eq "$HEADER" "$(run toggle-follow)" "on -> off"
assert_eq "off" "$(cat "$st/follow")" "state off"
assert_eq "first+$HEADER" "$(run toggle-follow)" "off -> on"

echo "follow: paused resumes when a new turn brings changes; off stays off"
r=$(mkrepo resume)
st=$(state "$r")
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "x\n" >> a.txt && printf "x\n" >> b.txt'
echo on > "$st/follow"
run on-change b.txt --force >/dev/null
run on-focus 1 a.txt >/dev/null
assert_eq "paused" "$(cat "$st/follow")" "navigation paused follow"
tool "$r" t2 sh -c 'printf "x\n" >> c.txt'
assert_eq "$RELOAD+pos(3)" "$(run on-change a.txt)" "more changes in the same turn: stay paused, keep focus"
assert_eq "paused" "$(cat "$st/follow")" "still paused"
hook "$r" UserPromptSubmit >/dev/null
assert_eq "" "$(run on-change a.txt)" "new turn without changes: nothing"
tool "$r" t3 sh -c 'printf "x\n" >> d.txt'
assert_eq "$RELOAD+first+$HEADER" "$(run on-change a.txt)" "new turn with changes: follow back on, jump to newest"
assert_eq "on" "$(cat "$st/follow")" "follow on again"
echo off > "$st/follow"
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t4 sh -c 'printf "x\n" >> e.txt'
assert_eq "off" "$(run on-change a.txt >/dev/null; cat "$st/follow")" "follow switched off with f stays off"

finish
