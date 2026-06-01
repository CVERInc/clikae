#!/usr/bin/env bats
# tests/bats/env.bats — `clikae env <engine> <tank>`: export lines for `eval`,
# the explicit way to put a shell ON a tank. (`[[ … ]]` carry `|| false`; see
# tests/README.md.)

load '../helpers'

@test "env: prints an export line for the tank's config dir" {
  clikae init claude work
  run clikae env claude work
  [ "$status" -eq 0 ]
  [[ "$output" == *"export CLAUDE_CONFIG_DIR="* ]] || false
  [[ "$output" == *"profiles/claude/work"* ]] || false
}

@test "env: eval'ing it puts the shell on the tank (status then detects it)" {
  clikae init claude work
  eval "$(clikae env claude work)"
  [ -n "$CLAUDE_CONFIG_DIR" ]
  run clikae status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"work"* ]] || false
}

@test "env: a flag-strategy engine has nothing to export and says so" {
  clikae init vercel prod
  run clikae env vercel prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"flag-strategy"* ]] || false
}
