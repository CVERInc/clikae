# shellcheck shell=bash

# _usage_wake <engine> <tank> <force_cockpit> <json>
# `--wake`: refresh the token unconditionally (one trivial prompt through
# `clikae burn` — usage_wake_burn, lib/core/usage.sh), then re-read usage with
# no cache. Since #177 a plain `clikae usage` does the same refresh on its own
# when the token is past its expiry; --wake stays for "I want it refreshed
# now, whatever the reading says" and for --force-cockpit.
_usage_wake() {
  local e="$1" t="$2" force="$3" json="$4" rc=0 reading
  usage_wake_burn "$e" "$t" "$force" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_err "wake: the burn on $e/$t did not complete (exit $rc) — --wake did not re-read usage."
    return "$rc"
  fi
  # The burn ran: a token the vendor still refuses now is relogin-required,
  # not another refresh (_CLIKAE_USAGE_AFTER_WAKE, read by usage_read).
  reading="$(CLIKAE_USAGE_TTL=0 CLIKAE_USAGE_AUTO_WAKE=0 _CLIKAE_USAGE_AFTER_WAKE=1 usage_read "$e" "$t" 1)"
  _usage_print "$e" "$t" "$reading" "$json"
}

_usage_print() {
  local e="$1" t="$2" reading="$3" json="$4" _reason
  if [ "$json" = 1 ]; then
    printf '{"engine":%s,"tank":%s,%s\n' "$(json_str "$e")" "$(json_str "$t")" "${reading#\{}"
  else
    printf '%s/%s %s\n' "$e" "$t" "$reading"
    # #179: the remedy line for an auth reason, on stderr (stdout stays the
    # "<engine>/<tank> <reading>" line for anything parsing it).
    case "$reading" in
      *'"reason":"'*)
        _reason="${reading#*\"reason\":\"}"; _reason="${_reason%%\"*}"
        usage_auth_hintv "$e" "$t" "$_reason"
        [ -z "$_UEH" ] || printf '  %s\n' "$_UEH" >&2 ;;
    esac
    case "$reading" in
      *'"groups":['*) _usage_groups_line "$reading" ;;
    esac
  fi
}

# #149: the one-line summary under the per-tank lines, e.g.
#   claude 85/96/87(Fable 100)/85? · codex 100 · agy used 3h ago
# A "(name pct)" suffix is a vendor per-model row (from the reading's own
# `models[]`, never a name clikae knows) whose pct is above the tank's weekly.
# One token per tank, engines in the order their tanks were listed: the
# weekly percentage (the window's when a vendor reports no weekly), a
# last-known number marked "?" when there is no current one, "??" when there
# never was one. agy has no number at all, so its token is when a tank of it
# last ran. Human output only, on stderr: stdout stays one "<engine>/<tank>
# <reading>" line per tank for anything parsing it; --json never has it.
# _usage_groups_line <reading> — #151: agy's quota groups are separate quotas,
# so the text form names each one, window/weekly used:
#   gemini 0/99% · claude -/100%
# ("-" = no enabled bucket of that class). The headline group, the one the
# top-level numbers are, comes first. stderr, like the expired hint above.
_usage_groups_line() {
  local line
  line="$(printf '%s' "$1" | jq -r '
    def r: if type == "number" then (. + 0.5 | floor | tostring) else "-" end;
    .headline_group as $h |
    [ (.groups // [])[] | select(.disabled | not) ] |
    (map(select(.name == $h)) + map(select(.name != $h))) |
    map("\(.name) \(.window_pct|r)/\(.weekly_pct|r)%") | join(" · ")' 2>/dev/null)" || line=""
  [ -z "$line" ] || printf '  %s\n' "$line" >&2
}

_USAGE_SUM_ENGINES=""
_usage_summary_add() {
  local e="$1" tok var
  [ "$e" != antigravity ] || e=agy
  # #174: a number is never printed as "now" when it is not. Past an hour the
  # token carries its age ("92 3h ago"); a last-known number carries the age
  # of THAT reading; and an axis whose reset has passed since the reading
  # says `reset` instead of the percentage it had before the reset.
  tok="$(printf '%s' "$2" | jq -r --argjson now "$(date +%s)" '
    def r: if type == "number" then (. + 0.5 | floor | tostring) else null end;
    def age: if . == null or . < 3600 then "" elif . < 86400 then " \(./3600|floor)h ago" else " \(./86400|floor)d ago" end;
    (.weekly_pct | numbers // -1) as $wk |
    ([(.models // [])[] | select(.pct > $wk) | "\(.name) \(.pct|r)"] | join(",")) as $bind |
    (if $bind == "" then "" else "(" + $bind + ")" end) as $sp |
    (.age_sec | age) as $a |
    (.last_age_sec | age) as $la |
    if (.weekly_pct|r) != null then
      (if .weekly_reset_passed == true then "reset" else (.weekly_pct|r) + $sp end) + $a
    elif (.window_pct|r) != null then
      (if .window_reset_passed == true then "reset" else (.window_pct|r) + $sp end) + $a
    elif (.last_used_at|type) == "number" then
      ($now - .last_used_at) as $d |
      "@" + (if $d < 3600 then "\($d/60|floor)m" elif $d < 86400 then "\($d/3600|floor)h" else "\($d/86400|floor)d" end)
    elif .gap == "no-signal" and has("last_used_at") then "no-signal"
    elif (.last_weekly_pct|r) != null then (.last_weekly_pct|r) + "?" + $la
    elif (.last_window_pct|r) != null then (.last_window_pct|r) + "?" + $la
    else "??" end' 2>/dev/null)" || tok="??"
  [ -n "$tok" ] || tok="??"
  var="_USAGE_SUM_$(printf '%s' "$e" | tr -c 'A-Za-z0-9' '_')"
  case " $_USAGE_SUM_ENGINES " in
    *" $e "*) printf -v "$var" '%s/%s' "${!var}" "$tok" ;;
    *) _USAGE_SUM_ENGINES="${_USAGE_SUM_ENGINES:+$_USAGE_SUM_ENGINES }$e"; printf -v "$var" '%s' "$tok" ;;
  esac
}
_usage_summary_print() {
  local e var line=""
  [ -n "$_USAGE_SUM_ENGINES" ] || return 0
  for e in $_USAGE_SUM_ENGINES; do
    var="_USAGE_SUM_$(printf '%s' "$e" | tr -c 'A-Za-z0-9' '_')"
    local v="${!var}"
    # agy tokens are ages marked "@": one "last used ... ago" around all of
    # them reads better than the phrase repeated per tank.
    case "$v" in
      *@*) v="last used ${v//@/} ago" ;;
    esac
    line="${line:+$line · }$e $v"
  done
  printf '%s\n' "$line" >&2
}

cmd_usage() {
  local engine="" tank="" json=0 fresh=0 e t _path reading found=0
  local wake="" wake_set=0 force_cockpit=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --fresh) fresh=1; shift ;;
      --force-cockpit) force_cockpit=1; shift ;;
      --wake)
        shift
        case "${1:-}" in ''|-*) log_err "--wake needs a tank: clikae usage [engine] --wake <tank>"; return 1 ;; esac
        wake="$1"; wake_set=1; shift ;;
      --help|-h)
        cat <<'HELP'
Usage: clikae usage [engine] [tank] [--json] [--fresh]
       clikae usage [engine] --wake <tank> [--json] [--force-cockpit]

Report each tank's vendor usage window(s) — how much of the quota is used,
and when it resets. No engine/tank = every tank. --json prints one object
per tank, adding "engine"/"tank" to the reading; the plain form prints
"<engine>/<tank> <reading>".

Reading fields: window_pct, weekly_pct (0-100, or null), window_resets_at,
weekly_resets_at (ISO instants, or null), source. source is "vendor" (a
live call answered), "quota-api" (agy: its own retrieveUserQuotaSummary
answered; the top-level numbers are one quota group's, headline_group,
and every group is under groups),
"transcript" (read from evidence the engine already
wrote locally — no live process invoked; currently Codex), or "unknown"
(no usable reading). Every reading carries "age_sec" (how old its evidence
is) and, when an axis's own resets_at is already behind now,
"window_reset_passed" / "weekly_reset_passed": true — the percentage beside
it is from before a reset.

An access token past its expiry with a refresh token beside it is REFRESHED
BEFORE IT IS MEASURED: one trivial headless prompt through `clikae burn`
(the same thing --wake does), then the real reading. CLIKAE_USAGE_AUTO_WAKE=0
turns that off for a reader that must not spend (the board, a session's wake
window, burn and `clikae watch` set it).

A reading with no numbers may carry one more field, "reason" — present only
when it is actually known, never on a vendor/transcript reading:
  needs-refresh   the token lapsed, the login is fine, and this reader was
                  not allowed to refresh it (or burn's own gates refused the
                  refresh: the recorded cockpit, a running burn). A session
                  clears it; so does `clikae usage` from a terminal. Cached
                  for at most 60s.
  relogin-required the refresh ran and the vendor still refused the token:
                  `clikae <engine> <tank>`, then /login. Cached 60s.
  keychain-denied macOS: this process may not read the tank's Keychain item.
                  The last reading is served with its age (the reason rides
                  beside the numbers) and the cache is not written.
  no-credentials  no usable token was found, or the vendor refused one
                  with no refresh token to renew it: this one needs a login.
  network         no connection, a timeout or a server error.
  rate-limited    the vendor answered 429. It may carry one more field,
                  "retry_after" — the vendor's own Retry-After header in
                  seconds, present only when that header was a whole number
                  of seconds between 1 and 86400. `clikae watch`'s usage
                  poll waits exactly that long before asking again.
  unparseable     the vendor answered, but not with one usable reading.

A VENDOR reading may carry a "models" array: the vendor's own per-model
weekly rows, each {name, pct, resets_at} — the second line the REPL's
/usage shows ("Current week (Fable) 11%") next to the all-models one. It is
reported here and nowhere else: the board's fuel dot deliberately keeps
using the all-models number, because picking the relevant per-model row
would mean knowing which model a tank runs, and a tank has no such property
(--model is an argument to burn/relay, not a setting on a tank).

--wake <tank> refreshes the token unconditionally: it runs the engine headless
for one trivial prompt through `clikae burn` (so burn's rules apply unchanged —
the recorded cockpit is refused without --force-cockpit, a tank with a
running burn is refused, the run is bounded to 60s), then re-reads usage
with no cache and prints that reading. Name the engine when the same tank
name exists under more than one.

Readings are cached for 120s (CLIKAE_USAGE_TTL overrides; --fresh bypasses
the cache and always calls; codex is the one exception — its cache hit is
timed from the last SCAN, but its reading is stamped with the underlying
event's own time, which is often older than 120s on a quiet tank). The
board never fetches — it only ever shows what is already on disk, aged if
it must. `clikae burn` does: once for the tank it just ran, when the run
ends (never before launching), and on a dry tank up to 3 calls spent on
the reroute candidates a first ranking off the on-disk cache says could
actually win — NOT one call per candidate. A fleet of 20 tanks costs 3 calls
here, not 20, and fewer still if one of them verifies a 0% window, which
stops the loop on the spot. (The budget is `_BURN_REROUTE_REFRESH_CAP`;
docs/DESIGN-board-fuel-dots.md has the ranking.)
HELP
        return 0 ;;
      -*) log_err "Unknown option: $1"; return 1 ;;
      *)
        if [ -z "$engine" ]; then engine="$1"
        elif [ -z "$tank" ]; then tank="$1"
        else
          log_err "Too many arguments: clikae usage [engine] [tank] [--json] [--fresh]"
          return 1
        fi
        shift ;;
    esac
  done
  [ "$engine" != agy ] || engine=antigravity
  if [ "$wake_set" = 1 ]; then
    if [ -n "$tank" ]; then
      log_err "--wake takes the tank itself: clikae usage [engine] --wake <tank>"
      return 1
    fi
    tank="$wake"
  elif [ "$force_cockpit" = 1 ]; then
    log_err "--force-cockpit only applies to --wake"
    return 1
  fi
  [ -z "$engine" ] || validate_name engine "$engine"
  [ -z "$tank" ] || validate_name profile "$tank"
  local wake_matches="" wake_n=0
  while IFS=$'\t' read -r e t _path; do
    [ -n "$e" ] || continue
    [ -z "$engine" ] || [ "$e" = "$engine" ] || continue
    [ -z "$tank" ] || [ "$t" = "$tank" ] || continue
    found=1
    if [ "$wake_set" = 1 ]; then
      wake_n=$((wake_n + 1)); wake_matches="$wake_matches $e/$t"
      continue
    fi
    reading="$(usage_read "$e" "$t" "$fresh")"
    _usage_print "$e" "$t" "$reading" "$json"
    [ "$json" = 1 ] || _usage_summary_add "$e" "$reading"
  done <<EOF_PROFILES
$(list_all_profiles)
EOF_PROFILES
  if [ "$wake_set" = 1 ]; then
    if [ "$wake_n" -eq 0 ]; then
      log_err "--wake: no tank named '$tank'${engine:+ under $engine}"
      return 1
    fi
    if [ "$wake_n" -gt 1 ]; then
      log_err "--wake: '$tank' exists under more than one engine ($wake_matches ) — name one: clikae usage <engine> --wake $tank"
      return 1
    fi
    wake_matches="${wake_matches# }"
    _usage_wake "${wake_matches%%/*}" "$tank" "$force_cockpit" "$json"
    return
  fi
  [ "$json" = 1 ] || _usage_summary_print
  [ "$found" = 1 ] || [ -z "$engine" ]
}
