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

exit 1
STUB
  chmod +x "$TEST_HOME/.testbin/gh"
  printf '0\n' > "$GH_STUB_DIR/auth_rc"
  printf 'me\n' > "$GH_STUB_DIR/login"
}

# _gh_stub_page <org|mentions> <call#> <tsv-lines...> — seed one call's TSV
# response. Each line is already tab-separated: number, updated_at, login,
# repo, html_url, is_pr, title — the exact shape _wg_fetch's jq filter emits.
_gh_stub_page() {
  local queue="$1" n="$2"; shift 2
  printf '%s\n' "$@" > "$GH_STUB_DIR/$queue.$n.tsv"
}

_gh_stub_fail() {
  local queue="$1" n="$2" rc="$3" err="$4"
  printf '%s\n' "$rc" > "$GH_STUB_DIR/$queue.$n.rc"
  printf '%s\n' "$err" > "$GH_STUB_DIR/$queue.$n.err"
}

_row() { # number updated login repo html_url is_pr title
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
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

@test "watch github --once: a 403 body means no cursor advance and a back-off line" {
  _gh_stub_install
  _gh_stub_fail org 1 1 'gh: HTTP 403: API rate limit exceeded (https://api.github.com/search/issues)'
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]   # --once still exits 0 — see the next test
  [[ "$output" == *"403"* ]] || false
  [[ "$output" == *"back"* ]] || false
  [ ! -f "$CLIKAE_HOME/state/watch-github/CVERInc.cursor" ]
}

@test "watch github --once exits 0 after one poll (even with zero events)" {
  _gh_stub_install
  run clikae watch github --org CVERInc --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 new event(s)"* ]] || false
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

@test "watch github: rejects a bad --interval" {
  _gh_stub_install
  run clikae watch github --org CVERInc --interval notaduration --once
  [ "$status" -ne 0 ]
  [[ "$output" == *"--interval"* ]] || false
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
