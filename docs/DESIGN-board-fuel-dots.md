# DESIGN — the board's status dot is a fuel gauge, not a "you are here"

_Decided with the maintainer, 2026-06-03, after the dot's meaning was found
confusing during dogfooding. This is the rationale behind `_home_fuel_dot`._

## The problem we found

The column-2 dot on the home board was overloaded across three orthogonal axes,
all crammed onto one glyph + colour:

| axis | where | glyph | meaning |
|---|---|---|---|
| dry / over-quota | tanks, also-available | `!` yellow | this tank is burned out |
| **active / current** | tanks **and** continue | `●` green / `○` | "this is the tank you're on" |
| neutral bullet | everywhere | `○` | just a row marker |

The **green "active"** dot was the confusing one, for two reasons:

1. **It meant different things per engine.** agy's "active" is a real, global,
   persistent fact (the `~/.gemini` symlink). claude/codex have no global active —
   "active" was resolved from the **launching shell's** `CLAUDE_CONFIG_DIR`. So the
   same green dot was "globally pinned" for agy but "happens to be set in THIS
   terminal" for claude → unstable, and it leaked an implementation difference
   (symlink vs env) up to the user.
2. **It was switcher-thinking.** "Which account am I currently on, per service"
   is the central state of an *account switcher*. clikae is deliberately **not** a
   switcher — tanks are equal peers in a burn-order list that you pick from each
   time. A human seeing claude **and** agy **and** codex all green asks "am I on
   all three at once?" — because `●`/"you are here" is inherently singular, and
   making it plural breaks the read.

## The fix: colour the dot by FUEL STATE (one axis), not by selection

Borrowing the traffic-light metaphor: three colours are not three flags, they are
**one gauge, mutually exclusive, one reading per tank** — exactly like a real
signal shows one lamp at a time. The axis is clikae's own identity: _can I burn
this tank?_

| dot | state | source |
|---|---|---|
| 🔴 red `●` | **dry** — over limit, can't burn now | `limit_tank_dry`: transcript (`limit_profile_dry`), log (`limit_log_dry`), or a **persisted dry marker** (`dry_store`, for exec-only limits like codex) — plus a sibling on the same dry account; verbatim reset string |
| 🟡 yellow `●` | **weekly-% caution** (BETA) | the vendor's own "used N% of your weekly limit", captured **verbatim + stamped** by watch/auto — never computed |
| 🟢 green `●` | **ready** — a detectable engine with no bad news | `limit_engine_detectable` true, not dry/warned |
| ○ (no colour) | **no reading** — no fuel signal on disk right now (e.g. codex when no limit was caught) | `limit_engine_detectable` false **and** not dry |

One sentence: **the dot is the engine's own last word about this tank's fuel.**
Red = "resets in 3h", yellow = "you're at 85% this week", green = "nothing bad to
report", ○ = "it has never told us anything" (honest blank — see codex).

### Why this dissolves the original confusion

- **Multiple greens are now correct,** not contradictory: they mean "several tanks
  have fuel", which is what you want to see.
- **"Which am I on"** is demoted to where it belongs: the cursor `❯` and the
  burn-order position (momentary, navigational), plus the default-launch-target
  logic, which stays tied to the `active` flag. We took the *colour* off `active`
  first; the on-row `← here` text label it also used to drive was dropped
  entirely on 2026-06-30 (commit `9d55047`) — with many shells open on different
  tanks at once, "which one is THIS shell on" turned out to be noise, not signal.
  `active` still drives the launch target underneath.
- **○ is honest.** For a long time this recorded that codex's limit was never
  written to a transcript at all, so clikae could not *passively* read it — a
  codex tank showed ○ ("no reading"), never a guessed green, and only a live
  catcher (`clikae burn`) actually seeing the limit in codex's exec output
  could light it red (persisted to a small dry-until store). That premise
  turned out to be false twice over — see "codex gets a real light now"
  below — but the honesty rule it protects is unchanged: still no guessed
  green, still an explicit ○ the moment codex has told clikae nothing at all
  (a brand new tank, or one clikae hasn't been asked to read since it last
  reported usage).

## The yellow light is BETA on purpose

The "used N% of your weekly limit" notice is a **real vendor signal**, but disk
has only raw per-project token tallies + the plan tier — **no weekly denominator
or window boundary** — so computing the % ourselves would be a guess (a phantom
feature, which clikae forbids). The only honest path is to **capture the vendor's
verbatim string when watch/auto sees it stream past**, cache it stamped, and relay
it — the same pattern as the dry detectors echoing "Resets in …".

**Unverified prerequisite:** it is not yet confirmed that Claude serialises this
notice into the transcript / `-p` stream (it may be TUI-render-only). So the whole
yellow path ships **BETA** — wired with a best-guess matcher (`limit_weekly_marker`)
that the maintainer can dogfood. If the notice never lands in a stream we can tail,
yellow simply never lights (safe default) and we revisit. Marking it BETA is what
makes it testable at all — otherwise the maintainer can't observe it firing.

## codex gets a real light now (2026-09-10)

Unlike claude/agy, codex's dot used to be earned only REACTIVELY — a dry marker
after the fact, or nothing. codex's own `/status` panel shows a PROACTIVE
reading whether or not anything is exhausted yet ("5h limit: [████] 100% left
(resets 05:14)", "Weekly limit: [████] 95% left (resets 22:12 on 15 Sep)"), and
clikae had no light for that at all: `clikae burn codex … --json` printed
`"reset": null` on a run that never hit anything, even though codex knew
exactly when the window resets.

**Source chosen: codex's own `rate_limits` object, persisted into the rollout
transcript.** Every codex session — headless `codex exec` included, confirmed
on a real rollout whose `session_meta.originator` is `codex_exec`, not just
the interactive TUI — writes a `token_count` event carrying
`rate_limits.primary`/`.secondary`, each already resolved by the SERVER to a
`used_percent` and an ABSOLUTE `resets_at` epoch. That is cheaper and more
reliable than scraping the rendered progress-bar text: no local-time guessing
at all, because the server already did that math and clikae only relays it —
the same "relay the vendor's own number, never compute one" rule the yellow
BETA light above lives by, except here the vendor's number is genuinely on
disk instead of a phantom feature waiting to happen.

A text-shape parser for the RENDERED line also exists
(`limit_codex_status_line` / `limit_codex_status_reset_epoch`,
lib/core/limit.sh) for the two grammars codex's own status line actually
uses — `resets HH:MM` (undated, local 24h clock, including the midnight
rollover) and `resets HH:MM on D Mon` (dated, no year, English month table,
resolved the same "closest real occurrence" way `limit_reset_epoch` resolves
claude's dated phrases) — so a captured status line (a burn log, or a manual
`$CLIKAE_LIMIT_PATTERN`-style paste) still works even where the structured
source doesn't reach. It carries no explicit zone, unlike claude's phrases:
codex always renders in the machine's own local wall-clock.

🔴 **Do not assume `primary` = 5h and `secondary` = weekly by POSITION.** A
real free-tier account on the maintainer's own machine reported
`limit_id:"codex"` with a 30-day (`window_minutes:43200`) window living in
`primary` and `secondary` always `null` — nothing like the 5h/weekly split a
different plan's `/status` shows. Each side is labelled by its OWN
`window_minutes` (`_limit_codex_window_label`: ≤360min → `5h`, ≤20160min →
`weekly`, else `<N>d`), never by which JSON key it arrived in.

**Light = the tighter window.** Thresholds are on percent LEFT, the same unit
codex's own text uses: 0% left is red (can't burn now, same meaning as every
other red dot), under 15% left is yellow, otherwise green — computed from
WHICHEVER of the two windows is closer to exhausted, so "5h: 90% left,
weekly: 0% left" reads red even though the 5h window alone looks healthy. No
data at all (a tank codex has never reported on) stays the honest ○/dim
"no reading" — never a guessed colour. `clikae burn codex … --json`'s
`"reset"` field now carries the tighter window's own rendered reset text
instead of always `null` on a healthy run; the board's note (`clikae tanks`)
shows both windows side by side.

## Cache

`$CLIKAE_HOME/cache/weekly/<cli>-<profile>` — first line = the verbatim vendor
phrase, written by the watch/auto capture, read by `_home_weekly_read`. Absent =
no reading = the tank falls through to green/○.

codex's proactive reading has no cache of its own — `limit_codex_status`
re-reads its tank's rollout files directly (the same 7-day `-mmin` window
`_limit_codex_dry` already scans), so it self-refreshes on every read with
nothing to invalidate.
