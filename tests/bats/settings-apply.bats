#!/usr/bin/env bats
load '../helpers'

@test "the claude permissions template is valid, shaped JSON with no exact-duplicate rules" {
  # `init` only tolerates rc 2 (no template) / rc 3 (no jq) from `settings
  # apply`; any other failure -- including a template that fails cmd_settings'
  # own shape check -- surfaces as a half-created tank (P76 R2 P3-B). This
  # guards the one trigger for that left standing once P2-1 was removed.
  local f="$CLIKAE_ROOT/templates/permissions/claude.json"
  jq -e 'type == "object" and (.permissions.allow | type == "array" and all(.[]; type == "string")) and (.permissions.deny | type == "array" and all(.[]; type == "string"))' "$f"
  jq -e '.permissions.allow | length == (unique | length)' "$f"
  jq -e '.permissions.deny | length == (unique | length)' "$f"
}

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
  [ "$status" -eq 2 ]
  [[ "$output" == *"No permissions template for engine: codex"* ]] || false
  run clikae settings apply claude absent
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tank does not exist: claude/absent"* ]] || false
  run clikae settings apply --check --dry-run
  [ "$status" -ne 0 ]
}

@test "settings apply without jq fails clearly and does not write" {
  local nojq="$BATS_TEST_TMPDIR/nojq"
  path_without_jq "$nojq"
  PATH="$nojq" command -v jq >/dev/null 2>&1 && skip "jq is on PATH even without /usr/bin and /bin"
  clikae init claude work
  local f="$CLIKAE_HOME/profiles/claude/work/settings.json"
  cp "$f" "$TEST_HOME/before"
  run env PATH="$nojq" "$CLIKAE_BIN" settings apply claude work
  [ "$status" -eq 3 ]
  [[ "$output" == *"requires jq"* ]] || false
  cmp "$f" "$TEST_HOME/before"
}

@test "an allow rule that matches a deny rule by the same string is applied, not refused" {
  # Claude evaluates deny before allow, so an identical string in both lists
  # is not a bypass: deny still wins. Refusing to write it here bought
  # nothing and left the tank worse off in the one case it fired on for real
  # (a tank that had already allowed Bash(sudo *) kept sudo allowed and
  # unopposed, instead of picking up the template's matching deny rule).
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  printf '%s\n' '{"permissions":{"allow":["Bash(sudo *)"]}}' > "$d/settings.json"
  run clikae settings apply claude work
  [ "$status" -eq 0 ]
  jq -e '.permissions.allow | index("Bash(sudo *)") != null' "$d/settings.json"
  jq -e '.permissions.deny | index("Bash(sudo *)") != null' "$d/settings.json"
}

@test "settings apply with no tanks of the engine says so and exits 0" {
  run clikae settings apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"No claude tanks found."* ]] || false
}

@test "doctor permissions helper reports each drifted tank and stays read-only" {
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  run bash -c 'source "$CLIKAE_LIB/core/profile_store.sh"; source "$CLIKAE_LIB/commands/settings.sh"; _settings_tank claude work doctor "$CLIKAE_ROOT/templates/permissions/claude.json"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude/work: permissions drift"* ]] || false
  [ ! -e "$d/settings.json" ]
}

@test "targeted apply leaves other tanks alone and expands \$HOME" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/a" "$CLIKAE_HOME/profiles/claude/b"
  clikae settings apply claude a
  [ ! -e "$CLIKAE_HOME/profiles/claude/b/settings.json" ]
  jq -e --arg rule "Bash($HOME/*)" '.permissions.allow | index($rule) != null' "$CLIKAE_HOME/profiles/claude/a/settings.json"
}

@test "\$HOME/* expands the same whether or not the caller's HOME has a trailing slash" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/a"
  clikae settings apply claude a
  run env HOME="$HOME/" "$CLIKAE_BIN" settings apply claude a --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/a: unchanged"* ]] || false
}

@test "a colon-spelled allow rule is recognized as equivalent to the template's space-spelled rule" {
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' > "$d/settings.json"
  run clikae settings apply claude work
  [ "$status" -eq 0 ]
  jq -e '[.permissions.allow[] | select(. == "Bash(ls *)" or . == "Bash(ls:*)")] | length == 1' "$d/settings.json"
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

@test "_settings_write_file refuses empty content and leaves the live file byte-identical (#63 P2-4)" {
  # The exact repro from the round-1 review: a jq that dies mid-pipeline (OOM,
  # disk full, killed mid-upgrade) makes command substitution swallow the
  # failure and hand `_settings_write_file` an empty string — which the old
  # code wrote as a single bare newline, rc=0, no error, over a live file.
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  printf '%s\n' '{"model":"opus"}' > "$d/settings.json"
  cp "$d/settings.json" "$TEST_HOME/before"
  source "$CLIKAE_LIB/commands/settings.sh"
  run _settings_write_file "$d/settings.json" "" probe
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to write empty content"* ]] || false
  cmp "$TEST_HOME/before" "$d/settings.json"
  # No backup should have been made either -- the write was refused before
  # touching anything, not rolled back after.
  [ "$(find "$d" -name '*.clikae.bak.*' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "settings.json.clikae.bak.* is capped at the newest 5 per tank (#63 P3-11)" {
  clikae init claude work
  local d="$CLIKAE_HOME/profiles/claude/work" i
  source "$CLIKAE_LIB/commands/settings.sh"
  for i in 1 2 3 4 5 6 7; do
    printf '%s\n' "{\"model\":\"m$i\"}" > "$d/settings.json"
    run _settings_write_file "$d/settings.json" "{\"model\":\"m$((i + 1))\"}" "claude/work"
    [ "$status" -eq 0 ] || { echo "iter $i failed: $output" >&2; false; }
  done
  [ "$(find "$d" -name '*.clikae.bak.*' | wc -l | tr -d ' ')" -eq 5 ]
}
