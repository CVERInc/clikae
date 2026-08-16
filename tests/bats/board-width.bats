#!/usr/bin/env bats
# tests/bats/board-width.bats — every row the board prints must fit the terminal.
#
# WHY THIS IS SEPARATE FROM home.bats' wrapping test. That one calls
# `_home_wrap_prefixed` directly and proves the HELPER wraps. It says nothing
# about a row that never calls the helper — and 35 of the board's printf sites
# do not. It is the same shape as `resume.sh` calling adapter_run directly while
# an audit asked "who calls tmux": searching for callers finds drift among the
# sites that opted in; it cannot find the site that never did.
#
# The question that finds it is "what does the board actually PRINT", and it has
# a definite answer: render it and measure every line.
#
# Reported 2026-08-16 from a PineNote over ssh: the board did not fit. Measured
# on this repo, it overflowed at every width below 72 columns.
#
# 🔴 Strip ANSI before measuring. `_dwidth` is not escape-aware — a 3-character
# red "abc" measures 12 — which is also why the render path passes prefix widths
# as hardcoded literals (`19` at home.sh:891). The ruler is the render's own,
# applied to what the eye sees.

load '../helpers'

_visible() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g; s/\033\\][^\a]*\a//g'; }

# EVERY overflowing row, not just the widest. A gate that reports one offender
# per width makes you fix them one at a time and re-run; worse, it reads like
# "there is one problem here" when there were eleven.
_over_rows() {  # <cols> -> one "<width>\t<line>" per offending row
  local cols="$1" line dw
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(_visible "$line")"
    [ -n "$line" ] || continue
    dw="$(_dwidth "$line")"
    [ "$dw" -gt "$cols" ] && printf '%s\t%s\n' "$dw" "$line"
  done < <(COLUMNS="$cols" CLIKAE_NO_UPDATE_CHECK=1 "$CLIKAE_BIN" 2>&1)
  return 0
}

# The INTERACTIVE board, which is what a person at a terminal actually sees.
# `clikae` with no tty renders the STATIC board, so a gate that only runs the
# binary covers the path the reporter was not on. _home_pick_draw_body composes
# the whole interactive frame as a string, so it can be measured without a pty.
_over_rows_interactive() {  # <cols> -> one "<width>\t<line>" per offending row
  local cols="$1" line dw items
  items="$(_home_items 2>/dev/null)"
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(_visible "$line")"
    [ -n "$line" ] || continue
    dw="$(_dwidth "$line")"
    [ "$dw" -gt "$cols" ] && printf '%s\t%s\n' "$dw" "$line"
  done < <(COLUMNS="$cols" _home_pick_draw_body "$items" 0 "" 2>/dev/null)
  return 0
}

@test "board: no row overflows the terminal, at any width a real terminal has" {
  # shellcheck source=/dev/null
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  clikae init claude work
  clikae init claude other
  local cols rows bad=""
  # 30 is _home_cols' own floor; below that it substitutes 80 by design.
  for cols in 30 36 40 48 56 64 72 80 100 120; do
    rows="$(_over_rows "$cols")"
    [ -n "$rows" ] && bad="$bad
  --- static, COLUMNS=$cols ---
$(printf '%s' "$rows" | sed 's/^/    /')"
    rows="$(_over_rows_interactive "$cols")"
    [ -n "$rows" ] && bad="$bad
  --- interactive, COLUMNS=$cols ---
$(printf '%s' "$rows" | sed 's/^/    /')"
  done
  [ -z "$bad" ] || { echo "rows wider than the terminal:$bad"; false; }
}

@test "board-width: the measurement itself can see an over-wide row" {
  # 🔴 The gate above passes when nothing overflows AND when the measurement is
  # broken — a stripped-to-nothing line measures 0 and fits any terminal. This
  # asserts the ruler: a known-wide line, with colour, must be reported.
  # shellcheck source=/dev/null
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  local wide plain
  wide="$(printf '\033[31m%s\033[0m' "$(printf 'x%.0s' $(seq 1 50))")"
  plain="$(_visible "$wide")"
  [ "$(_dwidth "$plain")" -eq 50 ] || { echo "measured $(_dwidth "$plain"), want 50"; false; }
  # and the ANSI must actually have been stripped (raw would measure ~59)
  [ "$(_dwidth "$wide")" -gt 50 ] || { echo "_dwidth is escape-aware now; _visible may be redundant"; false; }
}
