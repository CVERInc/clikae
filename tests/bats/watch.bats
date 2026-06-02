#!/usr/bin/env bats
# tests/bats/watch.bats — `clikae watch` detection + resolution (not the live
# tail loop, which is exercised manually).

load '../helpers'

_slug() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

_seed() {
  local profile="$1" dir="$2" extra="$3"
  local d="$CLIKAE_HOME/profiles/claude/$profile/projects/$(_slug "$dir")"
  mkdir -p "$d"
  {
    echo '{"type":"user","cwd":"'"$dir"'","message":{"role":"user","content":"do work"},"timestamp":"2026-05-31T01:00:00Z"}'
    [ -z "$extra" ] || echo "$extra"
  } > "$d/sid.jsonl"
  return 0
}

@test "watch --check reports no marker on a clean session" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed a "$work" ""
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae watch claude --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"No genuine limit marker"* ]] || false
}

@test "watch --check finds a genuine synthetic limit marker" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  # The real shape, dogfooded 2026-05-31: a synthetic api-error assistant line.
  _seed a "$work" '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit, resets 11pm"}]}}'
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae watch claude --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"genuine limit marker IS present"* ]] || false
  [[ "$output" == *"hit your session limit"* ]] || false
}

@test "watch --check ignores a session that only DISCUSSES a limit (dogfood regression)" {
  # A normal assistant turn (real model, no isApiErrorMessage) that merely talks
  # about limits — exactly what made the old pure-text match false-fire. Must NOT
  # be treated as a real limit event.
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed a "$work" '{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"lets discuss what happens when you hit your session limit and the usage limit resets"}]}}'
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae watch claude --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"No genuine limit marker"* ]] || false
}

@test "watch --check honours a custom --pattern" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed a "$work" '{"type":"system","text":"FUEL_EMPTY_XYZ"}'
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" \
    run clikae watch claude --check --pattern 'FUEL_EMPTY_XYZ'
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker IS present"* ]] || false
}

@test "watch errors when there's no next tank and no --to" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed a "$work" ""
  cd "$work"
  # Only one tank exists -> nothing after it in the burn order -> error.
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae watch claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"burn order"* ]] || false
}

@test "watch errors when there's no session to watch" {
  clikae init claude a
  local empty="$TEST_HOME/empty"; mkdir -p "$empty"
  cd "$empty"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae watch claude --to codex/work
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to watch"* ]] || false
}

# --- launch-only target (antigravity): watch its limit LOG, not a transcript ---

_agy_log() { # write $1 as agy's cli.log under the test HOME
  mkdir -p "$TEST_HOME/.gemini/antigravity-cli"
  printf '%s\n' "$1" > "$TEST_HOME/.gemini/antigravity-cli/cli.log"
}

@test "watch antigravity --check reports no marker on a clean log" {
  _agy_log "I0531 17:03:01 info: Print mode: silent auth succeeded"
  run clikae watch antigravity --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"No limit marker"* ]] || false
}

@test "watch antigravity --check finds the confirmed quota marker" {
  _agy_log "E0531 log.go:398] agent executor error: RESOURCE_EXHAUSTED (code 429): Individual quota reached. Contact your administrator to enable overages. Resets in 2h23m58s."
  run clikae watch antigravity --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker IS present"* ]] || false
  [[ "$output" == *"RESOURCE_EXHAUSTED"* ]] || false
  [[ "$output" == *"Individual quota reached"* ]] || false
}

@test "watch antigravity rejects a <profile> (single-account target)" {
  run clikae watch antigravity somelabel --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"single-account target"* ]] || false
}

@test "watch antigravity errors when there's no log yet" {
  # No ~/.gemini log seeded; follow mode must fail fast, not hang.
  run clikae watch antigravity --to codex/work
  [ "$status" -ne 0 ]
  [[ "$output" == *"Nothing to watch"* ]] || false
}
