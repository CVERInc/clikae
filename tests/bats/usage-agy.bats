#!/usr/bin/env bats
# tests/bats/usage-agy.bats — #151: `clikae usage agy <tank>` reads agy's own
# `v1internal:retrieveUserQuotaSummary` with the tank's saved access token, and
# splits the buckets into window/weekly by their own reset distance. No usable
# token, or any refusal, falls back to today's no-signal row. The token never
# reaches output, argv, the environment or the cache.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

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
    # The real body's shape (2026-09-27), values made up. 3p-weekly resets in
    # 20 h and is still weekly: `window` decides, not the reset distance.
    printf '{"groups":[
      {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
        {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.6,"resetTime":"%s"},
        {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":0.25,"resetTime":"%s"}]},
      {"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus","buckets":[
        {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.1,"resetTime":"%s"},
        {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","disabled":true,"remainingFraction":1,"resetTime":"%s"}]}]}' \
      "$AGY_WK_RESET" "$AGY_WIN_RESET" "$AGY_3P_RESET" "$AGY_WIN_RESET" ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
}

@test "agy usage: quota buckets become window/weekly by their own window name, source quota-api" {
  agy_fixture
  run clikae usage agy pike --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_HOME/out.log"
  echo "$output" | jq -e --arg w "$AGY_WIN_RESET" --arg k "$AGY_3P_RESET" '
    .engine == "antigravity" and .source == "quota-api"
    and .window_pct == 75 and .weekly_pct == 90
    and .window_resets_at == $w and .weekly_resets_at == $k
    and (has("gap") | not)
    and ([.models[].name] == ["Gemini Models weekly","Gemini Models 5h","Claude and GPT models weekly"])'
  # the project loadCodeAssist named is the one the quota call asked about
  grep -q 'stub-project-1' "$AGY_LOG"
  [ "$(tr '\n' ' ' < "$AGY_CALLS")" = "loadCodeAssist retrieveUserQuotaSummary " ] || false
  # same TTL as claude: a second read inside it is a cache hit, no call
  run clikae usage agy pike --json
  [ "$(wc -l < "$AGY_CALLS" | tr -d ' ')" = 2 ] || false
  ! grep -R 'stub-agy-secret151' "$AGY_LOG" "$TEST_HOME/out.log" "$CLIKAE_HOME/state"
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
