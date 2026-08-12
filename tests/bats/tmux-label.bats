#!/usr/bin/env bats
# tests/bats/tmux-label.bats — what the status bar says.
#
# That corner is on screen for the entire session, and for a long time it showed
# `[ck-claude-x:bash]`: an internal identifier plus the name of the shell that
# launched the engine rather than the engine. Nothing tested it because nothing
# was setting it — tmux was deriving it, and a default nobody chose is exactly
# the kind of thing that never gets looked at.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_switch() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/commands/switch.sh"
}
_src_wake() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/wake.sh"
}

_sess() { printf 'cklbl-%s-%s' "$$" "${BATS_TEST_NUMBER:-0}"; }

teardown() {
  tmux kill-session -t "$(_sess)" 2>/dev/null || true
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

@test "label: the bar names the tank in clikae's words, not the session id" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_switch
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  _switch_tmux_label "$(_sess)" claude work
  run tmux show-options -t "$(_sess)" status-left
  [[ "$output" == *"claude/work"* ]] || false
  # And the internal prefix is gone from what a person reads.
  [[ "$output" != *"ck-"* ]] || false
}

@test "label: the window is named after the engine, not the shell that starts it" {
  # The defect this replaces: three tanks open meant three windows called `bash`,
  # because the launch command is literally `bash -c …`.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_switch
  tmux new-session -d -s "$(_sess)" -n claude 'bash -c "sleep 30"'
  # Turn automatic-rename ON first. tmux ships with it on, but this machine's
  # config has it off — so without this line the assertion below passed with our
  # own `automatic-rename off` deleted, i.e. it was measuring the environment's
  # default and not the code. Set the condition the user actually has.
  tmux set-window-option -t "$(_sess)" automatic-rename on
  _switch_tmux_label "$(_sess)" claude work
  # `-n` alone does not hold: tmux renames a window after whatever is running in
  # it, so the name only survives because automatic-rename is turned off. Forcing
  # a respawn is what makes that visible in under a second — without it this test
  # passed with the option deleted, which is to say it was watching nothing.
  tmux respawn-pane -k -t "$(_sess)" 'sleep 30'
  sleep 1
  run tmux list-windows -t "$(_sess)" -F '#{window_name}'
  [ "$output" = "claude" ]
  [[ "$output" != *bash* ]] || false
  [[ "$output" != *sh ]] || false
}

@test "label: relabelling an existing session is safe to repeat" {
  # It runs on attach as well as on create, so a session started by an older
  # clikae picks the label up too.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_switch
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  _switch_tmux_label "$(_sess)" claude work
  _switch_tmux_label "$(_sess)" claude work
  run tmux show-options -t "$(_sess)" status-left
  [[ "$output" == *"claude/work"* ]] || false
}

@test "label: a session that is gone does not fail the caller" {
  # Cosmetics must never fail a launch — this runs right after the engine starts.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_switch
  run _switch_tmux_label "cklbl-nope-$$" claude work
  [ "$status" -eq 0 ]
}

@test "wake: the countdown reaches the window name, not just its own pane" {
  # Otherwise "it will resume itself" is invisible from the window you are in.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  WAKE_BUFFER_SECONDS=1
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  tmux new-window -d -t "$(_sess)" -n wake 'sleep 30'
  wake_sit "$(_sess)" "$(( $(date +%s) + 40 ))" >/dev/null &
  local sitter=$!
  sleep 2
  run tmux list-windows -t "$(_sess)" -F '#{window_name}'
  { kill "$sitter"; wait "$sitter"; } 2>/dev/null || true
  [[ "$output" == *"wake "* ]] || false      # "wake 39s", not bare "wake"
}
