#!/usr/bin/env bats
# tests/bats/adapters/codex.bats — the codex adapter's session-continuity hooks
# that let codex sessions show up in the board's "Continue" list (HANDOFF §12).
# Sources the adapter directly and feeds it fabricated rollout JSONL; no network,
# no real codex. (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../../helpers'

_setup_codex() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/codex.sh"
  WORK="$TEST_HOME/work"; mkdir -p "$WORK"; cd "$WORK" || return 1
  PROFILE="$TEST_HOME/cprofile"
  SDIR="$PROFILE/sessions"
  mkdir -p "$SDIR/2026/06/03"
}

# seed_rollout <sid> <cwd> <prompt> [hhmmss]
seed_rollout() {
  local sid="$1" cwd="$2" prompt="$3" ts="${4:-10-00-00}"
  local f="$SDIR/2026/06/03/rollout-2026-06-03T$ts-$sid.jsonl"
  {
    printf '{"timestamp":"2026-06-03T01:00:00.000Z","type":"session_meta","payload":{"id":"%s","cwd":"%s","originator":"codex_exec"}}\n' "$sid" "$cwd"
    printf '{"type":"event_msg","payload":{"type":"user_message","message":"%s"}}\n' "$prompt"
  } > "$f"
}

@test "codex recent_sids lists a session whose recorded cwd is the current dir" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-000000000001 "$WORK" "fix the build"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"019e0000-0000-7000-8000-000000000001"* ]] || false
}

@test "codex recent_sids EXCLUDES sessions recorded in a different cwd" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-00000000aaaa "$WORK"        "here"  10-00-00
  seed_rollout 019e0000-0000-7000-8000-00000000bbbb "/somewhere/else" "elsewhere" 11-00-00
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"00000000aaaa"* ]] || false
  [[ "$output" != *"00000000bbbb"* ]] || false
}

@test "codex session_title extracts the user_message prompt" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-00000000cccc "$WORK" "distil the notes"
  run adapter_session_title "$PROFILE" 019e0000-0000-7000-8000-00000000cccc
  [ "$status" -eq 0 ]
  [[ "$output" == *"distil the notes"* ]] || false
}

@test "codex session_title keeps a CJK prompt intact" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-00000000dddd "$WORK" "蒸餾成繁中筆記"
  run adapter_session_title "$PROFILE" 019e0000-0000-7000-8000-00000000dddd
  [ "$status" -eq 0 ]
  [[ "$output" == *"蒸餾成繁中筆記"* ]] || false
}

@test "codex resume_args emits 'resume <sid>'" {
  _setup_codex
  run adapter_resume_args 019e0000-0000-7000-8000-00000000eeee
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume"* ]] || false
  [[ "$output" == *"00000000eeee"* ]] || false
}

@test "codex transcript_path returns the current dir's newest rollout" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-00000000f001 "$WORK" "older" 09-00-00
  seed_rollout 019e0000-0000-7000-8000-00000000f002 "$WORK" "newer" 12-00-00
  run adapter_transcript_path "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"00000000f002"* ]] || false
}

# Regression: a rollout whose recorded cwd carries a TRAILING SLASH must still match
# the current dir (codex normally records no trailing slash, but a path that resolves
# with one would silently drop the session from the board / make resume impossible).
@test "codex cwd match is trailing-slash insensitive (recorded cwd has the slash)" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-0000000000a1 "$WORK/" "slashed cwd"
  run adapter_transcript_path "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0000000000a1"* ]] || false
  run adapter_recent_sids "$PROFILE"
  [[ "$output" == *"0000000000a1"* ]] || false
}

# And the reverse: a still-different cwd must NOT match (the fix must not become a
# loose prefix/substring match — only a trailing slash is normalised away).
@test "codex cwd match still EXCLUDES a genuinely different dir after the fix" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-0000000000b1 "$WORK"          "here"  10-00-00
  seed_rollout 019e0000-0000-7000-8000-0000000000b2 "${WORK}-other/" "there" 11-00-00
  run adapter_recent_sids "$PROFILE"
  [[ "$output" == *"0000000000b1"* ]] || false
  [[ "$output" != *"0000000000b2"* ]] || false
}
