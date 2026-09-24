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

# ─── @clikae_touch_drag: ON by default, and a launch writes the saved answer ──
# (2026-09-25). Unlike the four `-o` defaults above, the drag option is the
# projection of $CLIKAE_HOME/touch-drag and every launch writes it outright:
# the maintainer's live server still held `off` from a 0.31.0 launch after the
# default changed, and `-o` would have kept it there forever.

_src_pref() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/touch_pref.sh"
}

@test "touch drag pref: absent means on; set writes the first bare line; get reads it back" {
  _src_pref
  rm -f "$CLIKAE_HOME/touch-drag"
  [ "$(touch_drag_pref_raw)" = "unset" ]
  [ "$(touch_drag_pref_get)" = "on" ]
  touch_drag_pref_set off
  [ "$(head -n 1 "$CLIKAE_HOME/touch-drag")" = "off" ]
  [ "$(touch_drag_pref_get)" = "off" ]
  touch_drag_pref_set on
  [ "$(touch_drag_pref_get)" = "on" ]
  [ "$(grep -c . "$CLIKAE_HOME/touch-drag")" = "1" ]
  run touch_drag_pref_set maybe
  [ "$status" -ne 0 ]
  printf 'garbage\n' > "$CLIKAE_HOME/touch-drag"
  [ "$(touch_drag_pref_get)" = "on" ]
}

@test "touch drag: a launch sets ON over a live server an earlier launch left at off" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  rm -f "$CLIKAE_HOME/touch-drag"
  tmux_spawn_session --session rebindA -- 'sleep 30'
  tmux set-option -g @clikae_touch_drag off
  tmux_spawn_session --session rebindB -- 'sleep 30'
  run tmux show-options -gv @clikae_touch_drag
  _kill_probes
  [ "$output" = "on" ] || { echo "a stale off survived the launch: $output"; false; }
}

@test "touch drag: a saved off makes the launch set off" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  printf 'off\n' > "$CLIKAE_HOME/touch-drag"
  tmux_spawn_session --session rebindA -- 'sleep 30'
  run tmux show-options -gv @clikae_touch_drag
  _kill_probes
  [ "$output" = "off" ] || { echo "expected off, got: $output"; false; }
}

@test "touch drag verb: on/off writes the file and changes the live server; status shows both" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  rm -f "$CLIKAE_HOME/touch-drag"
  tmux_spawn_session --session rebindA -- 'sleep 30'
  run "$CLIKAE_TEST_ROOT/bin/clikae" touch drag off
  local off_out="$output" off_rc="$status" file live
  file="$(head -n 1 "$CLIKAE_HOME/touch-drag" 2>/dev/null)"
  live="$(tmux show-options -gv @clikae_touch_drag)"
  run "$CLIKAE_TEST_ROOT/bin/clikae" touch
  local st="$output"
  run "$CLIKAE_TEST_ROOT/bin/clikae" touch drag on
  local live_on; live_on="$(tmux show-options -gv @clikae_touch_drag)"
  _kill_probes
  [ "$off_rc" -eq 0 ] || { echo "rc=$off_rc: $off_out"; false; }
  [[ "$off_out" == *"touch drag: off"* ]] || { echo "$off_out"; false; }
  [ "$file" = "off" ] || { echo "file: $file"; false; }
  [ "$live" = "off" ] || { echo "live: $live"; false; }
  [[ "$st" == *"touch drag: off"* ]] && [[ "$st" == *"running tmux server: off"* ]] || { echo "$st"; false; }
  [ "$live_on" = "on" ] || { echo "live after on: $live_on"; false; }
  [ "$(head -n 1 "$CLIKAE_HOME/touch-drag")" = "on" ]
}
