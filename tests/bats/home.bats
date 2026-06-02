#!/usr/bin/env bats
# tests/bats/home.bats — bare `clikae` opens the home dashboard (tank board /
# welcome), the new default when no subcommand is given.

load '../helpers'

@test "bare clikae with no profiles shows the welcome + first step" {
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tanks yet"* ]] || false
  [[ "$output" == *"clikae init"* ]] || false
  [[ "$output" == *"13 engines"* ]] || false
}

@test "bare clikae with profiles shows the tank board grouped by CLI" {
  clikae init claude work
  clikae init claude personal
  clikae init codex cheap
  run clikae
  [ "$status" -eq 0 ]
  # Header summary: 3 tanks across 2 engines.
  [[ "$output" == *"3 tanks across 2 engines"* ]] || false
  [[ "$output" == *"claude"* ]] || false
  [[ "$output" == *"work"* ]] || false
  [[ "$output" == *"personal"* ]] || false
  [[ "$output" == *"codex"* ]] || false
  # No tank is active in this clean shell — nothing marked "active here".
  [[ "$output" != *"active here"* ]] || false
}

@test "the tank active in THIS shell is marked" {
  clikae init claude work
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/work" run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"active here"* ]] || false
}

@test "dashboard is reachable by name and via --help" {
  run clikae dashboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tanks yet"* ]] || false

  run clikae home --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"home dashboard"* ]] || false
}

# A fake executable on PATH, so "installed?" checks are deterministic in CI.
_fake_bin() {
  mkdir -p "$TEST_HOME/fakebin"
  printf '#!/bin/sh\n:\n' > "$TEST_HOME/fakebin/$1"
  chmod +x "$TEST_HOME/fakebin/$1"
}

@test "the board shows the real alias name (default and custom)" {
  clikae init claude work --alias            # default alias: claude-work
  clikae init claude solo
  clikae alias claude solo --name mysolo     # custom alias name
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-work"* ]] || false
  [[ "$output" == *"mysolo"* ]] || false
}

@test "Also available lists a relay-capable CLI with no tank (codex)" {
  clikae init claude work                    # a tank, so we get the board
  _fake_bin codex                            # codex installed, no profile
  PATH="$TEST_HOME/fakebin:$PATH" run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Also available"* ]] || false
  [[ "$output" == *"codex"* ]] || false
  [[ "$output" == *"opens default"* ]] || false
}

@test "Also available excludes non-agent tools (gh) even if installed" {
  clikae init claude work
  _fake_bin gh                               # gh installed, no profile, NOT an agent
  PATH="$TEST_HOME/fakebin:$PATH" run clikae
  [ "$status" -eq 0 ]
  # gh is a tool, not a session tank — it must not be offered as launchable.
  [[ "$output" != *"gh"* ]] || false
}

@test "a single-account target on PATH shows as its own group (agy)" {
  clikae init claude work
  _fake_bin agy
  PATH="$TEST_HOME/fakebin:$PATH" run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy"* ]] || false
  [[ "$output" == *"single-account"* ]] || false
  [[ "$output" == *"◈"* ]]                 # rendered as a launch target, not a tank
}

@test "the launch hint emits real colour escapes, not a literal backslash-033" {
  # Regression: colour codes are stored as the literal string '\033[2m' and only
  # printf %b interprets them — embedding one in a %s string leaks it as text.
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/i18n.sh"   # T_* strings the renderer reads
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  __C_DIM='\033[2m'; __C_RESET='\033[0m'; __C_BOLD='\033[1m'; __C_GREEN='\033[0;32m'
  local items; items="$(printf 'tank\037claude\037work\037me@x\037claude-work\0371\037\n')"
  run _home_render_static "$items"
  [ "$status" -eq 0 ]
  [[ "$output" == *"launch"* ]] || false
  [[ "$output" != *'\033'* ]]      # no literal escape leaked into the output
}

@test "antigravity slots render as tanks with the active one marked (multi mode)" {
  # Simulate the opt-in multi-account state: slots + consent + the ~/.gemini link.
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/default" "$CLIKAE_HOME/profiles/antigravity/work"
  : > "$CLIKAE_HOME/antigravity-multi-consent"
  ln -s "$CLIKAE_HOME/profiles/antigravity/work" "$HOME/.gemini"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"antigravity"* ]] || false
  [[ "$output" == *"work"* ]] || false
  [[ "$output" == *"active here"* ]]          # work is where the symlink points
}

# --- L4: over-quota (dry) tank awareness on the board ---------------------------

# Seed a transcript line under a profile's project dir.
_seed_tx() { # <profile> <jsonl-line>
  local p="$CLIKAE_HOME/profiles/claude/$1/projects/-Users-x"
  mkdir -p "$p"
  printf '%s\n' "$2" >> "$p/s.jsonl"
}

@test "the board badges an over-quota tank with ! and its reset time" {
  clikae init claude dry
  clikae init claude ok
  _seed_tx dry '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit, resets 11pm (Asia/Tokyo)"}]},"timestamp":"2026-06-01T10:05:00Z"}'
  _seed_tx ok  '{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"done"}]},"timestamp":"2026-06-01T10:00:00Z"}'
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"!"* ]] || false
  [[ "$output" == *"resets 11pm (Asia/Tokyo)"* ]] || false
  [[ "$output" == *"over quota"* ]] || false
}

@test "a tank whose limit was superseded by a later success is NOT badged (self-clear)" {
  clikae init claude back
  _seed_tx back '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit, resets 11pm"}]},"timestamp":"2026-06-01T10:05:00Z"}'
  _seed_tx back '{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"back to work"}]},"timestamp":"2026-06-01T10:10:00Z"}'
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" != *"over quota"* ]] || false
  [[ "$output" != *"over quota"* ]] || false
}

@test "a tank that only DISCUSSES a limit is NOT badged (dogfood regression)" {
  clikae init claude chatty
  _seed_tx chatty '{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"lets talk about what hit your session limit means"}]},"timestamp":"2026-06-01T10:00:00Z"}'
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" != *"over quota"* ]] || false
}

@test "the board badges the NEW session-limit shape (middot + apiErrorStatus:429)" {
  # The exact shape Claude Code writes for a session limit (dogfooded 2026-06-02,
  # the real burn that prompted this): type=assistant, model=<synthetic>,
  # isApiErrorMessage:true, apiErrorStatus:429, error:rate_limit, and a
  # "·"-separated reset phrase. Locks the new wording/structure in forever.
  clikae init claude dry
  _seed_tx dry '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · resets 6:50pm (Asia/Tokyo)"}],"stop_reason":"stop_sequence"},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"timestamp":"2026-06-02T09:44:49.962Z"}'
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"resets 6:50pm (Asia/Tokyo)"* ]] || false
  [[ "$output" == *"over quota"* ]] || false
}

@test "limit detection tolerates spaced JSON (future pretty-print)" {
  # Defensive: if a future Claude Code pretty-prints its JSONL (space after each
  # colon), the structural greps must still match.
  clikae init claude dry
  _seed_tx dry '{"type": "assistant", "message": {"model": "<synthetic>", "content": [{"type": "text", "text": "You have hit your session limit · resets 6:50pm (Asia/Tokyo)"}]}, "isApiErrorMessage": true, "apiErrorStatus": 429, "timestamp": "2026-06-02T09:44:49.962Z"}'
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"resets 6:50pm (Asia/Tokyo)"* ]] || false
  [[ "$output" == *"over quota"* ]] || false
}

# Seed agy's limit log (cli.log) under the test HOME — agy records its quota
# event ONLY here, never a transcript (confirmed marker; see limit_log_dry).
_agy_log() { # <line>
  mkdir -p "$TEST_HOME/.gemini/antigravity-cli"
  printf '%s\n' "$1" > "$TEST_HOME/.gemini/antigravity-cli/cli.log"
}

@test "the board badges a log-only target (agy) with ! + reset when its quota log is dry" {
  clikae init claude work                     # a tank, so the board renders
  _fake_bin agy                               # agy installed → shown as a target
  _agy_log "E0531 log.go:398] RESOURCE_EXHAUSTED (code 429): Individual quota reached. Contact your administrator to enable overages. Resets in 3h32m48s."
  PATH="$TEST_HOME/fakebin:$PATH" run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy"* ]] || false
  [[ "$output" == *"!"* ]] || false
  [[ "$output" == *"Resets in 3h32m48s"* ]]   # the vendor's verbatim reset phrase
}

@test "a log-only target (agy) with a clean quota log is NOT badged" {
  clikae init claude work
  _fake_bin agy
  _agy_log "I0531 log.go:1] starting conversation update stream — all normal"
  PATH="$TEST_HOME/fakebin:$PATH" run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy"* ]] || false
  [[ "$output" != *"over quota"* ]] || false
  [[ "$output" == *"◈"* ]]                     # plain launch glyph, not a warning
}

@test "bare clikae changes nothing on disk (read-only)" {
  clikae init claude work
  before="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  run clikae
  [ "$status" -eq 0 ]
  after="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  [ "$before" = "$after" ]
}

@test "an unknown subcommand still falls back to help" {
  run clikae definitely-not-a-command
  [[ "$output" == *"Unknown command"* ]] || false
  [[ "$output" == *"switch <engine> to <tank>"* ]] || false
}

@test "the board shows a continue headline for this dir's most recent session" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local slug; slug="$(printf '%s' "$work" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  local d="$CLIKAE_HOME/profiles/claude/a/projects/$slug"; mkdir -p "$d"
  {
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"raw first prompt"}]}}\n'
    printf '{"type":"ai-title","aiTitle":"Resume me please","sessionId":"dead0000-0000-0000-0000-000000000000"}\n'
  } > "$d/dead0000-0000-0000-0000-000000000000.jsonl"
  cd "$work"
  run clikae
  [ "$status" -eq 0 ]
  # Headline present (en-US per the pinned test locale), titled by Claude's
  # ai-title, naming the engine/tank to resume.
  [[ "$output" == *"Continue"* ]] || false
  [[ "$output" == *"Resume me please"* ]] || false
  [[ "$output" == *"claude/a"* ]] || false
}

@test "the board shows NO continue headline in a dir with no session" {
  clikae init claude a
  local empty="$TEST_HOME/empty"; mkdir -p "$empty"
  cd "$empty"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" != *"Continue"* ]] || false
}

@test "the continue list shows multiple recent sessions, newest first" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local slug; slug="$(printf '%s' "$work" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  local d="$CLIKAE_HOME/profiles/claude/a/projects/$slug"; mkdir -p "$d"
  printf '{"type":"ai-title","aiTitle":"Older session","sessionId":"a"}\n' > "$d/aaa00000-0000-0000-0000-000000000000.jsonl"
  sleep 1
  printf '{"type":"ai-title","aiTitle":"Newer session","sessionId":"b"}\n' > "$d/bbb00000-0000-0000-0000-000000000000.jsonl"
  cd "$work"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Newer session"* ]] || false
  [[ "$output" == *"Older session"* ]] || false
  # newest first: "Newer" appears before "Older"
  [[ "$output" == *"Newer session"*"Older session"* ]] || false
}

@test "a session's recap is shown under its continue row, hint stripped" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local slug; slug="$(printf '%s' "$work" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  local d="$CLIKAE_HOME/profiles/claude/a/projects/$slug"; mkdir -p "$d"
  {
    printf '{"type":"ai-title","aiTitle":"Has a recap","sessionId":"c"}\n'
    printf '{"type":"system","subtype":"away_summary","content":"Fixed the parser; next add tests. (disable recaps in /config)"}\n'
  } > "$d/ccc00000-0000-0000-0000-000000000000.jsonl"
  cd "$work"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Has a recap"* ]] || false
  [[ "$output" == *"Fixed the parser; next add tests."* ]] || false
  [[ "$output" != *"disable recaps"* ]] || false
}
