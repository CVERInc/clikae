#!/usr/bin/env bats
# tests/bats/adapters/extra.bats — the v0.4 built-in adapters (az, npm,
# terraform, pulumi) and their strategies/seeding.

load '../../helpers'

@test "adapters lists all 13 built-in CLIs" {
  run clikae adapters
  [ "$status" -eq 0 ]
  for cli in claude codex gh gcloud docker helm kubectl aws az npm terraform pulumi vercel; do
    [[ "$output" == *"$cli"* ]] || { echo "missing adapter: $cli"; false; }
  done
}

@test "codex adapter reports env-dir + CODEX_HOME" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex"*"env-dir"*"CODEX_HOME"* ]]
}

@test "codex alias exports CODEX_HOME at the profile dir" {
  clikae init codex cheap
  clikae alias codex cheap
  grep -qF "CODEX_HOME=\"$CLIKAE_HOME/profiles/codex/cheap\"" "$RC_FILE"
}

@test "vercel adapter reports the flag strategy" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"vercel"*"flag"* ]]
}

@test "vercel alias injects --global-config after the binary (flag strategy)" {
  clikae init vercel prod
  clikae alias vercel prod
  grep -qF "vercel --global-config \"$CLIKAE_HOME/profiles/vercel/prod\"" "$RC_FILE"
}

@test "vercel fish alias injects the flag with no env wrapper (flag strategy)" {
  clikae init vercel prod
  SHELL=/usr/bin/fish clikae alias vercel prod
  local fishrc="$TEST_HOME/.config/fish/config.fish"
  # flag-only adapter: binary + flag, no leading `env VAR=…` (there are no vars).
  grep -qF "alias vercel-prod 'vercel --global-config \"$CLIKAE_HOME/profiles/vercel/prod\"'" "$fishrc"
  ! grep -qF "alias vercel-prod 'env" "$fishrc"
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
