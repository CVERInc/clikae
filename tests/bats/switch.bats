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

@test "switch's not-installed message is generic for an engine with no hint (vercel)" {
  # vercel (a flag-strategy adapter, no install hint) is never in /usr/bin — gh
  # would be, on Ubuntu CI runners, so it'd slip past the restricted PATH.
  clikae init vercel work
  PATH="/usr/bin:/bin" run -127 clikae vercel work
  [[ "$output" == *"isn't installed"* ]] || false
  [[ "$output" == *"install 'vercel' and retry"* ]] || false
}
