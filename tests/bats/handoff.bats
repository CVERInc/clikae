#!/usr/bin/env bats
# tests/bats/handoff.bats — `clikae handoff`
#
# handoff reads (never writes) the current dir's transcript and renders a brief.
# We seed a realistic JSONL transcript: real typed prompts, plus the noise that
# also lives under role:user (tool results, meta/command wrappers) which the raw
# extract must filter out.

load '../helpers'

_slug() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

# Seed a transcript for <profile> covering <dir>.
_seed_transcript() {
  local profile="$1" dir="$2" sid="$3"
  local slug; slug="$(_slug "$dir")"
  local d="$CLIKAE_HOME/profiles/claude/$profile/projects/$slug"
  mkdir -p "$d"
  {
    echo '{"type":"user","cwd":"'"$dir"'","gitBranch":"main","version":"2.1.158","sessionId":"'"$sid"'","message":{"role":"user","content":"first real prompt"},"timestamp":"2026-05-31T01:00:00.000Z"}'
    echo '{"type":"user","isMeta":true,"message":{"role":"user","content":"<command-name>/clear</command-name>"},"timestamp":"2026-05-31T01:00:01.000Z"}'
    echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]},"timestamp":"2026-05-31T01:00:02.000Z"}'
    echo '{"type":"user","toolUseResult":true,"message":{"role":"user","content":[{"type":"tool_result","content":"SHOULD NOT APPEAR file dump"}]},"timestamp":"2026-05-31T01:00:03.000Z"}'
    echo '{"type":"user","message":{"role":"user","content":"second real prompt"},"timestamp":"2026-05-31T01:05:00.000Z"}'
  } > "$d/$sid.jsonl"
}

@test "handoff raw extract shows only real typed prompts, with metadata" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "11111111-2222-3333-4444-555555555555"

  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae handoff claude
  [ "$status" -eq 0 ]
  # Real prompts present, in order.
  [[ "$output" == *"first real prompt"* ]] || false
  [[ "$output" == *"second real prompt"* ]] || false
  # Noise filtered out.
  [[ "$output" != *"SHOULD NOT APPEAR"* ]] || false
  [[ "$output" != *"/clear"* ]] || false
  # Reliable metadata.
  [[ "$output" == *"$work"* ]] || false
  [[ "$output" == *"main"* ]] || false
  [[ "$output" == *"2.1.158"* ]] || false
}

@test "handoff auto-detects the profile from CLAUDE_CONFIG_DIR" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae handoff claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"second real prompt"* ]] || false
}

@test "handoff pipes the session to a summarizer and uses its output" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "22222222-2222-2222-2222-222222222222"
  cd "$work"
  # Summarizer echoes a marker and counts the lines it received on stdin.
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" \
    run clikae handoff claude --summarizer 'cat >/dev/null; echo BRIEF_FROM_MODEL'
  [ "$status" -eq 0 ]
  [[ "$output" == *"BRIEF_FROM_MODEL"* ]] || false
  # The model output replaces the raw extract entirely.
  [[ "$output" != *"raw extract"* ]] || false
}

@test "handoff falls back to raw when the summarizer emits nothing" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "33333333-3333-3333-3333-333333333333"
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" \
    run clikae handoff claude --summarizer 'true'
  [ "$status" -eq 0 ]
  [[ "$output" == *"raw extract"* ]] || false
  [[ "$output" == *"second real prompt"* ]] || false
}

@test "handoff auto-detects a local on-device summarizer and feeds it the cleaned digest" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "a1111111-1111-1111-1111-111111111111"
  # Stub a local model named `apfel` on PATH: it confirms the cleaned digest (the
  # real prompt) reached it on stdin, then emits a brief.
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/apfel" <<'STUB'
#!/usr/bin/env bash
if grep -q "second real prompt"; then echo "ONDEVICE_BRIEF saw-the-prompt"; else echo "ONDEVICE_BRIEF no-prompt"; fi
STUB
  chmod +x "$TEST_HOME/bin/apfel"
  cd "$work"
  PATH="$TEST_HOME/bin:$PATH" CLIKAE_HANDOFF_AUTOLOCAL=1 \
    CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae handoff claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"ONDEVICE_BRIEF saw-the-prompt"* ]] || false
  # Announced the on-device summarizer, and didn't fall back to the raw extract.
  [[ "$output" == *"on-device"* ]] || false
  [[ "$output" != *"raw extract"* ]] || false
}

@test "handoff auto-local can be turned off with CLIKAE_HANDOFF_AUTOLOCAL=0" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "a2222222-2222-2222-2222-222222222222"
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/apfel" <<'STUB'
#!/usr/bin/env bash
echo "SHOULD_NOT_RUN"
STUB
  chmod +x "$TEST_HOME/bin/apfel"
  cd "$work"
  # Even with apfel on PATH, AUTOLOCAL=0 keeps it to the dependency-free raw extract.
  PATH="$TEST_HOME/bin:$PATH" CLIKAE_HANDOFF_AUTOLOCAL=0 \
    CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae handoff claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"raw extract"* ]] || false
  [[ "$output" != *"SHOULD_NOT_RUN"* ]] || false
}

@test "handoff writes to --out" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "44444444-4444-4444-4444-444444444444"
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" \
    run clikae handoff claude --out "$work/HANDOFF.md"
  [ "$status" -eq 0 ]
  [ -f "$work/HANDOFF.md" ]
  grep -q "second real prompt" "$work/HANDOFF.md"
}

@test "handoff --to starts the target CLI seeded with the brief" {
  # Stub codex on PATH: record CODEX_HOME + the prompt it was started with.
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/codex" <<'STUB'
#!/usr/bin/env bash
{ echo "CODEX_HOME=$CODEX_HOME"; echo "PROMPT=$1"; } > "$CODEX_STUB_LOG"
exit 0
STUB
  chmod +x "$TEST_HOME/bin/codex"
  export PATH="$TEST_HOME/bin:$PATH" CODEX_STUB_LOG="$TEST_HOME/codex.log"

  clikae init claude a
  clikae init codex work
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "55555555-5555-5555-5555-555555555555"

  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" \
    run clikae handoff claude --to codex/work
  [ "$status" -eq 0 ]
  # Codex was launched under its own profile dir...
  grep -q "CODEX_HOME=$CLIKAE_HOME/profiles/codex/work" "$CODEX_STUB_LOG"
  # ...and seeded with the brief (which contains the real prompt).
  grep -q "second real prompt" "$CODEX_STUB_LOG"
}

@test "handoff --to antigravity launches the launch-only target with the brief" {
  # Stub agy on PATH: record its argv.
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/agy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$AGY_STUB_LOG"
exit 0
STUB
  chmod +x "$TEST_HOME/bin/agy"
  export PATH="$TEST_HOME/bin:$PATH" AGY_STUB_LOG="$TEST_HOME/agy.log"

  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "77777777-7777-7777-7777-777777777777"
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae handoff claude --to antigravity
  [ "$status" -eq 0 ]
  # agy was started with -i and the brief.
  grep -q '^-i$' "$AGY_STUB_LOG"
  grep -q "second real prompt" "$AGY_STUB_LOG"
}

@test "handoff --to a launch-only target rejects a /profile" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "88888888-8888-8888-8888-888888888888"
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae handoff claude --to antigravity/foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"single-account handoff target"* ]] || false
}

@test "handoff --to an unknown target errors clearly" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "99999999-9999-9999-9999-999999999999"
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae handoff claude --to nosuchcli
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown handoff target"* ]] || false
}

@test "handoff --to errors when the target can't be seeded with a prompt" {
  clikae init claude a
  clikae init aws work   # aws adapter has no adapter_start_with_prompt
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "66666666-6666-6666-6666-666666666666"
  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" \
    run clikae handoff claude --to aws/work
  [ "$status" -ne 0 ]
  [[ "$output" == *"can't be started from a handoff brief"* ]] || false
}

@test "handoff errors when there's no session for this directory" {
  clikae init claude a
  local empty="$TEST_HOME/empty"; mkdir -p "$empty"
  cd "$empty"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae handoff claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"No session for this directory"* ]] || false
}
