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
# the key actually used is (number, updated_at) — in practice equivalent,
# since any new comment/edit bumps updated_at to a value not seen before.
#
# CURSOR MONOTONICITY / BACKLOG. Requesting `sort=updated -f order=asc` (free
# — same request, no extra call) means page 1 is always the OLDEST unread
# items first, so the cursor advances through a backlog across polls instead
# of jumping to the newest result and stranding everything before it.
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

# --- queries --------------------------------------------------------------

# _wg_query_org <org> <since|""> -> the search string for "issues/PRs opened
# by others, replies on issues updated since <since>" (see the ⚠️ note above
# for what this does NOT catch).
_wg_query_org() {
  local org="$1" since="$2"
  if [ -n "$since" ]; then
    printf 'org:%s updated:>%s -author:%s' "$org" "$since" "$__WG_SELF"
  else
    printf 'org:%s -author:%s' "$org" "$__WG_SELF"
  fi
}

# _wg_query_mentions <org> <since|""> -> @mentions of self. Deliberately NOT
# author-excluded (a self-mention needs the login check in _wg_process, not
# the query, to be filtered — see the file header).
_wg_query_mentions() {
  local org="$1" since="$2"
  if [ -n "$since" ]; then
    printf 'org:%s updated:>%s mentions:%s' "$org" "$since" "$__WG_SELF"
  else
    printf 'org:%s mentions:%s' "$org" "$__WG_SELF"
  fi
}

# --- one query's worth of work ---------------------------------------------

# _wg_fetch <query> <errfile> -> TSV on stdout (number, updated_at, login,
# repo, html_url, is_pr, title — see the jq filter), gh's own exit code.
# gh's `--jq` is its own vendored implementation (gojq) — no external `jq`
# binary required, unlike lib/core/fleet_mcp.sh's merge (which genuinely
# needs the real jq for --slurpfile).
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
  local query="$1" errfile="$2"
  gh api search/issues --method GET -f q="$query" -f sort=updated -f order=asc \
    --jq '.items[]? | [(.number|tostring), .updated_at, .user.login, (.repository_url|split("/")|.[-1]), .html_url, (if .pull_request then "1" else "0" end), .title] | @tsv' \
    2>"$errfile"
}

# _wg_is_rate_limited <errfile> -> 0 if gh's own error text names 403/429.
_wg_is_rate_limited() {
  grep -qE '(^|[^0-9])(403|429)([^0-9]|$)' "$1" 2>/dev/null
}

# _wg_process <kind_query: org|mentions> <tsv> <org> <seen_file> <events_file>
# -> for every NEW (not-yet-seen) row: prints the wake line, appends a JSON
# record, appends the dedup key to the seen file, and folds updated_at into
# the running-max global $__WG_MAX_UPDATED. Bumps $__WG_EVENTS. bash 3.2: no
# associative arrays, no mapfile — a plain while/read loop over a variable
# via a here-string.
_wg_process() {
  local kind_query="$1" tsv="$2" org="$3" seen_file="$4" events_file="$5"
  [ -n "$tsv" ] || return 0
  local number updated login repo html_url is_pr title
  while IFS=$'\t' read -r number updated login repo html_url is_pr title; do
    [ -n "$number" ] || continue

    local kind
    if [ "$kind_query" = "mentions" ]; then
      # Self mentioning self (e.g. a self-authored issue that also contains
      # "@self") is not an event — the query itself can't exclude it (it has
      # no author filter; see _wg_query_mentions), only this login check can.
      [ "$login" != "$__WG_SELF" ] || continue
      kind="mention"
    else
      if grep -qE "^${number}\\|" "$seen_file" 2>/dev/null; then
        kind="comment"
      else
        kind="opened"
      fi
    fi

    local key="${number}|${updated}"
    grep -qxF "$key" "$seen_file" 2>/dev/null && continue   # already handled

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
    if [ -z "$__WG_MAX_UPDATED" ] || [[ "$updated" > "$__WG_MAX_UPDATED" ]]; then
      __WG_MAX_UPDATED="$updated"
    fi
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

# _wg_poll <org> -> runs both queries, updates $__WG_EVENTS / $__WG_BACKOFF
# (globals, set here — see lib/core/wake.sh's _wake_targetsv for the same
# "sets globals instead of forking a subshell" idiom this follows). Never
# advances the cursor past a query that failed to read.
_wg_poll() {
  local org="$1"
  __WG_EVENTS=0
  __WG_BACKOFF=0
  __WG_MAX_UPDATED=""
  __WG_SUMMARY_LINES=""
  local ok=1

  mkdir -p "$(_wg_state_dir)" "$(_wg_log_dir "$org")" 2>/dev/null || true
  local seen_file events_file cursor_file since
  seen_file="$(_wg_seen_file "$org")"
  events_file="$(_wg_events_file "$org")"
  cursor_file="$(_wg_cursor_file "$org")"
  [ -f "$seen_file" ] || : > "$seen_file"
  since=""
  [ -f "$cursor_file" ] && since="$(cat "$cursor_file" 2>/dev/null)"

  local q errfile tsv rc
  for kind_query in org mentions; do
    if [ "$kind_query" = "org" ]; then q="$(_wg_query_org "$org" "$since")"
    else                               q="$(_wg_query_mentions "$org" "$since")"
    fi
    errfile="$(mktemp "${TMPDIR:-/tmp}/clikae-watch-github.XXXXXX")"
    # 🔴 `cmd || rc=$?`, never a bare `cmd; rc=$?` — bin/clikae runs under
    # `set -eo pipefail`. A bare `tsv="$(_wg_fetch …)"` failing is not the
    # condition of any if/while/&&/||, so set -e would abort this whole
    # function right here — before `rc` is ever read, before the 403/429
    # check, before the cursor-preserving `continue` below — the moment
    # _wg_fetch's first nonzero exit happened to be a rate limit. Same fix
    # burn.sh's own tank-lock acquire documents at length for the identical
    # shape (search this repo for "never a bare").
    rc=0
    tsv="$(_wg_fetch "$q" "$errfile")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      ok=0
      if _wg_is_rate_limited "$errfile"; then
        __WG_BACKOFF=1
        log_warn "GitHub search rate-limited (403/429) on the $kind_query query — backing off."
      else
        log_warn "gh api search/issues failed on the $kind_query query: $(head -n1 "$errfile" 2>/dev/null)"
      fi
      rm -f "$errfile"
      continue
    fi
    rm -f "$errfile"
    _wg_process "$kind_query" "$tsv" "$org" "$seen_file" "$events_file"
  done

  # Cap the seen-file at the last 500 keys (brief's stated cap).
  if [ -f "$seen_file" ]; then
    tail -n 500 "$seen_file" > "${seen_file}.tmp" 2>/dev/null && mv "${seen_file}.tmp" "$seen_file"
  fi

  # Never advance past an event a failed query might have contained.
  if [ "$ok" -eq 1 ] && [ -n "$__WG_MAX_UPDATED" ]; then
    printf '%s\n' "$__WG_MAX_UPDATED" > "$cursor_file"
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
Usage: clikae watch github [--org <org>] [--interval <dur>] [--once]

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
  --once            Poll exactly once and exit 0 — for cron or a Stop hook,
                     not a live pane. No daemon, no tmux window of its own.

Rate limits: one poll is 2 requests (the search API allows 30/min
authenticated). On a 403/429 the interval backs off ×2 up to 1h and one line
is printed; the cursor is never advanced past a query that failed to read.

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
  local org="" interval_dur="10m" once=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)   _watch_github_help; return 0 ;;
      --org)       shift; [ $# -gt 0 ] || log_fail "--org needs a value"; org="$1"; shift ;;
      --interval)  shift; [ $# -gt 0 ] || log_fail "--interval needs a duration"; interval_dur="$1"; shift ;;
      --once)      once=1; shift ;;
      -*)          log_fail "Unknown flag: $1  (try: clikae watch github --help)" ;;
      *)           log_fail "Unexpected argument: $1  (try: clikae watch github --help)" ;;
    esac
  done

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
    _wg_poll "$org"
    log_info "github:$org — $__WG_EVENTS new event(s) this poll."
    return 0
  fi

  log_info "Watching GitHub org $org as $__WG_SELF — polling every $(wake_human_left "$interval_s"). Ctrl-C to stop."
  local cur="$interval_s"
  while :; do
    _wg_poll "$org"
    if [ "$__WG_BACKOFF" -eq 1 ]; then
      cur=$((cur * 2))
      [ "$cur" -le 3600 ] || cur=3600
    else
      cur="$interval_s"
    fi
    sleep "$cur"
  done
}
