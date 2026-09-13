#!/usr/bin/env bash
# lib/hooks/cockpit-guard.sh — Claude Code PreToolUse hook, matcher "Agent".
# Installed/removed by `clikae cockpit` (lib/commands/cockpit.sh, #63) on
# whichever ONE tank is currently the "cockpit" — the session that STEERS,
# dispatching build/review lanes to worker tanks instead of spawning them in
# its own context and spending its own weekly budget (broke for real
# 2026-09-10: four sonnet/opus lanes + their reviews, spawned in-session from
# the cockpit, burned most of that tank's week).
#
# CONTRACT (settings.json "hooks.PreToolUse"): stdin carries the tool-call
# JSON (session_id, tool_name, tool_input, …); exit 0 allows the tool; exit 2
# BLOCKS it and Claude is shown stderr as the reason; any other exit code is
# non-blocking (proceeds, stderr surfaced only as a notice). So refusing here
# means: print the reason to stderr, `exit 2`.
#
# Refuses only Agent (subagent) spawns whose model is missing, or whose model
# is opus/sonnet AND whose prompt reads as a build/review lane. The prompt
# heuristic is a TRIPWIRE, not a classifier: it is the issue's own narrow
# phrases (worktree, a git commit/push, REVIEWER/adversarial review, a test
# run) OR'd with a widened set of bare imperative verbs (commit, push, "open
# a PR", review, grade, run tests, make CI) plus a length tripwire (prompt
# over 1,500 chars on opus/sonnet refuses regardless of content). Round-1
# review measured this against a 14-item corpus: it does not separate "reads
# as a build/review lane" from "merely mentions one of these words" — see
# docs/usage.md's cockpit section for the measured hit rate and the specific
# misses in both directions. `--allow-agents`/CLIKAE_COCKPIT_ALLOW_AGENTS is
# the real door; this tripwire is cheap insurance, not a permission gate.
# Everything else — haiku, fable, any model with a prompt that doesn't match,
# and every OTHER tool — is untouched.
#
# FAIL OPEN, same tier as scripts/harness-pretool-hook.sh: this runs on every
# single Agent call, so a broken guard must never brick the session. Any parse
# failure, missing dependency, or unexpected shape falls through to `allow`
# with one stderr line — never a silent hang, never a wrongful block. This
# means the guard treats "field absent because the JSON is well-formed but
# doesn't have it" and "field absent because the payload looks truncated or
# malformed" as two DIFFERENT signals (#63 P1-2): a payload with no
# `tool_name` at all, or no readable `tool_input`, allows with a stderr note;
# only a well-formed `tool_input` object that genuinely lacks `model` refuses
# (a bare in-session spawn is exactly the thing this guard exists to catch).
#
# Escape hatch (the operator sometimes rules "burn the cockpit tank tonight"):
# CLIKAE_COCKPIT_ALLOW_AGENTS=1 in the environment, or a timed allowance
# written by `clikae cockpit --allow-agents <dur>` (state/cockpit-allow) — a
# guard nobody can lift gets deleted instead of obeyed.
#
# PERFORMANCE: measured well under 50ms on Linux/GNU-grep for a compact
# payload with a prompt up to a few KB (no jq, no subshell-heavy JSON parsing
# — lib/core/json.sh's grep field extractor); measured ~90-100ms for the same
# shape on GitHub's macos-latest runner (BSD grep, bash 3.2, slower CI
# hardware) — a real platform floor, not flakiness (tests/bats/cockpit-
# guard.bats's own timing test bound reflects this, not a strict 50ms). That
# budget is NOT flat with prompt size either way: the value-scanning regex is
# O(prompt length), measured ~54ms at 50kB and ~167ms at 200kB on the fast
# host before this was bounded (#63 P2-7). Since the hook runs on EVERY Agent
# call, `prompt` is capped to its first 8 KiB before the heuristic match runs
# — a 200kB prompt now finishes in the same ballpark as a small one on both
# platforms. `model`/`tool_name` are NOT capped (they are short values found
# by a fast literal search regardless of where they sit in the payload).

set -uo pipefail

allow() { [ -n "${1:-}" ] && printf '%s\n' "$1" >&2; exit 0; }
trap 'allow "cockpit-guard: internal error — allowing (fail-open)"' ERR

_ckpt_self_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -h "$src" ]; do
    local d; d="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$d/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

_dir="$(_ckpt_self_dir)" || allow "cockpit-guard: could not resolve own path — allowing"
# shellcheck source=../core/json.sh
source "$_dir/../core/json.sh" 2>/dev/null || allow "cockpit-guard: could not load json.sh — allowing"

CLIKAE_HOME="${CLIKAE_HOME:-$HOME/.clikae}"

payload="$(cat 2>/dev/null)" || true
[ -n "$payload" ] || allow "cockpit-guard: empty payload — allowing"

# #63 P2-7: everything up through the tool_input presence check works off a
# bounded PREFIX, not the full payload — `tool_name`/`tool_input` are always
# near the front (docstring: "session_id, tool_name, tool_input, …"), so
# there's no reason to pay the full payload's length for them. `head -c` on
# a pipe short-circuits once satisfied, so this is cheap even at 200kB.
_ckpt_head="$(printf '%s' "$payload" | head -c 8192)" || true
# `|| true` above and below: with `pipefail` (set at the top), `head -c`
# closing the pipe as soon as it has its 8192 bytes sends `printf` SIGPIPE
# on a payload bigger than that — a normal, expected early-close, but under
# pipefail it makes the WHOLE assignment "fail" and trip the ERR trap (fail-
# open, silently, on every large payload) even though $_ckpt_head itself
# came out fine.

# rc=1 here means json_field_str found no `"tool_name"` pair at all — a
# payload shape this guard has never seen, not just "some other tool ran"
# (that case is the ordinary `tool_name != Agent` branch below, and stays
# silent). #63 P1-2: distinguish the two rather than treating both as a
# plain, silent exit 0 — a payload this malformed is worth one stderr line.
if ! tool_name="$(json_field_str "$_ckpt_head" tool_name 2>/dev/null)"; then
  allow "cockpit-guard: payload has no tool_name field — allowing"
fi
[ "$tool_name" = "Agent" ] || exit 0   # matcher is "Agent" already; belt & suspenders

# --- escape hatch 1: env opt-out -------------------------------------------
[ "${CLIKAE_COCKPIT_ALLOW_AGENTS:-}" = "1" ] && allow "cockpit-guard: allowed via CLIKAE_COCKPIT_ALLOW_AGENTS=1"

# --- escape hatch 2: a timed allowance from `clikae cockpit --allow-agents` -
_allow_file="$CLIKAE_HOME/state/cockpit-allow"
if [ -f "$_allow_file" ]; then
  _exp="$(head -n 1 "$_allow_file" 2>/dev/null | tr -dc '0-9')"
  _now="$(date +%s 2>/dev/null || echo 0)"
  if [ -n "$_exp" ] && [ "$_now" -lt "$_exp" ]; then
    _hhmm="$(date -d "@$_exp" '+%H:%M' 2>/dev/null || date -r "$_exp" '+%H:%M' 2>/dev/null)"
    allow "cockpit-guard: allowed until ${_hhmm:-$_exp}"
  fi
  # expired — fall through to the normal check rather than delete the file;
  # this hook is read-only by design (a stale marker costs nothing to leave).
fi

# #63 P1-2: a well-formed `tool_input` that genuinely lacks `model` is the
# refusal case below ("a bare in-session spawn"). But `json_field_str` gives
# rc=1 for BOTH "field absent" and "JSON too broken to find the field in" —
# it is a flat regex scan, not a parser, so it cannot tell those apart on its
# own. Rule out the second case first, with two cheap, purpose-built checks,
# both O(1)-ish and pure bash (no subprocess — this runs on every Agent
# call), NOT a general well-formedness proof (see json.sh's own docstring on
# what this extractor is and isn't):
#   1. no `"tool_input"` substring anywhere -> the key is missing outright.
#   2. the payload's last non-whitespace character isn't `}` -> something (a
#      truncated write, a hook timeout mid-flush) cut the JSON off before it
#      closed — exactly the shape of the round-1 review's repro. A payload
#      that legitimately ends elsewhere (rare, and only in the fail-OPEN
#      direction — never a wrongful block) is the accepted cost of a cheap
#      check over an exact one.
if ! printf '%s' "$_ckpt_head" | grep -q '"tool_input"'; then
  allow "cockpit-guard: payload has no tool_input field — allowing"
fi
# Last character must be `}`. No trim needed first: `payload="$(cat)"` above
# is a command substitution, and bash strips ALL trailing newlines from a
# command substitution's result — there is no trailing-whitespace case left
# to handle by the time $payload exists. (A glob/case-based trim loop was
# tried here first and cost 40-plus SECONDS on a 200kB payload — bash's
# pattern matching against a long string is not the O(1) operation it looks
# like; plain arithmetic-offset substring expansion is.)
if [ "${payload:$((${#payload}-1)):1}" != "}" ]; then
  allow "cockpit-guard: tool_input payload looks truncated or malformed — allowing"
fi

# `model` is read from the LAST 8 KiB of the payload, not the front and not
# the full thing. The real captured shape (tests/fixtures/cockpit-guard/) has
# tool_input's keys in the order description, prompt, model — `model` comes
# AFTER `prompt`, so on a huge prompt it sits near the very end, not the
# front (measured: extracting it from the FULL 200kB payload alone cost
# ~34ms of this hook's ~50ms budget, dominated by grep scanning past the
# whole prompt just to reach the literal it's searching for). A `tail -c`
# window this size comfortably contains `,"model":"…"}}` regardless of how
# long the prompt is; it would miss a payload shape where `model` precedes a
# huge `prompt` instead — not the shape any real capture has shown so far.
_ckpt_tail="$(printf '%s' "$payload" | tail -c 8192)" || true
model="$(json_field_str "$_ckpt_tail" model 2>/dev/null || true)"
# `prompt` is read from at most the first 8 KiB of the payload (#63 P2-7) —
# reusing $_ckpt_head rather than re-slicing — with a synthetic closing quote
# appended so a value that got cut mid-string still parses as a (truncated)
# match instead of failing to match at all: the extractor's pattern requires
# a closing quote to match anything.
prompt="$(json_field_str "${_ckpt_head}\"" prompt 2>/dev/null || true)"

# _ckpt_refuse [model] [reason] -> print the refusal (reason + reserve + the
# burn shape) to stderr and exit 2. Best-effort enrichment (the reserve
# listing): its own failure must never turn a refusal into a silent allow,
# so it is wrapped separately from the fail-open trap above.
_ckpt_refuse() {
  local why
  if [ -z "${1:-}" ]; then
    why="the Agent tool call carried no model (a bare in-session spawn)"
  elif [ "${2:-}" = "long" ]; then
    why="a $1-model Agent spawn whose prompt is over the 1,500-char length tripwire"
  else
    why="a $1-model Agent spawn whose prompt reads as a build/review lane"
  fi
  {
    printf 'cockpit-guard: refused — %s.\n' "$why"
    printf 'Dispatch it instead:\n'
    printf '  clikae burn <engine> <tank> --prompt-file <f> --artifact <path>\n'
    ( source "$_dir/../core/profile_store.sh" 2>/dev/null &&
      source "$_dir/../core/burn_status.sh" 2>/dev/null &&
      cur="$(head -n 1 "$CLIKAE_HOME/state/cockpit" 2>/dev/null | tr -d '\n')" &&
      lines="$(
        while IFS=$'\t' read -r cli profile _path; do
          [ -n "$cli" ] || continue
          [ "$cli/$profile" = "$cur" ] && continue
          burn_tank_busy "$cli" "$profile" 2>/dev/null && continue
          printf '  %s/%s\n' "$cli" "$profile"
        done <<PROFILES
$(list_all_profiles 2>/dev/null)
PROFILES
      )" &&
      if [ -n "$lines" ]; then
        printf 'Current reserve (idle tanks):\n%s\n' "$lines"
      else
        printf 'No idle tank in the reserve right now.\n'
      fi
    ) 2>/dev/null
    printf 'Escape hatch: CLIKAE_COCKPIT_ALLOW_AGENTS=1, or `clikae cockpit --allow-agents <dur>`.\n'
  } >&2
  exit 2
}

if [ -z "$model" ]; then
  _ckpt_refuse ""
fi

# The heuristic (#63 P2-5): the issue's own narrow phrases, OR'd with a
# widened set of bare imperative verbs. Widening trades more false refusals
# (cheap — `--allow-agents` exists) for fewer false allows (expensive — that
# was the whole 2026-09-10 incident). Measured against a 14-item corpus in
# tests/bats/cockpit-guard.bats; the hit rate and the specific misses (in
# BOTH directions — an innocuous question that merely mentions one of these
# words still refuses) are documented in docs/usage.md. This is a tripwire,
# not a classifier.
_CKPT_HEURISTIC='worktree|git commit|git push|REVIEWER|adversarial review|bats |npm test|vitest|run the (full )?tests?|\bcommit\b|\bpush\b|open a pr|\breview\b|\bgrade\b|run (the )?tests|make ci'

model_lc="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"
case "$model_lc" in
  opus|sonnet)
    # Length tripwire: independent of any keyword. A prompt this long on a
    # build-capable model is refused regardless of content.
    if [ "${#prompt}" -gt 1500 ]; then
      _ckpt_refuse "$model" long
    fi
    if printf '%s' "$prompt" | grep -qiE "$_CKPT_HEURISTIC"; then
      _ckpt_refuse "$model"
    fi
    ;;
esac

exit 0
