# shellcheck shell=bash
# lib/adapters/claude.sh — adapter for Anthropic Claude Code CLI.
# Reference: https://docs.claude.com/en/docs/claude-code/iam (CLAUDE_CONFIG_DIR)

adapter_meta_name()        { echo "Claude Code"; }
adapter_meta_cli_binary()  { echo "claude"; }
adapter_meta_env_var()     { echo "CLAUDE_CONFIG_DIR"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "Anthropic Claude Code CLI (credentials + settings in CLAUDE_CONFIG_DIR)"; }

# adapter_init is optional. For Claude there's nothing to seed — the CLI itself
# initialises the directory on first login.
adapter_init() {
  local profile_dir="$1"
  : "$profile_dir"  # silence shellcheck
}

# Print KEY=VALUE pairs (one per line) to export when activating this profile.
adapter_export_env() {
  local profile_dir="$1"
  printf 'CLAUDE_CONFIG_DIR=%s\n' "$profile_dir"
}

# Exec the CLI with this profile's env applied.
adapter_run() {
  local profile_dir="$1"; shift
  CLAUDE_CONFIG_DIR="$profile_dir" exec claude "$@"
}

# --- macOS keychain login carry-over (optional migrate hook) ----------------
#
# On macOS, Claude Code stores its OAuth token in the login Keychain, NOT inside
# CLAUDE_CONFIG_DIR. The keychain service name is
#   "Claude Code-credentials-<suffix>"
# where <suffix> is the first 8 hex chars of sha256(<absolute CLAUDE_CONFIG_DIR>)
# (no trailing slash). So `clikae migrate`, which MOVES the config dir to a new
# path, changes the suffix and orphans the saved token — claude can't find it at
# the new path and asks you to log in again. Full write-up: docs/claude-on-macos.md.
#
# Map a config dir to its keychain service name (macOS sha256 via `shasum`).
_claude_keychain_service() {
  local dir="$1" hash
  hash="$(printf '%s' "$dir" | shasum -a 256 2>/dev/null | cut -c1-8)"
  [ -n "$hash" ] || return 1
  printf 'Claude Code-credentials-%s\n' "$hash"
}

# Optional adapter hook: `clikae migrate --keep-login` calls this after moving a
# profile's config dir, to carry the saved login from the old path's keychain
# slot to the new path's slot so the session survives the move.
#
# Returns: 0 = login copied; 1 = nothing to do (no old slot / new slot already
# present / not macOS); 2 = found a saved login but couldn't copy it.
# Never prints the secret.
adapter_migrate_credentials() {
  local old_dir="$1" new_dir="$2"
  case "$OSTYPE" in darwin*) ;; *) return 1 ;; esac
  command -v security >/dev/null 2>&1 || return 1

  local old_svc new_svc
  old_svc="$(_claude_keychain_service "$old_dir")" || return 1
  new_svc="$(_claude_keychain_service "$new_dir")" || return 1

  # Nothing saved at the old path → nothing to carry over.
  security find-generic-password -s "$old_svc" >/dev/null 2>&1 || return 1
  # Already present at the new path → don't clobber it.
  security find-generic-password -s "$new_svc" >/dev/null 2>&1 && return 1

  local acct secret
  acct="$(security find-generic-password -s "$old_svc" 2>/dev/null \
            | awk -F'"' '/^[[:space:]]*"acct"/{print $4}')"
  [ -n "$acct" ] || return 2
  secret="$(security find-generic-password -s "$old_svc" -w 2>/dev/null)" || return 2
  [ -n "$secret" ] || return 2

  security add-generic-password -a "$acct" -s "$new_svc" -l "$new_svc" \
    -w "$secret" -U >/dev/null 2>&1 || { secret=""; return 2; }
  secret=""
  return 0
}
