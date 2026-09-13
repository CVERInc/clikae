# shellcheck shell=bash
# Shared, atomic usage cache. Only normalized public readings reach disk.
usage_unknown() {
  printf '%s\n' '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"unknown"}'
}

usage_read() (
  local engine="$1" tank="$2" fresh="${3:-0}" cache now ttl reading tmp
  cache="$CLIKAE_HOME/state/usage/$engine/$tank.json"
  now="$(date +%s)"; ttl="${CLIKAE_USAGE_TTL:-120}"
  case "$ttl" in ''|*[!0-9]*) ttl=120 ;; esac
  command -v jq >/dev/null 2>&1 || { usage_unknown; return; }
  if [ "$fresh" != 1 ] && [ -f "$cache" ] &&
     jq -e --argjson now "$now" --argjson ttl "$ttl" \
       '.cached_at <= $now and ($now - .cached_at < $ttl)' "$cache" >/dev/null 2>&1; then
    jq -c 'del(.cached_at)' "$cache"; return
  fi
  reading=""
  if [ -f "$CLIKAE_LIB/adapters/$engine.sh" ]; then
    load_adapter "$engine"
    if declare -F adapter_usage >/dev/null; then
      reading="$(adapter_usage "$(profile_dir "$engine" "$tank")" 2>/dev/null)" || reading=""
    fi
  fi
  [ -n "$reading" ] || reading="$(usage_unknown)"
  # Whitelist fields: never cache a vendor error body or credentials.
  reading="$(printf '%s' "$reading" | jq -ce '
    def pct: if type == "number" and . >= 0 and . <= 100 then . else null end;
    def stamp: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9]{2}:[0-9]{2})$") then . else null end;
    {window_pct:(.window_pct|pct),weekly_pct:(.weekly_pct|pct),
     window_resets_at:(.window_resets_at|stamp),weekly_resets_at:(.weekly_resets_at|stamp),
     source:(if .source == "vendor" then "vendor" else "unknown" end)}')" || reading="$(usage_unknown)"
  umask 077
  if mkdir -p "${cache%/*}" && tmp="$(mktemp "$cache.XXXXXX")"; then
    if printf '%s' "$reading" | jq -c --argjson now "$now" '. + {cached_at:$now}' > "$tmp"; then
      mv -f "$tmp" "$cache"
    else rm -f "$tmp"; fi
  fi
  printf '%s\n' "$reading"
)

# Board reads only: never do network I/O during a redraw. Expired readings
# fall back to the existing transcript/expired-reset state.
usage_cached_fields() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json" ttl="${CLIKAE_USAGE_TTL:-120}"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  case "$ttl" in ''|*[!0-9]*) ttl=120 ;; esac
  jq -er --argjson now "$(date +%s)" --argjson ttl "$ttl" '
    select(.source == "vendor" and .cached_at <= $now and ($now-.cached_at < $ttl)) |
    select(.window_pct != null and .weekly_pct != null) |
    select(all([.window_resets_at,.weekly_resets_at][];
      . == null or ((try (sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) catch ($now+1)) > $now))) |
    [.window_pct,.weekly_pct,([.window_pct,.weekly_pct]|max)] | @tsv' "$cache" 2>/dev/null
}
