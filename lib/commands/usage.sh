# shellcheck shell=bash
cmd_usage() {
  local engine="" tank="" json=0 fresh=0 arg e t _path reading found=0
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;; --fresh) fresh=1 ;;
      --help|-h) echo 'Usage: clikae usage [engine] [tank] [--json] [--fresh]'; return ;;
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
