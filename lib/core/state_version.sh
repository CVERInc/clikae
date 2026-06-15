# shellcheck shell=bash
# lib/core/state_version.sh — a schema version for everything under $CLIKAE_HOME.
#
# The state dir (profiles/, order, dry/, autonomy, cache/, …) was un-versioned, so
# the moment any on-disk FORMAT needs a new field there'd be no way to tell old from
# new and no migration path. This is the minimum fix: one `$CLIKAE_HOME/version`
# integer + one forward-migration runner. Deliberately restrained — NOT a migration
# framework; just enough that a future format change is safe.
#
# The version is the STATE SCHEMA version, NOT the clikae binary version — it bumps
# only when an on-disk format changes (rare), so most releases don't touch it.
#
# Read-only safe: a steady-state read command never writes here. The version file is
# stamped when state is CREATED (ensure_profile --create → state_version_ensure), and
# state_version_check only writes when it actually runs a migration (a one-time event
# the first time you run a clikae new enough to need it). A missing version file means
# "the original, pre-versioning layout" = v1, handled without any write.

# Bump ONLY when a state format changes, and add a `_state_migrate_<n>` (n→n+1) below.
CLIKAE_STATE_VERSION=1

_state_version_file() { printf '%s/version' "$CLIKAE_HOME"; }

# state_version_read -> the on-disk state schema version as an integer. A missing or
# unparseable file means the original un-versioned layout, which IS v1 — so we never
# treat "no file" as v0 (there was never a v0 to migrate from).
state_version_read() {
  local f v=""; f="$(_state_version_file)"
  [ -f "$f" ] && v="$(tr -dc '0-9' < "$f" 2>/dev/null)"
  [ -n "$v" ] || v=1
  printf '%s' "$v"
}

# state_version_ensure -> stamp the CURRENT schema version. Called when state is
# created/migrated (a write is happening anyway), so read commands stay read-only.
state_version_ensure() {
  [ -d "$CLIKAE_HOME" ] || mkdir -p "$CLIKAE_HOME" 2>/dev/null || return 0
  printf '%s\n' "$CLIKAE_STATE_VERSION" > "$(_state_version_file)" 2>/dev/null || true
}

# state_version_check -> on startup: if the on-disk state is OLDER than this binary
# expects, run the forward migrations and re-stamp; if NEWER, warn (you're running an
# older clikae than last wrote your state); if equal, do nothing (no write). Migrations
# are `_state_migrate_<n>` (migrate state from version n to n+1). No-op when there's no
# state dir yet.
state_version_check() {
  [ -d "$CLIKAE_HOME" ] || return 0
  local cur; cur="$(state_version_read)"
  if [ "$cur" -gt "$CLIKAE_STATE_VERSION" ]; then
    log_warn "Your ~/.clikae was last written by a newer clikae (state v$cur > this binary's v$CLIKAE_STATE_VERSION). Upgrade clikae, or proceed with care."
    return 0
  fi
  [ "$cur" -lt "$CLIKAE_STATE_VERSION" ] || return 0   # current → nothing to do, no write
  local n
  for ((n = cur; n < CLIKAE_STATE_VERSION; n++)); do
    if declare -F "_state_migrate_$n" >/dev/null 2>&1; then
      # NOTE: keep spaces around the arrow. A multibyte `→` jammed directly
      # against `$n`/`$((…))` corrupts under bash 3.2 + a UTF-8 LANG with LC_ALL
      # unset (the digit and the arrow's lead byte get eaten → "v␦␦v2"). The
      # spaced form renders cleanly; the log_dim line below already uses spaces.
      "_state_migrate_$n" || { log_warn "clikae: state migration v$n → v$((n + 1)) failed — left as-is."; return 0; }
      log_dim "clikae: migrated state v$n → v$((n + 1))."
    fi
  done
  state_version_ensure
}
