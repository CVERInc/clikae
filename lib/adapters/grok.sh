# shellcheck shell=bash
# lib/adapters/grok.sh — adapter for xAI's Grok Build CLI.
# Reference: ~/.grok/docs/user-guide/05-configuration.md (GROK_HOME)
#
# Grok keeps every piece of local state — auth.json, config.toml, sessions/,
# rules/, skills/ — under GROK_HOME (default ~/.grok). Pointing GROK_HOME at a
# per-profile directory gives each tank its own login + settings + history, so
# this is a plain env-dir adapter (same shape as claude and codex).
#
# NOTE: GROK_HOME moves the STATE, not the binary. The installer drops `grok`
# at ~/.grok/bin/grok and puts that on PATH; a tank only re-homes what the CLI
# writes. Keep ~/.grok/bin on PATH even when every tank lives elsewhere.

adapter_meta_name()        { echo "Grok Build CLI"; }
adapter_meta_cli_binary()  { echo "grok"; }
adapter_meta_env_var()     { echo "GROK_HOME"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "xAI Grok Build CLI (auth + config + sessions in GROK_HOME)"; }
adapter_install_hint()     { echo "curl -fsSL https://x.ai/cli/install.sh | bash"; }

# Optional hook: where to drop a "your long-term memory (Soul) lives at <path>"
# pointer for `clikae memory share` (docs/memory.md). Grok's own cross-session
# memory (`--experimental-memory`) is an opaque vendor store, NOT a markdown dir
# we can symlink — but it reads `$GROK_HOME/AGENTS.md` as GLOBAL rules for every
# project (12-project-rules.md: "Home rules: $GROK_HOME, then …"). So we point
# grok at the shared markdown Soul there, exactly as codex does. Defining THIS
# hook (instead of adapter_memory_dir) marks the engine as pointer-strategy.
adapter_memory_pointer_path() {
  printf '%s\n' "$1/AGENTS.md"
}

# Nothing to seed — grok initialises GROK_HOME on first run / login.
adapter_init() {
  local profile_dir="$1"
  : "$profile_dir"
}

adapter_export_env() {
  local profile_dir="$1"
  printf 'GROK_HOME=%s\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  GROK_HOME="$profile_dir" exec grok "$@"
}

# Optional hook: start a session seeded with an initial prompt (for
# `clikae handoff --to grok/<profile>`). Grok takes a positional prompt
# (`grok "fix the bug"`). Defining this is ALSO what classifies grok as an
# AI engine for the board / burn (see docs/adding-an-adapter.md).
adapter_start_with_prompt() {
  local profile_dir="$1" prompt="$2"; shift 2
  GROK_HOME="$profile_dir" exec grok "$prompt" "$@"
}

# Optional hook: how to run grok HEADLESS-with-write for `clikae burn`'s
# convenience form (--prompt-file / --prompt). Grok's headless verb is the `-p`
# flag, its working dir is `--cwd <dir>`, and `--sandbox workspace` confines
# writes to that dir + temp + GROK_HOME (18-sandbox.md). `--permission-mode
# bypassPermissions` is what stops a non-TTY run from blocking on an approval
# prompt it can never answer. Grok takes a SINGLE working dir, so the FIRST
# --add-dir becomes --cwd (the rest are ignored — the sandbox's writable root
# IS the cwd). Items are NUL-separated so a multi-line prompt survives as ONE
# argv item (newline framing would shatter it).
adapter_burn_flags() {
  local prompt="$1"; shift
  [ $# -gt 0 ] && printf -- '--cwd\0%s\0' "$1"
  printf -- '--permission-mode\0bypassPermissions\0--sandbox\0workspace\0-p\0%s\0' "$prompt"
}

# Optional hook: how to run grok HEADLESS READ-ONLY for `clikae conduct`'s
# fan-out. Two independent fences, because either one alone has a hole:
#
#   --sandbox read-only   Kernel-enforced (Seatbelt/Landlock). Verified by doing:
#                         a leg told to write outside a temp dir is refused and
#                         grok logs an FsViolation to sandbox-events.jsonl. NOTE
#                         its documented shape — read-only still permits writes to
#                         GROK_HOME and to /tmp, /var/tmp & friends. A leg CAN
#                         write to a temp dir; it cannot touch your project.
#   --tools <read set>    In-process, for the platforms where the kernel profile
#                         can't be applied (18-sandbox.md warns and continues).
#
# The tool fence is an ALLOWLIST on purpose. The denylist form was tried first
# (--disallowed-tools with the mutating tools named) and it did NOT hold: with the
# sandbox off, a leg still created the file. An allowlist needs no correct guess
# at what the write tool is called, and keeps holding when grok ships a new one.
# Verified both ways with the sandbox off: writes refused, `list_dir` still
# answers — a fenced leg is read-only, not useless. (The model's own account of
# which tools it has is NOT evidence; it named the very tools the denylist run
# proved were still working.) NUL-separated items.
adapter_audit_flags() {
  local prompt="$1"; shift
  [ $# -gt 0 ] && printf -- '--cwd\0%s\0' "$1"
  printf -- '--permission-mode\0bypassPermissions\0--sandbox\0read-only\0'
  printf -- '--tools\0read_file,grep,list_dir\0'
  printf -- '-p\0%s\0' "$prompt"
}

# Optional hook: the logged-in account label, shown by `clikae list` / `status`
# and the dashboard. Grok stores identity in auth.json keyed by issuer+client,
# with the email as a PLAIN field (no JWT decode needed, unlike codex). Never
# propagate a no-match under the caller's `set -eo pipefail` (it would abort
# list/status) — always end at return 0.
adapter_account_label() {
  local f="$1/auth.json"
  [ -f "$f" ] || return 0
  grep -oE '"email"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
    | head -n 1 | sed -E 's/.*:[[:space:]]*"//; s/"$//' || true
  return 0
}

# --- session continuity: surface grok sessions in the board's "Continue" list -
# Grok stores each session as a DIRECTORY under
#   GROK_HOME/sessions/<url-encoded-cwd>/<session-uuid>/
# holding summary.json (the index entry: info.id, info.cwd, generated_title,
# session_summary, timestamps) plus chat_history.jsonl / updates.jsonl.
#
# The group directory name is the working dir percent-encoded (/Users/me →
# %2FUsers%2Fme), and 17-sessions.md documents a slug+hash fallback for very long
# paths. We therefore match on the RECORDED cwd inside summary.json rather than
# re-implementing grok's encoder in bash — same content-matching approach codex
# needs, and immune to an encoding change silently emptying the board.

_grok_sessions_dir() { printf '%s\n' "$1/sessions"; }

# _grok_json_str <file> <key> — first "key": "value" string in a pretty-printed
# JSON file, still JSON-escaped. Escape-aware so a value containing \" isn't
# truncated mid-string. The leading quote in the pattern is what keeps "id" from
# matching "request_id" / "current_model_id". Never aborts the caller under
# `set -eo pipefail`.
_grok_json_str() {
  local f="$1" key="$2" re
  [ -f "$f" ] || return 0
  re="\"$key\"[[:space:]]*:[[:space:]]*\"(\\\\.|[^\"\\\\])*\""
  grep -oE "$re" "$f" 2>/dev/null | head -n 1 \
    | sed -E "s/^\"$key\"[[:space:]]*:[[:space:]]*\"//; s/\"$//" || true
  return 0
}

# _grok_summaries_for_cwd <dir> — summary.json files under <dir> whose recorded
# cwd is $PWD. The compare is trailing-slash-insensitive on BOTH sides: a session
# recorded from a path with a trailing slash (or a $PWD that carries one) must
# still match, or it silently vanishes from the board / can't resume. Same
# normalisation `live_dir_users` already applies (`${dir%/}`). Depth is capped at
# 3 (sessions/<group>/<uuid>/summary.json) so `find` never descends into a
# session's terminal/ subtree.
_grok_summaries_for_cwd() {
  local sdir f want; sdir="$(_grok_sessions_dir "$1")"
  [ -d "$sdir" ] || return 0
  want="${PWD%/}"
  find "$sdir" -maxdepth 3 -type f -name 'summary.json' 2>/dev/null | while IFS= read -r f; do
    local rec; rec="$(_grok_json_str "$f" cwd)"
    [ "${rec%/}" = "$want" ] && printf '%s\n' "$f"
  done
}

# _grok_find_summary <dir> <sid> — the summary.json for a session id (the uuid IS
# the session directory's name), or empty. Not scoped to $PWD: `clikae resume
# <id>` looks a session up across directories.
_grok_find_summary() {
  local sdir; sdir="$(_grok_sessions_dir "$1")"
  [ -d "$sdir" ] || return 0
  find "$sdir" -maxdepth 3 -type f -name 'summary.json' -path "*/$2/summary.json" 2>/dev/null | head -n 1
}

# Resume a grok session by id: `grok --resume <uuid>` (verified via grok --help;
# UUID-shaped values always take the ID path, never the title path). Gates (with
# adapter_recent_sids) whether the board offers a "resume" affordance.
adapter_resume_args() {
  local sid="$1"
  [ -n "$sid" ] || return 1
  printf -- '--resume\n%s\n' "$sid"
}

# This dir's most recent conversation log under <dir> (for handoff / source
# detection). chat_history.jsonl is the readable conversation; updates.jsonl is
# the raw ACP event stream and runs an order of magnitude larger. Recency is
# taken from summary.json (rewritten every turn) and the sibling log returned.
adapter_transcript_path() {
  local f t
  local -a sfiles=()
  while IFS= read -r f; do
    [ -n "$f" ] && sfiles+=("$f")
  done <<EOF
$(_grok_summaries_for_cwd "$1")
EOF
  [ "${#sfiles[@]}" -gt 0 ] || return 1
  # cut -f2- keeps a path containing spaces intact (the mtime field is first).
  f="$(sessions_by_mtime "${sfiles[@]}" | head -n 1 | cut -d' ' -f2-)"
  [ -n "$f" ] || return 1
  t="${f%/summary.json}/chat_history.jsonl"
  [ -f "$t" ] || return 1
  printf '%s\n' "$t"
}

# CHEAP recent sessions for the home board: "<epoch-mtime>\037<sid>", newest
# first, capped at [limit] (default 5), for sessions whose cwd is $PWD.
adapter_recent_sids() {
  local dir="$1" limit="${2:-5}" f sid mt
  # grok's this-dir set is content-matched (see _grok_summaries_for_cwd), so the
  # FILE LIST comes from there; sessions_by_mtime (shared kernel) then stats+sorts
  # it. Read the list into an array line-by-line, never via unquoted
  # word-splitting: tank names are validated (no spaces) but $CLIKAE_HOME rides on
  # $HOME, which ISN'T — a space anywhere in the home path would shred every path
  # into fragments and silently drop all grok sessions from the board.
  local -a sfiles=()
  while IFS= read -r f; do
    [ -n "$f" ] && sfiles+=("$f")
  done <<EOF
$(_grok_summaries_for_cwd "$dir")
EOF
  [ "${#sfiles[@]}" -gt 0 ] || return 0
  # plain `read -r mt f` (NOT `IFS= read`) so "<mtime> <path>" splits into two.
  sessions_by_mtime "${sfiles[@]}" | head -n "$limit" | while read -r mt f; do
    [ -f "$f" ] || continue
    sid="$(_grok_json_str "$f" id)"
    [ -n "$sid" ] || continue
    printf '%s\037%s\n' "$mt" "$sid"
  done
}

# Optional hook: title straight from a summary.json FILE (see claude.sh's twin
# for why: cross-project listings can't derive the path from $PWD).
#
# Preferring `generated_title` IS the "prefer a user-set rename over a machine
# title" rule, verified by doing rather than inferred: after `/rename grok test`
# on a session the model had titled "測試 - Test Query Session", summary.json read
#   generated_title: "grok test"      <- the rename landed HERE
#   session_summary: "測試 - Test Query Session"   <- machine title, untouched
# So generated_title is the rename when there is one and the machine title
# otherwise, and session_summary is the fallback for a session whose title
# generator hasn't run yet. Reversing this preference would show the stale
# machine title on every renamed row.
adapter_title_for_file() {
  local f="$1" title_in=""
  [ -n "$f" ] && [ -f "$f" ] || return 0
  title_in="$(_grok_json_str "$f" generated_title)"
  [ -n "$title_in" ] || title_in="$(_grok_json_str "$f" session_summary)"
  [ -n "$title_in" ] || title_in="(no preview)"
  title_in="${title_in//\\n/ }"
  title_in="${title_in//\\t/ }"
  title_in="${title_in//\\\"/\"}"
  printf '%s' "$title_in"
}

# A session's title for the board, by id.
adapter_session_title() {
  local dir="$1" sid="$2" f
  [ -n "$sid" ] || return 0
  f="$(_grok_find_summary "$dir" "$sid")"
  adapter_title_for_file "$f"
}

adapter_find_session() {
  _grok_find_summary "$1" "$2"
}

adapter_session_cwd() {
  _grok_json_str "$1" cwd
}
