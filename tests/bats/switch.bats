#!/usr/bin/env bats
# tests/bats/switch.bats — the bare switch (`clikae <engine> <tank>`) when the
# engine's binary isn't installed. clikae switches accounts; it doesn't install
# the CLI, so a missing binary should fail HELPFULLY (with a per-engine install
# hint when the adapter has one), not with a bare "exec: <bin>: not found".
# (Real-user launcher-journey friction.) `[[ … ]]` carry `|| false`; see tests/README.md.

load '../helpers'

bats_require_minimum_version 1.5.0   # for `run -<expected-code>`

# Run a switch with a PATH that has clikae's own deps (/usr/bin, /bin) but NOT the
# engine binary, so `command -v <bin>` fails deterministically regardless of host.
@test "switch fails helpfully with an install hint when claude isn't installed" {
  clikae init claude work
  PATH="/usr/bin:/bin" run -127 clikae claude work
  [[ "$output" == *"claude/work"* ]] || false
  [[ "$output" == *"isn't installed"* ]] || false
  [[ "$output" == *"npm install -g @anthropic-ai/claude-code"* ]] || false
}

@test "switch's not-installed message is generic for an engine with no hint (gh)" {
  clikae init gh work
  PATH="/usr/bin:/bin" run -127 clikae gh work
  [[ "$output" == *"isn't installed"* ]] || false
  [[ "$output" == *"install 'gh' and retry"* ]] || false
}
