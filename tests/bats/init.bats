#!/usr/bin/env bats
# tests/bats/init.bats — `clikae init`

load '../helpers'

@test "init creates the profile directory" {
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
}

@test "init without --alias does not touch the rc file" {
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ ! -f "$RC_FILE" ]
}

@test "init --alias creates the profile and one alias block" {
  run clikae init claude work --alias
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
  [ "$(rc_block_count claude.work)" -eq 1 ]
}

@test "init fails for an unknown CLI" {
  run clikae init nosuchcli work
  [ "$status" -ne 0 ]
  [[ "$output" == *"No built-in adapter"* ]] || false
}

@test "init fails when the profile already exists" {
  clikae init claude work
  run clikae init claude work
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]] || false
}

@test "init rejects a profile name with a leading dot" {
  run clikae init claude .hidden
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid profile name"* ]] || false
}

@test "init rejects a profile name with a slash" {
  run clikae init claude a/b
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid profile name"* ]] || false
}

@test "init accepts a dotted profile name" {
  run clikae init claude work.2
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work.2" ]
}

@test "init accepts a dashed profile name" {
  run clikae init claude work-acct
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work-acct" ]
}

@test "init seeds an env-file adapter's config file (kubectl)" {
  run clikae init kubectl dev
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/kubectl/dev/config" ]
}

@test "init symlinks shared personal skills/commands into a new claude tank" {
  mkdir -p "$HOME/.claude/skills/recast-fidelity" "$HOME/.claude/commands"
  touch "$HOME/.claude/skills/recast-fidelity/SKILL.md"
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ -L "$CLIKAE_HOME/profiles/claude/work/skills" ]
  [ -e "$CLIKAE_HOME/profiles/claude/work/skills/recast-fidelity/SKILL.md" ]
  [ -L "$CLIKAE_HOME/profiles/claude/work/commands" ]
}

@test "init does not create a skills symlink when ~/.claude/skills doesn't exist" {
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/work/skills" ]
}

@test "init never clobbers a tank's own pre-existing skills dir" {
  mkdir -p "$HOME/.claude/skills"
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d/skills"
  touch "$d/skills/only-mine.md"
  run bash -c "source '$CLIKAE_TEST_ROOT/lib/adapters/claude.sh'; _claude_link_shared_asset '$d' skills"
  [ "$status" -eq 0 ]
  [ ! -L "$d/skills" ]
  [ -f "$d/skills/only-mine.md" ]
}
