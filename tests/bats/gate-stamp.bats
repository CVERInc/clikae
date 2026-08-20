#!/usr/bin/env bats
# tests/bats/gate-stamp.bats — the pre-push gate's "already green for this tree"
# shortcut.
#
# 🔴 THIS IS THE ONE THAT SKIPS THE TESTS, so its failure mode is invisible by
# construction: if it says yes when it should say no, a push goes out unverified
# and everything still looks green. So the cases that must REFUSE outnumber the
# one that may allow, and each is driven at the real script.

load '../helpers'

_repo() {
  STAMPER="$CLIKAE_TEST_ROOT/hooks/gate-stamp"
  R="$TEST_HOME/r"; mkdir -p "$R"; cd "$R" || return 1
  git init -q .
  git config user.email t@example.com
  git config user.name  Tester
  git config commit.gpgsign false
  printf 'x\n' > f.txt
  git add -A; git commit -qm base
  GD="$(git rev-parse --absolute-git-dir)"
}

# _stamp [tree] [epoch] — write a stamp; defaults to HEAD's tree, now.
_stamp() {
  local tree="${1:-$(git rev-parse 'HEAD^{tree}')}" at="${2:-$(date +%s)}"
  printf '%s %s\n' "$tree" "$at" > "$GD/clikae-gate-pass"
}

@test "gate stamp: ALLOWS a skip for the same tree, stamped just now" {
  _repo
  _stamp
  run bash "$STAMPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already green"* ]] || false     # never silently
}

@test "gate stamp: REFUSES when there is no stamp at all" {
  _repo
  run bash "$STAMPER"
  [ "$status" -ne 0 ]
}

@test "gate stamp: REFUSES after a new commit — a different tree" {
  _repo
  _stamp
  printf 'changed\n' > f.txt
  git add -A; git commit -qm 'new work'
  run bash "$STAMPER"
  [ "$status" -ne 0 ]
}

@test "gate stamp: REFUSES on a DIRTY tree, even if the stamp matches HEAD" {
  _repo
  _stamp
  # The suite would have run against content git is not about to send. This is
  # the case that could actually let something unverified through, so it is the
  # one worth being loudest about.
  printf 'uncommitted\n' > f.txt
  run bash "$STAMPER"
  [ "$status" -ne 0 ]
}

@test "gate stamp: REFUSES on an untracked file — also a dirty tree" {
  _repo
  _stamp
  printf 'new\n' > extra.sh
  run bash "$STAMPER"
  [ "$status" -ne 0 ]
}

@test "gate stamp: REFUSES a stamp older than the TTL" {
  _repo
  # A stamp is a claim about a machine as well as about content: bats, tmux and
  # python can all change under it.
  _stamp "$(git rev-parse 'HEAD^{tree}')" "$(( $(date +%s) - 7201 ))"
  run bash "$STAMPER"
  [ "$status" -ne 0 ]
  # …and honours a shorter TTL when one is set.
  _stamp "$(git rev-parse 'HEAD^{tree}')" "$(( $(date +%s) - 100 ))"
  run env CLIKAE_GATE_TTL=60 bash "$STAMPER"
  [ "$status" -ne 0 ]
}

@test "gate stamp: REFUSES a stamp dated in the future" {
  _repo
  # A clock jump must not buy an unbounded skip.
  _stamp "$(git rev-parse 'HEAD^{tree}')" "$(( $(date +%s) + 99999 ))"
  run bash "$STAMPER"
  [ "$status" -ne 0 ]
}

@test "gate stamp: REFUSES a corrupt or truncated stamp" {
  _repo
  printf 'not-a-tree not-a-number\n' > "$GD/clikae-gate-pass"
  run bash "$STAMPER"
  [ "$status" -ne 0 ]
  printf '\n' > "$GD/clikae-gate-pass"
  run bash "$STAMPER"
  [ "$status" -ne 0 ]
  : > "$GD/clikae-gate-pass"
  run bash "$STAMPER"
  [ "$status" -ne 0 ]
}

@test "gate stamp: CLIKAE_FORCE_GATE always refuses the skip" {
  _repo
  _stamp
  run env CLIKAE_FORCE_GATE=1 bash "$STAMPER"
  [ "$status" -ne 0 ]
}

@test "gate stamp: test.sh writes a stamp only when the tree is clean" {
  _repo
  # Drive the real writer, not a copy of its logic. A stub suite stands in for
  # the 520-second one; what is under test is the stamping, not the checks.
  mkdir -p scripts
  head -n -0 "$CLIKAE_TEST_ROOT/scripts/test.sh" >/dev/null 2>&1 || true
  # Reproduce just the tail of test.sh (the stamping block) by running the real
  # file with every check replaced — simplest honest way is to source the block.
  local blk="$TEST_HOME/stampblk.sh"
  awk '/^# Stamp what just passed/,0' "$CLIKAE_TEST_ROOT/scripts/test.sh" > "$blk"
  [ -s "$blk" ] || { echo "could not find the stamping block in scripts/test.sh"; false; }

  rm -f "$GD/clikae-gate-pass"
  bash "$blk"
  [ -f "$GD/clikae-gate-pass" ] || { echo "clean tree: no stamp written"; false; }
  read -r t _ < "$GD/clikae-gate-pass"
  [ "$t" = "$(git rev-parse 'HEAD^{tree}')" ] || false

  rm -f "$GD/clikae-gate-pass"
  printf 'dirty\n' > f.txt
  bash "$blk"
  [ ! -f "$GD/clikae-gate-pass" ] || { echo "dirty tree: a stamp was written anyway"; false; }
}

@test "gate stamp: the pre-push hook consults it before running the suite" {
  _repo
  # Wiring, executed rather than grepped — the lesson from the changelog guard,
  # whose first wiring test passed because the comment naming it came first.
  mkdir -p "$TEST_HOME/h/hooks" "$TEST_HOME/h/scripts"
  cp "$CLIKAE_TEST_ROOT/hooks/pre-push"        "$TEST_HOME/h/hooks/"
  cp "$CLIKAE_TEST_ROOT/hooks/changelog-guard" "$TEST_HOME/h/hooks/"
  cp "$CLIKAE_TEST_ROOT/hooks/gate-stamp"      "$TEST_HOME/h/hooks/"
  printf '#!/usr/bin/env bash\necho SUITE-RAN\nexit 0\n' > "$TEST_HOME/h/scripts/test.sh"
  chmod +x "$TEST_HOME/h/scripts/test.sh" "$TEST_HOME/h/hooks/"*

  local base head
  base="$(git rev-parse HEAD)"
  printf 'more\n' > f.txt
  printf '# Changelog\n' > CHANGELOG.md      # keep the changelog guard happy
  git add -A; git commit -qm 'work'
  head="$(git rev-parse HEAD)"

  # No stamp -> the suite runs.
  rm -f "$GD/clikae-gate-pass"
  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' '$head' '$base' \
                 | bash '$TEST_HOME/h/hooks/pre-push' origin git@example.com:x/y.git"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUITE-RAN"* ]] || { echo "expected the suite to run: $output"; false; }

  # Stamped -> it does not.
  _stamp
  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' '$head' '$base' \
                 | bash '$TEST_HOME/h/hooks/pre-push' origin git@example.com:x/y.git"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SUITE-RAN"* ]] || { echo "the stamp did not stop the suite: $output"; false; }
  [[ "$output" == *"already green"* ]] || false
}
