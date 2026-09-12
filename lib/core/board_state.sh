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
#
# 2026-09-12 round-2 fix review (P1-A/P1-B/P1-C): three of round-1's
# freshness signals still had gaps. P1-A — the per-file staleness check
# below only compared whole-second mtimes and threw away the size
# `files_mtime_size` already hands back, so a write landing in the SAME
# wall-clock second as the last publish was invisible in EITHER direction
# (a limit landing read as fresh, a resolved limit stuck reading stale).
# `recent/<key>` rows now carry a size column too, and both are compared at
# nanosecond precision (`files_mtime_size`'s `%.9Y`, the same fix
# `_reading_cache_keyv` already made — see reading_cache.sh's header).
# P1-B — claude's fuel reading is ACCOUNT-level (`claude-usage` scans
# `projects/` in full), but the only freshness signals were PWD-scoped, so a
# limit landing in a different project directory never invalidated this
# one's board. See `_claude_usage_stale` below. P1-C — codex's rollouts live
# three levels under `sessions/` (`sessions/YYYY/MM/DD/`), so a brand new
# session never touched `sessions/`'s own mtime; `_board_scan_root` now
# tracks today's date directory instead (computed, never a `find` — this
# check runs on every render).
#
# 2026-09-12 round-3 fix review: P1-B and P1-C each left one more gap. P1-2 —
# a brand new FILE inside an EXISTING project directory moved neither
# `projects/`'s own mtime nor any per-file record (it didn't exist yet at
# the last publish) — see `_claude_usage_stale`'s header for the fix (track
# each project directory's own mtime too). P2-1 — round-2's "today's date
# directory" was computed from the OBSERVER's clock, which silently
# disagrees with whatever clock wrote the newest rollout the moment clikae
# runs under a different `TZ` than usual — see `_codex_newest_chain`'s
# header (codex.sh) for reading the actual newest chain off disk instead.
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

# _board_scan_root <engine> <dir> -> one directory PER LINE whose own mtime
# proves (or disproves) "nothing new appeared since the last publish" for
# THIS PWD. Claude lays sessions out one subdirectory per project slug, so
# scoping to just that subdirectory means a sibling project's activity never
# forces a rebuild here. The other three engines record cwd IN the file, not
# in the path, so there is no PWD-scoped subdirectory to point at — the
# engine's whole session root is the best available O(1) signal. codex is
# the one engine that needs MORE than one line — see `_codex_newest_chain`'s
# header (round-3 fix review, P2-1): rollouts live three levels under
# sessions/, so a new day/month/year directory bumps a DIFFERENT ancestor's
# mtime depending on which of those already existed at publish time, and
# there is no clock-based way to know which one that will be.
_board_scan_root() {
  local engine="$1" dir="$2"
  case "$engine" in
    claude) printf '%s/projects/%s\n' "$dir" "$(_claude_project_slug "$PWD")" ;;
    codex) _codex_newest_chain "$(_codex_sessions_dir "$dir")" ;;
    grok) printf '%s/sessions\n' "$dir" ;;
    antigravity) printf '%s/antigravity-cli/brain\n' "$dir" ;;
  esac
}

# _claude_usage_stale <dir> <generation-path> -> success (0) when the
# ACCOUNT-level claude-usage/fuel reading recorded in <generation-path> no
# longer matches what is on disk. `limit_profile_dry` reads `claude-usage`
# (board_state_refresh: `find "$dir/projects" -name '*.jsonl' -mmin -300`,
# scanning EVERY project, not just this PWD's), so its freshness cannot be a
# PWD-scoped signal — see board_stale's own P1-B comment for the failure
# this closes: a limit landing in a DIFFERENT project directory never
# touches this scope's scanroot-mtime or recent/<key>, so this board stayed
# "fresh" (green) forever. Three signals, all O(bounded), none a fork per
# candidate file:
#   1. `projects/`'s OWN mtime (not projects/<slug>) — catches a brand new
#      project directory appearing anywhere in the account.
#   2. (2026-09-12 round-3 fix review, P1-2) each EXISTING `projects/<slug>`
#      directory's own mtime — bounded by the project count, not the file
#      count. Signal 1 only fires when a project directory is itself
#      created/removed; it stays put when a brand new FILE lands inside an
#      ALREADY-existing project directory, and that file was never inside
#      the -mmin -300 window at the LAST publish (it did not exist yet), so
#      signal 3 has no record to re-stat either. Creating a file DOES move
#      its parent directory's own mtime (a dirent add), so that is the
#      signal that catches it.
#   3. the recorded (mtime, size) of each file that was inside the -mmin
#      -300 window at the last publish, re-stat in ONE batched call — catches
#      an append (a limit landing, or clearing) to a session in a project
#      whose directory already existed, which does not bump `projects/`'s
#      own mtime, only that one file's.
# A file or directory recorded in signal 2/3 having disappeared (aged out,
# or the fixture moved it) is itself treated as stale — the usage snapshot
# is trusted only while every path it was computed from is still exactly
# what it was. An EMPTY signal-3 set at publish time (round-3 fix review:
# PROBE B4 — an append to an OLD file, already excluded from the -mmin -300
# window, pulls it back in without moving any directory's mtime) used to
# read as "nothing to compare against, call it fresh" — permanently, since
# nothing short of a brand new project directory or file could ever
# invalidate it again. Zero evidence is not evidence of freshness: rebuild.
_claude_usage_stale() {
  local dir="$1" gen="$2" root_mt saved_root_mt
  [ -f "$gen/claude-usage-root-mtime" ] || return 0
  root_mt="$(file_mtime "$dir/projects" 2>/dev/null)" || root_mt=""
  saved_root_mt=""
  IFS= read -r saved_root_mt < "$gen/claude-usage-root-mtime"
  [ -n "$root_mt" ] && [ "$root_mt" != "$saved_root_mt" ] && return 0

  if [ -f "$gen/claude-usage-projdirs" ]; then
    local pd pm
    local -a pdirs=() pmts=()
    while IFS=$'\037' read -r pd pm; do
      [ -n "$pd" ] || continue
      [ -d "$pd" ] || return 0   # a counted project directory vanished.
      pdirs+=("$pd"); pmts+=("$pm")
    done < "$gen/claude-usage-projdirs"
    if [ "${#pdirs[@]}" -gt 0 ]; then
      local _pi=0 _pmt _psz
      while read -r _pmt _psz; do
        [ "$_pmt" = "${pmts[$_pi]}" ] || return 0
        _pi=$((_pi + 1))
      done < <(files_mtime_size "${pdirs[@]}")
    fi
  fi

  [ -f "$gen/claude-usage-files" ] || return 0
  local p m s
  local -a upaths=() umts=() uszs=()
  while IFS=$'\037' read -r p m s; do
    [ -n "$p" ] || continue
    [ -f "$p" ] || return 0   # a counted file vanished — the reading is stale.
    upaths+=("$p"); umts+=("$m"); uszs+=("$s")
  done < "$gen/claude-usage-files"
  [ "${#upaths[@]}" -gt 0 ] || return 0
  local i=0 cur_mt cur_sz
  while IFS=' ' read -r cur_mt cur_sz; do
    { [ "$cur_mt" = "${umts[$i]}" ] && [ "$cur_sz" = "${uszs[$i]}" ]; } || return 0
    i=$((i + 1))
  done < <(files_mtime_size "${upaths[@]}")
  return 1
}

# board_stale <engine> <dir> <generation-path> -> success (0) when the
# published generation no longer matches what is on disk for THIS scope.
# O(1)-ish signals, neither a tree walk, and all compared for EQUALITY
# against what was RECORDED at publish time — never ">" against a wall-clock
# stamp: a fixture (or a clock skew) that dates a file into the future is a
# legitimate, existing pattern in this repo's own tests (touch -t past the
# current year, to force a deterministic "newest" without racing other
# fixtures' timestamps), and ">" against `updated` would read every such file
# as permanently stale, forever re-triggering a rebuild each read.
#   1. the PWD-scoped scan root's own mtime(s), vs `scanroot-mtime` recorded
#      at publish — catches a session that did not exist at publish time (a
#      new file is a new dirent, which always bumps its parent directory's
#      mtime). One path for claude/grok/antigravity; codex's is a whole
#      chain (see `_codex_newest_chain`'s header, round-3 fix review P2-1).
#   2. (claude only) the account-level fuel reading — see
#      `_claude_usage_stale` above. Checked BEFORE the per-scope early return
#      below, because a scope with no recorded recent sessions must still
#      answer for an account-level limit landing elsewhere (P1-B).
#   3. the (mtime, size) of each of THIS scope's already-recorded recent
#      sessions (bounded to CLIKAE_HOME_RECENT_MAX, never the whole tree), vs
#      what was recorded for it in `recent/<scope>` at publish — catches an
#      in-progress session simply growing, with no new/removed file at all
#      (the P1-3 shape: a limit landing mid-session). Both fields, at the
#      nanosecond precision `files_mtime_size` now reports (P1-A): a mtime-only,
#      whole-second comparison went blind to any write landing in the SAME
#      wall-clock second as the last publish, in EITHER direction.
# Any mismatch means rebuild.
board_stale() {
  local engine="$1" dir="$2" gen="$3" key
  [ -f "$gen/updated" ] || return 0

  # A codex tank's chain (`_board_scan_root`) can be several lines; re-stat
  # every RECORDED path in one batched call — never a fork per level — and
  # compare against the mtime published alongside it. A recorded path that
  # vanished (a fixture rewrite, or a directory recycled) is itself stale.
  if [ -f "$gen/scanroot-mtime" ]; then
    local _srp _srm
    local -a _sr_paths=() _sr_mts=()
    while IFS=$'\037' read -r _srp _srm; do
      [ -n "$_srp" ] || continue
      [ -d "$_srp" ] || return 0
      _sr_paths+=("$_srp"); _sr_mts+=("$_srm")
    done < "$gen/scanroot-mtime"
    if [ "${#_sr_paths[@]}" -gt 0 ]; then
      local _si=0 _smt _ssz
      while read -r _smt _ssz; do
        [ "$_smt" = "${_sr_mts[$_si]}" ] || return 0
        _si=$((_si + 1))
      done < <(files_mtime_size "${_sr_paths[@]}")
    fi
  fi

  if [ "$engine" = claude ] && _claude_usage_stale "$dir" "$gen"; then return 0; fi

  local scope key; scope="$(_board_scope_raw "$engine")"; key="$(board_key "$scope")"
  [ -f "$gen/recent/$key" ] || return 1
  # ONE stat call for every candidate (files_mtime_size, shared kernel — see
  # its own header in profile_store.sh), never one fork per file: this runs
  # on every board_read/board_recent/board_find, so paying N forks for N
  # recent files here would multiply right back into the O(files) cost #62
  # was written to kill, just moved from "every transcript" to "every recent
  # file, every read, every render".
  # Row shape (P1-A): "<display-mt>\037<stale-mt>\037<size>\037<sid>". The
  # DISPLAY mtime is whole-second — board_recent hands it straight to
  # callers (home.sh's `_human_age` does bash integer arithmetic on it) — so
  # it must stay exactly what it always was. The STALENESS check needs
  # nanosecond precision AND size (see this function's own header), which
  # live in the two fields between it and the sid.
  local dmt mt sz sid f sidkey savedsid
  local -a rmts=() rsizes=() rfiles=()
  local firstline=1
  while IFS=$'\037' read -r dmt mt sz sid; do
    if [ "$firstline" -eq 1 ]; then
      firstline=0
      # P3-2: a board_key collision on the scope itself is a miss, not a
      # confident wrong answer for a completely different directory. (The
      # header row has only two fields, so `mt` holds the recorded scope here.)
      { [ "$dmt" = "#scope" ] && [ "$mt" = "$scope" ]; } || return 1
      continue
    fi
    [ -n "$sid" ] || continue
    sidkey="$(board_key "$sid")"
    [ -f "$gen/sids/$sidkey" ] || continue
    { IFS= read -r savedsid; IFS= read -r f; } < "$gen/sids/$sidkey"
    [ "$savedsid" = "$sid" ] || continue   # P3-2: same guard on the sid index.
    [ -f "$f" ] || continue
    rmts+=("$mt"); rsizes+=("$sz"); rfiles+=("$f")
  done < "$gen/recent/$key"
  [ "${#rfiles[@]}" -gt 0 ] || return 1
  local i=0 cur_mt cur_sz
  while IFS=' ' read -r cur_mt cur_sz; do
    { [ "$cur_mt" = "${rmts[$i]}" ] && [ "$cur_sz" = "${rsizes[$i]}" ]; } || return 0
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
  # Rows are "<display-mt>\037<stale-mt>\037<size>\037<sid>" on disk (P1-A —
  # the last two fields back board_stale's own comparison), but every caller
  # (claude/codex/grok/antigravity's adapter_recent_sids, and home.sh's
  # `_human_age` after it, which does bash integer arithmetic on the mtime)
  # is written to the older, public "<display-mt>\037<sid>" contract. Keep
  # only the whole-second display mtime and the sid here, once, rather than
  # widen every adapter (and every arithmetic consumer) to a 4-field row.
  tail -n +2 "$gen/recent/$key" | head -n "$n" | cut -d $'\037' -f1,4
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
#
# P3-1 (2026-09-12 round-2 fix review): several publishes inside the same
# wall-clock second all get whole-second mtimes, so the sort had no way to
# tell them apart — a non-deterministic ordering that could rm the directory
# `current` actually points at. The consequence stays bounded either way
# (board_generation's own `[ -f "$root/current" ]` check + a rebuild covers
# a dangling pointer), but the sort itself should still be reproducible.
# Directory name as the tie-break: cheap, and turns "arbitrary" into
# "deterministic" even though mktemp's XXXXXX suffix is random, not ordered.
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
    done | sort -t$'\037' -k1,1rn -k2,2r | tail -n +"$((keep + 1))" | cut -d$'\037' -f2-
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
  # P3-4 (2026-09-12 round-2 fix review): load_adapter now runs BEFORE
  # mktemp -d, not after — a load failure used to leave a generation
  # directory behind that nothing would ever point `current` at (harmless
  # once board_gc_generations' keep-5 sweep started catching it, but there is
  # no reason to create it at all when this call is about to bail anyway).
  load_adapter "$engine" >/dev/null 2>&1 || return 0
  root="$(board_root "$dir")"
  mkdir -p "$root" || return 0
  gen="$(mktemp -d "$root/generation.XXXXXX")" || return 0
  mkdir -p "$gen/recent" "$gen/sids"
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
  # as permanently stale). `_board_scan_root` can be several lines for codex
  # (see its own header) — batch every existing one into the SAME
  # files_mtime_size call, one fork total, not one per level.
  local -a scan_roots=()
  while IFS= read -r p; do [ -n "$p" ] && [ -d "$p" ] && scan_roots+=("$p"); done \
    < <(_board_scan_root "$engine" "$dir" 2>/dev/null)
  : > "$gen/scanroot-mtime"
  if [ "${#scan_roots[@]}" -gt 0 ]; then
    local _si=0 _smt _ssz
    while read -r _smt _ssz; do
      printf '%s\037%s\n' "${scan_roots[$_si]}" "$_smt" >> "$gen/scanroot-mtime"
      _si=$((_si + 1))
    done < <(files_mtime_size "${scan_roots[@]}")
  fi
  # P1-A (2026-09-12 round-2 fix review): the mtime `sessions_by_mtime` sorts
  # by is whole-second and only used for ORDER here. What board_stale
  # actually re-checks later needs nanosecond precision AND size (see its own
  # header) — both come from files_mtime_size, ONE batched call (positional,
  # same order as $paths — see its own header in profile_store.sh) zipped
  # back onto each path by index, never a fork per file.
  local -A _fmap=()
  if [ "${#paths[@]}" -gt 0 ]; then
    local _fi=0 _fmt _fsz
    while read -r _fmt _fsz; do
      _fmap["${paths[$_fi]}"]="$_fmt"$'\037'"$_fsz"
      _fi=$((_fi + 1))
    done < <(files_mtime_size "${paths[@]}")
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
      # "<display-mt>\037<stale-mt>\037<size>\037<sid>" — $mt (whole-second,
      # sessions_by_mtime's own sort key) is the DISPLAY value board_recent
      # hands to callers unchanged; the fine-grained pair from _fmap is
      # board_stale's own comparison data (see its header). Falls back to
      # $mt again and a sentinel size only if $f somehow fell out of _fmap
      # between the two stat passes (a raced deletion) — degrades to the
      # OLD whole-second-only staleness check for that one row, never a
      # missing display value.
      printf '%s\037%s\037%s\n' "$mt" "${_fmap[$f]:-$mt$'\037'0}" "$sid" >> "$gen/recent/$key.all"
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
      _limit_claude_readings "$files" > "$gen/claude-usage"
      # P1-B (2026-09-12 round-2 fix review): claude-usage is ACCOUNT-level
      # (every project, not just this PWD's), so its OWN freshness signals
      # must be too — see _claude_usage_stale's header. `projects/`'s own
      # mtime catches a brand new project directory; the (mtime, size) of
      # each file that was inside the -mmin -300 window just now — bounded
      # by definition, never the whole tree — catches an append (a limit
      # landing, or clearing) to a session in a project whose directory
      # already existed.
      #
      # P1-2 (2026-09-12 round-3 fix review): neither of the above sees a
      # brand new FILE inside an EXISTING project directory — see
      # _claude_usage_stale's header. Record each existing project
      # directory's own mtime too, bounded by the project count, folded into
      # the SAME files_mtime_size call as the files above (one fork, not
      # two).
      file_mtime "$dir/projects" > "$gen/claude-usage-root-mtime" 2>/dev/null || true
      : > "$gen/claude-usage-files"
      : > "$gen/claude-usage-projdirs"
      local -a ufiles=() updirs=()
      while IFS= read -r f; do [ -n "$f" ] && ufiles+=("$f"); done <<< "$files"
      for f in "$dir"/projects/*/; do
        [ -d "$f" ] || continue
        updirs+=("${f%/}")
      done
      if [ "${#ufiles[@]}" -gt 0 ] || [ "${#updirs[@]}" -gt 0 ]; then
        local _ui=0 _umt _usz
        while read -r _umt _usz; do
          if [ "$_ui" -lt "${#ufiles[@]}" ]; then
            printf '%s\037%s\037%s\n' "${ufiles[$_ui]}" "$_umt" "$_usz" >> "$gen/claude-usage-files"
          else
            printf '%s\037%s\n' "${updirs[$((_ui - ${#ufiles[@]}))]}" "$_umt" >> "$gen/claude-usage-projdirs"
          fi
          _ui=$((_ui + 1))
        done < <(files_mtime_size "${ufiles[@]}" "${updirs[@]}")
      fi
      ;;
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
