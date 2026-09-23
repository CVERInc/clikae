#!/usr/bin/env bats
# tests/bats/adapters/codex.bats — the codex adapter's session-continuity hooks
# that let codex sessions show up in the board's "Continue" list (HANDOFF §12).
# Sources the adapter directly and feeds it fabricated rollout JSONL; no network,
# no real codex. (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../../helpers'

_setup_codex() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"   # sessions_by_mtime (shared kernel)
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/codex.sh"
  WORK="$TEST_HOME/work"; mkdir -p "$WORK"; cd "$WORK" || return 1
  PROFILE="$TEST_HOME/cprofile"
  SDIR="$PROFILE/sessions"
  mkdir -p "$SDIR/2026/06/03"
}

# seed_rollout <sid> <cwd> <prompt> [hhmmss]
seed_rollout() {
  local sid="$1" cwd="$2" prompt="$3" ts="${4:-10-00-00}"
  local f="$SDIR/2026/06/03/rollout-2026-06-03T$ts-$sid.jsonl"
  {
    printf '{"timestamp":"2026-06-03T01:00:00.000Z","type":"session_meta","payload":{"id":"%s","cwd":"%s","originator":"codex_exec"}}\n' "$sid" "$cwd"
    printf '{"type":"event_msg","payload":{"type":"user_message","message":"%s"}}\n' "$prompt"
  } > "$f"
}

@test "codex recent_sids lists a session whose recorded cwd is the current dir" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-000000000001 "$WORK" "fix the build"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"019e0000-0000-7000-8000-000000000001"* ]] || false
}

@test "codex recent_sids EXCLUDES sessions recorded in a different cwd" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-00000000aaaa "$WORK"        "here"  10-00-00
  seed_rollout 019e0000-0000-7000-8000-00000000bbbb "/somewhere/else" "elsewhere" 11-00-00
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"00000000aaaa"* ]] || false
  [[ "$output" != *"00000000bbbb"* ]] || false
}

@test "codex session_title extracts the user_message prompt" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-00000000cccc "$WORK" "distil the notes"
  run adapter_session_title "$PROFILE" 019e0000-0000-7000-8000-00000000cccc
  [ "$status" -eq 0 ]
  [[ "$output" == *"distil the notes"* ]] || false
}

@test "codex session_title keeps a CJK prompt intact" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-00000000dddd "$WORK" "蒸餾成繁中筆記"
  run adapter_session_title "$PROFILE" 019e0000-0000-7000-8000-00000000dddd
  [ "$status" -eq 0 ]
  [[ "$output" == *"蒸餾成繁中筆記"* ]] || false
}

@test "codex resume_args emits 'resume <sid>'" {
  _setup_codex
  run adapter_resume_args 019e0000-0000-7000-8000-00000000eeee
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume"* ]] || false
  [[ "$output" == *"00000000eeee"* ]] || false
}

@test "codex transcript_path returns the current dir's newest rollout" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-00000000f001 "$WORK" "older" 09-00-00
  seed_rollout 019e0000-0000-7000-8000-00000000f002 "$WORK" "newer" 12-00-00
  run adapter_transcript_path "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"00000000f002"* ]] || false
}

# Regression: a rollout whose recorded cwd carries a TRAILING SLASH must still match
# the current dir (codex normally records no trailing slash, but a path that resolves
# with one would silently drop the session from the board / make resume impossible).
@test "codex cwd match is trailing-slash insensitive (recorded cwd has the slash)" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-0000000000a1 "$WORK/" "slashed cwd"
  run adapter_transcript_path "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0000000000a1"* ]] || false
  run adapter_recent_sids "$PROFILE"
  [[ "$output" == *"0000000000a1"* ]] || false
}

# And the reverse: a still-different cwd must NOT match (the fix must not become a
# loose prefix/substring match — only a trailing slash is normalised away).
@test "codex cwd match still EXCLUDES a genuinely different dir after the fix" {
  _setup_codex
  seed_rollout 019e0000-0000-7000-8000-0000000000b1 "$WORK"          "here"  10-00-00
  seed_rollout 019e0000-0000-7000-8000-0000000000b2 "${WORK}-other/" "there" 11-00-00
  run adapter_recent_sids "$PROFILE"
  [[ "$output" == *"0000000000b1"* ]] || false
  [[ "$output" != *"0000000000b2"* ]] || false
}

@test "codex title_for_file keeps a prompt with escaped quotes intact (no truncation at \\\")" {
  _setup_codex
  local f="$SDIR/2026/06/03/rollout-2026-06-03T12-00-00-019e0000-0000-7000-8000-00000000ffff.jsonl"
  {
    printf '{"timestamp":"2026-06-03T01:00:00.000Z","type":"session_meta","payload":{"id":"019e0000-0000-7000-8000-00000000ffff","cwd":"%s"}}\n' "$WORK"
    printf '{"type":"event_msg","payload":{"type":"user_message","message":"fix the \\"off-by-one\\" bug"}}\n'
  } > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *'fix the "off-by-one" bug'* ]] || false
}

@test "codex recent_sids survives a CLIKAE_HOME path containing a space" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/codex.sh"
  WORK="$TEST_HOME/spaced work"; mkdir -p "$WORK"; cd "$WORK" || return 1
  PROFILE="$TEST_HOME/dir with space/cprofile"
  SDIR="$PROFILE/sessions"
  mkdir -p "$SDIR/2026/06/03"
  seed_rollout 019e0000-0000-7000-8000-000000000abc "$WORK" "prompt in spaced home"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"000000000abc"* ]] || false
}

# --- #74 round-1 P1-1: burn's sidecar writer and resume's picker used to
# derive a codex session's sid two different ways (payload.id from the file
# body vs "everything after the last hyphen" in the filename) and could never
# agree once the uuid itself has internal hyphens — the picker's derivation
# then never matched what burn recorded, so codex burn sessions were NEVER
# actually hidden despite the sidecar holding a line for every one of them. ---

@test "codex adapter_sid_canonical recovers the FULL uuid from a rollout path, not just its last hyphen segment" {
  _setup_codex
  local sid="019e0000-0000-7000-8000-00000000abcd"
  local f="$SDIR/2026/06/03/rollout-2026-06-03T10-00-00-$sid.jsonl"
  run adapter_sid_canonical "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$sid" ]
  [ "$output" != "00000000abcd" ]   # the old (broken) last-hyphen-segment answer
}

@test "codex adapter_sid_canonical matches adapter_recent_sids's own sid, byte for byte" {
  _setup_codex
  local sid="019e0000-0000-7000-8000-0000000beefd"
  seed_rollout "$sid" "$WORK" "fix the build"
  local f="$SDIR/2026/06/03/rollout-2026-06-03T10-00-00-$sid.jsonl"
  run adapter_recent_sids "$PROFILE"
  [ "$status" -eq 0 ]
  local from_recent="${output##*$'\037'}"
  run adapter_sid_canonical "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$from_recent" ]
}

# --- #74 round-4 P3-1: adapter_cwd_from_args argv shapes, measured against a
# real codex 0.154.0 binary (clap accepts `=`-joined long AND short forms). --

@test "codex adapter_cwd_from_args recognises -C <dir> (spaced)" {
  _setup_codex
  run adapter_cwd_from_args exec -C /tmp/one -s workspace-write 'go'
  [ "$status" -eq 0 ]
  [ "$output" = /tmp/one ]
}

@test "codex adapter_cwd_from_args recognises -C<dir> (attached)" {
  _setup_codex
  run adapter_cwd_from_args exec -C/tmp/two -s workspace-write 'go'
  [ "$status" -eq 0 ]
  [ "$output" = /tmp/two ]
}

@test "codex adapter_cwd_from_args recognises --cd <dir> (spaced long alias)" {
  _setup_codex
  run adapter_cwd_from_args exec --cd /tmp/three -s workspace-write 'go'
  [ "$status" -eq 0 ]
  [ "$output" = /tmp/three ]
}

@test "codex adapter_cwd_from_args recognises --cd=<dir> (clap long = form)" {
  _setup_codex
  run adapter_cwd_from_args exec --cd=/tmp/four -s workspace-write 'go'
  [ "$status" -eq 0 ]
  [ "$output" = /tmp/four ]
}

@test "codex adapter_cwd_from_args recognises -C=<dir> (clap short = form) without leaking the '='" {
  _setup_codex
  run adapter_cwd_from_args exec -C=/tmp/five -s workspace-write 'go'
  [ "$status" -eq 0 ]
  [ "$output" = /tmp/five ]
  [[ "$output" != =* ]] || false
}

@test "codex adapter_cwd_from_args returns empty (rc 1) with no -C/--cd at all" {
  _setup_codex
  run adapter_cwd_from_args exec -s workspace-write 'go'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# #105 item 5: two edge shapes broke the hook's own "empty means rc 1"
# contract — codex's own -C value omitted, and an explicit empty value.
@test "codex adapter_cwd_from_args treats -C followed by another flag as no value given" {
  _setup_codex
  run adapter_cwd_from_args exec -C -s workspace-write 'go'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "codex adapter_cwd_from_args returns rc 1 on an explicit empty -C value" {
  _setup_codex
  run adapter_cwd_from_args exec -C '' -s workspace-write 'go'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "codex adapter_cwd_from_args returns rc 1 on --cd= with nothing after the =" {
  _setup_codex
  run adapter_cwd_from_args exec --cd= -s workspace-write 'go'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "codex adapter_cwd_from_args returns rc 1 on -C= with nothing after the =" {
  _setup_codex
  run adapter_cwd_from_args exec -C= -s workspace-write 'go'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- #113 item 3: counter-specimens for recent_sids' sid-from-FILENAME fast path.
# #93 round 2 made adapter_recent_sids take the sid from the rollout name instead
# of reading session_meta, falling back to the read "when the name carries no
# uuid" — and produced no specimen where it doesn't. These are those specimens.

@test "codex recent_sids (#113): a rollout whose name carries NO uuid falls back to the body id" {
  _setup_codex
  local body="019e0000-0000-7000-8000-00000000b0d1"
  {
    printf '{"timestamp":"2026-06-03T01:00:00.000Z","type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$body" "$WORK"
    printf '{"type":"event_msg","payload":{"type":"user_message","message":"renamed by hand"}}\n'
  } > "$SDIR/2026/06/03/rollout-2026-06-03T10-00-00.jsonl"
  run adapter_recent_sids "$PROFILE" 10
  [ "$status" -eq 0 ]
  [ "${output#*$'\037'}" = "$body" ] || { printf '%q\n' "$output"; false; }
}

@test "codex recent_sids (#113): uuid-SHAPED but not hex in the name is not a uuid — the body id wins" {
  # 36 characters with dashes exactly where a uuid has them. The pre-#113
  # `????????-????-????-????-????????????` glob accepted this and put
  # "notauuid-zzzz-zzzz-zzzz-zzzzzzzzzzzz" on the board as a session id.
  _setup_codex
  local body="019e0000-0000-7000-8000-00000000b0d2"
  {
    printf '{"timestamp":"2026-06-03T01:00:00.000Z","type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$body" "$WORK"
    printf '{"type":"event_msg","payload":{"type":"user_message","message":"odd name"}}\n'
  } > "$SDIR/2026/06/03/rollout-2026-06-03T10-00-00-notauuid-zzzz-zzzz-zzzz-zzzzzzzzzzzz.jsonl"
  run adapter_recent_sids "$PROFILE" 10
  [ "$status" -eq 0 ]
  [ "${output#*$'\037'}" = "$body" ] || { printf '%q\n' "$output"; false; }
}

@test "codex recent_sids (#113): a uuid-named rollout keeps the FAST path — the name is used, the body id is not read" {
  # The proof the fast path is still taken: the body's id DIFFERS from the name,
  # and the answer is the name's. (The repo's own sid->file lookup,
  # _codex_find_rollout, resolves by that same name, so this is the id resume
  # can find the file by.)
  _setup_codex
  local name_sid="019e0000-0000-7000-8000-0000000fa57a"
  {
    printf '{"timestamp":"2026-06-03T01:00:00.000Z","type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "019e0000-0000-7000-8000-00000000d1ff" "$WORK"
    printf '{"type":"event_msg","payload":{"type":"user_message","message":"fast path"}}\n'
  } > "$SDIR/2026/06/03/rollout-2026-06-03T10-00-00-$name_sid.jsonl"
  run adapter_recent_sids "$PROFILE" 10
  [ "$status" -eq 0 ]
  [ "${output#*$'\037'}" = "$name_sid" ] || { printf '%q\n' "$output"; false; }
  # Upper-case hex is still hex.
  mv "$SDIR/2026/06/03/rollout-2026-06-03T10-00-00-$name_sid.jsonl" \
     "$SDIR/2026/06/03/rollout-2026-06-03T10-00-00-019E0000-0000-7000-8000-0000000FA57A.jsonl"
  run adapter_recent_sids "$PROFILE" 10
  [ "${output#*$'\037'}" = "019E0000-0000-7000-8000-0000000FA57A" ] || { printf '%q\n' "$output"; false; }
}
