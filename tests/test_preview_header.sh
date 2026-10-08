#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
strip() { sed $'s/\033\\[[0-9;]*m//g'; }

echo "preview"
r=$(mkrepo prev)
printf 'modified-line\n' >> "$r/a.txt"
printf 'brand-new-line\n' > "$r/fresh.txt"
rm "$r/c.txt"
out=$(cd "$r" && "$CR_HOME/lib/preview" a.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q modified-line && echo yes)" "modified file shows added line"
out=$(cd "$r" && "$CR_HOME/lib/preview" fresh.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q brand-new-line && echo yes)" "untracked file shows content"
out=$(cd "$r" && "$CR_HOME/lib/preview" c.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q c.txt && echo yes)" "deleted file shows a diff"
r2=$(mkrepo prevempty --empty)
printf 'first-ever\n' > "$r2/x.txt"
out=$(cd "$r2" && "$CR_HOME/lib/preview" x.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q first-ever && echo yes)" "repo without commits shows new file"
assert_eq "" "$(cd "$r" && "$CR_HOME/lib/preview" '')" "empty path prints nothing"

echo "header"
r=$(mkrepo head)
st=$(state "$r"); mkdir -p "$st"
: > "$st/view.list"
sha=$(git -C "$r" rev-parse --short HEAD)
assert_eq "head · 0 files
turn 0 · follow ○
No Claude changes since $sha init" "$(cd "$r" && "$CR_HOME/lib/header")" "empty state"
printf 'a.txt\tx\nb.txt\ty\n' > "$st/view.list"
echo on > "$st/follow"; echo 3 > "$st/turn"
assert_eq "head · 2 files
turn 3 · follow ●" "$(cd "$r" && "$CR_HOME/lib/header")" "with files, follow on"
echo paused > "$st/follow"
assert_eq "yes" "$(cd "$r" && "$CR_HOME/lib/header" | grep -q 'follow ⏸' && echo yes)" "paused symbol"

finish
