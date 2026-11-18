#!/usr/bin/env bats
load '../helpers'

# Public, synthetic paths: none of these hooks is ever executed.
_legacy_guard() {
  jq -n --arg command "$2" --argjson count "${3:-1}" '
    {env:{KEEP:"yes"},hooks:{
      PreToolUse: ([range($count) | {matcher:"Agent",hooks:[{type:"command",command:$command}]}]
        + [{matcher:"Bash",hooks:[{type:"command",command:"/example/human.sh"}]}]),
      Stop:[{hooks:[{type:"command",command:"/example/stop.sh"}]}]}}' > "$1"
}

@test "235 point 1: off removes all four unmarked guards across runtime and checkout paths" {
  local tank f
  for tank in A B C; do clikae init claude "$tank" >/dev/null; done
  _legacy_guard "$CLIKAE_HOME/profiles/claude/A/settings.json" "'/example/runtime/lib/hooks/cockpit-guard.sh'"
  _legacy_guard "$CLIKAE_HOME/profiles/claude/B/settings.json" "'/example/runtime/lib/hooks/cockpit-guard.sh'" 2
  _legacy_guard "$CLIKAE_HOME/profiles/claude/C/settings.json" "'/example/old checkout/lib/hooks/cockpit-guard.sh'"
  printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"

  run clikae cockpit --off
  [ "$status" -eq 0 ]
  for tank in A B C; do
    f="$CLIKAE_HOME/profiles/claude/$tank/settings.json"
    [ "$(jq '.hooks.PreToolUse | length' "$f")" -eq 1 ]
    jq -e '.env.KEEP == "yes" and .hooks.PreToolUse[0].hooks[0].command == "/example/human.sh"
      and .hooks.Stop[0].hooks[0].command == "/example/stop.sh"' "$f" >/dev/null
  done
  [[ "$output" == *"claude/A: cockpit guard removed (1 entry)"* ]] || false
  [[ "$output" == *"claude/B: cockpit guard removed (2 entries)"* ]] || false
  [[ "$output" == *"claude/C: cockpit guard removed (1 entry)"* ]] || false
  [[ "$output" == *"cockpit: off"* ]] || false
  [ ! -e "$CLIKAE_HOME/state/cockpit" ]
}

@test "235 point 2: burn warns when the calling session has moved away from the recorded cockpit" {
  clikae init claude A >/dev/null
  clikae init claude B >/dev/null
  printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"
  export CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/B"
  # No engine is launched: the existing recorded-cockpit gate still refuses A.
  run clikae burn claude A --artifact "$BATS_TEST_TMPDIR/out.md" -- -p test
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude/A is the recorded cockpit"* ]] || false
  [[ "$output" == *'cockpit: calling session claude/B differs from recorded cockpit claude/A; run `clikae cockpit claude B` if this session now steers.'* ]] || false
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = claude/A ]
}
