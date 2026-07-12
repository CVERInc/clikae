#!/usr/bin/env bats
# tests/bats/home.bats — bare `clikae` opens the home dashboard (tank board /
# welcome), the new default when no subcommand is given.

load '../helpers'

@test "bare clikae with no profiles shows the welcome + first step" {
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tanks yet"* ]] || false
  [[ "$output" == *"clikae init"* ]] || false
  [[ "$output" == *"14 engines"* ]] || false
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
}

@test "the active shell's tank drives the launch hint (no on-row 'here' marker)" {
  # The board intentionally does NOT badge the current shell's tank — with many
  # tanks open at once it's noise. But `active` is still computed under the hood:
  # it picks the default launch target shown at the bottom.
  clikae init claude work
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/work" run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"clikae claude work"* ]] || false   # the active tank is the launch suggestion
  [[ "$output" != *"here"* ]] || false                 # but not marked on its row
}

@test "the board sections off a solo (standalone) tank under 'Solo'" {
  clikae init claude work
  clikae init claude bot
  clikae solo claude bot
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Solo"* ]] || false        # the walled-off tank gets its own section
}

@test "a solo tank moves into its own 'Solo' section (not the fleet)" {
  clikae init claude work
  clikae init claude bot
  clikae solo claude bot
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Solo"* ]] || false
  # bot appears AFTER the Solo header, work appears under Tanks before it
  local solo_at work_at
  solo_at="$(printf '%s\n' "$output" | grep -n 'Solo' | head -1 | cut -d: -f1)"
  work_at="$(printf '%s\n' "$output" | grep -n '\bwork\b' | head -1 | cut -d: -f1)"
  [ -n "$solo_at" ] && [ -n "$work_at" ] && [ "$work_at" -lt "$solo_at" ] || false
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

@test "the board shows tank NAMES, not the shell alias (alias retired from board)" {
  clikae init claude work --alias            # default alias: claude-work
  clikae init claude solo
  clikae alias claude solo --name mysolo     # custom alias name
  run clikae
  [ "$status" -eq 0 ]
  # The name is the identity; the separate alias is no longer shown on the board.
  [[ "$output" == *"work"* ]] || false
  [[ "$output" == *"solo"* ]] || false
  [[ "$output" != *"claude-work"* ]] || false
  [[ "$output" != *"mysolo"* ]] || false
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

@test "a single-account target (agy) shows under Also available, not a floating group" {
  clikae init claude work
  _fake_bin agy
  PATH="$TEST_HOME/fakebin:$PATH" run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy"* ]] || false
  [[ "$output" == *"single-account"* ]] || false
  [[ "$output" == *"Also available"* ]] || false   # tucked in, not floating on its own
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
  [[ "$output" == *"agy"* ]] || false          # shown by its short name, not "antigravity"
  [[ "$output" != *"antigravity"* ]] || false
  [[ "$output" == *"work"* ]] || false
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
  [[ "$output" != *"over quota"* ]] || false   # clean log → not badged dry
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
  [[ "$output" == *"Resume"* ]] || false
  [[ "$output" == *"Resume me please"* ]] || false
  # The resume row uses the same columns as a tank row: name + engine, then title.
  local rrow; rrow="$(printf '%s\n' "$output" | grep 'Resume me please')"
  [[ "$rrow" == *"a"* ]] || false
  [[ "$rrow" == *"claude"* ]] || false
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

# --- M1c: the board is a flat BURN ORDER (no engine grouping) -------------------

@test "the board lists tanks in the order from the order file" {
  clikae init claude alpha
  clikae init claude beta
  printf 'claude/beta\nclaude/alpha\n' > "$CLIKAE_HOME/order"
  run clikae
  [ "$status" -eq 0 ]
  local lb la
  lb="$(printf '%s\n' "$output" | grep -n 'beta'  | head -1 | cut -d: -f1)"
  la="$(printf '%s\n' "$output" | grep -n 'alpha' | head -1 | cut -d: -f1)"
  [ -n "$lb" ] && [ -n "$la" ] && [ "$lb" -lt "$la" ]
}

@test "the board shows the engine name inline per row, not as a group header" {
  clikae init claude work
  clikae init codex main
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]] || false
  [[ "$output" == *"codex"* ]] || false
}

@test "_home_reorder moves a tank within the order file" {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/i18n.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  clikae init claude alpha
  clikae init claude beta
  # Default order is alpha, beta. Moving beta up -> beta first.
  _home_reorder claude beta -1
  [ "$(head -1 "$CLIKAE_HOME/order")" = "claude/beta" ]
}

@test "_home_wrap_prefixed wraps CJK by DISPLAY width (no overflow / col-0 wrap)" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  # 40 two-char CJK words ≈ 160 display cols; at the 80-col fallback it MUST wrap,
  # and (the bug) no line may exceed the terminal width.
  local s=""; local i
  for i in $(seq 1 40); do s="$s 字字"; done
  run _home_wrap_prefixed "$s" "  -> " 5 "" "" 0
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -ge 2 ]   # wrapped into multiple lines
  local line maxdw=0 dw cols
  cols="$( { stty size </dev/tty | awk '{print $2}'; } 2>/dev/null || true )"
  case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
  [ "$cols" -ge 30 ] || cols=80
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    dw="$(_dwidth "$line")"; [ "$dw" -gt "$maxdw" ] && maxdw="$dw"
  done < <(printf '%s\n' "$output")
  [ "$maxdw" -le "$cols" ]                                  # nothing overflows terminal columns
}

@test "agy tanks show the 'agy' name, not 'antigravity'" {
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/main"
  printf 'consented\n' > "$CLIKAE_HOME/antigravity-multi-consent"
  ln -s "$CLIKAE_HOME/profiles/antigravity/main" "$HOME/.gemini"
  clikae init claude work
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy"* ]] || false
  [[ "$output" != *"antigravity"* ]] || false
}

@test "a runaway Continue title is truncated with an ellipsis (no wrap)" {
  clikae init claude a
  local work="$TEST_HOME/tw"; mkdir -p "$work"
  local slug; slug="$(printf '%s' "$work" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  local d="$CLIKAE_HOME/profiles/claude/a/projects/$slug"; mkdir -p "$d"
  local long; long="$(printf 'X%.0s' $(seq 1 200))"
  printf '{"type":"ai-title","aiTitle":"%s","sessionId":"a"}\n' "$long" > "$d/aaa00000-0000-0000-0000-000000000000.jsonl"
  cd "$work"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"…"* ]] || false                  # truncated
  [[ "$output" != *"$long"* ]] || false              # not the full 200-char title
}

@test "the new-tank picker groups AI engines before tool CLIs (+ agy power)" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/i18n.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/adapter_loader.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  run _home_newtank_choices
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude  (AI)"* ]] || false
  [[ "$output" == *"codex  (AI)"* ]] || false
  [[ "$output" == *"aws  (tool)"* ]] || false
  [[ "$output" == *"agy  (AI"* ]] || false
  # AI listed before tools.
  local lc la
  lc="$(printf '%s\n' "$output" | grep -n 'claude  (AI)' | head -1 | cut -d: -f1)"
  la="$(printf '%s\n' "$output" | grep -n 'aws  (tool)'  | head -1 | cut -d: -f1)"
  [ -n "$lc" ] && [ -n "$la" ] && [ "$lc" -lt "$la" ]
}

# --- The status dot is a fuel gauge (docs/DESIGN-board-fuel-dots.md) ------------

@test "limit_engine_detectable: claude/agy yes, codex + tools no" {
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  limit_engine_detectable claude
  limit_engine_detectable antigravity
  ! limit_engine_detectable codex
  ! limit_engine_detectable gh
}

@test "_home_fuel_dot: detectable+clean = ●, un-detectable (codex) = ○ no-reading" {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  # claude, empty dry set → green ● (a real reading: ready)
  run _home_fuel_dot "" claude work
  [[ "$output" == *"●"* ]] || false
  # codex can't be read from disk → honest ○, never a guessed ●
  run _home_fuel_dot "" codex cheap
  [[ "$output" == *"○"* ]] || false
  [[ "$output" != *"●"* ]] || false
}

@test "_home_fuel_dot: a dry tank is ● with its verbatim reset phrase" {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  run _home_fuel_dot "$(printf 'claude\037work\037Resets in 2h')" claude work
  [[ "$output" == *"●"* ]] || false
  [[ "$output" == *"Resets in 2h"* ]] || false
}

@test "_home_fuel_dot: a cached weekly-% (BETA) lights ● with the verbatim phrase" {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  mkdir -p "$CLIKAE_HOME/cache/weekly"
  printf "used 85%% of your weekly limit\n" > "$CLIKAE_HOME/cache/weekly/claude-work"
  run _home_fuel_dot "" claude work
  [[ "$output" == *"●"* ]] || false
  [[ "$output" == *"85% of your weekly limit"* ]] || false
}

@test "limit_weekly_marker (BETA): captures the vendor weekly phrase, ignores noise" {
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  run limit_weekly_marker "You've used 85% of your weekly limit, resets Monday"
  [[ "$output" == *"85% of your weekly limit"* ]] || false
  # a stray percentage in normal output must NOT trip it
  run limit_weekly_marker "trimmed 10% of the context window to fit"
  [ -z "$output" ]
}

@test "board shows only burnable session tanks; tool-CLI tanks live in clikae tanks" {
  clikae init claude work
  clikae init gh personal        # gh is a tool CLI, not a session/fuel tank
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]] || false
  [[ "$output" == *"work"* ]] || false
  [[ "$output" == *"1 tank across 1 engine"* ]] || false   # only the claude tank counts on the board
  [[ "$output" != *"[gh]"* ]] || false                     # the gh tank is NOT shown on the board
  # …but it's still in the full inventory.
  run clikae tanks
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh"* ]] || false
  [[ "$output" == *"personal"* ]] || false
}

@test "board with only tool-CLI tanks renders gracefully (no crash on 0 fuel tanks)" {
  clikae init gh work        # a tool-CLI tank only — the board filters it out
  run clikae
  [ "$status" -eq 0 ]        # regression: grep -c . on 0 tank rows used to abort under set -eo pipefail
  [[ "$output" == *"0 tanks"* ]] || false
  [[ "$output" != *"[gh]"* ]] || false
}

# --- TUI width fixes (fix/tui-width) -----------------------------------------

@test "_home_row_budget: cols minus overhead, floored at min" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  [ "$(_home_row_budget 80 25)" = "55" ]           # plain subtraction
  [ "$(_home_row_budget 80 26 20)" = "54" ]
  [ "$(_home_row_budget 60 55 20)" = "20" ]        # would go negative -> floors at min
  [ "$(_home_row_budget 40 70)" = "12" ]           # default floor (12) when no min given
  [ "$(_home_row_budget garbage 10)" = "70" ]      # non-numeric cols -> the 80 fallback
}

@test "_home_cols with no controlling tty: honours \$COLUMNS, else falls back to 80" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  unset COLUMNS
  [ "$(_home_cols)" = "80" ]                 # nothing to go on -> the floor
  # The window is still THERE when output is piped; we just can't ask the tty.
  # $COLUMNS is what the shell knows, so `clikae clean --dry-run > f` in a
  # 60-column window must budget for 60, not 80.
  COLUMNS=60 ; [ "$(_home_cols)" = "60" ]
  COLUMNS=120; [ "$(_home_cols)" = "120" ]
  COLUMNS=12 ; [ "$(_home_cols)" = "80" ]    # implausibly narrow -> the floor
  COLUMNS=xx ; [ "$(_home_cols)" = "80" ]    # garbage -> the floor
}

# Regression (2026-07-13): _home_wrap_prefixed used to read `stty size` ITSELF
# instead of calling _home_cols, so $COLUMNS never reached it. With output piped
# in a 60-column window the ROWS (via _home_cols) correctly budgeted 60 while the
# PROSE around them still believed in 80 — and every heading between 61 and 79
# columns ran off the edge. One width source, or the two drift apart.
@test "_home_wrap_prefixed shares _home_cols' width source (honours \$COLUMNS)" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  # 68 columns of prose: fits in 80 (so a stale 80 would emit it on ONE line),
  # overflows 60 (so honouring $COLUMNS MUST split it).
  local s="Session data that can be cleaned up (biggest first in each section):"
  [ "$(_dwidth "$s")" -eq 68 ]
  COLUMNS=60 run _home_wrap_prefixed "$s" "" 0 "" ""
  [ "$status" -eq 0 ]
  local line n=0
  while IFS= read -r line; do
    n=$(( n + 1 ))
    [ "$(_dwidth "$line")" -le 60 ] || { echo ">60 cols: $line"; false; }
  done <<< "$output"
  [ "$n" -ge 2 ]                             # actually wrapped, not just "fits"
}

@test "_home_trunc_mid: fits unchanged; overflow gets a MIDDLE ellipsis biased to the tail" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  [ "$(_home_trunc_mid "/short/path" 40)" = "/short/path" ]   # already fits: untouched
  local long="/Users/someone/Developer/a-very-long-repo-name/lib/commands/resume.sh"
  local got; got="$(_home_trunc_mid "$long" 30)"
  [ "$(_dwidth "$got")" -le 30 ]                 # never exceeds the budget
  [[ "$got" == *…* ]] || false                   # actually elided
  [[ "$got" == /Users* ]] || false                # head is kept (starts like the original)
  [[ "$got" == *resume.sh ]] || false             # TAIL is kept (the leaf filename, not the head)
}

@test "engine-count classifier: the number is a placeholder INSIDE the string, so zh-TW/ko-KR attach it correctly and en-US keeps its space" {
  CLIKAE_LANG=zh-TW run clikae
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]個引擎 ]] || false          # attached, no space (correct zh typography)
  if [[ "$output" =~ [0-9]\ 個引擎 ]]; then echo "unwanted space before 個引擎: $output"; false; fi

  CLIKAE_LANG=ko-KR run clikae
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]개\ 엔진 ]] || false        # 개 attaches to the number, space before 엔진
  if [[ "$output" =~ [0-9]\ 개\ 엔진 ]]; then echo "unwanted space before 개: $output"; false; fi

  CLIKAE_LANG=en-US run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"14 engines"* ]] || false       # English keeps the space
}

@test "_home_help_row wraps a long es/de/fr/pt description without overflowing 80 cols" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  local loc
  for loc in es-ES de-DE fr-FR pt-BR; do
    ( source "$CLIKAE_TEST_ROOT/lib/i18n/$loc.sh"
      source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
      # T_K_SOLO/T_K_MEMORY are full sentences (82-92 cols) that used to be
      # printed on one unwrapped line via an absolute \033[24G column jump.
      out="$(_home_help_row "s" "$T_K_SOLO")"
      maxdw=0
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        # Line 1 embeds a literal `\033[24G` cursor jump — a REAL terminal
        # reads that as "go to column 24", not as printable characters, so
        # naive _dwidth (which has no notion of cursor motion) would
        # UNDER-count it. Model what the terminal actually does: everything
        # after the jump starts at column 24; continuation lines have no
        # escape (they're plain 24-space padding) and measure directly.
        case "$line" in
          *$'\033[24G'*)
            rem="${line#*$'\033[24G'}"
            dw=$(( 24 + $(_dwidth "$rem") )) ;;
          *) dw="$(_dwidth "$line")" ;;
        esac
        [ "$dw" -gt "$maxdw" ] && maxdw="$dw"
      done <<< "$out"
      [ "$maxdw" -le 80 ] || { echo "$loc T_K_SOLO overflowed: $maxdw cols"; exit 1; }
    ) || false
  done
}

@test "_home_chunk hard-breaks text a word-wrapper cannot: CJK (no interword spaces)" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  # A Japanese sentence is ONE "word" to a space-splitter — without a hard break
  # it can never wrap and runs off the edge (ja-JP's clean heading did exactly
  # that: 61 cols on a 60-col terminal).
  local ja="整理できるセッションデータ（各セクションでサイズの大きい順）:"
  local out chunk
  out="$(_home_chunk "$ja" 20)"
  [ -n "$out" ]
  for chunk in $out; do
    [ "$(_dwidth "$chunk")" -le 20 ] || { echo "chunk too wide: $chunk"; false; }
  done
  # No character is lost or duplicated by the split.
  local rejoined=""
  for chunk in $out; do rejoined="$rejoined$chunk"; done
  [ "$rejoined" = "$ja" ]
}

@test "_home_wrap_prefixed wraps a CJK sentence (no spaces) within the width" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  local ja="整理できるセッションデータ各セクションでサイズの大きい順に並びます一行に収まらない長い文章"
  run _home_wrap_prefixed "$ja" "" 0 "" ""
  [ "$status" -eq 0 ]
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(_dwidth "$line")" -le 80 ] || { echo ">80 cols: $line"; false; }
  done <<< "$output"
}

# --- display width: COLUMNS, not characters (the false-green regression) ------
# A width test whose data is all Latin cannot tell a column from a character —
# for Latin they are the same number. That is exactly how `_home_trunc` shipped
# cutting by CHARACTERS against budgets expressed in COLUMNS: a 40-char CJK
# title rendered 80 columns and blew an 80-col terminal apart on a real store,
# while an all-Latin fixture reported green. Every case below therefore carries
# wide characters.

@test "_dwidth measures DISPLAY COLUMNS (CJK=2, halfwidth kana=1, box glyphs=1)" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  [ "$(_dwidth "hello")" -eq 5 ]
  [ "$(_dwidth "規則：僅根據")" -eq 12 ]      # 6 ideographs = 12 columns
  [ "$(_dwidth "リファクタ")" -eq 10 ]
  [ "$(_dwidth "결제 조정")" -eq 9 ]          # hangul 2 + space 1
  [ "$(_dwidth "ｷﾘｶｴ")" -eq 4 ]              # HALFwidth katakana is 1 col, not 2
  [ "$(_dwidth "…")" -eq 1 ]                  # the ellipsis is ONE column
  [ "$(_dwidth "●○❯▲⏎")" -eq 5 ]              # the TUI's box glyphs are 1 col each
  [ "$(_dwidth "café")" -eq 4 ]               # accented Latin is 1 col (2 bytes)
  [ "$(_dwidth "Refactor 支払い x")" -eq 17 ] # mixed: 9 + 6 + 2
}

@test "_home_trunc cuts by COLUMNS, not characters — a CJK title honours its budget" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  # 40 ideographs = 80 columns. Cut to a 40-COLUMN budget it must render <= 40,
  # not 80 (the old char-based cut returned all 40 chars = 80 columns).
  local zh="規則：僅根據本訊息內文作答。不得讀取任何檔案、不得使用任何工具、不得引用你可能記得"
  local got; got="$(_home_trunc "$zh" 40)"
  [ "$(_dwidth "$got")" -le 40 ]
  [ "$(_dwidth "$got")" -ge 38 ]              # and it USES the budget (no over-cutting)
  [[ "$got" == *…* ]] || false
  # A budget the string already fits in leaves it untouched.
  [ "$(_home_trunc "短" 10)" = "短" ]
  # Latin still behaves.
  [ "$(_dwidth "$(_home_trunc "Refactor the payment pipeline" 12)")" -le 12 ]
  # Mixed CJK/Latin: the cut may land either side of the boundary, never over.
  local mixed="Refactor 支払い pipeline 重複課金 fix retried webhooks"
  local i
  for i in 8 13 20 27 33 41; do
    [ "$(_dwidth "$(_home_trunc "$mixed" $i)")" -le "$i" ] || { echo "budget $i overflowed"; false; }
  done
}

@test "_home_trunc never splits a fullwidth glyph in half" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  # An ODD budget against an all-wide string must round DOWN to a whole glyph,
  # never emit half a character (which would be mojibake, not a narrow cell).
  local zh="規則僅根據本訊息內文作答"
  local got i
  for i in 5 7 9 11; do
    got="$(_home_trunc "$zh" $i)"
    [ "$(_dwidth "$got")" -le "$i" ] || { echo "budget $i overflowed"; false; }
    # round-trips as valid UTF-8 (a split glyph would not)
    [ "$(printf '%s' "$got" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; echo $?)" -eq 0 ]
  done
}

@test "_home_trunc_mid cuts a CJK path by columns, keeping the tail" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  local p="/Users/x/Developer/專案目錄名稱很長/深層資料夾/lib/commands/resume.sh"
  local got; got="$(_home_trunc_mid "$p" 30)"
  [ "$(_dwidth "$got")" -le 30 ]
  [[ "$got" == /Users* ]] || false
  [[ "$got" == *resume.sh ]] || false
}
