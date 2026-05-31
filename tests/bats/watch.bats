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
  [[ "$output" == *"No limit marker"* ]]
}

@test "watch --check finds a limit marker when present" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed a "$work" '{"type":"error","message":{"content":"reached your usage limit"}}'
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae watch claude --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"limit-like marker IS present"* ]]
  [[ "$output" == *"usage limit"* ]]
}

@test "watch --check honours a custom --pattern" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed a "$work" '{"type":"system","text":"FUEL_EMPTY_XYZ"}'
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" \
    run clikae watch claude --check --pattern 'FUEL_EMPTY_XYZ'
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker IS present"* ]]
}

@test "watch errors when there's no next tank and no --to" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed a "$work" ""
  cd "$work"
  # Pool empty and claude/a not in it -> pool_next returns first (none) -> error.
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae watch claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"No next tank"* ]]
}

@test "watch errors when there's no session to watch" {
  clikae init claude a
  local empty="$TEST_HOME/empty"; mkdir -p "$empty"
  cd "$empty"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae watch claude --to codex/work
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to watch"* ]]
}
