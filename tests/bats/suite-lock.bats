#!/usr/bin/env bats
# tests/bats/suite-lock.bats — one suite at a time, including the runs that skip
# the front door.
#
# 🔴 WHY. scripts/test.sh locks so two runs cannot race each other over the real
# process table, tmux servers, ports and ~/.Trash. The lock lives in the SCRIPT,
# so `bats tests/bats/foo.bats` walks past it — and the maintainer spent an
# afternoon doing exactly that while a pre-push gate ran the whole suite, then
# read the gate's red as interference. It was not: there was a real bug under
# it, and the fix nearly went unmade. A preventable collision does not just cost
# one red run; it teaches you a reason to disbelieve red ones.

load '../helpers'

# `VAR= run fn`, not `run env -u VAR fn`: env execs a BINARY, and these are
# shell functions — every such line came back 127 'Command not found'.
# 🔴 THE TESTS OWN THEIR LOCK. The first cut probed the machine's real one, so
# the check named "with no suite running, nothing is in the way" was executed BY
# a running suite and failed — correctly, on a premise it could not hold. A test
# whose precondition is "nothing else is happening" has to build that condition,
# not hope for it. Every test here points the door at a file of its own.
_lockfile() { printf '%s/suite.lock\n' "$TEST_HOME"; }

setup_lock() { export CLIKAE_SUITE_LOCK="$(_lockfile)"; }

# Hold the real lock from another process, the way a running suite does.
# 🔴 Killed in teardown without fail: this suite once left fourteen busy loops
# running for fifteen hours and every measurement taken in that window was junk.
_hold_lock() {
  command -v lockf >/dev/null 2>&1 || skip "lockf needed to hold the lock"
  lockf -k -t 5 "$(_lockfile)" sleep 20 &
  HOLDER=$!
  # Wait for it to actually own the lock — starting the process is not holding it.
  local i=0
  while [ "$i" -lt 50 ]; do
    lockf -k -t 0 "$(_lockfile)" true 2>/dev/null || return 0
    i=$((i + 1)); sleep 0.1
  done
  kill "$HOLDER" 2>/dev/null || true
  skip "could not get the lock held"
}

teardown() {
  [ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null
  wait "${HOLDER:-$$}" 2>/dev/null || true
  HOLDER=""
}

@test "suite lock: with no suite running, nothing is in the way" {
  setup_lock
  # The control. A door that is always shut is indistinguishable from a wall.
  CLIKAE_SUITE_LOCKED= run _clikae_refuse_concurrent_suite
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ]
}

@test "suite lock: a bats run started while the suite holds it is REFUSED" {
  setup_lock
  _hold_lock
  CLIKAE_SUITE_LOCKED= run _clikae_refuse_concurrent_suite
  [ "$status" -ne 0 ] || { echo "let a second suite in"; false; }
  [[ "$output" == *"another clikae test suite is running"* ]] || { echo "$output"; false; }
  # A refusal with no way forward is just an obstacle.
  [[ "$output" == *"scripts/test.sh"* ]] || { echo "no next step offered: $output"; false; }
  [[ "$output" == *"CLIKAE_ALLOW_CONCURRENT_SUITE"* ]] || { echo "no override: $output"; false; }
}

@test "suite lock: the run that HOLDS the lock is not refused by its own door" {
  setup_lock
  # Without the marker, scripts/test.sh would probe the lock it is holding, find
  # it busy, and refuse every file of the suite it is running.
  _hold_lock
  CLIKAE_SUITE_LOCKED=1 run _clikae_refuse_concurrent_suite
  [ "$status" -eq 0 ] || { echo "the suite refused itself: $output"; false; }
}

@test "suite lock: the override works" {
  setup_lock
  _hold_lock
  CLIKAE_SUITE_LOCKED= CLIKAE_ALLOW_CONCURRENT_SUITE=1 run _clikae_refuse_concurrent_suite
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "suite lock: probing never creates the lock file" {
  setup_lock
  # Its absence is the common case, and a probe that leaves a file behind would
  # make every later run pay for a lock nobody took.
  [ ! -e "$(_lockfile)" ] || { echo "premise broken: the lock already exists"; false; }
  CLIKAE_SUITE_LOCKED= run _clikae_refuse_concurrent_suite
  [ "$status" -eq 0 ]
  [ ! -e "$(_lockfile)" ] || { echo "the probe created the lock file"; false; }
}

@test "suite lock: scripts/test.sh really does export the marker" {
  setup_lock
  # Wiring, read from the source rather than assumed — this is the one line that
  # keeps the door from locking the suite out of itself.
  run grep -q 'export CLIKAE_SUITE_LOCKED=1' "$CLIKAE_TEST_ROOT/scripts/test.sh"
  [ "$status" -eq 0 ] || { echo "scripts/test.sh no longer marks its own run"; false; }
}
