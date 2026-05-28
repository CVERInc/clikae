# shellcheck shell=bash
# lib/adapters/gcloud.sh — adapter for the Google Cloud CLI.
# Reference: https://cloud.google.com/sdk/docs/configurations (CLOUDSDK_CONFIG)
#
# CLOUDSDK_CONFIG is the gcloud config directory (active config, credentials,
# named configurations). A per-profile directory keeps each account's auth and
# active project fully separate.

adapter_meta_name()        { echo "Google Cloud CLI"; }
adapter_meta_cli_binary()  { echo "gcloud"; }
adapter_meta_env_var()     { echo "CLOUDSDK_CONFIG"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "Google Cloud CLI (auth + active config in CLOUDSDK_CONFIG)"; }

adapter_export_env() {
  local profile_dir="$1"
  printf 'CLOUDSDK_CONFIG=%s\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  CLOUDSDK_CONFIG="$profile_dir" exec gcloud "$@"
}
