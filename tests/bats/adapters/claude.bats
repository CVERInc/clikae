#!/usr/bin/env bats
# tests/bats/adapters/claude.bats — the built-in claude adapter + adapter listing.

load '../../helpers'

@test "adapters lists claude and the v0.2 adapters" {
  run clikae adapters
  [ "$status" -eq 0 ]
  for cli in claude gh gcloud docker helm kubectl aws; do
    [[ "$output" == *"$cli"* ]] || { echo "missing adapter: $cli"; false; }
  done
}

@test "claude adapter reports the env-dir strategy and its env var" {
  run clikae adapters
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"*"env-dir"*"CLAUDE_CONFIG_DIR"* ]] || false
}

@test "info reports a profile count that tracks init" {
  clikae init claude work
  clikae init gh personal
  run clikae info
  [ "$status" -eq 0 ]
  [[ "$output" == *"tanks"*"2"* ]] || false
}

@test "claude alias exports CLAUDE_CONFIG_DIR at the profile path" {
  clikae init claude work
  clikae alias claude work
  grep -qF "CLAUDE_CONFIG_DIR=\"$CLIKAE_HOME/profiles/claude/work\"" "$RC_FILE"
}

@test "claude title_for_file: aiTitle with escaped quotes survives intact" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t.jsonl"
  printf '{"type":"summary","aiTitle":"Fix the \\"off-by-one\\" bug in loop"}\n' > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [ "$output" = 'Fix the "off-by-one" bug in loop' ]
}

@test "claude title_for_file: falls back to the first user message when no aiTitle" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t2.jsonl"
  printf '{"role":"user","content":[{"type":"text","text":"hello from the opening prompt"}]}\n' > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from the opening prompt"* ]] || false
}

# --- customTitle precedence (2026-07-12: a `/rename` must outrank the stale
# machine-generated aiTitle everywhere a title is derived, INCLUDING clean's
# deletion list — a renamed live session was unrecognizable there) ------------

@test "claude title_for_file: a USER-set custom-title outranks a later aiTitle" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t5.jsonl"
  {
    printf '{"type":"custom-title","customTitle":"My Renamed Session"}\n'
    printf '{"type":"ai-title","aiTitle":"Machine title"}\n'
  } > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "My Renamed Session" ]
}

@test "claude title_for_file: a transcript with only aiTitle is unchanged" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t6.jsonl"
  printf '{"type":"summary","aiTitle":"Just the AI title"}\n' > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "Just the AI title" ]
}

# --- a /rename PAST the head window is still the name (2026-07-21: the resume
# picker and home board scanned only the first 100 lines, so a session renamed
# deep in a long conversation kept showing its PRE-rename name — while the
# board's own _claude_meta_for_file, which reads the tail, showed the new one) --

@test "claude title_for_file: a rename past line 100 wins over an early name" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t7.jsonl"
  # Early name in the head window, then 200 filler lines, then the real /rename
  # far past the 100-line head cutoff — only a tail scan can see it.
  printf '{"type":"custom-title","customTitle":"early-name"}\n' > "$f"
  local i; for ((i = 0; i < 200; i++)); do
    printf '{"type":"assistant","message":{"role":"assistant","content":"filler %d"}}\n' "$i" >> "$f"
  done
  printf '{"type":"custom-title","customTitle":"renamed-late"}\n' >> "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "renamed-late" ]
}

@test "claude title_for_file: a runaway title is capped before it is cleaned" {
  # Half of the hang fix, and the half that IS mechanically provable here: the
  # three global `${//}` substitutions below the extraction run in roughly O(n²)
  # in bash, so they must never see a 200 KB string. The cap is what stops that.
  # (_claude_meta_for_file has capped at 200 for this reason since it was
  # written; this function never did.)
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/long.jsonl"
  local pad; pad="$(awk 'BEGIN{s="";while(length(s)<50000)s=s "abcdefghij";print s}')"
  printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$pad" > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ] || false
  [ "${#output}" -le 400 ] || false      # old code returned all 50,000
  [ "${#output}" -gt 0 ] || false        # …but it still returns a title
}

# 🔴 THE HANG ITSELF HAS NO SYNTHETIC TEST, AND THAT IS RECORDED HONESTLY.
#
# The defect is real and measured: across the maintainer's store, 25 of 1,383
# transcripts made the OLD extractor exceed a 10-second timeout; the new one
# processes all 1,383 with none. The worst offender was 229,385 bytes on one
# line, carrying 2,956 quotes and 6,036 backslashes, and bash's `[[ =~ ]]` on
# `(([^"\]|\\.)*)` did not finish it in 60 seconds — nor the same regex against
# only its first 4 KB.
#
# THREE attempts to synthesise it all passed on the broken code: a long
# quote-sprinkled line (the regex stops at the first quote), a long quote-free
# line, and a line of thousands of `\n` escapes. Whatever the precise trigger
# is, it is not any of those, and a test that goes green on the code it was
# written to catch is decoration — so none of them is shipped.
#
# What guards the regression instead: the cap test above (mechanically red on
# the old code), and the extraction tests around it, which pin that the grep
# rewrite returns the same titles. If this ever needs re-proving, the method
# that worked is a differential run over a real store — dump every title with
# both implementations under a per-file `timeout`, and diff.

@test "claude title_for_file: both title keys on ONE line still resolve by rank" {
  # The extractor now finds customTitle and aiTitle in a SINGLE scan and sorts the
  # matches out afterwards, instead of scanning the transcript once per key. That
  # is only equivalent while the two stay distinguishable, and the tightest case
  # is a line carrying both — which no fixture had.
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t-both.jsonl"
  printf '{"type":"summary","aiTitle":"Machine guess","customTitle":"What I called it"}\n' > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "What I called it" ]
}

@test "claude title_for_file: the LAST customTitle wins when a line has two" {
  # grep -o emits matches in file order, which is what makes "take the last one"
  # mean "the newest rename". Pin that ordering survives inside a single line.
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/t-two.jsonl"
  printf '{"customTitle":"First name","x":1,"customTitle":"Second name"}\n' > "$f"
  run adapter_title_for_file "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "Second name" ]
}

# --- #74 round-1 P1-1: one canonical sid derivation, shared by burn's sidecar
# writer and resume's picker (see codex.bats's twin for the engine that was
# actually broken; claude's own filename-is-the-sid shape was always right,
# but the hook is defined here too so no caller has to special-case it). ---

@test "claude adapter_sid_canonical is the transcript basename minus .jsonl" {
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local f="$TEST_HOME/projects/slug/9a1c2222-3333-4444-8555-666677778888.jsonl"
  run adapter_sid_canonical "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "9a1c2222-3333-4444-8555-666677778888" ]
}

# --- subagent transcripts (`agent-<id>.jsonl`) ------------------------------
# claude writes a subagent's transcript beside its parent's, in the same
# project dir, every line carrying `"isSidechain":true`. The adapter owns the
# fact that those are not conversations; everything else asks it.
_setup_claude_adapter() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"   # sessions_by_mtime
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  WORK="$TEST_HOME/work"; mkdir -p "$WORK"; cd "$WORK" || return 1
  PROFILE="$TEST_HOME/cprofile"
  PROJ="$PROFILE/projects/$(_claude_project_slug "$WORK")"
  mkdir -p "$PROJ"
}

@test "claude adapter_transcript_is_resumable: the basename is the whole rule" {
  _setup_claude_adapter
  run adapter_transcript_is_resumable "$PROJ/11111111-2222-3333-4444-555555555555.jsonl"
  [ "$status" -eq 0 ]
  run adapter_transcript_is_resumable "$PROJ/agent-99999999-2222-3333-4444-555555555555.jsonl"
  [ "$status" -ne 0 ]
  # A session whose id merely CONTAINS "agent" is a session. The rule is the
  # prefix of the basename, not a substring of the path — and a project
  # directory called ".../agent-stuff/" must not disqualify what is inside it.
  run adapter_transcript_is_resumable "$PROJ/deadagent-2222-3333-4444-555555555555.jsonl"
  [ "$status" -eq 0 ]
  run adapter_transcript_is_resumable "/tmp/agent-dir/11111111-2222-3333-4444-555555555555.jsonl"
  [ "$status" -eq 0 ]
}

@test "claude adapter_all_transcripts does not descend into a sid dir's own subagents/ files" {
  _setup_claude_adapter
  local sid="cccccccc-2222-3333-4444-555555555555"
  printf '{"type":"ai-title","aiTitle":"real"}\n' > "$PROJ/$sid.jsonl"
  # A sibling sid dir's own nested transcript (subagent/workflow data) is
  # priced WITH its parent via clean's sibling-dir du, never enumerated as an
  # independent top-level transcript in its own right — unbounded find used
  # to hand this back as a second, unrelated "session".
  mkdir -p "$PROJ/$sid/subagents"
  printf '{"type":"user","isSidechain":true}\n' > "$PROJ/$sid/subagents/agent-1.jsonl"

  run adapter_all_transcripts "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$sid.jsonl"* ]] || { echo "missing the real transcript: $output"; false; }
  [[ "$output" != *"subagents"* ]] || { echo "nested subagent data leaked out as its own transcript: $output"; false; }
}

@test "claude adapter_recent_sids leaves subagent transcripts out of the board's list" {
  _setup_claude_adapter
  printf '{"type":"ai-title","aiTitle":"real"}\n' > "$PROJ/11111111-2222-3333-4444-555555555555.jsonl"
  touch -t 202601010000 "$PROJ/11111111-2222-3333-4444-555555555555.jsonl"
  # Newer, so a list that counted it would put it first AND — at limit 1 —
  # would return it INSTEAD of the real session. That is why the skip happens
  # before the cut, not after.
  printf '{"type":"user","isSidechain":true,"message":{"role":"user","content":"brief"}}\n' \
    > "$PROJ/agent-99999999-2222-3333-4444-555555555555.jsonl"
  touch -t 202606250000 "$PROJ/agent-99999999-2222-3333-4444-555555555555.jsonl"

  run adapter_recent_sids "$PROFILE" 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"11111111-2222-3333-4444-555555555555"* ]] || { echo "got: $output"; false; }
  [[ "$output" != *"agent-99999999"* ]] || { echo "got: $output"; false; }

  run adapter_recent_sids "$PROFILE" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"11111111-2222-3333-4444-555555555555"* ]] || { echo "cut before skip: $output"; false; }
}

@test "claude adapter_find_session still finds a subagent transcript by its full id" {
  _setup_claude_adapter
  printf '{"type":"user","isSidechain":true}\n' \
    > "$PROJ/agent-99999999-2222-3333-4444-555555555555.jsonl"
  run adapter_find_session "$PROFILE" "agent-99999999-2222-3333-4444-555555555555"
  [ "$status" -eq 0 ] || { echo "locate was narrowed: $output"; false; }
  [[ "$output" == *"agent-99999999-2222-3333-4444-555555555555.jsonl"* ]] || false
}
