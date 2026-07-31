#!/usr/bin/env bats
# tests/bats/adapters/grok.bats — the grok adapter's session-continuity hooks
# that let grok sessions show up in the board's "Continue" list (HANDOFF §12),
# plus the account label. Sources the adapter directly and feeds it fabricated
# session dirs; no network, no real grok. (`[[ … ]]` carry `|| false`; see
# tests/README.md.)

load '../../helpers'

_setup_grok() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"   # sessions_by_mtime (shared kernel)
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/grok.sh"
  WORK="$TEST_HOME/work"; mkdir -p "$WORK"; cd "$WORK" || return 1
  PROFILE="$TEST_HOME/gprofile"
  SDIR="$PROFILE/sessions"
  mkdir -p "$SDIR"
}

# seed_session <sid> <cwd> <title> [group-dir-name] [touch-stamp]
# Mirrors the real layout: sessions/<url-encoded-cwd>/<uuid>/summary.json, with
# chat_history.jsonl alongside. summary.json is PRETTY-PRINTED, as grok writes it.
seed_session() {
  local sid="$1" cwd="$2" title="$3" group="${4:-%2Fgroup}" stamp="${5:-}"
  local d="$SDIR/$group/$sid"
  mkdir -p "$d"
  cat > "$d/summary.json" <<JSON
{
  "info": {
    "id": "$sid",
    "cwd": "$cwd"
  },
  "session_summary": "$title",
  "created_at": "2026-07-31T10:20:32.668365Z",
  "updated_at": "2026-07-31T10:25:29.952256Z",
  "num_messages": 169,
  "current_model_id": "grok-4.5",
  "request_id": "608a4006-bddd-461d-a3ce-9cac9f6857fa",
  "grok_home": "$PROFILE",
  "generated_title": "$title"
}
JSON
  printf '{"type":"user","content":[{"type":"text","text":"%s"}]}\n' "$title" > "$d/chat_history.jsonl"
  if [ -n "$stamp" ]; then
    touch -t "$stamp" "$d/summary.json" "$d/chat_history.jsonl"
  fi
  return 0
}

@test "grok recent_sids lists a session whose recorded cwd is the current dir" {
  _setup_grok
  seed_session 019fb7b0-9b86-7f82-98a4-000000000001 "$WORK" "fix the build"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"019fb7b0-9b86-7f82-98a4-000000000001"* ]] || false
}

@test "grok recent_sids EXCLUDES sessions recorded in a different cwd" {
  _setup_grok
  seed_session 019fb7b0-9b86-7f82-98a4-00000000aaaa "$WORK"          "here"
  seed_session 019fb7b0-9b86-7f82-98a4-00000000bbbb "/somewhere/else" "elsewhere" "%2Fsomewhere%2Felse"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"00000000aaaa"* ]] || false
  [[ "$output" != *"00000000bbbb"* ]] || false
}

# The group directory is grok's percent-encoding of the cwd, and 17-sessions.md
# documents a slug+hash fallback for long paths. The adapter must match on the
# RECORDED cwd inside summary.json, never on the directory name — otherwise an
# encoder change empties the board silently. Seed a deliberately WRONG group name.
@test "grok matches the recorded cwd, not the encoded group directory name" {
  _setup_grok
  seed_session 019fb7b0-9b86-7f82-98a4-00000000c0de "$WORK" "encoded oddly" "some-slug-a1b2c3d4"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"00000000c0de"* ]] || false
}

@test "grok session_title prefers the generated_title" {
  _setup_grok
  seed_session 019fb7b0-9b86-7f82-98a4-00000000cccc "$WORK" "distil the notes"
  run adapter_session_title "$PROFILE" 019fb7b0-9b86-7f82-98a4-00000000cccc
  [ "$status" -eq 0 ]
  [[ "$output" == *"distil the notes"* ]] || false
}

# Dogfood regression: `/rename` overwrites generated_title and leaves
# session_summary holding the ORIGINAL machine title (verified against a real
# renamed session). Preferring generated_title is therefore what shows the user's
# rename; reversing it would show the stale machine title on every renamed row.
@test "grok title_for_file shows the RENAME, not the machine title, when the two differ" {
  _setup_grok
  local d="$SDIR/%2Fgroup/019fb7b0-9b86-7f82-98a4-00000000re01"
  mkdir -p "$d"
  cat > "$d/summary.json" <<JSON
{
  "info": {
    "id": "019fb7b0-9b86-7f82-98a4-00000000re01",
    "cwd": "$WORK"
  },
  "session_summary": "測試 - Test Query Session",
  "generated_title": "grok test"
}
JSON
  run adapter_title_for_file "$d/summary.json"
  [ "$status" -eq 0 ]
  [ "$output" = "grok test" ]
}

@test "grok title_for_file falls back to session_summary when generated_title is absent" {
  _setup_grok
  local d="$SDIR/%2Fgroup/019fb7b0-9b86-7f82-98a4-00000000fb00"
  mkdir -p "$d"
  cat > "$d/summary.json" <<JSON
{
  "info": {
    "id": "019fb7b0-9b86-7f82-98a4-00000000fb00",
    "cwd": "$WORK"
  },
  "session_summary": "untitled but summarised"
}
JSON
  run adapter_title_for_file "$d/summary.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"untitled but summarised"* ]] || false
}

@test "grok session_title keeps a CJK title intact" {
  _setup_grok
  seed_session 019fb7b0-9b86-7f82-98a4-00000000dddd "$WORK" "蒸餾成繁中筆記"
  run adapter_session_title "$PROFILE" 019fb7b0-9b86-7f82-98a4-00000000dddd
  [ "$status" -eq 0 ]
  [[ "$output" == *"蒸餾成繁中筆記"* ]] || false
}

@test "grok title_for_file keeps a title with escaped quotes intact (no truncation at \\\")" {
  _setup_grok
  local d="$SDIR/%2Fgroup/019fb7b0-9b86-7f82-98a4-00000000ffff"
  mkdir -p "$d"
  cat > "$d/summary.json" <<JSON
{
  "info": {
    "id": "019fb7b0-9b86-7f82-98a4-00000000ffff",
    "cwd": "$WORK"
  },
  "generated_title": "fix the \\"off-by-one\\" bug"
}
JSON
  run adapter_title_for_file "$d/summary.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'fix the "off-by-one" bug'* ]] || false
}

# "id" must not be captured from "request_id" / "current_model_id" — the leading
# quote in the pattern is the whole defence, so prove it fires by putting those
# fields FIRST, where a loose match would win.
@test "grok sid extraction is not confused by request_id / current_model_id" {
  _setup_grok
  local d="$SDIR/%2Fgroup/019fb7b0-9b86-7f82-98a4-00000000dead"
  mkdir -p "$d"
  cat > "$d/summary.json" <<JSON
{
  "request_id": "aaaaaaaa-0000-0000-0000-000000000000",
  "current_model_id": "grok-4.5",
  "info": {
    "id": "019fb7b0-9b86-7f82-98a4-00000000dead",
    "cwd": "$WORK"
  },
  "generated_title": "ordering trap"
}
JSON
  printf '{"type":"user"}\n' > "$d/chat_history.jsonl"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"00000000dead"* ]] || false
  [[ "$output" != *"aaaaaaaa-0000"* ]] || false
}

@test "grok resume_args emits '--resume <sid>'" {
  _setup_grok
  run adapter_resume_args 019fb7b0-9b86-7f82-98a4-00000000eeee
  [ "$status" -eq 0 ]
  [[ "$output" == *"--resume"* ]] || false
  [[ "$output" == *"00000000eeee"* ]] || false
}

@test "grok transcript_path returns the current dir's newest chat_history.jsonl" {
  _setup_grok
  seed_session 019fb7b0-9b86-7f82-98a4-00000000f001 "$WORK" "older" "%2Fgroup" 202606030900
  seed_session 019fb7b0-9b86-7f82-98a4-00000000f002 "$WORK" "newer" "%2Fgroup" 202606031200
  run adapter_transcript_path "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"00000000f002"* ]] || false
  [[ "$output" == *"chat_history.jsonl"* ]] || false
}

@test "grok find_session + session_cwd round-trip an id back to its directory" {
  _setup_grok
  seed_session 019fb7b0-9b86-7f82-98a4-00000000ab12 "$WORK" "round trip"
  run adapter_find_session "$PROFILE" 019fb7b0-9b86-7f82-98a4-00000000ab12
  [ "$status" -eq 0 ]
  [[ "$output" == *"00000000ab12/summary.json"* ]] || false
  local f="$output"
  run adapter_session_cwd "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$WORK" ]
}

# Regression: a session whose recorded cwd carries a TRAILING SLASH must still
# match the current dir, or it silently drops off the board / can't be resumed.
@test "grok cwd match is trailing-slash insensitive (recorded cwd has the slash)" {
  _setup_grok
  seed_session 019fb7b0-9b86-7f82-98a4-0000000000a1 "$WORK/" "slashed cwd"
  run adapter_transcript_path "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0000000000a1"* ]] || false
  run adapter_recent_sids "$PROFILE"
  [[ "$output" == *"0000000000a1"* ]] || false
}

# And the reverse: a genuinely different dir must NOT match (the normalisation
# must not become a loose prefix/substring match).
@test "grok cwd match still EXCLUDES a genuinely different dir after the fix" {
  _setup_grok
  seed_session 019fb7b0-9b86-7f82-98a4-0000000000b1 "$WORK"          "here"
  seed_session 019fb7b0-9b86-7f82-98a4-0000000000b2 "${WORK}-other/" "there" "%2Fother"
  run adapter_recent_sids "$PROFILE"
  [[ "$output" == *"0000000000b1"* ]] || false
  [[ "$output" != *"0000000000b2"* ]] || false
}

@test "grok recent_sids survives a CLIKAE_HOME path containing a space" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/grok.sh"
  WORK="$TEST_HOME/spaced work"; mkdir -p "$WORK"; cd "$WORK" || return 1
  PROFILE="$TEST_HOME/dir with space/gprofile"
  SDIR="$PROFILE/sessions"
  mkdir -p "$SDIR"
  seed_session 019fb7b0-9b86-7f82-98a4-000000000abc "$WORK" "prompt in spaced home"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"000000000abc"* ]] || false
}

@test "grok account_label reads the email straight out of auth.json" {
  _setup_grok
  cat > "$PROFILE/auth.json" <<'JSON'
{
  "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": {
    "key": "redacted",
    "auth_mode": "oidc",
    "email": "tank@example.com",
    "first_name": "Test"
  }
}
JSON
  run adapter_account_label "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$output" = "tank@example.com" ]
}

@test "grok account_label stays silent (status 0) when there is no auth.json" {
  _setup_grok
  run adapter_account_label "$PROFILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "grok export_env / run point GROK_HOME at the profile dir" {
  _setup_grok
  run adapter_export_env "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$output" = "GROK_HOME=$PROFILE" ]
}

@test "grok memory pointer lands on GROK_HOME/AGENTS.md (grok's global rules file)" {
  _setup_grok
  run adapter_memory_pointer_path "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROFILE/AGENTS.md" ]
}

@test "grok burn_flags carry --cwd, bypassPermissions, the workspace sandbox and -p" {
  _setup_grok
  run bash -c '. "'"$CLIKAE_TEST_ROOT"'/lib/adapters/grok.sh"; adapter_burn_flags "ship it" "/tmp/repo" | tr "\0" "\n"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"--cwd"* ]] || false
  [[ "$output" == *"/tmp/repo"* ]] || false
  [[ "$output" == *"bypassPermissions"* ]] || false
  [[ "$output" == *"workspace"* ]] || false
  [[ "$output" == *"ship it"* ]] || false
}

@test "grok burn_flags keep a MULTI-LINE prompt as one argv item" {
  _setup_grok
  run bash -c '. "'"$CLIKAE_TEST_ROOT"'/lib/adapters/grok.sh"; adapter_burn_flags "line one
line two" | tr "\0" "\a" | tr "\n" "@"'
  [ "$status" -eq 0 ]
  # The newline must survive INSIDE an item (\a-delimited), never as a separator.
  [[ "$output" == *"line one@line two"* ]] || false
}

@test "grok audit_flags are read-only: read-only sandbox AND the mutating tools removed" {
  _setup_grok
  run bash -c '. "'"$CLIKAE_TEST_ROOT"'/lib/adapters/grok.sh"; adapter_audit_flags "review this" "/tmp/repo" | tr "\0" "\n"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"read-only"* ]] || false
  [[ "$output" == *"--disallowed-tools"* ]] || false
  [[ "$output" == *"run_terminal_cmd"* ]] || false
  [[ "$output" != *"workspace"* ]] || false
}
