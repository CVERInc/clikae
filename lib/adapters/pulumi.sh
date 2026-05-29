# shellcheck shell=bash
# lib/adapters/pulumi.sh — adapter for the Pulumi CLI.
# Reference: https://www.pulumi.com/docs/cli/environment-variables/ (PULUMI_HOME)
#
# PULUMI_HOME (default ~/.pulumi) holds credentials.json (your backend login +
# access tokens), plugins, and templates — so pointing it at a per-profile
# directory isolates one Pulumi account/backend from another.

adapter_meta_name()        { echo "Pulumi"; }
adapter_meta_cli_binary()  { echo "pulumi"; }
adapter_meta_env_var()     { echo "PULUMI_HOME"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "Pulumi (backend login + credentials in PULUMI_HOME)"; }

adapter_export_env() {
  local profile_dir="$1"
  printf 'PULUMI_HOME=%s\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  PULUMI_HOME="$profile_dir" exec pulumi "$@"
}
