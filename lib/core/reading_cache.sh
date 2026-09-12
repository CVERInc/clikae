# shellcheck shell=bash
# Per-file parsed readings. Identity includes the path, size and mtime; empty
# results and unsuccessful readings are cached too. Never cache rendered ages.
reading_cache_run() {
  local kind="$1" f="$2"; shift 2
  local key id root cache saved rc value tmp
  [ -f "$f" ] || { "$@"; return $?; }
  key="$(stat -L -c '%s:%Y' "$f" 2>/dev/null || stat -L -f '%z:%m' "$f" 2>/dev/null)" || { "$@"; return $?; }
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
