#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
strip() { sed $'s/\033\\[[0-9;]*m//g'; }

echo "preview"
r=$(mkrepo prev)
printf 'modified-line\n' >> "$r/a.txt"
printf 'brand-new-line\n' > "$r/fresh.txt"
rm "$r/c.txt"
out=$(cd "$r" && "$DP_HOME/lib/preview" a.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q modified-line && echo yes)" "modified file shows added line"
out=$(cd "$r" && "$DP_HOME/lib/preview" fresh.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q brand-new-line && echo yes)" "untracked file shows content"
out=$(cd "$r" && "$DP_HOME/lib/preview" c.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q '│c' && echo yes)" "deleted file shows its removed line"
r2=$(mkrepo prevempty --empty)
printf 'first-ever\n' > "$r2/x.txt"
out=$(cd "$r2" && "$DP_HOME/lib/preview" x.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q first-ever && echo yes)" "repo without commits shows new file"
assert_eq "" "$(cd "$r" && "$DP_HOME/lib/preview" '')" "empty path prints nothing"
assert_eq "no" "$(cd "$r" && "$DP_HOME/lib/preview" a.txt | head -1 | strip | grep -q '^$' && echo yes || echo no)" "no blank first line"
assert_eq "0" "$(cd "$r" && "$DP_HOME/lib/preview" a.txt | strip | grep -c 'a\.txt')" "no file header (the list shows the name)"

echo "theme"
cfg="$TMPROOT/cfg"; mkdir -p "$cfg/diffpane"
theme_of() { XDG_CONFIG_HOME="$cfg" bash -c '. "$1/lib/common.sh"; dp_theme' _ "$DP_HOME"; }
assert_eq "dark" "$(theme_of)" "no config: dark"
assert_eq "light" "$(DIFFPANE_THEME=light theme_of)" "DIFFPANE_THEME sets it"
assert_eq "light" "$(DIFFPANE_THEME_CMD='echo light' theme_of)" "DIFFPANE_THEME_CMD from the environment"
echo "DIFFPANE_THEME_CMD='echo light'" > "$cfg/diffpane/config"
assert_eq "light" "$(theme_of)" "DIFFPANE_THEME_CMD from the config file"
echo "DIFFPANE_THEME_CMD='echo purple'" > "$cfg/diffpane/config"
assert_eq "dark" "$(theme_of)" "anything but light means dark"
assert_eq "light" "$(DIFFPANE_THEME=light theme_of)" "DIFFPANE_THEME wins over the command"
rm "$cfg/diffpane/config"
# added-line background: GitHub light #dafbe1, GitHub dark #2a6a3a (24-bit escapes)
out=$(cd "$r" && DIFFPANE_THEME=light "$DP_HOME/lib/preview" a.txt)
assert_eq "yes" "$(echo "$out" | grep -q '48;2;218;251;225' && echo yes)" "light preview: light green added bg"
out=$(cd "$r" && DIFFPANE_THEME=dark "$DP_HOME/lib/preview" a.txt)
assert_eq "yes" "$(echo "$out" | grep -q '48;2;42;106;58' && echo yes)" "dark preview: stronger green added bg"
printf '// note\n' > "$r/n.cs"
out=$(cd "$r" && DIFFPANE_THEME=dark "$DP_HOME/lib/preview" n.cs)
assert_eq "0" "$(echo "$out" | grep -c 'warning')" "no warning whether or not the optional syntax theme is installed"
if bat --list-themes 2>/dev/null | grep -qx diffpane; then
  assert_eq "yes" "$(echo "$out" | grep -q '38;2;180;176;154' && echo yes)" "dark preview: added comment keeps syntax, lighter comment color"
else
  echo "  skip lighter comment color: diffpane syntax theme not installed (see README)"
fi

echo "wrap"
W="$DP_HOME/lib/wrap"
E=$'\033'
assert_eq "short │line" "$(printf 'short │line\n' | "$W" 20)" "fits: unchanged"
assert_eq "$(printf '  1 │aaa bbb \n    │ccc')" "$(printf '  1 │aaa bbb ccc\n' | "$W" 13 | strip)" "breaks at a space, continuation indented past the gutter, digits blanked"
assert_eq "$(printf 'abcdef\nghij')" "$(printf 'abcdefghij\n' | "$W" 6 | strip)" "no gutter, no spaces: hard break at width"
out=$(printf '  1 │%s[42maaa bbb ccc%s[0m\n' "$E" "$E" | "$W" 13)
assert_eq "$(printf '%s[0m\n' "$E")" "$(printf '%s\n' "$out" | sed -n 1p | sed 's/.*bbb //')" "row ends with a reset"
assert_eq "yes" "$(printf '%s\n' "$out" | sed -n 2p | grep -q "│${E}\[0m${E}\[42mccc" && echo yes)" "colors carry over to the continuation"
printf '%s\n' "$(printf 'word %.0s' $(seq 1 20))" > "$r/long.txt"
echo on > "$(state "$r")/wrap"
rows=$(cd "$r" && FZF_PREVIEW_COLUMNS=30 "$DP_HOME/lib/preview" long.txt | wc -l | tr -d ' ')
assert_eq "yes" "$([ "$rows" -gt 1 ] && echo yes)" "preview wraps when wrap is on"
rm -f "$(state "$r")/wrap"
assert_eq "1" "$(cd "$r" && FZF_PREVIEW_COLUMNS=30 "$DP_HOME/lib/preview" long.txt | wc -l | tr -d ' ')" "and not when off"

echo "preview: a turn's own change"
r=$(mkrepo turnprev)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "first-turn\n" >> a.txt'
hook "$r" Stop >/dev/null
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t2 sh -c 'printf "second-turn\n" >> a.txt'
p() { (cd "$r" && "$DP_HOME/lib/preview" a.txt "$1") | strip | grep -o '[a-z]*-turn' | tr '\n' ' '; }
assert_eq "first-turn " "$(p 1)" "turn 1 shows only its line"
assert_eq "first-turn second-turn " "$(p 2)" "running turn: its line, with turn 1's as context"
assert_eq "yes" "$((cd "$r" && "$DP_HOME/lib/preview" a.txt 2) | strip | grep -q '^.*│second-turn' && (cd "$r" && "$DP_HOME/lib/preview" a.txt 2) | grep 'first-turn' | grep -qv '48;2' && echo yes)" "turn 1's line is context, not added"
assert_eq "first-turn second-turn " "$(p '')" "no turn: everything since HEAD"

echo "header"
r=$(mkrepo head)
st=$(state "$r"); mkdir -p "$st"
: > "$st/view.list"
sha=$(git -C "$r" rev-parse --short HEAD)
hdr() { (cd "$r" && FZF_COLUMNS=100 "$DP_HOME/lib/header") | strip; }  # list column: 30 wide
out=$(hdr)
assert_eq "head$(printf '%22s' '')↩ ○" "$(echo "$out" | sed -n 1p)" "empty state: repo, view and follow icons"
assert_eq "" "$(echo "$out" | sed -n 2p)" "empty state: no counts line, a spacer"
assert_eq "No Claude changes since" "$(echo "$out" | sed -n 3p)" "empty state: plain text"
assert_eq "yes" "$(echo "$out" | sed -n 4p | grep -q "^$sha · .* ago$" && echo yes)" "empty state: sha and relative time"
assert_eq "init" "$(echo "$out" | sed -n 5p)" "empty state: subject"
git -C "$r" commit -q --allow-empty -m "A rather long subject line that needs wrapping to fit" \
  -m "Body explains why. It is also long enough to wrap." -m "Co-Authored-By: Someone <x@y>"
out=$(hdr)
assert_eq "A rather long subject line
that needs wrapping to fit" "$(echo "$out" | sed -n 5,6p)" "long subject wraps at word boundaries"
assert_eq "yes" "$(echo "$out" | grep -q 'Body explains why' && echo yes)" "body shown"
assert_eq "0" "$(echo "$out" | grep -c 'Co-Authored-By')" "trailers left out"
assert_eq "0" "$(echo "$out" | sed 's/[○●⏸·↩≡]/x/g' | awk 'length > 29' | wc -l | tr -d ' ')" "nothing wider than the list column"
printf 'a.txt\tx\n' > "$st/view.list"
echo on > "$st/follow"
assert_eq "head                      ↩ ●
1 turn         1 file changed" "$(hdr)" "singular, Turns view, follow on"
printf 'a.txt\tx\n\t────\nb.txt\ty\n' > "$st/view.list"
echo paused > "$st/follow"
assert_eq "head                      ↩ ⏸
2 turns       2 files changed" "$(hdr)" "divider rows are not files, turns = dividers + 1"
printf 'a.txt\tx\t2\n\t────\t\na.txt\ty\t1\n' > "$st/view.list"
assert_eq "2 turns        1 file changed" "$(hdr | sed -n 2p)" "Turns view: a file in two turns counts once"
echo files > "$st/view"
printf '1\ta.txt\n2\ta.txt\n2\tb.txt\n3\tgone.txt\n' > "$st/touched"
printf 'a.txt\tx\t\nb.txt\ty\t\n' > "$st/view.list"
assert_eq "head                      ≡ ⏸
2 turns       2 files changed" "$(hdr)" "Files view: ≡, turns that changed a listed file"
rm "$st/view" "$st/touched"
printf 'a.txt\tx\n\t────\nb.txt\ty\n' > "$st/view.list"
assert_eq "2 turns                  2 files changed" "$( (cd "$r" && FZF_COLUMNS=100 FZF_PREVIEW_LEFT=43 "$DP_HOME/lib/header") | strip | sed -n 2p)" "preview dragged: right-aligned to the real list width"

finish
