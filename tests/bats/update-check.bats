#!/usr/bin/env bats
# tests/bats/update-check.bats — the "✨ a newer clikae is out" plumbing
# (lib/core/update_check.sh). Pure logic only: version compare, the pending gate
# (cache + skip), and install-method detection. NO network — the fetch is gated by
# the cache TTL and never runs here (tests seed the cache directly).

load '../helpers'

_src() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/update_check.sh"
}

_seed_cache() { # <version>  (stamp = now, so refresh sees it as fresh and skips the network)
  mkdir -p "$CLIKAE_HOME/cache"
  printf '%s\t%s\n' "$(date +%s)" "$1" > "$CLIKAE_HOME/cache/update-check"
}

# --- version compare -----------------------------------------------------------

@test "update_version_gt: basic ordering" {
  _src
  update_version_gt 0.5.9 0.5.8
  run update_version_gt 0.5.8 0.5.9
  [ "$status" -ne 0 ]
}

@test "update_version_gt: equal is NOT greater" {
  _src
  run update_version_gt 0.5.8 0.5.8
  [ "$status" -ne 0 ]
}

@test "update_version_gt: compares segments numerically (0.5.10 > 0.5.9)" {
  _src
  update_version_gt 0.5.10 0.5.9
  run update_version_gt 0.5.9 0.5.10
  [ "$status" -ne 0 ]
}

@test "update_version_gt: tolerates a v prefix / pre-release tail" {
  _src
  update_version_gt v0.6.0 0.5.9
  update_version_gt 0.6.0-beta 0.5.9
}

# --- pending gate --------------------------------------------------------------

@test "update_check_pending: a newer cached version is pending + echoed" {
  _src
  export CLIKAE_VERSION=0.5.8
  _seed_cache 0.5.9
  run update_check_pending
  [ "$status" -eq 0 ]
  [ "$output" = "0.5.9" ]
}

@test "update_check_pending: same/older cached version is NOT pending" {
  _src
  export CLIKAE_VERSION=0.5.9
  _seed_cache 0.5.9
  run update_check_pending
  [ "$status" -ne 0 ]
}

@test "update_check_pending: nothing pending with no cache" {
  _src
  export CLIKAE_VERSION=0.5.8
  run update_check_pending
  [ "$status" -ne 0 ]
}

@test "update_check_pending: a skipped version stays quiet until something newer ships" {
  _src
  export CLIKAE_VERSION=0.5.8
  _seed_cache 0.5.9
  update_check_skip 0.5.9
  run update_check_pending
  [ "$status" -ne 0 ]            # 0.5.9 was skipped → quiet
  _seed_cache 0.6.0
  run update_check_pending
  [ "$status" -eq 0 ]           # but 0.6.0 is newer than the skip → speaks up again
  [ "$output" = "0.6.0" ]
}

@test "update_check_pending: CLIKAE_NO_UPDATE_CHECK disables it entirely" {
  _src
  export CLIKAE_VERSION=0.5.8 CLIKAE_NO_UPDATE_CHECK=1
  _seed_cache 0.9.9
  run update_check_pending
  [ "$status" -ne 0 ]
}

# --- install-method detection --------------------------------------------------

@test "update_install_method: a Cellar path is brew" {
  _src
  export CLIKAE_ROOT="/opt/homebrew/Cellar/clikae/0.5.8/libexec"
  run update_install_method
  [ "$output" = "brew" ]
  run update_upgrade_command
  [ "$output" = "brew upgrade clikae" ]
}

@test "update_install_method: a ~/.local path is curl" {
  _src
  export CLIKAE_ROOT="$HOME/.local/share/clikae"
  run update_install_method
  [ "$output" = "curl" ]
}

@test "update_install_method: anywhere else is unknown (no upgrade command, never guess-run)" {
  _src
  export CLIKAE_ROOT="$TEST_HOME/some/dev/checkout"
  # brew may exist on the host but the root isn't under its prefix
  run update_install_method
  [ "$output" = "unknown" ]
  run update_upgrade_command
  [ -z "$output" ]
}
