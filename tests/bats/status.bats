#!/usr/bin/env bats
# tests/bats/status.bats — `clikae status`

load '../helpers'

@test "status reports nothing when there are no profiles" {
  run clikae status
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tanks yet"* ]] || false
}

@test "status shows (default) when the env var is unset" {
  clikae init claude work
  unset CLAUDE_CONFIG_DIR
  run clikae status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]] || false
  [[ "$output" == *"(default)"* ]] || false
}

@test "status resolves a path env var to its profile (env-dir)" {
  clikae init claude work
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/work" run clikae status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]] || false
  [[ "$output" == *"work"* ]] || false
}

@test "status reports (external) when the path is not a clikae profile" {
  clikae init claude work
  CLAUDE_CONFIG_DIR="/tmp/not-a-clikae-profile" run clikae status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"(external)"* ]] || false
}

@test "status resolves an env-var strategy (aws) to the profile name" {
  clikae init aws work
  AWS_PROFILE="work" run clikae status aws
  [ "$status" -eq 0 ]
  [[ "$output" == *"aws"* ]] || false
  [[ "$output" == *"work"* ]] || false
}

@test "status with no args lists every CLI that has a profile" {
  clikae init claude work
  clikae init gh personal
  unset CLAUDE_CONFIG_DIR GH_CONFIG_DIR
  run clikae status
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]] || false
  [[ "$output" == *"gh"* ]] || false
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
  [[ "$output" == *'"state":"default"'* ]] || false
  [[ "$output" == *'"profile":null'* ]] || false
  [[ "$output" == *'"envVar":"CLAUDE_CONFIG_DIR"'* ]] || false
  [[ "$output" == *'"envValue":null'* ]] || false
}

@test "status --json: active state resolves profile + account label" {
  clikae init claude work
  local d="$CLIKAE_HOME/profiles/claude/work"
  printf '{\n  "oauthAccount": { "emailAddress": "me@example.com" }\n}\n' > "$d/.claude.json"
  CLAUDE_CONFIG_DIR="$d" run clikae status claude --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"active"'* ]] || false
  [[ "$output" == *'"profile":"work"'* ]] || false
  [[ "$output" == *'"account":"me@example.com"'* ]] || false
  [[ "$output" == *"\"envValue\":\"$d\""* ]] || false
}

@test "status --json: external state when var points outside clikae" {
  clikae init claude work
  CLAUDE_CONFIG_DIR="/tmp/not-a-clikae-profile" run clikae status claude --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"external"'* ]] || false
  [[ "$output" == *'"profile":null'* ]] || false
}

@test "status --json: flag-strategy adapter reports flag state, null envVar" {
  clikae init vercel prod
  run clikae status vercel --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"flag"'* ]] || false
  [[ "$output" == *'"envVar":null'* ]] || false
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

# --- target-backed engines (agy) must not crash the all-engines view ----------
# Regression: load_adapter exit()s on a missing adapter file, so the `||` guard
# in _status_row_for never fired; an agy tank made `clikae status` (no args)
# abort with empty output + exit 1 under `set -eo pipefail`.

@test "status (no args) does not crash when an adapter-less agy tank exists" {
  mkdir -p "$HOME/.gemini"; echo LOGIN > "$HOME/.gemini/auth.txt"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1   # default(active)+work, symlinks ~/.gemini
  clikae init claude work
  run clikae status
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy"* ]] || false
  [[ "$output" == *"claude"* ]] || false
}

@test "status shows the agy tank the ~/.gemini symlink points at" {
  mkdir -p "$HOME/.gemini"; echo LOGIN > "$HOME/.gemini/auth.txt"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  run clikae status
  [ "$status" -eq 0 ]
  [[ "$output" == *"default"* ]] || false        # active tank, resolved from the symlink
  [[ "$output" == *"machine-wide"* ]] || false
}

@test "status --json: agy reports the 'global' state" {
  mkdir -p "$HOME/.gemini"; echo LOGIN > "$HOME/.gemini/auth.txt"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  run clikae status --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"cli":"agy"'* ]] || false
  [[ "$output" == *'"state":"global"'* ]] || false
  [[ "$output" == *'"profile":"default"'* ]] || false
}
