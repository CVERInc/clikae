#!/usr/bin/env bats
# tests/bats/remove.bats — `clikae remove`

load '../helpers'

@test "remove --force deletes the dir and the alias block" {
  clikae init claude work --alias
  run clikae remove claude work --force
  [ "$status" -eq 0 ]
  [ ! -d "$CLIKAE_HOME/profiles/claude/work" ]
  [ "$(rc_block_count claude.work)" -eq 0 ]
}

@test "remove cleans up the now-empty cli directory" {
  clikae init claude work
  clikae remove claude work --force
  [ ! -d "$CLIKAE_HOME/profiles/claude" ]
}

@test "remove --keep-data keeps the dir but removes the alias" {
  clikae init claude work --alias
  run clikae remove claude work --force --keep-data
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
  [ "$(rc_block_count claude.work)" -eq 0 ]
}

@test "remove handles a dangling alias when the dir is already gone" {
  clikae init claude work --alias
  rm -rf "$CLIKAE_HOME/profiles/claude/work"
  run clikae remove claude work --force
  [ "$status" -eq 0 ]
  [ "$(rc_block_count claude.work)" -eq 0 ]
}

@test "remove handles a dir with no alias" {
  clikae init claude work
  run clikae remove claude work --force
  [ "$status" -eq 0 ]
  [ ! -d "$CLIKAE_HOME/profiles/claude/work" ]
}

@test "remove backs up the rc file before stripping the alias" {
  clikae init claude work --alias
  clikae remove claude work --force
  [ "$(rc_backup_count)" -ge 1 ]
}

@test "remove without --force and no input aborts without deleting" {
  clikae init claude work
  run clikae remove claude work </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted"* ]] || false
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
}

@test "remove leaves unrelated alias blocks untouched" {
  clikae init claude work --alias
  clikae init claude personal --alias
  clikae remove claude work --force
  [ "$(rc_block_count claude.work)" -eq 0 ]
  [ "$(rc_block_count claude.personal)" -eq 1 ]
}
