#!/usr/bin/env bash
# Single entry point — the gating checks GitHub Actions runs (shellcheck + bats
# + pty smoke). The CI also runs a macOS/Linux smoke matrix and an informational
# Windows Pester job; those stay server-side. shellcheck severity=warning
# matches the CI action.
set -euo pipefail
cd "$(dirname "$0")/.."

# 🔴 ONE SUITE AT A TIME ON THIS MACHINE.
#
# Some tests read the REAL process table: clean's live guard runs
# `ps -axo command=` so it can never offer a session a process still has open.
# Two copies of this suite therefore share a ruler that the other one moves —
# suite A's `clikae` processes appear in suite B's snapshot, the fixtures use
# fixed session ids, and B decides those sessions are live and skips the rows
# the test is asserting on.
#
# That is not hypothetical, and it is not rare. The pre-commit hook runs this
# suite and so does pre-push, so `git commit && git push` overlaps them by
# construction. Reproduced 2026-08-16 by starting a second run 25s into the
# first: round 2 of 6 turned BOTH runs red, four clean.bats failures in one and
# two in the other, every one of them `[ "$status" -eq 0 ]` on a `clikae clean`.
# It is also the best explanation for a single unexplained pre-push red four
# days of investigation could not otherwise reproduce in ~218 isolated runs.
#
# So: wait for the other run rather than racing it, and say what is happening.
# A test suite that is red for a reason outside the code teaches you to ignore
# red, which is the one thing a gate cannot afford.
# 🔴 The re-exec below re-enters this script, so it MUST be told not to lock
# again — the first draft had no such marker and would have recursed until the
# process table said no.
if [ "${1:-}" = "--locked" ]; then
  shift
else
_TEST_LOCK="${TMPDIR:-/tmp}/clikae-test-suite.lock"
if command -v lockf >/dev/null 2>&1; then
  # -k: hold the lock for the whole command. Without it two processes both get 0.
  if ! lockf -k -t 0 "$_TEST_LOCK" true 2>/dev/null; then
    echo "→ another clikae test suite is running on this machine; waiting for it"
    echo "  (they share the real process table — see the note in scripts/test.sh)"
  fi
  exec lockf -k -t 900 "$_TEST_LOCK" "$0" --locked "$@"
elif command -v flock >/dev/null 2>&1; then
  if ! flock -n "$_TEST_LOCK" true 2>/dev/null; then
    echo "→ another clikae test suite is running on this machine; waiting for it"
  fi
  exec flock -w 900 "$_TEST_LOCK" "$0" --locked "$@"
fi
fi

echo "→ shellcheck (severity=warning)"
# NB: this script lints ITSELF too. It did not until 2026-07-27, and the gap was
# not theoretical: a prose comment here that happened to begin with the word
# "shellcheck" was parsed as a directive (SC1072/SC1073) and broke CI for two
# releases, while every local run stayed green — because the only file the gate
# never checked was the gate. CI scans the whole tree; make the local run match.
shellcheck -S warning bin/clikae install.sh "$0"
find lib tests scripts -name '*.sh' -print0 | xargs -0 shellcheck -S warning

echo "→ doc names (every function a doc names must exist)"
bash "$(dirname "$0")/doc-names-exist.sh"

echo "→ bats"
bats -r --print-output-on-failure tests/bats

# The third leg exists because the first two are structurally blind to the TUI:
# ShellCheck reads source, bats never presses a key. Every board regression of
# the last year lived in that gap — most expensively the `exec … 2>/dev/null`
# family, which discarded the board's stderr (invisible prompts, muted errors,
# and a dead stderr handed to the launched engine) while this gate stayed green.
# pty-smoke drives the real binary on a real pty in a throwaway $HOME.
echo "→ pty smoke (interactive screens — the layer bats cannot reach)"
if command -v python3 >/dev/null 2>&1; then
  python3 tests/tools/pty-smoke.py all
else
  # Loud, never silent: a skipped leg that says nothing reads as a passed one.
  echo "   ⚠️  SKIPPED — python3 not found."
  echo "   ⚠️  The board / resume / prompt key loops were NOT exercised."
fi

echo "✅ ALL GREEN"

# Stamp what just passed, so a push of the SAME content does not re-run 7 minutes
# of suite to reach the same answer. hooks/pre-push reads this.
#
# Only when the working tree is CLEAN. A dirty tree means the suite exercised
# content that is not what a push would send, so the stamp would be a claim about
# something nobody tested — the one way this could weaken the gate rather than
# just speed it up.
if git rev-parse --git-dir >/dev/null 2>&1 && [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  _gd="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
  _tree="$(git rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
  if [ -n "$_gd" ] && [ -n "$_tree" ]; then
    printf '%s %s\n' "$_tree" "$(date +%s)" > "$_gd/clikae-gate-pass" 2>/dev/null || true
  fi
fi
