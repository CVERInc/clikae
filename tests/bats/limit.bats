#!/usr/bin/env bats
# tests/bats/limit.bats — codex usage-limit detection primitives (lib/core/limit.sh).
# `codex exec` exits 0 even when it hit its limit and wrote nothing, so detection
# is by OUTPUT STRING, not exit code (burn-confirmed 2026-06-03, HANDOFF). Sources
# limit.sh directly. (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_limit() {
  # log.sh first (limit.sh's helpers expect the log functions to exist).
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
}

@test "codex limit detected in a PLAIN exec line (no json)" {
  _src_limit
  run limit_line_is_real codex "You've hit your usage limit. Try again at Jul 3rd, 2026 11:38 AM." "" 0
  [ "$status" -eq 0 ]
}

@test "codex limit detected in a --json failure object" {
  _src_limit
  run limit_line_is_real codex '{"type":"turn.failed","error":{"message":"You have hit your usage limit"}}' "" 0
  [ "$status" -eq 0 ]
}

@test "codex: ordinary prose that merely mentions quota does NOT trip detection" {
  _src_limit
  run limit_line_is_real codex "I think you might be near a quota soon, let me check" "" 0
  [ "$status" -ne 0 ]
}

@test "codex reset phrase is relayed verbatim (never a computed countdown)" {
  _src_limit
  run limit_codex_reset "You've hit your usage limit. Please try again at Jul 3rd, 2026 11:38 AM."
  [ "$status" -eq 0 ]
  [[ "$output" == *"try again at Jul 3rd, 2026 11:38 AM"* ]] || false
}

@test "codex output_dry: a limit string makes the job dry and echoes the reset" {
  _src_limit
  run limit_codex_output_dry $'working...\nYou\'ve hit your usage limit. try again at Jul 7th, 2026 2:17 PM.'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Jul 7th"* ]] || false
}

@test "codex output_dry: clean output is NOT dry" {
  _src_limit
  run limit_codex_output_dry "wrote /tmp/out.md, done."
  [ "$status" -ne 0 ]
}

# --- $CLIKAE_LIMIT_PATTERN fallback for the headless output-dry path -----------
# The built-in matcher leans on codex's CURRENT wording ("hit your usage limit").
# If a vendor rewords its limit line, burn/conduct would misread a dry tank as a
# real task failure with no override (watch already has --pattern / the env var;
# this path did not). $CLIKAE_LIMIT_PATTERN is the escape hatch — same env var the
# watch path honours — so a user can teach burn/conduct a new phrase in the field.

@test "limit_output_dry: a vendor wording change is missed by the built-in matcher" {
  _src_limit
  # Hypothetical future codex phrasing the built-in regex does NOT cover.
  run limit_output_dry codex "Quota exceeded for this account. Back at Jul 7th, 2026 2:17 PM."
  [ "$status" -ne 0 ]                       # built-in can't see it (the gap)
}

@test "limit_output_dry: \$CLIKAE_LIMIT_PATTERN teaches it a new vendor phrase (codex)" {
  _src_limit
  CLIKAE_LIMIT_PATTERN='Quota exceeded'
  run limit_output_dry codex "Quota exceeded for this account. Back at Jul 7th, 2026 2:17 PM."
  [ "$status" -eq 0 ]                       # the override catches it
}

@test "limit_output_dry: \$CLIKAE_LIMIT_PATTERN works for an engine with no built-in matcher" {
  _src_limit
  # gh has no output-dry detector at all (returns 1) — the override gives one engine
  # a signal where there was none, without inventing a per-engine matcher.
  run limit_output_dry gh "some output"
  [ "$status" -ne 0 ]                       # no built-in, no override → not dry
  CLIKAE_LIMIT_PATTERN='rate limited'
  run limit_output_dry gh "you are rate limited, retry later"
  [ "$status" -eq 0 ]
}

@test "limit_output_dry: clean output stays NOT dry even with a pattern set" {
  _src_limit
  CLIKAE_LIMIT_PATTERN='Quota exceeded'
  run limit_output_dry codex "wrote /tmp/out.md, all good."
  [ "$status" -ne 0 ]
}

# --- codex dry-detection from its own rollout ---------------------------------
# The project recorded for a long time that codex's usage limit was
# "exec-stdout-only — never written to a file clikae can scan". It is written:
# the interactive TUI puts it in the rollout transcript with a MACHINE-READABLE
# marker, `codex_error_info: usage_limit_exceeded`. We match that field, never
# the English sentence beside it (vendor copy drifts; the marker is the contract).
# NB: each remaining arg becomes its OWN LINE. Building the fixture with
# "$(_codex_limit_line …)$(_codex_reply_line …)" silently glues both JSON objects
# onto one line — command substitution eats the trailing newline — and a
# one-line fixture made the self-clearing test fail against correct code.
_seed_codex_rollout() {
  local dir="$1" name="$2"; shift 2
  mkdir -p "$dir/sessions/2026/07/27"
  local l
  : > "$dir/sessions/2026/07/27/rollout-$name.jsonl"
  for l in "$@"; do
    printf '%s\n' "$l" >> "$dir/sessions/2026/07/27/rollout-$name.jsonl"
  done
}
_codex_limit_line() {
  printf '{"timestamp": "%s", "type": "event_msg", "payload": {"type": "task_complete", "error": {"message": "You'"'"'ve hit your usage limit. Upgrade to Plus, or try again at Aug 23rd, 2026 8:26 PM.", "codex_error_info": "usage_limit_exceeded"}}}' "$1"
}
_codex_reply_line() {
  printf '{"timestamp": "%s", "type": "event_msg", "payload": {"type": "agent_message", "message": "back"}}' "$1"
}

@test "limit_profile_dry codex: a limit with no later success reads DRY, with the vendor's reset phrase" {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"   # transcript_tail
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  local d="$CLIKAE_HOME/profiles/codex/t"
  _seed_codex_rollout "$d" a "$(_codex_limit_line 2026-07-27T10:00:00.000Z)"
  run limit_profile_dry codex "$d"
  [ "$status" -eq 0 ]
  [[ "$output" == *"try again at Aug 23rd, 2026 8:26 PM"* ]] || false
}

@test "limit_profile_dry codex: a reply AFTER the limit clears it (self-clearing)" {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"   # transcript_tail
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  local d="$CLIKAE_HOME/profiles/codex/t"
  _seed_codex_rollout "$d" b \
    "$(_codex_limit_line 2026-07-27T10:00:00.000Z)" \
    "$(_codex_reply_line 2026-07-27T11:00:00.000Z)"
  run limit_profile_dry codex "$d"
  [ "$status" -ne 0 ]
}

@test "limit_profile_dry codex: the English sentence alone is NOT a limit" {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"   # transcript_tail
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  local d="$CLIKAE_HOME/profiles/codex/t"
  # A user pasting the phrase into a prompt must never dry the tank — we key on
  # the structured marker precisely so this can't happen.
  _seed_codex_rollout "$d" c \
    '{"timestamp": "2026-07-27T10:00:00.000Z", "type": "event_msg", "payload": {"type": "user_message", "message": "why do I keep hitting my usage limit?"}}'
  run limit_profile_dry codex "$d"
  [ "$status" -ne 0 ]
}

@test "limit_profile_dry rejects an engine it has no signal for" {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"   # transcript_tail
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  run limit_profile_dry antigravity "$CLIKAE_HOME/profiles/antigravity/g"
  [ "$status" -ne 0 ]
}
