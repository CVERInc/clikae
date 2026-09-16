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

# _adopt_warned_value <clikae_home> -> the exported dedupe value a clikae that
# warned about that store right now hands to everything it forks or execs.
_adopt_warned_value() {
  CLIKAE_HOME="$1" bash -c '
    CLIKAE_LIB="'"$CLIKAE_TEST_ROOT"'/lib"
    source "$CLIKAE_LIB/core/log.sh"
    source "$CLIKAE_LIB/core/adapter_loader.sh"
    source "$CLIKAE_LIB/core/profile_store.sh"
    unset _CLIKAE_ADOPT_WARNED
    _tank_adoption_warn_once 2>/dev/null
    printf "%s" "$_CLIKAE_ADOPT_WARNED"'
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

# --- #61 round-5 P3-4: every line `doctor --adopt` prints must either BE a
# command that works, or say plainly that no command does. Round 4 printed
# `clikae init <engine> <name> --adopt` for every content-shaped stray,
# including the two kinds `init` can never accept — and reconstructed the
# name with `awk '{print $1}'`, which cut `claude/my tank` to `claude/my`
# and named a different, real directory. This test EXECUTES what it is told.
@test "#61 round-5 P3-4: doctor --adopt prints only commands that work; unadoptable names are named, not commanded" {
  clikae init claude real --no-template
  local d
  for d in "hello.lock" "my tank" "my" "two"; do
    mkdir -p "$CLIKAE_HOME/profiles/claude/$d"
    printf '{"stub":true}\n' > "$CLIKAE_HOME/profiles/claude/$d/.claude.json"
  done

  run clikae doctor --adopt
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The two shapes `init --adopt` refuses are described, never commanded.
  [[ "$output" != *"clikae init claude hello.lock --adopt"* ]] || \
    { echo "commanded a lock-shaped adopt: $output"; false; }
  [[ "$output" == *"claude/hello.lock — a lock/sidecar-suffixed name can never be a tank"* ]] || { echo "$output"; false; }
  [[ "$output" == *"claude/my tank — that name can never be a tank"* ]] || \
    { echo "the name with a space was not reported whole: $output"; false; }
  # `claude/my` is a REAL, adoptable directory of its own — it must appear
  # once, on its own account, not as the truncation of `claude/my tank`.
  [ "$(printf '%s\n' "$output" | grep -c -- 'clikae init claude my --adopt')" -eq 1 ] || \
    { echo "$output"; false; }

  # Now run every command it printed, exactly as printed.
  local line n=0
  while IFS= read -r line; do
    n=$(( n + 1 ))
    run $line
    [ "$status" -eq 0 ] || { echo "suggested command failed: $line"$'\n'"$output"; false; }
  done < <(printf '%s\n' "$output" | grep -o 'clikae init claude [A-Za-z0-9._-]* --adopt')
  [ "$n" -eq 2 ] || { echo "expected 2 runnable suggestions, got $n"; false; }
  [ -f "$CLIKAE_HOME/profiles/claude/my/.clikae-tank" ]
  [ -f "$CLIKAE_HOME/profiles/claude/two/.clikae-tank" ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/hello.lock/.clikae-tank" ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/my tank/.clikae-tank" ]
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

# --- #61 round-5 P3-5: a brand-new store's FIRST command closes the adoption
# window by itself. bin/clikae's hoist runs before profiles/ exists and bails
# without writing the flag (correctly: three burn.bats tests require a refusal
# to create no state at all), so `clikae init` used to leave the window open
# until the SECOND clikae command — and anything that appeared in between was
# swept up as a real tank, which is round-1 P1-3's `mkdir zzempty` verbatim.
@test "#61 round-5 P3-5: the first init on a brand-new store writes the flag; a directory appearing after it is not a tank" {
  rm -rf "$CLIKAE_HOME"          # no store at all, not even the helpers' stamps
  run clikae init claude a --no-template
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$CLIKAE_HOME/state/tanks-adopted-v1" ] || \
    { echo "first init left the adoption window open"; ls -la "$CLIKAE_HOME/state" 2>&1; false; }

  mkdir -p "$CLIKAE_HOME/profiles/claude/zz"     # an outside process, in the old window
  run clikae tanks
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"a"* ]] || { echo "$output"; false; }
  [[ "$output" != *"zz"* ]] || { echo "post-init directory adopted: $output"; false; }
  [ ! -e "$CLIKAE_HOME/profiles/claude/zz/.clikae-tank" ]
}

# --- #61 round-5 P3-1: the read-only-store warning leaves NOTHING behind on
# any path, and one user action prints exactly one line. Rounds 3-4 deduped
# through a sentinel FILE in $TMPDIR removed by an EXIT trap; bash runs no
# EXIT trap on `exec`, so every launch path left one behind and the exec'd
# process (a new pid = a new sentinel name) warned all over again. The
# dedupe is an exported variable now — nothing to clean up, inherited by
# both forks and execs. ------------------------------------------------------
@test "adoption warn: one WARN line and NO file left behind in TMPDIR" {
  _unadopt
  mkdir -p "$CLIKAE_HOME/profiles/claude/ro1"
  chmod a-w "$CLIKAE_HOME/profiles/claude/ro1" "$CLIKAE_HOME/state" 2>/dev/null || true

  local fake_tmp="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$fake_tmp"
  local out="$BATS_TEST_TMPDIR/out" err="$BATS_TEST_TMPDIR/err" rc=0
  TMPDIR="$fake_tmp" "$CLIKAE_BIN" tanks >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || { cat "$err"; false; }
  [ "$(grep -c '\[ WARN \]' "$err")" -eq 1 ] || { echo "stderr: $(cat "$err")"; false; }
  # No file of any kind: the private TMPDIR must come out exactly as empty as
  # it went in, with no trap having had to run for that to be true.
  [ -z "$(ls -A "$fake_tmp")" ] || { echo "left behind: $(ls -la "$fake_tmp")"; false; }

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

@test "#61 round-4 P2-1: --version on a writable store forks neither ps nor date" {
  _stub_ps_date_counters
  run clikae --version
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/ps.calls" ] || { echo "ps called: $(cat "$BATS_TEST_TMPDIR/ps.calls")"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/date.calls" ] || { echo "date called: $(cat "$BATS_TEST_TMPDIR/date.calls")"; false; }
}

# #61 round-5 P3-1: round 4 forked `ps` once here, to key the sentinel file's
# NAME to this process's start time. With no file to name, a read-only store
# costs the same zero forks a writable one does.
@test "#61 round-5 P3-1: --version on a read-only store forks neither ps nor date either" {
  _unadopt
  mkdir -p "$CLIKAE_HOME/profiles/claude/ro5"
  chmod a-w "$CLIKAE_HOME/profiles/claude/ro5" "$CLIKAE_HOME/state" 2>/dev/null || true
  _stub_ps_date_counters
  run clikae --version
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/ps.calls" ] || { echo "ps called: $(cat "$BATS_TEST_TMPDIR/ps.calls")"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/date.calls" ] || { echo "date called: $(cat "$BATS_TEST_TMPDIR/date.calls")"; false; }
  chmod u+w "$CLIKAE_HOME/profiles/claude/ro5" "$CLIKAE_HOME/state" 2>/dev/null || true
}

@test "adoption warn dedupe: one line per process AND inherited by every fork and exec (#61 round-5 P3-1)" {
  # White-box. The dedupe must survive the two things a trap-cleaned file
  # could not: a forked child (`clikae` calling `clikae`) and an `exec`,
  # which replaces the image without running any EXIT trap at all.
  run bash -c '
    set -e
    CLIKAE_ROOT="'"$CLIKAE_TEST_ROOT"'"; CLIKAE_LIB="$CLIKAE_ROOT/lib"
    source "$CLIKAE_LIB/core/log.sh"
    source "$CLIKAE_LIB/core/adapter_loader.sh"
    source "$CLIKAE_LIB/core/profile_store.sh"
    _tank_adoption_warn_once            # 1 line
    _tank_adoption_warn_once            # same frame: silent
    ( _tank_adoption_warn_once )        # subshell: silent
    x="$(_tank_adoption_warn_once)"     # command substitution: silent
    bash -c "source \"$CLIKAE_LIB/core/log.sh\"; source \"$CLIKAE_LIB/core/profile_store.sh\"; _tank_adoption_warn_once"   # fork: silent
    exec bash -c "source \"$CLIKAE_LIB/core/log.sh\"; source \"$CLIKAE_LIB/core/profile_store.sh\"; _tank_adoption_warn_once"  # exec: silent
  ' 2>&1
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | grep -c 'WARN')" -eq 1 ] || { echo "$output"; false; }
}

@test "#61 round-6 P3-2: the warn dedupe is keyed by STORE — a second read-only store still gets its line" {
  # The exported flag used to be a bare `1`, keyed by nothing: a terminal
  # warned about store A then said nothing about an unrelated store B (a
  # mounted shared store, CLIKAE_HOME=/mnt/…) — so nobody was told that B's
  # answers were memory-only too.
  local A="$BATS_TEST_TMPDIR/storeA" B="$BATS_TEST_TMPDIR/storeB" s
  for s in "$A" "$B"; do
    mkdir -p "$s/.clikae/state" "$s/.clikae/profiles/claude/x"
    printf 'claude\n' > "$s/.clikae/profiles/claude/x/.clikae-tank"
    chmod a-w "$s/.clikae/state"
  done
  local a1 b1 a2 akey
  a1="$(CLIKAE_HOME="$A/.clikae" "$CLIKAE_BIN" tanks 2>&1 >/dev/null | grep -c 'WARN')" || true
  # Exactly what an exec'd/forked clikae would carry forward from that run.
  akey="$(_adopt_warned_value "$A/.clikae")"
  b1="$(_CLIKAE_ADOPT_WARNED="$akey" \
        CLIKAE_HOME="$B/.clikae" "$CLIKAE_BIN" tanks 2>&1 >/dev/null | grep -c 'WARN')" || true
  a2="$(_CLIKAE_ADOPT_WARNED="$akey" \
        CLIKAE_HOME="$A/.clikae" "$CLIKAE_BIN" tanks 2>&1 >/dev/null | grep -c 'WARN')" || true
  for s in "$A" "$B"; do chmod u+w "$s/.clikae/state"; done
  [ "$a1" -eq 1 ] || { echo "store A first run: $a1 WARN"; false; }
  [ "$b1" -eq 1 ] || { echo "store B silenced by store A's key: $b1 WARN"; false; }
  [ "$a2" -eq 0 ] || { echo "store A warned again despite its own key: $a2 WARN"; false; }
}

@test "#61 round-6 P3-3: the read-only adoption flag is INTERNAL and means exactly 1" {
  # One setter (lib/hooks/cockpit-guard.sh) and one reader
  # (_tank_adoption_ensure). Under its old public-looking name, tested with
  # `[ -n … ]`, anything in the environment called CLIKAE_ADOPT_READONLY — `0`
  # included — made every clikae command re-sweep, write no marker and no
  # flag, and say nothing: the one-time adoption window never closed again.
  local s
  for s in old zero one; do
    mkdir -p "$BATS_TEST_TMPDIR/$s/.clikae/profiles/claude/a1"
  done
  CLIKAE_ADOPT_READONLY=1 CLIKAE_HOME="$BATS_TEST_TMPDIR/old/.clikae" "$CLIKAE_BIN" tanks >/dev/null 2>&1
  _CLIKAE_ADOPT_READONLY=0 CLIKAE_HOME="$BATS_TEST_TMPDIR/zero/.clikae" "$CLIKAE_BIN" tanks >/dev/null 2>&1
  _CLIKAE_ADOPT_READONLY=1 CLIKAE_HOME="$BATS_TEST_TMPDIR/one/.clikae" "$CLIKAE_BIN" tanks >/dev/null 2>&1
  # the old public name is inert now: the store lands as it always should
  [ -f "$BATS_TEST_TMPDIR/old/.clikae/state/tanks-adopted-v1" ] || { echo "old name still suppresses the flag"; false; }
  [ -f "$BATS_TEST_TMPDIR/old/.clikae/profiles/claude/a1/.clikae-tank" ] || { echo "old name still suppresses the marker"; false; }
  # `0` means off
  [ -f "$BATS_TEST_TMPDIR/zero/.clikae/state/tanks-adopted-v1" ] || { echo "=0 was read as ON"; false; }
  [ -f "$BATS_TEST_TMPDIR/zero/.clikae/profiles/claude/a1/.clikae-tank" ] || { echo "=0 was read as ON"; false; }
  # and the real internal name still works, for the hook
  [ ! -e "$BATS_TEST_TMPDIR/one/.clikae/state/tanks-adopted-v1" ] || { echo "=1 no longer holds off"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/one/.clikae/profiles/claude/a1/.clikae-tank" ] || { echo "=1 no longer holds off"; false; }
}

@test "#61 round-6 P3-1: an unreadable marker is one WARN and a COMPLETE list, never a raw shell error" {
  if [ "$(id -u)" = "0" ]; then skip "root reads a mode-000 file"; fi
  local t
  for t in a1 b2 c3; do
    mkdir -p "$CLIKAE_HOME/profiles/claude/$t"
    printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/$t/.clikae-tank"
  done
  chmod 000 "$CLIKAE_HOME/profiles/claude/b2/.clikae-tank"
  local out err rc=0
  out="$BATS_TEST_TMPDIR/o"; err="$BATS_TEST_TMPDIR/e"
  "$CLIKAE_BIN" tanks > "$out" 2> "$err" || rc=$?
  chmod 644 "$CLIKAE_HOME/profiles/claude/b2/.clikae-tank" 2>/dev/null || true
  [ "$rc" -eq 0 ] || { cat "$err"; false; }
  # the walk is NOT truncated at b2 — c3 sorts after it
  grep -q ' a1 ' "$out" || grep -qw a1 "$out" || { cat "$out"; false; }
  grep -qw c3 "$out" || { echo "list truncated at the unreadable marker:"; cat "$out"; false; }
  grep -qw b2 "$out" && { echo "an unreadable marker must not name a tank:"; cat "$out"; false; }
  # exactly one warning line, and never a raw shell error (CHANGELOG's promise)
  [ "$(grep -c 'WARN' "$err")" -eq 1 ] || { cat "$err"; false; }
  ! grep -q 'profile_store.sh: line' "$err" || { cat "$err"; false; }
  ! grep -q 'unbound variable' "$err" || { cat "$err"; false; }
}

@test "#61 round-6 P3-1: list_all_profiles under \`set -u\` returns a COMPLETE list whatever position is unreadable" {
  if [ "$(id -u)" = "0" ]; then skip "root reads a mode-000 file"; fi
  # White-box, the hook's own shape: `set -u`, this file sourced without
  # log.sh. The enumerator used to abort at the unreadable tank and return
  # everything BEFORE it with rc 0 — a silently truncated answer.
  local t
  for t in a1 b2 c3 d4; do
    mkdir -p "$CLIKAE_HOME/profiles/claude/$t"
    printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/$t/.clikae-tank"
  done
  local which got
  for which in a1 b2 d4; do
    chmod 644 "$CLIKAE_HOME"/profiles/claude/*/.clikae-tank
    chmod 000 "$CLIKAE_HOME/profiles/claude/$which/.clikae-tank"
    got="$(bash -c '
      set -uo pipefail
      CLIKAE_ROOT="'"$CLIKAE_TEST_ROOT"'"; CLIKAE_LIB="$CLIKAE_ROOT/lib"
      source "$CLIKAE_LIB/core/adapter_loader.sh"
      source "$CLIKAE_LIB/core/profile_store.sh"
      list_all_profiles | cut -f2 | tr "\n" " "' 2>&1)"
    chmod 644 "$CLIKAE_HOME"/profiles/claude/*/.clikae-tank
    case "$got" in
      *"unbound variable"*|*"Permission denied"*) echo "$which: $got"; false ;;
    esac
    # every tank except the unreadable one, in sorted order, nothing dropped
    local want=""
    for t in a1 b2 c3 d4; do [ "$t" = "$which" ] || want="$want$t "; done
    [ "$got" = "$want" ] || { echo "$which unreadable -> got [$got] want [$want]"; false; }
  done
}

@test "adoption warn: launching a tank on a read-only store warns ONCE and leaves TMPDIR empty (#61 round-5 P3-1)" {
  # The launch family the round-5 review measured: `clikae <engine> <tank>`
  # ends in an `exec` into the engine. stdin/stdout are not TTYs under bats,
  # so this takes the no-tmux path and execs directly — exactly the shape
  # that no EXIT trap can ever clean up after.
  clikae init claude rolaunch --no-template
  cat > "$TEST_HOME/.testbin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${_CLIKAE_ADOPT_WARNED:-unset}" > "${HOME:?}/engine-saw-warned"
ls -A "${TMPDIR:-/tmp}" > "${HOME:?}/engine-saw-tmpdir"
STUB
  chmod +x "$TEST_HOME/.testbin/claude"
  _unadopt
  chmod a-w "$CLIKAE_HOME/state" 2>/dev/null || true

  local fake_tmp="$BATS_TEST_TMPDIR/tmp2"; mkdir -p "$fake_tmp"
  local err="$BATS_TEST_TMPDIR/err2" rc=0
  TMPDIR="$fake_tmp" "$CLIKAE_BIN" claude rolaunch >/dev/null 2>"$err" || rc=$?
  chmod u+w "$CLIKAE_HOME/state" 2>/dev/null || true
  [ "$rc" -eq 0 ] || { cat "$err"; false; }
  [ -f "$TEST_HOME/engine-saw-warned" ] || { echo "engine never ran: $(cat "$err")"; false; }
  # #61 round-6 P3-2: the dedupe carries a SET OF STORE KEYS now, not `1`, so
  # the assertion is that THIS store's key crossed the exec — a boolean would
  # also have silenced every other store (that is the finding).
  grep -Fq "$CLIKAE_HOME/state/tanks-adopted-v1" "$TEST_HOME/engine-saw-warned" || \
    { echo "engine did not inherit the dedupe: $(cat "$TEST_HOME/engine-saw-warned")"; false; }
  [ "$(grep -c '\[ WARN \]' "$err")" -eq 1 ] || { echo "stderr: $(cat "$err")"; false; }
  # Nothing left behind — checked both by the engine, while it was the live
  # process, and from here afterwards.
  [ -z "$(cat "$TEST_HOME/engine-saw-tmpdir")" ] || \
    { echo "engine saw: $(cat "$TEST_HOME/engine-saw-tmpdir")"; false; }
  [ -z "$(ls -A "$fake_tmp")" ] || { echo "left behind: $(ls -la "$fake_tmp")"; false; }
}

@test "#114: an engine that inherited the warn dedupe is quiet about the SAME store and warns again once the store changed" {
  # The exported key used to be the flag PATH only, so an engine session (or a
  # tmux pane, or a burn) started from a clikae that had warned stayed silent
  # about whatever store sat at that path afterwards — a store put back from a
  # backup, or repaired and read-only again, is a new fact and got no line.
  if [ "$(id -u)" = "0" ]; then skip "root writes a read-only directory"; fi
  clikae init claude rochange --no-template
  cat > "$TEST_HOME/.testbin/claude" <<STUB
#!/usr/bin/env bash
S="\$CLIKAE_HOME/state"
printf '%s\n' "\${_CLIKAE_ADOPT_WARNED:-unset}" > "\$HOME/engine-saw-warned"
"$CLIKAE_BIN" tanks 2>&1 >/dev/null | grep -c 'WARN' > "\$HOME/warn-unchanged"
# the store is replaced at the same path (a restored backup), still read-only
chmod u+w "\$S"; mv "\$S" "\$S.prev"; mkdir "\$S"; cp -R "\$S.prev/." "\$S/"; chmod a-w "\$S"
"$CLIKAE_BIN" tanks 2>&1 >/dev/null | grep -c 'WARN' > "\$HOME/warn-changed"
chmod u+w "\$S"
exit 0
STUB
  chmod +x "$TEST_HOME/.testbin/claude"
  _unadopt
  chmod a-w "$CLIKAE_HOME/state"
  local err="$BATS_TEST_TMPDIR/err" rc=0
  "$CLIKAE_BIN" claude rochange >/dev/null 2>"$err" || rc=$?
  chmod u+w "$CLIKAE_HOME/state" 2>/dev/null || true
  [ "$rc" -eq 0 ] || { cat "$err"; false; }
  [ "$(grep -c '\[ WARN \]' "$err")" -eq 1 ] || { echo "launch: $(cat "$err")"; false; }
  # the key the engine inherited still dedupes while the store is the one it was about
  [ "$(cat "$TEST_HOME/warn-unchanged")" -eq 0 ] || { echo "unchanged store warned again"; false; }
  # ...and no longer matches once the store changed: that store gets its line
  [ "$(cat "$TEST_HOME/warn-changed")" -eq 1 ] || \
    { echo "changed store: $(cat "$TEST_HOME/warn-changed") WARN; engine env: $(cat "$TEST_HOME/engine-saw-warned")"; false; }
  # (and it was this store's key that crossed the exec, not a boolean)
  grep -Fq "$CLIKAE_HOME/state/tanks-adopted-v1@" "$TEST_HOME/engine-saw-warned" || \
    { echo "engine env: $(cat "$TEST_HOME/engine-saw-warned")"; false; }
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

# --- #61 round-5 P3-3: the test above says "stays cheap" and asserts no such
# thing, and the shape it uses is the cheap one (a short first line). The
# expensive shape is a LONG FIRST LINE: `claude` followed by trailing
# whitespace made the tolerant strip quadratic — measured 0.07s at 1,000
# spaces, 3.5s at 8,000, 13.9s at 16,000 (x4 per doubling, bash 5.2 and bash
# 3.2 alike), i.e. `clikae tanks` silently hanging on a store it can list
# perfectly well. The read is bounded to 64 characters now; this is the ruler
# that says so, in wall-clock seconds rather than adjectives.
@test "#61 round-5 P3-3: a marker with 16 KB of trailing whitespace still names a tank, in bounded time" {
  clikae init claude fatmarker
  clikae init claude normal
  { printf 'claude'; head -c 16000 /dev/zero | tr '\0' ' '; echo; } \
    > "$CLIKAE_HOME/profiles/claude/fatmarker/.clikae-tank"
  local start end elapsed
  start="$(date +%s)"
  run clikae tanks
  end="$(date +%s)"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"fatmarker"* ]] || { echo "trailing whitespace lost the tank: $output"; false; }
  [[ "$output" == *"normal"* ]] || { echo "$output"; false; }
  elapsed=$(( end - start ))
  # Linear: ~30ms on the round-5 review's host. The pre-fix quadratic was
  # 13.9 SECONDS for this exact marker, so a bound of 10 tells the two apart
  # by a wide margin even on a loaded CI box.
  [ "$elapsed" -lt 10 ] || { echo "clikae tanks took ${elapsed}s on a 16 KB marker"; false; }
}

@test "#61 round-5 P3-3: a marker whose first line is longer than the bound is not a tank, and costs nothing to reject" {
  clikae init claude longline
  { head -c 200000 /dev/zero | tr '\0' 'x'; echo; } \
    > "$CLIKAE_HOME/profiles/claude/longline/.clikae-tank"
  local start end
  start="$(date +%s)"
  run clikae tanks
  end="$(date +%s)"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"longline"* ]] || { echo "a 200 KB first line is not an engine name: $output"; false; }
  [ $(( end - start )) -lt 10 ] || { echo "rejecting a 200 KB first line took $(( end - start ))s"; false; }
}
