# shellcheck shell=bash
# lib/commands/info.sh — `clikae info [--json]`
#
# Shows install paths, platform, supported adapters, and the profile count.
# `--json` emits the same facts as a single object for the menu-bar GUI / scripts.
# JSON helpers (json_str) live in lib/core/json.sh.

# Render a JSON array of strings from newline-separated values on stdin.
_info_json_array() {
  local item first=1
  printf '['
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ "$first" -eq 1 ] && first=0 || printf ', '
    printf '%s' "$(json_str "$item")"
  done
  printf ']'
}

cmd_info() {
  local as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) as_json=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae info [--json]

Show install paths, platform, supported adapters, and how many profiles exist.

Options:
  --json  Emit a single JSON object {version, installRoot, profileStore, shellRc,
          platform, adapters, profiles} instead of the human table. For the
          menu-bar GUI and scripts.
EOF
        return 0 ;;
      *) log_fail "Unexpected argument: $1" ;;
    esac
  done

  local count
  count="$(list_all_profiles | wc -l | tr -d ' ')"

  if [ "$as_json" -eq 1 ]; then
    printf '{\n'
    printf '  "version": %s,\n'      "$(json_str "$CLIKAE_VERSION")"
    printf '  "installRoot": %s,\n'  "$(json_str "$CLIKAE_ROOT")"
    printf '  "profileStore": %s,\n' "$(json_str "$CLIKAE_HOME")"
    printf '  "shellRc": %s,\n'      "$(json_str "$(detect_shell_rc)")"
    printf '  "platform": %s,\n'     "$(json_str "$(uname -s)")"
    printf '  "adapters": %s,\n'     "$(list_adapters | _info_json_array)"
    printf '  "profiles": %d\n'      "$count"
    printf '}\n'
    return 0
  fi

  echo "clikae $CLIKAE_VERSION"
  echo ""
  printf '  %-20s %s\n' "install root" "$CLIKAE_ROOT"
  printf '  %-20s %s\n' "profile store" "$CLIKAE_HOME"
  printf '  %-20s %s\n' "shell rc"      "$(detect_shell_rc)"
  printf '  %-20s %s\n' "platform"      "$(uname -s)"
  echo ""
  printf '  %-20s %s\n' "adapters"      "$(list_adapters | paste -sd , - | sed 's/,/, /g')"
  printf '  %-20s %s\n' "profiles"      "$count"
}
