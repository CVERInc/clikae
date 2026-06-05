# shellcheck shell=bash
# lib/core/dry_store.sh — persist a "this tank is dry until ~X" marker that LIVE
# catchers (burn's codex-exec stdout, _switch_supervise) write the moment they see
# a limit, so the PASSIVE board (clikae home) can light a red dot and show the
# vendor's verbatim reset phrase for engines whose limit never lands in a file.
#
# Why this exists: claude writes its limit into the transcript and agy into a log
# (both scannable after the fact), so home reads them directly. codex's limit is
# exec-stdout-only and vanishes when the run ends (burn-verified 2026-06-01). burn
# ALREADY detects it (limit_output_dry, which even extracts the reset phrase) but
# had nowhere to record it — so a passive `clikae home` opened later saw nothing.
# This is that record: the "dry-until window" limit.sh gestured at but never built.
#
# Honest by construction: the vendor's reset phrase is stored VERBATIM (never
# parsed into a countdown), and a marker self-clears two ways — a successful run
# clears it explicitly, and a conservative TTL ages it out. So a stale marker can
# never pin a tank red forever; better to turn green early and let the user retry
# than to fake a red. Best-effort throughout: a badge is a nicety, not a promise,
# so write/read failures degrade to "not dry" rather than abort the caller.

# CLIKAE_DRY_TTL — how long a dry marker is trusted before it's treated as stale.
# codex's usage window is ~5h; 6h is a touch generous so we don't clear a tank
# that's still genuinely limited. Overridable (tests pin it small).
: "${CLIKAE_DRY_TTL:=21600}"   # 6h, in seconds

# dry_store_path <engine> <tank> -> the marker file for this tank.
dry_store_path() { printf '%s/dry/%s/%s\n' "$CLIKAE_HOME" "$1" "$2"; }

# dry_store_mark <engine> <tank> [reset_phrase] -> record that this tank is dry as
# of NOW, carrying the vendor's verbatim reset phrase (may be empty). One line:
# "<epoch>\t<reset_phrase>". A write failure is non-fatal.
#
# Format note: this line layout is part of the $CLIKAE_HOME state schema (see
# lib/core/state_version.sh / CLIKAE_STATE_VERSION). If it ever needs a new field,
# bump the schema version and add a migration rather than parsing both shapes here.
dry_store_mark() {
  local engine="$1" tank="$2" reset="${3:-}" f now
  f="$(dry_store_path "$engine" "$tank")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  reset="$(printf '%s' "$reset" | tr -d '\n\r')"   # keep the record one line
  now="$(date +%s 2>/dev/null || echo 0)"
  printf '%s\t%s\n' "$now" "$reset" > "$f" 2>/dev/null || true
}

# dry_store_read <engine> <tank> -> 0 (dry) + echo the verbatim reset phrase if a
# FRESH marker exists; 1 otherwise. A marker older than CLIKAE_DRY_TTL is stale →
# lazily removed and reported not-dry (turn green early rather than pin red).
dry_store_read() {
  local engine="$1" tank="$2" f line stamp reset now age
  f="$(dry_store_path "$engine" "$tank")"
  [ -f "$f" ] || return 1
  IFS= read -r line < "$f" 2>/dev/null || return 1
  stamp="${line%%$'\t'*}"
  reset="${line#*$'\t'}"
  [ "$reset" = "$line" ] && reset=""        # no TAB in the line → no phrase
  case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
  now="$(date +%s 2>/dev/null || echo 0)"
  age=$(( now - stamp ))
  if [ "$stamp" -gt 0 ] && [ "$age" -ge "$CLIKAE_DRY_TTL" ]; then
    rm -f "$f" 2>/dev/null || true
    return 1
  fi
  printf '%s' "$reset"
  return 0
}

# dry_store_clear <engine> <tank> -> forget this tank's dry marker (a successful
# run recovered it). Silent if there was none.
dry_store_clear() {
  rm -f "$(dry_store_path "$1" "$2")" 2>/dev/null || true
}

# dry_store_epoch <engine> <tank> -> echo the epoch this marker was recorded, or
# return 1 if there's no usable marker. Feeds dry_seen_suffix for the board annotation.
dry_store_epoch() {
  local f line stamp; f="$(dry_store_path "$1" "$2")"
  [ -f "$f" ] || return 1
  IFS= read -r line < "$f" 2>/dev/null || return 1
  stamp="${line%%$'\t'*}"
  case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$stamp"
}

# dry_seen_suffix <epoch> -> "  · seen HH:MM" (localised) for the LOCAL time a frozen
# observation was captured, or empty for a bad/empty epoch. Shared by every reset
# that is a SNAPSHOT rather than a live reading — codex (its dry_store marker) and
# agy (its limit log's mtime) — so they annotate consistently. The point: those
# engines report a time we can't trust as live (codex gives UTC for whichever limit
# window the headless run hit; agy gives a relative "Resets in 3h" frozen at its last
# run), so stating WHEN we observed it frames the number honestly. claude is exempt —
# its dry is re-read live each render and its phrase is already absolute + timezoned.
# We only ever stamp our OWN observation time; we never parse or convert the vendor's.
dry_seen_suffix() {
  local stamp="${1:-}" hm
  case "$stamp" in ''|*[!0-9]*) return 0 ;; esac
  hm="$(date -r "$stamp" '+%H:%M' 2>/dev/null || date -d "@$stamp" '+%H:%M' 2>/dev/null)" || return 0
  [ -n "$hm" ] && printf '  · %s' "$(printf "$T_DRY_SEEN" "$hm")"
}
