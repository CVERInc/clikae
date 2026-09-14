# shellcheck shell=bash
# lib/commands/watch_github.sh — `clikae watch github`: turn other people's
# replies / @mentions on GitHub into a wake event, the way `clikae watch
# <engine>` already turns "tank ran dry" into one (#46).
#
# WHY POLL, NOT STREAM. The token clikae runs as has no notifications scope
# (#46's own report), so the only signal available is the search API:
#   gh api search/issues -f q='org:<org> updated:>=<cursor>'
# — every issue/PR updated since the last poll, INCLUDING your own. ONE
# request per poll before pagination, well inside the search API's 30
# req/min.
#
# 🔴 P2-2 (2026-09-13 fix-round-3 review): there used to be a SECOND query,
# `mentions:<self>`, run every poll. Once P1-2 (round 2) dropped
# `-author:<self>` from the org query above, that query became a strict
# SUPERSET of what `mentions:<self>` could ever return — any row the
# mentions query would find, the org query already found first (both
# queries run against the same org, and the org loop always runs before
# whatever came after it), so by the time the second query's own results
# reached _wg_process, the exact (repo, number, updated_at) key was already
# in the seen-file and got skipped before the mentions-specific branch ever
# ran. Net effect, measured: the mentions query bought nothing but 1-5 extra
# search requests/poll (E6 in the round-3 review) AND `kind=mention` was
# effectively unreachable in normal operation — the exact bug the docs'
# headline example was silently exposing (see P2-2 below). Removed. `kind`
# is now `mention` when the fetched activity's own body (the timeline event
# _wg_latest_actor already reads for P1-1) contains an `@<self>` mention —
# see WHAT "KIND" (AND "WHO") HONESTLY MEANS below.
#
# 🔴 P1-2 (2026-09-13 fix-round-2 review): the org query used to carry
# `-author:<self>` — which does not mean "exclude my own activity", it means
# "exclude every issue I ever OPENED, in full" — so a collaborator replying
# on an issue you opened never appeared in this query's results AT ALL, no
# matter who replied. That was issue #46's own headline example. Fixed by
# dropping the filter and moving self-exclusion to where it actually
# belongs: per EVENT ACTOR (see WHAT "KIND" HONESTLY MEANS below), checked
# in code against the login of whoever's activity actually bumped
# `updated_at` — never against who opened the issue.
#
# WHERE THIS PLUGS IN. `clikae watch` already means "watch something and turn
# a detected event into an announcement" (today: a dry tank -> an offer to
# switch). `github` is a SOURCE, not a parallel command — see the dispatch in
# watch.sh. Its own subcommand surface (--org/--interval/--once) does not fit
# the engine-watching flag set, so it is parsed here, not threaded through
# cmd_watch's loop.
#
# WHAT "WAKE" MEANS HERE — read before assuming this types into a tmux pane,
# and before re-adding the false claim this file used to carry (P1-1/P1-2,
# 2026-09-13 fix-round-1 review — read that review before touching this
# again). There is no generic wake bus in this codebase, and no `clikae go`
# command (grepped; none exists). Two real, DIFFERENT mechanisms carry the
# word "wake", and this file uses exactly one of them:
#   1. lib/core/wake.sh's wake_send/wake_sit: literally TYPES text (the
#      literal string "go", by default) into a live tmux pane to resume a
#      RATE-LIMITED session. `clikae burn` never calls this on completion —
#      grepped, burn.sh has zero references to wake_attach/wake_send/
#      wake_sit anywhere near _burn_status_write. A finished burn is not a
#      rate-limited one, so there is nothing here to replicate. This file
#      calls neither.
#   2. `clikae burn`/`clikae wait` (#41/#37): a cockpit "receives" a finished
#      burn by blocking, in its OWN foreground command, on a status file
#      (`status.json`) burn writes at every transition — the READER already
#      exists (`clikae wait <run_id|status-file>`, lib/commands/wait.sh,
#      sourcing lib/core/burn_status.sh's burn_status_str/burn_status_state),
#      and burn's entire "wake" IS that write, nothing more
#      (`_burn_status_write` in burn.sh — no tmux call anywhere near it). So
#      THIS is what this file replicates, literally: every poll that finds
#      >=1 new event writes ONE burn-status-SHAPED file — same `state`
#      field, same flat single-line JSON via lib/core/json.sh's escaping —
#      to $HOME/.clikae/logs/watch-github-<org>-<epoch>/status.json
#      (_wg_status_write below; P2-3, 2026-09-13 fix-round-2 review — burn's
#      OWN directory layout, `burn_status_dir`, not a parallel location
#      under $CLIKAE_HOME/state that `clikae wait` never recognised — see
#      _wg_status_write's own comment for the full story), with
#      `state:"done"`, `reason:"github-events"`, `artifact:` pointing at
#      this poll's events file, and `summary:` one line per event (capped,
#      see _wg_build_summary). `clikae wait watch-github-<org>-<epoch>` (or
#      `clikae wait --latest watch-github-<org>` — see wait.sh) returns 0
#      and PRINTS the summary — a cockpit (or a Stop hook, or a person)
#      blocks on it exactly the way it already blocks on a burn. The durable
#      $CLIKAE_HOME/logs/watch-github-<org>/events.jsonl log below is kept
#      too (a full history a cron job can grep after the fact), but it is
#      NOT the reader — nothing in this repo ever parsed it as one. An
#      earlier version of this comment claimed events.jsonl was "parseable
#      with burn_status.sh's OWN burn_status_field/burn_status_str"; grepped,
#      that was never true (zero call sites) — deleted, not fixed, because
#      the real reader is the status file above, not events.jsonl itself.
# A live foreground run (no --once) ALSO prints each wake line as it happens,
# the same way `clikae watch <engine>` prints "Looks like … hit its limit."
# live to whoever is watching that pane — the interactive half of "wake".
#
# WHAT "KIND" (AND "WHO") HONESTLY MEANS. The search API returns issue/PR-
# level rows, not per-comment ones, and its own `user.login` is always the
# ISSUE's author — never whoever's activity just bumped `updated_at` (P1-2/
# P2-5, 2026-09-13 fix-round-2 review: round 1 used that login both to guess
# `kind` AND to decide self-exclusion, which is wrong on both counts — an
# issue YOU opened stays forever "mine" by that field even after a
# collaborator replies on it). So:
#   - a number never seen before (this org's seen-file, any prior poll) ->
#     "opened", actor = the row's own `user.login` (unambiguous: opening IS
#     the event, no lookup needed). Self-authored -> not an event (you know
#     you opened it), but still recorded as seen.
#   - a number seen before, updated again -> the ACTUAL actor and kind come
#     from `issues/<n>/timeline` (_wg_latest_actor — the endpoint has no
#     `direction` param; fetches the LAST page via its own `Link: rel="last"`
#     header, up to 2 requests, still 1 unit against the budget below),
#     the one endpoint whose events carry an actor for every activity shape
#     that bumps `updated_at` — a comment, a review, a label, an assignee
#     change (`repos/.../comments`, round 1's endpoint, only ever covers the
#     first of those). Bounded to 50 lookups/poll, oldest-unseen-first (P1-2,
#     2026-09-13 fix-round-3 review — the org/mentions queries paginate
#     ascending now, see CURSOR MONOTONICITY / BACKLOG above), and stopped
#     early once `X-RateLimit-Remaining` drops below 100 (_wg_lookup_and_count,
#     P2-4) — a candidate beyond the budget is NEVER dropped, it is emitted
#     with actor "unknown" and kind's best guess instead (fail-open: a false
#     wake beats a silent miss, same call the review's own P2-5 fix made).
#     If that fetched event's own BODY TEXT contains an `@<self>` mention
#     (word-bounded — `@bob` must not match inside `@bobby` or an email
#     address; see _wg_body_mentions_self), `kind` is overridden to
#     `mention` regardless of what the event shape itself would have said
#     (a comment that @-mentions you is still, honestly, "someone got your
#     attention" — more specific than "comment"). This REPLACES the old
#     `mentions:<self>` SEARCH query (P2-2, 2026-09-13 fix-round-3 review —
#     see WHY POLL, NOT STREAM above for why that query was removed, not
#     merely fixed): a comment/review body is text this file already has in
#     hand from the P1-1 timeline fetch, at zero extra requests, and it
#     catches the exact case #46 cares about (someone @-mentioning you in a
#     reply) that the removed query had stopped reaching in practice.
#     Self-exclusion is unaffected by this override — it still checks WHO
#     the actor is, never what kind got assigned, so a comment where you
#     mention YOURSELF is still not an event.
#     🔴 SCOPE, STATED PLAINLY: this only covers a number ALREADY SEEN
#     before (the timeline-lookup path above) — a BRAND NEW issue/PR whose
#     own OPENING text @-mentions you still reports as `opened`, not
#     `mention` (search/issues' own TSV never carries the issue body, only
#     its title — reading it would mean a request this file doesn't
#     otherwise make for a fresh number). Not fixed here; a real, narrower
#     gap than the one this replaces.
#
# DEDUP KEY. The issue text says "(number, updated_at, comment id)"; there is
# no comment id available from search/issues within the request budget, so
# the key actually used is (repo, number, updated_at) — in practice
# equivalent to adding a comment id, since any new comment/edit bumps
# updated_at to a value not seen before. The `repo` is load-bearing (P1-4,
# 2026-09-13 fix-round-1 review): the seen-file is per-ORG, and every repo
# in an org restarts issue numbering at #1 — a bare (number, updated_at) key
# let repo-B's brand-new #12 read as a "comment" on repo-A's #12, and would
# silently DROP repo-B's #12 outright on any updated_at collision.
#
# CURSOR MONOTONICITY / BACKLOG. `sort=updated -f order=asc` (P1-2,
# 2026-09-13 fix-round-3 review — round 1/2 used `order=desc`; see the 🔴
# note right below for why that was a permanent-stall bug, not just a
# less-fresh cold start) means page 1 is always the OLDEST unseen item —
# everything `>= since`, working forward. A poll that finds a full page
# keeps paginating (up to 5/poll); the cursor then advances to the LAST row
# this poll actually processed (which, in ascending order, is simply
# $__WG_MAX_UPDATED — see _wg_poll), whether or not this poll got truncated.
# That is the whole fix: truncation no longer needs a special "pin to the
# oldest row read" case, because in ascending order the last row read IS the
# frontier to resume from — the next poll's `updated:>=` picks up exactly
# past it. Trade-off, stated plainly: a cold start on a backlogged org now
# crawls forward from `--since`/24h-ago instead of surfacing today's newest
# activity on poll #1 — see _wg_poll_one_query.
#
# 🔴 PERMANENT STALL, FIXED (P1-2, 2026-09-13 fix-round-3 review — read
# before reverting to `order=desc`). Round 2's fix pinned a truncated poll's
# cursor to "the oldest row of the LAST page read" — correct arithmetic, but
# still under `order=desc`, so every poll's page 1 was, again, the newest
# 100 rows. A busy org with >=500 rows inside the polling window therefore
# re-read the SAME newest 500 rows every single poll, got truncated at page
# 5 every single time, and recomputed the exact same cursor every single
# time — permanently stuck, forever reporting "truncated: continuing next
# poll" while never actually continuing. Proven with an HONEST stub (filters
# by `updated:>=` and re-paginates for real, not a canned per-call fixture):
# 501 rows, cursor identical after 3 consecutive polls, row #501 delivered
# zero times. `order=asc` fixes this structurally — the cursor can only ever
# move forward, past whatever this poll actually read, so a backlog of any
# size drains in bounded polls, never stalls, and needs no special-casing
# for the truncated vs. non-truncated case.
#
# 🔴 PERMANENT STALL, FIXED AGAIN (P1-1, 2026-09-14 fix-round-4 review —
# read before re-adding a lag subtraction to the cursor). Round 3's own fix
# above is correct about `order=asc`, but round 3 (and rounds 1-2 before
# it) ALSO subtracted a fixed 300s off the cursor for search-index lag
# (see the CURSOR SEMANTICS note above _wg_query_org) — and that
# subtraction alone recreated the identical permanent stall on a DENSER
# backlog: any 300-second window holding >=500 rows (the page-5 cap) put
# the lagged cursor back inside the very page this poll just read, so the
# next poll re-read it, recomputed the identical lagged cursor, forever.
# Proven with the same honest stub, denser corpora: 600 rows/0.6s apart
# (a 300s window = exactly 500 rows) never moved the cursor past poll 1,
# ever; worse, once stuck this way the feature stopped delivering ANY
# activity for that org afterward, not just the tail — the exact failure
# #46 exists to prevent. Fixed by dropping the lag from the cursor
# entirely (see CURSOR SEMANTICS) and covering the same index-lag margin
# with a separate, bounded `_wg_tail_sweep` that reads the last 300s on
# its own schedule and never feeds back into this cursor.
#
# ⚠️ FORMERLY A KNOWN GAP, FIXED (P1-2, 2026-09-13 fix-round-2 review): round
# 1 shipped `-author:<self>` in the org query as a "locked design decision",
# with a caveat saying a plain reply on your own issue only reaches you via
# an explicit @mention on the mentions:<self> query instead. That caveat was
# ALSO wrong — the mentions query's self-check compared the issue's own
# author (always you, on your own issue) against self, so it dropped that
# row too. Net effect: issue #46's own headline example (a collaborator's
# reply on an issue the maintainer opened) had 0% coverage, not the "half
# covered, half documented" the caveat claimed. Both are fixed now — see
# WHY POLL, NOT STREAM and WHAT "KIND" (AND "WHO") HONESTLY MEANS above.

# --- paths --------------------------------------------------------------

_wg_state_dir() { printf '%s/state/watch-github\n' "$CLIKAE_HOME"; }
_wg_log_dir()   { printf '%s/logs/watch-github-%s\n' "$CLIKAE_HOME" "$1"; }
_wg_cursor_file() { printf '%s/%s.cursor\n' "$(_wg_state_dir)" "$1"; }
_wg_seen_file()   { printf '%s/%s.seen\n'   "$(_wg_state_dir)" "$1"; }
_wg_events_file() { printf '%s/events.jsonl\n' "$(_wg_log_dir "$1")"; }
# _wg_lock_dir <org> -> the mkdir-lock guarding one poll's read-poll-write
# section for this org (P2-11). See _wg_lock_acquire/_wg_lock_release below.
_wg_lock_dir()    { printf '%s/%s.lock\n' "$(_wg_state_dir)" "$1"; }

# _wg_lock_acquire <org> [timeout_s=30] -> 0 once this process holds the
# lock (mkdir is atomic on every filesystem this needs to work on, NFS
# included — unlike a lock FILE's `O_CREAT|O_EXCL`, which some of clikae's
# other locks avoid for exactly that reason too), 1 on timeout. P2-11
# (2026-09-13 fix-round-1 review): this feature is explicitly designed to
# be invoked BOTH by cron (`--once`) and by hand (a person also running
# `--once`, or the live loop) — with no lock, two overlapping polls race
# the seen-file compaction (`tail`+`mv` under each other) and the cursor
# write, and an append landing in the gap between them silently vanishes.
#
# Deliberately much simpler than burn's own tank lock
# (lib/commands/burn.sh's _burn_tank_lock_acquire): that one has to survive
# a burn running for HOURS, with real pid/started-at reclaim logic for a
# holder that crashed mid-run. A watch-github poll is a handful of `gh api`
# calls that finishes in seconds — a plain mkdir + mtime-based staleness
# check (reusing lib/core/profile_store.sh's own file_mtime, which already
# solves the GNU/BSD `stat` footgun once) is honest here, not a shortcut.
_wg_lock_acquire() {
  local org="$1" timeout="${2:-30}" dir waited=0 age mtime old_pid
  dir="$(_wg_lock_dir "$org")"
  mkdir -p "$(_wg_state_dir)" 2>/dev/null || true
  while ! mkdir "$dir" 2>/dev/null; do
    if [ -d "$dir" ]; then
      mtime="$(file_mtime "$dir")"
      case "$mtime" in
        ''|*[!0-9]*) : ;;   # can't read it — don't guess, just keep waiting
        *)
          age=$(( $(date +%s 2>/dev/null || echo 0) - mtime ))
          if [ "$age" -gt 300 ]; then
            # P3-8 (2026-09-13 fix-round-2 review): reclaiming used to be
            # silent — 0 lines printed, 0 files recording who held it. Read
            # the holder's pid (written below) BEFORE removing it, and say so.
            old_pid="$(cat "$dir/pid" 2>/dev/null || printf 'unknown')"
            rm -f "$dir/pid" 2>/dev/null || true
            rmdir "$dir" 2>/dev/null || true
            log_warn "github:$org — stale poll lock (pid $old_pid, ${age}s old) reclaimed."
            continue
          fi
          ;;
      esac
    fi
    [ "$waited" -lt "$timeout" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || true
  return 0
}

_wg_lock_release() {
  local dir; dir="$(_wg_lock_dir "$1")"
  rm -f "$dir/pid" 2>/dev/null || true
  rmdir "$dir" 2>/dev/null || true
}

# --- time helpers -----------------------------------------------------------

# _wg_since_default -> ISO8601 Z for "24 hours ago" (the cold-start lower
# bound, P1-3/P2-7, 2026-09-13 fix-round-1 review — without a bound, a cold
# start's first query was `org:X -author:me` with NO time filter at all,
# `order=asc` handed back the org's oldest 30 issues ever, and a busy org
# took HOURS to crawl forward to "today", which is the entire value this
# feature exists for). GNU first, BSD fallback — same two-attempt shape
# lib/core/limit.sh's _limit_iso_epoch already uses for the same reason.
_wg_since_default() {
  date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# _wg_iso_from_epoch <epoch> -> ISO8601 Z string, or empty if this platform's
# `date` can't do it (GNU `-d @epoch`, BSD `-r epoch`).
_wg_iso_from_epoch() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# --- queries --------------------------------------------------------------

# CURSOR SEMANTICS (P1-3, 2026-09-13 fix-round-1 review; revised P1-1,
# 2026-09-14 fix-round-4 review). The original query used `updated:>cursor`
# (strict) with the cursor set to the exact max updated_at seen — no
# margin. GitHub's search index lags real writes by some minutes
# (documented search-API behaviour); anything that lands in the index AFTER
# the poll that set the cursor, but whose updated_at is <= that cursor,
# would never appear in ANY future query — gone, silently, forever. Fixed by
# using `>=` (inclusive), with the cursor set to the EXACT max updated_at
# actually processed each poll (_wg_poll below) — the seen-file dedup
# (already needed for other reasons) absorbs the resulting one-row overlap
# between polls for free.
#
# 🔴 Round 1 through 3 instead subtracted a fixed 300s straight off this
# cursor to buy the same index-lag margin — round-4 review found that this
# re-created the exact permanent-stall bug P1-2 (round 3) had just fixed:
# any 300-second window holding >=500 rows (a busy org's own page-5 cap)
# made the lagged cursor land BACK INSIDE the page this poll had just
# re-read, so the next poll re-read the identical window, computed the
# identical lagged cursor, forever — silently, with every poll still
# reporting rc=0. Fixed by dropping the lag from this value entirely: the
# cursor now only ever advances to what THIS poll actually saw, so it is
# monotonic by construction and cannot regress into its own just-read
# window. The 300s margin against index lag is instead bought by
# _wg_tail_sweep, a SEPARATE bounded re-read of the last 300s that never
# feeds back into this cursor — see that function's own comment.
#
# 🔴 TAIL SWEEP WINDOW, FIXED AGAIN (P2-1, 2026-09-14 fix-round-5 review —
# read before touching _wg_tail_sweep's own schedule or window again).
# Round 4's fix above bought back the 300s index-lag margin with
# _wg_tail_sweep on a fixed "every 5 polls" schedule and a fixed 300s
# window — but those two numbers only ever meet when 5 * interval <= 300s
# (--interval <= 60s). The default --interval is 10m: 5 * 600 = 3000s >>
# 300s, so 45 of every 50 minutes had nothing re-reading the index-lag
# margin at all; `--once` run from cron doesn't know --interval to begin
# with, so the old schedule was arithmetic that happened to work at one
# specific interval, not a general fix. Proven with the review's own
# two-arm probe: a row indexed late by 30s, ongoing activity every 600s —
# never recovered in 12 polls; the identical row, activity every 60s —
# recovered on poll 5.
#
# FIRST ATTEMPT (reverted): sweep on EVERY poll instead of every 5th, one
# of the two shapes the round-5 brief allowed. Broke 9 pre-existing bats
# tests: `_gh_stub_install`'s `gh` stub answers canned responses by a
# single per-call-number counter shared by every `search/issues` call —
# main query AND sweep alike, since the stub has no notion of `order=asc`
# vs `desc`. A sweep on poll 1 silently consumed the canned response the
# test had queued for poll 2's own main query, so poll 2 saw an empty
# page and reported 0 events where the test expected 1. The schedule
# staying poll-count-based (not "does this poll issue a sweep request")
# is what every one of those tests already assumed.
#
# ROUND-5'S FIX (round 4's schedule kept, only the window changed):
# window = max(300s, sweep_n * $__WG_POLL_GAP), where $__WG_POLL_GAP is
# the real wall-clock gap since the IMMEDIATELY PRECEDING poll
# (_wg_poll_measure_gap, measured every poll) and <sweep_n> is how many
# polls elapsed since the last sweep. That multiplication ASSUMES every
# one of those <sweep_n> gaps was the same length as the single most
# recent one — true when polling is evenly spaced, false the moment it
# is not.
#
# 🔴 REPLACED (P2-1, 2026-09-14 fix-round-6 review — read before touching
# _wg_tail_sweep's own window again). A live loop's own back-off breaks
# that even-spacing assumption BY DESIGN: cmd_watch_github's recovery
# (`cur="$interval_s"` on the first successful poll) resets `cur`
# straight back to `$interval_s` in ONE step the instant a poll succeeds,
# not a gradual climb-down — so the poll right after a long back-off has
# a short gap while the four polls before it were long ones. round-5's
# formula reads only that one short gap and multiplies it by 5, producing
# a window narrower than the real span since the last sweep — proven with
# the review's own two-arm probe: gaps 3600,3600,3600,3600 (window
# 5*3600=18000s, correct) vs 3600,3600,3600,600 (window 5*600=3000s, but
# 3*3600+600=11400s had actually elapsed) — the second arm silently lost
# a row sitting 9000s below the cursor, with rc=0 and no warning at all.
# FIXED by measuring instead of inferring: <org>.sweepat (beside the
# cursor, same shape as .cursor/.seen/.sweepn) holds the epoch the last
# sweep actually completed at; window = max(300s, now - sweepat) — the
# real elapsed span, however uneven the polls in between were, with no
# multiplication and no assumption about which of them "counts". The
# SCHEDULE (every 5 polls, or right after a truncated one) is still
# UNCHANGED — sweep_n keeps deciding WHEN to sweep; sweepat now decides
# how WIDE, independently. `_wg_poll_measure_gap`/`.lastrun` stay (a
# per-poll gap is still useful on its own), but neither feeds the window
# any more. The very first sweep an org ever has (or a `.sweepat` a
# sanity check below treats as missing) has no prior sweep to measure
# from — window stays at the 300s floor, same as before (since
# fix-round-7 P3-3, the first poll writes a baseline instead). (This note
# originally said "at most ONE extra request per poll"; since fix-round-6
# P2-2 paginates the sweep it is at most 5 — P3-2, fix-round-7.)
#
# 🔴 OVERLAP (P2-1, 2026-09-14 fix-round-7 review): that measured window
# still ended exactly where the previous sweep began, and an active org's
# cursor is ~now — so a row updated just before sweep S1 but indexed just
# after it fell between the two sweeps for good. window is now
# max(300s, now - sweepat) + 300s, with sweepat = when the last sweep
# STARTED; see _wg_tail_sweep_window for why that bounds every row with
# <= 300s index lag regardless of local clock skew.
#
# 🔴 SANITY (P3, 2026-09-14 fix-round-6 review): `.lastrun`/`.sweepat`
# both hold a bare epoch a future poll subtracts `now` from — `0` (the
# exact sentinel `date +%s 2>/dev/null || echo 0` itself writes on a
# `date` failure) or a value in the future (a foreign file, a clock that
# jumped) must read as "missing", not as "since 1970" or a negative gap;
# see _wg_sane_epoch below, shared by both files.

# _wg_query_org <org> <since> -> the search string for "issues/PRs updated
# since <since>" in <org> — EVERY one, including issues you opened yourself
# (P1-2, 2026-09-13 fix-round-2 review: no `-author:<self>` — see WHY POLL,
# NOT STREAM in the file header for why that filter was wrong, not just
# incomplete). Self-exclusion happens in _wg_process, per event actor.
# <since> is never empty — _wg_poll always resolves it to either the
# persisted cursor, --since, or the 24h default.
_wg_query_org() {
  local org="$1" since="$2"
  printf 'org:%s updated:>=%s' "$org" "$since"
}

# --- one query's worth of work ---------------------------------------------

# _wg_fetch <query> <page> <errfile> [order=asc] -> TSV on stdout (number,
# updated_at, login, repo, html_url, is_pr, title, comments — see the jq
# filter), gh's own exit code. `comments` (P2-9, see
# _wg_latest_comment_author below) is the issue's own comment COUNT as of
# this search hit — used to fetch the single latest comment's author with
# one extra request, not to print anything. gh's `--jq` is its own vendored
# implementation (gojq) — no external `jq` binary required, unlike
# lib/core/fleet_mcp.sh's merge (which genuinely needs the real jq for
# --slurpfile).
#
# `order=asc` + `per_page=100` (P2-7, 2026-09-13 fix-round-1 review; order
# flipped desc->asc in P1-2, 2026-09-13 fix-round-3 review — see CURSOR
# MONOTONICITY / BACKLOG in the file header for why desc could stall a busy
# org forever). The original call took whatever the API's own default page
# (30, oldest-first) handed back — a busy org's backlog could outrun a
# single poll. asc + 100/page + the pagination loop in _wg_poll (up to 5
# pages = 500 rows/poll/query) means page 1 is always the OLDEST unseen
# item, working forward — a poll that gets truncated still leaves the
# cursor exactly at the end of what it read, so the NEXT poll continues
# from there instead of re-reading the same top of the window forever.
# `order` is overridable (4th arg, default `asc`) ONLY for _wg_tail_sweep
# below, which deliberately wants `desc` — the newest rows in its 300s
# window first — over the SAME plumbing rather than a second copy of it.
#
# 🔴 `--method GET` IS NOT OPTIONAL. `gh api`'s own default HTTP method
# flips from GET to POST the moment ANY `-f`/`-F` is given (its docs say so
# plainly; this file's own `--once` smoke test against the real CVERInc org
# caught it directly — every `-f q=…` call came back "gh: Not Found (HTTP
# 404)" until this was added, because POSTing to a GET-only search endpoint
# 404s rather than 405s). `-f` still becomes a query-string param under an
# explicit GET, which is the whole point of using it instead of hand-quoting
# a URL.
_wg_fetch() {
  local query="$1" page="$2" errfile="$3" order="${4:-asc}"
  gh api search/issues --method GET -f q="$query" -f sort=updated -f order="$order" \
    -f per_page=100 -f page="$page" \
    --jq '.items[]? | [(.number|tostring), .updated_at, .user.login, (.repository_url|split("/")|.[-1]), .html_url, (if .pull_request then "1" else "0" end), .title, (.comments|tostring)] | @tsv' \
    2>"$errfile"
}

# _wg_http_status <errfile> -> the HTTP status code gh's own error text
# reported, or empty. Reads ONLY text immediately after the literal word
# "HTTP" — never any 3-digit number that happens to appear anywhere else in
# the message (an issue number in a URL, e.g. ".../issues/403", used to be
# misread as a rate-limit status by a bare `403|429` grep over the whole
# line — P3-14, 2026-09-13 fix-round-1 review). Handles both shapes `gh`
# actually emits: "HTTP 403: <msg>" and "<msg> (HTTP 404)".
_wg_http_status() {
  grep -oE 'HTTP[: ]+[0-9]{3}' "$1" 2>/dev/null | head -n1 | grep -oE '[0-9]{3}$'
}

# _wg_classify_error <errfile> -> one of: rate-limit | permanent | transient.
# P2-5/P2-6 (2026-09-13 fix-round-1 review): the OLD code treated every
# 403/429 as "back off and try again forever" — including a 403 for missing
# OAuth scope, SAML enforcement, or a bad org name, none of which a retry
# EVER fixes. In a live loop that meant backing off to 1h and printing
# "rate-limited" once an hour, permanently, with the real reason never
# shown. Now:
#   - 429, or a 403 whose text actually says the rate limit is why -> a
#     genuine rate limit: back off (see _wg_poll_one_query/cmd_watch_github).
#   - any OTHER 403, or 404 (a bad org/endpoint — this file's own --method
#     GET bug produced exactly this) -> permanent: never enters back-off,
#     surfaces the reason, exits (after one retry — see
#     _wg_fetch_classified below).
#   - anything else (network error, DNS, timeout, a status this can't read)
#     -> transient: today's existing behaviour (log and move on, no
#     back-off, cursor not advanced past it).
_wg_classify_error() {
  local errfile="$1" status
  status="$(_wg_http_status "$errfile")"
  case "$status" in
    429) printf 'rate-limit' ;;
    403)
      if grep -qiE 'rate.?limit' "$errfile" 2>/dev/null; then
        printf 'rate-limit'
      else
        printf 'permanent'
      fi
      ;;
    404) printf 'permanent' ;;
    5[0-9][0-9]) printf 'rate-limit' ;;
    *) printf 'transient' ;;
  esac
}

# _wg_fetch_classified <query> <page> [order=asc] -> rc 0 on success, with
# the TSV in global $__WG_LAST_TSV. On failure, retries the SAME call ONCE
# if (and only if) the first failure classified as "permanent" (a transient
# blip that merely wore a permission-denied costume is cheap to rule out; a
# genuine permanent failure fails the same way twice) — then sets
# $__WG_LAST_KIND / $__WG_LAST_REASON from whichever attempt is final and
# returns 1.
#
# 🔴 MUST be called directly, never as `x="$(_wg_fetch_classified …)"` — a
# command substitution forks a SUBSHELL, and this function's whole point is
# the global variables it sets on failure; those would be silently lost the
# instant the subshell exits (caught in this file's own bats suite: a "403"
# assertion failed because $__WG_LAST_REASON came back empty). The TSV
# payload goes through $__WG_LAST_TSV for the same reason, not stdout.
_wg_fetch_classified() {
  local query="$1" page="$2" order="${3:-asc}" errfile rc kind
  errfile="$(mktemp "${TMPDIR:-/tmp}/clikae-watch-github.XXXXXX")"
  rc=0
  __WG_LAST_TSV="$(_wg_fetch "$query" "$page" "$errfile" "$order")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$errfile"
    return 0
  fi
  kind="$(_wg_classify_error "$errfile")"
  if [ "$kind" = "permanent" ]; then
    rm -f "$errfile"
    errfile="$(mktemp "${TMPDIR:-/tmp}/clikae-watch-github.XXXXXX")"
    rc=0
    __WG_LAST_TSV="$(_wg_fetch "$query" "$page" "$errfile" "$order")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$errfile"
      return 0
    fi
    kind="$(_wg_classify_error "$errfile")"
  fi
  __WG_LAST_KIND="$kind"
  __WG_LAST_REASON="$(head -n1 "$errfile" 2>/dev/null)"
  rm -f "$errfile"
  return 1
}

# _wg_latest_actor <org> <repo> <number> -> 0 with $__WG_LOOKUP_ACTOR /
# $__WG_LOOKUP_KIND set, or 1 with $__WG_LOOKUP_LAST_KIND (rate-limit |
# permanent | transient, via the SAME _wg_classify_error the search calls
# use — never `|| out=""`, P2-4/P2-5, 2026-09-13 fix-round-2 review) /
# $__WG_LOOKUP_LAST_REASON set.
#
# 🔴 REWRITTEN (P1-1, 2026-09-13 fix-round-3 review — read before touching
# this again). `issues/<n>/timeline` HAS NO `direction` PARAMETER — round
# 2's `-f direction=desc` was silently ignored by the API, so `per_page=1`
# always returned the timeline's FIRST (oldest) item, not the latest. Real-
# world measurement (the one real `--once` this feature is allowed, against
# a temp CLIKAE_HOME through a forwarding shim): 22 lookups, only 9 carried
# `actor`/`user` at all, and the ones that did were hours-to-a-day stale —
# 13/22 fell back to `unknown`, and (worse, silently) some genuinely fresh
# activity got attributed to whoever the STALE first event happened to be,
# wrongly self-excluding it. `committed` — the single most common timeline
# event shape in real data — carries no `actor` field at all (only
# `author`/`committer` name/email, not a login), which is a second,
# independent reason `per_page=1` on an arbitrary item so often came back
# empty.
#
# Fixed in two calls (still ONE unit against the 50-lookup budget — see
# _wg_lookup_and_count): (1) fetch page 1 at `per_page=100` and read the
# `Link: rel="last"` response header for the LAST page number — the only
# way to find "the end of the timeline" this endpoint offers, since it
# can't be asked to sort descending; (2) if a last page beyond page 1
# exists, fetch THAT page (100 more items, the true tail of the timeline);
# otherwise page 1 already had everything, no second call needed. Either
# way, `_wg_last_actor_in_body` then scans that page BACKWARDS for the LAST
# event that carries `actor.login` OR `user.login` (a comment's own object
# is keyed `user`, not `actor` — round 1 and 2 both checked `actor` first,
# which still needs to happen first here, but a comment-shaped event was
# never reachable under the old per_page=1 approach often enough to notice
# the fallback mattered) — skipping `committed`/`cross-referenced`/anything
# else with neither. If NOTHING on that page carries either field (an
# all-`committed` history, or a genuinely empty timeline), this returns 1
# exactly like a lookup failure — the caller (_wg_process, via
# _wg_lookup_and_count) already treats that as "never drop, emit as
# unknown, never treated as self" — never inferring "not you" OR "you" from
# an actor it could not find.
_wg_latest_actor() {
  local org="$1" repo="$2" number="$3" errfile raw rc body last_page
  __WG_LOOKUP_ACTOR=""
  __WG_LOOKUP_KIND=""
  __WG_LOOKUP_BODY=""

  errfile="$(mktemp "${TMPDIR:-/tmp}/clikae-watch-github.XXXXXX")"
  raw="$(gh api "repos/$org/$repo/issues/$number/timeline" --method GET \
    -f per_page=100 -f page=1 -i 2>"$errfile")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    __WG_LOOKUP_LAST_KIND="$(_wg_classify_error "$errfile")"
    __WG_LOOKUP_LAST_REASON="$(head -n1 "$errfile" 2>/dev/null)"
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  __WG_LOOKUP_RATE_REMAINING="$(printf '%s\n' "$raw" \
    | grep -iE '^x-ratelimit-remaining:' | head -n1 | tr -d '\r' | awk '{print $2}')"
  # `Link: <...?per_page=100&page=3>; rel="next", <...&page=3>; rel="last"`
  # — isolate the rel="last" segment first, THEN pull its page number, so
  # `per_page=100` in the same URL (which also contains the substring
  # "page=100") can never be misread as the page number: require a `?`/`&`
  # immediately before `page=`.
  last_page="$(printf '%s\n' "$raw" | grep -iE '^link:' | head -n1 \
    | grep -oE '<[^>]*>; *rel="last"' | grep -oE '[?&]page=[0-9]+' | head -n1 | grep -oE '[0-9]+$')"
  body="$(printf '%s\n' "$raw" | awk 'f{print} /^\r?$/{f=1}')"

  if [ -n "$last_page" ] && [ "$last_page" != "1" ]; then
    errfile="$(mktemp "${TMPDIR:-/tmp}/clikae-watch-github.XXXXXX")"
    raw="$(gh api "repos/$org/$repo/issues/$number/timeline" --method GET \
      -f per_page=100 -f page="$last_page" -i 2>"$errfile")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      __WG_LOOKUP_LAST_KIND="$(_wg_classify_error "$errfile")"
      __WG_LOOKUP_LAST_REASON="$(head -n1 "$errfile" 2>/dev/null)"
      rm -f "$errfile"
      return 1
    fi
    rm -f "$errfile"
    __WG_LOOKUP_RATE_REMAINING="$(printf '%s\n' "$raw" \
      | grep -iE '^x-ratelimit-remaining:' | head -n1 | tr -d '\r' | awk '{print $2}')"
    body="$(printf '%s\n' "$raw" | awk 'f{print} /^\r?$/{f=1}')"
  fi

  if _wg_last_actor_in_body "$body"; then
    return 0
  fi
  __WG_LOOKUP_LAST_KIND="transient"
  __WG_LOOKUP_LAST_REASON="timeline: no actor in the last page fetched (page ${last_page:-1})"
  return 1
}

# _wg_timeline_events <json-array-text> -> one line per top-level array
# element, in order: <element's own top-level "body" string, still
# JSON-escaped, empty when null/absent/not a string> \037 <element text>.
# Quote-, escape- and depth-aware (P2-2, 2026-09-14 fix-round-7 review), so
# a `},{` inside a string or a nested array of objects never splits an
# element and a nested object's "body" key is never mistaken for the
# event's own. awk, not jq: this file needs no external jq (see _wg_fetch).
# LC_ALL=C: byte-wise substr, O(1) per character in every awk.
_wg_timeline_events() {
  printf '%s' "$1" | LC_ALL=C awk '
    { s = s $0 }
    END {
      US = sprintf("%c", 31)
      n = length(s); depth = 0; instr = 0; esc = 0; want = 0; isval = 0
      estart = 0; sstart = 0; key = ""; laststr = ""; body = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (instr) {
          if (esc) { esc = 0; continue }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") {
            instr = 0
            if (depth == 2) {
              str = substr(s, sstart, i - sstart)
              if (isval && key == "body") body = str
              if (!isval) laststr = str
            }
          }
          continue
        }
        if (c == "\"") {
          instr = 1; sstart = i + 1
          if (depth == 2) { isval = want; want = 0 }
          continue
        }
        if (c == " " || c == "\t" || c == "\r") continue
        if (c == ":" && depth == 2) { key = laststr; want = 1; continue }
        if (depth == 2) want = 0
        if (c == "{" || c == "[") {
          depth++
          if (depth == 2 && c == "{") { estart = i; body = ""; key = ""; laststr = "" }
          continue
        }
        if (c == "}" || c == "]") {
          depth--
          if (depth == 1 && c == "}" && estart > 0) {
            print body US substr(s, estart, i - estart + 1)
            estart = 0
          }
          continue
        }
      }
    }'
}

# _wg_last_actor_in_body <compact-json-array-body> -> 0 with
# $__WG_LOOKUP_ACTOR/$__WG_LOOKUP_KIND/$__WG_LOOKUP_BODY set to the LAST
# array element that carries `actor.login` or `user.login`, scanning from
# the end backward — or 1 if nothing in the page carries either (all
# `committed`, or `[]`). Array elements come from _wg_timeline_events
# (fix-round-7; this used to split on `},{`, which a body or a nested
# array of objects could contain). Portable reverse (no `tac`, which macOS doesn't ship): the classic
# `sed '1!G;h;$!d'` idiom.
#
# `$__WG_LOOKUP_BODY` (P2-2, 2026-09-13 fix-round-3 review; 🔴 FIXED AGAIN,
# P2-2, 2026-09-14 fix-round-5 review — read before touching this again):
# the matched event's own `body` field, unescaped-quote-aware
# (`([^"\\]|\\.)*` — a comment/review body legitimately contains `"`
# characters, escaped as `\"` in the JSON; the simpler `[^"]*` pattern this
# file uses for short fields like a login would truncate early on those).
# Empty when the SELECTED event's own type carries no `body` at all — fed
# to _wg_process's own `_wg_body_mentions_self` check, never printed
# anywhere (see the P2-2 note in _wg_process for why only the row's own
# `title` is ever shown in the wake line).
#
# 🔴 Round-3's own comment above claimed "the event this loop just picked
# is the newest one carrying an actor, which is also the newest one
# carrying a body (only a comment/review has either field at all)" — that
# parenthetical is false: `labeled`/`closed`/`assigned`/`renamed` all carry
# `actor` and never carry `body`. A timeline shaped
# [commented by zed (body @self), labeled by carol] picks carol (the last
# actor-carrying event, by design — that IS who most recently touched the
# item), but round 3's code then took the LAST `body` field anywhere in
# the page regardless of which event that was — zed's — and used it to
# decide `kind`, printing "mention by carol": a real @self mention, by
# zed, misattributed to carol, who only added a label. Fixed by gating the
# body extraction on the SELECTED event's own type, same `case` this
# function already classifies `kind` from: `commented`/`reviewed` are the
# shapes that can carry a body at all (the search API's own timeline
# schema — anything else gets "" (matching round 3's original,
# now-corrected intent). This does NOT change actor selection — carol is
# still reported as the row's actor, same as any other non-mentioning
# activity (see the control case right below this comment in the tests)
# — it only stops a body that belongs to a DIFFERENT, earlier event from
# upgrading that unrelated actor's own kind to `mention`.
#
# 🔴 `review_requested` REMOVED FROM THIS LIST (P2-3, 2026-09-14
# fix-round-6 review — read before adding it back). Round 5's own list
# above added it on the reasoning that it "could carry a body" — it
# never does (a review request has no comment text, only a
# `requested_reviewer`); its own event object never has a `body` field.
# With it in the list, a timeline shaped [commented by zed (body @self),
# review_requested by carol] still selects carol as the actor (correct —
# same as any other non-body event), but this `case` then let the SAME
# whole-page-last-body scan run for her too, picking up zed's UNRELATED
# body and printing "mention by carol" — carol only asked dan to review;
# zed is the one who said "@self". The exact r5 P2-2 bug this file's own
# fix-round-5 comment above describes, reopened by one extra name in a
# whitelist that is load-bearing: get ONE member wrong and the whole
# fix regresses silently, since `case` falls through to the SAME
# whole-flat-string scan for anything left in the list, not to "".
#
# 🔴 BODY FROM THE SELECTED EVENT ONLY (P2-2, 2026-09-14 fix-round-7 review
# — read before bringing back any whole-page body scan). Even with the list
# down to `commented|reviewed`, the body was still the LAST string body on
# the page, not the selected event's own: an Approve with no text is a
# `reviewed` event with `"body":null` (real cli/cli data, 2026-09-14; see
# tests/fixtures/github-timeline-approve-null-body.json), which that scan
# skipped straight past to the previous comment's "@me" — credited to the
# approver. The page is now split by _wg_timeline_events, a quote- and
# depth-aware splitter, which also hands back each event's OWN top-level
# body (empty for null/absent). That makes the `},{`-in-a-body fallback
# (P3-1, fix-round-4) unnecessary: a `},{` inside a string or a nested
# `labels:[{..},{..}]` no longer splits an event in the first place.
_wg_last_actor_in_body() {
  local body="$1" flat events line evline evbody actor event us
  us="$(printf '\037')"
  flat="$(printf '%s' "$body" | tr -d '\n')"
  [ -n "$flat" ] || return 1
  events="$(_wg_timeline_events "$flat")"
  [ -n "$events" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    evbody="${line%%"$us"*}"
    evline="${line#*"$us"}"
    actor="$(printf '%s' "$evline" | grep -oE '"actor":\{"login":"[^"]*"' | head -n1 | sed -E 's/.*"login":"([^"]*)"$/\1/')"
    [ -n "$actor" ] || actor="$(printf '%s' "$evline" | grep -oE '"user":\{"login":"[^"]*"' | head -n1 | sed -E 's/.*"login":"([^"]*)"$/\1/')"
    [ -n "$actor" ] || continue
    event="$(printf '%s' "$evline" | grep -oE '"event":"[^"]*"' | head -n1 | sed -E 's/.*"event":"([^"]*)"$/\1/')"
    __WG_LOOKUP_ACTOR="$actor"
    # $evbody is THIS event's own top-level body (see the 🔴 P2-2
    # fix-round-7 note above) — never another event's. Still gated on the
    # type (fix-round-5): only a comment or review is text its author wrote.
    case "$event" in
      commented|reviewed) __WG_LOOKUP_BODY="$evbody" ;;
      *) __WG_LOOKUP_BODY="" ;;
    esac
    case "$event" in
      commented) __WG_LOOKUP_KIND="comment" ;;
      reviewed)  __WG_LOOKUP_KIND="review" ;;
      *)         __WG_LOOKUP_KIND="activity" ;;
    esac
    return 0
  done < <(printf '%s\n' "$events" | sed '1!G;h;$!d')
  return 1
}

# _wg_body_mentions_self <body> <self> -> 0 if <body> contains a
# word-bounded `@<self>` mention — the character immediately before `@`
# (if any) is not itself part of a login/word (rules out an email address
# like `x@bob`), and the character immediately after <self> (if any) is not
# a login character (rules out `@bob` matching inside `@bobby`). GitHub
# logins are `[A-Za-z0-9-]` only, so <self> needs no regex-escaping here.
_wg_body_mentions_self() {
  local body="$1" self="$2"
  [ -n "$self" ] && [ -n "$body" ] || return 1
  printf '%s' "$body" | grep -qE "(^|[^A-Za-z0-9_])@${self}([^A-Za-z0-9_-]|\$)"
}

# _wg_lookup_budget_ok -> 0 while this poll may still spend a lookup: fewer
# than 50 done so far (P2-4, bounded — candidates arrive in the order the
# asc-sorted search results streamed them, i.e. oldest-unseen-first as of
# P1-2, 2026-09-13 fix-round-3 review), AND the last observed
# X-RateLimit-Remaining (if any) is not already under 100.
_wg_lookup_budget_ok() {
  [ "${__WG_LOOKUPS_DONE:-0}" -lt 50 ] || return 1
  case "${__WG_LOOKUP_RATE_REMAINING:-}" in
    ''|*[!0-9]*) return 0 ;;
    *) [ "$__WG_LOOKUP_RATE_REMAINING" -ge 100 ] ;;
  esac
}

# _wg_lookup_and_count <org> <repo> <number> -> 0 with $__WG_LOOKUP_ACTOR /
# $__WG_LOOKUP_KIND set on success. 1 when the budget is spent OR the lookup
# itself failed — EITHER WAY the caller (_wg_process) must still emit the
# event (actor "unknown", kind's best guess) rather than drop it; a lookup
# failure classified as rate-limit also stops the REST of this poll's
# lookups (same effect as the rate-remaining check above) and sets
# $__WG_BACKOFF, same as a search-query rate limit would.
_wg_lookup_and_count() {
  local org="$1" repo="$2" number="$3"
  _wg_lookup_budget_ok || { __WG_LOOKUPS_SKIPPED=$((__WG_LOOKUPS_SKIPPED + 1)); return 1; }
  __WG_LOOKUPS_DONE=$((__WG_LOOKUPS_DONE + 1))
  _wg_latest_actor "$org" "$repo" "$number" && return 0
  __WG_LOOKUPS_SKIPPED=$((__WG_LOOKUPS_SKIPPED + 1))
  if [ "$__WG_LOOKUP_LAST_KIND" = "rate-limit" ]; then
    __WG_LOOKUP_RATE_REMAINING=0
    __WG_BACKOFF=1
  fi
  if [ "${__WG_LOOKUP_WARNED:-0}" -ne 1 ]; then
    __WG_LOOKUP_WARNED=1
    log_warn "github:$org — activity lookup failed ($__WG_LOOKUP_LAST_KIND): $__WG_LOOKUP_LAST_REASON"
  fi
  return 1
}

# _wg_process <tsv> <org> <seen_file> <events_file> -> for every NEW
# (not-yet-seen) row: prints the wake line, appends a JSON record, appends
# the dedup key to the seen file. Folds updated_at into the running-max
# global $__WG_MAX_UPDATED for EVERY row read (P1-3, 2026-09-13 fix-round-1
# review — the cursor has to track the max updated_at this poll actually
# SAW, not just the ones that turned out new, or a poll that only re-saw
# already-handled rows near a boundary would never advance the cursor at
# all and requery the same window forever). Bumps $__WG_EVENTS only for
# genuinely new rows whose actual actor is NOT self (P1-2/P2-4/P2-5,
# 2026-09-13 fix-round-2 review — see WHAT "KIND" (AND "WHO") HONESTLY MEANS
# in the file header for the self-exclusion / lookup design). bash 3.2: no
# associative arrays, no mapfile — a plain while/read loop over a variable
# via a here-string. `local LC_ALL=C` (P3-13, round-2 review): the
# `[[ … > … ]]` comparisons below are fixed-width-ISO8601 lexicographic, and
# must not depend on the caller's locale.
#
# 🔴 P2-2 (2026-09-13 fix-round-3 review): ONE query now, not two — see WHY
# POLL, NOT STREAM in the file header for why the separate `mentions:<self>`
# query was removed rather than fixed. `kind_query` is gone from this
# signature along with it; every row is processed the one way (formerly
# "the org branch").
_wg_process() {
  local tsv="$1" org="$2" seen_file="$3" events_file="$4"
  [ -n "$tsv" ] || return 0
  local LC_ALL=C
  local number updated login repo html_url is_pr title
  # shellcheck disable=SC2034  # _comments: consumed to keep the 8-field TSV
  # aligned (see _wg_fetch's jq filter); no longer read (P1-2/P2-4/P2-5 moved
  # self-exclusion off the comments-count-based lookup onto the timeline one).
  local _comments
  while IFS=$'\t' read -r number updated login repo html_url is_pr title _comments; do
    [ -n "$number" ] || continue

    if [ -z "$__WG_MAX_UPDATED" ] || [[ "$updated" > "$__WG_MAX_UPDATED" ]]; then
      __WG_MAX_UPDATED="$updated"
    fi

    # Already handled by an earlier poll — check this FIRST, before
    # spending a lookup on it.
    local key="${repo}|${number}|${updated}"
    grep -qxF "$key" "$seen_file" 2>/dev/null && continue

    # P1-4 (2026-09-13 fix-round-1 review): the seen-file is PER-ORG, and
    # every repo in an org restarts issue numbering at #1 — a bare
    # `${number}` match here used to read repo-B's brand-new #12 as a
    # "comment" on repo-A's #12.
    # P3-1 (2026-09-13 fix-round-3 review): `$repo` was spliced into this
    # ERE unescaped — a repo name is the only GitHub-legal character that's
    # also an ERE metachar (`.` = "any char"), so seen-file `axb|5|…` made a
    # BRAND NEW `a.b#5` misread as already-known. GitHub repo names are
    # `[A-Za-z0-9._-]` only, so `.` is the only character needing escaping.
    local repo_esc="${repo//./\\.}"
    local known=0
    grep -qE "^${repo_esc}\\|${number}\\|" "$seen_file" 2>/dev/null && known=1

    local kind actor
    if [ "$known" -eq 0 ]; then
      kind="opened"; actor="$login"
      if [ "$actor" = "$__WG_SELF" ]; then
        printf '%s\n' "$key" >> "$seen_file"   # my own new issue — seen, not an event
        continue
      fi
    elif _wg_lookup_and_count "$org" "$repo" "$number"; then
      actor="$__WG_LOOKUP_ACTOR"; kind="$__WG_LOOKUP_KIND"
      # P2-2: the fetched event's own body — text this file already has in
      # hand from the P1-1 timeline lookup, no extra request — overrides
      # `kind` to `mention` when it @-mentions self. Checked regardless of
      # `actor`: self-exclusion below still runs on WHO did it, not what
      # kind got assigned, so mentioning yourself is still not an event.
      if _wg_body_mentions_self "$__WG_LOOKUP_BODY" "$__WG_SELF"; then
        kind="mention"
      fi
      if [ "$actor" = "$__WG_SELF" ]; then
        printf '%s\n' "$key" >> "$seen_file"   # my own reply/review — handled, not an event
        continue
      fi
    else
      actor="unknown"; kind="comment"   # never dropped — see _wg_lookup_and_count
    fi

    local line json_rec
    line="$(printf 'github %s/%s#%s %s by %s: %s' "$org" "$repo" "$number" "$kind" "$actor" "$title")"
    log_done "$line"

    json_rec="$(printf '{"kind":%s,"org":%s,"repo":%s,"number":%s,"login":%s,"title":%s,"updated_at":%s,"html_url":%s,"is_pr":%s,"line":%s}' \
      "$(json_str "$kind")" "$(json_str "$org")" "$(json_str "$repo")" "$number" \
      "$(json_str "$actor")" "$(json_str "$title")" "$(json_str "$updated")" \
      "$(json_str "$html_url")" "$([ "$is_pr" = "1" ] && printf true || printf false)" \
      "$(json_str "$line")")"
    printf '%s\n' "$json_rec" >> "$events_file"
    # P3-11 (2026-09-13 fix-round-2 review): fed to _wg_status_write's own
    # per-poll artifact file — `artifact` must point at THIS poll's events,
    # not the whole accumulated log (see _wg_status_write's comment).
    __WG_EVENT_JSON_LINES="${__WG_EVENT_JSON_LINES:+$__WG_EVENT_JSON_LINES$'\n'}$json_rec"

    printf '%s\n' "$key" >> "$seen_file"
    __WG_EVENTS=$((__WG_EVENTS + 1))
    # P1-1 (2026-09-13 fix-round-1 review): fed to _wg_status_write's
    # `summary` field, which is the whole reason `clikae wait` on that file
    # has anything to print — see _wg_build_summary below for the cap.
    __WG_SUMMARY_LINES="${__WG_SUMMARY_LINES:+$__WG_SUMMARY_LINES$'\n'}$line"
  done <<EOF
$tsv
EOF
}

# _wg_build_summary <lines> <n> -> <lines> (newline-joined) verbatim if <n> is
# <= 10; otherwise the first 10 lines plus a `+N` line for the rest — the cap
# the brief's design decision (1) names, so a status file's `summary` field
# never grows unbounded on a very busy poll.
_wg_build_summary() {
  local lines="$1" n="$2" cap=10
  if [ "$n" -le "$cap" ]; then
    printf '%s' "$lines"
    return 0
  fi
  local head; head="$(printf '%s\n' "$lines" | head -n "$cap")"
  printf '%s\n+%d' "$head" "$((n - cap))"
}

# _wg_status_write <org> <poll_json_lines> <summary> -> write ONE burn-
# status-SHAPED file to $HOME/.clikae/logs/watch-github-<org>-<epoch>[-N]/
# status.json — burn_status_dir's OWN layout (lib/core/burn_status.sh), not
# a parallel one under $CLIKAE_HOME/state (P2-3, 2026-09-13 fix-round-2
# review: the old runs/<epoch>.json location was invisible to `clikae wait`
# no matter what you passed it — the run_id this file itself wrote wasn't
# one burn_status_resolve's patterns recognised, an existing-but-unresolved
# path wasn't tried verbatim, and a not-yet-existing one couldn't be "waited
# on to appear" either; a cockpit's only option was a hand-rolled
# `until [ -e ... ]` poll of the runs/ directory — the exact thing #41
# exists to replace). Writing here means the run_id THIS FILE prints
# (`watch-github-<org>-<epoch>`) is also the one `clikae wait` resolves, via
# burn_status_resolve's own "anything else -> literal run-directory name"
# fallback — no change needed there. `clikae wait --latest <prefix>` (see
# wait.sh) covers the epoch a caller can't know in advance.
#
# `-N` (P3-10): two polls landing in the same second (cron and a manual
# --once overlapping) would otherwise collide on the SAME directory name —
# a counter suffix makes every run's own directory unique instead of the
# second one silently overwriting the first. Rotated to the newest 200
# afterward (_wg_runs_rotate) — plus burn's own day-based sweep now also
# globs these dirs (P3-3, 2026-09-13 fix-round-3 review — see
# _burn_sweep_old_logs in burn.sh), run from `clikae burn` OR `clikae
# clean`, whichever happens first.
#
# `artifact` (P3-11): THIS poll's own events, written to
# <run_dir>/events.jsonl — not $CLIKAE_HOME/logs/watch-github-<org>/
# events.jsonl, the ACCUMULATED durable log (still written by _wg_process
# directly; unrelated to this file). A consumer reading `artifact` off a
# wake should see what just happened, not the org's entire history.
#
# Same field set/escaping as burn's own status.json plus `summary`; write-
# then-rename so `clikae wait` (polling every second) never reads a
# half-written file.
_wg_status_write() {
  local org="$1" poll_json_lines="$2" summary="$3" now run_id run_dir n=1
  now="$(date +%s 2>/dev/null || echo 0)"
  run_id="watch-github-$org-$now"
  while [ -d "$(burn_status_dir "$run_id")" ]; do
    n=$((n + 1))
    run_id="watch-github-$org-$now-$n"
  done
  run_dir="$(burn_status_dir "$run_id")"
  mkdir -p "$run_dir" 2>/dev/null || return 0
  [ -n "$poll_json_lines" ] && printf '%s\n' "$poll_json_lines" > "$run_dir/events.jsonl" 2>/dev/null
  {
    printf '{"ok":true,"engine":%s,"tank":%s,"artifact":%s,"artifact_bytes":null,"reason":%s,"reset":null,"rerouted_from":[],"elapsed_s":0,"run_id":%s,"state":%s,"started_at":%s,"updated_at":%s,"pid":%s,"log":null,"reset_at":null,"summary":%s}\n' \
      "$(json_str "github")" "$(json_str "$org")" "$(json_str "$run_dir/events.jsonl")" \
      "$(json_str "github-events")" "$(json_str "$run_id")" \
      "$(json_str "done")" "$now" "$now" "$$" "$(json_str "$summary")"
  } > "$run_dir/status.json.tmp" 2>/dev/null && mv -f "$run_dir/status.json.tmp" "$run_dir/status.json" 2>/dev/null || true
  _wg_runs_rotate "$org"
}

# _wg_runs_rotate <org> -> keep only the newest 200 watch-github-<org>-*
# run directories under $HOME/.clikae/logs (P3-10) — a count-based floor
# independent of burn.sh's own day-based sweep (_burn_sweep_old_logs, which
# now also globs `watch-github-*`, P3-3), which only runs when `clikae
# burn` or `clikae clean` actually gets invoked, not on every poll. Sorted
# by mtime (not name — no assumption about epoch digit width).
_wg_runs_rotate() {
  local org="$1" base="$HOME/.clikae/logs" d keep=200 i=0
  [ -d "$base" ] || return 0
  while IFS= read -r d; do
    i=$((i + 1))
    if [ "$i" -gt "$keep" ]; then rm -rf "$d" 2>/dev/null; fi
  done < <(
    for d in "$base/watch-github-$org-"*; do
      # Only run directories (fix-round-7 P2-3): for org `foo`, this glob
      # also matches org `foo-bar`'s DURABLE log dir, which has no
      # status.json and the oldest mtime of all — first to be rotated out.
      [ -f "$d/status.json" ] || continue
      printf '%s\t%s\n' "$(file_mtime "$d" 2>/dev/null || echo 0)" "$d"
    done | sort -rn | cut -f2-
  )
  return 0
}

# _wg_events_rotate <file> -> keep the durable events.jsonl (P3-12) under
# 10MB — the newest tail, byte-bounded then trimmed to a whole line so the
# survivor is still valid one-JSON-object-per-line. Same shape as the
# seen-file cap just above: mktemp+mv, never a fixed .tmp name.
_wg_events_rotate() {
  local f="$1" max=$((10 * 1024 * 1024)) sz tmp
  [ -f "$f" ] || return 0
  # Every poll (fix-round-7 P2-3): an append never moves the directory's
  # own mtime, and day-based retention reads exactly that. Belt to
  # _burn_sweep_old_logs' own status.json check.
  touch "${f%/*}" 2>/dev/null || true
  sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
  [ "$sz" -gt "$max" ] || return 0
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 0
  tail -c "$max" "$f" 2>/dev/null | tail -n +2 > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" 2>/dev/null
  return 0
}

# --- one poll ---------------------------------------------------------------

# _wg_poll_one_query <org> <since> <seen_file> <events_file> -> paginate the
# org query (the only one — see P2-2, 2026-09-13 fix-round-3 review, in the
# file header for why the separate `mentions:<self>` query is gone) up to 5
# pages of 100 (P2-7), ASCENDING
# (P1-2, 2026-09-13 fix-round-3 review — see CURSOR MONOTONICITY / BACKLOG in
# the file header), stopping on a short page — fewer than per_page rows means
# we've reached the newest matching row, i.e. "now", and there is no next
# page (the query itself already filters `updated:>=since`, so a short page
# is a reliable end-of-results signal in ascending order; no separate
# lower-bound check is needed the way desc order needed one). On a failed
# page (P2-5/P2-6): sets $__WG_OK=0 always; a rate-limit-classified failure
# also sets $__WG_BACKOFF=1, a permanent one (missing scope, SAML, bad org
# — see _wg_classify_error) sets $__WG_PERMANENT=1/$__WG_PERMANENT_REASON
# and the caller (cmd_watch_github) exits rather than ever backing off on
# it. Either way, pages already processed already folded their rows into
# $__WG_MAX_UPDATED via _wg_process, so a failure on page 3 still leaves the
# cursor able to advance to what pages 1-2 saw (never past a page that
# failed to read).
#
# 🔴 Truncation (page 6+ exists) sets $__WG_TRUNCATED=1 for the WARN/summary
# wording ONLY — it does NOT need a special cursor formula any more. In
# ascending order, $__WG_MAX_UPDATED (folded in by _wg_process from every
# row this poll actually read, truncated or not) already IS "the last row
# this poll processed" — see _wg_poll's cursor computation, which now uses
# the SAME formula in both cases. That symmetry is the fix: round 2 needed
# an $__WG_TRUNCATED_OLDEST override specifically because desc order made
# $__WG_MAX_UPDATED equal to page 1's NEWEST row, which was wrong to resume
# from; asc order never has that problem, so the override is gone, not
# renamed.
_wg_poll_one_query() {
  local org="$1" since="$2" seen_file="$3" events_file="$4"
  local q page=1 tsv page_n
  q="$(_wg_query_org "$org" "$since")"
  while :; do
    # Called DIRECTLY, never through `tsv="$(...)"` — see the 🔴 note on
    # _wg_fetch_classified's own definition for why a subshell would lose
    # its global side effects. `never a bare cmd; rc=$?` still applies
    # (bin/clikae runs under `set -eo pipefail`): the `!` here is that
    # guard, same reasoning burn.sh's own tank-lock acquire documents at
    # length (search this repo for "never a bare").
    if ! _wg_fetch_classified "$q" "$page"; then
      __WG_OK=0
      case "$__WG_LAST_KIND" in
        rate-limit)
          __WG_BACKOFF=1
          # P3-7 (2026-09-13 fix-round-2 review): _wg_classify_error folds a
          # bare 5xx into "rate-limit" too (backing off is the right MOVE for
          # both), but "rate-limited" is a false claim about a 500/503 — say
          # which actually happened.
          case "$__WG_LAST_REASON" in
            *'HTTP 5'[0-9][0-9]*) log_warn "GitHub is having problems on the org query — backing off. ($__WG_LAST_REASON)" ;;
            *) log_warn "GitHub search rate-limited on the org query — backing off. ($__WG_LAST_REASON)" ;;
          esac
          ;;
        permanent)
          if [ "${__WG_PERMANENT:-0}" -ne 1 ]; then
            __WG_PERMANENT=1
            __WG_PERMANENT_REASON="$__WG_LAST_REASON"
          fi
          ;;
        *)
          log_warn "gh api search/issues failed on the org query: $__WG_LAST_REASON"
          ;;
      esac
      return 0
    fi
    tsv="$__WG_LAST_TSV"
    _wg_process "$tsv" "$org" "$seen_file" "$events_file"

    page_n="$(printf '%s\n' "$tsv" | grep -c . || true)"
    [ "$page_n" -ge 100 ] || return 0      # empty or short page: caught up to now

    page=$((page + 1))
    if [ "$page" -gt 5 ]; then
      log_warn "github:$org — org query has +more, will catch up next poll."
      # See the 🔴 note above the function: no special cursor handling
      # needed here any more — $__WG_MAX_UPDATED already reflects the last
      # row this poll read, and _wg_poll's cursor formula uses it either way.
      __WG_TRUNCATED=1
      return 0
    fi
  done
}

# _wg_tail_sweep_counter_file <org> -> path tracking how many polls have run
# since the last tail sweep (P1-1, 2026-09-14 fix-round-4 review). Schedule
# UNCHANGED by the round-5 window fix below — read the 🔴 TAIL SWEEP WINDOW
# note above CURSOR SEMANTICS before touching either this or the window fix:
# an EVERY-POLL schedule was tried first and reverted (broke every
# multi-poll test built on the canned-response-by-call-number `gh` stub —
# `_gh_stub_install`'s single "org" call counter has no notion of a sweep
# call vs a main-query call, so a sweep on every poll silently consumed the
# NEXT poll's canned response). The schedule staying poll-count-based, not
# request-count-based, is why that collision cannot recur.
_wg_tail_sweep_counter_file() { printf '%s/%s.sweepn\n' "$(_wg_state_dir)" "$1"; }

# _wg_poll_lastrun_file <org> -> path recording the epoch of the PREVIOUS
# poll (any poll, not only ones that swept), persisted BESIDE the cursor
# (P2-1, 2026-09-14 fix-round-5 review). No longer feeds the sweep window
# (see _wg_sweep_at_file below, P2-1 fix-round-6) — kept as its own
# independent per-poll gap measurement.
_wg_poll_lastrun_file() { printf '%s/%s.lastrun\n' "$(_wg_state_dir)" "$1"; }

# _wg_sweep_at_file <org> -> path recording the epoch the last TAIL SWEEP
# actually completed at (never written on a failure, see _wg_tail_sweep
# below), persisted beside the cursor (P2-1, 2026-09-14 fix-round-6
# review; since fix-round-7 P2-1 the epoch the sweep STARTED at). Read
# directly by _wg_tail_sweep_window: window = max(300s, now - sweepat) +
# 300s overlap — a MEASURED span, replacing round-5's sweep_n *
# one-poll's-own-gap INFERENCE (see the 🔴 TAIL SWEEP WINDOW note above
# CURSOR SEMANTICS in the file header for why that inference collapsed
# the moment polling wasn't evenly spaced — a back-off recovery poll, or
# a hand-run --once between two cron firings).
_wg_sweep_at_file() { printf '%s/%s.sweepat\n' "$(_wg_state_dir)" "$1"; }

# _wg_sane_epoch <candidate> <now> -> <candidate> on stdout if it parses as
# a positive integer no later than <now>; nothing (rc 1) otherwise (P3,
# 2026-09-14 fix-round-6 review). Shared by `.lastrun` and `.sweepat`: `0`
# is the EXACT sentinel `date +%s 2>/dev/null || echo 0` itself writes when
# `date` fails outright, and a value greater than `now` can only be a
# foreign/corrupted file or a clock that jumped backward since it was
# written — either way, subtracting it from `now` must not be trusted as a
# real elapsed span (a stray `0` alone turned into a multi-billion-second
# window in the round-6 review's own probe). Both read as "missing", same
# as no file at all — never as "since the epoch".
_wg_sane_epoch() {
  local v="$1" now="$2"
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "$v" -gt 0 ] && [ "$v" -le "$now" ] || return 1
  printf '%s' "$v"
}

# _wg_poll_measure_gap <org> -> sets $__WG_POLL_GAP to the real wall-clock
# seconds since the PREVIOUS poll of this org (any poll — main query ran,
# whether or not it swept), or empty on the very first poll ever (no prior
# timestamp to compare against, or a `.lastrun` _wg_sane_epoch rejects).
# Always updates the lastrun file to now, so the NEXT poll's own gap is
# measured against THIS one. Called unconditionally, once per _wg_poll,
# near the top.
_wg_poll_measure_gap() {
  local org="$1" lastrun_file now prev
  lastrun_file="$(_wg_poll_lastrun_file "$org")"
  now="$(date +%s 2>/dev/null || echo 0)"
  __WG_POLL_GAP=""
  if [ -f "$lastrun_file" ]; then
    prev="$(cat "$lastrun_file" 2>/dev/null)"
    prev="$(_wg_sane_epoch "$prev" "$now")" || prev=""
    if [ -n "$prev" ] && [ "$now" -gt "$prev" ]; then
      __WG_POLL_GAP=$((now - prev))
    fi
  fi
  printf '%s\n' "$now" > "${lastrun_file}.tmp" 2>/dev/null && mv -f "${lastrun_file}.tmp" "$lastrun_file" 2>/dev/null || true
}

# _wg_tail_sweep_window <org> -> the lag-window size in seconds for THIS
# sweep (stdout). window = max(300s, now - sweepat), where <sweepat> is
# `.sweepat`'s own value (the epoch the last sweep actually completed at —
# _wg_sane_epoch-checked against `now`, same guard `.lastrun` gets) — a
# span MEASURED directly, not sweep_n polls times one of their gaps
# (P2-1, 2026-09-14 fix-round-6 review — read the 🔴 TAIL SWEEP WINDOW
# note above CURSOR SEMANTICS in the file header before touching this
# again). No `.sweepat` yet (the very first sweep this org has ever had,
# or one _wg_sane_epoch rejects) means no measurement exists — window
# stays at the 300s floor, matching the original fixed margin. Since
# fix-round-7 P3-3 that only happens when _wg_poll could not write its
# baseline: every poll records one when `.sweepat` is missing or insane.
#
# 🔴 PLUS A FIXED 300s OVERLAP (P2-1, 2026-09-14 fix-round-7 review — read
# before trimming the `+ 300` below as "double counting the floor"). The
# previous sweep at S1 read what the index showed AT S1; a row updated just
# before S1 but indexed just after it is already behind the main cursor, so
# only the NEXT sweep can find it. Without the overlap that sweep's lower
# bound is cursor - (S2 - S1), and an active org's cursor is ~S2 — so the
# bound lands at ~S1, just ABOVE that row, and it is gone for good (proven
# in the review: 11/40 rows delivered at --interval 60 with 240s index lag;
# the SEAM test in watch-github.bats). The floor never helped there: it only
# applies while now - sweepat <= 300s. The overlap makes every sweep's
# lower bound <= S1 - 300s in GitHub's own clock, whatever the local clock
# says: the cursor is a GitHub timestamp no later than GitHub's "now", and
# now - sweepat is a DURATION, identical on both clocks. So every row whose
# index lag is <= 300s is re-read by at least one sweep after it became
# visible. Re-reads cost no duplicate events (the seen-file dedups them),
# only the rows in that extra 300s — at most one extra page per sweep while
# an org does <= 100 updates per 5 minutes.
_wg_tail_sweep_window() {
  local org="$1" now sweepat_file sweepat window=300 elapsed
  now="$(date +%s 2>/dev/null || echo 0)"
  sweepat_file="$(_wg_sweep_at_file "$org")"
  if [ -f "$sweepat_file" ]; then
    sweepat="$(cat "$sweepat_file" 2>/dev/null)"
    sweepat="$(_wg_sane_epoch "$sweepat" "$now")" || sweepat=""
    if [ -n "$sweepat" ]; then
      elapsed=$((now - sweepat))
      [ "$elapsed" -gt "$window" ] && window="$elapsed"
    fi
  fi
  printf '%s' "$((window + 300))"
}

# _wg_tail_sweep <org> <cursor> <seen_file> <events_file> -> a bounded,
# separate re-read of the window BELOW <cursor> (P1-1, 2026-09-14
# fix-round-4 review; window sizing revised P2-1, 2026-09-14 fix-round-5
# and again fix-round-6 review; read direction/pagination revised P2-2,
# 2026-09-14 fix-round-6 review — read the 🔴 notes in the file header
# before touching this). Catches a row whose updated_at is old enough to
# sit behind the main cursor but only just became visible in GitHub's
# search index (documented indexing lag) — WITHOUT lagging the main
# cursor itself, which is what let a >=500-row/300s window pin it forever
# (see CURSOR MONOTONICITY / BACKLOG). Run by _wg_poll, once every N=5
# polls or right after a truncated one — schedule UNCHANGED by this
# round's fix; ALWAYS after the main cursor is already computed and
# persisted from THIS poll's own $__WG_MAX_UPDATED alone — this
# function's own use of $__WG_MAX_UPDATED (folded in by _wg_process, same
# as any other query) is scratch, discarded by the caller, never fed back
# into the cursor file. Found rows go through the same
# seen-file/_wg_process dedup as any other row, so they are announced and
# logged exactly once, whichever query finds them first.
#
# 🔴 order=asc, PAGINATED (P2-2, 2026-09-14 fix-round-6 review — round 5's
# own review named this fix and it was not taken: `order=desc` reads the
# window's NEWEST end first, and a busy org's own recent activity, already
# in the seen-file from earlier polls, fills a single desc page before the
# sweep ever reaches the window's older rows. ⚠️ Corrected (P3-1,
# fix-round-7 review): late-indexed rows do NOT sit at the old end — the
# main cursor walks forward, so they are spread across the whole window;
# only the MOST overdue ones are oldest. ASCENDING (same as the main
# query) makes truncation less bad, not harmless: a truncated sweep still
# drops whatever late rows sit in its unread newer part (see the warning
# below). Reading oldest-first makes a single page usually enough — but not
# guaranteed enough on its own on
# a busy org, so this paginates within the SAME 5-page/100-per-page budget
# _wg_poll_one_query already uses, stopping on a short page the same way.
# "lag window truncated" is now reported ONLY when that 5-page cap is
# actually hit (proven un-triggerable before this fix — see the P3 note in
# the tests) — bounded to at most 5 extra requests per poll, the same cap
# the main query already accepts, and it can never itself stall anything
# (a truncated sweep still completes; see below). A sweep failure
# classified as rate-limit counts toward back-off exactly like a
# main-query failure would (P3-4, 2026-09-14 fix-round-5 review) — an org
# already being rate-limited otherwise kept taking one more doomed request
# every time the schedule fired, back-off or not.
_wg_tail_sweep() {
  local org="$1" cursor="$2" seen_file="$3" events_file="$4"
  local epoch since q tsv page_n window page=1 truncated=0 started
  epoch="$(_limit_iso_epoch "$cursor" "")"
  [ -n "$epoch" ] || return 0
  # The instant this sweep starts reading — what `.sweepat` records below
  # (P2-1, fix-round-7): a row that becomes visible while pages 2..5 are
  # still being fetched was NOT necessarily covered by page 1, so the next
  # sweep must measure from here, not from when this one finished.
  started="$(date +%s 2>/dev/null || echo 0)"
  window="$(_wg_tail_sweep_window "$org")"
  since="$(_wg_iso_from_epoch "$((epoch - window))")"
  [ -n "$since" ] || return 0
  q="$(_wg_query_org "$org" "$since")"
  while :; do
    if ! _wg_fetch_classified "$q" "$page" asc; then
      case "$__WG_LAST_KIND" in
        rate-limit) __WG_BACKOFF=1 ;;
      esac
      log_warn "github:$org — lag sweep failed, skipping this poll's sweep: $__WG_LAST_REASON"
      return 0
    fi
    tsv="$__WG_LAST_TSV"
    _wg_process "$tsv" "$org" "$seen_file" "$events_file"
    page_n="$(printf '%s\n' "$tsv" | grep -c . || true)"
    [ "$page_n" -ge 100 ] || break
    page=$((page + 1))
    if [ "$page" -gt 5 ]; then
      truncated=1
      break
    fi
  done
  [ "$truncated" -eq 1 ] && log_warn "github:$org — lag window truncated (>=500 updates in the last ${window}s); skipping the rest, not stalling."
  # Never written on a failed sweep (the early `return 0` above skips
  # this) — a sweep that never ran must not reset the clock on ground it
  # never covered; the NEXT sweep's window still needs to reach back to
  # the last one that actually completed.
  local sweepat_file; sweepat_file="$(_wg_sweep_at_file "$org")"
  printf '%s\n' "$started" > "${sweepat_file}.tmp" 2>/dev/null \
    && mv -f "${sweepat_file}.tmp" "$sweepat_file" 2>/dev/null || true
  return 0
}

# _wg_poll <org> [since_override] -> runs the org query (paginated; P2-2,
# 2026-09-13 fix-round-3 review — the separate mentions query is gone, see
# the file header), updates $__WG_EVENTS / $__WG_BACKOFF / $__WG_OK
# (globals, set here — see
# lib/core/wake.sh's _wake_targetsv for the same "sets globals instead of
# forking a subshell" idiom this follows). Never advances the cursor past a
# page that failed to read; the new cursor is EXACTLY the max updated_at
# actually processed this poll — no lag (P1-1, 2026-09-14 fix-round-4
# review; see the CURSOR SEMANTICS note above _wg_query_org and the 🔴 note
# in the file header for why a lag subtracted straight off this value was
# a permanent-stall bug, not a safety margin). Search-index lag is instead
# covered by _wg_tail_sweep, run separately below, which never touches this
# value. <since_override>, when non-empty, is used ONLY for a cold start
# (no persisted cursor, or an empty cursor file) — see cmd_watch_github's
# --since flag.
_wg_poll() {
  local org="$1" since_override="${2:-}"
  __WG_EVENTS=0
  __WG_BACKOFF=0
  __WG_OK=1
  __WG_PERMANENT=0
  __WG_PERMANENT_REASON=""
  __WG_MAX_UPDATED=""
  __WG_SUMMARY_LINES=""
  __WG_EVENT_JSON_LINES=""
  __WG_TRUNCATED=0
  # P2-4: the per-poll activity-lookup budget (_wg_lookup_and_count) — shared
  # across BOTH queries below, spent in the order results streamed in
  # (oldest-first, per the search API's own asc sort — P1-2, 2026-09-13
  # fix-round-3 review).
  __WG_LOOKUPS_DONE=0
  __WG_LOOKUPS_SKIPPED=0
  __WG_LOOKUP_RATE_REMAINING=""
  __WG_LOOKUP_WARNED=0

  # P2-11: one mkdir-lock around the whole read-poll-write section, so cron
  # running `--once` and a person ALSO running `--once` (or the live loop)
  # never interleave a seen-file compaction or a cursor write with each
  # other. A poll that can't get the lock inside 30s is reported as a
  # failed poll (ok=0) rather than proceeding unguarded.
  if ! _wg_lock_acquire "$org"; then
    __WG_OK=0
    log_warn "github:$org — could not acquire the poll lock (another watch github --once running concurrently?); skipping this poll."
    return 0
  fi

  mkdir -p "$(_wg_state_dir)" "$(_wg_log_dir "$org")" 2>/dev/null || true

  # P2-1 (2026-09-14 fix-round-5 review): measured EVERY poll, whether or
  # not this one ends up sweeping — see _wg_tail_sweep_window's own comment
  # for why the estimate it feeds needs the most recent single-poll gap,
  # not only a gap measured on sweep polls.
  _wg_poll_measure_gap "$org"

  # P3-3 (2026-09-14 fix-round-7 review): no usable `.sweepat` (an org's
  # first poll ever, state from before `.sweepat` existed, or a value
  # _wg_sane_epoch rejects) used to leave the FIRST sweep at the bare 300s
  # floor — narrower than the four polls before it had covered, so a row
  # updated just before poll 1 and indexed after it was lost. Record THIS
  # poll's start as the baseline instead: nothing before it was ever read
  # by this watcher, so the first sweep measuring from here (plus its 300s
  # overlap) covers exactly what the polls since then could have missed.
  # Only ever written when missing — never moves an existing sweep's mark.
  local sweepat_file sweepat_now sweepat_cur
  sweepat_file="$(_wg_sweep_at_file "$org")"
  sweepat_now="$(date +%s 2>/dev/null || echo 0)"
  sweepat_cur="$(cat "$sweepat_file" 2>/dev/null || true)"
  if ! _wg_sane_epoch "$sweepat_cur" "$sweepat_now" >/dev/null && [ "$sweepat_now" -gt 0 ]; then
    printf '%s\n' "$sweepat_now" > "${sweepat_file}.tmp" 2>/dev/null \
      && mv -f "${sweepat_file}.tmp" "$sweepat_file" 2>/dev/null || true
  fi

  local seen_file events_file cursor_file since
  seen_file="$(_wg_seen_file "$org")"
  events_file="$(_wg_events_file "$org")"
  cursor_file="$(_wg_cursor_file "$org")"
  [ -f "$seen_file" ] || : > "$seen_file"
  since=""
  [ -f "$cursor_file" ] && since="$(cat "$cursor_file" 2>/dev/null)"
  # P2-11: an EMPTY cursor file (a half-written one from before the
  # write-then-rename fix, or any other foreign zero-byte file at that
  # path) must read as cold start, never as "no time bound at all" (which
  # used to mean a full org replay — see _wg_query_org's history above).
  [ -n "$since" ] || since="${since_override:-$(_wg_since_default)}"

  # P2-2 (2026-09-13 fix-round-3 review): ONE query now — see WHY POLL, NOT
  # STREAM in the file header for why the separate `mentions:<self>` query
  # was removed (not merely rate-limit-skipped, P3-9's old fix) rather than
  # kept running alongside this one.
  _wg_poll_one_query "$org" "$since" "$seen_file" "$events_file"

  # Never advance past an event a failed page might have contained. The new
  # cursor is EXACTLY the max updated_at actually processed this poll — no
  # lag; `>=` in the query plus the seen-file dedup absorb the one-row
  # overlap between polls (P1-1, 2026-09-14 fix-round-4 review — see CURSOR
  # SEMANTICS above _wg_query_org for why a lag subtracted straight off
  # this value was the permanent-stall bug, not a safety margin).
  local new_cursor=""
  if [ "$__WG_OK" -eq 1 ] && [ -n "$__WG_MAX_UPDATED" ]; then
    new_cursor="$__WG_MAX_UPDATED"
    printf '%s\n' "$new_cursor" > "${cursor_file}.tmp" 2>/dev/null && mv -f "${cursor_file}.tmp" "$cursor_file" 2>/dev/null || true
  fi

  # TAIL SWEEP (P1-1, 2026-09-14 fix-round-4 review): once every N=5 polls,
  # or right after a truncated one (more likely to have left recent rows
  # behind an index-lag boundary) — see _wg_tail_sweep's own comment.
  # SCHEDULE unchanged by the round-5/round-6 window fixes (P2-1, read the
  # 🔴 TAIL SWEEP WINDOW note in the file header before touching this
  # again): an every-poll schedule was tried first and reverted, because
  # it broke every multi-poll bats test built on the
  # canned-response-by-call-number `gh` stub (a sweep is a real
  # search/issues call too, and that stub's call counter cannot tell one
  # apart from the next poll's own main query). $sweep_n only ever decides
  # WHEN this schedule fires now — the WIDTH _wg_tail_sweep computes once
  # it does fire comes from `.sweepat` (_wg_tail_sweep_window), not from
  # this counter (P2-1, 2026-09-14 fix-round-6 review). Never touches
  # $new_cursor above, so it can never re-create the stall it replaces.
  # Skipped entirely on a failed poll: $new_cursor would be either empty
  # or stale, neither a sound base for the sweep's own window.
  if [ "$__WG_OK" -eq 1 ] && [ -n "$new_cursor" ]; then
    local sweep_count_file sweep_n=0
    sweep_count_file="$(_wg_tail_sweep_counter_file "$org")"
    [ -f "$sweep_count_file" ] && sweep_n="$(cat "$sweep_count_file" 2>/dev/null || echo 0)"
    case "$sweep_n" in ''|*[!0-9]*) sweep_n=0 ;; esac
    sweep_n=$((sweep_n + 1))
    if [ "$__WG_TRUNCATED" -eq 1 ] || [ "$sweep_n" -ge 5 ]; then
      _wg_tail_sweep "$org" "$new_cursor" "$seen_file" "$events_file"
      sweep_n=0
    fi
    printf '%s\n' "$sweep_n" > "$sweep_count_file" 2>/dev/null || true
  fi

  # Cap the seen-file at the last 5,000 keys (brief's stated cap; P2-10 —
  # 500 was smaller than a single cold-start backlog could legitimately
  # be, so a busy first run would evict entries it had just written and
  # then re-announce them as "opened" a second time next poll). Atomic
  # `mktemp`+`mv` (P2-11): the old fixed `.tmp` name could collide with a
  # concurrent poll's own compaction even under the lock above if a
  # previous crashed run left a stale `.tmp` sitting there. Runs AFTER the
  # tail sweep above so a sweep-found row's own seen-file entry is covered
  # by the same compaction pass.
  if [ -f "$seen_file" ]; then
    local seen_tmp
    seen_tmp="$(mktemp "${seen_file}.XXXXXX" 2>/dev/null)" && \
      tail -n 5000 "$seen_file" > "$seen_tmp" 2>/dev/null && \
      mv -f "$seen_tmp" "$seen_file" 2>/dev/null
  fi

  # P3-12 (2026-09-13 fix-round-2 review): the durable events.jsonl had no
  # cap at all (unlike the seen-file, above) — an org active enough to need
  # this feature grows it forever. Rotated at 10MB, keeping the newest tail;
  # `tail -n +2` drops whatever partial line a byte-boundary `tail -c` cut
  # into, so the file that survives is still one JSON object per line.
  _wg_events_rotate "$events_file"

  # P1-1 (2026-09-13 fix-round-1 review): the wake itself — one status file
  # per poll that found something, so `clikae wait` has a terminal state to
  # read. Never on a zero-event poll (nothing for a cockpit to wake up FOR).
  if [ "$__WG_EVENTS" -ge 1 ]; then
    _wg_status_write "$org" "$__WG_EVENT_JSON_LINES" "$(_wg_build_summary "$__WG_SUMMARY_LINES" "$__WG_EVENTS")"
  fi

  _wg_lock_release "$org"
}

# --- the command --------------------------------------------------------------

_watch_github_help() {
  cat <<'EOF'
Usage: clikae watch github [--org <org>] [--interval <dur>] [--once] [--since <ts>]

Poll GitHub's search API for every issue/PR update in <org> — including
replies on issues YOU opened — and turn each new one into a wake line; a
comment/review whose own text @-mentions you is reported as kind `mention`
(see below):

  github <org>/<repo>#<n> <opened|comment|review|activity|mention> by <login>: <title>

Printed live (a foreground run) and appended, as flat JSON, to
$CLIKAE_HOME/logs/watch-github-<org>/events.jsonl — durable, so a cron job or
a Stop hook calling --once has something to read even with nobody watching.

The actual wake: every poll that finds >=1 new event writes ONE status file
(the same shape, same DIRECTORY LAYOUT, `clikae burn` writes) to
$HOME/.clikae/logs/watch-github-<org>-<epoch>/status.json — deliberately
$HOME, NOT $CLIKAE_HOME (P3-2, 2026-09-13 fix-round-3 review): this is the
one path in this feature that does not follow a $CLIKAE_HOME override —
burn's own status files never have either, and `clikae wait` only knows
how to resolve THAT layout. A sandboxed $CLIKAE_HOME therefore does not
sandbox this one file — so `clikae wait watch-github-<org>-<epoch>` (the
run_id this file itself
prints) or `clikae wait --latest watch-github-<org>` (no epoch needed)
returns 0 and prints the events, exactly like waiting on a burn. A cursor
(the exact max updated_at this poll actually processed — no lag; see below)
persists at $CLIKAE_HOME/state/watch-github/<org>.cursor; a small seen-file
next to it de-dupes (repo, issue number, updated_at) triples.

  --org <org>       GitHub org to watch. Default: inferred from this
                     directory's GitHub remote (`gh repo view`).
  --interval <dur>  Poll interval: bare seconds, or Ns/Nm/Nh/Nd. Default 10m.
                     Must be > 0; 0, negative, or unparseable exits 2.
  --once            Poll exactly once — for cron or a Stop hook, not a live
                     pane. No daemon, no tmux window of its own.
  --since <ts>      Cold-start lower bound (ISO8601, e.g.
                     2026-09-01T00:00:00Z), used ONLY when there is no
                     persisted cursor yet. Default: 24 hours ago.

Each query paginates up to 5 pages of 100 (order=asc, oldest unseen first),
so a poll that falls behind a busy org always makes forward progress:
a page cut short by the cap still leaves the cursor at the end of what it
actually read, so the NEXT poll picks up exactly there — no row is ever
permanently unreachable. A page beyond that cap prints "+more, will catch
up next poll" rather than blocking.

Every issue/PR update ALREADY SEEN before (a reply, review, label, or
assignee change) costs one more request to learn who actually did it and
whether it was you — bounded to 50 such lookups per poll, oldest-unseen-
first, and stopped early if GitHub's own rate limit drops under 100
remaining. Past that bound, the event is still reported (never silently
dropped), just with "by unknown" instead of a real login. If that fetched
comment/review's own text @-mentions you, `kind` is `mention` instead of
`comment`/`review` — a brand-new issue/PR whose own OPENING text mentions
you is not covered (no lookup happens for a fresh number; see docs/usage.md
for the full story), only a reply on something already seen.

Rate limits: normally 1 search request per poll (up to 5 when paginating to
the cap, plus up to 5 more for the tail sweep below, no more often than
every 5th poll or right after a truncated one; the search API allows
30/min authenticated), plus up to 50 activity lookups (above, up to 2
requests each against the core API's much larger budget). On a genuine
rate limit (429, or a 403 the response itself attributes to the rate
limit, or a 5xx) the interval backs off ×2 up to 1h — from a floor of 60s,
regardless of --interval — and one line is printed; the cursor is never
advanced past a page that failed to read. A poll cut short by the 5-page
cap prints "truncated: continuing next poll" — true: pagination runs
oldest-unseen first, so the cursor lands EXACTLY at the last row this poll
actually read, and the next poll's query starts exactly there. No backlog,
however large, can stall this permanently — it drains in bounded,
forward-only polls, because the cursor never regresses into a window it
has already re-read.

GitHub's search index itself lags real writes by some minutes; rather than
lagging the cursor above (which is what let a single dense poll pin it
forever — see CHANGELOG), that margin is covered by a separate, bounded
"tail sweep": once every 5 polls, or right after a truncated one, one or
more requests re-read the window below the cursor OLDEST FIRST — same
order as the main query — and deliver anything a poll may have missed
while it was still indexing (late-indexed rows can sit anywhere in that
window, not only at its old end, so a truncated sweep can still miss
some in the part it didn't read); a
small seen-file de-dupes whichever query finds a row first. The window is
the time since the last sweep STARTED (at least 300s) plus a fixed 300s
overlap with that sweep, so a row updated just before one sweep but
indexed just after it is re-read by the next — measured directly (an
epoch persisted beside the cursor), not
inferred from --interval or from how many polls elapsed, so cron's
`--once` is covered without needing to be told an interval, and a live
loop's own back-off (or recovery from one) is covered exactly, not
approximated from whichever single poll's gap happened to be shortest.
Reading paginates within the same 5-page/100-per-page budget the main
query uses; a window still not fully covered after that reports "lag
window truncated" and moves on rather than reading further — bounded to
at most 5 extra requests per poll, so it can never stall anything either.

A PERMANENT failure (missing OAuth scope, SAML enforcement, a bad org
name — any other 403, or a 404) is retried once, then reported and this
command exits 1 — it never enters back-off, since no amount of retrying
fixes a scope or SAML problem. `--once` returns 0 only when a poll actually
succeeded (events or none); 1 on any failure, permanent or not, so a cron
job can tell "quiet today" from "I've been failing silently".

Requires `gh` already logged in (whatever account that is — this never reads
or writes a token itself); exits 1 immediately if `gh auth status` fails.
EOF
}

# _wg_infer_org -> the owner login of this directory's GitHub remote, or
# empty. Best-effort; a caller with no --org and no inferable remote gets a
# clear usage error instead of a silent guess.
_wg_infer_org() {
  command -v gh >/dev/null 2>&1 || return 0
  gh repo view --json owner --jq .owner.login 2>/dev/null || true
}

cmd_watch_github() {
  local org="" interval_dur="10m" once=0 since_flag="" since_given=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)   _watch_github_help; return 0 ;;
      --org)       shift; [ $# -gt 0 ] || log_fail "--org needs a value"; org="$1"; shift ;;
      --interval)  shift; [ $# -gt 0 ] || log_fail "--interval needs a duration"; interval_dur="$1"; shift ;;
      --once)      once=1; shift ;;
      --since)     shift; [ $# -gt 0 ] || log_fail "--since needs an ISO8601 timestamp, e.g. 2026-09-01T00:00:00Z"
                   since_flag="$1"; since_given=1; shift ;;
      -*)          log_fail "Unknown flag: $1  (try: clikae watch github --help)" ;;
      *)           log_fail "Unexpected argument: $1  (try: clikae watch github --help)" ;;
    esac
  done

  # P3-15 (2026-09-13 fix-round-2 review): `--since ''` used to be silently
  # ACCEPTED and ignored (falling through to the 24h default) — indistinguishable
  # from never passing the flag at all. `$since_given` tells the two apart.
  if [ "$since_given" -eq 1 ]; then
    [ -n "$since_flag" ] || log_fail "--since: empty value  (e.g. 2026-09-01T00:00:00Z)"
    # P1-3 (2026-09-13 fix-round-1 review): only ever used for a COLD start
    # (no persisted cursor yet) — see _wg_poll's since_override. Validated
    # the same way an updated_at from GitHub itself is parsed
    # (lib/core/limit.sh's _limit_iso_epoch), so a caller gets a clear
    # refusal instead of a query GitHub's search API silently mis-parses.
    [ -n "$(_limit_iso_epoch "$since_flag" "")" ] \
      || log_fail "--since: not an ISO8601 timestamp: $since_flag  (e.g. 2026-09-01T00:00:00Z)"
  fi

  # P2-12 (2026-09-13 fix-round-1 review): _burn_parse_duration alone
  # accepts "0" as a perfectly valid duration (zero seconds) — it has no
  # opinion on whether zero makes SENSE for this particular caller. A live
  # loop's `sleep 0` would poll a 30 req/min endpoint at full speed, and
  # the same bug that let it through also let the back-off arithmetic
  # divide-by-nothing (`0 * 2 = 0` forever — see the floor below). Garbage
  # and negative values already failed _burn_parse_duration itself; both
  # paths now refuse with rc 2, not clikae's usual rc 1 (log_fail), so a
  # caller scripting around this can tell "bad flag" from "any other
  # failure" the same way `clikae wait`'s own exit codes are stratified.
  local interval_s
  if ! interval_s="$(_burn_parse_duration "$interval_dur")"; then
    log_err "--interval: not a duration: $interval_dur  (use e.g. 60, 60s, 10m, 1h)"
    return 2
  fi
  if [ "$interval_s" -le 0 ]; then
    log_err "--interval: must be greater than 0: $interval_dur"
    return 2
  fi

  command -v gh >/dev/null 2>&1 || log_fail "clikae watch github needs the 'gh' CLI on PATH."
  if ! gh auth status >/dev/null 2>&1; then
    log_err "gh is not logged in (gh auth status failed)."
    log_dim "  clikae watch github never reads or writes a token itself — it uses"
    log_dim "  whatever account 'gh auth login' already set up. Log in and retry."
    return 1
  fi

  __WG_SELF="$(gh api user --jq .login 2>/dev/null)" || true
  [ -n "$__WG_SELF" ] || log_fail "Could not resolve the authenticated GitHub login (gh api user)."

  [ -n "$org" ] || org="$(_wg_infer_org)"
  [ -n "$org" ] || log_fail "No --org given and none could be inferred from this directory's GitHub remote."
  validate_name org "$org"

  if [ "$once" -eq 1 ]; then
    _wg_poll "$org" "$since_flag"
    # P2-6: a permanent failure (missing scope, SAML, bad org — see
    # _wg_classify_error) is reported and failed outright, never retried
    # again beyond the ONE retry _wg_fetch_classified already spent.
    if [ "$__WG_PERMANENT" -eq 1 ]; then
      log_err "github:$org — giving up: ${__WG_PERMANENT_REASON:-a permanent error (see the warning above)}"
      return 1
    fi
    # P2-5: "0 new event(s)" is a SUCCESS claim — nothing to report is not
    # the same thing as "I read nothing because the query failed". The old
    # code printed this line and returned 0 unconditionally, so a cron job
    # calling --once could never tell "today was quiet" from "I've been
    # blind for three days" — exactly the failure mode issue #46 exists to
    # catch, reintroduced one layer up.
    if [ "$__WG_OK" -eq 1 ]; then
      # P1-1: an honest word for what just happened — the old WARN
      # ("will catch up next poll") was a claim nothing in the code backed
      # up; now that the cursor genuinely pins behind the unread tail (see
      # _wg_poll), this line is the one place a `--once` caller (a cron job,
      # a Stop hook) can actually see that a poll was cut short.
      local trunc_suffix=""
      [ "$__WG_TRUNCATED" -eq 1 ] && trunc_suffix=" (truncated: continuing next poll)"
      log_info "github:$org — $__WG_EVENTS new event(s) this poll.${trunc_suffix}"
      return 0
    fi
    log_err "github:$org — poll failed (see the warning above); not counted as 0 events."
    return 1
  fi

  log_info "Watching GitHub org $org as $__WG_SELF — polling every $(wake_human_left "$interval_s"). Ctrl-C to stop."
  local cur="$interval_s"
  while :; do
    _wg_poll "$org" "$since_flag"
    if [ "$__WG_PERMANENT" -eq 1 ]; then
      # P2-6: never enter back-off on a permanent failure — a live loop
      # backing off to 1h and printing "rate-limited" once an hour, forever,
      # for a missing OAuth scope is exactly the bug this fixes.
      log_err "github:$org — giving up: ${__WG_PERMANENT_REASON:-a permanent error (see the warning above)}"
      return 1
    fi
    if [ "$__WG_BACKOFF" -eq 1 ]; then
      # P2-12: back off from a FLOOR of 60s, not from whatever (possibly
      # tiny) --interval the caller set. Two reasons: `0 * 2 = 0` would
      # never back off at all if a zero interval ever reached here (now
      # impossible — see the --interval > 0 refusal above — but this stays
      # as a second, independent guard on the exact arithmetic that broke);
      # and a caller who set --interval 5s to watch something urgent still
      # deserves a back-off that actually throttles a rate-limited endpoint,
      # not 5/10/20/40s of continuing to hammer it.
      if [ "$cur" -lt 60 ]; then cur=60; else cur=$((cur * 2)); fi
      [ "$cur" -le 3600 ] || cur=3600
    else
      cur="$interval_s"
    fi
    sleep "$cur"
  done
}
