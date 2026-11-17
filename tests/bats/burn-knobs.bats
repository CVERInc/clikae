#!/usr/bin/env bats
# tests/bats/burn-knobs.bats — #237: `clikae burn` names the model and the
# reasoning effort a task runs with. Three behaviours:
#   1. every burn REPORTS the effective model and effort (first log line and
#      --json), each with where it came from: flag, env, profile or undeclared;
#   2. --model / --effort reach the engine through its adapter, and an engine
#      that cannot honour one fails BEFORE anything starts;
#   3. --require-declared refuses a burn whose model or effort is undeclared.
# Stub engines only; no real engine is ever launched.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'
bats_require_minimum_version 1.5.0   # for `run --separate-stderr`

# Each stub logs its argv, one item per line, so a value with spaces or quotes
# is still one assertion.
_stub_engine() {
  _knobs_init
  local name="$1" bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/$name" <<'STUB'
#!/usr/bin/env bash
[ -n "$STUB_ARGV_LOG" ] && { printf '%s\n' "$@"; printf -- '--END--\n'; } >> "$STUB_ARGV_LOG"
if [ -n "$STUB_HOME_VAR" ] && [ -f "${!STUB_HOME_VAR}/.dry" ]; then
  echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  exit 0
fi
[ -n "$STUB_ARTIFACT" ] && : > "$STUB_ARTIFACT"
exit 0
STUB
  chmod +x "$bin/$name"
  PATH="$bin:$PATH"; export PATH
}

_stub_agy() {
  _knobs_init
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/agy" <<'STUB'
#!/usr/bin/env bash
[ -n "$STUB_ARGV_LOG" ] && printf '%s\n' "$@" >> "$STUB_ARGV_LOG"
log=""
while [ $# -gt 0 ]; do
  [ "$1" = "--log-file" ] && { log="$2"; break; }
  shift
done
[ -n "$log" ] && { mkdir -p "$(dirname "$log")"; : > "$log"; }
[ -n "$STUB_ARTIFACT" ] && : > "$STUB_ARTIFACT"
exit 0
STUB
  chmod +x "$bin/agy"
  PATH="$bin:$PATH"; export PATH
}

_codex_tank() {   # <tank> [config.toml body]
  clikae init codex "$1"
  [ $# -lt 2 ] || printf '%s\n' "$2" > "$CLIKAE_HOME/profiles/codex/$1/config.toml"
}

_claude_tank() {  # <tank> [settings.json body]
  clikae init claude "$1"
  [ $# -lt 2 ] || printf '%s\n' "$2" > "$CLIKAE_HOME/profiles/claude/$1/settings.json"
}

# The one JSON object is the only thing on stdout; split it from the prose.
_burn_json() {
  run --separate-stderr clikae burn "$@" --json
}

_json_field() {   # <key> -> the string value of "key" in $output
  printf '%s' "$output" | grep -oE "\"$1\":(\"[^\"]*\"|null)" | head -n 1 | sed -E 's/^"[^"]*"://; s/^"//; s/"$//'
}

# Called by both stub builders, so every test that launches anything has it.
_knobs_init() {
  # A burn inherits the caller's environment, and these two decide the model
  # and effort ahead of any profile: the suite must own them.
  unset ANTHROPIC_MODEL CLAUDE_CODE_EFFORT_LEVEL
  git init -q "$BATS_TEST_TMPDIR"     # a generated codex burn needs a git cwd
  A="$BATS_TEST_TMPDIR/out.md"; L="$TEST_HOME/argv.log"
  export STUB_ARTIFACT="$A" STUB_ARGV_LOG="$L"
}

# The burn's opening line: whichever of the model/effort line and `task: …`
# comes FIRST. If the report ever slipped below the task line, this returns
# the task line and every assertion on it fails.
_knobs_line() {
  printf '%s\n' "$output" | grep -m1 -E '^ *(burn [^ ]+: model |task: )' | sed 's/^ *//'
}

# ── 1. report ────────────────────────────────────────────────────────────────

@test "burn reports a codex tank's profile model and effort: first log line and --json (#237)" {
  _stub_engine codex
  _codex_tank work 'model = "gpt-test"
model_reasoning_effort = "low"
[tui]
model = "not-this-one"'
  run clikae burn codex work --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_knobs_line)" = "burn codex/work: model gpt-test (profile), effort low (profile)" ]
  _burn_json codex work --artifact "$A" --prompt 'do it' --fresh
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-test ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = profile ]
}

@test "burn reports undeclared when neither a flag nor the profile names them (#237)" {
  _stub_engine codex
  _codex_tank bare
  run clikae burn codex bare --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_knobs_line)" = "burn codex/bare: model undeclared, effort undeclared" ]
  _burn_json codex bare --artifact "$A" --prompt 'do it' --fresh
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = undeclared ]
  [ "$(_json_field model_source)" = undeclared ]
  [ "$(_json_field effort)" = undeclared ]
  [ "$(_json_field effort_source)" = undeclared ]
}

@test "a codex key under a [table] is not the tank's model (#237)" {
  _stub_engine codex
  _codex_tank nested '[profiles.x]
model = "table-model"
model_reasoning_effort = "high"'
  _burn_json codex nested --artifact "$A" --prompt 'do it'
  [ "$(_json_field model_source)" = undeclared ]
  [ "$(_json_field effort_source)" = undeclared ]
}

@test "the status file carries the same four fields (#237)" {
  _stub_engine codex
  _codex_tank work 'model = "gpt-test"'
  run clikae burn codex work --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  local s; s="$(cat "$CLIKAE_HOME"/logs/burn-*/status.json)"
  [[ "$s" == *'"model":"gpt-test","model_source":"profile","effort":"undeclared","effort_source":"undeclared"'* ]] || false
}

@test "claude: the model comes from settings.json, top level only (#237)" {
  _stub_engine claude
  _claude_tank work '{
  "permissions": { "model": "not-this-one" },
  "model": "opus"
}'
  _burn_json claude work --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = opus ]
  [ "$(_json_field model_source)" = profile ]
}

@test "claude: a per-model effort in modelSettings is the profile's effort for that model (#237)" {
  _stub_engine claude
  _claude_tank work '{
  "model": "claude-test-9[1m]",
  "effortLevel": "high",
  "modelSettings": { "claude-test-9": { "effortLevel": "low" }, "claude-other": { "effortLevel": "xhigh" } }
}'
  _burn_json claude work --artifact "$A" --prompt 'do it'
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = profile ]
}

@test "claude: a top-level effortLevel alone is NOT reported as the effort, and the log says why (#237)" {
  # Claude Code applies a top-level effortLevel in the tank's own settings.json
  # only to older models; which model an alias means is the engine's to decide.
  _stub_engine claude
  _claude_tank work '{ "model": "opus", "effortLevel": "high" }'
  run clikae burn claude work --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_knobs_line)" = "burn claude/work: model opus (profile), effort undeclared" ]
  [[ "$output" == *"effortLevel is set to 'high'"* ]] || false
  [[ "$output" == *"pass --effort"* ]] || false
}

@test "claude: ANTHROPIC_MODEL and CLAUDE_CODE_EFFORT_LEVEL in the environment are reported as env (#237)" {
  _stub_engine claude
  _claude_tank work '{ "model": "opus" }'
  ANTHROPIC_MODEL=sonnet CLAUDE_CODE_EFFORT_LEVEL=medium _burn_json claude work --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = sonnet ]
  [ "$(_json_field model_source)" = env ]
  [ "$(_json_field effort)" = medium ]
  [ "$(_json_field effort_source)" = env ]
}

@test "raw argv: the engine's own model flag after -- is reported as a flag, not the profile (#237)" {
  _stub_engine codex
  _codex_tank work 'model = "gpt-profile"
model_reasoning_effort = "low"'
  run --separate-stderr clikae burn codex work --artifact "$A" --json \
    -- exec -m gpt-argv -c 'model_reasoning_effort="high"' 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-argv ]
  [ "$(_json_field model_source)" = flag ]
  [ "$(_json_field effort)" = high ]
  [ "$(_json_field effort_source)" = flag ]
}

@test "raw argv: claude's own --model/--effort after -- are reported as flags (#237)" {
  _stub_engine claude
  _claude_tank work '{ "model": "opus" }'
  run --separate-stderr clikae burn claude work --artifact "$A" --json \
    -- -p 'do it' --model=sonnet --effort low
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = sonnet ]
  [ "$(_json_field model_source)" = flag ]
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = flag ]
}

@test "json_string_leaves reports string members by key path, and nothing inside an array (#237)" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/json.sh"
  local f="$BATS_TEST_TMPDIR/s.json" us=$'\037' tab=$'\t' out
  printf '%s\n' '{ "a": { "model": "inner", "list": ["x:y", "{z"] },' \
    '  "model": "top", "n": 3, "esc": "q\"r: {s}",' \
    '  "m": { "k": { "effortLevel": "low" } }, "arr": [ { "model": "in-array" } ], "last": "z" }' > "$f"
  out="$(json_string_leaves "$f")"
  [ "$out" = "a${us}model${tab}inner
model${tab}top
esc${tab}q\"r: {s}
m${us}k${us}effortLevel${tab}low
last${tab}z" ]
  [ -z "$(json_string_leaves "$BATS_TEST_TMPDIR/absent.json")" ]
}

@test "agy has no profile key for either: undeclared without a flag (#237)" {
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  _burn_json agy default --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model_source)" = undeclared ]
  [ "$(_json_field effort_source)" = undeclared ]
}

@test "a reroute reports the tank that ran, not the one that was named (#237)" {
  STUB_HOME_VAR=CODEX_HOME; export STUB_HOME_VAR
  _stub_engine codex
  _codex_tank first 'model = "gpt-first"
model_reasoning_effort = "low"'
  _codex_tank second 'model = "gpt-second"
model_reasoning_effort = "high"'
  : > "$CLIKAE_HOME/profiles/codex/first/.dry"
  run --separate-stderr clikae burn codex first --to second --artifact "$A" --prompt 'do it' --json
  [ "$status" -eq 0 ]
  [ "$(_json_field tank)" = second ]
  [ "$(_json_field model)" = gpt-second ]
  [ "$(_json_field effort)" = high ]
  # shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
  [[ "$stderr" == *"burn codex/first: model gpt-first (profile), effort low (profile)"* ]] || false
  [[ "$stderr" == *"burn codex/second: model gpt-second (profile), effort high (profile)"* ]] || false
}

# ── 2. --model / --effort ────────────────────────────────────────────────────

@test "burn --model/--effort reach claude as its own --model and --effort (#237)" {
  _stub_engine claude
  _claude_tank work '{ "model": "opus" }'
  _burn_json claude work --artifact "$A" --prompt 'do it' --model sonnet --effort xhigh
  [ "$status" -eq 0 ]
  [ "$(grep -A1 -x -- '--model' "$L" | tail -n 1)" = sonnet ]
  [ "$(grep -A1 -x -- '--effort' "$L" | tail -n 1)" = xhigh ]
  [ "$(_json_field model)" = sonnet ]
  [ "$(_json_field model_source)" = flag ]
  [ "$(_json_field effort)" = xhigh ]
  [ "$(_json_field effort_source)" = flag ]
}

@test "burn --model/--effort reach codex as -m and a -c override, ahead of the prompt (#237)" {
  _stub_engine codex
  _codex_tank work 'model_reasoning_effort = "low"'
  _burn_json codex work --artifact "$A" --prompt 'do it' --model gpt-flag --effort high
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$L")" = exec ]
  [ "$(grep -A1 -x -- '-m' "$L" | tail -n 1)" = gpt-flag ]
  [ "$(grep -A1 -x -- '-c' "$L" | tail -n 1)" = 'model_reasoning_effort="high"' ]
  # The prompt stays the last argument.
  [ "$(grep -B1 -x -- '--END--' "$L" | head -n 1)" = 'do it' ]
  [ "$(_json_field effort)" = high ]
  [ "$(_json_field effort_source)" = flag ]
}

@test "burn --model/--effort reach agy as its own --model and --effort (#237)" {
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  _burn_json agy default --artifact "$A" --prompt 'do it' --model gem-test --effort low
  [ "$status" -eq 0 ]
  [ "$(grep -A1 -x -- '--model' "$L" | tail -n 1)" = gem-test ]
  [ "$(grep -A1 -x -- '--effort' "$L" | tail -n 1)" = low ]
  [ "$(_json_field model)" = gem-test ]
  [ "$(_json_field effort_source)" = flag ]
}

@test "only --effort: the model is still read from the profile, and no model flag is sent (#237)" {
  _stub_engine codex
  _codex_tank work 'model = "gpt-profile"'
  _burn_json codex work --artifact "$A" --prompt 'do it' --effort medium
  [ "$status" -eq 0 ]
  ! grep -qx -- '-m' "$L" || false
  [ "$(_json_field model)" = gpt-profile ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort_source)" = flag ]
}

@test "a cross-engine reroute regenerates the flags in the new engine's dialect (#237)" {
  STUB_HOME_VAR=CODEX_HOME; export STUB_HOME_VAR
  _stub_engine codex
  _stub_engine claude
  _codex_tank first
  _claude_tank second
  : > "$CLIKAE_HOME/profiles/codex/first/.dry"
  run --separate-stderr clikae burn codex first --to claude/second --artifact "$A" --prompt 'do it' \
    --model shared-name --effort high --json
  [ "$status" -eq 0 ]
  [ "$(_json_field engine)" = claude ]
  # First launch: codex's dialect. Second: claude's.
  local first second
  first="$(sed '/^--END--$/q' "$L")"; second="$(sed '1,/^--END--$/d' "$L")"
  [[ "$first" == *$'-m\nshared-name'* ]] || false
  [[ "$first" == *'model_reasoning_effort="high"'* ]] || false
  [[ "$second" == *$'--model\nshared-name'* ]] || false
  [[ "$second" == *$'--effort\nhigh'* ]] || false
  ! grep -qx -- '-m' <<<"$second" || false
}

@test "an engine with no model/effort mapping fails before starting, never ignoring the flag (#237)" {
  _stub_engine grok
  clikae init grok work
  _burn_json grok work --artifact "$A" --prompt 'do it' --model whatever
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"grok cannot honour --model"* ]] || false
  [ ! -e "$L" ]     # the engine was never started
  [ ! -e "$A" ]
  [[ "$output" == '{"ok":false,'* ]] || false
  [[ "$(_json_field reason)" == "refused: grok cannot honour --model"* ]] || false
}

@test "a --to engine that cannot honour the flag is refused up front, before the first tank runs (#237)" {
  _stub_engine codex
  _stub_engine grok
  _codex_tank first
  clikae init grok second
  run clikae burn codex first --to grok/second --artifact "$A" --prompt 'do it' --effort high
  [ "$status" -eq 1 ]
  [[ "$output" == *"grok cannot honour --effort"* ]] || false
  [ ! -e "$L" ]
}

@test "a --to naming an engine clikae does not know is left to the hop, not refused with an empty reason (#237)" {
  _stub_engine codex
  _codex_tank first
  run clikae burn codex first --to nosuch/x --artifact "$A" --prompt 'do it' --model gpt-x
  [ "$status" -eq 0 ]
  [ -e "$A" ]
}

@test "claude refuses an effort level its --help does not list (#237)" {
  _stub_engine claude
  _claude_tank work
  run clikae burn claude work --artifact "$A" --prompt 'do it' --effort ludicrous
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude cannot honour --effort ludicrous"* ]] || false
  [[ "$output" == *"low, medium, high, xhigh, max"* ]] || false
  [ ! -e "$L" ]
}

@test "claude: --effort against a different CLAUDE_CODE_EFFORT_LEVEL is refused — the variable would win (#237)" {
  _stub_engine claude
  _claude_tank work
  CLAUDE_CODE_EFFORT_LEVEL=low run clikae burn claude work --artifact "$A" --prompt 'do it' --effort high
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAUDE_CODE_EFFORT_LEVEL=low"* ]] || false
  [ ! -e "$L" ]
  # The same level in both is not a conflict.
  CLAUDE_CODE_EFFORT_LEVEL=high run clikae burn claude work --artifact "$A" --prompt 'do it' --effort high
  [ "$status" -eq 0 ]
}

@test "--model/--effort with a raw '-- <cmd>' task are refused, not dropped (#237)" {
  _stub_engine codex
  _codex_tank work
  run clikae burn codex work --artifact "$A" --model gpt-x -- exec 'do it'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--model and --effort only apply to a task given with --prompt or --prompt-file"* ]] || false
  [ ! -e "$L" ]
}

@test "the same knob from burn and again after -- is refused as ambiguous (#237)" {
  _stub_engine claude
  _claude_tank work
  run clikae burn claude work --artifact "$A" --prompt 'do it' --model opus -- --model sonnet
  [ "$status" -eq 1 ]
  [[ "$output" == *"--model is given twice"* ]] || false
  [ ! -e "$L" ]
}

@test "--effort rejects a value that is not one plain word (#237)" {
  _stub_engine codex
  _codex_tank work
  run clikae burn codex work --artifact "$A" --prompt 'do it' --effort 'high" x="y'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort must be one word"* ]] || false
  [ ! -e "$L" ]
}

# ── 3. --require-declared ────────────────────────────────────────────────────

@test "--require-declared refuses an undeclared effort before starting, and names what is missing (#237)" {
  _stub_engine codex
  _codex_tank work 'model = "gpt-test"'
  _burn_json codex work --artifact "$A" --prompt 'do it' --require-declared
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--require-declared: codex/work declares no effort"* ]] || false
  [ ! -e "$L" ]
  [ ! -e "$A" ]
  [ "$(_json_field reason)" = "refused: undeclared effort" ]
  [ "$(_json_field model)" = gpt-test ]
  [ "$(_json_field effort)" = undeclared ]
  # The status file ends terminal, so `clikae wait` does not stall on it.
  grep -q '"state":"fail"' "$CLIKAE_HOME"/logs/burn-*/status.json
}

@test "--require-declared passes when the profile declares both (#237)" {
  _stub_engine codex
  _codex_tank work 'model = "gpt-test"
model_reasoning_effort = "high"'
  run clikae burn codex work --artifact "$A" --prompt 'do it' --require-declared
  [ "$status" -eq 0 ]
  [ -e "$A" ]
}

@test "--require-declared passes when flags fill what the profile leaves out (#237)" {
  _stub_engine codex
  _codex_tank bare
  run clikae burn codex bare --artifact "$A" --prompt 'do it' --require-declared --model gpt-x --effort high
  [ "$status" -eq 0 ]
  [ -e "$A" ]
}

@test "--require-declared refuses a reroute onto a tank that declares nothing (#237)" {
  STUB_HOME_VAR=CODEX_HOME; export STUB_HOME_VAR
  _stub_engine codex
  _codex_tank first 'model = "gpt-first"
model_reasoning_effort = "low"'
  _codex_tank second
  : > "$CLIKAE_HOME/profiles/codex/first/.dry"
  run clikae burn codex first --to second --artifact "$A" --prompt 'do it' --require-declared
  [ "$status" -eq 1 ]
  [[ "$output" == *"--require-declared: codex/second declares no model or effort"* ]] || false
  [ "$(grep -c -x -- '--END--' "$L")" = 1 ]     # only the first tank ran
  [ ! -e "$A" ]
}

@test "burn --help documents the three flags (#237)" {
  run clikae burn --help
  [[ "$output" == *"--model <m>"* ]] || false
  [[ "$output" == *"--effort <e>"* ]] || false
  [[ "$output" == *"--require-declared"* ]] || false
}
