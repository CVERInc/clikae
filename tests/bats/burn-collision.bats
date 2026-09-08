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
_mark_busy() {
  local eng="$1" tank="$2" pid="${3:-$$}" run_id="burn-busy-$RANDOM"
  local d="$CLIKAE_HOME/logs/$run_id"
  mkdir -p "$d"
  printf '{"ok":null,"engine":"%s","tank":"%s","artifact":null,"artifact_bytes":null,"reason":null,"reset":null,"rerouted_from":[],"elapsed_s":0,"run_id":"%s","state":"running","started_at":1,"updated_at":1,"pid":%s,"log":null}\n' \
    "$eng" "$tank" "$run_id" "$pid" > "$d/status.json"
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
