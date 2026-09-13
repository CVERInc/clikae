#!/usr/bin/env bats
# tests/bats/tmux-shim.bats — lib/shims/tmux, the guard clikae puts ahead of the
# real tmux on every session it launches (CVERInc/clikae#97).
#
# 🔴 WHAT THIS IS ABOUT. A process that has INHERITED $TMUX from a live server
# and runs a destructive verb naming no socket hits the inherited server, not
# whatever it thought it was isolating. Twice:
#
#   2026-09-10  a reviewer's bare `tmux kill-server` (no -L) took down the
#               operator's real server.
#   2026-09-13  a fix lane ran `TMUX_TMPDIR="$T" tmux kill-server`, believing
#               TMUX_TMPDIR isolated it — socket precedence is
#               -S > -L > $TMUX > TMUX_TMPDIR, and $TMUX (inherited from the
#               cockpit) was set, so it killed the cockpit and 14 running
#               lanes. Resumed from its own transcript, it did it again.
#
# This file's own tests must not repeat the disease they are proving a fix
# for. Every test that exercises the REFUSAL runs the shim with an explicit
# throwaway `-S` server as the "inherited" one ($TMUX points at it, never at
# the real thing) and proves that server survived by listing it before and
# after. Tests that exercise the two PASS-THROUGH shapes tmux-spawn.bats and
# ssh-agent-link.bats already rely on ($TMUX unset, TMUX_TMPDIR isolated by
# tests/helpers.bash) reuse that same, already-audited isolation rather than
# inventing a second mechanism.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

SHIM() { printf '%s/lib/shims/tmux\n' "$CLIKAE_TEST_ROOT"; }

_src_tmux() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
}

# ── the guard itself ─────────────────────────────────────────────────────────

@test "shim: bare kill-server while \$TMUX is inherited is refused (rc 86), and the real server survives" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/victim-server.sock"
  tmux -S "$sock" new-session -d -s victim 'sleep 60'
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "victim" ] || {
    echo "premise broken: the throwaway victim server did not start: $output"; false; }

  run env TMUX="$sock,99999,0" bash "$(SHIM)" kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == *"kill-server"* ]] || { echo "message doesn't name the verb: $output"; false; }
  [[ "$output" == *"$sock"* ]] || { echo "message doesn't name the socket: $output"; false; }
  [[ "$output" == *"tmux -S"* ]] || { echo "message doesn't name the legal form: $output"; false; }

  # PROOF, not inference: list the victim server again, after.
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] || { echo "the victim server did NOT survive: $output"; false; }
  [ "$output" = "victim" ] || { echo "got: $output"; false; }

  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: kill-server -S <path> passes straight through" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/passthrough-server.sock"
  tmux -S "$sock" new-session -d -s pt 'sleep 60'

  # $TMUX names a DIFFERENT (nonexistent) inherited socket. Naming -S is what
  # must let this through, not the absence of an inherited $TMUX.
  run env TMUX="$TEST_HOME/not-the-real-one,1,0" bash "$(SHIM)" -S "$sock" kill-server
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }

  # Proof it reached the REAL binary, not just that the guard stayed quiet:
  # the -S target is actually gone.
  run tmux -S "$sock" list-sessions
  [ "$status" -ne 0 ] || { echo "the -S server should be dead: $output"; false; }
}

@test "shim: bare kill-session while \$TMUX is inherited is refused (rc 86), and the current session survives" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/victim-session.sock"
  tmux -S "$sock" new-session -d -s cur 'sleep 60'

  run env TMUX="$sock,99999,0" bash "$(SHIM)" kill-session
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == *"kill-session"* ]] || { echo "message doesn't name the verb: $output"; false; }
  [[ "$output" == *"$sock"* ]] || { echo "message doesn't name the socket: $output"; false; }
  [[ "$output" == *"-t"* ]] || { echo "message doesn't name the legal form: $output"; false; }

  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] || { echo "the current session did NOT survive: $output"; false; }
  [ "$output" = "cur" ] || { echo "got: $output"; false; }

  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: kill-session -t <target> passes straight through even with \$TMUX inherited" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/target-session.sock"
  tmux -S "$sock" new-session -d -s target 'sleep 60'

  # -S here is only so the command reaches OUR throwaway server; the guard's
  # kill-session check cares about -t, not -S/-L.
  run env TMUX="$TEST_HOME/not-the-real-one,1,0" bash "$(SHIM)" -S "$sock" kill-session -t target
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }

  run tmux -S "$sock" list-sessions
  [ "$status" -ne 0 ] || { echo "the target session should be dead: $output"; false; }
}

@test "shim: \$TMUX unset never refuses, not even a bare kill-server" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # Safety premise (same one tmux-spawn.bats states and relies on): $TMUX is
  # unset and TMUX_TMPDIR is THIS TEST's own throwaway directory, so the
  # "default" socket a bare, unqualified command reaches is never the real one.
  [ -z "${TMUX:-}" ] || { echo "TMUX leaked into the test: $TMUX"; false; }
  [[ "$TMUX_TMPDIR" == "$TEST_HOME"* ]] || { echo "TMUX_TMPDIR=$TMUX_TMPDIR"; false; }

  tmux new-session -d -s isoprobe 'sleep 60'
  run env -u TMUX bash "$(SHIM)" kill-server
  [ "$status" -eq 0 ] || { echo "refused with \$TMUX unset: status=$status output=$output"; false; }

  # Proof it reached the real binary: the isolated default server is gone too.
  run tmux list-sessions
  [ "$status" -ne 0 ] || { echo "expected the isolated server to be gone: $output"; false; }
}

@test "shim: never calls itself, even with its own directory on PATH twice" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local shimdir="$CLIKAE_TEST_ROOT/lib/shims"
  # If self-skip ever breaks, the symptom is a fork bomb, not a failed
  # assertion — bound it with timeout so that reads as a failure too.
  run env -u TMUX PATH="$shimdir:$shimdir:$PATH" timeout 15 "$(SHIM)" -V
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == tmux* ]] || { echo "expected a tmux version banner, got: $output"; false; }
}

@test "shim: an unknown/no-op verb is never touched, \$TMUX set or not" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  run env TMUX="$TEST_HOME/whatever,1,0" bash "$(SHIM)" -V
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == tmux* ]] || { echo "$output"; false; }
}

# ── clikae's own launch env: the shim goes first, at the single constructor ──

@test "launch: tmux_spawn_session puts the shim directory first on the session's PATH (Rule 10)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  # Rule 10 sets PATH via an explicit `-e`, exactly like Rule 4 already does
  # for SSH_AUTH_SOCK (see ssh-agent-link.bats) — so `show-environment -t` is
  # the right probe here, and this is executed rather than asserted about.
  tmux_spawn_session --session pathprobe97 -- 'sleep 30'
  run tmux show-environment -t '=pathprobe97' PATH
  tmux kill-session -t '=pathprobe97' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  case "$output" in
    "PATH=$CLIKAE_LIB/shims:"*) : ;;
    *) echo "got: $output"; false ;;
  esac
}

@test "launch: spawning from an already-shimmed PATH does not grow it" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  PATH="$CLIKAE_LIB/shims:$PATH"
  tmux_spawn_session --session pathprobe97b -- 'sleep 30'
  run tmux show-environment -t '=pathprobe97b' PATH
  tmux kill-session -t '=pathprobe97b' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local count
  count="$(printf '%s' "$output" | grep -o "$CLIKAE_LIB/shims" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] || { echo "shim dir appears $count times in: $output"; false; }
}
