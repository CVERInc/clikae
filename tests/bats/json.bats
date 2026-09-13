#!/usr/bin/env bats
load '../helpers'

# json_field_str is a small extractor (lib/core/json.sh) added for the
# cockpit guard (#63, lib/hooks/cockpit-guard.sh) to read a PreToolUse hook
# payload's tool_name / tool_input.model / tool_input.prompt without jq.
#
# Fixtures are written to a FILE with `printf '%s' '<literal>'` (the %s
# argument gets no backslash interpretation from printf, unlike the format
# string) so the JSON text below is exactly what's on disk — no second layer
# of shell-escaping to get wrong between here and the `bash -c` under test.
_json_extract() {
  local payload_file="$1" field="$2"
  run bash -c 'source "$CLIKAE_LIB/core/json.sh"; json_field_str "$(cat "$1")" "$2"' _ "$payload_file" "$field"
}

@test "json_field_str extracts a top-level string field" {
  local f="$BATS_TEST_TMPDIR/p.json"
  printf '%s' '{"tool_name":"Agent","x":1}' > "$f"
  _json_extract "$f" tool_name
  [ "$status" -eq 0 ]
  [ "$output" = "Agent" ]
}

@test "json_field_str extracts a field nested inside another object" {
  local f="$BATS_TEST_TMPDIR/p.json"
  printf '%s' '{"tool_input":{"model":"sonnet","prompt":"hi"}}' > "$f"
  _json_extract "$f" model
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]
}

@test "json_field_str decodes an escaped quote inside the value without truncating" {
  local f="$BATS_TEST_TMPDIR/p.json"
  printf '%s' '{"prompt":"say \"hi\" then stop"}' > "$f"
  _json_extract "$f" prompt
  [ "$status" -eq 0 ]
  [ "$output" = 'say "hi" then stop' ]
}

@test "json_field_str decodes an escaped newline" {
  local f="$BATS_TEST_TMPDIR/p.json"
  printf '%s' '{"prompt":"line one\nline two"}' > "$f"
  _json_extract "$f" prompt
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "line one" ]
  [ "${lines[1]}" = "line two" ]
}

@test "json_field_str leaves a literal backslash-n (not an escaped newline) alone" {
  local f="$BATS_TEST_TMPDIR/p.json"
  # JSON \\  ->  one real backslash, then the literal letters n u l.
  printf '%s' '{"prompt":"a path C:\\nul"}' > "$f"
  _json_extract "$f" prompt
  [ "$status" -eq 0 ]
  [ "$output" = 'a path C:\nul' ]
}

@test "json_field_str returns 1 and nothing for a field that is absent" {
  local f="$BATS_TEST_TMPDIR/p.json"
  printf '%s' '{"tool_name":"Agent"}' > "$f"
  _json_extract "$f" model
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "json_field_str returns 1 for malformed JSON rather than matching garbage" {
  local f="$BATS_TEST_TMPDIR/p.json"
  printf '%s' 'not json at all' > "$f"
  _json_extract "$f" model
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "json_field_str does not confuse a similarly-prefixed key (prompt_id) with the target field (prompt)" {
  local f="$BATS_TEST_TMPDIR/p.json"
  printf '%s' '{"prompt_id":"abc-123"}' > "$f"
  _json_extract "$f" prompt
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
