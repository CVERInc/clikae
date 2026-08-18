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
# Solo is the ONE way out of the shared brain: `memory isolate` was retired
# because it created a tank inside the fleet with no brain — invisible on a board
# whose only axis is fleet-vs-solo.
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
rotation skips it, and it keeps its OWN memory instead of the shared brain —
making a tank solo leaves the shared group and gives its own memory back, and
`--off` puts it back in both. Use it for a dedicated,
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
      log_done "  $cli/$tname${r:+   — $r}"
    done < <(list_all_profiles)
    [ "$saw" -eq 1 ] || log_dim "  (none — every tank is in the fleet)"
    return 0
  fi

  [ -n "$tank" ] || log_fail "solo: name a tank:  clikae solo <engine> <tank>"
  local canon="$engine"; [ "$canon" = "agy" ] && canon="antigravity"
  profile_exists "$canon" "$tank" || log_fail "solo: no such tank: $engine/$tank"

  local f; f="$(solo_marker_file "$canon" "$tank")"
  local dgroup; dgroup="$(soul_default_group 2>/dev/null || true)"

  if [ "$off" -eq 1 ]; then
    if [ -f "$f" ]; then
      rm -f "$f"
      log_done "$engine/$tank rejoined the fleet — relay/burn/share apply again."
      # Back in the fleet means back in the shared brain: the whole point of the
      # model is that those two are the same statement.
      #
      # 🔴 The group this tank ACTUALLY left wins over the machine default. The
      # default is written only by the first `memory share` ever run here, so it
      # is empty on plenty of installs — and when it was empty this branch did
      # nothing at all: the marker came off, the board said "in the fleet", and
      # the memory slot stayed the empty directory `_memory_isolate` left. A tank
      # that was in a group seconds ago must not need a global default to get home.
      local _back; _back="$(soul_left_read "$canon" "$tank")"
      [ -n "$_back" ] || _back="$dgroup"
      if [ -n "$_back" ] && [ -z "$(soul_group_for_tank "$canon" "$tank")" ]; then
        if "$CLIKAE_BIN" memory share "$_back" "$canon" "$tank" >/dev/null 2>&1; then
          soul_left_clear "$canon" "$tank"
          log_pass "rejoined the shared memory group '$_back'."
        else
          # The commonest reason is the cross-account guard refusing to commingle
          # two accounts without a human — which is correct. Say the command, so
          # the tank is one deliberate step from its brain instead of stranded.
          log_warn "couldn't rejoin the memory group '$_back' automatically — it keeps its own memory for now."
          log_dim  "If you meant to: clikae memory share $_back $canon $tank   (it will ask, if this crosses accounts)"
        fi
      elif [ -z "$_back" ] && [ -z "$(soul_group_for_tank "$canon" "$tank")" ]; then
        log_dim "(it has its own memory; no shared group on record to rejoin.)"
      fi
    else
      log_pass "$engine/$tank wasn't solo."
    fi
    return 0
  fi

  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$reason" > "$f"
  log_done "$engine/$tank is now solo — out of the fleet."

  # Leaving the fleet IS leaving the shared brain. This used to be a second verb
  # (`memory isolate`), which meant a tank could sit inside the fleet with no
  # brain — a third state the board has no way to show, and a verb that read like
  # "incognito" and got reached for as one (v0.14.3: run on a LIVE tank, the
  # session went amnesiac mid-flight). One idea, one verb, visible on the board.
  local _grp; _grp="$(soul_group_for_tank "$canon" "$tank")"
  if [ -n "$_grp" ]; then
    # Write down WHICH group, before leaving it — this is the only moment the
    # answer is knowable, and `--off` needs it to put the tank back (see there).
    soul_left_set "$canon" "$tank" "$_grp"
    # shellcheck source=./memory.sh
    source "$CLIKAE_LIB/commands/memory.sh"
    _memory_isolate "$canon" "$tank" || log_warn "solo is set, but leaving the memory group failed — check: clikae memory status"
    log_dim "left the shared memory group '$_grp' — 'clikae solo $engine $tank --off' puts it back."
  fi

  log_dim "no relay/\`to\` target · skipped by burn/watch · keeps its own memory."
  [ -n "$reason" ] && log_dim "reason: $reason"
  return 0
}
