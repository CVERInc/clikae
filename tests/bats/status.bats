#!/usr/bin/env bats
# tests/bats/status.bats — `clikae status`

load '../helpers'

@test "status reports nothing when there are no profiles" {
  run clikae status
  [ "$status" -eq 0 ]
  [[ "$output" == *"No profiles yet"* ]]
}

@test "status shows (default) when the env var is unset" {
  clikae init claude work
  unset CLAUDE_CONFIG_DIR
  run clikae status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"(default)"* ]]
}

@test "status resolves a path env var to its profile (env-dir)" {
  clikae init claude work
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/work" run clikae status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"work"* ]]
}

@test "status reports (external) when the path is not a clikae profile" {
  clikae init claude work
  CLAUDE_CONFIG_DIR="/tmp/not-a-clikae-profile" run clikae status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"(external)"* ]]
}

@test "status resolves an env-var strategy (aws) to the profile name" {
  clikae init aws work
  AWS_PROFILE="work" run clikae status aws
  [ "$status" -eq 0 ]
  [[ "$output" == *"aws"* ]]
  [[ "$output" == *"work"* ]]
}

@test "status with no args lists every CLI that has a profile" {
  clikae init claude work
  clikae init gh personal
  unset CLAUDE_CONFIG_DIR GH_CONFIG_DIR
  run clikae status
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"gh"* ]]
}

# --- --json: machine-readable output for the GUI / scripts --------------------

@test "status --json: no profiles emits an empty array (not a message)" {
  run clikae status --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "status --json: default state has null profile + the env var name" {
  clikae init claude work
  unset CLAUDE_CONFIG_DIR
  run clikae status claude --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"default"'* ]]
  [[ "$output" == *'"profile":null'* ]]
  [[ "$output" == *'"envVar":"CLAUDE_CONFIG_DIR"'* ]]
  [[ "$output" == *'"envValue":null'* ]]
}

@test "status --json: active state resolves profile + account label" {
  clikae init claude work
  local d="$CLIKAE_HOME/profiles/claude/work"
  printf '{\n  "oauthAccount": { "emailAddress": "me@example.com" }\n}\n' > "$d/.claude.json"
  CLAUDE_CONFIG_DIR="$d" run clikae status claude --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"active"'* ]]
  [[ "$output" == *'"profile":"work"'* ]]
  [[ "$output" == *'"account":"me@example.com"'* ]]
  [[ "$output" == *"\"envValue\":\"$d\""* ]]
}

@test "status --json: external state when var points outside clikae" {
  clikae init claude work
  CLAUDE_CONFIG_DIR="/tmp/not-a-clikae-profile" run clikae status claude --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"external"'* ]]
  [[ "$output" == *'"profile":null'* ]]
}

@test "status --json: flag-strategy adapter reports flag state, null envVar" {
  clikae init vercel prod
  run clikae status vercel --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"flag"'* ]]
  [[ "$output" == *'"envVar":null'* ]]
}

@test "status --json output parses as valid JSON" {
  clikae init claude work
  clikae init gh personal
  if command -v python3 >/dev/null; then
    clikae status --json | python3 -m json.tool >/dev/null
  else
    skip "python3 not available to validate JSON"
  fi
}
