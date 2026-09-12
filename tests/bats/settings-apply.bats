#!/usr/bin/env bats
load '../helpers'

@test "settings unions both lists and preserves other keys and backup" {
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  printf '%s\n' '{"permissions":{"allow":["Bash(custom *)"],"deny":["Bash(secret *)"],"defaultMode":"acceptEdits"},"env":{"X":"keep"},"hooks":{}}' > "$d/settings.json"
  cp "$d/settings.json" "$TEST_HOME/before"
  run clikae settings apply claude work
  [ "$status" -eq 0 ]
  jq -e '.permissions.allow[0] == "Bash(custom *)" and .permissions.deny[0] == "Bash(secret *)" and .permissions.defaultMode == "acceptEdits" and .env.X == "keep" and .hooks == {} and (.permissions.deny | index("Bash(sudo *)") != null)' "$d/settings.json"
  cmp "$TEST_HOME/before" "$d"/settings.json.clikae.bak.*
}

@test "second apply is a byte-identical no-op" {
  clikae init claude work
  local f="$CLIKAE_HOME/profiles/claude/work/settings.json"
  cp "$f" "$TEST_HOME/before"
  run clikae settings apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/work: unchanged"* ]] || false
  cmp "$f" "$TEST_HOME/before"
}

@test "check detects hand-edited drift and goes green after apply" {
  clikae init claude work
  local f="$CLIKAE_HOME/profiles/claude/work/settings.json"
  jq 'del(.permissions.deny[0])' "$f" > "$TEST_HOME/edited"
  cp "$TEST_HOME/edited" "$f"
  run clikae settings apply --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude/work: permissions drift"* ]] || false
  cmp "$f" "$TEST_HOME/edited"
  clikae settings apply
  run clikae settings apply --check
  [ "$status" -eq 0 ]
}

@test "init creates settings that pass check" {
  clikae init claude fresh
  run clikae settings apply claude fresh --check
  [ "$status" -eq 0 ]
}

@test "invalid JSON is skipped while other tanks are applied" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/bad" "$CLIKAE_HOME/profiles/claude/good"
  local f="$CLIKAE_HOME/profiles/claude/bad/settings.json"
  printf '{broken' > "$f"
  cp "$f" "$TEST_HOME/before"
  run clikae settings apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude/bad: skipped"*"invalid JSON"* ]] || false
  cmp "$f" "$TEST_HOME/before"
  [ -f "$CLIKAE_HOME/profiles/claude/good/settings.json" ]
}

@test "dry-run previews all tanks without creating settings" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/a" "$CLIKAE_HOME/profiles/claude/b"
  run clikae settings apply --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/a: +"*"claude/b: +"* ]] || false
  [ "$(find "$CLIKAE_HOME/profiles" -type f | wc -l | tr -d ' ')" -eq 0 ]
}

@test "settings rejects malformed shapes and empty files unchanged" {
  local d="$CLIKAE_HOME/profiles/claude/work" value
  mkdir -p "$d"
  for value in '' 'null' '[]' '{"permissions":{"allow":"oops"}}' '{} {}'; do
    printf '%s' "$value" > "$d/settings.json"
    cp "$d/settings.json" "$TEST_HOME/before"
    run clikae settings apply claude work
    [ "$status" -ne 0 ]
    cmp "$d/settings.json" "$TEST_HOME/before"
  done
}

@test "settings rejects unsupported engines missing tanks and conflicting flags" {
  run clikae settings apply codex
  [ "$status" -ne 0 ]
  run clikae settings apply claude absent
  [ "$status" -ne 0 ]
  run clikae settings apply --check --dry-run
  [ "$status" -ne 0 ]
}

@test "doctor permissions helper reports each drifted tank and stays read-only" {
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  run bash -c 'source "$CLIKAE_LIB/core/profile_store.sh"; source "$CLIKAE_LIB/commands/settings.sh"; _settings_tank claude work doctor "$CLIKAE_ROOT/templates/permissions/claude.json"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude/work: permissions drift"* ]] || false
  [ ! -e "$d/settings.json" ]
}

@test "targeted apply leaves other tanks alone and expands Linux username" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/a" "$CLIKAE_HOME/profiles/claude/b"
  clikae settings apply claude a
  [ ! -e "$CLIKAE_HOME/profiles/claude/b/settings.json" ]
  jq -e --arg rule "Bash(/home/$(id -un)/*)" '.permissions.allow | index($rule) != null' "$CLIKAE_HOME/profiles/claude/a/settings.json"
}

@test "symlinked settings are skipped without changing the target" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/work"
  printf '{}\n' > "$TEST_HOME/target"
  cp "$TEST_HOME/target" "$TEST_HOME/before"
  ln -s "$TEST_HOME/target" "$CLIKAE_HOME/profiles/claude/work/settings.json"
  run clikae settings apply
  [ "$status" -ne 0 ]
  cmp "$TEST_HOME/target" "$TEST_HOME/before"
  [ -L "$CLIKAE_HOME/profiles/claude/work/settings.json" ]
}

@test "failed rename preserves the live file and cleans the temporary file" {
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  printf '{}\n' > "$d/settings.json"
  cp "$d/settings.json" "$TEST_HOME/before"
  printf '#!/bin/sh\nexit 1\n' > "$TEST_HOME/.testbin/mv"
  chmod +x "$TEST_HOME/.testbin/mv"
  run clikae settings apply
  [ "$status" -ne 0 ]
  cmp "$d/settings.json" "$TEST_HOME/before"
  [ "$(find "$d" -name '*.tmp.*' | wc -l | tr -d ' ')" -eq 0 ]
}
