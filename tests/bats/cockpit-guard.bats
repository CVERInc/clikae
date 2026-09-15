#!/usr/bin/env bats
load '../helpers'

# lib/hooks/cockpit-guard.sh — the PreToolUse hook itself, exercised directly
# (stdin payload in, stdout/stderr + exit code out) rather than through a real
# Claude Code session. Contract: exit 0 = allow, exit 2 = blocked with the
# reason on stderr (docs.claude.com/en/docs/claude-code/hooks). See
# tests/bats/cockpit.bats for the `clikae cockpit` command that installs it.

GUARD="$CLIKAE_TEST_ROOT/lib/hooks/cockpit-guard.sh"
FIXTURE_REAL="$CLIKAE_TEST_ROOT/tests/fixtures/cockpit-guard/real-pretooluse-payload.json"

_guard() { printf '%s' "$1" | bash "$GUARD"; }
_guard_file() { bash "$GUARD" < "$1"; }

@test "allows a non-Agent tool without looking at model/prompt at all" {
  run _guard '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
  [ "$status" -eq 0 ]
}

@test "allows a haiku Explore spawn" {
  run _guard '{"tool_name":"Agent","tool_input":{"model":"haiku","subagent_type":"Explore","prompt":"look around the repo and summarize"}}'
  [ "$status" -eq 0 ]
}

@test "refuses a sonnet build brief mentioning worktree" {
  run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"make a worktree and implement the feature"}}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"clikae burn <engine> <tank>"* ]] || false
}

@test "refuses a missing-model spawn regardless of the prompt" {
  run _guard '{"tool_name":"Agent","tool_input":{"prompt":"just summarize this file, nothing fancy"}}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"carried no model"* ]] || false
}

@test "allows an opus spawn whose prompt has no lane heuristic" {
  run _guard '{"tool_name":"Agent","tool_input":{"model":"opus","prompt":"read these three files and tell me what they do"}}'
  [ "$status" -eq 0 ]
}

@test "each documented heuristic phrase refuses a sonnet/opus spawn" {
  local prompts=(
    "set up a worktree for this"
    "then git commit the result"
    "and git push when done"
    "act as REVIEWER on this diff"
    "run an adversarial review pass"
    "bats tests/bats/foo.bats"
    "npm test should be green"
    "run vitest once"
    "run the test suite"
    "run the full test suite"
  )
  local p
  for p in "${prompts[@]}"; do
    run _guard "$(printf '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"%s"}}' "$p")"
    [ "$status" -eq 2 ] || { echo "expected refuse for: $p" >&2; false; }
  done
}

@test "allows the real captured PreToolUse payload (#63 P1-1, compact JSON)" {
  # tests/fixtures/cockpit-guard/real-pretooluse-payload.json is byte-for-byte
  # (minus identifiers) what a real `claude -p` session sent this hook,
  # captured under a throwaway HOME — see the fixture's own README.md. It's a
  # haiku spawn with an innocuous prompt, so it should sail through untouched.
  [ -f "$FIXTURE_REAL" ]
  run _guard_file "$FIXTURE_REAL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the whitespace fix reaches end to end: a pretty-printed payload refuses like its compact twin (#63 P1-1)" {
  # The round-1 review's fixture (compact) is `refuses a sonnet build brief
  # mentioning worktree` above. This is the exact same payload, pretty-
  # printed with spaced colons, the shape the old zero-tolerance pattern in
  # json.sh went silently blind on.
  local pretty
  pretty="$(printf '%s\n' \
    '{' \
    '  "tool_name": "Agent",' \
    '  "tool_input": {' \
    '    "model": "sonnet",' \
    '    "prompt": "make a worktree and implement the feature"' \
    '  }' \
    '}')"
  run _guard "$pretty"
  [ "$status" -eq 2 ]
  [[ "$output" == *"clikae burn <engine> <tank>"* ]] || false
}

@test "no tool_name field at all REFUSES, fail-closed (#63 P1-2, r5 P2-5)" {
  run _guard '{"foo":"bar"}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"no tool_name field"* ]] || false
  [[ "$output" == *"fails closed"* ]] || false
}

@test "an ordinary non-Agent tool call stays silent (no stderr note, unlike a truly malformed payload)" {
  run _guard '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tool_input entirely absent REFUSES with its own reason, fail-closed (#63 P1-2, r5 P2-5)" {
  run _guard '{"tool_name":"Agent"}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"no tool_input field"* ]] || false
}

@test "truncated tool_input JSON REFUSES as malformed, not as a model-less spawn (#63 P1-2, r5 P2-5)" {
  # The round-1 repro hit the "carried no model" reason — the wrong one.
  # Round 5 keeps the reason right and the verdict closed.
  run _guard '{"tool_name":"Agent","tool_input":{"prompt":"x"'
  [ "$status" -eq 2 ]
  [[ "$output" == *"truncated or malformed"* ]] || false
  [[ "$output" != *"carried no model"* ]] || false
}

@test "honours the env escape hatch" {
  CLIKAE_COCKPIT_ALLOW_AGENTS=1 run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLIKAE_COCKPIT_ALLOW_AGENTS"* ]] || false
}

@test "honours a live timed allowance and names its expiry" {
  mkdir -p "$CLIKAE_HOME/state"
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$CLIKAE_HOME/state/cockpit-allow"
  run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"allowed until"* ]] || false
}

@test "an expired timed allowance refuses again" {
  mkdir -p "$CLIKAE_HOME/state"
  printf '%s\n' "$(( $(date +%s) - 10 ))" > "$CLIKAE_HOME/state/cockpit-allow"
  run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}'
  [ "$status" -eq 2 ]
}

@test "names the current reserve, excluding the cockpit tank itself" {
  mkdir -p "$CLIKAE_HOME/state" \
    "$CLIKAE_HOME/profiles/claude/cockpit-tank" \
    "$CLIKAE_HOME/profiles/claude/worker1" \
    "$CLIKAE_HOME/profiles/codex/worker2"
  # #61 round-5 merge: a tank is a directory with clikae's own marker, never
  # a bare mkdir (helpers.bash stamps this store as already adopted, exactly
  # like a real one) — so the reserve fixture writes the markers `clikae
  # init` would have written.
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/cockpit-tank/.clikae-tank"
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/worker1/.clikae-tank"
  printf 'codex\n' > "$CLIKAE_HOME/profiles/codex/worker2/.clikae-tank"
  printf 'claude/cockpit-tank\n' > "$CLIKAE_HOME/state/cockpit"
  run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"claude/worker1"* ]] || false
  [[ "$output" == *"codex/worker2"* ]] || false
  [[ "$output" != *"claude/cockpit-tank"* ]] || false
}

@test "fails CLOSED on an empty payload (#63 r5 P2-5)" {
  run _guard ''
  [ "$status" -eq 2 ]
  [[ "$output" == *"empty payload"* ]] || false
}

@test "fails CLOSED on malformed JSON (#63 r5 P2-5)" {
  run _guard 'not json at all, just noise'
  [ "$status" -eq 2 ]
  [[ "$output" == *"fails closed"* ]] || false
}

@test "the escape hatches still lift a fail-closed refusal: they are read before the payload (#63 r5 P2-5)" {
  CLIKAE_COCKPIT_ALLOW_AGENTS=1 run _guard 'not json at all'
  [ "$status" -eq 0 ]
  mkdir -p "$CLIKAE_HOME/state"
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$CLIKAE_HOME/state/cockpit-allow"
  run _guard ''
  [ "$status" -eq 0 ]
  [[ "$output" == *"allowed until"* ]] || false
}

@test "a missing dependency (no jq on PATH) refuses instead of allowing (#63 r5 P2-5/P2-6)" {
  local nojq="$BATS_TEST_TMPDIR/nojq"
  path_without_jq "$nojq"
  PATH="$nojq" command -v jq >/dev/null 2>&1 && skip "jq is on PATH even without /usr/bin and /bin"
  run env PATH="$nojq" bash "$GUARD" <<<'{"tool_name":"Agent","tool_input":{"model":"haiku","prompt":"hi"}}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"jq is not installed"* ]] || false
  [[ "$output" == *"fails closed"* ]] || false
}

# --- #63 round-5 P2-6: equivalent JSON serializations -----------------------
# codex review: starting from a refused sonnet/review call, six changes to
# the SERIALIZATION ONLY turned refuse into allow on f20a603. Each must now
# refuse with byte-for-byte the same stderr as the plain form.
_P26_PLAIN='{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"review"}}'

@test "six serialization variants of a refused call all refuse with the plain form's exact stderr (#63 r5 P2-6)" {
  run _guard "$_P26_PLAIN"
  [ "$status" -eq 2 ]
  local plain="$output"
  [[ "$plain" == *"a sonnet-model Agent spawn whose prompt reads as a build/review lane"* ]] || false
  local -a names=() variants=()
  names+=("trailing space");     variants+=("$_P26_PLAIN ")
  names+=("trailing tab");       variants+=("$_P26_PLAIN"$'\t')
  names+=("trailing CRLF");      variants+=("$_P26_PLAIN"$'\r\n')
  names+=("model \\u0073onnet"); variants+=('{"tool_name":"Agent","tool_input":{"model":"\u0073onnet","prompt":"review"}}')
  names+=("tool \\u0041gent");   variants+=('{"tool_name":"\u0041gent","tool_input":{"model":"sonnet","prompt":"review"}}')
  names+=("prompt \\u0072eview"); variants+=('{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"\u0072eview"}}')
  names+=("key tool\\u005finput"); variants+=('{"tool_name":"Agent","tool\u005finput":{"model":"sonnet","prompt":"review"}}')
  local i
  for i in "${!variants[@]}"; do
    run _guard "${variants[$i]}"
    [ "$status" -eq 2 ] || { echo "${names[$i]}: status=$status output=$output" >&2; false; }
    [ "$output" = "$plain" ] || { echo "${names[$i]}: stderr differs from the plain form:" >&2; echo "$output" >&2; false; }
  done
}

@test "a surrogate pair decodes to ONE character: 1,000 emoji + an innocuous word stays under the length tripwire (#63 r5 P2-6)" {
  # Counted as 2 UTF-16 units (or 12 raw escape characters) each, this
  # prompt would be over 1,500 and refused on length; decoded correctly it
  # is 1,010 characters with no keyword, and allowed.
  local emoji="" i
  for i in $(seq 1 1000); do emoji="$emoji"'\ud83d\ude00'; done
  run _guard "{\"tool_name\":\"Agent\",\"tool_input\":{\"model\":\"sonnet\",\"prompt\":\"$emoji summarize\"}}"
  [ "$status" -eq 0 ]
  # ...and the same prompt with an escaped keyword after the emoji refuses.
  run _guard "{\"tool_name\":\"Agent\",\"tool_input\":{\"model\":\"sonnet\",\"prompt\":\"$emoji \\u0072eview\"}}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"build/review lane"* ]] || false
}

@test "a model field elsewhere in the payload cannot stand in for tool_input.model (#63 r5 P2-6)" {
  # codex review, structure note: an earlier metadata.model="haiku" was the
  # first "model" the flat scan found, and the sonnet call was allowed.
  run _guard '{"metadata":{"model":"haiku"},"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"review"}}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"a sonnet-model Agent spawn"* ]] || false
}

@test "two concatenated JSON objects are malformed input, refused (#63 r5 P2-6)" {
  run _guard '{"tool_name":"Agent","tool_input":{"model":"haiku","prompt":"x"}}{"tool_name":"Agent"}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"not one well-formed JSON object"* ]] || false
}

# --- #63 round-5 P2-5: SIGPIPE on large pretty-printed payloads --------------
# codex review: at 65,536 / 131,073 / 1,048,576 filler characters the compact
# form refused and the pretty form (json.dumps indent=2) ALLOWED — the
# tool_input presence test was `printf | grep -q`, and grep's early exit
# killed printf with SIGPIPE under pipefail. Filler is varied prose, not one
# repeated byte, and carries no heuristic keyword (the prompt's own "review"
# is the only one).
_big_payload() {
  python3 - "$1" "$2" <<'PY'
import json, sys
n, form = int(sys.argv[1]), sys.argv[2]
words = "alpha bravo charlie delta echo foxtrot golf hotel india juliett kilo lima mike "
filler = (words * (n // len(words) + 1))[:n]
obj = {"tool_name": "Agent", "tool_input": {"model": "sonnet", "prompt": "review " + filler}}
sys.stdout.write(json.dumps(obj, indent=2) if form == "pretty" else json.dumps(obj))
PY
}

@test "large payloads refuse in BOTH compact and pretty-printed form: 65,536 / 131,073 / 1,048,576 (#63 r5 P2-5)" {
  local n form f
  for n in 65536 131073 1048576; do
    for form in compact pretty; do
      f="$BATS_TEST_TMPDIR/big-$n-$form.json"
      _big_payload "$n" "$form" > "$f"
      run _guard_file "$f"
      [ "$status" -eq 2 ] || { echo "n=$n form=$form status=$status output=$output" >&2; false; }
      [[ "$output" == *"length tripwire"* ]] || { echo "n=$n form=$form: $output" >&2; false; }
    done
  done
}

@test "runs comfortably inside the 50ms budget" {
  local t0 t1 ms
  t0="$(date +%s%N)"
  # This payload REFUSES (exit 2) by design — that's the more expensive path
  # (it enumerates the reserve) — so the timing matters more here than on an
  # allow. `|| true`: a bats test body fails on any unguarded nonzero exit.
  _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}' >/dev/null 2>/dev/null || true
  t1="$(date +%s%N)"
  ms=$(( (t1 - t0) / 1000000 ))
  echo "elapsed: ${ms}ms" >&2
  # The real budget (docstring, PR description) is <50ms, measured ~7-25ms on
  # an idle host. This bound is deliberately much looser: bats runs can share
  # this host with several OTHER full suites at once (measured 273ms here
  # under a 5-way pile-up, load average 18) — a hard-coded near-50ms bound
  # would be a flaky CI assertion, not a real regression signal. This just
  # catches the catastrophic case (an infinite loop, an accidental network
  # call) that no amount of host contention explains.
  [ "$ms" -lt 5000 ]
}

# --- #63 P2-5: the reviewer's 14-item corpus ---------------------------------
# 8 prompts that SHOULD read as a build/review lane, 6 that SHOULD NOT. 7 of
# the 14 are the review's own quoted examples (REVIEW-cockpit63-r1.md); the
# other 7 are added here to round the corpus out (4 refuse-side prompts that
# already matched under the pre-fix regex, 3 allow-side prompts with no
# heuristic word in them at all).
#
# Each row is "<ideal>\t<actual>\t<prompt>": <ideal> is what a human would
# want (refuse = reads as dispatchable build/review work); <actual> is what
# THIS heuristic — the issue's narrow phrases OR'd with a widened bare-verb
# set (docstring, cockpit-guard.sh) — really does. For 11/14, ideal == actual.
# For 3 (marked below), the widened regex still can't tell "explains/asks
# about X" from "do X" without either false-allowing the matching refuse-side
# prompt or false-refusing these — see docs/usage.md's cockpit section for
# the writeup. This table asserts <actual>, not <ideal>: that's what makes it
# a regression test rather than an aspiration.
_CKPT_CORPUS=(
  # --- should refuse (8) ---
  "refuse	refuse	Implement the fix, commit it, and open a PR"
  "refuse	refuse	Build the feature in a new branch and push it when tests pass"
  "refuse	refuse	Fix the failing unit tests in src/auth and make CI green"
  "refuse	refuse	Do a code review of the changes on this branch and grade P1/P2"
  "refuse	refuse	Set up a worktree and get this feature building"
  "refuse	refuse	Please git commit these changes and git push them"
  "refuse	refuse	Act as REVIEWER on this diff and flag every P1"
  "refuse	refuse	Run the full test suite and report back"
  # --- should allow (6) ---
  "allow	refuse	Explain what the phrase \"git push --force-with-lease\" does, do not run anything"
  "allow	refuse	Read docs/usage.md and tell me whether the worktree section is accurate"
  "allow	refuse	What does our CONTRIBUTING.md say about running npm test locally?"
  "allow	allow	Summarize what these three files do, in plain English"
  "allow	allow	List the open issues labeled bug in this repository"
  "allow	allow	Translate this error message into Traditional Chinese"
)

@test "the 14-item corpus: heuristic hit rate matches its documented, measured behavior" {
  local row ideal actual_expected prompt esc want_status got_status hits=0 misses=""
  for row in "${_CKPT_CORPUS[@]}"; do
    ideal="${row%%$'\t'*}"
    row="${row#*$'\t'}"
    actual_expected="${row%%$'\t'*}"
    prompt="${row#*$'\t'}"
    [ "$actual_expected" = refuse ] && want_status=2 || want_status=0
    # A couple of these prompts (deliberately) contain a literal `"` — JSON-
    # escape before splicing into the payload, or the embedded quote closes
    # the JSON string early and the test measures its own bug, not the guard.
    esc="${prompt//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    run _guard "$(printf '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"%s"}}' "$esc")"
    got_status="$status"
    [ "$got_status" -eq "$want_status" ] || {
      echo "MISMATCH (expected the code's own documented behavior, got something else): $prompt" >&2
      echo "  expected actual=$actual_expected (status $want_status), got status $got_status" >&2
      false
    }
    [ "$ideal" = "$actual_expected" ] && hits=$((hits + 1)) || misses="$misses|$prompt"
  done
  echo "corpus: ${hits}/14 match the ideal outcome (target >= 12; misses are documented in docs/usage.md, not silently accepted): $misses" >&2
  # Not asserted at >=12 here: the 3 known misses are structural (fixing them
  # would false-allow a should-refuse sibling in this same table — see the
  # comment above _CKPT_CORPUS). This test's job is regression: catch the
  # heuristic drifting further from what it already, measurably, does.
  [ "$hits" -ge 11 ]
}

# --- #63 P3-5: a SECOND corpus, chosen adversarially to be innocuous -------
# (round-2 review, REVIEW-cockpit63-r2.md, plus 4 more in the same spirit)
# rather than to round out the first table. docs/usage.md's "All 3 misses"
# undersold the false-refusal rate — it's a property of the 14-item corpus,
# not a bound. This asserts the CURRENT, honestly-measured outcome (2/10
# allowed), same philosophy as the 14-item test above: catch drift, don't
# pretend the heuristic is better than it is.
_CKPT_FALSE_REFUSAL_CORPUS=(
  "refuse	Find every file that mentions push notifications and list them"
  "refuse	Review the attached spec and tell me if the wording is clear"
  "refuse	What does the word \"commit\" mean in the context of database transactions?"
  "refuse	Explain how git worktrees differ from clones, conceptually"
  "refuse	Search the codebase for where we grade student submissions"
  "allow	Summarize the customer reviews in reviews.csv"
  "refuse	What does npm test actually run under the hood?"
  "refuse	Can you explain what 'open a PR' means for someone new to GitHub?"
  "allow	List the files that were pushed in the last release"
  "refuse	Grade how readable this poem is, out of 10"
)

@test "the 10-item false-refusal corpus: outcome matches docs/usage.md's table (#63 P3-5)" {
  local row actual_expected prompt esc want_status got_status
  for row in "${_CKPT_FALSE_REFUSAL_CORPUS[@]}"; do
    actual_expected="${row%%$'\t'*}"
    prompt="${row#*$'\t'}"
    [ "$actual_expected" = refuse ] && want_status=2 || want_status=0
    esc="${prompt//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    run _guard "$(printf '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"%s"}}' "$esc")"
    got_status="$status"
    [ "$got_status" -eq "$want_status" ] || {
      echo "docs/usage.md's table is now wrong for: $prompt (expected $actual_expected/$want_status, got $got_status)" >&2
      false
    }
  done
}

# --- #63 P1-1/P2-1 fix2 (REVIEW-cockpit63-r2.md): NON-UNIFORM large-payload
# specimens ------------------------------------------------------------------
# Round 1's large-payload fixtures here were a single repeated ASCII byte
# (`big="x"`) -- structurally unable to exercise the bug round 2 found: a
# multi-byte UTF-8 character, or a JS-escaped `\n`, straddling the byte
# offset that a `head -c 8192` pre-slice used to cut on. Every specimen below
# is generated by tests/fixtures/cockpit-guard/gen_specimen.py -- genuine
# zh+en prose or a deliberately positioned escape, never a uniform repeat.
GEN="$CLIKAE_TEST_ROOT/tests/fixtures/cockpit-guard/gen_specimen.py"

@test "a multi-byte character straddling the old 8192-byte cut still refuses (#63 P1-1 fix2)" {
  # gen_specimen.py self-checks (exit 2, to stderr) that byte offset 8192 of
  # the payload it built really does land mid multi-byte character -- this
  # is round 2's primary repro (measured 46/109 on real zh+en text).
  run _guard_file <(python3 "$GEN" straddle-cjk)
  [ "$status" -eq 2 ]
  [[ "$output" == *"length tripwire"* || "$output" == *"build/review lane"* ]] || false
}

@test "a JS-escaped \\n straddling the old 8192-byte cut still refuses (#63 P1-1 fix2)" {
  # The pure-ASCII half of the same bug (round 2: 4/109) -- the backslash of
  # an escaped newline sits exactly on the old cut point.
  run _guard_file <(python3 "$GEN" straddle-escape)
  [ "$status" -eq 2 ]
}

@test "100 synthetic zh+en briefs over 8 KiB all refuse on sonnet (#63 P1-1 fix2)" {
  # Each of the 100 is genuine zh+en prose, shifted by a different amount of
  # padding so the byte alignment differs across the corpus (the sliding-
  # cut-point idea from the round-2 review's own 109-trial sweep, turned
  # into a fixed regression corpus). On the PRE-fix2 guard roughly HALF of
  # an equivalent 100-item sample silently allow (measured while building
  # this test, see REPORT-cockpit63-fix2.md) -- 100/100 here is the bar.
  local hits=0 seed rc
  for seed in $(seq 0 99); do
    # `if`, not a bare pipeline: bats runs test bodies under errexit, and a
    # refuse (rc=2) is the EXPECTED outcome here, not a test error.
    if python3 "$GEN" brief "$seed" | bash "$GUARD" >/dev/null 2>/dev/null; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -eq 2 ]; then
      hits=$((hits + 1))
    else
      echo "MISS seed=$seed rc=$rc" >&2
    fi
  done
  echo "refused: ${hits}/100" >&2
  [ "$hits" -eq 100 ]
}

@test "a prompt over 8,192 characters with NO heuristic keyword still refuses on length alone (#63 P1-1 fix2)" {
  # Isolates the length tripwire from the keyword heuristic: this specimen
  # is plain English filler, nothing in it matches _CKPT_HEURISTIC. Proves
  # prompt_len_full (the UNTRUNCATED count) is what feeds the tripwire, not
  # the 8,192-CHARACTER copy truncated for the heuristic.
  run _guard_file <(python3 "$GEN" long-plain 0)
  [ "$status" -eq 2 ]
  [[ "$output" == *"length tripwire"* ]] || false
}

@test "\`model\` before a large prompt is found either way (#63 P2-1 fix2)" {
  # Round 1 capped `prompt` reading it from a head slice and read `model`
  # from a TAIL slice on the theory `model` always comes after `prompt` in
  # tool_input -- true of every real capture so far, but not guaranteed
  # (round-2 review: key order is generation-time, not schema-enforced).
  # Same payload shape, `model` BEFORE `prompt` this time: haiku must still
  # be silently allowed, sonnet must still refuse (for the real reason, not
  # "carried no model" -- that used to be the failure mode for BOTH models).
  run _guard_file <(python3 "$GEN" model-before-prompt haiku)
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run _guard_file <(python3 "$GEN" model-before-prompt sonnet)
  [ "$status" -eq 2 ]
  [[ "$output" != *"carried no model"* ]] || false
}

@test "family-prefixed model ids refuse like their short aliases (#63 P3-1)" {
  # An EXACT `opus|sonnet` match (round 1) silently allowed every real API
  # model id -- only the short aliases matched. `opusplan` is a real value
  # (not a family prefix) matched literally.
  local m
  for m in claude-sonnet-4-5-20250929 claude-opus-4-5 opusplan; do
    run _guard "$(printf '{"tool_name":"Agent","tool_input":{"model":"%s","prompt":"make a worktree and implement the feature"}}' "$m")"
    [ "$status" -eq 2 ] || { echo "expected refuse for model=$m" >&2; false; }
  done
  # A model that merely CONTAINS "sonnet" is not matched AS sonnet -- but
  # since round 5 (P3-2) an id the guard cannot place is checked like
  # opus/sonnet rather than waved through, and the refusal says so.
  run _guard '{"tool_name":"Agent","tool_input":{"model":"not-a-sonnet-clone","prompt":"make a worktree and implement the feature"}}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unrecognised model id (not-a-sonnet-clone"* ]] || false
}

@test "provider-spelled ids are placed in their family; unknown ids are checked, never silently allowed (#63 r5 P3-2)" {
  local lane='make a worktree and implement the feature' m
  # checked families, in provider spellings
  for m in us.anthropic.claude-sonnet-4-5-v1:0 anthropic.claude-opus-4-1-v1:0 'claude-sonnet-4-5@20250929' 'sonnet[1m]' claude-3-5-sonnet-20241022; do
    run _guard "$(printf '{"tool_name":"Agent","tool_input":{"model":"%s","prompt":"%s"}}' "$m" "$lane")"
    [ "$status" -eq 2 ] || { echo "expected refuse for $m" >&2; false; }
    [[ "$output" != *"unrecognised"* ]] || { echo "$m should be recognised: $output" >&2; false; }
  done
  # exempt families, in provider spellings: silent allow
  for m in haiku us.anthropic.claude-haiku-4-5-v1:0 'claude-haiku-4-5@20251001' claude-3-5-haiku-20241022 fable; do
    run _guard "$(printf '{"tool_name":"Agent","tool_input":{"model":"%s","prompt":"%s"}}' "$m" "$lane")"
    [ "$status" -eq 0 ] || { echo "expected allow for $m" >&2; false; }
    [ -z "$output" ] || { echo "expected silence for $m: $output" >&2; false; }
  done
  # unknown ids: refused on the tripwire, named as unrecognised...
  for m in unexpected inherit; do
    run _guard "$(printf '{"tool_name":"Agent","tool_input":{"model":"%s","prompt":"%s"}}' "$m" "$lane")"
    [ "$status" -eq 2 ] || { echo "expected refuse for $m" >&2; false; }
    [[ "$output" == *"unrecognised model id ($m"* ]] || false
  done
  # ...and allowed with a visible line when the prompt does not trip.
  run _guard '{"tool_name":"Agent","tool_input":{"model":"unexpected","prompt":"summarize these three files"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"allowed an Agent spawn with an unrecognised model id (unexpected)"* ]] || false
}

# --- #63 P2-7: large-payload timing (re-measured for fix2's full-payload
# extraction -- see REPORT-cockpit63-fix2.md for the 200 kB / 1 MB numbers
# and how they were measured; several other lanes' full suites shared this
# host throughout) --------------------------------------------------------

@test "a 200kB prompt stays inside a generous timing budget (median of 5)" {
  local t0 t1 ms times=() payload
  payload="$(python3 "$GEN" bulk 200000)"
  for _ in 1 2 3 4 5; do
    t0="$(date +%s%N)"
    printf '%s' "$payload" | bash "$GUARD" >/dev/null 2>/dev/null || true
    t1="$(date +%s%N)"
    ms=$(( (t1 - t0) / 1000000 ))
    times+=("$ms")
  done
  echo "elapsed (5 runs): ${times[*]}ms" >&2
  # Median of 5, no associative arrays / no [[ =~ ]] (bash-3.2 clean): a tiny
  # external sort on 5 numbers is fine, this isn't the hot path.
  local median
  median="$(printf '%s\n' "${times[@]}" | sort -n | sed -n '3p')"
  echo "median: ${median}ms" >&2
  # #63 P1-1 fix2 stopped pre-slicing the payload before extraction -- see
  # this file's docstring for why that was a correctness bug, not just an
  # optimization. The honest cost of that: the WHOLE payload is parsed (by
  # jq since round 5, #63 P2-6; by a bash/grep scan measured ~200-220ms
  # median for 200kB before that) -- this bound reflects that, it is not
  # the ~50ms round-1 claim. This is deliberately loose (the sibling 1MB-adjacent commit
  # already established that a tight bound here is a flaky-CI-assertion
  # mistake, not a real regression signal, on a host that runs several other
  # lanes' full suites at once) -- it still catches the catastrophic case
  # (quadratic blowup, an accidental network call) this class of test exists
  # to catch.
  [ "$median" -lt 3000 ]
}

# #61 round-5 merge — the hook is NOT `clikae`: it runs in its own process,
# under `set -euo pipefail`, possibly before any clikae command has ever swept
# this store. Two things must hold no matter what the store looks like.

@test "the hook decides nothing on disk: no marker, no adoption flag, even on a never-swept store (#61 round-5 merge)" {
  rm -f "$CLIKAE_HOME/state/tanks-adopted-v1"        # the "just upgraded" state
  mkdir -p "$CLIKAE_HOME/state" \
    "$CLIKAE_HOME/profiles/claude/keeper" \
    "$CLIKAE_HOME/profiles/codex/keeper2"
  printf 'claude/cockpit-tank\n' > "$CLIKAE_HOME/state/cockpit"
  run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}'
  [ "$status" -eq 2 ]
  # It still NAMES the reserve (in-memory adoption), …
  [[ "$output" == *"claude/keeper"* ]] || false
  [[ "$output" == *"codex/keeper2"* ]] || false
  # … while writing neither the one-time flag nor a single marker: a hook that
  # wrote the flag here would close the adoption window from a process that
  # knows no engines, orphaning every tank in the store for good.
  [ ! -e "$CLIKAE_HOME/state/tanks-adopted-v1" ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/keeper/.clikae-tank" ]
  [ ! -e "$CLIKAE_HOME/profiles/codex/keeper2/.clikae-tank" ]
  # The store is still adoptable by the real front door afterwards.
  run "$CLIKAE_BIN" tanks
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeper"* ]] || false
}

@test "a read-only store leaves no adopt-warn sentinel and no WARN behind (#61 round-5 merge, r5 P3-1)" {
  local tmp; tmp="$(mktemp -d "${BATS_TMPDIR:-/tmp}/clikae-guard-tmp.XXXXXX")"
  rm -f "$CLIKAE_HOME/state/tanks-adopted-v1"
  mkdir -p "$CLIKAE_HOME/state" "$CLIKAE_HOME/profiles/claude/keeper"
  printf 'claude/cockpit-tank\n' > "$CLIKAE_HOME/state/cockpit"
  chmod 500 "$CLIKAE_HOME"
  TMPDIR="$tmp" run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}'
  chmod 700 "$CLIKAE_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"claude/keeper"* ]] || false
  # The hook has no EXIT trap of clikae's to clean a sentinel up, so it must
  # never create one — nor emit the store-is-read-only WARN, which belongs to
  # a clikae invocation the operator actually typed.
  [ -z "$(ls -A "$tmp")" ]
  [[ "$output" != *"read-only store"* ]] || false
  rm -rf "$tmp"
}
