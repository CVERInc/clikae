#!/usr/bin/env bats
# tests/bats/live.bats — the board's Live section: what is running right now.
#
# It exists because of a real report: ssh in, run `clikae`, and the session you
# left running was nowhere on the page. The board could say which accounts you
# had and what you did yesterday, but not what was alive — a category tmux
# created and the board never grew.
#
# These drive the STATIC render (no tty), which is what `clikae` prints when it
# is not drawing the interactive picker, so the rows can be read as text.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

# A tank name unique to this test, so real sessions on the developer's machine
# and parallel runs cannot be mistaken for the fixture.
_tank() { printf 'lv%s%s' "$$" "${BATS_TEST_NUMBER:-0}"; }
_sess() { printf 'ck-codex-%s' "$(_tank)"; }

teardown() {
  tmux kill-session -t "$(_sess)" 2>/dev/null || true
  tmux kill-session -t "$(_sess)-4242" 2>/dev/null || true
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

@test "live: a running session appears, with its tank and engine" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex "$(_tank)"
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Live"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$(_tank)"* ]] || { echo "$output"; false; }
}

@test "live: no running session means no section — not an empty one" {
  # clikae's habit everywhere else: when it cannot read something it says
  # nothing, rather than printing a heading with nothing under it.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex "$(_tank)"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" != *"▸ Live"* ]] || { echo "$output"; false; }
}

@test "live: a session whose tank no longer exists is not drawn" {
  # A row you cannot open is worse than no row. The tank is resolved against the
  # disk, so a leftover session simply drops off.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  tmux new-session -d -s "$(_sess)" 'sleep 30'      # never init-ed: the session exists, the tank does not
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" != *"▸ Live"* ]] || { echo "$output"; false; }
}

@test "live: a resumed session (name carries an argv digest) is drawn too" {
  # Since a session is keyed on what was asked for, a resumed conversation is
  # `ck-<engine>-<tank>-<digits>`. It is just as alive as the bare one, and the
  # digest must not hide it.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex "$(_tank)"
  tmux new-session -d -s "$(_sess)-4242" 'sleep 30'
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"▸ Live"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$(_tank)"* ]] || { echo "$output"; false; }
}

@test "live: somebody else's tmux session is none of clikae's business" {
  # ADVERSARIAL ON PURPOSE. The obvious fixture — a session called `notclikae-1` —
  # is rejected by the tank-exists check whether or not the `ck-` gate is there,
  # so it proves nothing: both guards could be deleted and it stayed green.
  #
  # This name is one character away from being ours. Strip the `ck-` gate and
  # `codex-<tank>` parses straight into a tank that really exists, so the row
  # would be drawn — which is the failure this test is supposed to catch.
  #
  # There are TWO `ck-` gates (the grep in live_session_names and the case in
  # live_split) and they are redundant on purpose: widening either one alone
  # leaves this green, and widening both turns exactly this test red. Recorded
  # because "no test fails when I delete it" is the usual reason a redundant
  # guard gets deleted, and here it means the other one caught it.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex "$(_tank)"
  local theirs; theirs="codex-$(_tank)"
  tmux new-session -d -s "$theirs" 'sleep 30'
  run clikae
  tmux kill-session -t "$theirs" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" != *"▸ Live"* ]] || { echo "$output"; false; }
}

@test "live: with no tmux at all the section is absent and nothing errors" {
  # A PATH without tmux, not a stub that exits non-zero: `command -v` still FINDS
  # a stub, so a stub would test the wrong branch. (Learned the hard way when a
  # tmux stubbed as `exit 127` made a correct guard look broken.)
  clikae init codex "$(_tank)"
  # Link EVERYTHING on the current PATH except tmux, rather than listing the
  # binaries the board happens to need today. A hand-written list is a second
  # thing to keep in sync, and when it falls behind the test fails for the wrong
  # reason — which is exactly what it did on the first attempt.
  local farm="$BATS_TEST_TMPDIR/nopath" d f
  mkdir -p "$farm"
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      case "${f##*/}" in tmux) continue ;; esac
      [ -e "$farm/${f##*/}" ] || ln -s "$f" "$farm/${f##*/}" 2>/dev/null || true
    done
  done <<PATHDIRS
$(printf '%s\n' "$PATH" | tr ':' '\n')
PATHDIRS
  [ ! -x "$farm/tmux" ]                      # the whole point of the farm
  run env PATH="$farm" "$CLIKAE_BIN"
  [ "$status" -eq 0 ]
  [[ "$output" != *"▸ Live"* ]] || { echo "$output"; false; }
}

@test "live: a waiter's countdown is readable from the session, not only inside it" {
  # The countdown rides in the waiter's window NAME, which is what lets the board
  # show "it will resume itself" without anyone switching windows.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  tmux new-window -d -t "$(_sess)" -n 'wake 13h38m' 'sleep 30'
  run live_wake_note "$(_sess)"
  [ "$output" = "13h38m" ]
}

@test "live: a waiter that has not started counting yet reports nothing" {
  # `wake` with no time is a window that exists but has not begun; reporting a
  # countdown for it would be inventing one.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  tmux new-window -d -t "$(_sess)" -n wake 'sleep 30'
  run live_wake_note "$(_sess)"
  [ -z "$output" ]
}
