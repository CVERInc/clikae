#!/usr/bin/env bats
# tests/bats/adapters/extra.bats — the v0.4 built-in adapters (az, npm,
# terraform, pulumi) and their strategies/seeding.

load '../../helpers'

@test "adapters lists all 11 built-in CLIs" {
  run clikae adapters
  [ "$status" -eq 0 ]
  for cli in claude gh gcloud docker helm kubectl aws az npm terraform pulumi; do
    [[ "$output" == *"$cli"* ]] || { echo "missing adapter: $cli"; false; }
  done
}

@test "az adapter reports env-dir + AZURE_CONFIG_DIR" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"az"*"env-dir"*"AZURE_CONFIG_DIR"* ]]
}

@test "pulumi adapter reports env-dir + PULUMI_HOME" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"pulumi"*"env-dir"*"PULUMI_HOME"* ]]
}

@test "npm adapter reports env-file + NPM_CONFIG_USERCONFIG" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"npm"*"env-file"*"NPM_CONFIG_USERCONFIG"* ]]
}

@test "terraform adapter reports env-file + TF_CLI_CONFIG_FILE" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform"*"env-file"*"TF_CLI_CONFIG_FILE"* ]]
}

@test "az alias exports AZURE_CONFIG_DIR at the profile dir" {
  clikae init az work
  clikae alias az work
  grep -qF "AZURE_CONFIG_DIR=\"$CLIKAE_HOME/profiles/az/work\"" "$RC_FILE"
}

@test "pulumi alias exports PULUMI_HOME at the profile dir" {
  clikae init pulumi work
  clikae alias pulumi work
  grep -qF "PULUMI_HOME=\"$CLIKAE_HOME/profiles/pulumi/work\"" "$RC_FILE"
}

@test "init seeds npm's per-profile npmrc file" {
  run clikae init npm work
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/npm/work/npmrc" ]
}

@test "npm alias points at the npmrc FILE (env-file)" {
  clikae init npm work
  clikae alias npm work
  grep -qF "NPM_CONFIG_USERCONFIG=\"$CLIKAE_HOME/profiles/npm/work/npmrc\"" "$RC_FILE"
}

@test "init seeds terraform's per-profile terraformrc file" {
  run clikae init terraform work
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/terraform/work/terraformrc" ]
}

@test "terraform alias points at the terraformrc FILE (env-file)" {
  clikae init terraform work
  clikae alias terraform work
  grep -qF "TF_CLI_CONFIG_FILE=\"$CLIKAE_HOME/profiles/terraform/work/terraformrc\"" "$RC_FILE"
}
