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
  i18n_load "$(clikae_lang)"   # T_* aren't loaded at source time; the agy note below is localised
  local show_paths=0 as_json=0 available=0 engine="" order="" include_cockpit=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--paths) show_paths=1; shift ;;
      --json)     as_json=1; shift ;;
      --available) available=1; shift ;;
      --include-cockpit) include_cockpit=1; shift ;;
      --order)
        [ "${2:-}" = expiring ] || log_fail "--order requires expiring"
        order="$2"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae tanks [-p|--paths] [--json]      (alias: clikae list / ls)
       clikae tanks --available [engine] [--order expiring] [--include-cockpit] [--json]

--available lists eligible tank names, highest remaining quota per hour to reset
first. Uses the weekly window, or the single window when no weekly value exists.
Skips unreadable usage, usage >=90% (>=98% with <24h until reset), a separate
5h window >=95%, and the cockpit unless --include-cockpit is given. JSON includes
all tanks in scope: {engine, tank, available, score, reason}. Reasons are
unreadable / quota / window / cockpit, or null when eligible.

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
      -*) log_fail "Unexpected argument: $1" ;;
      *) [ -z "$engine" ] || log_fail "Unexpected argument: $1"
         engine="$1"; shift ;;
    esac
  done

  if [ "$available" = 1 ]; then
    [ "$show_paths" = 0 ] || log_fail "--paths does not apply to --available"
    _list_available "$engine" "$include_cockpit" "$as_json"
    return
  fi
  [ -z "$engine$order" ] && [ "$include_cockpit" = 0 ] || log_fail "Engine, --order and --include-cockpit require --available"

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
    dcli="$(engine_label "$cli")"
    enriched="$enriched$dcli"$'\037'"$profile"$'\037'"$account"$'\037'"$path"$'\n'
  done <<EOF
$rows
EOF

  if [ "$as_json" -eq 1 ]; then
    printf '%s' "$enriched" | _list_render_json
  else
    printf '%s' "$enriched" | _list_render_table "$show_paths"
    # Flag agy's nature: global login, one account active across all shells, so
    # it can never run two tanks in PARALLEL — but `clikae burn agy <tank>` CAN
    # reroute it sequentially on dry (Keychain carry, no OAuth), and it runs fine
    # headless on the active account via `agy -p`.
    # Localised via T_AGY_BURN_NOTE (lib/core/i18n.sh); English string is the fallback.
    case $'\n'"$enriched" in
      *$'\n'"agy"$'\037'*) printf '\n%b  %s%b\n' "$__C_DIM" "${T_AGY_BURN_NOTE:-agy login is global (one account at a time, never two in parallel) — clikae burn agy <tank> can reroute it sequentially on dry (Keychain carry, no OAuth needed), or run it headless on the active account with agy -p.}" "$__C_RESET" ;;
    esac
  fi
}

# Compose the same inventory and readings as tanks/usage, without launching
# another clikae process or waking an engine. Readers own freshness (#179).
_list_available() {
  local engine="$1" include_cockpit="$2" as_json="$3"
  local e t path reading row rows="" cockpit now result
  command -v jq >/dev/null 2>&1 || { log_err "--available requires jq"; return 1; }
  # shellcheck source=cockpit.sh
  source "$CLIKAE_LIB/commands/cockpit.sh"
  [ "$engine" != agy ] || engine=antigravity
  [ -z "$engine" ] || validate_name engine "$engine"
  now="$(date +%s)"
  while IFS=$'\t' read -r e t path; do
    [ -n "$e" ] || continue
    [ -z "$engine" ] || [ "$e" = "$engine" ] || continue
    cockpit=0
    if [ "$include_cockpit" = 0 ] && _cockpit_is_recorded "$e" "$t"; then cockpit=1; fi
    reading="$(usage_read "$e" "$t")" || reading='{}'
    row="$(jq -cn --arg reading "$reading" --arg engine "$(engine_label "$e")" \
      --arg tank "$t" --argjson cockpit "$cockpit" --argjson now "$now" \
      "$_USAGE_NORM_STAMP_JQ"'
      def pct: type == "number" and . >= 0 and . <= 100;
      ($reading | try fromjson catch {}) as $r |
      ($r.weekly_pct != null) as $weekly |
      (if $weekly then $r.weekly_pct else $r.window_pct end) as $used |
      (if $weekly then $r.weekly_resets_at else $r.window_resets_at end
       | try norm_stamp catch null) as $reset |
      (($used|pct) and $reset != null and
       ($r.window_pct == null or ($r.window_pct|pct))) as $readable |
      (if $readable then ([($reset-$now)/3600, 0.5]|max) else null end) as $hours |
      (if $cockpit == 1 then "cockpit"
       elif ($readable|not) then "unreadable"
       elif $used >= (if $hours < 24 then 98 else 90 end) then "quota"
       elif $weekly and $r.window_pct != null and $r.window_pct >= 95 then "window"
       else null end) as $reason |
      {engine:$engine,tank:$tank,available:($reason == null),
       score:(if $readable then (100-$used)/$hours else null end),reason:$reason}' )" || return 1
    rows="$rows$row"$'\n'
  done <<EOF_PROFILES
$(list_all_profiles)
EOF_PROFILES
  result="$(printf '%s' "$rows" | jq -s 'sort_by([if .available then 0 else 1 end, -(.score // 0), .engine, .tank])')" || return 1
  if [ "$as_json" = 1 ]; then
    printf '%s\n' "$result"
  else
    printf '%s' "$result" | jq -r '.[] | select(.available) | .tank'
  fi
}
