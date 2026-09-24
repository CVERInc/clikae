#!/usr/bin/env bats
# The touch-scroll bindings must be rewritten on EVERY launch, not only on
# the server's first. Until 2026-09-24 they sat in one `\;` list behind five
# `set-option -o` defaults; `-o` fails with "already set" on any later launch
# and tmux stops the list there, so the bind-keys silently never ran again.
# Receipt: after a 0.33.0 launch the live server still held nine bindings
# naming a 0.31.0 directory that brew had deleted.

load '../helpers'

_src_tmux() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
}

_kill_probes() {
  tmux kill-session -t '=rebindA' 2>/dev/null || true
  tmux kill-session -t '=rebindB' 2>/dev/null || true
}

@test "touch: a second launch on a live server rewrites bindings that name a vanished directory" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  tmux_spawn_session --session rebindA -- 'sleep 30'
  # Specimen: a binding left by an older install whose directory is gone.
  tmux bind-key -T root MouseUp1Pane "send-keys -M; run-shell \"bash '/gone/0.0.0/lib/core/touch_scroll.sh' #{mouse_y} #{pane_id} #{pane_mode}\""
  run bash -c 'tmux list-keys | grep -c "/gone/0.0.0/"'
  [ "$output" = "1" ] || { _kill_probes; echo "specimen not planted: $output"; false; }
  tmux_spawn_session --session rebindB -- 'sleep 30'
  run bash -c 'tmux list-keys | grep -c "/gone/0.0.0/"'
  local stale="$output"
  run bash -c "tmux list-keys | grep -c '$CLIKAE_HOME/runtime/lib/core/touch_scroll.sh'"
  local fresh="$output"
  _kill_probes
  [ "$stale" = "0" ] || { echo "stale binding survived a launch: $stale"; false; }
  [ "$fresh" -ge 9 ] || { echo "expected at least 9 runtime bindings, got $fresh"; false; }
}

@test "touch: an operator's own default survives a later launch (set-option -o still honoured)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  tmux_spawn_session --session rebindA -- 'sleep 30'
  tmux set-option -g @clikae_touch_scroll_lines 7
  tmux_spawn_session --session rebindB -- 'sleep 30'
  run tmux show-options -gv @clikae_touch_scroll_lines
  _kill_probes
  [ "$output" = "7" ] || { echo "operator value overwritten: $output"; false; }
}
