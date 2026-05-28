# shellcheck shell=bash
# lib/adapters/docker.sh — adapter for the Docker CLI.
# Reference: https://docs.docker.com/reference/cli/docker/#environment-variables (DOCKER_CONFIG)
#
# DOCKER_CONFIG points at the directory holding config.json (registry auth,
# contexts, CLI plugins). A per-profile directory isolates registry logins.

adapter_meta_name()        { echo "Docker CLI"; }
adapter_meta_cli_binary()  { echo "docker"; }
adapter_meta_env_var()     { echo "DOCKER_CONFIG"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "Docker CLI (registry auth + contexts in DOCKER_CONFIG)"; }

adapter_export_env() {
  local profile_dir="$1"
  printf 'DOCKER_CONFIG=%s\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  DOCKER_CONFIG="$profile_dir" exec docker "$@"
}
