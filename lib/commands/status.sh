# shellcheck shell=bash
# lib/commands/status.sh — `clikae status [<cli>]`
#
# Shows which profile each CLI is *currently* pointed at **in this shell**, by
# reading the live value of each adapter's env var and resolving it back to a
# clikae profile. This is a per-shell view: a different terminal (or one
# launched from a different `clikae app`) can be on a different profile.

# Render one status row for <cli>. Reads the adapter meta in a subshell.
_status_row_for() {
  local cli="$1"
  (
    load_adapter "$cli" >/dev/null 2>&1 || { printf '%s\t?\t?\t(no adapter)\n' "$cli"; exit 0; }
    local var strategy value active note
    var="$(adapter_meta_env_var)"
    strategy="$(adapter_meta_strategy)"

    # flag-strategy adapters select the profile via a CLI flag, not an env var,
    # so there's nothing in the environment to read back.
    if [ -z "$var" ]; then
      printf '%s\t%s\t%s\n' "$cli" "(n/a)" "flag-based — not detectable from the environment"
      exit 0
    fi

    # Indirect expansion — bash 3.2 supports ${!var}.
    value="${!var}"
    active="$(resolve_active_profile "$cli" "$strategy" "$value")"

    if [ -n "$active" ]; then
      note="$var=$value"
    elif [ -n "$value" ]; then
      active="(external)"
      note="$var=$value  — not a clikae profile"
    else
      active="(default)"
      note="$var unset — system default"
    fi
    printf '%s\t%s\t%s\n' "$cli" "$active" "$note"
  )
}

cmd_status() {
  local only_cli=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae status [<cli>]

Show which profile each CLI is currently using *in this shell*, by reading the
live value of each adapter's env var (e.g. $CLAUDE_CONFIG_DIR) and resolving it
back to a clikae profile.

This is a per-shell view: another terminal — or one started from a different
`clikae app` launcher — may be on a different profile. A CLI shows "(default)"
when its env var is unset (the CLI's own system default), or "(external)" when
the var points somewhere that isn't a clikae profile.

Arguments:
  <cli>   Only show status for this CLI (e.g. claude). Omit for all.

Examples:
  clikae status
  clikae status claude
EOF
        return 0
        ;;
      -*) log_fail "Unknown flag: $1" ;;
      *)
        if [ -z "$only_cli" ]; then only_cli="$1"; else log_fail "Unexpected argument: $1"; fi
        shift
        ;;
    esac
  done

  # Which CLIs to report on. With an explicit <cli>, just that one. Otherwise
  # every CLI that has at least one profile.
  local clis=""
  if [ -n "$only_cli" ]; then
    validate_name cli "$only_cli"
    clis="$only_cli"
  else
    clis="$(list_all_profiles | awk -F'\t' '{print $1}' | sort -u)"
    if [ -z "$clis" ]; then
      log_info "No profiles yet. Create one with:  clikae init <cli> <profile>"
      return 0
    fi
  fi

  printf '%b%-12s %-12s %s%b\n' "$__C_BOLD" "CLI" "ACTIVE" "SOURCE" "$__C_RESET"
  local cli
  while IFS= read -r cli; do
    [ -n "$cli" ] || continue
    _status_row_for "$cli"
  done <<EOF | awk -F'\t' '{printf "%-12s %-12s %s\n", $1, $2, $3}'
$clis
EOF
}
