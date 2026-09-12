# shellcheck shell=bash
# lib/adapters/codex.sh — adapter for the OpenAI Codex CLI.
# Reference: https://developers.openai.com/codex/config-advanced (CODEX_HOME)
#
# Codex keeps all of its local state — config.toml, auth.json, session history —
# under CODEX_HOME (default ~/.codex). Pointing CODEX_HOME at a per-profile
# directory gives each profile its own login + settings, so this is a plain
# env-dir adapter (same shape as claude).

adapter_meta_name()        { echo "OpenAI Codex CLI"; }
adapter_meta_cli_binary()  { echo "codex"; }
adapter_meta_env_var()     { echo "CODEX_HOME"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "OpenAI Codex CLI (auth + config + history in CODEX_HOME)"; }
# Optional: how to install the binary, shown when a switch finds it missing.
adapter_install_hint() { echo "npm install -g @openai/codex"; }

# Optional hook: where to drop a "your long-term memory (Soul) lives at <path>"
# pointer for `clikae memory share` (docs/memory.md). codex keeps its OWN memory
# in opaque sqlite, NOT a markdown dir we can symlink — but it reads `AGENTS.md`
# as instructions, and CODEX_HOME-scoped `$CODEX_HOME/AGENTS.md` is the global
# (per-tank, not per-repo) layer. So we point codex at the shared markdown Soul
# there. Defining THIS hook (instead of adapter_memory_dir) marks an engine as
# pointer-strategy: it reads/writes the shared Soul via the memory protocol
# rather than via a memory-dir symlink.
adapter_memory_pointer_path() {
  printf '%s\n' "$1/AGENTS.md"
}

# Nothing to seed — codex initialises CODEX_HOME on first run / login.
adapter_init() {
  local profile_dir="$1"
  : "$profile_dir"
}

adapter_export_env() {
  local profile_dir="$1"
  printf 'CODEX_HOME=%s\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  CODEX_HOME="$profile_dir" exec codex "$@"
}

# Optional hook: how to run codex HEADLESS-with-write for `clikae burn`'s
# convenience form (--prompt-file / --prompt). Codex's headless verb is `exec`,
# its working dir is `-C <dir>`, and `-s workspace-write` makes that dir writable.
# Codex takes a SINGLE working dir, so the FIRST --add-dir becomes -C (the rest
# are ignored — codex's writable root is the cwd under workspace-write). The
# prompt is the trailing positional. Items are NUL-separated so a multi-line
# prompt survives as ONE argv item (newline framing would shatter it).
adapter_burn_flags() {
  local prompt="$1"; shift
  printf 'exec\0'
  [ $# -gt 0 ] && printf -- '-C\0%s\0' "$1"
  printf -- '-s\0workspace-write\0%s\0' "$prompt"
}

# Optional hook: how to run codex HEADLESS READ-ONLY for `clikae conduct`'s
# fan-out. `-s read-only` sandboxes it to reads; --skip-git-repo-check lets it run
# outside a repo. First <dir> is the cwd (-C); the prompt is the trailing data.
# NUL-separated items (multi-line prompt survives as one argv item).
adapter_audit_flags() {
  local prompt="$1"; shift
  printf 'exec\0--skip-git-repo-check\0'
  [ $# -gt 0 ] && printf -- '-C\0%s\0' "$1"
  printf -- '-s\0read-only\0%s\0' "$prompt"
}

# Optional hook: start a session seeded with an initial prompt (for
# `clikae handoff --to codex/<profile>`). Codex takes a positional prompt.
adapter_start_with_prompt() {
  local profile_dir="$1" prompt="$2"; shift 2
  CODEX_HOME="$profile_dir" exec codex "$prompt" "$@"
}

# Optional hook: the logged-in account label, shown by `clikae list` / `status`
# and the dashboard. With ChatGPT auth, codex stores identity in auth.json's
# `id_token` — a JWT whose base64url payload carries the account email. Decode
# with grep/sed/tr + base64 (no jq); API-key logins have no id_token, so they
# just yield nothing. Never propagate a no-match under the caller's `set -eo
# pipefail` (it would abort list/status) — always end at return 0.
adapter_account_label() {
  local f="$1/auth.json" idt payload decoded
  [ -f "$f" ] || return 0
  idt="$(grep -oE '"id_token"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
        | head -n 1 | sed -E 's/.*"id_token"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  [ -n "$idt" ] || return 0
  # JWT = header.payload.signature; the payload is base64url (no padding).
  payload="$(printf '%s' "$idt" | cut -d. -f2 | tr '_-' '/+')"
  [ -n "$payload" ] || return 0
  case $(( ${#payload} % 4 )) in 2) payload="$payload==" ;; 3) payload="$payload=" ;; esac
  # base64 -d (GNU + recent macOS) with a -D fallback for older BSD.
  decoded="$(printf '%s' "$payload" | base64 -d 2>/dev/null || printf '%s' "$payload" | base64 -D 2>/dev/null || true)"
  [ -n "$decoded" ] || return 0
  printf '%s' "$decoded" \
    | grep -oE '"email"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n 1 | sed -E 's/.*:[[:space:]]*"//; s/"$//' || true
  return 0
}

# --- session continuity: surface codex sessions in the board's "Continue" list -
# Codex stores each session as a rollout JSONL under
#   CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ISO-ts>-<uuid>.jsonl
# whose FIRST line is a `session_meta` carrying payload.id (the session UUID) and
# payload.cwd (the dir it ran in). Unlike claude, codex does NOT slug $PWD into
# the path — so we match on the recorded cwd. Filenames embed a sortable ISO
# timestamp, so a lexical reverse sort is newest-first. We read only line 1 per
# file to decide, keeping the board cheap.

_codex_sessions_dir() { printf '%s\n' "$1/sessions"; }

# _codex_newest_chain <sessions-dir> -> one path per line: sessions/ itself,
# then the lexically-newest existing YYYY dir under it, then the newest MM
# under THAT, then the newest DD under THAT — stopping at the first level
# that does not exist. Used ONLY as board_stale's freshness signal for codex
# (see board_state.sh's `_board_scan_root`): a new rollout always
# creates/touches ITS day directory, but sessions/ itself sits three levels
# above and so never moves for it (P1-C). No `find` here on purpose — this
# runs on EVERY render via board_stale, and this repo's own test suite
# (home-bounded.bats' `_board_shims`) hard-fails any `find` call on a warm
# render; a bounded glob at each of 3 levels (at most a handful of years,
# 12 months, 31 days) is not that.
#
# round-3 fix review, P2-1: the previous version (`_codex_today_scan_dir`)
# derived y/m/d from the OBSERVER's own `date`, not from what is actually on
# disk. That is only correct when the observer's local "today" agrees with
# whatever clock wrote the newest rollout's date directory — true by default
# (codex uses the machine's own local time), false the moment clikae runs
# under an explicit `TZ=`, across a timezone during travel, or from a
# CI/cron invocation pinned to UTC while the interactive session that wrote
# the rollout ran in local time. When the two disagree, the old code walked
# up from a COMPUTED leaf that doesn't exist to a directory that does — but
# that directory could be a sibling of where the real newest rollout landed,
# whose own mtime a NEW rollout inside an EXISTING sibling day dir never
# touches (only that day dir's own mtime moves). The board then never
# rebuilds and a brand new session — and the limit it carries — is
# permanently invisible.
#
# Reading the actual newest chain off disk instead needs no clock at all:
# whichever level the account is CURRENTLY writing to is, by construction,
# the lexically-greatest entry at its level (zero-padded YYYY/MM/DD sort
# correctly as strings). board_state.sh records every level THIS returns,
# so a new rollout inside an existing day always bumps a directory this
# check is already watching, and a brand new day/month/year directory bumps
# its own newly-created parent, which is also on the list.
_codex_newest_chain() {
  local sess="$1"
  [ -d "$sess" ] || { printf '%s\n' "$sess"; return 0; }
  printf '%s\n' "$sess"
  local y="" m="" d="" p
  for p in "$sess"/*/; do [ -d "$p" ] && y="${p%/}"; done
  [ -n "$y" ] || return 0
  printf '%s\n' "$y"
  for p in "$y"/*/; do [ -d "$p" ] && m="${p%/}"; done
  [ -n "$m" ] || return 0
  printf '%s\n' "$m"
  for p in "$m"/*/; do [ -d "$p" ] && d="${p%/}"; done
  [ -n "$d" ] || return 0
  printf '%s\n' "$d"
}

# _codex_meta_field <file> <field> — pull a string field from the session_meta
# (first line). Never abort the caller under `set -eo pipefail`.
_codex_meta_field() {
  if declare -F reading_cache_run >/dev/null; then
    reading_cache_run "codex-meta-$2" "$1" _codex_meta_uncached "$@"
  else
    _codex_meta_uncached "$@"
  fi
}

_codex_meta_uncached() {
  local first_line=""
  read -r first_line < "$1" 2>/dev/null || true
  if [[ "$first_line" == *'"'"$2"'"'* ]]; then
    local part="${first_line#*\"$2\":\"}"
    printf '%s\n' "${part%%\"*}"
  fi
}

# _codex_find_rollout <dir> <sid> — the rollout file for a session id (the uuid is
# the filename suffix), or empty.
_codex_find_rollout() {
  if [ "${_CLIKAE_BOARD:-0}" = 1 ]; then
    local f; f="$(board_find codex "$1" "$2" 2>/dev/null)" && [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
  fi
  local sdir; sdir="$(_codex_sessions_dir "$1")"
  [ -d "$sdir" ] || return 0
  find "$sdir" -type f -name "rollout-*-$2.jsonl" 2>/dev/null | head -n 1
}

# _codex_rollouts_for_cwd <dir> — rollout files under <dir> whose recorded cwd is
# $PWD, newest first. The compare is trailing-slash-insensitive on BOTH sides: a
# rollout written from a path with a trailing slash (or a $PWD that carries one)
# must still match, or the session silently vanishes from the board / can't resume.
# Same normalisation `live_dir_users` already applies (`${dir%/}`).
_codex_rollouts_for_cwd() {
  local sdir f want; sdir="$(_codex_sessions_dir "$1")"
  [ -d "$sdir" ] || return 0
  want="${PWD%/}"
  find "$sdir" -type f -name 'rollout-*.jsonl' 2>/dev/null | sort -r | while IFS= read -r f; do
    local rec; rec="$(_codex_meta_field "$f" cwd)"
    [ "${rec%/}" = "$want" ] && printf '%s\n' "$f"
  done
}

# Resume a codex session by id: `codex resume <uuid>` (verified via codex --help).
# Gates (with adapter_recent_sids) whether the board offers a "resume" affordance.
adapter_resume_args() {
  local sid="$1"
  [ -n "$sid" ] || return 1
  printf 'resume\n%s\n' "$sid"
}

# Optional hook: the inverse of adapter_resume_args — see claude.sh's twin for
# why switch.sh needs this (it replaces the old CLIKAE_LAUNCH_SID environment
# variable, which leaked into every session a tmux server born under it later
# spawned).
#
# adapter_new_session_args is deliberately left undefined here. `codex exec`
# has a `--session_id`/fork option, but it names a session to FORK FROM — it
# requires that session to already exist, which is a different lifecycle from
# handing a brand-new interactive session a caller-chosen id before it starts.
# codex exposed nothing usable for that at the version checked (0.153.4;
# `codex --help` itself hung in this sandbox rather than a real terminal, so
# this was confirmed by inspecting the binary's own strings, not a live run —
# worth re-checking against a real `codex --help` before trusting it further).
# A bare `clikae codex <tank>` keeps the tank-scoped guess (DESIGN-tmux.md
# Rule 2: an engine with no equivalent flag degrades honestly rather than
# pretending to be exact).
adapter_sid_from_args() {
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "resume" ]; then printf '%s' "$a"; return 0; fi
    prev="$a"
  done
  return 1
}

# This dir's most recent rollout under <dir> (for relay / handoff).
adapter_transcript_path() {
  local f; f="$(_codex_rollouts_for_cwd "$1" | head -n 1)"
  [ -n "$f" ] || return 1
  printf '%s\n' "$f"
}

# CHEAP recent sessions for the home board: "<epoch-mtime>\037<sid>", newest
# first, capped at [limit] (default 5), for sessions whose cwd is $PWD.
adapter_recent_sids() {
  if [ "${_CLIKAE_BOARD:-0}" = 1 ]; then
    # Snapshot first, live content-scan fallback only on a genuine miss — see
    # claude.sh's twin comment (2026-09-12 round-1 fix review, P1-1).
    local _bout; _bout="$(board_recent codex "$@")"
    if [ -n "$_bout" ]; then printf '%s\n' "$_bout"; return 0; fi
  fi
  local dir="$1" limit="${2:-5}" f sid mt
  # codex's this-dir set is content-matched (a rollout records $PWD in its body,
  # not its path — see _codex_rollouts_for_cwd), so the FILE LIST comes from there;
  # sessions_by_mtime (shared kernel) then stats+sorts it. sid is read from each
  # rollout's session_meta (not derivable from the path). Read the list into an
  # array line-by-line, never via unquoted word-splitting: tank names are
  # validated (no spaces) but $CLIKAE_HOME rides on $HOME, which ISN'T — a space
  # anywhere in the home path used to shred every path into fragments and
  # silently drop all codex sessions from the board.
  local -a rfiles=()
  while IFS= read -r f; do
    [ -n "$f" ] && rfiles+=("$f")
  done <<EOF
$(_codex_rollouts_for_cwd "$dir")
EOF
  [ "${#rfiles[@]}" -gt 0 ] || return 0
  # plain `read -r mt f` (NOT `IFS= read`) so "<mtime> <path>" splits into two.
  sessions_by_mtime "${rfiles[@]}" | head -n "$limit" | while read -r mt f; do
    [ -f "$f" ] || continue
    sid="$(_codex_meta_field "$f" id)"
    [ -n "$sid" ] || continue
    printf '%s\037%s\n' "$mt" "$sid"
  done
}

# A session's title for the board: codex records the user's prompt as an event_msg
# with payload.type "user_message" carrying "message". Take the first, flatten
# escapes/whitespace (no jq). Empty → the board shows the age instead.
adapter_session_title() {
  local dir="$1" sid="$2" f
  [ -n "$sid" ] || return 0
  f="$(_codex_find_rollout "$dir" "$sid")"
  adapter_title_for_file "$f"
}

# Optional hook: title straight from a rollout FILE (see claude.sh's twin for
# why: cross-project listings can't derive the path from $PWD). Escape-aware
# =~ extraction — the old ${line%%\"*} surgery truncated at an internal \".
# No customTitle-equivalent here: codex's rollout format has no user-rename
# event to prefer (checked 2026-07-12 alongside claude.sh's customTitle fix;
# nothing invented — first user_message stays the only title source).
adapter_title_for_file() {
  if declare -F reading_cache_run >/dev/null; then
    reading_cache_run codex-title "$1" _codex_title_uncached "$@"
  else
    _codex_title_uncached "$@"
  fi
}

_codex_title_uncached() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 0

  local re_msg='"message"[[:space:]]*:[[:space:]]*"(([^"\]|\\.)*)"'
  local line_in idx_in=0 max_lines_in=100 title_in=""
  while IFS= read -r line_in; do
    idx_in=$((idx_in + 1))
    [ "$idx_in" -gt "$max_lines_in" ] && break
    if [[ "$line_in" == *'"type":"user_message"'* ]] && [[ $line_in =~ $re_msg ]]; then
      title_in="${BASH_REMATCH[1]}"
      break
    fi
  done < "$f" 2>/dev/null

  [ -n "$title_in" ] || title_in="(no preview)"
  title_in="${title_in//\\n/ }"
  title_in="${title_in//\\t/ }"
  title_in="${title_in//\\\"/\"}"
  printf '%s' "$title_in"
}

adapter_find_session() {
  _codex_find_rollout "$1" "$2"
}

adapter_session_cwd() {
  _codex_meta_field "$1" cwd
}

