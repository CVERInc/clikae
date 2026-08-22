#!/usr/bin/env bats
# tests/bats/changelog-guard.bats — the pre-push changelog guard.
#
# 🔴 A guard is only worth what you have watched it REFUSE. This repo shipped a
# constant-true guard once (wake's "am I the last window?", mis-quoted, never
# fired, a month) and the shape of that failure is invisible: everything is
# green, because the check always passes. So every case here says which way it
# is supposed to go, and the ones that must BLOCK outnumber the ones that pass.

load '../helpers'

# A throwaway repo with a real history to compute ranges over.
_repo() {
  GUARD="$CLIKAE_TEST_ROOT/hooks/changelog-guard"
  R="$TEST_HOME/r"; mkdir -p "$R"; cd "$R" || return 1
  git init -q .
  git config user.email t@example.com
  git config user.name  Tester
  git config commit.gpgsign false
  mkdir -p lib bin tests docs
  printf 'x\n' > lib/a.sh; printf 'x\n' > bin/clikae
  printf '# Changelog\n\n## [Unreleased]\n' > CHANGELOG.md
  printf 'x\n' > tests/t.bats; printf 'x\n' > docs/d.md
  git add -A; git commit -qm base
  BASE="$(git rev-parse HEAD)"
}

# _push_payload <remote-sha> <local-sha> -> feed the guard one ref line.
_guard() {
  printf 'refs/heads/main %s refs/heads/main %s\n' "$2" "$1" | bash "$GUARD"
}

_commit() { git add -A; git commit -qm "$1"; git rev-parse HEAD; }

@test "changelog guard: BLOCKS a lib/ change with no changelog entry" {
  _repo
  printf 'changed\n' > lib/a.sh
  local head; head="$(_commit 'touch lib')"
  run _guard "$head" "$BASE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANGELOG.md is untouched"* ]] || false
  [[ "$output" == *"lib/a.sh"* ]] || false        # names the actual file
}

@test "changelog guard: BLOCKS a bin/ change with no changelog entry" {
  _repo
  printf 'changed\n' > bin/clikae
  local head; head="$(_commit 'touch bin')"
  run _guard "$head" "$BASE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bin/clikae"* ]] || false
}

@test "changelog guard: BLOCKS when the changelog moved in an EARLIER push" {
  _repo
  # The range is what this push carries, not the whole history. A changelog entry
  # written last week does not license today's change.
  printf '# Changelog\n\n## [Unreleased]\n\n- something\n' > CHANGELOG.md
  local pushed; pushed="$(_commit 'changelog only')"
  printf 'changed\n' > lib/a.sh
  local head; head="$(_commit 'touch lib')"
  run _guard "$head" "$pushed"
  [ "$status" -ne 0 ]
}

@test "changelog guard: PASSES when the changelog moved in the same commit" {
  _repo
  printf 'changed\n' > lib/a.sh
  printf '# Changelog\n\n## [Unreleased]\n\n- said so\n' > CHANGELOG.md
  local head; head="$(_commit 'touch lib and say so')"
  run _guard "$head" "$BASE"
  [ "$status" -eq 0 ]
}

@test "changelog guard: PASSES when any commit in the range touched it" {
  _repo
  # How a real change is usually written: code first, notes before pushing.
  printf 'changed\n' > lib/a.sh
  _commit 'touch lib' >/dev/null
  printf '# Changelog\n\n## [Unreleased]\n\n- said so\n' > CHANGELOG.md
  local head; head="$(_commit 'write it up')"
  run _guard "$head" "$BASE"
  [ "$status" -eq 0 ]
}

@test "changelog guard: PASSES for tests, docs, hooks and scripts alone" {
  _repo
  # The question is "would a user notice?", so the guard must not fire on work
  # that cannot reach them. A guard that cries on every doc typo gets bypassed
  # reflexively, and then it is not protecting the case it exists for.
  printf 'changed\n' > tests/t.bats
  printf 'changed\n' > docs/d.md
  mkdir -p hooks scripts; printf 'x\n' > hooks/h; printf 'x\n' > scripts/s
  local head; head="$(_commit 'no user-visible change')"
  run _guard "$head" "$BASE"
  [ "$status" -eq 0 ]
}

@test "changelog guard: a TAG push carries no new commits and is let through" {
  _repo
  printf 'changed\n' > lib/a.sh
  local head; head="$(_commit 'touch lib')"
  run bash -c "printf 'refs/tags/v1.0.0 %s refs/tags/v1.0.0 %s\n' '$head' '0000000000000000000000000000000000000000' | bash '$GUARD'"
  [ "$status" -eq 0 ]
}

@test "changelog guard: deleting a branch is let through" {
  _repo
  run bash -c "printf 'refs/heads/gone %s refs/heads/gone %s\n' '0000000000000000000000000000000000000000' '$BASE' | bash '$GUARD'"
  [ "$status" -eq 0 ]
}

@test "changelog guard: CLIKAE_SKIP_CHANGELOG is the narrow escape, and says so" {
  _repo
  printf 'changed\n' > lib/a.sh
  local head; head="$(_commit 'touch lib')"
  run env CLIKAE_SKIP_CHANGELOG=1 bash -c \
    "printf 'refs/heads/main %s refs/heads/main %s\n' '$head' '$BASE' | bash '$GUARD'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED"* ]] || false     # never silently
}

@test "changelog guard: an unknown remote sha does not wedge the push" {
  _repo
  # A brand-new branch with no origin/main to measure against. The guard must
  # decline to judge rather than block a push it cannot reason about.
  printf 'changed\n' > lib/a.sh
  local head; head="$(_commit 'touch lib')"
  run _guard "$head" "0000000000000000000000000000000000000000"
  [ "$status" -eq 0 ]
}

@test "changelog guard: the real pre-push hook actually refuses the push" {
  # Wiring test, and it RUNS the hook rather than reading it. The first version of
  # this test compared line numbers — and passed with the guard moved after the
  # `exec`, because the first line mentioning "changelog-guard" is the COMMENT
  # explaining it. A guard's own documentation satisfying the assertion that
  # checks the guard is a real shape; the way out is to execute, not to grep.
  _repo
  # A copy of the tree the hook needs: the hook, the guard, and a test suite
  # stubbed to succeed instantly — so the ONLY thing that can refuse is the guard.
  mkdir -p "$TEST_HOME/h/hooks" "$TEST_HOME/h/scripts"
  # 🔴 EVERY hook, not a hand-kept list. pre-push chains them, so a fixture that
  # names three of them stops standing for pre-push the moment a fourth is added
  # — which is exactly what happened when hooks/tap-lag arrived: this test went
  # red for a hook it had never heard of, in a run that had nothing to do with it.
  cp "$CLIKAE_TEST_ROOT/hooks/"* "$TEST_HOME/h/hooks/"
  printf '#!/usr/bin/env bash\necho SUITE-RAN\nexit 0\n' > "$TEST_HOME/h/scripts/test.sh"
  chmod +x "$TEST_HOME/h/scripts/test.sh" "$TEST_HOME/h/hooks/changelog-guard"

  printf 'changed\n' > lib/a.sh
  local head; head="$(_commit 'touch lib')"

  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' '$head' '$BASE' \
                 | bash '$TEST_HOME/h/hooks/pre-push' origin git@example.com:x/y.git"
  [ "$status" -ne 0 ] || { echo "the hook allowed a push the guard should refuse"; false; }
  [[ "$output" == *"CHANGELOG.md is untouched"* ]] || false
  # And it refused BEFORE the suite: with the guard after the `exec`, the stub
  # runs and the hook exits 0, so this line is what pins the ordering.
  [[ "$output" != *"SUITE-RAN"* ]] || { echo "guard ran after the suite"; false; }
}

@test "changelog guard: the real pre-push hook lets a clean push through to the suite" {
  # The other half: the guard must not be a wall. If this passed while the one
  # above also passed only because the hook always fails, both would be lies.
  _repo
  mkdir -p "$TEST_HOME/h/hooks" "$TEST_HOME/h/scripts"
  # 🔴 EVERY hook, not a hand-kept list. pre-push chains them, so a fixture that
  # names three of them stops standing for pre-push the moment a fourth is added
  # — which is exactly what happened when hooks/tap-lag arrived: this test went
  # red for a hook it had never heard of, in a run that had nothing to do with it.
  cp "$CLIKAE_TEST_ROOT/hooks/"* "$TEST_HOME/h/hooks/"
  printf '#!/usr/bin/env bash\necho SUITE-RAN\nexit 0\n' > "$TEST_HOME/h/scripts/test.sh"
  chmod +x "$TEST_HOME/h/scripts/test.sh" "$TEST_HOME/h/hooks/changelog-guard"

  printf 'changed\n' > lib/a.sh
  printf '# Changelog\n\n## [Unreleased]\n\n- said so\n' > CHANGELOG.md
  local head; head="$(_commit 'touch lib and say so')"

  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' '$head' '$BASE' \
                 | bash '$TEST_HOME/h/hooks/pre-push' origin git@example.com:x/y.git"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUITE-RAN"* ]] || { echo "the suite never ran: $output"; false; }
}
