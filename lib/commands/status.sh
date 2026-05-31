# shellcheck shell=bash
# lib/commands/status.sh — `clikae status [<cli>] [--json]`
#
# Shows which profile each CLI is *currently* pointed at **in this shell**, by
# reading the live value of each adapter's env var and resolving it back to a
# clikae profile. This is a per-shell view: a different terminal (or one
# launched from a different `clikae app`) can be on a different profile.
#
# Two renderers off ONE canonical row:
#   human table (default) — aligned columns for the terminal
#   --json                — machine-readable, for the menu-bar GUI / scripts
# The row producer emits tab-separated fields and never formats for a human, so
# the two renderers can't drift.

# JSON string helpers (json_str / json_or_null) live in lib/core/json.sh.

# _status_row_for <cli>  -> one canonical row, fields separated by ASCII Unit
# Separator (\037), record terminated by newline:
#   cli ␟ state ␟ profile ␟ account ␟ envVar ␟ envValue
# state ∈ active | default | external | flag | noadapter. Empty fields ARE empty.
# (A non-whitespace delimiter is deliberate: tab is IFS-whitespace, so `read`
# would collapse consecutive empty fields and shift every column.)
_status_row_for() {
  local cli="$1"
  (
    load_adapter "$cli" >/dev/null 2>&1 || { printf '%s\037noadapter\037\037\037\037\n' "$cli"; exit 0; }
    local var strategy value active
    var="$(adapter_meta_env_var)"
    strategy="$(adapter_meta_strategy)"

    # flag-strategy adapters select the profile via a CLI flag, not an env var,
    # so there's nothing in the environment to read back.
    if [ -z "$var" ]; then
      printf '%s\037flag\037\037\037\037\n' "$cli"
      exit 0
    fi

    # Indirect expansion — bash 3.2 supports ${!var}.
    value="${!var}"
    active="$(resolve_active_profile "$cli" "$strategy" "$value")"

    if [ -n "$active" ]; then
      local account=""
      account="$(adapter_label "$(profile_dir "$cli" "$active")")"
      printf '%s\037active\037%s\037%s\037%s\037%s\n' "$cli" "$active" "$account" "$var" "$value"
    elif [ -n "$value" ]; then
      printf '%s\037external\037\037\037%s\037%s\n' "$cli" "$var" "$value"
    else
      printf '%s\037default\037\037\037%s\037\n' "$cli" "$var"
    fi
  )
}

# Render the canonical rows (on stdin) as an aligned human table.
_status_render_table() {
  printf '%b%-12s %-12s %-26s %s%b\n' "$__C_BOLD" "CLI" "ACTIVE" "ACCOUNT" "SOURCE" "$__C_RESET"
  local cli state profile account envVar envValue active_col account_col source_col
  while IFS=$'\037' read -r cli state profile account envVar envValue; do
    [ -n "$cli" ] || continue
    account_col="${account:--}"
    case "$state" in
      active)    active_col="$profile";     source_col="$envVar=$envValue" ;;
      external)  active_col="(external)";    source_col="$envVar=$envValue  — not a clikae profile" ;;
      default)   active_col="(default)";     source_col="$envVar unset — system default" ;;
      flag)      active_col="(n/a)";         source_col="flag-based — not detectable from the environment" ;;
      noadapter) active_col="?";             source_col="(no adapter)" ;;
      *)         active_col="$state";        source_col="" ;;
    esac
    printf '%-12s %-12s %-26s %s\n' "$cli" "$active_col" "$account_col" "$source_col"
  done
}

# Render the canonical rows (on stdin) as a JSON array.
_status_render_json() {
  local cli state profile account envVar envValue first=1
  printf '['
  while IFS=$'\037' read -r cli state profile account envVar envValue; do
    [ -n "$cli" ] || continue
    [ "$first" -eq 1 ] && first=0 || printf ','
    printf '\n  {"cli":%s,"state":%s,"profile":%s,"account":%s,"envVar":%s,"envValue":%s}' \
      "$(json_str "$cli")" "$(json_str "$state")" \
      "$(json_or_null "$profile")" "$(json_or_null "$account")" \
      "$(json_or_null "$envVar")" "$(json_or_null "$envValue")"
  done
  [ "$first" -eq 1 ] && printf ']\n' || printf '\n]\n'
}

cmd_status() {
  local only_cli="" as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae status [<cli>] [--json]

Show which profile each CLI is currently using *in this shell*, by reading the
live value of each adapter's env var (e.g. $CLAUDE_CONFIG_DIR) and resolving it
back to a clikae profile.

This is a per-shell view: another terminal — or one started from a different
`clikae app` launcher — may be on a different profile. A CLI shows "(default)"
when its env var is unset (the CLI's own system default), or "(external)" when
the var points somewhere that isn't a clikae profile.

Arguments:
  <cli>   Only show status for this CLI (e.g. claude). Omit for all.

Options:
  --json  Emit a JSON array instead of a table — one object per CLI with fields
          {cli, state, profile, account, envVar, envValue}, where state is one of
          active | default | external | flag | noadapter (profile/account/envValue
          are null when not applicable). For the menu-bar GUI and scripts.

Examples:
  clikae status
  clikae status claude
  clikae status --json
EOF
        return 0
        ;;
      --json) as_json=1; shift ;;
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
      [ "$as_json" -eq 1 ] && { printf '[]\n'; return 0; }
      log_info "No profiles yet. Create one with:  clikae init <cli> <profile>"
      return 0
    fi
  fi

  # Build the canonical rows once, then render.
  local rows="" cli
  while IFS= read -r cli; do
    [ -n "$cli" ] || continue
    rows="$rows$(_status_row_for "$cli")"$'\n'
  done <<EOF
$clis
EOF

  if [ "$as_json" -eq 1 ]; then
    printf '%s' "$rows" | _status_render_json
  else
    printf '%s' "$rows" | _status_render_table
  fi
}
