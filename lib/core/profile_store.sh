# shellcheck shell=bash
# lib/core/profile_store.sh — profile directory layout helpers.
#
# Layout:
#   $CLIKAE_HOME/
#     profiles/
#       <cli>/
#         <profile>/      <- the actual config dir that the CLI's env var points at

profiles_root() {
  printf '%s/profiles\n' "$CLIKAE_HOME"
}

# profile_dirv <cli> <profile> -> sets $_PROFILE_DIR. The same path as
# profile_dir, without the subshell: `$(profile_dir …)` costs a fork every time,
# which is invisible once and expensive in a loop over every tank. Callers on a
# hot path use this; everyone else keeps the printf form below. The path shape
# is written down ONCE, here, so the two can never drift apart.
profile_dirv() { _PROFILE_DIR="$CLIKAE_HOME/profiles/$1/$2"; }

# profile_dir <cli> <profile>
profile_dir() {
  profile_dirv "$1" "$2"; printf '%s\n' "$_PROFILE_DIR"
}

# profile_exists <cli> <profile>
profile_exists() {
  [ -d "$(profile_dir "$1" "$2")" ]
}

# clikae_is_target <cli>  ->  0 if <cli> is a LAUNCH-ONLY target (a global,
# single-account vendor whose switching/active-state is handled by a script in
# lib/targets/, e.g. antigravity), else 1.
#
# The canonical "is it a target, not an env-switchable engine?" predicate. It
# deliberately wins over the presence of an adapter file: a target may ALSO ship a
# thin lib/adapters/<cli>.sh that only adds a capability (e.g. antigravity's resume
# shim — find/resume by id), but that does NOT make it env-switchable. So status /
# handoff / watch / home must classify by target-ness FIRST, never by "an adapter
# file exists" (a safe proxy only while targets had no adapter file — an invariant
# the resume shim broke). Accepts the `agy` alias.
clikae_is_target() {
  local cli="$1"
  [ "$cli" = "agy" ] && cli="antigravity"
  [ -f "$CLIKAE_LIB/targets/$cli.sh" ]
}

# engine_label <cli> -> the name to PRINT for an engine. The on-disk directory is
# `antigravity`; the engine you type is `agy` (docs/grammar.md §6). Three surfaces
# had each grown their own copy of this mapping and `doctor` had none, so the same
# engine read as `agy` in `clikae list` and `antigravity` in `clikae doctor`. One
# owner, so they cannot disagree again.
#
# NB: this is a DISPLAY name. The store path, the targets/ filename and the JSON
# `path` field all stay `antigravity` — don't "fix" those to match.
engine_labelv() {
  case "$1" in
    antigravity) _ENGINE_LABEL='agy' ;;
    *)           _ENGINE_LABEL="$1" ;;
  esac
}
engine_label() { engine_labelv "$1"; printf '%s' "$_ENGINE_LABEL"; }

# ── Bounded transcript reads ────────────────────────────────────────────────
# Session transcripts get HUGE (100+ MB for a long agent run); scanning a whole
# one PER TANK is what made the home board crawl (dogfood 2026-06-29: ~8s on a
# 1.6 GB tank — `limit_profile_dry` + the recap each `grep`'d the full file).
# Every signal we actually need sits at a known END of the file:
#   · ai-title / opening prompt / cwd → near the HEAD (first lines)
#   · newest usage-limit marker / newest turn / latest recap → near the TAIL
# So readers take a BOUNDED slice, never the whole file. This is the ONE home for
# that rule — limit detection, the home recap, the resume picker all go through
# it rather than each re-deriving "read only what you need" and drifting on the
# bound. Override the bounds via env if a pathological transcript ever needs more.
CLIKAE_TX_HEAD_LINES="${CLIKAE_TX_HEAD_LINES:-200}"
CLIKAE_TX_TAIL_BYTES="${CLIKAE_TX_TAIL_BYTES:-524288}"   # 512 KiB

# transcript_head <file> [lines] — first N lines (head-of-file signals). One
# `head`, never the whole file. Silent (empty) if the file is missing.
transcript_head() {
  local f="$1" n="${2:-$CLIKAE_TX_HEAD_LINES}"
  [ -f "$f" ] || return 0
  head -n "$n" "$f" 2>/dev/null || true
}

# transcript_tail <file> [bytes] — last N BYTES (latest-event signals). Bounded
# by BYTES, not lines: a transcript line can be megabytes (a tool result / inline
# base64), so a line bound (`tail -n`) still reads/processes MBs and was the home
# board's last hot spot (dogfood 2026-06-29: tank C's 96 MB session → 0.9s per
# scan). `tail -c` seeks from the end → cost is the slice, period. The first line
# may be partial — harmless: callers match whole JSON objects, and the events they
# want (NEWEST limit marker / success turn / recap) are the most-recent COMPLETE
# lines at the very end. 512 KiB comfortably spans many recent turns.
transcript_tail() {
  local f="$1" b="${2:-$CLIKAE_TX_TAIL_BYTES}"
  [ -f "$f" ] || return 0
  tail -c "$b" "$f" 2>/dev/null || true
}

# transcript_tail_scan <file> <grep-pattern> [start-bytes] — like
# transcript_tail, but for a caller that needs a SPECIFIC event to be inside
# the window, not just "the last N bytes". Starts at <start-bytes> (default
# $CLIKAE_TX_TAIL_BYTES) and QUADRUPLES it until the slice contains a line
# matching <grep-pattern> or the slice already spans the whole file. Bounded:
# each iteration is one bigger `tail -c`, not a re-read from scratch, so the
# common case (the wanted event is well within the first window) costs
# exactly one `tail -c`, and the worst case costs a handful of geometrically
# growing reads — never more than "keep re-scanning the whole file every
# redraw".
#
# P1-2 (2026-09-12 round-1 review): a fixed-size tail silently drops the
# event a caller actually wants the moment something LARGE gets appended
# after it — CONFIRMED on a >1 MB codex rollout whose last `token_count`
# event was followed by >700 KB of trailing tool output: the fixed 512 KiB
# window never saw that event at all, and an older (possibly already-stale)
# one from a different file won the newest-wins comparison instead, with no
# error anywhere to say so. Growing the window until the wanted event is
# actually IN it closes that gap; the common case (the event is well within
# the first window) still costs exactly one `tail -c`.
#
# P2-1 (2026-09-12 round-2 review): `bin/clikae:6` runs the WHOLE program
# under `set -eo pipefail`, and this function used to test the window with
# `tail -c "$bytes" "$f" | grep -qaE "$pat"` — a plain pipeline. The moment
# `grep -q` matches early (the pattern sits near the START of the window,
# with more data still queued behind it), it exits immediately; `tail` is
# still writing to a now-closed pipe and dies of SIGPIPE (128+13=141). Under
# `pipefail` that 141 — NOT grep's own 0 — becomes the pipeline's reported
# exit status, so the `if` reads a genuine HIT as "not found" and keeps
# quadrupling `bytes` until the final `bytes >= size` branch fires and the
# ENTIRE file is read every single time, no matter where the pattern
# actually sits. bats itself runs with pipefail OFF (confirmed — see the
# tests below), so the whole test suite exercised a world `bin/clikae` never
# runs in and never saw this. Fixed by deciding the window purely on `grep`'s
# OWN exit status, with `pipefail` turned off for exactly this check (and
# restored before returning, in case the caller relies on it) — SIGPIPE on
# `tail`'s side then can't change what `if` sees, in EITHER world.
transcript_tail_scan() {
  local f="$1" pat="$2" bytes="${3:-$CLIKAE_TX_TAIL_BYTES}" size had_pipefail=0
  [ -f "$f" ] || return 0
  size="$(wc -c < "$f" 2>/dev/null || echo 0)"
  size="${size//[[:space:]]/}"
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [[ -o pipefail ]]; then had_pipefail=1; set +o pipefail; fi
  # 🔴 NEVER capture the chunk into a shell variable to test it: `$( )`
  # strips trailing newlines, and when several files' outputs are piped
  # together (as every caller here does — one process per rollout, all
  # feeding one awk) a stripped trailing newline SILENTLY MERGES this file's
  # last line into the next file's first line into one giant awk record,
  # which then matches whichever event happens to come first in that merge —
  # exactly the kind of wrong-event bug this function exists to prevent.
  # `tail -c` piped straight to `grep -q` never touches a variable, and the
  # final emit below is the same direct `tail -c` transcript_tail itself
  # uses, byte-for-byte including whatever trailing newline the file has.
  while :; do
    if [ "$bytes" -ge "$size" ]; then
      tail -c "$bytes" "$f" 2>/dev/null || true
      [ "$had_pipefail" -eq 1 ] && set -o pipefail
      return 0
    fi
    # pipefail is OFF here (see above), so `$?`/the `if` reflect grep's OWN
    # exit status only — a SIGPIPE-killed `tail` can never flip this.
    if tail -c "$bytes" "$f" 2>/dev/null | grep -qaE "$pat" 2>/dev/null; then
      tail -c "$bytes" "$f" 2>/dev/null || true
      [ "$had_pipefail" -eq 1 ] && set -o pipefail
      return 0
    fi
    bytes=$((bytes * 4))
  done
}

# sessions_by_mtime <path-or-glob>...  -> "<mtime-epoch> <path>" per existing file,
# NEWEST FIRST. ONE `stat` over every arg (the shell expands the globs first), then
# sort by the leading mtime — so N files cost ~2 processes, not N. This is the
# shared "list session files by recency" primitive the resume picker proved out
# (~30ms for 500+ files); the picker, `resume cleanup`, and each adapter's
# adapter_recent_sids all go through it rather than re-deriving an ls/stat-per-file
# loop. The CALLER chooses scope via its globs (all tanks/dirs vs one tank's $PWD
# project); the kernel just stats+sorts. GNU/BSD-portable (detect, don't `||`-fall
# back — a partial GNU failure on a non-matching glob would otherwise double-run).
# NEVER leaks stat's exit status: an unmatched glob reaches stat as a literal
# path, stat exits non-zero even when the OTHER args succeeded, and under the
# script-global `set -eo pipefail` that killed `clikae resume`/`cleanup` DEAD
# SILENT for anyone whose store lacks even one engine's directory (a
# single-engine new user, i.e. most of them). Missing paths are this function's
# normal case — the contract is "print what exists", so status is always 0.
# Which `stat` this machine has cannot change while we run, but the probe for it
# (`stat --version | grep`) is two forks and was paying them on EVERY call — and
# the resume picker, every adapter's recent-session list and the board's agy
# account column all call this repeatedly. Ask the once.
_CLIKAE_STAT_FMT=""

# _clikae_statv -> decide once which stat this machine has.
#
# 🔴 ASK `--version`, NEVER "try -f and fall back". GNU stat's `-f` means
# --file-system, so on a GNU-stat machine `stat -f %m file` PRINTS FILESYSTEM
# INFO (block size, block/inode counts) to stdout AND EXITS 1 — an `||`
# fallback DOES fire, and the caller's `$(...)` capture gets that multi-line
# report concatenated onto whatever the fallback call prints, not a clean
# epoch (measured: GNU coreutils 9.11, `stat -f %m /tmp` → rc=1, five lines of
# filesystem info; 2026-09-10 round-7 review, R7-P3-3, correcting this
# comment's own "EXITS 0" claim). This repo has been caught by the two flags
# four times; the fourth was a helper written three functions away from this
# one, which had already solved it. BSD stat has no `--version`, so the grep
# failing IS the BSD answer.
_clikae_statv() {
  [ -n "$_CLIKAE_STAT_FMT" ] && return 0
  if stat --version 2>/dev/null | grep -q GNU; then
    _CLIKAE_STAT_FMT='%Y %n'            # GNU
  else
    _CLIKAE_STAT_FMT='%m %N'            # BSD
  fi
  return 0
}

# file_mtime <file> -> its mtime in epoch seconds, nothing if it cannot be read.
file_mtime() {
  _clikae_statv
  if [ "$_CLIKAE_STAT_FMT" = '%Y %n' ]; then
    stat -c '%Y' "$1" 2>/dev/null
  else
    stat -f '%m' "$1" 2>/dev/null
  fi
}

# files_mtime_size <path>...  -> "<mtime> <size>" per arg, in the SAME ORDER
# given (positional — unlike sessions_by_mtime, this never sorts, so a caller
# can zip the output back onto its own argument list by index). ONE `stat`
# call covers mtime AND size for every file, so a caller checking many small
# files' own identity (e.g. a per-file cache key) pays one fork total instead
# of 2*N — the same "ask the kernel once" reasoning as sessions_by_mtime's
# own header, for a caller that needs the ORIGINAL order back, not recency.
files_mtime_size() {
  _clikae_statv
  if [ "$_CLIKAE_STAT_FMT" = '%Y %n' ]; then
    stat -c '%Y %s' "$@" 2>/dev/null || true
  else
    stat -f '%m %z' "$@" 2>/dev/null || true
  fi
}

sessions_by_mtime() {
  _clikae_statv
  if [ "$_CLIKAE_STAT_FMT" = '%Y %n' ]; then
    stat -c '%Y %n' "$@" 2>/dev/null | sort -rn || true
  else
    stat -f '%m %N' "$@" 2>/dev/null | sort -rn || true
  fi
  return 0
}

# Validate that <cli> and <profile> are sane names (no slashes, no leading dot, no whitespace).
validate_name() {
  local kind="$1"   # "cli" or "profile"
  local name="$2"
  if [ -z "$name" ]; then
    log_fail "$kind name is empty."
  fi
  case "$name" in
    .*|*/*|*\ *|*$'\t'*|*$'\n'*)
      log_fail "Invalid $kind name: '$name' (no leading dot, no slashes, no whitespace)."
      ;;
  esac
  # Keep it ASCII-friendly for cross-platform paths. Allow letters, digits, dot, dash, underscore.
  if ! printf '%s' "$name" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]+$'; then
    log_fail "Invalid $kind name: '$name'. Allowed: A-Z a-z 0-9 . _ -"
  fi
}

# --- per-tank git commit identity (issue #22) ------------------------------
# A tank governs an AI account's auth/fuel/memory; a coding session ALSO emits a
# git author/committer, which the tank does not control today. These helpers let
# a tank carry an OPTIONAL intended git identity, stamped into the shell by
# `clikae env` so commits aren't mis-attributed to the engine's account email.
# Stored as plain text under the tank dir (local-only, auditable):
#   clikae-meta/git-identity   -> "name<TAB>email" (one line)

# git_identity_file <cli> <profile> -> the path to the identity file.
git_identity_file() {
  printf '%s/clikae-meta/git-identity\n' "$(profile_dir "$1" "$2")"
}

# git_identity_read <cli> <profile> -> echo "name<TAB>email" if set, else nothing.
# Never aborts the caller under `set -eo pipefail` (a missing file is normal).
git_identity_read() {
  local f; f="$(git_identity_file "$1" "$2")"
  [ -f "$f" ] || return 0
  head -n 1 "$f" 2>/dev/null || true
}

# ── Solo tanks ──────────────────────────────────────────────────────────────
# A tank can be marked SOLO: it opts OUT of the fleet flow — not a relay/`to`
# target, skipped by the burn/`watch` rotation, and refused by `clikae memory
# share`. For a dedicated, standalone tank (a bot/persona tank, a client-only tank)
# that must never receive carried work or share a brain. The marker is a file in
# the tank dir; this is the one predicate everything checks. `agy` resolves to
# `antigravity`. See `clikae solo` and docs/grammar.md §2.
solo_marker_filev() {
  local cli="$1"; [ "$cli" = "agy" ] && cli="antigravity"
  profile_dirv "$cli" "$2"; _SOLO_MARKER="$_PROFILE_DIR/clikae-meta/solo"
}
solo_marker_file() {
  solo_marker_filev "$1" "$2"; printf '%s\n' "$_SOLO_MARKER"
}
# The board asks this for every tank, twice (fleet, then solo section). Going
# through the printf form cost TWO forks a call — one for solo_marker_file, one
# for the profile_dir nested inside it — so it goes straight to the v-form.
tank_is_solo() { solo_marker_filev "$1" "$2"; [ -f "$_SOLO_MARKER" ]; }

# ── The group a tank left when it went solo ─────────────────────────────────
# `clikae solo` leaves the shared brain; `--off` is supposed to put it back. It
# used to decide WHERE to put it back by reading the machine default
# (soul_default_group) — which is set only by the FIRST `memory share` ever run
# on the machine and is empty on plenty of installs. When it is empty, `--off`
# silently rejoined nothing: the marker came off, the board showed the tank back
# in the fleet, and its memory slot stayed an empty directory. A tank that was
# demonstrably in a group seconds ago must not need a global default to find its
# way home, so solo writes the group name down and --off reads it back.
# One line, in the tank's own meta dir, so it travels with a rename.
soul_left_file() {
  local cli="$1"; [ "$cli" = "agy" ] && cli="antigravity"
  printf '%s/clikae-meta/soul-left\n' "$(profile_dir "$cli" "$2")"
}
soul_left_read() {
  local f; f="$(soul_left_file "$1" "$2")"
  [ -f "$f" ] || return 0
  head -n 1 "$f" 2>/dev/null | tr -d '[:space:]'
}
soul_left_set() {
  local f; f="$(soul_left_file "$1" "$2")"
  [ -n "$3" ] || return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf '%s\n' "$3" > "$f" 2>/dev/null || true
}
soul_left_clear() { rm -f "$(soul_left_file "$1" "$2")" 2>/dev/null || true; }

# tank_engine_known <cli> -> 0 if <cli> is an engine clikae actually knows how
# to run — else 1. A directory under profiles_root() whose name is neither is
# not an engine clikae recognises; nothing under it can be a tank, no matter
# how many subdirectories it holds. This is the "engine's adapter recognises
# it" half of #61's fix — the profile-store walk used to accept ANY
# subdirectory of profiles_root() as a CLI.
#
# round-1 review P2-1: this used to be `[ -f adapters/$cli.sh ] ||
# clikae_is_target "$cli"` — two bugs. (1) a raw `-f` test accepted
# lib/adapters/_template.sh, so a stray `profiles/_template/` was read as a
# real engine's tanks. (2) clikae_is_target ALIASES "agy" -> "antigravity"
# (it has to — that alias is what a human types), so it said yes to a
# directory literally named `profiles/agy/` even though the on-disk name is
# always `antigravity` (never "fix" that to match — see engine_labelv above).
# Fixed by reusing list_adapters() (already excludes `_*` — one owner, not a
# second copy of that rule) for the adapter half, and testing the target
# FILE directly (no alias) for the target half: a directory's name IS the
# canonical on-disk name or it is nothing.
tank_engine_known() {
  local cli="$1"
  # #61 round-2 P3: $cli comes straight from a directory NAME with no `-e`/`--`
  # guard — a `profiles/-e/` directory makes grep read "$cli" as a second
  # OPTION instead of a pattern and print its own usage banner twice.
  list_adapters | grep -qxF -e "$cli" && return 0
  [ -f "$CLIKAE_LIB/targets/$cli.sh" ]
}

# CLIKAE_TANK_MARKER — the file that makes a directory a tank clikae
# recognises, rather than a directory that merely happens to sit where one
# would. One constant so init/the adoption sweep/the enumerator can never
# drift on the name.
CLIKAE_TANK_MARKER=".clikae-tank"

# tank_marker_path <dir> -> the marker file's path inside <dir>.
tank_marker_path() { printf '%s/%s\n' "${1%/}" "$CLIKAE_TANK_MARKER"; }

# tank_marker_write <cli> <dir> -> stamp <dir>'s marker with <cli> — the
# CANONICAL, on-disk engine name (never an alias like "agy"; always exactly
# what tank_engine_known would accept as this directory's own cli). Called
# from the one true creation point (ensure_profile --create, below), from
# agy's own tank-creation paths (lib/commands/antigravity.sh — agy tanks
# never go through ensure_profile), and from the one-time adoption sweep
# (_tank_adoption_ensure, below). Best-effort AND SILENT: a read-only
# filesystem must never turn "list my tanks" into a wall of raw shell errors.
#
# #61 round-2 P2-1: `> file 2>/dev/null` puts the redirects in the WRONG
# order — bash wires stdout to the file FIRST, and that redirection's own
# failure (Permission denied) prints to the ORIGINAL, still-unredirected
# stderr; only after that does `2>/dev/null` take effect, too late to catch
# it. Doing `2>/dev/null` first closes that window: every failure from here
# is silenced, never raced.
#
# #61 round-2 P3: also not ATOMIC — a bare `>` truncates the file before
# writing it, so a concurrent reader (another clikae process walking the
# same store) can observe a momentarily EMPTY marker and read a real tank as
# not-a-tank. Writing a per-write temp name and renaming over the marker
# means a reader only ever sees "old content" or "new content", never
# "truncated".
tank_marker_write() {
  local cli="$1" dir="$2" marker tmp
  marker="$(tank_marker_path "$dir")"
  tmp="${marker}.tmp.$$"
  printf '%s\n' "$cli" 2>/dev/null > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$marker" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# tank_dir_is_tank <cli> <dir> -> 0 if <dir> is a tank clikae itself made:
# its marker exists and names <cli> exactly. Read-only — does not adopt (see
# _tank_adoption_ensure below) and does not re-derive anything from the
# directory's NAME. #61 round-1 P1-3: the previous version was a NAME-SHAPE
# test (rejecting `*.lock`/dotdir-looking names) — so a stray `mkdir zzempty`
# (no lock-ish name at all) sailed through as a "real" tank and reproduced
# #61's exact symptom verbatim, just under a different name. A tank is a
# directory clikae MADE or ADOPTED, never a guess from what it's called.
#
# The second branch is the ONE exception, and only fires when this store's
# adoption flag could not be persisted (a read-only store — #61 round-2
# P1-1/P2-1): _tank_adoption_ensure still decides tank-ness for THIS run and
# remembers the decision here in memory rather than on disk, so `clikae
# tanks` on a read-only store still lists everything it would have adopted
# instead of going silent the moment persistence fails.
#
# #61: a stray `hello.lock` sitting beside real tank dirs was picked up as a
# reroute target and burned a few minutes failing to log in before reporting
# a generic "task failure" — indistinguishable, from the caller's `--json`,
# from the task itself having failed. `list_all_profiles` is the ONE place
# that decides what a tank is (clikae tanks / burn's reroute / to's and
# resume's next_tank all read it) — this is that filter, so nobody downstream
# writes a second one next to it.
tank_dir_is_tank() {
  local cli="$1" dir="$2" marker _m=""
  marker="$(tank_marker_path "$dir")"
  if [ -f "$marker" ]; then
    # #61 round-3 P3: builtin `read`, not a forked `cat` per tank on every
    # single read — measured 160ms -> 123ms on `clikae tanks` and
    # 519ms -> 483ms on `clikae doctor` with 30 tanks, same tank count out.
    #
    # #61 round-5 P3-3: BOUNDED at 64 characters (`-n`, not bash-4-only
    # `-N`: macOS ships bash 3.2), because the trailing-whitespace strip
    # below is quadratic in the length of what it is handed — round-5
    # review measured one marker of `claude` + 16,000 trailing spaces
    # taking `clikae tanks` 13.9 SECONDS (bash 5 and bash 3.2 alike, x4 per
    # doubling), which is the whole store silently hanging. 64 is far more
    # than any engine name and short enough that the strip is free; a first
    # line longer than that cannot be an engine name anyway, and the one
    # case where the OVERFLOW is meaningful — a real name followed by a
    # pile of whitespace — still matches, because the strip runs on the
    # first 64 characters and the name is at the front of them.
    #
    # 🔴 #61 round-6 P3-1: `_m` is initialised at the top of this function and
    # the read runs inside a REDIRECTED GROUP. Both halves are load-bearing,
    # and the bare `IFS= read … < "$marker" 2>/dev/null` this replaces had
    # neither:
    #
    #   * redirections are processed left to right, so `< "$marker"` failed
    #     (mode 000, a changed owner, an ACL) BEFORE `2>/dev/null` was in
    #     effect — the raw `profile_store.sh: line NNN: …: Permission denied`
    #     went to the operator's screen, which CHANGELOG's "exactly one
    #     warning line — never a raw shell error" promise forbids. `{ … }
    #     2>/dev/null` establishes the suppression around the whole group, so
    #     the failing open inside it has nowhere to print;
    #   * when the open fails, `read` never runs and `_m` is never assigned —
    #     so the `[ "$_m" = … ]` below died with `_m: unbound variable` under
    #     `set -u`. That is lib/hooks/cockpit-guard.sh, which the block at the
    #     bottom of this file promises will not die here. It did not die
    #     loudly: the enumerator aborted mid-walk and returned a list
    #     TRUNCATED AT THE UNREADABLE TANK, with rc 0 — the hook's refusal
    #     message then told the operator "No idle tank in the reserve right
    #     now" with idle tanks sitting in the store. rc kept its shape and the
    #     CONTENT ran off, which is the same failure b70967b (#61 P1-1) wrote
    #     its long note about.
    #
    # An unreadable marker is "not a tank" (nothing else is knowable about
    # it), said ONCE per process rather than swallowed — the probe below is
    # only paid when nothing was read, which is the empty-marker case too.
    { IFS= read -r -n 64 _m < "$marker"; } 2>/dev/null || true
    if [ -z "$_m" ] && ! { : < "$marker"; } 2>/dev/null; then
      _tank_marker_unreadable_warn_once "$dir"
      return 1
    fi
    if [ "$_m" = "$cli" ]; then
      return 0
    fi
    # #61 round-3 P3: tolerate a trailing `\r` (a sync tool turning `\n`
    # into `\r\n`) or trailing whitespace in the marker — round-3 review
    # found this makes a real tank vanish from `clikae tanks` entirely,
    # with no CLI able to bring it back. Exact match above is tried FIRST
    # and kept as ITS OWN branch, so the ordinary clean-marker case never
    # pays for the strip below.
    _m="${_m%$'\r'}"
    _m="${_m%"${_m##*[![:space:]]}"}"
    [ "$_m" = "$cli" ] && return 0
  fi
  [ -n "$_CLIKAE_INMEM_ADOPTED_ACTIVE" ] || return 1
  local name="${dir%/}"; name="${name##*/}"
  case "$_CLIKAE_INMEM_ADOPTED" in *$'\n'"$cli"$'\t'"$name"$'\n'*) return 0 ;; esac
  return 1
}

# _tank_shape_excluded <name> -> 0 if <name> can NEVER be a tank regardless
# of content — a dotdir, or a lock/sidecar-suffixed name. The same shapes
# 3c02eb2 rejected by NAME before the marker existed; a directory clikae
# itself creates can never look like this (validate_name forbids a leading
# dot). Used ONLY by the one-time adoption sweep below — once a directory
# has a marker, tank_dir_is_tank never re-checks its name again. #61
# round-4 P3-2: also checked directly by `init --adopt` — a NAMED, explicit
# adopt request still can't hand a marker to a shape the sweep would have
# skipped past on sight.
_tank_shape_excluded() {
  case "$1" in
    .*) return 0 ;;
    *.lock|*.lck|*.tmp|*.bak|*.swp|*.orig|*.reclaim|*~) return 0 ;;
  esac
  return 1
}

# _tank_candidates <cli_dir> -> "<name>\t<path>" per directory-shaped entry
# directly inside <cli_dir> (a real directory, or a symlink resolving to
# one), ONE per resolved real path. #61 round-2 P2-2: real directories are
# walked FIRST and always keep their own name; a symlink is dropped the
# moment it resolves to a real path already seen — dedupe prefers the tank
# ITSELF, never whichever sorts first alphabetically (the previous bug: a
# symlink named `aalias` sorted before the real `zreal` it pointed at, so
# `aalias` won the dedupe and doctor then reported the REAL tank as a
# stray). A symlink whose target is NOT another entry here (an alias to
# something outside this cli_dir, or the only copy) keeps its own name —
# nothing to prefer it over.
#
# #61 round-2 P2-4 (measured after the first version of this function shipped
# with a per-process cache above it): TWO `find | sort` pipelines per engine
# dir — 4 forks — was cheap once, expensive still cached, because caching
# only removes the "asked 15 times" multiplier, not the base cost of asking
# once. One plain bash glob (what main itself uses) plus the builtin `[ -L ]`
# test classifies real-vs-symlink with ZERO extra forks; `cd && pwd -P` per
# entry is the one remaining fork and is inherent to resolving a realpath at
# all (also true of the code this replaced).
_tank_candidates() {
  local cli_dir="${1%/}" seen=$'\n' d name real
  local -a reals=() links=()
  for d in "$cli_dir"/*/; do
    [ -e "$d" ] || continue   # unmatched glob literal (empty cli_dir)
    d="${d%/}"
    if [ -L "$d" ]; then links+=("$d"); else reals+=("$d"); fi
  done
  # 🔴 `${a[@]+"${a[@]}"}`, not `"${a[@]}"` — bash 3.2 (every stock macOS) treats
  # an EMPTY array as UNSET, so `"${reals[@]}"` under `set -u` is
  # `links[@]: unbound variable` and the walk dies. Caught by round-6 P3-1's own
  # `set -u` test on the macOS CI runner and nowhere else: bash 4+ expands an
  # empty array to nothing, so this is invisible on Linux. Reachable for real —
  # any engine dir whose entries are all real (or all symlinks) leaves the other
  # array empty, and lib/hooks/cockpit-guard.sh is a `set -u` caller of this
  # walk. The `+` form expands to nothing when the array is unset OR empty.
  for d in ${reals[@]+"${reals[@]}"}; do
    name="${d##*/}"
    real="$(cd "$d" 2>/dev/null && pwd -P)" || continue
    case "$seen" in *$'\n'"$real"$'\n'*) continue ;; esac
    seen="$seen$real"$'\n'
    printf '%s\t%s\n' "$name" "$d"
  done
  for d in ${links[@]+"${links[@]}"}; do
    [ -d "$d" ] || continue   # broken symlink, or one pointing at a non-dir
    name="${d##*/}"
    real="$(cd "$d" 2>/dev/null && pwd -P)" || continue
    case "$seen" in *$'\n'"$real"$'\n'*) continue ;; esac
    seen="$seen$real"$'\n'
    printf '%s\t%s\n' "$name" "$d"
  done
}

# ── One-time inclusive tank adoption (#61 round-2 P1-1) ─────────────────────
# origin/main's clikae writes NO marker at all, and 12 of the 15 adapters
# never defined adapter_tank_fingerprint — so gating adoption on a
# per-adapter fingerprint (this PR's first pass) silently orphaned every
# existing kubectl/npm/terraform/… tank, and a codex tank nobody had logged
# into yet, the moment someone upgraded: 7 of 8 tanks vanished from every
# list, with no CLI command able to bring them back (`init` refuses an
# existing directory; `doctor` only named the gap).
#
# The fix is INCLUSIVE, not smarter fingerprinting: the very first command
# run against a store with no adoption flag sweeps EVERY directory under
# EVERY known engine and marks it a tank unless it is shaped like something
# that can never be one (_tank_shape_excluded) or is a symlink alias for a
# directory already adopted (_tank_candidates). No fingerprint required. The
# flag is then written so this sweep NEVER runs again — from here on a
# marker-less directory is not a tank, full stop, which is what keeps #61's
# own fix intact (`zzempty`, created AFTER adoption, stays refused forever).
CLIKAE_TANKS_ADOPTED_FLAG_NAME="tanks-adopted-v1"

# tanks_adopted_flag_path -> the one flag file gating the sweep above.
tanks_adopted_flag_path() { printf '%s/state/%s\n' "$CLIKAE_HOME" "$CLIKAE_TANKS_ADOPTED_FLAG_NAME"; }

# tanks_adopted_flag_write <path> -> best-effort write, verified by reading
# the file back (mkdir/printf can each silently no-op on some read-only
# mounts without ever returning nonzero). Same redirect-order fix as
# tank_marker_write above.
tanks_adopted_flag_write() {
  local flag="$1"
  mkdir -p "$(dirname "$flag")" 2>/dev/null || true
  printf '%s\n' "$CLIKAE_VERSION" 2>/dev/null > "$flag" || true
  [ -f "$flag" ]
}

# _tank_adoption_warn_once -> exactly ONE line, ONCE per user action, when
# the store's adoption flag cannot be persisted (a read-only store).
#
# #61 round-2 P2-1: the first version printed unconditionally on every call,
# and scan_clis' 15-adapter fan-out turned ONE read-only tank into 32
# identical lines.
#
# Rounds 3-4 deduped through a SENTINEL FILE in $TMPDIR (the store itself is
# unwritable, so it could not live there), removed by an EXIT trap. Round-5
# review measured what that actually bought: the file survived every path
# that `exec`s — bash runs no EXIT trap on exec, so `clikae claude <tank>`,
# the board's enter/`R`, `resume`, `clean` all left one behind — and, because
# an exec'd or forked clikae is a NEW process with a NEW sentinel name, the
# operator still got 2-3 WARN lines for ONE keypress. Chaining the cleanup
# into more traps could never fix the second half of that.
#
# So the dedupe is an EXPORTED VARIABLE instead: it is inherited across both
# `fork` and `exec`, needs no cleanup anywhere (there is no file to leak, on
# any exit, including SIGKILL), and costs no forks. `$$` keeps the original
# pid inside every subshell and command substitution, so the round-2 fan-out
# stays deduped exactly as before — and bin/clikae runs the sweep from its
# top-level shell (the hoist near the bottom of its preamble) BEFORE any
# subshell can, so the first warning is always the one whose export survives.
#
# 🔴 #61 round-6 P3-2: THE VALUE IS A SET OF STORE KEYS, NOT A BOOLEAN — and
# the trade written here before was measured to be two levels wider than it
# said. It claimed "stays quiet about THE SAME STORE"; the flag was `1`, keyed
# by nothing, so:
#
#   (a) it silenced EVERY store. A terminal warned about store A then said
#       nothing about a second, unrelated read-only store B (a mounted shared
#       store, `CLIKAE_HOME=/mnt/…`) — measured, both directions. Fixed here:
#       the value is `:<flag path>:<flag path>:` and the check is for THIS
#       store's key, so each store still gets its own line exactly once.
#
#   (b) it outlives this terminal. `tmux new-session` creates a server from
#       whoever started it when none is running, and that server's GLOBAL
#       environment table is frozen at birth and outlives every process here
#       (this file's own header in lib/core/tmux.sh, and roam.bats' lesson).
#       clikae warns BEFORE it spawns the server, so the server is born
#       carrying the key — and every pane opened on it afterwards, for days,
#       including ones a clean client opens, inherits it. switch.sh's explicit
#       `--env` list (what clikae deliberately passes into a session) does not
#       contain this variable; it rides in on that inheritance.
#
# (b) is NOT fixed here, and this is the honest description of what it costs
# rather than a claim that it does not happen: what is suppressed is one
# advisory line about ONE store whose read-only-ness is a stable fact of that
# machine, in panes belonging to the same operator who already read it. It
# cannot suppress anything about a different store (that is (a)), it cannot
# change what is adopted, and it self-clears the moment the store becomes
# writable — then the flag persists and this function is never reached at all
# (measured). The two mechanisms that could close it are both worse than the
# bug: a sentinel file is what rounds 3-4 already tried and had to remove, and
# stripping the variable in tmux_spawn_session would give the LAUNCH path two
# warnings for one keypress, which is round-2 P2-1 coming back.
#
# The deliberate trade that remains: a clikae run from INSIDE an engine
# session that this clikae exec'd stays quiet about the SAME store (now
# literally the same store). That operator has already read the line in this
# terminal; a warning repeated per keypress is how this started (round-2
# P2-1), and an unremovable file is what it became.
# _tank_marker_unreadable_warn_once <dir> -> exactly ONE line per process
# when a `.clikae-tank` marker exists but cannot be opened (#61 round-6 P3-1).
# Deduped through the same exported-variable mechanism as the adoption warning
# below, for the same reasons; not keyed by store, because "one line" is the
# whole point and a second unreadable marker is the same news.
#
# `declare -F log_warn` is NOT defensiveness for its own sake: the one caller
# that must survive this path, lib/hooks/cockpit-guard.sh, sources THIS file
# without lib/core/log.sh, under `set -uo pipefail`. A bare `log_warn` there
# is a command-not-found, and `log_warn`'s own body reads `$__C_YELLOW`, which
# is unbound in that process — either one would abort the very walk this
# branch exists to keep intact. Silence is the correct behaviour there: the
# hook's stderr is shown to the MODEL as the reason for a refusal it has
# nothing to do with (the same reasoning as _CLIKAE_ADOPT_READONLY below).
_tank_marker_unreadable_warn_once() {
  [ -z "${_CLIKAE_MARKER_WARNED:-}" ] || return 0
  _CLIKAE_MARKER_WARNED=1
  export _CLIKAE_MARKER_WARNED
  if declare -F log_warn >/dev/null 2>&1 && [ -n "${__C_YELLOW+x}" ]; then
    log_warn "A tank marker exists but cannot be read: $1/.clikae-tank — treating that directory as NOT a tank this run. Fix its permissions (or remove and re-adopt it with \`clikae init <engine> <name> --adopt\`); \`clikae doctor\` lists it."
  fi
  return 0
}

_tank_adoption_warn_once() {
  local _key _seen
  _key="$(tanks_adopted_flag_path)"
  _seen="${_CLIKAE_ADOPT_WARNED:-}"
  case "$_seen" in *":$_key:"*) return 0 ;; esac
  # A pathological number of distinct stores in one process tree must not grow
  # an unbounded environment variable; past the cap the oldest keys are simply
  # forgotten and that store gets its line again, which is the safe direction.
  [ "${#_seen}" -lt 2000 ] || _seen=""
  _CLIKAE_ADOPT_WARNED="${_seen:-:}$_key:"
  export _CLIKAE_ADOPT_WARNED
  log_warn "This store's tanks aren't adopted yet and the flag can't be written (read-only store?) — recognising them in memory this run only. \`clikae doctor --adopt\` explains more; fix permissions on $(dirname "$(tanks_adopted_flag_path)") to persist it."
}

_CLIKAE_INMEM_ADOPTED=$'\n'
_CLIKAE_INMEM_ADOPTED_ACTIVE=""
_CLIKAE_ADOPT_LAST_COUNT=0
_CLIKAE_ADOPT_LAST_FLAG_OK=0

# _tank_adoption_ensure -> run the sweep described above exactly once per
# store — a fast no-op once the on-disk flag exists. `clikae doctor --adopt`
# calls this SAME function, unconditionally: the flag-present check below is
# exactly the guarantee that must hold for --adopt too (an ALREADY-adopted
# store must never sweep again — that would readmit a directory like
# `zzempty` created after the one-time window closed). --adopt's only real
# effect is on a store whose flag genuinely never persisted (read-only),
# where it retries the same write this function already attempts on every
# call. Sets _CLIKAE_ADOPT_LAST_COUNT (markers newly written this call) and
# _CLIKAE_ADOPT_LAST_FLAG_OK (1 once the flag is confirmed on disk) for
# callers that report on it.
#
# _CLIKAE_ADOPT_READONLY=1 (#61 round-5 merge, with #63's cockpit-guard hook):
# 🔴 #61 round-6 P3-3: leading underscore, and compared to EXACTLY `1`. It was
# `CLIKAE_ADOPT_READONLY` tested with `[ -n … ]`, which reads from the outside
# as a supported knob and is not one — it has exactly one setter (the hook,
# below) and one reader (this function). Anyone who exported it into a shell,
# or set it to `0` meaning "off", got a clikae that re-swept the whole store on
# every single command, wrote no marker and no flag, and said nothing about
# either: the one-time adoption window that #61 round-5 P3-5 spent a commit
# CLOSING stayed open forever, and reopened a directory created long after it
# should have. The internal name says who owns it, and `= 1` means `0` is off.
#
# sweep IN MEMORY ONLY — write no markers, no flag, and warn about neither.
# For a process that is NOT `clikae` and has no business deciding this
# store's permanent shape: lib/hooks/cockpit-guard.sh runs as a Claude Code
# PreToolUse hook, in its own process, possibly before any clikae command has
# ever swept this store. Without this, sourcing profile_store.sh from there
# would (a) write the one-time flag from a context where tank_engine_known
# answers for no engine at all — permanently orphaning EVERY tank in the
# store — and (b) on a read-only store call _tank_adoption_warn_once, whose
# WARN would land in the hook's own stderr, which Claude Code shows to the
# MODEL as the reason for a refusal it has nothing to do with. In-memory
# adoption keeps the hook's own listing honest without it ever deciding
# anything on disk, or saying anything about it.
_tank_adoption_ensure() {
  local flag; flag="$(tanks_adopted_flag_path)"
  _CLIKAE_ADOPT_LAST_COUNT=0
  if [ -f "$flag" ]; then
    _CLIKAE_ADOPT_LAST_FLAG_OK=1
    return 0
  fi
  local root cli_dir cli name path
  root="$(profiles_root)"
  # #61 round-3 P1-2: bin/clikae now calls this unconditionally on every
  # invocation (see the hoist near its top) — including ones that must
  # create NO clikae state at all when they refuse before ever touching a
  # tank (three burn.bats "refuses before creating any clikae state" tests
  # rely on `$HOME/.clikae` not existing afterward). A store with no
  # profiles/ dir yet has nothing to adopt; bail out before ANY write (not
  # just before the walk below) so a genuinely fresh or nonexistent store is
  # left untouched. #61 round-5 P3-5: "a later command runs the sweep then"
  # used to be all that closed the window, and it left one open across the
  # whole of a brand-new store's FIRST command — ensure_profile calls this
  # again the moment it creates a tank, so the store that just gained its
  # first content is adopted and flagged inside that same command.
  [ -d "$root" ] || return 0
  _CLIKAE_INMEM_ADOPTED=$'\n'
  for cli_dir in "$root"/*/; do
    [ -d "$cli_dir" ] || continue
    cli="${cli_dir%/}"; cli="${cli##*/}"
    tank_engine_known "$cli" || continue
    while IFS=$'\t' read -r name path; do
      [ -n "$name" ] || continue
      _tank_shape_excluded "$name" && continue
      _CLIKAE_INMEM_ADOPTED="$_CLIKAE_INMEM_ADOPTED$cli"$'\t'"$name"$'\n'
      tank_dir_is_tank "$cli" "$path" && continue   # already marked
      [ "${_CLIKAE_ADOPT_READONLY:-}" = 1 ] && continue
      tank_marker_write "$cli" "$path"
      _CLIKAE_ADOPT_LAST_COUNT=$((_CLIKAE_ADOPT_LAST_COUNT + 1))
    done < <(_tank_candidates "${cli_dir%/}")
  done
  _CLIKAE_INMEM_ADOPTED_ACTIVE=1
  if [ "${_CLIKAE_ADOPT_READONLY:-}" = 1 ]; then
    # Nothing written, nothing to warn about: this run's answers live in
    # memory and die with the process.
    _CLIKAE_ADOPT_LAST_FLAG_OK=0
    return 0
  fi
  if tanks_adopted_flag_write "$flag"; then
    _CLIKAE_ADOPT_LAST_FLAG_OK=1
    _CLIKAE_INMEM_ADOPTED_ACTIVE=""   # on disk now — strict marker mode is correct
  else
    _CLIKAE_ADOPT_LAST_FLAG_OK=0
    _tank_adoption_warn_once
  fi
  return 0
}

# _tank_fingerprint_match <cli> <dir> -> 0 if <dir> holds content the ENGINE
# ITSELF creates in a tank, per that adapter's optional
# adapter_tank_fingerprint hook (one candidate path per line, relative to the
# tank dir; the first that exists wins). #61 round-2 P1-1: no longer a
# precondition for adoption (_tank_adoption_ensure above is inclusive) —
# kept as a read-only signal `doctor` uses to explain WHY a stray directory
# looks like it used to be a tank of a given engine.
#
# Runs load_adapter in a SUBSHELL: this can fire for an engine other than
# whichever one a caller further up already `load_adapter`'d, and clobbering
# THAT engine's functions out from under it would be exactly the kind of
# cross-talk "ONE ENUMERATOR, REALLY" exists to prevent.
_tank_fingerprint_match() {
  local cli="$1" dir="$2" fps f
  fps="$(
    load_adapter "$cli" >/dev/null 2>&1 || exit 0
    declare -F adapter_tank_fingerprint >/dev/null 2>&1 || exit 0
    adapter_tank_fingerprint
  )"
  [ -n "$fps" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -e "$dir/$f" ] && return 0
  done <<EOF
$fps
EOF
  return 1
}

# The process-level cache profiles_cache_warm fills (see below). Declared
# HERE, at file scope, not merely assigned inside that function: a caller
# running under `set -u` that sources this file and calls list_all_profiles
# without warming anything must not die on an unset variable —
# lib/hooks/cockpit-guard.sh (a Claude Code PreToolUse hook, its own process,
# `set -euo pipefail`) is exactly that caller.
_CLIKAE_PROFILES_CACHE_SET=""
_CLIKAE_PROFILES_CACHE=""

# List every profile as "<cli> <profile> <path>" lines, sorted. THE one
# enumerator (clikae tanks / burn's reroute / to's and resume's next_tank all
# read it). Cached per process once warmed — see profiles_cache_warm below;
# a caller that never warms it gets exactly one fresh walk per call, same as
# before.
list_all_profiles() {
  if [ -n "$_CLIKAE_PROFILES_CACHE_SET" ]; then
    [ -n "$_CLIKAE_PROFILES_CACHE" ] && printf '%s\n' "$_CLIKAE_PROFILES_CACHE"
    return 0
  fi
  _list_all_profiles_uncached
}

# _list_all_profiles_uncached -> the actual walk. Runs the one-time adoption
# sweep first (a fast no-op once this store's flag exists), then lists every
# surviving (cli, dir) pair whose marker names that cli — nothing here
# re-derives tank-ness from a NAME; _tank_candidates already resolved
# symlink aliases down to one entry per real directory.
_list_all_profiles_uncached() {
  _tank_adoption_ensure
  local root
  root="$(profiles_root)"
  [ -d "$root" ] || return 0
  local cli_dir cli name path
  for cli_dir in "$root"/*/; do
    [ -d "$cli_dir" ] || continue
    cli="${cli_dir%/}"; cli="${cli##*/}"
    tank_engine_known "$cli" || continue
    while IFS=$'\t' read -r name path; do
      [ -n "$name" ] || continue
      # #61 round-3 P1-1: this must be an `if`, not `cmd && printf` — under
      # `bin/clikae`'s `set -eo pipefail`, a `while` loop's exit status is
      # its LAST command's, so with `&&` the whole loop (and the `for`
      # around it, and this function's own `| sort` pipeline) returned 1
      # whenever the LAST candidate walked happened not to be a tank —
      # `doctor`/`status`/`info`/board all died silently (0 lines, rc 1)
      # under `set -e`, with completely correct stdout. Whether this
      # function succeeds must never be a function of which candidate
      # happens to sort last.
      if tank_dir_is_tank "$cli" "$path"; then
        printf '%s\t%s\t%s\n' "$cli" "$name" "$path"
      fi
    done < <(_tank_candidates "${cli_dir%/}")
  done | sort
  return 0
}

# profiles_cache_warm -> populate the process-level cache of
# list_all_profiles' own output, ONCE, for hot callers (doctor/board/status)
# that otherwise re-walk the whole store many times in one invocation (#61
# round-2 P2-4: doctor alone was ~20 full walks on one store — scan_clis'
# 15-adapter fan-out, each re-deriving the same rows via tanks_for_engine —
# 2.2s on 30 tanks vs main's 0.46s).
#
# MUST be called DIRECTLY, never through $(...): a command substitution
# forks a subshell, and a subshell's variable writes vanish the moment it
# exits — so the assignment below has to happen in the CALLER's own frame.
# Call it as the first thing a refresh does; every subshell forked AFTER
# that point (command substitutions, background jobs, scan_clis' per-adapter
# `( … )` blocks) inherits the already-populated cache by ordinary
# fork/copy, so list_all_profiles above can just print it back instead of
# re-walking. bash 3.2 (macOS's shipped bash) has no associative arrays — a
# single string var, exactly i18n.sh's own CLIKAE_LANG_RESOLVED pattern,
# needs none.
profiles_cache_warm() {
  [ -n "$_CLIKAE_PROFILES_CACHE_SET" ] && return 0
  _CLIKAE_PROFILES_CACHE_SET=1
  _CLIKAE_PROFILES_CACHE="$(_list_all_profiles_uncached)"
  # #61 round-3 P1-1: an explicit `return 0` at the end — callers (doctor,
  # status, home's board) call this DIRECTLY under `set -e`, so this
  # function's own rc must always be "cache populated", never whatever the
  # walk's command substitution happened to return (that walk's rc is now
  # fixed too, but this makes the guarantee explicit rather than incidental).
  return 0
}

# profiles_cache_reset -> forget the warmed cache. The interactive board is a
# single long-lived process that mutates tanks (init/rename/remove/solo) and
# re-derives its rows after every such action (_home_refresh) — without this,
# the FIRST refresh's cache would keep answering for the rest of the session,
# so a tank created mid-session would never appear. Callers that mutate then
# re-render call this before profiles_cache_warm on the next pass.
profiles_cache_reset() {
  _CLIKAE_PROFILES_CACHE_SET=""
  _CLIKAE_PROFILES_CACHE=""
}

# tanks_for_engine <cli> -> every real tank NAME under <cli>, one per line,
# sorted — exactly the subset of list_all_profiles' own output for this
# engine. #61 round-1 P2-6 ("ONE ENUMERATOR, REALLY"): six call sites besides
# list_all_profiles' existing callers were each re-deriving "which tanks does
# this engine have" with their own `for … in profiles_root/$cli/*/`, so a
# stray non-tank directory could reappear as a tank through any ONE of them
# even with list_all_profiles itself fully hardened (P1-3/P2-1/P2-2 above) —
# most pointedly lib/commands/settings.sh, which WRITES into whatever it
# finds. This is the one place that filter is written; everyone else reads
# it. Callers that also need the path use profile_dir(cli, tank) — a second
# lookup, not a second walk.
tanks_for_engine() {
  local cli="$1"
  list_all_profiles | awk -F'\t' -v c="$cli" '$1==c{print $2}'
}

# order_file -> the burn-order file. One "<engine>/<tank>" per line, top first.
# The board IS this order; there is no separate "pool". Optional — when absent or
# partial, order_list fills in the rest deterministically.
order_file() { printf '%s\n' "$CLIKAE_HOME/order"; }

# order_list -> every FLEET tank as "<engine>/<tank>", in BURN ORDER: first the
# order-file entries that still exist (in file order), then any remaining tanks in
# default (list_all_profiles) order. Always complete + deterministic, so callers
# never need to special-case "not configured".
# 🔴 SOLO TANKS ARE NOT IN THE BURN ORDER. Solo means "out of the fleet"
# (docs/grammar.md §127) — it is not a relay/`to` target and the burn/watch
# rotation skips it — so a solo tank holding a POSITION in the order was a
# contradiction the order file stated out loud. It also made the board lie:
# `_home_items` renders solo tanks in their own section at the bottom, so what
# you saw was never what the file said, and `[`/`]` wrote the interleaved file
# order back rather than the order on screen. Measured on a real store: 4 of 9
# order entries were solo, two of them at positions 2 and 4.
#
# The board is the burn order, and the burn order is the fleet. Callers wanting
# EVERY tank (the board, so it can draw the Solo section) add solo_list.
# Every membership test here used to be `printf | grep -qxF` — six forks per
# order-file line, on a list that is at most a few dozen entries. $all and $listed
# are instead kept as newline-FENCED strings (a leading and trailing \n), so a
# bash glob can anchor both ends of an entry: without the fence, "ude/work" would
# match inside "claude/work" and a renamed tank could shadow another one.
order_list() {
  local f all listed line e t rest
  all=$'\n'
  while IFS=$'\t' read -r e t rest; do
    : "$rest"
    [ -n "$e" ] && [ -n "$t" ] || continue
    tank_is_solo "$e" "$t" && continue
    all="$all$e/$t"$'\n'
  done <<EOF
$(list_all_profiles)
EOF
  [ "$all" = $'\n' ] && return 0
  f="$(order_file)"
  listed=$'\n'
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="${line//[[:space:]]/}"                       # was: tr -d '[:space:]'
      [ -n "$line" ] || continue
      [[ "$all"    == *$'\n'"$line"$'\n'* ]] || continue  # still exists?
      [[ "$listed" == *$'\n'"$line"$'\n'* ]] && continue  # de-dupe
      printf '%s\n' "$line"
      listed="$listed$line"$'\n'
    done < "$f"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ "$listed" == *$'\n'"$line"$'\n'* ]] && continue
    printf '%s\n' "$line"
  done <<EOF
$all
EOF
}

# solo_list -> every SOLO tank as "<engine>/<tank>", in default listing order.
# The complement of order_list: together they cover every tank exactly once. The
# board draws order_list as the fleet and this as the Solo section beneath it, so
# the rows on screen and the burn-order file finally describe the same thing.
solo_list() {
  local e t rest
  while IFS=$'\t' read -r e t rest; do
    : "$rest"
    [ -n "$e" ] && [ -n "$t" ] || continue
    tank_is_solo "$e" "$t" && printf '%s\n' "$e/$t"
  done <<EOF
$(list_all_profiles)
EOF
  return 0
}

# rename_tank_state <engine> <old> <new> — carry a tank's OUT-OF-DIR state across a
# rename. The tank directory itself moves (with its clikae-meta/{solo,git-identity}),
# and Soul membership is handled by soul_rename_member — but two records key the tank
# by NAME from OUTSIDE the dir and would be orphaned:
#   · the burn-order file ($CLIKAE_HOME/order) — a stale "engine/old" entry no longer
#     matches an existing tank, so order_list drops it and the renamed tank silently
#     falls to the BOTTOM of the board order.
#   · the dry marker ($CLIKAE_HOME/dry/<engine>/<old>) — a red-badge record left
#     pointing at a name that no longer exists.
#   · the burn sidecar (state/burn-sessions/<engine>/<old>, #74 round-1 P2-2)
#     — left behind, its burn sessions would still hide correctly (the filter
#     only ever reads a sid, never a path), but the file becomes an orphan
#     nothing ever cleans, sitting under a tank name that no longer exists.
# <engine> is the on-disk cli dir name (agy → antigravity) for the burn-order
# file and the dry marker — but NOT for the sidecar: burn.sh has always
# stored agy's sidecar under the literal directory name "agy" (its own
# adapter file is antigravity.sh, but nothing under state/burn-sessions/ was
# ever named to match), so translate here rather than push that alias
# further up the call chain. Best-effort throughout.
rename_tank_state() {
  local engine="$1" old="$2" new="$3"
  local sc_engine="$engine"
  [ "$sc_engine" = "antigravity" ] && sc_engine="agy"
  local sc_old="$CLIKAE_HOME/state/burn-sessions/$sc_engine/$old"
  local sc_new="$CLIKAE_HOME/state/burn-sessions/$sc_engine/$new"
  if [ -f "$sc_old" ]; then
    mkdir -p "$(dirname "$sc_new")" 2>/dev/null || true
    mv "$sc_old" "$sc_new" 2>/dev/null || true
  fi
  local of; of="$(order_file)"
  if [ -f "$of" ]; then
    local tmp; tmp="$(mktemp)"
    # Match the token the way order_list reads it (strip a trailing #comment and all
    # whitespace); rewrite only an exact "engine/old" line, leave everything else.
    if awk -v o="$engine/$old" -v n="$engine/$new" '
         { line=$0; sub(/#.*/,"",line); gsub(/[[:space:]]/,"",line)
           if (line==o) print n; else print $0 }
       ' "$of" > "$tmp" 2>/dev/null; then
      cat "$tmp" > "$of"   # write THROUGH the file (keep its inode/perms), don't mv
    fi
    rm -f "$tmp"
  fi
  if declare -F dry_store_path >/dev/null 2>&1; then
    local od nd; od="$(dry_store_path "$engine" "$old")"; nd="$(dry_store_path "$engine" "$new")"
    if [ -f "$od" ]; then
      mkdir -p "$(dirname "$nd")" 2>/dev/null || true
      mv "$od" "$nd" 2>/dev/null || true
    fi
  fi
  return 0
}

# remove_tank_burn_sidecar <engine> <tank> — rename_tank_state's twin for the
# DELETION half of a tank's lifecycle (#74 round-1 P2-2): a removed tank's
# burn sidecar used to stay on disk forever, an orphan under a tank name
# nothing else references. Same "agy" alias as rename_tank_state above.
# Best-effort: never blocks a tank removal.
remove_tank_burn_sidecar() {
  local engine="$1" tank="$2" sc_engine="$1"
  [ "$sc_engine" = "antigravity" ] && sc_engine="agy"
  rm -f "$CLIKAE_HOME/state/burn-sessions/$sc_engine/$tank" 2>/dev/null || true
  return 0
}

# next_tank <engine> <current>  -> the next tank to carry onward to when
# <engine>/<current> runs dry. The selector is a RING — circular, and both fuel-
# and account-aware:
#   · CIRCULAR — walk the burn order from AFTER <current>, then WRAP past the end
#     back to the top, stopping when we'd return to <current>. A tank earlier in
#     the order is still a valid reserve once the one you're on is dry (the old
#     "fall down once, never cycle" rule silently stranded everything above you).
#   · SAME-ENGINE FIRST — a real `relay` resumes the LIVE conversation, which only
#     the same engine can do; a cross-engine hop is a cold written brief. So we
#     prefer the nearest fuelled SAME-engine tank anywhere in the ring, and only
#     fall to a fuelled cross-engine tank when every same-engine tank is dry.
#   · ACCOUNT-AWARE — "dry" is limit_tank_dry, so a sibling sharing a dry account's
#     exhausted quota is skipped (no pointless hop onto the same empty tank).
#   · HONEST WHEN ALL DRY — echoes NOTHING if the whole ring is dry; the caller
#     says so rather than hopping onto a tank that has no fuel either.
# Echoes "<engine>\t<tank>" (TAB-separated), or empty.
next_tank() {
  local engine="$1" current="$2"
  local cur="$engine/$current"
  # Build the ring from ONE order_list pass (it used to run twice — and each run
  # is a directory walk + per-line greps): note <current>'s index, then slice
  # after + before (wrap-around). Not listed (edge) → walk everything, in order.
  local -a all=() ring=()
  local entry cur_idx=-1 i
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$cur" ] && cur_idx=${#all[@]}
    all+=("$entry")
  done <<EOF
$(order_list)
EOF
  if [ "$cur_idx" -ge 0 ]; then
    for ((i = cur_idx + 1; i < ${#all[@]}; i++)); do ring+=("${all[i]}"); done
    for ((i = 0; i < cur_idx; i++));               do ring+=("${all[i]}"); done
  else
    ring=(${all[@]+"${all[@]}"})   # same bash 3.2 empty-array trap as _tank_candidates
  fi
  [ "${#ring[@]}" -gt 0 ] || return 0

  # Dryness for the whole fleet in ONE batch (limit_dry_set computes each tank's
  # own signal exactly once, then resolves account contagion from that cache).
  # The old per-candidate limit_tank_dry re-ran the contagion scan — a full
  # list_all_profiles + an adapter-load subshell per sibling — for EVERY ring
  # candidate: O(n²) walks on a fleet of same-account tanks. Same verdicts.
  # Keys are newline-fenced "engine/tank" (names are validated: no newlines).
  local dry_keys=$'\n'
  if declare -F limit_dry_set >/dev/null 2>&1; then
    local de dt _r
    while IFS=$'\037' read -r de dt _r; do
      [ -n "$de" ] || continue
      dry_keys="$dry_keys$de/$dt"$'\n'
    done <<EOF
$(list_all_profiles | limit_dry_set)
EOF
  fi

  # Pass 1: nearest fuelled SAME-engine tank (real resume). Pass 2: any engine.
  local pass e t
  for pass in same any; do
    for entry in ${ring[@]+"${ring[@]}"}; do
      e="${entry%%/*}"; t="${entry#*/}"
      # agy/antigravity is global single-account — it can't be an auto carry-onward
      # target (handoff treats it as a no-/tank single-account target, so a ring
      # entry "antigravity/<tank>" would dead-end). Reach it explicitly instead.
      [ "$e" = "antigravity" ] && continue
      tank_is_solo "$e" "$t" && continue   # a solo tank is out of the fleet — never an auto carry-onward target
      [ "$pass" = "same" ] && [ "$e" != "$engine" ] && continue
      case "$dry_keys" in *$'\n'"$entry"$'\n'*) continue ;; esac
      printf '%s\t%s' "$e" "$t"; return 0
    done
  done
  # Whole ring dry → nothing. The caller surfaces "all dry" honestly.
  return 0
}

# resolve_tank_name <name>  -> "<engine>\t<tank>" line(s) for every tank whose
# NAME equals <name>, across all engines. Powers the bare `clikae <name>` shortcut
# (scheme B): a tank's name is its identity, so you can switch to it without typing
# the engine. 0 lines = no such name; 1 = unambiguous; >1 = same name in multiple
# engines (caller disambiguates).
resolve_tank_name() {
  local want="$1" cli profile
  [ -n "$want" ] || return 0
  while IFS=$'\t' read -r cli profile _; do
    [ -n "$cli" ] || continue
    [ "$profile" = "$want" ] && printf '%s\t%s\n' "$cli" "$profile"
  done <<EOF
$(list_all_profiles)
EOF
}

# resolve_active_profile <cli> <strategy> <value>
# Given the live value of an adapter's env var, echo the clikae profile it
# corresponds to (or nothing). Used by `clikae status` and `clikae relay` to
# answer "which profile is this CLI on right now?".
#   env-var strategy  -> the value IS the profile name (e.g. AWS_PROFILE=work)
#   everything else   -> the value is a path; match it to a profile dir (a
#                        profile dir, or a file/subpath seeded inside one)
resolve_active_profile() {
  local cli="$1" strategy="$2" value="$3"
  [ -n "$value" ] || return 0
  case "$strategy" in
    env-var)
      profile_exists "$cli" "$value" && printf '%s\n' "$value"
      ;;
    *)
      # #61 round-1 P2-6: this used to be its own `for … in profiles_root/
      # $cli/*/` — a second walk inside the very file that claims to own the
      # one true walk (list_all_profiles, above). Routed through
      # tanks_for_engine so a stray non-tank directory can never resolve as
      # the "active" profile here even when its path happens to match.
      local norm="${value%/}" pdir profile
      while IFS= read -r profile; do
        [ -n "$profile" ] || continue
        pdir="$(profile_dir "$cli" "$profile")"
        if [ "$norm" = "$pdir" ] || case "$norm" in "$pdir"/*) true ;; *) false ;; esac; then
          printf '%s\n' "$profile"
          return 0
        fi
      done <<EOF
$(tanks_for_engine "$cli")
EOF
      ;;
  esac
}

# Ensure profile_dir exists. Pass --create to mkdir, --require to fail if missing.
ensure_profile() {
  local mode="$1" cli="$2" profile="$3"
  local d
  d="$(profile_dir "$cli" "$profile")"
  case "$mode" in
    --create)
      # #61 round-5 P3-7: log_fail, not a bare mkdir. This function runs
      # inside a command substitution, where a silent failure here reaches
      # the caller as an empty string and an exit status `local x="$(…)"`
      # throws away — which is how `init` came to print "Created tank" for a
      # directory it had not created.
      mkdir -p "$d" || log_fail "Could not create $d"
      # Stamp the state-schema version alongside the first state we create, so an
      # existing install is always identifiable for future migrations (read commands
      # then never need to write it). Guarded — older callers may not have it sourced.
      declare -F state_version_ensure >/dev/null 2>&1 && state_version_ensure
      # #61 round-1 P1-3: this is THE one creation point every env-adapter
      # engine's `clikae init` goes through (agy is symlink-managed and never
      # calls ensure_profile — it stamps its own marker directly, see
      # lib/commands/antigravity.sh). A tank is a directory clikae MADE or
      # ADOPTED, so the tank clikae is making right now gets its marker before
      # anything else runs (adapter_init, the permissions template, …).
      # `rename` MOVES this file with the directory (no separate handling
      # needed — the marker only names the ENGINE, which a rename never
      # changes); `remove` deletes the directory, marker included.
      tank_marker_write "$cli" "$d"
      # #61 round-5 P3-5: and CLOSE the one-time adoption window, which the
      # hoist in bin/clikae cannot close on a brand-new store — it runs
      # before any command has created profiles/, and bails without writing
      # the flag because there is nothing there to adopt. The tank we just
      # made IS that first content, so the sweep belongs here, right after
      # it: otherwise the window stayed open until the SECOND clikae command,
      # and a directory that appeared in between (round-1 P1-3's `mkdir
      # zzempty`) was swept up as a real tank. A no-op single `[ -f ]` once
      # the flag exists, which is every case but the very first tank.
      _tank_adoption_ensure
      ;;
    --require)
      [ -d "$d" ] || log_fail "Profile not found: $cli/$profile  (expected at $d)"
      ;;
    *)
      log_fail "ensure_profile: unknown mode '$mode'"
      ;;
  esac
  printf '%s\n' "$d"
}
