#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"

echo "record: tool-agnostic capture"
r=$(mkrepo basic)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "a2\n" >> a.txt'
assert_eq "a.txt" "$(touched "$r")" "edit inside a tool call is recorded"
tool "$r" t2 sed -i '' 's/b/B/' b.txt
assert_eq $'a.txt\nb.txt' "$(touched "$r")" "sed edit is recorded"
tool "$r" t3 rm c.txt
tool "$r" t4 sh -c 'printf "n\n" > "new file.txt"'
assert_eq $'a.txt\nb.txt\nc.txt\nnew file.txt' "$(touched "$r")" "delete and new file with space are recorded"
assert_eq "1" "$(cat "$(state "$r")/turn")" "turn counter is 1"

echo "record: rename shows both paths"
r=$(mkrepo rename)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 git mv a.txt z.txt
assert_eq $'a.txt\nz.txt' "$(touched "$r" | sort)" "git mv records old and new path"

echo "record: user edits outside tool calls are ignored"
r=$(mkrepo user)
hook "$r" UserPromptSubmit >/dev/null
printf 'mine\n' >> "$r/a.txt"
tool "$r" t1 sh -c 'printf "x\n" >> b.txt'
assert_eq "b.txt" "$(touched "$r")" "user edit before tool call is not attributed"

echo "record: Stop catches late changes, not edits between turns"
r=$(mkrepo stop)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "x\n" >> a.txt'
printf 'late\n' >> "$r/b.txt"   # e.g. a background job finishing after its tool call returned
hook "$r" Stop >/dev/null
assert_eq $'a.txt\nb.txt' "$(touched "$r")" "Stop adds late change and does not repeat a.txt"
printf 'between turns\n' >> "$r/c.txt"
hook "$r" UserPromptSubmit >/dev/null
hook "$r" Stop >/dev/null
assert_eq $'a.txt\nb.txt' "$(touched "$r")" "edit between turns is not attributed"

echo "record: parallel and failed tool calls"
r=$(mkrepo parallel)
hook "$r" UserPromptSubmit >/dev/null
hook "$r" PreToolUse Bash p1 >/dev/null
hook "$r" PreToolUse Edit p2 >/dev/null
printf 'x\n' >> "$r/a.txt"
hook "$r" PostToolUse Bash p1 >/dev/null
printf 'y\n' >> "$r/b.txt"
hook "$r" PostToolUse Edit p2 >/dev/null
assert_eq $'a.txt\nb.txt' "$(touched "$r" | sort -u)" "interleaved parallel calls capture both files"
assert_eq "" "$(ls "$(state "$r")/pre")" "pre snapshots are cleaned up"
hook "$r" PreToolUse Bash f1 >/dev/null
printf 'z\n' >> "$r/c.txt"
hook "$r" PostToolUseFailure Bash f1 >/dev/null
assert_eq "c.txt" "$(touched "$r" | tail -1)" "PostToolUseFailure records changes"
hook "$r" PreToolUse Bash >/dev/null
printf 'w\n' >> "$r/a.txt"
hook "$r" PostToolUse Bash >/dev/null
assert_eq "a.txt" "$(touched "$r" | tail -1)" "missing tool_use_id still works"

echo "record: read-only tools skip snapshots"
hook "$r" PreToolUse Read r1 >/dev/null
assert_eq "no" "$([ -e "$(state "$r")/pre/r1" ] && echo yes || echo no)" "Read creates no pre snapshot"

echo "record: commit wipes the list"
r=$(mkrepo commit)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "x\n" >> a.txt'
tool "$r" t2 sh -c 'git add -A && git commit -qm wip'
assert_eq "" "$(touched "$r")" "commit inside a tool call empties the log"

echo "record: silent and safe"
r=$(mkrepo silent)
out=$(hook "$r" UserPromptSubmit; hook "$r" PreToolUse Bash s1; hook "$r" PostToolUse Bash s1; hook "$r" Stop)
assert_eq "" "$out" "record prints nothing"
mkdir -p "$TMPROOT/plain"
out=$(hook "$TMPROOT/plain" PostToolUse Bash x; echo "rc=$?")
assert_eq "rc=0" "$out" "outside a git repo: silent, exit 0"
out=$(echo 'not json' | "$CR_HOME/record"; echo "rc=$?")
assert_eq "rc=0" "$out" "garbage input: silent, exit 0"

echo "record: commit inside a tool call keeps other changes from that call"
r=$(mkrepo commitmix)
hook "$r" UserPromptSubmit >/dev/null
tool "$r" t1 sh -c 'printf "x\n" >> a.txt && printf "fmt\n" >> b.txt && git add a.txt && git commit -qm part'
assert_eq "b.txt" "$(rows "$r")" "uncommitted b.txt from the committing call is listed"

finish
