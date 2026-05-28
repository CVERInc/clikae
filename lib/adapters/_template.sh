# shellcheck shell=bash
# lib/adapters/_template.sh — copy this to <your-cli>.sh and fill in the blanks.
#
# An adapter teaches clikae HOW to switch profiles for a particular CLI tool.
# Most modern CLIs follow one of these strategies:
#
#   env-dir   : a single env var points at a config DIRECTORY
#               examples: CLAUDE_CONFIG_DIR, GH_CONFIG_DIR, CLOUDSDK_CONFIG, DOCKER_CONFIG
#
#   env-file  : a single env var points at a config FILE
#               examples: KUBECONFIG, AWS_CONFIG_FILE
#
#   env-var   : a single env var holds the profile NAME (the CLI looks it up internally)
#               examples: AWS_PROFILE
#
#   flag      : the CLI takes a --profile-style flag (wrapper injects it)
#               examples: aws --profile, doctl --context
#
#   subcommand: the CLI has its own activate/use command we shell out to
#               examples: gcloud config configurations activate, kubectl config use-context
#
# Pick one and implement adapter_export_env + adapter_run accordingly.

adapter_meta_name()        { echo "Example CLI"; }
adapter_meta_cli_binary()  { echo "example"; }
adapter_meta_env_var()     { echo "EXAMPLE_CONFIG_DIR"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "Short one-line description of what this CLI is for."; }

# Optional: called once when `clikae init` creates a new profile.
# Use it to seed the profile dir with default files, run `cli init`, etc.
adapter_init() {
  local profile_dir="$1"
  : "$profile_dir"
}

# Required: print KEY=VALUE pairs (one per line) for the env vars that need
# to be exported when this profile is active. Used by:
#   - the shell alias generator
#   - the .app launcher generator
adapter_export_env() {
  local profile_dir="$1"
  printf 'EXAMPLE_CONFIG_DIR=%s\n' "$profile_dir"
}

# Required: invoke the CLI with this profile active. Use exec so signals work.
adapter_run() {
  local profile_dir="$1"; shift
  EXAMPLE_CONFIG_DIR="$profile_dir" exec example "$@"
}
