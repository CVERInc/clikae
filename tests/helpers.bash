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
  # Host-safety: git exports these into every hook it runs, and $GIT_DIR is
  # RELATIVE (".git"). A test that cd's into its own throwaway repo and calls
  # `git config` would therefore write to whichever repo invoked the hook — the
  # real one. That is not hypothetical: running this suite from a pre-push hook
  # wrote `user.name = Wrong Person` into the maintainer's clikae config on
  # 2026-07-12 (from git_id.bats' deliberately-wrong fixture) and every commit
  # for the next month carried it. The hook unsets these too; both, because
  # either one alone leaves the suite unsafe to run from the other's context.
  unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_QUARANTINE_PATH \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
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
  # ONE stub, shared with the pty harness — see tests/stubs/security for why
  # this is host safety rather than convenience.
  cp "$CLIKAE_TEST_ROOT/tests/stubs/security" "$TEST_HOME/.testbin/security"
  chmod +x "$TEST_HOME/.testbin/security"
  export PATH="$TEST_HOME/.testbin:$PATH"
  # Pin the interface language so assertions are deterministic regardless of the
  # CI/host locale. i18n itself is covered by tests/bats/i18n.bats.
  # Answer the wake question up front. Since 2026-08-13 a launch asks once, at
  # the moment a human is present — and a pty-driven test IS a terminal, so every
  # launch test would sit at that prompt forever. `off` rather than `on`: a test
  # that means to exercise the waiter says so, and one that does not should never
  # have a background window typing into its session.
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  printf 'off\n' > "$CLIKAE_HOME/wake-on-reset"
  # 🔴 Stamp the CURRENT schema so no test is surprised by a migration. Without
  # this, the first clikae in a test prints "migrated state v1 → v2" and the
  # second does not — which broke the byte-identical-alias test the day the
  # schema was bumped, for a reason that had nothing to do with aliases. Read
  # from the source rather than written down, so the next bump does not repeat
  # this. Tests that exercise migrations overwrite the file themselves.
  printf '%s\n' "$(sed -n 's/^CLIKAE_STATE_VERSION=//p' \
    "$CLIKAE_TEST_ROOT/lib/core/state_version.sh" | head -1)" > "$CLIKAE_HOME/version"

  # 🔴 PIN THE LIBRARY PATH, or a test inherits the developer's INSTALLED clikae.
  # Eleven test files source library code through $CLIKAE_LIB, and helpers did not
  # set it — so each one set it itself, and any that forgot picked up whatever the
  # surrounding shell had. On this machine that is
  # /opt/homebrew/Cellar/clikae/0.27.0/libexec/lib: a test could source clean.sh
  # from the working tree and have it pull resume.sh from a release five versions
  # old, and pass. It failed on CI, where nothing is installed and the variable is
  # empty — which is the honest environment, arriving late.
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  export CLIKAE_ROOT="$CLIKAE_TEST_ROOT"
  # A test is not running inside a tank, whatever launched the suite thinks. This
  # arrives set whenever the developer runs the gate from a clikae session, and
  # never on CI — so leaving it is a difference between the two environments for
  # no reason.
  unset CLIKAE_TANK_NAME
  # …and the VERSION must come from the tree under test, not from whatever is
  # installed. Inherited, it reads 0.27.0 here while bin/clikae says 0.28.2.
  unset CLIKAE_VERSION
  export CLIKAE_LANG=en-US
  # Host-safety: the tmux tests are not polite guests. roam.bats calls a bare
  # `tmux kill-server` twice (it needs a known-empty server to prove create-or-
  # attach), and that command has no notion of "only the ones I made" — on the
  # default socket it kills every clikae tank the maintainer has open, mid-work,
  # with no warning and nothing to resume from. Found 2026-08-15 while auditing
  # this layer: `scripts/test.sh` was unsafe to run on any machine with live
  # tanks, which is every machine that dogfoods clikae.
  #
  # TMUX_TMPDIR moves the socket, so the suite gets a whole server of its own
  # ($TEST_HOME/tmux/tmux-<uid>/default) and `kill-server` can only reach that.
  #
  # 🔴 TMUX_TMPDIR ALONE IS NOT ENOUGH. A tmux client prefers an inherited $TMUX
  # over TMUX_TMPDIR, and anyone who runs this suite from a tmux pane — the normal
  # way to run it on a machine that dogfoods clikae — has $TMUX set. Measured:
  #
  #   TMUX_TMPDIR=<iso> tmux list-sessions                 -> isolated
  #   TMUX=<real> TMUX_TMPDIR=<iso> tmux list-sessions      -> the REAL server's
  #                                                            four live tanks
  #
  # So the variable that actually decides has to go. tmux-label.bats already knew
  # this and passed `env -u TMUX` per call; doing it here covers every test,
  # including the ones that shell out to python and call tmux from there.
  #
  # This is the same root cause the suite is testing for — a tmux server belongs
  # to whoever started it, and everyone here assumed they owned it.
  unset TMUX TMUX_PANE
  export TMUX_TMPDIR="$TEST_HOME/tmux"
  mkdir -p "$TMUX_TMPDIR"
  # Keep the suite hermetic: don't let a local-model CLI that happens to be on
  # the dev machine's PATH (apfel/ollama/llm) make `handoff` auto-summarize. Tests
  # that exercise auto-detection re-enable this and stub a summarizer on PATH.
  export CLIKAE_HANDOFF_AUTOLOCAL=0
  # 🔴 No network from the suite. The home board's pre-frame path runs
  # update_check_refresh, which `curl`s the GitHub releases API with a 5s
  # timeout. Nothing here set the opt-out, so any test that renders the board
  # could reach the internet — making the gate slower offline and, worse,
  # dependent on a third party being up. (board-width.bats set it per
  # invocation; pty-smoke set a variable name that does not exist.) One export,
  # once, for every test.
  export CLIKAE_NO_UPDATE_CHECK=1
  RC_FILE="$TEST_HOME/.zshrc"
  # A pty, portably. `script -q /dev/null cmd args` is the BSD form and util-linux
# rejects it outright ("unexpected number of arguments"), which is how this file
# passed on macOS and failed on ubuntu. python3's pty is on both runners and is
# what tests/tools/pty-smoke.py already uses.
_pty_run() {
  python3 - "$@" <<'PYEOF'
import os, pty, fcntl, termios, struct, sys

# 80x24 on purpose: the point of this test is that 200 lines SCROLL OFF the
# visible screen, so the pty must be a normal size. A pty left at its default
# (or 0x0) can swallow the whole run, and then `capture-pane` without -S -
# still finds line 1 — the probe passes whether the fix is there or not.
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
pid = os.fork()
if pid == 0:
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    os.close(master); os.close(slave)
    os.environ["TERM"] = os.environ.get("CK_PTY_TERM") or "xterm-256color"
    os.execvp(sys.argv[1], sys.argv[1:])
os.close(slave)
chunks = []
while True:
    try:
        d = os.read(master, 4096)
    except OSError:
        break
    if not d:
        break
    chunks.append(d)
os.waitpid(pid, 0)
sys.stdout.write(b"".join(chunks).decode(errors="replace"))
PYEOF
}

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
