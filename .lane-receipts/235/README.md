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
