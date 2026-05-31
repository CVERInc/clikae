# shellcheck shell=bash
# lib/commands/antigravity.sh — `clikae antigravity`: OPT-IN multi-account for
# Google's Antigravity CLI (agy).
#
# WHY OPT-IN (and not a normal adapter): agy hardcodes its state under ~/.gemini
# and ignores every env var / has no config-dir flag (verified on a real
# install), so clikae's clean per-shell model can't switch it. The ONLY way to
# give it multiple accounts is to SWAP ~/.gemini between per-slot directories —
# which mutates your real home dir and is GLOBAL (one account active at a time
# across all terminals; swapping under a running agy would corrupt its session).
#
# So this is a sudo-style, consciously-enabled power mode: `enable` warns, backs
# up ~/.gemini, and is fully reversible with `disable`. Default clikae never
# touches ~/.gemini; nothing here runs until you opt in.

_agy_slots()   { printf '%s\n' "$(profiles_root)/antigravity"; }
_agy_link()    { printf '%s\n' "$HOME/.gemini"; }
_agy_consent() { printf '%s\n' "$CLIKAE_HOME/antigravity-multi-consent"; }

# Enabled = consent recorded AND ~/.gemini is a symlink we manage.
_agy_enabled() { [ -f "$(_agy_consent)" ] && [ -L "$(_agy_link)" ]; }

# Refuse to swap/restore while an agy process is live (the symlink would change
# under it mid-session). No pgrep -> skip the guard rather than block.
_agy_assert_not_running() {
  command -v pgrep >/dev/null 2>&1 || return 0
  if pgrep -x agy >/dev/null 2>&1; then
    log_fail "An 'agy' process is running. Quit it first — swapping ~/.gemini now would corrupt its live session."
  fi
}

# The slot the ~/.gemini symlink currently points at (basename), or empty.
_agy_active() {
  local link target slots; link="$(_agy_link)"; slots="$(_agy_slots)"
  [ -L "$link" ] || return 0
  target="$(readlink "$link")"
  case "$target" in "$slots"/*) basename "$target" ;; esac
}

_agy_help() {
  cat <<'EOF'
Usage: clikae antigravity <command>

OPT-IN multi-account for Antigravity (agy). agy hardcodes ~/.gemini and ignores
env vars, so the only way to switch accounts is to swap that directory. This is
a power mode — it mutates your real ~/.gemini and is global (one account active
at a time across all terminals). It is reversible.

Commands:
  enable            Turn it on: warns, backs up ~/.gemini, migrates it to a
                    'default' slot, and manages it via a symlink. Asks first.
  add <name>        Create a new empty account slot (then `use` it and log in).
  use <name>        Switch the active account to <name> (refuses if agy is up).
  list | status     Show slots and which one is active. (Default subcommand.)
  disable           Restore a normal single-account ~/.gemini and turn it off.

Typical flow:
  clikae antigravity enable
  clikae antigravity add work
  clikae antigravity use work     # then run `agy` and log in to that account
EOF
}

_agy_enable() {
  if _agy_enabled; then log_info "Antigravity multi-account is already enabled."; _agy_status; return 0; fi
  local link slots; link="$(_agy_link)"; slots="$(_agy_slots)"
  log_warn "Antigravity multi-account is a POWER mode with real tradeoffs:"
  cat >&2 <<EOF
  • It turns your real ~/.gemini into a clikae-managed symlink.
  • It is GLOBAL: only one agy account is active at a time across ALL terminals
    (agy ignores per-shell env). Don't run two accounts at once.
  • Swapping while agy is running can corrupt that session.
  Reversible: 'clikae antigravity disable' restores a normal ~/.gemini.
EOF
  confirm "Enable it (your current ~/.gemini becomes the 'default' slot)?" || { log_info "Not enabled."; return 0; }
  _agy_assert_not_running
  mkdir -p "$slots"
  if [ -L "$link" ]; then
    : # already a symlink — leave as-is
  elif [ -d "$link" ]; then
    local ts bak; ts="$(date +%Y%m%d-%H%M%S)"; bak="$link.clikae.bak.$ts"
    cp -R "$link" "$bak" && log_ok "Backed up ~/.gemini -> $bak"
    mv "$link" "$slots/default" && log_ok "Migrated current ~/.gemini -> slot 'default' (login preserved)"
    ln -s "$slots/default" "$link"
  else
    mkdir -p "$slots/default"
    ln -s "$slots/default" "$link"
    log_ok "Created an empty 'default' slot."
  fi
  printf 'consented %s\n' "$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo yes)" > "$(_agy_consent)"
  log_ok "Antigravity multi-account enabled. Active slot: $(_agy_active)"
  log_dim "Add an account:  clikae antigravity add <name>   then  clikae antigravity use <name>"
}

_agy_add() {
  _agy_enabled || log_fail "Enable first:  clikae antigravity enable"
  local name="$1"; validate_name profile "$name"
  local slot; slot="$(_agy_slots)/$name"
  if [ -d "$slot" ]; then log_info "Slot already exists: $name"; return 0; fi
  mkdir -p "$slot"
  log_ok "Created Antigravity slot: $name"
  log_dim "Switch to it:  clikae antigravity use $name   (then run agy and log in)"
}

_agy_use() {
  _agy_enabled || log_fail "Enable first:  clikae antigravity enable"
  local name="$1" slots link; slots="$(_agy_slots)"; link="$(_agy_link)"
  [ -d "$slots/$name" ] || log_fail "No such slot: $name  (add it:  clikae antigravity add $name)"
  _agy_assert_not_running
  rm -f "$link"
  ln -s "$slots/$name" "$link"
  log_ok "Antigravity is now on slot: $name"
  log_dim "Run it:  agy"
}

_agy_disable() {
  _agy_enabled || { log_info "Antigravity multi-account isn't enabled."; return 0; }
  _agy_assert_not_running
  local link slots active; link="$(_agy_link)"; slots="$(_agy_slots)"; active="$(_agy_active)"
  rm -f "$link"
  if [ -n "$active" ] && [ -d "$slots/$active" ]; then
    cp -R "$slots/$active" "$link" && log_ok "Restored ~/.gemini from slot '$active' (single-account again)."
  else
    log_warn "No active slot to restore; ~/.gemini left absent (agy will recreate it on next run)."
  fi
  rm -f "$(_agy_consent)"
  log_ok "Antigravity multi-account disabled."
  log_dim "Your slots are kept under $slots — delete by hand if you don't want them."
}

_agy_status() {
  if ! _agy_enabled; then
    log_info "Antigravity multi-account: OFF (single-account, launch-only)."
    log_dim "Enable the opt-in power mode:  clikae antigravity enable"
    return 0
  fi
  local slots active d name; slots="$(_agy_slots)"; active="$(_agy_active)"
  log_bold "Antigravity slots:"
  for d in "$slots"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if [ "$name" = "$active" ]; then printf '  %b●%b %s  (active)\n' "$__C_GREEN" "$__C_RESET" "$name"
    else printf '  %b○%b %s\n' "$__C_DIM" "$__C_RESET" "$name"; fi
  done
}

cmd_antigravity() {
  local sub="${1:-status}"
  shift || true
  case "$sub" in
    -h|--help|help) _agy_help ;;
    enable)         _agy_enable ;;
    disable)        _agy_disable ;;
    add)            [ $# -ge 1 ] || log_fail "Usage: clikae antigravity add <name>"; _agy_add "$1" ;;
    use)            [ $# -ge 1 ] || log_fail "Usage: clikae antigravity use <name>"; _agy_use "$1" ;;
    list|status)    _agy_status ;;
    *)              log_fail "Unknown subcommand: $sub  (try: enable, add, use, list, disable)" ;;
  esac
}
