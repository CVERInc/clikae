#!/usr/bin/env bats
# tests/bats/adapters/claude.bats — the built-in claude adapter + adapter listing.

load '../../helpers'

@test "adapters lists claude and the v0.2 adapters" {
  run clikae adapters
  [ "$status" -eq 0 ]
  for cli in claude gh gcloud docker helm kubectl aws; do
    [[ "$output" == *"$cli"* ]] || { echo "missing adapter: $cli"; false; }
  done
}

@test "claude adapter reports the env-dir strategy and its env var" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"*"env-dir"*"CLAUDE_CONFIG_DIR"* ]] || false
}

@test "info reports a profile count that tracks init" {
  clikae init claude work
  clikae init gh personal
  run clikae info
  [ "$status" -eq 0 ]
  [[ "$output" == *"tanks"*"2"* ]] || false
}

@test "claude alias exports CLAUDE_CONFIG_DIR at the profile path" {
  clikae init claude work
  clikae alias claude work
  grep -qF "CLAUDE_CONFIG_DIR=\"$CLIKAE_HOME/profiles/claude/work\"" "$RC_FILE"
}

@test "claude title_for_file: aiTitle with escaped quotes survives intact" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t.jsonl"
  printf '{"type":"summary","aiTitle":"Fix the \\"off-by-one\\" bug in loop"}\n' > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [ "$output" = 'Fix the "off-by-one" bug in loop' ]
}

@test "claude title_for_file: falls back to the first user message when no aiTitle" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t2.jsonl"
  printf '{"role":"user","content":[{"type":"text","text":"hello from the opening prompt"}]}\n' > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from the opening prompt"* ]] || false
}
