# shellcheck shell=bash
# lib/adapters/terraform.sh — adapter for the Terraform CLI.
# Reference: https://developer.hashicorp.com/terraform/cli/config/config-file (TF_CLI_CONFIG_FILE)
#
# Unlike the env-dir adapters, Terraform's CLI configuration is a single FILE
# (the ".terraformrc"), not a directory. TF_CLI_CONFIG_FILE overrides its
# location, and that file holds `credentials` blocks for Terraform Cloud / HCP
# Terraform and private module registries — so a per-profile file isolates one
# org/account login from another. We keep it at <profile_dir>/terraformrc and
# seed an empty one on init; `terraform login` writes the token into it.

adapter_meta_name()        { echo "Terraform"; }
adapter_meta_cli_binary()  { echo "terraform"; }
adapter_meta_env_var()     { echo "TF_CLI_CONFIG_FILE"; }
adapter_meta_strategy()    { echo "env-file"; }
adapter_meta_description() { echo "Terraform (Terraform Cloud / registry credentials in a CLI config file)"; }

# Seed an empty CLI config file so TF_CLI_CONFIG_FILE always points at something.
adapter_init() {
  local profile_dir="$1"
  [ -f "$profile_dir/terraformrc" ] || touch "$profile_dir/terraformrc"
}

adapter_export_env() {
  local profile_dir="$1"
  printf 'TF_CLI_CONFIG_FILE=%s/terraformrc\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  TF_CLI_CONFIG_FILE="$profile_dir/terraformrc" exec terraform "$@"
}
