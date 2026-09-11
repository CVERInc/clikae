#!/usr/bin/env bats
# tests/bats/clean.bats — `clikae clean` (extracted from `resume cleanup`,
# which survives as a hidden forwarding alias): the three-section preview and
# its smart defaults, the stale-copy reclaim (relay/cross-tank resume copies),
# the orphaned-sid-dir sweep, the built-in big-but-recent floor, the --min-size
# axis, and the byte-level safety check that gates deduping.
#
# The interactive checkbox picker itself needs a real pty (tests/tools/
# pty-smoke.py territory); everything here goes through --dry-run — which must
# print the same sectioned list — or calls the safety-check helpers directly.

load '../helpers'

# Bring _clean_stale_copy_check + friends into THIS bats process, in the same
# order bin/clikae sources them (clean.sh itself sources resume.sh → home.sh) —
# needed only by the unit-level tests; the dry-run tests drive the real
# `clikae` binary.
_source_clean() {
  CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  # shellcheck source=../../lib/core/log.sh
  source "$CLIKAE_LIB/core/log.sh"
  # shellcheck source=../../lib/core/i18n.sh
  source "$CLIKAE_LIB/core/i18n.sh"
  # shellcheck source=../../lib/core/profile_store.sh
  source "$CLIKAE_LIB/core/profile_store.sh"
  # shellcheck source=../../lib/core/adapter_loader.sh
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  # shellcheck source=../../lib/core/tui.sh
  source "$CLIKAE_LIB/core/tui.sh"
  # bin/clikae loads this before any command runs, and the GC's globs are built
  # from its prefix constants. Sourcing clean.sh without it builds an environment
  # that never exists at runtime.
  # shellcheck source=../../lib/core/tmux.sh
  source "$CLIKAE_LIB/core/tmux.sh"
  # shellcheck source=../../lib/commands/clean.sh
  source "$CLIKAE_LIB/commands/clean.sh"
}

# The ephemeral-GC reads its locks from the PRIVATE state dir, never world-writable
# /tmp (a co-tenant there could plant a lock the GC reads as dead, killing your
# session + deleting your state). This pins the location AND that a dead lock's
# companion state files get reaped from that dir.
@test "GC reaps a dead lock's state files from the private \$HOME/.clikae/state dir" {
  _source_clean
  local sdir="$HOME/.clikae/state"
  mkdir -p "$sdir"
  # A lock nobody holds → the GC's non-blocking grab succeeds → treated as dead.
  : > "$sdir/clikae-ephem-claude-x-burn-1234.lock"
  : > "$sdir/claude-x-burn-1234.sh"
  : > "$sdir/claude-x-burn-1234_exit"
  # No tmux session ck-claude-x-burn-1234 exists → the else branch removes state.
  _clean_tmux_gc 0
  [ ! -f "$sdir/claude-x-burn-1234.sh" ]
  [ ! -f "$sdir/claude-x-burn-1234_exit" ]
  [ ! -f "$sdir/clikae-ephem-claude-x-burn-1234.lock" ]
}

@test "GC ignores a lock in /tmp (only the private state dir is scanned)" {
  _source_clean
  local planted="${TMPDIR:-/tmp}/ck-ephem-claude-decoy-$$-99.lock"
  : > "$planted"
  _clean_tmux_gc 0
  [ -f "$planted" ]   # untouched: the GC no longer looks in /tmp
  rm -f "$planted"
}

@test "clikae clean (KITT/R10-P1-1): a real, HELD ephemeral lock does not kill the whole run under errexit -- it is named, and the tank-lock GC still runs" {
  # R10-P1-1 (2026-09-12 round-10 review): _clean_tmux_gc's own flock/lockf
  # probes were bare statements ("… ; rc=$?") under bin/clikae's own
  # `set -eo pipefail` -- the exact shape R9-P1-1 fixed at cmd_burn's own
  # acquire call, just never grepped for at this sibling site. A
  # GENUINELY HELD ephemeral lock (exactly what any real `clikae burn`'s
  # tmux wrapper holds for its entire run, lib/commands/burn.sh) made the
  # probe exit non-zero, and errexit killed the WHOLE `clikae clean`
  # process right there: rc=75 (lockf) or rc=1 (flock), ZERO lines of
  # output, before `_clean_scrollback_gc`/`_clean_tank_lock_gc` -- this
  # PR's own documented recovery path for everything else -- ever ran.
  # This drives the real binary against a REAL held lock (a backgrounded
  # process blocked on its own `flock`/`lockf` fd, never a sleep loop
  # pretending to be alive), not a unit call to `_clean_tmux_gc` alone
  # (bats itself does not run under errexit, so a unit call could not
  # reproduce this).
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999985
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  # A dead-holder tank lock the tank-lock GC should still find and report,
  # proving it actually ran (not merely that clean's own exit code is 0).
  ln -s "$dead:1700000000" "$sdir/tank-busy-codex_T20.lock"

  local lock_file="$sdir/clikae-ephem-probe-$$.lock"
  (
    exec 9> "$lock_file"
    if command -v flock >/dev/null 2>&1; then flock 9; else lockf 9; fi
    sleep 5
  ) &
  local holder=$!
  sleep 0.3

  run clikae clean --dry-run
  local rc="$status" out="$output"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  rm -f "$lock_file" "$sdir/tank-busy-codex_T20.lock"

  [ "$rc" -eq 0 ] || { echo "$out"; echo "-- clean died (rc=$rc) instead of skipping the held lock and continuing -- the R10-P1-1 errexit death"; false; }
  [ -n "$out" ] || { echo "-- zero lines of output -- the exact silent-errexit-death symptom this test guards against"; false; }
  [[ "$out" == *"clikae-ephem-probe-$$.lock"* ]] || { echo "$out"; echo "-- the busy ephemeral lock was never named"; false; }
  [[ "$out" == *"Would remove dead-holder tank lock tank-busy-codex_T20.lock"* ]] || {
    echo "$out"; echo "-- the tank-lock GC (the PR's own documented recovery path) did not run/report while the ephemeral lock was held"; false; }
}

# Seed a claude transcript for tank $1 with $3 conversation lines under a fixed
# project dir; echoes the transcript path.
_seed_lines() {
  local profile="$1" sid="$2" n="$3" i
  local dir="$CLIKAE_HOME/profiles/claude/$profile/projects/-w"
  mkdir -p "$dir"
  for ((i=1; i<=n; i++)); do
    printf '{"type":"user","cwd":"/tmp/w","message":{"role":"user","content":"conversation line %d"}}\n' "$i"
  done > "$dir/$sid.jsonl"
  printf '%s\n' "$dir/$sid.jsonl"
}

# Same, but with an explicit ai-title ($3) — for the width tests, whose whole
# point is that the title may be CJK (2 display columns per glyph) rather than
# Latin. Raw UTF-8, exactly as a real transcript stores it.
_seed_titled() {
  local profile="$1" sid="$2" title="$3" n="$4" i
  local dir="$CLIKAE_HOME/profiles/claude/$profile/projects/-w"
  mkdir -p "$dir"
  { printf '{"type":"ai-title","aiTitle":"%s","sessionId":"%s"}\n' "$title" "$sid"
    for ((i=1; i<=n; i++)); do
      printf '{"type":"user","cwd":"/tmp/w","message":{"role":"user","content":"conversation line %d"}}\n' "$i"
    done
  } > "$dir/$sid.jsonl"
  printf '%s\n' "$dir/$sid.jsonl"
}

# Seed a RECENT claude transcript whose first line titles it $3 and whose body
# pads it to ~$4 MB — the "big but recent" fixture (the built-in floor is 20 MB).
_seed_big() {
  local profile="$1" sid="$2" title="$3" mb="$4"
  local dir="$CLIKAE_HOME/profiles/claude/$profile/projects/-w"
  mkdir -p "$dir"
  { printf '{"type":"user","cwd":"/tmp/w","message":{"role":"user","content":"%s"}}\n' "$title"
    dd if=/dev/zero bs=1048576 count="$mb" 2>/dev/null | LC_ALL=C tr '\0' 'a'; echo
  } > "$dir/$sid.jsonl"
}

# --- _clean_stale_copy_check (unit) ----------------------------------------------

@test "stale check: an exact byte-prefix copy is safe" {
  _source_clean
  local kept cand
  kept="$(_seed_lines a 11111111-2222-3333-4444-555555555555 200)"
  cand="$TEST_HOME/cand.jsonl"
  head -n 100 "$kept" > "$cand"
  _clean_stale_copy_check "$kept" "$cand"
}

@test "stale check: a byte-identical copy is safe (the exactly-n-bytes BSD cmp edge)" {
  # BSD `cmp -s -n <sz> A B` exits 1 ("EOF") when B is exactly <sz> bytes, which
  # would misread every byte-identical relay copy as diverged. The head|cmp form
  # must pass this.
  _source_clean
  local kept cand
  kept="$(_seed_lines a 22222222-2222-3333-4444-555555555555 50)"
  cand="$TEST_HOME/cand.jsonl"
  cp "$kept" "$cand"
  _clean_stale_copy_check "$kept" "$cand"
}

@test "stale check: a metadata-only tail after the shared prefix is safe" {
  _source_clean
  local kept cand
  kept="$(_seed_lines a 33333333-2222-3333-4444-555555555555 80)"
  cand="$TEST_HOME/cand.jsonl"
  head -n 60 "$kept" > "$cand"
  printf '{"type":"ai-title","title":"a title"}\n' >> "$cand"
  printf '{"type":"last-prompt","prompt":"a prompt"}\n' >> "$cand"
  printf '{"type":"permission-mode","mode":"plan"}\n' >> "$cand"
  _clean_stale_copy_check "$kept" "$cand"
}

@test "stale check: a conversation line after the shared prefix diverges" {
  _source_clean
  local kept cand
  kept="$(_seed_lines a 44444444-2222-3333-4444-555555555555 80)"
  cand="$TEST_HOME/cand.jsonl"
  head -n 60 "$kept" > "$cand"
  printf '{"type":"user","message":{"role":"user","content":"UNIQUE user turn"}}\n' >> "$cand"
  run _clean_stale_copy_check "$kept" "$cand"
  [ "$status" -ne 0 ]
}

@test "stale check: a divergence deeper than the last 4096 bytes diverges" {
  _source_clean
  local kept cand i
  kept="$(_seed_lines a 55555555-2222-3333-4444-555555555555 300)"
  cand="$TEST_HOME/cand.jsonl"
  head -n 10 "$kept" > "$cand"
  # >4 KB of metadata beyond the shared prefix: type-wise acceptable, but the
  # divergence point falls outside the last-4096-bytes window the safety check
  # allows, so it must NOT be auto-selected.
  for ((i=0; i<200; i++)); do
    printf '{"type":"last-prompt","prompt":"padding padding padding padding"}\n' >> "$cand"
  done
  [ "$(_file_bytes "$cand")" -le "$(_file_bytes "$kept")" ]   # fixture sanity
  run _clean_stale_copy_check "$kept" "$cand"
  [ "$status" -ne 0 ]
}

# --- the move: clikae clean is canonical, resume cleanup forwards ----------------

@test "resume cleanup is a hidden alias: byte-identical output with clikae clean" {
  local sid="10101010-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 200 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/b/projects/-w"
  head -n 100 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" \
    > "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"

  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  local canon="$output"
  [[ "$canon" == *"stale copy (kept: a)"* ]] || false   # fixture produced rows
  run clikae resume cleanup --dry-run
  [ "$status" -eq 0 ]
  [ "$output" = "$canon" ]
}

# --- section assignment + defaults (through `clikae clean --dry-run`) ------------

@test "a stale copy lands in 'Redundant (safe)', pre-checked" {
  local sid="12121212-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 200 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/b/projects/-w"
  head -n 100 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" \
    > "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"

  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Redundant (safe)"* ]] || false
  [[ "$output" == *"[x] claude/b"* ]] || false
  [[ "$output" == *"Total sessions to clean: 1"* ]] || false
  # Nothing old and nothing over the floor → the other sections don't print.
  [[ "$output" != *"Untouched for"* ]] || false
  [[ "$output" != *"Big but recent"* ]] || false
}

@test "an old session lands under 'Untouched for N+ days', pre-checked" {
  local sid="23232323-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 5 >/dev/null
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl"

  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Untouched for 30+ days"* ]] || false
  [[ "$output" == *"[x] claude/a"* ]] || false
  # The section heading follows --older-than.
  run clikae clean --dry-run --older-than 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"Untouched for 7+ days"* ]] || false
}

@test "a big RECENT session shows unchecked under 'Big but recent' — no flags needed" {
  # The built-in 20 MB floor: the space hogs must be VISIBLE with zero flags,
  # but only ever opt-in — informational, never counted into the default total.
  _seed_big a "34343434-2222-3333-4444-555555555555" "huge recent session" 21
  _seed_lines a "45454545-2222-3333-4444-555555555555" 3 >/dev/null   # small + recent

  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Big but recent — your call"* ]] || false
  [[ "$output" == *"[ ] claude/a"* ]] || false
  [[ "$output" == *"huge recent session"* ]] || false
  [[ "$output" != *"conversation line"* ]] || false     # under the floor → not shown
  [[ "$output" == *"Total sessions to clean: 0"* ]] || false
}

@test "a diverged copy lands in 'Big but recent' unchecked, labeled has-unique-content" {
  local sid="56565656-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 80 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/b/projects/-w"
  head -n 60 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" \
    > "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"UNIQUE tail"}}\n' \
    >> "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"

  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Big but recent — your call"* ]] || false
  [[ "$output" == *"diverged — has unique content"* ]] || false
  [[ "$output" == *"[ ] claude/b"* ]] || false
  # Not selected → not counted.
  [[ "$output" == *"Total sessions to clean: 0"* ]] || false
}

# --- dedupe scan (through `clikae clean --dry-run`) ------------------------------

@test "clean dedupes copies of one session and keeps the LARGEST, not the newest" {
  local sid="66666666-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 200 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/b/projects/-w"
  head -n 100 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" \
    > "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"
  # The SMALLER copy is the newer one — mtime must not decide.
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl"
  touch -t 202606250000 "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"

  run clikae clean --dry-run --older-than 9999
  [ "$status" -eq 0 ]
  # Neither copy passes the 9999d age filter or the big-file floor, yet the
  # redundant copy is offered anyway: the Redundant section bypasses both.
  [[ "$output" == *"claude/b"* ]] || false
  [[ "$output" == *"stale copy (kept: a)"* ]] || false
  [[ "$output" != *"claude/a"* ]] || false
}

@test "clean groups copies across project dirs of the SAME tank (project rename)" {
  local sid="77777777-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 120 >/dev/null
  local old_dir="$CLIKAE_HOME/profiles/claude/a/projects/-old-name"
  mkdir -p "$old_dir"
  head -n 40 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" > "$old_dir/$sid.jsonl"
  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale copy (kept: a)"* ]] || false
}

@test "clean skips a dedupe group whose sid has a live process" {
  local sid="99999999-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 100 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/b/projects/-w"
  head -n 50 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" \
    > "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"
  # A fake ps whose output carries the sid — as if `claude --resume <sid>` were
  # running in another terminal. helpers.bash already puts .testbin first on PATH.
  cat > "$TEST_HOME/.testbin/ps" <<PSSTUB
#!/usr/bin/env bash
echo "claude --resume $sid"
PSSTUB
  chmod +x "$TEST_HOME/.testbin/ps"

  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"stale copy"* ]] || false
}

# --- orphaned sid dirs ------------------------------------------------------------

@test "clean offers an orphaned claude sid dir (transcript already gone)" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/a/projects/-w/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/subagents"
  echo x > "$CLIKAE_HOME/profiles/claude/a/projects/-w/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/subagents/t.jsonl"
  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"orphaned subagent data"* ]] || false
  [[ "$output" == *"Redundant (safe)"* ]] || false
}

@test "clean does NOT flag a sid dir whose transcript still exists, nor a non-sid dir" {
  local sid="bbbbbbbb-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 5 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid/subagents"     # has its transcript
  mkdir -p "$CLIKAE_HOME/profiles/claude/a/projects/-w/not-a-session-dir"  # not uuid-shaped
  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"orphaned subagent data"* ]] || false
}

@test "clean prices a claude transcript together with its sibling sid dir" {
  local sid="cccccccc-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 2 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid/subagents"
  dd if=/dev/zero of="$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid/subagents/big.jsonl" \
    bs=1024 count=3072 2>/dev/null
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl"
  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  # A ~200 B transcript alone would price in KB; the bundled sid dir puts it in MB.
  [[ "$output" == *"3.0 MB"* ]] || false
}

# --- --min-size -------------------------------------------------------------------

@test "clean --min-size alone filters by size only (no age cutoff) and pre-checks" {
  local big="dddddddd-2222-3333-4444-555555555555"
  local small="eeeeeeee-2222-3333-4444-555555555555"
  _seed_lines a "$small" 3 >/dev/null
  { printf '{"type":"user","cwd":"/tmp/w","message":{"role":"user","content":"big session"}}\n'
    dd if=/dev/zero bs=1024 count=2048 2>/dev/null | LC_ALL=C tr '\0' 'a'; echo
  } > "$CLIKAE_HOME/profiles/claude/a/projects/-w/$big.jsonl"

  run clikae clean --dry-run --min-size 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"big session"* ]] || false
  [[ "$output" != *"conversation line"* ]] || false
  [[ "$output" == *"Total sessions to clean: 1"* ]] || false
  # An explicit --min-size is a power-user selection, so its section says so.
  [[ "$output" == *"1 MB or larger"* ]] || false
}

@test "clean --min-size with --older-than requires BOTH (a recent big file is excluded)" {
  local big="ffffffff-2222-3333-4444-555555555555"
  mkdir -p "$CLIKAE_HOME/profiles/claude/a/projects/-w"
  { printf '{"type":"user","cwd":"/tmp/w","message":{"role":"user","content":"big recent"}}\n'
    dd if=/dev/zero bs=1024 count=2048 2>/dev/null | LC_ALL=C tr '\0' 'a'; echo
  } > "$CLIKAE_HOME/profiles/claude/a/projects/-w/$big.jsonl"

  run clikae clean --dry-run --min-size 1 --older-than 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"No sessions older than 30 days and at least 1 MB found"* ]] || false

  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$big.jsonl"
  run clikae clean --dry-run --min-size 1 --older-than 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"big recent"* ]] || false
}

@test "clean --min-size rejects a non-numeric value" {
  run clikae clean --min-size lots
  [ "$status" -ne 0 ]
  [[ "$output" == *"--min-size requires a numeric"* ]] || false
}

# --- guardrails -------------------------------------------------------------------

@test "clean still refuses to delete without an interactive confirmation (non-TTY)" {
  local sid="a1a1a1a1-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 5 >/dev/null
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl"
  run clikae clean
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to move anything to the Trash without an interactive confirmation"* ]] || false
  [ -f "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" ]
}

@test "clean --help documents the sections and axes" {
  run clikae clean --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"clikae clean"* ]] || false
  [[ "$output" == *"--min-size"* ]] || false
  [[ "$output" == *"stale copies"* ]] || false
  [[ "$output" == *"orphaned subagent data"* ]] || false
  [[ "$output" == *"Big but recent"* ]] || false
}

@test "clean --help talks about the Trash, not deleting files outright" {
  run clikae clean --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Trash"* ]] || false
  [[ "$output" != *"Delete old session"* ]] || false
}

# --- live-session guard: ONE guard, every class (2026-07-11 incident) ------------
# A session a process still holds must never become a candidate in ANY section.
# The dedupe path already had its own inline check (see "clean skips a dedupe
# group..." above, now routed through the shared `_clean_session_is_live`); these
# cover the classes that had NO guard at all — the actual incident: a live
# session surfaced UNCHECKED under "Big but recent", one keypress from deletion.

@test "clean's live guard covers 'Big but recent' too — a live big-recent session is never listed" {
  local sid="c0ffee00-2222-3333-4444-555555555555"
  _seed_big a "$sid" "still open right now" 25
  cat > "$TEST_HOME/.testbin/ps" <<PSSTUB
#!/usr/bin/env bash
echo "claude --resume $sid"
PSSTUB
  chmod +x "$TEST_HOME/.testbin/ps"

  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"still open right now"* ]] || false
  [[ "$output" != *"Big but recent"* ]] || false
}

@test "clean's live guard covers the old/regular class too — a live old session is never listed" {
  local sid="d0ffee00-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 5 >/dev/null
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl"
  cat > "$TEST_HOME/.testbin/ps" <<PSSTUB
#!/usr/bin/env bash
echo "claude --resume $sid"
PSSTUB
  chmod +x "$TEST_HOME/.testbin/ps"

  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  # The only session in the store is filtered out entirely by the live guard —
  # not merely left unchecked — so the pool is empty and clean says so.
  [[ "$output" != *"Untouched for 30+ days"* ]] || false
  [[ "$output" == *"Nothing to clean"* ]] || false
}

# --- _clean_session_is_live (unit): the ONE guard every class shares -------------

@test "session_is_live: matches a claude sid (bare uuid) against a ps snapshot" {
  _source_clean
  local f="$CLIKAE_HOME/profiles/claude/a/projects/-w/11111111-2222-3333-4444-555555555555.jsonl"
  _clean_session_is_live "$f" "claude --resume 11111111-2222-3333-4444-555555555555"
}

@test "session_is_live: matches a codex rollout path by its trailing 36-char uuid" {
  _source_clean
  local f="$CLIKAE_HOME/profiles/codex/a/sessions/2026/07/11/rollout-2026-07-11T12-00-00-99999999-2222-3333-4444-555555555555.jsonl"
  _clean_session_is_live "$f" "codex --resume 99999999-2222-3333-4444-555555555555"
}

@test "session_is_live: matches an antigravity brain/<sid>/ directory, not the transcript filename" {
  _source_clean
  local f="$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/brain/88888888-2222-3333-4444-555555555555/.system_generated/logs/transcript.jsonl"
  _clean_session_is_live "$f" "some-agy-process --sid 88888888-2222-3333-4444-555555555555"
}

@test "session_is_live: a bare sid string (dedupe's g_sid) works without a path" {
  _source_clean
  _clean_session_is_live "77777777-2222-3333-4444-555555555555" "claude --resume 77777777-2222-3333-4444-555555555555"
}

@test "session_is_live: no match when the snapshot doesn't mention the sid" {
  _source_clean
  local f="$CLIKAE_HOME/profiles/claude/a/projects/-w/11111111-2222-3333-4444-555555555555.jsonl"
  run _clean_session_is_live "$f" "some other unrelated process"
  [ "$status" -ne 0 ]
}

@test "session_is_live: an empty ps snapshot never manufactures a false skip" {
  _source_clean
  local f="$CLIKAE_HOME/profiles/claude/a/projects/-w/11111111-2222-3333-4444-555555555555.jsonl"
  run _clean_session_is_live "$f" ""
  [ "$status" -ne 0 ]
}

# --- _clean_to_trash (unit): move, NEVER destroy — collision-safe, honest skip ---
# HOME == TEST_HOME (helpers.bash), so $HOME/.Trash is a throwaway fixture path;
# never the real ~/.Trash.

@test "to_trash moves a file into \$HOME/.Trash and the original is gone" {
  _source_clean
  local f="$TEST_HOME/session-a.jsonl"
  echo "conversation" > "$f"
  _clean_to_trash "$f"
  [ "$CLEAN_TRASH_SKIPPED" -eq 0 ]
  [ -f "$HOME/.Trash/session-a.jsonl" ]
  [ ! -e "$f" ]
  [ "$CLEAN_TRASH_DEST" = "$HOME/.Trash/session-a.jsonl" ]
}

@test "to_trash moves a directory (a sibling sid dir) into \$HOME/.Trash intact" {
  _source_clean
  local d="$TEST_HOME/sid-dir"
  mkdir -p "$d/subagents"
  echo x > "$d/subagents/t.jsonl"
  _clean_to_trash "$d"
  [ "$CLEAN_TRASH_SKIPPED" -eq 0 ]
  [ -d "$HOME/.Trash/sid-dir" ]
  [ -f "$HOME/.Trash/sid-dir/subagents/t.jsonl" ]
  [ ! -e "$d" ]
}

@test "to_trash suffixes a name collision — never clobbers an existing Trash entry" {
  _source_clean
  mkdir -p "$HOME/.Trash"
  printf 'first tank copy' > "$HOME/.Trash/dupe.jsonl"          # already there
  local f="$TEST_HOME/dupe.jsonl"
  printf 'second tank copy' > "$f"
  _clean_to_trash "$f"
  [ "$CLEAN_TRASH_SKIPPED" -eq 0 ]
  [ "$CLEAN_TRASH_DEST" = "$HOME/.Trash/dupe.jsonl (1)" ]
  [ "$(cat "$HOME/.Trash/dupe.jsonl")" = "first tank copy" ]      # untouched
  [ "$(cat "$HOME/.Trash/dupe.jsonl (1)")" = "second tank copy" ]
  [ ! -e "$f" ]
}

@test "to_trash suffixes a SECOND collision as (2), still never clobbering" {
  _source_clean
  mkdir -p "$HOME/.Trash"
  printf 'a' > "$HOME/.Trash/trip.jsonl"
  printf 'b' > "$HOME/.Trash/trip.jsonl (1)"
  local f="$TEST_HOME/trip.jsonl"
  printf 'c' > "$f"
  _clean_to_trash "$f"
  [ "$CLEAN_TRASH_DEST" = "$HOME/.Trash/trip.jsonl (2)" ]
  [ "$(cat "$HOME/.Trash/trip.jsonl")" = "a" ]
  [ "$(cat "$HOME/.Trash/trip.jsonl (1)")" = "b" ]
  [ "$(cat "$HOME/.Trash/trip.jsonl (2)")" = "c" ]
}

@test "to_trash LEAVES THE FILE when the Trash is unusable — never rm" {
  _source_clean
  # A FILE (not a dir) sitting where ~/.Trash should be: mkdir -p fails, and the
  # pre-existing-dir check also fails — the realistic shape of "Trash got
  # replaced/corrupted", no root/chmod tricks needed.
  rm -rf "$HOME/.Trash"
  printf 'not a directory' > "$HOME/.Trash"
  local f="$TEST_HOME/orphan.jsonl"
  echo "data" > "$f"
  _clean_to_trash "$f"
  [ "$CLEAN_TRASH_SKIPPED" -eq 1 ]
  [ -z "$CLEAN_TRASH_DEST" ]
  # THE point of this whole path: a session clean could not relocate must still
  # be on disk. A stuck row costs one uncleaned file; an rm costs it forever.
  [ -e "$f" ]
  [ "$(cat "$f")" = "data" ]
}

@test "to_trash with no \$HOME leaves the file alone" {
  _source_clean
  local f="$TEST_HOME/nohome.jsonl"
  echo "data" > "$f"
  HOME="" _clean_to_trash "$f"
  [ "$CLEAN_TRASH_SKIPPED" -eq 1 ]
  [ -e "$f" ]
}

@test "to_trash on a path that doesn't exist is a no-op, not a fallback" {
  _source_clean
  _clean_to_trash "$TEST_HOME/never-existed.jsonl"
  [ "$CLEAN_TRASH_SKIPPED" -eq 0 ]
  [ -z "$CLEAN_TRASH_DEST" ]
}

# --- honest strings: nothing here promises "freed" until the Trash is emptied ---

@test "the dry-run summary talks about moving to the Trash, not freeing space outright" {
  local sid="e0e0e0e0-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 5 >/dev/null
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl"
  run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Estimated space to move to the Trash"* ]] || false
  [[ "$output" != *"Estimated space to free"* ]] || false
  [[ "$output" != *"Freed"* ]] || false
}

# --- row width budget: progressive disclosure by importance (fix/tui-width) ---
# The row must never exceed the terminal, and when it tightens it must sacrifice
# in importance order: age first, then size (compressed, then dropped), and only
# then the title — which still never drops below _CR_TITLE_MIN. The LABEL (the
# safety semantics) is never truncated; if it can't fit beside the rest it moves
# to its own continuation line.

@test "_kb_compact squeezes the size (21.0 MB -> 21M) without lying about it" {
  _source_clean
  [ "$(_kb_compact 512)" = "512K" ]
  [ "$(_kb_compact 21504)" = "21M" ]        # 21.0 MB
  [ "$(_kb_compact 1536)" = "1.5M" ]        # 1.5 MB keeps its decimal
  [[ "$(_kb_compact 2097152)" == *G ]] || false
  # always narrower than the spaced-out form it replaces
  [ "$(_dwidth "$(_kb_compact 21504)")" -lt "$(_dwidth "$(_kb_human 21504)")" ]
}

@test "_clean_row_fit: a wide row keeps everything (age, full size, whole title)" {
  _source_clean
  _clean_row_fit 120 16 "Short title" "0d ago" 21504 " · stale copy (kept: b)"
  [ "$_CR_TITLE" = "Short title" ]          # not truncated
  [ "$_CR_AGE" = "0d ago" ]
  [ "$_CR_SIZE" = "21.0 MB" ]               # full, uncompressed
  [ "$_CR_WRAP" -eq 0 ]
}

@test "_clean_row_fit: AGE is the first thing sacrificed, and the title outranks it" {
  _source_clean
  local long="Refactor the payment reconciliation pipeline for retried webhooks"
  # 60-col terminal, 10 cols of lead chrome -> avail 50.
  _clean_row_fit 50 16 "$long" "0d ago" 21504 ""
  [ -z "$_CR_AGE" ]                                  # age dropped...
  [ "$_CR_TITLE" != "" ]
  # ...to buy the title a RECOGNIZABLE width, not a 12-col stub.
  [ "$(_dwidth "$_CR_TITLE")" -ge "$_CR_TITLE_GOOD" ]
}

@test "_clean_row_fit: the title never drops below _CR_TITLE_MIN" {
  _source_clean
  local long="Refactor the payment reconciliation pipeline for retried webhooks"
  _clean_row_fit 34 16 "$long" "0d ago" 21504 ""
  [ "$(_dwidth "$_CR_TITLE")" -ge "$_CR_TITLE_MIN" ]
}

@test "_clean_row_fit: a long localized label is NEVER truncated — it wraps to its own line" {
  _source_clean
  local long="Refactor the payment reconciliation pipeline for retried webhooks"
  local fr=" · copie obsolète (celle de work est gardée)"   # the fr-FR stale-copy label
  _clean_row_fit 70 16 "$long" "il y a 0j" 21504 "$fr"
  [ "$_CR_WRAP" -eq 1 ]                              # label pushed to line 2
  [ "$(_dwidth "$_CR_TITLE")" -ge "$_CR_TITLE_MIN" ] # title still readable
}

@test "no clean --dry-run line exceeds 80 columns, in any of the nine locales (CJK titles)" {
  # Measured with unicodedata.east_asian_width — the TRUE display width — not
  # with lib's own `_dwidth` (asserting the render with the render's own ruler
  # would prove nothing if the ruler is what's wrong). Skip rather than fake it
  # if python3 isn't around — same pattern as list.bats/status.bats' JSON checks.
  #
  # 🔴 The TITLES ARE CJK ON PURPOSE. This test previously seeded Latin titles
  # only, and passed while the real store rendered 120+ column rows: for Latin,
  # 1 character == 1 display column, so it could not distinguish a truncator
  # that cuts by characters (the bug) from one that cuts by columns (the fix).
  # A width test with no wide characters in its data is not a width test.
  command -v python3 >/dev/null || skip "python3 not available to measure display width"
  local zh="規則：僅根據本訊息內文作答。不得讀取任何檔案、不得使用任何工具、不得引用你可能記得"
  local ja="リファクタリング：支払い照合パイプラインの重複課金を修正し再試行を処理する"
  local ko="결제 조정 파이프라인에서 재시도된 웹훅의 이중 청구를 수정하고 백필을 추가"
  local mixed="Refactor 支払い pipeline 重複課金 fix — retried webhooks 的 key 修正"
  local i=0 t sid
  for t in "$zh" "$ja" "$ko" "$mixed" "Plain latin title for contrast"; do
    i=$((i + 1))
    sid="3434343${i}-2222-3333-4444-555555555555"
    _seed_titled a "$sid" "$t" 200
    # a stale cross-tank copy -> a "Redundant (safe)" row, i.e. the row that
    # carries the LONG localized label right next to the CJK title. That
    # combination is what measured 120-124 cols on the maintainer's real store.
    mkdir -p "$CLIKAE_HOME/profiles/claude/b/projects/-w"
    head -n 100 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" \
      > "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"
  done
  local loc
  for loc in en-US ja-JP zh-TW zh-Hans ko-KR es-ES de-DE fr-FR pt-BR; do
    # Not a tty here, so the render takes its documented 80-col fallback — the
    # floor these tests are specified against. (The 60-col + live-tty behaviour
    # is covered by the PTY audit, which drives a real pty at both widths.)
    CLIKAE_LANG="$loc" run clikae clean --dry-run
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | python3 -c '
import sys, unicodedata
bad = []
for line in sys.stdin.read().splitlines():
    line = line.rstrip()
    if not line:
        continue
    w = sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in line)
    if w > 80:
        bad.append((w, line))
for w, line in bad:
    print("%d cols: %s" % (w, line), file=sys.stderr)
sys.exit(1 if bad else 0)
' || { echo "locale $loc has an over-width line (above)"; false; }
  done
}

@test "the localized stale-copy LABEL is never truncated, even in the longest language (fr)" {
  local sid="45454545-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 200 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/b/projects/-w"
  head -n 100 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" \
    > "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"
  # fr-FR's label is the longest of the nine — it must appear IN FULL (it carries
  # the safety semantics: which copy is being kept). The title is what yields.
  CLIKAE_LANG=fr-FR run clikae clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"copie obsolète (celle de a est gardée)"* ]] || false
  [[ "$output" != *"copie obsolète (celle de a est gard…"* ]] || false   # not cut
}

@test "trash_usable says no when ~/.Trash isn't a usable directory" {
  _source_clean
  rm -rf "$HOME/.Trash"
  printf 'not a directory' > "$HOME/.Trash"
  run _clean_trash_usable
  [ "$status" -ne 0 ]
}

@test "trash_usable says yes for a writable ~/.Trash, and will create a missing one" {
  _source_clean
  rm -rf "$HOME/.Trash"
  run _clean_trash_usable      # a fresh account may simply not have one yet
  [ "$status" -eq 0 ]
  [ -d "$HOME/.Trash" ]
}

@test "trash_usable says no without a \$HOME" {
  _source_clean
  HOME="" run _clean_trash_usable
  [ "$status" -ne 0 ]
}

# --- orphaned scrollbacks -----------------------------------------------------
#
# 🔴 NOTHING EVER COLLECTED THESE. tmux_attach deletes the scrollback it made, on
# both of its exits — if it reaches one. A clikae killed mid-attach leaves the
# file, and the ephemeral GC above cannot see it: that loop is driven by
# `*-ephem-*.lock`, and an ordinary `clikae claude x` writes no lock. Found on a
# real machine: 14 orphans, oldest a week, zero locks.

@test "GC removes a scrollback whose writer is gone" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  # A pid that cannot be running: allocate one, then make sure it is not.
  local dead=999999
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  : > "$sdir/clikae-claude-x-$dead.scrollback"
  _clean_scrollback_gc 0
  [ ! -f "$sdir/clikae-claude-x-$dead.scrollback" ] || { echo "the orphan survived"; false; }
}

@test "GC keeps a scrollback whose writer is still running" {
  # The direction that matters: a session you stay attached to for three days has
  # a three-day-old scrollback and is very much alive. Age would delete it; the
  # writer's pid does not.
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  : > "$sdir/clikae-claude-x-$$.scrollback"
  _clean_scrollback_gc 0
  [ -f "$sdir/clikae-claude-x-$$.scrollback" ] || {
    echo "deleted a scrollback whose writer is this very process"; false; }
  rm -f "$sdir/clikae-claude-x-$$.scrollback"
}

@test "GC leaves a scrollback with no trailing pid alone" {
  # Not a name this code writes, so it is not this code's to delete.
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  : > "$sdir/someone-elses.scrollback"
  _clean_scrollback_gc 0
  [ -f "$sdir/someone-elses.scrollback" ] || { echo "deleted a file it does not own"; false; }
}

@test "GC dry run reports the orphan and deletes nothing" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999998
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  : > "$sdir/clikae-codex-m-$dead.scrollback"
  run _clean_scrollback_gc 1
  [[ "$output" == *"Would remove orphaned scrollback"* ]] || { echo "$output"; false; }
  [ -f "$sdir/clikae-codex-m-$dead.scrollback" ] || { echo "a dry run deleted it"; false; }
}

@test "GC sweeps orphans under the OLD prefix too" {
  # The 14 that started this were all `ck-*`; the sweep is prefix-agnostic on
  # purpose, and this pins that rather than trusting the glob.
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999997
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  : > "$sdir/ck-claude-h-$dead.scrollback"
  _clean_scrollback_gc 0
  [ ! -f "$sdir/ck-claude-h-$dead.scrollback" ] || { echo "the legacy orphan survived"; false; }
}

# --- orphaned .session_id state files (R1-P3-3 / R2-P3-5) ---------------------
#
# 🔴 NOTHING EVER COLLECTED THESE. tmux_set_session_id writes
# `<session>.session_id` as the fallback mirror of the `@clikae_session_id`
# tmux option; doctor.sh's "old names" line claims orphaned state files "go on
# the next `clikae clean`", which was not true for this file type until this.

@test "GC removes a .session_id file whose tmux session is gone" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  printf '%s\n' "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa" > "$sdir/clikae-claude-nosuch-$$.session_id"
  _clean_session_id_gc 0
  [ ! -f "$sdir/clikae-claude-nosuch-$$.session_id" ] || { echo "the orphan survived"; false; }
}

@test "GC keeps a .session_id file whose tmux session is still alive" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local sess="clikae-claude-alive-$$"
  tmux new-session -d -s "$sess" 'sleep 30'
  printf '%s\n' "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa" > "$sdir/$sess.session_id"
  _clean_session_id_gc 0
  tmux kill-session -t "$sess" 2>/dev/null || true
  [ -f "$sdir/$sess.session_id" ] || { echo "deleted a .session_id file whose session is alive"; false; }
  rm -f "$sdir/$sess.session_id"
}

@test "GC dry run reports the orphaned .session_id and deletes nothing" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  printf '%s\n' "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa" > "$sdir/clikae-claude-nosuch2-$$.session_id"
  run _clean_session_id_gc 1
  [[ "$output" == *"Would remove orphaned"* ]] || { echo "$output"; false; }
  [ -f "$sdir/clikae-claude-nosuch2-$$.session_id" ] || { echo "a dry run deleted it"; false; }
}

# --- dead-holder tank locks (R4-P3-2, R3-P3-3 before it) ----------------------
#
# 🔴 NOTHING ELSE EVER SWEPT THESE. `_burn_tank_lock_acquire` reclaims a dead
# holder's lock, but only when something calls it AGAIN for that exact
# engine/tank pair — a tank nobody ever burns again keeps a dead holder's lock
# (and, before round 4, could keep a permanently wedged reclaim mutex) forever.

@test "GC removes a tank lock whose holder is gone" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999996
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  ln -s "$dead:1700000000" "$sdir/tank-busy-codex_T1.lock"
  _clean_tank_lock_gc 0
  [ ! -L "$sdir/tank-busy-codex_T1.lock" ] || { echo "the dead-holder lock survived"; false; }
}

@test "GC keeps a tank lock whose holder is still running" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  ln -s "$$:1700000000" "$sdir/tank-busy-codex_T2.lock"
  _clean_tank_lock_gc 0
  [ -L "$sdir/tank-busy-codex_T2.lock" ] || {
    echo "deleted a tank lock whose holder is this very process"; false; }
  rm -f "$sdir/tank-busy-codex_T2.lock"
}

@test "GC removes a pid-less/malformed reclaim mutex link" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  # Non-empty but pid-less payload -- Linux's symlink(2) refuses an outright
  # empty target (ENOENT), so this stays constructible on every kernel while
  # still tripping the same malformed-payload branch as an empty one would.
  ln -s ":1700000000" "$sdir/tank-busy-codex_T3.lock.reclaim"
  _clean_tank_lock_gc 0
  [ ! -L "$sdir/tank-busy-codex_T3.lock.reclaim" ] || { echo "the malformed mutex survived"; false; }
}

@test "GC removes an orphaned reclaim graveyard entry whose reaper is gone" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999995
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  # Filename carries the REAPER's pid ($dead here), the target carries whoever
  # it evicted (irrelevant to this GC) — the liveness test is on the filename.
  ln -s "31337:1700000000" "$sdir/tank-busy-codex_T4.lock.reclaim.stale.$dead.12345"
  _clean_tank_lock_gc 0
  [ ! -L "$sdir/tank-busy-codex_T4.lock.reclaim.stale.$dead.12345" ] || {
    echo "the orphaned graveyard entry survived"; false; }
}

@test "GC keeps a reclaim graveyard entry whose reaper is still running" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  ln -s "31337:1700000000" "$sdir/tank-busy-codex_T5.lock.reclaim.stale.$$.12345"
  _clean_tank_lock_gc 0
  [ -L "$sdir/tank-busy-codex_T5.lock.reclaim.stale.$$.12345" ] || {
    echo "deleted a graveyard entry whose reaper is this very process"; false; }
  rm -f "$sdir/tank-busy-codex_T5.lock.reclaim.stale.$$.12345"
}

# --- R10-P2-1 (2026-09-12 round-10 review): the LOCK family's own
# restore-failure grave (`_burn_tank_lock_reap_verified`'s "could NOT
# restore" branch, lib/commands/burn.sh -- the only surviving copy of a
# live claim) has the identical shape as the mutex family's graveyard
# above, but this GC's glob (`tank-busy-*.lock.reclaim.stale.*`)
# structurally cannot match `tank-busy-*.lock.stale.*` (no `.reclaim.`
# segment) -- so it had no sweeper anywhere in this codebase and would
# accumulate forever. These pin the fix, mirroring the mutex-family pair
# right above one-for-one, and confirm the two globs never see each
# other's entries. -------------------------------------------------------

@test "GC (R10-P2-1) removes an orphaned LOCK-family graveyard entry whose reaper is gone" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999983
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  # Filename carries the REAPER's pid ($dead here); the target carries
  # whoever it could not restore (irrelevant to this GC) — same liveness
  # test as the mutex family, on the filename, not the target.
  ln -s "31337:1700000000" "$sdir/tank-busy-codex_T21.lock.stale.$dead.12345"
  run _clean_tank_lock_gc 0
  [ ! -L "$sdir/tank-busy-codex_T21.lock.stale.$dead.12345" ] || {
    echo "$output"; echo "-- the orphaned lock-family graveyard entry survived (R10-P2-1 regression)"; false; }
  # Real (non-dry-run) removals of graveyard entries are counted, not named
  # per-entry -- only the summary line reports them, same as the mutex
  # family's own sibling test above; per-entry naming is dry-run's job
  # (see the very next test).
  [[ "$output" == *"GC: removed 1 dead-holder tank lock(s)"* ]] || {
    echo "$output"; echo "-- the removal was not counted in the summary"; false; }
}

@test "GC (R10-P2-1) keeps a LOCK-family graveyard entry whose reaper is still running" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  ln -s "31337:1700000000" "$sdir/tank-busy-codex_T22.lock.stale.$$.12345"
  _clean_tank_lock_gc 0
  [ -L "$sdir/tank-busy-codex_T22.lock.stale.$$.12345" ] || {
    echo "deleted a lock-family graveyard entry whose reaper is this very process"; false; }
  rm -f "$sdir/tank-busy-codex_T22.lock.stale.$$.12345"
}

@test "GC --dry-run (R10-P2-1) names an orphaned LOCK-family graveyard entry and deletes nothing" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999982
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  ln -s "31337:1700000000" "$sdir/tank-busy-codex_T23.lock.stale.$dead.12345"
  run _clean_tank_lock_gc 1
  [[ "$output" == *"Would remove orphaned graveyard entry tank-busy-codex_T23.lock.stale.$dead.12345"* ]] || {
    echo "$output"; false; }
  [ -L "$sdir/tank-busy-codex_T23.lock.stale.$dead.12345" ] || { echo "a dry run deleted it"; false; }
}

@test "GC (R10-P2-1): the two graveyard globs never see each other's entries" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999981
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  # One entry from each family, same dead reaper pid — a naive combined
  # glob (or an accidental substring collision) would double-count or
  # cross-report one as the other's shape.
  ln -s "31337:1700000000" "$sdir/tank-busy-codex_T24.lock.stale.$dead.111"
  ln -s "31337:1700000000" "$sdir/tank-busy-codex_T24.lock.reclaim.stale.$dead.222"
  # Dry-run names each entry individually (unlike a real run, which only
  # counts them into the summary line — see the two tests above) — the
  # sharpest way to prove neither glob mis-sees the other's entry.
  run _clean_tank_lock_gc 1
  [[ "$output" == *"Would remove orphaned graveyard entry tank-busy-codex_T24.lock.stale.$dead.111"* ]] || {
    echo "$output"; echo "-- lock-family entry not named"; false; }
  [[ "$output" == *"Would remove orphaned graveyard entry tank-busy-codex_T24.lock.reclaim.stale.$dead.222"* ]] || {
    echo "$output"; echo "-- mutex-family entry not named"; false; }
  local n; n="$(printf '%s\n' "$output" | grep -c 'Would remove orphaned graveyard entry')"
  [ "$n" -eq 2 ] || { echo "$output"; echo "-- expected exactly 2 preview lines, got $n"; false; }
  [ -L "$sdir/tank-busy-codex_T24.lock.stale.$dead.111" ] && [ -L "$sdir/tank-busy-codex_T24.lock.reclaim.stale.$dead.222" ] || {
    echo "a dry run deleted something"; false; }
  rm -f "$sdir/tank-busy-codex_T24.lock.stale.$dead.111" "$sdir/tank-busy-codex_T24.lock.reclaim.stale.$dead.222"
}

@test "GC dry run reports a dead-holder tank lock and deletes nothing" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999994
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  ln -s "$dead:1700000000" "$sdir/tank-busy-codex_T6.lock"
  run _clean_tank_lock_gc 1
  [[ "$output" == *"Would remove dead-holder tank lock"* ]] || { echo "$output"; false; }
  [ -L "$sdir/tank-busy-codex_T6.lock" ] || { echo "a dry run deleted it"; false; }
}

# --- R5-P1-2 (2026-09-10 round-5 review): the GC used to remove the tank
# lock with NO mutex at all — a second, unguarded remover of the one thing
# this whole design depends on never having a second remover. Measured by
# the review: a real acquirer already past its own under-mutex re-verify and
# about to remove a lock it correctly judged stale, racing this GC — 5/5
# deterministic violations, a fresh contender's legitimate claim landing on
# the path GC vacated, then the original holder's now-stale `rm` deleting
# that fresh claim too (two burns on one tank, #40). -------------------------

@test "GC (R5-P1-2): skips a tank lock while its reclaim mutex is genuinely held, rather than racing it" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999993
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  local lock="$sdir/tank-busy-codex_T7.lock"
  ln -s "$dead:1700000000" "$lock"   # looks dead by the lock's own liveness read
  # Hold the reclaim mutex from a separate live process, exactly as a real
  # _burn_tank_lock_acquire/_release mid check-and-act on this exact lock
  # would — the GC must SKIP, not wait for it and not race it.
  ( _burn_reclaim_mutex_try "$lock.reclaim"; sleep 2 ) &
  local holder=$!
  sleep 0.3
  _clean_tank_lock_gc 0
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  [ -L "$lock" ] || { echo "GC removed a lock while its reclaim mutex was held by someone else"; false; }
}

@test "GC (R5-P1-2): skips a tank whose status file says a burn is RUNNING right now, independent of the lock's own liveness" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999992
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  local lock="$sdir/tank-busy-codex_T8.lock"
  ln -s "$dead:1700000000" "$lock"   # the LOCK's own recorded holder looks dead
  # But a status file (#41) says a burn is genuinely RUNNING on codex/T8
  # right now, using this test's own $$ (alive for the test's duration) —
  # the second, independent signal R5-P1-2 added.
  local d="$HOME/.clikae/logs/burn-$$-t8"; mkdir -p "$d"
  local now; now="$(date +%s)"
  printf '{"ok":null,"engine":"codex","tank":"T8","artifact":null,"artifact_bytes":null,"reason":null,"reset":null,"rerouted_from":[],"elapsed_s":0,"run_id":"burn-t8","state":"running","started_at":%s,"updated_at":%s,"pid":%s,"log":null}\n' \
    "$now" "$now" "$$" > "$d/status.json"
  _clean_tank_lock_gc 0
  [ -L "$lock" ] || { echo "GC removed a lock whose own status file said a burn is RUNNING"; false; }
}

# --- R6-P2-1 (2026-09-10 round-6 review): `--dry-run` used to preview a
# `.lock` removal with NO knowledge of whether its reclaim mutex was even
# claimable, and a `.lock.reclaim` removal with a bare `kill -0` -- both
# promises wrong on the same fixture the review measured. -------------------

@test "GC --dry-run (R6-P2-1): reports 'skipping', not 'Would remove', for a dead-holder lock whose reclaim mutex is genuinely held" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999989
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  local lock="$sdir/tank-busy-codex_T10.lock"
  ln -s "$dead:1700000000" "$lock"   # looks dead by the lock's own liveness read
  ( _burn_reclaim_mutex_try "$lock.reclaim"; sleep 2 ) &
  local holder=$!
  sleep 0.3
  run _clean_tank_lock_gc 1
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  [[ "$output" != *"Would remove dead-holder tank lock ${lock##*/}"* ]] || {
    echo "$output"; echo "-- dry run promised a removal the real run would have refused (mutex busy)"; false; }
  [[ "$output" == *"skipping ${lock##*/}"* ]] || { echo "$output"; false; }
  [ -L "$lock" ] || { echo "a dry run removed the lock"; false; }
}

@test "GC --dry-run (R6-P2-1): a dead-holder mutex link younger than 30s previews 'skipping', never a false promise, and is left untouched" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999988
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  local reclaim="$sdir/tank-busy-codex_T11.lock.reclaim"
  local before; before="${dead}:$(date +%s)"
  ln -s "$before" "$reclaim"   # dead, but recorded moments ago -- inside the 30s grace
  run _clean_tank_lock_gc 1
  [[ "$output" != *"Would remove dead-holder tank lock ${reclaim##*/}"* ]] || {
    echo "$output"; echo "-- dry run promised a removal the real run's own 30s grace would refuse"; false; }
  [ -L "$reclaim" ] || { echo "a dry run's own preview call destroyed the mutex link"; false; }
  [ "$(readlink "$reclaim")" = "$before" ] || {
    echo "a dry run's own preview call left the mutex claiming a DIFFERENT identity than before -- not side-effect-free"; false; }
  rm -f "$reclaim"
}

@test "GC --dry-run (R6-P2-1): a genuinely LIVE reclaim mutex is never claimed by the preview itself" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local lock="$sdir/tank-busy-codex_T12.lock"
  local dead=999987
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  ln -s "$dead:1700000000" "$lock"
  ( _burn_reclaim_mutex_try "$lock.reclaim"; sleep 2 ) &
  local holder=$!
  sleep 0.3
  local before; before="$(readlink "$lock.reclaim")"
  run _clean_tank_lock_gc 1
  local after; after="$(readlink "$lock.reclaim")"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  [ "$before" = "$after" ] || {
    echo "a dry run's own preview call changed who holds the reclaim mutex ($before -> $after)"; false; }
}

@test "GC (KITT/foreign-mutex): a bare DIRECTORY left at the .lock.reclaim path is refused, never swept, and reported as foreign-mutex" {
  # KITT (2026-09-11): the legacy-directory reclaim branch this test used to
  # cover is deleted -- this PR never shipped, so no released clikae ever
  # created a directory-shaped reclaim mutex. A directory at this path now
  # gets the SAME treatment as any other foreign object: refused, reported,
  # never removed.
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999986
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  local lock="$sdir/tank-busy-codex_T13.lock"
  ln -s "$dead:1700000000" "$lock"
  local reclaim="$sdir/tank-busy-codex_T13.lock.reclaim"
  mkdir -p "$reclaim"
  printf '%s' "$dead" > "$reclaim/pid"
  run _clean_tank_lock_gc 0
  [[ "$output" == *"foreign-mutex"* ]] || { echo "$output"; echo "-- refusal not reported under foreign-mutex"; false; }
  [ -d "$reclaim" ] && [ ! -L "$reclaim" ] || { echo "the foreign directory was removed"; false; }
  [ "$(cat "$reclaim/pid" 2>/dev/null)" = "$dead" ] || { echo "the foreign directory's own contents were touched"; false; }
  [ -L "$lock" ] || { echo "the dead-holder lock was removed even though its reclaim mutex refused"; false; }
}

@test "GC (R5-P1-2): a dead-holder mutex link (not a directory) is reaped through _burn_reclaim_mutex_try's own liveness rule" {
  # The mutex's OWN removal is now the same reap-with-verify primitive
  # everything else uses, not a bare kill -0 + rm -f (a third, weaker
  # liveness rule for the same object).
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999991
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  ln -s "${dead}:$(date +%s)" "$sdir/tank-busy-codex_T9.lock.reclaim"   # dead, but younger than 30s
  _clean_tank_lock_gc 0
  [[ -L "$sdir/tank-busy-codex_T9.lock.reclaim" ]] || {
    echo "GC reaped a mutex younger than 30s -- ignoring the age half of the shared rule"; false; }
  rm -f "$sdir/tank-busy-codex_T9.lock.reclaim"
}

# --- R7-P2-1 (2026-09-10 round-7 review): `_burn_reclaim_mutex_try` returns
# `1` both when a live holder refuses it AND when it just reaped a dead one
# (by design, it never claims a reap for the caller) -- the GC read both as
# "busy", so the single most common outcome (a dead lock whose mutex was
# simply reapable, not held) printed a reason that was definitely wrong and
# needed a SECOND `clean` run to actually remove the lock. Measured by the
# review: 3/3 fixtures where dry-run promised a removal the very next real
# run then refused. --------------------------------------------------------

@test "GC (R7-P2-1): a dead-holder lock whose reclaim mutex is REAPABLE (not held by anyone) is removed in ONE pass, never called \"busy\"" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999984
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  local lock="$sdir/tank-busy-codex_T17.lock"
  ln -s "$dead:1700000000" "$lock"            # dead by the lock's own liveness read
  ln -s "${dead}:1700000000" "$lock.reclaim"  # dead AND older than the 30s grace -- reapable, held by nobody
  run _clean_tank_lock_gc 0
  [[ "$output" != *"${lock##*/} -- its reclaim mutex is busy right now"* ]] || {
    echo "$output"; echo "-- called a mutex it just reaped in this same call \"busy\""; false; }
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || {
    echo "the lock survived a single GC pass even though its mutex was merely reapable, not genuinely held"; false; }
}

@test "GC --dry-run (R7-P2-1): agrees with the very next real run, not just with its own predicate" {
  # The dry-run predicate (_burn_reclaim_mutex_available) and the real rule
  # already agreed as PREDICATES (R6-P2-1's own tests); what R7-P2-1 found
  # is that the real GC's DECISION on a `try` of 1 did not agree with
  # either of them. Plant the exact reapable-mutex shape and confirm the
  # dry run's promise and the next real run's outcome now match.
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999983
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  local lock="$sdir/tank-busy-codex_T18.lock"
  ln -s "$dead:1700000000" "$lock"
  ln -s "${dead}:1700000000" "$lock.reclaim"
  run _clean_tank_lock_gc 1
  [[ "$output" == *"Would remove dead-holder tank lock ${lock##*/}"* ]] || { echo "$output"; false; }
  _clean_tank_lock_gc 0
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || {
    echo "dry run promised a removal the very next real run did not deliver"; false; }
}

# --- KITT (2026-09-11, extreme-subtraction ruling on R8-P1-1/R8-P1-2): the
# legacy-directory reclaim branch (and both of R7-P2-2's foreign-symlink-to-
# directory guards) is deleted -- this PR never shipped, so no released
# clikae ever created a directory-shaped reclaim mutex. One rule replaces
# all of it: a mutex path that is not a symlink whose target is plain data
# -- a directory, a symlink resolving to one, or a plain file -- is never
# touched. `clean`'s GC reports it under its own `foreign-mutex` reason and
# never removes it (no `--force` path in this PR). ---

@test "GC (KITT): a foreign symlink-to-directory at .lock.reclaim is refused and reported foreign-mutex, never reaped" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999985
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  local lock="$sdir/tank-busy-codex_T19.lock"
  ln -s "$dead:1700000000" "$lock"
  local target="$sdir/T19-foreign-target-dir"
  mkdir -p "$target"
  printf '%s' "$$" > "$target/pid"   # a LIVE pid (this test's own) inside the foreign target
  local reclaim="$sdir/tank-busy-codex_T19.lock.reclaim"
  ln -s "$target" "$reclaim"          # the mutex PATH is a symlink resolving to that directory
  run _clean_tank_lock_gc 0
  [[ "$output" == *"foreign-mutex"* ]] || { echo "$output"; echo "-- not reported under foreign-mutex"; false; }
  [ -L "$reclaim" ] && [ "$(readlink "$reclaim")" = "$target" ] || {
    echo "the foreign symlink-to-directory was removed or changed"; false; }
  [ -d "$target" ] && [ "$(cat "$target/pid" 2>/dev/null)" = "$$" ] || {
    echo "the reap touched the foreign directory's own contents"; false; }
  [ -L "$lock" ] || { echo "the dead-holder lock was removed even though its mutex refused"; false; }
  rm -rf "$target"
}

@test "GC (KITT): a bare directory at .lock.reclaim is refused and reported foreign-mutex, never reaped" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999984
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  local lock="$sdir/tank-busy-codex_T19B.lock"
  ln -s "$dead:1700000000" "$lock"
  local reclaim="$sdir/tank-busy-codex_T19B.lock.reclaim"
  mkdir -p "$reclaim"
  printf '%s' "$$" > "$reclaim/pid"
  run _clean_tank_lock_gc 0
  [[ "$output" == *"foreign-mutex"* ]] || { echo "$output"; echo "-- not reported under foreign-mutex"; false; }
  [ -d "$reclaim" ] && [ ! -L "$reclaim" ] || { echo "the bare directory was removed or changed"; false; }
  [ "$(cat "$reclaim/pid" 2>/dev/null)" = "$$" ] || { echo "the reap touched the directory's own contents"; false; }
  [ -L "$lock" ] || { echo "the dead-holder lock was removed even though its mutex refused"; false; }
}

@test "GC --dry-run (KITT): a foreign symlink-to-directory previews as foreign-mutex, never as removable or genuinely held" {
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local target="$sdir/T20-foreign-target-dir"
  mkdir -p "$target"
  printf '%s' "$$" > "$target/pid"
  local reclaim="$sdir/tank-busy-codex_T20.lock.reclaim"
  ln -s "$target" "$reclaim"
  run _burn_reclaim_mutex_available "$reclaim"
  [ "$status" -eq 1 ] || { echo "dry-run predicate says a foreign symlink-to-directory is available/removable"; false; }
  run _clean_tank_lock_gc 1
  [[ "$output" == *"foreign-mutex"* ]] || { echo "$output"; echo "-- dry-run preview did not name foreign-mutex"; false; }
  [[ "$output" != *"Would remove"*"T20"* ]] || { echo "$output"; echo "-- dry-run promised a removal that would never happen"; false; }
  [ -L "$reclaim" ] || { echo "the dry-run predicate itself mutated the entry"; false; }
  rm -rf "$target" "$reclaim"
}

@test "end-to-end (KITT): clikae clean refuses a foreign symlink-to-directory reclaim mutex, clikae burn stays refused until it is removed by hand, and both succeed once it is" {
  # The recovery path this design intentionally leaves: no --force in this
  # PR, so a human removes the foreign object, then `clean` and `burn` both
  # proceed exactly as if it had never been there.
  local bin="$BATS_TEST_TMPDIR/e2e-bin"; mkdir -p "$bin"
  cat > "$bin/codex" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "run" ] && [ -n "$2" ]; then : > "$2"; fi
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"

  clikae init codex T21
  local sdir="$CLIKAE_HOME/state"; mkdir -p "$sdir"
  local dead=999982
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  ln -s "$dead:1700000000" "$sdir/tank-busy-codex_T21.lock"
  local target="$sdir/T21-foreign-target-dir"
  mkdir -p "$target"
  printf '%s' "$$" > "$target/pid"
  ln -s "$target" "$sdir/tank-busy-codex_T21.lock.reclaim"

  run clikae clean --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"foreign-mutex"* ]] || { echo "$output"; false; }
  run clikae clean
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"foreign-mutex"* ]] || { echo "$output"; false; }
  [ -L "$sdir/tank-busy-codex_T21.lock" ] || {
    echo "$output"; echo "-- clean removed the dead-holder lock even though its mutex is foreign"; false; }
  [ -L "$sdir/tank-busy-codex_T21.lock.reclaim" ] || {
    echo "$output"; echo "-- clean removed the foreign symlink-to-directory itself"; false; }

  local artifact="$BATS_TEST_TMPDIR/e2e.md"
  run "$CLIKAE_BIN" burn codex T21 --artifact "$artifact" -- run "$artifact"
  [ "$status" -ne 0 ] || { echo "$output"; echo "-- burn claimed a tank whose reclaim mutex is still a foreign object"; false; }
  [ ! -f "$artifact" ] || { echo "burn's engine ran against a tank that should still be wedged"; false; }

  # A human removes the foreign object by hand, exactly as the refusal says to.
  rm -f "$sdir/tank-busy-codex_T21.lock.reclaim"
  run clikae clean
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"foreign-mutex"* ]] || { echo "$output"; echo "-- still reporting foreign-mutex after it was removed"; false; }
  [ ! -e "$sdir/tank-busy-codex_T21.lock" ] && [ ! -L "$sdir/tank-busy-codex_T21.lock" ] || {
    echo "$output"; echo "-- clean left the dead-holder lock behind once the foreign object was gone"; false; }

  run "$CLIKAE_BIN" burn codex T21 --artifact "$artifact" -- run "$artifact"
  [ "$status" -eq 0 ] || { echo "$output"; echo "-- burn still refused the tank after the foreign object was removed"; false; }
  [ -f "$artifact" ] || { echo "burn's engine never actually ran against the tank -- still wedged"; false; }
  rm -rf "$target"
}

# --- R6-P2-6 (2026-09-10 round-6 review): 36+64 tests and none of them ever
# asserted the ONE invariant this whole design rests on -- "no code path
# removes the tank-busy lock (or its reclaim mutex) without EITHER holding
# the reclaim mutex first OR operating only on a private graveyard name" --
# which is exactly how _clean_tank_lock_gc shipped 61/61 green while
# breaking that invariant (R5-P1-2). A structural, grep-based pin: every
# `rm`/`rmdir` touching `$lock`/`$grave` in burn.sh, or `$f` inside clean.sh's
# OWN `_clean_tank_lock_gc`, is enumerated and checked against a set already
# hand-classified below. `$lock`/`$grave`/`$reclaim_dir`/`$reclaim_link` are
# used as variable names ONLY by burn.sh's tank-lock/reclaim-mutex functions
# (confirmed: `grep -n '\$lock=\|\$grave=\|\$reclaim_dir=\|\$reclaim_link='`
# names only `_burn_tank_lock_acquire`/`_release`/`_burn_reclaim_mutex_try`),
# so this grep cannot be confused by an unrelated `$lock` elsewhere in the
# file.
#
# R7-P2-4 (2026-09-10 round-7 review): the original version of this pin
# enumerated ABSOLUTE LINE NUMBERS across the whole file, which two things
# defeat without proving anything about safety: (1) a PURE COMMENT added
# anywhere above line 1 renumbers every site below it, turning the pin red
# for an edit that added no remover at all; (2) the variable-name coverage
# was three spellings (`$lock`/`$grave`/`$1`) and did not include
# `$reclaim_dir`, so a real, bare, unguarded `rm -rf "$reclaim_dir"` dropped
# into an already-allow-listed function was invisible to the grep entirely.
# Fixed by pinning the SET OF ENCLOSING FUNCTION NAMES instead of line
# numbers, with comments stripped first, and widening the pattern to a
# fourth spelling.
#
# R8-P2-1 (2026-09-10 round-8 review): pinning the SET of function names,
# not the MULTISET of removal sites inside them, made the rewrite immune to
# a real remover too -- a SECOND bare `rm -f "$lock"` inserted into
# `_burn_tank_lock_release` (already on the allow-list) left the set
# byte-identical, and the pattern still lacked the `$reclaim_link` spelling
# the round-8 fix's own new guard removes by (`lib/commands/burn.sh`'s
# single foreign-mutex refusal, KITT ruling on R8-P1-1/R8-P1-2) -- both of
# the review's own committed mutations left the allow-list green. Fixed by
# counting OCCURRENCES per function (a `sort` without `-u`, so a second
# remover in an already-covered function changes the multiset) and adding
# the fifth spelling. clean.sh's already function-scoped check is similarly
# pinned by OFFSET from `_clean_tank_lock_gc`'s own start line, not an
# absolute line number, for the same reason.
_pin_burn_removal_functions() {
  awk '
    /^_burn_[a-zA-Z_]*\(\) \{/ { fn = $0; sub(/\(\).*/, "", fn) }
    $0 ~ /^[[:space:]]*#/ { next }
    { line = $0; sub(/[[:space:]]*#.*/, "", line) }
    line ~ /rm (-rf|-f) "\$(lock|grave|1|reclaim_dir|reclaim_link)"/ { print fn }
  ' "$1" | sort | paste -sd' ' -
}

# _pin_clean_tank_lock_gc_removals <clean.sh path> — clean.sh's half of the
# same pin, scoped to _clean_tank_lock_gc's OWN body ($f/$dir are reused by
# OTHER GCs in this file that have nothing to do with the tank-busy lock,
# so this must not grep the whole file). Found dynamically by function name
# + matching closing brace (never an absolute line number), comments
# stripped per line, and reports a MULTISET of matches ("RM" once per real
# removal line) rather than their offsets.
#
# R9-P2-5 (2026-09-11 round-9 review): the pre-round-9 version of this half
# pinned ABSOLUTE OFFSETS from the function's own start line ("62 63 147")
# -- R7-P2-4's own fix for the file-wide absolute-line-number version, but
# the SAME false-positive shape one level down: a PURE COMMENT inserted
# anywhere INSIDE the function's body shifts every offset after it,
# turning the pin red for an edit that added no remover at all (measured:
# "62 63 147" -> "63 64 148" for one comment line). And it had no mutation
# check at all -- unlike burn.sh's twin, nothing ever proved it goes red
# for a real remover. This is burn.sh's own fix (round 7's function-scoped,
# comment-stripped counting) applied to clean.sh's single function.
_pin_clean_tank_lock_gc_removals() {
  local clean="$1" gc_start gc_end
  gc_start="$(grep -n '^_clean_tank_lock_gc() {' "$clean" | head -1 | cut -d: -f1)"
  [ -n "$gc_start" ] || { echo "MISSING-FUNCTION-START"; return 1; }
  gc_end="$(awk -v s="$gc_start" 'NR>s && /^}/{print NR; exit}' "$clean")"
  [ -n "$gc_end" ] || { echo "MISSING-FUNCTION-END"; return 1; }
  awk -v s="$gc_start" -v e="$gc_end" '
    NR>=s && NR<=e {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      if (line ~ /rm (-rf|-f)[[:space:]]*"\$(f|dir)"/ || line ~ /rmdir[[:space:]]*"\$(f|dir)"/) print "RM"
    }
  ' "$clean" | sort | paste -sd' ' -
}

@test "structural (R6-P2-6/R7-P2-4/R8-P2-1): every removal touching the tank-busy lock or its reclaim mutex sits in an allow-listed function, and a SECOND one in an already-listed function is caught too" {
  local burn="$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  local clean="$CLIKAE_TEST_ROOT/lib/commands/clean.sh"

  # burn.sh: `$grave` sites are all a private graveyard name (`<path>.stale.
  # $$.$RANDOM`, unique per caller, never a rendezvous point) or a
  # verified-by-`readlink` restore-with-`ln -s` of a live holder's own claim
  # (R8-P1-1/R9-P1-1) followed by discarding the now-superfluous graveyard
  # copy; `$lock`/`$reclaim_dir` sites are all inside a branch that has
  # already won `_burn_reclaim_mutex_try` (or, in `_burn_tank_lock_release`'s
  # fast path, already recorded as holding it via
  # `_BURN_RECLAIM_MUTEX_OWNED`); the one `"$1"` site is
  # `_burn_reclaim_mutex_release` itself, removing the mutex link it names
  # ONLY after re-reading it and confirming it still names `$$` -- the
  # mutex's own identity-checked self-release, not something a SEPARATE
  # mutex needs to guard.
  #
  # R9-P1-1 (2026-09-11 round-9 review): `_burn_tank_lock_acquire`'s own
  # re-verify-under-the-mutex `rm -f "$lock"` moved into a new shared
  # helper, `_burn_tank_lock_reap_verified` -- one fewer site directly in
  # `_burn_tank_lock_acquire` (3 -> 2), two new `$grave` sites in the new
  # function (the same mv-then-classify shape `_burn_reclaim_mutex_try`
  # already has: discard on a match, restore-and-verify on a mismatch).
  run bash -c "$(declare -f _pin_burn_removal_functions); _pin_burn_removal_functions '$burn'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "_burn_reclaim_mutex_release _burn_reclaim_mutex_try _burn_reclaim_mutex_try _burn_tank_lock_acquire _burn_tank_lock_acquire _burn_tank_lock_reap_verified _burn_tank_lock_reap_verified _burn_tank_lock_release _burn_tank_lock_release" ] || {
    echo "burn.sh's lock/mutex/graveyard removal sites changed shape: [$output]"
    echo "-- classify the new/moved site (mutex-guarded / private graveyard /"
    echo "   mutex's own identity-checked self-release) and update this allow-list,"
    echo "   or revert it if it is a bare, unguarded remover."
    false
  }

  # clean.sh: scoped to _clean_tank_lock_gc's OWN body -- $f is reused by
  # OTHER GCs in this file (scrollback, tmux) that have nothing to do with
  # the tank-busy lock, so this must not grep the whole file. See
  # _pin_clean_tank_lock_gc_removals's own header (above) for why this is a
  # match-count, not an offset list (R9-P2-5).
  run bash -c "$(declare -f _pin_clean_tank_lock_gc_removals); _pin_clean_tank_lock_gc_removals '$clean'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "RM" ] || {
    echo "clean.sh's _clean_tank_lock_gc removal-line count changed: [$output]"
    echo "-- classify the new/moved line and update this pin, or revert it."
    false
  }
}

@test "structural (R6-P2-6/R7-P2-4/R8-P2-1) mutation check: the pin itself goes RED on both of the review's committed mutations, and stays green on a pure comment" {
  # R8-P2-1's own finding: the previous version of this test only asserted
  # that the pin's grep matched the injected line's TEXT, never that calling
  # _pin_burn_removal_functions on the MUTATED file actually differs from
  # baseline -- so it never proved the pin goes red for a real remover. This
  # version asserts the pin's own output changes (or doesn't), directly.
  local burn="$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  local baseline
  baseline="$(_pin_burn_removal_functions "$burn")"
  [ "$baseline" = "_burn_reclaim_mutex_release _burn_reclaim_mutex_try _burn_reclaim_mutex_try _burn_tank_lock_acquire _burn_tank_lock_acquire _burn_tank_lock_reap_verified _burn_tank_lock_reap_verified _burn_tank_lock_release _burn_tank_lock_release" ] || {
    echo "baseline allow-list already disagrees with the test above -- fix that test first: [$baseline]"; false; }

  # MUTATION A -- a real, bare, unguarded SECOND `rm -f "$lock"` inserted
  # right after _burn_tank_lock_release's own opening lines: an
  # already-covered spelling, in an already-allow-listed function -- the
  # exact shape R8-P2-1 found the SET-based pin blind to.
  local release_line mutated_a mutated_a_pin
  release_line="$(grep -n '^_burn_tank_lock_release() {' "$burn" | head -1 | cut -d: -f1)"
  [ -n "$release_line" ] || { echo "_burn_tank_lock_release's own definition line moved or was renamed"; false; }
  mutated_a="$BATS_TEST_TMPDIR/burn_mutation_a.sh"
  awk -v n="$release_line" '
    NR==n { print; print "  rm -f \"$lock\" 2>/dev/null   # MUTATION-A: bare, unguarded, second remover"; next }
    { print }
  ' "$burn" > "$mutated_a"
  grep -q 'MUTATION-A: bare, unguarded' "$mutated_a" || { echo "mutation A did not apply -- _burn_tank_lock_release's shape changed upstream"; false; }
  mutated_a_pin="$(_pin_burn_removal_functions "$mutated_a")"
  [ "$mutated_a_pin" != "$baseline" ] || {
    echo "the pin did NOT go red for a real, bare, unguarded second rm -- R8-P2-1 regression"
    echo "baseline: [$baseline]  mutation A: [$mutated_a_pin]"
    false
  }

  # MUTATION B -- R7-P2-4's own gap: a real, bare, unguarded
  # `rm -rf "$reclaim_dir"` inserted into _burn_tank_lock_acquire's own
  # opening lines, a DIFFERENT variable spelling than `$lock`/`$grave`/`$1`.
  local acquire_line mutated_b mutated_b_pin
  acquire_line="$(grep -n '^_burn_tank_lock_acquire() {' "$burn" | head -1 | cut -d: -f1)"
  [ -n "$acquire_line" ] || { echo "_burn_tank_lock_acquire's own definition line moved or was renamed"; false; }
  mutated_b="$BATS_TEST_TMPDIR/burn_mutation_b.sh"
  awk -v n="$acquire_line" '
    NR==n { print; print "  rm -rf \"$reclaim_dir\" 2>/dev/null   # MUTATION-B: bare, unguarded, different spelling"; next }
    { print }
  ' "$burn" > "$mutated_b"
  grep -q 'MUTATION-B: bare, unguarded' "$mutated_b" || { echo "mutation B did not apply -- _burn_tank_lock_acquire's shape changed upstream"; false; }
  mutated_b_pin="$(_pin_burn_removal_functions "$mutated_b")"
  [ "$mutated_b_pin" != "$baseline" ] || {
    echo "the pin did NOT go red for a bare rm -rf \"\$reclaim_dir\" -- R7-P2-4 regression"
    echo "baseline: [$baseline]  mutation B: [$mutated_b_pin]"
    false
  }

  # MUTATION E -- R8-P2-1's own gap: a real, bare, unguarded
  # `rm -f "$reclaim_link"` inserted into _burn_tank_lock_acquire's own
  # opening lines -- the exact spelling this round's own new guard
  # (lib/commands/burn.sh's single foreign-mutex refusal) removes by, at the
  # one site the round-8 review measured a live claim deleted in silence
  # (5/5) with no verification of any kind.
  local mutated_e mutated_e_pin
  mutated_e="$BATS_TEST_TMPDIR/burn_mutation_e.sh"
  awk -v n="$acquire_line" '
    NR==n { print; print "  rm -f \"$reclaim_link\" 2>/dev/null   # MUTATION-E: bare, unguarded, reclaim_link spelling"; next }
    { print }
  ' "$burn" > "$mutated_e"
  grep -q 'MUTATION-E: bare, unguarded' "$mutated_e" || { echo "mutation E did not apply -- _burn_tank_lock_acquire's shape changed upstream"; false; }
  mutated_e_pin="$(_pin_burn_removal_functions "$mutated_e")"
  [ "$mutated_e_pin" != "$baseline" ] || {
    echo "the pin did NOT go red for a bare rm -f \"\$reclaim_link\" -- R8-P2-1 regression"
    echo "baseline: [$baseline]  mutation E: [$mutated_e_pin]"
    false
  }
  # The OLD (pre-round-8) pattern is the control: it must NOT see MUTATION-E
  # at all, which is exactly how this spelling shipped invisible to the pin
  # in the same commit that added it.
  run bash -c "grep -nE 'rm (-rf|-f) \"\\\$(lock|grave|1|reclaim_dir)\"' '$mutated_e' | grep -F 'MUTATION-E'"
  [ "$status" -ne 0 ] || { echo "the OLD pattern saw \$reclaim_link too -- this is no longer demonstrating the R8-P2-1 gap"; false; }

  # CONTROL -- a pure comment, no remover at all, prepended above everything
  # (the R7-P2-4 false-positive shape: maximal renumbering, zero new
  # removers). The allow-list must be BYTE-IDENTICAL to baseline.
  local commented
  commented="$BATS_TEST_TMPDIR/burn_comment.sh"
  { printf '# a harmless comment mentioning rm -f "$lock" for illustration only\n'; cat "$burn"; } > "$commented"
  local after_comment
  after_comment="$(_pin_burn_removal_functions "$commented")"
  [ "$after_comment" = "$baseline" ] || {
    echo "a pure comment prepended above everything turned the pin red -- it is not immune to renumbering (R7-P2-4)"
    echo "baseline: [$baseline]  after comment: [$after_comment]"
    false
  }
}

@test "structural (R9-P2-5) mutation check: clean.sh's OWN half of the pin goes RED on a real new remover and stays GREEN on a pure comment inside the function" {
  # R9-P2-5 (2026-09-11 round-9 review): the pre-round-9 version of this
  # half was a list of absolute OFFSETS from the function's own start line
  # ("62 63 147") with NO mutation check anywhere -- unlike burn.sh's twin,
  # nothing ever proved it goes red for a real remover, and a pure comment
  # inserted inside the function (not just above it) shifted every offset
  # after it and turned the pin red for an edit that added no remover at
  # all (measured: "62 63 147" -> "63 64 148" for one comment line). This
  # test is the mutation check that pin never had, against the count-based
  # replacement (which reads by name + closing brace and strips comments,
  # so a comment inside the function changes nothing it counts).
  local clean="$CLIKAE_TEST_ROOT/lib/commands/clean.sh"
  local baseline
  baseline="$(_pin_clean_tank_lock_gc_removals "$clean")"
  [ "$baseline" = "RM" ] || {
    echo "baseline already disagrees with the test above -- fix that test first: [$baseline]"; false; }

  # MUTATION-N -- a real, bare, unguarded, NEW `rm -rf "$dir"` inserted
  # right after _clean_tank_lock_gc's own opening lines: a real removal
  # this function's body did not have before.
  local gc_line mutated_n mutated_n_pin
  gc_line="$(grep -n '^_clean_tank_lock_gc() {' "$clean" | head -1 | cut -d: -f1)"
  [ -n "$gc_line" ] || { echo "_clean_tank_lock_gc's own definition line moved or was renamed"; false; }
  mutated_n="$BATS_TEST_TMPDIR/clean_mutation_n.sh"
  awk -v n="$gc_line" '
    NR==n { print; print "  rm -rf \"$dir\" 2>/dev/null   # MUTATION-N: bare, unguarded, new remover"; next }
    { print }
  ' "$clean" > "$mutated_n"
  grep -q 'MUTATION-N: bare, unguarded' "$mutated_n" || { echo "mutation N did not apply -- _clean_tank_lock_gc's shape changed upstream"; false; }
  mutated_n_pin="$(_pin_clean_tank_lock_gc_removals "$mutated_n")"
  [ "$mutated_n_pin" != "$baseline" ] || {
    echo "the pin did NOT go red for a real, bare, unguarded new remover"
    echo "baseline: [$baseline]  mutation N: [$mutated_n_pin]"
    false
  }

  # CONTROL -- a pure comment, no remover at all, inserted INSIDE the
  # function's body (not merely above the whole file, which is what the
  # burn.sh control above tests) -- the exact shape that shifted the OLD
  # offset-based pin's numbers and turned it red for nothing.
  local commented commented_pin
  commented="$BATS_TEST_TMPDIR/clean_comment.sh"
  awk -v n="$gc_line" '
    NR==n { print; print "  # a harmless comment mentioning rm -f \"$f\" for illustration only"; next }
    { print }
  ' "$clean" > "$commented"
  commented_pin="$(_pin_clean_tank_lock_gc_removals "$commented")"
  [ "$commented_pin" = "$baseline" ] || {
    echo "a pure comment inside the function turned the pin red -- it is not immune to renumbering (R9-P2-5, R7-P2-4's own shape one level down)"
    echo "baseline: [$baseline]  after comment: [$commented_pin]"
    false
  }
}
