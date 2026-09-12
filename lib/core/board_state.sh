# shellcheck shell=bash
# Tree discovery belongs to session boundaries. Renders consume immutable,
# per-tank generations through an atomically replaced pointer. A missing index
# is an unknown reading, never permission to scan a transcript tree on a frame.
#
# 2026-09-12 round-1 fix review (closing #62's round-1 gate, "R1"): a snapshot
# that only gets (re)built at a session BOUNDARY (`clikae run`/`burn`/agy's own
# switch) goes stale the moment anything reaches an engine WITHOUT passing
# through one of those three call sites — `clikae alias`, `clikae env`, a
# `.app` bundle, `relay`, switch.sh's ephemeral path — and none of those is
# rare. `board_generation` below now does one cheap freshness check PER READ,
# PER TANK (a directory mtime plus a bounded handful of file mtimes — never a
# scan of the whole tree), and rebuilds inline, ONLY for the one tank actually
# being read, the instant that check disagrees with what was last published.
# The point of #62 was never "boundary events are the only time a scan may
# happen" — it was "a render must not cost O(every transcript this account has
# ever written)". A per-tank inline rebuild on a genuine miss is O(that one
# tank); the thing #62 killed was O(all of them, every frame, whether or not
# anything changed).
board_key() { local k; k="$(printf '%s' "$1" | cksum)"; printf '%s' "${k%% *}"; }
board_root() { printf '%s/state/board/%s' "${CLIKAE_HOME:-$HOME/.clikae}" "$(board_key "$1")"; }

# _board_scope_raw <engine> -> the per-(cwd, engine) scope string itself
# (never hashed) — factored out so a reader (board_stale, board_recent) and
# the writer can never drift on what "this scope" means, AND so a reader can
# verify the hash it looked up by (see _board_scope_key) against the value
# actually recorded, not just trust a `board_key` collision.
_board_scope_raw() {
  local engine="$1" scope
  if [ "$engine" = claude ]; then scope="$(_claude_project_slug "$PWD")"; else scope="${PWD%/}"; fi
  printf '%s' "${scope%/}"
}

# _board_scope_key <engine> -> board_key of _board_scope_raw. `board_key` is a
# 32-bit cksum — a genuine collision would otherwise let one directory's
# resume list silently answer for a completely different one. board_recent
# guards this the same way reading_cache_run already does for its own key
# (see reading_cache.sh's header): the RAW scope is written as `recent/<key>`'s
# own first line and checked back on every read, so a collision is a miss,
# never a wrong answer.
_board_scope_key() {
  board_key "$(_board_scope_raw "$1")"
}

# _board_scan_root <engine> <dir> -> the ONE directory whose own mtime proves
# (or disproves) "nothing new appeared since the last publish" for THIS PWD.
# Claude lays sessions out one subdirectory per project slug, so scoping to
# just that subdirectory means a sibling project's activity never forces a
# rebuild here. The other three engines record cwd IN the file, not in the
# path, so there is no PWD-scoped subdirectory to point at — the engine's
# whole session root is the best available O(1) signal.
_board_scan_root() {
  local engine="$1" dir="$2"
  case "$engine" in
    claude) printf '%s/projects/%s' "$dir" "$(_claude_project_slug "$PWD")" ;;
    codex) _codex_sessions_dir "$dir" ;;
    grok) printf '%s/sessions' "$dir" ;;
    antigravity) printf '%s/antigravity-cli/brain' "$dir" ;;
  esac
}

# board_stale <engine> <dir> <generation-path> -> success (0) when the
# published generation no longer matches what is on disk for THIS scope.
# Two O(1)-ish signals, neither a tree walk, and both compared for EQUALITY
# against what was RECORDED at publish time — never ">" against a wall-clock
# stamp: a fixture (or a clock skew) that dates a file into the future is a
# legitimate, existing pattern in this repo's own tests (touch -t past the
# current year, to force a deterministic "newest" without racing other
# fixtures' timestamps), and ">" against `updated` would read every such file
# as permanently stale, forever re-triggering a rebuild each read.
#   1. the PWD-scoped scan root's own mtime, vs `scanroot-mtime` recorded at
#      publish — catches a session that did not exist at publish time (a new
#      file is a new dirent, which always bumps its parent directory's mtime).
#   2. the mtime of each of THIS scope's already-recorded recent sessions
#      (bounded to CLIKAE_HOME_RECENT_MAX, never the whole tree), vs the mtime
#      recorded for it in `recent/<scope>` at publish — catches an in-progress
#      session simply growing, with no new/removed file at all (the P1-3
#      shape: a limit landing mid-session).
# Either mismatch means rebuild.
board_stale() {
  local engine="$1" dir="$2" gen="$3" scan_root root_mt saved_root_mt key
  [ -f "$gen/updated" ] || return 0

  scan_root="$(_board_scan_root "$engine" "$dir" 2>/dev/null || true)"
  if [ -n "$scan_root" ] && [ -d "$scan_root" ]; then
    root_mt="$(file_mtime "$scan_root" 2>/dev/null)" || root_mt=""
    saved_root_mt=""
    [ -f "$gen/scanroot-mtime" ] && IFS= read -r saved_root_mt < "$gen/scanroot-mtime"
    if [ -n "$root_mt" ] && [ "$root_mt" != "$saved_root_mt" ]; then return 0; fi
  fi

  local scope key; scope="$(_board_scope_raw "$engine")"; key="$(board_key "$scope")"
  [ -f "$gen/recent/$key" ] || return 1
  # ONE stat call for every candidate (files_mtime_size, shared kernel — see
  # its own header in profile_store.sh), never one fork per file: this runs
  # on every board_read/board_recent/board_find, so paying N forks for N
  # recent files here would multiply right back into the O(files) cost #62
  # was written to kill, just moved from "every transcript" to "every recent
  # file, every read, every render".
  local mt sid f sidkey savedsid
  local -a rmts=() rfiles=()
  local firstline=1
  while IFS=$'\037' read -r mt sid; do
    if [ "$firstline" -eq 1 ]; then
      firstline=0
      # P3-2: a board_key collision on the scope itself is a miss, not a
      # confident wrong answer for a completely different directory.
      { [ "$mt" = "#scope" ] && [ "$sid" = "$scope" ]; } || return 1
      continue
    fi
    [ -n "$sid" ] || continue
    sidkey="$(board_key "$sid")"
    [ -f "$gen/sids/$sidkey" ] || continue
    { IFS= read -r savedsid; IFS= read -r f; } < "$gen/sids/$sidkey"
    [ "$savedsid" = "$sid" ] || continue   # P3-2: same guard on the sid index.
    [ -f "$f" ] || continue
    rmts+=("$mt"); rfiles+=("$f")
  done < "$gen/recent/$key"
  [ "${#rfiles[@]}" -gt 0 ] || return 1
  local i=0 cur_mt _rest
  while IFS=' ' read -r cur_mt _rest; do
    [ "$cur_mt" = "${rmts[$i]}" ] || return 0
    i=$((i + 1))
  done < <(files_mtime_size "${rfiles[@]}")
  return 1
}

# board_generation <engine> <dir> -> the fresh generation directory for this
# tank, rebuilding inline (once, self-limiting — the rebuild's own `updated`
# reads as current to every later call in the SAME render) when missing or
# stale. Memoized per (engine,dir) for the lifetime of this process: a single
# render reads count/updated/claude-usage/… from the same tank several times
# over, and the freshness check itself must not be paid more than once.
# -g: several tests source this file from INSIDE a helper function
# (_board_source), where a plain `declare -A` would scope the array to that
# function and vanish the moment it returns — leaving board_generation, called
# later from global scope, referencing an unset variable. Bash then treats the
# bare name as a plain (indexed) array by default, and an indexed subscript is
# an ARITHMETIC context: `${_BOARD_GEN_CACHE[$cachekey]}` with a cachekey like
# "codex<RS>/tmp/…" becomes "invalid arithmetic operator" the first time this
# runs from outside that sourcing function.
declare -gA _BOARD_GEN_CACHE
board_generation() {
  local engine="$1" dir="$2" cachekey root gen=""
  cachekey="$engine"$'\036'"$dir"
  if [ -n "${_BOARD_GEN_CACHE[$cachekey]+x}" ]; then
    gen="${_BOARD_GEN_CACHE[$cachekey]}"
    [ -n "$gen" ] || return 1
    printf '%s' "$gen"
    return 0
  fi
  load_adapter "$engine" >/dev/null 2>&1 || true
  root="$(board_root "$dir")"
  [ -f "$root/current" ] && IFS= read -r gen < "$root/current"
  case "$gen" in generation.*) gen="$root/$gen" ;; *) gen="" ;; esac
  if [ -z "$gen" ] || board_stale "$engine" "$dir" "$gen"; then
    board_state_refresh "$engine" "$dir" >/dev/null 2>&1 || true
    local gen2=""
    [ -f "$root/current" ] && IFS= read -r gen2 < "$root/current"
    case "$gen2" in generation.*) gen="$root/$gen2" ;; esac
  fi
  _BOARD_GEN_CACHE["$cachekey"]="$gen"
  [ -n "$gen" ] || return 1
  printf '%s' "$gen"
}
board_read() {
  local engine="$1" dir="$2" gen
  gen="$(board_generation "$engine" "$dir")" || return 0
  [ ! -f "$gen/$3" ] || cat "$gen/$3"
}
board_recent() {
  local engine="$1" dir="$2" n="${3:-10}" scope key gen hmark hscope
  case "$n" in ''|*[!0-9]*) n=10 ;; esac
  gen="$(board_generation "$engine" "$dir")" || return 0
  scope="$(_board_scope_raw "$engine")"; key="$(board_key "$scope")"
  [ -f "$gen/recent/$key" ] || return 0
  IFS=$'\037' read -r hmark hscope < "$gen/recent/$key"
  # P3-2: a board_key collision on the scope is a miss, never someone else's
  # recent list — see board_stale's twin guard.
  { [ "$hmark" = "#scope" ] && [ "$hscope" = "$scope" ]; } || return 0
  tail -n +2 "$gen/recent/$key" | head -n "$n"
}
board_find() {
  local engine="$1" dir="$2" sid="$3" gen f="" sf savedsid
  # A newly launched Claude session has a known path even before its first
  # lifecycle snapshot. No wildcard lookup, even when the stamp is missing.
  if [ "$engine" = claude ]; then
    f="$dir/projects/$(_claude_project_slug "$PWD")/$sid.jsonl"
    [ ! -f "$f" ] || { printf '%s\n' "$f"; return 0; }
  fi
  gen="$(board_generation "$engine" "$dir")" || return 1
  sf="$gen/sids/$(board_key "$sid")"
  [ -f "$sf" ] || return 1
  { IFS= read -r savedsid; IFS= read -r f; } < "$sf"
  # P3-2: a board_key collision on the sid is a miss, never another
  # session's transcript.
  [ "$savedsid" = "$sid" ] || return 1
  [ -f "$f" ] || return 1
  printf '%s\n' "$f"
}

# board_gc_generations <root> [keep] -> delete all but the newest [keep]
# (default 5, $CLIKAE_BOARD_KEEP_GENERATIONS) generation directories under
# <root>, by mtime, regardless of age. Called after every publish (a tank
# launched a dozen times a day used to pile up a full day's worth under the
# old `-mtime +1` rule) and by `clikae clean` (so a tank nobody has launched
# in a while still gets swept without waiting on a day-old floor).
board_gc_generations() {
  local root="$1" keep="${2:-${CLIKAE_BOARD_KEEP_GENERATIONS:-5}}" gd gmt
  [ -d "$root" ] || return 0
  while IFS= read -r gd; do
    [ -n "$gd" ] && rm -rf "$gd"
  done < <(
    for gd in "$root"/generation.*; do
      [ -d "$gd" ] || continue
      gmt="$(file_mtime "$gd" 2>/dev/null)" || continue
      printf '%s\037%s\n' "$gmt" "$gd"
    done | sort -t$'\037' -k1,1 -rn | tail -n +"$((keep + 1))" | cut -d$'\037' -f2-
  )
  return 0
}

board_state_refresh() (
  # Subshell isolates adapter hooks, umask and board-mode overrides from caller.
  local engine="$1" dir="$2" root gen pointer files f mt sid scope key count=0
  local _CLIKAE_BOARD=0 n="${CLIKAE_HOME_RECENT_MAX:-10}"
  case "$engine" in claude|codex|antigravity|grok) ;; *) return 0 ;; esac
  case "$n" in ''|*[!0-9]*) n=10 ;; esac
  umask 077
  root="$(board_root "$dir")"
  mkdir -p "$root" || return 0
  gen="$(mktemp -d "$root/generation.XXXXXX")" || return 0
  mkdir -p "$gen/recent" "$gen/sids"
  load_adapter "$engine" >/dev/null 2>&1 || return 0
  case "$engine" in
    claude) files="$(find "$dir/projects" -type f -name '*.jsonl' 2>/dev/null || true)" ;;
    codex) files="$(find "$(_codex_sessions_dir "$dir")" -type f -name 'rollout-*.jsonl' 2>/dev/null || true)" ;;
    grok) files="$(find "$dir/sessions" -maxdepth 3 -type f -name summary.json 2>/dev/null || true)" ;;
    antigravity) files="$(find "$dir/antigravity-cli/brain" -type f -name transcript.jsonl 2>/dev/null || true)" ;;
  esac
  local -a paths=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    count=$((count + 1))
    case "${f##*/}" in agent-*) continue ;; esac
    paths+=("$f")
  done <<< "$files"
  printf '%s\n' "$count" > "$gen/count"
  date +%s > "$gen/updated"
  # Recorded for board_stale's equality check, never compared with ">" — see
  # its own header for why (a future-dated fixture/clock skew must not read
  # as permanently stale).
  local scan_root; scan_root="$(_board_scan_root "$engine" "$dir" 2>/dev/null || true)"
  if [ -n "$scan_root" ] && [ -d "$scan_root" ]; then
    file_mtime "$scan_root" > "$gen/scanroot-mtime" 2>/dev/null || true
  fi
  if [ "${#paths[@]}" -gt 0 ]; then
    while read -r mt f; do
      [ -f "$f" ] || continue
      case "$engine" in
        claude) sid="${f##*/}"; sid="${sid%.jsonl}"; scope="${f%/*}"; scope="${scope##*/}" ;;
        codex) sid="$(_codex_meta_field "$f" id)"; scope="$(_codex_meta_field "$f" cwd)" ;;
        grok) sid="$(_grok_json_str "$f" id)"; scope="$(_grok_json_str "$f" cwd)" ;;
        antigravity) sid="${f%/.system_generated/*}"; sid="${sid##*/}"; scope="$(adapter_session_cwd "$f")" ;;
      esac
      [ -n "$sid" ] || continue
      key="$(board_key "$sid")"
      # P3-2: the sid itself is written back so a reader (board_find,
      # board_stale) can verify it — a 32-bit cksum collision then reads as a
      # miss, never someone else's transcript.
      printf '%s\n%s\n' "$sid" "$f" > "$gen/sids/$key"
      scope="${scope%/}"
      key="$(board_key "$scope")"
      # Same guard on the scope: a fresh recent/<key>.all gets the raw scope
      # as its own first line, verified back by board_recent/board_stale.
      [ -f "$gen/recent/$key.all" ] || printf '#scope\037%s\n' "$scope" > "$gen/recent/$key.all"
      printf '%s\037%s\n' "$mt" "$sid" >> "$gen/recent/$key.all"
    done < <(sessions_by_mtime "${paths[@]}")
  fi
  for f in "$gen"/recent/*.all; do
    [ -f "$f" ] || continue
    # +1: the header line (never counted against CLIKAE_HOME_RECENT_MAX).
    head -n "$((n + 1))" "$f" > "${f%.all}"
    rm -f "$f"
  done
  case "$engine" in
    claude)
      files="$(find "$dir/projects" -name '*.jsonl' -mmin -300 2>/dev/null || true)"
      _limit_claude_readings "$files" > "$gen/claude-usage" ;;
    antigravity) agy_email "$dir" > "$gen/email" ;;
    codex)
      _limit_codex_rate_limits_cached "$dir" "$root/codex-cache" > "$gen/codex-usage" || true
      files="$(find "$dir/sessions" -name 'rollout-*.jsonl' -mmin -10080 2>/dev/null || true)"
      _limit_codex_readings "$files" > "$gen/codex-dry" ;;
  esac
  pointer="$(mktemp "$root/current.XXXXXX")" || return 0
  printf '%s\n' "${gen##*/}" > "$pointer"
  mv -f "$pointer" "$root/current"
  # Old generations remain available to concurrent readers already holding a
  # path to one — deleting the directory does not invalidate an open fd/still
  # readable path on POSIX, only unlinks the name.
  board_gc_generations "$root"
)

board_total() {
  local engine tank dir n total=0
  while IFS=$'\t' read -r engine tank dir; do
    [ -n "$tank" ] || continue
    n="$(board_read "$engine" "$dir" count)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    total=$((total + n))
  done <<EOF_PROFILES
$(list_all_profiles)
EOF_PROFILES
  printf '%s' "$total"
}
