#!/usr/bin/env bats
# tests/bats/adapters/antigravity.bats — the antigravity (agy) adapter's
# session-continuity hooks (mirrors adapters/codex.bats). Sources the adapter
# directly and feeds it fabricated brain/history files; no network, no real agy.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../../helpers'

_setup_agy() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"   # sessions_by_mtime (shared kernel)
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/antigravity.sh"
  WORK="$TEST_HOME/work"; mkdir -p "$WORK"; cd "$WORK" || return 1
  PROFILE="$TEST_HOME/aprofile"
  BRAIN="$PROFILE/antigravity-cli/brain"
  mkdir -p "$BRAIN"
}

# seed_agy_session <sid> <cwd> <content>
seed_agy_session() {
  local sid="$1" cwd="$2" content="$3"
  local sdir="$BRAIN/$sid/.system_generated/logs"
  mkdir -p "$sdir"
  printf '{"role":"user","content":"%s"}\n' "$content" > "$sdir/transcript.jsonl"
  printf '{"sessionId":"%s","workspace":"%s"}\n' "$sid" "$cwd" >> "$BRAIN/history.jsonl"
}

@test "antigravity recent_sids lists a session whose recorded cwd is the current dir" {
  _setup_agy
  seed_agy_session ag-0001 "$WORK" "fix the build"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ag-0001"* ]] || false
}

@test "antigravity recent_sids EXCLUDES sessions recorded in a different cwd" {
  _setup_agy
  seed_agy_session ag-aaaa "$WORK" "here"
  seed_agy_session ag-bbbb "/somewhere/else" "elsewhere"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ag-aaaa"* ]] || false
  [[ "$output" != *"ag-bbbb"* ]] || false
}

@test "antigravity recent_sids: no brain dir at all -> empty, not an error" {
  _setup_agy
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "antigravity session_title extracts the opening USER_REQUEST" {
  _setup_agy
  seed_agy_session ag-cccc "$WORK" "<USER_REQUEST>distil the notes</USER_REQUEST>"
  run adapter_session_title "$PROFILE" ag-cccc
  [ "$status" -eq 0 ]
  [[ "$output" == *"distil the notes"* ]] || false
}

# --- 2026-09-06 report: the home board's Live row for an agy tank showed a
# bare `""` — no fallback at all, the only engine on the board with none.
# codex/claude/grok all land on "(no preview)" via their own
# adapter_title_for_file; antigravity's never had the fallback line. ----------
@test "antigravity title_for_file falls back to (no preview) when nothing is extractable" {
  _setup_agy
  local sid="ag-dddd" sdir
  sdir="$BRAIN/$sid/.system_generated/logs"
  mkdir -p "$sdir"
  printf '{"role":"assistant","note":"no content field here"}\n' > "$sdir/transcript.jsonl"
  run adapter_title_for_file "$sdir/transcript.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "(no preview)" ] || { echo "got: '$output'"; false; }
}

@test "antigravity session_title falls back to (no preview) too (not just title_for_file)" {
  _setup_agy
  seed_agy_session ag-eeee "$WORK" ""
  run adapter_session_title "$PROFILE" ag-eeee
  [ "$status" -eq 0 ]
  [ "$output" = "(no preview)" ] || { echo "got: '$output'"; false; }
}

@test "antigravity title_for_file on a missing file returns nothing (not an error, not the fallback)" {
  _setup_agy
  run adapter_title_for_file "$BRAIN/does-not-exist/transcript.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # adapter_session_title itself supplies no id -> also nothing; the
                      # (no preview) fallback is for a REAL, readable-but-empty transcript
}
