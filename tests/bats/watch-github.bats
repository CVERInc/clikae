#!/usr/bin/env bats
# tests/bats/watch-github.bats — `clikae watch github` (#46): poll GitHub's
# search API and turn a reply/@mention into a wake event.
#
# A stub `gh` on PATH, never the real GitHub API — the ONE real call this
# feature ever makes to a live account is exercised manually at the end of
# the build (see the PR/report), never from this suite.

load '../helpers'

# --- a scripted `gh` -----------------------------------------------------
#
# Driven entirely by files under $GH_STUB_DIR so each test can script exactly
# what a sequence of `--once` polls sees, call by call, the same "one stub,
# indexed by call count" idea tests/helpers.bash's own
# _write_argv_logging_stub uses for engine argv (append/read-back), adapted
# here to canned RESPONSES instead of a recorded argv.
_gh_stub_install() {
  GH_STUB_DIR="$TEST_HOME/.ghstub"
  mkdir -p "$GH_STUB_DIR"
  export GH_STUB_DIR
  cat <<'STUB' > "$TEST_HOME/.testbin/gh"
#!/usr/bin/env bash
set -u
dir="${GH_STUB_DIR:?}"

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  rc=0
  [ -f "$dir/auth_rc" ] && rc="$(cat "$dir/auth_rc")"
  exit "$rc"
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  cat "$dir/login" 2>/dev/null
  exit 0
fi

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  [ -f "$dir/repo_owner" ] && cat "$dir/repo_owner"
  exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "search/issues" ]; then
  shift 2
  q="" method="" page=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --method) shift; method="${1:-}" ;;
      -f) shift
          case "${1:-}" in
            q=*) q="${1#q=}" ;;
            page=*) page="${1#page=}" ;;
          esac
          ;;
    esac
    shift
  done
  queue="org"
  case "$q" in *mentions:*) queue="mentions" ;; esac
  cf="$dir/$queue.calls"
  n=0
  [ -f "$cf" ] && n="$(cat "$cf")"
  n=$((n + 1))
  printf '%s' "$n" > "$cf"
  # P2-8: record what was actually SENT, not just what to answer with — a
  # bats test can then assert on the query string / HTTP method / page
  # number, the exact gap the round-1 review named ("stub永遠驗不到 HTTP
  # 動詞" — the stub is ours to write; asserting it is three lines).
  printf '%s\n' "$method" > "$dir/$queue.$n.sent_method"
  printf '%s\n' "$q" > "$dir/$queue.$n.sent_query"
  printf '%s\n' "$page" > "$dir/$queue.$n.sent_page"
  rcf="$dir/$queue.$n.rc"
  tsvf="$dir/$queue.$n.tsv"
  errf="$dir/$queue.$n.err"
  if [ -f "$rcf" ]; then
    [ -f "$errf" ] && cat "$errf" >&2
    exit "$(cat "$rcf")"
  fi
  [ -f "$tsvf" ] && cat "$tsvf"
  exit 0
fi

# P1-2/P2-4/P2-5: _wg_latest_actor's one-request-per-candidate lookup against
# the TIMELINE endpoint (not /comments — round 1's endpoint had no actor for
# a review/label/assignee change). `-i` (--include) means gh prints headers,
# a blank line, then the body — the stub answers the same shape so
# _wg_latest_actor's own header/body split is exercised for real.
# $dir/timeline.<repo>.<number>: line 1 = actor login, line 2 = event type
# (default "commented"). No file -> empty timeline (`[]`), no actor.
# $dir/timeline.<repo>.<number>.remaining overrides X-RateLimit-Remaining
# (default 5000 — "not rate-limited" unless a test says otherwise).
case "${1:-}/${2:-}" in
  api/repos/*/issues/*/timeline)
    path="$2"
    # path = repos/<org>/<repo>/issues/<number>/timeline
    repo="$(printf '%s' "$path" | cut -d/ -f3)"
    number="$(printf '%s' "$path" | cut -d/ -f5)"
    cf="$dir/timeline.calls"
    n=0
    [ -f "$cf" ] && n="$(cat "$cf")"
    n=$((n + 1))
    printf '%s' "$n" > "$cf"
    rcf="$dir/timeline.$repo.$number.rc"
    errf="$dir/timeline.$repo.$number.err"
    if [ -f "$rcf" ]; then
      [ -f "$errf" ] && cat "$errf" >&2
      exit "$(cat "$rcf")"
    fi
    remaining=5000
    [ -f "$dir/timeline.$repo.$number.remaining" ] && remaining="$(cat "$dir/timeline.$repo.$number.remaining")"
    actor="" event="commented"
    if [ -f "$dir/timeline.$repo.$number" ]; then
      actor="$(sed -n '1p' "$dir/timeline.$repo.$number")"
      ev="$(sed -n '2p' "$dir/timeline.$repo.$number")"
      [ -n "$ev" ] && event="$ev"
    fi
    printf 'HTTP/2.0 200 OK\r\n'
    printf 'x-ratelimit-remaining: %s\r\n' "$remaining"
    printf '\r\n'
    if [ -n "$actor" ]; then
      printf '[{"event":"%s","actor":{"login":"%s"}}]\n' "$event" "$actor"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
esac

exit 1
STUB
  chmod +x "$TEST_HOME/.testbin/gh"
  printf '0\n' > "$GH_STUB_DIR/auth_rc"
  printf 'me\n' > "$GH_STUB_DIR/login"
}

# _gh_stub_timeline <repo> <number> <actor> [event=commented] [remaining] —
# seed the answer _wg_latest_actor's timeline lookup gets for this row.
_gh_stub_timeline() {
  local repo="$1" number="$2" actor="$3" event="${4:-commented}" remaining="${5:-}"
  printf '%s\n%s\n' "$actor" "$event" > "$GH_STUB_DIR/timeline.$repo.$number"
  [ -z "$remaining" ] || printf '%s\n' "$remaining" > "$GH_STUB_DIR/timeline.$repo.$number.remaining"
}

# _gh_stub_timeline_fail <repo> <number> <rc> <err> — the lookup itself fails.
_gh_stub_timeline_fail() {
  printf '%s\n' "$3" > "$GH_STUB_DIR/timeline.$1.$2.rc"
  printf '%s\n' "$4" > "$GH_STUB_DIR/timeline.$1.$2.err"
}

# _gh_stub_page <org|mentions> <call#> <tsv-lines...> — seed one call's TSV
# response. Each line is already tab-separated: number, updated_at, login,
# repo, html_url, is_pr, title, comments — the exact shape _wg_fetch's jq
# filter emits.
_gh_stub_page() {
  local queue="$1" n="$2"; shift 2
  printf '%s\n' "$@" > "$GH_STUB_DIR/$queue.$n.tsv"
}

_gh_stub_fail() {
  local queue="$1" n="$2" rc="$3" err="$4"
  printf '%s\n' "$rc" > "$GH_STUB_DIR/$queue.$n.rc"
  printf '%s\n' "$err" > "$GH_STUB_DIR/$queue.$n.err"
}

_row() { # number updated login repo html_url is_pr title [comments=0]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-0}"
}

@test "watch github: gh auth status failing exits 1 with a clear line" {
  _gh_stub_install
  printf '1\n' > "$GH_STUB_DIR/auth_rc"
  run clikae watch github --org T
  [ "$status" -eq 1 ]
  [[ "$output" == *"not logged in"* ]] || false
}

@test "watch github --once: first run emits N events and writes the cursor" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://github.com/CVERInc/reef/issues/100 0 "First issue")" \
    "$(_row 101 2026-09-07T04:32:00Z bob   reef https://github.com/CVERInc/reef/pull/101   1 "Second one")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#100 opened by alice: First issue"* ]] || false
  [[ "$output" == *"github CVERInc/reef#101 opened by bob: Second one"* ]] || false
  [[ "$output" == *"2 new event(s)"* ]] || false
  local cursor="$CLIKAE_HOME/state/watch-github/CVERInc.cursor"
  [ -f "$cursor" ]
  # P1-3 (2026-09-13 fix-round-1 review): the cursor lags 300s behind the max
  # updated_at actually seen (04:32:00 - 5m = 04:27:00), never the exact max
  # — see the CURSOR SEMANTICS note in lib/commands/watch_github.sh.
  [ "$(cat "$cursor")" = "2026-09-07T04:27:00Z" ]
  # Durable JSONL record too — same $CLIKAE_HOME/logs directory burn's own
  # status.json lives under.
  local events="$CLIKAE_HOME/logs/watch-github-CVERInc/events.jsonl"
  [ -f "$events" ]
  [ "$(wc -l < "$events")" -eq 2 ]

  # P1-1 (2026-09-13 fix-round-1 review): the actual wake — a burn-status-
  # shaped file, and `clikae wait` on it (the reader that already exists)
  # returns 0 and prints the summary. This IS the end-to-end proof the
  # brief demanded: not "a file got written", but "the existing reader
  # accepts it and reports success".
  #
  # P2-3 (2026-09-13 fix-round-2 review): it lives at burn_status_dir's OWN
  # layout now ($HOME/.clikae/logs/watch-github-<org>-<epoch>/status.json —
  # under $CLIKAE_HOME/logs, since these tests run with $CLIKAE_HOME =
  # $HOME/.clikae), not a parallel state/ location `clikae wait` never
  # recognised. Proven two ways: by PATH (as before) AND by the run_id THIS
  # FILE ITSELF prints — round 1's file claimed a run_id nothing could
  # resolve; this one must actually work.
  local status_file
  status_file="$(find "$CLIKAE_HOME/logs" -maxdepth 2 -path '*/watch-github-CVERInc-*/status.json' | head -n1)"
  [ -n "$status_file" ]
  [ -f "$status_file" ]
  run clikae wait "$status_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"done"'* ]] || false
  [[ "$output" == *"github CVERInc/reef#100 opened by alice: First issue"* ]] || false
  [[ "$output" == *"github CVERInc/reef#101 opened by bob: Second one"* ]] || false

  local run_id; run_id="$(basename "$(dirname "$status_file")")"
  run clikae wait "$run_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"done"'* ]] || false
}

@test "watch github --once: second run with the same page emits 0 (de-dup)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 new event(s)"* ]] || false

  # Same page again (as if the same window were re-fetched).
  _gh_stub_page org 2 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
  [[ "$output" != *"[ DONE ]"* ]] || false
}

@test "watch github --once: a page with one newer event emits exactly 1" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  # Same old row + one new row (100 updated again -> comment; 102 brand new -> opened).
  _gh_stub_page org 2 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")" \
    "$(_row 102 2026-09-07T05:00:00Z carol reef https://x/102 0 "Third issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 new event(s)"* ]] || false
  [[ "$output" == *"github CVERInc/reef#102 opened by carol: Third issue"* ]] || false
  [[ "$output" != *"#100"* ]] || false
}

@test "watch github --once: an already-seen number updated again reads as 'comment', actor via timeline" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"#100 opened by alice"* ]] || false

  _gh_stub_timeline reef 100 alice commented
  _gh_stub_page org 2 \
    "$(_row 100 2026-09-07T09:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"#100 comment by alice"* ]] || false
}

@test "watch github --once: my OWN new issue is not an event, but a collaborator's reply on it IS (P1-2 headline)" {
  _gh_stub_install
  # No `-author:<self>` any more (P1-2) — the org query DOES return an issue
  # I opened myself, but opening it is not an event: I already know.
  _gh_stub_page org 1 \
    "$(_row 313 2026-09-07T04:00:00Z me reef https://x/313 0 "auth redirect")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
  [[ "$output" != *"#313"* ]] || false

  # A collaborator replies. The row's own login is STILL "me" (search/issues
  # gives the ISSUE's author, never the commenter) — round 1's bug compared
  # THAT against self and dropped this unconditionally. The timeline lookup
  # gives the REAL actor.
  _gh_stub_timeline reef 313 collaborator commented
  _gh_stub_page org 2 \
    "$(_row 313 2026-09-07T05:00:00Z me reef https://x/313 0 "auth redirect")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#313 comment by collaborator: auth redirect"* ]] || false
  [[ "$output" == *"1 new event(s)"* ]] || false
}

@test "watch github --once: my own comment on my own issue is 0 events (P1-2)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 313 2026-09-07T04:00:00Z me reef https://x/313 0 "auth redirect")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false

  _gh_stub_timeline reef 313 me commented
  _gh_stub_page org 2 \
    "$(_row 313 2026-09-07T05:00:00Z me reef https://x/313 0 "auth redirect")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
  [[ "$output" != *"#313"* ]] || false
}

@test "watch github --once: a self-reply on someone ELSE's issue is dropped, not woken (P2-9/P1-2)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"#100 opened by bob"* ]] || false

  _gh_stub_timeline reef 100 me commented
  _gh_stub_page org 2 \
    "$(_row 100 2026-09-07T05:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
  [[ "$output" != *"#100"* ]] || false
  # One gh api call made to check — the request budget the review asked for.
  [ "$(cat "$GH_STUB_DIR/timeline.calls")" = "1" ]
}

@test "watch github --once: a comment by someone ELSE on a non-self issue still wakes (P2-9)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  _gh_stub_timeline reef 100 carol commented
  _gh_stub_page org 2 \
    "$(_row 100 2026-09-07T05:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#100 comment by carol: bob's issue"* ]] || false
  [[ "$output" == *"1 new event(s)"* ]] || false
}

@test "watch github --once: a review on an already-known issue reads 'review' with the real actor (P2-5)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z bob reef https://x/100 1 "bob's PR")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  _gh_stub_timeline reef 100 carol reviewed
  _gh_stub_page org 2 \
    "$(_row 100 2026-09-07T05:00:00Z bob reef https://x/100 1 "bob's PR")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#100 review by carol: bob's PR"* ]] || false
}

@test "watch github --once: a lookup beyond the 50-per-poll budget still wakes, as 'unknown' (P2-4)" {
  _gh_stub_install
  # 51 already-known issues in one poll, all pre-seeded into the seen-file
  # (so poll 1 treats every row as an UPDATE, not an 'opened').
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  local i mm ts
  local -a rows=() seed=()
  for i in $(seq 1 51); do
    mm="$(printf '%02d' "$i")"
    ts="2026-09-07T04:${mm}:00Z"
    rows+=("$(_row "$i" "$ts" bob reef "https://x/$i" 0 "issue $i")")
    seed+=("reef|$i|2026-01-01T00:00:00Z")
  done
  printf '%s\n' "${seed[@]}" > "$state_dir/CVERInc.seen"
  # Every candidate resolves to a real (non-self) actor if looked up — the
  # test is about the BOUND, not about any individual lookup failing.
  for i in $(seq 1 51); do _gh_stub_timeline reef "$i" carol commented; done
  _gh_stub_page org 1 "${rows[@]}"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  # Exactly 50 lookups spent — never 51.
  [ "$(cat "$GH_STUB_DIR/timeline.calls")" = "50" ]
  # All 51 rows still woke (never silently dropped) — 50 as "carol", 1 as
  # "unknown" (the one past budget).
  [[ "$output" == *"51 new event(s)"* ]] || false
  [[ "$output" == *"by unknown:"* ]] || false
}

@test "watch github --once: a lookup that comes back rate-limited stops the rest and still wakes as 'unknown' (P2-4)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf 'reef|1|2026-01-01T00:00:00Z\nreef|2|2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  _gh_stub_timeline reef 1 carol commented 42   # X-RateLimit-Remaining: 42, under the 100 floor
  _gh_stub_page org 1 \
    "$(_row 1 2026-09-07T04:00:01Z bob reef https://x/1 0 "issue 1")" \
    "$(_row 2 2026-09-07T04:00:02Z bob reef https://x/2 0 "issue 2")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  # Only ONE lookup made — the second candidate's budget check saw
  # X-RateLimit-Remaining=42 from the first response and stopped early.
  [ "$(cat "$GH_STUB_DIR/timeline.calls")" = "1" ]
  [[ "$output" == *"2 new event(s)"* ]] || false
  [[ "$output" == *"by unknown:"* ]] || false
}

@test "watch github --once: a lookup failure is classified, not swallowed (P2-4)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf 'reef|100|2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  _gh_stub_timeline_fail reef 100 1 'gh: HTTP 403: API rate limit exceeded'
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"activity lookup failed (rate-limit)"* ]] || false
  [[ "$output" == *"by unknown:"* ]] || false
}

@test "watch github --once: same number, two DIFFERENT repos, same poll — neither is dropped (P1-4)" {
  _gh_stub_install
  # reef#12 and mixfairy#12, same updated_at — the exact collision E3 in the
  # 2026-09-13 fix-round-1 review reproduced: a bare (number, updated_at)
  # dedup key silently swallowed the second row.
  _gh_stub_page org 1 \
    "$(_row 12 2026-09-07T04:00:00Z alice reef     https://x/reef/12     0 "reef twelve")" \
    "$(_row 12 2026-09-07T04:00:00Z bob   mixfairy https://x/mixfairy/12 0 "mixfairy twelve")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#12 opened by alice: reef twelve"* ]] || false
  [[ "$output" == *"github CVERInc/mixfairy#12 opened by bob: mixfairy twelve"* ]] || false
  [[ "$output" == *"2 new event(s)"* ]] || false
  local events="$CLIKAE_HOME/logs/watch-github-CVERInc/events.jsonl"
  [ "$(wc -l < "$events")" -eq 2 ]
}

@test "watch github --once: a brand-new issue in a DIFFERENT repo reusing a seen number reads 'opened', not 'comment' (P1-4)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 12 2026-09-07T04:00:00Z alice reef https://x/reef/12 0 "reef twelve")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"#12 opened by alice"* ]] || false

  # A completely different repo's brand-new #12 — must NOT read as a comment
  # on reef#12 just because the bare issue number was already in the seen
  # file (the exact E2 misclassification from the same review).
  _gh_stub_page org 2 \
    "$(_row 12 2026-09-07T05:00:00Z carol mixfairy https://x/mixfairy/12 0 "mixfairy twelve")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/mixfairy#12 opened by carol: mixfairy twelve"* ]] || false
  [[ "$output" != *"comment"* ]] || false
}

@test "watch github --once: a genuine rate-limit 403 means no cursor advance, a back-off line, and rc=1 (P2-5)" {
  _gh_stub_install
  _gh_stub_fail org 1 1 'gh: HTTP 403: API rate limit exceeded (https://api.github.com/search/issues)'
  run clikae watch github --org CVERInc --once
  # P2-5 (2026-09-13 fix-round-1 review): --once used to exit 0 on ANY
  # failure and print "0 new event(s) this poll" — actively claiming
  # success. A rate limit IS a failed poll: rc=1, and no "0 new event(s)"
  # line (that would be the same false claim under a new name).
  [ "$status" -eq 1 ]
  [[ "$output" == *"403"* ]] || false
  [[ "$output" == *"back"* ]] || false
  [[ "$output" != *"new event(s)"* ]] || false
  [ ! -f "$CLIKAE_HOME/state/watch-github/CVERInc.cursor" ]
}

@test "watch github --once: a permanent 403 (missing scope) retries once, then exits 1 without a back-off line (P2-6)" {
  _gh_stub_install
  # No "rate limit" wording — a genuine scope/SAML denial, exactly what
  # _wg_classify_error must NOT treat as rate-limited. Seeded on BOTH call
  # 1 and call 2: a real permanent failure fails the identical way twice,
  # so the one retry _wg_fetch_classified spends does not cure it.
  _gh_stub_fail org 1 1 'gh: Resource not accessible by personal access token (HTTP 403)'
  _gh_stub_fail org 2 1 'gh: Resource not accessible by personal access token (HTTP 403)'
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"giving up"* ]] || false
  [[ "$output" == *"Resource not accessible"* ]] || false
  [[ "$output" != *"back"* ]] || false
  [ ! -f "$CLIKAE_HOME/state/watch-github/CVERInc.cursor" ]
  # The retry actually happened — two calls recorded for this queue.
  [ "$(cat "$GH_STUB_DIR/org.calls")" = "2" ]
}

@test "watch github --once: a 404 (bad org / the --method bug) is permanent, not rate-limited (P3-14)" {
  _gh_stub_install
  # Deliberately includes a trailing 3-digit number in the URL that is NOT
  # an HTTP status — the exact shape that used to fool a bare 403|429 grep
  # over the whole error line.
  _gh_stub_fail org 1 1 'gh: Not Found (HTTP 404) https://api.github.com/repos/CVERInc/reef/issues/403'
  _gh_stub_fail org 2 1 'gh: Not Found (HTTP 404) https://api.github.com/repos/CVERInc/reef/issues/403'
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"giving up"* ]] || false
  [[ "$output" != *"back"* ]] || false
}

@test "watch github --once: a permanent-shaped failure that clears on retry succeeds (one retry, P2-6)" {
  _gh_stub_install
  # Call 1 fails permanent-shaped; call 2 (the automatic retry) is NOT
  # seeded, so the stub's default (success, empty page) answers it — a
  # transient blip that merely wore a permission-denied costume.
  _gh_stub_fail org 1 1 'gh: Resource not accessible by personal access token (HTTP 403)'
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
  [ "$(cat "$GH_STUB_DIR/org.calls")" = "2" ]
}

@test "watch github --once exits 0 after one poll (even with zero events)" {
  _gh_stub_install
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
}

@test "watch github --once: seen-file caps at 5,000 lines, not 500 (P2-10)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  # 5,100 pre-existing keys, well past the OLD 500 cap and past the NEW
  # 5,000 one too — P2-10's finding was that 500 was smaller than a single
  # cold-start backlog could legitimately be, evicting entries the SAME
  # poll had just written and re-announcing them next time.
  seq 1 5100 | sed 's/^/reef|/; s/$/|2026-01-01T00:00:00Z/' > "$state_dir/CVERInc.seen"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$state_dir/CVERInc.seen")" -eq 5000 ]
  # It's a TAIL — the newest (highest-numbered) keys survive, not the oldest.
  grep -qxF "reef|5100|2026-01-01T00:00:00Z" "$state_dir/CVERInc.seen"
  ! grep -qxF "reef|100|2026-01-01T00:00:00Z" "$state_dir/CVERInc.seen"
}

@test "watch github --once: an empty cursor file is cold start, not a full org replay (P2-11)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  # A zero-byte cursor file — e.g. left behind by an older clikae, or any
  # foreign empty file at that path.
  : > "$state_dir/CVERInc.cursor"
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  # A real cursor got written (proves _wg_poll treated the empty file as
  # "no cursor" and fell through to the cold-start default, not as some
  # unparseable literal it choked on).
  [ -s "$state_dir/CVERInc.cursor" ]
}

@test "watch github --once: a stale poll lock is reclaimed, not blocked on forever (P2-11)" {
  _gh_stub_install
  local lock="$CLIKAE_HOME/state/watch-github/CVERInc.lock"
  mkdir -p "$lock"
  # Backdate it well past the 300s staleness window — simulating a poll
  # that crashed mid-run and never released it.
  local past
  past="$(date -u -d '-10 minutes' +%Y%m%d%H%M.%S 2>/dev/null || date -u -v-10M +%Y%m%d%H%M.%S)"
  touch -t "$past" "$lock"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
  # Released normally after the reclaimed poll finished — not left behind.
  [ ! -d "$lock" ]
}

@test "watch github --once: a comment by self is not an event" {
  _gh_stub_install
  _gh_stub_page mentions 1 \
    "$(_row 200 2026-09-07T06:00:00Z me reef https://x/200 0 "Self-authored, self-mentioned")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
  [[ "$output" != *"#200"* ]] || false
}

@test "watch github --once: a genuine mention by someone else IS an event" {
  _gh_stub_install
  _gh_stub_page mentions 1 \
    "$(_row 201 2026-09-07T06:05:00Z dave reef https://x/201 0 "cc @me please look")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#201 mention by dave: cc @me please look"* ]] || false
  [[ "$output" == *"1 new event(s)"* ]] || false
}

@test "watch github: rejects garbage --interval with rc=2 (P2-12)" {
  _gh_stub_install
  run clikae watch github --org CVERInc --interval notaduration --once
  # P2-12 (2026-09-13 fix-round-1 review): a bad --interval is now
  # distinguishable from clikae's usual rc=1 (log_fail) — rc=2 specifically,
  # like a caller scripting around `clikae wait`'s own exit codes.
  [ "$status" -eq 2 ]
  [[ "$output" == *"--interval"* ]] || false
}

@test "watch github: rejects --interval 0 with rc=2 (P2-12)" {
  _gh_stub_install
  run clikae watch github --org CVERInc --interval 0 --once
  [ "$status" -eq 2 ]
  [[ "$output" == *"--interval"* ]] || false
  [[ "$output" == *"greater than 0"* ]] || false
}

@test "watch github: rejects --interval -5 with rc=2 (P2-12)" {
  _gh_stub_install
  run clikae watch github --org CVERInc --interval -5 --once
  [ "$status" -eq 2 ]
  [[ "$output" == *"--interval"* ]] || false
}

@test "watch github: accepts a valid --interval like 30m (P2-12, positive control)" {
  _gh_stub_install
  run clikae watch github --org CVERInc --interval 30m --once
  [ "$status" -eq 0 ]
}

# --- P2-8: regression coverage for what the stub never validated before ----

@test "watch github --once: sends --method GET (P2-8)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  # This is the ONE assertion the review's round-1 audit found missing:
  # 11 tests passed with `--method GET` deleted outright (the exact shape
  # that 404s against the real API — see _wg_fetch's own 🔴 comment).
  [ "$(cat "$GH_STUB_DIR/org.1.sent_method")" = "GET" ]
}

@test "watch github --once: the query uses updated:>= , never a bare > (P2-8)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  # Second poll: a cursor now exists, so THIS query must carry updated:>=.
  _gh_stub_page org 2 \
    "$(_row 101 2026-09-07T04:40:00Z bob reef https://x/101 0 "Second issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$(cat "$GH_STUB_DIR/org.2.sent_query")" == *"updated:>="* ]] || false
}

@test "watch github --once: the cursor sent next poll is lagged 300s behind the max seen (P2-8)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:32:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  _gh_stub_page org 2 \
    "$(_row 101 2026-09-07T05:00:00Z bob reef https://x/101 0 "Second issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  # 04:32:00 - 300s = 04:27:00 — the SENT query, not just the persisted
  # cursor file, must reflect the lag.
  [[ "$(cat "$GH_STUB_DIR/org.2.sent_query")" == *"updated:>=2026-09-07T04:27:00Z"* ]] || false
}

@test "watch github --once: cursor is not advanced when a later PAGE fails to read (P2-8)" {
  _gh_stub_install
  # A fixed, old persisted cursor (not the 24h-ago cold-start default,
  # which would depend on today's date) so "oldest row < since" reliably
  # stays FALSE across all 100 generated rows and pagination genuinely
  # continues to page 2, deterministically, forever.
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf '2026-09-01T00:00:00Z\n' > "$state_dir/CVERInc.cursor"
  # 100 rows -> a full page, so _wg_poll_one_query requests page 2. Newest
  # first (order=desc), one minute apart, hour rolling over correctly
  # (04:59 down to 04:00, then 03:59 down to 03:20) rather than going
  # negative.
  local -a rows=()
  local i hour minute
  for i in $(seq 0 99); do
    if [ "$i" -lt 60 ]; then hour=4; minute=$((59 - i)); else hour=3; minute=$((119 - i)); fi
    minute="$(printf '%02d' "$minute")"
    rows+=("$(_row "$((200 + i))" "2026-09-07T0${hour}:${minute}:00Z" alice reef "https://x/$((200 + i))" 0 "issue $i")")
  done
  _gh_stub_page org 1 "${rows[@]}"
  _gh_stub_fail org 2 1 'gh: connection reset'
  run clikae watch github --org CVERInc --once
  # P2-5's rc contract applies here too: page 2 failing makes the WHOLE
  # poll a failure, so --once is rc=1, and the "N new event(s)" success
  # line is suppressed — even though page 1's 100 events were real.
  [ "$status" -eq 1 ]
  [[ "$output" != *"new event(s)"* ]] || false
  [[ "$output" == *"github CVERInc/reef#200 opened by alice: issue 0"* ]] || false
  # Two calls were made — page 2 really was requested (pagination
  # continued), not silently skipped.
  [ "$(cat "$GH_STUB_DIR/org.calls")" = "2" ]
  # The whole point: page 1's 100 events were real and got announced /
  # written to events.jsonl, but the cursor must NOT advance PAST the
  # pre-existing one — page 2 failing means we don't know what we might
  # have missed between page 1's oldest row and wherever page 2 would
  # have continued from.
  [ "$(cat "$state_dir/CVERInc.cursor")" = "2026-09-01T00:00:00Z" ]
  local events="$CLIKAE_HOME/logs/watch-github-CVERInc/events.jsonl"
  [ "$(wc -l < "$events")" -eq 100 ]
}

# --- P1-1 (2026-09-13 fix-round-2 review): pagination truncation must pin
# the cursor to the OLDEST row actually read, never the max seen — the old
# code let the cursor race straight to page 1's newest row, making every
# row past the 5-page cap permanently unreachable with no error and no WARN.

_wgt_epoch_iso() { # <epoch> -> ISO8601 Z, GNU first then BSD
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

@test "watch github --once: pagination truncation pins the cursor to the oldest row READ, not the max (P1-1)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf '2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.cursor"

  local base
  base="$(date -u -d '2026-09-07T05:00:00Z' +%s 2>/dev/null \
    || date -u -jf '%Y-%m-%dT%H:%M:%SZ' '2026-09-07T05:00:00Z' +%s)"

  local page i idx ts
  for page in 1 2 3 4 5; do
    local -a rows=()
    for i in $(seq 0 99); do
      idx=$(( (page - 1) * 100 + i ))
      ts="$(_wgt_epoch_iso "$((base - idx))")"
      rows+=("$(_row "$((900 + idx))" "$ts" alice reef "https://x/$((900 + idx))" 0 "issue $idx")")
    done
    _gh_stub_page org "$page" "${rows[@]}"
  done

  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"+more, will catch up next poll"* ]] || false
  [[ "$output" == *"500 new event(s) this poll. (truncated: continuing next poll)"* ]] || false
  # Only 5 calls made — page 6 was never fetched (the truncation itself).
  [ "$(cat "$GH_STUB_DIR/org.calls")" = "5" ]
  # Page 5's own oldest row is idx 499 (100 rows/page, page 5 = idx 400..499)
  # — the cursor must land on THAT row minus the 300s lag, not on idx 0's
  # (page 1's newest, the old buggy formula).
  local expect_cursor; expect_cursor="$(_wgt_epoch_iso "$((base - 499 - 300))")"
  [ "$(cat "$state_dir/CVERInc.cursor")" = "$expect_cursor" ]

  # poll 2: the row that lived on the never-fetched page 6 (idx 500 — older
  # than page 5's oldest, so under the OLD (max-based) cursor it would sit
  # below the window forever) must now be reachable.
  local six_ts; six_ts="$(_wgt_epoch_iso "$((base - 500))")"
  _gh_stub_page org 6 "$(_row 1400 "$six_ts" bob reef "https://x/1400" 0 "page six issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#1400 opened by bob: page six issue"* ]] || false
  [[ "$(cat "$GH_STUB_DIR/org.6.sent_query")" == *"updated:>=${expect_cursor}"* ]] || false
}

# --- P2-3 (2026-09-13 fix-round-2 review): end to end, `clikae wait --latest
# watch-github-<org>` against the REAL writer, no epoch known in advance —
# the whole point of the fix (a cockpit can only know the prefix).

@test "watch github --once: clikae wait --latest resolves the run a cockpit never saw the epoch for (P2-3)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  run clikae wait --latest watch-github-CVERInc
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"done"'* ]] || false
  [[ "$output" == *"github CVERInc/reef#100 opened by alice: First issue"* ]] || false
}

@test "watch: still dispatches to the engine path for a non-github first argument" {
  # Regression guard for the new branch in cmd_watch: 'github' is special-
  # cased, everything else must reach the ordinary engine flow untouched.
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local slug d
  slug="$(printf '%s' "$work" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  d="$CLIKAE_HOME/profiles/claude/a/projects/$slug"
  mkdir -p "$d"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"hi"},"timestamp":"2026-05-31T01:00:00Z"}\n' "$work" > "$d/sid.jsonl"
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae watch claude --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"No genuine limit marker"* ]] || false
}
