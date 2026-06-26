#!/usr/bin/env bats
# tests/bats/resume.bats — `clikae resume [session-id]`
#
# resume exec's the engine to reopen a past session, so we stub `claude` to record
# its argv + CLAUDE_CONFIG_DIR + cwd, then assert clikae found the right tank,
# cd'd to the session's recorded directory, and resumed under that tank's config.

load '../helpers'

# A fake `claude` that records argv, CLAUDE_CONFIG_DIR and $PWD, then exits.
_install_claude_stub() {
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/claude" <<'STUB'
#!/usr/bin/env bash
{
  echo "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
  echo "PWD=$PWD"
  echo "ARGS=$*"
} > "$CLAUDE_STUB_LOG"
exit 0
STUB
  chmod +x "$TEST_HOME/bin/claude"
  export PATH="$TEST_HOME/bin:$PATH"
  export CLAUDE_STUB_LOG="$TEST_HOME/stub.log"
}

# Slug a path the way Claude Code does: [^A-Za-z0-9] -> '-'.
_slug() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

# Seed a transcript for <profile> covering directory <dir>, carrying a cwd field.
_seed_transcript() {
  local profile="$1" dir="$2" sid="$3"
  local slug; slug="$(_slug "$dir")"
  mkdir -p "$CLIKAE_HOME/profiles/claude/$profile/projects/$slug"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"hi"}}\n' "$dir" \
    > "$CLIKAE_HOME/profiles/claude/$profile/projects/$slug/$sid.jsonl"
}

@test "resume finds the tank holding a session id and resumes it there" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="11111111-2222-3333-4444-555555555555"
  _seed_transcript b "$work" "$sid"   # session lives in tank b

  cd "$TEST_HOME"                       # NOT in the session's dir
  unset CLAUDE_CONFIG_DIR
  run clikae resume "$sid"
  [ "$status" -eq 0 ]

  grep -q "ARGS=--resume $sid" "$CLAUDE_STUB_LOG"
  grep -q "CLAUDE_CONFIG_DIR=$CLIKAE_HOME/profiles/claude/b" "$CLAUDE_STUB_LOG"
  # cd'd into the session's recorded directory.
  grep -q "PWD=$work" "$CLAUDE_STUB_LOG"
}

@test "resume errors when the session is in no tank" {
  _install_claude_stub
  clikae init claude a
  run clikae resume "deadbeef-0000-0000-0000-000000000000"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No session"* ]]
  [ ! -f "$CLAUDE_STUB_LOG" ]
}

@test "resume forwards passthrough args after --" {
  _install_claude_stub
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  _seed_transcript a "$work" "$sid"

  cd "$TEST_HOME"
  unset CLAUDE_CONFIG_DIR
  run clikae resume "$sid" -- --model opus
  [ "$status" -eq 0 ]
  grep -q "ARGS=--resume $sid --model opus" "$CLAUDE_STUB_LOG"
}

@test "resume picks the most recent when a session id is in two tanks" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="cccccccc-dddd-eeee-ffff-000000000000"
  _seed_transcript a "$work" "$sid"
  _seed_transcript b "$work" "$sid"
  # Make tank b's copy strictly newer than a's (distinct mtimes, not sub-second ties).
  local slug; slug="$(_slug "$work")"
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/$slug/$sid.jsonl"
  touch -t 202606250000 "$CLIKAE_HOME/profiles/claude/b/projects/$slug/$sid.jsonl"

  cd "$TEST_HOME"
  unset CLAUDE_CONFIG_DIR
  run clikae resume "$sid"
  [ "$status" -eq 0 ]
  grep -q "CLAUDE_CONFIG_DIR=$CLIKAE_HOME/profiles/claude/b" "$CLAUDE_STUB_LOG"
}

@test "resume --help shows usage" {
  run clikae resume --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: clikae resume"* ]]
}

@test "resume is a reserved command (not mistaken for a tank)" {
  run clikae resume "no-such-session-id-xyz"
  [ "$status" -ne 0 ]
  # The error is resume's "No session", not the dispatcher's "Unknown command".
  [[ "$output" == *"No session"* ]]
}
