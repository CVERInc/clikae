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
  [[ "$output" == *"codex"*"env-dir"*"CODEX_HOME"* ]] || false
}

@test "codex alias exports CODEX_HOME at the profile dir" {
  clikae init codex cheap
  clikae alias codex cheap
  grep -qF "CODEX_HOME=\"$CLIKAE_HOME/profiles/codex/cheap\"" "$RC_FILE"
}

@test "vercel adapter reports the flag strategy" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"vercel"*"flag"* ]] || false
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

@test "codex shows the logged-in account (email) from its auth.json id_token" {
  clikae init codex work
  local dir="$CLIKAE_HOME/profiles/codex/work"
  # A JWT whose base64url payload carries {"email":"alice@codex.test"}.
  local payload
  payload="$(printf '%s' '{"email":"alice@codex.test","sub":"x"}' | base64 | tr '+/' '-_' | tr -d '=')"
  printf '{"auth_mode":"chatgpt","tokens":{"id_token":"hdr.%s.sig"}}\n' "$payload" > "$dir/auth.json"
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice@codex.test"* ]] || false
}

@test "codex account label is empty (not an error) when there's no id_token" {
  clikae init codex apikey
  printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-xxxx"}\n' \
    > "$CLIKAE_HOME/profiles/codex/apikey/auth.json"
  run clikae list
  [ "$status" -eq 0 ]            # no crash under set -eo pipefail
  [[ "$output" == *"codex"* ]] || false
}

@test "az adapter reports env-dir + AZURE_CONFIG_DIR" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"az"*"env-dir"*"AZURE_CONFIG_DIR"* ]] || false
}

@test "pulumi adapter reports env-dir + PULUMI_HOME" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"pulumi"*"env-dir"*"PULUMI_HOME"* ]] || false
}

@test "npm adapter reports env-file + NPM_CONFIG_USERCONFIG" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"npm"*"env-file"*"NPM_CONFIG_USERCONFIG"* ]] || false
}

@test "terraform adapter reports env-file + TF_CLI_CONFIG_FILE" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform"*"env-file"*"TF_CLI_CONFIG_FILE"* ]] || false
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

# 🔴 The unset list in lib/core/adapter_loader.sh is what stops one adapter's
# OPTIONAL hook from answering for the next one loaded in the same process
# (`clikae handoff <a> --to <b>`, and every board render that walks engines).
# It has drifted three times: #81 added adapter_burn_flags/adapter_audit_flags
# to claude, #60 added adapter_meta_permission_modes, and round 12 of #62 found
# four more (adapter_cwd_from_args, adapter_ephemeral_flags,
# adapter_mcp_config_file, adapter_tank_fingerprint). Each was caught by a
# person reading the list, and each time only the hook that person was thinking
# about got a leak-guard test. This is the general form: a hook that exists is
# in the list, or this test names it. Adding a hook and forgetting the list can
# no longer be silent.
@test "every adapter hook is in adapter_loader's unset list" {
  local defined unset_list missing
  defined="$(grep -ho '^adapter_[a-z_]*()' "$CLIKAE_TEST_ROOT"/lib/adapters/*.sh \
    | sed 's/()$//' | LC_ALL=C sort -u)"
  [ -n "$defined" ] || { echo "found no adapter hooks at all — the grep is wrong"; false; }
  unset_list="$(sed -n '/unset -f adapter_meta_name/,/2>\/dev\/null || true/p' \
    "$CLIKAE_TEST_ROOT/lib/core/adapter_loader.sh" \
    | tr ' \\' '\n\n' | grep '^adapter_' | LC_ALL=C sort -u)"
  [ -n "$unset_list" ] || { echo "found no unset list — the sed range is wrong"; false; }
  missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$defined") <(printf '%s\n' "$unset_list"))"
  [ -z "$missing" ] || {
    echo "adapter hooks missing from adapter_loader's unset list — they leak across a two-adapter load:"
    printf '%s\n' "$missing"
    false
  }
}

@test "an optional hook one adapter defines is not inherited by the next (leak-guard, generalised)" {
  # The list above is a claim about a FILE; this is the same claim about the
  # running shell, for the four hooks round 12 added. claude defines all four
  # of them (grok defines none), so one load of each side proves both halves.
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  local h
  load_adapter claude
  for h in adapter_cwd_from_args adapter_ephemeral_flags adapter_mcp_config_file adapter_tank_fingerprint; do
    declare -F "$h" >/dev/null || { echo "fixture is stale: claude no longer defines $h"; false; }
  done
  load_adapter grok
  # grok defines adapter_cwd_from_args itself, so only the other three can
  # prove a leak here.
  for h in adapter_ephemeral_flags adapter_mcp_config_file adapter_tank_fingerprint; do
    ! declare -F "$h" >/dev/null || { echo "grok inherited claude's $h"; false; }
  done
}
