#!/usr/bin/env bats
# tests/bats/wait.bats — `clikae wait <run_id|status-file>… [--any|--all] [--timeout <s>]`
#
# #37: the cockpit's hand-rolled `until [ -e DONE ]; do sleep 60; done` (plus a
# separate grep for "ran dry" / "[ FAIL ]") replaced by ONE command that blocks
# on #41's status files. Fabricates status.json fixtures directly rather than
# running real burns — the polling/exit-code contract is independent of what
# produced the file, and a fixture-driven suite can assert the BLOCKING
# behaviour (does it actually wait?) without a real multi-minute engine run.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

# _mkstatus <run_id> <state> <ok> [engine] [tank] -> writes a minimal, valid
# status.json for <run_id> under $CLIKAE_HOME/logs/<run_id>/status.json.
_mkstatus() {
  local run_id="$1" state="$2" ok="$3" eng="${4:-codex}" tank="${5:-T1}"
  local d="$CLIKAE_HOME/logs/$run_id"
  mkdir -p "$d"
  printf '{"ok":%s,"engine":"%s","tank":"%s","artifact":"/tmp/x","artifact_bytes":3,"reason":"r","reset":null,"rerouted_from":[],"elapsed_s":1,"run_id":"%s","state":"%s","started_at":1,"updated_at":1,"pid":%s,"log":null}\n' \
    "$ok" "$eng" "$tank" "$run_id" "$state" "$$" > "$d/status.json"
}

@test "wait: a target already done exits 0 and prints its status object" {
  _mkstatus burn-1 done true
  run clikae wait burn-1
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"done"'* ]] || false
}

@test "wait: a target already dry exits 2" {
  _mkstatus burn-1 dry false
  run clikae wait burn-1
  [ "$status" -eq 2 ]
  [[ "$output" == *'"state":"dry"'* ]] || false
}

@test "wait: a target already fail exits 1" {
  _mkstatus burn-1 fail false
  run clikae wait burn-1
  [ "$status" -eq 1 ]
  [[ "$output" == *'"state":"fail"'* ]] || false
}

@test "wait: an infra target exits 1" {
  _mkstatus burn-1 infra false
  run clikae wait burn-1
  [ "$status" -eq 1 ]
}

@test "wait: --any (the default) returns on the FIRST terminal target, not all of them" {
  _mkstatus burn-1 running null
  _mkstatus burn-2 done true
  run clikae wait burn-1 burn-2
  [ "$status" -eq 0 ]
  [[ "$output" == *"burn-2"* ]] || false
  [[ "$output" != *"burn-1"* ]] || false   # burn-1 is still running — never reported
}

@test "wait: --all waits for every target and exits 0 only when EVERY one is done" {
  _mkstatus burn-1 done true
  _mkstatus burn-2 done true
  run clikae wait burn-1 burn-2 --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"burn-1"* ]] || false
  [[ "$output" == *"burn-2"* ]] || false
}

# P2-3 (2026-09-09 round-1 review): the exact bug — a done+dry mix under
# --all used to exit 0 because ANY done anywhere won, unconditionally. The
# caller explicitly asked about EVERY target; one of them being dry means
# the requested condition was NOT met.
@test "wait: --all exits 1 (not 0) on a done+dry mix — one finishing clean does not save the others" {
  _mkstatus burn-1 dry false
  _mkstatus burn-2 done true
  run clikae wait burn-1 burn-2 --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"burn-1"* ]] || false
  [[ "$output" == *"burn-2"* ]] || false
}

@test "wait: --all exits 1 (not 0) on a done+fail mix" {
  _mkstatus burn-1 fail false
  _mkstatus burn-2 done true
  run clikae wait burn-1 burn-2 --all
  [ "$status" -eq 1 ]
}

@test "wait: --all exits 2 when every target is dry" {
  _mkstatus burn-1 dry false
  _mkstatus burn-2 dry false
  run clikae wait burn-1 burn-2 --all
  [ "$status" -eq 2 ]
}

@test "wait: accepts a bare pid as shorthand for burn-<pid>" {
  _mkstatus burn-4242 done true
  run clikae wait 4242
  [ "$status" -eq 0 ]
}

@test "wait: accepts a literal status-file path" {
  _mkstatus burn-1 done true
  run clikae wait "$CLIKAE_HOME/logs/burn-1/status.json"
  [ "$status" -eq 0 ]
}

@test "wait: an unknown target refuses rather than hanging" {
  run clikae wait burn-does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"no status file"* ]] || false
}

@test "wait: --timeout gives up and exits 1 on a target that never finishes" {
  _mkstatus burn-1 running null
  run clikae wait burn-1 --timeout 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out"* ]] || false
}

# P1-3 (2026-09-09 round-1 review): a timeout used to exit 0 whenever ANY
# target happened to already be done, even under --all with the OTHER named
# target still running — `clikae wait A B --all --timeout 2 && ship` shipped
# on a timeout. `--timeout` expiring is 1, full stop, in both modes.
@test "wait: --all exits 1 (not 0) on a timeout even when one target is already done" {
  _mkstatus burn-1 done true
  _mkstatus burn-2 running null
  run clikae wait burn-1 burn-2 --all --timeout 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out"* ]] || false
}

@test "wait: --any exits 1 (not 0) on a timeout with no target ever reaching done" {
  _mkstatus burn-1 running null
  run clikae wait burn-1 --timeout 1
  [ "$status" -eq 1 ]
}

@test "wait: actually BLOCKS — a target that flips to done mid-wait is caught, not missed" {
  _mkstatus burn-1 running null
  ( sleep 2; _mkstatus burn-1 done true ) &
  local bgpid=$!
  local t0=$SECONDS
  run clikae wait burn-1 --timeout 20
  wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"done"'* ]] || false
  [ "$((SECONDS - t0))" -ge 1 ] || false   # it did not return before the flip could happen
}
