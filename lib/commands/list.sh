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

List all profiles across all CLIs. The ACCOUNT column shows which account each
profile is logged in to (when the adapter can tell — e.g. the email for claude),
so you don't have to remember what a name means.

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

  # Enrich each row with the account label from its adapter (best-effort).
  local enriched="" cli profile path account
  while IFS="$(printf '\t')" read -r cli profile path; do
    [ -n "$cli" ] || continue
    account="$(
      load_adapter "$cli" >/dev/null 2>&1 || exit 0
      adapter_label "$path"
    )"
    [ -n "$account" ] || account="-"
    enriched="$enriched$cli	$profile	$account	$path
"
  done <<EOF
$rows
EOF

  # Pretty table.
  if [ "$show_paths" -eq 1 ]; then
    printf '%b%-12s %-20s %-26s %s%b\n' "$__C_BOLD" "CLI" "PROFILE" "ACCOUNT" "PATH" "$__C_RESET"
    printf '%s' "$enriched" | awk -F'\t' 'NF>=4{printf "%-12s %-20s %-26s %s\n", $1, $2, $3, $4}'
  else
    printf '%b%-12s %-20s %s%b\n' "$__C_BOLD" "CLI" "PROFILE" "ACCOUNT" "$__C_RESET"
    printf '%s' "$enriched" | awk -F'\t' 'NF>=4{printf "%-12s %-20s %s\n", $1, $2, $3}'
  fi
}
