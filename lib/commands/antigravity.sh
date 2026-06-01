# shellcheck shell=bash
# lib/commands/antigravity.sh — Antigravity (agy) folded into clikae's standard
# grammar. See docs/grammar.md §6.
#
# WHY agy is special: its CLI (`agy`) hardcodes state under ~/.gemini and ignores
# every env var / has no config-dir flag (verified on a real install). clikae's
# clean per-shell model can't switch it, so the only way to give it multiple
# tanks is to SWAP ~/.gemini between per-tank directories via a symlink. That is
# GLOBAL (one tank active at a time across ALL terminals) and mutates your real
# home dir — so the first `init agy` asks before taking over, and it's reversible
# with `clikae agy --release`.
#
# The user types the SAME verbs as every other engine — there is no `agy enable`
# / `add` / `use` / `disable` subcommand tree any more:
#   clikae init agy <tank>     create a tank (first time: warns + confirms takeover)
#   clikae agy [tank]          switch to a tank and run agy (this file's cmd_*)
#   clikae remove agy <tank>   remove a tank (last one offers teardown)
#   clikae agy --release       restore a normal ~/.gemini, keep the tank dirs

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

# Tank basenames, one per line (glob, not ls|grep — handles odd names).
_agy_tank_names() {
  local slots d; slots="$(_agy_slots)"
  [ -d "$slots" ] || return 0
  for d in "$slots"/*/; do [ -d "$d" ] && basename "$d"; done
}

# The tank the ~/.gemini symlink currently points at (basename), or empty.
_agy_active() {
  local link target slots; link="$(_agy_link)"; slots="$(_agy_slots)"
  [ -L "$link" ] || return 0
  target="$(readlink "$link")"
  case "$target" in "$slots"/*) basename "$target" ;; esac
}

# First-time takeover: warn, confirm, back up ~/.gemini, adopt it as a tank, and
# manage it via a symlink. Returns 1 (no takeover) if the user declines.
_agy_takeover() {
  local link slots; link="$(_agy_link)"; slots="$(_agy_slots)"
  log_warn "Setting up agy multi-account is a POWER mode with real tradeoffs:"
  cat >&2 <<EOF
  • It turns your real ~/.gemini into a clikae-managed symlink.
  • It is GLOBAL: only one agy tank is active at a time across ALL terminals
    (agy ignores per-shell env). Don't run two tanks at once.
  • Swapping while agy is running can corrupt that session.
  Reversible: 'clikae agy --release' restores a normal ~/.gemini.
EOF
  confirm "Let clikae take over ~/.gemini (your current login becomes a tank)?" \
    || { log_info "Not enabled — no agy tank created."; return 1; }
  _agy_assert_not_running
  mkdir -p "$slots"
  if [ -L "$link" ]; then
    :   # already a symlink — leave as-is
  elif [ -d "$link" ]; then
    local ts bak adopt; ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
    bak="$link.clikae.bak.$ts"
    cp -R "$link" "$bak" && log_ok "Backed up ~/.gemini -> $bak"
    # First time -> 'default'. Re-takeover (a 'default' already exists, e.g.
    # after --release) -> a fresh 'restored-<ts>' tank, never clobbering.
    adopt="default"; [ -e "$slots/default" ] && adopt="restored-$ts"
    mv "$link" "$slots/$adopt" && log_ok "Adopted current ~/.gemini -> tank '$adopt' (login preserved)"
    ln -s "$slots/$adopt" "$link"
  else
    mkdir -p "$slots/default"
    ln -s "$slots/default" "$link"
    log_ok "Created an empty 'default' tank."
  fi
  printf 'consented %s\n' "$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo yes)" > "$(_agy_consent)"
  log_ok "clikae now manages ~/.gemini. Active tank: $(_agy_active)"
  return 0
}

_agy_create_tank() {
  local name="$1" slot; slot="$(_agy_slots)/$name"
  if [ -d "$slot" ]; then log_info "agy tank already exists: $name"; return 0; fi
  mkdir -p "$slot"
  log_ok "Created agy tank: $name"
  log_dim "Switch to it:  clikae agy $name   (then run agy and log in)"
}

# `clikae init agy <tank>` lands here. First tank takes clikae through the
# one-time takeover; after that it's just a mkdir, same friction as init claude.
_agy_init() {
  local name="$1"
  validate_name profile "$name"
  if ! _agy_enabled; then
    # Declining the takeover is a graceful no-op (already messaged), not an error.
    _agy_takeover || return 0
  fi
  _agy_create_tank "$name"
}

# `clikae agy <tank>` lands here: repoint the symlink and run agy.
_agy_switch() {
  local name="$1"; shift || true
  _agy_enabled || log_fail "agy multi-account isn't set up yet. Create a tank first:  clikae init agy $name"
  local slots link; slots="$(_agy_slots)"; link="$(_agy_link)"
  [ -d "$slots/$name" ] || log_fail "No such agy tank: $name  (create it:  clikae init agy $name)"
  _agy_assert_not_running
  rm -f "$link"
  ln -s "$slots/$name" "$link"
  log_ok "agy is now on tank: $name"
  log_dim "agy is global — switched all terminals to $name."
  exec agy "$@"
}

# `clikae agy --release`: restore a normal single-account ~/.gemini from the
# active tank, drop the takeover, but KEEP the tank dirs for later.
_agy_release() {
  _agy_enabled || { log_info "agy multi-account isn't set up — nothing to release."; return 0; }
  _agy_assert_not_running
  local link slots active; link="$(_agy_link)"; slots="$(_agy_slots)"; active="$(_agy_active)"
  rm -f "$link"
  if [ -n "$active" ] && [ -d "$slots/$active" ]; then
    cp -R "$slots/$active" "$link" && log_ok "Restored ~/.gemini from tank '$active' (single-account again)."
  else
    log_warn "No active tank to restore; ~/.gemini left absent (agy will recreate it)."
  fi
  rm -f "$(_agy_consent)"
  log_ok "clikae released ~/.gemini. Your tanks are kept under $slots."
}

# `clikae remove agy <tank>` lands here. Removing the LAST tank also ends
# multi-account, offering to keep the login by restoring it as a normal ~/.gemini.
_agy_remove() {
  local name="$1" force="${2:-0}"
  validate_name profile "$name"
  _agy_enabled || log_fail "agy multi-account isn't set up. Nothing to remove."
  local slots active link; slots="$(_agy_slots)"; active="$(_agy_active)"; link="$(_agy_link)"
  [ -d "$slots/$name" ] || log_fail "No such agy tank: $name"
  _agy_assert_not_running

  local count; count="$(_agy_tank_names | grep -c . || true)"

  if [ "$count" -le 1 ]; then
    # Last tank → this ends multi-account too.
    if [ "$force" -eq 0 ]; then
      if confirm "This is your last agy tank. Restore it as a normal ~/.gemini (keep the login) and turn multi-account off?"; then
        rm -f "$link"; mv "${slots:?}/$name" "$link"; rm -f "$(_agy_consent)"
        rmdir "$slots" 2>/dev/null || true
        log_ok "Restored ~/.gemini from '$name' and turned agy multi-account off."
        return 0
      fi
      confirm "Remove it anyway? Your agy login in this tank will be lost." \
        || { log_info "Aborted — nothing removed."; return 0; }
    fi
    rm -f "$link"; rm -rf "${slots:?}/$name"; rm -f "$(_agy_consent)"
    rmdir "$slots" 2>/dev/null || true
    log_ok "Removed agy tank '$name' and turned multi-account off (agy will recreate ~/.gemini)."
    return 0
  fi

  # More than one tank remains.
  if [ "$name" = "$active" ]; then
    log_fail "'$name' is the active agy tank. Switch to another first:  clikae agy <other-tank>"
  fi
  rm -rf "${slots:?}/$name"
  log_ok "Removed agy tank: $name"
}

_agy_help() {
  cat <<'EOF'
Usage: clikae agy [tank] [-- args...]    switch agy to <tank> and run it
       clikae init agy <tank>            create an agy tank (asks before managing
                                         ~/.gemini the first time)
       clikae remove agy <tank>          remove an agy tank
       clikae agy --release              restore a normal ~/.gemini, keep tanks

Antigravity (agy) hardcodes ~/.gemini and ignores env vars, so clikae can't
switch it per-shell like other engines. Instead it swaps ~/.gemini between tank
dirs via a symlink — a GLOBAL power mode: one agy tank is active at a time across
ALL terminals. The first `init agy` asks before taking over ~/.gemini; it's
reversible with `clikae agy --release`.
EOF
}

# `clikae agy [tank]` / `clikae agy --release` — the bare switch for agy.
cmd_antigravity() {
  local release=0 tank=""
  local -a passthru=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --release)  release=1; shift ;;
      -h|--help)  _agy_help; return 0 ;;
      --)         shift; passthru=("$@"); break ;;
      -*)         log_fail "Unknown flag: $1  (try: clikae agy --help)" ;;
      *)          if [ -z "$tank" ]; then tank="$1"; shift; else break; fi ;;
    esac
  done

  if [ "$release" -eq 1 ]; then
    [ -z "$tank" ] || log_fail "--release takes no tank."
    _agy_release
    return $?
  fi

  if [ -z "$tank" ]; then
    if ! _agy_enabled; then
      log_info "No agy tanks yet."
      log_dim "Create one:  clikae init agy <tank>   (clikae asks before managing ~/.gemini)"
      return 0
    fi
    local names count
    names="$(_agy_tank_names)"
    count="$(printf '%s\n' "$names" | grep -c . || true)"
    if [ "$count" -eq 1 ]; then
      tank="$names"
    else
      log_info "agy has several tanks — pick one:"
      printf '%s\n' "$names" | while IFS= read -r t; do
        [ -n "$t" ] && printf '    clikae agy %s\n' "$t"
      done
      return 0
    fi
  fi

  _agy_switch "$tank" "${passthru[@]}"
}
