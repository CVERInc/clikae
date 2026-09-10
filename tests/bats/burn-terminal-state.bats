#!/usr/bin/env bats
# tests/bats/burn-terminal-state.bats — P1-1 (2026-09-09 round-1 review of #41's
# status file / #37's `clikae wait`): a burn that exits WITHOUT ever writing a
# terminal state used to leave `status.json` saying `running` forever, and
# `clikae wait` (which switches on `state` alone) then blocked on a dead burn
# until its own `--timeout` (if any) expired — unbounded by default.
#
# Two independent halves of the fix, each tested here:
#   1. burn.sh installs an EXIT/INT/TERM/HUP trap right after the first
#      `running` write that writes a terminal `fail` unless one was already
#      published — covers every early `log_fail`, not just the ones this
#      review named explicitly, AND a real SIGTERM/SIGINT/SIGHUP.
#   2. `clikae wait` treats a `running` (or #38's `waiting-reset`) status
#      whose recorded pid is DEAD as a terminal, `fail`-equivalent outcome
#      (surfaced as the synthetic state `stale`) — so a status file written
#      by an OLDER clikae, or one from before this fix landed, still can't
#      hang `wait` forever.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_stub_codex() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/codex" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "run" ] && [ -n "$2" ]; then : > "$2"; fi
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

_stub_codex_slow() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/codex" <<'STUB'
#!/usr/bin/env bash
sleep 30
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

_the_status_file() {
  local f
  f="$(ls "$CLIKAE_HOME"/logs/burn-*/status.json 2>/dev/null | head -n 1)"
  [ -n "$f" ] || return 1
  printf '%s' "$f"
}

@test "burn: an early log_fail (unknown tank) ends the status file in state fail, not stuck running" {
  _stub_codex
  # Deliberately never `clikae init`ed — ensure_profile --require fails, one
  # of the "four early log_fail paths" the review named, AFTER the first
  # `running` write (#41) but before any engine ever runs.
  run clikae burn codex NOSUCHTANK --artifact "$BATS_TEST_TMPDIR/out.md" --prompt hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"Profile not found"* ]] || false

  local f; f="$(_the_status_file)"
  [ -n "$f" ] || false
  [[ "$(cat "$f")" == *'"state":"fail"'* ]] || false
  [[ "$(cat "$f")" == *'"ok":false'* ]] || false
  [[ "$(cat "$f")" != *'"state":"running"'* ]] || false
}

@test "burn: a normal successful run is NOT clobbered by the safety-net trap" {
  # Regression guard: the trap must be a true no-op once a real terminal
  # state is on disk — it must never overwrite a good `done` with its own
  # generic "exited without reaching a terminal state" reason.
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  local f; f="$(_the_status_file)"
  [[ "$(cat "$f")" == *'"state":"done"'* ]] || false
  [[ "$(cat "$f")" != *"exited without reaching a terminal state"* ]] || false
}

@test "wait: a running status with a DEAD pid is treated as terminal (stale), not hung forever" {
  # A real dead pid, not a guessed-unused one (macOS/Linux pid_max varies —
  # see the review's own P3-11): fork, let it exit, then reap it so the pid
  # is guaranteed gone.
  ( exit 0 ) &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true

  local run_id="burn-9001"
  local d="$CLIKAE_HOME/logs/$run_id"
  mkdir -p "$d"
  printf '{"ok":null,"engine":"codex","tank":"T1","artifact":null,"artifact_bytes":null,"reason":null,"reset":null,"rerouted_from":[],"elapsed_s":0,"run_id":"%s","state":"running","started_at":1,"updated_at":1,"pid":%s,"log":null,"reset_at":null}\n' \
    "$run_id" "$dead_pid" > "$d/status.json"

  local t0=$SECONDS
  run clikae wait "$run_id" --timeout 15
  local elapsed=$((SECONDS - t0))
  [[ "$output" == *'"state":"stale"'* ]] || false
  [ "$elapsed" -lt 10 ] || false   # never hangs to the timeout on a dead burn
}

@test "burn: SIGTERM mid-run leaves the status file in state fail, not running" {
  _stub_codex_slow
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  # Invoke the binary directly (not the `clikae` test wrapper function) so
  # $! is unambiguously bin/clikae's own pid, not a wrapping subshell's.
  "$CLIKAE_BIN" burn codex T1 --artifact "$A" --prompt hi &
  local bpid=$!

  local f="" waited=0
  while [ "$waited" -lt 15 ]; do
    f="$(ls "$CLIKAE_HOME"/logs/burn-*/status.json 2>/dev/null | head -n1)"
    if [ -n "$f" ] && grep -q '"state":"running"' "$f" 2>/dev/null; then break; fi
    sleep 1; waited=$((waited + 1))
  done
  [ -n "$f" ] || false
  [[ "$(cat "$f")" == *'"state":"running"'* ]] || false

  kill -TERM "$bpid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true

  local waited2=0
  while [ "$waited2" -lt 15 ]; do
    grep -q '"state":"fail"' "$f" 2>/dev/null && break
    sleep 1; waited2=$((waited2 + 1))
  done
  [[ "$(cat "$f")" == *'"state":"fail"'* ]] || false
  [[ "$(cat "$f")" != *'"state":"running"'* ]] || false
}
