# shellcheck shell=bash
# lib/adapters/aws.sh — adapter for the AWS CLI.
# Reference: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html (AWS_PROFILE)
#
# AWS is different from the env-dir adapters: it does NOT isolate config into a
# separate directory. Instead AWS_PROFILE holds the NAME of a profile defined in
# your shared config (~/.aws/config and ~/.aws/credentials). The clikae profile
# NAME is used verbatim as AWS_PROFILE, so `clikae init aws work` expects a
# matching `[profile work]` (and/or `[work]` credentials) entry to already exist.
#
# (If you'd rather give each clikae profile its own isolated credentials file,
# write an `env-file` adapter pointing AWS_SHARED_CREDENTIALS_FILE /
# AWS_CONFIG_FILE at <profile_dir> instead — see docs/adding-an-adapter.md.)

adapter_meta_name()        { echo "AWS CLI"; }
adapter_meta_cli_binary()  { echo "aws"; }
adapter_meta_env_var()     { echo "AWS_PROFILE"; }
adapter_meta_strategy()    { echo "env-var"; }
adapter_meta_description() { echo "AWS CLI (selects a named profile from your shared AWS config via AWS_PROFILE)"; }

adapter_export_env() {
  local profile_dir="$1"
  printf 'AWS_PROFILE=%s\n' "$(basename "$profile_dir")"
}

adapter_run() {
  local profile_dir="$1"; shift
  AWS_PROFILE="$(basename "$profile_dir")" exec aws "$@"
}
