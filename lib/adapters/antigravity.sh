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

# Optional hook (#61 round-1 P1-3): paths, relative to a tank dir, that AGY
# ITSELF writes there — used ONLY to recognise a legacy tank (predates the
# `.clikae-tank` marker, e.g. one carried over by a pre-marker `clikae agy
# --release`-then-reimport, or hand-restored from a backup) worth adopting.
# `antigravity-cli/` is the directory agy creates on first launch under
# whichever slot ~/.gemini currently points at (brain/, conversations/, its
# own log — see lib/targets/antigravity.sh and lib/core/scan.sh).
adapter_tank_fingerprint() {
  printf 'antigravity-cli\n'
}

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
  # 🔴 #34: NEVER a format string that starts with `-` — bash's printf builtin
  # parses a leading `--conversation` as an unknown OPTION (rc=2, no stdout),
  # so `clikae resume <agy-sid>` silently launched agy with no --conversation
  # at all. Format first, literal args after.
  printf '%s\n%s\n' '--conversation' "$sid"
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

# Optional hook: the cwd agy's OWN argv carries — see codex.sh's twin for why
# `clikae burn`'s raw '-- <cmd...>' mode needs this (#74 round-3 P1-1). Moot
# in practice — burn.sh:2315 refuses raw mode for agy outright, it only ever
# runs through --prompt/--prompt-file — but defined for the same reason
# claude.sh's twin is: `agy --help` (checked live) has no cwd-override flag,
# so the honest answer is "no", not an absent function.
adapter_cwd_from_args() {
  return 1
}

adapter_find_session() {
  local dir="$1" sid="$2" f
  [ -n "$sid" ] || return 1
  f="$dir/antigravity-cli/brain/$sid/.system_generated/logs/transcript.jsonl"
  [ -f "$f" ] && printf '%s\n' "$f"
}

# Optional hook: the canonical session id for a transcript PATH — see
# claude.sh's twin for why this exists (#74 round-1 P1-1). agy's sid IS the
# brain/<sid>/ directory name; already what every other agy hook in this file
# derives, given here too so burn's sidecar writer and resume's picker read it
# from one place instead of two copies that could drift apart.
adapter_sid_canonical() {
  local f="$1" sid
  sid="${f%/.system_generated/*}"
  printf '%s' "${sid##*/}"
}

# Optional hook: EVERY transcript path under this profile dir — see codex.sh's
# twin (#74 P1-2). Used for burn's before/after snapshot diff.
adapter_all_transcripts() {
  local f
  for f in "$1/antigravity-cli/brain"/*/.system_generated/logs/transcript.jsonl; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
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

# Optional hook (#153): is this conversation one a human opened, or one agy
# spawned on its own? Prints `interactive`, `headless` or `unknown` (rc 0 / 1
# / 2 — rc 2 is never cached by reading_cache_run, so an answer that could not
# be read is asked again next render). The board lists only non-headless rows.
#
# 🔴 STRUCTURE, NEVER TEXT. A subagent's first message is its parent's whole
# brief, wrapped in <SYSTEM_MESSAGE>; matching that wording is exactly the
# "judge words" trap. The signal is agy's own per-conversation metadata:
# conversations/<id>.db, table trajectory_metadata_blob, row id='main', a
# protobuf blob. Measured on a real tank (chromis, 2026-09-27; one human
# conversation, one `self` subagent, one built-in `research` subagent):
#
#   human    (587 B)  top-level 1, 2, 3, 6 (its own id), 7, 15, 18
#   self     (43 KB)  1, 2, 3, 4, 5, 6, 7, 8, 10, 17, 18
#   research (22 KB)  same shape as self
#
#   4 = AgentConfig (4.1 = agent name string, 4.8 description, 4.7 config)
#   5 = parent conversation id
#
# So a conversation is a subagent when EITHER holds, and both are checked:
#   - top-level field 5 is present and is not this conversation's own id, or
#   - top-level field 4 is present and its field 1 is a length-delimited
#     string (an agent's name — any agent's, so a built-in agent agy ships
#     tomorrow is caught without a new string in this file).
# Neither → an ordinary conversation. A human's and a `clikae burn`'s look the
# same here (both small, both only a workspace); burns are hidden by #74's
# sidecar instead. 18 ('default-cli-project') is on BOTH kinds and is not a
# signal. `parent_references` is empty in practice and is not read.
#
# Read-only, twice over: the db is in WAL mode, so the newest pages may live
# only in <id>.db-wal, and even `sqlite3 -readonly` opens the -wal/-shm
# siblings read-write. Both files are copied to a private temp dir and the
# COPY is opened; agy's own files are never opened by sqlite at all.
adapter_session_mode() {
  local dir="$1" sid="$2" db
  db="$dir/antigravity-cli/conversations/$sid.db"
  if [ -z "$sid" ] || [ ! -f "$db" ]; then printf 'unknown'; return 2; fi
  if declare -F reading_cache_run >/dev/null; then
    reading_cache_run antigravity-mode "$db" _antigravity_mode_uncached "$db" "$sid"
  else
    _antigravity_mode_uncached "$db" "$sid"
  fi
}

_antigravity_mode_uncached() {
  local db="$1" sid="$2" tmp hex=""
  command -v sqlite3 >/dev/null 2>&1 || { printf 'unknown'; return 2; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/clikae-agy-mode.XXXXXX" 2>/dev/null)" || { printf 'unknown'; return 2; }
  if cp "$db" "$tmp/c.db" 2>/dev/null; then
    [ -f "$db-wal" ] && cp "$db-wal" "$tmp/c.db-wal" 2>/dev/null
    hex="$(sqlite3 "$tmp/c.db" "SELECT hex(data) FROM trajectory_metadata_blob WHERE id = 'main' LIMIT 1;" 2>/dev/null)" || hex=""
  fi
  rm -rf "$tmp"
  _agy_blob_mode "$hex" "$sid"
}

# _agy_pb_varint <hex> <pos> -> _PB_V (value), _PB_P (next pos, in hex chars);
# rc 1 past the end. <hex> is upper-case, two chars per byte.
_agy_pb_varint() {
  local h="$1" p="$2" v=0 s=0 b
  while :; do
    [ $((p + 2)) -le ${#h} ] || return 1
    b=$((16#${h:p:2})); p=$((p + 2))
    v=$(( v | ((b & 127) << s) )); s=$((s + 7))
    [ "$b" -lt 128 ] && break
    [ "$s" -le 56 ] || return 1
  done
  _PB_V=$v; _PB_P=$p
}

# _agy_pb_find <hex> <field> -> _PB_W (wire type) and, for a length-delimited
# field, _PB_HEX (its payload); rc 1 when absent, rc 2 on a malformed message.
# Top level of <hex> only — payloads are skipped by length, never parsed.
_agy_pb_find() {
  local h="$1" want="$2" p=0 k f w n
  while [ "$p" -lt ${#h} ]; do
    _agy_pb_varint "$h" "$p" || return 2
    k=$_PB_V; p=$_PB_P; f=$((k >> 3)); w=$((k & 7))
    case "$w" in
      0) _agy_pb_varint "$h" "$p" || return 2; p=$_PB_P; n=-1 ;;
      1) n=8 ;;
      2) _agy_pb_varint "$h" "$p" || return 2; p=$_PB_P; n=$_PB_V ;;
      5) n=4 ;;
      *) return 2 ;;
    esac
    if [ "$n" -ge 0 ]; then
      [ $((p + n * 2)) -le ${#h} ] || return 2
      if [ "$f" -eq "$want" ]; then _PB_W=$w; _PB_HEX="${h:p:n*2}"; return 0; fi
      p=$((p + n * 2))
    elif [ "$f" -eq "$want" ]; then
      _PB_W=$w; _PB_HEX=""; return 0
    fi
  done
  return 1
}

# _agy_blob_mode <hex> <own-id> -> interactive|headless|unknown (rc 0/1/2).
# Split out of the db read so the rule is testable on hand-built bytes.
_agy_blob_mode() {
  local LC_ALL=C
  local h="$1" sid="$2" own="" i c rc
  case "$h" in ''|*[!0-9A-Fa-f]*) printf 'unknown'; return 2 ;; esac
  [ $(( ${#h} % 2 )) -eq 0 ] || { printf 'unknown'; return 2; }
  h="$(printf '%s' "$h" | tr 'a-f' 'A-F')"
  for (( i = 0; i < ${#sid}; i++ )); do
    c="${sid:i:1}"; own="$own$(printf '%02X' "'$c")"
  done
  # Signal 1: a parent id that is not this conversation's own.
  _agy_pb_find "$h" 5; rc=$?
  if [ "$rc" -eq 0 ] && [ "$_PB_W" = 2 ] && [ -n "$_PB_HEX" ] && [ "$_PB_HEX" != "$own" ]; then
    printf 'headless'; return 1
  fi
  [ "$rc" -eq 2 ] && { printf 'unknown'; return 2; }
  # Signal 2: an AgentConfig whose field 1 (the agent's name) is a string.
  _agy_pb_find "$h" 4; rc=$?
  if [ "$rc" -eq 0 ] && [ "$_PB_W" = 2 ]; then
    if _agy_pb_find "$_PB_HEX" 1 && [ "$_PB_W" = 2 ] && [ -n "$_PB_HEX" ]; then
      printf 'headless'; return 1
    fi
  fi
  [ "$rc" -eq 2 ] && { printf 'unknown'; return 2; }
  printf 'interactive'; return 0
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

# Optional hook: CHEAP recent sessions under <dir> —
# "<epoch-mtime>\037<session-id>" per line — the same contract as
# claude.sh's/codex.sh's twins, and the missing half of why the home board's
# Live row showed an empty preview for agy: without this hook,
# `_home_live_rows` (lib/commands/home.sh) never even calls
# adapter_session_title — its `declare -F adapter_recent_sids` gate failed
# outright, so title/recap stayed the empty strings they were initialized to.
#
# 🔴 [n] (default 5) IS NOT A PURE LIMIT HERE — n=1 and n>1 answer two
# different questions, deliberately (#34 round-1 P3-1 named the asymmetry;
# this is it written down rather than removed):
#
#   n=1   "what did THIS DIRECTORY last talk to?" — the CLI's own per-directory
#         pointer cache (cache/last_conversations.json keyed by $PWD), one
#         stat, no tank walk. Falls through to the n>1 answer when this
#         directory has no pointer, or the pointer's brain dir is gone.
#   n>1   "what are this TANK's n newest sessions?" — newest first by
#         transcript mtime across the whole tank, the cache's own hit folded
#         in and ranked like any other row (never promoted, never given a
#         slot by right — tests/bats/adapters/antigravity.bats pins that).
#
# Kept rather than unified because the n=1 form is the cheap one and the only
# caller is a board hot path (home.sh's Live-row fallback title, once per live
# tank per frame). Measured on a 1,000-session tank: the tank walk this
# function does for n>1 is 4.7-5.0 s (it stats every session before it cuts —
# the cut's size makes no difference HERE), against one stat for the pointer. So
# making n=1 return "the first row of the tank ranking" would put five seconds
# on a frame render to change one fallback title, on the exact engine whose
# tanks get the most sessions. The user-visible consequence of keeping it is
# small and now documented: that one fallback title can differ depending on
# which directory you opened the board from.
#
# 🔴 #34 round-2 P3-1: "the cut's size makes no difference" is a property of
# THIS adapter (and claude's), not of adapters in general, and the round-1 fix
# generalised it to all of them after measuring only this one — the single
# engine with no per-row work after `head -n`. codex and grok did have such a
# tail (a fork + a file read per row, to get a sid the path did not carry) and
# paid ~+225…+373 ms / ~+917…+1056 ms going from a 10-row ask to a 200-row one
# on a 1,000-session tank. That tail is gone as of this PR (they read the sid
# from the filename now, see their adapter_recent_sids), so the claim is true
# across the board again — but it was an extrapolation when it was written, and
# the honest per-engine version now lives beside CLIKAE_HOME_RECENT_SCAN_MAX in
# lib/commands/home.sh rather than being re-asserted from one sample.
#
# (Aside, for whoever reads the mtime field: the n=1 path's mtime comes from
# _clikae_mtime, which lives in lib/core/adapter_loader.sh. The CLI always has
# it; a test or probe that sources ONLY this adapter + profile_store + json
# does not, and gets a literal "?" there. The sid is correct either way, and
# the sid is all home.sh:571 reads.)
#
# 🔴 SCOPE: this directory first, the whole tank only if this directory has
# nothing. #34 faced a real choice here and took "Option 1" — tank-wide rows,
# no cwd filter at all — because `workspace` is a constant ($HOME) on every
# real agy install (measured on #34/#83: 607/607 indexed conversations share
# one distinct workspace value), so a strict cwd filter left the board's agy
# rows permanently empty in any project directory.
#
# What that cost only showed up later, on a real store: the board's Continue
# list is ONE ranked list across every engine, so an engine answering
# tank-wide competes against engines answering $PWD-wide. Every one of the ten
# visible rows was agy, and the single claude session that genuinely belonged
# to the current directory ranked #13 and never appeared. A row meaning
# something different from the row above it is exactly the defect #34 set out
# to avoid, and being pushed off the list is worse than being one of several.
#
# So: ask adapter_session_cwd (#34's own preferred "Option 2"), newest-first,
# and keep the matches. If NOTHING in this tank names this directory — the
# constant-workspace install #34 measured, where the filter can never match —
# fall back to the tank-wide answer rather than showing an empty section. The
# fallback is what preserves #34; the filter is what stops agy crowding out
# the other engines wherever the directory IS recorded.
#
# The walk is bounded by CLIKAE_AGY_CWD_SCAN_MAX candidates (default 50) so a
# tank whose recent conversations all belong elsewhere — #34's "expensive
# case" — costs a bounded number of cwd reads, not one per session on disk.
# Burn one-shots stay hidden through #83's sidecar, unaffected by this. See
# docs/EXPECTATIONS.md "Engines on one board" for the trade-off in
# user-facing terms.
: "${CLIKAE_AGY_CWD_SCAN_MAX:=50}"

# _agy_scope_rows <dir> <n> <rows> -> at most <n> of <rows> ("<mt>\037<sid>",
# newest first) whose session records $PWD as its workspace; the first <n> of
# <rows> unchanged when none of them does. One place, so the snapshot path and
# the disk path cannot scope differently.
_agy_scope_rows() {
  local dir="$1" n="$2" rows="$3" keep_sid="${4:-}" want="${PWD%/}"
  local mt sid f rec kept=0 seen=0 out=""
  [ -n "$rows" ] || return 0
  while IFS=$'\037' read -r mt sid; do
    [ -n "$sid" ] || continue
    seen=$(( seen + 1 ))
    [ "$seen" -gt "$CLIKAE_AGY_CWD_SCAN_MAX" ] && break
    if [ -z "$keep_sid" ] || [ "$sid" != "$keep_sid" ]; then
      f="$dir/antigravity-cli/brain/$sid/.system_generated/logs/transcript.jsonl"
      rec="$(adapter_session_cwd "$f" 2>/dev/null || true)"
      [ "${rec%/}" = "$want" ] || continue
    fi
    out="$out$mt"$'\037'"$sid"$'\n'
    kept=$(( kept + 1 ))
    [ "$kept" -ge "$n" ] && break
  done <<ROWS
$rows
ROWS
  if [ "$kept" -gt 0 ]; then printf '%s' "$out"; return 0; fi
  # 🔴 THE FALLBACK SAYS SO, IN THE ROW. Measured on a faithful reproduction of
  # the maintainer's store (one claude session recorded in this directory, 15
  # newer agy sessions recorded at $HOME): the board ranks one list by mtime
  # across every engine, so fifteen fallback rows simply outranked the single
  # row that genuinely belonged to the directory and pushed it off the board —
  # the exact symptom the cwd scoping was meant to end, arriving through the
  # fallback instead.
  #
  # A fallback row is a courtesy — "this tank cannot tell which directory its
  # sessions belong to, here is what it has" — so it must never outrank a row
  # that IS this directory's. The third field is that statement, and the
  # board's ranking reads it (home.sh's _home_recent_rows). Every other
  # adapter emits two fields and is therefore scoped by construction; a reader
  # that ignores the field gets exactly the old behaviour.
  printf '%s\n' "$rows" | head -n "$n" | while IFS=$'\037' read -r mt sid; do
    [ -n "$sid" ] || continue
    printf '%s\037%s\037fallback\n' "$mt" "$sid"
  done
  return 0
}
adapter_recent_sids() {
  # #62: the board's bounded index answers this whole function when it is
  # warm. It is a SPEED path, never a narrower answer — an index that cannot
  # cover the caller's ask returns nothing and the disk scan below runs (see
  # board_recent's header).
  #
  # The snapshot's own scope is the TANK (`_BOARD_TANK_SCOPE`), so its rows
  # arrive unscoped and go through _agy_scope_rows exactly like the disk
  # path's — otherwise a warm board would quietly answer tank-wide while a
  # cold one answered $PWD-wide.
  #
  # 🔴 THE CANDIDATE LIST IS NEVER NARROWER THAN THE CALLER'S ASK. The ask is
  # already widened by the caller — home.sh adds this tank's burn-sid count so
  # hidden rows cannot eat the list (#34 round-2 P2-1 / #93) — and clamping it
  # to the cwd scan ceiling here threw that away: on a tank with 250 burns
  # newer than 3 human sessions, the humans fell outside the 50 candidates,
  # the cwd filter matched none of the burns, and the tank-wide FALLBACK then
  # had only burns to fall back to, which the caller's own filter then dropped.
  # Empty Resume block — exactly the regression #93 fixed. So the candidate
  # list is max(ask, ceiling); the ceiling bounds only the cwd READS inside
  # _agy_scope_rows, which is where the per-row cost actually is.
  local _n="${2:-5}" _lim
  case "$_n" in ''|*[!0-9]*) _n=5 ;; esac
  _lim="$CLIKAE_AGY_CWD_SCAN_MAX"
  [ "$_n" -gt "$_lim" ] && _lim="$_n"
  if [ "${_CLIKAE_BOARD:-0}" = 1 ]; then
    local _bout; _bout="$(board_recent antigravity "$1" "$_lim")"
    if [ -n "$_bout" ]; then _agy_scope_rows "$1" "$_n" "$_bout"; return 0; fi
  fi
  # $n, not $limit: at n=1 this is a MODE, not a count. See the docstring.
  local dir="$1" n="$_n" brain want sdir sid f
  brain="$dir/antigravity-cli/brain"
  [ -d "$brain" ] || return 0
  want="${PWD%/}"
  # #34 + #62: no bulk workspace index here. Round 3's `adapter_session_cwd_index`
  # (and the `_agy_ws_*` plain-global cache fix 7 built on it) existed for ONE
  # reader — the `$want` cwd filter in the scan below — and #34 deleted that
  # filter, because `workspace` is a constant on real installs and cwd-scoping
  # hid everything. Round 11 then dropped board_state.sh's own call with the cwd
  # keying it fed (`_BOARD_TANK_SCOPE` there), which left the index with no
  # caller at all; round 12 deleted it (review P3-1). `adapter_session_cwd` —
  # the single-session form burn.sh and resume.sh do call — reads the same file
  # and stays.
  local -a afiles=()
  local _cache_sid=""
  local cache="$dir/antigravity-cli/cache/last_conversations.json"
  # Burn needs the newest transcript even before the CLI refreshes its cache.
  # #34 round-2 P3-3: this used to be `[ "${3:-}" != disk ] && [ -f "$cache" ]`
  # — a third argument meant to let `clikae burn` bypass the cache and read
  # disk. Nothing has ever passed it: repo-wide, the only non-adapter callers
  # are home.sh (n=10, n=10, n=1) and the bats suites, all two-argument, and
  # burn.sh does not call this function at all. Deleted rather than kept
  # "for later": a dead branch with a docstring describing a caller that does
  # not exist is worse than no branch. Anything that needs the disk answer can
  # ask for n>1, which already folds the cache hit into the ranking instead of
  # letting it win.
  if [ -f "$cache" ]; then
    local want_esc; want_esc="$(printf '%s' "$want" | sed 's/[.[\*^$]/\\&/g')"
    # #74 round-1 P1-4: json_value_for_key (lib/core/json.sh) ANCHORS the
    # extraction to the matched "<cwd>": "<sid>" pair itself — the previous
    # shape (`grep -E … | sed 's/.*:[[:space:]]*"//'`) grep'd the whole
    # MATCHING LINE, then let sed's greedy `.*:` walk past it to whichever
    # `: "` came LAST in that line. Every real agy install writes this cache
    # compact/single-line (JSON.stringify's default), so once it holds more
    # than one project's pointer, that greedy walk silently returned a
    # DIFFERENT project's session — the board's Continue row (and its Enter
    # key) resumed the wrong conversation, not just a wrong preview string.
    sid="$(json_value_for_key "$cache" "$want_esc" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$sid" ]; then
      f="$brain/$sid/.system_generated/logs/transcript.jsonl"
      if [ -f "$f" ]; then
        # #74 round-1 P2-1: the cache is a per-directory POINTER — at most one
        # candidate for $want, ever — so it can only fully answer an n=1
        # ask. A
        # caller wanting more than one (the board's Continue list, home.sh's
        # exclusion-pass retries) used to get back exactly this one anyway: a
        # cache hit returned immediately and the scan below — the only thing
        # that can rank several sessions against each other — never ran.
        # n=1 keeps the original single-stat fast path unchanged; only a
        # bigger ask falls through, and even then this hit is kept (not
        # re-discovered) and excluded from the scan below so it isn't listed
        # twice.
        if [ "$n" -le 1 ]; then
          local mt
          mt="$(_clikae_mtime "$f" 2>/dev/null || echo "?")"
          printf '%s\037%s\n' "$mt" "$sid"
          return 0
        fi
        afiles=("$f")
        # The cache pointer IS a cwd statement — the CLI wrote it under this
        # very directory's key — and it is the authority, so this sid survives
        # the cwd filter below even when history.jsonl has no entry for it (in
        # which case adapter_session_cwd answers $HOME and would drop it).
        _cache_sid="$sid"
      fi
      # Stale: the cache's pointer no longer has a brain dir (e.g. cleaned up
      # since the cache was written). Fall through to the disk scan below
      # rather than erroring or returning nothing.
    fi
  fi

  local _seen _sf
  for sdir in "$brain"/*/; do
    [ -d "$sdir" ] || continue
    f="${sdir}.system_generated/logs/transcript.jsonl"
    [ -f "$f" ] || continue
    _seen=0
    if [ "${#afiles[@]}" -gt 0 ]; then
      for _sf in "${afiles[@]}"; do [ "$_sf" = "$f" ] && { _seen=1; break; }; done
    fi
    [ "$_seen" -eq 1 ] && continue
    # No cwd test in THIS loop: it is a plain "what does this tank hold" walk,
    # free of per-file reads. The scoping happens once, below, on the ranked
    # list — so the number of adapter_session_cwd reads is bounded by the scan
    # ceiling rather than by how many sessions the tank has on disk.
    afiles+=("$f")
  done
  [ "${#afiles[@]}" -gt 0 ] || return 0
  local _rows
  _rows="$(sessions_by_mtime "${afiles[@]}" | head -n "$_lim" \
    | while read -r mt f; do
        [ -f "$f" ] || continue
        sid="${f%/.system_generated/*}"; sid="${sid##*/}"
        [ -n "$sid" ] || continue
        printf '%s\037%s\n' "$mt" "$sid"
      done)"
  _agy_scope_rows "$dir" "$n" "$_rows" "$_cache_sid"
}


# ── Optional usage hook (#151) ───────────────────────────────────────────────
# agy asks for its own quota: the CLI POSTs `v1internal:retrieveUserQuotaSummary`
# (daily-cloudcode-pa.googleapis.com) with the tank's own OAuth token, after a
# `v1internal:loadCodeAssist` that names the Cloud project the quota belongs to.
# Both are reads. The shape, from the proto descriptor agy ships
# (google.internal.cloud.code.v1internal, QuotaSummaryProto):
#   request   {project}
#   response  {buckets:[Bucket], groups:[{displayName, description,
#              buckets:[Bucket]}], description}
#   Bucket    {bucketId, displayName, description, window, disabled,
#              remainingFraction | remainingAmount, resetTime}
# Each bucket is classified by its OWN reset distance, the same 24 h line
# limit.sh draws for the 429 sentence (LIMIT_AGY_WEEKLY_MIN_SEC): more than a
# day away is the weekly bucket, anything else the rolling window. The most
# spent bucket of each class is that class's number; every bucket rides along
# as `models` (at most 8). source is "quota-api", so a reader can tell this
# number from claude's vendor endpoint while treating it the same.
#
# The token file is the Linux "file" backend's (lib/commands/antigravity.sh,
# #96). No file (the macOS Keychain backend, or a tank that never logged in),
# an access token past its own recorded expiry, or a refusal: print nothing
# and fail, so usage_read falls back to exactly today's "no-signal" row. An
# expired agy token is the NORMAL idle state (it lives an hour and only agy
# refreshes it), and `clikae usage --wake` is a claude-shaped remedy — calling
# it "expired" would put a wrong instruction on most agy rows.
# The token lives in this subshell and curl's stdin only, never argv/env/disk.
# MEASURED 2026-09-27 on a real tank: both calls must look like agy's own.
# loadCodeAssist with ideType IDE_UNSPECIFIED answers 200 but names no project
# (the free tier comes back ineligible, UNSUPPORTED_CLIENT); with ideType
# ANTIGRAVITY it names one. retrieveUserQuotaSummary answers 403 "You do not
# have a valid license of this product" unless the User-Agent starts with
# "antigravity" (a curl User-Agent: 403, "antigravity": 200). The real body:
#   groups: "Gemini Models"         buckets gemini-weekly (window "weekly"),
#                                           gemini-5h     (window "5h")
#           "Claude and GPT models" buckets 3p-weekly, 3p-5h (may be disabled)
# `window` names the bucket, so it decides the class; reset distance is only
# the fallback for a window string this does not know. (A weekly bucket's
# reset can be under 24 h away near the end of its week — measured 59 h on
# one — so distance alone would misfile it.) Each class's number is its most
# spent enabled bucket across all groups, the same all-models rule the claude
# row's dot uses; the per-group rows ride along in `models`.
_AGY_USAGE_BASE="${CLIKAE_AGY_USAGE_BASE:-https://daily-cloudcode-pa.googleapis.com}"

# _agy_usage_platform -> the ClientMetadata.Platform value for this host.
_agy_usage_platform() {
  local os arch
  os="$(uname -s 2>/dev/null)"; arch="$(uname -m 2>/dev/null)"
  case "$os/$arch" in
    Darwin/arm64)          printf 'DARWIN_ARM64' ;;
    Darwin/*)              printf 'DARWIN_AMD64' ;;
    Linux/aarch64|Linux/arm64) printf 'LINUX_ARM64' ;;
    Linux/*)               printf 'LINUX_AMD64' ;;
    *)                     printf 'PLATFORM_UNSPECIFIED' ;;
  esac
}
_AGY_USAGE_MAX_BYTES=65536

# _agy_usage_post <token> <method> <json body> -> the body on stdout, rc 0 on a
# 2xx only. `--fail` keeps an error body from ever being read as a reading.
_agy_usage_post() {
  local out
  out="$(
    printf 'header = "Authorization: Bearer %s"\nheader = "User-Agent: antigravity"\n' "$1" |
      curl -q -s -K - --fail --connect-timeout 3 --max-time 8 \
        --max-filesize "$_AGY_USAGE_MAX_BYTES" \
        -X POST -H 'Content-Type: application/json' --data "$3" \
        "$_AGY_USAGE_BASE/v1internal:$2" 2>/dev/null |
      head -c "$(( _AGY_USAGE_MAX_BYTES + 1 ))"
    exit "${PIPESTATUS[1]}"
  )" || return 1
  [ "${#out}" -le "$_AGY_USAGE_MAX_BYTES" ] || return 1
  printf '%s' "$out"
}

adapter_usage() (
  set +x
  set +a
  local dir="$1" tokf token project body now
  export -n token
  tokf="$dir/antigravity-cli/antigravity-oauth-token"
  [ -f "$tokf" ] && command -v jq >/dev/null 2>&1 || exit 1
  now="$(date +%s)"
  token="$(jq -er --argjson now "$now" '
    .token | select(type == "object") |
    (.expiry // "" | if type == "string" and . != ""
       then (sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) else 0 end) as $exp |
    select($exp > $now + 30) | .access_token | select(type == "string" and . != "")' \
    "$tokf" 2>/dev/null)" || { token=""; exit 1; }
  case "$token" in *[!a-zA-Z0-9._~+/-]*) token=""; exit 1 ;; esac
  project="$(_agy_usage_post "$token" loadCodeAssist \
      "{\"metadata\":{\"ideType\":\"ANTIGRAVITY\",\"platform\":\"$(_agy_usage_platform)\",\"pluginType\":\"GEMINI\"}}" |
    jq -r '.cloudaicompanionProject | if type == "string" then .
           elif type == "object" then (.id // empty) else empty end' 2>/dev/null)" || project=""
  case "$project" in *[!a-zA-Z0-9._:-]*) project="" ;; esac
  body="$(_agy_usage_post "$token" retrieveUserQuotaSummary \
    "$(jq -cn --arg p "$project" 'if $p == "" then {} else {project:$p} end')")" ||
    { token=""; exit 1; }
  token=""
  printf '%s' "$body" | jq -ce -s --argjson now "$now" --argjson weekly "${LIMIT_AGY_WEEKLY_MIN_SEC:-86400}" '
    if (length != 1) or ((.[0]|type) != "object") then empty else .[0] end |
    [ ((.buckets // [])[]? | {g: "", b: .}),
      ((.groups // [])[]? | (.displayName // "") as $g | (.buckets // [])[]? | {g: $g, b: .}) ] |
    map(select((.b|type) == "object") | .g as $g | .b + {group: ($g|tostring)}) |
    map(select(type == "object" and .disabled != true and
               (.remainingFraction|type) == "number" and
               .remainingFraction >= 0 and .remainingFraction <= 1) |
        (.resetTime | if type == "string" then
           (sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) else null end) as $r |
        {name: ((if .group != "" then "\(.group) \(.window // .bucketId // "")"
                 else (.displayName // .bucketId // "") end) | tostring | .[0:40]),
         pct: (((1 - .remainingFraction) * 1000 | round) / 10),
         resets_at: (if $r == null then null else .resetTime end),
         class: (if .window == "weekly" then "weekly"
                 elif (.window|type) == "string" and (.window|test("^[0-9]+[hm]$")) then "window"
                 elif $r != null and ($r - $now) > $weekly then "weekly" else "window" end)}) |
    select(length > 0) |
    (map(select(.class == "window")) | max_by(.pct)) as $w |
    (map(select(.class == "weekly")) | max_by(.pct)) as $k |
    {window_pct: $w.pct, weekly_pct: $k.pct,
     window_resets_at: $w.resets_at, weekly_resets_at: $k.resets_at,
     source: "quota-api",
     models: [ .[] | select(.name != "") | {name, pct, resets_at} ] | .[0:8]}' 2>/dev/null
)
