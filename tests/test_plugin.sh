#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"

echo "plugin manifest, marketplace and hooks"
m="$DP_HOME/.claude-plugin"
assert_eq "diffpane" "$(jq -r .name "$m/plugin.json")" "plugin name"
assert_eq "diffpane" "$(jq -r '.plugins[0].name' "$m/marketplace.json")" "marketplace lists the plugin"
assert_eq "./" "$(jq -r '.plugins[0].source' "$m/marketplace.json")" "marketplace points at this repo"
h="$DP_HOME/hooks/hooks.json"
assert_eq "PostToolUse PostToolUseFailure PreToolUse Stop UserPromptSubmit" \
  "$(jq -r '.hooks | keys | join(" ")' "$h")" "all five events hooked"
cmds=$(jq -r '[.hooks[][].hooks[].command] | unique | .[]' "$h")
assert_eq '"${CLAUDE_PLUGIN_ROOT}/hooks/record"' "$cmds" "every event runs hooks/record"
assert_eq "yes" "$([ -x "$DP_HOME/hooks/record" ] && echo yes)" "record is executable"

finish
