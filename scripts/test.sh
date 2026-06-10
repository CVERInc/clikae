#!/usr/bin/env bash
# Single entry point — the gating checks GitHub Actions runs (shellcheck + bats).
# The CI also runs a macOS/Linux smoke matrix and an informational Windows Pester
# job; those stay server-side. shellcheck severity=warning matches the CI action.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ shellcheck (severity=warning)"
shellcheck -S warning bin/clikae install.sh
find lib tests -name '*.sh' -print0 | xargs -0 shellcheck -S warning
echo "→ bats"
bats -r --print-output-on-failure tests/bats
echo "✅ ALL GREEN"
