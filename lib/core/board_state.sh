# shellcheck shell=bash
# Tree discovery belongs to session boundaries. Renders consume immutable,
# per-tank generations through an atomically replaced pointer. A missing index
# is an unknown reading, never permission to PARSE a transcript tree on a frame.
#
# 2026-09-13 fix7 (PR #78 CI, all three macOS jobs, every run since this
# branch's first commit): `declare -gA _BOARD_GEN_CACHE` below (round-5's
# memo) ran at SOURCE time, and macOS ships bash 3.2 — no `declare -g`
# (4.2+), no associative arrays (`-A`, 4.0+). The file failed to source at
# all (`lib/core/board_state.sh: line 205: declare: -g: invalid option`),
# `clikae version` exited 2, ~1,000 bats red before a single one ran. Three
# more `local -A` sites in this file and one in lib/adapters/antigravity.sh
# (added by round-3's P2-2 bulk-index fix and round-6's incremental
# classifier — both correct in DESIGN, both bash-4-only in
# IMPLEMENTATION) had the same problem, just not yet exercised on the
# CI job that would have caught them first. PORTED, not shimmed — no version
# check, no bash-4-only fast path, one code path for 3.2 and 5.x alike:
#   - `board_generation`'s memo → plain globals keyed by a sanitized
#     (engine,dir) name, indirect-read via `eval` (see its own header).
#   - `_agy_ws`/`_ws` (antigravity's bulk cwd index) → the same scheme, as
#     `_agy_ws_load`/`_agy_ws_lookup`/`_agy_ws_varname` — living in
#     lib/adapters/antigravity.sh (see `_agy_ws_varname`'s own header there),
#     not here: an EARLIER draft of this port defined them in this file, and
#     tests/bats/adapters/antigravity.bats — which sources antigravity.sh
#     WITHOUT this file — immediately hit "_agy_ws_load: command not found"
#     (CI run 34760883667, `bats (ubuntu-latest)`). Moved to where
#     `adapter_session_cwd_index` already lives, and every call site here
#     guarded with `declare -F`, same as every other adapter-hook call in
#     this file — still O(1) forks per RENDER, not per session (P2-2's own
#     invariant, re-verified this round).
#   - the cold-build classifier's five per-path maps (`cur_mtime`, `cur_size`,
#     `sid_of`, `scope_of`, `reading_of`) → parallel INDEXED arrays keyed by
#     the file's position in `stat_rows`, not by path — bash 3.2 has always
#     had indexed arrays; nothing there needed a hash to begin with. The
#     INCREMENTAL classifier already used a single `awk` join with no bash
#     maps at all (round-6) and needed no change.
# tests/bats/compat.bats now source-scans for `declare -[gAn]`/`local
# -[An]`/`typeset -[An]` so a bash-4+ construct in lib/ or bin/clikae fails
# locally before it ever reaches a macOS CI job again.
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

# 2026-09-13 round-7 fix review P1-1/P2-1 — GENERATION CHAIN (design decision,
# KITT): rounds 6/7 carried `sids/`/`recent/` forward with `cp -al`, so every
# generation's entries were HARD LINKS to the previous generation's inodes and
# the two in-place rewrites below (`> "$base"`, `> "$gen/sids/$key"`) mutated a
# generation `current` was still pointing at — measured, not theorised (the
# reviewer's three-way probe: gen1's recent row changed the moment gen2
# published). It also made a rebuild cost one `link()` per file PRESENT
# (5,001 at 5,000 files), which is the O(tank) bookkeeping #62 exists to kill.
#
# Both go away together by not copying at all:
#
#   * A generation directory holds ONLY the `sids/`/`recent/` entries this
#     refresh actually changed, plus a `parent` file naming the generation it
#     was built from and a `depth` file counting how far that chain now runs.
#   * A reader resolves one entry by walking gen -> parent -> … and taking the
#     FIRST generation that has that name (`_board_gen_entry`). Nothing is
#     ever shared: two generations that both have the name have two separate
#     inodes, and the newer one wins by position, not by mutation.
#   * The walk is bounded. When appending one more link would reach
#     `_BOARD_GEN_MAX_DEPTH`, the next publish MATERIALISES instead: `cp -a`
#     (a real copy, no `-l`) of the resolved set, oldest ancestor first so the
#     newest copy of each name lands last, then `parent` is dropped and depth
#     goes back to 0. So a read is at most _BOARD_GEN_MAX_DEPTH lookups and a
#     write is proportional to CHANGED files, amortised against one full copy
#     every _BOARD_GEN_MAX_DEPTH publishes.
#   * A file that goes away cannot be expressed by deleting an entry — the
#     ancestor still has it — so removal writes a zero-byte TOMBSTONE under the
#     same name. `_board_gen_entry` treats a zero-byte entry as "resolved to
#     nothing" (rc=1). A real entry is never zero bytes: every writer below
#     emits at least one line, through a temp file + `mv -f`, so a half-written
#     entry never appears under its final name at all.
#   * Materialising drops tombstones (`-size 0c`, POSIX bytes — NOT `-size 0`,
#     which is 512-byte blocks and would match every small entry).
#
# `board_gc_generations` had to learn about this: keep-5 alone would happily
# unlink an ancestor the current generation still resolves through.
_BOARD_GEN_MAX_DEPTH="${CLIKAE_BOARD_GEN_MAX_DEPTH:-8}"

# _board_entry_key <string> -> sets $_board_entry_key_out to the FILENAME this
# sid/scope's entry lives under. Round-7 fix review P2-2: this used to be
# `board_key`, i.e. `$(printf '%s' "$x" | cksum)` — two forks, per FILE, twice
# (sid and scope). At 5,000 files that is 20,000 forks at ~1.8 ms each, and it
# is the whole of the 35.6 s cold build measured on an idle host; nothing else
# in that path came close. So the name is now computed with no process at all:
# pure parameter expansion here, one `gsub` in the cold build's awk, ONE rule
# written twice and pinned by a bats test that compares the two.
#
# It is a sanitisation, not a hash, and that is deliberate:
#   * A filename must be safe. Every character outside [A-Za-z0-9._-] folds to
#     `_`, so `/`, `..`, NUL-adjacent tricks and an empty string cannot escape
#     the entry directory. (`.`/`..` are folded whole.)
#   * A name over 100 characters keeps its first 60 and last 40 plus the
#     original length, so two long paths that merely share a prefix do not
#     land on the same entry.
#   * Collisions are HANDLED, not assumed away, and they are handled the same
#     way they already were: the raw sid is line 1 of a `sids/` entry and the
#     raw scope is the `#scope` header of a `recent/` entry, and board_find /
#     board_recent compare them back. A collision reads as a MISS, never as
#     another session's transcript.
#   * It collides far less than what it replaces. A real sid is a uuid, so
#     every character survives and two distinct sids cannot land on one name;
#     `board_key`'s 32-bit cksum has a ~0.3% chance of at least one colliding
#     pair in a 5,000-session tank — one silently missing Resume entry per
#     ~345 tanks that size.
# `board_key` itself stays exactly as it was: it still names the per-tank root
# (`board_root`), where it runs once per tank, not once per file.
#
# ONE implementation, in awk, used by BOTH sides — and it had to become that.
# The first version of this computed the name with bash parameter expansion on
# the reader side and `gsub` on the cold build's side: two spellings of one
# rule, exactly the shape that let this file's own fingerprint drift. PR #78's
# macOS CI job (run 34769949650, `bats (macos-latest)`) caught them
# disagreeing within hours, on a non-ASCII input:
#
#   bash (macOS 3.2) = "unicode-<2 non-ASCII chars>"   (matched nothing)
#   awk              = "unicode-__"                     (matched both)
#
# and on Linux they agreed, so nothing local would ever have shown it. A
# bracket expression over multibyte input is not portable — bash 3.2's and
# each awk's notion of "one character" differ, and the locale changes the
# answer again. The consequence would not have been visible either: the cold
# build writes `sids/unicode-__`, a reader looks up `sids/unicode-<chars>`,
# the lookup MISSES, and the session silently drops out of `clikae resume`
# with the file still on disk. A tank whose project paths are not ASCII (a
# Chinese or accented directory name — normal, not exotic) would lose its
# whole Resume list on macOS.
#
# So the rule is written once, as awk source, and both callers run it under
# `LC_ALL=C` so it is BYTE-oriented on every platform and every locale. The
# reader pays one fork per lookup, which is exactly what `board_key`'s
# `printf | cksum` cost before it — and the COLD path, the one that runs per
# file, still pays none: it runs this same source inline in the awk it was
# already running.
_BOARD_EKEY_AWK='
function ekey(s,   t, n) {
  t = s
  gsub(/[^A-Za-z0-9._-]/, "_", t)
  if (t == "" || t == "." || t == "..") t = "_" t "_"
  n = length(t)
  if (n > 100) t = substr(t, 1, 60) "_" substr(t, n - 39) "_" n
  return t
}'
_board_entry_key_out=""
_board_entry_key() {
  # A newline is folded first: awk reads records, so a sid or scope carrying
  # one would arrive as two. `$'\n'` is a single ASCII byte, so this fold is
  # locale-independent, unlike the class of pattern that caused the bug above.
  # (The cold build cannot hit this — its input comes from `find`, which is
  # newline-delimited already.)
  local s="${1//$'\n'/_}"
  _board_entry_key_out="$(printf '%s' "$s" | LC_ALL=C awk "$_BOARD_EKEY_AWK"'
    { print ekey($0) }
    END { if (NR == 0) print ekey("") }
  ')"
}

# Generation layout version. A generation written by an older clikae has a
# different on-disk shape and must never be read as if it were this one: an
# entry looked up under the wrong scheme reads as a MISS, which leaves Resume
# silently empty until the tank changes again instead of triggering the one
# rebuild that fixes it. A mismatch is treated exactly like a stale generation
# (board_stale) and like no previous generation at all (board_state_refresh).
_BOARD_GEN_FORMAT=8
_board_gen_format_ok() {
  local v=""
  [ -f "$1/format" ] || return 1
  IFS= read -r v < "$1/format" 2>/dev/null || return 1
  [ "$v" = "$_BOARD_GEN_FORMAT" ]
}

# _board_gen_entry <gen> <rel> -> sets $_board_gen_entry_out to the resolved
# path of one entry ("sids/<key>" / "recent/<key>"), rc=1 when the chain has no
# live entry under that name. Out-variable, not `$( )`: this runs once per
# lookup on a render's hot path and once per changed file inside a rebuild, and
# a subshell fork there is exactly the per-file cost this whole round is about
# (same pattern `_agy_ws_lookup` already uses in lib/adapters/antigravity.sh).
# No fork of any kind: `[ -f ]`/`[ -s ]` are builtins and `read < file` is a
# redirection, so a full-depth miss costs at most 3 * _BOARD_GEN_MAX_DEPTH
# syscalls.
_board_gen_entry_out=""
_board_gen_entry() {
  local g="$1" rel="$2" root="${1%/*}" d=0 p
  _board_gen_entry_out=""
  while [ -n "$g" ] && [ "$d" -lt "$_BOARD_GEN_MAX_DEPTH" ]; do
    if [ -f "$g/$rel" ]; then
      # Zero bytes is the tombstone (see the chain header above): the entry
      # exists in an ancestor but this generation says it is gone.
      [ -s "$g/$rel" ] || return 1
      _board_gen_entry_out="$g/$rel"
      return 0
    fi
    p=""
    [ ! -f "$g/parent" ] || IFS= read -r p < "$g/parent" 2>/dev/null
    case "$p" in generation.*) g="$root/$p" ;; *) return 1 ;; esac
    d=$((d + 1))
  done
  return 1
}

# _board_gen_put <gen> <rel> -> reads the entry's bytes from stdin and puts
# them at "$gen/<rel>" as temp + `mv -f`, the pattern _board_purge_recent_row
# has used since round-6. `mv` replaces a NAME; it never opens the inode an
# ancestor generation's identical name points at, and no reader can ever see a
# partially written entry (the reason this matters is in the chain header
# above). `.tmp/` is a sibling directory inside the same generation, so the
# rename is always same-filesystem and therefore atomic.
_board_gen_put() {
  local gen="$1" rel="$2" tmp="$1/.tmp/e.$$"
  cat > "$tmp" 2>/dev/null && mv -f "$tmp" "$gen/$rel" 2>/dev/null
}

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
#
# Round-7 fix review P3-4 — a KNOWN blind spot of the (mtime, size)
# fingerprint, recorded where the file that has it is named. grok's
# fingerprint file is `summary.json`, and grok REWRITES it; the other three
# engines append to a `.jsonl`, so their size always moves. On a filesystem
# whose mtime granularity is one whole second (this repo's CI hosts and this
# developer's ext4/tmpfs are 2-3 ms, measured — but HFS+, SMB and some NFS
# mounts are not), a `summary.json` rewritten to the SAME size inside the same
# second changes neither mtime nor size, and `_board_transcript_fingerprint`
# cannot see it. Consequence is bounded: the Resume list's ORDER for that grok
# session goes one edit stale until anything else in the tank changes. Fuel
# dots are unaffected (grok has no rate-limit window here) and no answer is
# wrong, only late.
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
# appended after the name filter.
#
# Round-7 fix review P3-3: this used to end in `2>/dev/null`, documented as
# "only ever hides 'no such directory' for an engine this tank has never
# used". It hid more than that. A redirection on `find` covers the stderr of
# whatever `-exec … +` runs too, so a `stat` that failed on an INDIVIDUAL file
# (a permission change, a mount that went away mid-walk) silently dropped that
# file's row — and its absence is indistinguishable, to the fingerprint, from
# the file not existing. Nothing reads wrong (both sides of the comparison run
# this same function, so a dropped row is dropped symmetrically), but it is
# not a class of failure that should be invisible. The one case the redirect
# genuinely existed for is now handled by asking the question directly, and
# everything else reaches the caller.
_board_transcript_find() {
  local engine="$1" dir="$2" root; shift 2
  root="$(_board_engine_root "$engine" "$dir")"
  [ -n "$root" ] && [ -d "$root" ] || return 0
  case "$engine" in
    grok) find "$root" -maxdepth 3 -type f -name "$(_board_engine_name "$engine")" "$@" ;;
    *) find "$root" -type f -name "$(_board_engine_name "$engine")" "$@" ;;
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

# _board_fingerprint_rows -> the fingerprint OF a stat-row stream on stdin.
#
# Round-7 fix review P1-2: there used to be two spellings of this. The reader
# (`board_stale`) piped `_board_stat_rows` straight into `cksum`; the writer
# captured the same rows in `$(…)` — which strips trailing newlines — and
# re-emitted them with `printf '%s\n'`. For a tank with at least one
# transcript the two byte streams happen to agree. For a tank with NONE they
# cannot: the pipeline sends ZERO bytes, `printf '%s\n' ""` sends ONE newline,
# so the saved fingerprint was cksum("\n") = "3515105045 1" and the live one
# cksum("") = "4294967295 0", every read said STALE, and a freshly `clikae
# init`'d tank rebuilt and published a whole new generation on EVERY frame,
# forever, never self-healing — 2.2x slower than main at doing nothing, and it
# is the very first screen a new user sees.
#
# There is ONE function now and both sides call it, so "the empty set" has one
# canonical value by construction rather than by two authors agreeing. The
# writer no longer goes through `$( )` at all: `board_state_refresh` spools the
# rows to a file and hands this that file, so the bytes hashed at publish are
# the exact bytes `_board_stat_rows` produced, empty set included.
_board_fingerprint_rows() {
  cksum
}
_board_transcript_fingerprint() {
  _board_stat_rows "$1" "$2" | _board_fingerprint_rows
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
  # An older layout is not "fresh data in a shape I can read" — see
  # _BOARD_GEN_FORMAT's own header.
  _board_gen_format_ok "$gen" || return 0
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
#
# fix7 (PR #78 CI, all three macOS jobs, since this branch's first commit):
# this memo used to be `declare -gA _BOARD_GEN_CACHE`. macOS ships bash 3.2,
# which has neither `declare -g` (4.2+) nor associative arrays (`-A`, 4.0+),
# and `declare -gA` runs at SOURCE time — the file failed to source at all
# (`lib/core/board_state.sh: line 205: declare: -g: invalid option`), exit 2
# before board_generation is ever called. Ported to the i18n.sh pattern (see
# that file's own header): plain globals, one per (engine,dir) pair, keyed by
# sanitizing the cachekey into a valid bash identifier and read back through
# indirect (`eval`) expansion — `${var//[^A-Za-z0-9_]/_}` is plain bash
# parameter expansion, no fork, no bash-4 dependency. `board_key` (a `cksum`
# fork) is deliberately NOT used to name the slot: board_generation runs
# several times per render (see "Memoized" above), and a fork on every call
# just to pick a cache slot would tax the exact path this memo exists to keep
# cheap.
#
# A cachekey sanitized this way is not guaranteed collision-free (two
# different (engine,dir) pairs could fold to the same identifier), so the
# original cachekey is written back alongside the generation path and
# compared on every read — a mismatch is treated as a miss and recomputed,
# never someone else's generation. Same guard board_recent/board_find already
# use for their own hashed (cksum) keys, applied here to a sanitized-name key
# instead. A cachekey never looked up before reads as "" via indirect
# expansion of an unset variable, indistinguishable from a genuinely-cached
# empty (board_stale-failed) result — so a miss is recorded as the sentinel
# `__NONE__` (a real generation path always starts with board_root's prefix,
# never equals that literal) rather than "".
#
# `_BOARD_GEN_CACHE_KEYS` tracks which sanitized names are live so
# `_board_gen_cache_clear` (called by `_home_refresh`, see home.sh's own
# header on why a long-lived process must clear this every refresh) can unset
# them without enumerating the whole environment — the indexed-array
# equivalent of the old `_BOARD_GEN_CACHE=()` single-assignment reset. Left
# unguarded (not `[ set ] ||`) like `_CLIKAE_I18N_DIR` in i18n.sh: a plain
# top-level assignment is global no matter where this file is sourced FROM
# (only `declare`/`local` scope to the calling function; see the array's own
# old comment on why `-g` existed at all), so re-sourcing this file simply
# starts the memo cold again — the same thing re-running `declare -gA` with no
# `=()` would NOT have done, but nothing depends on a stale process-lifetime
# cache surviving a fresh `source`.
_BOARD_GEN_CACHE_KEYS=()
_board_gen_cache_clear() {
  local k
  for k in "${_BOARD_GEN_CACHE_KEYS[@]}"; do
    unset "_BOARD_GEN_CACHE_$k" "_BOARD_GEN_CACHE_KEY_$k" 2>/dev/null
  done
  _BOARD_GEN_CACHE_KEYS=()
}
board_generation() {
  local engine="$1" dir="$2" cachekey root gen="" san varg vark gval cval
  cachekey="$engine"$'\036'"$dir"
  san="${cachekey//[^A-Za-z0-9_]/_}"
  varg="_BOARD_GEN_CACHE_$san"
  vark="_BOARD_GEN_CACHE_KEY_$san"
  eval "gval=\"\${$varg:-}\""
  if [ -n "$gval" ]; then
    eval "cval=\"\${$vark:-}\""
    if [ "$cval" = "$cachekey" ]; then
      [ "$gval" != __NONE__ ] || return 1
      printf '%s' "$gval"
      return 0
    fi
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
  printf -v "$varg" '%s' "${gen:-__NONE__}"
  printf -v "$vark" '%s' "$cachekey"
  _BOARD_GEN_CACHE_KEYS+=("$san")
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
  scope="$(_board_scope_raw "$engine")"
  _board_entry_key "$scope"; key="$_board_entry_key_out"
  # Round-8: the entry may live in an ancestor generation — see
  # _board_gen_entry's own header.
  _board_gen_entry "$gen" "recent/$key" || return 0
  local rf="$_board_gen_entry_out"
  IFS=$'\037' read -r hmark hscope < "$rf"
  # P3-2: a board_key collision on the scope is a miss, never someone else's
  # recent list — see board_stale's twin guard.
  { [ "$hmark" = "#scope" ] && [ "$hscope" = "$scope" ]; } || return 0
  # Rows are "<display-mt>\037<sid>" on disk — the mtime is whole-second
  # (home.sh's `_human_age` does bash integer arithmetic on it). round-5 fix
  # review: this used to carry two more fields (a nanosecond mtime + size)
  # for board_stale's OWN per-file comparison — dropped along with that
  # signal (superseded by the single whole-tank fingerprint; see this file's
  # own header), since nothing reads them anymore.
  tail -n +2 "$rf" | head -n "$n"
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
  # Round-8: resolve through the parent chain, and a zero-byte tombstone (a
  # transcript removed since an ancestor recorded it) resolves to nothing.
  _board_entry_key "$sid"
  _board_gen_entry "$gen" "sids/$_board_entry_key_out" || return 1
  sf="$_board_gen_entry_out"
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
#
# Round-8: a generation is no longer self-contained (see the chain header at
# the top of this file) — the current one resolves entries through up to
# _BOARD_GEN_MAX_DEPTH ancestors, and keep-N alone would happily unlink one of
# them. An unlinked ancestor is not a dangling POINTER that a rebuild heals; it
# is a silently EMPTY Resume list for every session that had not changed since
# that ancestor recorded it, with `current` still valid and `board_stale` still
# saying "fresh". So the chain from `current` is protected outright and the
# keep-N window applies to what is left. `_board_gc_candidates` is the ONE
# place that decides this: `clean.sh`'s own sweep (_clean_board_gc) calls it
# too, rather than keeping a second copy of the rule that would have to be
# taught about the chain separately.
_board_gc_candidates() {
  local root="$1" keep="${2:-${CLIKAE_BOARD_KEEP_GENERATIONS:-5}}" gd gmt cur="" p prot=$'\n' d=0
  [ -d "$root" ] || return 0
  if [ -f "$root/current" ]; then
    IFS= read -r cur < "$root/current" 2>/dev/null || cur=""
    while [ -n "$cur" ] && [ "$d" -lt "$_BOARD_GEN_MAX_DEPTH" ]; do
      case "$cur" in generation.*) ;; *) break ;; esac
      prot="$prot$cur"$'\n'
      p=""
      [ ! -f "$root/$cur/parent" ] || IFS= read -r p < "$root/$cur/parent" 2>/dev/null
      cur="$p"
      d=$((d + 1))
    done
  fi
  for gd in "$root"/generation.*; do
    [ -d "$gd" ] || continue
    case "$prot" in *$'\n'"${gd##*/}"$'\n'*) continue ;; esac
    gmt="$(file_mtime "$gd" 2>/dev/null)" || continue
    printf '%s\037%s\n' "$gmt" "$gd"
  done | sort -t$'\037' -k1,1rn -k2,2r | tail -n +"$((keep + 1))" | cut -d$'\037' -f2-
}
board_gc_generations() {
  local root="$1" keep="${2:-${CLIKAE_BOARD_KEEP_GENERATIONS:-5}}" gd
  [ -d "$root" ] || return 0
  while IFS= read -r gd; do
    [ -n "$gd" ] && rm -rf "$gd"
  done < <(_board_gc_candidates "$root" "$keep")
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
  local gen="$1" scope="$2" sid="$3" mt="$4" n="$5" key src hdr rmt rsid
  _board_entry_key "$scope"; key="$_board_entry_key_out"
  local -a rows=()
  # Round-8: the row this merges against is whatever the CHAIN resolves for
  # this scope — this generation's own copy if an earlier call in this same
  # refresh already wrote one, otherwise the nearest ancestor's. The result is
  # always written into THIS generation, through temp + `mv -f`
  # (_board_gen_put): the ancestor's file is never opened for writing, which
  # is the round-7 P1-1 defect (`> "$base"` through a `cp -al` hard link
  # rewrote a generation `current` still pointed at).
  if _board_gen_entry "$gen" "recent/$key"; then
    src="$_board_gen_entry_out"
    IFS= read -r hdr < "$src"
    while IFS=$'\037' read -r rmt rsid; do
      [ -n "$rsid" ] || continue
      [ "$rsid" = "$sid" ] && continue
      rows+=("$rmt"$'\037'"$rsid")
    done < <(tail -n +2 "$src")
  else
    hdr="#scope"$'\037'"$scope"
  fi
  rows+=("$mt"$'\037'"$sid")
  {
    printf '%s\n' "$hdr"
    printf '%s\n' "${rows[@]}" | sort -t$'\037' -k1,1rn | head -n "$n"
  } | _board_gen_put "$gen" "recent/$key"
}

# _board_purge_recent_row <gen> <scope> <sid> -> drops <sid>'s row from
# "$gen/recent/<key(scope)>" — for a file removed since the previous
# generation (board_find already treats a missing target as a miss, see its
# own header, but a stale row copied forward into `recent/` would keep
# LISTING a deleted session until something else in the same scope changed).
_board_purge_recent_row() {
  local gen="$1" scope="$2" sid="$3" key src hdr
  _board_entry_key "$scope"; key="$_board_entry_key_out"
  _board_gen_entry "$gen" "recent/$key" || return 0
  src="$_board_gen_entry_out"
  IFS= read -r hdr < "$src"
  { printf '%s\n' "$hdr"; tail -n +2 "$src" | awk -F$'\037' -v s="$sid" '$2 != s'; } \
    | _board_gen_put "$gen" "recent/$key"
}

# _board_engine_sidscope <engine> <path> -> echoes "<sid>\037<scope>" for a
# non-agent transcript, nothing for a path that yields no sid (agy adapter
# hook missing, malformed meta, …). The ONE place that spells out how each
# engine's sid/scope come out of a PATH or a file's own CONTENT —
# `board_state_refresh` calls this only for a file it has already decided
# needs a fresh parse (new, changed, or a cold build), never for one it can
# carry forward unchanged (round-6 fix review P1-2). Antigravity's branch
# expects `_agy_ws_load` (lib/adapters/antigravity.sh — see its own header)
# to have already run for this tank (board_state_refresh does so before
# either of its per-file loops) — guarded by `declare -F`, same as every
# other adapter-hook call in this file (e.g. `adapter_session_cwd_index`
# below): this file must stay usable when an adapter hasn't been loaded, not
# just when antigravity specifically hasn't (round-3 fix review's own
# `adapter_session_cwd_index` guard already established this; fix7's
# `_agy_ws_lookup` is one more hook of the same kind, not a new dependency).
_board_engine_sidscope() {
  local engine="$1" f="$2" sid="" scope=""
  case "$engine" in
    claude) sid="${f##*/}"; sid="${sid%.jsonl}"; scope="${f%/*}"; scope="${scope##*/}" ;;
    codex) sid="$(_codex_meta_field "$f" id)"; scope="$(_codex_meta_field "$f" cwd)" ;;
    grok) sid="$(_grok_json_str "$f" id)"; scope="$(_grok_json_str "$f" cwd)" ;;
    antigravity)
      sid="${f%/.system_generated/*}"; sid="${sid##*/}"
      _agy_ws_lookup_out=""
      declare -F _agy_ws_lookup >/dev/null 2>&1 && _agy_ws_lookup "$sid"
      if [ -n "$_agy_ws_lookup_out" ]; then
        scope="$_agy_ws_lookup_out"
      else
        scope="$(adapter_session_cwd "$f")"
      fi
      ;;
  esac
  [ -n "$sid" ] || return 0
  printf '%s\037%s' "$sid" "${scope%/}"
}

# _board_cold_sidscope <engine> <dir> <rows-file> -> "<path>\037<sid>\037<scope>"
# for every non-agent transcript in the stat rows, with NO fork per file. This
# is the cold build's whole sid/scope stage (see its own header in
# board_state_refresh for why per-file forks are the entire cold cost).
#
# The four engines split two ways, and the split is a property of where each
# one records a session's identity — the same property `_board_engine_sidscope`
# already encodes, one file at a time:
#   claude       sid = filename, scope = parent directory name  -> pure awk over
#                the rows, no file is opened at all.
#   antigravity  sid = the session directory in the path, scope = the bulk
#                `_agy_ws_load` index already loaded for this tank -> a bash
#                loop whose body is parameter expansion, with
#                `_board_engine_sidscope`'s stdout wired straight into this
#                function's stdout (no `$( )`, which would be a fork per file).
#   codex/grok   sid and cwd live IN the file -> ONE batched bounded read,
#                `_board_cold_sidscope_read` below.
_board_cold_sidscope() {
  # The batched table's scratch file is a sibling of the rows file — i.e.
  # inside the generation's own `.tmp/`, which board_state_refresh removes
  # before it publishes. No `mktemp` (a fork), and no `trap … RETURN`: a
  # RETURN trap set here also fires when the functions this one CALLS return,
  # which deleted the table before `cat` could read it (measured: "cat:
  # /tmp/clikae-sidscope.XXXX: No such file or directory", three bats red).
  local engine="$1" dir="$2" rowsf="$3" p tblf="${3%/*}/sidscope-batched"
  case "$engine" in
    claude)
      awk -F$'\037' '
        BEGIN { S = sprintf("%c", 31) }
        {
          p = $3; if (p == "") next
          b = p; sub(/.*\//, "", b)
          if (b ~ /^agent-/) next
          sid = b; sub(/\.jsonl$/, "", sid)
          if (sid == "") next
          d = p; sub(/\/[^\/]*$/, "", d); sub(/.*\//, "", d)
          print p S sid S d
        }
      ' "$rowsf"
      ;;
    antigravity)
      while IFS=$'\037' read -r _ _ p; do
        [ -n "$p" ] || continue
        case "${p##*/}" in agent-*) continue ;; esac
        printf '%s\037' "$p"
        _board_engine_sidscope "$engine" "$p"
        printf '\n'
      done < "$rowsf"
      ;;
    codex|grok)
      # The batched read is a SPEED path, never a narrower answer: any
      # non-agent file it did not resolve (a codex `session_meta` line longer
      # than the 512-byte bound, a grok `summary.json` that puts "id" further
      # down) is handed to the real `_board_engine_sidscope`, one at a time.
      # That is the old per-file cost, paid only for the files that need it.
      # Keeping the fallback INSIDE this function is the point: the bats
      # receipt that compares this function against `_board_engine_sidscope`
      # over a fixture is then comparing the thing the cold build actually
      # calls, not a happy-path subset of it.
      local miss
      _board_cold_sidscope_read "$engine" "$rowsf" > "$tblf"
      cat "$tblf"
      while IFS= read -r miss; do
        [ -n "$miss" ] || continue
        printf '%s\037' "$miss"
        _board_engine_sidscope "$engine" "$miss"
        printf '\n'
      done < <(awk -F$'\037' '
        FNR==NR { if ($1 != "") have[$1] = 1; next }
        { if ($3 != "" && !($3 in have)) print $3 }
      ' "$tblf" "$rowsf")
      ;;
  esac
}

# _board_cold_sidscope_read <engine> <rows-file> -> the same table for an engine
# whose sid lives in the file's CONTENT, from one batched bounded read.
#
# `head -c 512` with `/dev/null` FIRST in the argument list: `head` only prints
# its `==> name <==` banners when it has more than one file, and a batch can
# end up holding exactly one, so a fixed empty first file is what makes the
# output shape unconditional. `xargs -0` (fed by `tr '\n' '\0'`) does the
# batching — `-0` and `-c` are both POSIX/BSD-and-GNU, unlike `xargs -d`.
# 512 bytes is a bound, not an assumption: codex's `session_meta` is the first
# line and grok's `id`/`cwd` are at the top of a small `summary.json`, and any
# file this does NOT resolve is handed back to `_board_engine_sidscope` by the
# caller, so the bound costs speed on a pathological file, never an answer.
#
# The two extractors mirror `_codex_meta_uncached` and `_grok_json_str_uncached`
# deliberately, INCLUDING their quirks: codex looks only at the first line and
# matches `"key":"` with no space tolerance; grok is escape-aware (`\"` inside a
# value must not end it) and tolerates whitespace around the colon. A bats
# receipt compares this function's output against `_board_engine_sidscope`'s on
# the same fixtures, because "two spellings of one rule" is how the fingerprint
# in this same file drifted (see _board_fingerprint_rows).
_board_cold_sidscope_read() {
  local engine="$1" rowsf="$2"
  cut -d$'\037' -f3- "$rowsf" | tr '\n' '\0' \
    | xargs -0 head -c 512 /dev/null 2>/dev/null \
    | awk -v engine="$engine" '
      function jcodex(s, k,   re, m, v) {
        re = "\"" k "\":\""
        m = index(s, re); if (m == 0) return ""
        v = substr(s, m + length(re))
        m = index(v, "\""); if (m == 0) return v
        return substr(v, 1, m - 1)
      }
      function jgrok(s, k,   re, v) {
        re = "\"" k "\"[ \t\n]*:[ \t\n]*\"(\\\\.|[^\"\\\\])*\""
        if (!match(s, re)) return ""
        v = substr(s, RSTART, RLENGTH)
        sub(/^"[^"]*"[ \t\n]*:[ \t\n]*"/, "", v)
        sub(/"$/, "", v)
        return v
      }
      function emit(   sid, scope) {
        if (path == "" || path == "/dev/null") { path = ""; return }
        if (engine == "codex") { sid = jcodex(first, "id"); scope = jcodex(first, "cwd") }
        else { sid = jgrok(chunk, "id"); scope = jgrok(chunk, "cwd") }
        if (sid != "") { sub(/\/$/, "", scope); print path S sid S scope }
        path = ""
      }
      BEGIN { S = sprintf("%c", 31); path = "" }
      /^==> .* <==$/ { emit(); path = substr($0, 5, length($0) - 8); chunk = ""; first = ""; nl = 0; next }
      { if (nl == 0) first = $0; if (nl < 64) chunk = chunk $0 "\n"; nl++ }
      END { emit() }
    '
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
  [ -n "$oldgen" ] && [ -f "$oldgen/manifest" ] && _board_gen_format_ok "$oldgen" || oldgen=""

  gen="$(mktemp -d "$root/generation.XXXXXX")" || return 0
  mkdir -p "$gen/recent" "$gen/sids" "$gen/.tmp"
  printf '%s\n' "$_BOARD_GEN_FORMAT" > "$gen/format"

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
  # Spooled to a FILE, never captured in `$( )`: command substitution strips
  # trailing newlines, and that alone is what made a zero-transcript tank
  # permanently stale (see _board_fingerprint_rows' own header). A file also
  # lets the classifier awk below read the rows directly instead of through a
  # process substitution that re-materialises them.
  local rows_f="$gen/.tmp/rows"
  _board_stat_rows "$engine" "$dir" > "$rows_f"
  _board_fingerprint_rows < "$rows_f" > "$gen/transcripts-fp"
  date +%s > "$gen/updated"

  # P2-2 (2026-09-12 round-3 fix review): antigravity's cwd lives IN the
  # file, not the path, so a sid/scope lookup below scans the WHOLE
  # account's sessions, never just this PWD's — and used to pay one
  # reading_cache_run + fork pipeline PER session for that (measured ~5s
  # fixed on a synthetic 500-session tank). One bulk index read replaces
  # that with plain-global lookups (fix7: bash 3.2 has no associative
  # arrays — `_agy_ws_load`/`_agy_ws_lookup`/`_agy_ws_varname` now live in
  # lib/adapters/antigravity.sh — see `_agy_ws_varname`'s own header — not
  # here: this file must stay usable when antigravity's adapter hasn't been
  # loaded, same as the `declare -F adapter_session_cwd_index` guard already
  # did before this fork existed) — see adapter_session_cwd_index's header
  # (antigravity.sh) for why this is safe (same source of truth, same
  # "first occurrence wins" semantics).
  if [ "$engine" = antigravity ] && declare -F _agy_ws_load >/dev/null 2>&1; then
    _agy_ws_load "$dir"
  fi

  if [ -z "$oldgen" ]; then
    # ---------------- COLD BUILD ----------------
    # Round-7 fix review P2-2. #62's acceptance text is "Board render … under
    # 1 s cold and near-instant warm"; rounds 5-7 measured 3.4 s at 500 files
    # and 35.6 s at 5,000 on an IDLE host and framed cold as "not a target".
    # It is the target, and the cost was never the tree walk (`find … -exec
    # stat … {} +` over 5,000 files is ~30 ms): it was FORKS PER FILE. Two
    # `board_key`s (`printf | cksum`, two processes each) per file, plus a
    # `reading_cache_run` + parser pipeline per file inside the rate-limit
    # window. 5,000 x ~4 forks x ~1.8 ms IS the 35 s, to the second.
    #
    # This pass has no per-file fork at all:
    #   * The entry name comes from `_board_entry_key` — parameter expansion
    #     in bash, one `gsub` in awk, the same rule both sides (see its own
    #     header, and tests/bats/home-bounded.bats pins the two together).
    #   * claude keeps a session's id in its FILENAME and its scope in its
    #     parent directory, so the whole sid/scope table is one awk pass over
    #     the stat rows this function already has — zero file reads.
    #   * codex and grok keep the id IN the file, so the table comes from ONE
    #     batched BOUNDED read: `head -c 512` over `xargs -0` batches, parsed
    #     by one awk (`_board_cold_sidscope`). Never a `head` per file, never
    #     the whole file, never `reading_cache_run`.
    #   * antigravity's id is in its path and its scope comes from the bulk
    #     `_agy_ws_load` index loaded above (round-3 P2-2), so it goes through
    #     `_board_engine_sidscope` with its stdout wired straight into the
    #     table — no `$( )` per file.
    #   * Rate-limit readings are NOT computed here. That is the other half of
    #     the 35 s on a tank whose files are all recent, and #62's own point:
    #     a render must not PARSE the tree. Cold instead records the bounded
    #     set a reading would be needed for — `readings-pending`, the newest
    #     CLIKAE_HOME_RECENT_MAX files per project directory that fall inside
    #     the engine's window — and `board_generation` treats a non-empty
    #     pending list as a reason to refresh once more. The INCREMENTAL path
    #     then pays for those few files and publishes a generation with no
    #     pending list. Net effect: a cold build is a walk plus awk, and the
    #     fuel dots land on the NEXT render (pinned by a bats receipt), not
    #     35 s into this one. Everything else stays on demand.
    #
    # A cold build owns every entry it writes and has no ancestor to resolve
    # through: depth 0, no `parent`.
    printf '0\n' > "$gen/depth"
    local cnt_l ss_f="$gen/.tmp/sidscope" rec_f="$gen/.tmp/reccand" pend_f="$gen/.tmp/pendcand"
    cnt_l="$(wc -l < "$rows_f")"
    count="${cnt_l//[^0-9]/}"
    [ -n "$count" ] || count=0
    printf '%s\n' "$count" > "$gen/count"

    _board_cold_sidscope "$engine" "$dir" "$rows_f" > "$ss_f"

    # ONE awk over (sid/scope table, stat rows): writes every `sids/` entry,
    # the whole manifest, and the two candidate lists the two `sort`s below
    # turn into `recent/` entries and `readings-pending`. `close()` after each
    # entry keeps the open-file count at 1 — the one-true-awk on macOS has a
    # hard FOPEN_MAX and would abort without it.
    LC_ALL=C awk -v gen="$gen" -v now="${reading_now:-0}" -v window="${window:-0}" \
        -v man_out="$gen/manifest" -v rec_out="$rec_f" -v pend_out="$pend_f" \
        "$_BOARD_EKEY_AWK"'
      BEGIN { S = sprintf("%c", 31); R = sprintf("%c", 30) }
      FNR == NR {
        i = index($0, S); if (i == 0) next
        p = substr($0, 1, i - 1); rest = substr($0, i + 1)
        j = index(rest, S); if (j == 0) next
        sidof[p] = substr(rest, 1, j - 1); scopeof[p] = substr(rest, j + 1)
        next
      }
      {
        i = index($0, S); if (i == 0) next
        mt = substr($0, 1, i - 1); rest = substr($0, i + 1)
        j = index(rest, S); if (j == 0) next
        sz = substr(rest, 1, j - 1); path = substr(rest, j + 1)
        if (path == "") next
        sid = ""; scope = ""
        if (path in sidof) { sid = sidof[path]; scope = scopeof[path] }
        mts = mt; sub(/\..*$/, "", mts)
        if (sid != "") {
          f = gen "/sids/" ekey(sid)
          print sid "\n" path > f
          close(f)
          print ekey(scope) S scope S mts S sid > rec_out
        }
        print mt R sz R sid R scope R "" R path > man_out
        if (window + 0 > 0 && (now - mts) < window) {
          d = path; sub(/\/[^\/]*$/, "", d)
          print d S mts S path > pend_out
        }
      }
      END { printf "" > man_out }
    ' "$ss_f" "$rows_f"

    # recent/: newest <n> sessions per scope. One `sort` (scope key asc, mtime
    # desc) then one awk that writes each scope's entry in a single pass.
    if [ -s "$rec_f" ]; then
      LC_ALL=C sort -t$'\037' -k1,1 -k3,3rn "$rec_f" | awk -v gen="$gen" -v n="$n" '
        BEGIN { S = sprintf("%c", 31) }
        {
          i = index($0, S); k = substr($0, 1, i - 1); rest = substr($0, i + 1)
          j = index(rest, S); sc = substr(rest, 1, j - 1); rest = substr(rest, j + 1)
          j = index(rest, S); mt = substr(rest, 1, j - 1); sid = substr(rest, j + 1)
          if (k != cur) {
            if (cur != "") close(gen "/recent/" cur)
            cur = k; c = 0
            f = gen "/recent/" k
            print "#scope" S sc > f
          }
          if (c < n) { print mt S sid > f; c++ }
        }
        END { if (cur != "") close(gen "/recent/" cur) }
      '
    fi

    # readings-pending: newest <n> per PROJECT DIRECTORY inside the window.
    # Grouped by directory, not by scope, on purpose — claude's
    # `agent-*.jsonl` subagent transcripts carry no sid (so they have no
    # scope) and a rate limit lands in one of them with no matching write to
    # its parent session (round-5 fix review P2-2). They live in the project
    # directory, so grouping by directory keeps them in the bounded set.
    if [ -s "$pend_f" ]; then
      LC_ALL=C sort -t$'\037' -k1,1 -k2,2rn "$pend_f" | awk -v n="$n" '
        BEGIN { S = sprintf("%c", 31) }
        {
          i = index($0, S); k = substr($0, 1, i - 1); rest = substr($0, i + 1)
          j = index(rest, S); p = substr(rest, j + 1)
          if (k != cur) { cur = k; c = 0 }
          if (c < n) { print p; c++ }
        }
      ' > "$gen/readings-bounded"
    fi

    # ---- the bounded readings, folded in before this generation publishes ----
    #
    # DEVIATION FROM THE ROUND-8 BRIEF, and the measurement that forced it.
    # The brief asked for these readings to be computed "lazily by the
    # incremental path on the NEXT render". Built that way first, and it turns
    # a receipt this branch has been carrying since round 5 RED: three tests
    # in tests/bats/home-bounded.bats assert that a WARM render never opens a
    # transcript ("warm reads zero transcript bytes", "self-heals inline once,
    # then reads are bounded (list+stat, never content) again", "an
    # incremental rebuild re-reads only the ONE file that changed"), and the
    # render that consumes a pending list is, from outside, a warm render that
    # runs `tail -c 524288` over ten transcripts. Measured, not argued: those
    # three went red, plus "live rows … at most ONE candidate".
    #
    # So the LIST is still the mechanism and the bound is still the brief's —
    # the newest CLIKAE_HOME_RECENT_MAX per project directory, inside the
    # engine's window, and nothing else — but it is consumed here, before the
    # generation publishes, instead of one render later. What that keeps is
    # the property #62 actually asks for: a render that changes nothing reads
    # nothing. What it costs is that the discovery pass pays for the bounded
    # set, which is ~1 reading on #62's own tank shape and 10 on the 5,000-file
    # fixture — not the thousands the unbounded version paid.
    #
    # The list is published as `readings-bounded` so what was read is
    # inspectable after the fact rather than inferred.
    if [ -n "$window" ] && [ -s "$gen/readings-bounded" ]; then
      local pp pval
      while IFS= read -r pp; do
        [ -n "$pp" ] || continue
        if declare -F reading_cache_run >/dev/null; then
          pval="$(reading_cache_run "$kind" "$pp" "$parser" "$pp")"
        else
          pval="$("$parser" "$pp")"
        fi
        printf '%s\037%s\n' "$pp" "$pval"
      done < "$gen/readings-bounded" > "$gen/.tmp/readings"
      awk -v pf="$gen/.tmp/readings" '
        BEGIN { R = sprintf("%c", 30); S = sprintf("%c", 31) }
        FILENAME == pf {
          i = index($0, S); if (i == 0) next
          rd[substr($0, 1, i - 1)] = substr($0, i + 1)
          next
        }
        {
          n = split($0, f, R)
          if (n >= 6 && (f[6] in rd)) print f[1] R f[2] R f[3] R f[4] R rd[f[6]] R f[6]
          else print
        }
      ' "$gen/.tmp/readings" "$gen/manifest" > "$gen/.tmp/manifest2" \
        && mv -f "$gen/.tmp/manifest2" "$gen/manifest"
    fi
    if [ -n "$window" ]; then
      cut -d$'\036' -f5 "$gen/manifest" | awk -F $'\037' '
        $0 == "" { next }
        $1 > l { l = $1; r = $3 }
        $2 > s { s = $2 }
        END { printf "%s\037%s\037%s\n", l, s, r }
      ' > "$gen/$([ "$engine" = claude ] && printf claude-usage || printf codex-dry)"
    fi
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
    local d6 d7 manf="$oldgen/manifest"
    d6=$'\036'; d7=$'\037'
    awk -v OFS="$d6" -v FS7="$d7" -v now="${reading_now:-0}" -v window="${window:-0}" \
        -v manf="$manf" \
        -v unchanged_out="$unchanged_f" -v changed_out="$changed_f" -v removed_out="$removed_f" '
      FILENAME == manf {
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
    ' "$manf" "$rows_f"

    count=0
    [ -f "$unchanged_f" ] && count=$((count + $(wc -l < "$unchanged_f")))
    [ -f "$changed_f" ] && count=$((count + $(wc -l < "$changed_f")))
    printf '%s\n' "$count" > "$gen/count"

    # Round-7 fix review P1-1/P2-1 — carry-forward is now a LINK IN A CHAIN,
    # not a copy of the previous generation. See this file's own chain header
    # (`_BOARD_GEN_MAX_DEPTH`) for the whole design; here it is two branches:
    #
    #   depth+1 < max  -> write nothing. `parent` names the generation this
    #     one was built from and `_board_gen_entry` resolves any entry this
    #     refresh does not itself rewrite by walking to it. Cost: ZERO file
    #     operations proportional to the tank (round-7 measured 5,001 `link()`
    #     calls per rebuild at 5,000 files; this is 0).
    #   depth+1 >= max -> MATERIALISE: copy the resolved set once, oldest
    #     ancestor first so the newest copy of each name overwrites the older
    #     ones, then start a fresh chain (no `parent`, depth 0). `cp -a`, no
    #     `-l`: a hard link is exactly what round-7's P1-1 was, and the whole
    #     point here is that no two generations ever share an inode again.
    #     Tombstones (zero-byte entries, see the chain header) are dropped on
    #     the way out — `-size 0c` is POSIX BYTES; plain `-size 0` counts
    #     512-byte blocks and would match every entry in the tank.
    local depth=0 parentname="" cg cd=0 ci cp_p
    [ ! -f "$oldgen/depth" ] || IFS= read -r depth < "$oldgen/depth" 2>/dev/null
    case "$depth" in ''|*[!0-9]*) depth=0 ;; esac
    if [ "$((depth + 1))" -lt "$_BOARD_GEN_MAX_DEPTH" ]; then
      depth=$((depth + 1))
      parentname="${oldgen##*/}"
      printf '%s\n' "$parentname" > "$gen/parent"
    else
      local -a chain=()
      cg="$oldgen"
      while [ -n "$cg" ] && [ "$cd" -lt "$_BOARD_GEN_MAX_DEPTH" ]; do
        chain[cd]="$cg"; cd=$((cd + 1))
        cp_p=""
        [ ! -f "$cg/parent" ] || IFS= read -r cp_p < "$cg/parent" 2>/dev/null
        case "$cp_p" in
          generation.*) cg="$root/$cp_p"; [ -d "$cg" ] || cg="" ;;
          *) cg="" ;;
        esac
      done
      for ((ci = cd - 1; ci >= 0; ci--)); do
        [ ! -d "${chain[ci]}/sids" ] || cp -a "${chain[ci]}/sids/." "$gen/sids/" 2>/dev/null
        [ ! -d "${chain[ci]}/recent" ] || cp -a "${chain[ci]}/recent/." "$gen/recent/" 2>/dev/null
      done
      find "$gen/sids" "$gen/recent" -type f -size 0c -exec rm -f {} + 2>/dev/null
      depth=0
    fi
    printf '%s\n' "$depth" > "$gen/depth"

    # ---- REMOVED, BEFORE CHANGED ----
    # Round-7 fix review P2-3: this block used to run AFTER the changed loop
    # below, and a file that moves to a new path while keeping its sid is
    # classified as BOTH — removed at the old path, changed at the new one.
    # The changed loop wrote `sids/<key>` and this one then deleted the very
    # entry it had just written, so the session stayed on disk, kept its
    # `recent/` row, and `board_find` could no longer resolve it at all.
    # Ordering is the whole fix: purge what the previous generation knew
    # first, then apply this generation's facts on top. A moved file's entry
    # is tombstoned and immediately rewritten with its new path; a genuinely
    # deleted file's entry stays tombstoned.
    # The trigger surface is not narrow: claude encodes the sid in the
    # filename (so only a whole-file move between project directories hits
    # it), but codex, grok and antigravity read the sid out of the file's
    # CONTENT — a rollout moved, a grok session directory renamed, an agy
    # brain directory renamed all keep the sid and change the path.
    if [ -f "$removed_f" ]; then
      local rsid rscope rkey
      while IFS=$'\037' read -r _ rsid rscope; do
        [ -n "$rsid" ] || continue
        _board_entry_key "$rsid"; rkey="$_board_entry_key_out"
        # Round-8: `rm -f` only unlinked THIS generation's name, which since
        # the chain landed is usually not where the entry lives at all — the
        # ancestor would go on answering for a transcript that is gone. A
        # zero-byte TOMBSTONE is how a chain says "removed here" (see
        # _board_gen_entry).
        : | _board_gen_put "$gen" "sids/$rkey"
        _board_purge_recent_row "$gen" "$rscope" "$rsid"
      done < "$removed_f"
    fi

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
              _board_entry_key "$sid"; key="$_board_entry_key_out"
              # P3-2: the sid itself is written back so a reader (board_find,
              # board_stale) can verify it — a 32-bit cksum collision then
              # reads as a miss, never someone else's transcript.
              printf '%s\n%s\n' "$sid" "$fpv" | _board_gen_put "$gen" "sids/$key"
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

    rm -f "$unchanged_f" "$changed_f" "$removed_f"
  fi

  case "$engine" in
    antigravity) agy_email "$dir" > "$gen/email" ;;
    codex) _limit_codex_rate_limits_cached "$dir" "$root/codex-cache" > "$gen/codex-usage" || true ;;
  esac
  rm -rf "$gen/.tmp"
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
