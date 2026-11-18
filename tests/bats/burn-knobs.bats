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

@test "a model-pinned cross-engine --to is refused before anything starts: a model name belongs to one engine (#237)" {
  STUB_HOME_VAR=CODEX_HOME; export STUB_HOME_VAR
  _stub_engine codex
  _stub_engine claude
  _codex_tank work 'model = "gpt-profile"
model_reasoning_effort = "low"'
  _claude_tank second '{"model":"opus"}'
  : > "$CLIKAE_HOME/profiles/codex/work/.dry"
  _burn_json codex work --artifact "$A" --prompt 'do it' --to claude/second --model gpt-5 --effort high
  [ "$status" -eq 1 ]
  # Both engines are named, and so is the way out.
  [[ "$stderr" == *"--to claude/second: --model gpt-5 names a codex model"* ]] || false
  [[ "$stderr" == *"claude"*"--to-model"* ]] || false
  [[ "$stderr" == *"Nothing was started."* ]] || false
  [ ! -e "$L" ]     # neither engine was started
  [ ! -e "$A" ]
  [[ "$(_json_field reason)" == "refused: --model gpt-5 names a codex model"* ]] || false
  grep -q '"state":"fail"' "$CLIKAE_HOME"/logs/burn-*/status.json
}

@test "--to-model names the destination engine's model: the source's name never crosses the hop (#237)" {
  STUB_HOME_VAR=CODEX_HOME; export STUB_HOME_VAR
  _stub_engine codex
  _stub_engine claude
  _codex_tank first
  _claude_tank second '{"model":"opus"}'
  : > "$CLIKAE_HOME/profiles/codex/first/.dry"
  _burn_json codex first --artifact "$A" --prompt 'do it' --to claude/second \
    --model gpt-5 --to-model sonnet --effort high
  [ "$status" -eq 0 ]
  [ "$(_json_field engine)" = claude ]
  # First launch: codex's dialect and codex's model. Second: claude's.
  local first second
  first="$(sed '/^--END--$/q' "$L")"; second="$(sed '1,/^--END--$/d' "$L")"
  [[ "$first" == *$'-m\ngpt-5'* ]] || false
  [[ "$first" == *'model_reasoning_effort="high"'* ]] || false
  [[ "$second" == *$'--model\nsonnet'* ]] || false
  [[ "$second" == *$'--effort\nhigh'* ]] || false
  [[ "$second" != *gpt-5* ]] || false
  ! grep -qx -- '-m' <<<"$second" || false
  [ "$(_json_field model)" = sonnet ]
  [ "$(_json_field model_source)" = flag ]
  [[ "$stderr" == *"burn codex/first: model gpt-5 (flag), effort high (flag)"* ]] || false
  [[ "$stderr" == *"burn claude/second: model sonnet (flag), effort high (flag)"* ]] || false
}

@test "--to-model alone pins only the destination; the first tank keeps its profile's model (#237)" {
  STUB_HOME_VAR=CODEX_HOME; export STUB_HOME_VAR
  _stub_engine codex
  _stub_engine claude
  _codex_tank first 'model = "gpt-profile"'
  _claude_tank second '{"model":"opus"}'
  : > "$CLIKAE_HOME/profiles/codex/first/.dry"
  _burn_json codex first --artifact "$A" --prompt 'do it' --to claude/second --to-model sonnet
  [ "$status" -eq 0 ]
  local first second
  first="$(sed '/^--END--$/q' "$L")"; second="$(sed '1,/^--END--$/d' "$L")"
  ! grep -qx -- '-m' <<<"$first" || false
  [[ "$second" == *$'--model\nsonnet'* ]] || false
  [[ "$stderr" == *"burn codex/first: model gpt-profile (profile)"* ]] || false
  [ "$(_json_field model)" = sonnet ]
  [ "$(_json_field model_source)" = flag ]
}

@test "without --model a cross-engine reroute carries no model: the destination's profile decides (#237)" {
  STUB_HOME_VAR=CODEX_HOME; export STUB_HOME_VAR
  _stub_engine codex
  _stub_engine claude
  _codex_tank first 'model = "gpt-profile"'
  _claude_tank second '{"model":"opus"}'
  : > "$CLIKAE_HOME/profiles/codex/first/.dry"
  _burn_json codex first --artifact "$A" --prompt 'do it' --to claude/second --effort high
  [ "$status" -eq 0 ]
  local second; second="$(sed '1,/^--END--$/d' "$L")"
  ! grep -qx -- '--model' <<<"$second" || false
  [[ "$second" == *$'--effort\nhigh'* ]] || false
  [ "$(_json_field model)" = opus ]
  [ "$(_json_field model_source)" = profile ]
}

@test "--to-model is refused where there is no cross-engine --to for it to apply to (#237)" {
  _stub_engine codex
  _codex_tank first
  _codex_tank second
  run clikae burn codex first --artifact "$A" --prompt 'do it' --to-model sonnet
  [ "$status" -eq 1 ]
  [[ "$output" == *"--to-model only applies with a --to that names a different engine"* ]] || false
  run clikae burn codex first --artifact "$A" --prompt 'do it' --to second --to-model sonnet
  [ "$status" -eq 1 ]
  [[ "$output" == *"--to-model only applies with a --to that names a different engine"* ]] || false
  run clikae burn codex first --artifact "$A" --prompt 'do it' --to codex/second --to-model sonnet
  [ "$status" -eq 1 ]
  [ ! -e "$L" ]
}

@test "an effort level the --to engine does not accept is refused up front, naming that engine (#237)" {
  _stub_engine codex
  _stub_engine claude
  _codex_tank first
  _claude_tank second
  # codex takes any one word; claude's --help lists five levels.
  run clikae burn codex first --to claude/second --artifact "$A" --prompt 'do it' --effort minimal
  [ "$status" -eq 1 ]
  [[ "$output" == *"--to claude/second: claude cannot honour --effort minimal"* ]] || false
  [ ! -e "$L" ]
}

@test "a --to-model the destination engine has no flag for is refused up front (#237)" {
  _stub_engine codex
  _stub_engine grok
  _codex_tank first
  clikae init grok second
  run clikae burn codex first --to grok/second --artifact "$A" --prompt 'do it' --to-model whatever
  [ "$status" -eq 1 ]
  [[ "$output" == *"grok cannot honour --model"* ]] || false
  [ ! -e "$L" ]
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
  run clikae burn codex first --to nosuch/x --artifact "$A" --prompt 'do it' --effort high
  [ "$status" -eq 0 ]
  [ -e "$A" ]
  # A pinned model is another matter: whatever `nosuch` is, it is not codex.
  run clikae burn codex first --to nosuch/x --artifact "$A" --prompt 'do it' --fresh --model gpt-x
  [ "$status" -eq 1 ]
  [[ "$output" == *"--to nosuch/x: --model gpt-x names a codex model"* ]] || false
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
  [[ "$output" == *"--model, --to-model and --effort only apply to a task given with --prompt or --prompt-file"* ]] || false
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

# ── 4. codex: the argv after `--`, read the way codex reads it ───────────────
# Codex trims the key of a `-c key=value`, accepts the value glued to the
# option, ranks -m/--model above a `-c model=…`, and stops reading options at
# `--`. Each case below is one the first reader got wrong.

_codex_profiled() {
  _stub_engine codex
  _codex_tank work 'model = "gpt-profile"
model_reasoning_effort = "low"'
}

@test "codex: an effort override after -- with spaces round the key is still the same knob given twice (#237)" {
  _codex_profiled
  run --separate-stderr clikae burn codex work --artifact "$A" --json --prompt 'do it' \
    --model gpt-test --effort high -- -c 'model_reasoning_effort = "low"'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--effort is given twice"* ]] || false
  [ ! -e "$L" ]
  [ "$(_json_field reason)" = "refused: --effort given twice" ]
}

@test "codex: the compact -c<key=value> and -c=<key=value> spellings are the same knob given twice (#237)" {
  _codex_profiled
  run clikae burn codex work --artifact "$A" --prompt 'do it' --model gpt-test --effort high \
    -- '-cmodel_reasoning_effort="low"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort is given twice"* ]] || false
  run clikae burn codex work --artifact "$A" --prompt 'do it' --effort high \
    -- '-c=model_reasoning_effort="low"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort is given twice"* ]] || false
  run clikae burn codex work --artifact "$A" --prompt 'do it' --effort high \
    -- '--config= model_reasoning_effort =low'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort is given twice"* ]] || false
  run clikae burn codex work --artifact "$A" --prompt 'do it' --model gpt-test -- -mgpt-other
  [ "$status" -eq 1 ]
  [[ "$output" == *"--model is given twice"* ]] || false
  [ ! -e "$L" ]
}

@test "codex raw argv: -m glued to its value is the model that runs (#237)" {
  _codex_profiled
  run --separate-stderr clikae burn codex work --artifact "$A" --json \
    -- exec -mgpt-actual -c 'model_reasoning_effort="high"' 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-actual ]
  [ "$(_json_field model_source)" = flag ]
  [ "$(_json_field effort)" = high ]
  [ "$(_json_field effort_source)" = flag ]
  run --separate-stderr clikae burn codex work --artifact "$A" --json --fresh \
    -- exec -m=gpt-eq 'do it'
  [ "$(_json_field model)" = gpt-eq ]
  [ "$(_json_field model_source)" = flag ]
}

@test "codex raw argv: -m outranks a -c model override, as it does in codex (#237)" {
  _codex_profiled
  run --separate-stderr clikae burn codex work --artifact "$A" --json \
    -- exec -m gpt-actual -c 'model="gpt-config"' 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-actual ]
  [ "$(_json_field model_source)" = flag ]
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = profile ]
}

@test "codex raw argv: of two -c overrides of one key the later one runs (#237)" {
  _codex_profiled
  run --separate-stderr clikae burn codex work --artifact "$A" --json \
    -- exec -c 'model="gpt-a"' -c ' model = gpt-b ' -c "model_reasoning_effort='medium'" 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-b ]
  [ "$(_json_field model_source)" = flag ]
  [ "$(_json_field effort)" = medium ]
  [ "$(_json_field effort_source)" = flag ]
}

@test "codex raw argv: what follows the option terminator is a prompt, not a flag (#237)" {
  _codex_profiled
  run --separate-stderr clikae burn codex work --artifact "$A" --json \
    -- exec -- '--model=not-a-flag'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-profile ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = profile ]
}

@test "codex raw argv: an override whose value cannot be read with certainty is reported as unknown, not guessed (#237)" {
  _codex_profiled
  run clikae burn codex work --artifact "$A" \
    -- exec -c 'model="gpt-x" # pinned' -c 'model_reasoning_effort=5' 'do it'
  [ "$status" -eq 0 ]
  [ "$(_knobs_line)" = "burn codex/work: model unknown, effort unknown" ]
  [[ "$output" == *"the argv after -- sets the model and effort in a form clikae cannot read with certainty"* ]] || false
  run --separate-stderr clikae burn codex work --artifact "$A" --json --fresh \
    -- exec -c '"model"="gpt-quoted-key"' 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field model_source)" = unknown ]
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = profile ]
}

@test "codex: an unreadable override after -- still counts as the knob given twice (#237)" {
  _codex_profiled
  run clikae burn codex work --artifact "$A" --prompt 'do it' --effort high \
    -- -c 'model_reasoning_effort=5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort is given twice"* ]] || false
  [ ! -e "$L" ]
}

@test "--require-declared refuses an unknown model: it is not a declared one (#237)" {
  _codex_profiled
  run --separate-stderr clikae burn codex work --artifact "$A" --json --require-declared \
    -- exec -c 'model="gpt-x" # pinned' 'do it'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--require-declared: the model of codex/work cannot be determined"* ]] || false
  [ "$(_json_field reason)" = "refused: unknown model" ]
  [ ! -e "$L" ]
}

@test "codex raw argv reaches the engine byte for byte, whatever was read from it (#237)" {
  _codex_profiled
  run --separate-stderr clikae burn codex work --artifact "$A" --json \
    -- exec -mgpt-actual -c '  model_reasoning_effort  =  "high"' -- '--model=not-a-flag'
  [ "$status" -eq 0 ]
  [ "$(cat "$L")" = 'exec
-mgpt-actual
-c
  model_reasoning_effort  =  "high"
--
--model=not-a-flag
--END--' ]
  [ "$(_json_field model)" = gpt-actual ]
  [ "$(_json_field effort)" = high ]
}

# ── 5. codex: config.toml, read as TOML ──────────────────────────────────────

@test "codex: text inside a multi-line string in config.toml declares nothing (#237)" {
  _stub_engine codex
  _codex_tank work "model = \"gpt-actual\"
model_reasoning_effort = \"high\"
developer_instructions = '''
In examples, use this config:
model = \"example-model\"
model_reasoning_effort = \"low\"
'''"
  _burn_json codex work --artifact "$A" --prompt 'do it' --require-declared
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-actual ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = high ]
  [ "$(_json_field effort_source)" = profile ]
}

@test "codex: quoted keys in config.toml are the same keys (#237)" {
  _stub_engine codex
  _codex_tank work "\"model\" = \"gpt-actual\" # comment
'model_reasoning_effort' = 'high'"
  _burn_json codex work --artifact "$A" --prompt 'do it' --require-declared
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-actual ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = high ]
  [ "$(_json_field effort_source)" = profile ]
}

@test "codex: a root member that is not a string, or a multi-line one, is not a declaration (#237)" {
  _stub_engine codex
  _codex_tank work 'model = 5
model_reasoning_effort = """
high
"""'
  _burn_json codex work --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model_source)" = undeclared ]
  [ "$(_json_field effort_source)" = undeclared ]
}

@test "codex: a config.toml that is not valid TOML declares nothing, and the burn says why (#237)" {
  _stub_engine codex
  _codex_tank work 'model = "gpt-actual"
model_reasoning_effort = "high
[broken'
  run clikae burn codex work --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_knobs_line)" = "burn codex/work: model undeclared, effort undeclared" ]
  [[ "$output" == *"config.toml is not valid TOML"* ]] || false
}

@test "codex: with no usable python3 the profile reads as undeclared with the reason, never a guess (#237)" {
  _stub_engine codex
  _codex_tank work 'model = "gpt-actual"
model_reasoning_effort = "high"'
  # Ahead of the real one on PATH: a python3 that cannot run anything.
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/python3"
  chmod +x "$BATS_TEST_TMPDIR/bin/python3"
  run clikae burn codex work --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_knobs_line)" = "burn codex/work: model undeclared, effort undeclared" ]
  [[ "$output" == *"config.toml was not read: that needs python3 3.11 or newer"* ]] || false
  # A flag still names what the file could not; the note stays for the other.
  run clikae burn codex work --artifact "$A" --prompt 'do it' --fresh --effort high
  [ "$status" -eq 0 ]
  [ "$(_knobs_line)" = "burn codex/work: model undeclared, effort high (flag)" ]
  [[ "$output" == *"config.toml was not read"* ]] || false
  _burn_json codex work --artifact "$A" --prompt 'do it' --fresh --require-declared
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: undeclared model or effort" ]
  [[ "$stderr" == *"config.toml was not read"* ]] || false
}

# ── 5. the argv after `--`, before anything starts ───────────────────────────
# What follows `--` reaches every engine a burn launches byte for byte, so a
# model in it cannot be one engine's alone; and a config override key is the
# same key however it is dressed (spaces of any kind, quotes).

# A dry codex tank, and a claude tank for an explicit --to to land on.
_codex_dry_to_claude() {
  STUB_HOME_VAR=CODEX_HOME; export STUB_HOME_VAR
  _stub_engine codex
  _stub_engine claude
  _codex_tank work 'model = "gpt-profile"
model_reasoning_effort = "low"'
  _claude_tank second '{"model":"opus"}'
  : > "$CLIKAE_HOME/profiles/codex/work/.dry"
}

# _burn_json appends --json, which after a `--` would land in the engine's
# argv; these burns all carry one, so --json goes ahead of it.
_work_json() {
  run --separate-stderr clikae burn codex work --artifact "$A" --json "$@"
}

_NBSP=$'\xc2\xa0'            # U+00A0 no-break space
_FIGURE_SPACE=$'\xe2\x80\x87' # U+2007 figure space

@test "a model after -- with a cross-engine --to and --to-model is refused before the first tank runs (#237)" {
  _codex_dry_to_claude
  _work_json --prompt 'do it' --to claude/second --to-model sonnet -- --model gpt-5
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--to claude/second: the arguments after -- name a model"* ]] || false
  [[ "$stderr" == *"unchanged to both codex and claude"* ]] || false
  [[ "$stderr" == *"--model"*"--to-model"* ]] || false
  [[ "$stderr" == *"Nothing was started."* ]] || false
  [ ! -e "$L" ]     # the source tank was not spent on a burn that could not finish
  [ ! -e "$A" ]
  [ "$(_json_field reason)" = "refused: the arguments after -- name a model; --to claude/second would pass it to claude unchanged" ]
  grep -q '"state":"fail"' "$CLIKAE_HOME"/logs/burn-*/status.json
}

@test "a model after -- never reaches the other engine of a cross-engine --to: refused up front (#237)" {
  _codex_dry_to_claude
  _work_json --prompt 'do it' --to claude/second -- --model gpt-5
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--to claude/second: the arguments after -- name a model"* ]] || false
  [[ "$stderr" == *"Nothing was started."* ]] || false
  [ ! -e "$L" ]     # neither engine was started: claude never saw `--model gpt-5`
  [ ! -e "$A" ]
  # The same argv with a --to on the SAME engine is a plain burn.
  _codex_tank spare
  _work_json --prompt 'do it' --to codex/spare -- --model gpt-5
  [ "$status" -eq 0 ]
  [ "$(_json_field tank)" = spare ]
  [ "$(_json_field model)" = gpt-5 ]
  [ "$(_json_field model_source)" = flag ]
}

@test "a raw command that names a model is refused with a cross-engine --to: the same command would run on both (#237)" {
  _codex_dry_to_claude
  _work_json --to claude/second -- exec -m gpt-5 'do it'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--to claude/second: the arguments after -- name a model"* ]] || false
  [ ! -e "$L" ]
}

@test "codex: a quoted override key after -- is still the model: refused with a cross-engine --to, and a duplicate of --model (#237)" {
  _codex_dry_to_claude
  _work_json --prompt 'do it' --to claude/second -- -c '"model"="gpt-5"'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--to claude/second: the arguments after -- name a model"* ]] || false
  [ ! -e "$L" ]
  _work_json --prompt 'do it' --model gpt-test -- -c "'model' = \"gpt-5\""
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: --model given twice" ]
  [ ! -e "$L" ]
}

@test "codex: a no-break space round an override key after -- is still the same knob given twice (#237)" {
  _codex_profiled
  _work_json --prompt 'do it' --model gpt-test --effort high \
    -- -c "model_reasoning_effort${_NBSP}= \"low\""
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--effort is given twice"* ]] || false
  [ "$(_json_field reason)" = "refused: --effort given twice" ]
  [ ! -e "$L" ]
}

@test "codex: a figure space round an override key after -- is still the same knob given twice (#237)" {
  _codex_profiled
  _work_json --prompt 'do it' --effort high \
    -- -c "${_FIGURE_SPACE}model_reasoning_effort${_FIGURE_SPACE}=\"low\""
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: --effort given twice" ]
  _work_json --prompt 'do it' --model gpt-test \
    -- "--config=model${_FIGURE_SPACE}=\"gpt-other\""
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: --model given twice" ]
  [ ! -e "$L" ]
}

@test "codex raw argv: an override whose key had to be cleaned is unknown, never the profile's value (#237)" {
  _codex_profiled
  # The profile says low; the argv says high behind a no-break space. Neither
  # is reported as fact, and --require-declared does not take it as declared.
  _work_json --require-declared \
    -- exec -c "model_reasoning_effort${_NBSP}= \"high\"" 'do it'
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: unknown effort" ]
  [ "$(_json_field effort)" = unknown ]
  [ "$(_json_field effort_source)" = unknown ]
  [ ! -e "$L" ]
  _work_json \
    -- exec -c "model_reasoning_effort${_NBSP}= \"high\"" -c "${_FIGURE_SPACE}model=\"gpt-x\"" 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field model_source)" = unknown ]
  [ "$(_json_field effort)" = unknown ]
  [ "$(_json_field effort_source)" = unknown ]
  # The argv itself is passed on untouched.
  grep -qx -- "model_reasoning_effort${_NBSP}= \"high\"" "$L"
}

# ── 6. the same answer in every locale, on every C library ───────────────────
# The test above was red on macOS only: the reader told "plain trimming" from
# "had to be cleaned" with `[[:space:]]`, and whether a no-break space is in
# that class is the C library's and the locale's call (macOS: yes; glibc: no,
# but an em space is, in a UTF-8 locale). The reader now matches spelled-out
# ASCII lists, so these run it under LC_ALL=C and under the UTF-8 locales and
# expect one answer. A locale a host does not have falls back to C.

_NNBSP=$'\xe2\x80\xaf'       # U+202F narrow no-break space
_EM_SPACE=$'\xe2\x80\x83'    # U+2003 em space: [[:space:]] in glibc's UTF-8 locales
_IDEO_SPACE=$'\xe3\x80\x80'  # U+3000 ideographic space: likewise
_NEL=$'\xc2\x85'             # U+0085 next line: [[:cntrl:]] in a UTF-8 locale
_KNOB_LOCALES="C POSIX C.UTF-8 en_US.UTF-8"

# _in_locale <locale> <function of lib/adapters/codex.sh> <args...>, in a
# child shell that starts in that locale.
_in_locale() {
  local loc="$1"; shift
  LC_ALL="$loc" bash -c 'source "$CLIKAE_LIB/adapters/codex.sh" && "$@"' _ "$@" 2>/dev/null
}

@test "codex: the override key normaliser under LC_ALL=C drops every non-key byte, as in any other locale (#237)" {
  local loc sp
  for loc in $_KNOB_LOCALES; do
    for sp in ' ' $'\t' "$_NBSP" "$_FIGURE_SPACE" "$_NNBSP" "$_EM_SPACE" "$_IDEO_SPACE" "$_NEL" '"' "'"; do
      run _in_locale "$loc" _codex_override_key "${sp}model_reasoning_effort${sp}"
      [ "$status" -eq 0 ]
      [ "$output" = model_reasoning_effort ] || { echo "LC_ALL=$loc sp=[$sp] -> [$output]"; false; }
      run _in_locale "$loc" _codex_override_key "${sp}${sp}model"
      [ "$output" = model ] || { echo "LC_ALL=$loc sp=[$sp] -> [$output]"; false; }
    done
    # Only non-key characters go: another key stays another key.
    run _in_locale "$loc" _codex_override_key "model_provider${_NBSP}"
    [ "$output" = model_provider ]
    run _in_locale "$loc" _codex_override_key "Model.x-9"
    [ "$output" = Model.x-9 ]
    # A letter outside ASCII is not a key character either, in any locale.
    run _in_locale "$loc" _codex_override_key $'mod\xc3\xa9el'
    [ "$output" = model ]
  done
}

@test "codex: plain trimming is ASCII whitespace in every locale, and no other space is trimmed (#237)" {
  local loc sp
  for loc in $_KNOB_LOCALES; do
    # Plain: space, tab, CR, LF round the key and the value. Readable.
    run _in_locale "$loc" adapter_burn_knobs_from_args exec \
      -c $' \tmodel_reasoning_effort\r = \t"high" \n' -c $'\tmodel = gpt-x ' 'do it'
    [ "$output" = $'model=gpt-x\neffort=high' ] || { echo "LC_ALL=$loc -> [$output]"; false; }
    # Not plain, whatever the C library classes it as: the key is still that
    # setting, and its value is "cannot tell".
    for sp in "$_NBSP" "$_FIGURE_SPACE" "$_NNBSP" "$_EM_SPACE" "$_IDEO_SPACE" "$_NEL"; do
      run _in_locale "$loc" adapter_burn_knobs_from_args exec \
        -c "model_reasoning_effort${sp}= \"high\"" -c "${sp}model=\"gpt-x\"" 'do it'
      [ "$output" = $'model?\neffort?' ] || { echo "LC_ALL=$loc key sp=[$sp] -> [$output]"; false; }
      # The same for the value: a string followed by such a space is not one
      # this reader can vouch for.
      run _in_locale "$loc" adapter_burn_knobs_from_args exec \
        -c "model_reasoning_effort=\"high\"${sp}" -c "model=${sp}gpt-x" 'do it'
      [ "$output" = $'model?\neffort?' ] || { echo "LC_ALL=$loc value sp=[$sp] -> [$output]"; false; }
    done
    # A control character is the ASCII ones, by list, in every locale.
    run _in_locale "$loc" adapter_burn_knobs_from_args exec \
      -m $'gpt\033x' -c $'model_reasoning_effort="hi\177gh"' 'do it'
    [ "$output" = $'model?\neffort?' ] || { echo "LC_ALL=$loc cntrl -> [$output]"; false; }
    run _in_locale "$loc" adapter_burn_knobs_from_args exec -m "gpt${_NEL}x" 'do it'
    [ "$output" = "model=gpt${_NEL}x" ] || { echo "LC_ALL=$loc nel -> [$output]"; false; }
  done
}

@test "codex raw argv: a key behind a space that is not plain is unknown in every locale, never a declared value (#237)" {
  _codex_profiled
  local loc sp
  for loc in C C.UTF-8 en_US.UTF-8; do
    for sp in "$_NBSP" "$_EM_SPACE"; do
      rm -f "$L" "$A"
      LC_ALL="$loc" _work_json --require-declared \
        -- exec -c "model_reasoning_effort${sp}= \"high\"" 'do it'
      [ "$status" -eq 1 ] || { echo "LC_ALL=$loc sp=[$sp] ran: $output"; false; }
      [ "$(_json_field reason)" = "refused: unknown effort" ]
      [ "$(_json_field effort)" = unknown ]
      [ "$(_json_field effort_source)" = unknown ]
      [ ! -e "$L" ]
    done
  done
}

@test "codex: the argv reader matches no named character class, which is the C library's to define (#237)" {
  local body
  body="$(sed -n '/^# The character sets this reader matches with/,/^# _codex_config_root /p' "$CLIKAE_LIB/adapters/codex.sh")"
  # The section is the one meant: it holds the reader and its helpers.
  [[ "$body" == *"adapter_burn_knobs_from_args() {"* ]] || false
  [[ "$body" == *"_codex_override_key() {"* ]] || false
  [[ "$body" == *"_codex_override_string() {"* ]] || false
  run grep -nE '^[^#]*\[\[:[a-z]+:\]\]' <<<"$body"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

# ── 7. codex: profile layering (#239) ────────────────────────────────────────
# A root `profile` key, or a profile option in the argv, puts another layer
# over the root table. One value is reported only when every layer codex could
# be applying leads to it; otherwise `unknown` — never the root table's value
# as if nothing had been selected.

_codex_layer() {   # <tank> <name> <body> -> <tank>/<name>.config.toml
  printf '%s\n' "$3" > "$CLIKAE_HOME/profiles/codex/$1/$2.config.toml"
}

# The issue's reproduction: the root table says one thing, the profile the
# root key selects says another.
_codex_root_key_tank() {
  _stub_engine codex
  _codex_tank work 'model = "root-model"
model_reasoning_effort = "low"
profile = "x"
[profiles.x]
model = "layer-model"
model_reasoning_effort = "high"'
}

@test "codex: a root profile key whose table says otherwise is unknown, not the root table's value (#239)" {
  _codex_root_key_tank
  run clikae burn codex work --artifact "$A" --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_knobs_line)" = "burn codex/work: model unknown, effort unknown" ]
  [[ "$output" == *"codex profile layering is selected by the profile key in config.toml, and the layers codex could apply do not lead to one plain value, so clikae reports it as unknown rather than guessing."* ]] || false
  _burn_json codex work --artifact "$A" --prompt 'do it' --fresh
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field model_source)" = unknown ]
  [ "$(_json_field effort)" = unknown ]
  [ "$(_json_field effort_source)" = unknown ]
}

@test "--require-declared refuses a codex tank whose profile layering leaves both unknown (#239)" {
  _codex_root_key_tank
  _burn_json codex work --artifact "$A" --prompt 'do it' --require-declared
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: unknown model or effort" ]
  [[ "$stderr" == *"--require-declared: the model or effort of codex/work cannot be determined — codex profile layering is selected by the profile key in config.toml"* ]] || false
  [[ "$stderr" == *"Name it with --model / --effort. Nothing was started."* ]] || false
  [ ! -e "$L" ]
}

@test "codex: burn's --model and --effort still win over a selected profile, as flag (#239)" {
  _codex_root_key_tank
  _burn_json codex work --artifact "$A" --prompt 'do it' --require-declared --model gpt-x --effort medium
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-x ]
  [ "$(_json_field model_source)" = flag ]
  [ "$(_json_field effort)" = medium ]
  [ "$(_json_field effort_source)" = flag ]
  [[ "$stderr" != *"profile layering"* ]] || false
  # One flag: the other is still unknown, and still said to be.
  run clikae burn codex work --artifact "$A" --prompt 'do it' --fresh --model gpt-x
  [ "$status" -eq 0 ]
  [ "$(_knobs_line)" = "burn codex/work: model gpt-x (flag), effort unknown" ]
  [[ "$output" == *"so clikae reports it as unknown rather than guessing."* ]] || false
}

@test "codex: a knob named to burn and again after -- is still refused with a profile selected (#239)" {
  _codex_root_key_tank
  run clikae burn codex work --artifact "$A" --prompt 'do it' --effort high \
    -- -p x -c 'model_reasoning_effort="low"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort is given twice"* ]] || false
  [ ! -e "$L" ]
}

@test "codex: a profile table nothing selects changes nothing (#239)" {
  _stub_engine codex
  _codex_tank work 'model = "root-model"
model_reasoning_effort = "low"
[profiles.x]
model = "layer-model"
model_reasoning_effort = "high"'
  _codex_layer work x 'model = "file-model"'
  _burn_json codex work --artifact "$A" --prompt 'do it' --require-declared
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = root-model ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = profile ]
  [[ "$stderr" != *"profile layering"* ]] || false
}

@test "codex: a profile option in the argv layers <name>.config.toml over the root table, in every spelling (#239)" {
  _codex_profiled
  _codex_layer work fast 'model = "layer-model"
model_reasoning_effort = "high"'
  local form
  for form in '-p fast' '-pfast' '-p=fast' '--profile fast' '--profile=fast'; do
    rm -f "$L" "$A"
    # shellcheck disable=SC2086  # one or two words, on purpose
    _work_json --require-declared -- exec $form 'do it'
    [ "$status" -eq 0 ] || { echo "form [$form]: $stderr"; false; }
    [ "$(_json_field model)" = layer-model ] || { echo "form [$form]: $output"; false; }
    [ "$(_json_field model_source)" = profile ]
    [ "$(_json_field effort)" = high ]
    [ "$(_json_field effort_source)" = profile ]
  done
  # The extras of a --prompt burn are read the same way.
  rm -f "$L" "$A"
  run clikae burn codex work --artifact "$A" --prompt 'do it' -- -p fast
  [ "$status" -eq 0 ]
  [ "$(_knobs_line)" = "burn codex/work: model layer-model (profile), effort high (profile)" ]
}

@test "codex: a profile option after the option terminator is the prompt (#239)" {
  _codex_profiled
  _codex_layer work fast 'model = "layer-model"'
  _work_json -- exec -- -p fast
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-profile ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = low ]
}

@test "codex: a selected layer that sets one of the two leaves the other to the root table (#239)" {
  _codex_profiled
  _codex_layer work fast 'model = "layer-model"'
  _work_json --require-declared -- exec -p fast 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = layer-model ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = profile ]
}

@test "codex: a root-key profile that sets one of the two makes only that one unknown (#239)" {
  _stub_engine codex
  _codex_tank work 'model = "root-model"
model_reasoning_effort = "low"
profile = "x"
[profiles.x]
model_reasoning_effort = "high"'
  _work_json --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = root-model ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = unknown ]
  [ "$(_json_field effort_source)" = unknown ]
  [[ "$stderr" == *"so clikae reports it as unknown rather than guessing."* ]] || false
  rm -f "$L" "$A"
  _work_json --prompt 'do it' --require-declared
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: unknown effort" ]
  [ ! -e "$L" ]
}

@test "codex: a root-key profile that repeats the root table's values is those values (#239)" {
  _stub_engine codex
  _codex_tank work 'model = "same-model"
model_reasoning_effort = "low"
profile = "x"
[profiles.x]
model = "same-model"'
  _work_json --prompt 'do it' --require-declared
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = same-model ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = profile ]
}

@test "codex: an argv profile that exists only as a table is unknown where the table differs from the root (#239)" {
  _stub_engine codex
  _codex_tank work 'model = "root-model"
model_reasoning_effort = "low"
[profiles.x]
model = "layer-model"'
  _work_json -- exec -p x 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field model_source)" = unknown ]
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = profile ]
  [[ "$stderr" == *"codex profile layering is selected by a profile option in the arguments after --, and the layers codex could apply do not lead to one plain value, so clikae reports it as unknown rather than guessing."* ]] || false
}

@test "codex: an argv profile and a root profile key that disagree are unknown; the argv's layer is not assumed to win (#239)" {
  _stub_engine codex
  _codex_tank work 'model_reasoning_effort = "low"
profile = "b"
[profiles.b]
model = "b-model"'
  _codex_layer work a 'model = "a-model"
model_reasoning_effort = "high"'
  _work_json -- exec -p a 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field model_source)" = unknown ]
  # Nothing but the argv's layer and the root table name an effort, and the
  # layer is documented as going on top.
  [ "$(_json_field effort)" = high ]
  [ "$(_json_field effort_source)" = profile ]
  [[ "$stderr" == *"selected by a profile option in the arguments after -- and the profile key in config.toml"* ]] || false
  rm -f "$L" "$A"
  _work_json --require-declared -- exec -p a 'do it'
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: unknown model" ]
  [ ! -e "$L" ]
}

@test "codex: an argv profile and a root profile key that agree are that value (#239)" {
  _stub_engine codex
  _codex_tank work 'model_reasoning_effort = "low"
profile = "b"
[profiles.b]
model = "one-model"'
  _codex_layer work a 'model = "one-model"'
  _work_json --require-declared -- exec --profile=a 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = one-model ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = low ]
  [ "$(_json_field effort_source)" = profile ]
}

@test "codex: a selected profile that exists nowhere is unknown (#239)" {
  _stub_engine codex
  _codex_tank work 'model = "root-model"
model_reasoning_effort = "low"
profile = "gone"
[profiles.x]
model = "layer-model"'
  _work_json --prompt 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field effort)" = unknown ]
  [[ "$stderr" == *'profile "gone" is neither a [profiles.gone] table in config.toml nor a gone.config.toml file'* ]] || false
  # Named in the argv instead: the same.
  printf '%s\n' 'model = "root-model"' 'model_reasoning_effort = "low"' \
    > "$CLIKAE_HOME/profiles/codex/work/config.toml"
  rm -f "$L" "$A"
  _work_json --require-declared -- exec -p gone 'do it'
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: unknown model or effort" ]
  [[ "$stderr" == *'profile "gone" is neither a [profiles.gone] table in config.toml nor a gone.config.toml file'* ]] || false
  [ ! -e "$L" ]
}

@test "codex: an argv profile on a tank with no config.toml at all still reads its layer (#239)" {
  _stub_engine codex
  _codex_tank work
  rm -f "$CLIKAE_HOME/profiles/codex/work/config.toml"
  _codex_layer work fast 'model = "layer-model"'
  _work_json -- exec -p fast 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = layer-model ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort)" = undeclared ]
  [ "$(_json_field effort_source)" = undeclared ]
}

@test "codex: a selected layer's value that is not a one-line string is unknown (#239)" {
  _codex_profiled
  _codex_layer work fast 'model = 5
model_reasoning_effort = "high"'
  _work_json -- exec -p fast 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field model_source)" = unknown ]
  [ "$(_json_field effort)" = high ]
  [ "$(_json_field effort_source)" = profile ]
  # The same under the root key's table, and for a profile key that is no name.
  printf '%s\n' 'model = "root-model"' 'profile = "x"' '[profiles.x]' 'model = ["a", "b"]' \
    > "$CLIKAE_HOME/profiles/codex/work/config.toml"
  rm -f "$L" "$A"
  _work_json --prompt 'do it'
  [ "$(_json_field model)" = unknown ]
  printf '%s\n' 'model = "root-model"' 'model_reasoning_effort = "low"' 'profile = 3' \
    > "$CLIKAE_HOME/profiles/codex/work/config.toml"
  rm -f "$L" "$A"
  _work_json --prompt 'do it'
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field effort)" = unknown ]
  [[ "$stderr" == *"the profile it names cannot be read with certainty"* ]] || false
}

@test "codex: a profile selection the argv makes unreadably is unknown (#239)" {
  _codex_profiled
  _codex_layer work a 'model = "a-model"'
  _codex_layer work b 'model = "b-model"'
  local -a argv
  local i=0
  for i in 1 2 3 4 5; do
    case "$i" in
      1) argv=(-p a -p b) ;;                       # codex refuses it given twice
      2) argv=(-c 'profile="a"') ;;                # the root key, overridden
      3) argv=(-c 'profiles.a.model="other"') ;;   # a layer, overridden
      4) argv=(-p 'a/b') ;;                        # not a file name
      5) argv=(--profile=) ;;
    esac
    rm -f "$L" "$A"
    _work_json --require-declared -- exec "${argv[@]}" 'do it'
    [ "$status" -eq 1 ] || { echo "case $i ran: $output"; false; }
    [ "$(_json_field reason)" = "refused: unknown model or effort" ] || { echo "case $i: $output"; false; }
    [[ "$stderr" == *"the profile it names cannot be read with certainty"* ]] || false
    [ ! -e "$L" ]
  done
}

@test "codex: a selected layer file that is broken, or selects again, is unknown (#239)" {
  _codex_profiled
  _codex_layer work fast 'model = "unterminated'
  _work_json -- exec -p fast 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field effort)" = unknown ]
  [[ "$stderr" == *"fast.config.toml is not valid TOML (or could not be opened)"* ]] || false
  _codex_layer work fast 'model = "layer-model"
profile = "deeper"'
  rm -f "$L" "$A"
  _work_json -- exec -p fast 'do it'
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field effort)" = unknown ]
  [[ "$stderr" == *"fast.config.toml carries profile settings of its own"* ]] || false
}

@test "codex: an explicit model option in the argv is still that model with a profile selected (#239)" {
  _codex_root_key_tank
  _work_json -- exec -m gpt-actual 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gpt-actual ]
  [ "$(_json_field model_source)" = flag ]
  [ "$(_json_field effort)" = unknown ]
  [ "$(_json_field effort_source)" = unknown ]
}
