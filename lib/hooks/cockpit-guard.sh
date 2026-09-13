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
# is opus/sonnet AND whose prompt reads as a build/review lane (worktree, a
# git commit/push, REVIEWER/adversarial review, or a test run). Everything
# else — haiku, fable, any model with a prompt that doesn't match, and every
# OTHER tool — is untouched; this hook is not a general permission gate.
#
# FAIL OPEN, same tier as scripts/harness-pretool-hook.sh: this runs on every
# single Agent call, so a broken guard must never brick the session. Any parse
# failure, missing dependency, or unexpected shape falls through to `allow`
# with one stderr line — never a silent hang, never a wrongful block.
#
# Escape hatch (the operator sometimes rules "burn the cockpit tank tonight"):
# CLIKAE_COCKPIT_ALLOW_AGENTS=1 in the environment, or a timed allowance
# written by `clikae cockpit --allow-agents <dur>` (state/cockpit-allow) — a
# guard nobody can lift gets deleted instead of obeyed.
#
# PERFORMANCE: measured to run well under 50ms (no jq, no subshell-heavy
# JSON parsing — lib/core/json.sh's grep/sed field extractor). It runs on
# EVERY Agent call in the session, so this budget is load-bearing.

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

tool_name="$(json_field_str "$payload" tool_name 2>/dev/null || true)"
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

model="$(json_field_str "$payload" model 2>/dev/null || true)"
prompt="$(json_field_str "$payload" prompt 2>/dev/null || true)"

# _ckpt_refuse [model] -> print the refusal (reason + reserve + the burn
# shape) to stderr and exit 2. Best-effort enrichment (the reserve listing):
# its own failure must never turn a refusal into a silent allow, so it is
# wrapped separately from the fail-open trap above.
_ckpt_refuse() {
  local why
  if [ -z "${1:-}" ]; then
    why="the Agent tool call carried no model (a bare in-session spawn)"
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

model_lc="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"
case "$model_lc" in
  opus|sonnet)
    if printf '%s' "$prompt" | grep -qiE 'worktree|git commit|git push|REVIEWER|adversarial review|bats |npm test|vitest|run the (full )?test'; then
      _ckpt_refuse "$model"
    fi
    ;;
esac

exit 0
