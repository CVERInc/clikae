# shellcheck shell=bash
# shellcheck disable=SC2034  # TUI_KEY is the decoder's output slot, read by the
#                              pickers in lib/commands/home.sh and resume.sh.
# lib/core/tui.sh — the one keyboard decoder for clikae's full-screen pickers.
#
# The home board (_home_pick), its sub-menus (_home_choose), and the resume
# picker (_resume_pick) each grew their own ESC-sequence state machine, and they
# drifted: resume decoded PgUp/PgDn/Home/End, the board didn't; the board read
# bare stdin while the others isolated input on a dedicated /dev/tty fd. This
# file owns the byte-level decode so every picker speaks the same keys; what a
# key MEANS stays with each caller.
#
# tui_read_key [fd] — block-read ONE logical key from <fd> (default 0) and set
# TUI_KEY to a symbolic name:
#     up down left right pgup pgdn home end tab shift-tab enter esc unknown
# or, for anything else, the literal character read ("q", "j", "5", "/", …).
# Returns 1 on EOF (caller treats as quit). Never returns non-zero otherwise —
# callers run under `set -eo pipefail` (the _handle_key crash of dogfood
# 2026-06-29 came from exactly such a leak).
#
# Decode notes, learned the hard way in resume.sh's picker:
#   • One key per call, no `-t 0` typeahead drain — a drain on bare stdin once
#     swallowed the board's own escape-sequence echo as keystrokes.
#   • CSI params (ESC [ 5 ~) consume their trailing '~' so it can't leak into
#     the next read as a literal key.
#   • ESC O A/B/C/D (application-mode arrows, sent by some terminals) decode
#     like their CSI twins instead of leaving a stray letter in the buffer.
#   • A lone ESC (1s timeout, no follow-up byte) is the user pressing Escape.
#   • An unrecognised sequence is TUI_KEY=unknown — a no-op for every caller,
#     never a misfired action.
tui_read_key() {
  local fd="${1:-0}" key c1 c2
  TUI_KEY=""
  IFS= read -rsn1 -u "$fd" key || return 1
  case "$key" in
    $'\e')
      if ! IFS= read -rsn1 -t 1 -u "$fd" c1; then TUI_KEY="esc"; return 0; fi
      case "$c1" in
        '['|O)
          if ! IFS= read -rsn1 -t 1 -u "$fd" c2; then TUI_KEY="esc"; return 0; fi
          case "$c2" in
            A) TUI_KEY="up" ;;
            B) TUI_KEY="down" ;;
            C) TUI_KEY="right" ;;
            D) TUI_KEY="left" ;;
            Z) TUI_KEY="shift-tab" ;;
            H) TUI_KEY="home" ;;
            F) TUI_KEY="end" ;;
            1) IFS= read -rsn1 -t 1 -u "$fd" _ || true; TUI_KEY="home" ;;
            4) IFS= read -rsn1 -t 1 -u "$fd" _ || true; TUI_KEY="end" ;;
            5) IFS= read -rsn1 -t 1 -u "$fd" _ || true; TUI_KEY="pgup" ;;
            6) IFS= read -rsn1 -t 1 -u "$fd" _ || true; TUI_KEY="pgdn" ;;
            *) TUI_KEY="unknown" ;;
          esac ;;
        *) TUI_KEY="esc" ;;
      esac ;;
    $'\t')          TUI_KEY="tab" ;;
    ''|$'\n'|$'\r') TUI_KEY="enter" ;;
    *)              TUI_KEY="$key" ;;
  esac
  return 0
}
