# shellcheck shell=bash
# Shared, atomic usage cache. Only normalized public readings reach disk.
# P3-5 (round-6 review) and #107: a reading with no numbers may carry a
# `reason`. FIVE values (#136 added the last), and nothing else is ever
# emitted or cached:
#   expired-token   the vendor refused the token (HTTP 401/403), or its own
#                   recorded expiry had passed, AND the credentials hold a
#                   refresh token. The login is fine; the access token only
#                   needs the refresh a session does. This reason always
#                   comes with source:"expired", never "unknown" — that is
#                   the whole of #107: an idle tank at 99% weekly used to read
#                   exactly like a tank with no login at all.
#   no-credentials  no usable token was found at all (no credentials file, no
#                   Keychain entry, one that does not parse), or the vendor
#                   refused one that has no refresh token to renew it with.
#   network         the call did not complete usably for a transport or
#                   server reason: no connection, a timeout, a 5xx. Up to
#                   #136 this also swallowed every 429.
#   rate-limited    (#136) HTTP 429. May carry ONE more key, `retry_after`:
#                   the vendor's own `Retry-After` header, and only when it
#                   was delta-seconds in 1..86400 — absent for a missing,
#                   negative, zero, non-numeric, HTTP-date or out-of-range
#                   header, so a caller that sees the key can trust it
#                   without re-validating, and one that does not see it falls
#                   back to its own backoff.
#   unparseable     the call answered 200 and the body was not one usable
#                   reading (malformed, several documents, over the byte cap).
# The key is ABSENT (not null) when the reason is unknown, and absent on
# every vendor/transcript reading, so no existing output shape moves.
#
# THE AUTH CLASS IS TWO WORDS, NOT ONE. #136 asked for a single `reauth`;
# `expired-token` and `no-credentials` already are that class, split by the
# one fact that changes the remedy (is there a refresh token?). A caller that
# wants "this will never succeed on its own" asks for either word — see
# lib/commands/watch.sh's `_watch_usage_poll_one`.
#
# #137: a VENDOR reading may carry one extra key, `models` — an array of
# `{name, pct, resets_at}`, the vendor's own per-model weekly rows. Read by
# `clikae usage` only; no ranking, dot or backoff looks at it. See
# lib/adapters/claude.sh's `adapter_usage` for where it comes from and
# docs/usage.md for why the board's dot stays all-models.
#
# #107: an auth failure is cached for at most _USAGE_AUTH_FAIL_TTL_SEC, not
# the full CLIKAE_USAGE_TTL — the next read after a session refreshes the
# token must see the fresh number, not a minute-old "expired".
_USAGE_AUTH_FAIL_TTL_SEC=60

# usage_expired_hintv <tank> -> $_UEH, the one line a person reads next to an
# "expired" reading (`clikae usage` text, the board's note). The words are
# the remedy, not a diagnosis: the login is fine, only a session (or `clikae
# usage --wake`) refreshes the access token. A `…v` setter so the board's
# redraw pays no subshell for it.
usage_expired_hintv() {
  _UEH="token expired — run a session or 'clikae usage --wake $1'"
}
# usage_expired_board_notev <tank> -> $_UEH, the same remedy cut to fit the
# board's right gutter. A tank row spends 47 columns before its note (lead,
# dot, name 7, engine 8, account 22, gap), which leaves 33 on an 80-column
# terminal — the full sentence above is 63 and wrapped the row (measured on a
# rendered board). Every existing note ("window 44% · weekly 20% · 3h ago")
# fits that gutter; this one does for any tank name of up to 8 characters.
usage_expired_board_notev() {
  _UEH="expired · usage --wake $1"
}
# usage_unknown [reason] [retry_after]
# $2 is honoured for `rate-limited` only, and only as an integer in 1..86400
# — same bound, same digit-count guard against arithmetic overflow, as the
# adapter's own `_claude_usage_rate_limited`. Two gates on purpose: the
# adapter is one of several possible producers, this is the only writer.
usage_unknown() {
  local _u_retry=""
  case "${2:-}" in
    ''|*[!0-9]*|??????*) ;;
    *) if [ "$2" -ge 1 ] && [ "$2" -le 86400 ]; then _u_retry=",\"retry_after\":$2"; fi ;;
  esac
  case "${1:-}" in
    expired-token)
      printf '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"expired","reason":"%s"}\n' "$1" ;;
    rate-limited)
      printf '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"unknown","reason":"rate-limited"%s}\n' "$_u_retry" ;;
    no-credentials|network|unparseable)
      printf '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"unknown","reason":"%s"}\n' "$1" ;;
    *)
      printf '%s\n' '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"unknown"}' ;;
  esac
}

usage_read() (
  local engine="$1" tank="$2" fresh="${3:-0}" cache now ttl reading tmp
  local adapter_out="" adapter_reason="" adapter_retry=""
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
  # #107: an "expired" reading gets the shorter of the two TTLs.
  if [ "$fresh" != 1 ] && [ -f "$cache" ] &&
     jq -e --argjson now "$now" --argjson ttl "$ttl" --argjson authttl "$_USAGE_AUTH_FAIL_TTL_SEC" \
       '(.scanned_at // .cached_at) as $s
        | (if .source == "expired" and $authttl < $ttl then $authttl else $ttl end) as $t
        | $s <= $now and ($now - $s < $t)' "$cache" >/dev/null 2>&1; then
    jq -c 'del(.cached_at, .scanned_at)' "$cache"; return
  fi
  reading=""
  if [ -f "$CLIKAE_LIB/adapters/$engine.sh" ]; then
    load_adapter "$engine"
    if declare -F adapter_usage >/dev/null; then
      # P3-3 (codex security review, round-5): this used to be `2>/dev/null`,
      # which hid EVERY adapter's own diagnostics from the public `clikae
      # usage` path — including claude.sh's honest "running WITHOUT a time
      # bound" warning (lib/core/timeout_bin.sh) when a Keychain read can't
      # be bounded (no timeout/gtimeout/perl on PATH), silently leaving an
      # unbounded, possibly-hanging read with no way for anyone to know why.
      # Every adapter_usage implementation already redirects its OWN
      # vendor-body/secret-bearing subcalls internally (curl, jq, `security`
      # all pipe through their own `2>/dev/null` above this call) — nothing
      # but that kind of safe diagnostic ever reaches this level to leak.
      # P3-5 (round-6 review): a FAILED adapter_usage still gets its stdout
      # looked at — but only ever through the enum below, never as a
      # reading. "Never cache a vendor error body" (the whitelist further
      # down) stays exactly as strict: at most one of three fixed words
      # survives this, and anything else is discarded with the body.
      if adapter_out="$(adapter_usage "$(profile_dir "$engine" "$tank")")"; then
        reading="$adapter_out"
      else
        reading=""
        adapter_reason="$(printf '%s' "$adapter_out" | jq -r '
          if .reason == "expired-token" or .reason == "no-credentials"
             or .reason == "network" or .reason == "unparseable"
             or .reason == "rate-limited"
          then .reason else empty end' 2>/dev/null)"
        # #136: the ONE extra fact a failed call may carry out. Read only for
        # the reason that defines it, and only as a whole number of seconds —
        # `usage_unknown` re-checks the range anyway (a producer is not the
        # writer), but a non-integer must not reach it as `30.5`.
        if [ "$adapter_reason" = rate-limited ]; then
          adapter_retry="$(printf '%s' "$adapter_out" | jq -r '
            if (.retry_after|type) == "number" and .retry_after >= 1
               and .retry_after <= 86400 and (.retry_after|floor) == .retry_after
            then (.retry_after|tostring) else empty end' 2>/dev/null)"
        fi
      fi
    fi
  fi
  [ -n "$reading" ] || reading="$(usage_unknown "$adapter_reason" "$adapter_retry")"
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
    (if .reason == "no-credentials" or .reason == "network"
        or .reason == "unparseable" or .reason == "rate-limited"
     then .reason else null end) as $reason |
    # #136: `retry_after` exists only beside `rate-limited`, only as a whole
    # number of seconds in 1..86400. Anything else is dropped here, so a
    # reader that finds the key never has to re-validate it.
    (if .reason == "rate-limited" and (.retry_after|type) == "number"
        and .retry_after >= 1 and .retry_after <= 86400
        and (.retry_after|floor) == .retry_after
     then (.retry_after|floor) else null end) as $retry |
    # #137: the per-model weekly rows, whitelisted field by field
    # like everything else that reaches this cache — a bounded array of
    # at most 8 `{name, pct, resets_at}` with a name of at most 40 characters,
    # a percentage in 0..100 and a timestamp of the one shape `stamp` accepts.
    # Never carried on a non-vendor reading.
    (if (.models|type) == "array" then
       [ .models[] | select(type == "object") |
         {name: .name, pct: .pct, resets_at: (.resets_at|stamp)} |
         select((.name|type) == "string" and (.name|length) > 0 and (.name|length) <= 40) |
         select((.pct|type) == "number" and .pct >= 0 and .pct <= 100) ] | .[0:8]
     else [] end) as $models |
    # #107: "expired" exists only with its one reason, and never carries a
    # number — whatever else an adapter put beside it is dropped here.
    if .source == "expired" and .reason == "expired-token" then
      {window_pct:null,weekly_pct:null,window_resets_at:null,weekly_resets_at:null,
       source:"expired",reason:"expired-token"}
    else
    {window_pct:(.window_pct|pct),weekly_pct:(.weekly_pct|pct),
     window_resets_at:(.window_resets_at|stamp),weekly_resets_at:(.weekly_resets_at|stamp),
     source:(if .source == "vendor" or .source == "transcript" then .source else "unknown" end)} |
    if .source == "unknown" and $reason != null then . + {reason:$reason} else . end |
    if .source == "unknown" and $reason == "rate-limited" and $retry != null
    then . + {retry_after:$retry} else . end |
    if .source == "vendor" and ($models|length) > 0 then . + {models:$models} else . end
    end')" || { reading="$(usage_unknown)"; event_epoch=""; }
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
#     new bound invented). A refresh that fails to read back may only rank
#     that candidate the SAME or WORSE than the on-disk evidence, never
#     better (round-5 review P2-1, round-6 review P3-1): a known-<90%
#     candidate becomes unknown (it can never win on the stale number it
#     just failed to reproduce), a known->=90% one KEEPS its reading rather
#     than being laundered into an "unknown" that outranks it.
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
#     This "reset passed -> 0%" rule only applies to `usage_cache_peek`
#     WITHIN its own `_USAGE_CACHE_PEEK_MAX_AGE_SEC` age ceiling (900s,
#     below) — past that ceiling the reading is "unknown", never "0%",
#     because a reading too old to trust is also too old to know it hasn't
#     drifted past a LATER reset it never recorded. `usage_board_fields`
#     carries no such ceiling: it honours the same reset-passed rule at any
#     age, on its own 24h "unknown" cutoff (`home.sh`) instead — the two
#     callers do not share one ruler (round-5 review P3-5).
#
# (e) a LIVE SESSION refreshes its own tank, from the `wake` window it
#     already has: one `usage_read` at launch (wake_usage_prime, called from
#     lib/commands/switch.sh for a session it just spawned) and one every
#     WAKE_USAGE_INTERVAL from wake_watch's loop (lib/core/wake.sh). Added
#     2026-09-22 because (a)-(d) between them left the refresh UNOWNED on a
#     machine that never burns: measured, a nine-day-old cache and a tmux
#     status row showing the "no reading" glyph forever, while a machine
#     burning all day showed live numbers. It goes through this same function,
#     so it honours CLIKAE_USAGE_TTL like every other caller and keeps nothing
#     a `clikae usage` run would not have written.
#
# (f) `clikae watch`'s usage-poll heartbeat (#133) walks every tank through
#     this same function on its own schedule. (e) and (f) overlap on purpose:
#     (f) needs a person running `clikae watch`, (e) needs nothing but a live
#     session — and because both go through the TTL below, a tank both of them
#     touch costs a cache hit, not a second vendor call.
#
# Nothing else writes or refreshes this cache. `usage_read` above is the
# ONLY writer in the whole repo (`clikae usage`, plus (a)/(b)/(e)/(f) above
# calling it the same way); a cache file with no `clikae usage`/burn/live-session run
# behind it simply does not exist yet, and one that stops being refreshed simply
# ages in place — (c) is how the board says so instead of staying silent.
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

# P2 (round-4 review), corrected P2-2 (codex security review, round-5): how
# old a reading can be and still be trusted for burn's ranking, named once
# and used at usage_cache_peek's one call site below. Age is `cached_at` —
# the EVIDENCE's own timestamp, never `scanned_at` (round-4's original
# choice): `scanned_at` is "when usage_read last actually LOOKED", which for
# a vendor reading coincides with `cached_at` but for a codex transcript
# reading does not — a rollout's `cached_at` is deliberately the underlying
# EVENT's own old timestamp (P2-4, round-1 review), while `scanned_at` is
# whenever something last re-read that same unchanged rollout off disk.
# Ranking by `scanned_at` let a THREE-DAY-OLD rollout stay ranking-eligible
# forever, just by being rescanned — no new evidence from the vendor, only a
# fresh look at old evidence, renewing a claim that should have expired. That
# reproduced exactly: a synthetic 3-day-old rollout with both percentages at
# 100 and both resets already past kept scoring an eligible reading (and,
# combined with the reset-passed branch below, one that read as a
# suspiciously perfect 0% used) after every rescan. Ranking by `cached_at`
# instead means a codex candidate this stale correctly falls out of
# eligibility (empty output, "unknown") regardless of how recently anything
# rescanned it — the trade the round-4 comment warned about (codex
# candidates going unknown more often) is the point, not a regression: an
# unrefreshed reading's trustworthiness is about how old the FACT is, not how
# recently something looked at the file that holds it. 15 minutes is a small
# fraction of the 5-hour window burn ranks against (P2-3's "the 5-hour clock
# a burn starting now actually runs against") — long enough that a tank
# refreshed by a recent `clikae usage`, burn's own run-end refresh (a), or a
# reroute's Pass 4 candidate refresh (b, lib/commands/burn.sh's
# `_burn_next_same_engine`) still counts, short enough that the
# reset-instant-passed branch below can't be won by a reading old enough to
# predate the reset it's claiming to know about.
# P3-6 (round-5 review): a non-numeric override made every `--argjson
# max_age` call below fail to even start (jq errors out on a non-numeric
# arg), so every peek — cache-hit or not — silently read as "unknown", with
# no stderr at all (`usage_cache_peek`'s own `2>/dev/null`). This knob
# controls whether burn's ranking ever trusts ANY cached reading; a loud,
# named warning plus a safe default beats going quietly blind.
_USAGE_CACHE_PEEK_MAX_AGE_SEC=${_USAGE_CACHE_PEEK_MAX_AGE_SEC:-900}
# The unset/empty case above already resolved to the default and is never
# "invalid" — only a value that's actually SET to something non-numeric
# reaches this check (same shape as _BURN_REROUTE_REFRESH_CAP's, burn.sh).
# P3-4 (round-6 review): the digit-count bound is that shape too, and for
# this knob the overflow failure is the QUIETER of the two — an all-digit
# `99999999999999999999` sails through as a jq --argjson number, turning the
# age ceiling into 1e20 and making every reading trusted forever (the review
# measured a 3000-second-old reading accepted), with no warning at all.
# Nine digits is 31 years of ceiling; nothing legitimate is refused here.
case "$_USAGE_CACHE_PEEK_MAX_AGE_SEC" in
  *[!0-9]*|??????????*)
    declare -F log_warn >/dev/null && log_warn "_USAGE_CACHE_PEEK_MAX_AGE_SEC=\"$_USAGE_CACHE_PEEK_MAX_AGE_SEC\" is not a non-negative integer of at most 9 digits — using the default (900). Every cached usage reading silently reads as unknown otherwise."
    _USAGE_CACHE_PEEK_MAX_AGE_SEC=900
    ;;
esac

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
# P3-7 (round-6 review): CLOCK SKEW. A `cached_at` in the FUTURE (a cache
# written while the host clock was ahead, or copied from a machine that was)
# counts as AGE 0 — here and on the board, one rule, both rulers. This used
# to `select($evidence <= $now)`, i.e. reject the reading outright, while
# lib/commands/home.sh clamped the same case (`[ "$age" -ge 0 ] || age=0`):
# a cache stamped 30 seconds ahead read as UNKNOWN for burn ranking while
# the board showed its percentages as freshly read. The three age clocks in
# docs/DESIGN-board-fuel-dots.md are deliberately reconciled-not-unified
# about how LONG a reading stays good; they were never meant to disagree
# about what a NEGATIVE age means. Age 0 rather than rejection, because the
# reading is real evidence carrying a skewed stamp, and rejecting it would
# punish the tank for its host clock. A skewed stamp cannot make a reading
# look OLDER than it is, only younger, so this can never resurrect a reading
# the ceiling would otherwise have discarded.
usage_cache_peek() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json" now="${3:-}"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$now" ] || now="$(date +%s)"
  jq -er --argjson now "$now" --argjson max_age "$_USAGE_CACHE_PEEK_MAX_AGE_SEC" "$_USAGE_NORM_STAMP_JQ"'
    select(.source == "vendor" or .source == "transcript") |
    select(.window_pct != null and .weekly_pct != null) |
    (.cached_at) as $evidence |
    select($evidence != null) |
    # P3-7 (round-6 review): one clock-skew rule, shared with the board.
    # A timestamp in the FUTURE counts as age 0. See this function header.
    (if ($now - $evidence) < 0 then 0 else ($now - $evidence) end) as $age |
    select($age <= $max_age) |
    (if (.window_resets_at|expired) then 0 else .window_pct end) as $w |
    (if (.weekly_resets_at|expired) then 0 else .weekly_pct end) as $k |
    [$w,$k,([$w,$k]|max)] | @tsv' "$cache" 2>/dev/null
}

# P3-4 (round-5 review): does a candidate have ANY on-disk numeric reading at
# all, ignoring `_USAGE_CACHE_PEEK_MAX_AGE_SEC` entirely — used ONLY to decide
# burn's Pass-4 refresh PRIORITY (lib/commands/burn.sh's `_burn_next_same_
# engine`), never for ranking. Before this existed, a candidate whose only
# on-disk reading was older than the ceiling was indistinguishable, at
# refresh-priority time, from a candidate with NO reading at all — both
# collapsed to the same "unknown" bucket and lost the budget race to any
# candidate with a merely FRESH confident number, even when that stale
# reading (a tank the board itself still shows a percentage for, aged) was
# plausibly the actual best headroom in the fleet. This never returns a
# NUMBER (see usage_cache_peek for that, ceiling-bounded and reset-aware) —
# only whether refreshing this candidate is worth doing ahead of a blank one.
usage_cache_has_reading() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '(.source == "vendor" or .source == "transcript") and .window_pct != null and .weekly_pct != null' \
    "$cache" >/dev/null 2>&1
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
