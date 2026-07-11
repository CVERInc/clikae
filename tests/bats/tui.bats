#!/usr/bin/env bats
# tests/bats/tui.bats — the shared keyboard decoder (lib/core/tui.sh) behind the
# home board, its sub-menus, and the resume picker. Feeds raw byte sequences on
# stdin and asserts the symbolic keys that come out — the layer that, while it
# lived as three inline copies, regressed in dogfood more than once (swallowed
# arrows, →/PgDn crashes, stray bytes firing actions).

load '../helpers'

# _decode <printf-format...> — run tui_read_key over the given raw bytes until
# EOF, one symbolic name per line.
_decode() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tui.sh"
  local fmt="$1"; shift || true
  while tui_read_key 0; do printf '%s\n' "$TUI_KEY"; done < <(printf "$fmt" "$@")
}

@test "tui: CSI arrows decode to up/down/right/left" {
  run _decode '\033[A\033[B\033[C\033[D'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'up\ndown\nright\nleft')" ]
}

@test "tui: application-mode arrows (ESC O A…) decode the same, no stray letter" {
  run _decode '\033OA\033OB'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'up\ndown')" ]
}

@test "tui: PgUp/PgDn/Home/End consume their trailing ~" {
  run _decode '\033[5~\033[6~\033[1~\033[4~\033[H\033[F'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'pgup\npgdn\nhome\nend\nhome\nend')" ]
}

@test "tui: Shift-Tab, Tab, Enter (\\n and \\r) decode symbolically" {
  run _decode '\033[Z\t\n\r'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'shift-tab\ntab\nenter\nenter')" ]
}

@test "tui: plain characters pass through literally" {
  run _decode 'jkgGq/c5['
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'j\nk\ng\nG\nq\n/\nc\n5\n[')" ]
}

@test "tui: a lone ESC at end of input reads as esc (quit), not a hang" {
  run _decode '\033'
  [ "$status" -eq 0 ]
  [ "$output" = "esc" ]
}

@test "tui: an unrecognised CSI is 'unknown' — a no-op, never a misfired action" {
  run _decode '\033[Pq'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'unknown\nq')" ]
}

@test "tui: decoder returns success for every key under set -e (no _handle_key-class crash)" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tui.sh"
  set -e
  local out=""
  while tui_read_key 0; do out="$out$TUI_KEY "; done < <(printf '\033[C\033[6~q')
  [ "$out" = "right pgdn q " ]
}

@test "tui: modifier'd arrows (ESC[1;5C Ctrl-Right) decode as the arrow — no leaked param bytes" {
  run _decode '\033[1;5C\033[1;2A'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'right\nup')" ]
}

@test "tui: Delete/Insert (ESC[3~ / ESC[2~) are unknown with the ~ consumed" {
  run _decode '\033[3~\033[2~q'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'unknown\nunknown\nq')" ]
}

@test "tui: a terminal DA report (ESC[?64;1;2c) never leaks its final letter as a keystroke" {
  # A leaked 'c' would open the resume picker's cleanup flow — red-team finding.
  run _decode '\033[?64;1;2c\033[>0;276;0cq'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'unknown\nunknown\nq')" ]
}

@test "tui: modifier'd PgUp (ESC[5;3~) still pages" {
  run _decode '\033[5;3~\033[6;5~'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'pgup\npgdn')" ]
}

@test "tui: bracketed-paste markers (ESC[200~/201~) are unknown, not keystrokes" {
  run _decode '\033[200~\033[201~'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'unknown\nunknown')" ]
}
