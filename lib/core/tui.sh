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
# tui_screen_enter / tui_screen_leave — the ONE way in and out of a full-screen
# picker. Write to stdout; a caller drawing on a dedicated tty fd uses
# `tui_screen_enter >&3`.
#
# 🔴 The alt-screen switch and BRACKETED PASTE (mode 2004) travel together, and
# that is the whole point of these existing. The repo had fourteen literal
# `\033[?1049h\033[?25l` sites across four files and eight exits; a fix applied
# to some of them is not a fix, because every `_home_tty_leave` turns the mode
# back off and any un-converted re-entry point leaves it off. Measured: with
# only three of the eight home.sh entries converted, one ordinary `/` + Enter
# re-opened the hole and a pasted `dy\r` destroyed a tank again.
#
# Pairing them in one function is what makes "you cannot forget it" true.
# Terminals that do not know mode 2004 ignore the sequence and behave as before,
# so this is a mitigation, not a guarantee — the other half is that a
# destructive confirm must not be satisfiable by bytes already queued.
tui_screen_enter() { printf '\033[?1049h\033[?25l\033[?2004h'; }
tui_screen_leave() { printf '\033[?2004l\033[?25h\033[?1049l'; }

# tui_read_key [fd] — block-read ONE logical key from <fd> (default 0) and set
# TUI_KEY to a symbolic name:
#     up down left right pgup pgdn home end tab shift-tab enter esc unknown
# or, for anything else, the literal character read ("q", "j", "5", "/", …).
# Returns 1 on EOF (caller treats as quit). Never returns non-zero otherwise —
# callers run under `set -eo pipefail` (the _handle_key crash of dogfood
# 2026-06-29 came from exactly such a leak).
#
# Decode notes, learned the hard way in resume.sh's picker:
#   · One key per call, no `-t 0` typeahead drain — a drain on bare stdin once
#     swallowed the board's own escape-sequence echo as keystrokes.
#   · CSI params (ESC [ 5 ~) consume their trailing '~' so it can't leak into
#     the next read as a literal key.
#   · ESC O A/B/C/D (application-mode arrows, sent by some terminals) decode
#     like their CSI twins instead of leaving a stray letter in the buffer.
#   · A lone ESC (1s timeout, no follow-up byte) is the user pressing Escape.
#   · An unrecognised sequence is TUI_KEY=unknown — a no-op for every caller,
#     never a misfired action.
# tui_read_key <fd> [timeout-seconds]
#
# 🔴 With a timeout, a caller can wake up without a keypress — which is the only
# way a bash TUI notices a terminal resize. A `trap ... WINCH` does NOT rescue a
# blocked `read`: bash installs its handlers with SA_RESTART, so the read simply
# resumes and the flag the trap set is never looked at until a key arrives.
# Measured 2026-08-16 on a pty: SIGWINCH after the first frame produced zero
# bytes of repaint.
#
# Return codes: 0 = a key (in TUI_KEY), 2 = the timeout elapsed (bash 4+),
# 1 = anything else. Callers that pass no timeout are unchanged.
#
# 🔴 macOS's stock bash 3.2 — the shell clikae actually runs on — returns 1 for
# a `read -t` TIMEOUT, not the >128 that bash 4+ gives. Measured on a pty: two
# consecutive one-second timeouts both came back 1. So a caller CANNOT tell a
# timeout from EOF by exit code here, and must decide with an independent
# signal; _home_pick asks whether the terminal still has a size.
tui_read_key() {
  local fd="${1:-0}" to="${2:-}" key c1 c2 _rc
  TUI_KEY=""
  if [ -n "$to" ]; then
    IFS= read -rsn1 -t "$to" -u "$fd" key || { _rc=$?; [ "$_rc" -gt 128 ] && return 2; return 1; }
  else
    IFS= read -rsn1 -u "$fd" key || return 1
  fi
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
            [0-9]|\;|\?|\<|\=|\>)
              # Parameterized CSI: consume EVERY parameter byte up to the final
              # byte, then decode on (params, final). Consuming only one byte
              # here used to leak the rest into the buffer as live keystrokes —
              # Ctrl-Right (ESC [ 1 ; 5 C) read as "home" then a selection-jump
              # "5"; a terminal's DA report leaked a literal "c", which the
              # resume picker binds to cleanup (2026-07-11 red-team finding).
              local params="$c2" b=""
              while IFS= read -rsn1 -t 1 -u "$fd" b; do
                case "$b" in
                  [0-9]|\;|\?|\<|\=|\>|\:) params="$params$b" ;;
                  *) break ;;   # the final byte (letter / ~) — decode below
                esac
              done
              case "$b" in
                A) TUI_KEY="up" ;;      # modifier'd arrows still navigate
                B) TUI_KEY="down" ;;
                C) TUI_KEY="right" ;;
                D) TUI_KEY="left" ;;
                H) TUI_KEY="home" ;;
                F) TUI_KEY="end" ;;
                '~')
                  case "${params%%;*}" in   # modifier suffix (5;3~) doesn't change the key
                    1|7) TUI_KEY="home" ;;
                    4|8) TUI_KEY="end" ;;
                    5)   TUI_KEY="pgup" ;;
                    6)   TUI_KEY="pgdn" ;;
                    # 🔴 BRACKETED PASTE. With mode 2004 on (tui_screen_enter), a
                    # paste arrives fenced as  ESC[200~ <text> ESC[201~ . Without
                    # this arm every pasted BYTE is a keystroke: measured on a real
                    # pty, one paste of `dy\r` on the board ran d (delete tank) then
                    # answered its [y/N] — the tank was rm -rf'd, not trashed. The
                    # `d` is read off fd 3 here while the `y` still sitting in the
                    # tty queue is read by the child's `confirm` on fd 0, so no
                    # single-reader guard can catch it; the fence is what closes it.
                    # Swallow the payload and report ONE unknown key, i.e. a paste
                    # is a documented no-op. Bounded reads (-t 1) so a truncated
                    # paste cannot wedge the picker.
                    200)
                      local _pb="" _pp="" _pn=0
                      while IFS= read -rsn1 -t 1 -u "$fd" _pb; do
                        _pn=$((_pn + 1))
                        [ "$_pn" -gt 65536 ] && break     # never spin on a huge paste
                        if [ "$_pb" = $'\e' ]; then _pp=""; continue; fi
                        _pp="$_pp$_pb"
                        case "$_pp" in '[201~') break ;; esac
                        case "$_pp" in '['*) ;; *) _pp="" ;; esac
                      done
                      TUI_KEY="unknown" ;;
                    201) TUI_KEY="unknown" ;;   # a stray end-fence: ignore it too
                    *)   TUI_KEY="unknown" ;;
                  esac ;;
                *) TUI_KEY="unknown" ;;
              esac ;;
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
