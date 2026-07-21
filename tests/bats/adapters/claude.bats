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

# --- customTitle precedence (2026-07-12: a `/rename` must outrank the stale
# machine-generated aiTitle everywhere a title is derived, INCLUDING clean's
# deletion list — a renamed live session was unrecognizable there) ------------

@test "claude title_for_file: a USER-set custom-title outranks a later aiTitle" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t5.jsonl"
  {
    printf '{"type":"custom-title","customTitle":"My Renamed Session"}\n'
    printf '{"type":"ai-title","aiTitle":"Machine title"}\n'
  } > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "My Renamed Session" ]
}

@test "claude title_for_file: a transcript with only aiTitle is unchanged" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t6.jsonl"
  printf '{"type":"summary","aiTitle":"Just the AI title"}\n' > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "Just the AI title" ]
}

# --- a /rename PAST the head window is still the name (2026-07-21: the resume
# picker and home board scanned only the first 100 lines, so a session renamed
# deep in a long conversation kept showing its PRE-rename name — while the
# board's own _claude_meta_for_file, which reads the tail, showed the new one) --

@test "claude title_for_file: a rename past line 100 wins over an early name" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t7.jsonl"
  # Early name in the head window, then 200 filler lines, then the real /rename
  # far past the 100-line head cutoff — only a tail scan can see it.
  printf '{"type":"custom-title","customTitle":"early-name"}\n' > "$f"
  local i; for ((i = 0; i < 200; i++)); do
    printf '{"type":"assistant","message":{"role":"assistant","content":"filler %d"}}\n' "$i" >> "$f"
  done
  printf '{"type":"custom-title","customTitle":"renamed-late"}\n' >> "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "renamed-late" ]
}
