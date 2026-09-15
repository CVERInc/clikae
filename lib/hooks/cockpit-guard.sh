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
# this tripwire is cheap insurance, not a permission gate. Untouched: the
# haiku and fable families (named, below), any checked model whose prompt
# doesn't trip, and every OTHER tool. A model id the guard does not recognise
# is CHECKED like opus/sonnet, never waved through (#63 round-5 P3-2, see
# _ckpt_model_class). This is a check on MODEL, never on `subagent_type`:
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
# PARSING (#63 round-5 P2-6). Rounds 1-4 read tool_name/model/prompt with a
# flat regex scan (json_field_str) that decoded only \" \\ \n \t \r. The
# codex security review showed that equivalent, valid encodings of a refused
# call were allowed: "\u0073onnet", "\u0041gent", "\u0072eview", an escaped
# letter in the "tool_input" key (the scan never decoded keys), and trailing
# space/tab/CR after the final brace (a "last character must be }" check
# called it malformed). The payload is now parsed once by jq, which decodes
# every JSON escape (surrogate pairs included), accepts every whitespace JSON
# permits, reads `.tool_input.model` by path (a `model` elsewhere in the
# object cannot stand in for it), and rejects anything that is not exactly
# one JSON object — rejected input is refused, never allowed. jq is already
# required to install this hook (`clikae cockpit`); if it is missing here,
# that is refused too. The prompt's length is jq's codepoint count of the
# whole decoded prompt, and the prompt text itself is only handed to the
# shell when it is short enough for the keyword heuristic to run (<= 1,500
# characters), so a 1 MB prompt never becomes a 1 MB shell word.
#
# Earlier rounds' size findings still hold as requirements: nothing is
# pre-sliced (round 2: a byte window cut multi-byte characters and hid
# `model`), and a large prompt costs one jq parse, not a per-field scan.
#
# LOCALE: pinned to C.UTF-8 (falling back to en_US.UTF-8, then a documented-
# degraded C) right below, so grep's case folding and word boundaries in the
# keyword heuristic behave the same whatever the caller exported (round 2's
# clearest repro was the same bytes refusing under en_US.UTF-8 and passing
# under LC_ALL=C).
set -uo pipefail
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
# candidate is installed is a DOCUMENTED degradation, not a silent one: the
# keywords are ASCII, so plain `C` only changes how non-ASCII text around
# them is classified, and the length tripwire is counted by jq either way.
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
command -v jq >/dev/null 2>&1 || _ckpt_fail_closed "jq is not installed (the guard parses the call with jq; clikae cockpit needed it to install this hook)"

# Only the reserve listing in a refusal needs our own directory; failing to
# find it costs that listing, not the verdict.
_dir="$(_ckpt_self_dir 2>/dev/null)" || _dir=""

# One parse. Exactly one JSON value, and it must be an object; every string
# handed back is fully decoded, with NUL removed (a shell word cannot hold
# one), and quoted with @sh for the single eval below.
_CKPT_JQ='
  if length != 1 then error("expected exactly one JSON value") else .[0] end
  | if type != "object" then error("expected a JSON object") else . end
  | def text: if type == "string" then (split("\u0000") | join("")) else "" end;
  (.tool_input) as $in
  | (if ($in | type) == "object" then $in else {} end) as $obj
  | ($obj.prompt | if type == "string" then length else 0 end) as $plen
  | "ck_tool_type=\(.tool_name | type | @sh)",
    "ck_tool=\(.tool_name | text | @sh)",
    "ck_input_type=\($in | type | @sh)",
    "ck_model_type=\($obj.model | type | @sh)",
    "ck_model=\($obj.model | text | @sh)",
    "ck_prompt_type=\($obj.prompt | type | @sh)",
    "ck_prompt_len=\($plen)",
    "ck_prompt=\(if $plen <= 1500 then ($obj.prompt | text) else "" end | @sh)"
'
if ! _ckpt_fields="$(jq -rs "$_CKPT_JQ" <<<"$payload" 2>/dev/null)"; then
  _ckpt_fail_closed "the payload is not one well-formed JSON object (truncated or malformed)"
fi
ck_tool_type="" ck_tool="" ck_input_type="" ck_model_type="" ck_model=""
ck_prompt_type="" ck_prompt_len=0 ck_prompt=""
eval "$_ckpt_fields" || _ckpt_fail_closed "the guard could not read its own parse"

[ "$ck_tool_type" = string ] || _ckpt_fail_closed "the payload has no tool_name field"
[ "$ck_tool" = "Agent" ] || allow   # matcher is "Agent" already; belt & suspenders
[ "$ck_input_type" = object ] || _ckpt_fail_closed "the payload has no tool_input field (or it is not an object)"
case "$ck_model_type" in
  string|null) ;;
  *) _ckpt_fail_closed "tool_input.model is not a string" ;;
esac
case "$ck_prompt_type" in
  string|null) ;;
  *) _ckpt_fail_closed "tool_input.prompt is not a string" ;;
esac
case "$ck_prompt_len" in
  ''|*[!0-9]*) _ckpt_fail_closed "the guard could not measure the prompt" ;;
esac
model="$ck_model"

# _ckpt_refuse [model] [reason] -> print the refusal (reason + reserve + the
# burn shape) to stderr and exit 2. Best-effort enrichment (the reserve
# listing): its own failure must never turn a refusal into anything else,
# so it is wrapped separately from the traps above.
_ckpt_refuse() {
  local why who="a ${1:-}-model Agent spawn"
  [ "${3:-}" = unknown ] && who="an Agent spawn with an unrecognised model id (${1:-}, checked like opus/sonnet)"
  if [ -z "${1:-}" ]; then
    why="the Agent tool call carried no model (a bare in-session spawn)"
  elif [ "${2:-}" = "long" ]; then
    why="$who whose prompt is over the 1,500-character length tripwire"
  else
    why="$who whose prompt reads as a build/review lane"
  fi
  {
    printf 'cockpit-guard: refused — %s.\n' "$why"
    printf 'Dispatch it instead:\n'
    printf '  clikae burn <engine> <tank> --prompt-file <f> --artifact <path>\n'
    ( [ -n "$_dir" ] &&
      # #61 round-5 merge: the enumerator now (1) asks tank_engine_known,
      # which needs list_adapters (CLIKAE_LIB + adapter_loader.sh — this
      # hook is not `bin/clikae`, nothing sets those for it; without them
      # NO directory is a tank of any engine and the reserve reads empty),
      # and (2) runs the one-time adoption sweep, which this hook must
      # never perform ON DISK: CLIKAE_ADOPT_READONLY keeps the answers in
      # memory, so the hook writes no marker, no flag and no WARN sentinel.
      CLIKAE_ROOT="$(cd "$_dir/../.." 2>/dev/null && pwd)" &&
      CLIKAE_LIB="$CLIKAE_ROOT/lib" &&
      CLIKAE_ADOPT_READONLY=1 &&
      source "$_dir/../core/adapter_loader.sh" 2>/dev/null &&
      source "$_dir/../core/profile_store.sh" 2>/dev/null &&
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

# _ckpt_model_class <model> -> "exempt", "checked" or "unknown".
#
# #63 round-5 P3-2: until this round, any id outside the opus/sonnet match
# was allowed with ZERO stderr — `us.anthropic.claude-sonnet-4-5-v1:0`
# (Bedrock), `sonnet[1m]`, `inherit`, a typo, a model family that did not
# exist when this was written. The choice here is to CHECK unknown ids, not
# to allow them visibly: this guard exists to protect the cockpit's budget,
# an id it cannot place is most likely a newer (and not cheaper) model, and
# every other unreadable input already fails closed. Refusing unknown ids
# outright was rejected: it would block every harmless spawn the day a new
# alias appears, which is how a guard gets deleted instead of obeyed. An
# unknown id runs the same length tripwire and heuristic; a refusal names it
# as unrecognised, and a pass prints one stderr line saying so.
#
# Provider spellings are normalised before matching: lowercase; a `[...]`
# suffix (`sonnet[1m]`); a Vertex `@version`; a Bedrock `<region>.anthropic.`
# prefix and `-v<n>[:<n>]` suffix. Exempt stays exactly the families the
# guard always left alone (haiku, fable).
_ckpt_model_class() {
  local m
  m="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  m="${m%%\[*}"
  m="${m%%@*}"
  case "$m" in *anthropic.*) m="${m##*anthropic.}" ;; esac
  case "$m" in *-v[0-9]|*-v[0-9]:[0-9]|*-v[0-9][0-9]|*-v[0-9]:[0-9][0-9]) m="${m%-v[0-9]*}" ;; esac
  case "$m" in
    haiku|claude-haiku-*|claude-*-haiku|claude-*-haiku-*|fable|claude-fable-*) printf 'exempt' ;;
    # #63 P3-1: family-prefix match — the short aliases, every
    # `claude-opus-*`/`claude-sonnet-*` id (and the older
    # `claude-3-5-sonnet-*` word order), and `opusplan` (a real value).
    opus|sonnet|opusplan|claude-opus-*|claude-sonnet-*|claude-*-opus|claude-*-opus-*|claude-*-sonnet|claude-*-sonnet-*) printf 'checked' ;;
    *) printf 'unknown' ;;
  esac
}

model_class="$(_ckpt_model_class "$model")"
case "$model_class" in
  checked|unknown)
    # `ck_prompt_len` is the UNTRUNCATED decoded length (jq's codepoint
    # count), so a prompt long enough to BE the length tripwire's whole
    # reason to exist can never be the thing that defeats it.
    if [ "$ck_prompt_len" -gt 1500 ]; then
      _ckpt_refuse "$model" long "$model_class"
    fi
    prompt="$ck_prompt"
    # A here-string, not `printf | grep -q`: the same early-exit pipe P2-5
    # removed above (the prompt is at most 1,500 characters here, but a
    # SIGPIPE must never be able to decide this branch either).
    if grep -qiE "$_CKPT_HEURISTIC" <<<"$prompt"; then
      _ckpt_refuse "$model" "" "$model_class"
    fi
    if [ "$model_class" = unknown ]; then
      allow "cockpit-guard: allowed an Agent spawn with an unrecognised model id ($model) — it was checked like opus/sonnet and its prompt did not trip the build/review tripwire."
    fi
    ;;
esac

allow
