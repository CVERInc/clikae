#!/usr/bin/env bats
# tests/bats/usage-agy.bats — #151: `clikae usage agy <tank>` reads agy's own
# `v1internal:retrieveUserQuotaSummary` with the tank's saved access token, and
# splits the buckets into window/weekly by their own reset distance. No usable
# token, or any refusal, falls back to today's no-signal row. The token never
# reaches output, argv, the environment or the cache.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'
bats_require_minimum_version 1.5.0   # for `run --separate-stderr`

# _iso <seconds from now> -> an RFC 3339 instant (jq, so no GNU/BSD date split).
_iso() { jq -nr --argjson d "$1" '(now + $d) | floor | todate'; }

agy_fixture() {
  local d="$CLIKAE_HOME/profiles/antigravity/pike"
  # agy on PATH is what makes antigravity a listed engine at all.
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.testbin/agy"
  chmod +x "$TEST_HOME/.testbin/agy"
  mkdir -p "$d/antigravity-cli"
  printf 'antigravity\n' > "$d/.clikae-tank"
  jq -n --arg exp "${1:-$(_iso 1800)}" \
    '{token:{access_token:"stub-agy-secret151",token_type:"Bearer",refresh_token:"stub-agy-refresh151",expiry:$exp},auth_method:"oauth"}' \
    > "$d/antigravity-cli/antigravity-oauth-token"
  export AGY_CALLS="$TEST_HOME/agy-calls" AGY_LOG="$TEST_HOME/agy-curl.log"
  export AGY_WIN_RESET AGY_WK_RESET AGY_3P_RESET
  AGY_WIN_RESET="$(_iso 9000)"; AGY_WK_RESET="$(_iso 500000)"; AGY_3P_RESET="$(_iso 72000)"
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
config="$(cat)"
printf '%s\n' "$@" >> "$AGY_LOG"
env >> "$AGY_LOG"
# Record EVERY call before judging it: a call made without the token must
# still show up in AGY_CALLS, or "makes no call" could never go red.
url=""; for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
printf '%s\n' "${url##*:}" >> "$AGY_CALLS"
[[ "$config" == *'Authorization: Bearer stub-agy-secret151'* ]] || exit 2
# Measured on the real endpoint: a User-Agent that is not agy's gets 403, and
# loadCodeAssist names no project unless the caller says it is ANTIGRAVITY.
[[ "$config" == *'User-Agent: antigravity'* ]] || exit 22
[ "${AGY_FAIL:-0}" = 0 ] || exit 22
case "$url" in
  *:loadCodeAssist)
    case "$*" in
      *'"ideType":"ANTIGRAVITY"'*) printf '{"cloudaicompanionProject":"stub-project-1","currentTier":{"id":"free-tier"}}' ;;
      *) printf '{"allowedTiers":[{"id":"standard-tier"}],"ineligibleTiers":[{"tierId":"free-tier","reasonCode":"UNSUPPORTED_CLIENT"}]}' ;;
    esac ;;
  *:retrieveUserQuotaSummary)
    case "$*" in *'"project":"stub-project-1"'*) ;; *) exit 22 ;; esac
    # The real body's shape (2026-09-27), values made up: Gemini's weekly is
    # 99% spent, Claude/GPT's is untouched. 3p-weekly names its window in hours
    # ("168h") and resets in 20 h: the hours, not the distance, make it weekly.
    printf '{"groups":[
      {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
        {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.01,"resetTime":"%s"},
        {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1,"resetTime":"%s"}]},
      {"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus","buckets":[
        {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"168h","remainingFraction":1,"resetTime":"%s"},
        {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","disabled":true,"remainingFraction":1,"resetTime":"%s"}]}]}' \
      "$AGY_WK_RESET" "$AGY_WIN_RESET" "$AGY_3P_RESET" "$AGY_WIN_RESET" ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
}

@test "agy usage: each quota group keeps its own numbers; the headline is Gemini by default" {
  agy_fixture
  run clikae usage agy pike --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_HOME/out.log"
  echo "$output" | jq -e --arg k "$AGY_WK_RESET" --arg c "$AGY_3P_RESET" '
    .engine == "antigravity" and .source == "quota-api" and (has("gap") | not)
    and .headline_group == "gemini"
    and .window_pct == 0 and .weekly_pct == 99 and .weekly_resets_at == $k
    and ([.groups[] | {name, window_pct, weekly_pct, disabled}] ==
         [{name:"claude",window_pct:null,weekly_pct:0,disabled:false},
          {name:"gemini",window_pct:0,weekly_pct:99,disabled:false}])
    and (.groups[] | select(.name == "claude") | .weekly_resets_at) == $c'
  # the project loadCodeAssist named is the one the quota call asked about
  grep -q 'stub-project-1' "$AGY_LOG"
  [ "$(tr '\n' ' ' < "$AGY_CALLS")" = "loadCodeAssist retrieveUserQuotaSummary " ] || false
  # same TTL as claude: a second read inside it is a cache hit, no call
  run clikae usage agy pike --json
  [ "$(wc -l < "$AGY_CALLS" | tr -d ' ')" = 2 ] || false
  ! grep -R 'stub-agy-secret151' "$AGY_LOG" "$TEST_HOME/out.log" "$CLIKAE_HOME/state"
}

@test "agy usage: a Claude model hint makes the Claude/GPT group the headline" {
  agy_fixture
  CLIKAE_AGY_USAGE_MODEL=claude-sonnet-4-6 run clikae usage agy pike --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.headline_group == "claude" and .weekly_pct == 0 and .window_pct == null'
}

@test "agy usage: the text form names both groups, headline first" {
  agy_fixture
  run --separate-stderr clikae usage agy pike
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2154  # set by bats' run --separate-stderr
  [[ "$stderr" == *'gemini 0/99% · claude -/0%'* ]] || false
}

@test "agy usage: an access token past its own expiry is never sent; the row stays no-signal" {
  agy_fixture "$(_iso -60)"
  run clikae usage agy pike --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown" and .gap == "no-signal" and .window_pct == null'
  [ ! -e "$AGY_CALLS" ] || false
}

@test "agy usage: a refused call falls back to no-signal and caches no error body" {
  agy_fixture
  export AGY_FAIL=1
  run clikae usage agy pike --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown" and .gap == "no-signal"'
  ! grep -R 'stub-agy-secret151' "$CLIKAE_HOME/state"
}

@test "agy usage: no saved token file (the Keychain backend) makes no call" {
  agy_fixture
  rm "$CLIKAE_HOME/profiles/antigravity/pike/antigravity-cli/antigravity-oauth-token"
  run clikae usage agy pike --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.gap == "no-signal"'
  [ ! -e "$AGY_CALLS" ] || false
}

@test "agy burn: the model it passes agy is the usage hint (--model X, --model=X, -m X)" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  [ "$(_agy_burn_model_of --add-dir /x --model claude-opus)" = "claude-opus" ] || false
  [ "$(_agy_burn_model_of --model=gemini-3-pro -p hi)" = "gemini-3-pro" ] || false
  [ "$(_agy_burn_model_of -m gpt-oss)" = "gpt-oss" ] || false
  [ -z "$(_agy_burn_model_of --add-dir /x)" ] || false
}
