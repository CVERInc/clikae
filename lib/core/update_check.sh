# shellcheck shell=bash
# lib/core/update_check.sh — "✨ a newer clikae is out" — a quiet, opt-out update
# notice shown on the home board (the moment before you launch a tank), modelled on
# codex's startup prompt: ✨ banner + a 3-way choice (update now / skip / skip this
# version). Nothing here ever runs on a non-TTY path (the board gates it), so pipes,
# scripts and the test suite never see a prompt or a network call.
#
# DNA: help quietly, never nag, stay honest.
#   • Throttled — the network check runs at most once per CLIKAE_UPDATE_TTL (24h),
#     stamped in a cache; every other open just reads the cache (instant, offline-OK).
#   • Opt-out — CLIKAE_NO_UPDATE_CHECK=1 disables the check AND the prompt entirely.
#   • Honest about the upgrade — "Update now" runs the command for the install method
#     we can actually detect (brew / curl); if we CAN'T tell, we only SHOW the command
#     rather than guess-and-run something wrong.
#   • Self-limiting — "skip this version" suppresses the nag until a version newer
#     than the skipped one appears.

: "${CLIKAE_UPDATE_TTL:=86400}"   # 24h, in seconds — how long the cached check is trusted

_update_cache_file() { printf '%s/cache/update-check' "$CLIKAE_HOME"; }   # "<epoch>\t<version>"
_update_skip_file()  { printf '%s/cache/update-skip'  "$CLIKAE_HOME"; }   # "<version>"

# update_version_gt <a> <b> -> 0 if a > b, 1 otherwise. Numeric per dot-segment
# (so 0.5.10 > 0.5.9, not the string compare that would say otherwise). Any non-digit
# in a segment (a "v" prefix, a "-beta" tail) is stripped to its digits. bash 3.2-safe.
update_version_gt() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 1
  local -a aa bb; local i max x y
  IFS=. read -ra aa <<< "$a"      # split on dots into numeric segments
  IFS=. read -ra bb <<< "$b"
  max=${#aa[@]}
  [ "${#bb[@]}" -gt "$max" ] && max=${#bb[@]}
  for ((i = 0; i < max; i++)); do
    x="${aa[i]:-0}"; y="${bb[i]:-0}"
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 1
}

# _update_cached_version -> echo the cached latest version (may be empty), or return 1.
_update_cached_version() {
  local f line; f="$(_update_cache_file)"
  [ -f "$f" ] || return 1
  IFS= read -r line < "$f" 2>/dev/null || return 1
  local v="${line#*$'\t'}"; [ "$v" = "$line" ] && v=""   # no TAB → no version
  printf '%s' "$v"
}

# update_check_refresh -> if enabled and the cache is stale, fetch the latest release
# tag from GitHub and rewrite the cache. Synchronous but tight (--max-time 2) and only
# once per TTL, so the cost is at most a ~2s pause once a day; offline just fails quiet.
# The cache stamp is bumped BEFORE the fetch so a failing/offline attempt doesn't retry
# every single open. No-op without curl, or when CLIKAE_NO_UPDATE_CHECK is set.
update_check_refresh() {
  [ -z "${CLIKAE_NO_UPDATE_CHECK:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local f line stamp now tag; f="$(_update_cache_file)"
  now="$(date +%s 2>/dev/null || echo 0)"
  if [ -f "$f" ]; then
    IFS= read -r line < "$f" 2>/dev/null || line=""
    stamp="${line%%$'\t'*}"; case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
    [ "$((now - stamp))" -lt "${CLIKAE_UPDATE_TTL:-86400}" ] && return 0   # still fresh
  fi
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  # Throttle even on failure: stamp now, keep whatever version we already knew.
  printf '%s\t%s\n' "$now" "$(_update_cached_version 2>/dev/null || true)" > "$f" 2>/dev/null || true
  tag="$(curl -fsSL --max-time 2 "https://api.github.com/repos/CVERInc/clikae/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/')"
  [ -n "$tag" ] && printf '%s\t%s\n' "$now" "$tag" > "$f" 2>/dev/null || true
  return 0
}

# update_check_pending -> 0 + echo the newer version if one is available and not being
# skipped; 1 otherwise. Pure (reads cache only) — no network, so it's cheap and the
# tests drive it by seeding the cache. The gate: cached latest must be > CLIKAE_VERSION,
# AND (if a version was "skip"ed) latest must be newer than that skipped version.
update_check_pending() {
  [ -z "${CLIKAE_NO_UPDATE_CHECK:-}" ] || return 1
  local latest skip; latest="$(_update_cached_version 2>/dev/null || true)"
  [ -n "$latest" ] || return 1
  update_version_gt "$latest" "${CLIKAE_VERSION:-0}" || return 1
  skip="$(cat "$(_update_skip_file)" 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -n "$skip" ]; then
    update_version_gt "$latest" "$skip" || return 1   # not newer than what was skipped → stay quiet
  fi
  printf '%s' "$latest"
}

# update_check_skip <version> -> remember not to nag again until something newer than
# <version> ships.
update_check_skip() {
  local f; f="$(_update_skip_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$f" 2>/dev/null || true
}

# update_install_method -> brew | curl | unknown, from the RESOLVED install root
# (CLIKAE_ROOT already follows symlinks). brew's libexec lives under .../Cellar/clikae/;
# the curl installer lands under ~/.local. Anything else → unknown (we won't guess).
update_install_method() {
  case "$CLIKAE_ROOT" in
    */Cellar/clikae/*) printf 'brew'; return 0 ;;
  esac
  if command -v brew >/dev/null 2>&1; then
    local p; p="$(brew --prefix 2>/dev/null || true)"
    [ -n "$p" ] && case "$CLIKAE_ROOT" in "$p"/*) printf 'brew'; return 0 ;; esac
  fi
  case "$CLIKAE_ROOT" in
    "$HOME"/.local|"$HOME"/.local/*) printf 'curl'; return 0 ;;
  esac
  printf 'unknown'
}

# update_upgrade_command -> the exact shell command that upgrades THIS install, or
# empty when the method is unknown (caller then just shows the release page).
update_upgrade_command() {
  case "$(update_install_method)" in
    brew) printf 'brew upgrade clikae' ;;
    curl) printf 'curl -fsSL https://raw.githubusercontent.com/CVERInc/clikae/main/install.sh | bash' ;;
    *)    printf '' ;;
  esac
}
