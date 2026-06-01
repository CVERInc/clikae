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
  [[ "$output" == *"Profile not found"* ]] || false
}

@test "alias backs up an existing rc file before editing" {
  printf '# my existing rc\n' > "$RC_FILE"
  clikae init claude work
  clikae alias claude work
  [ "$(rc_backup_count)" -ge 1 ]
  grep -qF "# my existing rc" "$RC_FILE"
}

# --- fish shell: different alias syntax + no inline VAR=val (uses env) ---------

@test "alias under fish writes fish syntax + env wrapper, creating config.fish" {
  clikae init claude work
  local fishrc="$TEST_HOME/.config/fish/config.fish"
  [ ! -e "$fishrc" ]                                   # parent dir doesn't exist yet
  SHELL=/usr/bin/fish run clikae alias claude work
  [ "$status" -eq 0 ]
  [ -f "$fishrc" ]                                     # mkdir -p created it
  [ "$(grep -cF "# >>> clikae:claude.work >>>" "$fishrc")" -eq 1 ]
  grep -qF "alias claude-work 'env CLAUDE_CONFIG_DIR=" "$fishrc"
  ! grep -qF "alias claude-work=" "$fishrc"            # NOT the posix form
}

@test "alias under fish wraps an env-var adapter (aws) through env too" {
  clikae init aws prod
  SHELL=/usr/bin/fish run clikae alias aws prod
  [ "$status" -eq 0 ]
  grep -qF "alias aws-prod 'env AWS_PROFILE=\"prod\" aws'" "$TEST_HOME/.config/fish/config.fish"
}

@test "remove cleans up a fish alias block" {
  clikae init claude work
  SHELL=/usr/bin/fish clikae alias claude work
  local fishrc="$TEST_HOME/.config/fish/config.fish"
  [ "$(grep -cF "# >>> clikae:claude.work >>>" "$fishrc")" -eq 1 ]
  SHELL=/usr/bin/fish run clikae remove claude work --force
  [ "$status" -eq 0 ]
  [ "$(grep -cF "# >>> clikae:claude.work >>>" "$fishrc")" -eq 0 ]
}
