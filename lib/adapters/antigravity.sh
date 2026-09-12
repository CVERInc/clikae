# shellcheck shell=bash
# lib/adapters/antigravity.sh — Antigravity (agy) RESUME-ONLY adapter shim.
#
# ⚠️ antigravity is a launch-only TARGET (lib/targets/antigravity.sh), NOT an
# env-switchable engine: it's a global single-account vendor whose tank switching
# rides the ~/.gemini symlink + a macOS Keychain login carry (see
# lib/commands/antigravity.sh). This file exists ONLY to give `clikae resume` the
# per-engine hooks it needs (find/resume a session by id) — it deliberately has an
# EMPTY env var and `subcommand` strategy so the rest of clikae keeps treating
# antigravity as the target it is. Classification code must use clikae_is_target,
# which wins over this file's presence; never infer "env-switchable" from it.

adapter_meta_name()        { echo "Antigravity"; }
adapter_meta_cli_binary()  { echo "agy"; }
adapter_meta_env_var()     { echo ""; }
adapter_meta_strategy()    { echo "subcommand"; }
adapter_meta_description() { echo "Google DeepMind Antigravity CLI"; }

adapter_init() {
  :
}

adapter_export_env() {
  :
}

adapter_run() {
  local profile_dir="$1"; shift
  local name; name="$(basename "$profile_dir")"
  # Sourcing lib/commands/antigravity.sh so we can call _agy_switch
  # shellcheck source=../commands/antigravity.sh
  source "$CLIKAE_LIB/commands/antigravity.sh"
  _agy_switch "$name" "$@"
}

adapter_resume_args() {
  local sid="$1"
  [ -n "$sid" ] || return 1
  printf '--conversation\n%s\n' "$sid"
}

# Optional hook: the inverse of adapter_resume_args — see claude.sh's twin for
# why switch.sh needs this (it replaces the old CLIKAE_LAUNCH_SID environment
# variable, which leaked into every session a tmux server born under it later
# spawned).
#
# adapter_new_session_args is deliberately left undefined here: `agy --help`
# (checked live) has no flag for handing a brand-new session a caller-chosen
# id — `--conversation` only resumes one that already exists, and
# `--new-project` takes a project name, not a session id. A bare `clikae agy
# <tank>` keeps the tank-scoped guess (DESIGN-tmux.md Rule 2).
adapter_sid_from_args() {
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "--conversation" ]; then printf '%s' "$a"; return 0; fi
    prev="$a"
  done
  return 1
}

adapter_find_session() {
  local dir="$1" sid="$2" f
  [ -n "$sid" ] || return 1
  f="$dir/antigravity-cli/brain/$sid/.system_generated/logs/transcript.jsonl"
  [ -f "$f" ] && printf '%s\n' "$f"
}

adapter_session_cwd() {
  local f="$1"
  [ -f "$f" ] || return 0
  local bdir; bdir="$(dirname "$(dirname "$(dirname "$(dirname "$f")")")")"
  local sid; sid="${f%/.system_generated/*}"; sid="${sid##*/}"
  local cwd
  cwd="$(grep -F "$sid" "$bdir/history.jsonl" 2>/dev/null \
    | grep -oE '"workspace"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
    | sed -E 's/^"workspace"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
  [ -n "$cwd" ] || cwd="$HOME"
  printf '%s\n' "$cwd"
}

adapter_session_title() {
  local dir="$1" sid="$2"
  [ -n "$sid" ] || return 0
  adapter_title_for_file "$dir/antigravity-cli/brain/$sid/.system_generated/logs/transcript.jsonl"
}

# Optional hook: title straight from a transcript FILE (see claude.sh's twin).
# The resume picker used to re-implement this extraction inline — minus the
# whitespace-collapse below, so the same session titled differently in the
# picker vs the home board. No customTitle-equivalent here: antigravity's
# transcript has no user-rename event to prefer (checked 2026-07-12 alongside
# claude.sh's customTitle fix; nothing invented — the opening request stays
# the only title source).
#
# 🔴 2026-09-06: an empty extraction used to fall through as a bare "", which
# the home board's Live row printed as a literal `""` — the ONLY row on the
# board with no fallback text (codex/claude/grok all land on "(no preview)"
# via their own adapter_title_for_file). Same fallback here, same reason: an
# unreadable/pre-opening-message transcript still deserves SOME word in that
# column, not silence that reads as a rendering bug.
adapter_title_for_file() {
  local f="$1" t
  [ -n "$f" ] && [ -f "$f" ] || return 0
  t="$(head -n 1 "$f" 2>/dev/null | grep -oE '"content"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1 \
        | sed -E 's/^"content"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
  if [[ "$t" == *"<USER_REQUEST>"* ]]; then
    t="${t#*<USER_REQUEST>}"
    t="${t%%</USER_REQUEST>*}"
  fi
  t="$(printf '%s' "$t" | sed -E 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g' \
    | tr '\t\n' '  ' | sed -E 's/  +/ /g; s/^ //; s/ $//')"
  [ -n "$t" ] || t="(no preview)"
  printf '%s' "$t"
}

# Optional hook: CHEAP list of this directory's recent sessions under <dir> —
# "<epoch-mtime>\037<session-id>" per line, newest first, capped at [limit]
# (default 5) — the same contract as claude.sh's/codex.sh's twins, and the
# missing half of why the home board's Live row showed an empty preview for
# agy: without this hook, `_home_live_rows` (lib/commands/home.sh) never even
# calls adapter_session_title — its `declare -F adapter_recent_sids` gate
# failed outright, so title/recap stayed the empty strings they were
# initialized to. `agy` has no equivalent of $PWD-embedded transcript paths
# (claude) or in-file cwd records (codex); the only cwd record is
# history.jsonl's "workspace" field per session, keyed by session id — so scope
# by reading that back per candidate, same as adapter_session_cwd already does
# for one session at a time.
adapter_recent_sids() {
  local dir="$1" limit="${2:-5}" brain want sdir sid f cwd
  brain="$dir/antigravity-cli/brain"
  [ -d "$brain" ] || return 0
  want="${PWD%/}"
  local cache="$dir/antigravity-cli/cache/last_conversations.json"
  # Burn needs the newest transcript even before the CLI refreshes its cache.
  if [ "${3:-}" != disk ] && [ -f "$cache" ]; then
    local want_esc; want_esc="$(printf '%s' "$want" | sed 's/[.[\*^$]/\\&/g')"
    sid="$(grep -E '"'"$want_esc"'"[[:space:]]*:[[:space:]]*"[^"]+"' "$cache" 2>/dev/null \
      | head -n 1 | sed -E 's/.*:[[:space:]]*"//; s/".*//' || true)"
    if [ -n "$sid" ]; then
      f="$brain/$sid/.system_generated/logs/transcript.jsonl"
      if [ -f "$f" ]; then
        local mt
        mt="$(_clikae_mtime "$f" 2>/dev/null || echo "?")"
        printf '%s\037%s\n' "$mt" "$sid"
        return 0
      fi
    fi
  fi

  local -a afiles=()
  for sdir in "$brain"/*/; do
    [ -d "$sdir" ] || continue
    f="${sdir}.system_generated/logs/transcript.jsonl"
    [ -f "$f" ] || continue
    cwd="$(adapter_session_cwd "$f" 2>/dev/null || true)"
    [ "${cwd%/}" = "$want" ] || continue
    afiles+=("$f")
  done
  [ "${#afiles[@]}" -gt 0 ] || return 0
  sessions_by_mtime "${afiles[@]}" | head -n "$limit" | while read -r mt f; do
    [ -f "$f" ] || continue
    sid="${f%/.system_generated/*}"; sid="${sid##*/}"
    [ -n "$sid" ] || continue
    printf '%s\037%s\n' "$mt" "$sid"
  done
}

