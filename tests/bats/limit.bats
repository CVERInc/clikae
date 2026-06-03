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
