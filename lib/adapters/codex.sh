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

# Optional hook: start a session seeded with an initial prompt (for
# `clikae handoff --to codex/<profile>`). Codex takes a positional prompt.
adapter_start_with_prompt() {
  local profile_dir="$1" prompt="$2"; shift 2
  CODEX_HOME="$profile_dir" exec codex "$prompt" "$@"
}

# Optional hook: the logged-in account label, shown by `clikae list` / `status`
# and the dashboard. With ChatGPT auth, codex stores identity in auth.json's
# `id_token` — a JWT whose base64url payload carries the account email. Decode
# with grep/sed/tr + base64 (no jq); API-key logins have no id_token, so they
# just yield nothing. Never propagate a no-match under the caller's `set -eo
# pipefail` (it would abort list/status) — always end at return 0.
adapter_account_label() {
  local f="$1/auth.json" idt payload decoded
  [ -f "$f" ] || return 0
  idt="$(grep -oE '"id_token"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
        | head -n 1 | sed -E 's/.*"id_token"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  [ -n "$idt" ] || return 0
  # JWT = header.payload.signature; the payload is base64url (no padding).
  payload="$(printf '%s' "$idt" | cut -d. -f2 | tr '_-' '/+')"
  [ -n "$payload" ] || return 0
  case $(( ${#payload} % 4 )) in 2) payload="$payload==" ;; 3) payload="$payload=" ;; esac
  # base64 -d (GNU + recent macOS) with a -D fallback for older BSD.
  decoded="$(printf '%s' "$payload" | base64 -d 2>/dev/null || printf '%s' "$payload" | base64 -D 2>/dev/null || true)"
  [ -n "$decoded" ] || return 0
  printf '%s' "$decoded" \
    | grep -oE '"email"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n 1 | sed -E 's/.*:[[:space:]]*"//; s/"$//' || true
  return 0
}
