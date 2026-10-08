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
assert_eq "$RELOAD+pos(2)" "$(run on-change b.txt)" "first change with follow on jumps to newest file (below its turn title)"
assert_eq "" "$(run on-change b.txt)" "unchanged list prints nothing"
assert_eq "$RELOAD+pos(2)" "$(run on-change b.txt --force)" "--force reloads anyway"
echo off > "$st/follow"
tool "$r" t3 sh -c 'printf "x\n" >> c.txt'
assert_eq "$RELOAD+pos(4)" "$(run on-change a.txt)" "follow off keeps focus on a.txt (now row 4)"
tool "$r" t4 git checkout -- a.txt
assert_eq "$RELOAD+pos(2)" "$(run on-change a.txt)" "focused file gone falls back to newest"

echo "on-focus"
echo on > "$st/follow"
run on-change c.txt --force >/dev/null
assert_eq "down" "$(run on-focus 0 '')" "turn title at the top: skip down"
assert_eq "on" "$(cat "$st/follow")" "focus on a turn title keeps follow on"
out=$(run on-focus 1 c.txt)
assert_eq "on" "$(cat "$st/follow")" "focus on newest file keeps follow on"
assert_eq "$RELOAD+pos(2)" "$out" "focusing unseen newest file marks it seen and reloads"
assert_eq "" "$(run on-focus 1 c.txt)" "already seen row: no actions"
out=$(run on-focus 2 b.txt)
assert_eq "paused" "$(cat "$st/follow")" "moving off newest file pauses follow"
assert_eq "$HEADER+$RELOAD+pos(3)" "$out" "pause updates header, marks b.txt seen keeping focus"
assert_eq "" "$(run on-focus '' '')" "empty list: no actions"

echo "on-focus: turn titles between groups are skipped in the direction of travel"
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t5 sh -c 'printf "x\n" >> d.txt'
run on-change d.txt --force >/dev/null   # rows: title, d.txt, title, c.txt, b.txt
run on-focus 1 d.txt >/dev/null
assert_eq "down" "$(run on-focus 2 '')" "moving down onto a title: down"
run on-focus 3 c.txt >/dev/null
assert_eq "up" "$(run on-focus 2 '')" "moving up onto a title: up"

echo "toggle-follow"
assert_eq "pos(2)+$HEADER" "$(run toggle-follow)" "paused -> on jumps to newest"
assert_eq "on" "$(cat "$st/follow")" "state on"
assert_eq "$HEADER" "$(run toggle-follow)" "on -> off"
assert_eq "off" "$(cat "$st/follow")" "state off"
assert_eq "pos(2)+$HEADER" "$(run toggle-follow)" "off -> on"

finish
