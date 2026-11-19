# #246 second review: receipts

- `red-on-994a9a1.log`: `tests/bats/cockpit-246-r2.bats` run against an archive of 994a9a1 (10/10 fail).
- `green-r2.log`: the same file on the fix (10/10 pass).
- `mutations.log`: each fix removed in turn (`mutate.py` M1-M9), running only its test; all 9 fail.
- `cockpit-all.log`: cockpit-246-r2, cockpit-246, cockpit-235, cockpit, cockpit-guard (149/149).
- `neighbours.log`: doctor, runtime-stable, tank-adoption, settings-apply (114/114).
- `shellcheck.log`: `shellcheck -S warning` on lib/commands/cockpit.sh and both 246 bats files (empty = clean).

Every run held the suite lock (flock on the shared lock file) with CLIKAE_SUITE_LOCKED=1.
