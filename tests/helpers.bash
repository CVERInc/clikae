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
  # Pin the interface language so assertions are deterministic regardless of the
  # CI/host locale. i18n itself is covered by tests/bats/i18n.bats.
  export CLIKAE_LANG=en-US
  # Keep the suite hermetic: don't let a local-model CLI that happens to be on
  # the dev machine's PATH (apfel/ollama/llm) make `handoff` auto-summarize. Tests
  # that exercise auto-detection re-enable this and stub a summarizer on PATH.
  export CLIKAE_HANDOFF_AUTOLOCAL=0
  RC_FILE="$TEST_HOME/.zshrc"
  # Make EVERY assertion count. bats only enforces a test's LAST command, so an
  # intermediate `[ … ]` (or command) that fails is otherwise silently ignored.
  # set -e (which persists into the test body — same shell) makes `[ … ]` and
  # command failures abort the test. NB: bash EXEMPTS `[[ … ]]` from set -e, so
  # those assertions also carry an explicit `|| false`. See tests/README.md.
  set -e
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
