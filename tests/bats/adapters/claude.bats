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
