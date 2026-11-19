# Issue 244 verification receipts

Baseline: `origin/main` and initial HEAD were both
`2194d5229000980083274e262470aa369c6e9634`.

- `red.log`: raw output from `bats --print-output-on-failure tests/bats/burn-knobs-twice-env.bats`, exit 1, before any production-code edit. At that point the new file contained only the first regression test; its lines remain unchanged. The real burn launched the stub and wrote an artifact instead of refusing the duplicate.
- `green-regression.log`: the same command after the resolver fix and five additional tests, exit 0 (6 tests).
- `green-burn-knobs.log`: `bats --print-output-on-failure tests/bats/burn-knobs.bats tests/bats/burn-knobs-argv.bats tests/bats/burn-knobs-twice-env.bats`, exit 0 (125 tests). Both pre-existing files are unchanged from the baseline.
- `shellcheck.log`: `shellcheck -S warning lib/core/burn_knobs.sh tests/bats/burn-knobs-twice-env.bats`; no diagnostics, exit 0.
- `load.log`: `uptime` before the full suite, and any load waiting. Only the full suite waits for load1 to fall to 12 or below, for at most 20 minutes.
- `full-suite.log`: status-only transcript from the single `scripts/test.sh` invocation; test descriptions are omitted to avoid copying unrelated legacy reviewer labels. The unabridged transcript is retained locally and its SHA256 is recorded. The run was interrupted at the work-budget boundary after 2477 completed cases; case 2478 was interrupted in teardown. Its exit code (1) is recorded in `full-suite-exit.txt`; this is not a green full-suite receipt.

Tests use temporary homes and stub task engines. The existing reader contract tests also inspect installed engine help/version declarations. No real task is dispatched.
