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
  # P3 (round-2 review, "codex reading gets a TTL like claude's"): the
  # cache-hit check below used to key off `cached_at` alone — fine for a
  # vendor reading (cached_at IS the fetch time) but wrong for codex's
  # transcript readings, whose `cached_at` is the EVENT's own timestamp
  # (P2-4, round-1 review — deliberate, so a stale reading is never lied
  # about as fresh). Since codex only writes a token_count event
  # occasionally, `cached_at` is almost always older than $ttl, so this
  # check never hit and `clikae usage codex` re-scanned the ENTIRE rollout
  # store on every call (measured: 85ms/82ms back-to-back, zero cache hits).
  # `scanned_at` is the wall-clock time of the last actual scan, separate
  # from the reading's own evidentiary timestamp — that's what a cache-hit
  # check should mean, the same thing it already means for a vendor read
  # (where the two coincide). `// .cached_at` falls back for any cache file
  # written before this field existed.
  if [ "$fresh" != 1 ] && [ -f "$cache" ] &&
     jq -e --argjson now "$now" --argjson ttl "$ttl" \
       '(.scanned_at // .cached_at) as $s | $s <= $now and ($now - $s < $ttl)' "$cache" >/dev/null 2>&1; then
    jq -c 'del(.cached_at, .scanned_at)' "$cache"; return
  fi
  reading=""
  if [ -f "$CLIKAE_LIB/adapters/$engine.sh" ]; then
    load_adapter "$engine"
    if declare -F adapter_usage >/dev/null; then
      reading="$(adapter_usage "$(profile_dir "$engine" "$tank")" 2>/dev/null)" || reading=""
    fi
  fi
  [ -n "$reading" ] || reading="$(usage_unknown)"
  # P2-4 (round-1 review): a reading can be honest evidence without a LIVE
  # vendor call behind it (codex's is derived from a rollout transcript it
  # already wrote) — pull out the event's own timestamp BEFORE whitelisting
  # discards it, so the cache can be stamped with when the reading actually
  # happened, not "now". Only trusted for source:"transcript"; a vendor
  # reading's cached_at is always the fetch time (the two coincide there).
  local event_epoch=""
  event_epoch="$(printf '%s' "$reading" | jq -r '
    if .source == "transcript" and (.event_epoch|type) == "number"
    then .event_epoch else empty end' 2>/dev/null)"
  # Whitelist fields: never cache a vendor error body or credentials.
  reading="$(printf '%s' "$reading" | jq -ce '
    def pct: if type == "number" and . >= 0 and . <= 100 then . else null end;
    def stamp: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9]{2}:[0-9]{2})$") then . else null end;
    {window_pct:(.window_pct|pct),weekly_pct:(.weekly_pct|pct),
     window_resets_at:(.window_resets_at|stamp),weekly_resets_at:(.weekly_resets_at|stamp),
     source:(if .source == "vendor" or .source == "transcript" then .source else "unknown" end)}')" || { reading="$(usage_unknown)"; event_epoch=""; }
  umask 077
  if mkdir -p "${cache%/*}" && tmp="$(mktemp "$cache.XXXXXX")"; then
    if printf '%s' "$reading" | jq -c --argjson now "$now" --arg ev "$event_epoch" \
         '. + {cached_at:(if $ev == "" then $now else ($ev|tonumber) end), scanned_at:$now}' > "$tmp"; then
      mv -f "$tmp" "$cache"
    else rm -f "$tmp"; fi
  fi
  printf '%s\n' "$reading"
)

# --- who writes this cache, and who honours what (P2-1, round-2 review) ---
#
# (a) `burn` refreshes the LAUNCHED tank's reading at run END — one vendor
#     call, off the launch path (launching itself still pays zero — P1-2..
#     P1-4), fired after the run's artifact check so it can never delay
#     judging that run's own outcome. See lib/commands/burn.sh's cmd_burn.
# (b) when the named tank is dry and burn must reroute, `_burn_next_same_
#     engine` ranks every surviving candidate once on whatever is already on
#     disk, then spends its live-call budget (`_BURN_REROUTE_REFRESH_CAP`,
#     default 3) refreshing only the top candidates off THAT snapshot —
#     never all of them, and never before the snapshot ranking runs (bounded
#     to candidates only, reusing the adapter's own existing --max-time — no
#     new bound invented). A refresh that fails to read back demotes that
#     candidate to unknown in memory for the FINAL ranking (round-5 review
#     P2-1) — it can never win on the stale number it just failed to
#     reproduce.
# (c) the board NEVER fetches (usage_cache_peek/usage_board_fields below are
#     cache-only, always) and shows the reading's age next to the dot once
#     it is older than the TTL ("3h ago"), or "unknown" once it is older
#     than 24h — see lib/commands/home.sh's _home_fuel_dotv_compute.
# (d) `usage_cache_peek` (burn's ranking) and `usage_board_fields` (the
#     board's display) both honour the reading's OWN window_resets_at /
#     weekly_resets_at: a window whose reset instant has already passed
#     reads as 0% used, not as whatever stale percentage the last fetch
#     happened to record — a tank that ran dry at 15:00Z must not still be
#     ranked (or shown) at its old 100% two hours after its window reset.
#
# Nothing else writes or refreshes this cache. `usage_read` above is the
# ONLY writer in the whole repo (`clikae usage`, plus (a)/(b) above calling
# it the same way); a cache file with no `clikae usage`/burn run behind it
# simply does not exist yet, and one that stops being refreshed simply ages
# in place — (c) is how the board says so instead of staying silent.
#
# `scanned_at` vs `cached_at` (P3, round-2 review): a vendor reading's
# `cached_at` IS the fetch time — the two never differ. A transcript
# (codex) reading's `cached_at` is the underlying EVENT's own timestamp
# (P2-4, round-1 review, deliberate: never lie about how old the FACT is),
# which can be old even in a cache written moments ago. `scanned_at` is
# always "when `usage_read` last actually looked" — that is what a
# cache-hit/TTL check means everywhere else, so codex gets the same TTL
# behaviour claude already had instead of a check that almost never fires.
# `cached_at` keeps meaning "how old is this NUMBER", used by (c)'s age
# display and (d)'s reset-instant guard — unchanged by this.

# P2-3 (round-1 review) / P3-12 (round-2 review): the vendor's real reset
# instant is "2026-09-13T14:50:00.189940+00:00" — microseconds AND a UTC
# offset, never the bare "…Z" jq's fromdateiso8601 requires. norm_stamp
# drops the fractional seconds, then parses ANY "±HH:MM" offset (not just
# "+00:00"/"-00:00", the round-1 fix's shape) and converts to an epoch by
# arithmetic: the naive local time read as if it were already UTC, then
# shifted by the offset (subtract for "+", add for "-"). A stamp that
# doesn't match this shape at all still fails to parse — the caller's own
# `catch` decides what that means (both uses below fail OPEN: treat as not
# yet expired, same as before this fix, and still no real vendor sends a
# shape this doesn't parse).
_USAGE_NORM_STAMP_JQ='
  def norm_stamp:
    sub("\\.[0-9]+";"") as $s
    | if ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$")) then
        ($s | capture("^(?<naive>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<off>Z|[+-][0-9]{2}:[0-9]{2})$")) as $c
        | ($c.naive + "Z" | fromdateiso8601) as $base
        | if $c.off == "Z" then $base
          elif ($c.off[0:1]) == "+" then $base - (($c.off[1:3]|tonumber)*3600 + ($c.off[4:6]|tonumber)*60)
          else $base + (($c.off[1:3]|tonumber)*3600 + ($c.off[4:6]|tonumber)*60)
          end
      else error("norm_stamp: unrecognized timestamp shape")
      end;
  def expired: if . == null then false else ((try norm_stamp catch ($now+1)) <= $now) end;
'

# P2 (round-4 review): how old a reading can be and still be trusted for
# burn's ranking, named once and used at usage_cache_peek's one call site
# below. Age is (a plain cache peek's only clock) `scanned_at` — "when
# usage_read last actually looked" (see the (a)/(b)/`scanned_at` vs
# `cached_at` note above), never `cached_at` alone: a codex transcript
# reading's `cached_at` is deliberately the EVENT's own old timestamp
# (P2-4, round-1 review) even when it was scanned moments ago, and ranking
# by that would make almost every codex candidate "unknown". 15 minutes is
# a small fraction of the 5-hour window burn ranks against (P2-3's "the
# 5-hour clock a burn starting now actually runs against") — long enough
# that a tank refreshed by a recent `clikae usage`, burn's own run-end
# refresh (a), or a reroute's Pass 4 candidate refresh (b, lib/commands/
# burn.sh's `_burn_next_same_engine`) still counts, short enough that the
# reset-instant-passed branch below can't be
# won by a reading old enough to predate the reset it's claiming to know
# about.
_USAGE_CACHE_PEEK_MAX_AGE_SEC=${_USAGE_CACHE_PEEK_MAX_AGE_SEC:-900}

# Cache-only peek: never calls the vendor, never forks the adapter, never
# writes. burn's candidate ranking needs a headroom number to order tanks by
# — but burn's launch/reroute path must not pay a vendor round-trip just to
# pick one (that bound is (b) above's job, done once per reroute, not here).
# A reading up to _USAGE_CACHE_PEEK_MAX_AGE_SEC old is still returned here
# (stale-but-recent headroom beats no headroom for ranking purposes) —
# EXCEPT a window/weekly whose own reset instant has already passed, which
# reads as 0% used, never as its last stale reading (P2-1(d) above). Past
# the age ceiling the reading is "unknown", not "0% used because the reset
# passed": P2 (round-4 review) — a reading old enough to be unverifiable is
# also old enough to have crossed a reset instant it never recorded, and an
# unrefreshed candidate's number only gets systematically MORE flattering
# with age (window/weekly readings only fall or reset, never rise), so
# trusting an old "0%" here is exactly backwards from what "stale beats
# nothing" was meant to buy. Only a missing cache, missing jq, a reading
# older than the ceiling, or a non-vendor/incomplete reading is "unknown":
# empty stdout, rc=4 (jq -er's exit status when the pipeline produces no
# output at all, not rc=1 — rc=1 is "last value was false/null", which
# never happens here since select() either produces a value or nothing).
usage_cache_peek() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json" now="${3:-}"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$now" ] || now="$(date +%s)"
  jq -er --argjson now "$now" --argjson max_age "$_USAGE_CACHE_PEEK_MAX_AGE_SEC" "$_USAGE_NORM_STAMP_JQ"'
    select(.source == "vendor" or .source == "transcript") |
    select(.window_pct != null and .weekly_pct != null) |
    ((.scanned_at // .cached_at)) as $scanned |
    select($scanned != null and $scanned <= $now and ($now - $scanned) <= $max_age) |
    (if (.window_resets_at|expired) then 0 else .window_pct end) as $w |
    (if (.weekly_resets_at|expired) then 0 else .weekly_pct end) as $k |
    [$w,$k,([$w,$k]|max)] | @tsv' "$cache" 2>/dev/null
}

# Board reads, up to 24h old (P2-1(c) above): never does network I/O during a
# redraw (cache-only, same file usage_cache_peek reads), but unlike
# usage_cached_fields below does NOT stop returning a reading once it is
# older than the TTL — it returns the reading PLUS its age (epoch
# `cached_at`, 4th column) so the caller can show "3h ago" instead of
# nothing. Same window/weekly reset-instant guard as usage_cache_peek (P2-1
# (d)): an expired window reads as 0%, not a stale ≥90%. The caller (home.sh)
# is the one that draws the 24h line and prints "unknown" past it — this
# function itself has no upper bound, same as usage_cache_peek.
usage_board_fields() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json" now="${3:-}"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$now" ] || now="$(date +%s)"
  jq -er --argjson now "$now" "$_USAGE_NORM_STAMP_JQ"'
    select(.source == "vendor" or .source == "transcript") |
    select(.window_pct != null and .weekly_pct != null) |
    (if (.window_resets_at|expired) then 0 else .window_pct end) as $w |
    (if (.weekly_resets_at|expired) then 0 else .weekly_pct end) as $k |
    [$w,$k,([$w,$k]|max),.cached_at] | @tsv' "$cache" 2>/dev/null
}

# Board reads, fresh only (within the TTL): never do network I/O during a
# redraw. `now` may be passed in (epoch seconds) so a caller doing several
# lookups in one redraw forks `date` once, not once per lookup (P2-1, round-1
# review) — see lib/commands/home.sh's _home_fuel_dotv memoization. Same
# window/weekly reset-instant guard as usage_cache_peek/usage_board_fields
# above (P2-1(d)). Superseded as the board's PRIMARY read by
# usage_board_fields (P2-1(c), round-2 review: a 120s TTL made the vendor
# cache invisible to the board within a couple of minutes of the last
# `clikae usage`) but kept — same contract, same tests — for anything that
# genuinely only wants "fresh or nothing".
usage_cached_fields() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json" ttl="${CLIKAE_USAGE_TTL:-120}" now="${3:-}"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  case "$ttl" in ''|*[!0-9]*) ttl=120 ;; esac
  [ -n "$now" ] || now="$(date +%s)"
  jq -er --argjson now "$now" --argjson ttl "$ttl" "$_USAGE_NORM_STAMP_JQ"'
    (.scanned_at // .cached_at) as $scanned |
    select((.source == "vendor" or .source == "transcript") and $scanned <= $now and ($now-$scanned < $ttl)) |
    select(.window_pct != null and .weekly_pct != null) |
    select(all(.window_resets_at, .weekly_resets_at; expired | not)) |
    [.window_pct,.weekly_pct,([.window_pct,.weekly_pct]|max)] | @tsv' "$cache" 2>/dev/null
}
