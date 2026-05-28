# shellcheck shell=bash
# tests/helpers.bash — shared setup/teardown for the bats suite.
#
# Each test runs against a throwaway $HOME + $CLIKAE_HOME so it never touches
# your real config. We pin $SHELL=/bin/zsh so detect_shell_rc resolves to a
# predictable ~/.zshrc, and set NO_COLOR so output assertions stay clean.

# Repo root: this file lives at <root>/tests/helpers.bash.
CLIKAE_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIKAE_BIN="$CLIKAE_TEST_ROOT/bin/clikae"

setup() {
  TEST_HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/clikae-test.XXXXXX")"
  export HOME="$TEST_HOME"
  export CLIKAE_HOME="$TEST_HOME/.clikae"
  export SHELL="/bin/zsh"
  export NO_COLOR=1
  RC_FILE="$TEST_HOME/.zshrc"
}

teardown() {
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
}

# Invoke the real clikae binary with the test environment.
clikae() {
  "$CLIKAE_BIN" "$@"
}

# Count how many clikae sentinel-open lines for <id> are in the rc file.
rc_block_count() {
  local id="$1"
  [ -f "$RC_FILE" ] || { echo 0; return; }
  grep -cF "# >>> clikae:$id >>>" "$RC_FILE"
}

# Count how many *.clikae.bak.* backups exist next to the rc file.
rc_backup_count() {
  local n
  n=$(find "$TEST_HOME" -maxdepth 1 -name '.zshrc.clikae.bak.*' 2>/dev/null | wc -l)
  echo "$((n))"
}
