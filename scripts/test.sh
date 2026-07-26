#!/usr/bin/env bash
# Single entry point — the gating checks GitHub Actions runs (shellcheck + bats
# + pty smoke). The CI also runs a macOS/Linux smoke matrix and an informational
# Windows Pester job; those stay server-side. shellcheck severity=warning
# matches the CI action.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ shellcheck (severity=warning)"
shellcheck -S warning bin/clikae install.sh
find lib tests -name '*.sh' -print0 | xargs -0 shellcheck -S warning

echo "→ bats"
bats -r --print-output-on-failure tests/bats

# The third leg exists because the first two are structurally blind to the TUI:
# shellcheck reads source, bats never presses a key. Every board regression of
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
