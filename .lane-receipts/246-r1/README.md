# PR 246 review-fix receipts

Baseline: `d6b76c18ab1a0abf97dc98c8e82bcced021e95d9`.
All new regression fixtures drive the real CLI through the shared throwaway-HOME helper.

| Receipt | Result |
| --- | --- |
| `red.log` | Nine selected regressions fail behaviorally on the baseline CLI (rc 1). |
| `cockpit.log` | Initial cockpit files: 137 passed (rc 0). |
| `green-regressions.log` | Fifteen regressions plus five assertion-linter cases pass (rc 0). |
| `continuation-red.log` | New continuation case fails on the intermediate parser, before its final correction (rc 1). |
| `final-regressions.log` | All sixteen new regressions pass on final code (rc 0). |
| `shellcheck.log` | Final touched-file ShellCheck, severity warning: no diagnostics (rc 0). |
| `assertion-lint.log` | Final standalone assertion linter: no diagnostics (rc 0). |
| `full-suite.log`, `full-suite.exit` | Incomplete: terminated for the time budget after case 2480/2708, no failures reported, 30 skips, rc 143. PTY smoke was not reached. |
| `full-suite-interrupted.log` | Earlier partial invocation stopped after case 265 to fix and stage assertions before the tracked-file linter. |
| `full-suite-interrupted-shape.log` | Second partial invocation stopped after case 705 to add the array-shape ownership check. |
| `final-cockpit-blocked.log` | Broad final rerun was refused: another worktree held the shared suite lock. Not a passing result. |
| `load-check.log` | Load was below the 16-CPU count at each invocation; no load wait was required. |

The full run passed all 138 cockpit cases before the final continuation correction.
The final regression file was run with the documented `CLIKAE_ALLOW_CONCURRENT_SUITE=1`
exception: these sixteen tests only manipulate isolated settings/state fixtures and
do not inspect the shared process table. The broad cockpit suite was not run concurrently.

Commands: `bats --print-output-on-failure tests/bats/cockpit*.bats`,
`bats --print-output-on-failure tests/bats/cockpit-246.bats tests/bats/bats-dbracket-lint.bats`,
`shellcheck -S warning lib/commands/cockpit.sh tests/bats/cockpit-235.bats tests/bats/cockpit-246.bats`,
and `scripts/test.sh`. The final isolated run used only `tests/bats/cockpit-246.bats`.

For the baseline RED run, extract `git archive d6b76c1` to a temporary directory,
copy the new test file into its `tests/bats/`, and select the argument_only,
different_matcher, mixed_group, nested_quotes, split_quotes, trailing_space,
malformed-and-malformed_escaped, install-and-repair, and entry-shape tests.
The continuation RED receipt instead uses an intermediate copy of the new parser,
which is explicitly not the d6b76c1 baseline.

No completed full-gate pass is claimed. The uncommitted lane report contains the
ownership predicate verbatim, historical installer forms, output lines and PR text.
