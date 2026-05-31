# shellcheck shell=bash
# lib/commands/home.sh — `clikae` with no arguments opens here: your home
# dashboard, the screen clikae wants to be the first thing you type.
#
# Two states, both read-only:
#   have tanks -> the "tank board": every profile (tank) grouped by CLI, the one
#                 active in THIS shell marked, account labels, the fuel-pool
#                 fall-through order, and how to launch.
#   no tanks   -> a welcome: what clikae found on this machine + the first step.
# The full command reference is one keystroke away at `clikae help`; the deep
# machine check at `clikae doctor`.

# _home_active_for <cli>  -> the profile active for <cli> in THIS shell, or empty.
# Mirrors `clikae status`: read the adapter's live env var and resolve it back.
_home_active_for() {
  local cli="$1"
  (
    load_adapter "$cli" >/dev/null 2>&1 || exit 0
    local var strategy value
    var="$(adapter_meta_env_var)"
    [ -n "$var" ] || exit 0     # flag-strategy CLIs aren't detectable from env
    strategy="$(adapter_meta_strategy)"
    value="${!var}"
    resolve_active_profile "$cli" "$strategy" "$value"
  )
}

# The tank board: $1 = the (tab-delimited cli/profile/path) rows from
# list_all_profiles, sorted by cli then profile so we can group as we go.
_home_tank_board() {
  local rows="$1"
  log_bold "clikae  ｷﾘｶｴ  ·  your tanks"
  echo ""
  local cur_cli="" active="" cli profile path label
  while IFS=$'\t' read -r cli profile path; do
    [ -n "$cli" ] || continue
    if [ "$cli" != "$cur_cli" ]; then
      cur_cli="$cli"
      active="$(_home_active_for "$cli")"
      printf '  %b%s%b\n' "$__C_BOLD" "$cli" "$__C_RESET"
    fi
    label="$(
      load_adapter "$cli" >/dev/null 2>&1 || exit 0
      adapter_label "$path"
    )"
    if [ -n "$active" ] && [ "$profile" = "$active" ]; then
      printf '    %b●%b %-16s %b%-26s%b %b← active here%b\n' \
        "$__C_GREEN" "$__C_RESET" "$profile" "$__C_DIM" "${label:--}" "$__C_RESET" "$__C_GREEN" "$__C_RESET"
    else
      printf '    %b○%b %-16s %b%-26s%b\n' \
        "$__C_DIM" "$__C_RESET" "$profile" "$__C_DIM" "${label:--}" "$__C_RESET"
    fi
  done <<EOF
$rows
EOF
  echo ""

  # Fuel pool fall-through order (if the user has set one).
  local pool
  pool="$(pool_list | awk 'NR>1{printf " → "} {printf "%s", $0} END{ if (NR) print "" }')"
  [ -n "$pool" ] && printf '  %-9s %s\n' "fuel pool" "$pool"

  # Launch hint: prefer whichever tank is active in this shell, else the first.
  local first_cli first_profile
  first_cli="$(printf '%s\n' "$rows" | head -n1 | cut -f1)"
  first_profile="$(printf '%s\n' "$rows" | head -n1 | cut -f2)"
  printf '  %-9s %s\n' "launch" "clikae run $first_cli $first_profile   ${__C_DIM}(or your alias, e.g. $first_cli-$first_profile)${__C_RESET}"
  printf '  %-9s %s\n' "more"   "clikae status · clikae doctor · clikae watch · clikae help"
}

# The welcome screen, shown when there are no profiles yet. Uses the read-only
# machine scan to point at the CLIs the user actually has.
_home_welcome() {
  log_bold "clikae  ｷﾘｶｴ  ·  one CLI, many accounts — swap the tank, keep burning"
  echo ""
  local installed="" total=0 cli inst binary strategy count label
  while IFS=$'\037' read -r cli inst binary strategy count label; do
    [ -n "$cli" ] || continue
    : "$binary" "$strategy" "$count" "$label"
    total=$((total + 1))
    if [ "$inst" -eq 1 ]; then
      [ -n "$installed" ] && installed="$installed · $cli" || installed="$cli"
    fi
  done <<EOF
$(scan_clis)
EOF

  local example="claude"
  if [ -n "$installed" ]; then
    printf '  No tanks yet. clikae supports %d CLIs; installed on this machine:\n' "$total"
    printf '    %b%s%b\n' "$__C_GREEN" "$installed" "$__C_RESET"
    example="$(printf '%s' "$installed" | awk '{print $1}')"
  else
    printf '  No tanks yet. clikae supports %d CLIs (none of them detected on PATH here).\n' "$total"
  fi
  echo ""
  log_bold "Fill your first tank (pick a CLI you use):"
  log_dim  "  clikae init $example work --alias     # then: source your rc, run $example-work"
  echo ""
  log_dim "See every supported CLI:  clikae adapters        Full machine check:  clikae doctor"
}

cmd_home() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae            (no arguments)

Opens the home dashboard — your "tank board": every profile grouped by CLI, the
one active in this shell marked, account labels, and the fuel-pool order. With no
profiles yet it welcomes you and points at the first step.

The full command reference is at `clikae help`; the machine check at
`clikae doctor`.
EOF
      return 0 ;;
    "") : ;;
    *) log_fail "Unexpected argument: $1  (try: clikae help)" ;;
  esac

  local rows; rows="$(list_all_profiles || true)"
  if [ -z "$rows" ]; then
    _home_welcome
  else
    _home_tank_board "$rows"
  fi
}
