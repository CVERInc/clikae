# clikae runtime redesign — locked design + build plan

> **Status:** direction LOCKED with the maintainer (2026-06-02, grill session on
> branch `feat/v0.5.3-i18n-tui`). ✅ **The build plan below is complete** — M1 and
> M2 shipped in the v0.5 line, M3 shipped BETA (`clikae auto`, the board's `A` key,
> claude only at first), and M4's version bump happened many releases ago. Read it for the
> **locked decisions and the reasoning**, not as outstanding work.
>
> **Scope of its SSOT claim:** this file owns *why* the supervising runtime is
> shaped the way it is. It does **not** own the command surface —
> [grammar.md](/grammar.md) does — and where the two ever disagree, grammar.md wins
> and this file is the one that's stale.
>
> The "No phantom features" rule below is **not** historical: it still binds.

## North star

clikae is **the runtime you run all your tanks through**: you set it up once, then
it works quietly in the background and **reports what it did**. CLI-first; the
board is a dashboard you glance at, not a place you live in.

## The integrity rule — NO PHANTOM FEATURES

Every user-facing claim — board copy, README, `--help`, marketing — may only state
capabilities that are **actually wired and verified**. If something can't be done,
say so plainly in the same place a user would expect it. This is a hard
requirement from the maintainer: being served a version that *looks* like it does
X but doesn't forces him to re-litigate and dig old records — never do that.

Concretely, the known honest limits this redesign MUST surface, not hide:
- ~~**Interactive codex cannot be auto-managed.**~~ **Falsified 2026-07-27.** The
  claim was that codex's limit signal lives only in live `codex exec --json` stdout
  and never in a file. It does reach a file: the interactive TUI writes
  `codex_error_info: usage_limit_exceeded` into its own rollout transcript. Kept
  here rather than deleted because it is the sharpest example of what this section
  is FOR — an honest-limit note is only honest while someone keeps checking it, and
  this one was recited for months without anyone opening a rollout after a limit.
  Detectable today: claude (transcript), codex (rollout), agy (log).
- **The same-terminal handoff is a kill+resume, not a seamless continuation.**
  There's one screen redraw ("a flicker"). True in-place continuation needs Claude
  Code itself (issue anthropics/claude-code#35744), which is out of our control.
- **clikae only supervises sessions you launched through clikae.** Nothing runs
  when you haven't opened it — this is deliberate (no always-on daemon = a privacy
  feature), but it means externally-started sessions are unmanaged.

## Locked decisions (the grill, Q1–Q10)

1. **Primary surface = CLI verbs.** Board is a dashboard. North star above.
2. **Autonomy is a user-chosen spectrum** via informed-consent opt-in (safe default
   asks; one explicit, reversible step to full-auto / "SU mode"). Mirrors the
   existing `watch --auto` one-time-consent pattern. See memory
   `feedback-informed-consent-power`.
3. **The homepage IS the burn order.** A single, user-arranged ordered list of
   tanks — NOT grouped by engine. Engine becomes an inline tag. The user reorders
   on the board; that order is the fall-through order.
4. **Cross-engine in the order:** same-engine fall-through is a seamless resume;
   crossing engines is a cold-start brief (lossy). In safe-auto, crossing **pauses
   / notifies**; in full-auto / SU it just does it. Governed by the autonomy level,
   not a separate switch.
5. **`alias` collapses into the tank's NAME.** One identity: the board label, the
   `clikae` argument, and the shell shortcut are the same name (replaces a/b).
6. **Background engine = a supervisor, NOT a daemon.** You launch through clikae; it
   runs the engine as a child and watches the live signal. "Must be opened to run"
   is a deliberate privacy feature. Detection sources: claude=transcript file,
   agy=log file, codex=rollout transcript (and live stdout when headless).
7. **Handoff experience = same terminal, kill+resume in place** (one flicker
   accepted), with a one-line inline report. Interactive-codex excepted (see
   limits).
8. **Autonomy on-ramp = one-time consent** (first burn asks "auto from now on?",
   remembered, reversible) **+ a visible, switchable state on the board.**
9. **Reporting = inline one-liner + a queryable history log** (shown in the board /
   `clikae status`). No desktop notifications; terminal-native.
10. **Naming (scheme B):** names are unique *within an engine* (so claude/work +
    codex/work may coexist). The board shows the bare name (engine as a tag; the
    selected/hover row expands to show engine + disambiguation). A shell shortcut is
    auto-created only when the name is globally unambiguous; on collision use
    `clikae <name>`, which resolves (prompt / most-recent). Use the board's hover
    expansion rather than over-minimising.

### Consequent concept changes
- **`watch` folds into the supervisor** — launching through clikae already watches;
  a separate `watch` command becomes redundant (keep as a hidden alias at most).
- **`pool` is already removed** (v0.5.3 WIP): tanks ARE the reserve; the order is
  the burn order.
- **Re-queueing a DROPPED PARALLEL TASK is a non-goal** (decided 2026-07-27).
  When several tanks burn in parallel and one dries mid-task, nothing re-fires
  *that* task onto a live tank. That is not an unbuilt feature — it is
  architecturally out of reach here, for the same reason the supervisor advances
  only on exit: clikae runs the engine as a CHILD and can act only when the child
  returns. A relay that has to intervene while the process is still running would
  need the engine's cooperation, which is the same wall as decision 7's
  "interactive-codex excepted".

  It is also no longer needed. `clikae resume` reaches back to any past session
  across every tank, so the human decides which tank picks the work up — the
  choice a task↔tank scheduler would have made for them, at the moment they
  actually have the context to make it. The durable version of "a dropped task
  can just re-fire" is the convention already in the playbooks: make the task
  idempotent and verify it by its artifact.

  Building it anyway would mean clikae growing a scheduler that tracks live
  work — a daemon in all but name, against decision 6.
- **`to` / `relay` / `handoff`:** `to` stays the user verb; bare `clikae to` walks
  the burn order to the next tank. relay/handoff stay internal.

## Build plan (milestones, lowest-risk first; each shippable + verifiable)

Each milestone must land green (bats + shellcheck) and have its claims match
reality before the next. Version bumps only when a milestone is real.

### M1 — Names + board as the burn order (NO automation)
- Collapse alias → name (scheme B): `init <engine> <name>`; auto shell shortcut
  when globally unique; `clikae <name>` resolver with collision handling; `rename`
  already moves dir+shortcut+login.
- Board → flat, user-ordered list; engine as inline tag; hover/selected expands.
  Reorder keys (move up/down) persisted to `$CLIKAE_HOME/order` (or similar).
- `next_tank` follows the user order (cross-engine aware), replacing same-engine
  only. Bare `clikae to` already calls `next_tank` → now walks the order.
  **v0.5.8:** `next_tank` became a RING — it wraps past the end of the order (a
  tank earlier in your order is still a reserve), prefers a fuelled **same-engine**
  tank (real resume) over a cross-engine cold brief, and judges "dry" with
  `limit_tank_dry` (account-aware: a sibling on the same exhausted login is
  skipped; a persisted `dry_store` marker covers exec-only limits like codex).
  Returns nothing when the whole ring is dry, so callers say so honestly.
- Honesty: still no "auto" claims anywhere.

### M2 — Report log (SHIPPED)
- Switch-history log (`$CLIKAE_HOME/history`): `history_log`/`history_recent`.
  `clikae to` + the board's `r` log real carries; `clikae status` shows a "recent
  carries" tail. Only user-initiated carries today; the supervisor's auto-switch
  logging arrives with M3.
- NOTE (no-phantom refinement): the **autonomy state/toggle moved to M3**. A
  toggle that says "full-auto" while nothing auto-switches would be a phantom, so
  the autonomy control ships together with its consumer (the supervisor).

### M3 — The supervisor runtime + autonomy (the headline) — IMPLEMENTED (BETA)
Shipped behind a BETA label (`clikae auto`; board `A`; one hop per run). Covered
claude only until 2026-07-27, when codex's limit turned out to be readable from its
rollout after all; agy stays out (one global login, no per-tank signal). Stub tests cover the decision gate + dry-advance; real interactive
kill+resume still wants real-claude dogfooding (docs say "beta, feedback welcome").
Original spec below.

- `clikae <name>` runs the engine as a foreground CHILD inside a loop (not exec);
  a background watcher tails the right signal (claude transcript / agy log /
  headless-codex stdout); on dry it flags + SIGTERMs the child, the loop sees the
  flag and, per autonomy level, relays/resumes onto the next tank in the order in
  the SAME terminal (the "flicker"), logs it, prints the inline report. No-dry =
  behaves exactly like today's exec.
- Autonomy level (ask | safe-auto | full-auto): one-time consent on first burn +
  a board toggle + `clikae auto`. Cross-engine: pause in safe-auto, proceed in
  full-auto. Surfaces every honest limit above (esp. interactive codex).
- **Verification gate (no-phantom):** stub tests cover the loop MACHINERY, but the
  real kill+resume on an interactive engine can only be confirmed by dogfooding on
  real claude. M3 is NOT "done" / claimed working on real engines / version-bumped
  until that dogfood passes. Best built with the maintainer's real engine in the
  loop, not blind.

### M4 — Honesty + docs pass, then version bump
- README / board / `--help` / CHANGELOG updated to match EXACTLY what M1–M3 do,
  with the limits stated. Only now bump CLIKAE_VERSION.

## Open refinements (not blockers, decide during build)
- Board reorder key bindings + the exact order-file format.
- Collision UX wording in the hover-expanded row.
- Whether `watch` is removed outright or kept as a hidden alias.
