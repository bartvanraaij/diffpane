#!/usr/bin/env bash
# Average Pre+Post hook time in a real repo. Usage: bench.sh <repo>
. "$(dirname "$0")/helpers.sh"
repo="${1:?usage: bench.sh <repo>}"
hook "$repo" PreToolUse Bash warm >/dev/null; hook "$repo" PostToolUse Bash warm >/dev/null
TIMEFORMAT='%R'
total=$( { time (for i in 1 2 3 4 5 6 7 8 9 10; do
  hook "$repo" PreToolUse Bash "b$i" >/dev/null
  hook "$repo" PostToolUse Bash "b$i" >/dev/null
done) ; } 2>&1 )
echo "10 Pre+Post pairs: ${total}s total (target < 0.5s, i.e. < 50ms per pair)"
