#!/usr/bin/env bats
# tests/bats/dry-verdict-routes.bats — which vendor event makes a tank "over
# quota", one route per test.
#
# Two false reds reached the board from real fleet transcripts (2026-10-15):
#
#   · claude/wrasse — a PER-MODEL limit ("You've reached your Fable limit",
#     apiError model_requires_usage_credits, no reset phrase) was counted as
#     the whole tank running dry, because the reading awk took ANY synthetic
#     api-error line as a limit. The vendor's own usage API said window 0%,
#     weekly 79%, models:[Fable 100%] at the same moment: every other model
#     on that account still worked.
#   · codex/salmon — a usage limit whose reset had long passed, followed by a
#     "workspace is out of credits" event with no reset phrase at all, read
#     red for six days with nobody touching the tank.
#
# The fixture lines below copy the REAL line shapes (keys, nesting, wording),
# with absolute ISO timestamps. Bodies that identify anything (uuids, paths)
# are replaced; nothing structural is.

load '../helpers'

_boot() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/i18n.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/dry_store.sh"
  source "$CLIKAE_LIB/core/reading_cache.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/duration.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/home.sh"
  __C_YELLOW=YELLOW; __C_YELLOW_SOFT=SOFT; __C_DIM=DIM; __C_GREEN=GREEN; __C_RED=RED; __C_RESET=""
  # codex renders its reset in the machine's own zone; pin it.
  export TZ=UTC
}

_board_boot() {
  _boot
  source "$CLIKAE_LIB/core/board_state.sh"
}

# --- real line shapes ------------------------------------------------------

# claude/wrasse, 2026-10-15T05:29:42.866Z — a per-MODEL limit.
_wrasse_line() {
  cat <<'EOF'
{"parentUuid":"00000000-0000-0000-0000-000000000001","isSidechain":false,"userType":"external","cwd":"/work","sessionId":"00000000-0000-0000-0000-00000000000a","version":"2.1.0","gitBranch":"main","type":"assistant","uuid":"00000000-0000-0000-0000-000000000002","timestamp":"2026-10-15T05:29:42.866Z","message":{"id":"00000000-0000-0000-0000-000000000003","container":null,"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"text","text":"You've reached your Fable limit. Run /usage-credits to continue or switch models with /model."}]},"apiError":"model_requires_usage_credits","error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}
EOF
}

# A genuine claude SESSION limit in the same envelope (Route A). 2099 so the
# reset is always ahead of the test's real clock.
_session_limit_line() {
  cat <<'EOF'
{"parentUuid":"00000000-0000-0000-0000-000000000001","isSidechain":false,"type":"assistant","uuid":"00000000-0000-0000-0000-000000000004","timestamp":"2099-01-01T00:00:00.000Z","message":{"id":"00000000-0000-0000-0000-000000000005","container":null,"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","content":[{"type":"text","text":"You've hit your session limit · resets 11pm (Asia/Tokyo)"}]},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}
EOF
}

# Synthetic api errors that are NOT a limit (Route C): overloaded, network.
_overloaded_line() {
  cat <<'EOF'
{"parentUuid":"00000000-0000-0000-0000-000000000001","isSidechain":false,"type":"assistant","uuid":"00000000-0000-0000-0000-000000000006","timestamp":"2026-10-15T05:29:42.866Z","message":{"id":"00000000-0000-0000-0000-000000000007","container":null,"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","content":[{"type":"text","text":"API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"}]},"error":"unknown","isApiErrorMessage":true,"apiErrorStatus":529}
EOF
}
_network_line() {
  cat <<'EOF'
{"parentUuid":"00000000-0000-0000-0000-000000000001","isSidechain":false,"type":"assistant","uuid":"00000000-0000-0000-0000-000000000008","timestamp":"2026-10-15T05:30:10.000Z","message":{"id":"00000000-0000-0000-0000-000000000009","container":null,"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","content":[{"type":"text","text":"API Error: Connection error."}]},"error":"unknown","isApiErrorMessage":true}
EOF
}

# codex/salmon, 2026-10-09T10:45:39Z — a usage limit whose reset is long past.
_salmon_limit_line() {
  cat <<'EOF'
{"timestamp":"2026-10-09T10:45:39.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"0","last_agent_message":null,"error":{"message":"You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 1:41 PM.","codex_error_info":"usage_limit_exceeded"}}}
EOF
}
# codex/salmon, 2026-10-09T11:18:49Z — the workspace is out of credits.
_salmon_credits_line() {
  cat <<'EOF'
{"timestamp":"2026-10-09T11:18:49.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"1","last_agent_message":null,"error":{"message":"{\"error\":{\"message\":\"Your workspace is out of credits. Add credits to continue.\",\"codex_error_info\":\"usage_limit_exceeded\"}}","codex_error_info":"usage_limit_exceeded"}}}
EOF
}

# --- tanks -----------------------------------------------------------------

# _claude_tank <tank> <line-fn>... -> one transcript in the 5h scan window.
_claude_tank() {
  local tank="$1" fn d; shift
  clikae init claude "$tank" >/dev/null 2>&1
  d="$CLIKAE_HOME/profiles/claude/$tank/projects/proj"
  mkdir -p "$d"
  : > "$d/s.jsonl"
  for fn in "$@"; do "$fn" >> "$d/s.jsonl"; done
  touch "$d/s.jsonl"
}

# _codex_tank <tank> <line-fn>... -> one rollout in the 7-day scan window.
_codex_tank() {
  local tank="$1" fn d; shift
  clikae init codex "$tank" >/dev/null 2>&1
  d="$CLIKAE_HOME/profiles/codex/$tank/sessions/2026/10/09"
  mkdir -p "$d"
  printf '{"timestamp":"2026-10-09T10:40:00.000Z","type":"session_meta","payload":{"id":"s","cwd":"/work","originator":"codex_cli_rs"}}\n' > "$d/rollout-s.jsonl"
  for fn in "$@"; do "$fn" >> "$d/rollout-s.jsonl"; done
  touch "$d/rollout-s.jsonl"
}

# The vendor usage reading taken at the wrasse moment: window 0, weekly 79,
# Fable at 100%.
_wrasse_usage() {
  local now; now="$(date +%s)"
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"window_pct":0,"weekly_pct":79,"window_resets_at":"2099-01-01T00:00:00Z","weekly_resets_at":"2099-01-07T00:00:00Z","source":"vendor","models":[{"name":"Fable","pct":100,"resets_at":"2099-01-07T00:00:00Z"}],"cached_at":%s,"scanned_at":%s}\n' \
    "$now" "$now" > "$CLIKAE_HOME/state/usage/claude/$1.json"
}

# --- Route A: a real session/weekly limit still dries the tank -------------

@test "route A: a claude session limit with a reset phrase is dry until the reset (regression)" {
  _boot
  _claude_tank wrasse _session_limit_line
  run limit_tank_dry claude wrasse
  [ "$status" -eq 0 ]
  [ "$output" = "resets 11pm (Asia/Tokyo)" ] || { echo "got: $output"; false; }
  run limit_tank_model_dry claude wrasse
  [ "$status" -ne 0 ]
  run limit_dry_set <<< "claude	wrasse	x"
  [[ "$output" == "claude"$'\037'"wrasse"$'\037'"resets 11pm (Asia/Tokyo)" ]] || false
}

# --- Route B: a per-model limit is a model fact, not a dry tank ------------

@test "route B: the wrasse per-model limit leaves the tank usable and names the model" {
  _boot
  _claude_tank wrasse _wrasse_line
  run limit_tank_dry claude wrasse
  [ "$status" -ne 0 ] || { echo "tank read dry: $output"; false; }
  run limit_tank_model_dry claude wrasse
  [ "$status" -eq 0 ]
  [ "$output" = "Fable" ] || { echo "model: $output"; false; }
  # The selector's form (no flag) lists dry tanks only: wrasse is not one.
  run limit_dry_set <<< "claude	wrasse	x"
  [ -z "$output" ] || { echo "dry set: $output"; false; }
  # Control: the old shape — a SESSION limit in the same file, newer than the
  # model one — still dries it.
  _session_limit_line >> "$CLIKAE_HOME/profiles/claude/wrasse/projects/proj/s.jsonl"
  run limit_tank_dry claude wrasse
  [ "$status" -eq 0 ]
}

@test "route B: the board row reads 'Fable dry · weekly 79%' on a non-red dot" {
  _boot
  _claude_tank wrasse _wrasse_line
  _wrasse_usage wrasse
  local dry; dry="$(limit_dry_set --include-unverified <<< "claude	wrasse	x")"
  _home_fuel_memo_reset
  _home_fuel_dotv "$dry" claude wrasse
  [[ "$_FNOTE" == "Fable dry · "* ]] || { echo "note: $_FNOTE"; false; }
  [[ "$_FNOTE" == *"weekly 79%"* ]] || { echo "note: $_FNOTE"; false; }
  [[ "$_FDOT" != RED* ]] || { echo "dot: $_FDOT"; false; }
  ! _home_is_dryv "$dry" claude wrasse || false
}

@test "route B: carry-onward (next_tank) does not skip a tank whose only limit is per-model" {
  _boot
  _claude_tank aa _session_limit_line
  _claude_tank wrasse _wrasse_line
  run next_tank claude aa
  [ "$output" = "claude	wrasse" ] || { echo "next: $output"; false; }
}

# --- Route C: other synthetic api errors are not a limit --------------------

@test "route C: an overloaded (529) or network synthetic error does not dry the tank" {
  _boot
  _claude_tank tuna _overloaded_line _network_line
  run limit_tank_dry claude tuna
  [ "$status" -ne 0 ] || { echo "tank read dry: $output"; false; }
  run limit_tank_model_dry claude tuna
  [ "$status" -ne 0 ]
  run limit_dry_set --include-unverified <<< "claude	tuna	x"
  [ -z "$output" ] || { echo "dry set: $output"; false; }
}

# --- Route D: a codex limit with a future reset is dry ----------------------

@test "route D: a codex usage limit with a future 'try again at' is dry (regression)" {
  _boot
  _future_line() {
    _salmon_limit_line | sed 's/try again at 1:41 PM/try again at Dec 1st, 2099 1:41 PM/'
  }
  _codex_tank salmon _future_line
  run limit_tank_dry codex salmon
  [ "$status" -eq 0 ]
  [ "$output" = "try again at Dec 1st, 2099 1:41 PM" ] || { echo "got: $output"; false; }
}

# --- Route E: a codex limit never stays red past its own reset --------------

@test "route E: a codex limit whose 'try again at' has passed is not dry, only unverified" {
  _boot
  _codex_tank salmon _salmon_limit_line
  run limit_tank_dry codex salmon
  [ "$status" -ne 0 ] || { echo "tank read dry: $output"; false; }
  run limit_dry_set --include-unverified <<< "codex	salmon	x"
  [ "$output" = "codex"$'\037'"salmon"$'\037'"$LIMIT_RESET_UNVERIFIED" ] || { echo "set: $output"; false; }
}

@test "route E: a codex limit with NO reset phrase, older than the 5h window, is not dry" {
  _boot
  _nophrase_line() {
    _salmon_limit_line | sed 's/ Upgrade to Pro.*1:41 PM\.//'
  }
  _codex_tank salmon _nophrase_line
  grep -q 'usage limit.","codex_error_info' "$CLIKAE_HOME/profiles/codex/salmon/sessions/2026/10/09/rollout-s.jsonl"
  run limit_tank_dry codex salmon
  [ "$status" -ne 0 ] || { echo "tank read dry: $output"; false; }
  run limit_dry_set --include-unverified <<< "codex	salmon	x"
  [ "$output" = "codex"$'\037'"salmon"$'\037'"$LIMIT_RESET_UNVERIFIED" ] || { echo "set: $output"; false; }
}

@test "route E: salmon as recorded (limit, then out-of-credits, six days idle) self-heals" {
  _boot
  _codex_tank salmon _salmon_limit_line _salmon_credits_line
  run limit_tank_dry codex salmon
  [ "$status" -ne 0 ] || { echo "tank read dry: $output"; false; }
  run limit_dry_set <<< "codex	salmon	x"
  [ -z "$output" ] || { echo "selector set: $output"; false; }
}

# --- Route F: out of credits is its own state, not "over quota" -------------

@test "route F: 'workspace is out of credits' is the credits state, labelled apart from quota" {
  _boot
  _fresh_credits_line() { _salmon_credits_line | sed 's/2026-10-09T11:18:49/2099-01-01T00:00:00/'; }
  _codex_tank salmon _fresh_credits_line
  run limit_profile_dry codex "$CLIKAE_HOME/profiles/codex/salmon"
  [ "$status" -eq 0 ]
  [ "$output" = "$LIMIT_STATE_CREDITS" ] || { echo "got: $output"; false; }
  local dry; dry="$(limit_dry_set --include-unverified <<< "codex	salmon	x")"
  i18n_load en-US
  _home_fuel_memo_reset
  _home_fuel_dotv "$dry" codex salmon
  [ "$_FNOTE" = "$T_FUEL_CREDITS" ] || { echo "note: $_FNOTE"; false; }
  [[ "$_FNOTE" != *"over quota"* ]] || false
  i18n_load zh-TW
  _home_fuel_memo_reset
  _home_fuel_dotv "$dry" codex salmon
  [ "$_FNOTE" = "$T_FUEL_CREDITS" ] || false
  [ "$_FNOTE" != "workspace out of credits" ] || { echo "zh-TW not translated: $_FNOTE"; false; }
  # Control: a plain usage-limit event (no credits wording) is still the
  # quota shape — it carries its own reset phrase, not the credits state.
  _codex_tank cod _salmon_limit_line
  run limit_profile_dry codex "$CLIKAE_HOME/profiles/codex/cod"
  [ "$status" -eq 0 ]
  [ "$output" = "try again at 1:41 PM" ] || { echo "control: $output"; false; }
}

@test "route F: every locale file defines T_FUEL_CREDITS" {
  local f
  for f in "$CLIKAE_TEST_ROOT"/lib/i18n/*.sh; do
    grep -q '^T_FUEL_CREDITS=' "$f" || { echo "missing in $f"; false; }
  done
}

# --- Route G: the board cache path agrees -----------------------------------

@test "route G: the board-cache path reads the wrasse model limit as model-dry, not dry" {
  _board_boot
  _claude_tank wrasse _wrasse_line
  local dir="$CLIKAE_HOME/profiles/claude/wrasse"
  rm -rf "$CLIKAE_HOME/state/board" "$CLIKAE_HOME/state/readings"
  _board_gen_cache_clear
  board_state_refresh claude "$dir"
  local _CLIKAE_BOARD=1
  run limit_profile_dry claude "$dir"
  [ "$status" -eq 3 ] || { echo "rc=$status out=$output"; false; }
  [ "$output" = "Fable" ] || false
  # Control: the old shape through the same cache is still dry.
  _session_limit_line >> "$dir/projects/proj/s.jsonl"
  _board_gen_cache_clear
  board_state_refresh claude "$dir"
  run limit_profile_dry claude "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "resets 11pm (Asia/Tokyo)" ] || { echo "got: $output"; false; }
}

@test "route G: the board-cache path lets salmon self-heal too" {
  _board_boot
  _codex_tank salmon _salmon_limit_line _salmon_credits_line
  local dir="$CLIKAE_HOME/profiles/codex/salmon"
  rm -rf "$CLIKAE_HOME/state/board" "$CLIKAE_HOME/state/readings"
  _board_gen_cache_clear
  board_state_refresh codex "$dir"
  local _CLIKAE_BOARD=1
  run limit_tank_dry codex salmon
  [ "$status" -ne 0 ] || { echo "tank read dry: $output"; false; }
}

@test "route G: a per-file reading cached by the OLD parser is not trusted" {
  _boot
  _claude_tank wrasse _wrasse_line
  local f="$CLIKAE_HOME/profiles/claude/wrasse/projects/proj/s.jsonl" key id root
  # Plant what the previous parser cached for this exact file: the model
  # limit's stamp in the TANK-limit slot.
  key="$f:$(_reading_cache_keyv "$f")"
  id="$(printf '%s' "claude-usage:$f" | cksum)"; id="${id%% *}"
  root="$CLIKAE_HOME/state/readings"; mkdir -p "$root"
  printf '%s\n0\n%s' "$key" "2026-10-15T05:29:42.866Z"$'\037\037' > "$root/claude-usage-$id"
  run limit_tank_dry claude wrasse
  [ "$status" -ne 0 ] || { echo "stale cache read dry: $output"; false; }
}
