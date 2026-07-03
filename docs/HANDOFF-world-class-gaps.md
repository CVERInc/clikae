# HANDOFF — world-class gaps

> ✅ **HISTORICAL — punch-list fully cleared** (P1s in v0.5.9, P2 in v0.5.12). This file
> is kept as a record of the 2026-06-05 quality audit; there is **nothing left to do
> here**. For live project state see `CHANGELOG.md` — do not read this as an open list.

Focused continuation handoff for a fresh agent. Scope: the remaining gaps found in
the adversarial quality audit of **2026-06-05** (CVER world-class standard, 7-dim
quality ruler). Read `HANDOFF.md` first for the project itself; this file only
covers what's left to make clikae pass the bar.

## Before you touch anything

- **`git fetch origin` and work off `origin/main` first.** This repo lives on an
  iCloud-synced Desktop; the local working tree goes stale. The first audit agent
  read a tree 3 commits behind (v0.5.7) and *false-reported two P0s that were
  already fixed*. Don't repeat that — verify against `origin/main`.
- Audited version: **0.5.8** (Homebrew install == `origin/main`, byte-identical).
- Baseline to keep green: `bats -r tests` = **327/327** (was 309; +18 in v0.5.9),
  `shellcheck -S warning` on bin+lib+install = **0 warnings**. Any change here must
  keep both green and add tests for the new behaviour.

## Already verified — do NOT re-investigate

- **`burn` "burnout" — codex-side isolation is solid; the claude-side reroute was FIXED
  in v0.5.10 (don't re-clear it the old way).** The 2026-06-05 log first declared the
  whole burnout P0 fixed after testing **codex only** — a false clear. The codex case is
  genuinely safe (env export sandboxed in a `$(...)` subshell; codex adapter exports
  only `CODEX_HOME`, zero claude vars). BUT `burn **claude**`'s same-engine reserve
  includes the tank an interactive session is on, so it could reroute a headless job
  onto your live conversation's quota (the original 2026-06-04 dogfood P0 + the
  same-account P1 — both code-confirmed still-live until v0.5.10). **v0.5.10 fix:**
  `_burn_next_same_engine` skips a tank `live_dir_users` reports as in interactive use
  (`--allow-active` overrides) and skips same-account dried siblings; tested in
  `tests/bats/burn.bats`. All-dry exit stays graceful (exit 1). Lesson logged: don't
  clear a multi-engine bug by testing one engine.
- Homebrew formula v0.5.8 `sha256` (`cf360a8…`) verified against the real GitHub
  tarball; `v0.5.8` git tag exists. Delivery (dim ⑦) is otherwise green.

## What's left (the actual punch-list)

### ✅ P1 — `--timeout` silently degrades to a no-op on stock macOS — DONE (v0.5.9)
- The flag help now discloses the dependency ("NEEDS `timeout`/`gtimeout` … stock
  macOS has neither, so WITHOUT it the run is NOT bounded and a warning is printed").
- The tool selection is factored into `_burn_timeout_bin` (`lib/commands/burn.sh`),
  unit-tested both ways in `tests/bats/burn.bats` (picks `timeout` when present;
  warns + runs unbounded when absent). The optional in-script wall-clock fallback
  was deliberately NOT added — disclosure is the world-class-correct minimum
  (don't promise a bound the platform can't keep); a half-baked fallback is worse.

### ✅ P1 — `clikae to` multi-engine ambiguity rejection had no regression test — DONE (v0.5.9)
- `tests/bats/to.bats` now pins it: a shell on >1 engine ⇒ `clikae to` exits
  non-zero with the disambiguation message listing both candidates, and does NOT
  switch. The historical "burned the wrong account" neighbourhood is now guarded.

### ✅ P2 — state files have no schema version / migration — DONE (v0.5.12)

> **Resolved.** `lib/core/state_version.sh`: a `$CLIKAE_HOME/version` integer
> (`CLIKAE_STATE_VERSION`, the STATE schema version — bumped only on a format change,
> not per release) + a forward-migration runner (`state_version_check` on startup;
> `_state_migrate_<n>` hooks run n→n+1). Stamped when state is created
> (`ensure_profile --create` → `state_version_ensure`), so read commands stay
> read-only (the "bare clikae changes nothing on disk" guarantee holds — verified by
> test). A missing version file = the original un-versioned layout = v1 (migrates
> cleanly to a future v2). A newer-than-binary version warns instead of downgrading.
> Tests in `tests/bats/state-version.bats`. Kept minimalist — one file + one runner, no
> framework. **clikae now clears the world-class bar** (the original writeup follows).

### (original) P2 — state files have no schema version / migration (dim ⑤, portfolio-wide weak)
- **Where:** everything under `$CLIKAE_HOME/` — `profiles/`, `order`, `dry/<engine>/<tank>`
  (`lib/core/dry_store.sh:38`, format `<epoch>\t<phrase>`), `autonomy`,
  `auto-relay-consent`, `cache/weekly/`. All are bare files with no version marker.
- **Why it fails the bar:** the moment any of these formats needs a new field there
  is no way to tell old from new, and no migration path. This is the systemic weak
  dimension across the whole CVER portfolio (see the vault audit) — clikae is no
  exception.
- **DoD (first brick is enough to start):**
  1. Write a `$CLIKAE_HOME/version` file and read it on startup.
  2. A migration hook that runs when the on-disk version is older than the binary.
  3. Reserve a version prefix in the `dry_store` line format so it can evolve.
  - Keep it minimalist: don't over-engineer a migration framework; one version file + one
    hook is the world-class-correct minimum.

## Reference

- Full audit + 7-dim scorecard + reusable self-check method:
  Obsidian vault → `Notes/world-class-self-check-bleedblend-clikae.md`
  and the standard itself → `Notes/world-class-CVER-quality-standards.md`.
- clikae's strongest dims today are ⑥ restraint and ② root-cause; the weak ones WERE
  ⑤ (state versioning) and the P1 test-coverage gaps. **All cleared: the two P1s in
  v0.5.9, P2 in v0.5.12. The punch-list is empty — clikae clears the world-class bar.**
  (A separate "implementation vs expectation" audit on 2026-06-05 also fixed a
  shipped `clikae watch` crash + doc drift in v0.5.11; see that CHANGELOG.)

— left by Claude a, 2026-06-05. P1s closed v0.5.9; expectation audit v0.5.11; P2 closed v0.5.12.
