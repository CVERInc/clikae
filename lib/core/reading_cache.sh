# shellcheck shell=bash
# Per-file parsed readings. Identity includes the path, size and mtime; empty
# results and unsuccessful readings are cached too. Never cache rendered ages.

# _reading_cache_keyv <file> -> "<size>:<mtime-with-subsecond-precision>", one
# `stat` call. Sub-second precision (not just whole seconds) because an
# append-only transcript always grows in size and so is safe either way, but a
# same-size overwrite within the same wall-clock second is not — this repo
# already has a test for exactly that shape on the OLDER, single-purpose codex
# cache (limit_codex_status_cached's "SAME wall-clock second" case). GNU's
# fractional-seconds modifier / BSD's `F` sub-format, DETECTED via
# _clikae_statv — never `stat -c … || stat -f …` (see _clikae_statv's own
# red-flagged history in profile_store.sh: on a GNU machine, `-f` means
# --file-system, not "try the BSD flag").
_reading_cache_keyv() {
  _clikae_statv
  if [ "$_CLIKAE_STAT_FMT" = '%Y %n' ]; then
    stat -L -c '%s:%.9Y' "$1" 2>/dev/null
  else
    stat -L -f '%z:%Fm' "$1" 2>/dev/null
  fi
}

reading_cache_run() {
  local kind="$1" f="$2"; shift 2
  local key id root cache saved rc value tmp
  [ -f "$f" ] || { "$@"; return $?; }
  key="$(_reading_cache_keyv "$f")" || { "$@"; return $?; }
  key="$f:$key"
  id="$(printf '%s' "$kind:$f" | cksum)"; id="${id%% *}"
  root="${CLIKAE_HOME:-$HOME/.clikae}/state/readings"
  cache="$root/$kind-$id"
  if [ -f "$cache" ]; then
    {
      IFS= read -r saved
      IFS= read -r rc
      if [ "$saved" = "$key" ]; then
        case "$rc" in 0|1) cat; return "$rc" ;; esac
      fi
    } < "$cache"
  fi
  rc=0; value="$("$@")" || rc=$?
  # mktemp, rather than $$: sibling command substitutions share a shell PID.
  if mkdir -p "$root" 2>/dev/null; then
    tmp="$(mktemp "$cache.XXXXXX" 2>/dev/null)" || tmp=""
    if [ -n "$tmp" ]; then
      { printf '%s\n%s\n%s' "$key" "$rc" "$value" > "$tmp" && mv -f "$tmp" "$cache"; } 2>/dev/null || rm -f "$tmp"
    fi
  fi
  printf '%s' "$value"
  return "$rc"
}
