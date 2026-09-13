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

# Cache-only peek: never calls the vendor, never forks the adapter, never
# writes. burn's candidate ranking (P2-2, round-1 review) needs a headroom
# number to order tanks by — but burn's launch/reroute path must not pay a
# vendor round-trip (up to --max-time 8 EACH, serialized per candidate) just
# to pick one. Unlike usage_cached_fields below, a STALE reading is still
# returned here (stale headroom beats no headroom for ranking purposes);
# only a missing cache, missing jq, or a non-vendor/incomplete reading is
# "unknown" (empty stdout, rc=1). Fresh reads happen only in `clikae usage`
# (usage_read, optionally --fresh) and in the board's own refresh step.
usage_cache_peek() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -er '
    select(.source == "vendor") |
    select(.window_pct != null and .weekly_pct != null) |
    [.window_pct,.weekly_pct,([.window_pct,.weekly_pct]|max)] | @tsv' "$cache" 2>/dev/null
}

# Board reads only: never do network I/O during a redraw. Expired readings
# fall back to the existing transcript/expired-reset state. `now` may be
# passed in (epoch seconds) so a caller doing several lookups in one redraw
# forks `date` once, not once per lookup (P2-1, round-1 review) — see
# lib/commands/home.sh's _home_fuel_dotv memoization.
#
# P2-3 (round-1 review): the vendor's real reset instant is
# "2026-09-13T14:50:00.189940+00:00" — microseconds AND a "+00:00" offset,
# never the bare "…Z" jq's fromdateiso8601 requires. The old guard fed the
# raw string straight in, the `catch` swallowed the resulting parse error,
# and the select() below fell open ("not yet expired") on every real
# reading — dead code that had never once fired against an actual vendor
# response (tests/bats/usage.bats's fixture used "2099-01-01T00:00:00Z",
# a shape the vendor never sends). `norm_stamp` is the one place both
# fields go through: drop fractional seconds, then turn a UTC-zero
# "+00:00"/"-00:00" offset into "Z" (any other offset still fails to parse
# and still fails open — unchanged, and no real vendor sends one).
usage_cached_fields() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json" ttl="${CLIKAE_USAGE_TTL:-120}" now="${3:-}"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  case "$ttl" in ''|*[!0-9]*) ttl=120 ;; esac
  [ -n "$now" ] || now="$(date +%s)"
  jq -er --argjson now "$now" --argjson ttl "$ttl" '
    def norm_stamp: sub("\\.[0-9]+";"") | sub("[+-]00:00$";"Z");
    select(.source == "vendor" and .cached_at <= $now and ($now-.cached_at < $ttl)) |
    select(.window_pct != null and .weekly_pct != null) |
    select(all([.window_resets_at,.weekly_resets_at][];
      . == null or ((try (norm_stamp | fromdateiso8601) catch ($now+1)) > $now))) |
    [.window_pct,.weekly_pct,([.window_pct,.weekly_pct]|max)] | @tsv' "$cache" 2>/dev/null
}
