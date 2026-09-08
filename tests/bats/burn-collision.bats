#!/usr/bin/env bats
# tests/bats/burn-collision.bats — #40: a burn refuses to start on a tank that
# already has a RUNNING burn, and the reroute walk SKIPS such a tank rather
# than colliding with it on the tmux session name.
#
# Detection is via #41's status files (a `state: running` row whose pid is
# still alive) — never tmux session names, which is what actually collided in
# the field report this closes. Fabricates a "running" status.json directly
# (using the test's OWN pid, guaranteed alive for the test's duration) rather
# than trying to keep a real burn alive in the background.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

# Source burn.sh's own functions directly (unit-testing _burn_tank_lock_*
# rather than racing two real `clikae burn` processes against the clock,
# which is not reproducible on demand — see the P2-4 tests below).
_src_burn_lock() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/json.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/burn_status.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/duration.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/antigravity.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
}

_stub_codex() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/codex" <<'STUB'
#!/usr/bin/env bash
if [ -f "$CODEX_HOME/.dry" ]; then
  echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  exit 0
fi
if [ "$1" = "run" ] && [ -n "$2" ]; then : > "$2"; fi
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

# _mark_busy <engine> <tank> [pid] -> a fabricated "running" status.json for
# <engine>/<tank>, as if a DIFFERENT burn were mid-flight on it right now.
# Defaults to this test's own pid ($$), which is alive for as long as the test
# runs — exactly what burn_tank_busy's liveness check is supposed to accept.
#
# `started_at` is "now", not a fixed placeholder like `1` (1970): P2-1
# (2026-09-09 round-1 review) added a second check to `burn_tank_busy` — the
# marker's `started_at` must be at-or-before the named pid's OWN process
# start time, so a real 1970 timestamp next to a pid that (like this test's
# own $$) started decades later would itself look like a recycled-pid
# mismatch, which is the wrong failure mode for a fixture meaning "this is
# genuinely busy right now".
_mark_busy() {
  local eng="$1" tank="$2" pid="${3:-$$}" run_id="burn-busy-$RANDOM"
  local d="$CLIKAE_HOME/logs/$run_id" now
  now="$(date +%s 2>/dev/null || echo 1)"
  mkdir -p "$d"
  printf '{"ok":null,"engine":"%s","tank":"%s","artifact":null,"artifact_bytes":null,"reason":null,"reset":null,"rerouted_from":[],"elapsed_s":0,"run_id":"%s","state":"running","started_at":%s,"updated_at":%s,"pid":%s,"log":null}\n' \
    "$eng" "$tank" "$run_id" "$now" "$now" "$pid" > "$d/status.json"
}

@test "burn-collision: refuses to start on a tank that already has a running burn" {
  _stub_codex
  clikae init codex T1
  _mark_busy codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has a running burn"* ]] || false
  [ ! -e "$A" ] || false   # never even ran the engine
}

@test "burn-collision: --allow-active overrides the running-burn refusal" {
  _stub_codex
  clikae init codex T1
  _mark_busy codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" --allow-active -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ] || false
}

@test "burn-collision: a STALE running marker (dead pid) does not block a new burn" {
  _stub_codex
  clikae init codex T1
  # 99999 is not a real pid on any sane machine; kill -0 on it fails, so
  # burn_tank_busy must treat this marker as abandoned, not live.
  _mark_busy codex T1 99999
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ] || false
}

@test "burn-collision: reroute SKIPS a busy tank instead of colliding with it" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"   # T1 dry -> would normally reroute to T2
  _mark_busy codex T2                          # but T2 already has a burn running
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"skipping codex/T2"* ]] || false
  [[ "$output" == *"already running"* ]] || false
  [[ "$output" == *"dry"* ]] || false   # reserve exhausted (T1 dry, T2 busy) — not a real task failure
}

@test "burn-collision: reroute still lands on a THIRD tank when only one is busy" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  clikae init codex T3
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  _mark_busy codex T2
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ] || false
  [[ "$output" == *"codex/T3"* ]] || false
}

# --- P2-1 (2026-09-09 round-1 review): kill -0 alone only proves SOMETHING
# is alive at a pid, not that it's the SAME thing the marker names. A burn
# that crashed/was SIGKILLed leaves its pid free for the OS to recycle onto
# an unrelated process within the 7-day status-file retention window — and
# from then on the tank was refused FOREVER, which is a false POSITIVE (it
# blocks real work), not the false-negative window pid-liveness checks
# elsewhere in this codebase already accept. -------------------------------

@test "burn-collision: a RECYCLED pid (real, live, but started long after the marker) does not block a new burn" {
  _stub_codex
  clikae init codex T1
  # A genuinely live process — not a guessed-unused pid (see the review's own
  # P3-11 note on why 99999 alone isn't a safe universal fixture) — but its
  # OWN start time is "now", while the marker claims started_at=1 (1970).
  # That gap is exactly what a recycled pid looks like from the outside.
  sleep 60 &
  local live_pid=$!
  local run_id="burn-recycled-$RANDOM"
  local d="$CLIKAE_HOME/logs/$run_id"
  mkdir -p "$d"
  printf '{"ok":null,"engine":"codex","tank":"T1","artifact":null,"artifact_bytes":null,"reason":null,"reset":null,"rerouted_from":[],"elapsed_s":0,"run_id":"%s","state":"running","started_at":1,"updated_at":1,"pid":%s,"log":null,"reset_at":null}\n' \
    "$run_id" "$live_pid" > "$d/status.json"

  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$A" ] || false
}

@test "burn-collision: a marker whose pid is alive AND started at-or-before started_at still blocks (no false negative introduced)" {
  # Guards the other direction: P2-1's extra check must not turn a REAL busy
  # tank into a free one. _mark_busy's own started_at is "now" (see its
  # comment) — the pid ($$, this test process) started at-or-before that.
  _stub_codex
  clikae init codex T1
  _mark_busy codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has a running burn"* ]] || false
  [ ! -e "$A" ] || false
}

# --- P2-4 (2026-09-09 round-1 review): the busy-check and the `running`
# write are two separate statements with nothing between them serializing
# two burns started together — a per-tank mkdir lock now wraps them. Unit-
# tested directly against the lock primitives themselves (deterministic,
# unlike racing two real `clikae burn` processes against the clock). -------

@test "_burn_tank_lock_acquire: mutual exclusion — a second acquire blocks until the first releases" {
  _src_burn_lock
  _burn_tank_lock_acquire codex LOCKT1 5
  local held_by; held_by="$(cat "$(_burn_tank_lock_path codex LOCKT1)/pid")"
  [[ -n "$held_by" ]] || false

  # A second acquire, while this shell still holds the lock, must time out
  # rather than succeed — prove the lock is actually exclusive, not just
  # advisory-by-convention.
  run _burn_tank_lock_acquire codex LOCKT1 2
  [ "$status" -eq 1 ] || { echo "$output"; false; }

  _burn_tank_lock_release codex LOCKT1
  [[ ! -d "$(_burn_tank_lock_path codex LOCKT1)" ]] || false

  # Now that it's released, a fresh acquire succeeds immediately.
  run _burn_tank_lock_acquire codex LOCKT1 2
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "_burn_tank_lock_acquire: a lock left by a DEAD holder is reclaimed, not stuck forever" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKT2)"
  mkdir -p "$lock"
  ( exit 0 ) &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  printf '%s' "$dead_pid" > "$lock/pid"

  local t0=$SECONDS
  run _burn_tank_lock_acquire codex LOCKT2 5
  local elapsed=$((SECONDS - t0))
  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 5 ] || false   # reclaimed promptly, not stuck to the timeout
}
