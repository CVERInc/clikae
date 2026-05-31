# shellcheck shell=bash
# lib/adapters/codex.sh — adapter for the OpenAI Codex CLI.
# Reference: https://developers.openai.com/codex/config-advanced (CODEX_HOME)
#
# Codex keeps all of its local state — config.toml, auth.json, session history —
# under CODEX_HOME (default ~/.codex). Pointing CODEX_HOME at a per-profile
# directory gives each profile its own login + settings, so this is a plain
# env-dir adapter (same shape as claude).

adapter_meta_name()        { echo "OpenAI Codex CLI"; }
adapter_meta_cli_binary()  { echo "codex"; }
adapter_meta_env_var()     { echo "CODEX_HOME"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "OpenAI Codex CLI (auth + config + history in CODEX_HOME)"; }

# Nothing to seed — codex initialises CODEX_HOME on first run / login.
adapter_init() {
  local profile_dir="$1"
  : "$profile_dir"
}

adapter_export_env() {
  local profile_dir="$1"
  printf 'CODEX_HOME=%s\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  CODEX_HOME="$profile_dir" exec codex "$@"
}
