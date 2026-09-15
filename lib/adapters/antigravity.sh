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
# the cut's size makes no difference), against one stat for the pointer. So
# making n=1 return "the first row of the tank ranking" would put five seconds
# on a frame render to change one fallback title, on the exact engine whose
# tanks get the most sessions. The user-visible consequence of keeping it is
# small and now documented: that one fallback title can differ depending on
# which directory you opened the board from.
#
# (Aside, for whoever reads the mtime field: the n=1 path's mtime comes from
# _clikae_mtime, which lives in lib/core/adapter_loader.sh. The CLI always has
# it; a test or probe that sources ONLY this adapter + profile_store + json
# does not, and gets a literal "?" there. The sid is correct either way, and
# the sid is all home.sh:571 reads.)
#
# 🔴 #34: this used to also filter by "$PWD == the session's recorded
# history.jsonl workspace field" (the same trick adapter_session_cwd uses for
# one session at a time). But workspace is a constant ($HOME) on every real
# agy install — measured on #34/#83: 607/607 indexed conversations share one
# distinct workspace value — so that filter could never match outside $HOME,
# and the board's Resume rows for agy were permanently empty in any real
# project directory. workspace is a constant on real installs, so
# cwd-scoping would hide everything: dropped in favor of TANK-scoped rows
# (issue #34's "Option 1") — every session in this tank, newest first,
# relying on the CALLER's own cap ($n / the board's CLIKAE_HOME_RECENT_MAX)
# rather than a cwd match to keep the list from flooding. Burn one-shots stay hidden through #83's sidecar, unaffected by
# this. See docs/EXPECTATIONS.md "Engines on one board" for the trade-off in
# user-facing terms.
adapter_recent_sids() {
  # $n, not $limit: at n=1 this is a MODE, not a count. See the docstring.
  local dir="$1" n="${2:-5}" brain want sdir sid f
  brain="$dir/antigravity-cli/brain"
  [ -d "$brain" ] || return 0
  want="${PWD%/}"
  local -a afiles=()
  local cache="$dir/antigravity-cli/cache/last_conversations.json"
  # Burn needs the newest transcript even before the CLI refreshes its cache.
  if [ "${3:-}" != disk ] && [ -f "$cache" ]; then
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
        # ask (burn's own use, via the "disk"-bypassing 3rd arg aside). A
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
    # #34: tank-scoped — every session in this tank, newest first, capped by
    # the caller's own $n. No adapter_session_cwd/$want filter here (see
    # the docstring above): workspace is a constant on real installs, so
    # cwd-scoping would hide everything.
    afiles+=("$f")
  done
  [ "${#afiles[@]}" -gt 0 ] || return 0
  sessions_by_mtime "${afiles[@]}" | head -n "$n" | while read -r mt f; do
    [ -f "$f" ] || continue
    sid="${f%/.system_generated/*}"; sid="${sid##*/}"
    [ -n "$sid" ] || continue
    printf '%s\037%s\n' "$mt" "$sid"
  done
}

