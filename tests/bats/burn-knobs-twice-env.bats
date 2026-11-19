#!/usr/bin/env bats
# #244: duplicate detection must not depend on which effort value wins.
# Exercise the real burn resolver and preflight; only the engine is a stub.

load '../helpers'

_claude_fixture() {
  unset ANTHROPIC_MODEL CLAUDE_CODE_EFFORT_LEVEL
  local bin="$TEST_HOME/bin"
  mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGV_LOG"
printf 'artifact\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$bin/claude"
  export PATH="$bin:$PATH"
  export STUB_ARGV_LOG="$TEST_HOME/argv.log" STUB_ARTIFACT="$TEST_HOME/out.md"
  clikae init claude work
}

@test "claude: environment precedence does not permit effort named twice (#244)" {
  _claude_fixture
  CLAUDE_CODE_EFFORT_LEVEL=high run clikae burn claude work \
    --artifact "$STUB_ARTIFACT" --prompt 'do it' --effort high -- --effort low
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort is given twice"* ]] || false
  [ ! -e "$STUB_ARGV_LOG" ]
  [ ! -e "$STUB_ARTIFACT" ]
}

@test "claude: an outranked effort duplicates burn's flag even if equal or unreadable (#244)" {
  _claude_fixture
  local value
  for value in high low '' invalid; do
    CLAUDE_CODE_EFFORT_LEVEL=high run clikae burn claude work \
      --artifact "$STUB_ARTIFACT" --prompt 'do it' --effort high --json -- "--effort=$value"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"reason":"refused: --effort given twice"'* ]] || false
    [ ! -e "$STUB_ARGV_LOG" ]
    [ ! -e "$STUB_ARTIFACT" ]
  done
  CLAUDE_CODE_EFFORT_LEVEL=high run clikae burn claude work \
    --artifact "$STUB_ARTIFACT" --prompt 'do it' --effort high -- --effort
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort is given twice"* ]] || false
  [ ! -e "$STUB_ARGV_LOG" ]
}

@test "claude: both duplicate knobs are reported when argv effort is outranked (#244)" {
  _claude_fixture
  CLAUDE_CODE_EFFORT_LEVEL=high run clikae burn claude work \
    --artifact "$STUB_ARTIFACT" --prompt 'do it' --model opus --effort high \
    --json -- --model sonnet --effort low
  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason":"refused: --model and --effort given twice"'* ]] || false
  [ ! -e "$STUB_ARGV_LOG" ]
  [ ! -e "$STUB_ARTIFACT" ]
}

@test "claude: model naming still refuses readable and unknown argv with an environment model (#244)" {
  _claude_fixture
  local value
  for value in sonnet ''; do
    ANTHROPIC_MODEL=opus run clikae burn claude work \
      --artifact "$STUB_ARTIFACT" --prompt 'do it' --model opus --json -- "--model=$value"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"reason":"refused: --model given twice"'* ]] || false
    [ ! -e "$STUB_ARGV_LOG" ]
    [ ! -e "$STUB_ARTIFACT" ]
  done
}

@test "claude: an outranked argv effort alone still reports the environment (#244)" {
  _claude_fixture
  CLAUDE_CODE_EFFORT_LEVEL=high run clikae burn claude work \
    --artifact "$STUB_ARTIFACT" --prompt 'do it' --json -- --effort low
  [ "$status" -eq 0 ]
  [[ "$output" == *'"effort":"high","effort_source":"env"'* ]] || false
  grep -qx -- '--effort' "$STUB_ARGV_LOG"
  grep -qx low "$STUB_ARGV_LOG"
  [ -s "$STUB_ARTIFACT" ]
}

@test "claude: effort text consumed as a value or after the terminator is not a duplicate (#244)" {
  _claude_fixture
  local form
  for form in --system-prompt --; do
    CLAUDE_CODE_EFFORT_LEVEL=high run clikae burn claude work \
      --artifact "$STUB_ARTIFACT" --fresh --prompt 'do it' --effort high \
      --json -- "$form" --effort low
    [ "$status" -eq 0 ]
    [[ "$output" == *'"effort":"high","effort_source":"flag"'* ]] || false
    [ -s "$STUB_ARTIFACT" ]
  done
}
