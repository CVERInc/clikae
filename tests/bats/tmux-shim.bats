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
bats_require_minimum_version 1.5.0   # for `run -<expected-code>`

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

# ── P2-3: the hop ceiling must not depend on `head` being resolvable
# (review round 2). Measured: shim + one other self-skip guard + NO real
# tmux + NO coreutils anywhere on PATH hung indefinitely (5040 bounces) —
# `$(head -c 2 …)` silently returned empty with no `head` to run, which read
# as "not a script", so the ceiling's own fallback path never triggered.

@test "shim: the hop ceiling fires even with no coreutils (not even head) on PATH" {
  local bash_bin; bash_bin="$(command -v bash)"
  mkdir -p "$TEST_HOME/.guard2bin"
  # A second, independent self-skip guard (same technique as
  # tests/stubs/tmux-guard) with an ABSOLUTE shebang, so launching it needs no
  # PATH lookup either — the whole point is a PATH with nothing resolvable on
  # it but the shim and this file.
  cat > "$TEST_HOME/.guard2bin/tmux" <<EOF
#!$bash_bin
_IFS_SAVE="\$IFS"; IFS=:
for _d in \$PATH; do
  IFS="\$_IFS_SAVE"
  [ -n "\$_d" ] || continue
  [ -x "\$_d/tmux" ] || continue
  [ "\$_d/tmux" -ef "\$0" ] && continue
  exec "\$_d/tmux" "\$@"
done
IFS="\$_IFS_SAVE"
exit 127
EOF
  chmod +x "$TEST_HOME/.guard2bin/tmux"
  # No coreutils anywhere on this PATH — not even head — and no real tmux to
  # ever terminate the leapfrog. `timeout` bounds it so a regression reads as
  # a failure (rc 124), not a hang, exactly like the round-1 self-skip test.
  # Absolute path to `timeout` itself: `env PATH=... timeout` would resolve
  # `timeout` through the very restricted PATH this test is building. Stock
  # macOS ships neither `timeout` nor `gtimeout` (same gap `_burn_timeout_bin`
  # in lib/commands/burn.sh already documents) — skip rather than fail the
  # runner for a tool this test needs but the platform doesn't have.
  local timeout_bin
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="$(command -v gtimeout)"
  else
    skip "no timeout/gtimeout on this runner's PATH to bound the hop-ceiling probe"
  fi
  run -127 env -u TMUX PATH="$CLIKAE_LIB/shims:$TEST_HOME/.guard2bin" "$timeout_bin" 10 "$(SHIM)" -V
  [[ "$output" == *"gave up after"* ]] || { echo "expected the hop-ceiling message, got: $output"; false; }
}

# ── P3-5: a malformed counter means "no counter", never an abort (review round 3).
# Measured before the pid-bound format: `garbage` -> `unbound variable`, rc 1;
# `4` -> rc 127 (the ceiling, on the very first call). Neither let a kill
# through, since the refusal runs first, but both broke an ordinary call.

@test "shim: a garbage, stale or oversized hop counter reads as no counter (the call still goes through)" {
  _tg_recorder
  local bash_bin; bash_bin="$(command -v bash)"
  local p="$CLIKAE_LIB/shims:$TEST_HOME/.recorderbin"
  local bad="" v rc
  for v in garbage 4 99 1 '1:1' '1:4' ':' ':1' '-1' '1:' 'x[$(echo INJECTED >&2)]'; do
    rm -f "$TEST_HOME/recorder.log"
    run env -u TMUX _CLIKAE_TMUX_SHIM_HOPS="$v" PATH="$p" "$bash_bin" "$(SHIM)" -V
    rc="$status"
    { [ "$rc" -eq 0 ] && [ -e "$TEST_HOME/recorder.log" ] && [[ "$output" != *INJECTED* ]] && [[ "$output" != *"unbound"* ]]; } || bad="$bad
  _CLIKAE_TMUX_SHIM_HOPS='$v': rc=$rc reached=$([ -e "$TEST_HOME/recorder.log" ] && echo yes || echo no) output=$output"
  done
  [ -z "$bad" ] || { echo "$bad"; false; }
}

@test "shim: a garbage hop counter never gets ahead of the refusal (kill-server still rc 86)" {
  _tg_recorder
  local bash_bin; bash_bin="$(command -v bash)"
  run env TMUX="$TEST_HOME/fake,1,0" _CLIKAE_TMUX_SHIM_HOPS=garbage PATH="$CLIKAE_LIB/shims:$TEST_HOME/.recorderbin" "$bash_bin" "$(SHIM)" kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  [ ! -e "$TEST_HOME/recorder.log" ] || { echo "reached the recorder — should have refused first"; false; }
}

@test "shim: an unknown/no-op verb is never touched, \$TMUX set or not" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  run env TMUX="$TEST_HOME/whatever,1,0" bash "$(SHIM)" -V
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == tmux* ]] || { echo "$output"; false; }
}

# ── clikae's own launch env: the shim goes first, at the single constructor ──
#
# 🔴 P1-1 (clikae#97 review round 1): `show-environment -t` only ever reports
# what Rule 10's `-e "PATH=…"` was asked to write — it is NOT what a pane's
# real PROCESS gets (tmux hands a new pane's process the spawning CLIENT's
# live PATH instead). The two tests below still probe the `-e` table because
# staying in sync with what Rule 10 intends is worth checking, but they are
# no longer this file's proof of the actual guarantee — the "PANE PROCESS"
# section further down is.

@test "launch: tmux_spawn_session puts the shim directory first on the session's -e table (documentary, not the guarantee)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  tmux_spawn_session --session pathprobe97 -- 'sleep 30'
  run tmux show-environment -t '=pathprobe97' PATH
  tmux kill-session -t '=pathprobe97' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  case "$output" in
    "PATH=$CLIKAE_LIB/shims:"*) : ;;
    *) echo "got: $output"; false ;;
  esac
}

@test "launch: spawning from an already-shimmed PATH does not grow the -e table" {
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

# ── P1-1: the PANE PROCESS itself, not the session table (review round 1) ──
# Linux-only: these read the pane process's real environment straight out of
# /proc, the same probe `doctor`'s `_doctor_pane_path` now uses (P1-2) — see
# lib/commands/doctor.sh for the macOS `ps eww` equivalent, not exercised
# here because bats has no portable way to inspect a process's environment
# without /proc.

@test "launch: the pane PROCESS itself gets the shim first on PATH, not just the -e table" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  [ -r /proc/self/environ ] || skip "no /proc on this platform"
  _src_tmux
  tmux_spawn_session --session pathprocprobe97 -- 'sleep 30'
  local pid; pid="$(tmux list-panes -t '=pathprocprobe97' -F '#{pane_pid}' | head -n1)"
  # tr NUL->newline INSIDE the run'd command, not after: bats captures `run`
  # output via command substitution, which silently DROPS embedded NUL bytes
  # (bash's own behaviour) — by the time that happened to a raw `cat` of
  # /proc/…/environ, every "KEY=value" pair had already run together with no
  # separator left to split on.
  run bash -c "tr '\\0' '\\n' < /proc/$pid/environ"
  tmux kill-session -t '=pathprocprobe97' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "could not read /proc/$pid/environ: $output"; false; }
  local pane_path
  pane_path="$(printf '%s\n' "$output" | sed -n 's/^PATH=//p')"
  case "$pane_path" in
    "$CLIKAE_LIB/shims:"*) : ;;
    *) echo "pane process PATH: $pane_path"; false ;;
  esac
}

@test "launch: a CHILD of the pane process inherits the shim on PATH too" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  [ -r /proc/self/environ ] || skip "no /proc on this platform"
  _src_tmux
  local outfile="$TEST_HOME/child-path.out"
  tmux_spawn_session --session pathchildprobe97 -- \
    "bash -c 'printenv PATH > $outfile; sleep 30'"
  local i=0
  while [ ! -s "$outfile" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  tmux kill-session -t '=pathchildprobe97' 2>/dev/null || true
  [ -s "$outfile" ] || { echo "the nested child never wrote its PATH"; false; }
  case "$(cat "$outfile")" in
    "$CLIKAE_LIB/shims:"*) : ;;
    *) echo "child PATH: $(cat "$outfile")"; false ;;
  esac
}

# ── P2-1: the hop counter must not leak into the pane's own environment
# (review round 2). A real `tmux_spawn_session` whose PATH is
# shim -> a wrapper SCRIPT -> the real tmux binary: the shim's own cycle
# counter has to survive its exec into that wrapper (it might leapfrog back
# into the shim), but the wrapper has no obligation to scrub it before
# reaching the real binary — measured with `~/.local/bin/tmux` reaching a
# real server that way. If that unwitnessed client happens to be the one that
# forks a fresh server, every future pane on it is born believing it is
# already mid-cycle.

@test "launch: the hop counter never reaches the pane process, even through an intermediate wrapper script" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  [ -r /proc/self/environ ] || skip "no /proc on this platform"
  _src_tmux
  local real_tmux; real_tmux="$(command -v tmux)"
  mkdir -p "$TEST_HOME/.wrapperbin"
  local bash_bin; bash_bin="$(command -v bash)"
  cat > "$TEST_HOME/.wrapperbin/tmux" <<EOF
#!$bash_bin
exec "$real_tmux" "\$@"
EOF
  chmod +x "$TEST_HOME/.wrapperbin/tmux"
  # A wrapper script sits ahead of the real tmux; tmux_spawn_session then
  # prepends the shim ahead of THAT, giving exactly shim -> wrapper -> real.
  PATH="$TEST_HOME/.wrapperbin:$PATH"
  tmux_spawn_session --session hopsleakprobe97 -- 'sleep 30'
  local pid; pid="$(tmux list-panes -t '=hopsleakprobe97' -F '#{pane_pid}' | head -n1)"
  run bash -c "tr '\\0' '\\n' < /proc/$pid/environ"
  tmux kill-session -t '=hopsleakprobe97' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "could not read /proc/$pid/environ: $output"; false; }
  case "$output" in
    *_CLIKAE_TMUX_SHIM_HOPS=*)
      echo "pane process inherited the hop counter:"; printf '%s\n' "$output"; false ;;
  esac
}

# ── P2-A: the counter must not leak through the SERVER either (review round 3).
# `env -u` above only cleans the pane `tmux_spawn_session` itself starts. A
# server forked through a wrapper script keeps the counter in its GLOBAL
# table, and every other pane on it (`new-window`, a split, clikae's own wake
# window) inherits that. With a bare number it read as "already mid-cycle":
# the pane's first `tmux` skipped the wrapper, and with host guard v3 as the
# wrapper, `unset TMUX; tmux kill-server` from that pane killed the server.

@test "launch: a new-window pane on a server born through a wrapper script goes through that wrapper on its FIRST tmux call" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  local real_tmux; real_tmux="$(command -v tmux)"
  local bash_bin; bash_bin="$(command -v bash)"
  mkdir -p "$TEST_HOME/.wrapperbin"
  cat > "$TEST_HOME/.wrapperbin/tmux" <<EOF
#!$bash_bin
printf 'WRAP argv=%s\n' "\$*" >> "$TEST_HOME/wrap.log"
exec "$real_tmux" "\$@"
EOF
  chmod +x "$TEST_HOME/.wrapperbin/tmux"
  # shim -> wrapper script -> real tmux, and the server is born by this call.
  PATH="$TEST_HOME/.wrapperbin:$PATH"
  tmux_spawn_session --session newwinprobe97 -- 'sleep 30'
  run "$real_tmux" show-environment -g _CLIKAE_TMUX_SHIM_HOPS
  [ "$status" -eq 0 ] || { tmux kill-session -t '=newwinprobe97' 2>/dev/null || true
    echo "premise broken: the server was not born carrying the counter: $output"; false; }
  : > "$TEST_HOME/wrap.log"
  # A CLEAN client (no counter of its own) opens the window, as the review
  # measured, so the only counter the new pane can hold is the server's.
  local out="$TEST_HOME/newwin-pane.out"
  env -u _CLIKAE_TMUX_SHIM_HOPS "$real_tmux" new-window -d -t '=newwinprobe97:' \
    "bash -c 'echo \"inherited=\${_CLIKAE_TMUX_SHIM_HOPS-<unset>}\" > $out; tmux -V >> $out 2>&1; echo done >> $out; sleep 30'"
  local i=0
  while ! grep -qx done "$out" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  tmux kill-session -t '=newwinprobe97' 2>/dev/null || true
  grep -qx done "$out" || { echo "the new-window pane never finished: $(cat "$out" 2>/dev/null)"; false; }
  # Premise: that pane really did inherit a counter from the server, so the
  # assertion below is about ignoring it, not about it never being there.
  ! grep -qx 'inherited=<unset>' "$out" || { echo "premise broken: pane inherited no counter: $(cat "$out")"; false; }
  grep -q '^tmux ' "$out" || { echo "pane's tmux -V did not run: $(cat "$out")"; false; }
  grep -qx 'WRAP argv=-V' "$TEST_HOME/wrap.log" || {
    echo "the pane's first tmux call skipped the wrapper"; echo "pane: $(cat "$out")"; echo "wrap.log: $(cat "$TEST_HOME/wrap.log")"; false; }
}

@test "shim: a wrapper that runs tmux as a CHILD (not exec) still hits the hop ceiling" {
  local bash_bin; bash_bin="$(command -v bash)"
  mkdir -p "$TEST_HOME/.forkguard"
  # Like the self-skip guard above, but it forks the next tmux instead of
  # exec'ing it, so every bounce is a new pid. It carries its own depth cap
  # so a regression reads as a failure, never as a runaway process chain.
  cat > "$TEST_HOME/.forkguard/tmux" <<EOF
#!$bash_bin
_FG_DEPTH=\$(( \${_FG_DEPTH:-0} + 1 )); export _FG_DEPTH
[ "\$_FG_DEPTH" -le 20 ] || { echo "forkguard: depth cap hit" >&2; exit 99; }
_IFS_SAVE="\$IFS"; IFS=:
for _d in \$PATH; do
  IFS="\$_IFS_SAVE"
  [ -n "\$_d" ] || continue
  [ -x "\$_d/tmux" ] || continue
  [ "\$_d/tmux" -ef "\$0" ] && continue
  "\$_d/tmux" "\$@"
  exit \$?
done
exit 127
EOF
  chmod +x "$TEST_HOME/.forkguard/tmux"
  run -127 env -u TMUX -u _CLIKAE_TMUX_SHIM_HOPS PATH="$CLIKAE_LIB/shims:$TEST_HOME/.forkguard" "$bash_bin" "$(SHIM)" -V
  [[ "$output" == *"gave up after"* ]] || { echo "expected the hop-ceiling message, got: $output"; false; }
  [[ "$output" != *"depth cap hit"* ]] || { echo "the shim never recognised the forked bounce: $output"; false; }
}

@test "launch: a bare kill-server run AS the pane's own process is refused (rc 86), the throwaway server survives" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  [ -r /proc/self/environ ] || skip "no /proc on this platform"
  _src_tmux
  tmux_spawn_session --session pathkillprobe97 -- 'sleep 30'
  local pid; pid="$(tmux list-panes -t '=pathkillprobe97' -F '#{pane_pid}' | head -n1)"
  local pane_path pane_tmux
  pane_path="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^PATH=//p')"
  pane_tmux="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^TMUX=//p')"
  [ -n "$pane_tmux" ] || { echo "premise broken: the pane process has no \$TMUX"; false; }
  # Reconstruct exactly what the pane's own process would run: its own real
  # PATH and $TMUX, nothing inherited from this bats process.
  run env -i PATH="$pane_path" TMUX="$pane_tmux" HOME="$TEST_HOME" bash -c 'tmux kill-server'
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux list-sessions -F '#{session_name}'
  tmux kill-session -t '=pathkillprobe97' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "the throwaway server did NOT survive: $output"; false; }
  [[ "$output" == *"pathkillprobe97"* ]] || { echo "got: $output"; false; }
}

# ── P2-1: verb resolution beyond the literal string (review round 1) ───────
# tmux itself is far more permissive than an exact "kill-server"/"kill-session"
# string: it accepts an unambiguous PREFIX of a command name, a value-taking
# GLOBAL OPTION can push the verb out of argv[1], and a `\;` COMMAND LIST runs
# every segment as its own command. Each row measured as a real bypass — a
# disposable server actually killed — under the old literal check.

@test "shim: an unambiguous prefix of kill-server (kill-serv) is refused exactly like the verb" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-serv.sock"
  tmux -S "$sock" new-session -d -s bypassserv 'sleep 60'
  run env TMUX="$sock,1,0" bash "$(SHIM)" kill-serv
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypassserv" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: an unambiguous prefix of kill-session (kill-ses) is refused exactly like the verb" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-ses.sock"
  tmux -S "$sock" new-session -d -s bypassses 'sleep 60'
  run env TMUX="$sock,1,0" bash "$(SHIM)" kill-ses
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypassses" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: a value-taking global option ahead of the verb (-f /dev/null kill-server) does not hide it" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-f.sock"
  tmux -S "$sock" new-session -d -s bypassf 'sleep 60'
  run env TMUX="$sock,1,0" bash "$(SHIM)" -f /dev/null kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypassf" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test 'shim: a `\;` command list checks EVERY segment, not just the first' {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-list.sock"
  tmux -S "$sock" new-session -d -s bypasslist 'sleep 60'
  run env TMUX="$sock,1,0" bash "$(SHIM)" list-sessions \; kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypasslist" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

# ── P2-2: the option scan is per-SEGMENT, not per-argv (review round 2) ────
# Each row measured as a real bypass — a disposable server actually killed —
# under the old check, which scanned -S/-L/-t/-a once over the whole argv
# before the verb loop ran at all.

@test 'shim: a `;` glued onto the previous word (ls\; kill-server, no space) still ends the segment' {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-glued.sock"
  tmux -S "$sock" new-session -d -s bypassglued 'sleep 60'
  # No space before the backslash: the shell hands the shim ONE token, "ls;".
  run env TMUX="$sock,1,0" bash "$(SHIM)" ls\; kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypassglued" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: another command's -S (capture-pane -S <line>) does not satisfy kill-server's socket check" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-capS.sock"
  tmux -S "$sock" new-session -d -s bypasscaps 'sleep 60'
  # capture-pane's `-S -3` is a start LINE, not a socket — it belongs to a
  # DIFFERENT segment than kill-server and must not satisfy its guard.
  run env TMUX="$sock,1,0" bash "$(SHIM)" capture-pane -S -3 -p \; kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypasscaps" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: another command's -t (list-panes -t x) does not satisfy kill-session's target check" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-listt.sock"
  tmux -S "$sock" new-session -d -s bypasslistt 'sleep 60'
  # list-panes' `-t x` names ITS target, not kill-session's — a DIFFERENT
  # segment's -t must not satisfy kill-session's guard.
  run env TMUX="$sock,1,0" bash "$(SHIM)" list-panes -t x \; kill-session
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypasslistt" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: kill-session -t =<name> is still allowed (naming the target is the whole ask)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/allowed-eqtarget.sock"
  tmux -S "$sock" new-session -d -s x 'sleep 60'
  run env TMUX="$TEST_HOME/not-the-real-one,1,0" bash "$(SHIM)" -S "$sock" kill-session -t =x
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions
  [ "$status" -ne 0 ] || { echo "the target session should be dead: $output"; false; }
}

@test "shim: kill-session -aC (combined short options) is still recognised as -a (review round 2 P3)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-ac.sock"
  tmux -S "$sock" new-session -d -s bypassac 'sleep 60'
  run env TMUX="$sock,1,0" bash "$(SHIM)" kill-session -aC
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == *"every OTHER session"* ]] || { echo "message doesn't credit -a: $output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypassac" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

# ── P2-B: a target is a VALUE, not a flag (review round 3) ─────────────────
# `-t ''` used to count as "named" just because `-t` was there. Measured on a
# real throwaway server: tmux, handed an empty target, picks a session itself
# — it killed the OTHER of two sessions, and the whole server when only one
# existed. `tmux kill-session -t "$SESS"` with `$SESS` unset is this argv.

@test "shim: kill-session -t '' (empty target) is refused (rc 86) and BOTH sessions survive" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/empty-target.sock"
  tmux -S "$sock" new-session -d -s cur 'sleep 60'
  tmux -S "$sock" new-session -d -s other 'sleep 60'
  run env TMUX="$sock,1,0" bash "$(SHIM)" kill-session -t ''
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  tmux -S "$sock" kill-server 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "server did not survive: $output"; false; }
  [ "$output" = "$(printf 'cur\nother')" ] || { echo "surviving sessions: $output"; false; }
}

@test "shim: every 'no target' spelling of kill-session is refused, every named one passes (no real tmux needed)" {
  _tg_recorder
  local bash_bin; bash_bin="$(command -v bash)"
  local p="$CLIKAE_LIB/shims:$TEST_HOME/.recorderbin"
  local bad=""
  _tg_expect() { # _tg_expect <86|0> <label> args...
    local want="$1" label="$2"; shift 2
    rm -f "$TEST_HOME/recorder.log"
    local rc=0
    env TMUX="$TEST_HOME/fake,1,0" PATH="$p" "$bash_bin" "$(SHIM)" "$@" >/dev/null 2>&1 || rc=$?
    local reached=no; [ -e "$TEST_HOME/recorder.log" ] && reached=yes
    if [ "$want" -eq 86 ]; then
      { [ "$rc" -eq 86 ] && [ "$reached" = no ]; } || bad="$bad
  expected refusal:     $label (rc=$rc reached=$reached)"
    else
      { [ "$rc" -eq 0 ] && [ "$reached" = yes ]; } || bad="$bad
  expected pass-through: $label (rc=$rc reached=$reached)"
    fi
  }
  _tg_expect 86 "-t ''"                kill-session -t ''
  _tg_expect 86 '-t ""'                kill-session -t ""
  _tg_expect 86 "-t (last token)"      kill-session -t
  _tg_expect 86 "-t="                  kill-session -t=
  _tg_expect 86 "-t ="                 kill-session -t =
  _tg_expect 86 "-t '' ; ls"           kill-session -t '' ';' ls
  _tg_expect 86 "-t ; ls"              kill-session -t ';' ls
  _tg_expect 86 "-t; ls (glued)"       kill-session '-t;' ls
  _tg_expect 86 "ls ; kill-session -t" ls ';' kill-session -t
  _tg_expect 86 "-a -t ''"             kill-session -a -t ''
  _tg_expect 0  "-t cur"               kill-session -t cur
  _tg_expect 0  "-tcur"                kill-session -tcur
  _tg_expect 0  "-t=cur"               kill-session -t=cur
  _tg_expect 0  "-t =cur"              kill-session -t =cur
  _tg_expect 0  "-t 'cur;' ls"         kill-session -t 'cur;' ls
  [ -z "$bad" ] || { echo "$bad"; false; }
}

# ── P2-2: the REFUSAL decision needs no real tmux at all (review round 1) ──
# lib/shims/tmux checks argv + $TMUX and can exit 86 before ever resolving a
# real tmux, so these run identically whether or not tmux is installed —
# unlike every test above this line, gated on `command -v tmux` because they
# also have to prove a REAL server survived or died. This is what actually
# closes the macOS CI gap: GitHub's macos bats runner ships no tmux at all,
# so ALL of the tests above (P2-1's new bypass coverage included) silently
# skipped there. These do not.

# A "real tmux" that only records what reached it, never installed as `tmux`
# anywhere a refusal should stop the call reaching it first. `#!<absolute
# path>` rather than `#!/usr/bin/env bash`: the recorder's own exec must not
# depend on the restricted PATH being handed to the shim under test.
_tg_recorder() {
  mkdir -p "$TEST_HOME/.recorderbin"
  local bash_bin; bash_bin="$(command -v bash)"
  cat > "$TEST_HOME/.recorderbin/tmux" <<EOF
#!$bash_bin
printf 'ARGV:%s\n' "\$*" >> "$TEST_HOME/recorder.log"
printf 'PATH:%s\n' "\$PATH" >> "$TEST_HOME/recorder.log"
exit 0
EOF
  chmod +x "$TEST_HOME/.recorderbin/tmux"
}

@test "shim: kill-server is refused without ever needing a real tmux on PATH" {
  _tg_recorder
  # Absolute path for bash itself: `env PATH=<restricted> bash …` would make
  # env resolve "bash" through that SAME restricted PATH and fail to find it
  # — nothing to do with the shim under test, just env's own lookup.
  local bash_bin; bash_bin="$(command -v bash)"
  run env TMUX="$TEST_HOME/fake,1,0" PATH="$CLIKAE_LIB/shims:$TEST_HOME/.recorderbin" "$bash_bin" "$(SHIM)" kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  [ ! -e "$TEST_HOME/recorder.log" ] || { echo "reached the recorder — should have refused first"; false; }
}

@test "shim: kill-serv (bypass prefix) is refused without ever needing a real tmux on PATH" {
  _tg_recorder
  local bash_bin; bash_bin="$(command -v bash)"
  run env TMUX="$TEST_HOME/fake,1,0" PATH="$CLIKAE_LIB/shims:$TEST_HOME/.recorderbin" "$bash_bin" "$(SHIM)" kill-serv
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  [ ! -e "$TEST_HOME/recorder.log" ] || { echo "reached the recorder — should have refused first"; false; }
}

@test "shim: an allowed call reaches whatever is on PATH with argv and PATH intact, real tmux or not" {
  _tg_recorder
  local bash_bin; bash_bin="$(command -v bash)"
  local test_path="$CLIKAE_LIB/shims:$TEST_HOME/.recorderbin"
  run env -u TMUX PATH="$test_path" "$bash_bin" "$(SHIM)" -V
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [ -f "$TEST_HOME/recorder.log" ] || { echo "the recorder was never reached"; false; }
  grep -qF -- '-V' "$TEST_HOME/recorder.log" || { echo "argv not forwarded: $(cat "$TEST_HOME/recorder.log")"; false; }
  # "PATH intact" is the other half of this test's own name (P3, clikae#97
  # review round 2) — the shim must leave $PATH exactly as received, not
  # strip its own directory before handing off (see the file's own comment
  # on why: stripping bought nothing against recursion and only cost every
  # downstream process the guard).
  grep -qF "PATH:$test_path" "$TEST_HOME/recorder.log" || { echo "PATH not intact: $(cat "$TEST_HOME/recorder.log")"; false; }
}
