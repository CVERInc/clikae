#!/usr/bin/env bats
# tests/bats/agy-harness.bats — the restraint that ships inside an agy tank.
#
# The behaviour under test is not "does agy behave" — it is "does a claim without
# a receipt get through". So most of these feed the hook a transcript that says
# one thing and a record that says another, and check which way it rules.
#
# Shapes here are not invented: the transcript fields (`exit_code`, `tool_calls`,
# `source: MODEL`) and the Stop contract were read off real agy runs on
# 2026-08-12, not off the vendor's docs — whose example even puts transcriptPath
# in the wrong directory.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_harness_lib() {
  CLIKAE_ROOT="$CLIKAE_TEST_ROOT"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/agy_harness.sh"
}

HARNESS() { printf '%s' "$CLIKAE_TEST_ROOT/assets/agy-harness/clikae-harness.sh"; }

# _transcript <file> <last-model-message> [with_command] [with_test_file]
_transcript() {
  local f="$1" msg="$2" cmd="${3:-0}" tf="${4:-0}"
  : > "$f"
  printf '{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"do the thing"}\n' >> "$f"
  if [ "$cmd" = "1" ]; then
    printf '{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command","args":{"CommandLine":"make test"}}]}\n' >> "$f"
    printf '{"step_index":2,"source":"TOOL","type":"TOOL_RESULT","exit_code":0,"content":"ok"}\n' >> "$f"
  fi
  if [ "$tf" = "1" ]; then
    printf '{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"write_file","args":{"path":"tests/foo_test.py"}}]}\n' >> "$f"
  fi
  python3 -c '
import json,sys
print(json.dumps({"step_index":9,"source":"MODEL","type":"PLANNER_RESPONSE","content":sys.argv[1]}))
' "$msg" >> "$f"
}

# _payload <transcript> [workspace]
_payload() {
  python3 -c '
import json,sys
print(json.dumps({"conversationId":"conv-'"$BATS_TEST_NUMBER"'",
                  "workspacePaths":[sys.argv[2]],
                  "transcriptPath":sys.argv[1],
                  "terminationReason":"model_stop","fullyIdle":True}))
' "$1" "${2:-$BATS_TEST_TMPDIR}"
}

_run_stop() {  # stdin: payload
  CK_HARNESS_STATE="$BATS_TEST_TMPDIR/state" bash "$(HARNESS)" Stop
}

@test "harness: a verified claim with ZERO commands run is not accepted" {
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  _transcript "$t" "I verified everything works and all tests pass." 0
  run bash -c "printf %s '$(_payload "$t")' | CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision": "continue"'* || "$output" == *'"decision":"continue"'* ]] || false
  [[ "$output" == *"ZERO commands"* ]] || false
}

@test "harness: the same claim WITH a command run is accepted" {
  # The control. Without it, a hook that blocked everything would pass the test
  # above and look like it was working.
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  _transcript "$t" "I verified everything works and all tests pass." 1
  run bash -c "printf %s '$(_payload "$t")' | CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "harness: an ordinary reply that claims nothing is left alone" {
  # The threshold is the CLAIM, not the amount of work. Answering a question
  # without running anything is not a defect and must not be nagged.
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  _transcript "$t" "The file lives in lib/core/limit.sh, around line 40." 0
  run bash -c "printf %s '$(_payload "$t")' | CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [ -z "$output" ]
}

@test "harness: claiming tests were added without touching a test file is caught" {
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  _transcript "$t" "I added tests for the new parser." 1 0
  run bash -c "printf %s '$(_payload "$t")' | CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [[ "$output" == *"no test file was touched"* ]] || false
}

@test "harness: claiming tests were added AND touching one is accepted" {
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  _transcript "$t" "I added tests for the new parser." 1 1
  run bash -c "printf %s '$(_payload "$t")' | CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [ -z "$output" ]
}

@test "harness: interactively it interrupts ONCE, then gets out of your way" {
  # A gate that can never pass must not be able to hold a session forever — and
  # when you are sitting there, one interruption is all it takes for the claim to
  # arrive with its contradiction attached.
  local t="$BATS_TEST_TMPDIR/t.jsonl" p
  _transcript "$t" "I verified everything works." 0
  p="$(_payload "$t")"
  run bash -c "printf %s '$p' | CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [[ "$output" == *"continue"* ]] || false
  run bash -c "printf %s '$p' | CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [[ "$output" != *"continue"* ]] || false          # second stop is allowed
}

@test "harness: dispatched it holds on longer, but still stops" {
  local t="$BATS_TEST_TMPDIR/t.jsonl" p i
  _transcript "$t" "I verified everything works." 0
  p="$(_payload "$t")"
  for i in 1 2 3; do
    run bash -c "printf %s '$p' | CLIKAE_DISPATCH=1 CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
    [[ "$output" == *"continue"* ]] || false
  done
  run bash -c "printf %s '$p' | CLIKAE_DISPATCH=1 CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [[ "$output" != *"continue"* ]] || false          # the cap is real
}

@test "harness: the project's own gate is run, and its output is what comes back" {
  local t="$BATS_TEST_TMPDIR/t.jsonl" ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws"
  printf '#!/usr/bin/env bash\necho "CUSTOM-GATE-SAYS-NO"\nexit 3\n' > "$ws/.clikae-gate"
  chmod +x "$ws/.clikae-gate"
  _transcript "$t" "Done." 1
  run bash -c "printf %s '$(_payload "$t" "$ws")' | CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [[ "$output" == *"CUSTOM-GATE-SAYS-NO"* ]] || false
  [[ "$output" == *"exit 3"* ]] || false
}

@test "harness: no project gate means no project check, not a silent pass claim" {
  local t="$BATS_TEST_TMPDIR/t.jsonl" ws="$BATS_TEST_TMPDIR/ws2"
  mkdir -p "$ws"
  _transcript "$t" "Done." 1
  run bash -c "printf %s '$(_payload "$t" "$ws")' | CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [ -z "$output" ]
}

@test "harness: a dispatched agent may not edit the ruler" {
  run bash -c "printf '%s' '{\"toolCall\":{\"name\":\"write_file\",\"args\":{\"path\":\"/repo/tests/foo.bats\"}}}' | CLIKAE_DISPATCH=1 bash '$(HARNESS)' PreToolUse"
  [[ "$output" == *deny* ]] || false
}

@test "harness: interactively YOU may edit your own tests" {
  # Friction belongs on how dangerous the action is, not on who is doing it.
  run bash -c "printf '%s' '{\"toolCall\":{\"name\":\"write_file\",\"args\":{\"path\":\"/repo/tests/foo.bats\"}}}' | bash '$(HARNESS)' PreToolUse"
  [[ "$output" == *allow* ]] || false
}

@test "harness: an unparseable tool call is allowed, not blocked" {
  # Fail open: a harness that blocks work it cannot read is worse than one that
  # misses an edit.
  run bash -c "printf '%s' 'not json at all' | CLIKAE_DISPATCH=1 bash '$(HARNESS)' PreToolUse"
  [[ "$output" == *allow* ]] || false
}

@test "harness: a missing transcript does not block anything" {
  run bash -c "printf '%s' '{\"conversationId\":\"x\",\"transcriptPath\":\"/no/such/file\",\"workspacePaths\":[\"/tmp\"]}' | CK_HARNESS_STATE='$BATS_TEST_TMPDIR/state' bash '$(HARNESS)' Stop"
  [ -z "$output" ]
}

@test "install: a new tank gets the harness, wired to its own copy" {
  _src_harness_lib
  local tank="$BATS_TEST_TMPDIR/tank"
  mkdir -p "$tank"
  run agy_harness_install "$tank"
  [ "$status" -eq 0 ]
  [ -x "$tank/config/clikae-harness.sh" ]
  grep -q "$tank/config/clikae-harness.sh" "$tank/config/hooks.json"
  [[ "$(cat "$tank/config/hooks.json")" != *__CK_HARNESS_SH__* ]] || false
}

@test "install: an existing file is never overwritten" {
  # Two people's decisions are at stake: someone who tuned it, and someone who
  # deleted it on purpose. Silently restoring a deleted guard is the same class
  # of bug as silently deleting one.
  _src_harness_lib
  local tank="$BATS_TEST_TMPDIR/tank2"
  mkdir -p "$tank/config"
  printf 'MINE\n' > "$tank/config/clikae-harness.sh"
  run agy_harness_install "$tank"
  [ "$status" -eq 1 ]
  [ "$(cat "$tank/config/clikae-harness.sh")" = "MINE" ]
}

@test "install: someone else's hooks.json is left alone" {
  _src_harness_lib
  local tank="$BATS_TEST_TMPDIR/tank3"
  mkdir -p "$tank/config"
  printf '{"their-hook":{}}\n' > "$tank/config/hooks.json"
  run agy_harness_install "$tank"
  [ "$status" -eq 1 ]
  grep -q 'their-hook' "$tank/config/hooks.json"
}
