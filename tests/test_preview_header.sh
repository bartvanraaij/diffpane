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

echo "theme"
h="$TMPROOT/home"; mkdir -p "$h/.config/ghostty"
theme_of() { HOME="$h" bash -c '. "$1/lib/common.sh"; cr_theme' _ "$CR_HOME"; }
assert_eq "dark" "$(theme_of)" "no ghostty theme file: dark"
echo "theme = github-light-bart" > "$h/.config/ghostty/theme.ghostty"
assert_eq "light" "$(theme_of)" "light ghostty theme: light"
echo "theme = GitHub Dark Default" > "$h/.config/ghostty/theme.ghostty"
assert_eq "dark" "$(theme_of)" "dark ghostty theme: dark"
assert_eq "light" "$(CR_THEME=light theme_of)" "CR_THEME overrides"
# added-line background: GitHub light #dafbe1, GitHub dark #2a6a3a (24-bit escapes)
out=$(cd "$r" && CR_THEME=light "$CR_HOME/lib/preview" a.txt)
assert_eq "yes" "$(echo "$out" | grep -q '48;2;218;251;225' && echo yes)" "light preview: light green added bg"
out=$(cd "$r" && CR_THEME=dark "$CR_HOME/lib/preview" a.txt)
assert_eq "yes" "$(echo "$out" | grep -q '48;2;42;106;58' && echo yes)" "dark preview: stronger green added bg"

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
