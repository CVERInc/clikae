# #246 third review: receipts

- `red-on-58fe127.log`: `tests/bats/cockpit-246-r2.bats` with the new and changed tests, run against an archive of 58fe127 (3/12 fail: tests 4, 5, 6; the other 9 are unchanged).
- `jq-probe.log`: each reviewer input classified by `cockpit_scan` inside a marked `Agent` group, on 58fe127 and on the fix.
- `off-outputs.log`: `clikae cockpit --off` output, exit code and resulting file for the reviewer inputs, on 58fe127 and on the fix.
- `green-*.log`: cockpit-246-r2 (12), cockpit-246 (16), cockpit-235 (10), cockpit (57), cockpit-guard (56), run one at a time on the fix (151/151).
- `shellcheck.log`: `shellcheck -S warning` on lib/commands/cockpit.sh and tests/bats/cockpit-246-r2.bats (empty = clean).

Every bats run held the suite lock (flock on the shared lock file) with CLIKAE_SUITE_LOCKED=1.
