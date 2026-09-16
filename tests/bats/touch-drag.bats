#!/usr/bin/env bats
# tests/bats/touch-drag.bats — the drag stream (#108, second half), against a
# REAL tmux server.
#
# 🔴 WHY A REAL SERVER, AND WHY SOME OF IT NEEDS A REAL CLIENT. #88 shipped
# green on a stub suite and did not work on the device it was written for: the
# stub could prove which branch a MouseUp took, and the defect was that the
# phone sends no MouseUp at all. tests/bats/tmux.bats still proves the binding
# STRINGS (that is what a stub is good at); everything here asks tmux itself.
#
# Three of these tests go one further and drive a real CLIENT with real SGR
# mouse bytes, because the questions they ask — "does the program under the
# pane still receive a click", "is `off` really stock tmux" — are about tmux's
# key tables and its mouse forwarding, neither of which any amount of calling
# the helper by hand can reach. The pty comes from a SECOND tmux server whose
# pane runs `tmux -S <first socket> attach`; bytes typed into the host pane are
# bytes arriving on the client's terminal.
#
# Every server is this file's own socket from `mktemp -d` and is killed through
# that socket by path (`env -u TMUX`, `-S <path>`, always). The servers this
# file creates directly also pass `-f /dev/null`, because the developer
# machine's own ~/.tmux.conf otherwise answers the question "what does stock
# tmux do here" and it is not stock — a first pass at these tests read clikae's
# own installed bindings back as the default. The three client tests instead go
# through the product's own installer (`_install`), which passes no `-f`; they
# are safe because tests/helpers.bash gives every test a throwaway $HOME, so
# there is no ~/.tmux.conf to read.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_sock() { printf '%s/sock' "$CK_SOCKDIR"; }
_t() { command env -u TMUX PATH="$CK_PATH" "$CK_TMUX" -S "$(_sock)" "$@"; }

_helper() { printf '%s/lib/core/touch_scroll.sh' "$CLIKAE_TEST_ROOT"; }

# _base — the socket, the `tmux` wrapper the helper will find on PATH (it calls
# a bare `tmux`, exactly as tmux's own run-shell leaves it), and the two panes'
# launcher scripts.
_base() {
  CK_PATH="$PATH"
  CK_TMUX="$(command -v tmux)"
  # Reuse a directory a test made first (the tap test has to write its pane
  # script before the server exists); one directory per test, cleaned once.
  [ -n "${CK_SOCKDIR:-}" ] || CK_SOCKDIR="$(mktemp -d)"
  mkdir -p "$CK_SOCKDIR/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec env -u TMUX PATH=%q %q -S %q "$@"\n' "$CK_PATH" "$CK_TMUX" "$(_sock)"
  } > "$CK_SOCKDIR/bin/tmux"
  chmod +x "$CK_SOCKDIR/bin/tmux"
}

# _echo_pane <file> <alt: 1|0> — a pane that turns on SGR mouse reporting and
# then echoes every byte it receives, unbuffered, so the test can read what the
# APPLICATION got rather than what tmux was asked to send. `stty -icanon` is
# load-bearing: in canonical mode `cat` holds the bytes until a newline that a
# mouse report never contains.
_echo_pane() {
  local out="$1" alt="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'stty -icanon -echo min 1 time 0\n'
    [ "$alt" = "1" ] && printf "printf '\\\\033[?1049h'\n"
    printf "printf '\\\\033[?1000h\\\\033[?1006h'\n"
    printf 'exec cat -v\n'
  } > "$out"
  chmod +x "$out"
}

# _server <height> — a detached session whose pane has real scrollback to
# scroll through.
_server() {
  local height="${1:-24}" waited=0
  _base
  _t -f /dev/null new-session -d -s drag -x 80 -y "$height" 'sh -c "seq 1 400; sleep 300"'
  CK_PANE="$(_t display-message -p -t '=drag:' '#{pane_id}')"
  CK_H="$(_t display-message -p -t "$CK_PANE" '#{pane_height}')"
  _t set-option -g @clikae_touch_scroll on
  _t set-option -g @clikae_touch_drag on
  while [ "$waited" -lt 25 ]; do
    [ "$(_t capture-pane -p -t "$CK_PANE" | grep -c '400')" -gt 0 ] && break
    sleep 0.2
    waited=$(( waited + 1 ))
  done
}

_cleanup() {
  [ -n "${CK_HOSTDIR:-}" ] && {
    command env -u TMUX "$CK_TMUX" -S "$CK_HOSTDIR/sock" kill-server 2>/dev/null || true
    rm -rf "$CK_HOSTDIR"
    CK_HOSTDIR=
  }
  [ -n "${CK_SOCKDIR:-}" ] || return 0
  _t kill-server 2>/dev/null || true
  rm -rf "$CK_SOCKDIR"
}

# _press <row> — what MouseDown1Pane writes, at the scope it writes it at.
_press() {
  _t set-option -p -t "$CK_PANE" @clikae_touch_y "$1"
  _t set-option -p -t "$CK_PANE" @clikae_touch_h "$CK_H"
}

# _phase <row> <mode> <phase> [pane] — the helper, run the way if-shell runs it.
_phase() {
  local pane="${4:-$CK_PANE}"
  PATH="$CK_SOCKDIR/bin:$CK_PATH" command env -u TMUX \
    bash "$(_helper)" "$1" "$pane" "$2" "$3" 5
}

_mode() { _t display-message -p -t "$CK_PANE" '#{pane_mode}'; }
_pos()  { _t display-message -p -t "$CK_PANE" '#{scroll_position}'; }

# ─── the drag stream ─────────────────────────────────────────────────────────

@test "drag (real tmux): a stream of motion scrolls copy-mode by delta x lines, per event" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _t set-option -g @clikae_touch_scroll_lines 2

  _press 10
  local first second m
  _phase 12 '' drag || { _cleanup; false; }
  m="$(_mode)"; first="$(_pos)"
  _phase 14 "$m" drag || { _cleanup; false; }
  second="$(_pos)"
  _cleanup

  # The finger pulls the content with it: down the glass reveals OLDER lines.
  [ "$m" = "copy-mode" ] || { echo "mode after first motion: $m"; false; }
  [ "$first" = "4" ]  || { echo "2 rows x 2 lines = 4, got $first"; false; }
  [ "$second" = "8" ] || { echo "2 more rows = 8, got $second"; false; }
}

@test "drag (real tmux): the multiplier sets the speed, and it is the same option the swipe uses" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _t set-option -g @clikae_touch_scroll_lines 5

  _press 10
  local pos
  _phase 13 '' drag || { _cleanup; false; }
  pos="$(_pos)"
  _cleanup
  [ "$pos" = "15" ] || { echo "3 rows x 5 lines = 15, got $pos"; false; }
}

@test "drag (real tmux): dragging back up scrolls toward the live view" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _press 10
  _phase 18 '' drag || { _cleanup; false; }
  local far back
  far="$(_pos)"
  _phase 14 copy-mode drag || { _cleanup; false; }
  back="$(_pos)"
  _cleanup
  [ "$far" = "16" ] || { echo "8 rows x 2 = 16, got $far"; false; }
  [ "$back" = "8" ] || { echo "4 rows back = 8, got $back"; false; }
}

@test "drag (real tmux): a motion event that crosses no row does nothing" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _press 10
  local m pos
  _phase 10 '' drag || { _cleanup; false; }
  m="$(_mode)"; pos="$(_pos)"
  _cleanup
  # Not even copy-mode: a stationary finger has asked for nothing.
  [ "$m" = "" ] || { echo "entered a mode on a zero delta: $m"; false; }
  [ "$pos" = "" ] || { echo "scrolled on a zero delta: $pos"; false; }
}

@test "drag (real tmux): the delta is clamped to the pane height" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  # A delta larger than the pane can only come from a resize, a reattach at
  # another size, or two coalesced events — never from a finger.
  _press 0
  local pos
  _phase 400 '' drag || { _cleanup; false; }
  pos="$(_pos)"
  _cleanup
  [ "$pos" = "$(( CK_H * 2 ))" ] || { echo "want $(( CK_H * 2 )) (height x 2), got $pos"; false; }
}

@test "drag (real tmux): a motion with no recorded row records it and still reports success" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  # Declining here would hand tmux's own `copy-mode -M` the first event of a
  # gesture about to be translated, and a selection would open under the finger.
  _t set-option -pu -t "$CK_PANE" @clikae_touch_y
  local m recorded
  _phase 12 '' drag || { _cleanup; echo "declined the first motion"; false; }
  m="$(_mode)"
  recorded="$(_t show-options -pqv -t "$CK_PANE" @clikae_touch_y)"
  _cleanup
  [ "$m" = "" ] || { echo "entered a mode with nothing to measure: $m"; false; }
  [ "$recorded" = "12" ] || { echo "did not record the row: [$recorded]"; false; }
}

# ─── the end of the gesture ──────────────────────────────────────────────────

@test "drag (real tmux): an end at the live bottom leaves copy-mode and destroys both halves of the geometry" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _press 10
  _phase 14 '' drag || { _cleanup; false; }
  _phase 10 copy-mode drag || { _cleanup; false; }
  local at_bottom m y h
  at_bottom="$(_pos)"
  _phase 10 copy-mode end || { _cleanup; false; }
  m="$(_mode)"
  y="$(_t show-options -pqv -t "$CK_PANE" @clikae_touch_y)"
  h="$(_t show-options -pqv -t "$CK_PANE" @clikae_touch_h)"
  _cleanup
  [ "$at_bottom" = "0" ] || { echo "not back at the live bottom: $at_bottom"; false; }
  [ "$m" = "" ] || { echo "still in a mode after the finger left: $m"; false; }
  [ "$y" = "" ] || { echo "@clikae_touch_y survived the end: [$y]"; false; }
  [ "$h" = "" ] || { echo "@clikae_touch_h survived the end: [$h]"; false; }
}

@test "drag (real tmux): an end part-way up STAYS in copy-mode" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _press 10
  _phase 14 '' drag || { _cleanup; false; }
  local m pos
  _phase 14 copy-mode end || { _cleanup; false; }
  m="$(_mode)"; pos="$(_pos)"
  _cleanup
  # Ending a flick half-way up the history must not throw the history away —
  # that is the whole gesture undone by letting go.
  [ "$m" = "copy-mode" ] || { echo "cancelled mid-history: [$m]"; false; }
  [ "$pos" = "8" ] || { echo "moved on the end event: $pos"; false; }
}

@test "drag (real tmux): an end on a live pane clears the geometry and nothing else" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _press 10
  local m y
  _phase 10 '' end || { _cleanup; false; }
  m="$(_mode)"
  y="$(_t show-options -pqv -t "$CK_PANE" @clikae_touch_y)"
  _cleanup
  [ "$m" = "" ] || { echo "entered a mode on an end: $m"; false; }
  [ "$y" = "" ] || { echo "@clikae_touch_y survived: [$y]"; false; }
}

# ─── the alternate screen ────────────────────────────────────────────────────

@test "drag (real tmux): an alternate-screen pane gets SGR wheel bytes and never enters copy-mode" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _base
  _echo_pane "$CK_SOCKDIR/alt.sh" 1
  _t -f /dev/null new-session -d -s drag -x 80 -y 24 "bash '$CK_SOCKDIR/alt.sh'"
  CK_PANE="$(_t display-message -p -t '=drag:' '#{pane_id}')"
  CK_H=24
  _t set-option -g @clikae_touch_scroll on
  _t set-option -g @clikae_touch_drag on
  local waited=0
  while [ "$waited" -lt 25 ]; do
    [ "$(_t display-message -p -t "$CK_PANE" '#{alternate_on}')" = "1" ] && break
    sleep 0.2
    waited=$(( waited + 1 ))
  done

  local alt hist seen_down m seen_up
  alt="$(_t display-message -p -t "$CK_PANE" '#{alternate_on}')"
  hist="$(_t display-message -p -t "$CK_PANE" '#{history_size}')"

  _press 10
  _phase 12 '' drag || { _cleanup; false; }
  sleep 0.5
  seen_down="$(_t capture-pane -p -t "$CK_PANE" | tr -d '\n ')"
  m="$(_mode)"

  _t set-option -p -t "$CK_PANE" @clikae_touch_y 12
  _phase 9 '' drag || { _cleanup; false; }
  sleep 0.5
  seen_up="$(_t capture-pane -p -t "$CK_PANE" | tr -d '\n ')"
  _cleanup

  [ "$alt" = "1" ] || { echo "pane is not on the alternate screen"; false; }
  [ "$hist" = "0" ] || { echo "this pane was supposed to have no history: $hist"; false; }
  # copy-mode on a pane with no history is a mode change attached to a no-op.
  [ "$m" = "" ] || { echo "entered copy-mode on the alternate screen: $m"; false; }
  # 64 = wheel up, at 1-based column 5+1 and row 12+1. Two rows x 2 lines / 2
  # lines per notch = 2 notches.
  [[ "$seen_down" == *'^[[<64;6;13M^[[<64;6;13M'* ]] || { echo "app saw: [$seen_down]"; false; }
  # 65 = wheel down, three rows back up = 3 notches.
  [[ "$seen_up" == *'^[[<65;6;10M^[[<65;6;10M^[[<65;6;10M'* ]] || { echo "app saw: [$seen_up]"; false; }
}

@test "drag (real tmux): the literal word WheelUpPane is NEVER typed at the application" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # 🔴 THE TRAP THIS GUARDS. `tmux send-keys -t <pane> WheelUpPane` does not
  # deliver a wheel event — it types the WORD. tmux's mouse key names exist for
  # bind-key, not for send-keys, and the first prototype of this feature typed
  # `WheelUpPane` into the pane for four scrolls before anyone ran `cat -v`.
  _base
  _echo_pane "$CK_SOCKDIR/alt.sh" 1
  _t -f /dev/null new-session -d -s drag -x 80 -y 24 "bash '$CK_SOCKDIR/alt.sh'"
  CK_PANE="$(_t display-message -p -t '=drag:' '#{pane_id}')"
  CK_H=24
  _t set-option -g @clikae_touch_scroll on
  _t set-option -g @clikae_touch_drag on
  local waited=0
  while [ "$waited" -lt 25 ]; do
    [ "$(_t display-message -p -t "$CK_PANE" '#{alternate_on}')" = "1" ] && break
    sleep 0.2
    waited=$(( waited + 1 ))
  done

  _press 10
  _phase 16 '' drag || { _cleanup; false; }
  _t set-option -p -t "$CK_PANE" @clikae_touch_y 16
  _phase 4 '' drag || { _cleanup; false; }
  sleep 0.5
  local seen
  seen="$(_t capture-pane -p -t "$CK_PANE")"
  _cleanup
  [[ "$seen" != *Wheel* ]] || { echo "a mouse KEY NAME reached the app: [$seen]"; false; }
  [[ "$seen" != *Pane* ]]  || { echo "a mouse KEY NAME reached the app: [$seen]"; false; }
}

# ─── the gates ───────────────────────────────────────────────────────────────

@test "drag (real tmux): @clikae_touch_drag ships OFF, and off means DECLINE, not no-op" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _t set-option -g @clikae_touch_drag off
  _press 10
  local drag_rc=0 end_rc=0 m
  _phase 12 '' drag || drag_rc=$?
  _phase 12 '' end || end_rc=$?
  m="$(_mode)"
  _cleanup
  # Non-zero is what makes tmux's if-shell run its OWN command for the key; a
  # 0 here would silently eat every drag on every desktop.
  [ "$drag_rc" -ne 0 ] || { echo "drag returned 0 with the option off"; false; }
  [ "$end_rc" -ne 0 ]  || { echo "end returned 0 with the option off"; false; }
  [ "$m" = "" ] || { echo "acted anyway: $m"; false; }
}

@test "drag (real tmux): @clikae_touch_scroll is the master switch over drag too" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _t set-option -g @clikae_touch_drag on
  _t set-option -g @clikae_touch_scroll off
  _press 10
  local rc=0 m
  _phase 12 '' drag || rc=$?
  m="$(_mode)"
  _cleanup
  [ "$rc" -ne 0 ] || { echo "drag ran with touch scrolling turned off"; false; }
  [ "$m" = "" ] || { echo "acted anyway: $m"; false; }
}

@test "drag (real tmux): the on-word list is the same one the other touch options use" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  local word rc
  for word in on ON On 1 yes YES true TRUE; do
    _t set-option -g @clikae_touch_drag "$word"
    _t set-option -pu -t "$CK_PANE" @clikae_touch_y
    _press 10
    rc=0
    _phase 12 '' drag || rc=$?
    [ "$rc" -eq 0 ] || { _cleanup; echo "'$word' did not turn it on"; false; }
    _t send-keys -t "$CK_PANE" -X cancel 2>/dev/null || true
  done
  for word in off OFF 0 no NO false '' garbage; do
    _t set-option -g @clikae_touch_drag "$word"
    _press 10
    rc=0
    _phase 12 '' drag || rc=$?
    [ "$rc" -ne 0 ] || { _cleanup; echo "'$word' turned it on"; false; }
  done
  _cleanup
}

@test "drag (real tmux): a mode the helper cannot talk to declines rather than failing inside tmux" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _press 10
  local rc=0
  _phase 12 tree-mode drag || rc=$?
  _cleanup
  [ "$rc" -ne 0 ] || { echo "claimed a tree-mode drag"; false; }
}

# ─── the empty #{pane_mode} trap ─────────────────────────────────────────────

@test "drag (binding): an EMPTY #{pane_mode} does not shift the argument list" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # 🔴 #{pane_mode} expands to the EMPTY STRING outside a mode — not to a
  # placeholder, to nothing at all — so unquoted it produces NO argument and
  # `drag` lands in `mode`. #88 could not see this (pane_mode was its last
  # argument); the drag line puts two after it.
  #
  # First: the source still quotes all five. This is the assertion that breaks
  # if someone tidies the quotes away.
  grep -q "'#{mouse_y}' '#{pane_id}' '#{pane_mode}' drag '#{mouse_x}'" \
    "$CLIKAE_TEST_ROOT/lib/core/tmux.sh" || { echo "the binding stopped quoting its formats"; false; }

  _server 24
  [ "$(_mode)" = "" ] || { _cleanup; echo "pane started in a mode"; false; }

  # Then: the SAME command string tmux would run, expanded by tmux itself
  # against a pane that is in no mode, handed to `sh -c` the way if-shell does.
  local quoted unquoted rc_q=0 rc_u=0 pos_q pos_u
  quoted="$(_t display-message -p -t "$CK_PANE" \
    "bash '$(_helper)' '12' '$CK_PANE' '#{pane_mode}' drag '5'")"
  unquoted="$(_t display-message -p -t "$CK_PANE" \
    "bash '$(_helper)' 12 $CK_PANE #{pane_mode} drag 5")"

  _press 10
  PATH="$CK_SOCKDIR/bin:$CK_PATH" command env -u TMUX sh -c "$quoted" || rc_q=$?
  pos_q="$(_pos)"

  _t send-keys -t "$CK_PANE" -X cancel 2>/dev/null || true
  _press 10
  PATH="$CK_SOCKDIR/bin:$CK_PATH" command env -u TMUX sh -c "$unquoted" || rc_u=$?
  pos_u="$(_pos)"
  _cleanup

  [ "$rc_q" -eq 0 ] || { echo "the quoted form declined: rc=$rc_q"; false; }
  [ "$pos_q" = "4" ] || { echo "the quoted form did not scroll: [$pos_q]"; false; }
  # The control: without the quotes the list really does shift, and the helper
  # refuses rather than mistaking `drag` for a mode name.
  [ "$rc_u" -ne 0 ] || { echo "the unquoted form was accepted — the trap is gone"; false; }
  [ "$pos_u" = "" ] || { echo "the unquoted form scrolled: [$pos_u]"; false; }
}

# ─── a real client, real mouse bytes ─────────────────────────────────────────

# _install <pane command> — THE PRODUCT'S OWN INSTALLER, NOT A COPY OF ITS
# STRINGS. A copy of the command list written out here would be green whatever
# lib/core/tmux.sh does; touch-pages.bats already learned that (its own note
# says the copy stayed green against origin/main while six real cases went
# red). These three tests are the only ones in the suite where a real key press
# meets a real binding, so the binding they meet has to be the shipped one.
#
# `bind-key` validates its command list AT BIND TIME, so a chain tmux accepts
# is also proof that `if-shell "<helper>" '' '<tmux's own command>'` is
# something this tmux version will take.
_install() {
  _base
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  tmux() { command env -u TMUX PATH="$CK_PATH" "$CK_TMUX" -S "$(_sock)" "$@"; }
  _tmux_ssh_agent_link() { return 1; }
  tmux_server_born_note() { :; }
  CK_SESSION=clikae-drag-install
  run tmux_spawn_session --session "$CK_SESSION" -- "$1"
  local rc="$status" out="$output"
  unset -f tmux
  [ "$rc" -eq 0 ] || { echo "spawn failed: $out"; return 1; }
  CK_PANE="$(_t display-message -p -t "=$CK_SESSION:" '#{pane_id}')"
  CK_H="$(_t display-message -p -t "$CK_PANE" '#{pane_height}')"
  # Cosmetic only, and not part of what is under test: one fewer row to reason
  # about when converting an injected terminal row to a pane row.
  _t set-option -g status off
}

# _client — a second tmux server whose pane runs `tmux -S <our socket> attach`.
# That pane IS the pty; bytes sent to it are bytes on the client's terminal.
_client() {
  CK_HOSTDIR="$(mktemp -d)"
  command env -u TMUX "$CK_TMUX" -S "$CK_HOSTDIR/sock" -f /dev/null \
    new-session -d -s host -x 90 -y 30 \
    "env -u TMUX '$CK_TMUX' -S '$(_sock)' attach -t '$CK_SESSION'"
  local waited=0
  while [ "$waited" -lt 40 ]; do
    [ "$(_t list-clients 2>/dev/null | wc -l)" -gt 0 ] && break
    sleep 0.2
    waited=$(( waited + 1 ))
  done
  sleep 0.5
}

_inject() {
  command env -u TMUX "$CK_TMUX" -S "$CK_HOSTDIR/sock" send-keys -t '=host:' -l "$1"
  sleep 0.25
}

# _flick <press row> <first row> <last row> — a press, one motion per row
# crossed, and a release-with-motion. Exactly the event shape a real iPhone
# sends through a-Shell (measured 2026-09-16); note there is NO MouseUp.
_flick() {
  local r
  _inject "$(printf '\033[<0;6;%dM' "$1")"
  r="$2"
  while [ "$r" -le "$3" ]; do
    _inject "$(printf '\033[<32;6;%dM' "$r")"
    r=$(( r + 1 ))
  done
  _inject "$(printf '\033[<32;6;%dm' "$3")"
}

@test "drag (client): with @clikae_touch_drag OFF a drag is stock tmux — it still selects and copies" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _install 'sh -c "seq 1 400; sleep 300"' || { _cleanup; false; }
  # off is what the installer writes; saying so here is the assertion that it
  # keeps being what the installer writes.
  [ "$(_t show-options -gqv @clikae_touch_drag)" = "off" ] \
    || { _cleanup; echo "the shipped default is no longer off"; false; }
  _client
  _t delete-buffer 2>/dev/null || true

  _flick 10 11 13
  sleep 0.4
  local buffers m
  buffers="$(_t list-buffers 2>/dev/null | tr -d '\n')"
  m="$(_mode)"
  _cleanup

  # This IS the behaviour the issue reports — "copied N chars to tmux buffer"
  # where a scroll was wanted — and on a desktop, with a trackpad, it is not a
  # bug. `off` has to keep doing it, or this feature takes text selection away
  # from every Mac to give scrolling to the phones.
  [ -n "$buffers" ] || { echo "stock drag-selection was lost with the option OFF"; false; }
  [ "$m" = "" ] || { echo "stock ends with copy-pipe-and-cancel, mode was: $m"; false; }
}

@test "drag (client): with it ON the same gesture scrolls the history and copies nothing" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _install 'sh -c "seq 1 400; sleep 300"' || { _cleanup; false; }
  _t set-option -g @clikae_touch_drag on
  _t set-option -g @clikae_touch_scroll_lines 2
  _client
  _t delete-buffer 2>/dev/null || true

  _flick 10 11 13
  sleep 0.4
  local buffers m pos
  buffers="$(_t list-buffers 2>/dev/null | tr -d '\n')"
  m="$(_mode)"; pos="$(_pos)"
  _cleanup

  [ -z "$buffers" ] || { echo "still copied: [$buffers]"; false; }
  [ "$m" = "copy-mode" ] || { echo "did not enter copy-mode: [$m]"; false; }
  [ "$pos" = "6" ] || { echo "3 rows x 2 lines = 6, got [$pos]"; false; }
}

@test "drag (client): a tap still forwards BOTH the press and the release to the program" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # _install runs _base itself; the pane script has to exist before it.
  CK_SOCKDIR="$(mktemp -d)"
  _echo_pane "$CK_SOCKDIR/app.sh" 0
  local script="$CK_SOCKDIR/app.sh"
  _install "bash '$script'" || { _cleanup; false; }
  _t set-option -g @clikae_touch_scroll on
  _t set-option -g @clikae_touch_drag on
  local waited=0
  while [ "$waited" -lt 25 ]; do
    [ "$(_t display-message -p -t "$CK_PANE" '#{mouse_any_flag}')" = "1" ] && break
    sleep 0.2
    waited=$(( waited + 1 ))
  done
  _client

  # A tap: press and release on the SAME row, no motion between them. The drag
  # bindings must not be able to intercept this.
  _inject "$(printf '\033[<0;20;5M')"
  _inject "$(printf '\033[<0;20;5m')"
  sleep 0.5
  local seen m
  seen="$(_t capture-pane -p -t "$CK_PANE" | tr -d '\n ')"
  m="$(_mode)"
  _cleanup

  [[ "$seen" == *'^[[<0;20;5M'* ]] || { echo "the press never reached the app: [$seen]"; false; }
  [[ "$seen" == *'^[[<0;20;5m'* ]] || { echo "the release never reached the app: [$seen]"; false; }
  [ "$m" = "" ] || { echo "a tap entered a mode: $m"; false; }
}
