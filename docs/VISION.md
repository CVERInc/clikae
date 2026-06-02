# clikae — Vision

> The north-star for clikae's positioning and roadmap. SSOT for the README intro,
> the `/oss` card, and release notes. (Decided 2026-06-02.)

## One line

**clikae — your starting point for working with AI CLIs.**
Open it and you land on _everything you were just burning through_: your recent
sessions across every account and every engine, each with a one-line recap of
where you left off. Pick one and pick up exactly where you were.

> 你跟 AI CLI 工作的起點。一個畫面,跨帳號、跨引擎、帶 recap,挑一條接回。

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

## Two faces

1. **`clikae` — the bash CLI (MIT, the soul).** The continue list, recap, status
   dots, relay, ephemeral (無痕). Pure bash, no daemons, auditable. This is the
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
