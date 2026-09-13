# shellcheck shell=bash
# lib/commands/watch_github.sh — `clikae watch github`: turn other people's
# replies / @mentions on GitHub into a wake event, the way `clikae watch
# <engine>` already turns "tank ran dry" into one (#46).
#
# WHY POLL, NOT STREAM. The token clikae runs as has no notifications scope
# (#46's own report), so the only signal available is the search API:
#   gh api search/issues -f q='org:<org> updated:><cursor> -author:<self>'
# — issues/PRs updated since the last poll, with your own activity excluded —
# plus a second query for `mentions:<self>` (which is NOT author-scoped, so a
# self-mention on a self-opened issue can still appear; filtered in code, see
# below). Two requests per poll, well inside the search API's 30 req/min.
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
#      under $CLIKAE_HOME/state/watch-github/<org>/runs/<epoch>.json
#      (_wg_status_write below), with `state:"done"`, `reason:"github-
#      events"`, `artifact:` pointing at this poll's events file, and
#      `summary:` one line per event (capped, see _wg_build_summary).
#      `clikae wait <that file>` returns 0 and PRINTS the summary — a
#      cockpit (or a Stop hook, or a person) blocks on it exactly the way it
#      already blocks on a burn. The durable
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
# WHAT "KIND" HONESTLY MEANS. The search API returns issue/PR-level rows, not
# per-comment ones — there is no cheap way, inside a 2-request budget, to ask
# "who commented, and was it a review?". So:
#   - a number never seen before (this org's seen-file, any prior poll) ->
#     "opened"
#   - a number seen before, updated again -> "comment" — this is also what a
#     PR REVIEW looks like from search/issues, since a review's HTTP surface
#     is invisible here; "review" is accepted as a `kind` value (the issue
#     text lists it) but this implementation never emits it — folding it into
#     "comment" is the honest choice over guessing from is-this-a-PR, which
#     would mislabel an ordinary PR comment as a review.
#   - a mentions:<self> hit -> "mention", UNLESS the issue's own `user.login`
#     (the only login the search API gives us) is <self> — that is how "a
#     comment by self is not an event" is satisfied for the one query where
#     self can appear (the org query already excludes author:<self> in the
#     query string itself). It is an approximation, not proof: item.user is
#     the ISSUE's author, not necessarily whoever's activity just bumped
#     updated_at, because search/issues has no per-event actor field. The
#     `login` printed in a "comment" wake line is the issue's author for the
#     same reason — it is what is available, not a claim about who replied.
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
# CURSOR MONOTONICITY / BACKLOG. `sort=updated -f order=desc` + pagination
# (P2-7, 2026-09-13 fix-round-1 review) means page 1 is always the NEWEST
# items first, so a cold start (or a poll that fell behind) surfaces today's
# events immediately instead of crawling forward from the org's oldest
# history — see _wg_poll_one_query.
#
# ⚠️ KNOWN GAP, not fixed here because it is a locked design decision (the
# brief's DESIGN DECISION (a), from the dispatcher): `-author:<self>` in the
# org query excludes every issue YOU opened from that query's results — which
# is exactly issue #46's own motivating example (a collaborator's reply on an
# issue the maintainer opened). Only an explicit @mention on such a reply
# reaches the mentions:<self> query instead. Catching a plain reply on your
# own issue would need a query scoped by `involves:<self>` (or dropping
# `-author:<self>`) rather than excluding your authorship outright — noted
# here and in the PR body/report rather than changed unilaterally.

# --- paths --------------------------------------------------------------

_wg_state_dir() { printf '%s/state/watch-github\n' "$CLIKAE_HOME"; }
_wg_log_dir()   { printf '%s/logs/watch-github-%s\n' "$CLIKAE_HOME" "$1"; }
_wg_cursor_file() { printf '%s/%s.cursor\n' "$(_wg_state_dir)" "$1"; }
_wg_seen_file()   { printf '%s/%s.seen\n'   "$(_wg_state_dir)" "$1"; }
_wg_events_file() { printf '%s/events.jsonl\n' "$(_wg_log_dir "$1")"; }
# _wg_runs_dir <org> -> where the burn-status-shaped file `clikae wait` reads
# lives for this org (P1-1, see the WHAT "WAKE" MEANS HERE note above).
_wg_runs_dir()    { printf '%s/%s/runs\n' "$(_wg_state_dir)" "$1"; }

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

# CURSOR SEMANTICS (P1-3, 2026-09-13 fix-round-1 review). The old query used
# `updated:>cursor` (strict) with the cursor set to the exact max updated_at
# seen — no margin. GitHub's search index lags real writes by some minutes
# (documented search-API behaviour); anything that lands in the index AFTER
# the poll that set the cursor, but whose updated_at is <= that cursor,
# would never appear in ANY future query — gone, silently, forever. Fixed by
# using `>=` (inclusive) with the cursor itself already lagged 300s behind
# the max seen (_wg_poll below) — the seen-file dedup (already needed for
# other reasons) absorbs the resulting overlap between polls for free.

# _wg_query_org <org> <since> -> the search string for "issues/PRs opened by
# others, replies on issues updated since <since>" (see the ⚠️ note above for
# what this does NOT catch). <since> is never empty — _wg_poll always
# resolves it to either the persisted cursor, --since, or the 24h default.
_wg_query_org() {
  local org="$1" since="$2"
  printf 'org:%s updated:>=%s -author:%s' "$org" "$since" "$__WG_SELF"
}

# _wg_query_mentions <org> <since> -> @mentions of self. Deliberately NOT
# author-excluded (a self-mention needs the login check in _wg_process, not
# the query, to be filtered — see the file header).
_wg_query_mentions() {
  local org="$1" since="$2"
  printf 'org:%s updated:>=%s mentions:%s' "$org" "$since" "$__WG_SELF"
}

# --- one query's worth of work ---------------------------------------------

# _wg_fetch <query> <page> <errfile> -> TSV on stdout (number, updated_at,
# login, repo, html_url, is_pr, title, comments — see the jq filter), gh's
# own exit code. `comments` (P2-9, see _wg_latest_comment_author below) is
# the issue's own comment COUNT as of this search hit — used to fetch the
# single latest comment's author with one extra request, not to print
# anything. gh's `--jq` is its own vendored implementation (gojq) — no
# external `jq` binary required, unlike lib/core/fleet_mcp.sh's merge
# (which genuinely needs the real jq for --slurpfile).
#
# `order=desc` + `per_page=100` (P2-7, 2026-09-13 fix-round-1 review): the
# old call took whatever the API's own default page (30, oldest-first via
# `order=asc`) handed back — a busy org's backlog could outrun a single
# poll forever. desc + 100/page + the pagination loop in _wg_poll (up to 5
# pages = 500 rows/poll/query) means the NEWEST items are always seen
# first, so a cold start (or a poll that falls behind) still surfaces
# today's events on poll #1 instead of queueing behind history.
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
  local query="$1" page="$2" errfile="$3"
  gh api search/issues --method GET -f q="$query" -f sort=updated -f order=desc \
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

# _wg_fetch_classified <query> <page> -> rc 0 on success, with the TSV in
# global $__WG_LAST_TSV. On failure, retries the SAME call ONCE if (and
# only if) the first failure classified as "permanent" (a transient blip
# that merely wore a permission-denied costume is cheap to rule out; a
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
  local query="$1" page="$2" errfile rc kind
  errfile="$(mktemp "${TMPDIR:-/tmp}/clikae-watch-github.XXXXXX")"
  rc=0
  __WG_LAST_TSV="$(_wg_fetch "$query" "$page" "$errfile")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$errfile"
    return 0
  fi
  kind="$(_wg_classify_error "$errfile")"
  if [ "$kind" = "permanent" ]; then
    rm -f "$errfile"
    errfile="$(mktemp "${TMPDIR:-/tmp}/clikae-watch-github.XXXXXX")"
    rc=0
    __WG_LAST_TSV="$(_wg_fetch "$query" "$page" "$errfile")" || rc=$?
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

# _wg_latest_comment_author <org> <repo> <number> <comments> -> the login of
# the LATEST comment on <org>/<repo>#<number>, or empty if it can't be
# determined. One `gh api` request per candidate (P2-9, 2026-09-13
# fix-round-1 review): fetching page=<comments> at per_page=1 on the
# comments endpoint returns exactly the last comment, never the whole
# thread — same "ask for only what's needed" discipline as the search
# calls themselves. Bounded the same way those are: only ever called for a
# row that already survived pagination (_wg_poll_one_query), so this never
# runs unboundedly many times in one poll.
_wg_latest_comment_author() {
  local org="$1" repo="$2" number="$3" comments="$4" errfile out
  case "$comments" in ''|*[!0-9]*|0) return 1 ;; esac
  errfile="$(mktemp "${TMPDIR:-/tmp}/clikae-watch-github.XXXXXX")"
  out="$(gh api "repos/$org/$repo/issues/$number/comments" --method GET \
    -f per_page=1 -f page="$comments" \
    --jq '.[0].user.login // empty' 2>"$errfile")" || out=""
  rm -f "$errfile"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# _wg_process <kind_query: org|mentions> <tsv> <org> <seen_file> <events_file>
# -> for every NEW (not-yet-seen) row: prints the wake line, appends a JSON
# record, appends the dedup key to the seen file. Folds updated_at into the
# running-max global $__WG_MAX_UPDATED for EVERY row read (P1-3, 2026-09-13
# fix-round-1 review — the cursor has to track the max updated_at this poll
# actually SAW, not just the ones that turned out new, or a poll that only
# re-saw already-handled rows near a boundary would never advance the
# cursor at all and requery the same window forever). Bumps $__WG_EVENTS
# only for genuinely new rows that are also NOT a comment self made on
# someone else's issue (P2-9, see the self-exclusion block below). bash
# 3.2: no associative arrays, no mapfile — a plain while/read loop over a
# variable via a here-string.
_wg_process() {
  local kind_query="$1" tsv="$2" org="$3" seen_file="$4" events_file="$5"
  [ -n "$tsv" ] || return 0
  local number updated login repo html_url is_pr title comments
  while IFS=$'\t' read -r number updated login repo html_url is_pr title comments; do
    [ -n "$number" ] || continue

    if [ -z "$__WG_MAX_UPDATED" ] || [[ "$updated" > "$__WG_MAX_UPDATED" ]]; then
      __WG_MAX_UPDATED="$updated"
    fi

    local kind
    if [ "$kind_query" = "mentions" ]; then
      # Self mentioning self (e.g. a self-authored issue that also contains
      # "@self") is not an event — the query itself can't exclude it (it has
      # no author filter; see _wg_query_mentions), only this login check can.
      [ "$login" != "$__WG_SELF" ] || continue
      kind="mention"
    else
      # P1-4 (2026-09-13 fix-round-1 review): the seen-file is PER-ORG, and
      # every repo in an org restarts issue numbering at #1 — a bare
      # `${number}` match here used to read repo-B's brand-new #12 as a
      # "comment" on repo-A's #12, and the dedup key below (before the
      # `repo|` prefix was added) would silently DROP repo-B's #12 entirely
      # whenever the two happened to share an updated_at second.
      if grep -qE "^${repo}\\|${number}\\|" "$seen_file" 2>/dev/null; then
        kind="comment"
      else
        kind="opened"
      fi
    fi

    local key="${repo}|${number}|${updated}"
    grep -qxF "$key" "$seen_file" 2>/dev/null && continue   # already handled

    # P2-9 (2026-09-13 fix-round-1 review): self-exclusion is per EVENT, not
    # per issue. `-author:<self>` in the org query (_wg_query_org) only
    # excludes issues YOU opened — it says nothing about a COMMENT you left
    # on someone else's issue, which still bumps updated_at and still
    # matches the query, kind="comment", login=<the issue's own author, not
    # you>. Left unfixed, replying to your own inbox wakes it back up under
    # someone else's name. Only checkable for "comment" rows (an "opened"
    # row is already excluded server-side by -author:<self>), and only
    # costs a request when the issue actually has comments to check.
    if [ "$kind_query" = "org" ] && [ "$kind" = "comment" ]; then
      local latest_author
      if latest_author="$(_wg_latest_comment_author "$org" "$repo" "$number" "$comments")" \
        && [ "$latest_author" = "$__WG_SELF" ]; then
        printf '%s\n' "$key" >> "$seen_file"   # handled — don't re-check every poll in the overlap window
        continue
      fi
    fi

    local line
    line="$(printf 'github %s/%s#%s %s by %s: %s' "$org" "$repo" "$number" "$kind" "$login" "$title")"
    log_done "$line"

    printf '{"kind":%s,"org":%s,"repo":%s,"number":%s,"login":%s,"title":%s,"updated_at":%s,"html_url":%s,"is_pr":%s,"line":%s}\n' \
      "$(json_str "$kind")" "$(json_str "$org")" "$(json_str "$repo")" "$number" \
      "$(json_str "$login")" "$(json_str "$title")" "$(json_str "$updated")" \
      "$(json_str "$html_url")" "$([ "$is_pr" = "1" ] && printf true || printf false)" \
      "$(json_str "$line")" >> "$events_file"

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

# _wg_status_write <org> <events_file> <summary> -> write ONE burn-status-
# SHAPED file under $CLIKAE_HOME/state/watch-github/<org>/runs/<epoch>.json
# so `clikae wait <that file>` — the reader that already exists, see the
# WHAT "WAKE" MEANS HERE note at the top of this file — returns 0 and prints
# `summary`. Superset of burn's own status.json field set (same `state`,
# same escaping via lib/core/json.sh) plus `summary`, which burn's own
# status.json has no use for. Write-then-rename, same as burn.sh's own
# _burn_status_write, so `clikae wait` (polling every second) never reads a
# half-written file.
_wg_status_write() {
  local org="$1" events_file="$2" summary="$3" run_dir now f
  run_dir="$(_wg_runs_dir "$org")"
  mkdir -p "$run_dir" 2>/dev/null || return 0
  now="$(date +%s 2>/dev/null || echo 0)"
  f="$run_dir/$now.json"
  {
    printf '{"ok":true,"engine":%s,"tank":%s,"artifact":%s,"artifact_bytes":null,"reason":%s,"reset":null,"rerouted_from":[],"elapsed_s":0,"run_id":%s,"state":%s,"started_at":%s,"updated_at":%s,"pid":%s,"log":null,"reset_at":null,"summary":%s}\n' \
      "$(json_str "github")" "$(json_str "$org")" "$(json_str "$events_file")" \
      "$(json_str "github-events")" "$(json_str "watch-github-$org-$now")" \
      "$(json_str "done")" "$now" "$now" "$$" "$(json_str "$summary")"
  } > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null || true
}

# --- one poll ---------------------------------------------------------------

# _wg_poll_one_query <kind_query> <org> <since> <seen_file> <events_file> ->
# paginate ONE query (org or mentions) up to 5 pages of 100 (P2-7), stopping
# early on a short page (the normal case: fewer than per_page rows means
# there is no next page) or once a page's oldest row is already <= <since>
# (defensive — the query itself already filters `updated:>=since`, so every
# row returned should already satisfy this; kept as the brief's own stated
# stop condition rather than trusting the filter silently). On a failed
# page (P2-5/P2-6): sets $__WG_OK=0 always; a rate-limit-classified failure
# also sets $__WG_BACKOFF=1, a permanent one (missing scope, SAML, bad org
# — see _wg_classify_error) sets $__WG_PERMANENT=1/$__WG_PERMANENT_REASON
# and the caller (cmd_watch_github) exits rather than ever backing off on
# it. Either way, pages already processed already folded their rows into
# $__WG_MAX_UPDATED via _wg_process, so a failure on page 3 still leaves the
# cursor able to advance to what pages 1-2 saw (never past a page that
# failed to read).
_wg_poll_one_query() {
  local kind_query="$1" org="$2" since="$3" seen_file="$4" events_file="$5"
  local q page=1 tsv page_n oldest
  if [ "$kind_query" = "org" ]; then q="$(_wg_query_org "$org" "$since")"
  else                               q="$(_wg_query_mentions "$org" "$since")"
  fi
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
          log_warn "GitHub search rate-limited on the $kind_query query — backing off. ($__WG_LAST_REASON)"
          ;;
        permanent)
          if [ "${__WG_PERMANENT:-0}" -ne 1 ]; then
            __WG_PERMANENT=1
            __WG_PERMANENT_REASON="$__WG_LAST_REASON"
          fi
          ;;
        *)
          log_warn "gh api search/issues failed on the $kind_query query: $__WG_LAST_REASON"
          ;;
      esac
      return 0
    fi
    tsv="$__WG_LAST_TSV"
    _wg_process "$kind_query" "$tsv" "$org" "$seen_file" "$events_file"

    page_n="$(printf '%s\n' "$tsv" | grep -c . || true)"
    [ "$page_n" -gt 0 ] || return 0        # empty page: nothing more to read
    [ "$page_n" -ge 100 ] || return 0      # short page: that WAS the last page

    oldest="$(printf '%s\n' "$tsv" | tail -n1 | cut -f2)"
    local LC_ALL=C   # fixed-width ISO8601 sorts lexicographically; pin the
                      # collation so this never depends on the caller's locale
    if [ -n "$oldest" ] && [ -n "$since" ] && [[ "$oldest" < "$since" ]]; then
      return 0   # already reached (or passed) the requested lower bound
    fi

    page=$((page + 1))
    if [ "$page" -gt 5 ]; then
      log_warn "github:$org — $kind_query query has +more, will catch up next poll."
      return 0
    fi
  done
}

# _wg_poll <org> [since_override] -> runs both queries (paginated), updates
# $__WG_EVENTS / $__WG_BACKOFF / $__WG_OK (globals, set here — see
# lib/core/wake.sh's _wake_targetsv for the same "sets globals instead of
# forking a subshell" idiom this follows). Never advances the cursor past a
# page that failed to read; the new cursor is lagged 300s behind the max
# updated_at actually seen (P1-3 — see the CURSOR SEMANTICS note above
# _wg_query_org). <since_override>, when non-empty, is used ONLY for a cold
# start (no persisted cursor, or an empty cursor file) — see cmd_watch_github's
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

  mkdir -p "$(_wg_state_dir)" "$(_wg_log_dir "$org")" 2>/dev/null || true
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

  for kind_query in org mentions; do
    # A permanent failure on the first query means the second would fail
    # the identical way (same auth, same org) — no point spending the
    # request or the retry on it.
    [ "$__WG_PERMANENT" -eq 1 ] && break
    _wg_poll_one_query "$kind_query" "$org" "$since" "$seen_file" "$events_file"
  done

  # Cap the seen-file at the last 500 keys (brief's stated cap).
  if [ -f "$seen_file" ]; then
    tail -n 500 "$seen_file" > "${seen_file}.tmp" 2>/dev/null && mv "${seen_file}.tmp" "$seen_file"
  fi

  # Never advance past an event a failed page might have contained. The new
  # cursor lags 300s behind the max updated_at actually seen this poll —
  # `>=` in the query plus the seen-file dedup absorb the resulting overlap.
  if [ "$__WG_OK" -eq 1 ] && [ -n "$__WG_MAX_UPDATED" ]; then
    local max_epoch new_cursor
    max_epoch="$(_limit_iso_epoch "$__WG_MAX_UPDATED" "")"
    new_cursor=""
    if [ -n "$max_epoch" ]; then
      new_cursor="$(_wg_iso_from_epoch "$((max_epoch - 300))")"
    fi
    [ -n "$new_cursor" ] || new_cursor="$__WG_MAX_UPDATED"   # unparseable: no lag, still forward progress
    printf '%s\n' "$new_cursor" > "${cursor_file}.tmp" 2>/dev/null && mv -f "${cursor_file}.tmp" "$cursor_file" 2>/dev/null || true
  fi

  # P1-1 (2026-09-13 fix-round-1 review): the wake itself — one status file
  # per poll that found something, so `clikae wait` has a terminal state to
  # read. Never on a zero-event poll (nothing for a cockpit to wake up FOR).
  if [ "$__WG_EVENTS" -ge 1 ]; then
    _wg_status_write "$org" "$events_file" "$(_wg_build_summary "$__WG_SUMMARY_LINES" "$__WG_EVENTS")"
  fi
}

# --- the command --------------------------------------------------------------

_watch_github_help() {
  cat <<'EOF'
Usage: clikae watch github [--org <org>] [--interval <dur>] [--once] [--since <ts>]

Poll GitHub's search API for issues/PRs opened by others, replies, and
@mentions in <org>, and turn each new one into a wake line:

  github <org>/<repo>#<n> <opened|comment|mention> by <login>: <title>

Printed live (a foreground run) and appended, as flat JSON, to
$CLIKAE_HOME/logs/watch-github-<org>/events.jsonl — durable, so a cron job or
a Stop hook calling --once has something to read even with nobody watching.

The actual wake: every poll that finds >=1 new event writes ONE status file
(the same shape `clikae burn` writes, same reader) to
$CLIKAE_HOME/state/watch-github/<org>/runs/<epoch>.json — so
`clikae wait <that file>` returns 0 and prints the events, exactly like
waiting on a burn. A cursor (the newest updated_at seen) persists at
$CLIKAE_HOME/state/watch-github/<org>.cursor; a small seen-file next to it
de-dupes (repo, issue number, updated_at) triples.

  --org <org>       GitHub org to watch. Default: inferred from this
                     directory's GitHub remote (`gh repo view`).
  --interval <dur>  Poll interval: bare seconds, or Ns/Nm/Nh/Nd. Default 10m.
  --once            Poll exactly once — for cron or a Stop hook, not a live
                     pane. No daemon, no tmux window of its own.
  --since <ts>      Cold-start lower bound (ISO8601, e.g.
                     2026-09-01T00:00:00Z), used ONLY when there is no
                     persisted cursor yet. Default: 24 hours ago.

Each query paginates up to 5 pages of 100 (order=desc, newest first), so a
cold start or a poll that fell behind still surfaces today's events first
instead of crawling forward from the org's oldest history. A page beyond
that cap prints "+more, will catch up next poll" rather than blocking.

Rate limits: normally 2 requests per poll (up to 10 when paginating both
queries to the cap; the search API allows 30/min authenticated). On a
genuine rate limit (429, or a 403 the response itself attributes to the
rate limit, or a 5xx) the interval backs off ×2 up to 1h and one line is
printed; the cursor is never advanced past a page that failed to read, and
is kept 300s behind the newest update actually seen (GitHub's search index
itself lags real writes by some minutes) — a small seen-file de-dupes the
resulting overlap between polls.

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
  local org="" interval_dur="10m" once=0 since_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)   _watch_github_help; return 0 ;;
      --org)       shift; [ $# -gt 0 ] || log_fail "--org needs a value"; org="$1"; shift ;;
      --interval)  shift; [ $# -gt 0 ] || log_fail "--interval needs a duration"; interval_dur="$1"; shift ;;
      --once)      once=1; shift ;;
      --since)     shift; [ $# -gt 0 ] || log_fail "--since needs an ISO8601 timestamp, e.g. 2026-09-01T00:00:00Z"
                   since_flag="$1"; shift ;;
      -*)          log_fail "Unknown flag: $1  (try: clikae watch github --help)" ;;
      *)           log_fail "Unexpected argument: $1  (try: clikae watch github --help)" ;;
    esac
  done

  if [ -n "$since_flag" ]; then
    # P1-3 (2026-09-13 fix-round-1 review): only ever used for a COLD start
    # (no persisted cursor yet) — see _wg_poll's since_override. Validated
    # the same way an updated_at from GitHub itself is parsed
    # (lib/core/limit.sh's _limit_iso_epoch), so a caller gets a clear
    # refusal instead of a query GitHub's search API silently mis-parses.
    [ -n "$(_limit_iso_epoch "$since_flag" "")" ] \
      || log_fail "--since: not an ISO8601 timestamp: $since_flag  (e.g. 2026-09-01T00:00:00Z)"
  fi

  local interval_s
  interval_s="$(_burn_parse_duration "$interval_dur")" \
    || log_fail "--interval: not a duration: $interval_dur  (use e.g. 60, 60s, 10m, 1h)"

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
      log_info "github:$org — $__WG_EVENTS new event(s) this poll."
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
      cur=$((cur * 2))
      [ "$cur" -le 3600 ] || cur=3600
    else
      cur="$interval_s"
    fi
    sleep "$cur"
  done
}
