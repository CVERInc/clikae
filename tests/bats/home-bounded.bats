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
  for tool in head tail stat; do
    real="$(command -v "$tool")"
    {
      printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "$BOARD_IO_LOG"\n' "$tool"
      printf 'exec %q "$@"\n' "$real"
    } > "$TEST_HOME/io-bin/$tool"
    chmod +x "$TEST_HOME/io-bin/$tool"
  done
  # A render must never discover transcripts. Make any find invocation fail
  # loudly as well as recording it (a swallowed error must still fail the test).
  printf '#!/bin/bash\necho FIND >> "$BOARD_IO_LOG"\nexit 99\n' > "$TEST_HOME/io-bin/find"
  chmod +x "$TEST_HOME/io-bin/find"
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
  # Counts include pipeline-only head/tail calls and both BSD/GNU stat probes.
  [ "$small" -le 160 ]
  ! grep -q FIND "$BOARD_IO_LOG" || false
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
  [ "$large" -le 160 ]
  ! grep -q FIND "$BOARD_IO_LOG" || false
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

@test "home: missing state self-heals inline once, then reads are bounded again" {
  # 2026-09-12 round-1 fix review, P1-2: a board with NO snapshot at all for
  # this tank (never launched through a session boundary — `clikae alias` /
  # `env` / a `.app` bundle never call board_state_refresh) used to render an
  # empty Resume section forever, silently, with no way to self-correct. Now
  # board_generation (lib/core/board_state.sh) rebuilds the ONE missing tank
  # inline the first time anything reads it — so the render must show the
  # fixture immediately, at the cost of exactly one discovery pass for that
  # one tank — and every render after that is bounded again, with no further
  # discovery, because the rebuild it just did is what the second render
  # reads back.
  _board_fixture 10
  rm -rf "$CLIKAE_HOME/state/board"
  # A SOFT find shim for this first render: it must still discover the real
  # fixture (unlike _board_shims' hard-failing find below, which exists to
  # prove the OPPOSITE — that a second render does not discover anything).
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
  # Now the strict shim: a SECOND render must read back what the first one
  # just self-healed, with no further discovery at all.
  _board_shims
  : > "$BOARD_IO_LOG"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fixture"* ]] || false
  ! grep -q FIND "$BOARD_IO_LOG" || false
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
  ! grep -q FIND "$BOARD_IO_LOG" || false
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
  ! grep -q FIND "$BOARD_IO_LOG" || false
  ! grep -E '^(head|tail).*\.jsonl' "$BOARD_IO_LOG" || false
  PATH="${PATH#*:}"
  printf '{"timestamp":"2026-09-12T00:01:00Z","type":"agent_message"}\n' >> "$f"
  board_state_refresh codex "$dir"
  run limit_profile_dry codex "$dir"
  [ "$status" -eq 1 ]
}

@test "home: grok recent and live lookup use snapshots without discovery" {
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
  ! grep -q FIND "$BOARD_IO_LOG" || false
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
