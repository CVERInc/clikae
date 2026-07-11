#!/usr/bin/env bats
# tests/bats/resume-cleanup.bats — `clikae resume cleanup`: the stale-copy
# reclaim (relay/cross-tank resume copies), the orphaned-sid-dir sweep, the
# --min-size axis, and the byte-level safety check that gates deduping.
#
# The interactive checkbox picker itself needs a real pty (tests/tools/
# pty-smoke.py territory); everything here goes through --dry-run — which must
# print the same list — or calls the safety-check helpers directly.

load '../helpers'

# Bring _resume_stale_copy_check + friends into THIS bats process, in the same
# order bin/clikae sources them — needed only by the unit-level tests; the
# dry-run tests drive the real `clikae` binary.
_source_resume() {
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
  # shellcheck source=../../lib/commands/resume.sh
  source "$CLIKAE_LIB/commands/resume.sh"
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

# --- _resume_stale_copy_check (unit) -------------------------------------------

@test "stale check: an exact byte-prefix copy is safe" {
  _source_resume
  local kept cand
  kept="$(_seed_lines a 11111111-2222-3333-4444-555555555555 200)"
  cand="$TEST_HOME/cand.jsonl"
  head -n 100 "$kept" > "$cand"
  _resume_stale_copy_check "$kept" "$cand"
}

@test "stale check: a byte-identical copy is safe (the exactly-n-bytes BSD cmp edge)" {
  # BSD `cmp -s -n <sz> A B` exits 1 ("EOF") when B is exactly <sz> bytes, which
  # would misread every byte-identical relay copy as diverged. The head|cmp form
  # must pass this.
  _source_resume
  local kept cand
  kept="$(_seed_lines a 22222222-2222-3333-4444-555555555555 50)"
  cand="$TEST_HOME/cand.jsonl"
  cp "$kept" "$cand"
  _resume_stale_copy_check "$kept" "$cand"
}

@test "stale check: a metadata-only tail after the shared prefix is safe" {
  _source_resume
  local kept cand
  kept="$(_seed_lines a 33333333-2222-3333-4444-555555555555 80)"
  cand="$TEST_HOME/cand.jsonl"
  head -n 60 "$kept" > "$cand"
  printf '{"type":"ai-title","title":"a title"}\n' >> "$cand"
  printf '{"type":"last-prompt","prompt":"a prompt"}\n' >> "$cand"
  printf '{"type":"permission-mode","mode":"plan"}\n' >> "$cand"
  _resume_stale_copy_check "$kept" "$cand"
}

@test "stale check: a conversation line after the shared prefix diverges" {
  _source_resume
  local kept cand
  kept="$(_seed_lines a 44444444-2222-3333-4444-555555555555 80)"
  cand="$TEST_HOME/cand.jsonl"
  head -n 60 "$kept" > "$cand"
  printf '{"type":"user","message":{"role":"user","content":"UNIQUE user turn"}}\n' >> "$cand"
  run _resume_stale_copy_check "$kept" "$cand"
  [ "$status" -ne 0 ]
}

@test "stale check: a divergence deeper than the last 4096 bytes diverges" {
  _source_resume
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
  run _resume_stale_copy_check "$kept" "$cand"
  [ "$status" -ne 0 ]
}

# --- dedupe scan (through `clikae resume cleanup --dry-run`) --------------------

@test "cleanup dedupes copies of one session and keeps the LARGEST, not the newest" {
  local sid="66666666-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 200 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/b/projects/-w"
  head -n 100 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" \
    > "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"
  # The SMALLER copy is the newer one — mtime must not decide.
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl"
  touch -t 202606250000 "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"

  run clikae resume cleanup --dry-run --older-than 9999
  [ "$status" -eq 0 ]
  # Both copies are recent for the age filter (9999d finds nothing regular), yet
  # the redundant copy is offered anyway: dedupe bypasses the filters.
  [[ "$output" == *"claude/b"* ]] || false
  [[ "$output" == *"stale copy (kept: a)"* ]] || false
  [[ "$output" != *"claude/a"* ]] || false
}

@test "cleanup groups copies across project dirs of the SAME tank (project rename)" {
  local sid="77777777-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 120 >/dev/null
  local old_dir="$CLIKAE_HOME/profiles/claude/a/projects/-old-name"
  mkdir -p "$old_dir"
  head -n 40 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" > "$old_dir/$sid.jsonl"
  run clikae resume cleanup --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale copy (kept: a)"* ]] || false
}

@test "cleanup lists a diverged copy unchecked instead of auto-selecting it" {
  local sid="88888888-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 80 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/b/projects/-w"
  head -n 60 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" \
    > "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"UNIQUE tail"}}\n' \
    >> "$CLIKAE_HOME/profiles/claude/b/projects/-w/$sid.jsonl"

  run clikae resume cleanup --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"diverged — not auto-selected"* ]] || false
  [[ "$output" == *"[ ] claude/b"* ]] || false
  # Not selected → not counted.
  [[ "$output" == *"Total sessions to clean: 0"* ]] || false
}

@test "cleanup skips a dedupe group whose sid has a live process" {
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

  run clikae resume cleanup --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"stale copy"* ]] || false
}

# --- orphaned sid dirs ----------------------------------------------------------

@test "cleanup offers an orphaned claude sid dir (transcript already gone)" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/a/projects/-w/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/subagents"
  echo x > "$CLIKAE_HOME/profiles/claude/a/projects/-w/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/subagents/t.jsonl"
  run clikae resume cleanup --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"orphaned subagent data"* ]] || false
}

@test "cleanup does NOT flag a sid dir whose transcript still exists, nor a non-sid dir" {
  local sid="bbbbbbbb-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 5 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid/subagents"     # has its transcript
  mkdir -p "$CLIKAE_HOME/profiles/claude/a/projects/-w/not-a-session-dir"  # not uuid-shaped
  run clikae resume cleanup --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"orphaned subagent data"* ]] || false
}

@test "cleanup prices a claude transcript together with its sibling sid dir" {
  local sid="cccccccc-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 2 >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid/subagents"
  dd if=/dev/zero of="$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid/subagents/big.jsonl" \
    bs=1024 count=3072 2>/dev/null
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl"
  run clikae resume cleanup --dry-run
  [ "$status" -eq 0 ]
  # A ~200 B transcript alone would price in KB; the bundled sid dir puts it in MB.
  [[ "$output" == *"3.0 MB"* ]] || false
}

# --- --min-size -----------------------------------------------------------------

@test "cleanup --min-size alone filters by size only (no age cutoff)" {
  local big="dddddddd-2222-3333-4444-555555555555"
  local small="eeeeeeee-2222-3333-4444-555555555555"
  _seed_lines a "$small" 3 >/dev/null
  { printf '{"type":"user","cwd":"/tmp/w","message":{"role":"user","content":"big session"}}\n'
    dd if=/dev/zero bs=1024 count=2048 2>/dev/null | LC_ALL=C tr '\0' 'a'; echo
  } > "$CLIKAE_HOME/profiles/claude/a/projects/-w/$big.jsonl"

  run clikae resume cleanup --dry-run --min-size 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"big session"* ]] || false
  [[ "$output" != *"conversation line"* ]] || false
  [[ "$output" == *"Total sessions to clean: 1"* ]] || false
}

@test "cleanup --min-size with --older-than requires BOTH (a recent big file is excluded)" {
  local big="ffffffff-2222-3333-4444-555555555555"
  mkdir -p "$CLIKAE_HOME/profiles/claude/a/projects/-w"
  { printf '{"type":"user","cwd":"/tmp/w","message":{"role":"user","content":"big recent"}}\n'
    dd if=/dev/zero bs=1024 count=2048 2>/dev/null | LC_ALL=C tr '\0' 'a'; echo
  } > "$CLIKAE_HOME/profiles/claude/a/projects/-w/$big.jsonl"

  run clikae resume cleanup --dry-run --min-size 1 --older-than 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"No sessions older than 30 days and at least 1 MB found"* ]] || false

  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$big.jsonl"
  run clikae resume cleanup --dry-run --min-size 1 --older-than 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"big recent"* ]] || false
}

@test "cleanup --min-size rejects a non-numeric value" {
  run clikae resume cleanup --min-size lots
  [ "$status" -ne 0 ]
  [[ "$output" == *"--min-size requires a numeric"* ]] || false
}

# --- guardrails -----------------------------------------------------------------

@test "cleanup still refuses to delete without an interactive confirmation (non-TTY)" {
  local sid="a1a1a1a1-2222-3333-4444-555555555555"
  _seed_lines a "$sid" 5 >/dev/null
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl"
  run clikae resume cleanup
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to delete without an interactive confirmation"* ]] || false
  [ -f "$CLIKAE_HOME/profiles/claude/a/projects/-w/$sid.jsonl" ]
}

@test "cleanup --help documents the new axes" {
  run clikae resume cleanup --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--min-size"* ]] || false
  [[ "$output" == *"stale copies"* ]] || false
  [[ "$output" == *"orphaned subagent data"* ]] || false
}
