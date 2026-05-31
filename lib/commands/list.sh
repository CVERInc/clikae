# shellcheck shell=bash
# lib/commands/list.sh — `clikae list [-p|--paths] [--json]`
#
# Lists every profile across all CLIs, enriched with the logged-in account label
# where the adapter can tell. One canonical row (US-delimited) feeds either a
# human table or a JSON array, so the two can't drift.

# Render canonical rows (on stdin: cli ␟ profile ␟ account ␟ path) as a table.
# $1 = show_paths (1/0). Empty account renders as "-".
_list_render_table() {
  local show_paths="$1" cli profile account path
  if [ "$show_paths" -eq 1 ]; then
    printf '%b%-12s %-20s %-26s %s%b\n' "$__C_BOLD" "CLI" "PROFILE" "ACCOUNT" "PATH" "$__C_RESET"
  else
    printf '%b%-12s %-20s %s%b\n' "$__C_BOLD" "CLI" "PROFILE" "ACCOUNT" "$__C_RESET"
  fi
  while IFS=$'\037' read -r cli profile account path; do
    [ -n "$cli" ] || continue
    if [ "$show_paths" -eq 1 ]; then
      printf '%-12s %-20s %-26s %s\n' "$cli" "$profile" "${account:--}" "$path"
    else
      printf '%-12s %-20s %s\n' "$cli" "$profile" "${account:--}"
    fi
  done
}

# Render canonical rows (on stdin) as a JSON array.
_list_render_json() {
  local cli profile account path first=1
  printf '['
  while IFS=$'\037' read -r cli profile account path; do
    [ -n "$cli" ] || continue
    [ "$first" -eq 1 ] && first=0 || printf ','
    printf '\n  {"cli":%s,"profile":%s,"account":%s,"path":%s}' \
      "$(json_str "$cli")" "$(json_str "$profile")" "$(json_or_null "$account")" "$(json_str "$path")"
  done
  [ "$first" -eq 1 ] && printf ']\n' || printf '\n]\n'
}

cmd_list() {
  local show_paths=0 as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--paths) show_paths=1; shift ;;
      --json)     as_json=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae list [-p|--paths] [--json]

List all profiles across all CLIs. The ACCOUNT column shows which account each
profile is logged in to (when the adapter can tell — e.g. the email for claude),
so you don't have to remember what a name means.

Options:
  -p, --paths   Also show the profile directory path.
  --json        Emit a JSON array instead of a table — one object per profile
                {cli, profile, account, path} (account is null when unknown).
                For the menu-bar GUI and scripts; --paths is implied (path is
                always included).
EOF
        return 0
        ;;
      *) log_fail "Unexpected argument: $1" ;;
    esac
  done

  local rows
  rows="$(list_all_profiles || true)"
  if [ -z "$rows" ]; then
    [ "$as_json" -eq 1 ] && { printf '[]\n'; return 0; }
    log_info "No profiles yet. Create one with:  clikae init <cli> <profile>"
    return 0
  fi

  # Enrich each profile with its account label (best-effort, from the adapter),
  # into US-delimited rows so empty account fields survive (tab would collapse).
  local enriched="" cli profile path account
  while IFS="$(printf '\t')" read -r cli profile path; do
    [ -n "$cli" ] || continue
    account="$(
      load_adapter "$cli" >/dev/null 2>&1 || exit 0
      adapter_label "$path"
    )"
    enriched="$enriched$cli"$'\037'"$profile"$'\037'"$account"$'\037'"$path"$'\n'
  done <<EOF
$rows
EOF

  if [ "$as_json" -eq 1 ]; then
    printf '%s' "$enriched" | _list_render_json
  else
    printf '%s' "$enriched" | _list_render_table "$show_paths"
  fi
}
