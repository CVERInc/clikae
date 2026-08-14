# shellcheck shell=bash
# lib/commands/wake.sh — `clikae wake`: pick a rate-limited tank back up the
# moment its limit lifts, instead of you setting an alarm.
#
#   clikae wake                     what the setting is, and what it means
#   clikae wake on | off            change it
#   clikae wake <engine> <tank>     attach a waiter to that tank right now
#   clikae wake --sit <s> <epoch>   (internal) the countdown itself, run inside
#                                   the tmux window it belongs to

cmd_wake() {
  case "${1:-}" in
    --watch)
      # Internal, like --sit: the body of the session's `wake` window during its
      # WATCHING phase. It hands over to the countdown in place when the tank
      # goes dry, so one window covers both.
      shift
      wake_watch "${1:-}" "${2:-}" "${3:-}"
      return $?
      ;;
    --sit)
      # Internal. Not in help: it is the body of a tmux window, not something a
      # person types. Kept as a subcommand rather than a private script so the
      # waiter runs the SAME code the tests exercise.
      shift
      wake_sit "${1:-}" "${2:-}"
      return $?
      ;;
    on|off)
      wake_pref_set "$1" || { log_err "Unknown value: $1"; return 1; }
      log_done "clikae will now: $(wake_pref_label "$1")"
      return 0
      ;;
    ""|status)
      local pref; pref="$(wake_pref_get)"
      log_info "wake: $pref — $(wake_pref_label "$pref")"
      [ "$pref" = "unset" ] && log_dim "  You'll be asked the first time a tank runs dry."
      log_dim "  Set with: clikae wake on   |   clikae wake off"
      return 0
      ;;
  esac

  local engine tank
  engine="$1"; tank="${2:-}"
  if [ -z "$tank" ]; then
    log_err "Usage: clikae wake <engine> <tank>   (or: clikae wake on|off)"
    return 1
  fi

  local dir reset session
  dir="$(profile_dir "$engine" "$tank")"
  if [ ! -d "$dir" ]; then
    log_err "No such tank: $engine/$tank"
    return 1
  fi

  # The reset phrase comes from the same detector the board uses — one reading of
  # "is this tank dry", not a second opinion that could disagree with the dot the
  # user is looking at.
  if ! reset="$(limit_tank_dry "$engine" "$tank")"; then
    log_info "$engine/$tank is not out of fuel — nothing to wait for."
    return 0
  fi
  if [ -z "$reset" ]; then
    log_err "$engine/$tank is dry, but the vendor did not say when it resets."
    log_dim "  Without a time there is nothing to count down to; resume by hand."
    return 1
  fi

  local epoch now
  now="$(date +%s)"
  if ! epoch="$(limit_reset_epoch "$reset" "$now")"; then
    log_err "Could not read a time out of: $reset"
    log_dim "  Not scheduling anything — a guessed time would fire at the wrong moment."
    return 1
  fi

  local sessions; sessions="$(wake_sessions_for "$engine" "$tank")"
  if [ -z "$sessions" ]; then
    log_err "No live session for $engine/$tank."
    log_dim "  The waiter types into a session that is still open; there is none."
    log_dim "  Start one with: clikae $engine $tank"
    return 1
  fi

  local attached=0
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    wake_attach "$session" "$epoch" && attached=$((attached + 1))
  done <<EOF
$sessions
EOF
  if [ "$attached" -gt 0 ]; then
    log_done "Waiting on $engine/$tank — $reset"
    log_dim "  It will send \"$WAKE_NUDGE\" $((WAKE_BUFFER_SECONDS))s after that, once the pane is idle."
    log_dim "  Watch or cancel it in the session's 'wake' window."
    return 0
  fi
  log_err "Could not attach the waiter to $session."
  return 1
}
