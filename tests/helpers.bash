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
  # Host-independence: agy's "is a session running?" guard uses `pgrep -x agy`,
  # which would otherwise see a REAL Antigravity running on the dev machine and
  # make agy tests fail nondeterministically. Stub a no-match pgrep on PATH (no
  # test relies on real pgrep). CI has no agy running, so this only matters locally.
  mkdir -p "$TEST_HOME/.testbin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_HOME/.testbin/pgrep"
  chmod +x "$TEST_HOME/.testbin/pgrep"
  # Host-safety: agy's per-tank login carry shells out to `security`. WITHOUT a
  # stub, running the suite on a real Mac would read/WRITE/DELETE the maintainer's
  # actual `gemini` login Keychain item — corrupting their real agy login. Stub a
  # stateful `security` (one file per service under $TEST_HOME/.testkeychain) so
  # every test is hermetic. Tests that need their own keychain behaviour (e.g.
  # migrate.bats) prepend their own stub later in PATH and win.
  export CLIKAE_TEST_KEYCHAIN="$TEST_HOME/.testkeychain"
  mkdir -p "$CLIKAE_TEST_KEYCHAIN"
  cat > "$TEST_HOME/.testbin/security" <<'SECSTUB'
#!/usr/bin/env bash
state="${CLIKAE_TEST_KEYCHAIN:?}"
sub="$1"; shift
svc=""; want_w=0; secret=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift 2 ;;
    -w) shift
        if [ "$sub" = "add-generic-password" ]; then secret="$1"; shift; else want_w=1; fi ;;
    -a|-l) shift 2 ;;
    -U|-g) shift ;;
    *) shift ;;
  esac
done
file="$state/$svc"
case "$sub" in
  find-generic-password)
    [ -f "$file" ] || exit 1
    if [ "$want_w" -eq 1 ]; then cat "$file"; else echo '    "acct"<blob>="antigravity"'; fi
    exit 0 ;;
  add-generic-password)  printf '%s' "$secret" > "$file"; exit 0 ;;
  delete-generic-password) rm -f "$file"; exit 0 ;;
esac
exit 1
SECSTUB
  chmod +x "$TEST_HOME/.testbin/security"
  export PATH="$TEST_HOME/.testbin:$PATH"
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
