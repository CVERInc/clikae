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
# file to decide, keeping the board cheap. (HANDOFF §12.)

_codex_sessions_dir() { printf '%s\n' "$1/sessions"; }

# _codex_meta_field <file> <field> — pull a string field from the session_meta
# (first line). Never abort the caller under `set -eo pipefail`.
_codex_meta_field() {
  head -n 1 "$1" 2>/dev/null \
    | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 \
    | sed -E "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"//; s/\"\$//" || true
}

# _codex_find_rollout <dir> <sid> — the rollout file for a session id (the uuid is
# the filename suffix), or empty.
_codex_find_rollout() {
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
# Gates (with adapter_recent_sids) whether the board offers a "接回" affordance.
adapter_resume_args() {
  local sid="$1"
  [ -n "$sid" ] || return 1
  printf 'resume\n%s\n' "$sid"
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
  local dir="$1" limit="${2:-5}" f sid mt
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    sid="$(_codex_meta_field "$f" id)"
    [ -n "$sid" ] || continue
    mt="$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0)"
    printf '%s\037%s\n' "$mt" "$sid"
  done <<EOF
$(_codex_rollouts_for_cwd "$dir" | head -n "$limit")
EOF
}

# A session's title for the board: codex records the user's prompt as an event_msg
# with payload.type "user_message" carrying "message". Take the first, flatten
# escapes/whitespace (no jq). Empty → the board shows the age instead.
adapter_session_title() {
  local dir="$1" sid="$2" f t
  [ -n "$sid" ] || return 0
  f="$(_codex_find_rollout "$dir" "$sid")"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  t="$(grep -m1 '"type":"user_message"' "$f" 2>/dev/null \
        | grep -oE '"message"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1 \
        | sed -E 's/^"message"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  printf '%s' "$t" | sed -E 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g' \
    | tr '\t\n' '  ' | sed -E 's/  +/ /g; s/^ //; s/ $//'
}
