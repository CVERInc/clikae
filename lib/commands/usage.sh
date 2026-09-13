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

Readings are cached for 120s (CLIKAE_USAGE_TTL overrides; --fresh bypasses
the cache and always calls). The board and `clikae burn` only ever read
this cache — burn never fetches on its own, so a cold burn never pays a
vendor round-trip just to pick a tank.
HELP
        return 0 ;;
      -*) log_err "Unknown option: $arg"; return 1 ;;
      *) if [ -z "$engine" ]; then engine="$arg"; elif [ -z "$tank" ]; then tank="$arg"; else return 1; fi ;;
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
