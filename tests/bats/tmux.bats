#!/usr/bin/env bats
# Stub-only: never load the shared helpers that create/clean up tmux servers.

setup() {
  export TOUCH_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLIKAE_LIB="$TOUCH_ROOT/lib"
  export TOUCH_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export TOUCH_ACTIONS="$BATS_TEST_TMPDIR/actions.log"
  export TOUCH_Y1=20 TOUCH_ENABLED=on TOUCH_MULTIPLIER=2
  # #108's press-time geometry and its two options. TOUCH_PAGES defaults to
  # `off` here because that is what the product ships: every pre-#108 case in
  # this file must therefore keep passing with these exports in place, which
  # is the assertion that the new feature changes nothing until asked for.
  export TOUCH_H=24 TOUCH_PAGES=off TOUCH_PAGES_ROWS=3 TOUCH_SCROLL_POS=0
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
      @clikae_touch_h) printf '%s' "$TOUCH_H" ;;
      @clikae_touch_scroll) printf '%s' "$TOUCH_ENABLED" ;;
      @clikae_touch_scroll_lines) printf '%s' "$TOUCH_MULTIPLIER" ;;
      @clikae_touch_pages) printf '%s' "$TOUCH_PAGES" ;;
      @clikae_touch_pages_rows) printf '%s' "$TOUCH_PAGES_ROWS" ;;
    esac ;;
  display-message) printf '%s' "$TOUCH_SCROLL_POS" ;;
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
  # #108: paging ships OFF (it re-purposes a click that reaches the program),
  # with a 3-row band — and rides the SAME `-og` chain, so a human's existing
  # setting survives a later launch exactly like the touch-scroll pair's does.
  [[ "$output" == *'<set-option><-og><@clikae_touch_pages><off><;><set-option><-og><@clikae_touch_pages_rows><3>'* ]] || false
  # The press records BOTH halves of the geometry the band is measured against
  # (#108): the row, and the pane height AT PRESS TIME.
  [[ "$output" == *'<bind-key><-T><root><MouseDown1Pane><set-option -p -t = -F @clikae_touch_y "#{mouse_y}"; set-option -p -t = -F @clikae_touch_h "#{pane_height}"; select-pane -t =; send-keys -M>'* ]] || false
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
    [[ "$output" == *"<bind-key><-T><$table><MouseDown1Pane><set-option -p -t = -F @clikae_touch_y \"#{mouse_y}\"; set-option -p -t = -F @clikae_touch_h \"#{pane_height}\"; select-pane -t =>"* ]] || false
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
  [[ "$output" != *'@clikae_touch_pages'* ]] || false
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

@test "touch: tmux floor — 3.0 is below it, 3.1 is at it (version-gate boundary, P3-3)" {
  # P3-3 (2026-09 R2 review): the earlier stub only proved the gate fires
  # SOMEWHERE, at 3.0 (skip) and the 3.4 default (install) — any floor
  # anywhere in (3.0, 3.4] made both of those cases pass, including a wrong
  # one. Pin the actual boundary tmux itself changed at: `set-option -p`/`-pu`
  # (pane-scoped options, used by every binding this chain installs) shipped
  # in CHANGES FROM 3.0 TO 3.1 — the same floor lib/core/tmux.sh's
  # _tmux_touch_scroll_floor_met and docs/usage.md both declare.
  # shellcheck source=/dev/null
  source "$TOUCH_ROOT/lib/core/tmux.sh"
  _tmux_ssh_agent_link() { return 1; }
  tmux_server_born_note() { :; }

  export TOUCH_TMUX_V='tmux 3.0'
  : > "$TOUCH_LOG"
  run tmux_spawn_session --session clikae-floor-red -- 'echo test'
  [ "$status" -eq 0 ]
  run cat "$TOUCH_LOG"
  [[ "$output" != *'@clikae_touch_scroll'* ]] || false      # RED at 3.0

  export TOUCH_TMUX_V='tmux 3.1'
  : > "$TOUCH_LOG"
  run tmux_spawn_session --session clikae-floor-green -- 'echo test'
  [ "$status" -eq 0 ]
  run cat "$TOUCH_LOG"
  [[ "$output" == *'@clikae_touch_scroll'* ]] || false      # GREEN at 3.1
}

# ── tap zones (#108) ────────────────────────────────────────────────────────
#
# One handler decides both features, so these cases are written as the tree
# they run through: displacement first, then zone, then "leave it alone". The
# real-server receipts (history actually moving one screen, copy-mode actually
# ending) are in tests/bats/touch-pages.bats; what a stub can prove — and what
# a real server proves slowly — is which branch a given touch lands in.

@test "pages: a tap in the top band enters copy-mode and pages up" {
  export TOUCH_PAGES=on TOUCH_Y1=1
  release 1 %7 ''
  [ "$(cat "$TOUCH_ACTIONS")" = $'<copy-mode><-t><%7>\n<send-keys><-t><%7><-X><page-up>' ]
  # Already in copy-mode: page again, do not re-enter (same shape #88 has).
  : > "$TOUCH_ACTIONS"
  release 1 %7 copy-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><page-up>' ]
}

@test "pages: a tap in the bottom band pages down, and at the newest line leaves copy-mode" {
  export TOUCH_PAGES=on TOUCH_Y1=23 TOUCH_SCROLL_POS=22
  release 23 %7 copy-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><page-down>' ]
  # #{scroll_position} 0 IS the live view: there is nothing further forward to
  # page into, so the tap means the same thing #88's tap means — go back.
  : > "$TOUCH_ACTIONS"
  export TOUCH_SCROLL_POS=0
  release 23 %7 copy-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><cancel>' ]
}

@test "pages: a bottom-band tap on a LIVE pane is left to the app" {
  # The root binding already forwarded the release before this helper ran, so
  # the only correct action here is no action at all — pressing page-down on a
  # live pane would drag the pane into copy-mode to show it what it is
  # already showing.
  export TOUCH_PAGES=on TOUCH_Y1=23
  release 23 %7 ''
  [ ! -s "$TOUCH_ACTIONS" ]
}

@test "pages: a tap in the middle band keeps #88's meaning exactly" {
  export TOUCH_PAGES=on TOUCH_Y1=12
  release 12 %7 ''
  [ ! -s "$TOUCH_ACTIONS" ]                       # live pane: an ordinary click
  : > "$TOUCH_ACTIONS"
  release 12 %7 copy-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><cancel>' ]   # #88's tap
}

@test "pages: OFF by default — all three taps are forwarded unchanged" {
  # The whole opt-in claim, stated as the absence of any tmux action. TOUCH_PAGES
  # is `off` in setup() because that is the shipped default.
  local row
  for row in 1 12 23; do
    : > "$TOUCH_ACTIONS"
    export TOUCH_Y1="$row"
    release "$row" %7 ''
    [ ! -s "$TOUCH_ACTIONS" ] || { echo "row $row acted with pages off"; false; }
  done
}

@test "pages: only a recognised on-word turns it on" {
  # 🔴 THE ASYMMETRY IS THE POINT. touch-scroll treats anything that is not an
  # off-word as ON (it has shipped on since #88 and an unreadable option must
  # not remove it); paging treats anything that is not an on-word as OFF (it
  # takes a click away from the program, so it must be asked for). A typo
  # therefore lands on today's behaviour in both cases.
  export TOUCH_Y1=1
  local value
  for value in on On ON 1 yes YES true True; do
    : > "$TOUCH_ACTIONS"
    export TOUCH_PAGES="$value"
    release 1 %7 ''
    [ -s "$TOUCH_ACTIONS" ] || { echo "'$value' did not enable paging"; false; }
  done
  for value in '' off no 0 false enabled onn yep 2; do
    : > "$TOUCH_ACTIONS"
    export TOUCH_PAGES="$value"
    release 1 %7 ''
    [ ! -s "$TOUCH_ACTIONS" ] || { echo "'$value' enabled paging"; false; }
  done
}

@test "pages: the band height option decides where the bands end" {
  export TOUCH_PAGES=on TOUCH_PAGES_ROWS=1
  export TOUCH_Y1=0
  release 0 %7 ''
  [[ "$(cat "$TOUCH_ACTIONS")" == *'<page-up>'* ]] || false      # row 0 is the band
  : > "$TOUCH_ACTIONS"
  export TOUCH_Y1=1
  release 1 %7 ''
  [ ! -s "$TOUCH_ACTIONS" ]                                      # row 1 no longer is
  # A wider band reaches further in from both edges (height 24, N=6).
  : > "$TOUCH_ACTIONS"
  export TOUCH_PAGES_ROWS=6 TOUCH_Y1=5
  release 5 %7 ''
  [[ "$(cat "$TOUCH_ACTIONS")" == *'<page-up>'* ]] || false
  : > "$TOUCH_ACTIONS"
  export TOUCH_Y1=18
  release 18 %7 copy-mode
  [[ "$(cat "$TOUCH_ACTIONS")" == *'<cancel>'* ]] || false        # bottom band, at newest
  # Garbage falls back to 3, it does not disable the feature or divide by it.
  : > "$TOUCH_ACTIONS"
  export TOUCH_PAGES_ROWS=nope TOUCH_Y1=2
  release 2 %7 ''
  [[ "$(cat "$TOUCH_ACTIONS")" == *'<page-up>'* ]] || false
  : > "$TOUCH_ACTIONS"
  export TOUCH_PAGES_ROWS=0 TOUCH_Y1=2
  release 2 %7 ''
  [[ "$(cat "$TOUCH_ACTIONS")" == *'<page-up>'* ]] || false
}

@test "pages: the two bands can never close the middle on a short pane" {
  # 🔴 A touch device has no second button. If the bands met there would be
  # nowhere left on the pane to make an ordinary click, and the default N=3 on
  # a 4-row split is exactly that. N is clamped to (height - 1) / 2.
  export TOUCH_PAGES=on TOUCH_PAGES_ROWS=3 TOUCH_H=4
  export TOUCH_Y1=0
  release 0 %7 ''
  [[ "$(cat "$TOUCH_ACTIONS")" == *'<page-up>'* ]] || false      # row 0: top
  local row
  for row in 1 2; do
    : > "$TOUCH_ACTIONS"
    export TOUCH_Y1="$row"
    release "$row" %7 ''
    [ ! -s "$TOUCH_ACTIONS" ] || { echo "row $row of 4 was not a plain click"; false; }
  done
  : > "$TOUCH_ACTIONS"
  export TOUCH_Y1=3
  release 3 %7 copy-mode
  [[ "$(cat "$TOUCH_ACTIONS")" == *'<cancel>'* ]] || false       # row 3: bottom
  # Two rows leave no room for a band at all: every tap stays a click.
  export TOUCH_H=2
  for row in 0 1; do
    : > "$TOUCH_ACTIONS"
    export TOUCH_Y1="$row"
    release "$row" %7 ''
    [ ! -s "$TOUCH_ACTIONS" ] || { echo "row $row of 2 was banded"; false; }
  done
}

@test "pages: a missing or malformed press height leaves the tap a plain click" {
  export TOUCH_PAGES=on TOUCH_Y1=1
  local value
  for value in '' nope -; do
    : > "$TOUCH_ACTIONS"
    export TOUCH_H="$value"
    release 1 %7 ''
    [ ! -s "$TOUCH_ACTIONS" ] || { echo "height '$value' still banded"; false; }
  done
}

@test "pages: a swipe is still a swipe with paging on (#88 regression)" {
  # Displacement is decided FIRST, so a swipe that starts or ends inside a band
  # — most swipes do, that is where a thumb reaches — still scrolls.
  export TOUCH_PAGES=on TOUCH_Y1=22
  release 2 %7 ''
  [ "$(cat "$TOUCH_ACTIONS")" = $'<copy-mode><-t><%7>\n<send-keys><-t><%7><-X><-N><40><scroll-up>' ]
}

@test "pages: the two options gate independently of each other" {
  # `@clikae_touch_scroll off` is about translating MOVEMENT. Someone who then
  # turns paging on asked for paging, and gets it — while swipes and #88's
  # tap-to-cancel stay off, which is what they asked for first.
  export TOUCH_ENABLED=off TOUCH_PAGES=on
  export TOUCH_Y1=1
  release 1 %7 ''
  [ "$(cat "$TOUCH_ACTIONS")" = $'<copy-mode><-t><%7>\n<send-keys><-t><%7><-X><page-up>' ]
  : > "$TOUCH_ACTIONS"
  export TOUCH_Y1=22
  release 2 %7 ''                       # a swipe, with scroll off
  [ ! -s "$TOUCH_ACTIONS" ]
  : > "$TOUCH_ACTIONS"
  export TOUCH_Y1=12
  release 12 %7 copy-mode               # #88's middle tap-to-cancel, with scroll off
  [ ! -s "$TOUCH_ACTIONS" ]
  # And the mirror: paging off, scrolling on, is exactly pre-#108 behaviour.
  : > "$TOUCH_ACTIONS"
  export TOUCH_ENABLED=on TOUCH_PAGES=off TOUCH_Y1=1
  release 1 %7 copy-mode
  [ "$(cat "$TOUCH_ACTIONS")" = '<send-keys><-t><%7><-X><cancel>' ]
}

@test "pages: both options off is one exit, before any tmux call" {
  export TOUCH_ENABLED=off TOUCH_PAGES=off TOUCH_Y1=1
  : > "$TOUCH_LOG"
  release 1 %7 copy-mode
  [ ! -s "$TOUCH_ACTIONS" ]
  run cat "$TOUCH_LOG"
  [[ "$output" != *'@clikae_touch_y'* ]] || false     # never even read the press
}

@test "pages: @clikae_touch_h is UNSET after one Up, like @clikae_touch_y" {
  # Same structural rule #88 gave the row: the geometry of a touch is read once
  # and destroyed, so an Up with no Down on its own key table finds nothing
  # rather than last touch's pane height. A stale height is how a band ends up
  # measured against a pane that no longer exists at that size.
  local ystate="$BATS_TEST_TMPDIR/ty" hstate="$BATS_TEST_TMPDIR/th"
  printf '%s' 1 > "$ystate"; printf '%s' 24 > "$hstate"
  cat > "$BATS_TEST_TMPDIR/bin/tmux" <<STUB
#!/usr/bin/env bash
case "\$1" in
  show-options)
    case "\${*: -1}" in
      @clikae_touch_y) cat "$ystate" 2>/dev/null ;;
      @clikae_touch_h) cat "$hstate" 2>/dev/null ;;
      @clikae_touch_scroll) printf 'on' ;;
      @clikae_touch_pages) printf 'on' ;;
      @clikae_touch_pages_rows) printf '3' ;;
    esac ;;
  set-option)
    case " \$* " in
      *' -pu '*'@clikae_touch_y'*) : > "$ystate" ;;
      *' -pu '*'@clikae_touch_h'*) : > "$hstate" ;;
    esac ;;
  copy-mode|send-keys)
    printf '<%s>' "\$@" >> "$TOUCH_ACTIONS"
    printf '\n' >> "$TOUCH_ACTIONS" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  release 1 %7 ''
  [ "$(cat "$TOUCH_ACTIONS")" = $'<copy-mode><-t><%7>\n<send-keys><-t><%7><-X><page-up>' ]
  : > "$TOUCH_ACTIONS"
  release 1 %7 ''
  [ ! -s "$TOUCH_ACTIONS" ]
}
