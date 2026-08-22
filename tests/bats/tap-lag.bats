#!/usr/bin/env bats
# tests/bats/tap-lag.bats — the check that a release actually shipped.
#
# 🔴 WHAT IT IS FOR. brew does not install from this repository; it reads
# CVERInc/homebrew-clikae/Formula/clikae.rb. Updating homebrew/clikae.rb here
# feels like releasing and is not. That step was skipped for 0.28.0, 0.28.1 and
# 0.28.2 — three tagged, changelogged, released versions that reached nobody,
# found only when the maintainer noticed his own clikae was five behind while
# running code that fixed bugs he had reported. A comment in the formula did not
# stop it happening; this refuses every push until the tap catches up.
#
# 🔴 AND IT MUST FAIL OPEN. It is the one check here that reaches the internet.
# A missed reminder costs one more push; an unpushable repo on a train costs the
# afternoon. Both directions are pinned below, because "blocks correctly" and
# "does not block wrongly" are different claims.

load '../helpers'

# A repo with a REAL `origin` — the hook asks the remote which tags exist, so a
# fixture with only local tags would be testing a question nobody asks.
_repo() {
  HOOK="$CLIKAE_TEST_ROOT/hooks/tap-lag"
  BARE="$TEST_HOME/origin.git"; git init -q --bare "$BARE"
  R="$TEST_HOME/r"; mkdir -p "$R"; cd "$R" || return 1
  git init -q .
  git config user.email t@example.com
  git config user.name Tester
  git config commit.gpgsign false
  git remote add origin "$BARE"
  printf 'x\n' > f.txt; git add -A; git commit -qm base
  git push -q --no-verify origin HEAD:refs/heads/main 2>/dev/null || true
  STUB="$TEST_HOME/stub"; mkdir -p "$STUB"
  export PATH="$STUB:$PATH"
}

# _released <version> — a tag that a stranger can already see.
_released() { git tag "v$1"; git push -q --no-verify origin "v$1"; }

# _tap_serves <version> — the tap answers with a formula naming that tag.
_tap_serves() {
  cat > "$STUB/curl" <<EOF
#!/usr/bin/env bash
echo '  url "https://github.com/CVERInc/clikae/archive/refs/tags/v$1.tar.gz"'
echo '  sha256 "deadbeef"'
EOF
  chmod +x "$STUB/curl"
}

_tap_unreachable() {
  printf '#!/usr/bin/env bash\nexit 6\n' > "$STUB/curl"    # curl's "could not resolve host"
  chmod +x "$STUB/curl"
}

_tap_garbage() {
  printf '#!/usr/bin/env bash\necho "not a formula at all"\n' > "$STUB/curl"
  chmod +x "$STUB/curl"
}

@test "tap-lag: passes when the tap serves the newest tag" {
  _repo; _released 1.2.3; _tap_serves 1.2.3
  run bash "$HOOK"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "tap-lag: REFUSES when the newest tag has not reached the tap" {
  _repo; _released 1.2.3; _tap_serves 1.2.2
  run bash "$HOOK"
  [ "$status" -ne 0 ] || { echo "let a shipped-nowhere release through"; false; }
  # The refusal has to say what to do; a blocked push with no next step is worse
  # than the thing it is blocking.
  [[ "$output" == *"1.2.3"* ]] || { echo "$output"; false; }
  [[ "$output" == *"homebrew-clikae"* ]] || { echo "$output"; false; }
  [[ "$output" == *"CLIKAE_SKIP_TAP_CHECK"* ]] || { echo "no escape offered: $output"; false; }
}

@test "tap-lag: version comparison is by VERSION, not by string" {
  # 1.2.10 is newer than 1.2.9; `>` on strings says otherwise, and that mistake
  # would let exactly the tenth patch of a series ship nowhere.
  _repo; _released 1.2.10; _tap_serves 1.2.9
  run bash "$HOOK"
  [ "$status" -ne 0 ] || { echo "read 1.2.10 as older than 1.2.9"; false; }
}

@test "tap-lag: a tap AHEAD of this clone is not this clone's problem" {
  # Someone released from another machine; this checkout has not fetched the tag.
  # Blocking here would punish a stale clone for being stale.
  _repo; _released 1.2.3; _tap_serves 1.3.0
  run bash "$HOOK"
  [ "$status" -eq 0 ] || { echo "blocked a push because the tap was newer: $output"; false; }
}

@test "tap-lag: FAILS OPEN when the tap cannot be reached" {
  # 🔴 The load-bearing exception. No network must never mean no work.
  _repo; _released 1.2.3; _tap_unreachable
  run bash "$HOOK"
  [ "$status" -eq 0 ] || { echo "an offline machine could not push: $output"; false; }
  [[ "$output" == *"offline"* ]] || { echo "failed open in silence: $output"; false; }
}

@test "tap-lag: FAILS OPEN on a response it cannot parse" {
  # A redirect to a login page, a rewritten formula, an outage page. Guessing
  # from something unrecognised is worse than saying so.
  _repo; _released 1.2.3; _tap_garbage
  run bash "$HOOK"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"no recognisable version"* ]] || { echo "$output"; false; }
}

@test "tap-lag: no tags at all is not a lagging release" {
  _repo; _tap_serves 1.0.0
  run bash "$HOOK"
  [ "$status" -eq 0 ]
}

@test "tap-lag: CLIKAE_SKIP_TAP_CHECK overrides it" {
  _repo; _released 1.2.3; _tap_serves 1.2.2
  run env CLIKAE_SKIP_TAP_CHECK=1 bash "$HOOK"
  [ "$status" -eq 0 ]
}

@test "tap-lag: pre-push runs it" {
  # Wiring, executed rather than grepped — the lesson from the changelog guard,
  # whose first wiring test passed on the comment that named it.
  _repo
  mkdir -p "$TEST_HOME/h/hooks" "$TEST_HOME/h/scripts"
  # 🔴 EVERY hook, not a hand-kept list. pre-push chains them, so a fixture that
  # names three of them stops standing for pre-push the moment a fourth is added
  # — which is exactly what happened when hooks/tap-lag arrived: this test went
  # red for a hook it had never heard of, in a run that had nothing to do with it.
  cp "$CLIKAE_TEST_ROOT/hooks/"* "$TEST_HOME/h/hooks/"
  printf '#!/usr/bin/env bash\necho SUITE-RAN\nexit 0\n' > "$TEST_HOME/h/scripts/test.sh"
  chmod +x "$TEST_HOME/h/scripts/test.sh" "$TEST_HOME/h/hooks/"*

  _released 1.2.3; _tap_serves 1.2.2          # tap behind -> pre-push must refuse
  printf '# Changelog\n' > CHANGELOG.md
  printf 'more\n' > f.txt; git add -A; git commit -qm work
  local head base
  head="$(git rev-parse HEAD)"; base="$(git rev-parse HEAD~1)"

  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' '$head' '$base' \
                 | bash '$TEST_HOME/h/hooks/pre-push' origin git@example.com:x/y.git"
  [ "$status" -ne 0 ] || { echo "pre-push shipped a release nobody can install: $output"; false; }
  [[ "$output" == *"homebrew-clikae"* ]] || { echo "a different check refused: $output"; false; }
}

@test "tap-lag: a tag that has NOT been pushed is not a release yet" {
  # 🔴 THE DEADLOCK, AS A TEST. Keyed on the local tag, this hook refused the
  # push OF THE TAG — and the tap cannot be updated before the tag exists on the
  # remote, because the formula's url points at its tarball. So the check blocked
  # the release it was written to complete. Found by releasing, not by reading.
  _repo; _tap_serves 1.2.2
  git tag v1.2.3                      # local only, deliberately not pushed
  run bash "$HOOK"
  [ "$status" -eq 0 ] || { echo "refused the push of the tag itself: $output"; false; }
}

@test "tap-lag: FAILS OPEN when the remote's tags cannot be listed" {
  _repo; _tap_serves 1.2.2
  git remote set-url origin /nonexistent/nope.git
  run bash "$HOOK"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"remote"* ]] || { echo "failed open without saying why: $output"; false; }
}
