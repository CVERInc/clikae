# shellcheck shell=bash
# lib/adapters/vercel.sh — adapter for the Vercel CLI.
# Reference: https://vercel.com/docs/cli/global-options (--global-config / -Q)
#
# Vercel has no config-DIRECTORY environment variable; instead each invocation
# takes a `--global-config <DIR>` flag pointing at the directory that holds
# `auth.json` + `config.json`. So this is a `flag`-strategy adapter: there's
# nothing to export into the environment — clikae injects the flag after the
# binary in the generated alias / .app / run command.

adapter_meta_name()        { echo "Vercel CLI"; }
adapter_meta_cli_binary()  { echo "vercel"; }
adapter_meta_env_var()     { echo ""; }   # no config-dir env var — uses a flag
adapter_meta_strategy()    { echo "flag"; }
adapter_meta_description() { echo "Vercel CLI (per-profile dir via --global-config)"; }

# Nothing to seed — vercel creates auth.json/config.json on first `vercel login`.
adapter_init() {
  local profile_dir="$1"
  : "$profile_dir"
}

# flag-strategy adapters export no environment variables.
adapter_export_env() {
  local profile_dir="$1"
  : "$profile_dir"
}

# Flag args appended after the binary by the alias/.app generators. The dir is
# double-quoted so paths with spaces survive inside the single-quoted alias body.
adapter_flag_args() {
  local profile_dir="$1"
  printf -- '--global-config "%s"\n' "$profile_dir"
}

# Exec the CLI with this profile's config dir selected via the flag.
adapter_run() {
  local profile_dir="$1"; shift
  exec vercel --global-config "$profile_dir" "$@"
}
