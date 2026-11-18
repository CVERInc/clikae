# Issue 235 test receipts

Baseline: `origin/main` at `2194d5229000980083274e262470aa369c6e9634`.

`red.tap` records the two behavioral reproductions against unchanged baseline
production code. The first drives `clikae cockpit --off` with four unmarked
legacy guards across three synthetic tanks. The second drives `clikae burn`
from a different tank than the recorded cockpit and expects a mismatch warning.

Command (the lock serializes tests with other local suites):

```sh
flock -w 900 /tmp/clikae-test-suite.lock env CLIKAE_SUITE_LOCKED=1 \
  bats --tap tests/bats/cockpit-235.bats
```

`red-lock-blocked.tap` is the initial attempt refused by the shared suite lock;
it is not evidence that either regression test failed.

Green verification:

- `green-reproductions.tap`: the original two reproductions after the fix.
- `green-regressions.tap`: nine regression tests; includes the Bats minimum-version
  warning subsequently corrected in the test harness.
- `green-targeted.tap`: 399 passing tests across `cockpit-235.bats`, `cockpit.bats`,
  `cockpit-guard.bats`, `burn.bats`, and `settings-apply.bats`, in that order.
- `green-final-cockpit.tap`: 67 passing tests in `cockpit-235.bats` and
  `cockpit.bats`, after adding unreadable-settings coverage and finishing the
  test harness. All existing test files are unchanged.
- `shellcheck-before-test-fix.log`: the initial warning for Bats' `stderr`
  variable, before explicitly initializing it in the test.
- `shellcheck.log`: final `shellcheck -S warning` over `lib/commands/cockpit.sh`,
  `lib/commands/burn.sh`, and `tests/bats/cockpit-235.bats`.

The targeted Bats runs used the same suite lock as the baseline run. Every
fixture uses the existing throwaway HOME/CLIKAE_HOME test harness. Engine calls
in the new burn tests are stubbed.
