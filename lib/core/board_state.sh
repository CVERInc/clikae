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

# _board_mtime_size_map <path>... -> fills the global `_BOARD_MTMAP`
# associative array, path -> "<mtime>\037<size>", one entry per arg that
# still exists. P3-4 (2026-09-13 round-4 fix review): every caller in this
# file used to zip a batched `files_mtime_size` call back onto its own
# argument array BY INDEX — safe only as long as every argument is still
# there when `stat` actually runs. GNU and BSD `stat` both print one FEWER
# line for a vanished argument (the error itself is swallowed by
# `2>/dev/null`), so a single file disappearing between the caller building
# its list and this call landing shifts every zip index after it onto the
# WRONG path — silently recording one file's (mtime, size) against another
# file's identity. Reading the path straight back from `stat` itself (`%n`/
# `%N`, the same field `sessions_by_mtime` already relies on) and keying off
# THAT instead makes a vanished argument a missing map entry, never a
# misaligned one. Kept local to this file rather than changed in
# `files_mtime_size` (profile_store.sh) itself, since that primitive's
# "<mtime> <size>" contract (no path field) has other callers outside this
# file (e.g. limit.sh's codex rate-limit cache) that already parse it
# positionally and would break the moment a third field appeared.
declare -gA _BOARD_MTMAP
_board_mtime_size_map() {
  _BOARD_MTMAP=()
  _clikae_statv
  local _p _mt _sz
  while IFS=$'\037' read -r _mt _sz _p; do
    [ -n "$_p" ] || continue
    _BOARD_MTMAP["$_p"]="$_mt"$'\037'"$_sz"
  done < <(
    if [ "$_CLIKAE_STAT_FMT" = '%Y %n' ]; then
      stat -c $'%.9Y\037%s\037%n' "$@" 2>/dev/null
    else
      stat -f $'%Fm\037%z\037%N' "$@" 2>/dev/null
    fi
  )
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
#   3. (2026-09-13 round-4 fix review, P1-1) the recorded (mtime, size) of
#      the NEWEST K files of EACH project directory, re-stat in ONE batched
#      call — catches an append (a limit landing, or clearing) to a session
#      in a project whose directory already existed, which does not bump
#      `projects/`'s own mtime, only that one file's. This set used to be
#      "whatever `-mmin -300` (the SAME window `claude-usage`'s own reading
#      is computed from) happened to match at publish time" — but that
#      window is legitimately EMPTY every morning, before anything has been
#      touched in the last five hours, on every account, every day. See this
#      function's own tail comment for why recording that window here (round-3
#      fix review, PROBE B4's fix) was the wrong set to fix B4 with.
# A file or directory recorded in signal 2/3 having disappeared (aged out,
# or the fixture moved it) is itself treated as stale — the usage snapshot
# is trusted only while every path it was computed from is still exactly
# what it was.
# round-3 fix review, PROBE B4: an append to an OLD file, already excluded
# from the `-mmin -300` window, pulls it back into view without moving any
# directory's mtime — signal 3's old (now-per-window) recorded set had no
# entry to re-stat, so an EMPTY set read as "nothing to compare against,
# call it fresh", permanently.
# round-4 fix review, P1-1: fixing B4 by making an empty signal-3 set mean
# "rebuild" instead was the wrong half to change — B4's actual shape is "the
# file the user is about to come back to is still one of the newest in ITS
# OWN project", which per-project top-K (this signal, now) catches directly,
# same as any other append. `-mmin -300` being momentarily empty (every idle
# account, every morning) no longer has anything to do with whether this
# signal has evidence to compare — it always does, as long as any project
# has ever had a file in it — so an empty set here is now trusted as
# genuinely nothing-recorded-because-nothing-exists, not treated as "maybe
# stale, rebuild every read forever" (measured: 3 claude tanks, idle window,
# 10.4s/frame before this fix, 390ms/frame on main and after it).
# P2-1 (2026-09-13 round-4 fix review): this used to run its own THREE
# `_board_mtime_size_map`/`files_mtime_size` calls (root mtime, projdirs,
# files) — its own separate stat fork per signal, on top of board_stale's
# other two. On a warm, idle render that is the entire cost, and it is paid
# ONCE PER CLAUDE TANK: measured, a claude-tank-heavy dogfood store (6 tanks)
# cost 260ms MORE per tank than main on the exact same warm store (P2-1's own
# receipt). `_claude_usage_stale` no longer stats anything itself — it only
# reads `_BOARD_MTMAP`, which board_stale (its only caller) has ALREADY
# populated, in ONE batched call, with every path this function and
# board_stale's other two signals need. See board_stale's own header.
_claude_usage_stale() {
  local dir="$1" gen="$2" root_mt saved_root_mt
  [ -f "$gen/claude-usage-root-mtime" ] || return 0
  # P3-1 (2026-09-12 round-3 fix review): P1-A upgraded every FILE mtime
  # comparison to nanosecond precision; this DIRECTORY one was still whole
  # seconds via `file_mtime`, so a project directory created in the SAME
  # wall-clock second as the last publish was invisible to signal 1 in
  # either direction. The nanosecond mtime half of `_BOARD_MTMAP`'s value is
  # the same stat this file's other two signals already use.
  root_mt="${_BOARD_MTMAP["$dir/projects"]%%$'\037'*}"
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
    local _pi
    for _pi in "${!pdirs[@]}"; do
      # projdirs records mtime only (a directory's size is not a
      # meaningful signal), so compare just the mtime half of the map's
      # "<mtime>\037<size>" value.
      [ "${_BOARD_MTMAP[${pdirs[$_pi]}]%%$'\037'*}" = "${pmts[$_pi]}" ] || return 0
    done
  fi

  [ -f "$gen/claude-usage-files" ] || return 0
  local p m s
  local -a upaths=() umts=() uszs=()
  while IFS=$'\037' read -r p m s; do
    [ -n "$p" ] || continue
    [ -f "$p" ] || return 0   # a counted file vanished — the reading is stale.
    upaths+=("$p"); umts+=("$m"); uszs+=("$s")
  done < "$gen/claude-usage-files"
  # P1-1: an empty recorded set is no longer "no evidence, assume stale" —
  # see this function's own header. It genuinely means no claude session has
  # ever existed anywhere in this account, which really is fresh.
  [ "${#upaths[@]}" -gt 0 ] || return 1
  local i
  for i in "${!upaths[@]}"; do
    [ "${_BOARD_MTMAP[${upaths[$i]}]:-}" = "${umts[$i]}"$'\037'"${uszs[$i]}" ] || return 0
  done
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
#      chain (see `_codex_newest_chain`'s header, round-3/round-4 fix review
#      P2-1/P2-2). (2026-09-13 round-4 fix review, P1-2) a level that did NOT
#      exist yet AT PUBLISH TIME is recorded too, as a MISSING sentinel — see
#      board_state_refresh's own comment — because "this tank's `sessions/`
#      doesn't exist yet" is itself a fact worth comparing on the next read:
#      the moment it (or any ancestor codex chain level) gets created, that
#      is new evidence, and the old code simply dropped it from the record
#      entirely, so nothing was ever watching for it to appear.
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
#
# P2-1 (2026-09-13 round-4 fix review): the three signals above used to each
# pay their OWN `_board_mtime_size_map`/`files_mtime_size` fork — up to five
# on a claude tank (scanroot, claude-usage's root/projdirs/files, recent
# files). That made a claude tank's WARM, nothing-changed cost scale with
# SIGNAL COUNT, not stay flat: measured, 6 claude tanks cost 260ms MORE per
# tank than main on an otherwise-identical small warm store. Every one of
# those five categories is read from a small on-disk record with NO fork
# (plain `read`/`[ -f ]`/`[ -d ]`), so nothing stops gathering every path
# they ALL need before stat-ing anything, then paying `_board_mtime_size_map`
# exactly ONCE per tank for the union — it is path-keyed (P3-4), so mixing
# unrelated categories into the same call is safe: each one below still
# looks its own paths up by their own key, never anyone else's.
board_stale() {
  local engine="$1" dir="$2" gen="$3" key
  [ -f "$gen/updated" ] || return 0

  # --- gather (no fork): read every small on-disk record this tank's
  # signals need, short-circuiting immediately on anything a plain
  # `[ -f ]`/`[ -d ]` already proves is stale, WITHOUT waiting for the
  # batched stat below to say so.
  local -a _stat_union=()

  # Signal 1: the PWD-scoped scan root (a whole chain for codex — see
  # `_codex_newest_chain`'s header). A row whose recorded mtime is the
  # `MISSING` sentinel means this level did not exist AT PUBLISH TIME (P1-2,
  # round-4 fix review) — the only fact worth comparing there is whether it
  # exists NOW (new evidence: rebuild), never re-stat'd.
  local -a _sr_paths=() _sr_mts=()
  if [ -f "$gen/scanroot-mtime" ]; then
    local _srp _srm
    while IFS=$'\037' read -r _srp _srm; do
      [ -n "$_srp" ] || continue
      if [ "$_srm" = MISSING ]; then
        [ -d "$_srp" ] && return 0
        continue
      fi
      [ -d "$_srp" ] || return 0
      _sr_paths+=("$_srp"); _sr_mts+=("$_srm")
    done < "$gen/scanroot-mtime"
    _stat_union+=("${_sr_paths[@]}")
  fi

  # Signal 2 (claude only): the account-level fuel reading's own three
  # sub-signals — see `_claude_usage_stale`'s header.
  local -a _cu_pdirs=() _cu_ufiles=()
  if [ "$engine" = claude ] && [ -f "$gen/claude-usage-root-mtime" ]; then
    _stat_union+=("$dir/projects")
    if [ -f "$gen/claude-usage-projdirs" ]; then
      local _pd _pm
      while IFS=$'\037' read -r _pd _pm; do
        [ -n "$_pd" ] || continue
        [ -d "$_pd" ] || return 0   # a counted project directory vanished.
        _cu_pdirs+=("$_pd")
      done < "$gen/claude-usage-projdirs"
      _stat_union+=("${_cu_pdirs[@]}")
    fi
    if [ -f "$gen/claude-usage-files" ]; then
      local _up _um _us
      while IFS=$'\037' read -r _up _um _us; do
        [ -n "$_up" ] || continue
        [ -f "$_up" ] || return 0   # a counted file vanished — stale.
        _cu_ufiles+=("$_up")
      done < "$gen/claude-usage-files"
      _stat_union+=("${_cu_ufiles[@]}")
    fi
  fi

  # Signal 3: this scope's already-recorded recent sessions.
  local scope; scope="$(_board_scope_raw "$engine")"; key="$(board_key "$scope")"
  local -a rmts=() rsizes=() rfiles=()
  local _has_recent=0
  if [ -f "$gen/recent/$key" ]; then
    _has_recent=1
    # ONE stat call for every candidate — this runs on every
    # board_read/board_recent/board_find, so paying N forks for N recent
    # files here would multiply right back into the O(files) cost #62 was
    # written to kill, just moved from "every transcript" to "every recent
    # file, every read, every render".
    # Row shape (P1-A): "<display-mt>\037<stale-mt>\037<size>\037<sid>". The
    # DISPLAY mtime is whole-second — board_recent hands it straight to
    # callers (home.sh's `_human_age` does bash integer arithmetic on it) —
    # so it must stay exactly what it always was. The STALENESS check needs
    # nanosecond precision AND size (see this function's own header), which
    # live in the two fields between it and the sid.
    local dmt mt sz sid f sidkey savedsid firstline=1
    while IFS=$'\037' read -r dmt mt sz sid; do
      if [ "$firstline" -eq 1 ]; then
        firstline=0
        # P3-2: a board_key collision on the scope itself is a miss, not a
        # confident wrong answer for a completely different directory. (The
        # header row has only two fields, so `mt` holds the recorded scope.)
        { [ "$dmt" = "#scope" ] && [ "$mt" = "$scope" ]; } || { _has_recent=2; break; }
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
    _stat_union+=("${rfiles[@]}")
  fi

  # --- ONE batched stat for every path any signal above needs ---
  _board_mtime_size_map "${_stat_union[@]}"

  # --- compare (no further fork) ---
  if [ "${#_sr_paths[@]}" -gt 0 ]; then
    local _si
    for _si in "${!_sr_paths[@]}"; do
      [ "${_BOARD_MTMAP[${_sr_paths[$_si]}]%%$'\037'*}" = "${_sr_mts[$_si]}" ] || return 0
    done
  fi

  if [ "$engine" = claude ] && _claude_usage_stale "$dir" "$gen"; then return 0; fi

  [ "$_has_recent" -eq 1 ] || return 1   # 0 = never recorded, 2 = scope collision (P3-2)
  [ "${#rfiles[@]}" -gt 0 ] || return 1
  local i
  for i in "${!rfiles[@]}"; do
    [ "${_BOARD_MTMAP[${rfiles[$i]}]:-}" = "${rmts[$i]}"$'\037'"${rsizes[$i]}" ] || return 0
  done
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
  # P2-2 (2026-09-12 round-3 fix review): antigravity's cwd lives IN the
  # file, not the path (see _board_scan_root's header), so this loop below
  # scans the WHOLE account's sessions, never just this PWD's — and used to
  # pay one reading_cache_run + fork pipeline PER session for that (measured
  # ~5s fixed on a synthetic 500-session tank). One bulk index read replaces
  # that with plain associative-array lookups — see
  # adapter_session_cwd_index's header (antigravity.sh) for why this is safe
  # (same source of truth, same "first occurrence wins" semantics).
  local -A _agy_ws=()
  if [ "$engine" = antigravity ] && declare -F adapter_session_cwd_index >/dev/null; then
    local _asid _aws
    while IFS=$'\037' read -r _asid _aws; do
      [ -n "$_asid" ] || continue
      _agy_ws["$_asid"]="$_aws"
    done < <(adapter_session_cwd_index "$dir" 2>/dev/null)
  fi
  date +%s > "$gen/updated"
  # Recorded for board_stale's equality check, never compared with ">" — see
  # its own header for why (a future-dated fixture/clock skew must not read
  # as permanently stale). `_board_scan_root` can be several lines for codex
  # (see its own header) — batch every existing one into the SAME stat call,
  # one fork total, not one per level.
  # P1-2 (2026-09-13 round-4 fix review): a level `_board_scan_root` names
  # that does NOT exist yet at THIS publish (a brand new codex tank with no
  # `sessions/` directory, or claude/grok/antigravity's own scan root before
  # its first session) used to be silently dropped here (`[ -d "$p" ]`
  # filtered it out) — so board_stale's signal 1 had nothing recorded for it
  # at all, and could never notice it come into existence later. Every level
  # is now recorded, existing or not: an existing one gets its real mtime, a
  # missing one gets the `MISSING` sentinel (never a possible real mtime
  # value, see profile_store.sh's `%.9Y`/`%Fm` formats) so board_stale can
  # tell "should compare a real mtime" from "should compare existence" apart
  # — see its own header for the read side.
  local -a scan_roots=() _scan_roots_exist=()
  while IFS= read -r p; do [ -n "$p" ] && scan_roots+=("$p"); done \
    < <(_board_scan_root "$engine" "$dir" 2>/dev/null)
  : > "$gen/scanroot-mtime"
  if [ "${#scan_roots[@]}" -gt 0 ]; then
    for p in "${scan_roots[@]}"; do [ -d "$p" ] && _scan_roots_exist+=("$p"); done
    _board_mtime_size_map "${_scan_roots_exist[@]}"
    local _srv
    for p in "${scan_roots[@]}"; do
      _srv="${_BOARD_MTMAP[$p]:-}"
      if [ -n "$_srv" ]; then
        printf '%s\037%s\n' "$p" "${_srv%%$'\037'*}" >> "$gen/scanroot-mtime"
      else
        printf '%s\037MISSING\n' "$p" >> "$gen/scanroot-mtime"
      fi
    done
  fi
  # P1-A (2026-09-12 round-2 fix review): the mtime `sessions_by_mtime` sorts
  # by is whole-second and only used for ORDER here. What board_stale
  # actually re-checks later needs nanosecond precision AND size (see its own
  # header) — both come from ONE batched stat call. P3-4 (round-4 fix
  # review): keyed by the path stat itself hands back (`_board_mtime_size_map`),
  # not zipped onto `$paths` by index — a file that vanished between the
  # `find` above and this stat is then a missing map entry, never a value
  # recorded against the WRONG path.
  _board_mtime_size_map "${paths[@]}"
  local -A _fmap=(); local _fk
  for _fk in "${!_BOARD_MTMAP[@]}"; do _fmap["$_fk"]="${_BOARD_MTMAP[$_fk]}"; done
  # P1-1 (2026-09-13 round-4 fix review): claude-usage-files (below) used to
  # record whatever `-mmin -300` happened to match — legitimately EMPTY every
  # morning before anything has been touched in the last five hours, which
  # made an idle account's fuel reading permanently indistinguishable from
  # "no evidence yet, keep rebuilding" (see _claude_usage_stale's header).
  # Tracked here, in the SAME newest-first pass that already builds each
  # project's recent list, at no extra cost: the newest K files of EACH
  # project directory (bounded by project count × K, not file count or the
  # -mmin window) is a signal that is never empty once anything exists, and
  # covers PROBE B4 (an append to an old, already-excluded-by-window file)
  # directly — that file only needs to still be among ITS OWN project's
  # newest K, which an append-in-place always keeps it as.
  local -A _claude_scope_count=()
  local -a claude_topk_files=()
  local _csc
  if [ "${#paths[@]}" -gt 0 ]; then
    while read -r mt f; do
      [ -f "$f" ] || continue
      case "$engine" in
        claude) sid="${f##*/}"; sid="${sid%.jsonl}"; scope="${f%/*}"; scope="${scope##*/}" ;;
        codex) sid="$(_codex_meta_field "$f" id)"; scope="$(_codex_meta_field "$f" cwd)" ;;
        grok) sid="$(_grok_json_str "$f" id)"; scope="$(_grok_json_str "$f" cwd)" ;;
        antigravity)
          sid="${f%/.system_generated/*}"; sid="${sid##*/}"
          if [ -n "${_agy_ws[$sid]+x}" ]; then
            scope="${_agy_ws[$sid]}"
          else
            scope="$(adapter_session_cwd "$f")"
          fi
          ;;
      esac
      [ -n "$sid" ] || continue
      key="$(board_key "$sid")"
      # P3-2: the sid itself is written back so a reader (board_find,
      # board_stale) can verify it — a 32-bit cksum collision then reads as a
      # miss, never someone else's transcript.
      printf '%s\n%s\n' "$sid" "$f" > "$gen/sids/$key"
      if [ "$engine" = claude ]; then
        _csc="${_claude_scope_count[$scope]:-0}"
        if [ "$_csc" -lt "$n" ]; then
          claude_topk_files+=("$f")
          _claude_scope_count["$scope"]=$((_csc + 1))
        fi
      fi
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
      # directory's own mtime too, bounded by the project count.
      # P3-1: nanosecond precision, matching _claude_usage_stale's own check
      # (see its header) — a whole-second `file_mtime` here went blind to a
      # project directory created in the SAME wall-clock second as this
      # publish.
      { local _rmt; _rmt="$(files_mtime_size "$dir/projects" 2>/dev/null)"; printf '%s\n' "${_rmt%% *}"; } \
        > "$gen/claude-usage-root-mtime" 2>/dev/null || true
      : > "$gen/claude-usage-files"
      : > "$gen/claude-usage-projdirs"
      # P1-1 (2026-09-13 round-4 fix review): this is no longer the `-mmin
      # -300` set (`$files`, still used above only to COMPUTE the actual
      # usage reading, which really is a 5-hour window) — it is
      # `claude_topk_files`, built above in the SAME pass that already
      # stats every path once (`_fmap`), so no second stat call is needed
      # here at all — see that pass's own comment for why per-project top-K
      # is the right freshness set. updirs is its own homogeneous list, kept
      # in a SEPARATE stat call (P3-4, round-4 fix review): joining it with
      # ufiles into one call and splitting the result back by index (the
      # OLD code here) misattributes every row after a vanished path to the
      # wrong path the moment `stat` silently prints one fewer line for it.
      # `_board_mtime_size_map` keys off the path stat itself returns
      # instead, so a vanished path is a missing entry, never a shifted one.
      for f in "${claude_topk_files[@]}"; do
        [ -n "${_fmap[$f]:-}" ] || continue
        printf '%s\037%s\n' "$f" "${_fmap[$f]}" >> "$gen/claude-usage-files"
      done
      local -a updirs=()
      for f in "$dir"/projects/*/; do
        [ -d "$f" ] || continue
        updirs+=("${f%/}")
      done
      if [ "${#updirs[@]}" -gt 0 ]; then
        _board_mtime_size_map "${updirs[@]}"
        for f in "${updirs[@]}"; do
          [ -n "${_BOARD_MTMAP[$f]:-}" ] || continue
          printf '%s\037%s\n' "$f" "${_BOARD_MTMAP[$f]%%$'\037'*}" >> "$gen/claude-usage-projdirs"
        done
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
