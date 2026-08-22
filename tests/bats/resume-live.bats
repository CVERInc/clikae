#!/usr/bin/env bats
# tests/bats/resume-live.bats — resuming a conversation that is already open.
#
# 🔴 THE FAILURE. `clikae resume` keys its tmux session on the argv it passes the
# engine (`--resume <sid>`), so resuming a DIFFERENT conversation on a busy tank
# correctly gets its own screen. But a session started plainly — `clikae claude
# x` — carries no conversation identity at all, so the conversation living inside
# it is invisible to that key. Resume then starts a SECOND engine on the same
# transcript, and two writers on one .jsonl is not a cosmetic problem.
#
# 🔴 AND IT CANNOT SIMPLY ASK. Measured on the maintainer's own live session: the
# process inside the pane is plain `claude`, no --resume, no sid. Which
# conversation it holds is Claude Code's own state. So the check is EVIDENCE —
# only the engine writes the transcript, so a file modified after a live session
# on that tank started is a file something in that session has been writing —
# and it is asymmetric on purpose: it can say "probably open there", never "not
# open". Silence means unknown, which is what this did before.

load '../helpers'

_src() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/commands/resume.sh"
  ISO="$TEST_HOME/rl-sock"; mkdir -p "$ISO"
  export TMUX_TMPDIR="$ISO"; unset TMUX
  _t() { env -u TMUX TMUX_TMPDIR="$ISO" tmux "$@"; }
}

teardown() {
  [ -n "${ISO:-}" ] && env -u TMUX TMUX_TMPDIR="$ISO" tmux kill-server 2>/dev/null
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

@test "resume-live: a transcript written since the session started names that session" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  clikae init claude rl
  _t new-session -d -s 'clikae-claude-rl' 'sleep 30'
  sleep 1                                   # so "after" is unambiguous
  local f="$TEST_HOME/live.jsonl"; : > "$f"

  run _resume_live_holder claude rl "$f"
  [ "$status" -eq 0 ] || { echo "saw nothing; expected the live session"; false; }
  [ "$output" = "clikae-claude-rl" ] || { echo "named '$output'"; false; }
}

@test "resume-live: a transcript OLDER than the session is not attributed to it" {
  # The asymmetry, stated as a test: no claim is better than a wrong one. A
  # conversation last written before this session existed was not written BY it.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  clikae init claude rl
  local f="$TEST_HOME/old.jsonl"; : > "$f"
  touch -t 202001010000 "$f"                # long before anything here
  _t new-session -d -s 'clikae-claude-rl' 'sleep 30'

  run _resume_live_holder claude rl "$f"
  [ "$status" -ne 0 ] || { echo "attributed an old transcript to '$output'"; false; }
}

@test "resume-live: a live session on ANOTHER tank is not this conversation's" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  clikae init claude rl
  clikae init claude other
  _t new-session -d -s 'clikae-claude-other' 'sleep 30'
  sleep 1
  local f="$TEST_HOME/live.jsonl"; : > "$f"

  run _resume_live_holder claude rl "$f"
  [ "$status" -ne 0 ] || { echo "blamed a session on a different tank: '$output'"; false; }
}

@test "resume-live: no live session at all means no claim" {
  _src
  clikae init claude rl
  local f="$TEST_HOME/live.jsonl"; : > "$f"
  run _resume_live_holder claude rl "$f"
  [ "$status" -ne 0 ]
}

@test "resume-live: a missing transcript is not evidence of anything" {
  _src
  run _resume_live_holder claude rl "$TEST_HOME/nope.jsonl"
  [ "$status" -ne 0 ]
}

@test "resume-live: the shared mtime helper works on this platform" {
  # 🔴 GNU and BSD stat take DIFFERENT FLAGS for the same question, and this repo
  # has been caught by that FOUR times — the fourth was the first draft of the
  # guard above, written three functions away from profile_store.sh, which had
  # already solved it. GNU's `-f` means --file-system: it prints block counts and
  # EXITS 0, so the `||` fallback never fires and the caller gets filesystem
  # statistics where it expected an epoch. If this returns empty the whole guard
  # silently stops claiming anything — a check that cannot fire, which is the
  # shape everything else here exists to prevent.
  _src
  local f="$TEST_HOME/t.txt"; : > "$f"
  run file_mtime "$f"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]] || { echo "not an epoch: '$output'"; false; }
  [ "$output" -gt 1600000000 ] || { echo "implausibly old epoch: $output"; false; }
}
