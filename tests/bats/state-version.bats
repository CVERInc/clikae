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
