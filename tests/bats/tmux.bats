#!/usr/bin/env bats
# Stub-only: never load the shared helpers that create/clean up tmux servers.

setup() {
  export TOUCH_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLIKAE_LIB="$TOUCH_ROOT/lib"
  export TOUCH_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export TOUCH_ACTIONS="$BATS_TEST_TMPDIR/actions.log"
  export TOUCH_Y1=20 TOUCH_ENABLED=on TOUCH_MULTIPLIER=2
  export TOUCH_TMUX_V='tmux 3.4'   # feeds _tmux_touch_scroll_floor_met (needs >= 3.1)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  : > "$TOUCH_LOG"
  : > "$TOUCH_ACTIONS"
  cat > "$BATS_TEST_TMPDIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf '<%s>' "$@" >> "$TOUCH_LOG"
printf '\n' >> "$TOUCH_LOG"
case "$1" in
  -V) printf '%s' "$TOUCH_TMUX_V" ;;
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

@test "touch: launch installs bindings on root/copy-mode/copy-mode-vi, forwards the release, and preserves configured defaults" {
  # Override filesystem/environment probes; exercise the real constructor.
  # shellcheck source=/dev/null
  source "$TOUCH_ROOT/lib/core/tmux.sh"
  _tmux_ssh_agent_link() { return 1; }
  tmux_server_born_note() { :; }
  run tmux_spawn_session --session clikae-test -- 'echo test'
  [ "$status" -eq 0 ]
  run cat "$TOUCH_LOG"
  [[ "$output" == *'<start-server>'*'<new-session><-d>'* ]] || false
  # mouse on stands alone now — not chained with the touch-scroll bindings, so
  # it still installs even below the touch-scroll version floor.
  [[ "$output" == *'<set-option><-g><mouse><on>'* ]] || false
  [[ "$output" == *'<set-option><-og><@clikae_touch_scroll><on><;><set-option><-og><@clikae_touch_scroll_lines><2>'* ]] || false
  [[ "$output" == *'<bind-key><-T><root><MouseDown1Pane><set-option -p -t = -F @clikae_touch_y "#{mouse_y}"; select-pane -t =; send-keys -M>'* ]] || false
  # P1-1: root's Up FORWARDS the release (send-keys -M) before translating —
  # the only table with an app underneath that needs it.
  [[ "$output" == *"<bind-key><-T><root><MouseUp1Pane><send-keys -M; run-shell \"bash '"* ]] || false
  # P2-1 (2026-09 R2 review): the binding passes #{pane_mode} — the mode NAME
  # — not #{pane_in_mode}'s stack-depth count, so the helper can tell
  # copy-mode/view-mode (act) apart from tree-mode/clock-mode/choose-* (no-op)
  # instead of guessing from a number.
  [[ "$output" == *"/core/touch_scroll.sh' #{mouse_y} #{pane_id} #{pane_mode}\">"* ]] || false
  # P1-2: copy-mode-vi mirrors copy-mode exactly — same Down, same plain-run-shell Up.
  local table
  for table in copy-mode copy-mode-vi; do
    [[ "$output" == *"<bind-key><-T><$table><MouseDown1Pane><set-option -p -t = -F @clikae_touch_y \"#{mouse_y}\"; select-pane -t =>"* ]] || false
    [[ "$output" == *"<bind-key><-T><$table><MouseUp1Pane><run-shell><bash '"*"/core/touch_scroll.sh' #{mouse_y} #{pane_id} #{pane_mode}>"* ]] || false
  done
  # choose-mode is deliberately left unbound (a tap there must select, not cancel).
  [[ "$output" != *'<-T><choose'* ]] || false
  [[ "$output" != *'<MouseDrag'* ]] || false
  [[ "$output" != *'<Wheel'* ]] || false
}

@test "touch: below the tmux floor, mouse still installs but the touch-scroll chain is skipped" {
  # P3-1: no ordering luck — an explicit floor, not a bind-key abort mid-chain.
  export TOUCH_TMUX_V='tmux 3.0'
  # shellcheck source=/dev/null
  source "$TOUCH_ROOT/lib/core/tmux.sh"
  _tmux_ssh_agent_link() { return 1; }
  tmux_server_born_note() { :; }
  run tmux_spawn_session --session clikae-test -- 'echo test'
  [ "$status" -eq 0 ]
  run cat "$TOUCH_LOG"
  [[ "$output" == *'<set-option><-g><mouse><on>'* ]] || false
  [[ "$output" != *'@clikae_touch_scroll'* ]] || false
  [[ "$output" != *'<bind-key>'* ]] || false
}

@test "touch: finger up enters copy-mode and scrolls eight lines" {
  release 16 %7 ''
  [ "$(cat "$TOUCH_ACTIONS")" = $'<copy-mode><-t><%7>\n<send-keys><-t><%7><-X><-N><8><scroll-up>' ]
  run cat "$TOUCH_LOG"
  [[ "$output" == *'<show-options><-pqv><-t><%7><@clikae_touch_y>'* ]] || false
}

@test "touch: finger down scrolls down" {
  export TOUCH_Y1=16
  release 20 %7 ''
  [ "$(cat "$TOUCH_ACTIONS")" = $'<copy-mode><-t><%7>\n<send-keys><-t><%7><-X><-N><8><scroll-down>' ]
}

@test "touch: swipe already in copy-mode does not re-enter it" {
  release 16 %7 copy-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><-N><8><scroll-up>' ]
}

@test "touch: view-mode (the P2-2 stacked-view-mode case) is still already-in-mode" {
  # P2-2 (2026-09 R1 review): a run-shell that prints output stacks its own
  # view-mode over an existing copy-mode. That case now arrives here as
  # mode=view-mode (P2-1, R2 review, replaced the #{pane_in_mode} count), and
  # view-mode is one of the two mode names this helper acts in.
  release 16 %7 view-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><-N><8><scroll-up>' ]
  : > "$TOUCH_ACTIONS"
  release 20 %7 view-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><cancel>' ]
}

@test "touch: tap in copy-mode cancels including one-row movement" {
  release 20 %7 copy-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><cancel>' ]
  : > "$TOUCH_ACTIONS"
  release 19 %7 copy-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><cancel>' ]
}

@test "touch: tap outside copy-mode does nothing" {
  release 20 %7 ''
  [ ! -s "$TOUCH_ACTIONS" ]
}

@test "touch: tree-mode and clock-mode do nothing at all, tap or swipe (P2-1)" {
  # These mode names have no `send-keys -X` command table; the old code (a
  # count) treated any nonzero depth as "already in a mode" and dispatched a
  # send-keys call that failed with tmux's own `not in a mode`, which
  # run-shell then rendered as a view-mode box over the picker/clock. The
  # helper now exits before making any tmux call at all for these modes —
  # not even the show-options reads below the mode guard.
  local m
  for m in tree-mode clock-mode; do
    : > "$TOUCH_ACTIONS"; : > "$TOUCH_LOG"
    release 20 "%7" "$m"                     # tap
    [ ! -s "$TOUCH_ACTIONS" ]
    [ ! -s "$TOUCH_LOG" ]
    : > "$TOUCH_ACTIONS"; : > "$TOUCH_LOG"
    release 16 "%7" "$m"                     # swipe
    [ ! -s "$TOUCH_ACTIONS" ]
    [ ! -s "$TOUCH_LOG" ]
  done
}

@test "touch: an unrecognized #{pane_mode} string is a no-op, not a crash" {
  # choose-mode, choose-mode-vi, or any future tmux mode name this helper
  # does not know about must fail closed the same way tree-mode/clock-mode do.
  release 16 %7 garbage
  [ ! -s "$TOUCH_ACTIONS" ]
}

@test "touch: multiplier honored at the two-row threshold" {
  export TOUCH_MULTIPLIER=3
  release 18 %7 copy-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><-N><6><scroll-up>' ]
}

@test "touch: disabled swipes and taps do nothing" {
  export TOUCH_ENABLED=off
  release 16 %7 ''
  release 20 %7 copy-mode
  [ ! -s "$TOUCH_ACTIONS" ]
}

@test "touch: @clikae_touch_scroll off is recognized case-insensitively" {
  # P3-1 (2026-09 R2 review): OFF/OFf/off must all disable, silently and
  # consistently — a human at `Ctrl-b :` cannot be expected to hit the exact
  # case the case-arm happened to be written in. bash 3.2 has no ${var,,}.
  local v
  for v in off OFF Off oFf 0 no NO No false FALSE False; do
    : > "$TOUCH_ACTIONS"
    export TOUCH_ENABLED="$v"
    release 16 %7 ''
    [ ! -s "$TOUCH_ACTIONS" ]
  done
}

@test "touch: values that only resemble 'off' still scroll" {
  # Case-folding must not become substring matching: only the exact tokens
  # (case-insensitively) disable; anything else keeps translating.
  local v
  for v in on 1 yes true offline nooo ' off' 'off '; do
    : > "$TOUCH_ACTIONS"
    export TOUCH_ENABLED="$v"
    release 16 %7 ''
    [ -s "$TOUCH_ACTIONS" ]
  done
}

@test "touch: missing or malformed coordinates do nothing" {
  export TOUCH_Y1=''
  release 16 %7 ''
  export TOUCH_Y1='not-a-row'
  release 16 %7 ''
  export TOUCH_Y1=20
  release 'not-a-row' %7 copy-mode
  [ ! -s "$TOUCH_ACTIONS" ]
}

@test "touch: unset options and invalid multiplier use defaults" {
  export TOUCH_ENABLED='' TOUCH_MULTIPLIER=''
  release 16 %7 copy-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><-N><8><scroll-up>' ]
  local value
  for value in 0 -3 nope; do
    : > "$TOUCH_ACTIONS"
    export TOUCH_MULTIPLIER="$value"
    release 16 %7 copy-mode
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
  release 16 %7 ''
  [ "$(cat "$TOUCH_ACTIONS")" = $'<copy-mode><-t><%7>\n<send-keys><-t><%7><-X><-N><8><scroll-up>' ]
  : > "$TOUCH_ACTIONS"
  release 16 %7 ''
  [ ! -s "$TOUCH_ACTIONS" ]
}
