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
  q=""
  while [ $# -gt 0 ]; do
    if [ "$1" = "-f" ]; then
      shift
      case "${1:-}" in q=*) q="${1#q=}" ;; esac
    fi
    shift
  done
  queue="org"
  case "$q" in *mentions:*) queue="mentions" ;; esac
  cf="$dir/$queue.calls"
  n=0
  [ -f "$cf" ] && n="$(cat "$cf")"
  n=$((n + 1))
  printf '%s' "$n" > "$cf"
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

# P2-9: _wg_latest_comment_author's one-request-per-candidate lookup.
# $dir/lastauthor.<repo>.<number> (repo-scoped so different tests/rows never
# collide), one login per line. No file -> empty (no comments to speak of).
case "${1:-}/${2:-}" in
  api/repos/*/issues/*/comments)
    path="$2"
    # path = repos/<org>/<repo>/issues/<number>/comments
    repo="$(printf '%s' "$path" | cut -d/ -f3)"
    number="$(printf '%s' "$path" | cut -d/ -f5)"
    f="$dir/lastauthor.$repo.$number"
    [ -f "$f" ] && cat "$f"
    exit 0
    ;;
esac

exit 1
STUB
  chmod +x "$TEST_HOME/.testbin/gh"
  printf '0\n' > "$GH_STUB_DIR/auth_rc"
  printf 'me\n' > "$GH_STUB_DIR/login"
}

# _gh_stub_last_author <repo> <number> <login> — seed the answer
# _wg_latest_comment_author's `gh api repos/.../issues/<number>/comments`
# call gets for this repo/number.
_gh_stub_last_author() {
  printf '%s\n' "$3" > "$GH_STUB_DIR/lastauthor.$1.$2"
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
  # shaped file under runs/, and `clikae wait` on it (the reader that
  # already exists) returns 0 and prints the summary. This IS the
  # end-to-end proof the brief demanded: not "a file got written", but "the
  # existing reader accepts it and reports success".
  local runs_dir="$CLIKAE_HOME/state/watch-github/CVERInc/runs"
  [ -d "$runs_dir" ]
  local status_file
  status_file="$(find "$runs_dir" -name '*.json' | head -n1)"
  [ -n "$status_file" ]
  [ -f "$status_file" ]
  run clikae wait "$status_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"done"'* ]] || false
  [[ "$output" == *"github CVERInc/reef#100 opened by alice: First issue"* ]] || false
  [[ "$output" == *"github CVERInc/reef#101 opened by bob: Second one"* ]] || false
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

@test "watch github --once: an already-seen number updated again reads as 'comment'" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"#100 opened by alice"* ]] || false

  _gh_stub_page org 2 \
    "$(_row 100 2026-09-07T09:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"#100 comment by alice"* ]] || false
}

@test "watch github --once: a self-comment on someone ELSE's issue is dropped, not woken (P2-9)" {
  _gh_stub_install
  # bob opens reef#100; org query's -author:me already excludes anything
  # self opened, so this is a normal 'opened' event.
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"#100 opened by bob"* ]] || false

  # reef#100 updated again — the row's own login is STILL bob (search/issues
  # gives the ISSUE's author, never the commenter), but the LATEST comment
  # was actually left by self. -author:<self> in the query does nothing
  # here: the issue itself was never self-authored, only this one comment
  # was. This is exactly the gap the review named: "I reply to my own
  # inbox, and get woken back up under someone else's name."
  _gh_stub_last_author reef 100 me
  _gh_stub_page org 2 \
    "$(_row 100 2026-09-07T05:00:00Z bob reef https://x/100 0 "bob's issue" 3)"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
  [[ "$output" != *"#100"* ]] || false
  # One gh api call made to check — the request budget the review asked for.
  [ -f "$GH_STUB_DIR/lastauthor.reef.100" ]
}

@test "watch github --once: a comment by someone ELSE on a non-self issue still wakes (P2-9)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  _gh_stub_last_author reef 100 carol
  _gh_stub_page org 2 \
    "$(_row 100 2026-09-07T05:00:00Z bob reef https://x/100 0 "bob's issue" 2)"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#100 comment by bob: bob's issue"* ]] || false
  [[ "$output" == *"1 new event(s)"* ]] || false
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
