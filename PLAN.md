# PLAN — clikae outstanding work (consolidated 2026-06-03)

> **STATUS 2026-06-05 — SHIPPED.** Phases 0–4c below all landed and shipped in the
> v0.5.x line (merged to `main`, tagged through **v0.5.9**). The "no version bump /
> no merge" notes below were true on the working branch at the time; they no longer
> describe HEAD. The live punch-list is now `docs/HANDOFF-world-class-gaps.md`
> (P2 = state schema versioning; Phase 4c's task↔tank scheduler is still
> design-first/deferred). Kept for the per-phase evidence and rationale.


One plan covering every open TODO: the bugs found this session, the dogfood
frictions recorded in `HANDOFF.md` (§11, §12, and the 2026-06-03 burn writeups),
and the still-open roadmap items. Read `HANDOFF.md` §1 (non-negotiables) and
`docs/grammar.md` (command-surface SSOT) before touching anything.

## Execution status — 2026-06-04 (branch `feat/agy-multiaccount-codex-continuity-guards`, pushed)
- ✅ **Phase 0** — status adapter-less crash fixed (+ `global` row).
- ✅ **Phase 1** — agy real multi-account: per-tank Keychain carry (1a, SU-consent
  disclosed), helpful `env agy` error (1b), active-tank label in `tanks` (1c).
- ✅ **Phase 2** — `proc.sh` cross-shell in-use guard wired into rename/migrate/remove.
- ✅ **Phase 3** — codex sessions surface in the board's Continue list.
- ✅ **Phase 4a** — codex dry-detect from plain exec output + reset-time parse.
- ✅ **Phase 4b** — `watch codex` made honest (limit isn't in the transcript).
- ✅ **Phase 4c** — `clikae burn` (provisional name): headless guarded task runner.
  Resolved the `pool`-removal conflict by NOT building a scheduler/pool verb —
  instead a single-task unit that verifies by artifact + limit-string (not exit
  code) and falls through THIS engine's reserve tanks on dry (`--to` overrides).
  Batch/parallelism stays the orchestrator's job. Discoverable in help. **Name
  `burn` is provisional** — grammar.md/usage.md entries deferred until the
  maintainer confirms or renames the verb.

Full suite **290/290 green**, shellcheck clean at warning level. All phases (0–4c)
shipped + pushed on `feat/agy-multiaccount-codex-continuity-guards` (no PR, no
merge to main, no version bump).

## Ship rules for this plan
- **Commit incrementally, one logical fix per commit.** Conventional-commit
  prefixes (`fix(...)`, `feat(...)`, `docs(...)`).
- **Do NOT bump `CLIKAE_VERSION` or move CHANGELOG `[Unreleased]` → a release
  section.** No version piling. A release is a separate, explicit decision.
- **bats must stay green** (`bats -r tests/bats`) and **shellcheck clean at
  warning** on every commit. Add tests with every behaviour change.
- bash 3.2 + BSD-safe (no `readlink -f`, no GNU sed-isms, quote everything).
- Honour HANDOFF §1: check-then-act, back up user files, never log in for the
  user, never touch system files, stop-and-report on anomaly.

## Execution model (how to actually run this)
- **Use every tank's model via clikae.** Route grunt/parallelizable work to a
  cheaper tank: `eval "$(clikae env codex <tank>)"; codex exec -C <dir> -s
  workspace-write --skip-git-repo-check "<task>" </dev/null`, or
  `cat in | agy -p "<task>"` (agy stdin-only — no tool-permission gate). Set the
  tank **inline in the same command** (per-shell `$CODEX_HOME` doesn't persist).
- **Claude dispatches many shells.** Independent tasks below are marked
  `∥ parallel-safe` — fan them out across shells/tanks; the orchestrator reviews
  and lands the diffs.
- **Never hand a tank slow iCloud-backed I/O** (codex `exec` hangs on it, can't
  self-abort in headless, burns tokens). Pre-stage inputs to `/tmp`. Bound long
  jobs with an in-script `timeout`.
- **Verify by artifact, not exit code** — `codex exec` exits 0 even when it hit
  its usage limit and wrote nothing.

---

# Phase 0 — DONE this session
- ✅ **`clikae status` adapter-less crash** (commit `a96d87b`). `status` no longer
  exit-1's when an agy tank exists; agy renders as a new `global` state showing
  its `~/.gemini` symlink target. +3 regression tests. Branch
  `fix/status-crash-adapterless-engine` (off `docs/codex-dispatch-dogfood`).

---

# Phase 1 — agy is the headline gap: multi-account is HALF-BUILT  ⭐ TOP PRIORITY
**Evidence (confirmed this session):** agy "tanks" swap the whole `~/.gemini` dir
via symlink, but Antigravity's Google login is a **single shared macOS Keychain
item** — proven: `security find-generic-password -s gemini` → one generic-password
`svce="gemini" acct="antigravity"`. The tank dirs contain **zero credential
files**. So switching agy tank changes settings/history but **NOT the Google
account** — every tank rides the one keychain login. "2 agy tanks = 2 accounts"
is currently false. The maintainer's own tank-8 history shows them hitting this
wall. This is the single most important correctness gap to close.

### 1a. Per-tank Keychain carry on `clikae agy <tank>`  (the real fix)
Make the symlink swap also swap the credential, so each agy tank can hold a
distinct Google account.
- New optional hook concept (agy is special-cased, not an adapter): on switch,
  **stash the outgoing tank's credential** and **restore the incoming tank's**.
  Store each tank's copy inside the tank dir as an opaque blob (NOT world-readable;
  `chmod 600`), e.g. `<tank>/.clikae/agy-credential`, written via
  `security find-generic-password -s gemini -w` (password value) + the account
  attr; restore with `security add-generic-password -U -s gemini -a antigravity -w <val>`.
- Precedent to reuse: `lib/adapters/claude.sh:adapter_migrate_credentials`
  (the `--keep-login` Keychain copy) already does keychain read/write safely —
  mirror its `security` usage and its "token never leaves the Keychain in
  plaintext on disk if avoidable" care. **Decision needed (ask maintainer):**
  storing the token blob inside the tank dir is the only way to swap it offline —
  acceptable, or require re-login per tank? Document the trade-off; gate behind
  the existing agy multi-account consent.
- Guard: refuse the swap if an `antigravity` process is live (`_agy_assert_not_running`
  already exists) — swapping the keychain under a running agy corrupts its session.
- Honest limit to document: if a tank's stored token has expired, restoring it
  still requires a re-login — surface that clearly rather than silently failing.
- Tests: stub `security` the way `tests/bats/migrate.bats` already does for the
  claude keychain path; assert switch saves outgoing + restores incoming.
- Files: `lib/commands/antigravity.sh`, `tests/bats/antigravity.bats`,
  `docs/grammar.md` §6, `docs/usage.md`, `docs/troubleshooting.md`.

### 1b. Resolve the `clikae env agy` inconsistency  (HANDOFF dogfood #3)
`clikae env agy <tank>` errors "No built-in adapter for 'agy'", yet `clikae tanks`
lists agy tanks — misleading. agy is global/symlink, not per-shell env.
- Make `clikae env agy [<tank>]` **fail with a helpful message** that points to
  `clikae agy <tank>` (machine-wide switch) instead of the generic adapter error
  — agy genuinely has no per-shell env var to emit. (Same root class as the
  Phase-0 status crash: adapter-less engine on a generic code path.)
- Audit every generic command path for the same adapter-less footgun
  (`grep -rn 'load_adapter' lib/`): `env`, `to`, `relay`, `app`, `alias`,
  `watch`, `handoff` — confirm each either special-cases agy or fails cleanly,
  never crashes. `∥ parallel-safe` (read-only audit → one fix commit).
- Files: `lib/commands/env.sh` (+ any path that crashes), tests.

### 1c. Show the agy account label in `tanks`/`status`
Today agy account shows `-` (clikae reads `antigravity-cli/log`'s `email=`, which
doesn't exist). After 1a, capture the account email at switch/login time and store
it per tank (e.g. `<tank>/.clikae/agy-account`), then surface it in the ACCOUNT
column. Files: `lib/commands/antigravity.sh`, `lib/commands/list.sh`,
`lib/commands/status.sh`.

---

# Phase 2 — phantom-tank bug: in-use guard only sees the current shell  (HANDOFF §11)
**Evidence:** renaming claude `b`→`L`/`a`→`C` left phantom `a`/`b` tanks that kept
reappearing — `rename`/`migrate`/`remove` only check the *running shell's* env var,
not a live interactive session or daemon/spares in another terminal holding
`CLAUDE_CONFIG_DIR=<old>`.
- New `lib/core/proc.sh::live_dir_users <dir> <envvar>` — scan same-uid procs for
  `<envvar>=<dir>`. macOS: `ps eww -o pid=,command=` then read env per pid; Linux:
  `/proc/<pid>/environ` (NUL-split). Pure ps/grep, bash 3.2, BSD-safe. (Detection
  already proven: `ps eww -p <pid> | tr ' ' '\n' | grep CLAUDE_CONFIG_DIR=`.)
- Wire into `cmd_rename`, `migrate`, `remove`: after the current-shell check, scan
  all procs for `<old_dir>`. **Classify by command string:** interactive TUI
  holding `=old` → **hard-fail** (not `--force`-bypassable); only `daemon run` /
  `--bg-spare` / `--bg-pty-host` → **soft warn** ("quit Claude Code fully first").
- agy exception: `_agy_rename`/agy `remove` refuse if any `antigravity` process is
  running (no per-tank env var to scan).
- Tests: stub `ps` the way helpers already stub `pgrep`.
- Honest limit (don't oversell): catches "open right now", not a check-then-open
  race; TUI-vs-daemon is a command-string heuristic.
- Files: new `lib/core/proc.sh`, `lib/commands/{rename,migrate,remove}.sh`,
  `lib/commands/antigravity.sh`, `tests/bats/{rename,migrate,remove}.bats`.
- `∥ parallel-safe` once `proc.sh` lands (the three call-sites are independent).

---

# Phase 3 — cross-engine continuity: board "Continue" is claude-only  (HANDOFF §12)
**Evidence:** a codex session run through a clikae codex tank shows on the board
only as a *tank*, never in **續上次/Continue** — even from its own `cwd`. clikae's
stated differentiator is cross-**engine** continuity; today it's claude-deep.
- Give `lib/adapters/codex.sh` an `adapter_transcript_path <dir>` → most recent
  `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl` whose recorded **`cwd` field**
  matches `<dir>` (codex does NOT slug `$PWD` like claude — match on cwd).
- A recap extractor for codex rollouts (fall back to "<age> ago" when none) so
  Continue rows render like claude's.
- Then the existing cross-engine board code lists codex sessions for free.
- agy stays launch-only (opaque `.pb` state — no transcript to resume).
- Files: `lib/adapters/codex.sh`, board/home code in `lib/commands/home.sh`,
  `tests/bats/{home,adapters}.bats`.

---

# Phase 4 — codex fuel axis + dropped-parallel-task relay  (2026-06-03 burn writeup)
**Evidence:** in a deliberate "全油箱同步燒", codex tank M ran dry mid-task —
`codex exec` **exited 0** but wrote no artifact; the limit only showed as
`You've hit your usage limit ... try again at <date> <time>` in its output. A
manual relay (orchestrator re-ran M's task on a live tank) saved the work.

### 4a. codex dry-detect (the long-open fuel TODO)
- Detect the literal `You've hit your usage limit` in codex stdout/stderr **and/or
  a missing expected artifact** — never trust the exit code.
- Parse the reset time (`try again at <date> <time>`) → mark the tank
  **dry-until-<timestamp>** so `watch`/pool don't re-pick it before it recovers.
- Wire into `lib/core/limit.sh` (the limit-marker registry) + `lib/adapters/codex.sh`.
- Tests: feed a synthetic limit string + a synthetic clean run (regression like the
  existing "ignores a session that only DISCUSSES a limit" watch test).

### 4b. extend `clikae auto`/`watch` to codex  (depends on 4a)
`clikae auto` is claude-only (BETA). With 4a, codex can self-relay on dry. Files:
`lib/commands/{auto,watch}.sh`, `lib/core/autonomy.sh`, tests.

### 4c. auto-relay of a *dropped parallel headless task* (pool/scheduler — design first)
Today `clikae to`/`relay` carries a *session*; the burn needed re-routing a
*headless task* (M→H or cross-engine). Needs a task↔tank map, not just "switch the
shell's tank". **Write a short design note in `docs/` first**, get a maintainer
greenlight, then build. Encourage **idempotent, artifact-checked** grunt tasks
(fixed input/output paths) so a dropped task just re-fires elsewhere.

### 4d. headless-grunt robustness (docs + optional guard)
Document/encode: pre-stage inputs to `/tmp` (never hand codex iCloud reads); bound
long headless jobs with an in-script `timeout`; agy is a fine cheap summarizer via
stdin only. Consider a thin `clikae`-side timeout wrapper for dispatched headless
jobs. Files: `docs/usage.md`, maybe a small dispatch helper.

---

# Phase 5 — lower priority / deferred (ask before spending effort)
- **`remove agy <active-tank>` auto-switch (was GH #23, closed 2026-06-24).** Today
  `clikae remove agy <active-tank>` refuses and names a concrete sibling to switch to
  first. UX option: auto-switch the global `~/.gemini` symlink + Keychain to a
  remaining tank, then remove. Tradeoff: removing the active tank becomes a *global*
  side-effect (every terminal's agy account changes) — that's why the safe default is
  to refuse. Deferred, debatable; the refuse-and-name default is reasonable as-is.
- **agy same-account parallel worker fan-out (was GH #25, closed 2026-06-24).** Full
  writeup already in `docs/proposals/issue-25-agy-parallel.md`: same-account agy
  workers each with their own `$HOME` run concurrently (verified), trading speed not
  quota; multi-account-multiplied parallelism stays out (ToS-gray for shipped OSS).
- **`clikae app` Warp target** + terminal auto-detect (HANDOFF §9.1). iTerm2 path
  needs partner dogfood (no iTerm2 on the maintainer's Mac).
- **v1.0 SwiftUI menu-bar GUI** runtime dogfood + signed `LSUIElement` `.app`
  packaging, login-item toggle, per-CLI terminal preference (`gui/ClikaeMenuBar/`).
- **Windows / PowerShell follow-ups — DEPRIORITIZED.** HANDOFF: Windows is
  community/unsupported, its CI is `continue-on-error` and never gates. Do **not**
  spend effort syncing PS to the grammar (`.psd1`, PSGallery, PS `migrate`, mirror
  watch/pool) unless the maintainer asks.

---

# Suggested order & parallelism
1. **Phase 1** (agy account story) — headline correctness; do first. 1a is the
   meat; 1b/1c are quick and `∥` with each other.
2. **Phases 2, 3, 4a** are mutually independent → fan out across tanks/shells in
   parallel. Phase 2 needs `proc.sh` to land before its 3 call-sites parallelize.
3. **4b** after 4a; **4c** after a design note + greenlight.
4. **Phase 5** only on maintainer request.

Branching: keep landing on focused `fix/*` and `feat/*` branches off
`docs/codex-dispatch-dogfood` (which carries the latest HANDOFF + dogfood notes);
merge to `main` is a release-time decision (no version bumps until then).
