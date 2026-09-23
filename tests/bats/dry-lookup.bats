#!/usr/bin/env bats
# tests/bats/dry-lookup.bats — "is this tank out of fuel?" is the one question the
# board exists to answer, and it is now answered without forking awk. A lookup
# that quietly said "not dry" would draw a green dot on an exhausted tank, which
# is worse than a slow board: it reads as an invitation. The awk implementation
# is kept here verbatim and every case is run through both.

load '../helpers'

_boot() {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
}

# The pre-rewrite lookup. Do not tidy — it is the reference, not code.
_home_is_dry_reference() {
  printf '%s\n' "$1" | awk -F'\037' -v c="$2" -v p="$3" \
    '$1==c && $2==p{print $3; found=1} END{exit !found}'
}

# Compare status AND phrase for one lookup.
_agree() {
  local set="$1" cli="$2" tank="$3"
  local fo fs ro rs
  fo="$(_home_is_dry "$set" "$cli" "$tank")" && fs=0 || fs=$?
  ro="$(_home_is_dry_reference "$set" "$cli" "$tank")" && rs=0 || rs=$?
  if [ "$fs" != "$rs" ] || [ "$fo" != "$ro" ]; then
    echo "disagree for [$cli/$tank]: fast=(rc=$fs '$fo')  reference=(rc=$rs '$ro')"
    return 1
  fi
  return 0
}

_set3() { printf 'claude\037work\037Resets in 2h\ncodex\037cheap\037\nclaude\037solo1\037tomorrow 09:00'; }

@test "dry lookup: agrees with the awk reference on a populated set" {
  _boot
  local s; s="$(_set3)"
  _agree "$s" claude work
  _agree "$s" codex cheap
  _agree "$s" claude solo1
  _agree "$s" claude missing
  _agree "$s" codex work
  _agree "$s" antigravity g
}

@test "dry lookup: agrees on an EMPTY set — the healthy-fleet case" {
  _boot
  # The common case by far, and the one a broken shortcut is most likely to get
  # right by accident. Kept explicit so the other tests are not the only cover.
  _agree "" claude work
  _agree "" codex cheap
}

@test "dry lookup: a dry tank keeps its verbatim reset phrase" {
  _boot
  local s; s="$(_set3)"
  run _home_is_dry "$s" claude work
  [ "$status" -eq 0 ]
  [ "$output" = "Resets in 2h" ] || false
  # Dry with NO phrase is still dry — the status carries it, not the text.
  run _home_is_dry "$s" codex cheap
  [ "$status" -eq 0 ]
  [ -z "$output" ] || false
}

@test "dry lookup: a name that is only a SUFFIX of a dry entry is not dry" {
  _boot
  # The failure mode the newline fence exists for. "ork" must not match inside
  # "work", or a healthy tank would be drawn as exhausted — and the neighbouring
  # engine field makes this easy to get wrong, because both are in one string.
  local s; s="$(printf 'claude\037work\037Resets in 2h')"
  _agree "$s" claude ork
  _agree "$s" laude work
  _agree "$s" e work
  run _home_is_dry "$s" claude ork
  [ "$status" -ne 0 ]
}

@test "dry lookup: the FIRST entry in the set is found" {
  _boot
  # An implementation that scans for a preceding newline can miss the entry that
  # has none. The first line is exactly where the newest dry tank tends to land.
  local s; s="$(_set3)"
  run _home_is_dry "$s" claude work
  [ "$status" -eq 0 ]
  [ "$output" = "Resets in 2h" ] || false
}

@test "dry lookup: the LAST entry, with no trailing newline, is found" {
  _boot
  local s; s="$(_set3)"          # command substitution strips the trailing \n
  run _home_is_dry "$s" claude solo1
  [ "$status" -eq 0 ]
  [ "$output" = "tomorrow 09:00" ] || false
}

@test "dry lookup: a phrase containing spaces and punctuation survives whole" {
  _boot
  local s; s="$(printf 'claude\037work\037Resets at 3:00pm (in 2h 14m), UTC+8')"
  run _home_is_dry "$s" claude work
  [ "$status" -eq 0 ]
  [ "$output" = "Resets at 3:00pm (in 2h 14m), UTC+8" ] || false
  _agree "$s" claude work
}

@test "fuel dot: the glyph and its note come from one lookup and still agree" {
  _boot
  source "$CLIKAE_TEST_ROOT/lib/core/i18n.sh"
  # _home_fuel_dot is now a printf wrapper over the variable-setting form, so the
  # two can no longer drift — pin that they report the same thing.
  local s; s="$(printf 'claude\037work\037Resets in 2h')"
  _home_fuel_dotv "$s" claude work
  local via_v="$_FDOT"$'\037'"$_FNOTE"
  local via_echo; via_echo="$(_home_fuel_dot "$s" claude work)"
  [ "$via_v" = "$via_echo" ] || { echo "v=[$via_v] echo=[$via_echo]"; false; }
  [[ "$via_echo" == *"Resets in 2h" ]] || false
}
