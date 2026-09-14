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

@test "#61 round-4 P3-4: a read-only store warns once even on --version/help/adapters, not just tank-reading commands" {
  _unadopt
  mkdir -p "$CLIKAE_HOME/profiles/claude/ro3"
  chmod a-w "$CLIKAE_HOME/profiles/claude/ro3" "$CLIKAE_HOME/state" 2>/dev/null || true

  for sub in --version help adapters; do
    local out="$BATS_TEST_TMPDIR/out-$sub" err="$BATS_TEST_TMPDIR/err-$sub" rc=0
    "$CLIKAE_BIN" "$sub" >"$out" 2>"$err" || rc=$?
    [ "$rc" -eq 0 ] || { echo "clikae $sub: $(cat "$err")"; false; }
    [ "$(grep -c '\[ WARN \]' "$err")" -eq 1 ] || { echo "clikae $sub stderr: $(cat "$err")"; false; }
  done

  chmod u+w "$CLIKAE_HOME/profiles/claude/ro3" "$CLIKAE_HOME/state" 2>/dev/null || true
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
  # #61 round-3 P1-2: bin/clikae's own hoisted _tank_adoption_ensure call now
  # runs before doctor's dispatcher ever sees "--adopt" — by the time this
  # process reaches doctor's own explicit retry, the store is ALREADY
  # writable (chmod u+w above ran before `run` did), so the hoist itself
  # does the write and doctor's case reports "Already adopted" instead of
  # "flag written". Either wording is correct: what matters is that this
  # SAME command, given a store that just became writable, ends with the
  # flag persisted and the tank marked — not which call inside the process
  # narrates doing it.
  [[ "$output" == *"flag written"* || "$output" == *"Already adopted"* ]] || { echo "$output"; false; }
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

# --- #61 round-4 P3-7: a HALF-adopted store (flag present, but a directory
# with real content lost its marker — e.g. a restored backup) must not say
# "Already adopted — nothing to do" while doctor's own stray-directory check
# names that very directory. ------------------------------------------------
@test "doctor --adopt on a half-adopted store (flag present, a content-shaped stray missing its marker) names the fix instead of claiming nothing to do" {
  clikae init claude real
  mkdir -p "$CLIKAE_HOME/profiles/claude/two"
  printf '{"stub":true}\n' > "$CLIKAE_HOME/profiles/claude/two/.claude.json"
  run clikae doctor --adopt
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"Already adopted"*"nothing to do"* ]] || \
    { echo "still claims nothing to do while naming a stray: $output"; false; }
  [[ "$output" == *"clikae init claude two --adopt"* ]] || { echo "$output"; false; }
  [ ! -f "$CLIKAE_HOME/profiles/claude/two/.clikae-tank" ]

  # The named fix actually works.
  run clikae init claude two --adopt
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$CLIKAE_HOME/profiles/claude/two/.clikae-tank" ]
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

# --- #61 round-3 P1-2: the sweep must close on the FIRST command run against
# the store, not just the first one that happens to WALK the whole store
# (list_all_profiles). `init` creates its own tank directly and never walks;
# a real upgrade's first command is very often something else entirely —
# `settings apply <engine> <tank>` (#76) requires a marker on a NAMED path
# without ever calling the enumerator, so on a genuinely pre-marker store
# (the exact shape an upgrade finds) it used to say "Not a tank" about a
# tank that has been real the whole time, main included.
@test "settings apply #61 P1-2: a pre-marker real tank passes as the very first command run" {
  _unadopt
  mkdir -p "$CLIKAE_HOME/profiles/claude/real"
  printf '{}\n' > "$CLIKAE_HOME/profiles/claude/real/.claude.json"
  [ ! -f "$CLIKAE_HOME/state/tanks-adopted-v1" ]
  [ ! -f "$CLIKAE_HOME/profiles/claude/real/.clikae-tank" ]

  run clikae settings apply claude real
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"Not a tank"* ]] || { echo "$output"; false; }

  # The hoist ran on this very first command — the window is now closed.
  [ -f "$CLIKAE_HOME/state/tanks-adopted-v1" ]
  [ -f "$CLIKAE_HOME/profiles/claude/real/.clikae-tank" ]
}

# --- #61 round-3 P1-2: the same guard must not touch a store that has no
# profiles/ directory yet at all — the three burn.bats "refuses before
# creating any clikae state" tests depend on this: a refusal that runs
# before ANY tank exists must create nothing, not even the state/ dir the
# adoption flag would live in.
@test "adoption #61 P1-2: a store with no profiles/ dir yet is left untouched by the hoist" {
  rm -rf "$CLIKAE_HOME"
  [ ! -e "$CLIKAE_HOME" ]
  run clikae doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # doctor itself creates $CLIKAE_HOME (it's a normal command), but the
  # adoption flag must not appear as a side effect of a store that had
  # nothing to adopt.
  [ ! -f "$CLIKAE_HOME/state/tanks-adopted-v1" ]
}

# --- #61 round-3 P3: the warn-once sentinel neither leaks nor can be
# silently defeated by pid reuse -------------------------------------------
@test "adoption warn sentinel: cleaned up after the process exits, not left in TMPDIR forever" {
  _unadopt
  mkdir -p "$CLIKAE_HOME/profiles/claude/ro1"
  chmod a-w "$CLIKAE_HOME/profiles/claude/ro1" "$CLIKAE_HOME/state" 2>/dev/null || true

  local fake_tmp="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$fake_tmp"
  local out="$BATS_TEST_TMPDIR/out" err="$BATS_TEST_TMPDIR/err" rc=0
  TMPDIR="$fake_tmp" "$CLIKAE_BIN" tanks >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || { cat "$err"; false; }
  [ "$(grep -c '\[ WARN \]' "$err")" -eq 1 ] || { echo "stderr: $(cat "$err")"; false; }
  # bin/clikae's own EXIT trap removes the sentinel — nothing should remain.
  [ -z "$(find "$fake_tmp" -maxdepth 1 -name '.clikae-adopt-warn.*' 2>/dev/null)" ] || \
    { echo "sentinel leaked: $(ls -la "$fake_tmp")"; false; }

  chmod u+w "$CLIKAE_HOME/profiles/claude/ro1" "$CLIKAE_HOME/state" 2>/dev/null || true
}

# --- #61 round-4 P2-1: the sentinel PATH is now recorded by
# _tank_adoption_warn_once into a global, and the EXIT trap just `rm -f`s
# it — no recomputing it (and forking `ps`/`date` to do so) on every exit,
# including the overwhelming majority where nothing was ever created. ------

_stub_ps_date_counters() {
  local bin="$BATS_TEST_TMPDIR/psdatebin"
  mkdir -p "$bin"
  local real_ps real_date
  real_ps="$(command -v ps)"
  real_date="$(command -v date)"
  cat > "$bin/ps" <<STUB
#!/usr/bin/env bash
printf 'x\n' >> "$BATS_TEST_TMPDIR/ps.calls"
exec "$real_ps" "\$@"
STUB
  chmod +x "$bin/ps"
  cat > "$bin/date" <<STUB
#!/usr/bin/env bash
printf 'x\n' >> "$BATS_TEST_TMPDIR/date.calls"
exec "$real_date" "\$@"
STUB
  chmod +x "$bin/date"
  PATH="$bin:$PATH"; export PATH
}

@test "#61 round-4 P2-1: --version on a writable store forks neither ps nor date (sentinel path is only computed when a sentinel is actually created)" {
  _stub_ps_date_counters
  run clikae --version
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/ps.calls" ] || { echo "ps called: $(cat "$BATS_TEST_TMPDIR/ps.calls")"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/date.calls" ] || { echo "date called: $(cat "$BATS_TEST_TMPDIR/date.calls")"; false; }
}

@test "#61 round-4 P2-1: --version on a read-only store forks ps exactly once (to name the sentinel it creates), never on the way out again" {
  _unadopt
  mkdir -p "$CLIKAE_HOME/profiles/claude/ro5"
  chmod a-w "$CLIKAE_HOME/profiles/claude/ro5" "$CLIKAE_HOME/state" 2>/dev/null || true
  _stub_ps_date_counters
  run clikae --version
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$BATS_TEST_TMPDIR/ps.calls" 2>/dev/null || echo 0)" -eq 1 ] || \
    { echo "ps.calls: $(cat "$BATS_TEST_TMPDIR/ps.calls" 2>/dev/null)"; false; }
  chmod u+w "$CLIKAE_HOME/profiles/claude/ro5" "$CLIKAE_HOME/state" 2>/dev/null || true
}

@test "adoption warn sentinel path: keyed by more than bare pid when this platform can report a start time" {
  # White-box: on any platform where `ps -o lstart=` + `date` parse (macOS
  # and this suite's own Linux host both do — round-3 review measured a
  # bare-\$\$ sentinel silently swallowing a warning after a simulated pid
  # reuse), the path must differ from the bare-\$\$ sentinel name the
  # pre-fix code always used, so a leftover file from a DIFFERENT process
  # that reused this pid can never match.
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  local path; path="$(_tank_adoption_warn_sentinel_path)"
  local bare="${TMPDIR:-/tmp}/.clikae-adopt-warn.$$"
  if ps -o lstart= -p "$$" >/dev/null 2>&1; then
    [ "$path" != "$bare" ] || { echo "sentinel is still bare-\$\$: $path"; false; }
    [[ "$path" == "$bare".* ]] || { echo "sentinel doesn't extend the bare name: $path"; false; }
  fi
  # Calling it twice in the same process is stable (idempotent naming).
  local path2; path2="$(_tank_adoption_warn_sentinel_path)"
  [ "$path" = "$path2" ]
}

# --- #61 round-3 P3: a marker with a trailing \r or trailing whitespace is
# still recognised — a sync tool turning \n into \r\n used to make a real,
# already-adopted tank vanish from `clikae tanks` entirely, with no CLI able
# to bring it back (doctor can't even name it: it reads as "not a tank",
# not "corrupted marker").
@test "a marker with a trailing CRLF still names a real tank" {
  clikae init claude crlf
  printf 'claude\r\n' > "$CLIKAE_HOME/profiles/claude/crlf/.clikae-tank"
  run clikae tanks
  [ "$status" -eq 0 ]
  [[ "$output" == *"crlf"* ]] || { echo "$output"; false; }
}

@test "a marker with trailing whitespace still names a real tank" {
  clikae init claude trailing
  printf 'claude   \n' > "$CLIKAE_HOME/profiles/claude/trailing/.clikae-tank"
  run clikae tanks
  [ "$status" -eq 0 ]
  [[ "$output" == *"trailing"* ]] || { echo "$output"; false; }
}

@test "a marker naming a DIFFERENT engine is still correctly rejected (exact match not loosened)" {
  clikae init claude wrongeng
  printf 'codex\n' > "$CLIKAE_HOME/profiles/claude/wrongeng/.clikae-tank"
  run clikae tanks
  [ "$status" -eq 0 ]
  [[ "$output" != *"wrongeng"* ]] || { echo "wrongly listed: $output"; false; }
}

# --- #61 round-4 P3-3: the round-3 cat->read builtin change narrowed the
# marker comparison from the WHOLE FILE to just its FIRST LINE. Documented
# (CHANGELOG.md, docs/usage.md) rather than restored, since every marker
# clikae itself writes is exactly one line — this pins down the chosen
# semantics against the two inputs the round-4 review used to demonstrate it.

@test "#61 round-4 P3-3: a marker with garbage after the first line still names a tank (first-line semantics, documented)" {
  clikae init claude multiline
  printf 'claude\nJUNK\n' > "$CLIKAE_HOME/profiles/claude/multiline/.clikae-tank"
  run clikae tanks
  [ "$status" -eq 0 ]
  [[ "$output" == *"multiline"* ]] || { echo "$output"; false; }
}

@test "#61 round-4 P3-3: a 200 KB marker still names a tank, and reading it stays cheap (bounded to the first line, not the whole file)" {
  clikae init claude bigmarker
  { printf 'claude\n'; head -c 200000 /dev/zero | tr '\0' 'x'; echo; } \
    > "$CLIKAE_HOME/profiles/claude/bigmarker/.clikae-tank"
  run clikae tanks
  [ "$status" -eq 0 ]
  [[ "$output" == *"bigmarker"* ]] || { echo "$output"; false; }
}
