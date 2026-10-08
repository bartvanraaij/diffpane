#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
strip() { sed $'s/\033\\[[0-9;]*m//g'; }

echo "preview"
r=$(mkrepo prev)
printf 'modified-line\n' >> "$r/a.txt"
printf 'brand-new-line\n' > "$r/fresh.txt"
rm "$r/c.txt"
out=$(cd "$r" && "$CDIFF_HOME/lib/preview" a.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q modified-line && echo yes)" "modified file shows added line"
out=$(cd "$r" && "$CDIFF_HOME/lib/preview" fresh.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q brand-new-line && echo yes)" "untracked file shows content"
out=$(cd "$r" && "$CDIFF_HOME/lib/preview" c.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q '│c' && echo yes)" "deleted file shows its removed line"
r2=$(mkrepo prevempty --empty)
printf 'first-ever\n' > "$r2/x.txt"
out=$(cd "$r2" && "$CDIFF_HOME/lib/preview" x.txt | strip)
assert_eq "yes" "$(echo "$out" | grep -q first-ever && echo yes)" "repo without commits shows new file"
assert_eq "" "$(cd "$r" && "$CDIFF_HOME/lib/preview" '')" "empty path prints nothing"
assert_eq "no" "$(cd "$r" && "$CDIFF_HOME/lib/preview" a.txt | head -1 | strip | grep -q '^$' && echo yes || echo no)" "no blank first line"
assert_eq "0" "$(cd "$r" && "$CDIFF_HOME/lib/preview" a.txt | strip | grep -c 'a\.txt')" "no file header (the list shows the name)"

echo "theme"
cfg="$TMPROOT/cfg"; mkdir -p "$cfg/claude-diff"
theme_of() { XDG_CONFIG_HOME="$cfg" bash -c '. "$1/lib/common.sh"; cdiff_theme' _ "$CDIFF_HOME"; }
assert_eq "dark" "$(theme_of)" "no config: dark"
assert_eq "light" "$(CLAUDE_DIFF_THEME=light theme_of)" "CLAUDE_DIFF_THEME sets it"
assert_eq "light" "$(CLAUDE_DIFF_THEME_CMD='echo light' theme_of)" "CLAUDE_DIFF_THEME_CMD from the environment"
echo "CLAUDE_DIFF_THEME_CMD='echo light'" > "$cfg/claude-diff/config"
assert_eq "light" "$(theme_of)" "CLAUDE_DIFF_THEME_CMD from the config file"
echo "CLAUDE_DIFF_THEME_CMD='echo purple'" > "$cfg/claude-diff/config"
assert_eq "dark" "$(theme_of)" "anything but light means dark"
assert_eq "light" "$(CLAUDE_DIFF_THEME=light theme_of)" "CLAUDE_DIFF_THEME wins over the command"
rm "$cfg/claude-diff/config"
# added-line background: GitHub light #dafbe1, GitHub dark #2a6a3a (24-bit escapes)
out=$(cd "$r" && CLAUDE_DIFF_THEME=light "$CDIFF_HOME/lib/preview" a.txt)
assert_eq "yes" "$(echo "$out" | grep -q '48;2;218;251;225' && echo yes)" "light preview: light green added bg"
out=$(cd "$r" && CLAUDE_DIFF_THEME=dark "$CDIFF_HOME/lib/preview" a.txt)
assert_eq "yes" "$(echo "$out" | grep -q '48;2;42;106;58' && echo yes)" "dark preview: stronger green added bg"
printf '// note\n' > "$r/n.cs"
out=$(cd "$r" && CLAUDE_DIFF_THEME=dark "$CDIFF_HOME/lib/preview" n.cs)
assert_eq "0" "$(echo "$out" | grep -c 'warning')" "no warning whether or not the optional syntax theme is installed"
if bat --list-themes 2>/dev/null | grep -qx claude-diff; then
  assert_eq "yes" "$(echo "$out" | grep -q '38;2;180;176;154' && echo yes)" "dark preview: added comment keeps syntax, lighter comment color"
else
  echo "  skip lighter comment color: claude-diff syntax theme not installed (see README)"
fi

echo "header"
r=$(mkrepo head)
st=$(state "$r"); mkdir -p "$st"
: > "$st/view.list"
sha=$(git -C "$r" rev-parse --short HEAD)
hdr() { (cd "$r" && FZF_COLUMNS=100 "$CDIFF_HOME/lib/header") | strip; }  # list column: 30 wide
out=$(hdr)
assert_eq "head$(printf '%24s' '')○" "$(echo "$out" | sed -n 1p)" "empty state: repo and follow icon"
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
assert_eq "0" "$(echo "$out" | sed 's/[○●⏸·]/x/g' | awk 'length > 29' | wc -l | tr -d ' ')" "nothing wider than the list column"
printf 'a.txt\tx\n' > "$st/view.list"
echo on > "$st/follow"
assert_eq "head                        ●
1 turn         1 file changed" "$(hdr)" "singular, follow on"
printf 'a.txt\tx\n\t────\nb.txt\ty\n' > "$st/view.list"
echo paused > "$st/follow"
assert_eq "head                        ⏸
2 turns       2 files changed" "$(hdr)" "divider rows are not files, turns = dividers + 1"
assert_eq "2 turns                  2 files changed" "$( (cd "$r" && FZF_COLUMNS=100 FZF_PREVIEW_LEFT=43 "$CDIFF_HOME/lib/header") | strip | sed -n 2p)" "preview dragged: right-aligned to the real list width"

finish
