#!/usr/bin/env bats
# tests/bats/doc-contract.bats — the doc gate must FIRE, not just be silent.
#
# scripts/doc-names-exist.sh was written because three defects shared one shape:
# a doc naming something the code lacked. Its first version checked one of the
# three and passed the negative controls for the other two — a gate motivated by
# three bugs that caught one. Silence on clean input proves nothing; each check
# needs a deliberate break that turns it red.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_gate() { bash "$CLIKAE_TEST_ROOT/scripts/doc-names-exist.sh"; }

# Work on a COPY of the repo: these tests deliberately corrupt sources, and a
# suite that edits its own checkout is one interrupted run away from a mess.
_copy_repo() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  ( cd "$CLIKAE_TEST_ROOT" && tar cf - lib docs scripts AGENTS.md README.md bin ) | ( cd "$REPO" && tar xf - )
}
_gate_in_copy() { bash "$REPO/scripts/doc-names-exist.sh"; }

@test "doc gate: passes on the repo as it stands" {
  run _gate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "doc gate: fires when a doc names a function that does not exist" {
  _copy_repo
  printf '\n`tmux_no_such_function` is named here.\n' >> "$REPO/docs/DESIGN-tmux.md"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"tmux_no_such_function"* ]] || { echo "$output"; false; }
}

@test "doc gate: fires when a docstring names a caller that does not call" {
  # The shape that hid burn's missing prelaunch: an enumeration is only useful
  # if it is complete, so it is checked in both directions.
  _copy_repo
  perl -0pi -e 's{# store\? Called from [^\n]*}{# store? Called from switch.sh / lang.sh, right where}' \
    "$REPO/lib/core/fleet_mcp.sh"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"lang.sh"* ]] || { echo "$output"; false; }
}

@test "doc gate: fires when a real caller is missing from the docstring" {
  _copy_repo
  perl -0pi -e 's{# store\? Called from [^\n]*}{# store? Called from switch.sh, right where}' \
    "$REPO/lib/core/fleet_mcp.sh"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"does not list it"* ]] || { echo "$output"; false; }
}

@test "doc gate: fires when a tmux option a rule names is never set" {
  # window-size was described in Rule 1 for a year and set nowhere, so the
  # behaviour held on tmux 3.7b and not on 3.4.
  _copy_repo
  perl -0pi -e 's{^\s*chain\+=\(";" set-option -g window-size latest\)\n}{}m' "$REPO/lib/core/tmux.sh"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"window-size"* ]] || { echo "$output"; false; }
}
