# diffpane

A live list and inline diff of every file Claude Code changes, for a pane next
to your Claude session.

Claude edits files through Edit and Write, but just as often through Bash:
`sed`, `awk`, `python`, `mv`, `rm`. diffpane doesn't care how. Hooks snapshot
the work tree around every tool call (with a private git index, so your staging
area is untouched) and record whatever changed.

```
my-app                      ●
2 turns       4 files changed
─────────────────────────────│ diff of the selected file,
M   +3     Company.cs  src/… │ rendered by delta
M +120     a.txt ●           │
──────────────────────────── │
A  +40     PageSize.cs ●     │
D      −1  c.txt ●           │
```

- Newest change on top, grouped by turn, accumulating until the next commit.
- `●` marks files changed since you last looked at them.
- **Follow mode** (`●` in the header) keeps the newest change selected. Moving
  through the list pauses it (`⏸`); the next turn that changes files resumes it.
  `f` switches it on/off (`○`).
- Stays out of the way: the hooks never print, block or fail Claude, and do
  nothing outside a git work tree.

## Requirements

- macOS or Linux with `bash`, `git`, `jq`, `curl`
- [fzf](https://github.com/junegunn/fzf) (tested with 0.74)
- [delta](https://github.com/dandavison/delta) (tested with 0.20)
- tmux (optional; see the bindings below)
- Claude Code with plugin support

## Install

1. Add the plugin (hooks):

   ```sh
   claude plugin marketplace add bartvanraaij/diffpane
   claude plugin install diffpane@diffpane
   ```

   Restart running Claude sessions; hooks load at startup.

2. Put the viewer on your `PATH`. The marketplace checkout is a stable place to
   link it from:

   ```sh
   ln -s ~/.claude/plugins/marketplaces/diffpane/bin/diffpane ~/.local/bin/diffpane
   ```

   Or clone the repo anywhere and link `bin/diffpane` from there.

## Use

Run `diffpane` in a pane inside the repo Claude works in. It shows everything
Claude changed since the last commit, even if it was started late.

Two views, switched with `v`:

- **Turns** `↩` (default): each turn's changes under a divider, newest first.
  A file changed in three turns is listed three times, each with only that
  turn's change.
- **Files** `≡`: each file once, with its whole diff since the last commit.

| Key                | Action                                       |
|--------------------|----------------------------------------------|
| `j` / `k`, click   | select file                                  |
| `ctrl-d` / `ctrl-u`, wheel | scroll the diff                      |
| `f`                | follow on/off                                |
| `w`                | wrap long lines in the diff on/off           |
| `v`                | switch view: Turns / Files                   |
| `r`                | reload                                       |
| `q`                | quit                                         |

Drag the border between list and diff to resize; the list realigns within a
few seconds.

### tmux

diffpane doesn't place itself; put it wherever you like. With tmux, these
bindings in `tmux.conf` open it next to Claude. The toggle finds the viewer by
its pane title, `Diffpane`.

```tmux
# prefix g: open/close diffpane left of the current pane
bind g run-shell 'p=$(tmux list-panes -t "#{pane_id}" -F "##{pane_id} ##{pane_title}" | awk "\$2 == \"Diffpane\" { print \$1; exit }"); \
  if [ -n "$p" ]; then tmux kill-pane -t "$p"; \
  else tmux split-window -hbd -l 67% -t "#{pane_id}" -c "#{pane_current_path}" "~/.local/bin/diffpane || sleep 3"; fi'
# prefix C: new window, diffpane left, claude right
bind C new-window -c "#{pane_current_path}" -n "#{b:pane_current_path}" "~/.local/bin/diffpane || sleep 3" \; \
  split-window -h -l 33% -c "#{pane_current_path}" claude
```

## Configuration

Optional, in `~/.config/diffpane/config` (a shell snippet) or the environment:

| Variable             | Meaning                                                        |
|----------------------|----------------------------------------------------------------|
| `DIFFPANE_THEME`     | `light` or `dark` (default `dark`)                             |
| `DIFFPANE_THEME_CMD` | command printing `light` or `dark`, checked on every redraw; the viewer restyles itself when it changes |

fzf and delta can't detect the terminal background inside the viewer, hence
the setting. Example that follows macOS appearance:

```sh
DIFFPANE_THEME_CMD='defaults read -g AppleInterfaceStyle >/dev/null 2>&1 && echo dark || echo light'
```

### Syntax theme (optional)

In dark mode, changed lines get strong backgrounds that make the default
theme's comments hard to read. `themes/diffpane.tmTheme` is Monokai Extended
with lighter comments. delta only finds it through bat's theme cache:

```sh
mkdir -p "$(bat --config-dir)/themes"
ln -s ~/.claude/plugins/marketplaces/diffpane/themes/diffpane.tmTheme "$(bat --config-dir)/themes/"
bat cache --build
```

Without it, delta silently uses its default theme.

## How it works

See [DESIGN.md](DESIGN.md). In short: `hooks/record` snapshots the work tree
into a private git index before and after each tool call, diffs the two trees,
and appends changed paths to `.git/diffpane/touched`. The viewer is fzf with a
delta preview, refreshed over fzf's `--listen` socket when the hooks record
something, and every few seconds to catch commits.

Each snapshot costs a few git processes, around 100 ms per tool call on macOS.
Large untracked files that aren't gitignored are hashed on every snapshot.

## Development

```sh
tests/run.sh            # unit tests
tests/smoke_viewer.sh   # viewer in a private tmux server
tests/smoke_tmux.sh     # the README's tmux bindings
tests/bench.sh          # hook latency
```

To work on a local checkout, add it as the marketplace instead
(`claude plugin marketplace add ~/path/to/diffpane`). Claude Code then reads the
hooks straight from that folder; edits apply at the next session start or after
`/reload-plugins`. Viewer edits (`bin/`, `lib/`) apply when you restart the
viewer.

## License

MIT
