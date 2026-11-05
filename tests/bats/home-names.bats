#!/usr/bin/env bats
# tests/bats/home-names.bats — the board's tank-name column fits the names on it.
# A fixed seven columns cut `shishamo` to `shisha…`, a name that reads as another
# tank. Width overflow with long names is board-width.bats's gate; this file pins
# what the column does with them.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_visible() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g'; }

_names_source() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/commands/home.sh"
}

_tank_items() {
  local sep=$'\037' n
  for n in "$@"; do printf 'tank%sclaude%s%s\n' "$sep" "$sep" "$n"; done
}

@test "board names: an eight-column tank name is shown whole on the board" {
  clikae init claude shishamo
  COLUMNS=80 run "$CLIKAE_BIN"
  [[ "$output" == *shishamo* ]] || false
  [[ "$output" != *shisha…* ]] || false
}

@test "board names: rows stay aligned around the longest name" {
  clikae init claude shishamo
  clikae init claude ray
  local out a b
  out="$(_visible "$(COLUMNS=80 "$CLIKAE_BIN" 2>&1)")"
  a="$(printf '%s\n' "$out" | grep ' shishamo ')"
  b="$(printf '%s\n' "$out" | grep ' ray ')"
  a="${a%%claude*}"; b="${b%%claude*}"
  [ "${#a}" -eq "${#b}" ] || { echo "'$a' vs '$b'"; false; }
}

@test "board names: a board of short names keeps the seven-column layout" {
  _names_source
  _home_name_colv "$(_tank_items ray anthias)"
  [ "$_HOME_NM_W" -eq 7 ]
  _home_namev ray
  [ "$_LPAD" = 'ray    ' ]
}

@test "board names: past the cap a name loses its middle, wide and narrow" {
  _names_source
  local long=averyverylongtankname
  _HOME_NARROW=0; _home_name_colv "$(_tank_items "$long" ray)"
  [ "$_HOME_NM_W" -eq 14 ]
  _home_namev "$long"
  [ "$_LPAD" = 'averyv…ankname' ] || { echo "$_LPAD"; false; }
  [ "$(_dwidth "$_LPAD")" -eq 14 ]

  _HOME_NARROW=1; _home_name_colv "$(_tank_items "$long" ray)"
  [ "$_HOME_NM_W" -eq 10 ]
  _home_namev "$long"
  [ "$_LPAD" = 'aver…kname' ] || { echo "$_LPAD"; false; }
  [ "$(_dwidth "$_LPAD")" -eq 10 ]

  # 30 columns: chrome 9 + title floor 12 leaves the name 9, not 10.
  _HOME_COLS_CACHE=30; _home_name_colv "$(_tank_items "$long" ray)"
  [ "$_HOME_NM_W" -eq 9 ]
}

@test "board names: rows that draw no tank name do not widen the column" {
  _names_source
  local sep=$'\037'
  _HOME_NARROW=0
  _home_name_colv "target${sep}antigravity${sep}somethingverylong"
  [ "$_HOME_NM_W" -eq 7 ]
}

@test "board names: a double-width name is cut on a character, never inside one" {
  _names_source
  _HOME_NM_W=8
  _home_namev '任務說明任務說明'
  [[ "$_LPAD" == *…* ]] || false
  [ "$(_dwidth "$_LPAD")" -eq 8 ]
}
