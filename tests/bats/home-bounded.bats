#!/usr/bin/env bats
load '../helpers'

_board_source() {
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/reading_cache.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/board_state.sh"
}

_board_fixture() {
  local n="$1" i slug dir
  [ -d "$CLIKAE_HOME/profiles/claude/work" ] || clikae init claude work >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return
  _board_source
  load_adapter claude
  slug="$(_claude_project_slug "$PWD")"
  dir="$CLIKAE_HOME/profiles/claude/work/projects/$slug"
  mkdir -p "$dir"
  # Ten main sessions plus the subagent-heavy store from the issue.
  for ((i=0; i<10; i++)); do
    printf '{"type":"ai-title","aiTitle":"Fixture %s"}\n' "$i" > "$dir/session-$i.jsonl"
  done
  for ((i=10; i<n; i++)); do
    printf '{"type":"assistant","timestamp":"2026-09-12T00:00:00Z"}\n' > "$dir/agent-$i.jsonl"
  done
  board_state_refresh claude "${dir%/projects/*}"
}

_board_shims() {
  local tool real
  export BOARD_IO_LOG="$TEST_HOME/io.log"
  mkdir -p "$TEST_HOME/io-bin"
  # round-5 fix review design decision: a render's ENTIRE staleness signal is
  # now one `find` (list every transcript this tank has) plus one batched
  # `stat` (their mtime/size) — never file CONTENT. `find`/`stat` are logged,
  # like `head`/`tail`, not hard-failed: the old hard-failing `find` shim
  # here asserted "a render never lists the tree at all", which was true of
  # rounds 1-4's bounded, per-signal approximations and is no longer the
  # design (see board_state.sh's own header for why that approximation was
  # abandoned). What must still hold, and is now the header this file's
  # tests assert instead: `find`+`stat` stay BOUNDED (one pass per tank, not
  # one per transcript), and NEITHER `head` NOR `tail` ever touches a
  # `.jsonl`/rollout/transcript file on a warm read.
  for tool in head tail stat find; do
    real="$(command -v "$tool")"
    {
      printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "$BOARD_IO_LOG"\n' "$tool"
      printf 'exec %q "$@"\n' "$real"
    } > "$TEST_HOME/io-bin/$tool"
    chmod +x "$TEST_HOME/io-bin/$tool"
  done
  export PATH="$TEST_HOME/io-bin:$PATH"
}

@test "home: 100 and 1000 transcripts cost equal bounded IO calls; warm reads zero transcript bytes" {
  local small large
  _board_fixture 100
  _board_shims
  : > "$BOARD_IO_LOG"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fixture"* ]] || false
  small="$(wc -l < "$BOARD_IO_LOG" | tr -d ' ')"
  # round-5 fix review design decision: staleness is now one `find` (list
  # every transcript this tank has) plus one batched `stat` (their
  # mtime/size), per TANK, not per section — `_home_refresh` primes
  # `board_generation` once for every tank before any section's `$( )`
  # subshell exists, and every subshell inherits that already-warm memo (see
  # `_home_refresh`'s own header). So the call count here does not grow with
  # section count OR transcript count, only tank count — still O(1) forks for
  # this one-tank fixture, whether it holds 100 or 1000 transcripts.
  [ "$small" -le 180 ]
  : > "$BOARD_IO_LOG"
  run clikae
  [ "$status" -eq 0 ]
  ! grep -E '^(head|tail).*\.jsonl' "$BOARD_IO_LOG" || false
  # Restore real tools while the lifecycle writer discovers the larger store.
  PATH="${PATH#*:}"
  _board_fixture 1000
  rm -rf "$CLIKAE_HOME/state/readings"
  PATH="$TEST_HOME/io-bin:$PATH"
  : > "$BOARD_IO_LOG"
  run clikae
  [ "$status" -eq 0 ]
  large="$(wc -l < "$BOARD_IO_LOG" | tr -d ' ')"
  echo "bounded IO: 100=$small 1000=$large" >&3
  [ "$large" -eq "$small" ]
  [ "$large" -le 180 ]
  : > "$BOARD_IO_LOG"
  run clikae
  [ "$status" -eq 0 ]
  ! grep -E '^(head|tail).*\.jsonl' "$BOARD_IO_LOG" || false
}

@test "home: timing unset is silent and enabled emits exactly four named millisecond sections" {
  _board_fixture 10
  clikae > "$TEST_HOME/plain" 2> "$TEST_HOME/before.err"
  [ ! -s "$TEST_HOME/before.err" ]
  CLIKAE_HOME_TIMING=0 clikae > "$TEST_HOME/disabled" 2> "$TEST_HOME/disabled.err"
  cmp "$TEST_HOME/before.err" "$TEST_HOME/disabled.err"
  CLIKAE_HOME_TIMING=1 clikae > "$TEST_HOME/timed" 2> "$TEST_HOME/timed.err"
  cmp "$TEST_HOME/plain" "$TEST_HOME/timed"
  [ "$(wc -l < "$TEST_HOME/timed.err" | tr -d ' ')" -eq 4 ]
  local section
  for section in tanks live recent fuel; do
    [ "$(grep -Ec "^clikae home $section: [0-9]+ ms$" "$TEST_HOME/timed.err")" -eq 1 ]
  done
}

@test "reading cache: hits bypass parser; size, mtime and path invalidate independently" {
  _board_source
  local f="$TEST_HOME/a" g="$TEST_HOME/b"
  printf first > "$f"
  cp -p "$f" "$g"
  _parser() { printf x >> "$TEST_HOME/parses"; cat "$1"; }
  [ "$(reading_cache_run probe "$f" _parser "$f")" = first ]
  [ "$(reading_cache_run probe "$f" _parser "$f")" = first ]
  [ "$(cat "$TEST_HOME/parses")" = x ]
  touch -t 202001010000 "$f"
  reading_cache_run probe "$f" _parser "$f" >/dev/null
  printf longer >> "$f"
  touch -t 202001010000 "$f"
  reading_cache_run probe "$f" _parser "$f" >/dev/null
  reading_cache_run probe "$g" _parser "$g" >/dev/null
  [ "$(cat "$TEST_HOME/parses")" = xxxx ]
}

@test "reading cache: caches absent readings and follows replaced log symlinks" {
  _board_source
  local f="$TEST_HOME/log" link="$TEST_HOME/cli.log"
  printf clean > "$f"; ln -s "$f" "$link"
  _absent() { printf x >> "$TEST_HOME/parses"; return 1; }
  run reading_cache_run none "$link" _absent
  [ "$status" -eq 1 ]
  run reading_cache_run none "$link" _absent
  [ "$status" -eq 1 ]
  [ "$(cat "$TEST_HOME/parses")" = x ]
  printf changed > "$TEST_HOME/newlog"
  ln -sf "$TEST_HOME/newlog" "$link"
  run reading_cache_run none "$link" _absent
  [ "$status" -eq 1 ]
  [ "$(cat "$TEST_HOME/parses")" = xx ]
}

@test "home: missing state self-heals inline once, then reads are bounded (list+stat, never content) again" {
  # 2026-09-12 round-1 fix review, P1-2: a board with NO snapshot at all for
  # this tank (never launched through a session boundary — `clikae alias` /
  # `env` / a `.app` bundle never call board_state_refresh) used to render an
  # empty Resume section forever, silently, with no way to self-correct. Now
  # board_generation (lib/core/board_state.sh) rebuilds the ONE missing tank
  # inline the first time anything reads it — so the render must show the
  # fixture immediately, at the cost of exactly one discovery pass for that
  # one tank.
  #
  # round-5 fix review design decision: every render after that ALSO lists +
  # stats this one tank's transcripts once — that is the entire staleness
  # signal now (see board_state.sh's own header) — but never opens/parses
  # any of them, so the SECOND render's cost is bounded to one find + one
  # stat, not the "zero discovery at all" this test asserted before that
  # redesign.
  _board_fixture 10
  rm -rf "$CLIKAE_HOME/state/board"
  # A SOFT find shim for this first render: it must still discover the real
  # fixture (same shim `_board_shims` below now uses too — see its header).
  export BOARD_IO_LOG="$TEST_HOME/io.log"
  mkdir -p "$TEST_HOME/io-bin"
  { printf '#!/bin/bash\nprintf "%%s\\n" "find $*" >> "$BOARD_IO_LOG"\n'
    printf 'exec %q "$@"\n' "$(command -v find)"; } > "$TEST_HOME/io-bin/find"
  chmod +x "$TEST_HOME/io-bin/find"
  export PATH="$TEST_HOME/io-bin:$PATH"
  : > "$BOARD_IO_LOG"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fixture"* ]] || false
  grep -q '^find ' "$BOARD_IO_LOG" || false
  PATH="${PATH#*:}"
  # Now the logging shim: a SECOND render reads back what the first one just
  # self-healed. It re-lists and re-stats this one tank (bounded — see this
  # test's own header) but must never re-read any transcript's CONTENT.
  _board_shims
  : > "$BOARD_IO_LOG"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fixture"* ]] || false
  ! grep -E '^(head|tail).*\.jsonl' "$BOARD_IO_LOG" || false
}

@test "home: live rows read the stamped row exactly, and guess the unstamped row from one candidate" {
  # 2026-09-12 round-1 fix review, P1-1: this test used to assert that an
  # UNSTAMPED row in board mode reads NOTHING and just shows the tank's own
  # name — which was true only because board mode disabled the whole guess
  # pass outright (home.sh used to gate it off with `_CLIKAE_BOARD`). That is
  # the exact defect live.bats' own "single live session's title carries no
  # guess marker" / "two live sessions… no guess marker" family exists to
  # forbid: an unstamped row must still get its best-available guess, the
  # same way it always did outside board mode. What must stay true here is
  # only the COST shape — the guess reads at most the ONE transcript it
  # settles on, never a scan of every other session on the tank.
  _board_fixture 10
  source "$CLIKAE_LIB/commands/home.sh"
  # Function fixtures only: no tmux client or server is invoked.
  tmux() { return 99; }
  live_session_names() { printf 'stamped\t0\t1\nunstamped\t0\t1\n'; }
  live_split() { printf 'claude\twork\n'; }
  live_session_id() { [ "$1" != stamped ] || printf session-3; }
  live_engine_alive() { return 0; }
  _board_shims
  : > "$BOARD_IO_LOG"
  local _CLIKAE_BOARD=1
  run _home_live_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fixture 3"* ]] || false
  # Content reads only (head -n 100 / tail -c 524288, how title/recap parsing
  # bounds its read) — a freshness check's own metadata stat legitimately
  # names every recent candidate in one batched call (files_mtime_size), and
  # that is not a content read.
  local touched
  touched="$(grep -E '^(head -n 100|tail -c 524288)' "$BOARD_IO_LOG" \
    | grep -oE 'session-[0-9]+\.jsonl' | sed 's/\.jsonl$//' | sort -u | grep -vx session-3 | wc -l | tr -d ' ')"
  [ "$touched" -le 1 ]
}

@test "run: launch keeps exec semantics — no board refresh, engine exit status preserved" {
  # 2026-09-12 round-1 fix review, P2-1/P2-2: cmd_run used to wrap adapter_run
  # in a subshell so a board_state_refresh could run before AND after —
  # holding clikae resident as the session's parent for as long as the engine
  # ran, and paying a full tank scan synchronously on every launch and every
  # exit. board_generation now self-heals a stale snapshot inline at render
  # time, so cmd_run has nothing left to buy by calling board_state_refresh
  # itself, and this must be the tail call adapter_run's own `exec` rides on.
  _board_source
  source "$CLIKAE_LIB/commands/run.sh"
  load_adapter() { :; }
  ensure_profile() { printf '%s' "$TEST_HOME/tank"; }
  validate_name() { :; }
  soul_prelaunch() { :; }
  fleet_mcp_prelaunch() { :; }
  adapter_run() { printf engine >> "$TEST_HOME/calls"; return 7; }
  board_state_refresh() { printf boundary >> "$TEST_HOME/calls"; }
  run cmd_run claude test
  [ "$status" -eq 7 ]
  [ "$(cat "$TEST_HOME/calls")" = engine ]
}

@test "home: codex quota errors survive snapshots and a later success clears them" {
  _board_source
  local dir="$TEST_HOME/codex" f
  mkdir -p "$dir/sessions"
  f="$dir/sessions/rollout-test.jsonl"
  printf '{"type":"session_meta","payload":{"id":"test","cwd":"%s"}}\n' "$PWD" > "$f"
  printf '{"timestamp":"2026-09-12T00:00:00Z","codex_error_info":"usage_limit_exceeded","message":"try again at tomorrow."}\n' >> "$f"
  board_state_refresh codex "$dir"
  _board_shims
  : > "$BOARD_IO_LOG"
  local _CLIKAE_BOARD=1
  run limit_profile_dry codex "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = 'try again at tomorrow' ]
  ! grep -E '^(head|tail).*\.jsonl' "$BOARD_IO_LOG" || false
  PATH="${PATH#*:}"
  printf '{"timestamp":"2026-09-12T00:01:00Z","type":"agent_message"}\n' >> "$f"
  board_state_refresh codex "$dir"
  run limit_profile_dry codex "$dir"
  # round-3 fix review, P1-1: #79 gave _limit_codex_dry a THIRD return code —
  # rc=2, not rc=1 — for exactly this shape (a real turn newer than the
  # newest limit): rc=1 just means "nothing found here" (fall through to
  # dry_store), while rc=2 is POSITIVE evidence of recovery that
  # _limit_tank_dry_raw weighs against a persisted marker's own timestamp
  # (R2-P1-3). The badge still clears; it clears via rc=2, not rc=1.
  [ "$status" -eq 2 ]
}

@test "home: grok recent and live lookup use snapshots without a content read" {
  _board_source
  local dir="$TEST_HOME/grok" f
  mkdir -p "$dir/sessions/group/session"
  f="$dir/sessions/group/session/summary.json"
  printf '{"id":"session","cwd":"%s","generated_title":"Grok fixture"}\n' "$PWD" > "$f"
  board_state_refresh grok "$dir"
  load_adapter grok
  _board_shims
  : > "$BOARD_IO_LOG"
  local _CLIKAE_BOARD=1
  run adapter_recent_sids "$dir" 10
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\037session' ]] || false
  [ "$(adapter_find_session "$dir" session)" = "$f" ]
  [ "$(adapter_session_title "$dir" session)" = 'Grok fixture' ]
  ! grep -E '^(head|tail).*summary\.json' "$BOARD_IO_LOG" || false
  : > "$BOARD_IO_LOG"
  [ "$(adapter_session_title "$dir" session)" = 'Grok fixture' ]
  ! grep -E '^(head|tail)' "$BOARD_IO_LOG" || false
}

@test "home: snapshot selects newest main sessions and excludes subagents" {
  _board_fixture 10
  local dir="$CLIKAE_HOME/profiles/claude/work" f
  f="$dir/projects/$(_claude_project_slug "$PWD")/session-0.jsonl"
  touch -t 203001010000 "$f"
  printf '{}\n' > "${f%/*}/agent-new.jsonl"
  CLIKAE_HOME_RECENT_MAX=2 board_state_refresh claude "$dir"
  local _CLIKAE_BOARD=1
  run adapter_recent_sids "$dir" 10
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *$'\037session-0' ]] || false
  [[ "$output" != *agent-new* ]] || false
}

# --- round-5 fix review receipts -------------------------------------------
# Each of these reproduces one of round 5's findings against the OLD, bounded
# per-signal staleness code and must go green under the new one-fingerprint
# design (board_state.sh's own header). Left in the suite so none of the four
# regresses again.

@test "home: a codex limit appended to a running rollout is visible from a different cwd (round-5 P1)" {
  _board_source
  local dir="$TEST_HOME/codex" f
  mkdir -p "$dir/sessions" "$TEST_HOME/work-a" "$TEST_HOME/somewhere-else"
  f="$dir/sessions/rollout-test.jsonl"
  printf '{"type":"session_meta","payload":{"id":"test","cwd":"%s"}}\n' "$TEST_HOME/work-a" > "$f"
  printf '{"timestamp":"2026-09-12T00:00:00Z","type":"agent_message"}\n' >> "$f"
  board_state_refresh codex "$dir"
  local _CLIKAE_BOARD=1
  run limit_profile_dry codex "$dir"
  [ "$status" -ne 0 ]
  # The limit lands via an APPEND to the SAME rollout — the shape the real
  # codex TUI uses (limit.sh's own header), never a new file. An append
  # touches no directory's mtime, only this one file's.
  printf '{"timestamp":"2026-09-12T00:01:00Z","codex_error_info":"usage_limit_exceeded","message":"try again at tomorrow."}\n' >> "$f"
  # Render from a cwd that is neither the rollout's own recorded cwd nor
  # $dir itself — round-5's P1: codex's only per-render freshness signal
  # used to be keyed to the OBSERVER's $PWD (a day-dir chain), so a render
  # from anywhere else never saw this append at all.
  cd "$TEST_HOME/somewhere-else" || return 1
  run limit_profile_dry codex "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = 'try again at tomorrow' ]
}

@test "home: a claude limit in a session that is NOT the newest in its project is visible (round-8 P1-1)" {
  # Round-8 P3-4: this receipt used to APPEND the limit to the 11th-newest
  # session — and an append makes that file the NEWEST, so it ranked 1st by
  # the time anything read it and the test could not tell a count bound from a
  # window bound at all. It was a ruler that could no longer reach its own
  # specimen: green on a branch whose cold build dropped exactly this shape.
  #
  # Round-8 P1-1 is that shape: the limit is ALREADY in the file and the file
  # is never written again, which is what a session that ran dry and was
  # abandoned leaves on disk. It sits one hour back — well inside claude's
  # 300-minute window — behind CLIKAE_HOME_RECENT_MAX + 2 newer neighbours in
  # the same project directory. A per-directory count bound never scans it; the
  # window does.
  [ -d "$CLIKAE_HOME/profiles/claude/work" ] || clikae init claude work >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  _board_source
  load_adapter claude
  local slug dir proj i stamp
  slug="$(_claude_project_slug "$PWD")"
  dir="$CLIKAE_HOME/profiles/claude/work"
  proj="$dir/projects/$slug"
  mkdir -p "$proj"
  printf '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · resets 11pm"}]},"timestamp":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$proj/session-quiet.jsonl"
  stamp="$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M')"
  touch -t "$stamp" "$proj/session-quiet.jsonl"
  for ((i = 0; i < 12; i++)); do
    printf '{"type":"ai-title","aiTitle":"Fixture %s"}\n' "$i" > "$proj/session-$i.jsonl"
  done
  rm -rf "$CLIKAE_HOME/state/board" "$CLIKAE_HOME/state/readings"
  _board_gen_cache_clear
  board_state_refresh claude "$dir"
  local _CLIKAE_BOARD=1
  run limit_profile_dry claude "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resets 11pm"* ]] || false
  # and the board agrees with the non-board scan it exists to approximate
  _CLIKAE_BOARD=0
  run limit_profile_dry claude "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resets 11pm"* ]] || false
}

@test "home: a codex limit in a rollout that is NOT the newest in its day dir is visible (round-8 P1-1)" {
  # Same defect, codex's shape: the "project directory" is a DATE directory
  # and a dozen rollouts in one day is ordinary. Codex's window is seven days,
  # so a rollout touched an hour ago is deep inside it.
  _board_source
  load_adapter codex >/dev/null 2>&1 || true
  local dir="$TEST_HOME/codex-window" sd i stamp
  sd="$dir/sessions/2026/09/13"
  mkdir -p "$sd" "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  printf '{"type":"session_meta","payload":{"id":"quiet","cwd":"%s"}}\n{"timestamp":"2026-09-13T00:01:00Z","codex_error_info":"usage_limit_exceeded","message":"try again at tomorrow."}\n' \
    "$TEST_HOME/work" > "$sd/rollout-quiet.jsonl"
  stamp="$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M')"
  touch -t "$stamp" "$sd/rollout-quiet.jsonl"
  for ((i = 0; i < 12; i++)); do
    printf '{"type":"session_meta","payload":{"id":"neighbour-%s","cwd":"%s"}}\n' \
      "$i" "$TEST_HOME/work" > "$sd/rollout-neighbour-$i.jsonl"
  done
  rm -rf "$CLIKAE_HOME/state/board" "$CLIKAE_HOME/state/readings"
  _board_gen_cache_clear
  board_state_refresh codex "$dir"
  local _CLIKAE_BOARD=1
  run limit_profile_dry codex "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = 'try again at tomorrow' ]
}

@test "home: a claude limit landing only in an already-existing agent-*.jsonl is visible (round-5 P2-2)" {
  [ -d "$CLIKAE_HOME/profiles/claude/work" ] || clikae init claude work >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  _board_source
  load_adapter claude
  local slug dir
  slug="$(_claude_project_slug "$PWD")"
  dir="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$dir/projects/$slug"
  printf '{"type":"ai-title","aiTitle":"Fixture 0"}\n' > "$dir/projects/$slug/session-0.jsonl"
  # A subagent transcript that already exists at publish time — round-4's
  # topK signal never considered agent-*.jsonl a candidate at all (filtered
  # out before top-K even saw it), so an APPEND to it moved neither a
  # directory mtime nor any recorded file.
  printf '{"type":"assistant","timestamp":"2026-09-12T00:00:00Z"}\n' > "$dir/projects/$slug/agent-sub.jsonl"
  board_state_refresh claude "$dir"
  local _CLIKAE_BOARD=1
  run limit_profile_dry claude "$dir"
  [ "$status" -ne 0 ]
  printf '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · resets 11pm"}]},"timestamp":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$dir/projects/$slug/agent-sub.jsonl"
  run limit_profile_dry claude "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resets 11pm"* ]] || false
}

@test "home: _home_refresh in one long-lived process does not reuse a stale generation on its next refresh (round-5 P2-1)" {
  _board_fixture 10
  source "$CLIKAE_LIB/commands/home.sh"
  # shellcheck disable=SC2034  # dynamically consumed by _home_refresh itself
  local items dry dir slug before after
  dir="$CLIKAE_HOME/profiles/claude/work"
  slug="$(_claude_project_slug "$PWD")"
  _home_refresh
  before="$(board_recent claude "$dir" 20)"
  [[ "$before" != *session-new* ]] || false
  # A brand new session, as if the user just launched one from the TUI and
  # came back to the picker — no new PROCESS starts, so a stale in-process
  # memo (round-5 P2-1) would hide it from the very next refresh.
  printf '{"type":"ai-title","aiTitle":"Fixture NEW"}\n' > "$dir/projects/$slug/session-new.jsonl"
  _home_refresh
  after="$(board_recent claude "$dir" 20)"
  [[ "$after" == *session-new* ]] || false
}

# --- round-6 fix review receipts --------------------------------------------
# round-5's fingerprint pushed EVERY transcript path into one `stat` argv;
# past ARG_MAX `stat` died E2BIG and the failure was swallowed by
# `2>/dev/null`, silently degrading the fingerprint to a file count. Round-6
# replaced it with one `find … -exec stat … {} +` (find batches its own
# argv, so this cannot E2BIG) and made the rebuild itself incremental.

@test "board: a batch-stat fingerprint over 20,000 transcripts still sees one appended line, and find+stat never fail (round-6 P1-1)" {
  [ -d "$CLIKAE_HOME/profiles/claude/work" ] || clikae init claude work >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  _board_source
  load_adapter claude
  local slug dir i
  slug="$(_claude_project_slug "$PWD")"
  dir="$CLIKAE_HOME/profiles/claude/work/projects/$slug"
  mkdir -p "$dir"
  for ((i = 0; i < 20000; i++)); do
    printf '{"type":"ai-title","aiTitle":"Fixture %s"}\n' "$i" > "$dir/session-$i.jsonl"
  done
  # Backdate everything but session-0 well outside claude's 300-min rate-limit
  # window (in one batched `touch -t … {} +`, not 20,000 forks) — this test is
  # about the FINGERPRINT surviving ARG_MAX, not about the per-file reading
  # fold's own (already-covered-elsewhere) cold-build cost.
  local stamp
  stamp="$(date -d '30 days ago' '+%Y%m%d%H%M' 2>/dev/null || date -v-30d '+%Y%m%d%H%M')"
  find "$dir" -name '*.jsonl' ! -name session-0.jsonl -exec touch -t "$stamp" {} +
  # Deliberately no `board_state_refresh` call here: the fingerprint
  # (`_board_transcript_fingerprint`) is independent of any generation ever
  # having been built — this test is about IT surviving ARG_MAX, not about
  # a full cold rebuild's own (already fork-heavy, already covered by
  # receipt 2's timing table) cost at 20,000 files.
  local before after
  before="$(_board_transcript_fingerprint claude "$CLIKAE_HOME/profiles/claude/work")"
  printf '{"type":"ai-title","aiTitle":"Fixture 0 appended"}\n' >> "$dir/session-0.jsonl"
  after="$(_board_transcript_fingerprint claude "$CLIKAE_HOME/profiles/claude/work")"
  [ "$before" != "$after" ]
  # Re-run the SAME shape of pipeline `_board_stat_rows` uses, but WITHOUT
  # its `2>/dev/null` (that one only hides a missing directory — see its own
  # header) and with `pipefail` on, so an E2BIG anywhere in the chain shows
  # up as a non-zero status here instead of being silently absorbed.
  local rc=0 statfmt
  _clikae_statv
  statfmt="$_CLIKAE_STAT_FMT"
  (
    set -o pipefail
    if [ "$statfmt" = '%Y %n' ]; then
      find "$dir" -type f -name '*.jsonl' -exec stat -c $'%.9Y\037%s\037%n' {} + 2> "$TEST_HOME/staterr" | sort | cksum > /dev/null
    else
      find "$dir" -type f -name '*.jsonl' -exec stat -f $'%Fm\037%z\037%N' {} + 2> "$TEST_HOME/staterr" | sort | cksum > /dev/null
    fi
  )
  rc=$?
  [ "$rc" -eq 0 ]
  [ ! -s "$TEST_HOME/staterr" ]
}

@test "board: an incremental rebuild re-reads only the ONE file that changed (round-6 P1-2)" {
  [ -d "$CLIKAE_HOME/profiles/claude/work" ] || clikae init claude work >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  _board_source
  load_adapter claude
  local slug dir i
  slug="$(_claude_project_slug "$PWD")"
  dir="$CLIKAE_HOME/profiles/claude/work/projects/$slug"
  mkdir -p "$dir"
  for ((i = 0; i < 50; i++)); do
    printf '{"type":"ai-title","aiTitle":"Fixture %s"}\n' "$i" > "$dir/session-$i.jsonl"
  done
  board_state_refresh claude "$CLIKAE_HOME/profiles/claude/work"
  # Design decision (round-6 fix review): a generation change must not drop
  # the per-file reading cache — only a file whose (mtime, size) actually
  # differs from the previous generation gets re-parsed. Stubbing the
  # per-file parser and counting its calls on the SECOND (incremental)
  # rebuild proves that directly, independent of wall-clock timing.
  _limit_claude_reading() { printf '%s\n' "$1" >> "$TEST_HOME/parsed.log"; printf '\037\037'; }
  printf '{"type":"ai-title","aiTitle":"Fixture 0 changed"}\n' >> "$dir/session-0.jsonl"
  board_state_refresh claude "$CLIKAE_HOME/profiles/claude/work"
  [ -f "$TEST_HOME/parsed.log" ]
  [ "$(wc -l < "$TEST_HOME/parsed.log" | tr -d ' ')" -eq 1 ]
  [[ "$(cat "$TEST_HOME/parsed.log")" == */session-0.jsonl ]] || false
  # Round-8 P3-2: `readings-bounded` is published by BOTH paths, so its
  # presence means one thing ("what this refresh opened"), not two.
  local root gen
  root="$(board_root "$CLIKAE_HOME/profiles/claude/work")"
  gen="$root/$(cat "$root/current")"
  [ "$(cat "$gen/readings-bounded")" = "$dir/session-0.jsonl" ]
}

@test "board: a removed transcript's resume row disappears after the next rebuild (round-6 incremental rebuild)" {
  [ -d "$CLIKAE_HOME/profiles/claude/work" ] || clikae init claude work >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  _board_source
  load_adapter claude
  local slug dir
  slug="$(_claude_project_slug "$PWD")"
  dir="$CLIKAE_HOME/profiles/claude/work/projects/$slug"
  mkdir -p "$dir"
  printf '{"type":"ai-title","aiTitle":"Fixture keep"}\n' > "$dir/session-keep.jsonl"
  printf '{"type":"ai-title","aiTitle":"Fixture gone"}\n' > "$dir/session-gone.jsonl"
  board_state_refresh claude "$CLIKAE_HOME/profiles/claude/work"
  local before after
  before="$(board_recent claude "$CLIKAE_HOME/profiles/claude/work" 20)"
  [[ "$before" == *session-gone* ]] || false
  rm -f "$dir/session-gone.jsonl"
  printf '{"type":"ai-title","aiTitle":"Fixture keep, edited"}\n' >> "$dir/session-keep.jsonl"
  board_state_refresh claude "$CLIKAE_HOME/profiles/claude/work"
  after="$(board_recent claude "$CLIKAE_HOME/profiles/claude/work" 20)"
  [[ "$after" != *session-gone* ]] || false
  [[ "$after" == *session-keep* ]] || false
}

# ---------------------------------------------------------------------------
# 2026-09-13 round-7 fix review (round-8 fixes). One receipt per finding; each
# one was RED on 6b952d9 before the fix that follows it.
# ---------------------------------------------------------------------------

_b8_tank() {
  [ -d "$CLIKAE_HOME/profiles/claude/work" ] || clikae init claude work >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  _board_source
  load_adapter claude
  B8_TANK="$CLIKAE_HOME/profiles/claude/work"
  B8_PROJ="$B8_TANK/projects/$(_claude_project_slug "$PWD")"
  mkdir -p "$B8_PROJ"
}

@test "board (P1-1): publishing a generation leaves the PREVIOUS one byte-identical, and shares no inode with it" {
  # Round-7 P1-1: `cp -al` hard-linked every carried-forward entry, and
  # `> "$base"` / `> "$gen/sids/$key"` then wrote THROUGH those links — so
  # publishing gen2 silently rewrote gen1, which `current` was still pointing
  # at while the rebuild ran. The reviewer's own three-way probe caught it:
  # gen1's recent row changed the moment gen2 published.
  _b8_tank
  local i
  for i in 0 1 2 3; do
    printf '{"type":"ai-title","aiTitle":"T%s"}\n' "$i" > "$B8_PROJ/session-$i.jsonl"
  done
  board_state_refresh claude "$B8_TANK"
  local root gen1 gen2 snap
  root="$(board_root "$B8_TANK")"
  gen1="$root/$(cat "$root/current")"
  snap="$TEST_HOME/gen1-snapshot"
  rm -rf "$snap"; mkdir -p "$snap"
  cp -r "$gen1/recent" "$snap/recent"
  cp -r "$gen1/sids" "$snap/sids"

  printf '{"type":"ai-title","aiTitle":"CHANGED"}\n' >> "$B8_PROJ/session-3.jsonl"
  _board_gen_cache_clear
  board_state_refresh claude "$B8_TANK"
  gen2="$root/$(cat "$root/current")"
  [ "$gen2" != "$gen1" ]

  # THE receipt: the superseded generation is byte-identical to its snapshot.
  diff -r "$snap/recent" "$gen1/recent"
  diff -r "$snap/sids" "$gen1/sids"

  # And the mechanism that guarantees it: nothing is hard-linked any more, so
  # there is no shared inode left for a future in-place write to reach.
  local f links
  for f in "$gen1"/sids/* "$gen1"/recent/* "$gen2"/sids/* "$gen2"/recent/*; do
    [ -f "$f" ] || continue
    links="$(stat -c %h "$f" 2>/dev/null || stat -f %l "$f")"
    [ "$links" -eq 1 ] || { echo "$f has $links links"; false; }
  done

  # gen2 carries ONLY what changed in it — not a copy of the tank.
  [ "$(ls "$gen2/sids" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(cat "$gen2/parent")" = "${gen1##*/}" ]
}

@test "board (P1-1): the parent chain is bounded — it materialises and never outgrows _BOARD_GEN_MAX_DEPTH" {
  _b8_tank
  printf '{"type":"ai-title","aiTitle":"T0"}\n' > "$B8_PROJ/session-0.jsonl"
  printf '{"type":"ai-title","aiTitle":"T1"}\n' > "$B8_PROJ/session-1.jsonl"
  board_state_refresh claude "$B8_TANK"
  local root i gen depth saw_materialise=0
  root="$(board_root "$B8_TANK")"
  for ((i = 0; i < 20; i++)); do
    printf '{"n":%s}\n' "$i" >> "$B8_PROJ/session-1.jsonl"
    _board_gen_cache_clear
    board_state_refresh claude "$B8_TANK"
    gen="$root/$(cat "$root/current")"
    depth="$(cat "$gen/depth")"
    [ "$depth" -lt "$_BOARD_GEN_MAX_DEPTH" ] || { echo "depth $depth"; false; }
    [ "$depth" -ne 0 ] || saw_materialise=1
    # session-0 was written once and never touched again: it can only still
    # resolve through the chain (or through a materialised copy of it).
    [ -n "$(board_find claude "$B8_TANK" session-0)" ]
  done
  [ "$saw_materialise" -eq 1 ]
}

@test "board (P1-1): GC never unlinks a generation the current one still resolves through" {
  # keep-N alone would have: the chain runs up to _BOARD_GEN_MAX_DEPTH deep
  # and keep is 5 by default. An unlinked ancestor is not a dangling pointer a
  # rebuild heals — it is a silently empty Resume list with `current` still
  # valid and board_stale still saying "fresh".
  _b8_tank
  local i
  for i in 0 1 2; do
    printf '{"type":"ai-title","aiTitle":"T%s"}\n' "$i" > "$B8_PROJ/session-$i.jsonl"
  done
  board_state_refresh claude "$B8_TANK"
  local root
  root="$(board_root "$B8_TANK")"
  for ((i = 0; i < 6; i++)); do
    printf '{"n":%s}\n' "$i" >> "$B8_PROJ/session-2.jsonl"
    _board_gen_cache_clear
    board_state_refresh claude "$B8_TANK"
  done
  # Walk the live chain and assert every link of it is still on disk.
  local cur p n=0
  cur="$(cat "$root/current")"
  while [ -n "$cur" ]; do
    [ -d "$root/$cur" ] || { echo "GC removed chain link $cur"; false; }
    n=$((n + 1))
    p=""
    [ ! -f "$root/$cur/parent" ] || p="$(cat "$root/$cur/parent")"
    cur="$p"
  done
  [ "$n" -ge 2 ]
  [ -n "$(board_find claude "$B8_TANK" session-0)" ]
  # and `clikae clean`'s own sweep uses the same rule
  source "$CLIKAE_LIB/commands/clean.sh"
  _clean_board_gc 0 >/dev/null 2>&1 || true
  [ -n "$(board_find claude "$B8_TANK" session-0)" ]
}

@test "board (round-8 P2-2): GC keeps the chain of every LIVE generation, not only current's" {
  # Round-8 fix review P2-2. `board_generation` memoizes a generation PATH for
  # the life of the process, so a TUI frame / a second `clikae` holds a
  # generation while another publishes. Protection was drawn around `current`
  # only: one further publish — the one that MATERIALISES and breaks the chain
  # away from `current` — let keep-N unlink the held generation's oldest
  # ancestors. It still existed, `current` was valid, `board_stale` still said
  # "fresh", and 49 of its 50 entries stopped resolving.
  _b8_tank
  local i
  for ((i = 0; i < 50; i++)); do
    printf '{"type":"ai-title","aiTitle":"T%s"}\n' "$i" > "$B8_PROJ/session-$i.jsonl"
  done
  printf '{"type":"ai-title","aiTitle":"driver"}\n' > "$B8_PROJ/driver.jsonl"
  rm -rf "$CLIKAE_HOME/state/board"
  _board_gen_cache_clear
  board_state_refresh claude "$B8_TANK"
  local root depth=0 held
  root="$(board_root "$B8_TANK")"
  # drive the chain to its deepest link WITHOUT touching any of the 50: they
  # can only still resolve through ancestors.
  while [ "$depth" -lt "$((_BOARD_GEN_MAX_DEPTH - 1))" ]; do
    printf '{"n":%s}\n' "$depth" >> "$B8_PROJ/driver.jsonl"
    _board_gen_cache_clear
    board_state_refresh claude "$B8_TANK"
    depth="$(cat "$root/$(cat "$root/current")/depth")"
  done
  held="$root/$(cat "$root/current")"
  [ "$(cat "$held/depth")" -eq "$((_BOARD_GEN_MAX_DEPTH - 1))" ]

  # one more publish: this is the materialising one, and it is where the held
  # generation's chain used to lose its oldest links
  printf '{"n":"more"}\n' >> "$B8_PROJ/driver.jsonl"
  _board_gen_cache_clear
  board_state_refresh claude "$B8_TANK"
  [ -d "$held" ] || { echo "the held generation itself is gone"; false; }

  # every link of the HELD chain is still on disk …
  local cur p n=0
  cur="${held##*/}"
  while [ -n "$cur" ]; do
    [ -d "$root/$cur" ] || { echo "GC removed held chain link $cur"; false; }
    n=$((n + 1))
    p=""
    [ ! -f "$root/$cur/parent" ] || p="$(cat "$root/$cur/parent")"
    cur="$p"
  done
  [ "$n" -eq "$_BOARD_GEN_MAX_DEPTH" ] || { echo "held chain is $n links"; false; }

  # … and all 50 entries still resolve FROM IT, which is what a reader holding
  # it would do
  local miss=0 key
  for ((i = 0; i < 50; i++)); do
    _board_entry_key "session-$i"; key="$_board_entry_key_out"
    _board_gen_entry "$held" "sids/$key" || { miss=$((miss + 1)); continue; }
    # shellcheck disable=SC2154  # _board_gen_entry_out is its out-variable
    [ -s "$_board_gen_entry_out" ] || miss=$((miss + 1))
  done
  [ "$miss" -eq 0 ] || { echo "$miss of 50 entries unresolvable from the held generation"; false; }

  # and `clikae clean`'s sweep, which shares the rule, does not undo it
  source "$CLIKAE_LIB/commands/clean.sh"
  _clean_board_gc 0 >/dev/null 2>&1 || true
  cur="${held##*/}"
  while [ -n "$cur" ]; do
    [ -d "$root/$cur" ] || { echo "clean removed held chain link $cur"; false; }
    p=""
    [ ! -f "$root/$cur/parent" ] || p="$(cat "$root/$cur/parent")"
    cur="$p"
  done
}

@test "board (P1-2): a tank with zero transcripts is never stale — one generation after five renders" {
  # Round-7 P1-2: the publisher hashed `printf '%s\n' "$stat_rows"` (one
  # newline for an empty tank, because `$( )` had already stripped the real
  # trailing newline) and board_stale hashed the pipeline's own output (zero
  # bytes). cksum("\n") can never equal cksum(""), so a freshly `clikae
  # init`'d tank published a whole new generation on EVERY frame, forever.
  clikae init claude empty1 >/dev/null
  clikae init codex empty2 >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  _board_source
  local pair eng tank dir root i
  for pair in "claude empty1" "codex empty2"; do
    set -- $pair; eng="$1"; tank="$2"
    dir="$CLIKAE_HOME/profiles/$eng/$tank"
    root="$(board_root "$dir")"
    for ((i = 0; i < 5; i++)); do
      _board_gen_cache_clear
      board_generation "$eng" "$dir" >/dev/null 2>&1 || true
    done
    [ "$(ls -d "$root"/generation.* | wc -l | tr -d ' ')" -eq 1 ]
    # the canonical empty-set value, on both sides
    local gen saved live
    gen="$root/$(cat "$root/current")"
    saved="$(cat "$gen/transcripts-fp")"
    live="$(_board_transcript_fingerprint "$eng" "$dir")"
    [ "$saved" = "$live" ]
    [ "$saved" = "$(printf '' | cksum)" ]
    run board_stale "$eng" "$dir" "$gen"
    [ "$status" -ne 0 ]
    # and the empty manifest exists, so the next refresh takes the incremental
    # path instead of cold-building forever
    [ -f "$gen/manifest" ]
  done
}

@test "board (P1-2): publish and board_stale fingerprint the SAME bytes, empty set included" {
  _b8_tank
  local dir="$B8_TANK" root gen
  root="$(board_root "$dir")"
  # zero files, then one, then two: the two sides must agree at every step
  local i
  for i in 0 1 2; do
    [ "$i" -eq 0 ] || printf '{"type":"ai-title","aiTitle":"T"}\n' > "$B8_PROJ/session-$i.jsonl"
    _board_gen_cache_clear
    board_state_refresh claude "$dir"
    gen="$root/$(cat "$root/current")"
    [ "$(cat "$gen/transcripts-fp")" = "$(_board_transcript_fingerprint claude "$dir")" ]
  done
}

@test "board (P2-2): the entry name the cold build WRITES is the one a reader LOOKS UP (incl. non-ASCII)" {
  # The cold build names `sids/<entry>` from awk; every reader computes
  # <entry> to find it again. The first version of this had one rule in bash
  # and a copy in awk, and PR #78's macOS CI job caught them disagreeing on a
  # non-ASCII sid within hours (bash 3.2's bracket expression matched nothing,
  # awk matched every byte) — a disagreement that shows up as a MISS, i.e. a
  # session silently absent from `clikae resume` with its file still on disk,
  # and that no Linux run would ever have surfaced.
  #
  # So this does not compare two spellings of the rule. It writes real
  # transcripts, cold-builds, and asserts the name on disk IS the name the
  # reader computes — through the real code path, on whatever platform and
  # locale the suite happens to run under.
  _b8_tank
  local sids=(
    "plain-sid"
    "0199a1b2-c3d4-7e8f-9012-3456789abcde"
    "dotted.name"
    "$(printf 'caf\303\251-r\303\251sum\303\251')"
    "$(printf '\344\270\255\346\226\207-\345\260\210\346\241\210')"
    "spaced name"
    "punct+colon;semi~tilde"
  )
  local sid
  for sid in "${sids[@]}"; do
    printf '{"type":"ai-title","aiTitle":"T"}\n' > "$B8_PROJ/$sid.jsonl"
  done
  rm -rf "$CLIKAE_HOME/state/board"
  _board_gen_cache_clear
  board_state_refresh claude "$B8_TANK"
  local root gen resolved
  root="$(board_root "$B8_TANK")"
  gen="$root/$(cat "$root/current")"
  for sid in "${sids[@]}"; do
    _board_entry_key "$sid"
    [ -f "$gen/sids/$_board_entry_key_out" ] \
      || { echo "no entry at [$_board_entry_key_out] for sid [$sid]; have: $(ls "$gen/sids")"; false; }
    resolved="$(board_find claude "$B8_TANK" "$sid")"
    [ "$resolved" = "$B8_PROJ/$sid.jsonl" ] \
      || { echo "board_find [$sid] gave [$resolved]"; false; }
  done
  # the name is always a single path component, whatever went in
  _board_entry_key "../../etc/passwd"
  [[ "$_board_entry_key_out" != */* ]] || false
  _board_entry_key ""
  [ -n "$_board_entry_key_out" ]
  # and a long scope keeps both ends, so two paths sharing a prefix differ
  local a b
  _board_entry_key "/home/x/$(printf 'p%.0s' $(seq 1 130))/alpha"; a="$_board_entry_key_out"
  _board_entry_key "/home/x/$(printf 'p%.0s' $(seq 1 130))/omega"; b="$_board_entry_key_out"
  [ "$a" != "$b" ]
}

@test "board (round-8 P1-2): non-ASCII sibling scopes keep their OWN Resume list, never a neighbour's" {
  # Round-8 P1-2. `_board_scope_raw` hands the raw `$PWD` to every engine but
  # claude, and round 8 named each entry by folding every byte outside
  # [A-Za-z0-9._-] to `_` — so two sibling directories with the same BYTE
  # LENGTH got the same `recent/` entry, the cold build merged both scopes'
  # sessions into it under the FIRST scope's `#scope` header, and one
  # directory's Resume list answered with the other's sessions while the
  # other's went silently empty. Two CJK characters are six bytes; so are two
  # others. This is an ordinary project path, not an exotic one.
  clikae init codex cjk >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  _board_source
  load_adapter codex >/dev/null 2>&1 || true
  local dir="$CLIKAE_HOME/profiles/codex/cjk" sd i j sid
  sd="$dir/sessions/2026/09/14"
  mkdir -p "$sd"
  local -a scopes=("$TEST_HOME/專案一" "$TEST_HOME/專案二" "$TEST_HOME/café" "$TEST_HOME/cafè")
  for ((i = 0; i < ${#scopes[@]}; i++)); do
    mkdir -p "${scopes[i]}"
    for j in 0 1; do
      sid="s$i-$j"
      printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$sid" "${scopes[i]}" \
        > "$sd/rollout-2026-09-14T0$i-0$j-$sid.jsonl"
    done
  done
  rm -rf "$CLIKAE_HOME/state/board" "$CLIKAE_HOME/state/readings"
  _board_gen_cache_clear
  board_state_refresh codex "$dir"

  # each scope's own two sessions, and nobody else's — cold
  local rows
  for ((i = 0; i < ${#scopes[@]}; i++)); do
    cd "${scopes[i]}" || return 1
    _board_gen_cache_clear
    rows="$(board_recent codex "$dir" 10)"
    [ "$(printf '%s\n' "$rows" | grep -c .)" -eq 2 ] \
      || { echo "[${scopes[i]}] got: $rows"; false; }
    # every row is this scope's own (sids are "s<scope index>-<n>")
    [ "$(printf '%s\n' "$rows" | grep -c "s$i-")" -eq 2 ] \
      || { echo "[${scopes[i]}] listed a sibling's session: $rows"; false; }
  done

  # distinct scopes must have distinct entry names in the first place
  local root gen ka kb
  root="$(board_root "$dir")"
  gen="$root/$(cat "$root/current")"
  _board_entry_key "${scopes[0]}"; ka="$_board_entry_key_out"
  _board_entry_key "${scopes[1]}"; kb="$_board_entry_key_out"
  [ "$ka" != "$kb" ] || { echo "two scopes, one entry name: $ka"; false; }
  [ -f "$gen/recent/$ka" ] && [ -f "$gen/recent/$kb" ]

  # and the INCREMENTAL path does not merge one scope's row into another's
  # entry either: append to one rollout, rebuild, re-check every scope
  printf '{"timestamp":"2026-09-14T00:00:00Z","type":"agent_message"}\n' \
    >> "$sd/rollout-2026-09-14T00-00-s0-0.jsonl"
  cd "$TEST_HOME/work" || return 1
  _board_gen_cache_clear
  board_state_refresh codex "$dir"
  for ((i = 0; i < ${#scopes[@]}; i++)); do
    cd "${scopes[i]}" || return 1
    _board_gen_cache_clear
    rows="$(board_recent codex "$dir" 10)"
    [ "$(printf '%s\n' "$rows" | grep -c .)" -eq 2 ] \
      || { echo "[${scopes[i]}] after rebuild got: $rows"; false; }
    [ "$(printf '%s\n' "$rows" | grep -c "s$i-")" -eq 2 ] \
      || { echo "[${scopes[i]}] after rebuild listed a sibling: $rows"; false; }
  done
}

@test "board (round-8 P1-1): a cold build scans the whole WINDOW, nothing outside it, and does not fork per file" {
  # Round-7 P2-2 measured 35.6 s at 5,000 files against #62's "under 1 s
  # cold", and rounds 7-8 bought that back partly by scanning FEWER files
  # (the newest CLIKAE_HOME_RECENT_MAX per project directory). That is the
  # round-8 P1-1 defect: a count cannot bound a window. The cost is bought
  # back by not FORKING per file instead — one `tail` per `xargs` batch, one
  # `awk` — so this pins both halves at once: every in-window file is in the
  # scanned set, no out-of-window file is, and the whole scan costs a handful
  # of processes rather than one per file.
  _b8_tank
  local i stamp
  for ((i = 0; i < 40; i++)); do
    printf '{"type":"assistant","timestamp":"2026-09-13T00:00:00Z"}\n' > "$B8_PROJ/session-$i.jsonl"
  done
  # five transcripts OUTSIDE claude's 300-minute window
  stamp="$(date -v-8H '+%Y%m%d%H%M' 2>/dev/null || date -d '8 hours ago' '+%Y%m%d%H%M')"
  for ((i = 0; i < 5; i++)); do
    printf '{"type":"assistant","timestamp":"2026-09-13T00:00:00Z"}\n' > "$B8_PROJ/stale-$i.jsonl"
    touch -t "$stamp" "$B8_PROJ/stale-$i.jsonl"
  done
  # count every `tail` process the rebuild starts
  export BOARD_IO_LOG="$TEST_HOME/tail.log"
  mkdir -p "$TEST_HOME/tail-bin"
  { printf '#!/bin/bash\nprintf "tail\\n" >> "$BOARD_IO_LOG"\n'
    printf 'exec %q "$@"\n' "$(command -v tail)"; } > "$TEST_HOME/tail-bin/tail"
  chmod +x "$TEST_HOME/tail-bin/tail"
  rm -rf "$CLIKAE_HOME/state/board" "$CLIKAE_HOME/state/readings"
  _board_gen_cache_clear
  : > "$BOARD_IO_LOG"
  local saved_path="$PATH"
  PATH="$TEST_HOME/tail-bin:$PATH"
  board_state_refresh claude "$B8_TANK"
  PATH="$saved_path"

  local root gen scanned tails
  root="$(board_root "$B8_TANK")"
  gen="$root/$(cat "$root/current")"
  scanned="$(wc -l < "$gen/readings-bounded" | tr -d ' ')"
  # every one of the 40 in-window files, and none of the 5 outside it
  [ "$scanned" -eq 40 ] || { echo "scanned $scanned of 40 in-window files"; false; }
  ! grep -q '/stale-' "$gen/readings-bounded" || { echo "scanned an out-of-window file"; false; }
  for ((i = 0; i < 40; i++)); do
    grep -q "/session-$i.jsonl\$" "$gen/readings-bounded" \
      || { echo "session-$i was inside the window and was not scanned"; false; }
  done
  # …and it cost a handful of processes, not one per file
  tails="$(wc -l < "$BOARD_IO_LOG" | tr -d ' ')"
  [ "$tails" -le 5 ] || { echo "the window scan started $tails tail processes"; false; }
  # every session still resolves, all 45 of them
  [ "$(wc -l < "$gen/manifest" | tr -d ' ')" -eq 45 ]
  [ -n "$(board_find claude "$B8_TANK" session-39)" ]
}

@test "board (round-8 P1-1): the batched window scan agrees with the per-file parser (claude, codex)" {
  # `_limit_batched_readings` reads the tails of many transcripts in one
  # `tail` and folds them in one `awk`; `_limit_claude_reading` /
  # `_limit_codex_reading` read one file properly. The cold build trusts the
  # first, so this asserts they answer the same thing — including a file whose
  # last byte is not a newline, where the next `==> name <==` banner would run
  # into the last record if `tail` did not separate them.
  _board_source
  local d="$TEST_HOME/readings" f eng parser
  mkdir -p "$d/claude" "$d/codex"
  printf '{"type":"ai-title","aiTitle":"nothing here"}\n' > "$d/claude/none.jsonl"
  printf '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"limit · resets 11pm"}]},"timestamp":"2026-09-13T01:00:00.000Z"}\n' \
    > "$d/claude/limit.jsonl"
  printf '{"type":"assistant","timestamp":"2026-09-13T02:00:00.000Z"}\n' > "$d/claude/ok.jsonl"
  printf '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"limit · resets 9am"}]},"timestamp":"2026-09-13T03:00:00.000Z"}' \
    > "$d/claude/no-trailing-newline.jsonl"
  printf '{"timestamp":"2026-09-10T00:00:00Z","codex_error_info":"usage_limit_exceeded","message":"try again at tomorrow."}\n' > "$d/codex/limit.jsonl"
  printf '{"timestamp":"2026-09-11T00:00:00Z","type":"agent_message"}\n' > "$d/codex/ok.jsonl"
  printf '{"timestamp":"2026-09-11T00:00:00Z","type":"agent_message"}' > "$d/codex/no-trailing-newline.jsonl"
  for eng in claude codex; do
    parser="_limit_${eng}_reading"
    ls "$d/$eng"/*.jsonl > "$d/$eng.list"
    _limit_batched_readings "$eng" "$d/$eng.list" | LC_ALL=C sort > "$d/$eng.batched"
    : > "$d/$eng.perfile"
    while IFS= read -r f; do
      printf '%s\037%s\n' "$f" "$("$parser" "$f")" >> "$d/$eng.perfile"
    done < "$d/$eng.list"
    LC_ALL=C sort -o "$d/$eng.perfile" "$d/$eng.perfile"
    diff "$d/$eng.batched" "$d/$eng.perfile" || { echo "$eng: batched != per-file"; false; }
    [ -s "$d/$eng.batched" ]
  done
}

@test "board (P2-2): the batched bounded read agrees with the per-file parser (codex, grok)" {
  # `_board_cold_sidscope` reads the first 512 bytes of many files in one
  # `head`; `_board_engine_sidscope` reads one file properly. The cold build
  # trusts the first. This asserts they answer the same thing — including on
  # a codex meta line longer than the 512-byte bound, which only the
  # per-file fallback inside _board_cold_sidscope can resolve.
  clikae init codex cx >/dev/null
  clikae init grok gk >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  _board_source
  load_adapter codex >/dev/null 2>&1 || true
  load_adapter grok >/dev/null 2>&1 || true
  local cd_="$CLIKAE_HOME/profiles/codex/cx" gd_="$CLIKAE_HOME/profiles/grok/gk"
  local sd="$cd_/sessions/2026/09/13" i pad
  mkdir -p "$sd"
  for i in 0 1 2; do
    printf '{"id":"1111111%s-0000-0000-0000-000000000000","cwd":"%s/sub %s"}\n' \
      "$i" "$TEST_HOME/work" "$i" > "$sd/rollout-2026-09-13T10-00-0$i-1111111$i-0000-0000-0000-000000000000.jsonl"
  done
  pad="$(head -c 600 /dev/zero | tr '\0' 'x')"
  printf '{"pad":"%s","id":"22222222-0000-0000-0000-000000000000","cwd":"%s"}\n' \
    "$pad" "$TEST_HOME/work" > "$sd/rollout-2026-09-13T11-00-00-22222222-0000-0000-0000-000000000000.jsonl"
  for i in 0 1; do
    mkdir -p "$gd_/sessions/g$i/aaaaaaa$i"
    printf '{\n  "request_id": "zz",\n  "id": "aaaaaaa%s",\n  "cwd": "%s/gr \\"q\\" %s"\n}\n' \
      "$i" "$TEST_HOME/work" "$i" > "$gd_/sessions/g$i/aaaaaaa$i/summary.json"
  done
  local pair eng d rows p ss
  for pair in "codex $cd_" "grok $gd_"; do
    set -- $pair; eng="$1"; d="$2"
    rows="$TEST_HOME/rows.$eng"
    _board_stat_rows "$eng" "$d" > "$rows"
    _board_cold_sidscope "$eng" "$d" "$rows" | LC_ALL=C sort > "$TEST_HOME/batched.$eng"
    : > "$TEST_HOME/perfile.$eng"
    while IFS=$'\037' read -r _ _ p; do
      [ -n "$p" ] || continue
      ss="$(_board_engine_sidscope "$eng" "$p")"
      [ -n "$ss" ] || continue
      printf '%s\037%s\n' "$p" "$ss" >> "$TEST_HOME/perfile.$eng"
    done < "$rows"
    LC_ALL=C sort -o "$TEST_HOME/perfile.$eng" "$TEST_HOME/perfile.$eng"
    diff "$TEST_HOME/batched.$eng" "$TEST_HOME/perfile.$eng" \
      || { echo "$eng: batched != per-file"; false; }
    [ -s "$TEST_HOME/batched.$eng" ]
  done
}

@test "board (P2-3): a transcript that changes PATH but keeps its sid keeps its entry" {
  # Round-7 P2-3: `removed` ran after `changed`, so a file seen at a new path
  # was written by the changed loop and then deleted by the removed loop
  # under the same key. The file was on disk, its resume row was there, and
  # board_find could not resolve it.
  _b8_tank
  mkdir -p "$TEST_HOME/other"
  local other
  other="$B8_TANK/projects/$(_claude_project_slug "$TEST_HOME/other")"
  mkdir -p "$other"
  local i
  for i in 0 1 2; do
    printf '{"type":"ai-title","aiTitle":"T%s"}\n' "$i" > "$B8_PROJ/session-$i.jsonl"
  done
  board_state_refresh claude "$B8_TANK"
  [ "$(board_find claude "$B8_TANK" session-1)" = "$B8_PROJ/session-1.jsonl" ]

  mv "$B8_PROJ/session-1.jsonl" "$other/session-1.jsonl"
  _board_gen_cache_clear
  board_state_refresh claude "$B8_TANK"
  [ "$(board_find claude "$B8_TANK" session-1)" = "$other/session-1.jsonl" ]

  # and a genuinely removed file still stops resolving (the tombstone works
  # through the chain, where `rm -f` on this generation's own name would not)
  rm -f "$other/session-1.jsonl"
  _board_gen_cache_clear
  board_state_refresh claude "$B8_TANK"
  run board_find claude "$B8_TANK" session-1
  [ "$status" -ne 0 ]
}

@test "board (P3-3): a per-file stat failure is not swallowed by the tree walk" {
  # Round-7 P3-3: `2>/dev/null` on the `find` covered the stderr of the
  # `stat` it `-exec`s, so an unreadable file vanished from the fingerprint
  # silently. The one case the redirect existed for — an engine this tank has
  # never used — is answered directly now.
  _b8_tank
  # an engine root this tank has never created: silent, rc=0, no `find` error
  run _board_transcript_find claude "$TEST_HOME/never-used-tank"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "unused tank was not silent: $output"; false; }
  printf '{"type":"ai-title","aiTitle":"T"}\n' > "$B8_PROJ/session-0.jsonl"
  # a directory find cannot descend into must be audible, not silent
  local blocked="$B8_PROJ/blocked"
  mkdir -p "$blocked"
  printf '{}\n' > "$blocked/session-x.jsonl"
  chmod 000 "$blocked"
  run _board_transcript_find claude "$CLIKAE_HOME/profiles/claude/work"
  chmod 755 "$blocked"
  if [ "$(id -u)" -ne 0 ]; then
    [[ "$output" == *blocked* ]] || { echo "walk error was swallowed: $output"; false; }
  fi
}

@test "board: a rebuilding render walks the tank ONCE, not once to check and once to rebuild" {
  # `board_generation` asks `board_stale` (one `find` + one batched `stat` over
  # every transcript) and then calls `board_state_refresh`, which used to walk
  # and stat the whole tank again. At 5,000 transcripts that second walk is
  # 26 ms of a 127 ms rebuild, paid on every render that changes anything.
  # board_stale now hands its rows over.
  _b8_tank
  local i
  for i in 0 1 2 3 4; do
    printf '{"type":"ai-title","aiTitle":"T%s"}\n' "$i" > "$B8_PROJ/session-$i.jsonl"
  done
  board_state_refresh claude "$B8_TANK"
  _board_gen_cache_clear

  # count `find` invocations across a render that DOES rebuild
  export BOARD_IO_LOG="$TEST_HOME/walk.log"
  mkdir -p "$TEST_HOME/walk-bin"
  { printf '#!/bin/bash\nprintf "find\\n" >> "$BOARD_IO_LOG"\n'
    printf 'exec %q "$@"\n' "$(command -v find)"; } > "$TEST_HOME/walk-bin/find"
  chmod +x "$TEST_HOME/walk-bin/find"
  local saved_path="$PATH"
  PATH="$TEST_HOME/walk-bin:$PATH"
  printf '{"type":"ai-title","aiTitle":"CHANGED"}\n' >> "$B8_PROJ/session-2.jsonl"
  : > "$BOARD_IO_LOG"
  board_generation claude "$B8_TANK" >/dev/null
  PATH="$saved_path"
  local walks
  walks="$(wc -l < "$BOARD_IO_LOG" | tr -d ' ')"
  [ "$walks" -eq 1 ] || { echo "rebuilding render walked the tank $walks times"; false; }

  # and the generation it published is correct + fresh
  local root gen
  root="$(board_root "$B8_TANK")"
  gen="$root/$(cat "$root/current")"
  [ "$(cat "$gen/transcripts-fp")" = "$(_board_transcript_fingerprint claude "$B8_TANK")" ]
  run board_stale claude "$B8_TANK" "$gen"
  [ "$status" -ne 0 ]
  [ -n "$(board_find claude "$B8_TANK" session-2)" ]
  [ -n "$(board_find claude "$B8_TANK" session-0)" ]
}
