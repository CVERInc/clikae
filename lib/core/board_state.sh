# shellcheck shell=bash
# Tree discovery belongs to session boundaries. Renders consume immutable,
# per-tank generations through an atomically replaced pointer. A missing index
# is an unknown reading, never permission to PARSE a transcript tree on a frame.
#
# 2026-09-13 round-5 fix review — DESIGN DECISION (closing the round-1..4
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
# batched call (`_board_stat_fingerprint`), on every read. That is real
# O(files) work, but it is `find` + `stat` ONLY — no file is opened, no line
# is parsed. #62's actual cost was PARSING (a title/recap read, a rate-limit
# scan) on every frame; stat never did that. Measured on this host: the raw
# `find`+`stat` forks over 500 transcripts run in well under 50ms (see
# REPORT-board62-fix5.md for the number and for why the FULL freshness check
# costs somewhat more than that — bash's own per-line loop building the file
# list, not the stat syscall itself).
# The bounded per-file READING cache (reading_cache.sh) is untouched — that
# is where the 12x speedup came from, and nothing about staleness detection
# changes what gets parsed once a rebuild is actually triggered.
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

# _board_transcript_paths <engine> <dir> -> every transcript file under this
# WHOLE tank, one per line — the entire account, not scoped to $PWD, and NOT
# filtered (claude's `agent-*.jsonl` subagent transcripts are included: a
# limit can land in one of those with no matching write to its parent
# session — round-5 fix review P2-2). This is the identical `find` per engine
# that `board_state_refresh` already runs to build a generation; `board_stale`
# runs it again, unchanged, to answer "did anything change" (see this file's
# own header).
_board_transcript_paths() {
  local engine="$1" dir="$2"
  case "$engine" in
    claude) find "$dir/projects" -type f -name '*.jsonl' 2>/dev/null ;;
    codex) find "$(_codex_sessions_dir "$dir")" -type f -name 'rollout-*.jsonl' 2>/dev/null ;;
    grok) find "$dir/sessions" -maxdepth 3 -type f -name summary.json 2>/dev/null ;;
    antigravity) find "$dir/antigravity-cli/brain" -type f -name transcript.jsonl 2>/dev/null ;;
  esac
}

# _board_stat_fingerprint <path>... -> one opaque line ("<count> <crc> <bytes>")
# summarizing every arg's identity: how many there were, plus a CRC over one
# batched `stat` call's own raw output (path, mtime_ns, size per line),
# sorted first so argument ORDER never affects the result (`find`'s own
# order is not guaranteed stable run to run). Deliberately never touches a
# bash associative array: piping `stat`'s output straight into `sort`/`cksum`
# avoids a 500-plus-iteration `while read` loop per call, which measured as
# the actual cost on this host — the `stat`/`find` FORKS themselves are a few
# ms each for 500 files; a bash-level loop over each line is not (round-5 fix
# review's own perf receipt — see REPORT-board62-fix5.md).
_board_stat_fingerprint() {
  _clikae_statv
  {
    printf '%s\n' "$#"
    if [ "$#" -gt 0 ]; then
      if [ "$_CLIKAE_STAT_FMT" = '%Y %n' ]; then
        stat -c $'%.9Y\037%s\037%n' "$@" 2>/dev/null
      else
        stat -f $'%Fm\037%z\037%N' "$@" 2>/dev/null
      fi | sort
    fi
  } | cksum
}

# _board_transcript_fingerprint <engine> <dir> -> `_board_stat_fingerprint`
# over a FRESH listing of every transcript this tank has, right now — one
# `find` plus one batched `stat`. Equality between this, recomputed on every
# read, and what `board_state_refresh` last recorded IS the entire staleness
# signal for every engine (round-5 fix review design decision — see this
# file's own header).
_board_transcript_fingerprint() {
  local engine="$1" dir="$2" f
  local -a files=()
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done \
    < <(_board_transcript_paths "$engine" "$dir")
  _board_stat_fingerprint "${files[@]}"
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
  files="$(_board_transcript_paths "$engine" "$dir")"
  local -a paths=() all_files=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    count=$((count + 1))
    all_files+=("$f")
    case "${f##*/}" in agent-*) continue ;; esac
    paths+=("$f")
  done <<< "$files"
  printf '%s\n' "$count" > "$gen/count"
  # P2-2 (2026-09-12 round-3 fix review): antigravity's cwd lives IN the
  # file, not the path, so this loop below scans the WHOLE account's
  # sessions, never just this PWD's — and used to
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
  # This IS board_stale's entire freshness signal (see this file's own
  # header and board_stale's) — every transcript this tank has (`all_files`,
  # including `agent-*.jsonl` — `paths` below excludes those, since they are
  # not real sessions to list in Resume), right now, reduced to one opaque
  # line via one batched `stat`.
  _board_stat_fingerprint "${all_files[@]}" > "$gen/transcripts-fp"
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
      scope="${scope%/}"
      key="$(board_key "$scope")"
      # Same guard on the scope: a fresh recent/<key>.all gets the raw scope
      # as its own first line, verified back by board_recent/board_stale.
      [ -f "$gen/recent/$key.all" ] || printf '#scope\037%s\n' "$scope" > "$gen/recent/$key.all"
      # "<display-mt>\037<sid>" — $mt (whole-second, sessions_by_mtime's own
      # sort key) is the DISPLAY value board_recent hands to callers
      # unchanged. round-5 fix review: this row used to carry two more
      # fields for board_stale's OWN per-file comparison — dropped along
      # with that signal (see board_recent's own header).
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
      _limit_claude_readings "$files" > "$gen/claude-usage"
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
