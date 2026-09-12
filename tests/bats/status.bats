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

# --- R1-P2-1: the fuel scan is shared, not re-run per row ---------------------
#
# _status_fuel_note used to re-run `list_all_profiles | limit_dry_set` from
# scratch for EVERY rendered row — a full re-scan of every tank's transcripts,
# once per row of the table it renders. A 12-tank board went from 42ms to
# 1.6s (see REPORT-dry75-fix1.md). The fix computes that scan ONCE per
# `_status_render_table`/`_status_render_json` call and passes it down.
@test "status --json's fuel scan runs ONCE no matter how many rows are rendered" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/i18n.sh"
  source "$CLIKAE_LIB/core/json.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/dry_store.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/commands/status.sh"

  local calls_file; calls_file="$(mktemp)"
  list_all_profiles() {
    printf 'x' >> "$calls_file"
    printf 'claude\ta\t/x/a\nclaude\tb\t/x/b\nclaude\tc\t/x/c\n'
  }

  local rows=""
  local i
  for i in a b c; do
    rows="$rows$(printf 'claude\037active\037%s\037acct\037CLAUDE_CONFIG_DIR\037/x/%s' "$i" "$i")"$'\n'
  done

  printf '%s' "$rows" | _status_render_json >/dev/null
  # THREE rendered rows, but the scan itself must run exactly once.
  [ "$(wc -c < "$calls_file")" -eq 1 ]
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
