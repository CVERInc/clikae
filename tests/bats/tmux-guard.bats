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

@test "tmux-guard: the suite installs it as \`tmux\`, ahead of the real one" {
  # Wiring, executed rather than grepped. helpers.bash has already run.
  local w; w="$(command -v tmux)"
  [ "$w" = "$TEST_HOME/.testbin/tmux" ] || {
    echo "the suite is not running through the guard; \`tmux\` resolves to $w"; false; }
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
