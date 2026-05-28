# shellcheck shell=bash
# lib/adapters/gh.sh — adapter for the GitHub CLI.
# Reference: https://cli.github.com/manual/gh_help_environment (GH_CONFIG_DIR)
#
# GH_CONFIG_DIR holds hosts.yml (auth tokens) + config.yml, so pointing it at a
# per-profile directory fully isolates one GitHub account from another.

adapter_meta_name()        { echo "GitHub CLI"; }
adapter_meta_cli_binary()  { echo "gh"; }
adapter_meta_env_var()     { echo "GH_CONFIG_DIR"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "GitHub CLI (auth + config in GH_CONFIG_DIR)"; }

adapter_export_env() {
  local profile_dir="$1"
  printf 'GH_CONFIG_DIR=%s\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  GH_CONFIG_DIR="$profile_dir" exec gh "$@"
}
