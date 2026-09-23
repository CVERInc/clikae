#!/usr/bin/env bats
# tests/bats/watch-compact.bats — the warm /compact (#131), against a real tmux
# session on the suite's own server (helpers.bash isolates it).
#
# Like wake.bats, most of these assert that it REFUSES: typing into a live
# session is the risk, and each guard gets a test that holds everything else
# true and flips only that one thing.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/wake.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/compact.sh"
  export COMPACT_SETTLE=1 CLIKAE_COMPACT_DEBUG=1
  # helpers.bash turns the feature off suite-wide; this file tests it from the
  # first-launch state.
  rm -f "$CLIKAE_HOME/warm-compact"
}

S=""
SID="0b4a1c55-1111-4222-8333-944455556666"

_sess() { printf 'ckcmp-%s-%s' "$$" "${BATS_TEST_NUMBER:-0}"; }

# _usage <input> <creation> <read> -> one assistant transcript line.
_usage() {
  printf '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":9}}}\n' "$1" "$2" "$3"
}

# _transcript <context-read-tokens> -> the session's transcript, with one real
# turn whose context is 10 + 0 + <n>, and a synthetic zero-usage line after it.
_transcript() {
  TX="$CLIKAE_HOME/profiles/claude/t1/projects/-p/$SID.jsonl"
  mkdir -p "${TX%/*}"
  { printf '{"type":"user","message":{"content":"hi"}}\n'
    _usage 10 0 "$1"
    _usage 0 0 0
  } > "$TX"
}

# _pane <draft> -> a session whose screen ends in a prompt line holding <draft>,
# and which records the first line typed into it.
_pane() {
  S="$(_sess)"; TYPED="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$S" -x 120 -y 20 \
    "printf 'claude\n\n> %s\n' '$1'; IFS= read -r l; printf '%s' \"\$l\" > '$TYPED'; sleep 30"
  tmux set-option -t "=$S:" @clikae_session_id "$SID"
  sleep 1
}

_idle_now() { printf '%s' $(( $(_compact_mtime "$TX") + COMPACT_IDLE_SECONDS + 5 )); }

teardown() {
  [ -n "$S" ] && tmux kill-session -t "=$S" 2>/dev/null
  return 0
}

@test "compact: context is read from the transcript's last REAL usage" {
  _src
  _transcript 250000
  run compact_context_tokens "$TX"
  [ "$status" -eq 0 ]
  [ "$output" = $'250010\t0' ]
}

@test "compact: prompt-line reader — empty, drafted, boxed, and absent" {
  _src
  compact_prompt_line_empty $'out\n> \n'
  compact_prompt_line_empty $'╭──╮\n│ >                │\n╰──╯'
  compact_prompt_line_empty $'x\n❯'
  ! compact_prompt_line_empty $'x\n> half a thought' || false
  ! compact_prompt_line_empty $'│ > draft   │' || false
  # No prompt on screen at all: fail safe, never "empty".
  ! compact_prompt_line_empty $'Thinking…\nesc to interrupt' || false
}

@test "compact: idle, big, empty prompt -> types /compact once and traces it" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _src
  _transcript 250000; _pane ""
  local now; now="$(_idle_now)"
  run compact_tick claude t1 "$S" "$now"
  [ "$status" -eq 0 ]
  sleep 1
  [ "$(cat "$TYPED")" = "/compact" ]
  local log; log="$(wake_log_file claude t1 "")"
  grep -q $'\tcompact-sent\tcontext=250010 idle=' "$log"
}

@test "compact: one send per idle period — the next tick holds" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _src
  _transcript 250000; _pane ""
  local now; now="$(_idle_now)"
  compact_tick claude t1 "$S" "$now" >/dev/null
  run compact_tick claude t1 "$S" "$((now + 60))"
  [ "$status" -eq 1 ]
  [ "$output" = "hold: sent-this-period" ]
  [ "$(grep -c 'compact-sent' "$(wake_log_file claude t1 "")")" -eq 1 ]
}

@test "compact: the next turn's numbers are traced as compact-verified" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _src
  _transcript 250000; _pane ""
  compact_tick claude t1 "$S" "$(_idle_now)" >/dev/null
  # What the engine writes after a compaction: a boundary, then a real turn.
  { printf '{"type":"system","subtype":"compact_boundary"}\n'
    _usage 3 21000 0
  } >> "$TX"
  compact_tick claude t1 "$S" "$(date +%s)" >/dev/null || true
  grep -q $'\tcompact-verified\tbefore=250010 after_cache_creation=21000 after_context=21003' \
    "$(wake_log_file claude t1 "")"
}

@test "compact: not idle long enough -> holds, nothing typed" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  _transcript 250000; _pane ""
  run compact_tick claude t1 "$S" "$(( $(_idle_now) - 60 ))"
  [ "$status" -eq 1 ]
  [ "$output" = "hold: not-idle" ]
  [ ! -e "$TYPED" ]
}

@test "compact: a drafted prompt line -> holds (never while typing)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _src
  _transcript 250000; _pane "half a thought"
  run compact_tick claude t1 "$S" "$(_idle_now)"
  [ "$status" -eq 1 ]
  [ "$output" = "hold: typing" ]
  [ ! -e "$TYPED" ]
}

@test "compact: a moving screen (turn running) -> holds" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _src
  _transcript 250000
  S="$(_sess)"
  tmux new-session -d -s "$S" -x 120 -y 20 \
    "while :; do clear; echo \"working \$RANDOM\"; printf '> \n'; sleep 0.2; done"
  tmux set-option -t "=$S:" @clikae_session_id "$SID"
  sleep 1
  run compact_tick claude t1 "$S" "$(_idle_now)"
  [ "$status" -eq 1 ]
  [ "$output" = "hold: pane-busy" ]
}

@test "compact: context below the threshold -> holds; the threshold is tunable" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _src
  _transcript 150000; _pane ""
  run compact_tick claude t1 "$S" "$(_idle_now)"
  [ "$status" -eq 1 ]
  [ "$output" = "hold: small-context" ]
  [ ! -e "$TYPED" ]
  CLIKAE_COMPACT_MIN_TOKENS=100000 run compact_tick claude t1 "$S" "$(_idle_now)"
  [ "$status" -eq 0 ]
}

@test "compact: preference — unset is on, global off, per-tank off, env override" {
  _src
  [ "$(compact_pref_get)" = "unset" ]
  compact_enabled claude t1
  compact_pref_set off
  ! compact_enabled claude t1 || false
  CLIKAE_WARM_COMPACT=on compact_enabled claude t1
  compact_pref_set on
  compact_pref_set off claude t1
  [ "$(compact_pref_get)" = "on" ]
  ! compact_enabled claude t1 || false
  compact_enabled claude t2
  compact_pref_set on claude t1
  compact_enabled claude t1
  CLIKAE_WARM_COMPACT=off run compact_enabled claude t1
  [ "$status" -eq 1 ]
}

@test "compact: an opted-out tank holds before touching the pane" {
  _src
  _transcript 250000
  compact_pref_set off claude t1
  run compact_tick claude t1 "nosuch" "$(_idle_now)"
  [ "$output" = "hold: pref" ]
}

@test "compact: ask-once is silent with nobody to ask, and leaves the default" {
  _src
  run compact_ask_once claude t1 < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(compact_pref_get)" = "unset" ]
}

@test "compact: ask-once in a terminal records the answer (yes -> on, no -> off)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  # [ -t 0 ] needs a tty; run the ask inside a pty.
  _pty_run bash -c ". '$CLIKAE_TEST_ROOT/lib/core/log.sh'; . '$CLIKAE_TEST_ROOT/lib/core/compact.sh'; confirm() { return 0; }; compact_ask_once claude t1" >/dev/null 2>&1 || true
  [ "$(compact_pref_get)" = "on" ]
  rm -f "$(compact_pref_file)"
  _pty_run bash -c ". '$CLIKAE_TEST_ROOT/lib/core/log.sh'; . '$CLIKAE_TEST_ROOT/lib/core/compact.sh'; confirm() { return 1; }; compact_ask_once claude t1" >/dev/null 2>&1 || true
  [ "$(compact_pref_get)" = "off" ]
}

@test "compact: the CLI sets and shows the preference and the trace" {
  _src
  run "$CLIKAE_BIN" watch compact off claude t1
  [ "$status" -eq 0 ]
  compact_tank_off claude t1
  wake_trace claude t1 s compact-sent "context=250010 idle=3005s"
  run "$CLIKAE_BIN" watch compact status claude t1
  [ "$status" -eq 0 ]
  [[ "$output" == *"warm /compact: on"* ]] || false
  [[ "$output" == *"claude/t1"* ]] || false
  [[ "$output" == *"compact-sent"*"context=250010"* ]] || false
}
