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
| 🟡 yellow `◐` | **reset passed · unverified** | a retained limit whose parseable reset has passed; eligible for burn, pending a successful turn |
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

Only that structured source ships. An earlier revision of this feature also
carried a text-shape parser for the RENDERED status line (two grammars, no
explicit zone, since codex always renders in the machine's own local
wall-clock) meant for "a captured status line where the structured source
doesn't reach" — a burn log, or a manual `$CLIKAE_LIMIT_PATTERN`-style paste.
It was removed in round-1 review (2026-09-12): nothing in `lib/`, `bin/`, or
`scripts/` ever called it, only its own tests did, so it was ~130 lines of
permanently-untested code promising a capability no path in clikae could
actually reach. If a real caller for a captured status line shows up later,
it can be rebuilt against `_limit_codex_render_reset`'s epoch→phrase
direction, which does ship (see below).

🔴 **Do not assume `primary` = 5h and `secondary` = weekly by POSITION.** A
real free-tier account reported
`limit_id:"codex"` with a 30-day (`window_minutes:43200`) window living in
`primary` and `secondary` always `null` — nothing like the 5h/weekly split a
different plan's `/status` shows. Each side is labelled by its OWN
`window_minutes` (`_limit_codex_window_label`: ≤360min → `5h`, ≤10080min →
`weekly`, else `<N>d`), never by which JSON key it arrived in.

🔴 **A window's own `resets_at` in the past means it has REFILLED, not that
it is still at its last reported percentage.** `rate_limits` is a snapshot
written at the moment of that `token_count` event; once `resets_at` passes,
the server has reset that window server-side, and the `used_percent` sitting
next to it describes a quota that no longer exists. A tank that burned to
100% at 08:00 with a 5h window resetting at 12:00 must read green/"100%
left" again at 16:00, not the red/"0% left" its last-known event still says
on disk — that exact case (a full tank read hours after its own reset,
still lighting red with a reset time already hours in the past) was round-1
review's P1-1 finding, since fixed: `_limit_codex_window_expired` treats any
side whose `resets_at` is more than 60s behind `now` as fully refilled (0
used / 100% left, no reset text), before the light or the rendered reset are
computed from it. The light therefore always follows the tighter of
whichever windows are still genuinely valid, and a past instant is never
rendered as if it were a future one.

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

`$CLIKAE_HOME/cache/codex/<profile>` — two lines: a cache key (the rollout
store's own file count + newest mtime + TOTAL byte size) and the raw
`rate_limits` fields last read from it, written/read by
`limit_codex_status_cached` (`_limit_codex_rate_limits_cached`,
lib/core/limit.sh). This replaced an earlier "no cache of its own,
self-refreshes on every read" design: that premise was true only on the
maintainer's own small store (6 rollouts, 5 MB); round-1 review (2026-09-12,
P2-1) measured `limit_codex_status` at ~1.5s per call on a synthetic
120-rollout (~62 MB) store, because it re-scanned every rollout file's
CONTENT on every board redraw — breaking `_home_fuel_dotv`'s own "fork-free"
contract. The cache is keyed by the store's mtime/count/size, not a TTL: a
redraw with no new codex activity since the last read costs one `find` + one
`stat` + one `wc -c`, never a re-scan of file content. Light/note/reset
themselves are never cached — they depend on `now` (see the P1-1 note
above) — only the raw vendor fields are, recomputed into a reading fresh on
every call.

🔴 **Size joined mtime in the key (round-2 review, P1-1).** codex appends to
the SAME rollout file rather than opening a new one per event, and mtime
alone is SECOND-resolution — a second `token_count` write landing in the
same wall-clock second as the read that built the cache was invisible to a
file-count+mtime-only key, so the board kept serving a stale reading
indefinitely (reproduced against a real board: persistent false green on a
tank already at 0% left). An append always changes the store's total byte
size even within the same second, so size closes that gap.

`$CLIKAE_HOME/cache/codex/<profile>.d/<rollout-basename>` — one small file
PER rollout (round-2 review, P2-2), keyed the same way
(`_limit_codex_file_state`: that file's own mtime + size) but scoped to a
single file rather than the whole store. The whole-store cache above is
still the fast path for an IDLE tank (one `find`+`stat`+`wc -c` and nothing
else); on a whole-store miss, `_limit_codex_rate_limits_cached` falls back to
these per-file entries instead of re-scanning every rollout — a redraw
during ACTIVITY (a burn appending to one rollout every few seconds) then
only re-scans that ONE file, reusing every other rollout's cached reading. A
rollout with no `rate_limits` event of its own caches a "none" marker too,
so a tank that has never reported usage doesn't pay a fresh scan of every
rollout on every redraw either. Round-1's whole-store-only cache made the
MISS path (any activity) costlier than the pre-cache code — 2.83s vs 1.68s
on the 120-rollout synthetic store, because the miss path re-scanned every
file AND (round-2's P2-1 finding) every one of those scans silently read
each file whole under `bin/clikae`'s real `pipefail` — the per-file cache
plus the pipefail fix together bring an ACTIVE-tank redraw back down near
the pre-cache cost of scanning just the one changed file, while an IDLE
redraw stays at the whole-store fast path's cost.

## Expired limit evidence (#75)

The shared tank verdict resolves reset phrases against the original observation
timestamp, then compares that instant with the current clock. This prevents an
undated time from rolling forward every day. A zone suffix in the phrase,
`(Asia/Tokyo)` and friends, is always authoritative when present — including
for codex's `try again at 5:23 PM` grammar — because agreeing with it on the
maintainer's machine and disagreeing on a traveller's is exactly what a zone
suffix exists to prevent (round-1 review, #75). Only when the phrase names no
zone at all does codex fall back to rendering in the observer's own local
timezone. Unparseable phrases keep the existing behavior. Live output detection
still reports a newly observed rejection as dry.

An expired limit is **yellow `◐`, “reset passed · unverified”**, taking precedence
over proactive percentage snapshots. The default dry batch excludes it, allowing
burn's next-tank selection to retry it. The board and status request the same
batch with cautions included; status exposes the note as `fuelNote` in JSON.
A later successful transcript turn clears the caution — including, for codex, a
turn observed in the transcript after an unrelated persisted marker was written
(round-1 review, #75: falling straight through to the marker regardless of a
transcript's own recovery could pin a tank yellow forever). That clear is
timestamp-gated, though (round-2 review, #75): a headless `codex exec` limit
never reaches the transcript at all, so a days-old interactive recovery must
not erase a marker burn wrote moments ago — only a recovery observed AFTER the
marker's own timestamp clears it; an older recovery next to a newer marker
falls through and the marker's own TTL / `CLIKAE_DRY_MAX_RETAIN` cap governs.
Parseable expired store evidence survives the marker TTL as unverified until
cleared, but never longer than `CLIKAE_DRY_MAX_RETAIN` (7 days) — retained
evidence is a caution, not a promise to remember forever. Unparseable store
evidence retains the existing TTL behavior.


## Vendor usage cache (#72)

Run `clikae usage [engine] [tank] [--json]` to read usage. JSON output is one
object per tank: `engine`, `tank`, `window_pct`, `weekly_pct`,
`window_resets_at`, `weekly_resets_at`, and `source`. Percentages are used
quota (0–100); unavailable fields are null. `source` is `"vendor"` (a live
call actually answered), `"transcript"` (derived from local evidence the
engine already wrote — currently Codex's `rate_limits`, scanned from
rollouts modified in the last 7 days, the same `-mmin -10080` window
`limit_codex_status` uses), `"expired"` (#107: the vendor refused an access
token whose credentials hold a refresh token, or that token's own recorded
expiry had passed — the login is fine, only a session refreshes it; always
with `reason:"expired-token"` and no numbers), or `"unknown"` (no usable
reading; `reason` is `no-credentials`, `network`, `rate-limited` or
`unparseable` when known). A `rate-limited` reading (#136: HTTP 429, which
used to be part of the `network` lump) may carry `retry_after`, the vendor's
own `Retry-After` header in whole seconds, and only when that header was in
1..86400 — `clikae watch`'s usage poll schedules that tank's next poll off it
instead of doubling its own backoff. A VENDOR reading may carry `models`
(#137): the per-model weekly rows the vendor sends in `limits[]` as entries
with kind `weekly_scoped`, normalized to `{name, pct, resets_at}`. Nothing on
the board reads them — the dot stays on the all-models number, because
choosing the relevant per-model row would require knowing which model a tank
runs and a tank carries no such property (`--model` is an argument to
`burn`/`relay`). They are reported by `clikae usage` only.
On the board an expired reading under 24h old draws the no-reading `·` with
the note `⏳ expired · usage --wake <tank>` (the ⏳ lives in the note, not the
dot: every dot is one column and the row grid is padded around that, an emoji
is two; and the note is the short form because a tank row leaves 33 columns
for it on an 80-column terminal — `clikae usage` prints the full sentence,
`⏳ token expired — run a session or 'clikae usage --wake <tank>'`). The tmux
status row, which has a fuel SLOT rather than a padded grid, draws the ⏳ in
that slot instead of the dot, on the same 24h ceiling and counted as the two
columns tmux lays it out in (`docs/DESIGN-tmux.md` Rule 11 §6/§7). The optional
adapter hook is `adapter_usage <config-dir>`. Claude calls the vendor OAuth
usage endpoint; Codex never runs a `codex` process for this — it reads the
same rollout transcript evidence `limit_codex_status` does, so its source is
`"transcript"` and its `cached_at` is that reading's own newest event
timestamp, not the time it was read (round-1 review, P2-4: a week-old
rollout must not be stamped "just now"); Antigravity currently returns
unknown. Parsing requires jq; without it readings are unknown.

Readings live at `$CLIKAE_HOME/state/usage/<engine>/<tank>.json`, including
`cached_at` (the reading's own evidentiary timestamp — see `usage_read`'s
header) and `scanned_at` (when it was actually fetched/scanned; round-2
review, P3 — the two coincide for a vendor reading but not for codex's
transcript evidence, whose `cached_at` is the underlying event's own time).
TTL defaults to 120 seconds against `scanned_at`; `CLIKAE_USAGE_TTL`
overrides it and `--fresh` bypasses it. Errors are cached too — except that
an `"expired"` reading is cached for at most `_USAGE_AUTH_FAIL_TTL_SEC` (60),
so the read after a session refreshes the token sees numbers (#107). Writes are
atomic, and `usage_read` is the ONLY writer in the repo.

**Who writes this cache, and who reads what (round-2 review, P2-1):**

- **(a)** `burn` refreshes the LAUNCHED tank's reading once, at run END —
  after the run's own artifact check (so it can never delay judging that
  run's outcome), never before launching (the launch itself still pays
  zero vendor round-trips — round-1 review, P1-2/P1-3/P1-4, unchanged).
- **(b)** when the named tank is dry and burn must reroute, this is the one
  moment a stale number would cost burn a wrong hop — so surviving
  CANDIDATES are ranked FIRST, on whatever is already known (their cache,
  through `usage_cache_peek`'s own age ceiling — see below), and ONLY THEN
  does burn spend live vendor calls verifying the candidates ranking says
  are worth a call, bounded by `_BURN_REROUTE_REFRESH_CAP` (3 by default;
  named once in `lib/commands/burn.sh`, never re-typed; an override that is
  not a non-negative integer of at most 9 digits warns loudly and falls back
  to the default rather than silently spending zero calls — round-5 review
  P3-6 for the non-numeric case, round-6 review P3-4 for the all-digit
  OVERFLOWING one, which passed the first check and then produced the same
  silent zero budget because `[ "$calls" -lt 99999999999999999999 ]` is an
  arithmetic overflow, not a comparison. `_USAGE_CACHE_PEEK_MAX_AGE_SEC`
  below carries the same bound, where an overflow was the quieter failure
  still: it became a 1e20-second ceiling, i.e. every reading trusted
  forever, with no warning at all). Round-3 review, P3-4, found
  `candidates * --max-time 8` has no total bound as a fleet grows — the cap
  answers that — but round-4 review, P2, found the round-3 shape spent that
  cap on the first 3 candidates by LISTING (alphabetical) order, refreshed
  BEFORE ranking existed: the calls landed on tanks that could never win
  while the tank that DID win was routinely the one candidate left
  unverified with a stale, flattering on-disk reading. Ranking first and
  spending the budget on the winning candidate(s) closes that: a same-account
  sibling was already collapsed to one candidate before any live call (Pass
  2, below), so this can never spend two calls on one account either — one
  refresh per account, reusing that one reading. A candidate the cap never
  reaches keeps whatever `usage_cache_peek` already returned for it (fresh,
  aged, or unknown past the ceiling) — never a live call, same as today.
  Refresh priority (round-5 review, P3-4) has FOUR levels, not three: a
  tier-1 candidate WITH an on-disk reading too old for the ceiling below
  goes first (the one case a confident-but-fresh candidate could be hiding
  an even better tank the board itself still shows a stale percentage for),
  then confident tier-0, then a blank tier-1 with no reading at all, then
  tier-2 last. And the moment a refresh confirms a verified 0% window (an
  unbeatable floor — nothing left in the pool can score lower), the loop
  stops spending the remaining budget rather than always burning every call
  in the cap regardless (round-5 review, P3-3). A refresh call that FAILS
  (401, network error, expired token) may only ever rank that candidate the
  SAME or WORSE than the evidence already on disk, never better (round-5
  review P2-1, round-6 review P3-1). Concretely: a snapshot tier-0 candidate
  (known <90%) becomes unknown — it must never win on the flattering stale
  number Pass 1 read before the call proved it unreadable — while a snapshot
  tier-2 candidate (known >=90%) KEEPS its last good reading and stays
  tier 2. Blanking tier 2 would have PROMOTED it, because unknown outranks
  known->=90% by design (see the three tiers above): a tank last read at 99%
  sixty seconds ago whose token is dead this call would have beaten a
  sibling that verified clean at 95% in the same call. The kept reading is
  already bounded by the age ceiling below (Pass 1 applied it, so anything
  older was unknown here to begin with), so this never resurrects a number
  the ceiling had discarded. `usage_read` overwrites that candidate's
  on-disk cache with `source:"unknown"` on the same failure either way: the
  disk records "cannot read it now", the ranking records "no better than
  what we last saw".
  `usage_cache_peek`'s own age ceiling (`_USAGE_CACHE_PEEK_MAX_AGE_SEC`,
  `lib/core/usage.sh`, 15 minutes by default) is the second half of the
  round-4 fix: a reading older than that is "unknown" for ranking purposes,
  never a flattering-but-stale percentage — belt-and-suspenders with the
  reorder above, since a reading young enough to survive the ceiling can
  still legitimately outrank an unverified tier and get prioritised for a
  live call, the same as any other tier-0 candidate would. This ceiling
  measures the evidence's own `cached_at`, not `scanned_at` — see the
  age-clock paragraph below for why that distinction matters for codex's
  transcript-derived readings specifically. A non-numeric override here
  warns loudly and falls back to the default rather than silently reading
  every candidate as unknown (round-5 review, P3-6).
- **(c)** the board NEVER fetches. It reads whatever is already on disk,
  however old, via `usage_board_fields` — silently within the TTL, WITH its
  age alongside it ("window 44% · weekly 20% · 3h ago") once past the TTL,
  and treated as if there were no cached reading at all once it is 24h or
  older. `clikae usage [engine] [tank] [--fresh]` (a bare `clikae usage
  --fresh` covers every tank) is the only thing a HUMAN runs to fill this
  cache; (a)/(b) are `burn` calling the same writer (`usage_read`) the same
  way, on its own schedule.
- **(d)** `usage_cache_peek` (burn's ranking) and `usage_board_fields` (the
  board's display) both honour the reading's OWN `window_resets_at` /
  `weekly_resets_at`: a window whose reset instant has already passed reads
  as 0% used, never as whatever stale percentage the last fetch happened to
  record — a tank that ran dry at 15:00Z must not still be ranked (or
  shown) at its old 100% two hours after its window reset. This "reset
  passed -> 0%" rule only fires for `usage_cache_peek` WITHIN its own age
  ceiling (below) — past that ceiling the reading is "unknown", never "0%":
  a reading too old to trust for ranking is also too old to know it hasn't
  drifted past a LATER reset it never recorded (round-5 review, P2-2, found
  the ceiling itself measuring the wrong clock let this combination produce
  a false "0%" for a 3-day-old codex transcript — see the age-clock
  paragraph below). `usage_board_fields` carries no such ceiling: it honours
  the reset-passed rule at any age, gated only by its own 24h cutoff in (c).
  Round-5 review, P3-4/P3-3, also changed WHICH candidates Pass 4 spends its
  live-call budget on and WHEN it stops: a tier-1 (unknown) candidate that
  DOES have an on-disk reading — just one too old for the ceiling below — is
  now refreshed BEFORE a confident, fresh tier-0 candidate (a candidate with
  no on-disk reading at all still ranks behind confident tier-0, only ahead
  of tier-2), so a tank the board still shows a stale percentage for can't
  sit unverified forever behind cap-many fresher-but-not-necessarily-better
  candidates; and the loop stops the moment a refresh confirms a verified 0%
  (an unbeatable floor) rather than always spending every call in the cap.
- **(e)** a LIVE SESSION refreshes its own tank, from the `wake` window it
  already has (2026-09-22). (a)–(d) between them left the refresh UNOWNED on
  a machine where nobody burns: measured, a nine-day-old cache and a tmux
  status row showing the no-reading `·` the whole time, while a machine
  burning all day showed live numbers — one `clikae usage <engine> <tank>`
  took 0.7s and the row read `5h 25% · 7d 10%` on the next redraw. So the
  session that is spending the quota is the one that keeps the reading
  current: one `usage_read` at launch, backgrounded, for a session clikae
  just spawned (`wake_usage_prime`, called from `lib/commands/switch.sh`),
  and one every `WAKE_USAGE_INTERVAL` (300s) from the watcher's own loop
  (`wake_watch`, `lib/core/wake.sh`). Same writer, same terms —
  `CLIKAE_USAGE_TTL` still applies, so a cadence shorter than the TTL would
  only re-read the cache — and it keeps that file's constraint: no daemon,
  no state file, nothing that outlives the session, and no model of anyone's
  quota. The tmux row itself still NEVER fetches (`tmux_status_fuelv`;
  `docs/DESIGN-tmux.md` Rule 11 §3 carries the same receipt), and a refresh
  that fails is silent: the last reading stays on disk and the row's own age
  suffix says how old it is. A tank nobody has a session on is unaffected —
  it ages on the board exactly as (c) describes.

**Three different clocks answer three different questions here — reconciled,
not unified, because unifying them would make one of the three lie (round-5
review, P3-5):**

One thing they are NOT allowed to disagree about is what a NEGATIVE age
means. A `cached_at` in the FUTURE — a cache written while the host clock was
ahead, or copied from a machine that was — **counts as age 0**, in both
rulers (round-6 review, P3-7). Until then `usage_cache_peek` REJECTED such a
reading (`select($evidence <= $now)`) while `_home_fuel_dotv_compute` clamped
it (`[ "$age" -ge 0 ] || age=0`), so a cache stamped thirty seconds ahead was
"unknown" for burn ranking and "freshly read" on the board at the same
instant — a fourth kind of inconsistency this section did not cover. Age 0
rather than rejection, because the reading is real evidence carrying a skewed
stamp and rejecting it punishes the tank for its host clock; and because a
skewed stamp can only make a reading look YOUNGER than it is, never older, so
the rule can never resurrect a reading the ceiling would otherwise discard.
On the board, age 0 also means no age annotation is printed, which is the
honest rendering: the stamp says "now" and we have no better number.

- `_USAGE_CACHE_PEEK_MAX_AGE_SEC` (`lib/core/usage.sh`, 900s / 15 minutes)
  answers "is this reading recent enough to RANK burn's reroute on". It
  measures the evidence's own `cached_at` (round-5 review, P2-2 — NOT
  `scanned_at`: a codex transcript reading's `cached_at` is the underlying
  quota EVENT's timestamp, while `scanned_at` is merely when something last
  re-read that same unchanged rollout off disk; measuring `scanned_at`
  let an indefinitely-old rollout stay ranking-eligible forever just by
  being rescanned, no new evidence from the vendor ever required). Short on
  purpose: burn's ranking is a live decision made once, right now, so a
  number a burn might act on immediately should be barely older than "now".
- `_home_fuel_dotv_compute`'s 24h cutoff (`lib/commands/home.sh`, 86400s;
  `_home_fuel_dotv` is the memoizing wrapper around it) answers
  "is this reading still worth SHOWING a percentage for on the board at
  all". Long on purpose: the board is a passive glance, not a live
  decision — a number from this morning is still useful context next to a
  dot, where a number from 15 minutes ago being ranking-stale would be
  useless noise if the board refused to show numbers past the same short
  ceiling burn uses.
- `next_tank` (`lib/core/profile_store.sh:508`) answers neither question —
  it carries no percentage and no age at all. It walks the burn-order RING
  by `limit_tank_dry`'s boolean dry/not-dry state (a completely different
  subsystem, `lib/core/limit.sh`, unrelated to the usage cache these two
  clocks measure) and stops at the first same-engine tank that isn't dry.
  Giving it either of the above ages would require it to start reading the
  usage cache it was never built to read — a materially different, larger
  change, not a two-line reconciliation.

`usage_cached_fields` (fresh-only, no age shown) still exists with its
original contract for any caller that genuinely wants "fresh or nothing",
but is no longer the board's primary read — see (c) above for why a
120s-TTL-only gate left the vendor cache invisible almost all the time on
a real machine (round-2 review's own receipt: 3 of 4 real tanks, hours
stale, showed nothing).

`_home_fuel_dotv`'s header used to promise the redraw path is "fork-free";
that was never fully true (see the codex paragraph above) and is even less
so now that (c) means every tank not yet memoized this redraw pays one
`jq` fork to parse its cache file (plus one shared `date` fork for the
whole redraw) — see that function's own header (round-2 review, P3-1) for
the measured cost and why a hand-rolled bash-only JSON reader was judged
not worth it for a sub-millisecond-per-tank, redraw-only cost.

Dry and the expired-limit caution are decided FIRST, from `_home_is_dryv` —
a persisted dry marker, an account-contagion sibling, or a parseable reset
that has already passed (`reset passed · unverified`) all win outright,
verbatim reset string included, before the vendor cache is even consulted
(round-3 review, P2-1: the reverse ordering let any <24h cached reading
paper over a dry tank). The vendor reading only colours a tank that has
already cleared both checks: for a current (<24h) reading on such a tank,
window and weekly are judged **separately** (2026-09-22 decision), not by
`peak = max(window_pct, weekly_pct)` — they cost differently: a full 5h
window means "wait up to two hours", a full week means the tank is gone for
days.

| dot | condition |
|---|---|
| 🔴 red `○` | transcript-dry (unchanged, above), OR window ≥ 100, OR weekly ≥ 100 |
| 🟡 yellow `◐` | weekly ≥ 85 (dispatch should already be moving to another tank — one step before the fleet's own "stop burning a shared tank at 90%" rule), OR window ≥ 90 (a burn dispatched now will probably die mid-run) |
| 🟢 green `●` | otherwise |

The note keeps carrying both percentages verbatim, unchanged ("window N% ·
weekly N%"). Missing readings, and readings 24h or older, are treated as
unknown and fall through to the existing weekly-caution / codex-status /
ready chain below.

The tank a caller names is always the one burn launches — there is no
pre-launch substitution (round-1 review, P1-2/P1-3/P1-4). Headroom
preference only governs which tank a *dry* burn reroutes to *next*, in
three tiers, best first: a known reading under 90% used beats an unknown
reading, which beats a known reading of 90% or more (P2-9 — a tank we know
nothing about should not lose to one the vendor just called nearly
exhausted; tiering itself uses `peak = max(window_pct, weekly_pct)`).
WITHIN a tier, ordered by lowest **window_pct** first, `weekly_pct` only as
the tie-break (round-2 review, P2-3 — swapped from round-1's weekly-first
shape: a burn is about to run NOW, against the 5-hour window, so a tank
with a great weekly number but its window nearly spent is the wrong pick).
Tanks sharing a vendor account rank as ONE, using the worst (highest)
reading any of them reported this call — never overstating a shared quota
because one sibling's cache snapshot happens to look better — and a tank
is never offered as the very next hop after a sibling on the same account,
even before that account is confirmed dry (P2-6). The existing
live-session, busy-burn, solo, and dried-account exclusions are retained.
`--to` always wins outright over this ordering, and every hop it produces
— including the very first, off a tank that just went dry — is recorded
in `rerouted_from`. Unknown usage keeps the existing transcript-based
launch and reroute behavior otherwise.

Claude reads the tank credential file or tank-specific macOS Keychain
service, guarded by `command -v security` and a bounded wait via
`lib/core/timeout_bin.sh`'s `_burn_timeout_bin` — `timeout` → `gtimeout` →
`perl -e 'alarm …; exec …'` → an honest warning and an unbounded call as a
last resort (mirroring the credential-migration hook's own guard; round-1
review, P2-7; round-2 review, P2-2: this used to be its own two-arm copy,
`timeout`/`gtimeout` only, right here — the ONE platform this branch runs
on, stock macOS, ships NEITHER by default, so the bound was silently empty
on an unmodified install; now it calls the repo's one shared resolver,
which already had the third arm). The bearer token is passed solely
through curl configuration on stdin, with shell tracing disabled, never
through argv or an exported variable. Curl defaults are disabled and
timeouts bound failures; HTTP errors and network failures become unknown
(or expired, above) without printing response bodies. `--fail` stays; the
HTTP status alone is written by `-w '%{stderr}%{http_code}'` to a private
temp file, which is what makes a 401 observable rather than inferred (#107).
