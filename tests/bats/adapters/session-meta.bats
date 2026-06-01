#!/usr/bin/env bats
# tests/bats/adapters/session-meta.bats — adapter_session_meta + adapter_list_sessions,
# the data behind `clikae relay`'s preview card and session picker. Sources the
# adapter directly and feeds it fabricated JSONL transcripts; no network, no real
# claude.

load '../../helpers'

# Source the adapter under test, then point it at a sandbox profile. The adapter
# slugs $PWD, so we cd into a stable working dir whose slug we mirror.
_setup_session_meta() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK"
  cd "$WORK" || return 1
  SLUG="$(printf '%s' "$PWD" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  PROFILE="$TEST_HOME/profile"
  PROJ="$PROFILE/projects/$SLUG"
  mkdir -p "$PROJ"
}

# seed_session <sid> <opening-user-text>
seed_session() {
  local sid="$1" text="$2"
  {
    echo '{"type":"summary","summary":"x"}'
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}\n' "$text"
    echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
  } > "$PROJ/$sid.jsonl"
}

# seed_session_titled <sid> <opening-user-text> <ai-title>
# Like seed_session, plus Claude's own {"type":"ai-title","aiTitle":"…"} line.
seed_session_titled() {
  local sid="$1" text="$2" aititle="$3"
  {
    echo '{"type":"summary","summary":"x"}'
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}\n' "$text"
    printf '{"type":"ai-title","aiTitle":"%s","sessionId":"%s"}\n' "$aititle" "$sid"
    echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
  } > "$PROJ/$sid.jsonl"
}

@test "session_meta finds the newest transcript and extracts the opening title" {
  _setup_session_meta
  seed_session abc12345-0000-0000-0000-000000000000 "hello world"
  run adapter_session_meta "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"abc12345"* ]] || false
  [[ "$output" == *"hello world"* ]] || false
}

@test "session_meta keeps a CJK title intact (no mid-character slicing)" {
  _setup_session_meta
  seed_session cjc00000-0000-0000-0000-000000000000 "換油箱測試：接力這場對話"
  run adapter_session_meta "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"換油箱測試：接力這場對話"* ]] || false
}

@test "session_meta prefers Claude's ai-title over the opening prompt" {
  _setup_session_meta
  seed_session_titled tit00000-0000-0000-0000-000000000000 "lucky number 65535?" "Lucky number confirmation"
  run adapter_session_meta "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Lucky number confirmation"* ]] || false
  [[ "$output" != *"lucky number 65535"* ]] || false
}

@test "session_meta uses the LAST ai-title when a session was re-titled" {
  _setup_session_meta
  {
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"start"}]}}\n'
    printf '{"type":"ai-title","aiTitle":"First title","sessionId":"x"}\n'
    printf '{"type":"ai-title","aiTitle":"Renamed title","sessionId":"x"}\n'
  } > "$PROJ/ret00000-0000-0000-0000-000000000000.jsonl"
  run adapter_session_meta "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Renamed title"* ]] || false
  [[ "$output" != *"First title"* ]] || false
}

@test "session_meta keeps an ai-title's CJK intact" {
  _setup_session_meta
  seed_session_titled cjt00000-0000-0000-0000-000000000000 "raw prompt" "換油箱續接驗證"
  run adapter_session_meta "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"換油箱續接驗證"* ]] || false
}

@test "session_meta can target a specific session id" {
  _setup_session_meta
  seed_session aaa00000-0000-0000-0000-000000000000 "the first one"
  seed_session bbb00000-0000-0000-0000-000000000000 "the second one"
  run adapter_session_meta "$PROFILE" "aaa00000-0000-0000-0000-000000000000"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the first one"* ]] || false
}

@test "session_meta returns nonzero when there is no transcript" {
  _setup_session_meta
  run adapter_session_meta "$TEST_HOME/does-not-exist"
  [ "$status" -ne 0 ]
}

@test "session_meta returns nonzero for a missing specific session id" {
  _setup_session_meta
  seed_session aaa00000-0000-0000-0000-000000000000 "present"
  run adapter_session_meta "$PROFILE" "nope0000-0000-0000-0000-000000000000"
  [ "$status" -ne 0 ]
}

@test "session_meta falls back to a placeholder when there is no user text" {
  _setup_session_meta
  printf '%s\n' '{"type":"summary","summary":"x"}' \
    > "$PROJ/nouser00-0000-0000-0000-000000000000.jsonl"
  run adapter_session_meta "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no preview)"* ]] || false
}

@test "list_sessions returns rows newest-first" {
  _setup_session_meta
  seed_session aaa00000-0000-0000-0000-000000000000 "older one"
  sleep 1
  seed_session bbb00000-0000-0000-0000-000000000000 "newer one"
  run adapter_list_sessions "$PROFILE"
  [ "$status" -eq 0 ]
  # newest ("newer one") must be on the first line; older one still listed
  [[ "${lines[0]}" == *"newer one"* ]] || false
  [[ "$output" == *"older one"* ]] || false
}

@test "list_sessions honours a limit" {
  _setup_session_meta
  seed_session aaa00000-0000-0000-0000-000000000000 "one"
  sleep 1
  seed_session bbb00000-0000-0000-0000-000000000000 "two"
  sleep 1
  seed_session ccc00000-0000-0000-0000-000000000000 "three"
  run adapter_list_sessions "$PROFILE" 2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "list_sessions keeps CJK titles intact" {
  _setup_session_meta
  seed_session cjk11111-0000-0000-0000-000000000000 "接力這場對話到另一個帳號"
  run adapter_list_sessions "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"接力這場對話到另一個帳號"* ]] || false
}

@test "list_sessions returns nonzero when there are no sessions" {
  _setup_session_meta
  run adapter_list_sessions "$TEST_HOME/does-not-exist"
  [ "$status" -ne 0 ]
}
