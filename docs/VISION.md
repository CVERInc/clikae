# clikae — Vision

> The north-star for clikae's positioning and roadmap. SSOT for the README intro,
> the `/oss` card, and release notes. (Decided 2026-06-02; positioning sharpened
> 2026-07-11 after a five-seat adversarial product review.)

## One line

**clikae — your starting point for working with AI CLIs.**
Open it and you land on _everything you were just burning through_: your recent
sessions across every account and every engine, each with a one-line recap of
where you left off. Pick one and pick up exactly where you were.

> *Your starting point for working with AI CLIs. One screen: cross-account, cross-engine, with recap; pick one to resume.*

## What clikae IS (and isn't)

clikae is an **on-ramp / continuity dashboard for AI coding CLIs** — not an
"account switcher". Switching accounts is incidental; the point is to **never
lose your place** across the threads you're juggling. The continue list + recap
are the soul; the dot that tells you whether a resume means switching accounts is
just a helpful detail.

- **Focus = AI CLIs.** Claude Code, Codex, Gemini, Antigravity are the main act.
  The other adapters (gh, gcloud, kubectl, aws, docker, terraform…) still work —
  they're a footnote, not the pitch.
- **Lead differentiator** (what `claude --resume` can't do): the trio —
  **cross-account × cross-engine × recap** in one view.
- **recap** = "where you left off + next step". Read free from Claude's own
  session summary (`away_summary`, the `※ recap:` line). For engines without one,
  generated **on-device** by a local model (apfel/ollama/llm) — **lazily, only for
  the row you hover**, so the board stays ~1s. Private, free, offline (reepub DNA).

## The two halves (positioning, 2026-07-11)

Your AI work has two halves. The model half is rented — engine, capability,
quota; the vendor's. The other half is **yours**: who you are (identities,
git identity, connectors), what you know (memory), where you left off
(sessions), what should leave no trace (incognito). clikae is the thin,
auditable, all-local layer that keeps **your half portable** across engines
and accounts. Multi-account quota rotation is a *corollary* of this layer,
not its story — it lives in an advanced chapter with an honest terms page
(docs/terms-and-your-accounts.md), never on the front page.

## The horizon: agent-first

The end state this points at: **your AI agent is yours; the models are fuel.**
The persistent thing — a name, an identity, a memory, a session history — is
the first-class citizen, and engines/accounts are interchangeable depots it
refuels at. The grammar already half-supports this: `clikae <tank-name>`
resolves a bare tank name across engines, so the tank's name is the subject
of the verb today. What's missing before the README may say it out loud:
the tank+Soul pair needs to feel like ONE nameable being, not two features.

**The line we hold, permanently:** clikae carries *continuity* — identity,
memory, place. It never claims to carry *capability*. Swap to a weaker model
and your agent thinks weaker thoughts; that's the vendor's half, priced and
chosen by you. Every future sentence of marketing gets checked against this
line — the moment the words promise "the same AI on a different engine",
they've exceeded the thing (that overclaim was independently torn apart by
two seats of the 2026-07-11 red team; we keep the scar as the rule).

## Two faces

1. **`clikae` — the bash CLI (MIT, the soul).** The continue list, recap, status
   dots, relay, ephemeral (incognito). Pure bash, no daemons, auditable. This is the
   product; everything else wraps it.
2. **`clikae.app` — the native Mac front door (clioil family, later).** A thin
   launcher: click it → it opens your favourite terminal (Ghostty / iTerm2 /
   Terminal) landing **inside the CLI board** → Enter to resume. Plus a **GUI for
   tank management** (add / log in / alias / delete accounts) so setup never needs
   a memorized command. GUI for setup; CLI for the actual work.

This dissolves the "first command" problem: clikae isn't a command you must
remember to type — it's the app you click (which is already muscle memory).

## Two audiences

- **Power users** — `brew install clikae`. Hardcore, auditable, MIT. Power-user tone.
- **Newcomers** — download `clikae.app`. Friendlier on-ramp for people who want to
  use Claude/Codex but aren't at home setting up accounts in a terminal.

Two landing pages, two tones. (Accepted cost: double the copy/maintenance.)

## Roadmap (sequencing — core first, front door later)

1. **v0.5.2 — the CLI board.** Continue list, recap (Claude's `away_summary`),
   status dots, single-write flicker fix, ASCII-safe glyphs, bottom-right logo +
   margins, hover detail (recap or age). _(this release)_
2. **Lazy cross-engine recap.** On-device local generation for engines without an
   `away_summary`, only for the hovered row — making "cross-engine recap" 100% true.
3. **`clikae.app`.** The native launcher + GUI tank management. The killer app.

## Honest limits

- recap today is **Claude-first** (read from `away_summary`); cross-engine recap is
  roadmap item 2, not shipped yet — don't claim it as present until it is.
- The local model needs Apple Intelligence / a local CLI available; clikae always
  falls back gracefully (raw extract / age) when it isn't.

## Future opportunities (not yet shipped)

**Interrupted-session pickup** — when a fleet worker's session is cut short
mid-task (tank ran dry, process killed, network drop), a future clikae could detect
the partial-completion state and hand off the remaining work to another engine with
enough context to resume from where the interrupted session stopped — not just a
static handoff brief, but a "here is what was done, here is the uncompleted step"
continuation. Today `clikae to` writes a handoff brief from a *completed or
voluntarily exited* session; this is distinct: it would pick up a *half-finished
job* and re-thread it to a live tank. The artifact-checked, idempotent task
convention (`burn`'s `--artifact`) is the right foundation — any task designed
around a verifiable artifact can be trivially re-fired. The harder piece is
reconstructing partial state for tasks that don't produce a clean midpoint artifact.
Not designed yet; flagged here as the natural next capability after the
model-tiering + neutral-grader work lands in practice.
