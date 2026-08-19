#!/usr/bin/env bats
# tests/bats/autonomy-read.bats — autonomy is the consent setting: it decides
# whether clikae may carry a live session onto ANOTHER ACCOUNT without asking.
# Reading it wrong in the permissive direction is not a display bug, it is doing
# something the user did not agree to. It had no direct tests; the read is now
# fork-free, so this pins it against the implementation it replaced.

load '../helpers'

_boot() { source "$CLIKAE_TEST_ROOT/lib/core/autonomy.sh"; }

# The pre-rewrite reader, verbatim. Do not tidy.
autonomy_get_reference() {
  local v=""
  [ -f "$(autonomy_file)" ] && v="$(tr -d '[:space:]' < "$(autonomy_file)" 2>/dev/null)"
  case "$v" in safe|full) printf '%s' "$v" ;; *) printf 'ask' ;; esac
}

# _same <literal-file-content-or-NOFILE> <expected>
_same() {
  local content="$1" expect="$2" f
  f="$(autonomy_file)"
  if [ "$content" = "NOFILE" ]; then rm -f "$f"; else printf '%s' "$content" > "$f"; fi
  local fast ref
  fast="$(autonomy_get)"; ref="$(autonomy_get_reference)"
  [ "$fast" = "$ref" ] || { echo "content=[$content] fast=$fast reference=$ref"; return 1; }
  [ "$fast" = "$expect" ] || { echo "content=[$content] got=$fast want=$expect"; return 1; }
}

@test "autonomy read: the three real values round-trip" {
  _boot
  mkdir -p "$CLIKAE_HOME"
  _same "$(printf 'ask\n')"  ask
  _same "$(printf 'safe\n')" safe
  _same "$(printf 'full\n')" full
}

@test "autonomy read: anything unrecognised normalises to ask, never upward" {
  _boot
  mkdir -p "$CLIKAE_HOME"
  # The direction matters: an unreadable setting must fall back to the state that
  # ASKS, not to one that acts. Each of these used to go through `tr`.
  _same NOFILE            ask
  _same ""                ask
  _same "$(printf '\n')"  ask
  _same "FULL"            ask      # case-sensitive on purpose
  _same "full-ish"        ask
  _same "safeful"         ask
  _same "ask safe full"   ask
  _same "0"               ask
}

@test "autonomy read: surrounding whitespace is stripped, as tr did" {
  _boot
  mkdir -p "$CLIKAE_HOME"
  _same "$(printf '  full  \n')"   full
  _same "$(printf '\tsafe\t\n')"   safe
  _same "$(printf '\n\nfull\n\n')" full
}

@test "autonomy read: whitespace INSIDE the word is stripped too, as tr did" {
  _boot
  mkdir -p "$CLIKAE_HOME"
  # `tr -d` deleted every space in the file, not just the ends — so "fu ll" read
  # as "full". Odd, but it is the behaviour that shipped, and a reader that is
  # stricter here would silently downgrade someone's setting to `ask`.
  _same "$(printf 'fu ll\n')"   full
  _same "$(printf 'sa\nfe\n')"  safe
}

@test "autonomy read: autonomy_getv and autonomy_get cannot disagree" {
  _boot
  mkdir -p "$CLIKAE_HOME"
  printf 'safe\n' > "$(autonomy_file)"
  autonomy_getv
  [ "$_AUTONOMY" = "$(autonomy_get)" ] || false
  [ "$_AUTONOMY" = "safe" ] || false
}

@test "autonomy read: autonomy_set then read gives back what was set" {
  _boot
  autonomy_set full
  [ "$(autonomy_get)" = "full" ] || false
  autonomy_set ask
  [ "$(autonomy_get)" = "ask" ] || false
  run autonomy_set nonsense
  [ "$status" -ne 0 ]
  [ "$(autonomy_get)" = "ask" ] || false     # a rejected set changes nothing
}
