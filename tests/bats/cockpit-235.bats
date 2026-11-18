#!/usr/bin/env bats
load '../helpers'
bats_require_minimum_version 1.5.0

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
  _stub_claude_235
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

@test "235 off handles unquoted and double-quoted paths without a record or tank marker, and backs up settings" {
  clikae init claude A >/dev/null
  clikae init claude B >/dev/null
  local a="$CLIKAE_HOME/profiles/claude/A/settings.json"
  local b="$CLIKAE_HOME/profiles/claude/B/settings.json"
  _legacy_guard "$a" /example/old/lib/hooks/cockpit-guard.sh
  _legacy_guard "$b" '"/example/old checkout/lib/hooks/cockpit-guard.sh"'
  rm "$CLIKAE_HOME/profiles/claude/B/.clikae-tank"
  cp "$a" "$BATS_TEST_TMPDIR/before.json"
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [ "$(jq '.hooks.PreToolUse | length' "$a")" -eq 1 ]
  [ "$(jq '.hooks.PreToolUse | length' "$b")" -eq 1 ]
  local backups=("$a".clikae.bak.*)
  [ "${#backups[@]}" -eq 1 ]
  cmp "$BATS_TEST_TMPDIR/before.json" "${backups[0]}"
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [ "$output" = 'cockpit: already off (unchanged)' ]
}

@test "235 off matches decoded JSON paths but preserves other events and similar command names" {
  clikae init claude A >/dev/null
  local f="$CLIKAE_HOME/profiles/claude/A/settings.json"
  cat > "$f" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Agent","hooks":[{"command":"\/example\/hooks\/cockpit-guard\u002esh"}]},
  {"matcher":"Agent","hooks":[{"command":"/example/hooks/cockpit-guard.sh.backup"}]},
  {"matcher":"Agent","hooks":[{"command":"/example/not-hooks/cockpit-guard.sh"}]},
  {"matcher":"Agent","hooks":[{"command":"/example/hooks/other.sh"}]}],
  "Stop":[{"hooks":[{"command":"/example/hooks/cockpit-guard.sh"}]}]}}
JSON
  jq 'del(.hooks.PreToolUse[0])' "$f" > "$BATS_TEST_TMPDIR/expected.json"
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *'cockpit guard removed (1 entry)'* ]] || false
  cmp "$BATS_TEST_TMPDIR/expected.json" "$f"
}

@test "235 off reports a broken legacy guard, continues the sweep, and never claims off" {
  clikae init claude A >/dev/null
  clikae init claude B >/dev/null
  local a="$CLIKAE_HOME/profiles/claude/A/settings.json"
  local b="$CLIKAE_HOME/profiles/claude/B/settings.json"
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"/example/hooks/cockpit-guard.sh"}] BROKEN\n' > "$a"
  cp "$a" "$BATS_TEST_TMPDIR/broken.json"
  _legacy_guard "$b" /example/hooks/cockpit-guard.sh
  run clikae cockpit --off
  [ "$status" -eq 1 ]
  [[ "$output" == *'claude/A: skipped — settings.json is not valid JSON'* ]] || false
  [[ "$output" == *'--off could not clean up: claude/A'* ]] || false
  [[ "$output" != *'cockpit: off'* ]] || false
  [ "$(jq '.hooks.PreToolUse | length' "$b")" -eq 1 ]
  cmp "$BATS_TEST_TMPDIR/broken.json" "$a"
}

@test "235 off refuses a symlinked legacy guard without altering its target" {
  clikae init claude A >/dev/null
  local f="$CLIKAE_HOME/profiles/claude/A/settings.json"
  _legacy_guard "$BATS_TEST_TMPDIR/target.json" /example/hooks/cockpit-guard.sh
  cp "$BATS_TEST_TMPDIR/target.json" "$BATS_TEST_TMPDIR/before.json"
  rm "$f"
  ln -s "$BATS_TEST_TMPDIR/target.json" "$f"
  run clikae cockpit --off
  [ "$status" -eq 1 ]
  [[ "$output" == *'settings.json is not a regular, unlinked file'* ]] || false
  [[ "$output" != *'cockpit: off'* ]] || false
  cmp "$BATS_TEST_TMPDIR/before.json" "$BATS_TEST_TMPDIR/target.json"
}

@test "235 moving and repairing the role remove legacy duplicates without accumulating guards" {
  clikae init claude A >/dev/null
  clikae init claude B >/dev/null
  local a="$CLIKAE_HOME/profiles/claude/A/settings.json"
  local b="$CLIKAE_HOME/profiles/claude/B/settings.json"
  _legacy_guard "$a" /example/old/hooks/cockpit-guard.sh 2
  _legacy_guard "$b" /example/runtime/hooks/cockpit-guard.sh 2
  printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"
  run clikae cockpit claude B
  [ "$status" -eq 0 ]
  [[ "$output" == *'claude/A: cockpit guard removed (2 entries)'* ]] || false
  [ "$(jq '.hooks.PreToolUse | length' "$a")" -eq 1 ]
  [ "$(jq '.hooks.PreToolUse | length' "$b")" -eq 2 ]
  jq -e '.hooks.PreToolUse[1]._clikae == "cockpit-guard"' "$b" >/dev/null
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = claude/B ]
  _legacy_guard "$b" /example/old/hooks/cockpit-guard.sh 2
  run clikae cockpit claude B
  [ "$status" -eq 0 ]
  [ "$(jq '.hooks.PreToolUse | length' "$b")" -eq 2 ]
  jq -e '.hooks.PreToolUse[1]._clikae == "cockpit-guard"' "$b" >/dev/null
  run clikae cockpit claude B
  [ "$status" -eq 0 ]
  [[ "$output" == *'cockpit guard already installed (unchanged)'* ]] || false
}

_stub_claude_235() {
  cat > "$TEST_HOME/.testbin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'completed\n' > "$ISSUE235_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/.testbin/claude"
  export ISSUE235_ARTIFACT="$BATS_TEST_TMPDIR/out.md"
}

@test "235 burn warns on stderr even when allowed onto the caller tank and keeps JSON stdout valid" {
  local stderr=""
  _stub_claude_235
  clikae init claude A >/dev/null
  clikae init claude B >/dev/null
  printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"
  export CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/B"
  run --separate-stderr clikae burn claude B --allow-active --json --artifact "$ISSUE235_ARTIFACT" -- -p test
  [ "$status" -eq 0 ]
  [ "$(cat "$ISSUE235_ARTIFACT")" = completed ]
  printf '%s' "$output" | jq -e '.ok == true and .tank == "B"' >/dev/null
  [[ "$stderr" == *'calling session claude/B differs from recorded cockpit claude/A'* ]] || false
  [ "$(printf '%s\n' "$stderr" | grep -c 'calling session')" -eq 1 ]
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = claude/A ]
}

@test "235 burn leaves matching, ambiguous and unidentified callers quiet" {
  _stub_claude_235
  clikae init claude A >/dev/null
  clikae init claude B >/dev/null
  clikae init codex C >/dev/null
  printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"
  local caller
  for caller in A missing; do
    export CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/$caller"
    run clikae burn claude A --artifact "$BATS_TEST_TMPDIR/out.md" -- -p test
    [ "$status" -eq 1 ]
    [[ "$output" == *'claude/A is the recorded cockpit'* ]] || false
    [[ "$output" != *'calling session'* ]] || false
  done
  # Set the additional engine's variable only in the child process.
  export CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/B"
  run env CODEX_HOME="$CLIKAE_HOME/profiles/codex/C" clikae burn claude A --artifact "$BATS_TEST_TMPDIR/out.md" -- -p test
  [ "$status" -eq 1 ]
  [[ "$output" != *'calling session'* ]] || false
}

@test "235 off refuses to claim success when legacy settings cannot be read" {
  if [ "$(id -u)" -eq 0 ]; then skip 'root can read a mode-000 file'; fi
  clikae init claude A >/dev/null
  local f="$CLIKAE_HOME/profiles/claude/A/settings.json"
  _legacy_guard "$f" /example/hooks/cockpit-guard.sh
  cp "$f" "$BATS_TEST_TMPDIR/before.json"
  chmod 000 "$f"
  run clikae cockpit --off
  chmod 600 "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *'claude/A: failed to read settings.json'* ]] || false
  [[ "$output" != *'cockpit: off'* ]] || false
  cmp "$BATS_TEST_TMPDIR/before.json" "$f"
}
