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

# --- #33: per-engine transcript shapes (adapter_handoff_extract) -----------
#
# codex's ASSISTANT turns wrap as a "response item" (OpenAI Responses API
# shape): `role` is present but `content` is an ARRAY of typed parts, not a
# string — the claude-shaped `"role":"user","content":"` anchor never
# matches it. codex's USER turns are event_msg/user_message (round-1 review
# P2-2 — see codex.sh's own comment: a response_item/role:user turn is
# machine-injected context, not something the human typed; a separate test
# below covers that filtering). grok's chat_history.jsonl has no `role` key
# at all: the message kind IS the top-level `type` ("user"/"assistant"),
# with the same array-of-parts `content`. Both fixtures also carry one
# garbage line (malformed JSON) to prove a bad line is skipped, not fatal.

_seed_codex_transcript() {
  local profile="$1" dir="$2" sid="$3"
  local d="$CLIKAE_HOME/profiles/codex/$profile/sessions/2026/09/10"
  mkdir -p "$d"
  {
    echo '{"timestamp":"2026-09-10T12:00:00.000Z","type":"session_meta","payload":{"id":"'"$sid"'","cwd":"'"$dir"'"}}'
    echo '{"timestamp":"2026-09-10T12:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"codex first real prompt"}}'
    echo '{"timestamp":"2026-09-10T12:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"codex working note"}]}}'
    echo 'THIS LINE IS NOT JSON AT ALL {{{ garbage SHOULD-NOT-APPEAR'
    echo '{"timestamp":"2026-09-10T12:00:03.000Z","type":"event_msg","payload":{"type":"user_message","message":"codex second real prompt"}}'
    echo '{"timestamp":"2026-09-10T12:00:04.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"codex last assistant note"}]}}'
  } > "$d/rollout-2026-09-10T12-00-00-$sid.jsonl"
}

@test "#33 handoff on codex extracts prompts (user_message) + notes (response_item) (malformed line skipped, not fatal)" {
  clikae init codex work
  local work="$TEST_HOME/work-codex"; mkdir -p "$work"
  _seed_codex_transcript work "$work" "11111111-1111-1111-1111-111111111111"
  cd "$work"
  # The raw (no-summarizer) brief only ever shows prompts (see
  # _handoff_raw_brief) — assistant notes are part of the CLEAN-TAIL digest,
  # which only a summarizer sees. `cat` as the summarizer echoes that digest
  # back verbatim, so this exercises BOTH _handoff_extract call sites (user
  # AND assistant) for the codex shape in one command, same as the
  # "handoff pipes the session to a summarizer" test above does for claude.
  CODEX_HOME="$CLIKAE_HOME/profiles/codex/work" \
    run clikae handoff codex work --summarizer cat
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex first real prompt"* ]] || false
  [[ "$output" == *"codex second real prompt"* ]] || false
  [[ "$output" == *"codex working note"* ]] || false
  [[ "$output" == *"codex last assistant note"* ]] || false
  # The malformed line neither crashed the command nor leaked into the brief.
  [[ "$output" != *"SHOULD-NOT-APPEAR"* ]] || false
  # Also prove the plain raw-extract path (no summarizer) survives codex's
  # shape and shows the real prompt, not just metadata.
  CODEX_HOME="$CLIKAE_HOME/profiles/codex/work" run clikae handoff codex work
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex second real prompt"* ]] || false
  [[ "$output" == *"raw extract"* ]] || false
}

_seed_codex_whitespace_transcript() {
  # Round-1 review P1-1: the "confirmed against a real rollout" shape
  # (tests/bats/limit-codex-status.bats:215, lib/core/limit.sh's whole codex
  # family) writes a SPACE after every colon — Python's json.dumps default,
  # not the compact form the #33 fixture above uses. A whitespace-blind
  # extractor matches zero lines on exactly this shape and stays silent
  # about it (that was the whole bug); this fixture proves the fix without
  # retiring the compact-JSON coverage above.
  #
  # session_meta stays COMPACT on purpose: `_codex_meta_field` (the
  # unrelated cwd/id lookup `_codex_rollouts_for_cwd` uses to find this file
  # at all) is its own, pre-existing, literal-quote parser — spacing IT is a
  # real gap too, but a different one, out of scope for this fix. Keeping it
  # compact here isolates the test to the thing P1-1 actually changed:
  # adapter_handoff_extract's own anchor/key matching, below.
  local profile="$1" dir="$2" sid="$3"
  local d="$CLIKAE_HOME/profiles/codex/$profile/sessions/2026/09/12"
  mkdir -p "$d"
  {
    echo '{"timestamp":"2026-09-12T00:00:00.000Z","type":"session_meta","payload":{"id":"'"$sid"'","cwd":"'"$dir"'"}}'
    echo '{"timestamp": "2026-09-12T00:00:01.000Z", "type": "event_msg", "payload": {"type": "user_message", "message": "spaced codex prompt"}}'
    echo '{"timestamp": "2026-09-12T00:00:02.000Z", "type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "spaced codex note"}]}}'
  } > "$d/rollout-2026-09-12T00-00-00-$sid.jsonl"
}

@test "#33 round-1 P1-1: codex handoff survives real-rollout JSON whitespace (space after every colon)" {
  clikae init codex spacedwork
  local work="$TEST_HOME/work-codex-spaced"; mkdir -p "$work"
  _seed_codex_whitespace_transcript spacedwork "$work" "55555555-5555-5555-5555-555555555555"
  cd "$work"
  CODEX_HOME="$CLIKAE_HOME/profiles/codex/spacedwork" \
    run clikae handoff codex spacedwork --summarizer cat
  [ "$status" -eq 0 ]
  [[ "$output" == *"spaced codex prompt"* ]] || false
  [[ "$output" == *"spaced codex note"* ]] || false
}

_seed_codex_injected_transcript() {
  # Round-1 review P2-2: a response_item/role:user turn is NOT the same as
  # something the human typed — codex also records machine-injected context
  # that way. Two injected turns ahead of one real (event_msg/user_message)
  # prompt: the digest must show ONLY the human line.
  local profile="$1" dir="$2" sid="$3"
  local d="$CLIKAE_HOME/profiles/codex/$profile/sessions/2026/09/11"
  mkdir -p "$d"
  {
    echo '{"timestamp":"2026-09-11T00:00:00.000Z","type":"session_meta","payload":{"id":"'"$sid"'","cwd":"'"$dir"'"}}'
    echo '{"timestamp":"2026-09-11T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd=/x shell=bash</environment_context>"}]}}'
    echo '{"timestamp":"2026-09-11T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<user_instructions>AGENTS.md contents here</user_instructions>"}]}}'
    echo '{"timestamp":"2026-09-11T00:00:03.000Z","type":"event_msg","payload":{"type":"user_message","message":"the actual human prompt"}}'
  } > "$d/rollout-2026-09-11T00-00-00-$sid.jsonl"
}

@test "#33 round-1 P2-2: codex handoff drops injected context turns, keeps only the human user_message" {
  clikae init codex work2
  local work="$TEST_HOME/work-codex-injected"; mkdir -p "$work"
  _seed_codex_injected_transcript work2 "$work" "44444444-4444-4444-4444-444444444444"
  cd "$work"
  CODEX_HOME="$CLIKAE_HOME/profiles/codex/work2" run clikae handoff codex work2
  [ "$status" -eq 0 ]
  [[ "$output" == *"the actual human prompt"* ]] || false
  [[ "$output" != *"environment_context"* ]] || false
  [[ "$output" != *"user_instructions"* ]] || false
  [[ "$output" != *"AGENTS.md"* ]] || false
  [[ "$output" != *"cwd=/x"* ]] || false
}

_seed_grok_transcript() {
  local profile="$1" dir="$2" sid="$3"
  local d="$CLIKAE_HOME/profiles/grok/$profile/sessions/group1/$sid"
  mkdir -p "$d"
  printf '{"info":{"id":"%s","cwd":"%s"},"generated_title":"test"}\n' "$sid" "$dir" > "$d/summary.json"
  {
    echo '{"type":"user","content":[{"type":"text","text":"grok first real prompt"}]}'
    echo '{"type":"assistant","content":[{"type":"text","text":"grok working note"}]}'
    echo 'NOT VALID JSON AT ALL ][{ SHOULD-NOT-APPEAR'
    echo '{"type":"user","content":[{"type":"text","text":"grok second real prompt 測試繁體中文"}]}'
    echo '{"type":"assistant","content":[{"type":"text","text":"grok last assistant note"}]}'
  } > "$d/chat_history.jsonl"
}

@test "#33 handoff on grok extracts prompts+notes from the no-role/array-content shape (CJK survives, malformed line skipped)" {
  clikae init grok work
  local work="$TEST_HOME/work-grok"; mkdir -p "$work"
  _seed_grok_transcript work "$work" "22222222-2222-2222-2222-222222222222"
  cd "$work"
  # Same reasoning as the codex test above: `cat` as the summarizer surfaces
  # the assistant-notes section too (raw-extract only ever shows prompts).
  GROK_HOME="$CLIKAE_HOME/profiles/grok/work" \
    run clikae handoff grok work --summarizer cat
  [ "$status" -eq 0 ]
  [[ "$output" == *"grok first real prompt"* ]] || false
  [[ "$output" == *"grok second real prompt 測試繁體中文"* ]] || false
  [[ "$output" == *"grok working note"* ]] || false
  [[ "$output" == *"grok last assistant note"* ]] || false
  [[ "$output" != *"SHOULD-NOT-APPEAR"* ]] || false
  GROK_HOME="$CLIKAE_HOME/profiles/grok/work" run clikae handoff grok work
  [ "$status" -eq 0 ]
  [[ "$output" == *"grok second real prompt 測試繁體中文"* ]] || false
  [[ "$output" == *"raw extract"* ]] || false
}

_seed_grok_whitespace_transcript() {
  # Round-1 review P1-1: no real grok chat_history.jsonl was available to
  # confirm it writes spaced JSON (unlike codex's rollout, which is
  # "confirmed against a real rollout" — see codex.sh's own comment), but
  # tolerating a space after the colon costs nothing and keeps this the
  # SAME idiom as every other whitespace-tolerant scanner in the repo.
  local profile="$1" dir="$2" sid="$3"
  local d="$CLIKAE_HOME/profiles/grok/$profile/sessions/group1/$sid"
  mkdir -p "$d"
  printf '{"info": {"id": "%s", "cwd": "%s"}, "generated_title": "test"}\n' "$sid" "$dir" > "$d/summary.json"
  {
    echo '{"type": "user", "content": [{"type": "text", "text": "spaced grok prompt"}]}'
    echo '{"type": "assistant", "content": [{"type": "text", "text": "spaced grok note"}]}'
  } > "$d/chat_history.jsonl"
}

@test "#33 round-1 P1-1: grok handoff survives JSON whitespace (space after every colon)" {
  clikae init grok spacedwork
  local work="$TEST_HOME/work-grok-spaced"; mkdir -p "$work"
  _seed_grok_whitespace_transcript spacedwork "$work" "66666666-6666-6666-6666-666666666666"
  cd "$work"
  GROK_HOME="$CLIKAE_HOME/profiles/grok/spacedwork" \
    run clikae handoff grok spacedwork --summarizer cat
  [ "$status" -eq 0 ]
  [[ "$output" == *"spaced grok prompt"* ]] || false
  [[ "$output" == *"spaced grok note"* ]] || false
}

@test "#33 handoff on codex survives a 20 kB single-line transcript (no truncation crash/hang)" {
  clikae init codex work
  local work="$TEST_HOME/work-codex-20k"; mkdir -p "$work"
  local d="$CLIKAE_HOME/profiles/codex/work/sessions/2026/09/11"
  mkdir -p "$d"
  local sid="33333333-3333-3333-3333-333333333333"
  local pad; pad="$(head -c 20000 /dev/zero | tr '\0' 'x')"
  {
    echo '{"timestamp":"2026-09-11T00:00:00.000Z","type":"session_meta","payload":{"id":"'"$sid"'","cwd":"'"$work"'"}}'
    # user_message (round-1 P2-2 shape, not response_item) so this still
    # exercises the actual escape-scanning loop the "user" branch runs.
    echo '{"timestamp":"2026-09-11T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"START-MARKER-'"$pad"'-END-MARKER"}}'
  } > "$d/rollout-2026-09-11T00-00-00-$sid.jsonl"
  cd "$work"
  CODEX_HOME="$CLIKAE_HOME/profiles/codex/work" run clikae handoff codex work
  [ "$status" -eq 0 ]
}

@test "#33 an engine with no adapter_handoff_extract hook falls back to the claude-shaped extraction" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/handoff.sh"
  # No adapter loaded in this process at all -> adapter_handoff_extract is
  # undefined, exactly the third-party-adapter case.
  unset -f adapter_handoff_extract 2>/dev/null || true
  local t="$TEST_HOME/fallback.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"fallback claude-shaped prompt"},"timestamp":"2026-05-31T01:00:00.000Z"}' > "$t"
  run _handoff_recent_prompts "$t" 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"fallback claude-shaped prompt"* ]] || false
}

# --- #33 round-1 review P2-1 -------------------------------------------------
# The test this replaces compared `_handoff_default_extract` against
# `adapter_handoff_extract` — but BOTH were added by the #33 commit itself,
# so all it could prove is that two copies pasted into the same commit agree
# with EACH OTHER. It never touched the pre-#33 code, despite its name
# claiming "byte-identical to the pre-#33 inline extraction". A round-1
# review caught this (P2-1): if #33 had drifted claude's behaviour, both
# copies would have drifted together and this test would have stayed green.
#
# The fix: compare against a FROZEN artefact of the ACTUAL pre-#33 code
# (a real ref, not a second guess at what it did). Grepped the test suite
# first for a precedent of reading another git ref inside a bats test (none
# found — `tests/helpers.bash` gives every test its own throwaway $HOME, no
# git plumbing), so the golden output is captured to a fixture file instead,
# generated ONCE and frozen:
#
#   git show 4496a6d980dfb87ae97400f06126a3df4a0d3bae:lib/core/handoff.sh \
#     > /tmp/handoff-pre33.sh
#   # 4496a6d980dfb87ae97400f06126a3df4a0d3bae is `git merge-base` of this
#   # branch and origin/main — the exact commit #33 branched from.
#   HOME="$(mktemp -d)" CLIKAE_HOME="$(mktemp -d)" bash -c '
#     . /tmp/handoff-pre33.sh
#     _handoff_clean_tail /path/to/the/fixture/below.jsonl
#   ' > tests/fixtures/handoff-claude-golden.txt
#
# The fixture pinned above is a real, unmodified pre-#33 file — no
# reimplementation of what it "should" have done. If a future change to
# claude's shape is ever intentional, this test is meant to go red and the
# golden file regenerated by rerunning the recipe above against the NEW
# code, with the reason written into the commit that touches it.
@test "#33 claude's handoff digest matches a FROZEN pre-#33 golden fixture byte-for-byte" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/handoff.sh"
  source "$CLIKAE_LIB/adapters/claude.sh"
  local t="$TEST_HOME/golden-parity.jsonl"
  {
    echo '{"type":"user","message":{"role":"user","content":"first real prompt"},"timestamp":"2026-05-31T01:00:00.000Z"}'
    echo '{"type":"user","isMeta":true,"message":{"role":"user","content":"<command-name>/clear</command-name>"},"timestamp":"2026-05-31T01:00:01.000Z"}'
    echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working on it, quote: he said \"hi\""}]},"timestamp":"2026-05-31T01:00:02.000Z"}'
    echo '{"type":"user","toolUseResult":true,"message":{"role":"user","content":[{"type":"tool_result","content":"SHOULD NOT APPEAR file dump"}]},"timestamp":"2026-05-31T01:00:03.000Z"}'
    echo '{"type":"user","message":{"role":"user","content":"second real prompt with 中文 too"},"timestamp":"2026-05-31T01:05:00.000Z"}'
  } > "$t"
  # _handoff_clean_tail is the FULL digest pipeline (both roles, header lines
  # included) — the same function handoff_render feeds a summarizer, so this
  # exercises the real call path, not just the raw extractor.
  local actual golden
  actual="$(_handoff_clean_tail "$t")"
  golden="$(cat "$CLIKAE_TEST_ROOT/tests/fixtures/handoff-claude-golden.txt")"
  [ "$actual" = "$golden" ]
  [ -n "$actual" ]
}
