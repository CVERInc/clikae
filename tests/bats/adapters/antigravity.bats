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

seed_agy_summaries() {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 required for fixture database"
  sqlite3 "$PROFILE/antigravity-cli/conversation_summaries.db" "
    CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, last_modified_time INTEGER);
    INSERT INTO conversation_summaries VALUES ('ag-title', '  Discord   權限' || char(10) || char(9) || '設定建議  ', 1);
    INSERT INTO conversation_summaries VALUES ('ag-empty', '', 1);
    INSERT INTO conversation_summaries VALUES ('ag-ws', '   ', 1);
    INSERT INTO conversation_summaries VALUES ('ag-quote''id', 'Quoted ID title', 1);
  "
}

assert_agy_title() {
  local sid="$1" expected="$2"
  run adapter_session_title "$PROFILE" "$sid"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  run adapter_title_for_file "$BRAIN/$sid/.system_generated/logs/transcript.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "antigravity summary title wins and both hooks collapse whitespace" {
  _setup_agy
  seed_agy_session ag-title "$WORK" "opening prompt"
  seed_agy_summaries
  assert_agy_title ag-title "Discord 權限 設定建議"
}

@test "antigravity empty summary title falls back to opening prompt" {
  _setup_agy
  seed_agy_session ag-empty "$WORK" '<USER_REQUEST>  opening\n  prompt  </USER_REQUEST>'
  seed_agy_summaries
  assert_agy_title ag-empty "opening prompt"
}

@test "antigravity missing summary row falls back to opening prompt" {
  _setup_agy
  seed_agy_session ag-missing "$WORK" "opening prompt"
  seed_agy_summaries
  assert_agy_title ag-missing "opening prompt"
}

@test "antigravity no database falls back without creating a database" {
  _setup_agy
  seed_agy_session ag-title "$WORK" "opening prompt"
  assert_agy_title ag-title "opening prompt"
  [ ! -e "$PROFILE/antigravity-cli/conversation_summaries.db" ]
}

# This exercises the fallback path when sqlite3 is entirely absent, not the
# `command -v sqlite3` gate specifically: `2>/dev/null` + `|| t=""` on the
# sqlite3 call already swallow a "command not found" the same way, so with no
# sqlite3 anywhere on PATH the gate's presence or absence is unobservable from
# output alone (removing it costs an extra failed fork, nothing else).
@test "antigravity falls back cleanly when sqlite3 is entirely unavailable" {
  _setup_agy
  seed_agy_session ag-title "$WORK" "opening prompt"
  seed_agy_summaries
  local limited_path="$TEST_HOME/no-sqlite" tool
  mkdir -p "$limited_path"
  for tool in head grep sed tr; do
    ln -s "$(command -v "$tool")" "$limited_path/$tool"
  done
  # Scope PATH to the adapter, leaving bats and teardown's tools available.
  run env PATH="$limited_path" /bin/bash -c '
    source "$1"
    ! command -v sqlite3 || exit 1
    adapter_session_title "$2" ag-title
  ' bash "$CLIKAE_TEST_ROOT/lib/adapters/antigravity.sh" "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$output" = "opening prompt" ]
}

@test "antigravity summary lookup escapes quoted conversation IDs" {
  _setup_agy
  seed_agy_session "ag-quote'id" "$WORK" "opening prompt"
  seed_agy_summaries
  assert_agy_title "ag-quote'id" "Quoted ID title"
}

@test "antigravity unreadable summary database falls back without an error" {
  _setup_agy
  seed_agy_session ag-title "$WORK" "opening prompt"
  printf 'not a database\n' > "$PROFILE/antigravity-cli/conversation_summaries.db"
  assert_agy_title ag-title "opening prompt"
}

@test "antigravity whitespace-only summary title falls back to opening prompt" {
  _setup_agy
  seed_agy_session ag-ws "$WORK" "opening prompt"
  seed_agy_summaries
  assert_agy_title ag-ws "opening prompt"
}

@test "antigravity summary title with backslashes and quotes round-trips byte-identical" {
  _setup_agy
  seed_agy_session ag-esc "$WORK" "opening prompt"
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 required for fixture database"
  sqlite3 "$PROFILE/antigravity-cli/conversation_summaries.db" "
    CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, last_modified_time INTEGER);
    INSERT INTO conversation_summaries VALUES ('ag-esc', 'Fix C:\temp\notes.txt say \\\"hi\\\" and \n keep it', 1);
  "
  assert_agy_title ag-esc 'Fix C:\temp\notes.txt say \"hi\" and \n keep it'
}

@test "antigravity summary lookup with duplicate conversation_id picks the newest row" {
  _setup_agy
  seed_agy_session ag-dup "$WORK" "opening prompt"
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 required for fixture database"
  sqlite3 "$PROFILE/antigravity-cli/conversation_summaries.db" "
    CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT, last_modified_time INTEGER);
    INSERT INTO conversation_summaries VALUES ('ag-dup', 'OLD TITLE', 1);
    INSERT INTO conversation_summaries VALUES ('ag-dup', 'NEW TITLE', 2);
  "
  assert_agy_title ag-dup "NEW TITLE"
}

@test "antigravity summary lookup always passes -readonly to sqlite3 (mutation guard)" {
  _setup_agy
  seed_agy_session ag-title "$WORK" "opening prompt"
  seed_agy_summaries
  local real_sqlite3
  real_sqlite3="$(command -v sqlite3)" || skip "sqlite3 required for fixture database"
  local stub_bin="$TEST_HOME/stub-bin" argv_log="$TEST_HOME/sqlite3.argv"
  mkdir -p "$stub_bin"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$argv_log"
    printf 'exec "%s" "$@"\n' "$real_sqlite3"
  } > "$stub_bin/sqlite3"
  chmod +x "$stub_bin/sqlite3"
  run env PATH="$stub_bin:$PATH" /bin/bash -c '
    source "$1"
    adapter_title_for_file "$2"
  ' bash "$CLIKAE_TEST_ROOT/lib/adapters/antigravity.sh" "$BRAIN/ag-title/.system_generated/logs/transcript.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "Discord 權限 設定建議" ]
  [ -f "$argv_log" ]
  run grep -- -readonly "$argv_log"
  [ "$status" -eq 0 ]
}
