# shellcheck shell=bash
# lib/commands/info.sh — `clikae info`

cmd_info() {
  echo "clikae $CLIKAE_VERSION"
  echo ""
  printf '  %-20s %s\n' "install root" "$CLIKAE_ROOT"
  printf '  %-20s %s\n' "profile store" "$CLIKAE_HOME"
  printf '  %-20s %s\n' "shell rc"      "$(detect_shell_rc)"
  printf '  %-20s %s\n' "platform"      "$(uname -s)"
  echo ""
  printf '  %-20s %s\n' "adapters"      "$(list_adapters | paste -sd ', ' -)"
  local count
  count="$(list_all_profiles | wc -l | tr -d ' ')"
  printf '  %-20s %s\n' "profiles"      "$count"
}
