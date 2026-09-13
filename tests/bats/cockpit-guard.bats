#!/usr/bin/env bats
load '../helpers'

# lib/hooks/cockpit-guard.sh — the PreToolUse hook itself, exercised directly
# (stdin payload in, stdout/stderr + exit code out) rather than through a real
# Claude Code session. Contract: exit 0 = allow, exit 2 = blocked with the
# reason on stderr (docs.claude.com/en/docs/claude-code/hooks). See
# tests/bats/cockpit.bats for the `clikae cockpit` command that installs it.

GUARD="$CLIKAE_TEST_ROOT/lib/hooks/cockpit-guard.sh"

_guard() { printf '%s' "$1" | bash "$GUARD"; }

@test "allows a non-Agent tool without looking at model/prompt at all" {
  run _guard '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
  [ "$status" -eq 0 ]
}

@test "allows a haiku Explore spawn" {
  run _guard '{"tool_name":"Agent","tool_input":{"model":"haiku","subagent_type":"Explore","prompt":"look around the repo and summarize"}}'
  [ "$status" -eq 0 ]
}

@test "refuses a sonnet build brief mentioning worktree" {
  run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"make a worktree and implement the feature"}}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"clikae burn <engine> <tank>"* ]] || false
}

@test "refuses a missing-model spawn regardless of the prompt" {
  run _guard '{"tool_name":"Agent","tool_input":{"prompt":"just summarize this file, nothing fancy"}}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"carried no model"* ]] || false
}

@test "allows an opus spawn whose prompt has no lane heuristic" {
  run _guard '{"tool_name":"Agent","tool_input":{"model":"opus","prompt":"read these three files and tell me what they do"}}'
  [ "$status" -eq 0 ]
}

@test "each documented heuristic phrase refuses a sonnet/opus spawn" {
  local prompts=(
    "set up a worktree for this"
    "then git commit the result"
    "and git push when done"
    "act as REVIEWER on this diff"
    "run an adversarial review pass"
    "bats tests/bats/foo.bats"
    "npm test should be green"
    "run vitest once"
    "run the test suite"
    "run the full test suite"
  )
  local p
  for p in "${prompts[@]}"; do
    run _guard "$(printf '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"%s"}}' "$p")"
    [ "$status" -eq 2 ] || { echo "expected refuse for: $p" >&2; false; }
  done
}

@test "honours the env escape hatch" {
  CLIKAE_COCKPIT_ALLOW_AGENTS=1 run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLIKAE_COCKPIT_ALLOW_AGENTS"* ]] || false
}

@test "honours a live timed allowance and names its expiry" {
  mkdir -p "$CLIKAE_HOME/state"
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$CLIKAE_HOME/state/cockpit-allow"
  run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"allowed until"* ]] || false
}

@test "an expired timed allowance refuses again" {
  mkdir -p "$CLIKAE_HOME/state"
  printf '%s\n' "$(( $(date +%s) - 10 ))" > "$CLIKAE_HOME/state/cockpit-allow"
  run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}'
  [ "$status" -eq 2 ]
}

@test "names the current reserve, excluding the cockpit tank itself" {
  mkdir -p "$CLIKAE_HOME/state" \
    "$CLIKAE_HOME/profiles/claude/cockpit-tank" \
    "$CLIKAE_HOME/profiles/claude/worker1" \
    "$CLIKAE_HOME/profiles/codex/worker2"
  printf 'claude/cockpit-tank\n' > "$CLIKAE_HOME/state/cockpit"
  run _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"claude/worker1"* ]] || false
  [[ "$output" == *"codex/worker2"* ]] || false
  [[ "$output" != *"claude/cockpit-tank"* ]] || false
}

@test "fails open on an empty payload" {
  run _guard ''
  [ "$status" -eq 0 ]
}

@test "fails open on malformed JSON rather than blocking" {
  run _guard 'not json at all, just noise'
  [ "$status" -eq 0 ]
}

@test "runs comfortably inside the 50ms budget" {
  local t0 t1 ms
  t0="$(date +%s%N)"
  # This payload REFUSES (exit 2) by design — that's the more expensive path
  # (it enumerates the reserve) — so the timing matters more here than on an
  # allow. `|| true`: a bats test body fails on any unguarded nonzero exit.
  _guard '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"worktree git push"}}' >/dev/null 2>/dev/null || true
  t1="$(date +%s%N)"
  ms=$(( (t1 - t0) / 1000000 ))
  echo "elapsed: ${ms}ms" >&2
  # The real budget (docstring, PR description) is <50ms, measured ~7-25ms on
  # an idle host. This bound is deliberately much looser: bats runs can share
  # this host with several OTHER full suites at once (measured 273ms here
  # under a 5-way pile-up, load average 18) — a hard-coded near-50ms bound
  # would be a flaky CI assertion, not a real regression signal. This just
  # catches the catastrophic case (an infinite loop, an accidental network
  # call) that no amount of host contention explains.
  [ "$ms" -lt 5000 ]
}
