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
  ln -s "" "$sdir/tank-busy-codex_T3.lock.reclaim"
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

@test "GC (R6-P1-1 fix shape): a legacy DIRECTORY left at the .lock.reclaim path is swept, not skipped for lacking a symlink" {
  # clean.sh:1027's old `[ -L "$f" ] || continue` made a legacy directory at
  # this exact path invisible to `clean` -- the one thing that made R6-P1-1
  # a permanent wedge instead of a recoverable one. _burn_reclaim_mutex_try
  # already understands this shape; the GC's own loop just had to stop
  # filtering it out.
  _source_clean
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999986
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  local reclaim="$sdir/tank-busy-codex_T13.lock.reclaim"
  mkdir -p "$reclaim"
  printf '%s' "$dead" > "$reclaim/pid"
  _clean_tank_lock_gc 0
  [[ ! -e "$reclaim" ]] || { echo "a legacy directory with a dead recorded pid survived clean's GC"; false; }
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

# --- R6-P2-6 (2026-09-10 round-6 review): 36+64 tests and none of them ever
# asserted the ONE invariant this whole design rests on -- "no code path
# removes the tank-busy lock (or its reclaim mutex) without EITHER holding
# the reclaim mutex first OR operating only on a private graveyard name" --
# which is exactly how _clean_tank_lock_gc shipped 61/61 green while
# breaking that invariant (R5-P1-2). A structural, grep-based pin: every
# `rm`/`rmdir` touching `$lock`/`$grave` in burn.sh, or `$f` inside clean.sh's
# OWN `_clean_tank_lock_gc`, is enumerated by line number and checked
# against the exact set already hand-classified below. `$lock` and `$grave`
# are used as variable names ONLY by burn.sh's tank-lock/reclaim-mutex
# functions (confirmed: `grep -n '\$lock=\|\$grave='` names only
# `_burn_tank_lock_acquire`/`_release`/`_burn_reclaim_mutex_try`), so this
# grep cannot be confused by an unrelated `$lock` elsewhere in the file. -----

@test "structural (R6-P2-6): every removal touching the tank-busy lock or its reclaim mutex is a known, hand-classified site -- a NEW one fails this test" {
  local burn="$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  local clean="$CLIKAE_TEST_ROOT/lib/commands/clean.sh"

  # burn.sh: $grave sites are all a private graveyard name (`<path>.stale.
  # $$.$RANDOM`, unique per caller, never a rendezvous point); $lock sites
  # are all inside a branch that has already won `_burn_reclaim_mutex_try`
  # (or, in `_burn_tank_lock_release`'s fast path, already recorded as
  # holding it via `_BURN_RECLAIM_MUTEX_OWNED`); the one `"$1"` site is
  # `_burn_reclaim_mutex_release` itself, removing the mutex link it names
  # ONLY after re-reading it and confirming it still names `$$` -- the
  # mutex's own identity-checked self-release, not something a SEPARATE
  # mutex needs to guard.
  run bash -c "grep -nE 'rm (-rf|-f) \"\\\$(lock|grave|1)\"' '$burn' | cut -d: -f1 | paste -sd' ' -"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "1138 1172 1174 1233 1274 1309 1474 1495 1576 1636 1649" ] || {
    echo "burn.sh's lock/mutex/graveyard removal sites changed: [$output]"
    echo "-- classify the new/moved line (mutex-guarded / private graveyard /"
    echo "   mutex's own identity-checked self-release) and update this pin,"
    echo "   or revert it if it is a bare, unguarded remover."
    false
  }

  # clean.sh: scoped to _clean_tank_lock_gc's OWN body -- $f is reused by
  # OTHER GCs in this file (scrollback, tmux) that have nothing to do with
  # the tank-busy lock, so this must not grep the whole file. Bounded by
  # line range (function start to its own closing `}`) rather than by
  # nesting an awk pattern inside `bash -c`'s own quoting.
  local gc_start gc_end
  gc_start="$(grep -n '^_clean_tank_lock_gc() {' "$clean" | head -1 | cut -d: -f1)"
  [ -n "$gc_start" ] || { echo "_clean_tank_lock_gc's own definition line moved or was renamed"; false; }
  gc_end="$(awk -v s="$gc_start" 'NR>s && /^}/{print NR; exit}' "$clean")"
  [ -n "$gc_end" ] || { echo "could not find _clean_tank_lock_gc's closing brace"; false; }
  run bash -c "grep -nE 'rm (-rf|-f)|rmdir' '$clean' | awk -F: -v s=$gc_start -v e=$gc_end '\$1>=s && \$1<=e {print \$1}' | paste -sd' ' -"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "1045 1046 1105" ] || {
    echo "clean.sh's _clean_tank_lock_gc removal sites changed: [$output]"
    echo "-- classify the new/moved line and update this pin, or revert it."
    false
  }
}

@test "structural (R6-P2-6) mutation check: a bare, unguarded rm -f \"\$lock\" turns the pin above red" {
  # Proves the pin test above is a real ruler, not a tautology: copy
  # burn.sh, drop one unguarded removal into a function that already uses
  # $lock (so the ONLY thing wrong with it is the missing guard), and
  # confirm the exact grep the test above runs now returns a DIFFERENT set.
  local burn="$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  local mutated="$BATS_TEST_TMPDIR/burn_mutated.sh"
  cp "$burn" "$mutated"
  # Insert a bare, unconditional removal right after _burn_tank_lock_release
  # computes $lock -- no mutex, no owner check, nothing guarding it.
  perl -0pi -e 's/(_burn_tank_lock_release\(\) \{\n  local lock reclaim_dir target holder tries=0\n  lock="\$\(_burn_tank_lock_path "\$1" "\$2"\)"\n)/$1  rm -f "\$lock" 2>\/dev\/null   # MUTATION: bare, unguarded\n/' "$mutated"
  grep -q 'MUTATION: bare, unguarded' "$mutated" || { echo "mutation did not apply -- _burn_tank_lock_release's shape changed upstream"; false; }

  run bash -c "grep -nE 'rm (-rf|-f) \"\\\$(lock|grave|1)\"' '$mutated' | cut -d: -f1 | paste -sd' ' -"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" != "1138 1172 1174 1233 1274 1309 1474 1495 1576 1636 1649" ] || {
    echo "the pin test's grep did not notice the injected unguarded rm -f \"\$lock\" -- it is not a real ruler"
    false
  }
}
