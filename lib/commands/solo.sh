# shellcheck shell=bash
# lib/commands/solo.sh — `clikae solo`: mark a tank as standalone (out of the fleet).
#
# The board's tanks are a FLEET: `to`/relay/`watch`/`burn` flow work across them and
# `memory share` lets them share one brain. A SOLO tank opts out of all of that — it
# won't receive a carried session, won't be an auto-switch target when another tank
# runs dry, and `memory share` refuses it. For a dedicated, standalone tank (a
# bot/persona tank on your own account, a client-only tank) that must stay separate.
#
#   clikae solo                         list the solo tanks
#   clikae solo <engine> <tank> [why]   make a tank solo (optional reason)
#   clikae solo <engine> <tank> --off   put it back in the fleet
#
# State is one marker file per tank (lib/core/profile_store.sh: solo_marker_file);
# tank_is_solo is the predicate the fleet (to/watch/burn) and memory share check.

cmd_solo() {
  local engine="" tank="" off=0 reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae solo                          list standalone (solo) tanks
       clikae solo <engine> <tank> [reason] make a tank solo
       clikae solo <engine> <tank> --off    return it to the fleet

A SOLO tank opts out of the fleet: it's never a `to`/relay target, the burn/`watch`
rotation skips it, and `clikae memory share` refuses it. Use it for a dedicated,
standalone tank (e.g. a bot/persona tank on the same account as your main one) that
must never receive carried work or share a brain. The cross-account guard can't see
this — same account, different purpose — so solo is how you wall it off.
EOF
        return 0 ;;
      --off) off=1; shift ;;
      -*) log_fail "solo: unknown flag: $1" ;;
      *) if [ -z "$engine" ]; then engine="$1"
         elif [ -z "$tank" ]; then tank="$1"
         else reason="${reason:+$reason }$1"; fi
         shift ;;
    esac
  done

  # No tank → list the solo ones.
  if [ -z "$engine" ]; then
    local saw=0
    log_info "solo (standalone) tanks — out of the fleet (no relay/burn/share):"
    while IFS=$'\t' read -r cli tname _; do
      tank_is_solo "$cli" "$tname" || continue
      saw=1
      local r; r="$(head -n1 "$(solo_marker_file "$cli" "$tname")" 2>/dev/null || true)"
      log_ok "  $cli/$tname${r:+   — $r}"
    done < <(list_all_profiles)
    [ "$saw" -eq 1 ] || log_dim "  (none — every tank is in the fleet)"
    return 0
  fi

  [ -n "$tank" ] || log_fail "solo: name a tank:  clikae solo <engine> <tank>"
  local canon="$engine"; [ "$canon" = "agy" ] && canon="antigravity"
  profile_exists "$canon" "$tank" || log_fail "solo: no such tank: $engine/$tank"

  local f; f="$(solo_marker_file "$canon" "$tank")"
  if [ "$off" -eq 1 ]; then
    if [ -f "$f" ]; then
      rm -f "$f"
      log_ok "$engine/$tank rejoined the fleet — relay/burn/share apply again."
    else
      log_ok "$engine/$tank wasn't solo."
    fi
    return 0
  fi

  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$reason" > "$f"
  log_ok "$engine/$tank is now solo — out of the fleet."
  log_dim "no relay/\`to\` target · skipped by burn/watch · \`memory share\` refuses it."
  [ -n "$reason" ] && log_dim "reason: $reason"
  return 0
}
