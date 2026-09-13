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
  if declare -F reading_cache_run >/dev/null; then
    # P2-A (2026-09-12 round-2 fix review): the cache identity used to be
    # the SHARED history.jsonl, not this one session's own transcript — so
    # any write to history.jsonl (e.g. one new agy session anywhere)
    # invalidated EVERY other session's cached cwd at once. On a synthetic
    # 500-session tank that turned "one new session" into a 500-entry cache
    # stampede and a ~10s board_state_refresh (measured: round-2 review's
    # P2-A, perf3.log). Keying on $f itself means an unrelated session's
    # cache entry survives a write elsewhere; only the one session whose OWN
    # transcript actually changed re-derives its cwd.
    reading_cache_run "agy-cwd" "$f" _agy_cwd_uncached "$@"
  else
    _agy_cwd_uncached "$@"
  fi
}

_agy_cwd_uncached() {
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

# Optional hook: BULK sid -> workspace index for the WHOLE account, one line
# per session as "<sid>\037<workspace>", built from a SINGLE pass over
# history.jsonl. round-3 fix review, P2-2: `board_state_refresh`'s rebuild
# loop calls a per-session cwd lookup for EVERY agy session in the account on
# a genuine miss — never PWD-scoped, since antigravity records cwd IN the
# file, not in the path (see adapter_recent_sids's header). Even a WARM
# `adapter_session_cwd` cache hit still pays a stat + a cksum + a subshell
# read per session (reading_cache.sh's own reading_cache_run); multiplied by
# a synthetic 500-session tank that measured as a ~5s FIXED cost — the round-2
# fix (P2-A) killed the cache-key STORM, but not this per-session fork
# overhead. A single awk pass over history.jsonl is the same total I/O
# (round-2's fix already made per-session reads warm-cache cheap; this
# removes the per-session FORKS around them, not more I/O) with the lookup
# itself becoming a plain bash read once the caller has this index (fix7:
# `_agy_ws_load`/`_agy_ws_lookup` below, plain globals — see
# `_agy_ws_varname`'s own header for why bash 3.2's lack of associative
# arrays doesn't cost the zero-forks-per-session property this hook exists
# for) — zero forks per session either way. Callers without this hook (or a
# minimal stub adapter in a test) keep using `adapter_session_cwd` one file
# at a time; this hook is a bulk-mode acceleration, not a new source of
# truth. First occurrence per sid wins, matching `_agy_cwd_uncached`'s own
# `head -n 1` semantics for a session recorded more than once.
adapter_session_cwd_index() {
  local dir="$1"
  local hf="$dir/antigravity-cli/brain/history.jsonl"
  [ -f "$hf" ] || return 0
  awk '
    {
      sid = ""
      if (match($0, /"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/.*"sessionId"[[:space:]]*:[[:space:]]*"/, "", s); sub(/"$/, "", s)
        sid = s
      }
      if (sid == "" || (sid in seen)) next
      ws = ""
      if (match($0, /"workspace"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/.*"workspace"[[:space:]]*:[[:space:]]*"/, "", s); sub(/"$/, "", s)
        ws = s
      }
      if (ws == "") next
      seen[sid] = 1
      printf "%s\037%s\n", sid, ws
    }
  ' "$hf" 2>/dev/null
}

# _agy_ws_varname <sid> -> sets $_agy_ws_var_out to the global variable name
# that holds this sid's cached "<sid>\037<workspace>" record. fix7: bash 3.2
# has no associative arrays (4.0+ only), so the bulk index this file's
# `adapter_session_cwd_index` output used to get loaded into (a `local -A`
# in board_state.sh and, separately, one in `adapter_recent_sids` below)
# becomes plain globals keyed by a sanitized name — same idea as
# `board_generation`'s own memo in board_state.sh (see its header for why
# this is NOT `board_key`/cksum-based: a fork here would run once per FILE
# in a cold build, reintroducing the per-session fork cost this file's
# round-3 fix review P2-2 removed). Lives HERE, not in board_state.sh: an
# earlier draft of the fix7 port put these three functions in
# board_state.sh, and tests/bats/adapters/antigravity.bats — which sources
# THIS file directly, never board_state.sh — immediately hit "_agy_ws_load:
# command not found" (CI run 34754505915's successor). This file must stay
# usable on its own, the same self-containment `adapter_session_cwd_index`
# above already has; board_state.sh's own call sites guard every use with
# `declare -F` for exactly this reason.
#
# Round-7 fix review P3-2: the name is namespaced by the TANK directory, and
# `_agy_ws_load` unsets what it loaded last. The old `local -A _ws=()` this
# replaced was FUNCTION-scoped, so every call started from an empty map for
# free; plain globals do not, and two things followed. A long-lived TUI
# accumulated one global per sid it had ever seen and kept answering for sids
# that had since vanished from `history.jsonl`, and a lookup made after
# loading a DIFFERENT tank could be answered by the first tank's index — the
# sid is written back and checked (see `_agy_ws_lookup`), but the same sid
# genuinely existing in two tanks is not a collision the write-back can catch.
# `board_generation`'s memo in board_state.sh already had the matching
# `_board_gen_cache_clear`; this is its twin.
_AGY_WS_NS=""
_AGY_WS_KEYS=()
_agy_ws_varname() {
  _agy_ws_var_out="_AGY_WS_${_AGY_WS_NS}_${1//[^A-Za-z0-9_]/_}"
}

# _agy_ws_clear -> drop every global `_agy_ws_load` set, without enumerating
# the environment (same indexed-array bookkeeping `_board_gen_cache_clear`
# uses, and for the same bash-3.2 reason: no associative arrays).
_agy_ws_clear() {
  local _ak
  for _ak in "${_AGY_WS_KEYS[@]}"; do
    unset "$_ak" 2>/dev/null
  done
  _AGY_WS_KEYS=()
}

# _agy_ws_load <dir> -> populates one global per antigravity session id this
# tank's history.jsonl carries a workspace for. ONE fork total
# (`adapter_session_cwd_index` above, itself one `awk` pass over
# history.jsonl — round-3 fix review P2-2's bulk index) no matter how many
# sessions exist; this loop and every `_agy_ws_lookup` below are pure bash,
# zero forks — the invariant P2-2's own review demanded stays true after
# this port: O(1) forks per RENDER, never O(sessions).
_agy_ws_load() {
  local dir="$1" _asid _aws
  _agy_ws_clear
  _AGY_WS_NS="${dir//[^A-Za-z0-9_]/_}"
  while IFS=$'\037' read -r _asid _aws; do
    [ -n "$_asid" ] || continue
    _agy_ws_varname "$_asid"
    printf -v "$_agy_ws_var_out" '%s\037%s' "$_asid" "$_aws"
    _AGY_WS_KEYS+=("$_agy_ws_var_out")
  done < <(adapter_session_cwd_index "$dir" 2>/dev/null)
}

# _agy_ws_lookup <sid> -> sets $_agy_ws_lookup_out to this sid's cached
# workspace, or "" on a miss (never loaded by `_agy_ws_load`, or a
# sanitized-name collision with a different sid — verified via the sid
# written back alongside the value, same guard board_recent/board_find
# (board_state.sh) use for their own hashed keys, applied here to a
# sanitized-name key instead).
_agy_ws_lookup() {
  local sid="$1" val vsid vws
  _agy_ws_lookup_out=""
  _agy_ws_varname "$sid"
  eval "val=\"\${$_agy_ws_var_out:-}\""
  [ -n "$val" ] || return 0
  IFS=$'\037' read -r vsid vws <<< "$val"
  [ "$vsid" = "$sid" ] || return 0
  _agy_ws_lookup_out="$vws"
}

adapter_session_title() {
  local dir="$1" sid="$2"
  [ -n "$sid" ] || return 0
  adapter_title_for_file "$dir/antigravity-cli/brain/$sid/.system_generated/logs/transcript.jsonl"
}

# Optional hook: title straight from a transcript FILE (see claude.sh's twin).
# The resume picker used to re-implement this extraction inline — minus the
# whitespace-collapse below, so the same session titled differently in the
# picker vs the home board. Prefer the CLI's conversation summary title;
# keep this lookup inside the hook so the picker's per-file cache covers it.
# SQLite is optional: absent/unreadable summaries fall back to the transcript.
#
# 🔴 2026-09-06: an empty extraction used to fall through as a bare "", which
# the home board's Live row printed as a literal `""` — the ONLY row on the
# board with no fallback text (codex/claude/grok all land on "(no preview)"
# via their own adapter_title_for_file). Same fallback here, same reason: an
# unreadable/pre-opening-message transcript still deserves SOME word in that
# column, not silence that reads as a rendering bug.
adapter_title_for_file() {
  if declare -F reading_cache_run >/dev/null; then
    reading_cache_run antigravity-title "$1" _antigravity_title_uncached "$@"
  else
    _antigravity_title_uncached "$@"
  fi
}

_antigravity_title_uncached() {
  local f="$1" t="" sdir sid db sql_sid
  [ -n "$f" ] && [ -f "$f" ] || return 0
  sdir="${f%/.system_generated/logs/transcript.jsonl}"
  sid="${sdir##*/}"
  db="${sdir%/brain/*}/conversation_summaries.db"
  if [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
    # Escape SQL string literals; read-only, short-lived connection because agy
    # writes this database. A failed read (including a lock) uses the prompt.
    # ORDER BY picks the newest row if conversation_id isn't unique. Note:
    # -readonly only guarantees the .db file itself is never opened for
    # writing — in WAL mode sqlite3 still opens/creates the -wal/-shm siblings
    # O_RDWR (standard SQLite behavior); a failed open there falls back the
    # same as any other unreadable summary.
    sql_sid=${sid//\'/\'\'}
    t="$(sqlite3 -readonly "$db" "SELECT title FROM conversation_summaries WHERE conversation_id = '$sql_sid' ORDER BY last_modified_time DESC LIMIT 1;" 2>/dev/null)" || t=""
    # This title is already plain text, never JSON — only collapse whitespace.
    # Running it through the transcript's JSON-unescape below would mangle a
    # real backslash sequence (e.g. a Windows path) into garbage.
    t="$(printf '%s' "$t" | tr '\t\n' '  ' | sed -E 's/  +/ /g; s/^ //; s/ $//')"
  fi
  if [ -z "$t" ]; then
    t="$(head -n 1 "$f" 2>/dev/null | grep -oE '"content"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1 \
        | sed -E 's/^"content"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
    if [[ "$t" == *"<USER_REQUEST>"* ]]; then
      t="${t#*<USER_REQUEST>}"
      t="${t%%</USER_REQUEST>*}"
    fi
    t="$(printf '%s' "$t" | sed -E 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g' \
      | tr '\t\n' '  ' | sed -E 's/  +/ /g; s/^ //; s/ $//')"
  fi
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
  if [ "${_CLIKAE_BOARD:-0}" = 1 ]; then
    local _bout; _bout="$(board_recent antigravity "$@")"
    if [ -n "$_bout" ]; then printf '%s\n' "$_bout"; return 0; fi
  fi
  local dir="$1" limit="${2:-5}" brain want sdir sid f cwd
  brain="$dir/antigravity-cli/brain"
  [ -d "$brain" ] || return 0
  want="${PWD%/}"
  # P2-2 (2026-09-12 round-3 fix review): one bulk index read instead of one
  # reading_cache_run + fork pipeline PER session — see
  # adapter_session_cwd_index's header. fix7: the per-session index this used
  # to hold in a `local -A _ws` (bash 4+) now lives in the plain globals
  # `_agy_ws_load`/`_agy_ws_lookup` above build and read — bash 3.2 has no
  # associative arrays; see `_agy_ws_varname`'s own header for why a
  # fork-free, sanitized-name lookup is what keeps this at O(1) forks per
  # RENDER rather than one per session.
  _agy_ws_load "$dir"
  local -a afiles=()
  for sdir in "$brain"/*/; do
    [ -d "$sdir" ] || continue
    f="${sdir}.system_generated/logs/transcript.jsonl"
    [ -f "$f" ] || continue
    sid="${sdir%/}"; sid="${sid##*/}"
    _agy_ws_lookup "$sid"
    if [ -n "$_agy_ws_lookup_out" ]; then cwd="$_agy_ws_lookup_out"; else cwd="$(adapter_session_cwd "$f" 2>/dev/null || true)"; fi
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

