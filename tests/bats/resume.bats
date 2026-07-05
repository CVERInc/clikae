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

# Bring _resume_carry_session (lib/core/session_carry.sh) and its dependencies
# into THIS bats process, in the same order bin/clikae sources them — needed only
# by tests that call it directly rather than through a `clikae` subprocess.
_source_session_carry() {
  CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  # shellcheck source=../../lib/core/log.sh
  source "$CLIKAE_LIB/core/log.sh"
  # shellcheck source=../../lib/core/profile_store.sh
  source "$CLIKAE_LIB/core/profile_store.sh"
  # shellcheck source=../../lib/core/adapter_loader.sh
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  # shellcheck source=../../lib/core/history.sh
  source "$CLIKAE_LIB/core/history.sh"
  # shellcheck source=../../lib/core/session_carry.sh
  source "$CLIKAE_LIB/core/session_carry.sh"
}

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

# --- resume ask-tank (lib/core/resume_settings.sh) -----------------------------

@test "resume ask-tank defaults to always, with no setting file" {
  run clikae resume ask-tank
  [ "$status" -eq 0 ]
  [[ "$output" == *"always"* ]]
  [ ! -f "$CLIKAE_HOME/resume-ask-tank" ]
}

@test "resume ask-tank <value> persists and reports back" {
  run clikae resume ask-tank dry-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-only"* ]]
  [ "$(cat "$CLIKAE_HOME/resume-ask-tank")" = "dry-only" ]
  run clikae resume ask-tank
  [[ "$output" == *"dry-only"* ]]
}

@test "resume ask-tank rejects an unknown value" {
  run clikae resume ask-tank sometimes
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown choice"* ]]
}

# --- _resume_carry_session (lib/core/session_carry.sh) -------------------------
# Unit-level: the shared cross-tank session copy, exercised directly (no TTY
# needed) so both `clikae resume`'s picker and the home board's carry action are
# covered by testing the one function they both call.

@test "_resume_carry_session copies a claude transcript into the target tank, source untouched" {
  _source_session_carry
  clikae init claude a >/dev/null
  clikae init claude b >/dev/null
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="cccccccc-1111-2222-3333-444444444444"
  _seed_transcript a "$work" "$sid"
  cd "$TEST_HOME"; load_adapter claude
  _resume_carry_session claude a b "$sid"
  [ -f "$CLIKAE_HOME/profiles/claude/b/projects/$(_slug "$work")/$sid.jsonl" ]
  [ -f "$CLIKAE_HOME/profiles/claude/a/projects/$(_slug "$work")/$sid.jsonl" ]   # source untouched
}

@test "_resume_carry_session copies a codex rollout into the target tank" {
  _source_session_carry
  clikae init codex a >/dev/null
  clikae init codex b >/dev/null
  local sid="dddddddd-1111-2222-3333-444444444444"
  local rdir="$CLIKAE_HOME/profiles/codex/a/sessions/2026/07/05"
  mkdir -p "$rdir"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$sid" "$TEST_HOME" \
    > "$rdir/rollout-2026-07-05T00-00-00-$sid.jsonl"
  load_adapter codex
  _resume_carry_session codex a b "$sid"
  find "$CLIKAE_HOME/profiles/codex/b/sessions" -name "*$sid.jsonl" | grep -q .
  find "$CLIKAE_HOME/profiles/codex/a/sessions" -name "*$sid.jsonl" | grep -q .   # source untouched
}

@test "_resume_carry_session copies antigravity brain + conversation db into the target tank" {
  _source_session_carry
  local sid="eeeeeeee-1111-2222-3333-444444444444"
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/brain/$sid"
  echo "note" > "$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/brain/$sid/note.txt"
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/conversations"
  echo "db" > "$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/conversations/$sid.db"
  _resume_carry_session antigravity a b "$sid"
  [ -f "$CLIKAE_HOME/profiles/antigravity/b/antigravity-cli/brain/$sid/note.txt" ]
  [ -f "$CLIKAE_HOME/profiles/antigravity/b/antigravity-cli/conversations/$sid.db" ]
  [ -f "$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/brain/$sid/note.txt" ]   # source untouched
}

@test "_resume_carry_session is a safe no-op when there's nothing to find" {
  _source_session_carry
  clikae init claude a >/dev/null
  clikae init claude b >/dev/null
  load_adapter claude
  run _resume_carry_session claude a b "no-such-session"
  [ "$status" -eq 0 ]
}
