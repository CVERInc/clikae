#!/usr/bin/env bats
# tests/bats/fleet-hooks.bats — `clikae hooks <share|unshare|list>` and
# fleet_hooks_prelaunch (#141). Needs `jq`; skipped elsewhere.
# (NB: `[[ … ]]` assertions carry `|| false` — see tests/README.md.)
#
# 🔴 Half of these cases are NEGATIVE on purpose. The merge's whole value is
# what it does NOT do — append a command twice, drop a hook the user wrote,
# touch a solo tank, rewrite a file that is already correct — and each of
# those failures is invisible from the outside: everything still works, just
# twice, or not at all. That is exactly the shape #141 reported.

load '../helpers'

jq_only() { command -v jq >/dev/null 2>&1 || skip "clikae hooks needs jq"; }

_settings_of() { printf '%s/profiles/claude/%s/settings.json\n' "$CLIKAE_HOME" "$1"; }

# Every command a tank runs for <event>, newline-separated, in order.
_hook_cmds() {
  jq -r --arg e "$2" '[ (.hooks[$e] // [])[] | (.hooks // [])[] | .command ] | .[]' \
    "$(_settings_of "$1")"
}

# Stub `claude`: the launch tests must not depend on the engine being
# installed (fleet-mcp.bats learned this on both CI runners). The prelaunch
# hook is what is under test, not the engine.
_stub_claude() {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/claude"
  chmod +x "$bin/claude"; PATH="$bin:$PATH"; export PATH
}

@test "hooks share: promotes a command into the fleet store and lists it" {
  jq_only
  run clikae hooks list claude
  [[ "$output" == *"No fleet-wide hooks"* ]] || false
  run clikae hooks share Stop "/bin/echo snapshot" claude
  [ "$status" -eq 0 ]
  run jq -r '.Stop[0].hooks[0].command' "$CLIKAE_HOME/fleet-hooks/claude.json"
  [ "$output" = "/bin/echo snapshot" ]
  run clikae hooks list claude
  [[ "$output" == *"Stop"* ]] || false
  [[ "$output" == *"/bin/echo snapshot"* ]] || false
}

@test "hooks share: backfills an existing non-solo tank" {
  jq_only
  clikae init claude a
  clikae hooks share Stop "/bin/echo snapshot" claude
  run _hook_cmds a Stop
  [ "$output" = "/bin/echo snapshot" ]
}

@test "hooks share: a tank created LATER gets the hook at init, with no launch" {
  jq_only
  clikae hooks share SessionStart "/bin/echo hello" claude
  clikae init claude fresh
  run _hook_cmds fresh SessionStart
  [ "$output" = "/bin/echo hello" ]
}

@test "hooks share: sharing the same command twice never appends it twice" {
  jq_only
  clikae init claude a
  clikae hooks share Stop "/bin/echo snapshot" claude
  clikae hooks share Stop "/bin/echo snapshot" claude
  run _hook_cmds a Stop
  [ "$output" = "/bin/echo snapshot" ]           # one line, not two
  # …and the store did not grow either.
  run jq '[.Stop[]] | length' "$CLIKAE_HOME/fleet-hooks/claude.json"
  [ "$output" = "1" ]
}

@test "hooks prelaunch: a second launch with nothing new does not rewrite settings.json" {
  jq_only
  _stub_claude
  clikae init claude a
  clikae hooks share Stop "/bin/echo snapshot" claude
  clikae run claude a -- --version
  local target ino_before ino_after
  target="$(_settings_of a)"
  ino_before="$(ls -i "$target" | awk '{print $1}')"
  clikae run claude a -- --version
  ino_after="$(ls -i "$target" | awk '{print $1}')"
  # The inode, not the bytes: the merge used to be decided by comparing
  # reformatted JSON, which "changed" every time and replaced the file under
  # any live session on the same tank (fleet_mcp_prelaunch's 2026-08 bug).
  [ "$ino_before" = "$ino_after" ]
}

@test "hooks prelaunch: a tank that lost the hook gets it back at its next launch" {
  jq_only
  _stub_claude
  clikae init claude a
  clikae hooks share Stop "/bin/echo snapshot" claude
  # The #141 shape, reproduced: the tank's own settings no longer run it.
  local target; target="$(_settings_of a)"
  jq 'del(.hooks)' "$target" > "$target.x" && mv "$target.x" "$target"
  run _hook_cmds a Stop
  [ -z "$output" ]
  clikae run claude a -- --version
  run _hook_cmds a Stop
  [ "$output" = "/bin/echo snapshot" ]
}

@test "hooks share: a tank's OWN hook for the same event survives the merge" {
  jq_only
  clikae init claude a
  local target; target="$(_settings_of a)"
  jq '.hooks.Stop = [{hooks: [{type: "command", command: "/bin/echo mine"}]}]' \
    "$target" > "$target.x" && mv "$target.x" "$target"
  clikae hooks share Stop "/bin/echo snapshot" claude
  run _hook_cmds a Stop
  [[ "$output" == *"/bin/echo mine"* ]] || false        # kept
  [[ "$output" == *"/bin/echo snapshot"* ]] || false    # added
}

@test "hooks share: a command the tank ALREADY runs is not added a second time" {
  jq_only
  clikae init claude a
  local target; target="$(_settings_of a)"
  # The user added it by hand, before it was ever shared. A hook is identified
  # by what it RUNS, so this tank is already covered.
  jq '.hooks.Stop = [{hooks: [{type: "command", command: "/bin/echo snapshot"}]}]' \
    "$target" > "$target.x" && mv "$target.x" "$target"
  clikae hooks share Stop "/bin/echo snapshot" claude
  run _hook_cmds a Stop
  [ "$output" = "/bin/echo snapshot" ]
}

@test "hooks share: leaves the rest of settings.json alone and still valid JSON" {
  jq_only
  clikae init claude a
  local target; target="$(_settings_of a)"
  # The permissions template init just applied is the realistic neighbour.
  local before; before="$(jq -S '.permissions' "$target")"
  clikae hooks share Stop "/bin/echo snapshot" claude
  run jq -e . "$target"
  [ "$status" -eq 0 ]
  run jq -S '.permissions' "$target"
  [ "$output" = "$before" ]
}

@test "hooks share: never touches a SOLO tank" {
  jq_only
  clikae init claude a
  clikae init claude b
  clikae solo claude b
  clikae hooks share Stop "/bin/echo snapshot" claude
  run _hook_cmds a Stop
  [ "$output" = "/bin/echo snapshot" ]
  run _hook_cmds b Stop
  [ -z "$output" ]
}

@test "hooks unshare: removes from the store but leaves tanks that already got it" {
  jq_only
  clikae init claude a
  clikae hooks share Stop "/bin/echo snapshot" claude
  run clikae hooks unshare Stop "/bin/echo snapshot" claude
  [ "$status" -eq 0 ]
  run jq 'has("Stop")' "$CLIKAE_HOME/fleet-hooks/claude.json"
  [ "$output" = "false" ]
  run _hook_cmds a Stop
  [ "$output" = "/bin/echo snapshot" ]   # a's own copy is untouched
}

@test "hooks unshare: fails clearly when that command isn't shared" {
  jq_only
  clikae init claude a
  clikae hooks share Stop "/bin/echo snapshot" claude
  run clikae hooks unshare Stop "/bin/echo something-else" claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"shares no Stop hook"* ]] || false
}

@test "hooks share: refuses an event name that could not be one" {
  jq_only
  clikae init claude a
  run clikae hooks share "Stop; rm -rf /" "/bin/echo snapshot" claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a hook event name"* ]] || false
  [ ! -f "$CLIKAE_HOME/fleet-hooks/claude.json" ]
}

@test "hooks share: refuses an engine with no hooks layout" {
  jq_only
  run clikae hooks share Stop "/bin/echo snapshot" codex
  [ "$status" -ne 0 ]
  [[ "$output" == *"no known hook config layout"* ]] || false
}

@test "hooks share: fails clearly without jq" {
  local jq_path; jq_path="$(command -v jq || true)"
  [ -n "$jq_path" ] || skip "jq not installed (nothing to hide)"
  local nojq="$BATS_TEST_TMPDIR/nojq"
  path_without_jq "$nojq"
  PATH="$nojq" command -v jq >/dev/null 2>&1 && skip "jq is on PATH even without /usr/bin and /bin"
  run env PATH="$nojq" "$CLIKAE_BIN" hooks share Stop "/bin/echo snapshot" claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]] || false
}
