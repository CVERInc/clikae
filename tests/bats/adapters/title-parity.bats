#!/usr/bin/env bats
# tests/bats/adapters/title-parity.bats — one session, two code paths, one title.
#
# The home board titles a Continue row with adapter_session_title <dir> <sid>.
# `clikae resume`'s picker titles the SAME session with adapter_title_for_file
# <path> (through _lazy_parse). Nothing made those two answer the same thing:
# the antigravity copy had already drifted once — the picker's inline version
# skipped the whitespace collapse, so the same conversation read differently
# depending on which list you were looking at, which is exactly the class of
# "the board and resume disagree" report this file exists to prevent.
#
# Today every adapter's adapter_session_title delegates to its own
# adapter_title_for_file, so the two paths are one function. This pins that:
# a future adapter that answers the board directly, or re-implements the
# extraction "just for the board", fails here instead of shipping two titles.
#
# Sources each adapter directly against fabricated stores; no network, no
# engines. (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../../helpers'

_parity_core() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  WORK="$TEST_HOME/work"; mkdir -p "$WORK"; cd "$WORK" || return 1
}

# _assert_parity <dir> <sid> <file> — both paths, same session, same string,
# and the string is not empty (an adapter that returns "" for everything would
# otherwise "agree" with itself).
_assert_parity() {
  local dir="$1" sid="$2" f="$3" by_sid by_file
  by_sid="$(adapter_session_title "$dir" "$sid")"
  by_file="$(adapter_title_for_file "$f")"
  [ -n "$by_sid" ] || { echo "adapter_session_title said nothing"; return 1; }
  [ "$by_sid" = "$by_file" ] || {
    echo "board path: '$by_sid'"
    echo "picker path: '$by_file'"
    return 1
  }
  return 0
}

@test "claude: the board's title and the picker's title are the same string" {
  _parity_core
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local dir="$TEST_HOME/cprofile" sid="aaaaaaaa-0000-4000-8000-000000000001" proj
  proj="$dir/projects/$(_claude_project_slug "$PWD")"
  mkdir -p "$proj"
  {
    printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"raw first prompt"}}\n' "$PWD"
    printf '{"type":"ai-title","aiTitle":"a  title\\twith  whitespace","sessionId":"%s"}\n' "$sid"
  } > "$proj/$sid.jsonl"
  _assert_parity "$dir" "$sid" "$proj/$sid.jsonl"
}

@test "codex: the board's title and the picker's title are the same string" {
  _parity_core
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/codex.sh"
  local dir="$TEST_HOME/xprofile" sid="bbbbbbbb-0000-4000-8000-000000000002" f
  mkdir -p "$dir/sessions/2026/09/22"
  f="$dir/sessions/2026/09/22/rollout-2026-09-22T00-00-00-$sid.jsonl"
  {
    printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$sid" "$PWD"
    printf '{"type":"event_msg","payload":{"type":"user_message","message":"a  title\\twith  whitespace"}}\n'
  } > "$f"
  _assert_parity "$dir" "$sid" "$f"
}

@test "grok: the board's title and the picker's title are the same string" {
  _parity_core
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/grok.sh"
  local dir="$TEST_HOME/gprofile" sid="019fb7b0-9b86-7f82-98a4-000000000003" d
  d="$dir/sessions/%2Fwork/$sid"
  mkdir -p "$d"
  cat > "$d/summary.json" <<JSON
{
  "info": {
    "id": "$sid",
    "cwd": "$PWD"
  },
  "session_summary": "a machine summary",
  "generated_title": "a  title\twith  whitespace"
}
JSON
  _assert_parity "$dir" "$sid" "$d/summary.json"
}

@test "antigravity: the board's title and the picker's title are the same string" {
  _parity_core
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/antigravity.sh"
  local dir="$TEST_HOME/aprofile" sid="cccccccc-0000-4000-8000-000000000004" f
  f="$dir/antigravity-cli/brain/$sid/.system_generated/logs/transcript.jsonl"
  mkdir -p "$(dirname "$f")"
  # The whitespace is the point: the picker's old inline copy of this
  # extraction skipped the collapse, and that is how the two paths drifted.
  printf '{"content":"a  title\\twith  whitespace"}\n' > "$f"
  printf '{"conversation_id":"%s","workspace":"%s"}\n' "$sid" "$PWD" \
    > "$dir/antigravity-cli/brain/history.jsonl"
  _assert_parity "$dir" "$sid" "$f"
}
