#!/usr/bin/env bats
# tests/bats/adapters/claude.bats — the built-in claude adapter + adapter listing.

load '../../helpers'

@test "adapters lists claude and the v0.2 adapters" {
  run clikae adapters
  [ "$status" -eq 0 ]
  for cli in claude gh gcloud docker helm kubectl aws; do
    [[ "$output" == *"$cli"* ]] || { echo "missing adapter: $cli"; false; }
  done
}

@test "claude adapter reports the env-dir strategy and its env var" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"*"env-dir"*"CLAUDE_CONFIG_DIR"* ]]
}

@test "info reports a profile count that tracks init" {
  clikae init claude work
  clikae init gh personal
  run clikae info
  [ "$status" -eq 0 ]
  [[ "$output" == *"profiles"*"2"* ]]
}

@test "claude alias exports CLAUDE_CONFIG_DIR at the profile path" {
  clikae init claude work
  clikae alias claude work
  grep -qF "CLAUDE_CONFIG_DIR=\"$CLIKAE_HOME/profiles/claude/work\"" "$RC_FILE"
}
