# shellcheck shell=bash
# lib/commands/list.sh — `clikae list`

cmd_list() {
  local show_paths=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--paths) show_paths=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae list [-p|--paths]

List all profiles across all CLIs.

Options:
  -p, --paths   Also show the profile directory path.
EOF
        return 0
        ;;
      *) log_fail "Unexpected argument: $1" ;;
    esac
  done

  local rows
  rows="$(list_all_profiles || true)"
  if [ -z "$rows" ]; then
    log_info "No profiles yet. Create one with:  clikae init <cli> <profile>"
    return 0
  fi

  # Pretty table.
  if [ "$show_paths" -eq 1 ]; then
    printf '%b%-12s %-20s %s%b\n' "$__C_BOLD" "CLI" "PROFILE" "PATH" "$__C_RESET"
    printf '%s\n' "$rows" | awk -F'\t' '{printf "%-12s %-20s %s\n", $1, $2, $3}'
  else
    printf '%b%-12s %s%b\n' "$__C_BOLD" "CLI" "PROFILE" "$__C_RESET"
    printf '%s\n' "$rows" | awk -F'\t' '{printf "%-12s %s\n", $1, $2}'
  fi
}
