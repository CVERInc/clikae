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
# is opus/sonnet (any family-prefixed form — `claude-opus-*`, `claude-
# sonnet-*`, `opusplan`, or the bare alias — #63 P3-1) AND whose prompt reads
# as a build/review lane. The prompt heuristic is a TRIPWIRE, not a
# classifier: it is the issue's own narrow phrases (worktree, a git
# commit/push, REVIEWER/adversarial review, a test run) OR'd with a widened
# set of bare imperative verbs (commit, push, "open a PR", review, grade, run
# tests, make CI) plus a length tripwire (prompt over 1,500 CHARACTERS on
# opus/sonnet refuses regardless of content). Round-1 review measured this
# against a 14-item corpus: it does not separate "reads as a build/review
# lane" from "merely mentions one of these words" — see docs/usage.md's
# cockpit section for the measured hit rate and the specific misses in both
# directions. `--allow-agents`/CLIKAE_COCKPIT_ALLOW_AGENTS is the real door;
# this tripwire is cheap insurance, not a permission gate. Everything else —
# haiku, fable, any model with a prompt that doesn't match, and every OTHER
# tool — is untouched. This is a check on MODEL, never on `subagent_type`:
# the guard doesn't read that field at all, so an opus/sonnet `Explore` spawn
# is checked exactly like any other opus/sonnet spawn (#63 P3-2).
#
# FAIL CLOSED (#63 round-5 P2-5). Rounds 1-4 failed OPEN: any parse failure,
# missing dependency or unexpected shape allowed with one stderr line. The
# codex security review turned that into a bypass without touching the
# guard: a large pretty-printed payload made the tool_input presence test
# (`printf … | grep -q`) die of SIGPIPE under pipefail, and the guard allowed
# "payload has no tool_input field". Every path out of this hook that is not
# a decision about a call it could read now REFUSES (exit 2) with the reason
# and the escape hatch: an empty payload, no tool_name, no readable
# tool_input, a truncated or malformed payload, a missing library, an
# internal error. An EXIT trap turns any other exit code (a `set -u` abort, a
# stray exit 1 — non-blocking to Claude Code, i.e. an allow) into a refusal.
# Timing out is the one exit this script cannot convert: Claude Code treats a
# hook that overruns its timeout as non-blocking.
#
# Escape hatch (the operator sometimes rules "burn the cockpit tank tonight"):
# CLIKAE_COCKPIT_ALLOW_AGENTS=1 in the environment, or a timed allowance
# written by `clikae cockpit --allow-agents <dur>` (state/cockpit-allow) — a
# guard nobody can lift gets deleted instead of obeyed. Both are checked
# BEFORE the payload is parsed, so a fail-closed refusal can always be lifted.
#
# #63 P1-1/P2-1 fix2 (round-2 review, REVIEW-cockpit63-r2.md): round 1 capped
# cost by slicing the RAW PAYLOAD to a fixed 8 KiB BYTE window before ever
# calling the field extractor — `head -c 8192` in front of `prompt`, `tail -c
# 8192` in front of `model`. Two bugs came from that, both silent:
#   1. A cut that lands mid multi-byte UTF-8 character (routine on a Chinese-
#      or mixed-script prompt, measured 42% of slide positions on a real
#      zh+en brief) leaves invalid UTF-8 at the boundary; `json_field_str`'s
#      `[^"\\]` class can't match through it, so the WHOLE "prompt" pair goes
#      unmatched — `prompt=""`. That zeroes BOTH the heuristic (nothing to
#      match) AND the length tripwire (`${#prompt}` = 0) at once, with zero
#      stderr — the one guardrail that was supposed to hold "no content match
#      needed" independent of content parsing.
#   2. `tail -c 8192` for `model` silently MISSES it on any payload shape
#      where `model` sits before a huge `prompt` in `tool_input` (the
#      original comment reasoned this was merely a low-probability miss —
#      backwards: the observed failure mode is `model=""`, which hits the
#      unconditional "carried no model" refusal — every model, haiku
#      included, wrongly BLOCKED, for the wrong stated reason).
# Neither field is pre-sliced anymore. `tool_name` and `model` are always
# read with `json_field_str` straight off the FULL `$payload`; `prompt` is
# too, but only once the model gate below says this call is one the guard
# actually inspects (#63 P3-2, round 3 — see the comment by the `model`
# read). Cost is bounded only by however big the payload actually is
# (measured 200 kB and 1 MB in REPORT-cockpit63-fix2.md; a huge prompt is no
# longer free on the models it applies to, and this docstring says so
# plainly rather than repeating the round-1 "well under
# 50ms" claim past the point it stopped being true). `prompt`'s DECODED,
# UNTRUNCATED length feeds the length tripwire below (#63 P3-1, round 3: an
# earlier draft also truncated a COPY to 8,192 characters for the keyword
# heuristic, but that copy can never see more than 1,500 characters anyway —
# the length tripwire already refuses anything longer, on the only models the
# heuristic runs for, before the heuristic is reached. Removed as dead code
# rather than documenting a cap that can't fire).
#
# LOCALE: pinned to C.UTF-8 (falling back to en_US.UTF-8, then a documented-
# degraded C) right below, specifically so `${#prompt}` counts CHARACTERS the
# SAME WAY regardless of the caller's own environment — the round-2 review's
# single clearest repro of the bug above
# was `LC_ALL=C` passing while the operator's ordinary `en_US.UTF-8` shell
# refused correctly: same bytes, same script, different verdict, entirely by
# accident of environment. See _ckpt_pick_locale below for what "documented
# degradation" means when neither UTF-8 locale is installed.
set -uo pipefail

allow() { if [ -n "${1:-}" ]; then printf '%s\n' "$1" >&2; fi; trap - EXIT; exit 0; }
# _ckpt_fail_closed <why> -> refuse a call this guard could not read.
_ckpt_fail_closed() {
  trap - EXIT
  {
    printf 'cockpit-guard: refused — %s. The guard fails closed: a call it cannot read is not let through.\n' "$1"
    printf 'Escape hatch: CLIKAE_COCKPIT_ALLOW_AGENTS=1, or `clikae cockpit --allow-agents <dur>`.\n'
  } >&2
  exit 2
}
trap '_ckpt_fail_closed "internal error"' ERR
_ckpt_on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then _ckpt_fail_closed "internal error (exit $rc)"; fi
}
trap _ckpt_on_exit EXIT

# _ckpt_pick_locale -> echoes the first of C.UTF-8 / en_US.UTF-8 that
# `locale -a` actually lists, or fails. Checked against the installed list
# rather than blindly exported: `setlocale()` returns failure and leaves the
# CURRENT locale untouched when asked for one that isn't installed — it does
# NOT fall back to "C" on its own — so a blind `export LC_ALL=C.UTF-8` on a
# host that lacks it would silently keep whatever locale the CALLER exported,
# which is exactly the non-determinism this pin exists to remove. Falling
# back to the literal `C` locale (below, not in this function) when neither
# candidate is installed is a DOCUMENTED degradation, not a silent one: under
# plain `C`, `${#prompt}`/character-slicing count/cut by BYTE, so a multi-
# byte prompt can once again be cut mid-character — but only in the direction
# that makes the length tripwire fire MORE readily (byte count >= character
# count for UTF-8), never the direction that silently lets a real build/
# review lane through unexamined.
_ckpt_pick_locale() {
  local have want norm
  have="$(locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '.-')"
  for want in C.UTF-8 en_US.UTF-8; do
    norm="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]' | tr -d '.-')"
    if printf '%s\n' "$have" | grep -qx "$norm"; then
      printf '%s' "$want"
      return 0
    fi
  done
  return 1
}
LC_ALL="$(_ckpt_pick_locale 2>/dev/null)" || LC_ALL=C
export LC_ALL

_ckpt_self_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -h "$src" ]; do
    local d; d="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$d/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

CLIKAE_HOME="${CLIKAE_HOME:-$HOME/.clikae}"

# `|| true`: a read error leaves whatever arrived, and an empty result is
# refused just below — never allowed.
payload="$(cat 2>/dev/null)" || true

# --- escape hatch 1: env opt-out -------------------------------------------
if [ "${CLIKAE_COCKPIT_ALLOW_AGENTS:-}" = "1" ]; then
  allow "cockpit-guard: allowed via CLIKAE_COCKPIT_ALLOW_AGENTS=1"
fi

# --- escape hatch 2: a timed allowance from `clikae cockpit --allow-agents` -
_allow_file="$CLIKAE_HOME/state/cockpit-allow"
if [ -f "$_allow_file" ]; then
  _exp="$(head -n 1 "$_allow_file" 2>/dev/null | tr -dc '0-9' || true)"
  _now="$(date +%s 2>/dev/null || echo 0)"
  if [ -n "$_exp" ] && [ "$_now" -lt "$_exp" ]; then
    _hhmm="$(date -d "@$_exp" '+%H:%M' 2>/dev/null || date -r "$_exp" '+%H:%M' 2>/dev/null || true)"
    allow "cockpit-guard: allowed until ${_hhmm:-$_exp}"
  fi
  # expired — fall through to the normal check rather than delete the file;
  # this hook is read-only by design (a stale marker costs nothing to leave).
fi

[ -n "$payload" ] || _ckpt_fail_closed "the hook received an empty payload"

_dir="$(_ckpt_self_dir)" || _ckpt_fail_closed "the guard could not resolve its own path"
# shellcheck source=../core/json.sh
source "$_dir/../core/json.sh" 2>/dev/null || _ckpt_fail_closed "the guard could not load json.sh"

# rc=1 here means json_field_str found no `"tool_name"` pair anywhere in the
# full payload — a shape this guard has never seen, not just "some other
# tool ran" (that case is the ordinary `tool_name != Agent` branch below, and
# stays silent).
if ! tool_name="$(json_field_str "$payload" tool_name 2>/dev/null)"; then
  _ckpt_fail_closed "the payload has no tool_name field"
fi
[ "$tool_name" = "Agent" ] || allow   # matcher is "Agent" already; belt & suspenders

# #63 P1-2: a well-formed `tool_input` that genuinely lacks `model` is the
# refusal case below ("a bare in-session spawn"). But `json_field_str` gives
# rc=1 for BOTH "field absent" and "JSON too broken to find the field in" —
# it is a flat regex scan, not a parser, so it cannot tell those apart on its
# own. Rule out the second case first, with two cheap, purpose-built checks
# over the full payload, NOT a general well-formedness proof (see json.sh's
# own docstring on what this extractor is and isn't):
#   1. no `"tool_input"` substring anywhere -> the key is missing outright.
#   2. the payload's last non-whitespace character isn't `}` -> something (a
#      truncated write, a hook timeout mid-flush) cut the JSON off before it
#      closed — exactly the shape of the round-1 review's repro. A payload
#      that legitimately ends elsewhere (rare, and only in the fail-OPEN
#      direction — never a wrongful block) is the accepted cost of a cheap
#      check over an exact one.
#
# #63 round-5 P2-5: check 1 used to be `printf '%s' "$payload" | grep -q …`.
# grep -q exits at its first match while printf is still writing a large
# payload; printf dies of SIGPIPE, pipefail fails the pipeline, and the
# negated test allowed a pretty-printed 65 KiB call as "no tool_input". The
# test is a bash pattern match on the variable now — no pipe, no early reader.
case "$payload" in
  *'"tool_input"'*) ;;
  *) _ckpt_fail_closed "the payload has no tool_input field" ;;
esac
# Last character must be `}`. No trim needed first: `payload="$(cat)"` above
# is a command substitution, and bash strips ALL trailing newlines from a
# command substitution's result — there is no trailing-whitespace case left
# to handle by the time $payload exists. (A glob/case-based trim loop was
# tried here first and cost 40-plus SECONDS on a 200kB payload — bash's
# pattern matching against a long string is not the O(1) operation it looks
# like; plain arithmetic-offset substring expansion is.)
if [ "${payload:$((${#payload}-1)):1}" != "}" ]; then
  _ckpt_fail_closed "the payload looks truncated or malformed"
fi

# `model` is read straight off the FULL `$payload` now — #63 P2-1/P1-1 fix2,
# see the docstring at the top of this file for why the old `tail -c 8192` /
# `head -c 8192` windows were wrong, not just slow. `prompt` is NOT read here
# (#63 P3-2, round 3): it costs ~92% of a 1 MB payload's total parse time
# (610 ms of 663 ms measured), so extracting it unconditionally made every
# model this guard is documented to leave "untouched" — haiku, fable, any
# non-opus/sonnet id — pay almost the same latency as the model it actually
# inspects. It is now read only inside the `opus|sonnet…)` arm below, after
# the model gate has already decided this call is guarded.
model="$(json_field_str "$payload" model 2>/dev/null || true)"
# _ckpt_refuse [model] [reason] -> print the refusal (reason + reserve + the
# burn shape) to stderr and exit 2. Best-effort enrichment (the reserve
# listing): its own failure must never turn a refusal into a silent allow,
# so it is wrapped separately from the fail-open trap above.
_ckpt_refuse() {
  local why
  if [ -z "${1:-}" ]; then
    why="the Agent tool call carried no model (a bare in-session spawn)"
  elif [ "${2:-}" = "long" ]; then
    why="a $1-model Agent spawn whose prompt is over the 1,500-character length tripwire"
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
    ) 2>/dev/null || true
    printf 'Escape hatch: CLIKAE_COCKPIT_ALLOW_AGENTS=1, or `clikae cockpit --allow-agents <dur>`.\n'
  } >&2
  trap - EXIT
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
  # #63 P3-1: an EXACT match against the two short aliases used to silently
  # allow (rc=0, zero stderr) every real API model id this guard exists to
  # catch — `claude-sonnet-4-5-20250929`, `claude-opus-4-5`, `opusplan` all
  # measured straight through. Today's captured traffic uses the short
  # aliases (n=2), so this wasn't yet a live miss, but it's a one-character-
  # format-change away from becoming one, with nothing to notice when it
  # does. Family-prefix match instead: the two short aliases plus every
  # `claude-opus-*`/`claude-sonnet-*` id, plus `opusplan` (a real value, not
  # a family — matched literally).
  opus|sonnet|opusplan|claude-opus-*|claude-sonnet-*)
    # #63 P3-2: extracted here, not up top — see the comment by the `model`
    # extraction above. `prompt_len_full` is the UNTRUNCATED decoded length,
    # so a prompt long enough to BE the length tripwire's whole reason to
    # exist can never be the thing that defeats it.
    prompt="$(json_field_str "$payload" prompt 2>/dev/null || true)"
    prompt_len_full="${#prompt}"
    if [ "$prompt_len_full" -gt 1500 ]; then
      _ckpt_refuse "$model" long
    fi
    # A here-string, not `printf | grep -q`: the same early-exit pipe P2-5
    # removed above (the prompt is at most 1,500 characters here, but a
    # SIGPIPE must never be able to decide this branch either).
    if grep -qiE "$_CKPT_HEURISTIC" <<<"$prompt"; then
      _ckpt_refuse "$model"
    fi
    ;;
esac

allow
