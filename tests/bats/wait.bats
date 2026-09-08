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

# --- P1-4a (2026-09-09 round-1 review): both published examples of --timeout
# use a duration (20m/30m), and the old bare-integer-only parser rejected
# both on first try. --------------------------------------------------------

@test "wait: --timeout accepts a duration like 20m (both --help examples, as written)" {
  _mkstatus burn-1 done true
  run clikae wait burn-1 --timeout 20m
  [ "$status" -eq 0 ]
}

@test "wait: --timeout still refuses garbage rather than guessing" {
  _mkstatus burn-1 running null
  run clikae wait burn-1 --timeout banana
  [ "$status" -ne 0 ]
  [[ "$output" == *"--timeout"* ]] || false
}

# --- P1-4b: `clikae burn … --json & clikae wait "burn-$!"` (docs/orchestration.md's
# and --help's own example) loses the startup race — wait sources fewer libs
# and reads its first status file before burn has written one. -------------

@test "wait: tolerates a status file that appears a moment late (the burn & wait \"burn-\$!\" race)" {
  local run_id="burn-race1"
  local d="$CLIKAE_HOME/logs/$run_id"
  ( sleep 1; mkdir -p "$d"
    printf '{"ok":true,"engine":"codex","tank":"T1","artifact":"/tmp/x","artifact_bytes":3,"reason":"r","reset":null,"rerouted_from":[],"elapsed_s":1,"run_id":"%s","state":"done","started_at":1,"updated_at":1,"pid":%s,"log":null}\n' \
      "$run_id" "$$" > "$d/status.json" ) &
  local bgpid=$!
  CLIKAE_WAIT_RESOLVE_TIMEOUT_S=5 run clikae wait "$run_id" --timeout 10
  wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"done"'* ]] || false
}

@test "wait: a target that NEVER appears still refuses within the resolve window, not forever" {
  local t0=$SECONDS
  CLIKAE_WAIT_RESOLVE_TIMEOUT_S=2 run clikae wait burn-never-appears
  local elapsed=$((SECONDS - t0))
  [ "$status" -ne 0 ]
  [[ "$output" == *"no status file"* ]] || false
  [ "$elapsed" -ge 2 ] || false
  [ "$elapsed" -lt 10 ] || false
}

# --- P2-5: --json's own run_id ("<engine>-<tank>-burn-<pid>[-retryN]") is a
# valid `wait` target, resolved to the top-level status file it was derived
# from, instead of being tried (and failing) as a literal directory name. --

@test "wait: --json's own run_id (engine-tank-burn-pid) resolves to the top-level status file" {
  _mkstatus burn-28186 done true codex T1
  run clikae wait codex-T1-burn-28186
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"done"'* ]] || false
}

@test "wait: --json's per-attempt run_id with a -retryN suffix also resolves" {
  _mkstatus burn-28186 done true codex T1
  run clikae wait codex-T1-burn-28186-retry2
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"done"'* ]] || false
}

# --- End-to-end: docs/orchestration.md's and --help's FIRST example, as
# written, with a real (stubbed-engine) `clikae burn`, not a fabricated
# status.json. Both P1-4a (the `20m` duration) and P1-4b (the startup race)
# have to work together for this to pass. ------------------------------------

_stub_codex_for_wait() {
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

@test "wait: the documented composition — clikae burn ... --json & clikae wait \"burn-\$!\" --timeout 20m" {
  _stub_codex_for_wait
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  export CLIKAE_WAIT_RESOLVE_TIMEOUT_S=10
  # The binary directly, not the `clikae` test-wrapper FUNCTION: backgrounding
  # a function call can fork an extra subshell, and then $! would be that
  # subshell's pid, not bin/clikae's own $$ — which is what status.json (and
  # therefore "burn-$bpid") is actually keyed on.
  "$CLIKAE_BIN" burn codex T1 --artifact "$A" --json -- run "$A" >/dev/null 2>&1 &
  local bpid=$!
  run clikae wait "burn-$bpid" --timeout 20m
  wait "$bpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'"state":"done"'* ]] || false
}
