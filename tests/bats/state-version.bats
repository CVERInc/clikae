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
  clikae init claude work
  [ -f "$CLIKAE_HOME/version" ]
  run cat "$CLIKAE_HOME/version"
  [ "$output" = "1" ]
}

@test "state_version_read: no file = the original un-versioned layout = v1" {
  _src; mkdir -p "$CLIKAE_HOME"
  run state_version_read
  [ "$output" = "1" ]
}

@test "state_version_read: reads the stamped integer" {
  _src; mkdir -p "$CLIKAE_HOME"; printf '3\n' > "$CLIKAE_HOME/version"
  run state_version_read
  [ "$output" = "3" ]
}

@test "state_version_check: current version is a no-op (writes nothing)" {
  _src; mkdir -p "$CLIKAE_HOME"; printf '1\n' > "$CLIKAE_HOME/version"
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
  _src; mkdir -p "$CLIKAE_HOME"     # no version file at all
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

# --- end-to-end v1 -> v2 forward migration (the future-format-change rehearsal) ---
# Simulates the real lifecycle of the FIRST on-disk format change: a tank created by
# an old (v1) clikae, then a newer binary that bumps CLIKAE_STATE_VERSION to 2 and
# ships a `_state_migrate_1` hook (the convention is `_state_migrate_<n>` = n -> n+1,
# so v1->v2 is `_state_migrate_1`). Asserts the hook (a) sees the OLD layout, (b)
# actually runs exactly once, and (c) leaves the version file stamped at the new 2.
@test "state schema v1 -> v2: a real v1 tank migrates forward and re-stamps to 2" {
  _src
  # 1) An old (v1) clikae creates a tank. No bump yet → version stamps as 1.
  clikae init claude work
  [ "$(cat "$CLIKAE_HOME/version")" = "1" ]
  # Pretend v1's layout kept a setting in a flat file the v2 format relocates.
  printf 'legacy-value\n' > "$CLIKAE_HOME/old_setting"

  # 2) A newer binary: bump the schema to 2 and register the v1->v2 migration.
  CLIKAE_STATE_VERSION=2
  _migrate_runs=0
  _state_migrate_1() {
    _migrate_runs=$((_migrate_runs + 1))
    # The migration sees the OLD (v1) layout and moves it into the v2 shape.
    [ -f "$CLIKAE_HOME/old_setting" ] || return 1     # must run BEFORE re-stamp
    mkdir -p "$CLIKAE_HOME/settings"
    mv "$CLIKAE_HOME/old_setting" "$CLIKAE_HOME/settings/value"
  }

  # 3) Startup runs the forward migration.
  state_version_check

  [ "$_migrate_runs" -eq 1 ]                            # ran exactly once
  [ ! -f "$CLIKAE_HOME/old_setting" ]                   # old layout gone
  [ "$(cat "$CLIKAE_HOME/settings/value")" = "legacy-value" ]   # data carried over
  [ "$(cat "$CLIKAE_HOME/version")" = "2" ]             # re-stamped to the new version

  # 4) Idempotent: a second startup at v2 is a no-op (the hook does NOT run again).
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
