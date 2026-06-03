# shellcheck shell=bash
# lib/commands/status.sh — `clikae status [<engine>] [--json]`
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

# _status_row_for <engine>  -> one canonical row, fields separated by ASCII Unit
# Separator (\037), record terminated by newline:
#   cli ␟ state ␟ profile ␟ account ␟ envVar ␟ envValue
# state ∈ active | default | external | flag | global | noadapter. Empty fields ARE empty.
# (A non-whitespace delimiter is deliberate: tab is IFS-whitespace, so `read`
# would collapse consecutive empty fields and shift every column.)
_status_row_for() {
  local cli="$1"
  (
    # No adapter file for this engine. load_adapter log_fails (exit 1) on a miss,
    # which the `||` below CANNOT catch — `exit` kills this subshell before the
    # guard runs, and under `set -e` the empty `$(...)` then aborts cmd_status
    # (the very trap cmd_list documents). So gate on the file first.
    if [ ! -f "$CLIKAE_LIB/adapters/$cli.sh" ]; then
      # agy is target-backed: a machine-wide ~/.gemini symlink, not a per-shell
      # env var. Report the tank it points at as `global` so it isn't silently
      # dropped (and so this whole command doesn't crash just because an agy
      # tank exists). See lib/commands/antigravity.sh:_agy_active.
      if [ "$cli" = "antigravity" ] || [ "$cli" = "agy" ]; then
        local link="$HOME/.gemini" slots target active=""
        slots="$(profiles_root)/antigravity"
        if [ -L "$link" ]; then
          target="$(readlink "$link")"
          case "$target" in "$slots"/*) active="$(basename "$target")" ;; esac
        fi
        if [ -n "$active" ]; then
          printf '%s\037global\037%s\037\037\037%s\n' agy "$active" "$target"
        else
          printf '%s\037global\037\037\037\037\n' agy
        fi
      else
        printf '%s\037noadapter\037\037\037\037\n' "$cli"
      fi
      exit 0
    fi
    load_adapter "$cli" >/dev/null 2>&1
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
  printf '%b%-12s %-12s %-26s %s%b\n' "$__C_BOLD" "ENGINE" "TANK" "ACCOUNT" "SOURCE" "$__C_RESET"
  local cli state profile account envVar envValue active_col account_col source_col
  while IFS=$'\037' read -r cli state profile account envVar envValue; do
    [ -n "$cli" ] || continue
    account_col="${account:--}"
    case "$state" in
      active)    active_col="$profile";     source_col="$envVar=$envValue" ;;
      external)  active_col="(external)";    source_col="$envVar=$envValue  — not a clikae tank" ;;
      default)   active_col="(default)";     source_col="$envVar unset — system default" ;;
      flag)      active_col="(n/a)";         source_col="flag-based — not detectable from the environment" ;;
      global)    active_col="${profile:-(none)}"
                 # ~/.gemini below is literal label text (naming the symlink), not a path to expand.
                 # shellcheck disable=SC2088
                 if [ -n "$envValue" ]; then source_col="~/.gemini → $envValue  (machine-wide, all shells)"
                 else                         source_col="~/.gemini — not a clikae-managed symlink"; fi ;;
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
Usage: clikae status [<engine>] [--json]

Show which tank each engine is currently using *in this shell*, by reading the
live value of each adapter's env var (e.g. $CLAUDE_CONFIG_DIR) and resolving it
back to a clikae tank.

This is a per-shell view: another terminal — or one started from a different
`clikae app` launcher — may be on a different tank. An engine shows "(default)"
when its env var is unset (the engine's own system default), or "(external)"
when the var points somewhere that isn't a clikae tank.

Arguments:
  <engine>   Only show status for this engine (e.g. claude). Omit for all.

Options:
  --json  Emit a JSON array instead of a table — one object per engine with fields
          {cli, state, profile, account, envVar, envValue}, where state is one of
          active | default | external | flag | global | noadapter (profile/account/
          envValue are null when not applicable). "global" is agy's machine-wide
          ~/.gemini symlink (envValue = its target). For the menu-bar GUI and scripts.

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

  # Which CLIs to report on. With an explicit <engine>, just that one. Otherwise
  # every CLI that has at least one profile.
  local clis=""
  if [ -n "$only_cli" ]; then
    validate_name cli "$only_cli"
    clis="$only_cli"
  else
    clis="$(list_all_profiles | awk -F'\t' '{print $1}' | sort -u)"
    if [ -z "$clis" ]; then
      [ "$as_json" -eq 1 ] && { printf '[]\n'; return 0; }
      log_info "No tanks yet. Create one with:  clikae init <engine> <tank>"
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
    return 0
  fi

  printf '%s' "$rows" | _status_render_table

  # The "what clikae did" tail — recent session carries (clikae to / board relay,
  # and later the supervisor's auto-switches). Only shown when there's history.
  local recent; recent="$(history_recent 5)"
  if [ -n "$recent" ]; then
    printf '\n  %brecent carries%b\n' "$__C_BOLD" "$__C_RESET"
    printf '%s\n' "$recent" | while IFS= read -r _l; do
      [ -n "$_l" ] && printf '    %b%s%b\n' "$__C_DIM" "$_l" "$__C_RESET"
    done
  fi
}
