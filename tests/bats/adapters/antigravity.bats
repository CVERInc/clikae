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
  . "$CLIKAE_TEST_ROOT/lib/core/json.sh"            # json_value_for_key (cache lookup)
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

# --- scope: this directory first, the tank only as a fallback ----------------
# #34's finding stands — workspace is a constant ($HOME) on every real agy
# install (607/607 indexed conversations, one distinct value), so a STRICT cwd
# filter leaves this list empty in any project directory. #34 answered by
# dropping the filter; that made agy's rows mean something different from
# every other engine's in one shared, ranked list, and agy crowded them out.
# The filter is back WITH a fallback: scoped when this directory has anything,
# tank-wide when it has nothing. See docs/EXPECTATIONS.md "Engines on one
# board".
@test "antigravity recent_sids keeps THIS directory's sessions when it has any" {
  _setup_agy
  seed_agy_session ag-aaaa "$WORK" "here"
  seed_agy_session ag-bbbb "/somewhere/else" "elsewhere"
  run adapter_recent_sids "$PROFILE" 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"ag-aaaa"* ]] || { echo "got: $output"; false; }
  [[ "$output" != *"ag-bbbb"* ]] || { echo "not scoped: $output"; false; }
}

@test "antigravity recent_sids falls back to the whole tank when this directory has none (#34)" {
  _setup_agy
  seed_agy_session ag-aaaa "/one/place" "there"
  seed_agy_session ag-bbbb "/somewhere/else" "elsewhere"
  run adapter_recent_sids "$PROFILE" 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"ag-aaaa"* ]] || { echo "got: $output"; false; }
  [[ "$output" == *"ag-bbbb"* ]] || { echo "got: $output"; false; }
}

@test "antigravity recent_sids: newest-first, capped at limit, within this directory" {
  _setup_agy
  seed_agy_session ag-old "$WORK" "oldest"
  touch -t 202001010000 "$BRAIN/ag-old/.system_generated/logs/transcript.jsonl"
  seed_agy_session ag-mid "$WORK" "middle"
  touch -t 202101010000 "$BRAIN/ag-mid/.system_generated/logs/transcript.jsonl"
  seed_agy_session ag-new "$WORK" "newest"
  touch -t 202201010000 "$BRAIN/ag-new/.system_generated/logs/transcript.jsonl"

  run adapter_recent_sids "$PROFILE" 2
  [ "$status" -eq 0 ]
  local first second
  first="$(printf '%s\n' "$output" | sed -n 1p | cut -d$'\037' -f2)"
  second="$(printf '%s\n' "$output" | sed -n 2p | cut -d$'\037' -f2)"
  [ "$first" = "ag-new" ] || { echo "got: $output"; false; }
  [ "$second" = "ag-mid" ] || { echo "got: $output"; false; }
  [[ "$output" != *"ag-old"* ]] || false
}

@test "antigravity recent_sids: the fallback is ranked and capped the same way" {
  _setup_agy
  seed_agy_session ag-old "/elsewhere" "oldest"
  touch -t 202001010000 "$BRAIN/ag-old/.system_generated/logs/transcript.jsonl"
  seed_agy_session ag-mid "/elsewhere" "middle"
  touch -t 202101010000 "$BRAIN/ag-mid/.system_generated/logs/transcript.jsonl"
  seed_agy_session ag-new "/somewhere/else" "newest"
  touch -t 202201010000 "$BRAIN/ag-new/.system_generated/logs/transcript.jsonl"

  run adapter_recent_sids "$PROFILE" 2
  [ "$status" -eq 0 ]
  local first second
  first="$(printf '%s\n' "$output" | sed -n 1p | cut -d$'\037' -f2)"
  second="$(printf '%s\n' "$output" | sed -n 2p | cut -d$'\037' -f2)"
  [ "$first" = "ag-new" ] || { echo "got: $output"; false; }
  [ "$second" = "ag-mid" ] || { echo "got: $output"; false; }
  [[ "$output" != *"ag-old"* ]] || false
}

@test "antigravity recent_sids: a cache entry pointing at a deleted brain dir is skipped, not an error (#34)" {
  _setup_agy
  seed_agy_session ag-real "$WORK" "still here"
  mkdir -p "$PROFILE/antigravity-cli/cache"
  printf '{"%s":"%s"}\n' "$WORK" "ag-ghost-deleted" > "$PROFILE/antigravity-cli/cache/last_conversations.json"
  run adapter_recent_sids "$PROFILE" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ag-real"* ]] || { echo "got: $output"; false; }
  [[ "$output" != *"ag-ghost"* ]] || false
}

@test "antigravity recent_sids: a present cache does not truncate a multi-row request (#34)" {
  _setup_agy
  seed_agy_session ag-one "$WORK" "one"
  # Both in THIS directory: what this test is about is the cache hit not
  # short-circuiting a multi-row ask, not the cwd scope (its own tests, above).
  seed_agy_session ag-two "$WORK" "two"
  mkdir -p "$PROFILE/antigravity-cli/cache"
  printf '{"%s":"%s"}\n' "$WORK" "ag-one" > "$PROFILE/antigravity-cli/cache/last_conversations.json"
  run adapter_recent_sids "$PROFILE" 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"ag-one"* ]] || { echo "got: $output"; false; }
  [[ "$output" == *"ag-two"* ]] || { echo "got: $output"; false; }
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

# --- #74 round-1 P1-1: one canonical sid derivation, shared by burn's sidecar
# writer and resume's picker. ---

@test "antigravity adapter_sid_canonical is the brain/<sid>/ directory name" {
  _setup_agy
  seed_agy_session ag-canon "$WORK" "hi"
  run adapter_sid_canonical "$BRAIN/ag-canon/.system_generated/logs/transcript.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "ag-canon" ]
}

@test "antigravity adapter_all_transcripts lists every session's transcript under a profile dir" {
  _setup_agy
  seed_agy_session ag-one "$WORK" "one"
  seed_agy_session ag-two "/elsewhere" "two"
  run adapter_all_transcripts "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ag-one"* ]] || false
  [[ "$output" == *"ag-two"* ]] || false
}

# --- #74 round-1 P1-4: the cache extraction used to be a greedy `.*:` sed
# walk over the whole MATCHED LINE — on a real (compact, single-line) cache
# with more than one project's pointer, it silently returned whichever `: "`
# came LAST in the file, not the one for the matched key. -------------------

@test "antigravity cache lookup returns THIS cwd's sid, not a later key's, from a compact multi-entry cache" {
  _setup_agy
  local sid_here="ag-here-0001" sid_other="ag-other-0002"
  local other_dir="$TEST_HOME/other-project"
  mkdir -p "$BRAIN/$sid_here/.system_generated/logs" "$BRAIN/$sid_other/.system_generated/logs"
  printf '{"content":"here"}\n'  > "$BRAIN/$sid_here/.system_generated/logs/transcript.jsonl"
  printf '{"content":"other"}\n' > "$BRAIN/$sid_other/.system_generated/logs/transcript.jsonl"
  mkdir -p "$PROFILE/antigravity-cli/cache"
  # ONE line, WORK's entry first, the other project's entry (and thus the
  # LAST "\"…\":\"…\"" in the file) second — exactly the shape a naive
  # greedy `.*:` walk gets wrong regardless of which key actually matched.
  printf '{"%s":"%s","%s":"%s"}\n' "$WORK" "$sid_here" "$other_dir" "$sid_other" \
    > "$PROFILE/antigravity-cli/cache/last_conversations.json"
  # limit=1 isolates the cache fast path (returns immediately on the anchored
  # hit, never reaching the disk scan below) — #34 made recent_sids
  # tank-scoped, so at limit>1 sid_other's OWN session would legitimately
  # appear too (it has its own real transcript in this tank); that is no
  # longer evidence of a mis-anchored cache read, so it can't be asserted
  # away here. What this test still pins is the cache extraction itself:
  # the anchored lookup must resolve $want to sid_here, not sid_other.
  run adapter_recent_sids "$PROFILE" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"$sid_here"* ]] || false
  [[ "$output" != *"$sid_other"* ]] || false
}

@test "antigravity cache lookup: order reversed still returns THIS cwd's sid" {
  _setup_agy
  local sid_here="ag-here-0003" sid_other="ag-other-0004"
  local other_dir="$TEST_HOME/other-project-2"
  mkdir -p "$BRAIN/$sid_here/.system_generated/logs" "$BRAIN/$sid_other/.system_generated/logs"
  printf '{"content":"here"}\n'  > "$BRAIN/$sid_here/.system_generated/logs/transcript.jsonl"
  printf '{"content":"other"}\n' > "$BRAIN/$sid_other/.system_generated/logs/transcript.jsonl"
  mkdir -p "$PROFILE/antigravity-cli/cache"
  # This cwd's entry LAST this time — the old bug's "return whatever's last"
  # shape would have passed this ordering by accident; both orderings must work.
  printf '{"%s":"%s","%s":"%s"}\n' "$other_dir" "$sid_other" "$WORK" "$sid_here" \
    > "$PROFILE/antigravity-cli/cache/last_conversations.json"
  # limit=1: see the sibling test above — isolates the cache extraction from
  # #34's tank-scoped disk scan, which would otherwise legitimately surface
  # sid_other's own session too.
  run adapter_recent_sids "$PROFILE" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"$sid_here"* ]] || false
  [[ "$output" != *"$sid_other"* ]] || false
}

# --- #74 round-1 P2-1: a cache hit used to `return 0` immediately, so any
# limit greater than 1 still got back exactly one row — the board's Continue
# list (limit 10) and its exclusion-pass retries (home.sh:330/437, also
# limit 10) silently collapsed to at most one agy candidate no matter how
# many real sessions this directory actually had. -----------------------------

@test "antigravity recent_sids with limit>1 returns the cached hit PLUS the rest from disk, not just the cached one" {
  _setup_agy
  local sid_cached="ag-cached-01"
  seed_agy_session "$sid_cached" "$WORK" "cached pointer"
  mkdir -p "$PROFILE/antigravity-cli/cache"
  printf '{"%s":"%s"}\n' "$WORK" "$sid_cached" > "$PROFILE/antigravity-cli/cache/last_conversations.json"
  # Three MORE real sessions in this same directory that the cache never
  # learned about (a stale/not-yet-refreshed pointer is the normal case).
  seed_agy_session ag-disk-01 "$WORK" "disk only 1"
  seed_agy_session ag-disk-02 "$WORK" "disk only 2"
  seed_agy_session ag-disk-03 "$WORK" "disk only 3"
  run adapter_recent_sids "$PROFILE" 10
  [ "$status" -eq 0 ]
  local n; n="$(printf '%s\n' "$output" | grep -c .)"
  [ "$n" -eq 4 ]
  [[ "$output" == *"$sid_cached"* ]] || false
  [[ "$output" == *"ag-disk-01"* ]] || false
  [[ "$output" == *"ag-disk-02"* ]] || false
  [[ "$output" == *"ag-disk-03"* ]] || false
  # The cached one is not ALSO re-discovered by the disk scan (no duplicate line).
  local hits; hits="$(printf '%s\n' "$output" | grep -c "$sid_cached")"
  [ "$hits" -eq 1 ]
}

@test "antigravity recent_sids with limit=1 keeps the original single-stat cache fast path" {
  _setup_agy
  local sid_cached="ag-cached-02"
  seed_agy_session "$sid_cached" "$WORK" "cached pointer"
  mkdir -p "$PROFILE/antigravity-cli/cache"
  printf '{"%s":"%s"}\n' "$WORK" "$sid_cached" > "$PROFILE/antigravity-cli/cache/last_conversations.json"
  seed_agy_session ag-disk-04 "$WORK" "disk only"
  run adapter_recent_sids "$PROFILE" 1
  [ "$status" -eq 0 ]
  local n; n="$(printf '%s\n' "$output" | grep -c .)"
  [ "$n" -eq 1 ]
  [[ "$output" == *"$sid_cached"* ]] || false
}

@test "antigravity recent_sids with limit>1 still caps at limit across cache+disk" {
  _setup_agy
  local sid_cached="ag-cached-03"
  seed_agy_session "$sid_cached" "$WORK" "cached pointer"
  mkdir -p "$PROFILE/antigravity-cli/cache"
  printf '{"%s":"%s"}\n' "$WORK" "$sid_cached" > "$PROFILE/antigravity-cli/cache/last_conversations.json"
  seed_agy_session ag-disk-05 "$WORK" "d1"
  seed_agy_session ag-disk-06 "$WORK" "d2"
  seed_agy_session ag-disk-07 "$WORK" "d3"
  run adapter_recent_sids "$PROFILE" 2
  [ "$status" -eq 0 ]
  local n; n="$(printf '%s\n' "$output" | grep -c .)"
  [ "$n" -eq 2 ]
}

# --- #34 round-1 P2-2: the two P1-4 anchoring tests above were narrowed to
# limit=1 (tank-scoping made their limit=5 exclusion assertion untrue), and
# nothing replaced them at limit>1. Every other cache test at limit>1 checks
# only PRESENCE or a line count — so "a stale cache pointer never beats disk
# truth" had no test there at all, and the review's M2 mutant (make the cached
# sid sort first and take a slot, whatever its mtime) survived the whole suite
# green. At limit>1 a mis-anchored or stale cache read cannot change the
# output SET any more (the disk scan sweeps the tank and dedups), so ORDER and
# WHO GETS SQUEEZED OUT are the only faces left where it can go wrong — this
# is the test for that face. ------------------------------------------------

@test "antigravity recent_sids at limit=5: a stale cache pointer does not beat disk mtime order (#34 P2-2)" {
  _setup_agy
  local i sid
  for i in 1 2 3 4 5; do
    sid="ag-rank-0$i"
    seed_agy_session "$sid" "$WORK" "rank $i"
    touch -t "20200101000$i" "$BRAIN/$sid/.system_generated/logs/transcript.jsonl"
  done
  mkdir -p "$PROFILE/antigravity-cli/cache"
  # The normal stale case: the CLI wrote this pointer for $WORK, and four
  # newer sessions have happened on the tank since.
  printf '{"%s":"%s"}\n' "$WORK" "ag-rank-01" \
    > "$PROFILE/antigravity-cli/cache/last_conversations.json"
  run adapter_recent_sids "$PROFILE" 5
  [ "$status" -eq 0 ]
  # Exact mtime order, newest first — and the cache's own sid in its TRUE
  # position (last, because it is the oldest), not promoted to the front.
  local got
  got="$(printf '%s\n' "$output" | cut -d$'\037' -f2 | tr '\n' ' ')"
  [ "$got" = "ag-rank-05 ag-rank-04 ag-rank-03 ag-rank-02 ag-rank-01 " ] \
    || { echo "order was: [$got]"; false; }
}

@test "antigravity recent_sids at limit=4: the stale cache pointer is the row that gets squeezed out (#34 P2-2)" {
  _setup_agy
  local i sid
  for i in 1 2 3 4 5; do
    sid="ag-cut-0$i"
    seed_agy_session "$sid" "$WORK" "cut $i"
    touch -t "20200101000$i" "$BRAIN/$sid/.system_generated/logs/transcript.jsonl"
  done
  mkdir -p "$PROFILE/antigravity-cli/cache"
  printf '{"%s":"%s"}\n' "$WORK" "ag-cut-01" \
    > "$PROFILE/antigravity-cli/cache/last_conversations.json"
  run adapter_recent_sids "$PROFILE" 4
  [ "$status" -eq 0 ]
  local got
  got="$(printf '%s\n' "$output" | cut -d$'\037' -f2 | tr '\n' ' ')"
  # The oldest session loses its slot even though the cache points at it; the
  # newest four are the answer. A cache pointer that took a slot by right
  # would evict ag-cut-02 instead.
  [ "$got" = "ag-cut-05 ag-cut-04 ag-cut-03 ag-cut-02 " ] \
    || { echo "order was: [$got]"; false; }
}

# --- #34 round-1 P3-1: n=1 and n>1 answer two different questions ------------
# n=1 is "what did THIS DIRECTORY last talk to" (the CLI's own per-directory
# pointer cache, one stat); n>1 is "this TANK's n newest". The asymmetry is
# kept on purpose — the docstring gives the measurement — so it gets a test
# that says so out loud, instead of only living in prose.

@test "antigravity recent_sids n=1 answers THIS DIRECTORY's pointer, and n>1 keeps it in a scoped ranking (#34 P3-1)" {
  _setup_agy
  seed_agy_session ag-ptr-old "$WORK" "the pointer's session, oldest on the tank"
  touch -t 202001010000 "$BRAIN/ag-ptr-old/.system_generated/logs/transcript.jsonl"
  seed_agy_session ag-ptr-new "/somewhere/else" "the tank's newest"
  touch -t 202201010000 "$BRAIN/ag-ptr-new/.system_generated/logs/transcript.jsonl"
  mkdir -p "$PROFILE/antigravity-cli/cache"
  printf '{"%s":"%s"}\n' "$WORK" "ag-ptr-old" \
    > "$PROFILE/antigravity-cli/cache/last_conversations.json"

  # n=1 from a directory WITH a pointer: the pointer wins, even though it is
  # the oldest session on the tank. (This is what keeps the board's Live-row
  # fallback title off a whole-tank stat walk.)
  run adapter_recent_sids "$PROFILE" 1
  [ "$status" -eq 0 ]
  local n1; n1="$(printf '%s\n' "$output" | cut -d$'\037' -f2 | tr -d '\n')"
  [ "$n1" = "ag-ptr-old" ] || { echo "n=1 gave: [$n1]"; false; }

  # n>1 from the same directory: ranked, newest first, and scoped — the
  # tank's newest belongs to another directory, so it is not in this answer.
  # 🔴 The pointer's session survives the cwd filter even though nothing in
  # history.jsonl would place it here: the cache entry IS a cwd statement,
  # written by the CLI under this very directory's key, and it is the
  # authority. Without that rule a pointer session with no history entry
  # would be dropped by the very filter that is supposed to find it.
  run adapter_recent_sids "$PROFILE" 5
  [ "$status" -eq 0 ]
  local n5; n5="$(printf '%s\n' "$output" | cut -d$'\037' -f2 | tr '\n' ' ')"
  [ "$n5" = "ag-ptr-old " ] || { echo "n=5 gave: [$n5]"; false; }

  # n=1 from a directory with NO pointer and nothing of its own falls through
  # to the tank's newest — the documented fallback, and the reason the two
  # answers can differ per cwd.
  local nokey="$TEST_HOME/no-pointer"; mkdir -p "$nokey"; cd "$nokey" || false
  run adapter_recent_sids "$PROFILE" 1
  [ "$status" -eq 0 ]
  local n1b; n1b="$(printf '%s\n' "$output" | cut -d$'\037' -f2 | tr -d '\n')"
  [ "$n1b" = "ag-ptr-new" ] || { echo "n=1 (no pointer) gave: [$n1b]"; false; }
}
