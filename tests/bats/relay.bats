#!/usr/bin/env bats
# tests/bats/relay.bats — `clikae relay`
#
# relay exec's the target CLI, so we put a stub `claude` on PATH that records its
# argv + CLAUDE_CONFIG_DIR to a log file and exits, instead of the real binary.

load '../helpers'

# Install a fake `claude` on PATH. Writes argv/env to $CLAUDE_STUB_LOG.
_install_claude_stub() {
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/claude" <<'STUB'
#!/usr/bin/env bash
{
  echo "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
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

# Seed a transcript for <profile> covering directory <dir>.
_seed_transcript() {
  local profile="$1" dir="$2" sid="$3"
  local slug; slug="$(_slug "$dir")"
  mkdir -p "$CLIKAE_HOME/profiles/claude/$profile/projects/$slug"
  echo '{"type":"user","text":"hi"}' \
    > "$CLIKAE_HOME/profiles/claude/$profile/projects/$slug/$sid.jsonl"
}

@test "relay copies the current dir's transcript into the target and resumes it" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="11111111-2222-3333-4444-555555555555"
  _seed_transcript a "$work" "$sid"

  cd "$work"
  unset CLAUDE_CONFIG_DIR
  run clikae relay claude a b
  [ "$status" -eq 0 ]

  # Resumed the right session under profile b's config dir.
  grep -q "ARGS=--resume $sid" "$CLAUDE_STUB_LOG"
  grep -q "CLAUDE_CONFIG_DIR=$CLIKAE_HOME/profiles/claude/b" "$CLAUDE_STUB_LOG"

  # Transcript now present under b, and still present under a (non-destructive).
  local slug; slug="$(_slug "$work")"
  [ -f "$CLIKAE_HOME/profiles/claude/b/projects/$slug/$sid.jsonl" ]
  [ -f "$CLIKAE_HOME/profiles/claude/a/projects/$slug/$sid.jsonl" ]
}

@test "relay auto-detects the source profile from CLAUDE_CONFIG_DIR" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  _seed_transcript a "$work" "$sid"

  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae relay claude b
  [ "$status" -eq 0 ]
  grep -q "ARGS=--resume $sid" "$CLAUDE_STUB_LOG"
}

@test "relay starts fresh when there is no transcript to carry" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local empty="$TEST_HOME/empty"; mkdir -p "$empty"

  cd "$empty"
  unset CLAUDE_CONFIG_DIR
  run clikae relay claude a b
  [ "$status" -eq 0 ]
  # No --resume: a plain run under b.
  grep -q "ARGS=$" "$CLAUDE_STUB_LOG"
  grep -q "CLAUDE_CONFIG_DIR=$CLIKAE_HOME/profiles/claude/b" "$CLAUDE_STUB_LOG"
}

@test "relay refuses when source and target are the same" {
  _install_claude_stub
  clikae init claude a
  run clikae relay claude a a
  [ "$status" -ne 0 ]
  [[ "$output" == *"same profile"* ]]
}

@test "relay errors when a named profile does not exist" {
  _install_claude_stub
  clikae init claude a
  run clikae relay claude a nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "relay can't auto-detect source errors helpfully" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  unset CLAUDE_CONFIG_DIR
  run clikae relay claude b
  [ "$status" -ne 0 ]
  [[ "$output" == *"explicitly"* ]]
}
