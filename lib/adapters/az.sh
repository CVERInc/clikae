# shellcheck shell=bash
# lib/adapters/az.sh — adapter for the Azure CLI.
# Reference: https://learn.microsoft.com/cli/azure/azure-cli-configuration (AZURE_CONFIG_DIR)
#
# AZURE_CONFIG_DIR points at the directory holding azureProfile.json (your
# subscriptions), the token cache, and config — so pointing it at a per-profile
# directory fully isolates one Azure tenant/account from another.

adapter_meta_name()        { echo "Azure CLI"; }
adapter_meta_cli_binary()  { echo "az"; }
adapter_meta_env_var()     { echo "AZURE_CONFIG_DIR"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "Azure CLI (subscriptions + token cache in AZURE_CONFIG_DIR)"; }

adapter_export_env() {
  local profile_dir="$1"
  printf 'AZURE_CONFIG_DIR=%s\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  AZURE_CONFIG_DIR="$profile_dir" exec az "$@"
}
