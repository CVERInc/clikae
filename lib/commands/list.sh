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
    printf '%b%-12s %-20s %-26s %s%b\n' "$__C_BOLD" "ENGINE" "TANK" "ACCOUNT" "PATH" "$__C_RESET"
  else
    printf '%b%-12s %-20s %s%b\n' "$__C_BOLD" "ENGINE" "TANK" "ACCOUNT" "$__C_RESET"
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
Usage: clikae tanks [-p|--paths] [--json]      (alias: clikae list / ls)

List all tanks across all engines. The ACCOUNT column shows which account each
tank is logged in to (when the adapter can tell — e.g. the email for claude),
so you don't have to remember what a name means.

Options:
  -p, --paths   Also show the tank directory path.
  --json        Emit a JSON array instead of a table — one object per tank
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
    log_info "No tanks yet. Create one with:  clikae init <engine> <tank>"
    return 0
  fi

  # Enrich each tank with its account label (best-effort, from the adapter), into
  # US-delimited rows so empty account fields survive (tab would collapse).
  local enriched="" cli profile path account dcli
  while IFS="$(printf '\t')" read -r cli profile path; do
    [ -n "$cli" ] || continue
    # Gate on the adapter FILE: load_adapter log_fails (exit 1) on a miss, which
    # under `set -e` would kill cmd_list. target-backed tanks (e.g. agy) have no
    # adapter, so they list with an empty account.
    account=""
    if [ -f "$CLIKAE_LIB/adapters/$cli.sh" ]; then
      account="$(load_adapter "$cli" >/dev/null 2>&1 && adapter_label "$path" || true)"
    fi
    # agy has no adapter (account stays empty). It DOES log its signed-in Google
    # account under <tank>/antigravity-cli/log — read it (same source the home board
    # uses, so list and board agree). The ACCOUNT column is for the account, not the
    # active state (that's `clikae status` / the board cursor), so an un-logged-in
    # tank shows "-", never a faked "(active)".
    if [ "$cli" = "antigravity" ] && [ -z "$account" ]; then
      account="$(agy_email "${path%/}" 2>/dev/null || true)"
    fi
    # Display the canonical engine name: the on-disk dir is 'antigravity', the
    # engine you type is 'agy' (docs/grammar.md §6).
    dcli="$cli"; [ "$cli" = "antigravity" ] && dcli="agy"
    enriched="$enriched$dcli"$'\037'"$profile"$'\037'"$account"$'\037'"$path"$'\n'
  done <<EOF
$rows
EOF

  if [ "$as_json" -eq 1 ]; then
    printf '%s' "$enriched" | _list_render_json
  else
    printf '%s' "$enriched" | _list_render_table "$show_paths"
    # Flag agy's nature so nobody tries `burn agy`: its login is global (one account
    # across all shells), so there's no per-tank headless burn — interactive switch only.
    case $'\n'"$enriched" in
      *$'\n'"agy"$'\037'*) printf '\n%b  agy login is global — one account active at a time, interactive switch only (clikae agy <tank>); not burnable.%b\n' "$__C_DIM" "$__C_RESET" ;;
    esac
  fi
}
