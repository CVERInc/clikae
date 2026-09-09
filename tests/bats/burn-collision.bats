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
  local lock; lock="$(_burn_tank_lock_path codex LOCKT1)"
  local held; held="$(readlink "$lock")"
  [ "${held%%:*}" = "$$" ] || false

  # A second acquire, while this shell still holds the lock, must time out
  # rather than succeed — prove the lock is actually exclusive, not just
  # advisory-by-convention.
  run _burn_tank_lock_acquire codex LOCKT1 2
  [ "$status" -eq 1 ] || { echo "$output"; false; }

  _burn_tank_lock_release codex LOCKT1
  [[ ! -L "$lock" ]] || false

  # Now that it's released, a fresh acquire succeeds immediately.
  run _burn_tank_lock_acquire codex LOCKT1 2
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

_dead_pid() {
  ( exit 0 ) &
  local p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}

@test "_burn_tank_lock_acquire: a lock left by a DEAD holder is reclaimed, not stuck forever" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKT2)"
  mkdir -p "$(dirname "$lock")"
  ln -s "$(_dead_pid):1" "$lock"

  local t0=$SECONDS
  run _burn_tank_lock_acquire codex LOCKT2 5
  local elapsed=$((SECONDS - t0))
  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 5 ] || false   # reclaimed promptly, not stuck to the timeout
}

# --- R3-P1-1/R3-P1-2/R3-P2-1/R3-P2-2 (2026-09-09 round-3 review) -----------
#
# Round 2's fix for the race below ("two contenders racing a DEAD-holder
# lock — exactly one ever wins (5 trials)") was GREEN over a live mutual-
# exclusion failure the round-3 review measured at 48% of trials. Three
# independent reasons, all fixed here rather than patched around:
#
#   (a) Its two contenders were `( … ) &` SUBSHELLS OF THE SAME BATS SHELL,
#       so `$$` — and therefore every identity the lock or a `mv`-based
#       reclaim's graveyard name derived from it — was IDENTICAL across the
#       "two" things it claimed to be racing. A fixture that can't tell its
#       two doubles apart in the one field the mechanism uses for identity
#       cannot detect a mechanism that gets that field wrong.
#   (b) The winner never released, so a loser could never observe a SECOND
#       stale generation — exactly the state every real violation passes
#       through (one contender's reclaim succeeding, a second contender
#       then racing the FRESH lock the first one just planted).
#   (c) Two contenders is not enough. The interleaving that broke round 2
#       needs a THIRD identity in the mix (one process vacating the path
#       while a second restores and a third claims the gap) — reproduced by
#       the review with 4, not 2.
#
# Rewritten below: each contender is a real, separate PROCESS (`bash -c`,
# so `$$` genuinely differs — not a subshell of this bats shell), released
# together off a barrier file so they actually overlap, at least 4 per
# trial, against a pre-seeded stale (dead-pid) lock. A successful acquirer
# must also win an INDEPENDENT witness mutex (`mkdir`) before it may count
# itself a winner — if that `mkdir` fails, some OTHER contender is already
# inside the critical section, which is the thing round 2's green test
# could not observe even though it was happening.

# A `cat` that reads immediately but SLEEPS before returning, on PATH ahead
# of the real one — widens exactly the window between "I decided the holder
# is dead" and "I act on that decision", the same window the round-2 AND
# round-3 reviews both used to make the underlying races land reliably on
# demand. `command cat` still walks $PATH (it only skips shell
# functions/aliases), so a wrapper installed AHEAD of the real `cat` under
# the same name that tried `command cat` would find ITSELF again —
# infinite self-recursion, not a slow read. Resolve the real binary's
# absolute path NOW, before $PATH is ever reordered, and bake that path in.
_install_slow_cat() {
  local bin="$BATS_TEST_TMPDIR/slowcat" real_cat
  real_cat="$(command -v cat)"
  mkdir -p "$bin"
  cat > "$bin/cat" <<STUB
#!/usr/bin/env bash
out="\$("$real_cat" "\$@")"
sleep 1
printf '%s' "\$out"
STUB
  chmod +x "$bin/cat"
  printf '%s' "$bin"
}

# _race_contender <tank> <barrier> <witness> <won-file> <slow 0|1> <slowcat_bin> <hold_s>
# Launches ONE real background process (not a subshell of this shell) that
# waits for <barrier> to appear, then calls the REAL, sourced
# _burn_tank_lock_acquire against <tank>. On success it immediately races
# every other winner for <witness> (`mkdir`, atomic) — the loser of THAT
# race writes "<won-file>.violation" instead of "<won-file>", which is how a
# genuine mutual-exclusion failure (two processes both inside the critical
# section at once) is told apart from ordinary sequential hand-off. The
# winner then HOLDS both the witness and the tank lock for <hold_s> (doing
# nothing — standing in for real critical-section work) before releasing
# both — without a hold, a winner that returns instantly can't be caught
# overlapping anyone, which is a property of THIS TEST, not of the lock.
# Sets $! to the new process's pid, as `&` always does.
_race_contender() {
  local tank="$1" barrier="$2" witness="$3" won="$4" slow="$5" slowcat_bin="$6" hold_s="$7"
  bash -c '
    root="$1"; tank="$2"; barrier="$3"; witness="$4"; won="$5"; slow="$6"; slowcat_bin="$7"; hold_s="$8"
    if [ "$slow" = 1 ]; then PATH="$slowcat_bin:$PATH"; fi
    # shellcheck source=/dev/null
    . "$root/lib/core/log.sh"
    . "$root/lib/core/json.sh"
    . "$root/lib/core/burn_status.sh"
    . "$root/lib/core/duration.sh"
    . "$root/lib/commands/antigravity.sh"
    . "$root/lib/commands/burn.sh"
    while [ ! -f "$barrier" ]; do sleep 0.1; done
    if _burn_tank_lock_acquire codex "$tank" 5; then
      if mkdir "$witness" 2>/dev/null; then
        : > "$won"
        sleep "$hold_s"
        rmdir "$witness" 2>/dev/null
      else
        printf "VIOLATION\n" > "${won}.violation"
      fi
      _burn_tank_lock_release codex "$tank"
    fi
  ' _ "$CLIKAE_TEST_ROOT" "$tank" "$barrier" "$witness" "$won" "$slow" "$slowcat_bin" "$hold_s" &
}

# WIN can legitimately be >1 per trial here (releasing means a SECOND
# contender can cleanly take the SAME tank after the first hands it back —
# that's ordinary sequential access, not a defect). What must be exactly
# zero is VIOLATION (two processes both held the witness — the mutual-
# exclusion failure this whole file exists to catch) and a LEAKED lock
# (the symlink still present after every contender has finished, which is
# how R3-P1-2's nesting bug showed up: a lock that never became empty
# again).
@test "_burn_tank_lock_acquire (R3-P2-2): 4 independent processes racing a DEAD-holder lock — 0 violations, 0 leaks, 20 trials" {
  _src_burn_lock
  local slowcat_bin; slowcat_bin="$(_install_slow_cat)"
  local trials=20 contenders=4 hold_s=0.3
  local trial violations=0 leaked=0 wins_total=0
  for trial in $(seq 1 "$trials"); do
    local tank="RACE$trial"
    local lock; lock="$(_burn_tank_lock_path codex "$tank")"
    mkdir -p "$(dirname "$lock")"
    ln -s "$(_dead_pid):1" "$lock"

    local barrier="$BATS_TEST_TMPDIR/barrier-$trial" witness="$BATS_TEST_TMPDIR/witness-$trial"
    rm -f "$barrier"; rm -rf "$witness"
    local -a pids=()
    local i won
    for i in $(seq 1 "$contenders"); do
      won="$BATS_TEST_TMPDIR/won-$trial-$i"
      rm -f "$won" "$won.violation"
      local slow=0; [ "$i" -eq 1 ] && slow=1
      _race_contender "$tank" "$barrier" "$witness" "$won" "$slow" "$slowcat_bin" "$hold_s"
      pids+=("$!")
    done
    : > "$barrier"   # release all 4 together
    local p
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

    for i in $(seq 1 "$contenders"); do
      won="$BATS_TEST_TMPDIR/won-$trial-$i"
      [ -f "$won" ] && wins_total=$((wins_total + 1))
      [ -f "$won.violation" ] && violations=$((violations + 1))
    done
    if [ -L "$lock" ] || [ -e "$lock" ]; then
      echo "trial $trial: lock still present after every contender finished — leaked"
      leaked=$((leaked + 1))
    fi
  done
  echo "trials=$trials contenders=$contenders wins=$wins_total violations=$violations leaked_locks=$leaked"
  [ "$violations" -eq 0 ] || false
  [ "$leaked" -eq 0 ] || false
}

@test "_burn_tank_lock_acquire (R3-P2-2 control): same harness with NO stale lock pre-seeded — 0 violations, 0 leaks, 8 trials" {
  _src_burn_lock
  local trials=8 contenders=4 hold_s=0.3
  local trial violations=0 leaked=0 wins_total=0
  for trial in $(seq 1 "$trials"); do
    local tank="RACECTL$trial"
    # No pre-seeded lock at all here (unlike the arm above) — this proves
    # the harness isn't rigged to report "0 violations" regardless of what
    # it's pointed at; it's a normal, uncontended free-for-all on a path
    # nothing occupies yet.
    local lock; lock="$(_burn_tank_lock_path codex "$tank")"
    local barrier="$BATS_TEST_TMPDIR/ctl-barrier-$trial" witness="$BATS_TEST_TMPDIR/ctl-witness-$trial"
    rm -f "$barrier"; rm -rf "$witness"
    local -a pids=()
    local i won
    for i in $(seq 1 "$contenders"); do
      won="$BATS_TEST_TMPDIR/ctl-won-$trial-$i"
      rm -f "$won" "$won.violation"
      _race_contender "$tank" "$barrier" "$witness" "$won" 0 "" "$hold_s"
      pids+=("$!")
    done
    : > "$barrier"
    local p
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
    for i in $(seq 1 "$contenders"); do
      won="$BATS_TEST_TMPDIR/ctl-won-$trial-$i"
      [ -f "$won" ] && wins_total=$((wins_total + 1))
      [ -f "$won.violation" ] && violations=$((violations + 1))
    done
    if [ -L "$lock" ] || [ -e "$lock" ]; then
      echo "control trial $trial: lock still present after every contender finished — leaked"
      leaked=$((leaked + 1))
    fi
  done
  echo "control trials=$trials wins=$wins_total violations=$violations leaked_locks=$leaked"
  [ "$violations" -eq 0 ] || false
  [ "$leaked" -eq 0 ] || false
}

@test "_burn_tank_lock_acquire: a non-symlink leftover at the lock path (pre-round-3 directory-style lock) is reclaimed, not stuck forever" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKLEGACY)"
  mkdir -p "$lock"   # as an old, pre-round-3 directory-style lock would leave behind

  local t0=$SECONDS
  run _burn_tank_lock_acquire codex LOCKLEGACY 5
  local elapsed=$((SECONDS - t0))
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$elapsed" -lt 5 ] || false
  [[ -L "$lock" ]] || false   # and it's now genuinely OUR symlink, not the old directory
}

@test "_burn_tank_lock_acquire: a lock whose pid is alive but RECYCLED (marker predates the pid's own start) is still reclaimed" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKRECYCLED)"
  mkdir -p "$(dirname "$lock")"
  sleep 60 &
  local live_pid=$!
  ln -s "$live_pid:1" "$lock"   # 1970 — this genuinely-alive pid started decades later

  local t0=$SECONDS
  run _burn_tank_lock_acquire codex LOCKRECYCLED 5
  local elapsed=$((SECONDS - t0))
  kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$elapsed" -lt 5 ] || false
}

@test "_burn_tank_lock_acquire: a LIVE holder's lock is never stolen, even by several simultaneous contenders" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKLIVE)"
  _burn_tank_lock_acquire codex LOCKLIVE 5   # this shell genuinely holds it
  local held; held="$(readlink "$lock")"
  [ "${held%%:*}" = "$$" ] || false

  local -a pids=()
  local _
  for _ in 1 2 3 4 5; do
    ( _src_burn_lock; _burn_tank_lock_acquire codex LOCKLIVE 2 ) &
    pids+=("$!")
  done
  local p rc rc_sum=0
  for p in "${pids[@]}"; do
    if wait "$p" 2>/dev/null; then rc=0; else rc=$?; fi
    rc_sum=$((rc_sum + rc))
  done
  # every one of the 5 must time out (rc 1) — none may ever acquire a lock a
  # live holder still owns.
  [ "$rc_sum" -eq 5 ] || { echo "at least one contender wrongly acquired a LIVE holder's lock"; false; }
  held="$(readlink "$lock")"
  [ "${held%%:*}" = "$$" ] || false   # and OUR copy was never touched

  _burn_tank_lock_release codex LOCKLIVE
}

# R3-P2-1 arm: round 2's pid-less grace could steal a legitimate holder's
# lock if that holder merely stalled between claiming the path and writing
# its identity into it — reachable from ordinary fork/subshell lag, not
# only a kill. The symlink design makes the underlying window structurally
# impossible (pid+started_at are already IN the link the instant it
# exists, so there is nothing separate left to stall on) — this test shows
# the same real-world timing (a holder stalling for seconds under load)
# still cannot displace a live holder, probe included per the review.
@test "_burn_tank_lock_acquire (R3-P2-1 arm): a holder that stalls 3s after acquiring is never displaced" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKSTALL)"
  (
    _src_burn_lock
    _burn_tank_lock_acquire codex LOCKSTALL 10
    sleep 3
    sleep 5
  ) &
  local holder_pid=$!
  sleep 0.3
  [[ -L "$lock" ]] || { echo "lock never appeared"; false; }
  local -a pids=()
  local i
  for i in 1 2 3; do
    ( _src_burn_lock; _burn_tank_lock_acquire codex LOCKSTALL 2 ) &
    pids+=("$!")
  done
  local p rc rc_sum=0
  for p in "${pids[@]}"; do
    if wait "$p" 2>/dev/null; then rc=0; else rc=$?; fi
    rc_sum=$((rc_sum + rc))
  done
  [ "$rc_sum" -eq 3 ] || { echo "a contender wrongly acquired the lock during the holder's stall"; false; }
  kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null || true
}

@test "_burn_tank_lock_acquire/_burn_tank_lock_release: the lock is gone on every exit path — success, a losing timeout, and a trapped signal" {
  _src_burn_lock

  # success
  _burn_tank_lock_acquire codex LOCKEXIT1 5
  _burn_tank_lock_release codex LOCKEXIT1
  [[ ! -L "$(_burn_tank_lock_path codex LOCKEXIT1)" ]] || false

  # a losing timeout must not disturb (or remove) the winner's own lock
  _burn_tank_lock_acquire codex LOCKEXIT2 5
  local lock2; lock2="$(_burn_tank_lock_path codex LOCKEXIT2)"
  local winner_target; winner_target="$(readlink "$lock2")"
  run bash -c ". '$CLIKAE_TEST_ROOT/lib/core/log.sh'; . '$CLIKAE_TEST_ROOT/lib/core/json.sh'; . '$CLIKAE_TEST_ROOT/lib/core/burn_status.sh'; . '$CLIKAE_TEST_ROOT/lib/core/duration.sh'; . '$CLIKAE_TEST_ROOT/lib/commands/antigravity.sh'; . '$CLIKAE_TEST_ROOT/lib/commands/burn.sh'; _burn_tank_lock_acquire codex LOCKEXIT2 1"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [ "$(readlink "$lock2")" = "$winner_target" ] || false
  _burn_tank_lock_release codex LOCKEXIT2
  [[ ! -L "$lock2" ]] || false

  # a signal landing while the SAME trap commands cmd_burn installs around
  # its own check-and-write section are armed must still release the lock —
  # exercised directly (forcing a real SIGTERM to land inside that exact
  # multi-statement window of a real `clikae burn` is not reproducible on
  # demand; the trap commands under test are byte-identical to burn.sh's own).
  (
    _src_burn_lock
    status_engine=codex tank=LOCKEXIT3
    trap '_burn_tank_lock_release "$status_engine" "$tank"; exit 143' TERM
    trap '_burn_tank_lock_release "$status_engine" "$tank"' EXIT
    _burn_tank_lock_acquire "$status_engine" "$tank"
    sleep 5
  ) &
  local bg=$!
  sleep 1
  [[ -L "$(_burn_tank_lock_path codex LOCKEXIT3)" ]] || { echo "lock never appeared"; false; }
  kill -TERM "$bg"
  wait "$bg" 2>/dev/null || true
  [[ ! -L "$(_burn_tank_lock_path codex LOCKEXIT3)" ]] || false
}

@test "_burn_reclaim_mutex_try: a successful claim is a symlink carrying pid:started_at from the instant it exists (R4-P1-1)" {
  # Superseded by R4-P1-1 (2026-09-10 round-4 review): the mutex used to be
  # a 0700 `mkdir`-ed directory with a separate 0600 pid FILE written right
  # after — exactly the two-statement claim-then-identify race the symlink
  # design abolishes one function down. There is no separate pid file any
  # more to check permissions on; what must hold instead is that the mutex
  # itself is a symlink and its payload is present atomically.
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKPERMS)"
  mkdir -p "$(dirname "$lock")"
  local reclaim_link="${lock}.reclaim"
  run _burn_reclaim_mutex_try "$reclaim_link"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ -L "$reclaim_link" ]] || { echo "mutex is not a symlink"; false; }
  local target; target="$(readlink "$reclaim_link")"
  [ "${target%%:*}" = "$$" ] || { echo "mutex target=$target, expected pid $$"; false; }
  case "${target#*:}" in
    ''|*[!0-9]*) echo "mutex started_at not numeric: $target"; false ;;
  esac
  _burn_reclaim_mutex_release "$reclaim_link"
  [[ ! -L "$reclaim_link" ]] || { echo "release left the mutex behind"; false; }
}

# --- R4-P1-1/R4-P1-2/R4-P1-3/R4-P2-1/R4-P2-2/R4-P2-3 (2026-09-10 round-4 review) ---
#
# All three P1s lived in the 17-line reclaim mutex itself, whose failure
# branch had NO test coverage at all (P2-3): a pid-less mutex directory
# (killed between `mkdir` and its separate pid write) was never reaped and
# permanently disabled the tank; a stale reaper's check-then-act could
# destroy a LIVE holder's mutex; and `stat -f` running first on a GNU-stat
# PATH silently disabled the 30s age half of the stale rule. The fix makes
# the mutex a symlink too (identity atomic with claim, like the lock it
# guards) and reaps via rename-to-a-unique-graveyard-then-verify, never a
# blind check-then-act — see the mutex's own header comment above.

@test "_burn_tank_lock_acquire (R4-P1-1a): a pid-less LEGACY reclaim directory does not wedge the tank forever" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKWEDGE1)"
  mkdir -p "$(dirname "$lock")"
  ln -s "$(_dead_pid):1" "$lock"
  mkdir -p "${lock}.reclaim"   # pre-round-4 mkdir-based mutex, never given a pid file

  local t0=$SECONDS
  run _burn_tank_lock_acquire codex LOCKWEDGE1 5
  local elapsed=$((SECONDS - t0))
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$elapsed" -le 2 ] || {
    echo "took ${elapsed}s -- the old bug never reaped a pid-less mutex at all (permanent refusal)"
    false
  }
  [[ ! -e "${lock}.reclaim" ]] || { echo "reclaim mutex leaked"; false; }
  _burn_tank_lock_release codex LOCKWEDGE1
}

@test "_burn_tank_lock_acquire (R4-P1-1b): a pid-less/malformed reclaim SYMLINK does not wedge the tank forever" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKWEDGE2)"
  mkdir -p "$(dirname "$lock")"
  ln -s "$(_dead_pid):1" "$lock"
  ln -s "" "${lock}.reclaim"   # a malformed payload from anywhere must self-heal, same as the pid-less directory above

  local t0=$SECONDS
  run _burn_tank_lock_acquire codex LOCKWEDGE2 5
  local elapsed=$((SECONDS - t0))
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$elapsed" -le 2 ] || { echo "took ${elapsed}s"; false; }
  [[ ! -e "${lock}.reclaim" ]] || { echo "reclaim mutex leaked"; false; }
  _burn_tank_lock_release codex LOCKWEDGE2
}

@test "_burn_tank_lock_acquire (R4-P1-1c): a SECOND, independent burn on a tank that just healed a wedged reclaim mutex also succeeds" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKWEDGE3)"
  mkdir -p "$(dirname "$lock")"
  ln -s "$(_dead_pid):1" "$lock"
  mkdir -p "${lock}.reclaim"
  _burn_tank_lock_acquire codex LOCKWEDGE3 5
  _burn_tank_lock_release codex LOCKWEDGE3

  # The old bug's whole failure mode was "every burn AFTER the first one is
  # refused forever" -- this is the one that must not regress.
  local t0=$SECONDS
  run _burn_tank_lock_acquire codex LOCKWEDGE3 5
  local elapsed=$((SECONDS - t0))
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$elapsed" -lt 2 ] || false
  _burn_tank_lock_release codex LOCKWEDGE3
}

@test "_burn_reclaim_mutex_try (R4-P2-3a): a pid-less/malformed link is reaped on the first try and claimable on the second" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKMX1)"
  mkdir -p "$(dirname "$lock")"
  local reclaim_link="${lock}.reclaim"
  ln -s "" "$reclaim_link"
  run _burn_reclaim_mutex_try "$reclaim_link"
  [ "$status" -eq 1 ] || { echo "$output"; false; }   # reaps, never claims for the caller
  [[ ! -e "$reclaim_link" ]] || { echo "malformed mutex survived the reap attempt"; false; }
  run _burn_reclaim_mutex_try "$reclaim_link"
  [ "$status" -eq 0 ] || { echo "$output"; false; }   # now claimable
  _burn_reclaim_mutex_release "$reclaim_link"
}

@test "_burn_reclaim_mutex_try (R4-P2-3a2): a pre-round-4 LEGACY (non-symlink) reclaim directory is reaped the same way" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKMX2)"
  mkdir -p "$(dirname "$lock")"
  local reclaim_link="${lock}.reclaim"
  mkdir -p "$reclaim_link"
  run _burn_reclaim_mutex_try "$reclaim_link"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ ! -e "$reclaim_link" ]] || { echo "legacy directory survived the reap attempt"; false; }
  run _burn_reclaim_mutex_try "$reclaim_link"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  _burn_reclaim_mutex_release "$reclaim_link"
}

@test "_burn_reclaim_mutex_try (R5-P1-1): a LEGACY directory mutex with a DEAD pid recorded inside it is discarded" {
  # R5-P1-1 (2026-09-10 round-5 review): the non-symlink branch used to
  # discard unconditionally with no liveness test at all. A legacy
  # directory CAN carry an identity the pre-round-3 lock format used: a
  # `pid` file written inside after the `mkdir`. A dead pid there is no
  # different from no pid file at all -- still safe to discard.
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKMX5)"
  mkdir -p "$(dirname "$lock")"
  local reclaim_link="${lock}.reclaim"
  local dead; dead="$(_dead_pid)"
  mkdir -p "$reclaim_link"
  printf '%s' "$dead" > "$reclaim_link/pid"
  run _burn_reclaim_mutex_try "$reclaim_link"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ ! -e "$reclaim_link" ]] || { echo "a legacy directory with a dead recorded pid survived"; false; }
}

@test "_burn_reclaim_mutex_try (R5-P1-1/R6-P1-1): a LEGACY directory whose recorded pid is genuinely alive is left in place, never moved" {
  # A legacy directory whose `pid` file names a pid that is still ALIVE
  # must not be treated as safe-to-discard just because it isn't a symlink.
  # R6-P1-1 (2026-09-10 round-6 review) found the ROUND-5 mechanism for
  # this ("mv it aside unconditionally, then mv it back if it turns out to
  # be alive") itself opened a window where an ordinary caller could claim
  # the mutex while this branch still believed a live holder owned it --
  # the fix classifies BEFORE moving anything, so a genuinely live holder
  # (started at-or-before this directory's own creation, exactly like this
  # fixture's `sleep 300 &`, which starts before the `mkdir` below) is
  # never moved at all: same end state as round 5's "restored" (still a
  # DIRECTORY, same recorded pid), reached without ever vacating the path.
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKMX6)"
  mkdir -p "$(dirname "$lock")"
  local reclaim_link="${lock}.reclaim"
  sleep 300 &
  local live_pid=$!
  mkdir -p "$reclaim_link"
  printf '%s' "$live_pid" > "$reclaim_link/pid"
  run _burn_reclaim_mutex_try "$reclaim_link"
  kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null || true
  [ "$status" -eq 1 ] || { echo "$output"; false; }   # never claims it FOR the caller
  [ -d "$reclaim_link" ] || { echo "a legacy directory with a LIVE recorded pid was destroyed, not left alone"; false; }
  [ -L "$reclaim_link" ] && { echo "wrong shape (symlink instead of directory) -- something moved it"; false; }
  [ "$(cat "$reclaim_link/pid" 2>/dev/null)" = "$live_pid" ] || { echo "pid file changed -- something touched it"; false; }
  rm -rf "$reclaim_link"
}

@test "_burn_reclaim_mutex_try (R6-P1-1): a LEGACY directory whose recorded pid is alive but RECYCLED (started after the directory) is reaped in one call, not kept forever" {
  # The regression round 6 found: round 5's fix judged liveness with a bare
  # `kill -0` -- proof SOMETHING is alive at that pid, never proof it's the
  # SAME process that made the directory. A pid recycled onto a dead
  # holder's number was "restored" and kept FOREVER (fb536ce: 10s timeout
  # on _burn_tank_lock_acquire, no recovery path anywhere in the product).
  # This format never wrote a `started_at` file, so the directory's OWN
  # mtime stands in for it: backdate the directory well into the past, then
  # start a brand-new process AFTER that -- exactly a recycled pid's shape
  # (it necessarily started later than the truly dead original holder did).
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKMX8)"
  mkdir -p "$(dirname "$lock")"
  local reclaim_link="${lock}.reclaim"
  mkdir -p "$reclaim_link"
  sleep 300 &
  local recycled_pid=$!
  printf '%s' "$recycled_pid" > "$reclaim_link/pid"
  # Backdate the directory AFTER writing into it -- writing a file inside a
  # directory updates ITS mtime too, so backdating first (then writing)
  # would silently erase the very backdate this fixture depends on.
  touch -t "$(date -v-600S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '600 seconds ago' '+%Y%m%d%H%M.%S')" "$reclaim_link"

  local t0=$SECONDS
  run _burn_reclaim_mutex_try "$reclaim_link"
  local elapsed=$((SECONDS - t0))
  kill "$recycled_pid" 2>/dev/null; wait "$recycled_pid" 2>/dev/null || true
  [ "$status" -eq 1 ] || { echo "$output"; false; }   # never claims it FOR the caller
  [ "$elapsed" -le 1 ] || {
    echo "took ${elapsed}s -- fb536ce never reaps this at all (10s timeout upstream, wedged forever downstream)"
    false
  }
  [[ ! -e "$reclaim_link" ]] || { echo "a legacy directory holding a RECYCLED pid survived -- the R6-P1-1 wedge"; false; }
}

@test "_burn_reclaim_mutex_try (R4-P2-3b): a DEAD-pid mutex younger than 30s is left alone" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKMX3)"
  mkdir -p "$(dirname "$lock")"
  local reclaim_link="${lock}.reclaim"
  local dead; dead="$(_dead_pid)"
  ln -s "${dead}:$(date +%s)" "$reclaim_link"   # dead, but its OWN started_at is "just now"
  run _burn_reclaim_mutex_try "$reclaim_link"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ -L "$reclaim_link" ]] || { echo "reaped a mutex younger than 30s"; false; }
  rm -f "$reclaim_link"
}

@test "_burn_reclaim_mutex_try (R4-P2-3c/R5-P2-1): a mutex whose pid is ALIVE and matches its recorded started_at is never reaped, regardless of age" {
  # R5-P2-1 (2026-09-10 round-5 review) added a marker check here (the same
  # one the main lock already used), so this fixture's started_at must now
  # be this pid's OWN real start time, not an arbitrary old constant — a
  # constant unrelated to the pid's real start is exactly the "recycled
  # pid" shape the new check below exists to catch, tested separately.
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKMX4)"
  mkdir -p "$(dirname "$lock")"
  local reclaim_link="${lock}.reclaim"
  sleep 300 &
  local live_pid=$! real_started
  real_started="$(date +%s)"   # this genuinely is $live_pid's own start
  ln -s "${live_pid}:${real_started}" "$reclaim_link"
  run _burn_reclaim_mutex_try "$reclaim_link"
  kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null || true
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ -L "$reclaim_link" ]] || { echo "reaped a mutex whose pid was genuinely alive and matched"; false; }
  rm -f "$reclaim_link"
}

@test "_burn_reclaim_mutex_try (R5-P2-1): a mutex whose pid is alive but does NOT match its recorded started_at is reaped like a recycled pid" {
  # A bare `kill -0` alone cannot tell a genuine holder from a pid recycled
  # onto its number — a live pid whose recorded started_at predates its own
  # real start (as if it inherited a stale marker) must be treated as stale
  # regardless of age, the same way the main lock already treats a
  # recycled holder (R5-P2-1, 2026-09-10 round-5 review; before this fix
  # it wedged the mutex, and the tank it guards, for this pid's whole
  # lifetime).
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKMX4B)"
  mkdir -p "$(dirname "$lock")"
  local reclaim_link="${lock}.reclaim"
  sleep 300 &
  local live_pid=$!
  ln -s "${live_pid}:1" "$reclaim_link"   # started_at=1 -- this pid did not exist then
  run _burn_reclaim_mutex_try "$reclaim_link"
  kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null || true
  [ "$status" -eq 1 ] || { echo "$output"; false; }   # never claims the mutex FOR the caller either way
  [[ ! -L "$reclaim_link" ]] || { echo "an alive-but-mismatched (recycled-shaped) mutex survived"; false; }
}

@test "_burn_reclaim_mutex_try (R4-P1-3): staleness is judged from started_at IN the symlink, never the symlink's own mtime" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKNOSTAT)"
  mkdir -p "$(dirname "$lock")"
  local reclaim_link="${lock}.reclaim"
  local dead; dead="$(_dead_pid)"
  local now; now="$(date +%s)"

  # Embedded started_at says "60s ago" (past the 30s rule); force the
  # symlink's OWN mtime to right now. A `stat`-mtime-based rule (or the old
  # BSD-first bug, which silently forces age to "infinite" on a GNU PATH —
  # the opposite failure) would both get this case right by accident or by
  # bug; the one input that must NOT matter here is the filesystem mtime.
  ln -s "${dead}:$((now - 60))" "$reclaim_link"
  touch -h "$reclaim_link" 2>/dev/null || true
  run _burn_reclaim_mutex_try "$reclaim_link"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ ! -e "$reclaim_link" ]] || { echo "not reaped despite a stale embedded started_at"; false; }

  # Reverse: embedded started_at says "just now" (must NOT be reaped), but
  # force the symlink's mtime to 2020 -- if age were ever read from the
  # filesystem, this would misread as ancient and reap a brand-new mutex.
  ln -s "${dead}:${now}" "$reclaim_link"
  touch -h -t 202001010000 "$reclaim_link" 2>/dev/null || true
  run _burn_reclaim_mutex_try "$reclaim_link"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ -L "$reclaim_link" ]] || {
    echo "reaped a mutex younger than 30s just because its mtime was forced to 2020"
    false
  }
  rm -f "$reclaim_link"
}

@test "_burn_tank_lock_acquire (R4-P2-1): a symlink whose target resolves to an existing directory is reclaimed, not nested into" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKNEST)"
  mkdir -p "$(dirname "$lock")"
  mkdir -p "$(dirname "$lock")/somedir"
  ln -s "somedir" "$lock"   # foreign symlink resolving to an EXISTING DIRECTORY

  local t0=$SECONDS
  run _burn_tank_lock_acquire codex LOCKNEST 5
  local elapsed=$((SECONDS - t0))
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$elapsed" -lt 5 ] || false
  [[ -L "$lock" ]] || { echo "lock is not a symlink"; false; }
  local target; target="$(readlink "$lock")"
  [ "${target%%:*}" = "$$" ] || { echo "lock target=$target"; false; }
  # and the foreign directory was never nested into (the old bug would have
  # created "somedir/$$:<epoch>" instead of failing/reclaiming "$lock" itself)
  [ -z "$(ls -A "$(dirname "$lock")/somedir" 2>/dev/null)" ] || {
    echo "the old bug landed the lock INSIDE somedir instead of reclaiming \$lock"
    false
  }
  _burn_tank_lock_release codex LOCKNEST
}

@test "_burn_tank_lock_acquire (R4-P2-2): a durable empty-target symlink is reclaimed promptly, not spun on forever" {
  _src_burn_lock
  local lock; lock="$(_burn_tank_lock_path codex LOCKEMPTY)"
  mkdir -p "$(dirname "$lock")"
  ln -s "" "$lock"   # durable empty target -- occupies the path forever on its own

  local t0=$SECONDS
  run _burn_tank_lock_acquire codex LOCKEMPTY 5
  local elapsed=$((SECONDS - t0))
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$elapsed" -le 2 ] || { echo "took ${elapsed}s -- the old bug spun at full CPU for the whole timeout"; false; }
  local target; target="$(readlink "$lock")"
  [ "${target%%:*}" = "$$" ] || { echo "lock target=$target"; false; }
  _burn_tank_lock_release codex LOCKEMPTY
}

@test "_burn_tank_lock_acquire (R4-P1-2): 4 independent processes racing a DEAD-holder lock through the reclaim mutex — 0 violations, 0 leaks, 50 trials" {
  # Same _race_contender harness as R3-P2-2 above (real separate processes,
  # a barrier, an independent witness mutex, hold-then-release), scaled to
  # the round-4 review's requested 50 trials, run specifically to re-verify
  # mutual exclusion still holds through the REBUILT reclaim mutex (a
  # direct-hammering probe of _burn_reclaim_mutex_try alone, bypassing the
  # natural pacing every real caller has between retries, was also built
  # and run as a scratchpad probe -- see the report for what it found and
  # why that finding does not apply to any reachable call pattern in this
  # codebase, and is deliberately NOT a committed test here).
  _src_burn_lock
  local slowcat_bin; slowcat_bin="$(_install_slow_cat)"
  local trials=50 contenders=4 hold_s=0.3
  local trial violations=0 leaked=0 wins_total=0
  for trial in $(seq 1 "$trials"); do
    local tank="R4RACE$trial"
    local lock; lock="$(_burn_tank_lock_path codex "$tank")"
    mkdir -p "$(dirname "$lock")"
    ln -s "$(_dead_pid):1" "$lock"

    local barrier="$BATS_TEST_TMPDIR/r4-barrier-$trial" witness="$BATS_TEST_TMPDIR/r4-witness-$trial"
    rm -f "$barrier"; rm -rf "$witness"
    local -a pids=()
    local i won
    for i in $(seq 1 "$contenders"); do
      won="$BATS_TEST_TMPDIR/r4-won-$trial-$i"
      rm -f "$won" "$won.violation"
      local slow=0; [ "$i" -eq 1 ] && slow=1
      _race_contender "$tank" "$barrier" "$witness" "$won" "$slow" "$slowcat_bin" "$hold_s"
      pids+=("$!")
    done
    : > "$barrier"   # release all 4 together
    local p
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

    for i in $(seq 1 "$contenders"); do
      won="$BATS_TEST_TMPDIR/r4-won-$trial-$i"
      [ -f "$won" ] && wins_total=$((wins_total + 1))
      [ -f "$won.violation" ] && violations=$((violations + 1))
    done
    if [ -L "$lock" ] || [ -e "$lock" ]; then
      echo "trial $trial: lock still present after every contender finished — leaked"
      leaked=$((leaked + 1))
    fi
  done
  echo "trials=$trials contenders=$contenders wins=$wins_total violations=$violations leaked_locks=$leaked"
  [ "$violations" -eq 0 ] || false
  [ "$leaked" -eq 0 ] || false
}

@test "burn-collision: SIGTERM while blocked acquiring the busy-tank lock (before 'running' is ever written) still writes a terminal 'fail' status file (R3-P3-1)" {
  _stub_codex
  clikae init codex T1
  # A genuinely LIVE holder (not a fabricated status row) squats the
  # TANK-LEVEL lock itself, not the busy-check status file, so the second
  # burn below blocks inside _burn_tank_lock_acquire's retry loop -- the
  # exact window whose own trap R3-P3-1 is about. It has never reached the
  # first `running` write, so `_burn_install_exit_trap`'s safety net isn't
  # even installed yet; only the section-scoped trap covers this.
  sleep 60 &
  local live_pid=$!
  local lockdir="$CLIKAE_HOME/state"
  mkdir -p "$lockdir"; chmod 0700 "$lockdir"
  ln -s "$live_pid:$(date +%s)" "$lockdir/tank-busy-codex_T1.lock"

  local A="$BATS_TEST_TMPDIR/out.md"
  "$CLIKAE_BIN" burn codex T1 --artifact "$A" -- run "$A" &
  local bpid=$!

  sleep 2   # long enough to be solidly inside the acquire retry loop,
            # short enough that the default 10s acquire timeout never fires
  kill -TERM "$bpid" 2>/dev/null || true
  local rc=0
  wait "$bpid" 2>/dev/null || rc=$?
  kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null || true

  [ "$rc" -eq 143 ] || { echo "rc=$rc (want 143)"; false; }
  [ ! -e "$A" ] || { echo "engine ran despite never reaching the lock"; false; }

  local f
  f="$(ls "$CLIKAE_HOME"/logs/burn-*/status.json 2>/dev/null | head -n1)"
  [ -n "$f" ] || { echo "no status.json was written at all for the killed burn"; false; }
  local json; json="$(cat "$f")"
  [[ "$json" == *'"state":"fail"'* ]] || { echo "$json"; false; }
  [[ "$json" == *'"ok":false'* ]] || { echo "$json"; false; }

  # The live holder's own lock must be untouched -- this signal killed a
  # LOSING contender, not the holder, and losing must never steal.
  local held; held="$(readlink "$lockdir/tank-busy-codex_T1.lock" 2>/dev/null)"
  [ "${held%%:*}" = "$live_pid" ] || { echo "live holder's lock was disturbed: $held"; false; }
}

@test "burn-collision: a busy-tank refusal writes a terminal 'fail' status file with a busy reason (P3-1)" {
  _stub_codex
  clikae init codex T1
  _mark_busy codex T1
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -ne 0 ]
  local new_dir d
  for d in "$CLIKAE_HOME"/logs/burn-*; do
    case "$(basename "$d")" in burn-busy-*) continue ;; esac
    new_dir="$(basename "$d")"
  done
  [ -n "$new_dir" ] || { echo "no run directory created for the refused burn"; false; }
  local f="$CLIKAE_HOME/logs/$new_dir/status.json"
  [ -f "$f" ] || { echo "no status.json written for the refused burn: $f"; false; }
  local json; json="$(cat "$f")"
  [[ "$json" == *'"state":"fail"'* ]] || { echo "$json"; false; }
  [[ "$json" == *'"ok":false'* ]] || { echo "$json"; false; }
  [[ "$json" == *'"reason":"busy:'* ]] || { echo "$json"; false; }
}

# --- R5-P2-3/R5-P2-4 (2026-09-10 round-5 review) ----------------------------
#
# A signal landing while THIS process already holds the reclaim mutex (from
# its own reclaim path inside _burn_tank_lock_acquire) used to make the
# trap's own call to _burn_tank_lock_release try to RE-acquire a mutex it
# already held: the mutex's liveness check correctly sees its own live pid
# and refuses to evict it, so the release spun its whole retry budget, then
# did so AGAIN when the signal's own `exit` triggered the EXIT trap stacked
# behind it (measured by the review: 18-19s to actually exit, mutex leaked
# for that whole window). Separately, the "mutex is busy" branch of the
# lock's own retry loop had no backoff at all.

@test "_burn_tank_lock_release (R5-P2-3): does not deadlock against itself when this process already holds the reclaim mutex" {
  _src_burn_lock
  local eng=codex tank=LOCKSIG1
  _burn_tank_lock_acquire "$eng" "$tank" 5
  local lock; lock="$(_burn_tank_lock_path "$eng" "$tank")"
  local reclaim_dir="${lock}.reclaim"
  # Simulate a signal landing while this SAME process already holds the
  # reclaim mutex from its own internal reclaim path -- claim it directly
  # and mark ownership exactly the way _burn_tank_lock_acquire's own
  # internal call sites do (see _BURN_RECLAIM_MUTEX_OWNED in burn.sh).
  _burn_reclaim_mutex_try "$reclaim_dir"
  _BURN_RECLAIM_MUTEX_OWNED="$reclaim_dir"
  local start_s=$SECONDS
  _burn_tank_lock_release "$eng" "$tank"
  local elapsed=$((SECONDS - start_s))
  [ "$elapsed" -lt 2 ] || { echo "took ${elapsed}s -- looped trying to reacquire its own mutex"; false; }
  [[ ! -L "$lock" ]] || { echo "lock survived release"; false; }
  [[ ! -L "$reclaim_dir" ]] || { echo "mutex leaked"; false; }
  [ -z "$_BURN_RECLAIM_MUTEX_OWNED" ] || { echo "ownership flag not cleared"; false; }
}

@test "_burn_tank_lock_acquire/_burn_tank_lock_release (R5-P2-3): a real signal landing while this process holds the reclaim mutex exits promptly, no leak" {
  # End-to-end version of the unit test above, using the SAME trap shape
  # cmd_burn installs (see the existing "lock is gone on every exit path"
  # test above) and a real SIGTERM landing while _BURN_RECLAIM_MUTEX_OWNED
  # is genuinely set — the review's own measured window.
  (
    _src_burn_lock
    status_engine=codex tank=LOCKSIG2
    trap '_burn_tank_lock_release "$status_engine" "$tank"; exit 143' TERM
    trap '_burn_tank_lock_release "$status_engine" "$tank"' EXIT
    _burn_tank_lock_acquire "$status_engine" "$tank"
    lock="$(_burn_tank_lock_path "$status_engine" "$tank")"
    reclaim_dir="${lock}.reclaim"
    _burn_reclaim_mutex_try "$reclaim_dir"
    _BURN_RECLAIM_MUTEX_OWNED="$reclaim_dir"
    # backgrounded + waited-on, not a bare foreground `sleep`: bash only
    # runs a pending trap once its CURRENT foreground command returns, and a
    # bare `sleep 5` here would make this test measure "however much of the
    # 5s was left", not the release logic's own speed — `wait` on a
    # background job IS interruptible by an arriving signal, same as the
    # real engine subprocess a live `clikae burn` is waiting on.
    sleep 5 &   # the signal lands here, inside the held-mutex window
    wait $!
  ) &
  local bg=$!
  sleep 1
  local start_s=$SECONDS
  kill -TERM "$bg"
  wait "$bg" 2>/dev/null || true
  local elapsed=$((SECONDS - start_s))
  [ "$elapsed" -le 2 ] || { echo "took ${elapsed}s to exit -- self-deadlocked"; false; }
  [[ ! -L "$(_burn_tank_lock_path codex LOCKSIG2)" ]] || { echo "lock leaked"; false; }
  [[ ! -L "$(_burn_tank_lock_path codex LOCKSIG2).reclaim" ]] || { echo "mutex leaked"; false; }
}

@test "_burn_tank_lock_acquire (R5-P2-4): a busy reclaim mutex backs off instead of spinning at full CPU" {
  _src_burn_lock
  local eng=codex tank=LOCKBACKOFF
  local lock; lock="$(_burn_tank_lock_path "$eng" "$tank")"
  mkdir -p "$(dirname "$lock")"
  local dead; dead="$(_dead_pid)"
  ln -s "${dead}:1" "$lock"   # dead holder -- every loop iteration re-enters the reclaim branch
  local reclaim_dir="${lock}.reclaim"
  # Hold the reclaim mutex from a separate live process for the whole probe,
  # so every one of the caller's retries hits the "mutex is busy" branch.
  ( _src_burn_lock; _burn_reclaim_mutex_try "$reclaim_dir"; sleep 3 ) &
  local holder=$!
  sleep 0.3   # let it actually claim the mutex first
  TIMEFORMAT='%2U'
  local timefile="$BATS_TEST_TMPDIR/time.out"
  # The acquire is EXPECTED to time out (rc=1) -- the mutex stays busy for
  # the whole 2s window -- so its own non-zero status must not fail the
  # test; only the CPU-time measurement matters here.
  { time { _burn_tank_lock_acquire "$eng" "$tank" 2 >/dev/null 2>&1 || true; }; } 2> "$timefile"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  local user_s; user_s="$(cat "$timefile")"
  # A no-backoff spin burns most of a core for the whole 2s window; a 1s
  # sleep between retries keeps user CPU time a small fraction of that.
  awk -v u="$user_s" 'BEGIN { exit !(u < 1.0) }' || { echo "user time ${user_s}s -- looks like a busy spin"; false; }
}
