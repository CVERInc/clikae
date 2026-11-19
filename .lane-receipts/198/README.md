# Issue 198 receipts

Baseline: `origin/main` at `84cfd47c6871f12051c0faa7c0860a1df73e54b9`.
PR search found merged PR 200; no additional matching PR was found. Usage-related
remote branches were checked before implementation.

- `red-origin-main.log`: initial 12 behavioral tests against the unchanged
  baseline: 6 pass, 6 fail; exit 1.
- `red-expanded-origin-main.log`: final 16 tests against an immutable
  `git archive` export of the same baseline: 7 pass, 9 fail; exit 1. Only the
  new test file and its fixtures were copied into that export.
- `green-regression.log`: the same final tests against the fix: 16 pass; exit 0.
- `shellcheck.log`: warning-level ShellCheck on all touched shell/test files.
- `output-examples.log`: literal output from isolated command/function calls,
  covering changed JSON shapes and the three added help lines.

The behavioral command was:

```sh
bats --print-output-on-failure tests/bats/usage-contract-198.bats
```

Every test uses the repository's throwaway HOME and CLIKAE_HOME setup. Live
app-server responses are stubbed; no vendor call or model prompt is made.
Fixture provenance is documented in `tests/fixtures/usage-codex/README.md`.
The top-level fixtures are reconstructed. `captured/` holds real token_count
events (captured 2026-11-19, sanitized to rate-limit fields only) for a
two-window plus plan, weekly-only prolite and team plans, and a live
zero-length-window event. No vendor `/status` text was recorded alongside them.

- `red-captured-origin-main.log`: the five captured-fixture tests against the
  baseline export: 4 pass, 1 fails (the zero-length window); exit 1.
- `green-contract.log`: all 21 contract tests against the fix; exit 0.
- `full-suite.log`: summary of the full `scripts/test.sh` run (shellcheck, doc
  names, 2710 bats tests with 0 failures and 30 skips, 43 pty smoke checks):
  exit 0. It is a count summary plus this issue's test lines; the raw log
  repeats every existing test name and is not committed.
- `load-full-suite.log`: load1 samples taken before the full suite started.
