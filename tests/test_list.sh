#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"

echo "list: order, stats, tags"
r=$(mkrepo list)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "a2\n" >> a.txt'
hook "$r" Stop >/dev/null
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t2 rm c.txt
tool "$r" t3 sh -c 'printf "1\n2\n3\n" > "new file.txt"'
tool "$r" t4 sh -c 'printf "b2\n" >> b.txt'
assert_eq $'b.txt\nnew file.txt\nc.txt\na.txt' "$(rows "$r")" "newest first"
assert_eq $'M +1     b.txt ●\nA +3     new file.txt ●\nD    −1  c.txt ●\n─────────────────────────────\nM +1     a.txt ●' \
  "$(display "$r")" "display: turns split by a divider, status, stats (zeros blank), name, unseen mark"
assert_eq "1" "$(cd "$r" && "$DP_HOME/lib/list" | awk -F'\t' '$1 == ""' | wc -l | tr -d ' ')" "divider rows have an empty path"

echo "list: reverted files drop, re-edits move to top"
tool "$r" t5 git checkout -- b.txt
assert_eq $'new file.txt\nc.txt\na.txt' "$(rows "$r")" "reverted b.txt is gone"
tool "$r" t6 sh -c 'printf "a3\n" >> a.txt'
assert_eq "a.txt" "$(rows "$r" | head -1)" "re-edited a.txt moves to top"
tool "$r" t7 sh -c 'printf "x\n" > tmp.txt && rm tmp.txt'
assert_eq "" "$(rows "$r" | grep -x tmp.txt)" "file created and deleted is not listed"

echo "list: seen marker"
echo files > "$(state "$r")/view"
total=$(wc -l < "$(state "$r")/touched" | tr -d ' ')
printf '%s\t%s\n' "$total" a.txt >> "$(state "$r")/seen"
assert_eq "M +2     a.txt" "$(display "$r" | grep a.txt)" "seen file has no marker"

rm "$(state "$r")/view"

echo "list: commit outside Claude resets"
git -C "$r" add -A && git -C "$r" commit -qm user
assert_eq "" "$(rows "$r")" "list empty after user commit"

echo "list: repo without commits"
r=$(mkrepo empty --empty)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "x\n" > x.txt'
assert_eq "A +1  x.txt ●" "$(display "$r")" "new file listed in fresh repo; all-zero column dropped"

echo "list: paths are literal, not pathspecs"
r=$(mkrepo glob)
mkdir -p "$r/app/[id]" "$r/app/i"
printf 'x\n' > "$r/app/[id]/page.txt"; printf 'x\n' > "$r/app/i/page.txt"
git -C "$r" add -A && git -C "$r" commit -qm routes
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "y\n" >> "app/[id]/page.txt" && printf "y\n" >> app/i/page.txt'
assert_eq "M +1  page.txt ●  app/[id]" "$(display "$r" | grep -F '[id]')" "bracket path gets its own stats only"

echo "list: columns align, name before directory"
r=$(mkrepo align)
mkdir -p "$r/src/deep"; printf 'x\n' > "$r/src/deep/m.cs"
git -C "$r" add -A && git -C "$r" commit -qm src
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'seq 12 >> a.txt && printf "y\n" > src/deep/m.cs'
assert_eq $'M  +1 −1  m.cs ●  src/deep\nM +12     a.txt ●' "$(display "$r")" "stats right-aligned per column"

echo "list: divider follows the real list width"
r=$(mkrepo wide)
hook "$r" UserPromptSubmit >/dev/null; tool "$r" t1 sh -c 'printf "x\n" >> a.txt'
hook "$r" UserPromptSubmit >/dev/null; tool "$r" t2 sh -c 'printf "x\n" >> b.txt'
assert_eq "$(printf '─%.0s' $(seq 40))" "$(cd "$r" && FZF_COLUMNS=100 FZF_PREVIEW_LEFT=43 "$DP_HOME/lib/list" | awk -F'\t' '$1 == ""' | cut -f2 | sed $'s/\033\\[[0-9;]*m//g')" "preview dragged to column 43: 40-wide divider"

echo "list: Turns view, one row per file per turn"
r=$(mkrepo turnview)
st=$(state "$r")
turns() { (cd "$r" && "$DP_HOME/lib/list") | awk -F'\t' '$1 != "" { print $3 }' | tr '\n' ' '; }
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "1\n" >> a.txt'
hook "$r" Stop >/dev/null
printf 'user\n' >> "$r/a.txt"   # the user, between turns
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t2 sh -c 'printf "2\n" >> a.txt && printf "x\n" >> b.txt'
hook "$r" Stop >/dev/null
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t3 sh -c 'printf "3\n" >> a.txt'
assert_eq $'a.txt\nb.txt\na.txt\na.txt' "$(rows "$r")" "newest turn first, a file once per turn that changed it"
assert_eq "3 2 2 1 " "$(turns)" "third field is the turn"
assert_eq $'M +1  a.txt ●\n─────────────────────────────\nM +1  b.txt ●\nM +1  a.txt ●\n─────────────────────────────\nM +1  a.txt ●' \
  "$(display "$r")" "stats are the turn's own; the user's edit between turns is in none"
tool "$r" t4 sh -c 'printf "y\n" >> c.txt'
tool "$r" t5 git checkout -- c.txt
assert_eq "" "$(rows "$r" | grep -x c.txt)" "changed and changed back within the turn: no row"
hook "$r" Stop >/dev/null
assert_eq "yes" "$([ -n "$(ls "$st/turnstat")" ] && echo yes)" "finished turns' stats are cached"

echo "list: turns without a start snapshot are left out"
awk -F'\t' '!($1 == 1 && $2 == "start")' "$st/turns" > "$st/turns.new" && mv "$st/turns.new" "$st/turns"
assert_eq "3 2 2 " "$(turns)" "turn 1 has no start snapshot: hidden"

echo "list: nothing to show, with seen entries: no hang"
r=$(mkrepo seenonly)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "x\n" >> a.txt'
printf '1\ta.txt\n' >> "$(state "$r")/seen"
: > "$(state "$r")/turns"   # a turn from before the turn log: hidden
# Watchdog kills the whole process group, so a looping awk can't hang the suite.
out=$(cd "$r" && perl -e 'setpgrp; $SIG{ALRM} = sub { kill 9, -$$ }; alarm 5; system @ARGV; exit($? >> 8)' "$DP_HOME/lib/list" >/dev/null; echo "rc=$?")
assert_eq "rc=0" "$out" "empty Turns view returns at once"

echo "list: work after Stop in the same turn counts"
r=$(mkrepo resumed)
hook "$r" UserPromptSubmit >/dev/null
hook "$r" Stop >/dev/null                 # e.g. a Stop hook sends Claude back to work
tool "$r" t1 sh -c 'printf "x\n" >> a.txt'
assert_eq "M +1  a.txt ●" "$(display "$r")" "change after an early Stop is shown"
hook "$r" Stop >/dev/null
assert_eq "M +1  a.txt ●" "$(display "$r")" "and still after the real Stop"

echo "list: interrupted turn (no Stop) ends where the next one starts"
r=$(mkrepo interrupted)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "1\n" >> a.txt'
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t2 sh -c 'printf "2\n2\n" >> a.txt'
assert_eq $'M +2  a.txt ●\n─────────────────────────────\nM +1  a.txt ●' "$(display "$r")" "turn 1 does not include turn 2's lines"

echo "list: Files view"
r=$(mkrepo files)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "1\n" >> a.txt'
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t2 sh -c 'printf "2\n" >> a.txt && printf "x\n" >> b.txt'
echo files > "$(state "$r")/view"
assert_eq $'b.txt\na.txt' "$(rows "$r")" "one row per file, newest change first"
assert_eq $'M +1  b.txt ●\nM +2  a.txt ●' "$(display "$r")" "no dividers, stats against HEAD"
assert_eq "0" "$(cd "$r" && "$DP_HOME/lib/list" | awk -F'\t' '$3 != ""' | wc -l | tr -d ' ')" "third field empty"

echo "list: fast with many files"
r=$(mkrepo many)
for i in $(seq 40); do printf 'x\n' > "$r/f$i.txt"; done
git -C "$r" add -A && git -C "$r" commit -qm many
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'for i in $(seq 40); do printf "y\n" >> f$i.txt; done'
TIMEFORMAT='%R'
secs=$( { time (cd "$r" && "$DP_HOME/lib/list" >/dev/null); } 2>&1 )
assert_eq "40" "$(rows "$r" | wc -l | tr -d ' ')" "40 rows listed"
assert_eq "yes" "$(awk -v s="$secs" 'BEGIN { print (s < 0.3) ? "yes" : "no" }')" "40 files listed in < 0.3s (took ${secs}s)"

finish
