#!/usr/bin/env bats
# tests/bats/burn.bats — `clikae burn`: run a headless task on a tank, verify by
# ARTIFACT (not exit code — codex exec exits 0 even when limited), and fall through
# to the next tank when one runs dry. Uses a stubbed `codex` binary; no real codex.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

# Stub `codex` on PATH. Per-tank behaviour keyed off $CODEX_HOME:
#   a ".dry" marker in the tank dir  -> emit the limit line, write nothing (exit 0)
#   otherwise, `run <path>`          -> create <path> (the artifact)
#   otherwise                        -> do nothing (a task that fails to produce)
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

@test "burn completes on a live tank and verifies by the artifact" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [[ "$output" == *"Done on codex/T1"* ]] || false
}

@test "burn reroutes from a dry tank to the next same-engine tank" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"     # T1 is dry; T2 is live
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [[ "$output" == *"ran dry"* ]] || false
  [[ "$output" == *"codex/T2"* ]] || false
}

@test "burn honours an explicit --to next hop on a dry tank" {
  _stub_codex
  clikae init codex T1
  clikae init codex H
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" --to codex/H -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [[ "$output" == *"codex/H"* ]] || false
}

@test "burn fails when every reachable tank is dry" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  : > "$CLIKAE_HOME/profiles/codex/T2/.dry"
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dry"* ]] || false
}

@test "burn does NOT reroute a real task failure (no artifact, no limit)" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" -- noop
  [ "$status" -ne 0 ]
  [[ "$output" == *"real task failure"* ]] || false
  [[ "$output" != *"codex/T2"* ]] || false      # did not fall through
}

@test "burn --no-reroute runs once and stops on a dry tank" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --no-reroute -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -ne 0 ]
  [[ "$output" != *"codex/T2"* ]] || false
}

@test "burn rejects agy (global, not per-tank headless)" {
  run clikae burn agy work --artifact /tmp/x -- run /tmp/x
  [ "$status" -ne 0 ]
  [[ "$output" == *"global"* ]] || false
}

@test "burn requires --artifact" {
  run clikae burn codex T1 -- run x
  [ "$status" -ne 0 ]
  [[ "$output" == *"artifact"* ]] || false
}

# --- _burn_timeout_bin: the honest-when-no-coreutils contract (world-class P1) ---

@test "_burn_timeout_bin: picks \`timeout\` when it's on PATH" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n' > "$BATS_TEST_TMPDIR/bin/timeout"; chmod +x "$BATS_TEST_TMPDIR/bin/timeout"
  local out; out="$(PATH="$BATS_TEST_TMPDIR/bin:$PATH" _burn_timeout_bin)"
  [ "$out" = "timeout" ]
}

@test "_burn_timeout_bin: no timeout tool → empty bin + a WARNING (runs unbounded, doesn't silently lie)" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  local out
  out="$(PATH="$TEST_HOME/.testbin" _burn_timeout_bin 2>"$BATS_TEST_TMPDIR/err")"   # testbin has no timeout/gtimeout
  [ -z "$out" ]                                                   # no bin selected
  grep -q "without a time bound" "$BATS_TEST_TMPDIR/err" || grep -qi "WITHOUT a time bound" "$BATS_TEST_TMPDIR/err"
}
