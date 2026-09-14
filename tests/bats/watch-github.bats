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
    shift 2
    page=1
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) shift; case "${1:-}" in page=*) page="${1#page=}" ;; esac ;;
      esac
      shift
    done
    cf="$dir/timeline.calls"
    n=0
    [ -f "$cf" ] && n="$(cat "$cf")"
    n=$((n + 1))
    printf '%s' "$n" > "$cf"
    printf '%s\n' "$page" > "$dir/timeline.$repo.$number.$n.sent_page"
    rcf="$dir/timeline.$repo.$number.rc"
    errf="$dir/timeline.$repo.$number.err"
    if [ -f "$rcf" ]; then
      [ -f "$errf" ] && cat "$errf" >&2
      exit "$(cat "$rcf")"
    fi
    remaining=5000
    [ -f "$dir/timeline.$repo.$number.remaining" ] && remaining="$(cat "$dir/timeline.$repo.$number.remaining")"
    last=1
    [ -f "$dir/timeline.$repo.$number.last" ] && last="$(cat "$dir/timeline.$repo.$number.last")"
    printf 'HTTP/2.0 200 OK\r\n'
    printf 'x-ratelimit-remaining: %s\r\n' "$remaining"
    if [ "$page" = "1" ] && [ "$last" != "1" ]; then
      printf 'link: <https://api.github.com/repositories/1/issues/%s/timeline?per_page=100&page=%s>; rel="last"\r\n' \
        "$number" "$last"
    fi
    printf '\r\n'
    bodyfile="$dir/timeline.$repo.$number.page$page.json"
    if [ -f "$bodyfile" ]; then
      cat "$bodyfile"
    elif [ "$page" = "1" ] && [ -f "$dir/timeline.$repo.$number" ]; then
      # Legacy single-page shape (_gh_stub_timeline): line 1 = actor login,
      # line 2 = event type — still exercised by the many pre-P1-1 tests
      # that never needed multi-page control.
      actor="$(sed -n '1p' "$dir/timeline.$repo.$number")"
      ev="$(sed -n '2p' "$dir/timeline.$repo.$number")"
      [ -n "$ev" ] || ev="commented"
      if [ -n "$actor" ]; then
        printf '[{"event":"%s","actor":{"login":"%s"}}]\n' "$ev" "$actor"
      else
        printf '[]\n'
      fi
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

# --- P1-1 (2026-09-13 fix-round-3 review): the timeline endpoint has no
# `direction` — _wg_latest_actor now reads page 1's own `Link: rel="last"`
# header and fetches THAT page, then scans it backwards for the last event
# carrying `actor.login` OR `user.login`. These two helpers give a test full
# control over a specific page's raw body and the reported last-page number,
# modelled on the real shapes the round-3 review's one real call captured
# (committed events with neither field, comment events keyed `user` not
# `actor`, an all-committed tail, an empty `[]` page).

# _gh_stub_timeline_page <repo> <number> <page> <raw-json-array> — the exact
# body _wg_latest_actor's request for <page> gets.
_gh_stub_timeline_page() {
  printf '%s\n' "$4" > "$GH_STUB_DIR/timeline.$1.$2.page$3.json"
}

# _gh_stub_timeline_last <repo> <number> <last_page> — the page number
# reported in the `Link: rel="last"` header on a page=1 request. Not set (or
# set to 1) means "single page" — no Link header at all, same as a real
# timeline with <=100 items.
_gh_stub_timeline_last() {
  printf '%s\n' "$3" > "$GH_STUB_DIR/timeline.$1.$2.last"
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

# --- an HONEST server (P1-2, 2026-09-13 fix-round-3 review) --------------
#
# Every other stub in this file answers "the Nth call gets canned response
# N" — which is exactly what let round 2's own truncation regression test
# pass while the real bug (permanent stall under desc pagination) sat right
# next to it: that test fed page 6 back as a hand-picked SECOND-POLL fixture,
# not as the honest continuation a real re-paginating query would produce.
# This stub is different in kind: it holds one corpus of rows and actually
# FILTERS by the `updated:>=` clause in the query string and ORDERS by
# `order=asc|desc`, then slices out whichever `page` was asked for — so a
# multi-poll test against it proves the real query behaviour, not just the
# cursor arithmetic in isolation. See _gh_stub_install_honest_corpus below.
_gh_stub_install_honest_corpus() {
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
  q="" page="" order="asc" per_page=100
  while [ $# -gt 0 ]; do
    case "$1" in
      -f) shift
          case "${1:-}" in
            q=*) q="${1#q=}" ;;
            page=*) page="${1#page=}" ;;
            order=*) order="${1#order=}" ;;
            per_page=*) per_page="${1#per_page=}" ;;
          esac
          ;;
    esac
    shift
  done
  queue="org"
  case "$q" in *mentions:*) queue="mentions" ;; esac
  cf="$dir/$queue.calls"
  n=0; [ -f "$cf" ] && n="$(cat "$cf")"; n=$((n + 1)); printf '%s' "$n" > "$cf"
  printf '%s\n' "$q" > "$dir/$queue.$n.sent_query"
  printf '%s\n' "$page" > "$dir/$queue.$n.sent_page"
  # `updated:>=<ts>` -> the ts (a fixed-width ISO8601 token, no spaces).
  since="$(printf '%s' "$q" | grep -oE 'updated:>=[^ ]+' | head -n1 | cut -d= -f2)"
  corpus="$dir/honest_corpus.tsv"
  [ -f "$corpus" ] || exit 0
  sortflag=""
  [ "$order" = "desc" ] && sortflag="-r"
  filtered="$(awk -F'\t' -v s="$since" '$2>=s' "$corpus" | sort -t "$(printf '\t')" -k2,2 $sortflag)"
  start=$(( (page - 1) * per_page + 1 ))
  end=$(( page * per_page ))
  printf '%s\n' "$filtered" | sed -n "${start},${end}p"
  exit 0
fi

case "${1:-}/${2:-}" in
  api/repos/*/issues/*/timeline)
    printf 'HTTP/2.0 200 OK\r\n'
    printf 'x-ratelimit-remaining: 5000\r\n'
    printf '\r\n'
    printf '[]\n'
    exit 0
    ;;
esac

exit 1
STUB
  chmod +x "$TEST_HOME/.testbin/gh"
  printf '0\n' > "$GH_STUB_DIR/auth_rc"
  printf 'me\n' > "$GH_STUB_DIR/login"
}

# _honest_corpus_write <n> <start_iso> <step_s> -> write $n rows to
# honest_corpus.tsv, numbers 2000+1..2000+n, updated_at = start_iso +
# i*step_s (ascending), repo "reef", login "alice", title "issue <i>".
_honest_corpus_write() {
  local n="$1" start_iso="$2" step="$3" base
  base="$(date -u -d "$start_iso" +%s 2>/dev/null \
    || date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$start_iso" +%s)"
  local i ts
  : > "$GH_STUB_DIR/honest_corpus.tsv"
  for i in $(seq 1 "$n"); do
    ts="$(date -u -d "@$((base + i * step))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -r "$((base + i * step))" +%Y-%m-%dT%H:%M:%SZ)"
    _row "$((2000 + i))" "$ts" alice reef "https://x/$((2000 + i))" 0 "issue $i" \
      >> "$GH_STUB_DIR/honest_corpus.tsv"
    printf '\n' >> "$GH_STUB_DIR/honest_corpus.tsv"
  done
}

# _honest_corpus_write_dense <n> <start_iso> <rows_per_block> <secs_per_block>
# -> like _honest_corpus_write, but <rows_per_block> rows share each
# <secs_per_block>-second span (e.g. 5/3 = 0.6s/row, 5/1 = 0.2s/row) — bash
# integer arithmetic can't take a fractional step directly, so several
# consecutive rows land on the same whole second instead; what a real-time
# window actually captures (the property P1-1 below depends on) is
# identical either way. Overwrites honest_corpus.tsv, same shape/numbering
# as _honest_corpus_write above.
_honest_corpus_write_dense() {
  local n="$1" start_iso="$2" rpb="$3" spb="$4" base
  base="$(date -u -d "$start_iso" +%s 2>/dev/null \
    || date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$start_iso" +%s)"
  local i sec ts
  : > "$GH_STUB_DIR/honest_corpus.tsv"
  for i in $(seq 1 "$n"); do
    sec=$(( (i - 1) * spb / rpb ))
    ts="$(date -u -d "@$((base + sec))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -r "$((base + sec))" +%Y-%m-%dT%H:%M:%SZ)"
    _row "$((2000 + i))" "$ts" alice reef "https://x/$((2000 + i))" 0 "issue $i" \
      >> "$GH_STUB_DIR/honest_corpus.tsv"
    printf '\n' >> "$GH_STUB_DIR/honest_corpus.tsv"
  done
}

# _honest_corpus_append <start_num> <n> <start_iso> <step_s> -> APPEND $n
# more rows (numbers <start_num>+1..<start_num>+n) to the EXISTING
# honest_corpus.tsv, same shape as _honest_corpus_write — for simulating
# activity that arrives well after an already-drained backlog (P1-1's
# self-heal scenario).
_honest_corpus_append() {
  local start_num="$1" n="$2" start_iso="$3" step="$4" base
  base="$(date -u -d "$start_iso" +%s 2>/dev/null \
    || date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$start_iso" +%s)"
  local i ts
  for i in $(seq 1 "$n"); do
    ts="$(date -u -d "@$((base + i * step))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -r "$((base + i * step))" +%Y-%m-%dT%H:%M:%SZ)"
    _row "$((start_num + i))" "$ts" alice reef "https://x/$((start_num + i))" 0 "late issue $i" \
      >> "$GH_STUB_DIR/honest_corpus.tsv"
    printf '\n' >> "$GH_STUB_DIR/honest_corpus.tsv"
  done
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
  # P1-1 (2026-09-14 fix-round-4 review): the cursor is EXACTLY the max
  # updated_at actually processed this poll — no lag (an earlier round
  # lagged this 300s, which turned out to be the permanent-stall bug the
  # CURSOR SEMANTICS note in lib/commands/watch_github.sh now documents).
  [ "$(cat "$cursor")" = "2026-09-07T04:32:00Z" ]
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

# --- P1-1 (2026-09-13 fix-round-3 review): the timeline endpoint has no
# `direction`. Fixture shapes modelled on what the one real `--once` call
# actually captured: `committed` events with neither `actor` nor `user`,
# comment events keyed `user` not `actor`, and a `[]` page.

@test "watch github --once: a committed tail with no actor falls back to an EARLIER comment on the same page (P1-1)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf 'reef|100|2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  # Single page (no Link header): a comment, then two commits with neither
  # actor nor user — the real, most common shape. The LAST event with an
  # actor is the comment, even though it is not literally the last element.
  _gh_stub_timeline_page reef 100 1 \
    '[{"event":"commented","actor":{"login":"dana"}},{"event":"committed","author":{"name":"dana","email":"d@x"},"committer":{"name":"dana","email":"d@x"}},{"event":"committed","author":{"name":"dana","email":"d@x"},"committer":{"name":"dana","email":"d@x"}}]'
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T09:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#100 comment by dana: bob's issue"* ]] || false
}

@test "watch github --once: an all-committed page has no actor at all — never dropped, never treated as self (P1-1)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf 'reef|100|2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  _gh_stub_timeline_page reef 100 1 \
    '[{"event":"committed","author":{"name":"dana"}},{"event":"committed","author":{"name":"dana"}}]'
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T09:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  # Never dropped — still emitted, actor "unknown", never mistaken for self.
  [[ "$output" == *"github CVERInc/reef#100"*"by unknown: bob's issue"* ]] || false
  [[ "$output" == *"1 new event(s)"* ]] || false
}

@test "watch github --once: an empty timeline page ([]) is never dropped, never treated as self (P1-1)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf 'reef|100|2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  _gh_stub_timeline_page reef 100 1 '[]'
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T09:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"by unknown: bob's issue"* ]] || false
}

@test "watch github --once: a multi-page timeline fetches the LAST page (Link rel=last), not page 1 (P1-1)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf 'reef|100|2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  # Page 1 (stale, hours old): opened by carol. If the code ever regresses
  # to reading page 1 (round 1/2's bug, applied to the wrong end this time),
  # this would wrongly report "carol".
  _gh_stub_timeline_page reef 100 1 '[{"event":"opened","actor":{"login":"carol"}}]'
  _gh_stub_timeline_last reef 100 3
  # Page 3 (the true last page): the real latest actor, erin, via a comment.
  _gh_stub_timeline_page reef 100 3 '[{"event":"commented","actor":{"login":"erin"}}]'
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T09:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#100 comment by erin: bob's issue"* ]] || false
  [[ "$output" != *"by carol"* ]] || false
  # Exactly 2 timeline calls for this one candidate — page 1 (to learn the
  # last page number) then page 3 (the true tail) — still 1 unit against
  # the 50-lookup budget (see the P2-4 budget test elsewhere in this file).
  [ "$(cat "$GH_STUB_DIR/timeline.calls")" = "2" ]
  [ "$(cat "$GH_STUB_DIR/timeline.reef.100.1.sent_page")" = "1" ]
  [ "$(cat "$GH_STUB_DIR/timeline.reef.100.2.sent_page")" = "3" ]
}

@test "watch github --once: a single-page timeline (no Link header) costs exactly ONE timeline call (P1-1)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf 'reef|100|2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  _gh_stub_timeline reef 100 alice commented
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T09:00:00Z bob reef https://x/100 0 "bob's issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#100 comment by alice: bob's issue"* ]] || false
  [ "$(cat "$GH_STUB_DIR/timeline.calls")" = "1" ]
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

# P3-1 (2026-09-13 fix-round-3 review): the seen-file's `known` check
# spliced `$repo` into an ERE unescaped — `.` is the only GitHub-legal repo
# character that's also an ERE metachar. seen-file entry `axb|5|…` would
# make a BRAND NEW `a.b#5` misread as already-known (`.` matches `x`),
# costing a lookup and printing 'comment' instead of 'opened'.
@test "watch github --once: a repo name containing '.' is not misread as a regex against an unrelated repo (P3-1)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  # A DIFFERENT repo, "axb", already has #5 seen — under the old unescaped
  # regex, "a.b" (this poll's repo) as a PATTERN would match "axb" as DATA.
  printf 'axb|5|2020-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  _gh_stub_timeline "a.b" 5 zed commented   # only reachable if the bug fires
  _gh_stub_page org 1 \
    "$(_row 5 2026-09-07T04:00:00Z alice "a.b" https://x/5 0 "brand new in a.b")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/a.b#5 opened by alice: brand new in a.b"* ]] || false
  [[ "$output" != *"comment by zed"* ]] || false
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

# P3-9's original fix (round 2: skip the mentions query once the org query
# is rate-limited) is moot as of P2-2 (2026-09-13 fix-round-3 review): the
# separate mentions query is gone entirely, not conditionally skipped — see
# the file header. Kept as a narrower assertion that a rate-limited org
# query makes exactly ONE search call, not a growing number across retries.
@test "watch github --once: a rate-limited org query makes exactly ONE search call, no second query exists to skip (P3-9)" {
  _gh_stub_install
  _gh_stub_fail org 1 1 'gh: HTTP 403: API rate limit exceeded (https://api.github.com/search/issues)'
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 1 ]
  [ ! -f "$GH_STUB_DIR/mentions.calls" ]
  [ "$(cat "$GH_STUB_DIR/org.calls")" = "1" ]
}

@test "watch github --once: a 5xx backs off with HONEST wording, not a rate-limit claim (P3-7)" {
  _gh_stub_install
  _gh_stub_fail org 1 1 'gh: HTTP 503: Service unavailable (https://api.github.com/search/issues)'
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"back"* ]] || false
  [[ "$output" == *"having problems"* ]] || false
  [[ "$output" != *"rate-limited"* ]] || false
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
  printf '99999\n' > "$lock/pid"   # P3-8: the (long-dead) holder's own pid
  # Backdate it well past the 300s staleness window — simulating a poll
  # that crashed mid-run and never released it.
  local past
  past="$(date -u -d '-10 minutes' +%Y%m%d%H%M.%S 2>/dev/null || date -u -v-10M +%Y%m%d%H%M.%S)"
  touch -t "$past" "$lock"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
  # P3-8: reclaiming a stale lock is no longer silent — a line, with the
  # dead holder's own pid, not just "something happened".
  [[ "$output" == *"stale poll lock (pid 99999,"* ]] || false
  [[ "$output" == *"reclaimed"* ]] || false
  # Released normally after the reclaimed poll finished — not left behind.
  [ ! -d "$lock" ]
}

# --- P2-2 (2026-09-13 fix-round-3 review): kind=mention now comes from the
# fetched activity's own BODY text (@-self, via the P1-1 timeline lookup
# already made for actor resolution), not a separate `mentions:<self>`
# search query — see the file header's WHY POLL, NOT STREAM. Both of these
# tests used to drive the removed mentions queue directly; rewritten to
# drive the same scenarios through the org query + a timeline body.

@test "watch github --once: a self-authored comment that @-mentions self is still not an event (P2-2)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf 'reef|200|2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  _gh_stub_timeline_page reef 200 1 \
    '[{"event":"commented","actor":{"login":"me"},"body":"talking to myself, cc @me"}]'
  _gh_stub_page org 1 \
    "$(_row 200 2026-09-07T06:00:00Z me reef https://x/200 0 "Self-authored, self-mentioned")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
  [[ "$output" != *"#200"* ]] || false
}

@test "watch github --once: a comment by someone else that @-mentions self reads kind=mention (P2-2)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf 'reef|201|2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  _gh_stub_timeline_page reef 201 1 \
    '[{"event":"commented","actor":{"login":"dave"},"body":"cc @me please look"}]'
  _gh_stub_page org 1 \
    "$(_row 201 2026-09-07T06:05:00Z alice reef https://x/201 0 "auth redirect")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#201 mention by dave: auth redirect"* ]] || false
  [[ "$output" == *"1 new event(s)"* ]] || false
}

@test "watch github --once: a mention of someone ELSE ('@dan') never matches self='dana' (word-boundary, P2-2)" {
  _gh_stub_install
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  printf 'reef|202|2026-01-01T00:00:00Z\n' > "$state_dir/CVERInc.seen"
  printf 'dana\n' > "$GH_STUB_DIR/login"
  _gh_stub_timeline_page reef 202 1 \
    '[{"event":"commented","actor":{"login":"dave"},"body":"cc @dan please look, not @danother either"}]'
  _gh_stub_page org 1 \
    "$(_row 202 2026-09-07T06:05:00Z alice reef https://x/202 0 "some issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"github CVERInc/reef#202 comment by dave: some issue"* ]] || false
  [[ "$output" != *"mention"* ]] || false
}

@test "watch github --once: a fresh issue whose OWN opening text @-mentions self still reads 'opened', not 'mention' (P2-2 scope)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 300 2026-09-07T06:05:00Z carol reef https://x/300 0 "cc @me please look")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  # No lookup happens for a fresh number — no body text to check — so this
  # stays "opened", documented scope, not a regression (see the file header
  # and docs/usage.md's caveat).
  [[ "$output" == *"github CVERInc/reef#300 opened by carol: cc @me please look"* ]] || false
  [[ "$output" != *"mention"* ]] || false
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

@test "watch github: --since '' is rejected, not silently ignored (P3-15)" {
  _gh_stub_install
  run clikae watch github --org CVERInc --since '' --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"--since"* ]] || false
  [[ "$output" == *"empty"* ]] || false
}

@test "watch github: --since garbage is rejected with a clear message" {
  _gh_stub_install
  run clikae watch github --org CVERInc --since 'yesterday' --once
  [ "$status" -eq 1 ]
  [[ "$output" == *"--since"* ]] || false
  [[ "$output" == *"ISO8601"* ]] || false
}

@test "watch github: a valid --since is accepted and reaches the query (positive control)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --since 2026-09-01T00:00:00Z --once
  [ "$status" -eq 0 ]
  [[ "$(cat "$GH_STUB_DIR/org.1.sent_query")" == *"updated:>=2026-09-01T00:00:00Z"* ]] || false
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

# P1-1 (2026-09-14 fix-round-4 review): earlier rounds lagged the cursor
# 300s behind the max seen, and asserted that lag reached the SENT query
# here. That lag was the permanent-stall bug (see CURSOR MONOTONICITY /
# BACKLOG in lib/commands/watch_github.sh) — the cursor, and therefore the
# next poll's query, now carries the EXACT max updated_at instead.
@test "watch github --once: the cursor sent next poll is the EXACT max seen, no lag (P2-8/P1-1)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:32:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  _gh_stub_page org 2 \
    "$(_row 101 2026-09-07T05:00:00Z bob reef https://x/101 0 "Second issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$(cat "$GH_STUB_DIR/org.2.sent_query")" == *"updated:>=2026-09-07T04:32:00Z"* ]] || false
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

# --- P1-2 (2026-09-13 fix-round-3 review): ascending pagination can never
# permanently stall — the round-2 fix ("pin the cursor to the oldest row
# READ") was correct arithmetic under `order=desc`, but desc order itself
# meant EVERY poll's page 1 was the same newest 100 rows: a busy org with
# >=500 rows in the window got truncated at page 5, computed the SAME
# cursor, every single poll, forever. Proven here with an HONEST stub (see
# _gh_stub_install_honest_corpus above) that actually filters/re-paginates,
# not a canned per-call fixture — 501 rows, every row delivered exactly
# once, and the cursor genuinely moves forward each time (not stuck).
#
# Revised (P1-1, 2026-09-14 fix-round-4 review): row #2501 now arrives
# DURING poll 1, not poll 2 — the tail sweep that fires right after a
# truncated poll (_wg_tail_sweep) re-reads the 300s below the brand-new
# cursor, desc order, and #2501 (only 10s past it) sits inside that
# window. That's a correct, even earlier, delivery — not a regression —
# see the P1-1 tests right below this one for the density this test's own
# 10s-apart corpus is too sparse to exercise (the actual round-4 bug).

@test "watch github --once: ascending pagination can never stall — 501 rows delivered exactly once, the tail caught by the same poll's sweep (P1-2/P1-1)" {
  _gh_stub_install_honest_corpus
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  # Cursor set just before row 1 (10s apart), so poll 1's query is `>=` a
  # value every one of the 501 rows already satisfies.
  local start_iso='2026-09-01T00:00:00Z'
  _honest_corpus_write 501 "$start_iso" 10
  printf '%s\n' "$start_iso" > "$state_dir/CVERInc.cursor"

  # --- poll 1: 5 full pages (500 rows) truncate the MAIN query — cursor
  # still moves forward to EXACTLY row #2500's own updated_at (no lag; NOT
  # stuck re-reading page 1's window — that's the bug this replaces) — and
  # the tail sweep that fires right after a truncated poll catches #2501
  # in the very same poll.
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"+more, will catch up next poll"* ]] || false
  [[ "$output" == *"501 new event(s) this poll. (truncated: continuing next poll)"* ]] || false
  [[ "$output" == *"github CVERInc/reef#2001 opened by alice: issue 1"* ]] || false
  [[ "$output" == *"github CVERInc/reef#2500 opened by alice: issue 500"* ]] || false
  [[ "$output" == *"github CVERInc/reef#2501 opened by alice: issue 501"* ]] || false
  local cursor1; cursor1="$(cat "$state_dir/CVERInc.cursor")"
  [ -n "$cursor1" ]
  [ "$cursor1" != "$start_iso" ]   # forward progress — round-2's bug left this stuck
  local ts2500; ts2500="$(awk -F'\t' '$1==2500{print $2}' "$GH_STUB_DIR/honest_corpus.tsv")"
  [ "$cursor1" = "$ts2500" ]       # EXACT, no lag (P1-1, fix-round-4)

  # --- poll 2: fully caught up now — 0 new events, no truncation, cursor
  # only ever advances (never regresses, even though this poll re-reads
  # #2500/#2501 via `>=` and folds their updated_at into the running max).
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s) this poll."* ]] || false
  [[ "$output" != *"+more, will catch up next poll"* ]] || false
  local cursor2; cursor2="$(cat "$state_dir/CVERInc.cursor")"
  [[ "$cursor2" > "$cursor1" || "$cursor2" == "$cursor1" ]] || false
  local ts2501; ts2501="$(awk -F'\t' '$1==2501{print $2}' "$GH_STUB_DIR/honest_corpus.tsv")"
  [ "$cursor2" = "$ts2501" ]

  # The whole point: all 501 rows reached the durable log exactly once —
  # round 2's own bug delivered 500 and then NEVER the 501st, on any poll.
  local events="$CLIKAE_HOME/logs/watch-github-CVERInc/events.jsonl"
  [ "$(wc -l < "$events")" -eq 501 ]
  [ "$(grep -c '"number":2001' "$events")" -eq 1 ]
  [ "$(grep -c '"number":2501' "$events")" -eq 1 ]
  [ "$(grep -oE '"number":[0-9]+' "$events" | sort -u | wc -l)" -eq 501 ]
}

# --- P1-1 (2026-09-14 fix-round-4 review): P1-2 above got `order=asc`
# right, but this file ALSO lagged the cursor 300s behind the max seen (to
# absorb GitHub search's own indexing delay) — and THAT alone recreated an
# identical permanent stall on a denser backlog: any 300-second window
# holding >=500 rows (the 5-page cap) put the lagged cursor back inside the
# very page a poll had just re-read, forever, silently reporting rc=0.
# Proven with the review's own densities (600 rows/0.6s-apart — a 300s
# window holds ~500 rows, the exact critical ratio; 800 rows/0.2s-apart —
# denser still) and a self-heal case (new activity an hour after a dense
# backlog fully drains — the old bug's rounds 1-3 never delivered this
# once stuck). Fixed by dropping the lag from the cursor entirely (see the
# CURSOR SEMANTICS note above _wg_query_org) — the 300s margin is instead
# bought by the separate, bounded _wg_tail_sweep exercised in the test
# right above this block.

@test "watch github --once: 600 rows 0.6s apart (a 300s window holds ~500 — the exact round-1..3 stall density) fully drain within 2 polls, cursor never regresses (P1-1)" {
  _gh_stub_install_honest_corpus
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  local start_iso='2026-09-01T00:00:00Z'
  _honest_corpus_write_dense 600 "$start_iso" 5 3   # 5 rows / 3s = 0.6s/row
  printf '%s\n' "$start_iso" > "$state_dir/CVERInc.cursor"

  local -a cursors=()
  local i cur
  for i in 1 2; do
    run clikae watch github --org CVERInc --once
    [ "$status" -eq 0 ] || { echo "poll $i: $output"; false; }
    cur="$(cat "$state_dir/CVERInc.cursor")"
    if [ "$i" -gt 1 ]; then
      [[ "$cur" > "${cursors[0]}" || "$cur" == "${cursors[0]}" ]] || { echo "cursor regressed: ${cursors[0]} -> $cur"; false; }
    fi
    cursors+=("$cur")
  done
  # A third poll must find nothing left — the whole backlog is drained,
  # not stuck reporting "truncated" forever the way rounds 1-3 did on this
  # exact density.
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s) this poll."* ]] || false
  [[ "$output" != *"+more, will catch up next poll"* ]] || false

  local events="$CLIKAE_HOME/logs/watch-github-CVERInc/events.jsonl"
  [ "$(wc -l < "$events")" -eq 600 ]
  [ "$(grep -oE '"number":[0-9]+' "$events" | sort -u | wc -l)" -eq 600 ]
  [ "$(grep -c '"number":2600' "$events")" -eq 1 ]
}

@test "watch github --once: 800 rows 0.2s apart (denser still) fully drain within 2 polls, cursor never regresses (P1-1)" {
  _gh_stub_install_honest_corpus
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  local start_iso='2026-09-01T00:00:00Z'
  _honest_corpus_write_dense 800 "$start_iso" 5 1   # 5 rows / 1s = 0.2s/row
  printf '%s\n' "$start_iso" > "$state_dir/CVERInc.cursor"

  local -a cursors=()
  local i cur
  for i in 1 2; do
    run clikae watch github --org CVERInc --once
    [ "$status" -eq 0 ] || { echo "poll $i: $output"; false; }
    cur="$(cat "$state_dir/CVERInc.cursor")"
    if [ "$i" -gt 1 ]; then
      [[ "$cur" > "${cursors[0]}" || "$cur" == "${cursors[0]}" ]] || { echo "cursor regressed: ${cursors[0]} -> $cur"; false; }
    fi
    cursors+=("$cur")
  done
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s) this poll."* ]] || false
  [[ "$output" != *"+more, will catch up next poll"* ]] || false

  local events="$CLIKAE_HOME/logs/watch-github-CVERInc/events.jsonl"
  [ "$(wc -l < "$events")" -eq 800 ]
  [ "$(grep -oE '"number":[0-9]+' "$events" | sort -u | wc -l)" -eq 800 ]
  [ "$(grep -c '"number":2800' "$events")" -eq 1 ]
}

@test "watch github --once: after a dense backlog fully drains, activity an hour later still wakes — no permanent stall (P1-1 self-heal)" {
  _gh_stub_install_honest_corpus
  local state_dir="$CLIKAE_HOME/state/watch-github"
  mkdir -p "$state_dir"
  local start_iso='2026-09-01T00:00:00Z'
  _honest_corpus_write_dense 600 "$start_iso" 5 3   # same critical density
  printf '%s\n' "$start_iso" > "$state_dir/CVERInc.cursor"

  # Drain it (2 polls suffice per the test above; give it 3 for margin).
  local i
  for i in 1 2 3; do
    run clikae watch github --org CVERInc --once
    [ "$status" -eq 0 ] || { echo "poll $i: $output"; false; }
  done
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s) this poll."* ]] || false

  # An hour later, 20 more rows land — the old bug's stuck cursor would
  # have made these unreachable forever (0/20 delivered, per the round-4
  # review's own self-heal measurement).
  _honest_corpus_append 2600 20 "2026-09-01T01:00:00Z" 10
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"20 new event(s) this poll."* ]] || false
  [[ "$output" == *"github CVERInc/reef#2601 opened by alice: late issue 1"* ]] || false
  [[ "$output" == *"github CVERInc/reef#2620 opened by alice: late issue 20"* ]] || false

  local events="$CLIKAE_HOME/logs/watch-github-CVERInc/events.jsonl"
  [ "$(wc -l < "$events")" -eq 620 ]
  [ "$(grep -c '"number":2620' "$events")" -eq 1 ]
}

# --- P2-3 (2026-09-13 fix-round-2 review): end to end, `clikae wait --latest
# watch-github-<org>` against the REAL writer, no epoch known in advance —
# the whole point of the fix (a cockpit can only know the prefix).

# P3-2 (2026-09-13 fix-round-3 review): documented, not changed — the run
# status file deliberately does NOT follow a $CLIKAE_HOME override (same
# as burn's own status files never have; `clikae wait` only knows how to
# resolve $HOME's layout). Regression guard: this needs to stay true, or
# the docs/usage.md and --help notes added this round go stale silently.
@test "watch github --once: the run status file lands under \$HOME even when \$CLIKAE_HOME is sandboxed elsewhere (P3-2)" {
  _gh_stub_install
  local real_clikae_home="$CLIKAE_HOME"
  export CLIKAE_HOME="$TEST_HOME/elsewhere/.clikae-sandbox"
  mkdir -p "$CLIKAE_HOME"
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  # cursor/seen/events DO follow the sandboxed CLIKAE_HOME...
  [ -f "$CLIKAE_HOME/state/watch-github/CVERInc.cursor" ]
  [ -f "$CLIKAE_HOME/logs/watch-github-CVERInc/events.jsonl" ]
  # ...but the run status file (what `clikae wait` reads) does NOT — it's
  # under real $HOME/.clikae/logs, same as burn's own.
  local status_file
  status_file="$(find "$real_clikae_home/logs" -maxdepth 2 -path '*/watch-github-CVERInc-*/status.json' | head -n1)"
  [ -n "$status_file" ]
  [ -f "$status_file" ]
  ! find "$CLIKAE_HOME/logs" -maxdepth 2 -path '*/watch-github-CVERInc-*/status.json' | grep -q .
}

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

@test "watch github --once: the status file's artifact is THIS poll's own events, not the accumulated log (P3-11)" {
  _gh_stub_install
  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  local status_file
  status_file="$(find "$CLIKAE_HOME/logs" -maxdepth 2 -path '*/watch-github-CVERInc-*/status.json' | head -n1)"
  local artifact
  artifact="$(grep -oE '"artifact":"[^"]*"' "$status_file" | sed -E 's/.*"([^"]*)"$/\1/')"
  # NOT the durable, accumulated log.
  [ "$artifact" != "$CLIKAE_HOME/logs/watch-github-CVERInc/events.jsonl" ]
  [ -f "$artifact" ]
  [ "$(wc -l < "$artifact")" -eq 1 ]
  grep -q '"number":100' "$artifact"

  # A SECOND poll's own artifact must not repeat the first poll's event.
  _gh_stub_page org 2 \
    "$(_row 101 2026-09-07T04:40:00Z bob reef https://x/101 0 "Second issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  local status_file2 artifact2
  status_file2="$(find "$CLIKAE_HOME/logs" -maxdepth 2 -path '*/watch-github-CVERInc-*/status.json' -newer "$status_file" | head -n1)"
  artifact2="$(grep -oE '"artifact":"[^"]*"' "$status_file2" | sed -E 's/.*"([^"]*)"$/\1/')"
  [ "$(wc -l < "$artifact2")" -eq 1 ]
  grep -q '"number":101' "$artifact2"
  ! grep -q '"number":100' "$artifact2"
}

@test "watch github --once: two runs in the same second get DIFFERENT directories, not a silent overwrite (P3-10)" {
  _gh_stub_install
  # A real wall-clock race (two --once calls landing in the same second) is
  # exactly what this covers, but polling the REAL clock for it would make
  # the test itself flaky at a second boundary — pin `date +%s` instead, real
  # `date` for everything else (ISO8601 formatting, mtime math, …).
  local real_date; real_date="$(command -v date)"
  cat > "$TEST_HOME/.testbin/date" <<STUB
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\$1" = "+%s" ]; then printf '1700000000\n'; exit 0; fi
exec "$real_date" "\$@"
STUB
  chmod +x "$TEST_HOME/.testbin/date"

  mkdir -p "$HOME/.clikae/logs/watch-github-CVERInc-1700000000"
  printf '{"ok":true}\n' > "$HOME/.clikae/logs/watch-github-CVERInc-1700000000/status.json"

  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  # The pre-existing same-second directory is untouched...
  grep -qxF '{"ok":true}' "$HOME/.clikae/logs/watch-github-CVERInc-1700000000/status.json"
  # ...and this poll's own write landed in a DIFFERENT, counter-suffixed one.
  [ -f "$HOME/.clikae/logs/watch-github-CVERInc-1700000000-2/status.json" ]
  grep -q '"run_id":"watch-github-CVERInc-1700000000-2"' \
    "$HOME/.clikae/logs/watch-github-CVERInc-1700000000-2/status.json"
}

@test "watch github --once: run directories rotate, keeping the newest 200 (P3-10)" {
  _gh_stub_install
  local base="$HOME/.clikae/logs" i past
  mkdir -p "$base"
  for i in $(seq 1 205); do
    mkdir -p "$base/watch-github-CVERInc-fake$i"
    printf '{"ok":true}\n' > "$base/watch-github-CVERInc-fake$i/status.json"
    past="$(date -u -d "-$((300 - i)) minutes" +%Y%m%d%H%M.%S 2>/dev/null || date -u -v-"$((300 - i))"M +%Y%m%d%H%M.%S)"
    touch -t "$past" "$base/watch-github-CVERInc-fake$i"   # the DIRECTORY's own mtime — that's what rotation sorts on
  done

  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  local n; n="$(find "$base" -maxdepth 1 -type d -name 'watch-github-CVERInc-*' | wc -l)"
  [ "$n" -eq 200 ]
  # The OLDEST fake ones (lowest i, backdated furthest) are gone...
  [ ! -d "$base/watch-github-CVERInc-fake1" ]
  # ...the newest fake ones, and this poll's own real run, survive.
  [ -d "$base/watch-github-CVERInc-fake205" ]
}

@test "watch github --once: the durable events.jsonl rotates at 10MB (P3-12)" {
  _gh_stub_install
  local events="$CLIKAE_HOME/logs/watch-github-CVERInc/events.jsonl"
  mkdir -p "$(dirname "$events")"
  # ~12.1MB of padding (1,100,000 x 11-byte lines) — comfortably past the cap.
  yes '0123456789' | head -n 1100000 > "$events"

  _gh_stub_page org 1 \
    "$(_row 100 2026-09-07T04:00:00Z alice reef https://x/100 0 "First issue")"
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]

  local sz; sz="$(wc -c < "$events")"
  [ "$sz" -le "$((10 * 1024 * 1024))" ]
  # The newest line — this poll's own event, appended before rotation ran —
  # survived; rotation trims the OLD end, not the new one.
  tail -n1 "$events" | grep -q '"number":100'
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
