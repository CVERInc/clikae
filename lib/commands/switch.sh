# shellcheck shell=bash
# lib/commands/switch.sh — the BARE SWITCH: `clikae <engine> [tank] [-- args]`.
#
# clikae's headline action, and it carries no verb of its own: the program name
# IS the verb (clikae = 切り替え, "switch"). `clikae claude work` reads "switch
# claude to work". See docs/grammar.md §3.1 / §5.
#
# This handler is reached from the dispatcher when the first argument is an
# installed engine (an adapter in lib/adapters/), not a reserved command.

# _switch_active_tank <engine>  -> the tank active for <engine> in THIS shell
# (resolved from the live env var), or empty. Mirrors `clikae status`.
_switch_active_tank() {
  local engine="$1"
  [ -f "$CLIKAE_LIB/adapters/$engine.sh" ] || return 0
  (
    load_adapter "$engine" >/dev/null 2>&1 || exit 0
    local var strategy value
    var="$(adapter_meta_env_var)"
    [ -n "$var" ] || exit 0     # flag-strategy engines aren't detectable from env
    strategy="$(adapter_meta_strategy)"
    value="${!var}"
    resolve_active_profile "$engine" "$strategy" "$value"
  )
}

# §5 dry-aware guard (option B). Only fires when the tank we're CURRENTLY on for
# this engine in this shell is over quota — the one moment a silent fresh start
# is the opposite of intent. Otherwise switching is silent and instant.
# May exec (carry); if it returns, the caller proceeds with a fresh start.
_switch_dry_guard() {
  local engine="$1" current="$2" tank="$3" cur_dir
  cur_dir="$(profile_dir "$engine" "$current")"
  limit_profile_dry "$engine" "$cur_dir" >/dev/null 2>&1 || return 0

  if [ -t 0 ] && [ -t 1 ]; then
    log_warn "$engine/$current is out of fuel right now."
    printf '  Carry this session over to %b%s%b, or start it fresh?\n' \
      "$__C_BOLD" "$tank" "$__C_RESET"
    printf '    %b[c]%b carry over (resume)   %b[f]%b start fresh   %b[q]%b cancel: ' \
      "$__C_GREEN" "$__C_RESET" "$__C_DIM" "$__C_RESET" "$__C_DIM" "$__C_RESET"
    local ans; IFS= read -r ans || ans="q"
    case "$ans" in
      # Carry: hand to `clikae to` (same engine -> relay, with its own preview +
      # confirm, so carrying is never a blind leap).
      c|C|"") exec "$CLIKAE_BIN" to "$engine" "$tank" ;;
      f|F)    return 0 ;;
      *)      log_info "Cancelled — staying on $engine/$current."; exit 0 ;;
    esac
  else
    log_dim "hint: $engine/$current is dry — to continue this session use:  clikae to $engine $tank"
    return 0
  fi
}

_switch_help() {
  cat <<'EOF'
Usage: clikae <engine> [tank] [-- args...]

The bare switch — clikae's main action. Switch <engine> to <tank> and run it.
The verb is the program name (clikae = "switch"), so none is typed.

  clikae claude work            switch claude to the 'work' tank and run it
  clikae claude                 if claude has one tank, use it; else list them
  clikae claude work -- --help  pass everything after -- straight to the engine

To carry your current session onto another tank instead of starting fresh,
use `clikae to` (see: clikae help to).
EOF
}

cmd_switch() {
  local engine="$1"; shift || true
  local tank=""
  local -a passthru=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --)        shift; passthru=("$@"); break ;;
      -h|--help) _switch_help; return 0 ;;
      -*)        log_fail "Unknown flag: $1  (engine flags go after --)" ;;
      *)         if [ -z "$tank" ]; then tank="$1"; shift; else break; fi ;;
    esac
  done

  validate_name cli "$engine"

  # No tank: 0 -> offer to create; 1 -> use it; many -> list and ask.
  if [ -z "$tank" ]; then
    local tanks count
    tanks="$(list_all_profiles | awk -F'\t' -v e="$engine" '$1==e{print $2}')"
    count="$(printf '%s\n' "$tanks" | grep -c . || true)"
    if [ "$count" -eq 0 ]; then
      log_info "No $engine tanks yet."
      log_dim  "Create one:  clikae init $engine <tank>"
      return 0
    elif [ "$count" -eq 1 ]; then
      tank="$tanks"
    else
      log_info "$engine has several tanks — pick one:"
      printf '%s\n' "$tanks" | while IFS= read -r t; do
        [ -n "$t" ] && printf '    clikae %s %s\n' "$engine" "$t"
      done
      return 0
    fi
  fi

  validate_name profile "$tank"
  profile_exists "$engine" "$tank" \
    || log_fail "No such tank: $engine/$tank  (create it:  clikae init $engine $tank)"

  # §5: only nags when the current tank is dry; otherwise silent.
  local current
  current="$(_switch_active_tank "$engine")"
  if [ -n "$current" ] && [ "$current" != "$tank" ]; then
    _switch_dry_guard "$engine" "$current" "$tank"
  fi

  # Fresh switch: apply the tank's env and exec the engine.
  local d
  d="$(ensure_profile --require "$engine" "$tank")"
  load_adapter "$engine"
  adapter_run "$d" "${passthru[@]}"
}
