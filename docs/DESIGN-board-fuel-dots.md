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
| 🔴 red `●` | **dry** — over limit, can't burn now | `limit_profile_dry` / `limit_log_dry`, verbatim reset string |
| 🟡 yellow `●` | **weekly-% caution** (BETA) | the vendor's own "used N% of your weekly limit", captured **verbatim + stamped** by watch/auto — never computed |
| 🟢 green `●` | **ready** — a detectable engine with no bad news | `limit_engine_detectable` true, not dry/warned |
| ○ (no colour) | **no reading** — engine we can't read (codex), or no detector | `limit_engine_detectable` false |

One sentence: **the dot is the engine's own last word about this tank's fuel.**
Red = "resets in 3h", yellow = "you're at 85% this week", green = "nothing bad to
report", ○ = "it has never told us anything" (honest blank — see codex).

### Why this dissolves the original confusion

- **Multiple greens are now correct,** not contradictory: they mean "several tanks
  have fuel", which is what you want to see.
- **"Which am I on"** is demoted to where it belongs: the cursor `❯` and the
  burn-order position (momentary, navigational) — plus the `← here` text label and
  the default-launch-target logic, which stay tied to the `active` flag. We only
  took the *colour* off `active`; `active` still drives launch + the text label.
- **○ is honest.** codex's limit is provably un-detectable from disk, so a codex
  tank shows ○ ("no reading"), never a guessed green. Same for never-probed engines.

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

## Cache

`$CLIKAE_HOME/cache/weekly/<cli>-<profile>` — first line = the verbatim vendor
phrase, written by the watch/auto capture, read by `_home_weekly_read`. Absent =
no reading = the tank falls through to green/○.
