# clikae runtime redesign — locked design + build plan

> **Status:** direction LOCKED with the maintainer (2026-06-02, grill session on
> branch `feat/v0.5.3-i18n-tui`). This file is the **single source of truth** for
> the "clikae as a supervising runtime" redesign. Read it before touching the
> command surface, the board, or the launch path.
>
> **Version is intentionally NOT bumped while this is in flight.** Bump only when a
> milestone is actually implemented AND verified — see "No phantom features".

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
- **Interactive codex cannot be auto-managed.** Its limit signal lives only in the
  live `codex exec --json` stdout (never a file), and an interactive codex TUI owns
  its own tty, so clikae-as-parent can't see it. Only claude (transcript), agy
  (log), and **headless** codex (piped stdout) are auto-detectable.
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
   agy=log file, codex=live stdout stream (headless only).
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
Shipped behind a BETA label (claude-only; `clikae auto`; board `A`; one hop per
run). Stub tests cover the decision gate + dry-advance; real interactive
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
