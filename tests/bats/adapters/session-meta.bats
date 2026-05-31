#!/usr/bin/env bats
# tests/bats/adapters/session-meta.bats — adapter_session_meta, the data behind
# `clikae relay`'s preview card. Sources the adapter directly and feeds it
# fabricated JSONL transcripts; no network, no real claude.

load '../../helpers'

# Source the adapter under test, then point it at a sandbox profile. The adapter
# slugs $PWD, so we cd into a stable working dir whose slug we mirror.
_setup_session_meta() {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/adapters/claude.sh"
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

@test "session_meta finds the newest transcript and extracts the opening title" {
  _setup_session_meta
  seed_session abc12345-0000-0000-0000-000000000000 "hello world"
  run adapter_session_meta "$PROFILE"
  assert_success
  assert_contains "abc12345"
  assert_contains "hello world"
}

@test "session_meta keeps a CJK title intact (no mid-character slicing)" {
  _setup_session_meta
  seed_session cjc00000-0000-0000-0000-000000000000 "換油箱測試：接力這場對話"
  run adapter_session_meta "$PROFILE"
  assert_success
  assert_contains "換油箱測試：接力這場對話"
}

@test "session_meta can target a specific session id" {
  _setup_session_meta
  seed_session aaa00000-0000-0000-0000-000000000000 "the first one"
  seed_session bbb00000-0000-0000-0000-000000000000 "the second one"
  run adapter_session_meta "$PROFILE" "aaa00000-0000-0000-0000-000000000000"
  assert_success
  assert_contains "the first one"
}

@test "session_meta returns nonzero when there is no transcript" {
  _setup_session_meta
  run adapter_session_meta "$TEST_HOME/does-not-exist"
  assert_failure
}

@test "session_meta returns nonzero for a missing specific session id" {
  _setup_session_meta
  seed_session aaa00000-0000-0000-0000-000000000000 "present"
  run adapter_session_meta "$PROFILE" "nope0000-0000-0000-0000-000000000000"
  assert_failure
}

@test "session_meta falls back to a placeholder when there is no user text" {
  _setup_session_meta
  printf '%s\n' '{"type":"summary","summary":"x"}' \
    > "$PROJ/nouser00-0000-0000-0000-000000000000.jsonl"
  run adapter_session_meta "$PROFILE"
  assert_success
  assert_contains "(no preview)"
}
