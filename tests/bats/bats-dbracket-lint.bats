#!/usr/bin/env bats
# tests/bats/bats-dbracket-lint.bats — scripts/bats-dbracket-lint.sh and the
# suite it guards.
#
# 🔴 On bash 3.2 (a stock Mac's /bin/bash) errexit does not fire on a failing
# `[[ ]]`, so a bare `[[ ]]` assertion that is not a test's last line is
# ignored and the test reports ok. Proven 2026-09-29 on usage.bats:723 with a
# deliberately wrong expected value: green before ` || false`, red after.
# Linux CI (bash 5) never showed it, so the Mac was the only place it lied.
#
# A guard is only worth what you have watched it refuse: the first three tests
# are the refusals. Fixtures are built with printf, not heredocs, so this
# file's own text can never satisfy or trip the lint it is testing.

load '../helpers'

LINT="$CLIKAE_TEST_ROOT/scripts/bats-dbracket-lint.sh"

@test "bats-dbracket-lint: a bare [[ ]] assertion line is caught (rc 1, file:line printed)" {
  printf '@test "x" {\n  run true\n  %s "$output" == *foo* %s\n  echo after\n}\n' '[[' ']]' > "$TEST_HOME/bad.bats"
  run bash "$LINT" "$TEST_HOME/bad.bats"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "$TEST_HOME/bad.bats:3: [[ \"\$output\" == *foo* ]]" ]
}

@test "bats-dbracket-lint: a backslash-continued [[ ]] with no OR on the next line is caught" {
  printf '  %s "$a" == b %s \\\n    ; echo hi\n' '[[' ']]' > "$TEST_HOME/cont.bats"
  run bash "$LINT" "$TEST_HOME/cont.bats"
  [ "$status" -eq 1 ]
}

@test "bats-dbracket-lint: a negated bare ! [[ ]] is caught" {
  printf '  ! %s "$a" == b %s\n' '[[' ']]' > "$TEST_HOME/neg.bats"
  run bash "$LINT" "$TEST_HOME/neg.bats"
  [ "$status" -eq 1 ]
}

@test "bats-dbracket-lint: legal forms pass (|| false, || {…}, &&, backslash + ||, if [[, heredoc body)" {
  {
    printf '  %s "$a" == b %s || false\n' '[[' ']]'
    printf '  %s "$a" == b %s || { echo "got $a"; false; }\n' '[[' ']]'
    printf '  %s -n "$a" %s && echo yes\n' '[[' ']]'
    printf '  %s "$a" == b %s \\\n    || { echo "got $a"; false; }\n' '[[' ']]'
    printf '  if %s "$a" == b %s; then :; fi\n' '[[' ']]'
    printf '  cat > f <<EOF\n%s "$a" == b %s\nEOF\n' '[[' ']]'
    printf '  cat > g <<-'"'"'X'"'"'\n\t%s "$a" == b %s\n\tX\n' '[[' ']]'
  } > "$TEST_HOME/good.bats"
  run bash "$LINT" "$TEST_HOME/good.bats"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bats-dbracket-lint: every tracked .bats file in this repo is clean" {
  run bash "$LINT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
