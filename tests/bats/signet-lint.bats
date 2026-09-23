#!/usr/bin/env bats
# tests/bats/signet-lint.bats — scripts/signet-lint.sh's own self-test.
#
# 🔴 A guard is only worth what you have watched it REFUSE. `⏳` (U+23F3) once
# reached the tmux status row and neither the fetched signet linter's own
# ranges nor this wrapper's cursor-exception ranges (U+2600–27BF, U+1F300–
# 1FAFF, U+2B00–2BFF, U+FE0F) ever covered Miscellaneous Technical, the block
# it lives in — so the standing no-emoji rule was breached silently. The fix
# added a local scan for the emoji-presentation code points actually in that
# block (U+231A–231B, U+23E9–23FA), which excludes `⌘`/`⌥` (legitimate key
# names in the same block) by construction. `--self-test` proves that local
# scan still fires — no network, no fetched linter, nothing else this script
# does.

load '../helpers'

SIGNET_LINT="$CLIKAE_TEST_ROOT/scripts/signet-lint.sh"

@test "signet-lint --self-test: a file containing the old ⏳ mark is caught" {
  run bash "$SIGNET_LINT" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"caught"* ]] || { echo "$output"; false; }
}

@test "signet-lint --self-test: needs no network and no fetched linter" {
  # A `curl` that would fail loudly if this path ever tried to reach the
  # network — the self-test must never get that far.
  mkdir -p "$TEST_HOME/.testbin"
  printf '#!/usr/bin/env bash\necho "curl should not run here" >&2\nexit 1\n' \
    > "$TEST_HOME/.testbin/curl"
  chmod +x "$TEST_HOME/.testbin/curl"
  run env PATH="$TEST_HOME/.testbin:$PATH" bash "$SIGNET_LINT" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" != *"curl should not run"* ]] || { echo "$output"; false; }
}

@test "signet-lint: the new clock-glyph scan names the file and line, not just 'somewhere'" {
  # Runs the scan step in isolation (the same loop signet-lint.sh runs over
  # its own file list), against a throwaway file, so this does not depend on
  # network access to the fetched upstream linter either.
  local f="$TEST_HOME/probe.sh"
  printf '#!/usr/bin/env bash\necho hi\n# ⏳ expired\n' > "$f"
  run perl -CSD -ne 'print "$ARGV:$.: [emoji-clock] $_" if /[\x{231A}-\x{231B}\x{23E9}-\x{23FA}]/' "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$f:3:"* ]] || { echo "$output"; false; }
}

@test "signet-lint: the clock-glyph scan does not flag the legitimate key names in the same block" {
  local f="$TEST_HOME/probe.sh"
  printf '#!/usr/bin/env bash\n# held ⌘ and ⌥ together\n' > "$f"
  run perl -CSD -ne 'print "$ARGV:$.: [emoji-clock] $_" if /[\x{231A}-\x{231B}\x{23E9}-\x{23FA}]/' "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "flagged a legitimate key name: $output"; false; }
}
