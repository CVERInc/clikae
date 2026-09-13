#!/usr/bin/env bats
# tests/bats/tank-adoption.bats — #61 round-2 P1-1: the one-time INCLUSIVE
# adoption sweep, gated by the store flag `state/tanks-adopted-v1`.
#
# helpers.bash's setup() pre-stamps that flag for every OTHER test in the
# suite (so a fixture's bare `mkdir` is never accidentally swept up). Every
# test here removes it first to put the store back in the "just upgraded,
# never adopted" state the sweep exists for.

load '../helpers'

_unadopt() {
  rm -f "$CLIKAE_HOME/state/tanks-adopted-v1"
}

# --- P1-1: inclusive, one-time, no fingerprint required ----------------------
# Mirrors the round-2 review's own reproduction: a store shaped like
# origin/main's clikae left it (no marker at all) — 8 real tanks across 5
# engines, one of them (codex/dd) LOGGED OUT (no content whatsoever — the
# case a fingerprint-gated sweep could never adopt), one symlink alias for a
# real tank, one lock-shaped file, and one directory created only AFTER
# adoption closes.
@test "adoption: inclusive one-time sweep adopts every pre-existing shape, fingerprint or not, and never re-opens" {
  _unadopt
  mkdir -p "$CLIKAE_HOME/profiles/claude/aa" "$CLIKAE_HOME/profiles/claude/bb"
  printf '{}\n' > "$CLIKAE_HOME/profiles/claude/aa/settings.json"
  printf '{}\n' > "$CLIKAE_HOME/profiles/claude/aa/.claude.json"
  # bb: no content at all — same shape as a codex tank nobody logged into.
  mkdir -p "$CLIKAE_HOME/profiles/codex/cc" "$CLIKAE_HOME/profiles/codex/dd"
  printf 'x\n' > "$CLIKAE_HOME/profiles/codex/cc/auth.json"
  # dd: LOGGED-OUT codex — no auth.json/config.toml, no fingerprint whatsoever.
  mkdir -p "$CLIKAE_HOME/profiles/kubectl/ee"
  printf 'x\n' > "$CLIKAE_HOME/profiles/kubectl/ee/config"
  mkdir -p "$CLIKAE_HOME/profiles/npm/ff"
  printf 'x\n' > "$CLIKAE_HOME/profiles/npm/ff/npmrc"
  mkdir -p "$CLIKAE_HOME/profiles/terraform/gg" "$CLIKAE_HOME/profiles/terraform/hh"
  printf 'x\n' > "$CLIKAE_HOME/profiles/terraform/hh/terraformrc"
  ln -s "$CLIKAE_HOME/profiles/terraform/hh" "$CLIKAE_HOME/profiles/terraform/hh-alias"
  : > "$CLIKAE_HOME/profiles/codex/hello.lock"

  [ ! -f "$CLIKAE_HOME/state/tanks-adopted-v1" ]
  run clikae tanks
  [ "$status" -eq 0 ]
  # 8 real tanks, each exactly once; the alias never appears as its own row.
  for want in aa bb cc dd ee ff gg hh; do
    [[ "$output" == *"$want"* ]] || { echo "missing $want: $output"; false; }
  done
  [[ "$output" != *"hh-alias"* ]] || { echo "alias listed separately: $output"; false; }
  [[ "$output" != *"hello.lock"* ]] || { echo "hello.lock listed: $output"; false; }
  # Exactly two terraform rows (gg, hh) — not three, which is what the alias
  # winning the dedupe instead of the real directory would have produced.
  [ "$(printf '%s\n' "$output" | grep -c "^terraform")" -eq 2 ] || {
    printf '%s\n' "$output" | grep "^terraform"; false
  }

  # The flag is now on disk, and every real tank (not the alias, not the
  # lock file) carries a marker.
  [ -f "$CLIKAE_HOME/state/tanks-adopted-v1" ]
  for want in claude/aa claude/bb codex/cc codex/dd kubectl/ee npm/ff terraform/gg terraform/hh; do
    [ -f "$CLIKAE_HOME/profiles/$want/.clikae-tank" ] || { echo "no marker for $want"; false; }
  done
  # hh-alias is a symlink TO hh, so a path through it resolves to hh's own
  # marker — the real assertion is that the alias has no SEPARATE identity:
  # `clikae tanks` above already proved it never gets its own row.
  [ -L "$CLIKAE_HOME/profiles/terraform/hh-alias" ]

  # A directory created AFTER the flag exists is never a tank — #61's own
  # fix stays intact once adoption has closed.
  mkdir -p "$CLIKAE_HOME/profiles/codex/zzempty"
  run clikae tanks
  [ "$status" -eq 0 ]
  [[ "$output" != *"zzempty"* ]] || { echo "post-adoption dir was adopted: $output"; false; }
  [ ! -e "$CLIKAE_HOME/profiles/codex/zzempty/.clikae-tank" ]
  run clikae doctor
  [[ "$output" == *"codex/zzempty"* ]] || { echo "doctor didn't name the post-adoption stray: $output"; false; }
}

# --- P2-1: a read-only store adopts in memory, warns exactly once ------------
@test "adoption: a store whose flag can't be written lists correctly and warns exactly once, every run" {
  _unadopt
  mkdir -p "$CLIKAE_HOME/profiles/claude/ro1" "$CLIKAE_HOME/profiles/claude/ro2"
  chmod a-w "$CLIKAE_HOME/profiles/claude/ro1" "$CLIKAE_HOME/profiles/claude/ro2" "$CLIKAE_HOME/state" 2>/dev/null || true

  local out="$BATS_TEST_TMPDIR/out1" err="$BATS_TEST_TMPDIR/err1" rc=0
  "$CLIKAE_BIN" tanks >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || { cat "$err"; false; }
  grep -qF "ro1" "$out" || { echo "ro1 missing: $(cat "$out")"; false; }
  grep -qF "ro2" "$out" || { echo "ro2 missing: $(cat "$out")"; false; }
  [ "$(grep -c '\[ WARN \]' "$err")" -eq 1 ] || { echo "stderr: $(cat "$err")"; false; }
  grep -qF "Permission denied" "$err" && { echo "raw shell error leaked: $(cat "$err")"; false; }

  # Every run re-adopts in memory (the flag never persisted) — same result,
  # same single warning, not zero and not a pile-up.
  local out2="$BATS_TEST_TMPDIR/out2" err2="$BATS_TEST_TMPDIR/err2"
  rc=0; "$CLIKAE_BIN" tanks >"$out2" 2>"$err2" || rc=$?
  [ "$rc" -eq 0 ] || { cat "$err2"; false; }
  grep -qF "ro1" "$out2" && grep -qF "ro2" "$out2" || { echo "$(cat "$out2")"; false; }
  [ "$(grep -c '\[ WARN \]' "$err2")" -eq 1 ]

  chmod u+w "$CLIKAE_HOME/profiles/claude/ro1" "$CLIKAE_HOME/profiles/claude/ro2" "$CLIKAE_HOME/state" 2>/dev/null || true
}

# --- P2-1: doctor's own 15-adapter fan-out must not multiply the warning ----
@test "adoption: doctor's per-adapter scan does not turn one read-only tank into many warning lines" {
  _unadopt
  mkdir -p "$CLIKAE_HOME/profiles/claude/ro1"
  chmod a-w "$CLIKAE_HOME/profiles/claude/ro1" "$CLIKAE_HOME/state" 2>/dev/null || true

  local out="$BATS_TEST_TMPDIR/dout" err="$BATS_TEST_TMPDIR/derr" rc=0
  "$CLIKAE_BIN" doctor >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || { cat "$err"; false; }
  [ "$(grep -c '\[ WARN \]' "$err")" -eq 1 ] || { echo "stderr: $(cat "$err")"; false; }

  chmod u+w "$CLIKAE_HOME/profiles/claude/ro1" "$CLIKAE_HOME/state" 2>/dev/null || true
}

# --- doctor --adopt: retry button for a store whose flag never persisted ----
@test "doctor --adopt persists the flag once the store becomes writable, and reports it" {
  _unadopt
  mkdir -p "$CLIKAE_HOME/profiles/claude/ro1"
  chmod a-w "$CLIKAE_HOME/profiles/claude/ro1" "$CLIKAE_HOME/state" 2>/dev/null || true
  clikae tanks >/dev/null 2>&1 || true
  [ ! -f "$CLIKAE_HOME/state/tanks-adopted-v1" ]

  chmod u+w "$CLIKAE_HOME/profiles/claude/ro1" "$CLIKAE_HOME/state" 2>/dev/null || true
  run clikae doctor --adopt
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag written"* ]] || { echo "$output"; false; }
  [ -f "$CLIKAE_HOME/state/tanks-adopted-v1" ]
  [ -f "$CLIKAE_HOME/profiles/claude/ro1/.clikae-tank" ]
}

# --- doctor --adopt must never re-open an already-adopted store ------------
@test "doctor --adopt on an already-adopted store is a no-op — it must not readmit a post-adoption stray" {
  clikae init claude real
  mkdir -p "$CLIKAE_HOME/profiles/claude/zzempty"
  run clikae doctor --adopt
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already adopted"* ]] || { echo "$output"; false; }
  [ ! -e "$CLIKAE_HOME/profiles/claude/zzempty/.clikae-tank" ]
  run clikae tanks
  [[ "$output" != *"zzempty"* ]] || { echo "$output"; false; }
}

# --- P2-2: doctor must not call a symlink alias a stray directory ----------
@test "adoption: a symlink alias for a real, adopted tank is not reported as a stray directory" {
  clikae init codex zreal
  ln -s "$CLIKAE_HOME/profiles/codex/zreal" "$CLIKAE_HOME/profiles/codex/aalias"
  run clikae doctor
  [[ "$output" != *"codex/aalias"* ]] || { echo "alias reported as stray: $output"; false; }
  run clikae tanks
  [[ "$output" == *"zreal"* ]] || false
  [[ "$output" != *"aalias"* ]] || { echo "alias listed as its own tank: $output"; false; }
}

# --- P2-3: naming a non-tank no longer seeds one --------------------------
@test "settings apply on an explicitly named non-tank directory is refused, and never adopts it" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/zzempty"
  run clikae settings apply claude zzempty
  [ "$status" -ne 0 ]
  [[ "$output" == *"Not a tank"* ]] || { echo "$output"; false; }
  [ ! -e "$CLIKAE_HOME/profiles/claude/zzempty/settings.json" ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/zzempty/.clikae-tank" ]
  run clikae tanks
  [[ "$output" != *"zzempty"* ]] || { echo "$output"; false; }
}
