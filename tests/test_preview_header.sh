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
assert_eq "yes" "$(echo "$out" | grep -q '│c' && echo yes)" "deleted file shows its removed line"
r2=$(mkrepo prevempty --empty)
printf 'first-ever\n' > "$r2/x.txt"
out=$(cd "$r2" && "$CR_HOME/lib/preview" x.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q first-ever && echo yes)" "repo without commits shows new file"
assert_eq "" "$(cd "$r" && "$CR_HOME/lib/preview" '')" "empty path prints nothing"
assert_eq "no" "$(cd "$r" && "$CR_HOME/lib/preview" a.txt | head -1 | strip | grep -q '^$' && echo yes || echo no)" "no blank first line"
assert_eq "0" "$(cd "$r" && "$CR_HOME/lib/preview" a.txt | strip | grep -c 'a\.txt')" "no file header (the list shows the name)"

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
printf '// note\n' > "$r/n.cs"
out=$(cd "$r" && CR_THEME=dark "$CR_HOME/lib/preview" n.cs)
assert_eq "yes" "$(echo "$out" | grep -q '38;2;180;176;154' && echo yes)" "dark preview: added comment keeps syntax, lighter comment color"

echo "header"
r=$(mkrepo head)
st=$(state "$r"); mkdir -p "$st"
: > "$st/view.list"
sha=$(git -C "$r" rev-parse --short HEAD)
hdr() { (cd "$r" && FZF_COLUMNS=100 "$CR_HOME/lib/header") | strip; }  # list column: 30 wide
assert_eq "head                        ○
0 turns       0 files changed
No Claude changes since $sha init" "$(hdr)" "empty state, counts right-aligned"
printf 'a.txt\tx\n' > "$st/view.list"
echo on > "$st/follow"
assert_eq "head                        ●
1 turn         1 file changed" "$(hdr)" "singular, follow on"
printf 'a.txt\tx\n\t────\nb.txt\ty\n' > "$st/view.list"
echo paused > "$st/follow"
assert_eq "head                        ⏸
2 turns       2 files changed" "$(hdr)" "divider rows are not files, turns = dividers + 1"
assert_eq "2 turns                  2 files changed" "$( (cd "$r" && FZF_COLUMNS=100 FZF_PREVIEW_LEFT=43 "$CR_HOME/lib/header") | strip | sed -n 2p)" "preview dragged: right-aligned to the real list width"

finish
