# shellcheck shell=bash
# lib/adapters/helm.sh — adapter for the Helm CLI.
# Reference: https://helm.sh/docs/helm/helm/ (HELM_CONFIG_HOME)
#
# HELM_CONFIG_HOME holds repositories.yaml and registry/config.json (registry
# auth). A per-profile directory isolates repo lists and OCI registry logins.

adapter_meta_name()        { echo "Helm"; }
adapter_meta_cli_binary()  { echo "helm"; }
adapter_meta_env_var()     { echo "HELM_CONFIG_HOME"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "Helm (repo list + registry auth in HELM_CONFIG_HOME)"; }

adapter_export_env() {
  local profile_dir="$1"
  printf 'HELM_CONFIG_HOME=%s\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  HELM_CONFIG_HOME="$profile_dir" exec helm "$@"
}
