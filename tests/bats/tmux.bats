#!/usr/bin/env bats
# Stub-only: never load the shared helpers that create/clean up tmux servers.

setup() {
  export TOUCH_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLIKAE_LIB="$TOUCH_ROOT/lib"
  export TOUCH_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export TOUCH_ACTIONS="$BATS_TEST_TMPDIR/actions.log"
  export TOUCH_Y1=20 TOUCH_ENABLED=on TOUCH_MULTIPLIER=2
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  : > "$TOUCH_LOG"
  : > "$TOUCH_ACTIONS"
  cat > "$BATS_TEST_TMPDIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf '<%s>' "$@" >> "$TOUCH_LOG"
printf '\n' >> "$TOUCH_LOG"
case "$1" in
  show-options)
    case "${*: -1}" in
      @clikae_touch_y) printf '%s' "$TOUCH_Y1" ;;
      @clikae_touch_scroll) printf '%s' "$TOUCH_ENABLED" ;;
      @clikae_touch_scroll_lines) printf '%s' "$TOUCH_MULTIPLIER" ;;
    esac ;;
  copy-mode|send-keys)
    printf '<%s>' "$@" >> "$TOUCH_ACTIONS"
    printf '\n' >> "$TOUCH_ACTIONS" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

release() {
  run bash "$TOUCH_ROOT/lib/core/touch_scroll.sh" "$@"
  [ "$status" -eq 0 ]
}

@test "touch: launch installs four bindings alongside mouse and preserves configured defaults" {
  # Override filesystem/environment probes; exercise the real constructor.
  # shellcheck source=/dev/null
  source "$TOUCH_ROOT/lib/core/tmux.sh"
  _tmux_ssh_agent_link() { return 1; }
  tmux_server_born_note() { :; }
  run tmux_spawn_session --session clikae-test -- 'echo test'
  [ "$status" -eq 0 ]
  run cat "$TOUCH_LOG"
  [[ "$output" == *'<start-server>'*'<new-session><-d>'* ]] || false
  [[ "$output" == *'<set-option><-g><mouse><on><;><set-option><-og><@clikae_touch_scroll><on><;><set-option><-og><@clikae_touch_scroll_lines><2>'* ]] || false
  [[ "$output" == *'<bind-key><-T><root><MouseDown1Pane><set-option -p -t = -F @clikae_touch_y "#{mouse_y}"; select-pane -t =; send-keys -M>'* ]] || false
  [[ "$output" == *'<bind-key><-T><copy-mode><MouseDown1Pane><set-option -p -t = -F @clikae_touch_y "#{mouse_y}"; select-pane -t =>'* ]] || false
  # P1-1: root's Up FORWARDS the release (send-keys -M) before translating —
  # the only table with an app underneath that needs it; copy-mode's Up has no
  # app to forward to and stays a plain run-shell.
  [[ "$output" == *"<bind-key><-T><root><MouseUp1Pane><send-keys -M; run-shell \"bash '"* ]] || false
  [[ "$output" == *"/core/touch_scroll.sh' #{mouse_y} #{pane_id} #{pane_in_mode}\">"* ]] || false
  [[ "$output" == *"<bind-key><-T><copy-mode><MouseUp1Pane><run-shell><bash '"*"/core/touch_scroll.sh' #{mouse_y} #{pane_id} #{pane_in_mode}>"* ]] || false
  # P1-2: copy-mode-vi mirrors copy-mode exactly — same Down, same plain-run-shell Up.
  [[ "$output" == *"<bind-key><-T><copy-mode-vi><MouseDown1Pane><set-option -p -t = -F @clikae_touch_y \"#{mouse_y}\"; select-pane -t =>"* ]] || false
  [[ "$output" == *"<bind-key><-T><copy-mode-vi><MouseUp1Pane><run-shell><bash '"*"/core/touch_scroll.sh' #{mouse_y} #{pane_id} #{pane_in_mode}>"* ]] || false
  # choose-mode is deliberately left unbound (a tap there must select, not cancel).
  [[ "$output" != *'<-T><choose'* ]] || false
  [[ "$output" != *'<MouseDrag'* ]] || false
  [[ "$output" != *'<Wheel'* ]] || false
}

@test "touch: finger up enters copy-mode and scrolls eight lines" {
  release 16 %7 0
  [ "$(cat "$TOUCH_ACTIONS")" = $'<copy-mode><-t><%7>\n<send-keys><-t><%7><-X><-N><8><scroll-up>' ]
  run cat "$TOUCH_LOG"
  [[ "$output" == *'<show-options><-pqv><-t><%7><@clikae_touch_y>'* ]] || false
}

@test "touch: finger down scrolls down" {
  export TOUCH_Y1=16
  release 20 %7 0
  [ "$(cat "$TOUCH_ACTIONS")" = $'<copy-mode><-t><%7>\n<send-keys><-t><%7><-X><-N><8><scroll-down>' ]
}

@test "touch: swipe already in copy-mode does not re-enter it" {
  release 16 %7 1
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><-N><8><scroll-up>' ]
}

@test "touch: tap in copy-mode cancels including one-row movement" {
  release 20 %7 1
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><cancel>' ]
  : > "$TOUCH_ACTIONS"
  release 19 %7 1
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><cancel>' ]
}

@test "touch: tap outside copy-mode does nothing" {
  release 20 %7 0
  [ ! -s "$TOUCH_ACTIONS" ]
}

@test "touch: multiplier honored at the two-row threshold" {
  export TOUCH_MULTIPLIER=3
  release 18 %7 1
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><-N><6><scroll-up>' ]
}

@test "touch: disabled swipes and taps do nothing" {
  export TOUCH_ENABLED=off
  release 16 %7 0
  release 20 %7 1
  [ ! -s "$TOUCH_ACTIONS" ]
}

@test "touch: missing or malformed coordinates do nothing" {
  export TOUCH_Y1=''
  release 16 %7 0
  export TOUCH_Y1='not-a-row'
  release 16 %7 0
  export TOUCH_Y1=20
  release 'not-a-row' %7 1
  [ ! -s "$TOUCH_ACTIONS" ]
}

@test "touch: unset options and invalid multiplier use defaults" {
  export TOUCH_ENABLED='' TOUCH_MULTIPLIER=''
  release 16 %7 1
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><-N><8><scroll-up>' ]
  local value
  for value in 0 -3 nope; do
    : > "$TOUCH_ACTIONS"
    export TOUCH_MULTIPLIER="$value"
    release 16 %7 1
    [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><-N><8><scroll-up>' ]
  done
}

@test "touch: @clikae_touch_y is UNSET after one Up, so a second Up without a Down does nothing" {
  # P1-2's structural half: not "we remembered to clear it" but "there is
  # nothing left to reuse". A stateful stub pane option: `set-option -pu`
  # clears the same value `show-options -pqv` reads back.
  local statefile="$BATS_TEST_TMPDIR/touch_y_state"
  printf '%s' 20 > "$statefile"
  cat > "$BATS_TEST_TMPDIR/bin/tmux" <<STUB
#!/usr/bin/env bash
case "\$1" in
  show-options)
    case "\${*: -1}" in
      @clikae_touch_y) cat "$statefile" 2>/dev/null ;;
      @clikae_touch_scroll) printf 'on' ;;
      @clikae_touch_scroll_lines) printf '2' ;;
    esac ;;
  set-option)
    case " \$* " in *' -pu '*'@clikae_touch_y'*) : > "$statefile" ;; esac ;;
  copy-mode|send-keys)
    printf '<%s>' "\$@" >> "$TOUCH_ACTIONS"
    printf '\n' >> "$TOUCH_ACTIONS" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  release 16 %7 0
  [ "$(cat "$TOUCH_ACTIONS")" = $'<copy-mode><-t><%7>\n<send-keys><-t><%7><-X><-N><8><scroll-up>' ]
  : > "$TOUCH_ACTIONS"
  release 16 %7 0
  [ ! -s "$TOUCH_ACTIONS" ]
}
