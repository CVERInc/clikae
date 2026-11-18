#!/usr/bin/env bats
# tests/bats/burn-knobs-argv.bats — #240: the Claude and agy readers of the
# arguments after `--` follow each engine's own option syntax, as the Codex
# one has since #238:
#   1. they stop at the option terminator, and know which options take the
#      next argument as their value;
#   2. they read every spelling the engine accepts for the model and the
#      effort and no other; what cannot be read with certainty is `unknown`;
#   3. a knob named to burn and again after `--` is refused;
#   4. an effort after `--` is refused with a cross-engine --to, as a model is;
#   5. nothing on these paths depends on the locale;
#   6. (#242) the claude reader applies the rules of claude's own option
#      parser — a value option takes the next argument even when it is `--`,
#      an optional value is never an argument that starts with `-`, a list
#      option takes the plain arguments after it, and only a plain argument
#      that no option took can be a subcommand — and an option a reader does
#      not have is read each way it could be taken;
#   7. (#242) the option lists are the installed engine's.
# Each engine's syntax is the one its own --help lists (claude 2.1.326,
# agy 1.5.9). Stub engines only; no real engine is ever launched. Section 7
# asks the installed engine for its --help and --version, and skips without it.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'
bats_require_minimum_version 1.5.0   # for `run --separate-stderr`

_KNOB_LOCALES="C POSIX C.UTF-8 en_US.UTF-8"

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
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
}

_knobs_init() {
  unset ANTHROPIC_MODEL CLAUDE_CODE_EFFORT_LEVEL
  git init -q "$BATS_TEST_TMPDIR"
  A="$BATS_TEST_TMPDIR/out.md"; L="$TEST_HOME/argv.log"
  export STUB_ARTIFACT="$A" STUB_ARGV_LOG="$L"
}

_codex_tank() {   # <tank> [config.toml body]
  clikae init codex "$1"
  [ $# -lt 2 ] || printf '%s\n' "$2" > "$CLIKAE_HOME/profiles/codex/$1/config.toml"
}

_claude_tank() {  # <tank> [settings.json body]
  clikae init claude "$1"
  [ $# -lt 2 ] || printf '%s\n' "$2" > "$CLIKAE_HOME/profiles/claude/$1/settings.json"
}

_json_field() {   # <key> -> the string value of "key" in $output
  printf '%s' "$output" | grep -oE "\"$1\":(\"[^\"]*\"|null)" | head -n 1 | sed -E 's/^"[^"]*"://; s/^"//; s/"$//'
}

# --json goes ahead of the `--`: after it, it would land in the engine's argv.
_burn_j() {
  run --separate-stderr clikae burn "$@"
}

# _reads <engine> <expected lines> <argv...> — what the engine's reader makes
# of an argv, in a child shell started in each locale of _KNOB_LOCALES. The
# same answer is required in all of them; LC_ALL=C is the first.
_reads() {
  local eng="$1" want="$2" loc; shift 2
  for loc in $_KNOB_LOCALES; do
    if [ "$eng" = claude ]; then
      run env -u CLAUDE_CODE_EFFORT_LEVEL LC_ALL="$loc" bash -c \
        'source "$1/adapters/claude.sh" 2>/dev/null; shift; adapter_burn_knobs_from_args "$@"' _ "$CLIKAE_LIB" "$@"
    else
      run env LC_ALL="$loc" bash -c \
        'source "$1/core/burn_knobs.sh"; shift; _burn_knobs_from_args agy "$@"' _ "$CLIKAE_LIB" "$@"
    fi
    [ "$status" -eq 0 ] || { echo "$eng LC_ALL=$loc [$*] rc=$status: $output"; return 1; }
    [ "$output" = "$want" ] || { echo "$eng LC_ALL=$loc [$*] -> [$output], want [$want]"; return 1; }
  done
}

# _hop <engine> <to> <argv...> — _burn_knobs_check_hop for a burn started on
# <engine>; prints the short reason when it refuses.
_hop() {
  local eng="$1"; shift
  run env LC_ALL=C bash -c '
    lib="$1"; eng="$2"; shift 2
    source "$lib/core/burn_knobs.sh"
    case "$eng" in agy) ;; *) source "$lib/adapters/$eng.sh" 2>/dev/null ;; esac
    CLIKAE_LIB="$lib"
    _burn_knobs_check_hop "$eng" "$@" && exit 0
    printf "%s\n" "$_BURN_KNOBS_REFUSAL_REASON"; exit 1' _ "$CLIKAE_LIB" "$eng" "$@"
}

setup_knob_lib() { CLIKAE_LIB="${CLIKAE_LIB:-$CLIKAE_TEST_ROOT/lib}"; export CLIKAE_LIB; }

# ── 1. the option terminator ─────────────────────────────────────────────────

@test "claude: a prompt after the option terminator is not a model flag — the reported reproduction (#240)" {
  _stub_engine claude
  _claude_tank work '{ "model": "opus" }'
  _burn_j claude work --artifact "$A" --json -- -p -- '--model=not-a-flag'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = opus ]
  [ "$(_json_field model_source)" = profile ]
  # shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
  [[ "$stderr" == *"burn claude/work: model opus (profile)"* ]] || false
  # The argv itself is untouched.
  grep -qx -- '--model=not-a-flag' "$L"
}

@test "claude: the same reproduction under LC_ALL=C (#240)" {
  _stub_engine claude
  _claude_tank work '{ "model": "opus" }'
  LC_ALL=C _burn_j claude work --artifact "$A" --json -- -p -- '--model=not-a-flag' --effort high
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = opus ]
  [ "$(_json_field model_source)" = profile ]
  [ "$(_json_field effort_source)" = undeclared ]
}

@test "claude reader: nothing after -- is read, in any spelling (#240)" {
  setup_knob_lib
  _reads claude '' -p -- '--model=not-a-flag'
  _reads claude '' -p 'do it' -- --model sonnet --effort high
  _reads claude 'model=opus' --model opus -p -- --model sonnet --effort=low
  _reads claude '' -- -pc --model x
}

@test "agy reader: nothing after -- is read, and flag parsing ends at the first plain argument (#240)" {
  setup_knob_lib
  _reads agy '' --dangerously-skip-permissions -- --model=x
  _reads agy '' -- --model x --effort high
  _reads agy 'effort=low' --effort low -- -effort=high -model=x
  # agy 1.5.9 stops reading flags at a plain argument (and then refuses it).
  _reads agy '' stray --model x
  _reads agy '' - --model x
}

@test "claude reader: an option that takes a value takes the next argument, whatever it looks like (#240)" {
  setup_knob_lib
  # --system-prompt <prompt>: `--model` is the system prompt, `x` the prompt.
  _reads claude '' --system-prompt --model x
  # …and `--` in that position is the value, not the terminator.
  _reads claude 'model=x' --system-prompt -- --model=x
  _reads claude 'effort=high' -n --model --effort high
  _reads claude 'model=x' --add-dir a b --model x
  _reads claude 'model=x' --permission-mode acceptEdits --model x
}

@test "agy reader: a flag that takes a value takes the next argument, whatever it looks like (#240)" {
  setup_knob_lib
  # -p <prompt>: the prompt is `--model=x`.
  _reads agy '' -p --model=x
  _reads agy '' --print --model x
  # `--` after a value flag is its value; the flags go on.
  _reads agy 'model=x' --print -- --model x
  _reads agy 'model=x' --log-file /tmp/l --add-dir /a -model x
  # Flags its --help shows taking none.
  _reads agy 'model=x' --sandbox --dangerously-skip-permissions -c --model x
}

# ── 2. the spellings each engine accepts, and no other ───────────────────────

@test "claude reader: --model/--effort as a separate argument or with =, and no short form (#240)" {
  setup_knob_lib
  _reads claude $'model=opus\neffort=high' --model opus --effort high
  _reads claude $'model=opus\neffort=high' --model=opus --effort=high
  _reads claude 'model=claude-x[1m]' -p 'do it' --model 'claude-x[1m]'
  # claude has no -m, and takes no abbreviation or other case: not a model.
  _reads claude '' -m opus
  _reads claude '' --mod opus
  _reads claude '' --Model opus
}

@test "claude reader: clustered short options are read letter by letter (#240)" {
  setup_knob_lib
  # -p and -c take no value.
  _reads claude 'model=x' -pc --model x
  # -n <name>: at the end of a cluster it takes the next argument…
  _reads claude '' -pn --model x
  # …and what is glued after it is the name.
  _reads claude 'model=x' -pnNAME --model x
  _reads claude 'model=x' -dhooks --model x
  # A letter claude's --help does not list: what follows cannot be vouched for.
  _reads claude 'model?' -px --model x
  _reads claude 'effort?' -pZ --effort=high
}

@test "claude reader: after an option it does not know, a model or effort is unknown, never a guess (#240)" {
  setup_knob_lib
  _reads claude 'model?' --frobnicate --model x
  # `--model` may be that option's value. The effort is read the same way
  # whether it is or not.
  _reads claude $'model?\neffort=high' --frobnicate --model x --effort high
  # With = the unknown option is one argument: nothing is left open.
  _reads claude 'model=x' --frobnicate=1 --model x
  # Is `--` its value or the terminator? Not known.
  _reads claude 'model?' --frobnicate -- --model=x
  _reads claude '' --frobnicate y -- --model=x
  # What was read before it stands.
  _reads claude 'model=a' --model a --frobnicate y
  _reads claude 'model?' --model a --frobnicate --model b
}

@test "claude reader: a subcommand has its own options — a model after it is unknown (#240)" {
  setup_knob_lib
  _reads claude 'model?' mcp list --model x
  # `mcp` after -r [value] is the session to resume, not the subcommand.
  _reads claude 'model=x' -r mcp --model x
  _reads claude 'model=x' -p 'do it' --model x
  _reads claude 'model=x' -p 'do it' mcp --model x
}

@test "claude reader: a value that cannot be the one that runs is unknown (#240)" {
  setup_knob_lib
  _reads claude 'model?' --model
  _reads claude 'model?' --model=
  _reads claude 'model?' --model -x
  _reads claude 'model?' --model $'a\033b'
  _reads claude 'model?' --model a --model b
  _reads claude 'model=a' --model a --model=a
  _reads claude 'effort?' --effort bogus
  _reads claude 'effort?' --effort=High
  _reads claude 'effort?' --effort 'low medium'
  _reads claude 'effort?' --effort low --effort=high
  _reads claude 'effort?' --effort
}

@test "agy reader: one dash or two, a separate argument or =; no short form and no cluster (#240)" {
  setup_knob_lib
  _reads agy $'model=x\neffort=high' --model x --effort high
  _reads agy $'model=x\neffort=high' -model x -effort high
  _reads agy $'model=x\neffort=high' --model=x -effort=high
  _reads agy 'model=x' -c=false -model=x
  # agy 1.5.9 defines no -m: clikae cannot vouch for it either way.
  _reads agy 'model?' -m x
  _reads agy 'model?' -m=x
  # No clusters: -pc is one flag agy does not define.
  _reads agy 'model?' -pc --model x
  _reads agy 'model?' --frobnicate --model x
  _reads agy 'model=x' --frobnicate=1 --model x
  _reads agy '' --frobnicate y -- --model=x
  # Flags whose kind its --help does not show: neither takes a value.
  _reads agy 'model=x' --remote-control --model x
  _reads agy 'model=x' --remote-agent --remote-control=true --model x
}

@test "agy reader: a value that cannot be the one that runs is unknown (#240)" {
  setup_knob_lib
  _reads agy 'model?' --model
  _reads agy 'model?' --model=
  # agy takes `--effort` as the model here; the effort is not set.
  _reads agy 'model?' --model --effort high
  _reads agy 'model?' --model a --model b
  _reads agy 'model=a' --model a -model=a
  _reads agy 'effort?' --effort bogus
  _reads agy 'effort?' --effort=High
  _reads agy 'model?' --model $'a\033b'
}

@test "claude: an unknown model after -- is reported as unknown, and --require-declared refuses it (#240)" {
  _stub_engine claude
  _claude_tank work '{ "model": "opus" }'
  # -x is not a claude option: `--model` may be its value.
  _burn_j claude work --artifact "$A" --json -- -px --model sonnet 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field model_source)" = unknown ]
  rm -f "$L" "$A"
  _burn_j claude work --artifact "$A" --json --require-declared -- -px --model sonnet 'do it'
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: unknown model" ]
  [ ! -e "$L" ]
  # With the prompt between them every reading gives the same model.
  _burn_j claude work --artifact "$A" --json -- -px 'do it' --model sonnet
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = sonnet ]
  [ "$(_json_field model_source)" = flag ]
}

@test "agy: a model after -- in the one-dash spelling is reported as a flag (#240)" {
  _stub_agy
  _burn_j agy default --artifact "$A" --json --prompt 'do it' -- -model=gem-x -effort high
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = gem-x ]
  [ "$(_json_field model_source)" = flag ]
  [ "$(_json_field effort)" = high ]
  [ "$(_json_field effort_source)" = flag ]
}

# ── 3. the same knob named twice ─────────────────────────────────────────────

@test "claude: burn's --model/--effort and the same one after -- are refused before launch (#240)" {
  _stub_engine claude
  _claude_tank work
  run clikae burn claude work --artifact "$A" --prompt 'do it' --model opus -- --model=sonnet
  [ "$status" -eq 1 ]
  [[ "$output" == *"--model is given twice"* ]] || false
  run clikae burn claude work --artifact "$A" --prompt 'do it' --effort high -- -c --effort low
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort is given twice"* ]] || false
  # One that would not start is still a second naming.
  run clikae burn claude work --artifact "$A" --prompt 'do it' --model opus -- --model
  [ "$status" -eq 1 ]
  [[ "$output" == *"--model is given twice"* ]] || false
  [ ! -e "$L" ]
}

@test "claude: text after the option terminator is not a second naming (#240)" {
  _stub_engine claude
  _claude_tank work
  _burn_j claude work --artifact "$A" --json --prompt 'do it' --model opus -- -- '--model=not-a-flag'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = opus ]
  [ "$(_json_field model_source)" = flag ]
}

@test "agy: burn's --model/--effort and the same one after -- are refused before launch, in every spelling (#240)" {
  _stub_agy
  local extra
  for extra in '--model=b' '-model=b' '-model b' '--model b' '-m b'; do
    # shellcheck disable=SC2086  # two words on purpose
    run clikae burn agy default --artifact "$A" --prompt 'do it' --model a -- $extra
    [ "$status" -eq 1 ] || { echo "[$extra] ran: $output"; false; }
    [[ "$output" == *"--model is given twice"* ]] || false
  done
  run clikae burn agy default --artifact "$A" --prompt 'do it' --effort low -- -effort=high
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort is given twice"* ]] || false
  [ ! -e "$L" ]
  # After the terminator it is not a flag.
  _burn_j agy default --artifact "$A" --json --prompt 'do it' --model a -- --sandbox -- -model=b
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = a ]
}

# ── 4. an effort after -- and a cross-engine --to ────────────────────────────

@test "codex source: an effort after -- with a cross-engine --to is refused before the first tank runs (#240)" {
  STUB_HOME_VAR=CODEX_HOME; export STUB_HOME_VAR
  _stub_engine codex
  _stub_engine claude
  _codex_tank work
  _claude_tank second
  : > "$CLIKAE_HOME/profiles/codex/work/.dry"
  _burn_j codex work --artifact "$A" --json --prompt 'do it' --to claude/second \
    -- -c 'model_reasoning_effort="high"'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--to claude/second: the arguments after -- name an effort"* ]] || false
  [[ "$stderr" == *"unchanged to both codex and claude"* ]] || false
  [[ "$stderr" == *"Nothing was started."* ]] || false
  [ "$(_json_field reason)" = "refused: the arguments after -- name an effort; --to claude/second would pass it to claude unchanged" ]
  [ ! -e "$L" ]
  [ ! -e "$A" ]
  grep -q '"state":"fail"' "$CLIKAE_HOME"/logs/burn-*/status.json
}

@test "claude source: an effort after -- with a cross-engine --to is refused before the first tank runs (#240)" {
  STUB_HOME_VAR=CLAUDE_CONFIG_DIR; export STUB_HOME_VAR
  _stub_engine codex
  _stub_engine claude
  _claude_tank work
  _codex_tank second
  : > "$CLIKAE_HOME/profiles/claude/work/.dry"
  _burn_j claude work --artifact "$A" --json --prompt 'do it' --to codex/second -- --effort high
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--to codex/second: the arguments after -- name an effort"* ]] || false
  [[ "$stderr" == *"unchanged to both claude and codex"* ]] || false
  [ "$(_json_field reason)" = "refused: the arguments after -- name an effort; --to codex/second would pass it to codex unchanged" ]
  [ ! -e "$L" ]
  # The same arguments with a --to on the SAME engine are a plain burn.
  _claude_tank spare
  rm -f "$CLIKAE_HOME/profiles/claude/work/.dry"
  _burn_j claude work --artifact "$A" --json --prompt 'do it' --to claude/spare -- --effort high
  [ "$status" -eq 0 ]
  [ "$(_json_field effort)" = high ]
  [ "$(_json_field effort_source)" = flag ]
}

@test "an effort after -- is refused with a cross-engine --to from each of the three engines, readable or not (#240)" {
  setup_knob_lib
  local want='the arguments after -- name an effort; --to'
  _hop claude codex/b --effort high
  [ "$status" -eq 1 ]; [[ "$output" == "$want codex/b would pass it to codex unchanged" ]] || false
  _hop claude agy/b -p 'do it' --effort=bogus
  [ "$status" -eq 1 ]; [[ "$output" == "$want agy/b would pass it to agy unchanged" ]] || false
  _hop codex claude/b exec -c 'model_reasoning_effort="high"' 'do it'
  [ "$status" -eq 1 ]; [[ "$output" == "$want claude/b would pass it to claude unchanged" ]] || false
  _hop codex agy/b exec -c 'model_reasoning_effort=1' 'do it'
  [ "$status" -eq 1 ]; [[ "$output" == "$want agy/b would pass it to agy unchanged" ]] || false
  _hop agy claude/b -effort=high
  [ "$status" -eq 1 ]; [[ "$output" == "$want claude/b would pass it to claude unchanged" ]] || false
  _hop agy codex/b --effort high
  [ "$status" -eq 1 ]; [[ "$output" == "$want codex/b would pass it to codex unchanged" ]] || false
  # A model is still named first when both are there.
  _hop claude codex/b --effort high --model x
  [ "$status" -eq 1 ]; [[ "$output" == "the arguments after -- name a model; --to codex/b would pass it to codex unchanged" ]] || false
  # After the terminator it is the prompt: nothing to refuse.
  _hop agy claude/b --sandbox -- --effort high
  [ "$status" -eq 0 ]
  _hop claude agy/b -p -- --effort high
  [ "$status" -eq 0 ]
  # Same engine: not a hop.
  _hop claude claude/b --effort high
  [ "$status" -eq 0 ]
}

@test "claude: an effort after -- that CLAUDE_CODE_EFFORT_LEVEL outranks still cannot cross to another engine (#240)" {
  setup_knob_lib
  CLAUDE_CODE_EFFORT_LEVEL=medium _hop claude codex/b --effort high
  [ "$status" -eq 1 ]
  [[ "$output" == "the arguments after -- name an effort; --to codex/b would pass it to codex unchanged" ]] || false
  # On claude itself the variable is still what runs, as before.
  run env CLAUDE_CODE_EFFORT_LEVEL=medium bash -c \
    'source "$1/adapters/claude.sh" 2>/dev/null; shift; adapter_burn_knobs_from_args "$@"' _ "$CLIKAE_LIB" --effort high
  [[ "$output" != *"effort="* ]] || false
  [[ "$output" != *"effort?"* ]] || false
}

# ── 5. nothing here is the locale's to decide ────────────────────────────────

@test "the claude and agy readers match no named character class or \\s (#240)" {
  setup_knob_lib
  local body
  body="$(sed -n '/^# The options of `claude --help`/,/^# _claude_settings_leaf /p' "$CLIKAE_LIB/adapters/claude.sh")"
  [[ "$body" == *"adapter_burn_knobs_from_args() {"* ]] || false
  run grep -nE '^[^#]*(\[\[:[a-z]+:\]\]|\\s)' <<<"$body"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  # burn_knobs.sh holds agy's reader and everything that words a refusal.
  run grep -nE '^[^#]*(\[\[:[a-z]+:\]\]|\\s)' "$CLIKAE_LIB/core/burn_knobs.sh"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  grep -q '^_burn_knobs_agy_from_args() {' "$CLIKAE_LIB/core/burn_knobs.sh"
}

@test "a space that is not plain ASCII is part of the value in every locale (#240)" {
  setup_knob_lib
  local nbsp=$'\xc2\xa0' nel=$'\xc2\x85'
  _reads claude "model=a${nbsp}b" --model "a${nbsp}b"
  _reads claude "model=a${nel}b" --model="a${nel}b"
  _reads agy "model=a${nbsp}b" -model "a${nbsp}b"
  _reads claude 'effort?' --effort "high${nbsp}"
  _reads agy 'effort?' --effort="${nbsp}high"
}

# ── 6. the engine's own rules, case by case (#242) ───────────────────────────
# Each expectation below is what claude 2.1.326's option parser does with the
# argv: which options it sets, and what it leaves as the prompt.

@test "claude reader: an option claude has but its help does not list is read by its kind (#242)" {
  setup_knob_lib
  # --max-turns <turns> takes `1`; --system-prompt <prompt> takes `--`; the
  # model option after it is one.
  _reads claude 'model=sonnet' -p --max-turns 1 --system-prompt -- --model sonnet 'do it'
  # …and with a model before it, the two differ.
  _reads claude 'model?' -p --model opus --max-turns 1 --system-prompt -- --model sonnet 'do it'
  _reads claude 'model=sonnet' --system-prompt -- --model sonnet -p 'do it'
  # --permission-prompt-tool <tool> takes `--model`: no model is named.
  _reads claude '' -p --permission-prompt-tool --model 'do it'
  _reads claude 'model=x' --max-turns 3 --thinking enabled --init --model x
  _reads claude 'model=x' --rc --model x
  # -d2e is one option, not a cluster of -d.
  _reads claude 'model=x' -d2e --model x
}

@test "claude reader: an optional value is never an argument that starts with a dash (#242)" {
  setup_knob_lib
  # `--` after --debug [filter] is the terminator; `--model` is the prompt.
  _reads claude '' -p --debug -- --model
  _reads claude '' -p -d -- --model
  _reads claude '' -r -- --model=x
  _reads claude '' --debug -- --effort=low
  _reads claude '' -w -- --model x --effort high
  _reads claude '' --from-pr -- --model x
  # A dash-prefixed argument after it is an option of its own.
  _reads claude 'model=x' --debug --model x
  _reads claude 'model=x' -r --model x
  # A plain one is its value: `mcp` here is a session name, `x` a filter.
  _reads claude $'model=sonnet\neffort=high' -r mcp --model sonnet --effort high -p 'do it'
  _reads claude 'model=y' --debug x --model y
}

@test "claude reader: a list option takes the plain arguments after it; none of them is a subcommand (#242)" {
  setup_knob_lib
  _reads claude $'model=sonnet\neffort=high' --add-dir lib mcp --model sonnet --effort high -p 'do it'
  _reads claude 'model=x' --allowedTools Bash Edit mcp --model x
  _reads claude 'model=x' --add-dir=lib --model x
  # The list ends at the next option; a subcommand after that is one.
  _reads claude 'model?' --add-dir lib -p mcp --model x
  # The terminator ends the list too.
  _reads claude '' --add-dir lib mcp -- --model x
  # The value of a plain value option is not a subcommand either.
  _reads claude 'model=x' --session-id mcp --model x
  _reads claude 'model=x' -n mcp --model x
}

@test "claude reader: only the first plain argument that no option took can be a subcommand (#242)" {
  setup_knob_lib
  _reads claude 'model?' -p mcp --model x
  _reads claude $'model?\neffort?' agents --model x --effort=high
  # What stood before the subcommand was claude's own.
  _reads claude 'model=a' --model a mcp list
  _reads claude 'model?' --model a mcp --model a
  # After a subcommand `--` is the subcommand's to read.
  _reads claude 'model?' mcp add x -- --model y
  _reads claude 'model=x' hello mcp --model x
  _reads claude '' mcp list
}

@test "claude reader: a flag letter leaves the rest of its cluster to be read as an argument (#242)" {
  setup_knob_lib
  # `-p-` is -p, then `--`.
  _reads claude '' -p- --model x
  _reads claude 'model=x' -pcv --model x
  # -r [value] and -d [filter] take what is glued on; -w too.
  _reads claude 'model=x' -rmcp --model x
  _reads claude 'model=x' -pwname --model x
}

@test "claude reader: an option it does not have is read each way it could be taken (#242)" {
  setup_knob_lib
  # Flag, value or list: `1` aside, the model option is read the same.
  _reads claude 'model=sonnet' -p --frobnicate 1 --system-prompt -- --model sonnet 'do it'
  # A flag: --system-prompt takes `--`, the model is sonnet. A value option:
  # it takes `--system-prompt`, `--` ends the options. Not the profile's.
  _reads claude 'model?' -p --frobnicate --system-prompt -- --model sonnet 'do it'
  _reads claude 'model?' --model opus --frobnicate --system-prompt -- --model sonnet
  # Every reading leaves this after the terminator: it names nothing.
  _reads claude '' --frobnicate y -- --model=x
  _reads claude '' --frobnicate -p -- --model x
  # Its value may be what makes `mcp` the subcommand.
  _reads claude 'model?' --frobnicate x mcp --model y
  _reads claude 'model=y' --frobnicate=x hello --model y
  # Two of them, and more than can be read out.
  _reads claude $'model?\neffort=high' --foo --bar --model x --effort high
  _reads claude 'model=x' --foo 1 --bar 2 --model x
  _reads claude $'model?\neffort?' --a1 --a2 --a3 --a4 --a5 --model x --effort=high
  _reads claude '' --a1 --a2 --a3 --a4 --a5 'do it'
}

@test "agy reader: a flag it does not have is read each way it could be taken (#242)" {
  setup_knob_lib
  # No value: --print takes `--`, the model is x. A value: it takes
  # `--print`, and `--` ends the flags. Not the profile's.
  _reads agy 'model?' --frobnicate --print -- --model x
  _reads agy 'model?' --model a --frobnicate --print -- --model b
  _reads agy 'model=x' --frobnicate --sandbox --model x
  _reads agy '' --frobnicate y -- --model=x
  # Is `--` its value or the terminator? Not known.
  _reads agy 'model?' --frobnicate -- --model=x
  # A subcommand is a plain argument: agy reads no flag after it.
  _reads agy '' mcp --model x
  _reads agy 'model=x' --add-dir mcp --model x
  _reads agy $'model?\neffort?' --a1 --a2 --a3 --a4 --a5 --a6 --model x -effort=high
}

@test "claude: a model after an unlisted option and a value option's \`--\` is the one reported (#242)" {
  _stub_engine claude
  _claude_tank work '{"model":"opus"}'
  CLAUDE_CODE_EFFORT_LEVEL=high _burn_j claude work --artifact "$A" --json --require-declared \
    -- -p --max-turns 1 --system-prompt -- --model sonnet 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = sonnet ]
  [ "$(_json_field model_source)" = flag ]
  grep -qx sonnet "$L"
  # An option the reader does not have, in the same place: not the profile's
  # model, and --require-declared refuses.
  rm -f "$L" "$A"
  CLAUDE_CODE_EFFORT_LEVEL=high _burn_j claude work --artifact "$A" --json --require-declared \
    -- -p --frobnicate --system-prompt -- --model sonnet 'do it'
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: unknown model" ]
  [ ! -e "$L" ]
}

@test "claude: a prompt that looks like a flag, after --debug and the terminator, runs (#242)" {
  _stub_engine claude
  _claude_tank work '{"model":"opus"}'
  CLAUDE_CODE_EFFORT_LEVEL=high _burn_j claude work --artifact "$A" --json --require-declared \
    -- -p --debug -- --model
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = opus ]
  [ "$(_json_field model_source)" = profile ]
  grep -qx -- '--model' "$L"
}

@test "claude: a directory or a session named like a subcommand does not hide the model and effort (#242)" {
  _stub_engine claude
  _claude_tank work '{"model":"opus"}'
  mkdir -p "$BATS_TEST_TMPDIR/lib" "$BATS_TEST_TMPDIR/mcp"
  cd "$BATS_TEST_TMPDIR"
  _burn_j claude work --artifact "$A" --json --require-declared \
    -- --add-dir lib mcp --model sonnet --effort high -p 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = sonnet ]
  [ "$(_json_field model_source)" = flag ]
  [ "$(_json_field effort)" = high ]
  [ "$(_json_field effort_source)" = flag ]
  rm -f "$L" "$A"
  _burn_j claude work --artifact "$A" --json --require-declared \
    -- -r mcp --model sonnet --effort high -p 'do it'
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = sonnet ]
  [ "$(_json_field effort)" = high ]
}

# ── 7. the option lists against the installed engine (#242) ──────────────────
# These three read the engine that is installed on this machine — its help
# text, and for claude the option declarations in its program file. Nothing is
# launched: `--help` and `--version` only. Without the engine they SKIP, and
# say so; they never pass unseen.

# _installed <engine> <pattern> -> the path of the real engine on PATH, or
# empty: a test double does not answer --version like the real one.
_installed() {
  local bin
  bin="$(command -v "$1" 2>/dev/null)" || return 0
  [ -n "$bin" ] || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$bin" --version 2>/dev/null | grep -q -- "$2" || return 0
  else
    "$bin" --version 2>/dev/null | grep -q -- "$2" || return 0
  fi
  printf '%s\n' "$bin"
}

# _spec_kinds: option specs, one per line as claude writes them
# (`-n, --name <name>`) -> `<kind> <name>` for every name.
_spec_kinds() {
  awk '{
    line = $0; kind = "flag"
    if (line ~ / <[^>]*\.\.\.>$/) kind = "variadic"
    else if (line ~ / <.*>$/) kind = "value"
    else if (line ~ / \[.*\]$/) kind = "optional"
    sub(/ [<\[].*$/, "", line)
    n = split(line, names, ", ")
    for (i = 1; i <= n; i++) if (names[i] != "") print kind, names[i]
  }'
}

# _reader_disagrees: `<kind> <name>` lines on stdin -> one line per option the
# claude reader has as another kind, or does not have.
_reader_disagrees() {
  bash -c '
    source "$1/adapters/claude.sh" 2>/dev/null
    while read -r kind name; do
      _claude_opt_kind "$name"
      [ "$_claude_kind" = "$kind" ] || printf "%s: the installed claude has it as %s, the reader as %s\n" \
        "$name" "$kind" "${_claude_kind:-(not in its lists)}"
    done' _ "$CLIKAE_LIB"
}

@test "claude reader: has every option the installed claude --help lists, as the same kind (#242)" {
  setup_knob_lib
  local bin help specs n bad cmds c
  bin="$(_installed claude 'Claude Code')"
  [ -n "$bin" ] || skip "claude is not installed here: its --help cannot be compared with the reader's lists"
  help="$("$bin" --help 2>/dev/null)"
  # An option line is indented by two; its description starts after two or
  # more spaces, or on the next line.
  specs="$(printf '%s\n' "$help" | awk '
    /^Options:/ { on = 1; next }
    /^Commands:/ { on = 0 }
    on && /^  -/ { line = $0; sub(/^  /, "", line); sub(/  +.*$/, "", line); print line }' | _spec_kinds)"
  n="$(printf '%s\n' "$specs" | grep -c . || true)"
  [ "$n" -ge 40 ] || { echo "only $n options read out of claude --help: $help"; false; }
  # The parse itself: these four are one of each kind.
  [[ $'\n'"$specs"$'\n' == *$'\n''flag --print'$'\n'* ]] || false
  [[ $'\n'"$specs"$'\n' == *$'\n''value --model'$'\n'* ]] || false
  [[ $'\n'"$specs"$'\n' == *$'\n''optional -r'$'\n'* ]] || false
  [[ $'\n'"$specs"$'\n' == *$'\n''variadic --add-dir'$'\n'* ]] || false
  bad="$(printf '%s\n' "$specs" | _reader_disagrees)"
  [ -z "$bad" ] || { echo "$bad"; false; }
  # The subcommands it lists, aliases included (`stop|kill <id>`).
  cmds="$(printf '%s\n' "$help" | awk '
    /^Commands:/ { on = 1; next }
    on && /^  [a-z]/ { name = $1; gsub(/\|/, " ", name); print name }')"
  [ -n "$cmds" ] || { echo "no subcommand read out of claude --help"; false; }
  for c in $cmds; do
    # shellcheck disable=SC2016  # expanded by the child shell
    run bash -c 'source "$1/adapters/claude.sh" 2>/dev/null; [[ "$_CLAUDE_COMMANDS" == *" $2 "* ]]' _ "$CLIKAE_LIB" "$c"
    [ "$status" -eq 0 ] || { echo "subcommand $c is in claude --help and not in _CLAUDE_COMMANDS"; false; }
  done
}

@test "claude reader: has every option the installed claude declares, listed in --help or not (#242)" {
  setup_knob_lib
  local bin real specs n bad
  bin="$(_installed claude 'Claude Code')"
  [ -n "$bin" ] || skip "claude is not installed here: its option declarations cannot be compared with the reader's lists"
  real="$(realpath "$bin" 2>/dev/null || readlink -f "$bin" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] || skip "the installed claude ($bin) cannot be resolved to a file to read"
  # An option is declared as `.option("<spec>", …)` or `new <Option>("<spec>", …)`.
  # The main program's declarations stand together; the anchor is -p, --print,
  # and the run of declarations around it less than 20000 bytes apart is the
  # main program's (the subcommands' own are far away, and are not claude's).
  specs="$(LC_ALL=C grep -aobE '(\.option\(|new [A-Za-z_$][A-Za-z0-9_$]*\()"-[^"\\]{1,90}"' "$real" 2>/dev/null | awk '
    {
      off[NR] = $0; sub(/:.*$/, "", off[NR])
      spec[NR] = $0; sub(/^[^"]*"/, "", spec[NR]); sub(/"$/, "", spec[NR])
      if (spec[NR] == "-p, --print" && !anchor) anchor = NR
    }
    END {
      if (!anchor) exit
      lo = anchor; while (lo > 1 && off[lo] - off[lo - 1] < 20000) lo--
      hi = anchor; while (hi < NR && off[hi + 1] - off[hi] < 20000) hi++
      for (i = lo; i <= hi; i++)
        if (spec[i] ~ /^(-[A-Za-z0-9]+, )?--[A-Za-z0-9-]+(, --[A-Za-z0-9-]+)?( [<\[].*[>\]])?$/) print spec[i]
    }' | _spec_kinds)"
  n="$(printf '%s\n' "$specs" | grep -c . || true)"
  [ "$n" -ge 60 ] || skip "the installed claude ($real) does not hold its option declarations in a form this test reads ($n found)"
  [[ $'\n'"$specs"$'\n' == *$'\n''value --model'$'\n'* ]] || false
  [[ $'\n'"$specs"$'\n' == *$'\n''value --max-turns'$'\n'* ]] || false
  bad="$(printf '%s\n' "$specs" | _reader_disagrees)"
  [ -z "$bad" ] || { echo "$bad"; false; }
}

@test "agy reader: has every flag the installed agy --help lists (#242)" {
  setup_knob_lib
  local bin help flags f n=0
  bin="$(_installed agy '[0-9]')"
  [ -n "$bin" ] || skip "agy is not installed here: its --help cannot be compared with the reader's lists"
  help="$("$bin" --help 2>&1 || true)"
  [[ "$help" == *"Usage of agy"* ]] || skip "the installed agy ($bin) does not print the help this test reads"
  flags="$(printf '%s\n' "$help" | awk '/^Available subcommands/ { exit } /^  -/ { f = $1; sub(/^--?/, "", f); print f }')"
  for f in $flags; do
    n=$((n + 1))
    # shellcheck disable=SC2016  # expanded by the child shell
    run bash -c 'source "$1/core/burn_knobs.sh"; [[ "$_BURN_KNOBS_AGY_VALUE$_BURN_KNOBS_AGY_BOOL" == *" $2 "* ]]' _ "$CLIKAE_LIB" "$f"
    [ "$status" -eq 0 ] || { echo "flag --$f is in agy --help and in neither of the reader's lists"; false; }
  done
  [ "$n" -ge 20 ] || { echo "only $n flags read out of agy --help: $help"; false; }
}
