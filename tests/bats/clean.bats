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
  # shellcheck source=../../lib/commands/clean.sh
  source "$CLIKAE_LIB/commands/clean.sh"
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

# --- _clean_to_trash (unit): move, never rm — collision-safe, honest fallback ---
# HOME == TEST_HOME (helpers.bash), so $HOME/.Trash is a throwaway fixture path;
# never the real ~/.Trash.

@test "to_trash moves a file into \$HOME/.Trash and the original is gone" {
  _source_clean
  local f="$TEST_HOME/session-a.jsonl"
  echo "conversation" > "$f"
  _clean_to_trash "$f"
  [ "$CLEAN_TRASH_FELL_BACK" -eq 0 ]
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
  [ "$CLEAN_TRASH_FELL_BACK" -eq 0 ]
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
  [ "$CLEAN_TRASH_FELL_BACK" -eq 0 ]
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

@test "to_trash falls back to rm AND reports it when the Trash is unusable" {
  _source_clean
  # A FILE (not a dir) sitting where ~/.Trash should be: mkdir -p fails, and the
  # pre-existing-dir check also fails — the realistic shape of "Trash got
  # replaced/corrupted", no root/chmod tricks needed.
  rm -rf "$HOME/.Trash"
  printf 'not a directory' > "$HOME/.Trash"
  local f="$TEST_HOME/orphan.jsonl"
  echo "data" > "$f"
  _clean_to_trash "$f"
  [ "$CLEAN_TRASH_FELL_BACK" -eq 1 ]
  [ -z "$CLEAN_TRASH_DEST" ]
  [ ! -e "$f" ]     # gone via the honest rm fallback, not stuck
}

@test "to_trash with no \$HOME falls back to rm and reports it" {
  _source_clean
  local f="$TEST_HOME/nohome.jsonl"
  echo "data" > "$f"
  HOME="" _clean_to_trash "$f"
  [ "$CLEAN_TRASH_FELL_BACK" -eq 1 ]
  [ ! -e "$f" ]
}

@test "to_trash on a path that doesn't exist is a no-op, not a fallback" {
  _source_clean
  _clean_to_trash "$TEST_HOME/never-existed.jsonl"
  [ "$CLEAN_TRASH_FELL_BACK" -eq 0 ]
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

@test "no clean --dry-run line exceeds 80 columns, in any of the nine locales" {
  # Measured with unicodedata.east_asian_width — the TRUE display width — not
  # with lib's own `_dwidth`. _dwidth is a bash-3.2-safe byte heuristic that
  # OVER-counts (an accented Latin char costs 2 bytes -> +0.5 col, a 3-byte "…"
  # -> 2 cols), which is exactly what you want in the RENDER (it budgets
  # conservatively, so it can only under-fill, never overflow) but would make
  # this assertion lie in both directions. Skip rather than fake it if python3
  # isn't around — same pattern as list.bats/status.bats' JSON checks.
  command -v python3 >/dev/null || skip "python3 not available to measure display width"
  local sid="34343434-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 200 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/b/projects/-w"
  head -n 100 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" \
    > "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"
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
