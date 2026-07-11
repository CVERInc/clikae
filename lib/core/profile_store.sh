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

# profile_dir <cli> <profile>
profile_dir() {
  printf '%s/profiles/%s/%s\n' "$CLIKAE_HOME" "$1" "$2"
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

# ── Bounded transcript reads ────────────────────────────────────────────────
# Session transcripts get HUGE (100+ MB for a long agent run); scanning a whole
# one PER TANK is what made the home board crawl (dogfood 2026-06-29: ~8s on a
# 1.6 GB tank — `limit_profile_dry` + the recap each `grep`'d the full file).
# Every signal we actually need sits at a known END of the file:
#   • ai-title / opening prompt / cwd → near the HEAD (first lines)
#   • newest usage-limit marker / newest turn / latest recap → near the TAIL
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
sessions_by_mtime() {
  if stat --version 2>/dev/null | grep -q GNU; then
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
solo_marker_file() {
  local cli="$1"; [ "$cli" = "agy" ] && cli="antigravity"
  printf '%s/clikae-meta/solo\n' "$(profile_dir "$cli" "$2")"
}
tank_is_solo() { [ -f "$(solo_marker_file "$1" "$2")" ]; }

# List every profile as "<cli> <profile> <path>" lines, sorted.
list_all_profiles() {
  local root
  root="$(profiles_root)"
  [ -d "$root" ] || return 0
  local cli_dir cli profile_path profile
  for cli_dir in "$root"/*/; do
    [ -d "$cli_dir" ] || continue
    cli="${cli_dir%/}"; cli="${cli##*/}"
    for profile_path in "$cli_dir"*/; do
      [ -d "$profile_path" ] || continue
      profile="${profile_path%/}"; profile="${profile##*/}"
      printf '%s\t%s\t%s\n' "$cli" "$profile" "${profile_path%/}"
    done
  done | sort
}

# order_file -> the burn-order file. One "<engine>/<tank>" per line, top first.
# The board IS this order; there is no separate "pool". Optional — when absent or
# partial, order_list fills in the rest deterministically.
order_file() { printf '%s\n' "$CLIKAE_HOME/order"; }

# order_list -> every EXISTING tank as "<engine>/<tank>", in BURN ORDER: first the
# order-file entries that still exist (in file order), then any remaining tanks in
# default (list_all_profiles) order. Always complete + deterministic, so callers
# never need to special-case "not configured".
order_list() {
  local f all listed line
  all="$(list_all_profiles | awk -F'\t' 'NF>=2{print $1"/"$2}')"
  [ -n "$all" ] || return 0
  f="$(order_file)"
  listed=""
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [ -n "$line" ] || continue
      printf '%s\n' "$all" | grep -qxF "$line" || continue       # still exists?
      printf '%s\n' "$listed" | grep -qxF "$line" && continue    # de-dupe
      printf '%s\n' "$line"
      listed="$listed$line"$'\n'
    done < "$f"
  fi
  printf '%s\n' "$all" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$listed" | grep -qxF "$line" && continue
    printf '%s\n' "$line"
  done
}

# next_tank <engine> <current>  -> the next tank to carry onward to when
# <engine>/<current> runs dry. The selector is a RING — circular, and both fuel-
# and account-aware:
#   • CIRCULAR — walk the burn order from AFTER <current>, then WRAP past the end
#     back to the top, stopping when we'd return to <current>. A tank earlier in
#     the order is still a valid reserve once the one you're on is dry (the old
#     "fall down once, never cycle" rule silently stranded everything above you).
#   • SAME-ENGINE FIRST — a real `relay` resumes the LIVE conversation, which only
#     the same engine can do; a cross-engine hop is a cold written brief. So we
#     prefer the nearest fuelled SAME-engine tank anywhere in the ring, and only
#     fall to a fuelled cross-engine tank when every same-engine tank is dry.
#   • ACCOUNT-AWARE — "dry" is limit_tank_dry, so a sibling sharing a dry account's
#     exhausted quota is skipped (no pointless hop onto the same empty tank).
#   • HONEST WHEN ALL DRY — echoes NOTHING if the whole ring is dry; the caller
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
    ring=("${all[@]}")
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
    for entry in "${ring[@]}"; do
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
      local norm="${value%/}" pdir profile root
      root="$(profiles_root)/$cli"
      [ -d "$root" ] || return 0
      for pdir in "$root"/*/; do
        [ -d "$pdir" ] || continue
        pdir="${pdir%/}"
        profile="${pdir##*/}"
        if [ "$norm" = "$pdir" ] || case "$norm" in "$pdir"/*) true ;; *) false ;; esac; then
          printf '%s\n' "$profile"
          return 0
        fi
      done
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
      mkdir -p "$d"
      # Stamp the state-schema version alongside the first state we create, so an
      # existing install is always identifiable for future migrations (read commands
      # then never need to write it). Guarded — older callers may not have it sourced.
      declare -F state_version_ensure >/dev/null 2>&1 && state_version_ensure
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
