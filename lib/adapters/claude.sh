# shellcheck shell=bash
# lib/adapters/claude.sh — adapter for Anthropic Claude Code CLI.
# Reference: https://docs.claude.com/en/docs/claude-code/iam (CLAUDE_CONFIG_DIR)

adapter_meta_name()        { echo "Claude Code"; }
adapter_meta_cli_binary()  { echo "claude"; }
adapter_meta_env_var()     { echo "CLAUDE_CONFIG_DIR"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "Anthropic Claude Code CLI (credentials + settings in CLAUDE_CONFIG_DIR)"; }

# adapter_init is optional. For Claude there's nothing to seed — the CLI itself
# initialises the directory on first login.
adapter_init() {
  local profile_dir="$1"
  : "$profile_dir"  # silence shellcheck
}

# Print KEY=VALUE pairs (one per line) to export when activating this profile.
adapter_export_env() {
  local profile_dir="$1"
  printf 'CLAUDE_CONFIG_DIR=%s\n' "$profile_dir"
}

# Exec the CLI with this profile's env applied.
adapter_run() {
  local profile_dir="$1"; shift
  CLAUDE_CONFIG_DIR="$profile_dir" exec claude "$@"
}

# Optional hook: start a fresh session under this profile, seeded with an initial
# prompt. Used by `clikae handoff --to` to hand a brief to the next tank. Claude
# Code takes an initial prompt as a positional argument.
adapter_start_with_prompt() {
  local profile_dir="$1" prompt="$2"; shift 2
  CLAUDE_CONFIG_DIR="$profile_dir" exec claude "$prompt" "$@"
}

# Optional hook: the CLI flags to RESUME a specific session by id, one per line
# (each line becomes a separate argv item). The home board's "continue" headline
# uses this to reopen this directory's most recent session — effectively
# `clikae claude <tank> -- --resume <sid>`. Defining this hook is what marks an
# engine as resume-capable on the board, so the "⏎ 接回" affordance only shows up
# when the session can really be resumed.
adapter_resume_args() {
  local sid="$1"
  [ -n "$sid" ] || return 1
  printf -- '--resume\n%s\n' "$sid"
}

# --- session carry-over for `clikae relay` ----------------------------------
#
# Claude Code stores each conversation as a JSONL transcript at
#   <CLAUDE_CONFIG_DIR>/projects/<slug>/<session-id>.jsonl
# where <slug> is the absolute working directory with every non-alphanumeric
# character replaced by "-" (so /Users/me/dev → -Users-me-dev). `claude --resume
# <session-id>` resumes a transcript by id within the current directory.
#
# So to hand the *current directory's* live conversation from one profile to
# another (e.g. when the first profile hit its usage limit), we copy that
# directory's most recent transcript into the target profile's matching project
# dir, then resume it under the target profile — new turns burn the target's
# quota. The source profile is never touched.
#
# Returns non-zero (without exec'ing) if there's no transcript to carry, so the
# caller can fall back to starting a fresh session.
_claude_project_slug() {
  # Mirror Claude Code's own slugify: [^A-Za-z0-9] -> '-'.
  printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'
}

# Optional hook: where Claude Code keeps THIS directory's long-term memory, for
# `clikae <engine> <tank> --ephemeral`. Same projects/<slug> layout as transcripts
# (slug = $PWD slugified); memory lives in a `memory/` subdir. Defining this hook
# is what marks an engine as ephemeral-capable.
adapter_memory_dir() {
  local dir="$1"
  printf '%s\n' "$dir/projects/$(_claude_project_slug "$PWD")/memory"
}

# Optional hook: print the path to the *current directory's* most recent
# transcript under the given config dir, or return non-zero if there is none.
# Used by `clikae relay` (to carry/resume a session) and `clikae handoff` (to
# summarise a session into a portable brief). Keeping the lookup here means the
# slug rule lives in exactly one place.
adapter_transcript_path() {
  local dir="$1"
  local proj
  proj="$dir/projects/$(_claude_project_slug "$PWD")"
  [ -d "$proj" ] || return 1
  local latest
  latest="$(ls -t "$proj"/*.jsonl 2>/dev/null | head -n 1 || true)"
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

# Build a relay-preview row for one transcript FILE:
#   <session-id> \037 <last-active> \037 <approx-msgs> \037 <title>
# The title is the opening user message, left untruncated so multibyte (CJK)
# titles never get sliced mid-character (a 200-byte guard caps a runaway line).
# One place owns this format so the single-session and list views can't drift.
_claude_meta_for_file() {
  local f="$1"
  [ -f "$f" ] || return 1
  local sid mtime nmsgs title
  sid="$(basename "$f" .jsonl)"
  # GNU stat FIRST (Linux `stat -f` = --file-system, prints garbage instead of
  # failing, so it must not lead); BSD/macOS stat rejects `-c` and falls through.
  mtime="$(stat -c '%y' "$f" 2>/dev/null | cut -d. -f1 \
        || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f" 2>/dev/null \
        || true)"
  [ -n "$mtime" ] || mtime="?"
  # Approximate turn count: lines carrying a role marker. Cheap and good enough
  # for a preview; never let a no-match abort under the caller's pipefail.
  nmsgs="$(grep -c '"role"' "$f" 2>/dev/null || true)"
  [ -n "$nmsgs" ] || nmsgs=0
  # Title: prefer Claude's OWN ai-generated session title. The transcript carries
  # a  {"type":"ai-title","aiTitle":"…"}  line — the same human-readable name
  # Claude shows in its session list (e.g. "Lucky number confirmation"). It's
  # already in the file, so a real title costs nothing: no local model needed.
  # Take the LAST one (a session can be re-titled). Sessions/engines without such
  # a line fall through to the opening user message below.
  title="$(grep -oE '"aiTitle"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' "$f" 2>/dev/null \
        | tail -n 1 \
        | sed -E 's/^"aiTitle"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
  # Fallback = the opening user message. The first line with a user role carries
  # the prompt in one of two shapes, depending on the Claude Code version:
  #   "content":"…"                          (current — a plain string)
  #   "content":[{"type":"text","text":"…"}]   (older / tool-augmented — an array)
  # Take the first user line, then try the array's "text" field, falling back to
  # the plain "content" string. (No jq/python — grep+sed only.)
  if [ -z "$title" ]; then
    local _uline
    _uline="$(grep -m1 '"role"[[:space:]]*:[[:space:]]*"user"' "$f" 2>/dev/null || true)"
    title="$(printf '%s' "$_uline" \
          | grep -oE '"text"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1 \
          | sed -E 's/^"text"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    [ -n "$title" ] || title="$(printf '%s' "$_uline" \
          | grep -oE '"content"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1 \
          | sed -E 's/^"content"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  fi
  title="$(printf '%s' "$title" \
        | sed -E 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g' \
        | tr '\t\n' '  ' \
        | sed -E 's/  +/ /g; s/^ //; s/ $//')"
  [ -n "$title" ] || title="(no preview)"
  [ "${#title}" -gt 200 ] && title="${title:0:200}…"
  printf '%s\037%s\037%s\037%s\n' "$sid" "$mtime" "$nmsgs" "$title"
}

# Optional hook: describe ONE session for `clikae relay`'s preview card — the
# current directory's newest transcript under <dir>, or a specific one when <sid>
# is given. Returns non-zero if there's no such transcript.
adapter_session_meta() {
  local dir="$1" sid="${2:-}" f
  if [ -n "$sid" ]; then
    f="$dir/projects/$(_claude_project_slug "$PWD")/$sid.jsonl"
  else
    f="$(adapter_transcript_path "$dir" || true)"
  fi
  [ -n "$f" ] || return 1
  _claude_meta_for_file "$f"
}

# Optional hook: list recent sessions for the current dir under <dir>, newest
# first, one preview row each (same columns as adapter_session_meta), capped at
# [limit] (default 10). Powers relay's "pick another session" chooser. Returns
# non-zero when there are none.
adapter_list_sessions() {
  local dir="$1" limit="${2:-10}" proj f any=0
  proj="$dir/projects/$(_claude_project_slug "$PWD")"
  [ -d "$proj" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _claude_meta_for_file "$f" && any=1
  done <<EOF
$(ls -t "$proj"/*.jsonl 2>/dev/null | head -n "$limit")
EOF
  [ "$any" -eq 1 ] || return 1
}

adapter_relay() {
  local from_dir="$1" to_dir="$2"; shift 2

  # Optional: carry a SPECIFIC session (relay's session picker passes this);
  # without it, fall back to the current directory's newest transcript.
  local want_sid=""
  if [ "${1:-}" = "--session" ]; then want_sid="$2"; shift 2; fi

  local to_proj
  to_proj="$to_dir/projects/$(_claude_project_slug "$PWD")"

  # Most recently modified transcript = the conversation you were just in.
  local latest=""
  if [ -n "$want_sid" ]; then
    latest="$from_dir/projects/$(_claude_project_slug "$PWD")/$want_sid.jsonl"
    [ -f "$latest" ] || latest=""
  else
    latest="$(adapter_transcript_path "$from_dir" || true)"
  fi
  if [ -z "$latest" ]; then
    log_warn "No Claude transcript found for this directory under the source profile."
    log_dim "(looked under $from_dir/projects/$(_claude_project_slug "$PWD"))"
    return 1
  fi

  local sid
  sid="$(basename "$latest" .jsonl)"

  mkdir -p "$to_proj"
  if ! cp "$latest" "$to_proj/$sid.jsonl"; then
    log_warn "Couldn't copy the transcript into the target profile."
    return 1
  fi

  log_ok "Carried session ${sid%%-*}… into the target profile."
  log_dim "Resuming on the new profile's quota; the original session is untouched."
  CLAUDE_CONFIG_DIR="$to_dir" exec claude --resume "$sid" "$@"
}

# Optional hook: a human-readable label for whichever account is logged in to
# this profile, shown by `clikae list` / `status` so you don't have to remember
# what "a" vs "b" means. Claude stores the logged-in account in .claude.json as
# oauthAccount.emailAddress — pull it with grep/sed (no jq/python dependency).
# Prints nothing if the profile hasn't been logged in yet.
adapter_account_label() {
  local dir="$1" f="$1/.claude.json"
  [ -f "$f" ] || return 0
  # Real .claude.json is pretty-printed: `"emailAddress": "you@example.com"`
  # (whitespace after the colon), so tolerate it. And never let a no-match grep
  # propagate failure up — under the caller's `set -eo pipefail` that would abort
  # `clikae list` / `status` instead of just showing a dash.
  grep -oE '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
    | head -n 1 \
    | sed -E 's/.*:[[:space:]]*"//; s/"$//' || true
  return 0
}

# --- macOS keychain login carry-over (optional migrate hook) ----------------
#
# On macOS, Claude Code stores its OAuth token in the login Keychain, NOT inside
# CLAUDE_CONFIG_DIR. The keychain service name is
#   "Claude Code-credentials-<suffix>"
# where <suffix> is the first 8 hex chars of sha256(<absolute CLAUDE_CONFIG_DIR>)
# (no trailing slash). So `clikae migrate`, which MOVES the config dir to a new
# path, changes the suffix and orphans the saved token — claude can't find it at
# the new path and asks you to log in again. Full write-up: docs/claude-on-macos.md.
#
# Map a config dir to its keychain service name (macOS sha256 via `shasum`).
_claude_keychain_service() {
  local dir="$1" hash
  hash="$(printf '%s' "$dir" | shasum -a 256 2>/dev/null | cut -c1-8)"
  [ -n "$hash" ] || return 1
  printf 'Claude Code-credentials-%s\n' "$hash"
}

# Optional adapter hook: `clikae migrate --keep-login` calls this after moving a
# profile's config dir, to carry the saved login from the old path's keychain
# slot to the new path's slot so the session survives the move.
#
# Returns: 0 = login copied; 1 = nothing to do (no old slot / new slot already
# present / not macOS); 2 = found a saved login but couldn't copy it.
# Never prints the secret.
adapter_migrate_credentials() {
  local old_dir="$1" new_dir="$2"
  case "$OSTYPE" in darwin*) ;; *) return 1 ;; esac
  command -v security >/dev/null 2>&1 || return 1

  local old_svc new_svc
  old_svc="$(_claude_keychain_service "$old_dir")" || return 1
  new_svc="$(_claude_keychain_service "$new_dir")" || return 1

  # Nothing saved at the old path → nothing to carry over.
  security find-generic-password -s "$old_svc" >/dev/null 2>&1 || return 1
  # Already present at the new path → don't clobber it.
  security find-generic-password -s "$new_svc" >/dev/null 2>&1 && return 1

  local acct secret
  acct="$(security find-generic-password -s "$old_svc" 2>/dev/null \
            | awk -F'"' '/^[[:space:]]*"acct"/{print $4}')"
  [ -n "$acct" ] || return 2
  secret="$(security find-generic-password -s "$old_svc" -w 2>/dev/null)" || return 2
  [ -n "$secret" ] || return 2

  security add-generic-password -a "$acct" -s "$new_svc" -l "$new_svc" \
    -w "$secret" -U >/dev/null 2>&1 || { secret=""; return 2; }
  secret=""
  return 0
}
