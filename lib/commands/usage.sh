# shellcheck shell=bash
cmd_usage() {
  local engine="" tank="" json=0 fresh=0 arg e t _path reading found=0
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;; --fresh) fresh=1 ;;
      --help|-h)
        cat <<'HELP'
Usage: clikae usage [engine] [tank] [--json] [--fresh]

Report each tank's vendor usage window(s) — how much of the quota is used,
and when it resets. No engine/tank = every tank. --json prints one object
per tank, adding "engine"/"tank" to the reading; the plain form prints
"<engine>/<tank> <reading>".

Reading fields: window_pct, weekly_pct (0-100, or null), window_resets_at,
weekly_resets_at (ISO instants, or null), source. source is "vendor" (a
live call answered), "transcript" (read from evidence the engine already
wrote locally — no live process invoked; currently Codex), or "unknown"
(no usable reading).

An "unknown" reading may carry one more field, "reason" — present only
when it is actually known, never on a vendor/transcript reading:
  no-credentials  no usable token was found at all.
  expired-token   a token was found and its own recorded expiry had
                  already passed when the call was made.
  network         everything else: the call was attempted and did not
                  come back with a usable reading. NOT a claim about the
                  wire — an HTTP refusal, a timeout and an unparseable
                  body all land here. Taking that lump apart, and acting
                  on an expired token instead of just naming it, is
                  issue #107.

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
      -*) log_err "Unknown option: $arg"; return 1 ;;
      *)
        if [ -z "$engine" ]; then engine="$arg"
        elif [ -z "$tank" ]; then tank="$arg"
        else
          log_err "Too many arguments: clikae usage [engine] [tank] [--json] [--fresh]"
          return 1
        fi ;;
    esac
  done
  [ "$engine" != agy ] || engine=antigravity
  [ -z "$engine" ] || validate_name engine "$engine"
  [ -z "$tank" ] || validate_name profile "$tank"
  while IFS=$'\t' read -r e t _path; do
    [ -n "$e" ] || continue
    [ -z "$engine" ] || [ "$e" = "$engine" ] || continue
    [ -z "$tank" ] || [ "$t" = "$tank" ] || continue
    found=1
    reading="$(usage_read "$e" "$t" "$fresh")"
    if [ "$json" = 1 ]; then
      printf '{"engine":%s,"tank":%s,%s\n' "$(json_str "$e")" "$(json_str "$t")" "${reading#\{}"
    else
      printf '%s/%s %s\n' "$e" "$t" "$reading"
    fi
  done <<EOF_PROFILES
$(list_all_profiles)
EOF_PROFILES
  [ "$found" = 1 ] || [ -z "$engine" ]
}
