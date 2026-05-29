# shellcheck shell=bash
# lib/adapters/npm.sh — adapter for the npm CLI.
# Reference: https://docs.npmjs.com/cli/using-npm/config (NPM_CONFIG_USERCONFIG)
#
# Unlike the env-dir adapters, npm's auth lives in a per-user .npmrc FILE, not a
# directory. NPM_CONFIG_USERCONFIG overrides which .npmrc npm reads, and that
# file holds the registry auth tokens (`//registry.npmjs.org/:_authToken=...`),
# scoped-registry config, etc. We keep that file at <profile_dir>/npmrc and seed
# an empty one on init so the path always exists. `npm login` writes into it.

adapter_meta_name()        { echo "npm"; }
adapter_meta_cli_binary()  { echo "npm"; }
adapter_meta_env_var()     { echo "NPM_CONFIG_USERCONFIG"; }
adapter_meta_strategy()    { echo "env-file"; }
adapter_meta_description() { echo "npm (registry auth tokens in a per-profile .npmrc file)"; }

# Seed an empty .npmrc so NPM_CONFIG_USERCONFIG always points at something.
adapter_init() {
  local profile_dir="$1"
  [ -f "$profile_dir/npmrc" ] || touch "$profile_dir/npmrc"
}

adapter_export_env() {
  local profile_dir="$1"
  printf 'NPM_CONFIG_USERCONFIG=%s/npmrc\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  NPM_CONFIG_USERCONFIG="$profile_dir/npmrc" exec npm "$@"
}
