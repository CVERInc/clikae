# shellcheck shell=bash

# #107: the ceiling on --wake's one-prompt burn, whole seconds. Passed to
# burn's own --timeout, so it bounds the engine run the way every other burn
# is bounded (timeout/gtimeout/perl, or an honest warning with none of them).
_USAGE_WAKE_TIMEOUT_SEC=60

# _usage_wake <engine> <tank> <force_cockpit> <json>
# Refresh a tank's token the only way clikae knows how without touching the
# vendor's OAuth flow itself: run the engine headless for one trivial prompt,
# through `clikae burn` — the same process, the same cockpit gate, the same
# running-burn lock and tmux session — then re-read usage with no cache.
# A child process, not cmd_burn in this shell: burn owns fd 1/2 redirection,
# EXIT traps and `exit`, none of which may leak into this command.
_usage_wake() {
  local e="$1" t="$2" force="$3" json="$4" work rc=0 reading fc=""
  [ "$force" != 1 ] || fc=--force-cockpit
  work="$(mktemp -d "${TMPDIR:-/tmp}/clikae-wake.XXXXXX")" || { log_err "wake: could not create a temp directory"; return 1; }
  # The artifact is the proof the engine actually answered. The prompt names
  # it verbatim; nothing else is asked for.
  # Burn's own words (progress, refusals) go to stderr: stdout stays the
  # reading, the same shape `clikae usage` always prints.
  "$CLIKAE_BIN" burn "$e" "$t" --no-reroute --infra-retries 0 \
    --timeout "$_USAGE_WAKE_TIMEOUT_SEC" \
    --artifact "$work/wake-ok" --add-dir "$work" \
    --prompt "Write the single word ok into the file $work/wake-ok and do nothing else." \
    ${fc:+"$fc"} 1>&2 || rc=$?
  rm -rf "$work"
  if [ "$rc" -ne 0 ]; then
    log_err "wake: the burn on $e/$t did not complete (exit $rc) — --wake did not re-read usage."
    return "$rc"
  fi
  reading="$(CLIKAE_USAGE_TTL=0 usage_read "$e" "$t" 1)"
  _usage_print "$e" "$t" "$reading" "$json"
}

_usage_print() {
  local e="$1" t="$2" reading="$3" json="$4"
  if [ "$json" = 1 ]; then
    printf '{"engine":%s,"tank":%s,%s\n' "$(json_str "$e")" "$(json_str "$t")" "${reading#\{}"
  else
    printf '%s/%s %s\n' "$e" "$t" "$reading"
    case "$reading" in
      *'"source":"expired"'*) usage_expired_hintv "$t"; printf '  %s\n' "$_UEH" >&2 ;;
    esac
  fi
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
live call answered), "transcript" (read from evidence the engine already
wrote locally — no live process invoked; currently Codex), "expired" (the
login is fine but its access token has lapsed — see --wake), or "unknown"
(no usable reading).

A reading with no numbers may carry one more field, "reason" — present only
when it is actually known, never on a vendor/transcript reading:
  expired-token   (always with source "expired") the vendor refused the
                  token, or its own recorded expiry had passed, and the
                  credentials hold a refresh token. Only a session refreshes
                  it — an idle tank reads this, not "no login". Cached for at
                  most 60s, so the read after a session sees fresh numbers.
  no-credentials  no usable token was found, or the vendor refused one
                  with no refresh token to renew it: this one needs a login.
  network         no connection, a timeout, a rate limit or a server error.
  unparseable     the vendor answered, but not with one usable reading.

--wake <tank> refreshes an expired token: it runs the engine headless for
one trivial prompt through `clikae burn` (so burn's rules apply unchanged —
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
  [ "$found" = 1 ] || [ -z "$engine" ]
}
