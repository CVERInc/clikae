#!/usr/bin/env bats
# tests/bats/state-version.bats — the $CLIKAE_HOME state-schema version + forward
# migration runner (lib/core/state_version.sh). The minimum that makes a future
# on-disk format change safe. (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/state_version.sh"
}

@test "init stamps the state schema version" {
  # 🔴 Asks the source what "current" is instead of writing it down. Hardcoded,
  # this test breaks on every bump — which is a red light that means "someone
  # changed a number", not "something is wrong", and those get fixed by editing
  # the number until one day the number was wrong.
  _src
  clikae init claude work
  [ -f "$CLIKAE_HOME/version" ]
  run cat "$CLIKAE_HOME/version"
  [ "$output" = "$CLIKAE_STATE_VERSION" ] || {
    echo "stamped '$output', current schema is $CLIKAE_STATE_VERSION"; false; }
}

@test "state_version_read: no file = the original un-versioned layout = v1" {
  # helpers stamps the current schema so ordinary tests never see a migration
  # message; this one is ABOUT the file being absent, so it takes it away again.
  _src; mkdir -p "$CLIKAE_HOME"; rm -f "$CLIKAE_HOME/version"
  run state_version_read
  [ "$output" = "1" ]
}

@test "state_version_read: reads the stamped integer" {
  _src; mkdir -p "$CLIKAE_HOME"; printf '3\n' > "$CLIKAE_HOME/version"
  run state_version_read
  [ "$output" = "3" ]
}

@test "state_version_check: current version is a no-op (writes nothing)" {
  # "current" comes from the source, not from a literal — see the note on the
  # rehearsal below. Stamped `1` here, this passed until the day v2 shipped.
  _src; mkdir -p "$CLIKAE_HOME"; printf '%s\n' "$CLIKAE_STATE_VERSION" > "$CLIKAE_HOME/version"
  local before; before="$(find "$CLIKAE_HOME" | sort; echo --; cat "$CLIKAE_HOME/version")"
  state_version_check
  local after; after="$(find "$CLIKAE_HOME" | sort; echo --; cat "$CLIKAE_HOME/version")"
  [ "$before" = "$after" ]
}

@test "state_version_check: an OLDER on-disk version runs the migration and re-stamps" {
  _src; mkdir -p "$CLIKAE_HOME"; printf '1\n' > "$CLIKAE_HOME/version"
  CLIKAE_STATE_VERSION=2
  _state_migrate_1() { touch "$CLIKAE_HOME/.migrated_1"; }
  state_version_check
  [ -f "$CLIKAE_HOME/.migrated_1" ]               # migration ran
  [ "$(cat "$CLIKAE_HOME/version")" = "2" ]       # re-stamped to current
}

@test "state_version_check: NO version file but v2 binary migrates from v1 (no-file = v1)" {
  _src; mkdir -p "$CLIKAE_HOME"; rm -f "$CLIKAE_HOME/version"     # no version file at all
  CLIKAE_STATE_VERSION=2
  _state_migrate_1() { touch "$CLIKAE_HOME/.migrated_from_unversioned"; }
  state_version_check
  [ -f "$CLIKAE_HOME/.migrated_from_unversioned" ]
  [ "$(cat "$CLIKAE_HOME/version")" = "2" ]
}

@test "state_version_check: a NEWER on-disk version warns and does NOT downgrade" {
  _src; mkdir -p "$CLIKAE_HOME"; printf '9\n' > "$CLIKAE_HOME/version"
  run state_version_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"newer clikae"* ]] || false
  [ "$(cat "$CLIKAE_HOME/version")" = "9" ]        # untouched
}

@test "state_version_check: no state dir at all is a clean no-op" {
  _src
  rm -rf "$CLIKAE_HOME"
  run state_version_check
  [ "$status" -eq 0 ]
  [ ! -d "$CLIKAE_HOME" ]                          # didn't create anything
}

# --- end-to-end forward migration (the format-change rehearsal) ---
# The lifecycle of an on-disk format change: a tank created by the CURRENT binary,
# then a newer one that bumps CLIKAE_STATE_VERSION by one and ships the matching
# `_state_migrate_<n>` hook (the convention is n -> n+1). Asserts the hook (a) sees
# the OLD layout, (b) runs exactly once, and (c) leaves the version re-stamped.
#
# 🔴 Written against "current + 1", not against a literal version pair. It used to
# rehearse v1 -> v2; the day v2 became real, this test failed for having been
# overtaken rather than for finding anything. The rehearsal is about the RUNNER,
# and the runner does not care which numbers it is between.
@test "state schema: a real tank migrates forward one version and re-stamps" {
  _src
  local from="$CLIKAE_STATE_VERSION" to=$((CLIKAE_STATE_VERSION + 1))
  # 1) The current binary creates a tank. Version stamps at today's schema.
  clikae init claude work
  [ "$(cat "$CLIKAE_HOME/version")" = "$from" ]
  # Pretend this layout keeps a setting in a flat file the next format relocates.
  printf 'legacy-value\n' > "$CLIKAE_HOME/old_setting"

  # 2) A newer binary: bump the schema and register the matching migration.
  CLIKAE_STATE_VERSION="$to"
  _migrate_runs=0
  eval "_state_migrate_$from() {
    _migrate_runs=\$((_migrate_runs + 1))
    [ -f \"\$CLIKAE_HOME/old_setting\" ] || return 1   # must run BEFORE re-stamp
    mkdir -p \"\$CLIKAE_HOME/settings\"
    mv \"\$CLIKAE_HOME/old_setting\" \"\$CLIKAE_HOME/settings/value\"
  }"

  # 3) Startup runs the forward migration.
  state_version_check

  [ "$_migrate_runs" -eq 1 ]                            # ran exactly once
  [ ! -f "$CLIKAE_HOME/old_setting" ]                   # old layout gone
  [ "$(cat "$CLIKAE_HOME/settings/value")" = "legacy-value" ]   # data carried over
  [ "$(cat "$CLIKAE_HOME/version")" = "$to" ]           # re-stamped

  # 4) Idempotent: a second startup at the new version does NOT run it again.
  state_version_check
  [ "$_migrate_runs" -eq 1 ]
}

@test "state schema: a FAILED v1 -> v2 migration leaves the version UNbumped (safe)" {
  _src
  mkdir -p "$CLIKAE_HOME"; printf '1\n' > "$CLIKAE_HOME/version"
  CLIKAE_STATE_VERSION=2
  _state_migrate_1() { return 1; }                     # the migration fails
  run state_version_check
  [ "$status" -eq 0 ]                                  # never aborts the user's command
  # The arrow is spaced on purpose (bash 3.2 + UTF-8 LANG corrupts a multibyte `→`
  # jammed against $n/$((…)) into "v␦␦v2" — regression guard for that env bug).
  [[ "$output" == *"migration v1 → v2 failed"* ]] || false
  [ "$(cat "$CLIKAE_HOME/version")" = "1" ]            # NOT re-stamped → retried next run
}
