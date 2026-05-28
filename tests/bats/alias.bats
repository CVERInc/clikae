#!/usr/bin/env bats
# tests/bats/alias.bats — `clikae alias`

load '../helpers'

@test "alias writes a sentinel-wrapped block to the rc file" {
  clikae init claude work
  run clikae alias claude work
  [ "$status" -eq 0 ]
  [ "$(rc_block_count claude.work)" -eq 1 ]
  grep -qF "alias claude-work=" "$RC_FILE"
}

@test "alias embeds the adapter's env var (env-dir)" {
  clikae init claude work
  clikae alias claude work
  grep -qF "CLAUDE_CONFIG_DIR=" "$RC_FILE"
}

@test "alias uses the profile NAME for an env-var adapter (aws)" {
  clikae init aws prod
  clikae alias aws prod
  grep -qF "AWS_PROFILE=\"prod\"" "$RC_FILE"
}

@test "alias points at the config FILE for an env-file adapter (kubectl)" {
  clikae init kubectl dev
  clikae alias kubectl dev
  grep -qF "KUBECONFIG=\"$CLIKAE_HOME/profiles/kubectl/dev/config\"" "$RC_FILE"
}

@test "re-running alias replaces rather than duplicates" {
  clikae init claude work
  clikae alias claude work
  clikae alias claude work
  [ "$(rc_block_count claude.work)" -eq 1 ]
}

@test "alias --name overrides the default alias name" {
  clikae init claude work
  run clikae alias claude work --name cw
  [ "$status" -eq 0 ]
  grep -qF "alias cw=" "$RC_FILE"
}

@test "alias fails when the profile does not exist" {
  run clikae alias claude ghost
  [ "$status" -ne 0 ]
  [[ "$output" == *"Profile not found"* ]]
}

@test "alias backs up an existing rc file before editing" {
  printf '# my existing rc\n' > "$RC_FILE"
  clikae init claude work
  clikae alias claude work
  [ "$(rc_backup_count)" -ge 1 ]
  grep -qF "# my existing rc" "$RC_FILE"
}
