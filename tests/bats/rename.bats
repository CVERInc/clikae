#!/usr/bin/env bats
# tests/bats/rename.bats — `clikae rename`

load '../helpers'

@test "rename moves the dir and rewrites the alias" {
  clikae init claude a
  clikae alias claude a
  run clikae rename claude a cver --force
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/cver" ]
  [ ! -d "$CLIKAE_HOME/profiles/claude/a" ]
  grep -qF "alias claude-cver=" "$RC_FILE"
  ! grep -qF "alias claude-a=" "$RC_FILE"
}

@test "rename points the new alias at the new directory" {
  clikae init claude a
  clikae alias claude a
  clikae rename claude a cver --force
  grep -qF "CLAUDE_CONFIG_DIR=\"$CLIKAE_HOME/profiles/claude/cver\"" "$RC_FILE"
}

@test "rename works without an alias (dir only)" {
  clikae init claude a
  run clikae rename claude a cver --force
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/cver" ]
}

@test "rename refuses when the target already exists" {
  clikae init claude a
  clikae init claude cver
  run clikae rename claude a cver --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "rename refuses when the source is missing" {
  run clikae rename claude ghost cver --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "rename refuses the same name" {
  clikae init claude a
  run clikae rename claude a a --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"same"* ]]
}

@test "rename refuses to move a profile in use in this shell" {
  clikae init claude a
  run env CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" "$CLIKAE_BIN" rename claude a cver --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"currently points"* ]]
  # nothing moved
  [ -d "$CLIKAE_HOME/profiles/claude/a" ]
}

@test "rename keeps a custom alias name (only swaps the default pattern)" {
  clikae init claude a
  clikae alias claude a --name myclaude
  clikae rename claude a cver --force
  grep -qF "alias myclaude=" "$RC_FILE"
}

@test "list shows the logged-in account label for claude" {
  clikae init claude a
  printf '{"oauthAccount":{"emailAddress":"hi@cver.net"}}' > "$CLIKAE_HOME/profiles/claude/a/.claude.json"
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"hi@cver.net"* ]]
}

@test "list shows a dash when no account is detectable" {
  clikae init gh personal
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh"*"personal"*"-"* ]]
}
