#!/usr/bin/env bats
# tests/bats/touch-pages.bats — tap zones page the history (#108), against a
# REAL tmux server.
#
# 🔴 WHY THIS FILE EXISTS ALONGSIDE tests/bats/tmux.bats. That file is
# stub-only by design and proves which BRANCH a touch lands in; a stub cannot
# prove that the branch does anything, because the thing the branch is for —
# tmux's history actually moving one screen and coming back — lives entirely
# inside tmux. #88 learned this the expensive way: its stub suite was green
# while both of its P1 defects (a consumed release, a stale row in
# copy-mode-vi) reproduced on the first real server anyone tried.
#
# The ruler here is tmux's own `#{scroll_position}` — the number of lines the
# copy-mode view sits above the live output — read back out of the server
# after the helper runs. It is not a number this repo computes.
#
# Every server is this file's own socket from `mktemp -d` and is killed
# through that socket by path. Nothing here touches a shared or inherited
# server (`env -u TMUX`, `-S <path>`, always).
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_sock() { printf '%s/sock' "$CK_SOCKDIR"; }
_t() { command env -u TMUX PATH="$CK_PATH" "$CK_TMUX" -S "$(_sock)" "$@"; }

# _server <height> — a detached session whose pane has real scrollback to page
# through, plus a `tmux` on PATH that reaches THIS socket (the helper calls a
# bare `tmux`, exactly as tmux's own run-shell leaves it).
_server() {
  local height="${1:-24}"
  CK_PATH="$PATH"
  CK_TMUX="$(command -v tmux)"
  CK_SOCKDIR="$(mktemp -d)"
  mkdir -p "$CK_SOCKDIR/bin"
  # 🔴 PATH is restored INSIDE the wrapper before exec'ing the real binary: a
  # wrapper named `tmux` that resolves `tmux` through the PATH it was found on
  # finds itself (or clikae's own tmux shim finds the wrapper) and the two
  # bounce until the shim's hop ceiling fires.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec env -u TMUX PATH=%q %q -S %q "$@"\n' "$CK_PATH" "$CK_TMUX" "$(_sock)"
  } > "$CK_SOCKDIR/bin/tmux"
  chmod +x "$CK_SOCKDIR/bin/tmux"
  _t new-session -d -s pages -x 80 -y "$height" 'sh -c "seq 1 400; sleep 300"'
  CK_PANE="$(_t display-message -p -t '=pages:' '#{pane_id}')"
  CK_H="$(_t display-message -p -t "$CK_PANE" '#{pane_height}')"
  # The pane must have printed its 400 lines before the first page-up, or the
  # history being paged through is whatever had arrived by then.
  local waited=0
  while [ "$waited" -lt 10 ]; do
    [ "$(_t capture-pane -p -t "$CK_PANE" | grep -c '400')" -gt 0 ] && break
    sleep 0.2
    waited=$(( waited + 1 ))
  done
}

_cleanup() {
  [ -n "${CK_SOCKDIR:-}" ] || return 0
  _t kill-server 2>/dev/null || true
  rm -rf "$CK_SOCKDIR"
}

# _touch <press row> <release row> <mode> — the press writes exactly what the
# MouseDown binding writes (`set-option -p` on the same two options, same
# scope), then the helper runs the way run-shell runs it.
_touch() {
  _t set-option -p -t "$CK_PANE" @clikae_touch_y "$1"
  _t set-option -p -t "$CK_PANE" @clikae_touch_h "$CK_H"
  command env -u TMUX PATH="$CK_SOCKDIR/bin:$CK_PATH" \
    bash "$CLIKAE_TEST_ROOT/lib/core/touch_scroll.sh" "$2" "$CK_PANE" "$3"
}

_mode() { _t display-message -p -t "$CK_PANE" '#{pane_mode}'; }
_pos()  { _t display-message -p -t "$CK_PANE" '#{scroll_position}'; }

@test "pages (real tmux): a top-band tap moves the history one screen and enters copy-mode" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _t set-option -g @clikae_touch_pages on

  [ "$(_mode)" = "" ] || { echo "started in a mode: $(_mode)"; _cleanup; false; }
  _touch 1 1 ''
  local mode first second page
  mode="$(_mode)"; first="$(_pos)"
  # tmux's own page is the pane minus its two rows of carried context.
  page=$(( CK_H - 2 ))
  _touch 1 1 copy-mode
  second="$(_pos)"
  _cleanup
  [ "$mode" = "copy-mode" ] || { echo "mode after top tap: '$mode'"; false; }
  [ "$first" = "$page" ] || { echo "one page = $page lines, moved $first"; false; }
  [ "$second" = "$(( page * 2 ))" ] || { echo "second page landed at $second"; false; }
}

@test "pages (real tmux): a bottom-band tap pages forward, and at the newest line returns to live" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _t set-option -g @clikae_touch_pages on
  local bottom=$(( CK_H - 1 )) page=$(( CK_H - 2 ))

  local up down1 down2 mode_at_zero mode_after
  _touch 1 1 ''                       # two pages back
  _touch 1 1 copy-mode
  up="$(_pos)"
  _touch "$bottom" "$bottom" copy-mode
  down1="$(_pos)"
  _touch "$bottom" "$bottom" copy-mode
  down2="$(_pos)"                     # 0 — the live view, still in copy-mode
  mode_at_zero="$(_mode)"
  _touch "$bottom" "$bottom" copy-mode
  mode_after="$(_mode)"
  _cleanup
  [ "$up" = "$(( page * 2 ))" ] || { echo "two pages up landed at $up"; false; }
  [ "$down1" = "$page" ] || { echo "one page down landed at $down1"; false; }
  [ "$down2" = "0" ] || { echo "second page down landed at $down2, not the newest line"; false; }
  [ "$mode_at_zero" = "copy-mode" ] || { echo "left copy-mode early: '$mode_at_zero'"; false; }
  [ "$mode_after" = "" ] || { echo "tap at the newest line did not return to live: '$mode_after'"; false; }
}

@test "pages (real tmux): a middle tap never enters copy-mode, and the option off leaves all three taps alone" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  local bottom=$(( CK_H - 1 )) middle=$(( CK_H / 2 )) mid_mode="" off=""

  _t set-option -g @clikae_touch_pages on
  _touch "$middle" "$middle" ''
  mid_mode="$(_mode)"

  # 🔴 The red control for every assertion in this file: with the shipped
  # default, the SAME three taps must leave the pane exactly where it was.
  _t set-option -g @clikae_touch_pages off
  local row
  for row in 1 "$middle" "$bottom"; do
    _touch "$row" "$row" ''
    off="$off$(_mode)"
  done
  _cleanup
  [ "$mid_mode" = "" ] || { echo "a middle tap entered '$mid_mode'"; false; }
  [ "$off" = "" ] || { echo "paging off still acted: '$off'"; false; }
}

@test "pages (real tmux): a per-pane setting beats the server-wide one, both ways" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  # Server says off, this pane says on.
  _t set-option -g @clikae_touch_pages off
  _t set-option -p -t "$CK_PANE" @clikae_touch_pages on
  local pane_on pane_off
  _touch 1 1 ''
  pane_on="$(_mode)"
  _t send-keys -t "$CK_PANE" -X cancel

  # Server says on, this pane says off.
  _t set-option -g @clikae_touch_pages on
  _t set-option -p -t "$CK_PANE" @clikae_touch_pages off
  _touch 1 1 ''
  pane_off="$(_mode)"
  _cleanup
  [ "$pane_on" = "copy-mode" ] || { echo "per-pane 'on' did not win: '$pane_on'"; false; }
  [ "$pane_off" = "" ] || { echo "per-pane 'off' did not win: '$pane_off'"; false; }
}

@test "pages (real tmux): the band height option decides which rows page" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _t set-option -g @clikae_touch_pages on
  _t set-option -g @clikae_touch_pages_rows 1

  local narrow edge wide
  _touch 1 1 ''                       # row 1 is outside a 1-row band
  narrow="$(_mode)"
  _touch 0 0 ''                       # row 0 is inside it
  edge="$(_mode)"
  _t send-keys -t "$CK_PANE" -X cancel

  _t set-option -g @clikae_touch_pages_rows 6
  _touch 5 5 ''                       # row 5 is inside a 6-row band
  wide="$(_mode)"
  _cleanup
  [ "$narrow" = "" ] || { echo "row 1 paged with a 1-row band: '$narrow'"; false; }
  [ "$edge" = "copy-mode" ] || { echo "row 0 did not page with a 1-row band: '$edge'"; false; }
  [ "$wide" = "copy-mode" ] || { echo "row 5 did not page with a 6-row band: '$wide'"; false; }
}

@test "pages (real tmux): a swipe still scrolls with paging on (#88 regression)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _server 24
  _t set-option -g @clikae_touch_pages on
  # A swipe from the bottom band to the top band: displacement is decided
  # first, so this is #88's scroll (2 lines per row), not two zone taps.
  local mode pos
  _touch 20 10 ''
  mode="$(_mode)"; pos="$(_pos)"
  _cleanup
  [ "$mode" = "copy-mode" ] || { echo "swipe did not enter copy-mode: '$mode'"; false; }
  [ "$pos" = "20" ] || { echo "10 rows x 2 lines should be 20, got $pos"; false; }
}

@test "pages (real tmux): the product's own launch installs the chain, and tmux 3.4 accepts it" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # 🔴 THE PRODUCT'S INSTALLER, NOT A COPY OF ITS STRINGS. tests/bats/tmux.bats
  # asserts what clikae WRITES; a copy of the same command list asserted here
  # would be green whatever lib/core/tmux.sh does, and was — measured against
  # origin/main while the other six cases in this file went red. So this calls
  # tmux_spawn_session itself, against this file's own socket, and reads the
  # result back out of the server.
  #
  # `bind-key` validates its command list AT BIND TIME, so a chain tmux
  # accepts is also the proof that `set-option -p -t = -F @clikae_touch_h
  # "#{pane_height}"` is a command this tmux version will take.
  CK_PATH="$PATH"
  CK_TMUX="$(command -v tmux)"
  CK_SOCKDIR="$(mktemp -d)"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  tmux() { command env -u TMUX PATH="$CK_PATH" "$CK_TMUX" -S "$(_sock)" "$@"; }
  _tmux_ssh_agent_link() { return 1; }
  tmux_server_born_note() { :; }
  run tmux_spawn_session --session clikae-pages-install -- 'sleep 30'
  local install_rc="$status" install_out="$output"
  unset -f tmux

  local keys opt_pages opt_rows
  keys="$(_t list-keys -T root 2>/dev/null | grep MouseDown1Pane)"
  opt_pages="$(_t show-options -gqv @clikae_touch_pages)"
  opt_rows="$(_t show-options -gqv @clikae_touch_pages_rows)"
  _cleanup
  [ "$install_rc" -eq 0 ] || { echo "spawn failed: $install_out"; false; }
  [[ "$keys" == *'@clikae_touch_h'*'pane_height'* ]] || { echo "press binding: $keys"; false; }
  [ "$opt_pages" = "off" ] || { echo "default is '$opt_pages', not off"; false; }
  [ "$opt_rows" = "3" ] || { echo "band height default is '$opt_rows', not 3"; false; }
}
