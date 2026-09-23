#!/usr/bin/env bats
# tests/bats/tmux-guard.bats — the backstop for the suite's tmux isolation.
#
# 🔴 WHAT THIS IS ABOUT. On 2026-08-21 the maintainer's live tmux server died
# twice while the gate was running, taking four working tanks with it. The
# isolation was not missing: every `kill-server` in the suite ran with
# $TMUX_TMPDIR correctly set, and an audit of the sources said so. What was
# missing was the DIRECTORY. tmux answers a $TMUX_TMPDIR that no longer exists
# by silently using /tmp instead — no error, no warning, no exit code — so the
# isolation read correctly and was absent at runtime.
#
# The disease is proved here first (a read-only control), then the guard.
# Without that control this file would only show that a script exits non-zero
# when handed a bad path, which proves nothing about why it is needed.

load '../helpers'

# The real binary, not the guard the suite installs as `tmux`.
_real_tmux() {
  local d
  local IFS=:
  for d in $PATH; do
    [ "$d" = "$TEST_HOME/.testbin" ] && continue
    [ -x "$d/tmux" ] && { printf '%s\n' "$d/tmux"; return 0; }
  done
  return 1
}

@test "tmux-guard: the DISEASE is real — a deleted TMUX_TMPDIR silently means /tmp" {
  # Read-only: `list-sessions` names the socket it consulted, so the fallback
  # can be demonstrated without creating or killing anything on it. Doing this
  # with kill-server is what cost the maintainer his tanks.
  local real; real="$(_real_tmux)" || skip "tmux not installed"
  local gone="$TEST_HOME/deleted-sandbox"

  # Control: while the directory EXISTS, tmux stays where it was told.
  mkdir -p "$gone"
  run env -u TMUX TMUX_TMPDIR="$gone" "$real" list-sessions
  [[ "$output" == *"$gone"* ]] || { echo "expected the isolated path, got: $output"; false; }

  # …and once it is gone, the SAME command consults /tmp instead.
  #
  # 🔴 The proof is "it did NOT stay where it was told", not "it printed /tmp".
  # This first ran while three sessions happened to be alive on the host socket,
  # so tmux LISTED THEM and printed no path at all — the test went red for
  # demonstrating the defect more completely than it knew how to assert. What
  # the host has running is not this test's business; where tmux went is.
  rm -rf "$gone"
  run env -u TMUX TMUX_TMPDIR="$gone" "$real" list-sessions
  [[ "$output" != *"$gone"* ]] || { echo "expected a fallback, got: $output"; false; }
  # It reached the default socket either way: it found a server there (status 0)
  # or it named that socket while failing to.
  [ "$status" -eq 0 ] || [[ "$output" == *"/tmp/"* ]] || {
    echo "went neither to the isolated path nor to /tmp: $output"; false; }
}

@test "tmux-guard: REFUSES when TMUX_TMPDIR points at a directory that is gone" {
  local g="$CLIKAE_TEST_ROOT/tests/stubs/tmux-guard"
  run env -u TMUX TMUX_TMPDIR="$TEST_HOME/not-there" bash "$g" kill-server
  [ "$status" -ne 0 ]
  # Naming the command matters: the failure has to say what it stopped, or the
  # next person sees an exit code with no subject.
  [[ "$output" == *"kill-server"* ]] || { echo "$output"; false; }
  [[ "$output" == *"REFUSING"* ]] || { echo "$output"; false; }
}

@test "tmux-guard: REFUSES when TMUX_TMPDIR is not set at all" {
  local g="$CLIKAE_TEST_ROOT/tests/stubs/tmux-guard"
  run env -u TMUX -u TMUX_TMPDIR bash "$g" kill-server
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSING"* ]] || { echo "$output"; false; }
}

@test "tmux-guard: ALLOWS and behaves as tmux when the sandbox is intact" {
  # A guard that refuses everything would pass the two tests above and break the
  # suite, so prove the pass-through as well — and prove it reaches the REAL
  # binary, not just that it exits 0.
  _real_tmux >/dev/null || skip "tmux not installed"
  local g="$CLIKAE_TEST_ROOT/tests/stubs/tmux-guard"
  mkdir -p "$TEST_HOME/live-sandbox"
  run env -u TMUX TMUX_TMPDIR="$TEST_HOME/live-sandbox" bash "$g" -V
  [ "$status" -eq 0 ]
  [[ "$output" == tmux* ]] || { echo "expected a tmux version banner, got: $output"; false; }
}

@test "tmux-guard: never calls itself, even when installed as \`tmux\` on PATH" {
  # It finds the real binary by skipping its own directory. If that ever breaks
  # the symptom is a fork bomb, not a failed assertion, so bound it.
  _real_tmux >/dev/null || skip "tmux not installed"
  mkdir -p "$TEST_HOME/live-sandbox"
  run env -u TMUX TMUX_TMPDIR="$TEST_HOME/live-sandbox" \
      PATH="$TEST_HOME/.testbin:$PATH" timeout 20 tmux -V
  [ "$status" -eq 0 ]
  [[ "$output" == tmux* ]] || { echo "$output"; false; }
}

@test "tmux-guard: bats deliberately does NOT run through it" {
  # 🔴 This asserts an ABSENCE, so it has to say why or someone will "fix" it.
  #
  # The guard was on the bats PATH for about an hour. What it costs, measured on
  # a QUIET machine against scrollback.bats — the suite's most timing-sensitive
  # test — with the baseline taken twice, before and after, to prove the machine
  # did not drift mid-experiment:
  #
  #   nothing installed                          10/10 green
  #   this guard                                   2/5  green
  #   a NULL shim (exec <real tmux> "$@")          3/5  green
  #
  # 🔴 THE NULL SHIM IS THE WHOLE FINDING. A wrapper that checks NOTHING costs
  # the same as this one, so the price is the bash PROCESS — one fork per tmux
  # call, and clikae calls tmux several times per launch — not anything the
  # guard does with it. Optimising cannot buy it a place here: the first version
  # went from ~21.5ms to ~4ms and the pass rate did not come back.
  #
  # 🔴 An earlier version of this comment said "0 out of 8, deterministic". That
  # was measured on a machine at load 82 — which the person measuring had
  # saturated himself with runaway processes and not noticed. Everything
  # collapses at load 82, including the empty arm (1/3), so the experiment had no
  # resolution and the strong claim was not earned. The effect is real and the
  # decision stands; the magnitude was not what was written. Take the baseline in
  # the same sitting as the arms, and if the baseline is not near-perfect, fix
  # the machine before believing anything else.
  #
  # bats does not need it. The measured killer lived in the pty harness (a
  # parent deleting $TMUX_TMPDIR while its child still had a `tmux kill-server`
  # to run), it is fixed at the source, and the guard still covers that harness
  # — where it has run green, though nobody has A/B'd it there, so treat that as
  # "no failure seen" and not as "measured free". What bats gets instead is the
  # free check below: the isolation directory must still exist when a test ends.
  # `|| true`: on a host with NO tmux at all — GitHub's macos runner, which is
  # how this test broke CI for five commits while the local gate stayed green —
  # `command -v` exits non-zero and the assignment itself fails the test. An
  # absent tmux is not the guard either, so it satisfies what is being asserted.
  local w; w="$(command -v tmux || true)"
  [ "$w" != "$TEST_HOME/.testbin/tmux" ] || {
    echo "the guard is back on the bats hot path; see the A/B above"; false; }
}

@test "tmux-guard: the bats isolation directory survives its own test" {
  # The free half of the protection. The mechanism that cost the maintainer his
  # tanks is "$TMUX_TMPDIR stopped existing while something still wanted it", and
  # here that directory lives INSIDE $TEST_HOME, which teardown removes. This
  # costs one stat per test instead of 4ms per tmux call.
  [ -n "${TMUX_TMPDIR:-}" ] || { echo "the suite set no TMUX_TMPDIR at all"; false; }
  [ -d "$TMUX_TMPDIR" ] || {
    echo "TMUX_TMPDIR ($TMUX_TMPDIR) is gone; any tmux call now silently means /tmp"; false; }
}

@test "tmux-guard: pty-smoke installs it in its sandbox too" {
  # The harness that actually did the damage builds its own PATH, so cover it
  # here rather than trusting that both places were remembered.
  local py="$CLIKAE_TEST_ROOT/tests/tools/pty-smoke.py"
  # PYTHONDONTWRITEBYTECODE: importing the harness as a module would otherwise
  # leave a tests/tools/__pycache__ behind in the developer's checkout. A test
  # that dirties the working tree is a test that breaks the gate's own
  # clean-tree stamp for whoever runs it next.
  run env PYTHONDONTWRITEBYTECODE=1 python3 - "$py" <<'PYEOF'
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location('ptysmoke', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env = m.sandbox(tanks=(('claude', 'a'),))
binp = env['PATH'].split(os.pathsep)[0]
t = os.path.join(binp, 'tmux')
assert os.path.isfile(t) and os.access(t, os.X_OK), 'no tmux guard in the sandbox bin'
assert 'REFUSING' in open(t).read(), 'the file installed as tmux is not the guard'
assert os.path.isdir(env['TMUX_TMPDIR']), 'TMUX_TMPDIR does not exist at handout'
print('OK')
PYEOF
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"OK"* ]] || { echo "$output"; false; }
}
