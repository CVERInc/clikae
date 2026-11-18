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
#   5. nothing on these paths depends on the locale.
# Each engine's syntax is the one its own --help lists (claude 2.1.326,
# agy 1.5.9). Stub engines only; no real engine is ever launched.
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
  _reads claude $'model?\neffort?' --frobnicate --model x --effort high
  # With = the unknown option is one argument: nothing is left open.
  _reads claude 'model=x' --frobnicate=1 --model x
  # Is `--` its value or the terminator? Not known.
  _reads claude 'model?' --frobnicate -- --model=x
  _reads claude '' --frobnicate y -- --model=x
  # What was read before it stands.
  _reads claude 'model=a' --model a --frobnicate y
  _reads claude 'model?' --model a --frobnicate --model b
  # An option with an optional value, then `--`.
  _reads claude 'model?' -r -- --model=x
  _reads claude 'effort?' --debug -- --effort=low
}

@test "claude reader: a subcommand has its own options — a model after it is unknown (#240)" {
  setup_knob_lib
  _reads claude 'model?' mcp list --model x
  _reads claude 'model?' -r mcp --model x
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
  # Flags whose kind its --help does not show.
  _reads agy 'model?' --remote-control --model x
  _reads agy 'model=x' --remote-control=true --model x
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
  _burn_j claude work --artifact "$A" --json -- -px 'do it' --model sonnet
  [ "$status" -eq 0 ]
  [ "$(_json_field model)" = unknown ]
  [ "$(_json_field model_source)" = unknown ]
  rm -f "$L" "$A"
  _burn_j claude work --artifact "$A" --json --require-declared -- -px 'do it' --model sonnet
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: unknown model" ]
  [ ! -e "$L" ]
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
