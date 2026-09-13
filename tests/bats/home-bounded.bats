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

@test "home: a claude limit appended to the 11th-newest session in its project is visible (round-5 P2-2)" {
  [ -d "$CLIKAE_HOME/profiles/claude/work" ] || clikae init claude work >/dev/null
  mkdir -p "$TEST_HOME/work"
  cd "$TEST_HOME/work" || return 1
  _board_source
  load_adapter claude
  local slug dir i stamp
  slug="$(_claude_project_slug "$PWD")"
  dir="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$dir/projects/$slug"
  # 11 real sessions, session-0 newest down to session-10 oldest — round-4's
  # per-project top-10 recorded set would have watched session-0..session-9
  # only, dropping session-10 (the 11th) entirely.
  for ((i = 0; i < 11; i++)); do
    printf '{"type":"ai-title","aiTitle":"Fixture %s"}\n' "$i" > "$dir/projects/$slug/session-$i.jsonl"
    stamp="$(date -v-${i}H '+%Y%m%d%H%M' 2>/dev/null || date -d "$i hours ago" '+%Y%m%d%H%M')"
    touch -t "$stamp" "$dir/projects/$slug/session-$i.jsonl"
  done
  board_state_refresh claude "$dir"
  local _CLIKAE_BOARD=1
  run limit_profile_dry claude "$dir"
  [ "$status" -ne 0 ]
  printf '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · resets 11pm"}]},"timestamp":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$dir/projects/$slug/session-10.jsonl"
  run limit_profile_dry claude "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resets 11pm"* ]] || false
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

