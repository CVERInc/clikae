# shellcheck shell=bash
# Tree discovery belongs to session boundaries. Renders consume immutable,
# per-tank generations through an atomically replaced pointer. A missing index
# is an unknown reading, never permission to PARSE a transcript tree on a frame.
#
# 2026-09-13 round-6 fix review — the round-5 whole-tank fingerprint below is
# still the entire staleness signal (see board_stale's own header); round-6
# fixed two costs in how it was COMPUTED and ACTED ON, not what it means:
#
#   P1-1/P2-1: the fingerprint used to hand every path to `stat` as one argv,
#   built by a bash `while read` loop pulling `find`'s output through a
#   process substitution ONE BYTE AT A TIME. Past ARG_MAX, `stat` failed
#   E2BIG and the failure was swallowed (`2>/dev/null`), silently collapsing
#   the whole fingerprint to a file count — an append to an EXISTING file
#   then changed nothing a render could see. The bash loop itself cost
#   hundreds of ms at a few thousand files even when `stat` succeeded.
#   Fix: `_board_stat_rows` is now ONE `find … -exec stat … {} +` piped
#   straight into `sort | cksum` — `find` batches argv itself (an
#   `-exec … +` batch cannot overflow ARG_MAX no matter how many files
#   match), and no path is ever pulled into a bash variable, let alone read
#   from a pipe one byte at a time.
#
#   P1-2: any write anywhere in the tank made `board_state_refresh` rebuild
#   EVERY file's sid/scope/resume-row and re-run EVERY file's rate-limit scan
#   through `reading_cache_run` — fork cost proportional to the tank's WHOLE
#   transcript count, never to what actually changed. Fix:
#   `board_state_refresh` now diffs the fresh stat rows against the
#   PREVIOUS generation's own small manifest and only parses a file — sid,
#   scope, rate-limit reading — when its (mtime, size) differs from last
#   time. Everything else is carried forward: `sids/` and `recent/` start as
#   a plain `cp -a` of the previous generation, and only the sid/scope a
#   changed, new, or removed file actually touches gets rewritten.
#
# 2026-09-12 round-5 fix review — DESIGN DECISION (closing the round-1..4
# whack-a-mole for good): rounds 1-4 each shipped a bounded, PER-SIGNAL
# freshness check (a scan-root directory mtime, an account-level top-K of
# recorded files, a codex day-dir chain, …) meant to avoid re-listing a
# tank's whole transcript tree on every render. Every round found one more
# write shape those bounded signals could not see, because each one is a
# GUESS at which paths might change, built from whatever happened to be true
# at the LAST publish — an append to the 11th-newest file in a project, a
# limit landing in a subagent's `agent-*.jsonl`, a rollout appended to after
# publish from a different cwd. A guess about which paths to watch is always
# one write shape behind reality.
#
# The fix is to stop guessing: `board_stale` now re-lists EVERY transcript
# file under the tank (the exact same `find` `board_state_refresh` already
# runs to build the generation) and re-stats every one of them in a SINGLE
# batched call (`_board_transcript_fingerprint`), on every read. That is real
# O(files) work, but it is `find` + `stat` ONLY — no file is opened, no line
# is parsed. #62's actual cost was PARSING (a title/recap read, a rate-limit
# scan) on every frame; stat never did that. Measured on this host: a single
# `find … -exec stat … {} +` batch over 5,000 transcripts runs in well under
# 30ms (round-6 fix review's own number — see this file's round-6 header for
# why an EARLIER implementation of this same idea cost far more than that).
# The bounded per-file READING cache (reading_cache.sh) is untouched — that
# is where the 12x speedup came from, and round-6's incremental rebuild (see
# this file's own header) is what keeps a rebuild from re-running it over
# every file just because the fingerprint changed.
#
# Superseded by this and deleted outright (see git history for rounds 1-4's
# versions): the per-project top-K recorded-file set, the `-mmin -300`
# recorded-file set it replaced, codex's day/month/year scan-root chain, and
# every per-engine "scan root" mtime signal. All of them existed only to
# approximate "did anything change under this tank" without paying a full
# list+stat — which is exactly what `_board_transcript_fingerprint` below now
# does directly, so there is nothing left for them to approximate.
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

# _board_engine_root/_board_engine_name <engine> <dir> -> the one `find` root
# and `-name` glob a transcript tree lives under, factored out so
# `_board_transcript_find` is the ONLY place that ever spells out an engine's
# directory layout — `_board_transcript_paths` (a plain listing) and
# `_board_stat_rows` (round-6 fix review's batched fingerprint source) must
# never drift onto two different trees for the same engine.
_board_engine_root() {
  case "$1" in
    claude) printf '%s/projects' "$2" ;;
    codex) _codex_sessions_dir "$2" ;;
    grok) printf '%s/sessions' "$2" ;;
    antigravity) printf '%s/antigravity-cli/brain' "$2" ;;
  esac
}
_board_engine_name() {
  case "$1" in
    claude) printf '*.jsonl' ;;
    codex) printf 'rollout-*.jsonl' ;;
    grok) printf 'summary.json' ;;
    antigravity) printf 'transcript.jsonl' ;;
  esac
}

# _board_transcript_find <engine> <dir> [find-args...] -> runs the ONE `find`
# this engine's whole tank uses, with any extra args (e.g. `-exec … +`)
# appended after the name filter. `2>/dev/null` here only ever hides "no such
# directory" for an engine this tank has never used (round-6 fix review: it
# is NOT hiding a `stat` argv failure — `-exec … {} +` batches its own argv,
# so that failure mode no longer exists; see this file's own header).
_board_transcript_find() {
  local engine="$1" dir="$2" root; shift 2
  root="$(_board_engine_root "$engine" "$dir")"
  case "$engine" in
    grok) find "$root" -maxdepth 3 -type f -name "$(_board_engine_name "$engine")" "$@" 2>/dev/null ;;
    *) find "$root" -type f -name "$(_board_engine_name "$engine")" "$@" 2>/dev/null ;;
  esac
}

# _board_transcript_paths <engine> <dir> -> every transcript file under this
# WHOLE tank, one per line — the entire account, not scoped to $PWD, and NOT
# filtered (claude's `agent-*.jsonl` subagent transcripts are included: a
# limit can land in one of those with no matching write to its parent
# session — round-5 fix review P2-2).
_board_transcript_paths() {
  _board_transcript_find "$1" "$2"
}

# _board_stat_rows <engine> <dir> -> sorted "<mtime_ns>\037<size>\037<path>"
# lines for every transcript this tank has, right now — ONE `find … -exec
# stat … {} +` (round-6 fix review P1-1/P2-1). `-exec … {} +` batches its own
# argv per the target's real ARG_MAX, so this can never E2BIG no matter how
# many files match, and nothing here ever pulls a path into a bash variable:
# `find` hands its batches straight to `stat`, `stat`'s own output goes
# straight into `sort`. `board_state_refresh` reuses these exact rows as its
# per-file manifest (round-6 header) instead of re-listing the tree a second
# time.
_board_stat_rows() {
  local engine="$1" dir="$2"
  _clikae_statv
  if [ "$_CLIKAE_STAT_FMT" = '%Y %n' ]; then
    _board_transcript_find "$engine" "$dir" -exec stat -c $'%.9Y\037%s\037%n' {} +
  else
    _board_transcript_find "$engine" "$dir" -exec stat -f $'%Fm\037%z\037%N' {} +
  fi | LC_ALL=C sort
}

# _board_transcript_fingerprint <engine> <dir> -> a `cksum` over
# `_board_stat_rows`. Equality between this, recomputed on every read, and
# what `board_state_refresh` last recorded IS the entire staleness signal for
# every engine (round-5 fix review design decision — see this file's own
# header).
_board_transcript_fingerprint() {
  _board_stat_rows "$1" "$2" | cksum
}

# board_stale <engine> <dir> <generation-path> -> success (0) when the
# published generation no longer matches what is on disk for this tank.
# ONE signal, for every engine: `_board_transcript_fingerprint` re-lists and
# re-stats every transcript this tank has, right now, and the result is
# compared for EQUALITY against what `board_state_refresh` recorded at
# publish — never ">" against a wall-clock stamp, since a fixture (or a
# clock skew) that dates a file into the future is a legitimate, existing
# pattern in this repo's own tests (touch -t past the current year, to force
# a deterministic "newest" without racing other fixtures' timestamps), and
# ">" against `updated` would read every such file as permanently stale,
# forever re-triggering a rebuild each read. See this file's own header for
# why a full re-list/re-stat, on every read, is the design here rather than
# one more bounded approximation.
board_stale() {
  local engine="$1" dir="$2" gen="$3" saved cur
  [ -f "$gen/updated" ] || return 0
  [ -f "$gen/transcripts-fp" ] || return 0
  IFS= read -r saved < "$gen/transcripts-fp"
  cur="$(_board_transcript_fingerprint "$engine" "$dir")"
  [ "$cur" = "$saved" ] || return 0
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
  # Rows are "<display-mt>\037<sid>" on disk — the mtime is whole-second
  # (home.sh's `_human_age` does bash integer arithmetic on it). round-5 fix
  # review: this used to carry two more fields (a nanosecond mtime + size)
  # for board_stale's OWN per-file comparison — dropped along with that
  # signal (superseded by the single whole-tank fingerprint; see this file's
  # own header), since nothing reads them anymore.
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

# _board_merge_recent_row <gen> <scope> <sid> <mt> <n> -> folds ONE fresh
# "<mt>\037<sid>" row into "$gen/recent/<key(scope)>": drops any existing row
# for the SAME sid (a session that already had a resume row and just got a
# newer mtime must not appear twice), appends the fresh row, re-sorts by
# mtime and re-caps to <n>. The "rest of the scope" it merges against is
# whatever `board_state_refresh` already copied forward from the previous
# generation for this key — bounded by <n>+1 lines regardless of tank size,
# which is what keeps one call to this function O(1) rather than O(scope
# size) (round-6 fix review P1-2). A file whose mtime moves BACKWARD (a
# restored/backdated fixture — board_stale's own header already treats this
# as an accepted, existing pattern) can in principle leave an unrelated,
# previously-uncapped session invisible; nothing here re-derives full scope
# membership to cover that narrow case.
_board_merge_recent_row() {
  local gen="$1" scope="$2" sid="$3" mt="$4" n="$5" key base hdr rmt rsid
  key="$(board_key "$scope")"
  base="$gen/recent/$key"
  local -a rows=()
  if [ -f "$base" ]; then
    IFS= read -r hdr < "$base"
    while IFS=$'\037' read -r rmt rsid; do
      [ -n "$rsid" ] || continue
      [ "$rsid" = "$sid" ] && continue
      rows+=("$rmt"$'\037'"$rsid")
    done < <(tail -n +2 "$base")
  else
    hdr="#scope"$'\037'"$scope"
  fi
  rows+=("$mt"$'\037'"$sid")
  {
    printf '%s\n' "$hdr"
    printf '%s\n' "${rows[@]}" | sort -t$'\037' -k1,1rn | head -n "$n"
  } > "$base"
}

# _board_purge_recent_row <gen> <scope> <sid> -> drops <sid>'s row from
# "$gen/recent/<key(scope)>" — for a file removed since the previous
# generation (board_find already treats a missing target as a miss, see its
# own header, but a stale row copied forward into `recent/` would keep
# LISTING a deleted session until something else in the same scope changed).
_board_purge_recent_row() {
  local gen="$1" scope="$2" sid="$3" key base hdr
  key="$(board_key "$scope")"
  base="$gen/recent/$key"
  [ -f "$base" ] || return 0
  IFS= read -r hdr < "$base"
  { printf '%s\n' "$hdr"; tail -n +2 "$base" | awk -F$'\037' -v s="$sid" '$2 != s'; } \
    > "$base.tmp" && mv -f "$base.tmp" "$base"
}

# _board_engine_sidscope <engine> <path> <-A _agy_ws nameref-by-convention> ->
# echoes "<sid>\037<scope>" for a non-agent transcript, nothing for a path
# that yields no sid (agy adapter hook missing, malformed meta, …). The ONE
# place that spells out how each engine's sid/scope come out of a PATH or a
# file's own CONTENT — `board_state_refresh` calls this only for a file it
# has already decided needs a fresh parse (new, changed, or a cold build),
# never for one it can carry forward unchanged (round-6 fix review P1-2).
_board_engine_sidscope() {
  local engine="$1" f="$2" sid="" scope=""
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
  [ -n "$sid" ] || return 0
  printf '%s\037%s' "$sid" "${scope%/}"
}

board_state_refresh() (
  # Subshell isolates adapter hooks, umask and board-mode overrides from caller.
  local engine="$1" dir="$2" root gen oldgen oldname pointer f mt sid scope key count=0
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

  # round-6 fix review P1-2: the generation this call is about to SUPERSEDE
  # is the carry-forward source everything below reads from — captured
  # before `mktemp -d` so a concurrent reader's `current` pointer stays
  # valid until this whole rebuild finishes and is published atomically. No
  # usable manifest (never refreshed before, or an older pre-round-6
  # generation) is treated exactly like no previous generation at all: a
  # cold build.
  oldgen=""
  if [ -f "$root/current" ]; then
    oldname=""
    IFS= read -r oldname < "$root/current"
    case "$oldname" in generation.*) [ -d "$root/$oldname" ] && oldgen="$root/$oldname" ;; esac
  fi
  [ -n "$oldgen" ] && [ -f "$oldgen/manifest" ] || oldgen=""

  gen="$(mktemp -d "$root/generation.XXXXXX")" || return 0
  mkdir -p "$gen/recent" "$gen/sids"

  # A file's rate-limit reading is independent of its sid/scope. `window` is
  # the ONLY per-engine knob the rest of this function needs for it.
  local window="" kind="" parser="" reading_now=""
  case "$engine" in
    claude) window=$((300 * 60)); kind=claude-usage; parser=_limit_claude_reading ;;
    codex) window=$((10080 * 60)); kind=codex-dry; parser=_limit_codex_reading ;;
  esac
  [ -z "$window" ] || reading_now="$(date +%s)"

  # round-6 fix review P1-1/P2-1: ONE batched stat pass — `_board_stat_rows`
  # is a single `find … -exec stat … {} +`, no bash loop of its own — is
  # both the staleness fingerprint and, below, the ONLY listing of this
  # tank's files this function ever does. No second `find` anywhere here.
  local stat_rows
  stat_rows="$(_board_stat_rows "$engine" "$dir")"
  printf '%s\n' "$stat_rows" | cksum > "$gen/transcripts-fp"
  date +%s > "$gen/updated"

  # P2-2 (2026-09-12 round-3 fix review): antigravity's cwd lives IN the
  # file, not the path, so a sid/scope lookup below scans the WHOLE
  # account's sessions, never just this PWD's — and used to pay one
  # reading_cache_run + fork pipeline PER session for that (measured ~5s
  # fixed on a synthetic 500-session tank). One bulk index read replaces
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

  if [ -z "$oldgen" ]; then
    # Cold build (or a fully-invalidated generation): every file is new, so
    # there is nothing to diff against — one plain listing pass, one sort of
    # the mtimes it already collected, one reading-fold pass, same shape as
    # before this round's carry-forward machinery existed (which only pays
    # for itself once there IS a previous generation to reuse). Sorted
    # in-process from `cur_mtime` rather than a second `sessions_by_mtime
    # "${paths[@]}"` call: that call's own argv is exactly the P1-1 ARG_MAX
    # exposure this round fixed for the fingerprint, and a cold build is the
    # shape most likely to have a huge `paths` count in the first place.
    local -a all_files=() paths=() manifest_lines=() reading_lines=()
    local -A cur_mtime=() cur_size=() sid_of=() scope_of=() reading_of=()
    local mtv szv fpv age mtsec val sidscope
    while IFS=$'\037' read -r mtv szv fpv; do
      [ -n "$fpv" ] || continue
      count=$((count + 1))
      all_files+=("$fpv")
      cur_mtime["$fpv"]="$mtv"; cur_size["$fpv"]="$szv"
      case "${fpv##*/}" in agent-*) ;; *) paths+=("$fpv") ;; esac
    done <<< "$stat_rows"
    printf '%s\n' "$count" > "$gen/count"
    if [ "${#paths[@]}" -gt 0 ]; then
      while read -r mt f; do
        [ -f "$f" ] || continue
        sidscope="$(_board_engine_sidscope "$engine" "$f")"
        [ -n "$sidscope" ] || continue
        sid="${sidscope%%$'\037'*}"; scope="${sidscope#*$'\037'}"
        sid_of["$f"]="$sid"; scope_of["$f"]="$scope"
        key="$(board_key "$sid")"
        printf '%s\n%s\n' "$sid" "$f" > "$gen/sids/$key"
        key="$(board_key "$scope")"
        [ -f "$gen/recent/$key.all" ] || printf '#scope\037%s\n' "$scope" > "$gen/recent/$key.all"
        printf '%s\037%s\n' "$mt" "$sid" >> "$gen/recent/$key.all"
      done < <(
        for f in "${paths[@]}"; do printf '%s %s\n' "${cur_mtime[$f]%%.*}" "$f"; done \
          | LC_ALL=C sort -k1,1rn
      )
      for f in "$gen"/recent/*.all; do
        [ -f "$f" ] || continue
        head -n "$((n + 1))" "$f" > "${f%.all}"
        rm -f "$f"
      done
    fi
    if [ -n "$window" ]; then
      for f in "${all_files[@]}"; do
        mtsec="${cur_mtime[$f]%%.*}"
        age=$((reading_now - mtsec))
        [ "$age" -lt "$window" ] || continue
        if declare -F reading_cache_run >/dev/null; then
          val="$(reading_cache_run "$kind" "$f" "$parser" "$f")"
        else
          val="$("$parser" "$f")"
        fi
        reading_of["$f"]="$val"
        reading_lines+=("$val")
      done
      printf '%s\n' "${reading_lines[@]}" | awk -F $'\037' '
        $1 > l { l = $1; r = $3 }
        $2 > s { s = $2 }
        END { printf "%s\037%s\037%s\n", l, s, r }
      ' > "$gen/$([ "$engine" = claude ] && printf claude-usage || printf codex-dry)"
    fi
    for f in "${all_files[@]}"; do
      manifest_lines+=("${cur_mtime[$f]}"$'\036'"${cur_size[$f]}"$'\036'"${sid_of[$f]-}"$'\036'"${scope_of[$f]-}"$'\036'"${reading_of[$f]-}"$'\036'"$f")
    done
    [ "${#manifest_lines[@]}" -eq 0 ] || printf '%s\n' "${manifest_lines[@]}" > "$gen/manifest"
  else
    # Incremental rebuild (round-6 fix review P1-2): a previous generation's
    # manifest exists, so the only work that has to be proportional to the
    # WHOLE tank is deciding what changed — and that decision is delegated
    # to ONE awk pass over both manifests (old, sorted by path in the OLD
    # `stat_rows` order; new, from THIS refresh's `stat_rows`) instead of a
    # bash `while read` loop building associative arrays keyed by path. Bash
    # native loops over 5,000+ lines cost ~100-200ms EACH (measured, this
    # round); awk does the equivalent set comparison in single-digit ms. The
    # three outputs are themselves small, seekable files:
    #   unchanged — already-final manifest LINES for a file whose (mtime,
    #     size) still matches (its reading field is blanked if it has aged
    #     out of `window` since — the fold below must not go on counting a
    #     genuinely-expired reading forever just because the file itself
    #     never changed again).
    #   changed   — "<mtime>\037<size>\037<path>" for a new or modified
    #     file: the ONLY paths that pay a fresh sid/scope parse or a fresh
    #     reading_cache_run below, so this function's real cost is now
    #     proportional to CHANGED files, not files present.
    #   removed   — "<path>\037<sid>\037<scope>" for a file gone missing
    #     since the previous generation, so its stale sids/recent entry can
    #     be purged (see _board_purge_recent_row's own header) without this
    #     function ever loading the old manifest into a bash hashtable.
    local unchanged_f="$gen/.manifest-unchanged" changed_f="$gen/.manifest-changed" removed_f="$gen/.manifest-removed"
    local d6 d7
    d6=$'\036'; d7=$'\037'
    awk -v OFS="$d6" -v FS7="$d7" -v now="${reading_now:-0}" -v window="${window:-0}" \
        -v unchanged_out="$unchanged_f" -v changed_out="$changed_f" -v removed_out="$removed_f" '
      FNR==NR {
        if (split($0, f, OFS) < 6) next
        path = f[6]
        om[path] = $0
        omt[path] = f[1]; osz[path] = f[2]
        next
      }
      {
        if (split($0, f, FS7) < 3) next
        mt = f[1]; sz = f[2]; path = f[3]
        if (path == "") next
        cur[path] = 1
        if ((path in omt) && omt[path] == mt && osz[path] == sz) {
          line = om[path]
          if (window != 0 && (now - int(mt)) >= window) {
            split(line, g, OFS)
            line = g[1] OFS g[2] OFS g[3] OFS g[4] OFS "" OFS g[6]
          }
          print line > unchanged_out
        } else {
          print mt FS7 sz FS7 path > changed_out
        }
      }
      END {
        for (p in om) if (!(p in cur)) { split(om[p], g, OFS); print p FS7 g[3] FS7 g[4] > removed_out }
      }
    ' "$oldgen/manifest" <(printf '%s\n' "$stat_rows")

    count=0
    [ -f "$unchanged_f" ] && count=$((count + $(wc -l < "$unchanged_f")))
    [ -f "$changed_f" ] && count=$((count + $(wc -l < "$changed_f")))
    printf '%s\n' "$count" > "$gen/count"

    # `sids/` and `recent/` start as an exact copy of the previous
    # generation — one `cp -al` (hard link, not a data copy; both
    # directories are removed independently later by
    # `board_gc_generations`, which only ever unlinks a NAME, so sharing the
    # underlying inode across generations is safe — same reasoning as this
    # file's own note on deleting a generation a concurrent reader still
    # holds a path into) — and are only touched below for the sid/scope a
    # changed or removed file actually affects. `-l` is a option both GNU
    # and BSD/macOS `cp` accept (unlike the GNU-only `--reflink`), so this
    # needs no platform branch.
    [ -d "$oldgen/sids" ] && cp -al "$oldgen/sids/." "$gen/sids/" 2>/dev/null
    [ -d "$oldgen/recent" ] && cp -al "$oldgen/recent/." "$gen/recent/" 2>/dev/null

    local -a manifest_lines=() reading_lines=()
    local mtv szv fpv age mtsec val sidscope
    if [ -f "$changed_f" ]; then
      while IFS=$'\037' read -r mtv szv fpv; do
        [ -n "$fpv" ] || continue
        sid=""; scope=""; val=""
        case "${fpv##*/}" in
          agent-*) : ;; # no sid/scope for subagent transcripts
          *)
            sidscope="$(_board_engine_sidscope "$engine" "$fpv")"
            if [ -n "$sidscope" ]; then
              sid="${sidscope%%$'\037'*}"; scope="${sidscope#*$'\037'}"
              key="$(board_key "$sid")"
              # P3-2: the sid itself is written back so a reader (board_find,
              # board_stale) can verify it — a 32-bit cksum collision then
              # reads as a miss, never someone else's transcript.
              printf '%s\n%s\n' "$sid" "$fpv" > "$gen/sids/$key"
              mt="${mtv%%.*}"
              _board_merge_recent_row "$gen" "$scope" "$sid" "$mt" "$n"
            fi
            ;;
        esac
        if [ -n "$window" ]; then
          mtsec="${mtv%%.*}"
          age=$((reading_now - mtsec))
          if [ "$age" -lt "$window" ]; then
            if declare -F reading_cache_run >/dev/null; then
              val="$(reading_cache_run "$kind" "$fpv" "$parser" "$fpv")"
            else
              val="$("$parser" "$fpv")"
            fi
            reading_lines+=("$val")
          fi
        fi
        manifest_lines+=("$mtv"$'\036'"$szv"$'\036'"$sid"$'\036'"$scope"$'\036'"$val"$'\036'"$fpv")
      done < "$changed_f"
    fi
    {
      [ ! -f "$unchanged_f" ] || cat "$unchanged_f"
      [ "${#manifest_lines[@]}" -eq 0 ] || printf '%s\n' "${manifest_lines[@]}"
    } > "$gen/manifest"
    if [ -n "$window" ]; then
      {
        printf '%s\n' "${reading_lines[@]}"
        [ ! -f "$unchanged_f" ] || cut -d$'\036' -f5 "$unchanged_f" 2>/dev/null
      } | awk -F $'\037' '
        $0 == "" { next }
        $1 > l { l = $1; r = $3 }
        $2 > s { s = $2 }
        END { printf "%s\037%s\037%s\n", l, s, r }
      ' > "$gen/$([ "$engine" = claude ] && printf claude-usage || printf codex-dry)"
    fi

    # A file gone missing since the previous generation must not go on
    # answering for a session that no longer exists — see
    # _board_purge_recent_row's own header.
    if [ -f "$removed_f" ]; then
      local rsid rscope rkey
      while IFS=$'\037' read -r _ rsid rscope; do
        [ -n "$rsid" ] || continue
        rkey="$(board_key "$rsid")"
        rm -f "$gen/sids/$rkey"
        _board_purge_recent_row "$gen" "$rscope" "$rsid"
      done < "$removed_f"
    fi
    rm -f "$unchanged_f" "$changed_f" "$removed_f"
  fi

  case "$engine" in
    antigravity) agy_email "$dir" > "$gen/email" ;;
    codex) _limit_codex_rate_limits_cached "$dir" "$root/codex-cache" > "$gen/codex-usage" || true ;;
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
