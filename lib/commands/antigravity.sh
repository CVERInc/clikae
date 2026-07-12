# shellcheck shell=bash
# lib/commands/antigravity.sh — Antigravity (agy) folded into clikae's standard
# grammar. See docs/grammar.md §6.
#
# WHY agy is special: its CLI (`agy`) keeps its login as one global Keychain entry
# (state follows $HOME, but the account doesn't) and has no per-account config-dir
# flag. clikae's clean per-shell model can't switch the account, so the only way to
# give it multiple tanks is to SWAP ~/.gemini between per-tank directories via a
# symlink AND carry each tank's login with it — see the Keychain note below. That
# is GLOBAL (one tank active at a time across ALL terminals) and mutates your real
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

# ── Per-tank Google login (macOS Keychain) ──────────────────────────────────
# agy keeps its Google OAuth login in ONE machine-wide macOS Keychain item
# (verified on a real install: service "gemini", account "antigravity") — NOT in
# the ~/.gemini dir clikae swaps. And agy reads the account purely from that
# Keychain slot, IGNORING which tank dir ~/.gemini points at (verified live
# 2026-06-30: on tank-8 state with tank-c's token in the slot, agy ran as tank c).
#
# So clikae carries that login WITH the tank: on switch it stashes the outgoing
# tank's login into a clikae-namespaced Keychain slot and restores the incoming
# tank's. Keychain↔Keychain — the token is never written to disk.
#
# 2026-06-30 history: this WAS ripped out (commit 32507a8) after a live test
# showed a restore that silently no-op's (e.g. the incoming tank has no stash
# yet, or `security` behaves subtly differently than assumed) can leave agy
# running on the WRONG account with zero warning — and the whole mechanism had
# NEVER been exercised against a real Keychain (tests stub `security`
# entirely). It's back now with the actual fix for that: _agy_kc_verify_restore
# below refuses to proceed silently if the restore didn't verifiably take, and
# tests/bats/antigravity_keychain_real.bats exercises the real `security`
# binary end to end. macOS-only; on Linux agy stores its login in files inside
# ~/.gemini, which the dir swap already isolates, so these are no-ops.
_agy_kc_canon_service() { printf 'gemini\n'; }
_agy_kc_account()       { printf 'antigravity\n'; }
_agy_kc_tank_service()  { printf 'clikae-agy-%s\n' "$1"; }
_agy_kc_available() {
  case "$OSTYPE" in darwin*) ;; *) return 1 ;; esac
  command -v security >/dev/null 2>&1
}

# A trailing keychain-file argument for `security` (verified against the real
# binary: it's a bare positional path at the END of the command, NOT a `-k`
# flag), left in the global $_agy_kc_kargs array (bash 3.2 on macOS has no
# namerefs or a builtin to read a command's output straight into an array, so a
# fixed-name global is the portable way to hand one back to a caller). Empty
# (= the default search list, i.e. the real login keychain) unless a test sets
# $CLIKAE_AGY_KEYCHAIN to a scratch keychain path — production code never sets
# this, only tests/bats/antigravity_keychain_real.bats does.
_agy_kc_kargs=()
_agy_kc_keychain_argv() {
  _agy_kc_kargs=()
  [ -n "${CLIKAE_AGY_KEYCHAIN:-}" ] && _agy_kc_kargs=("$CLIKAE_AGY_KEYCHAIN")
  return 0   # under `set -e`, a false `[ ... ] &&` as the last statement would kill the caller
}

# Read one generic-password service's secret, or return 1 if absent/empty.
# Never prints the secret to stdout on failure paths.
_agy_kc_read() {
  local svc="$1" acct; acct="$(_agy_kc_account)"
  local -a kargs=(); _agy_kc_keychain_argv; kargs=("${_agy_kc_kargs[@]}")
  # `security`'s optional keychain arg is TRAILING/positional, not a flag — it
  # must come after -w, or the real binary rejects it as an unknown option
  # (verified against the real binary; the old bash-stub tests never caught this
  # since the stub didn't validate argument order).
  security find-generic-password -s "$svc" -a "$acct" -w "${kargs[@]}" 2>/dev/null
}

# Copy one generic-password service's secret to another (-U overwrites). Returns
# 1 if the source has no secret. Never prints the secret.
_agy_kc_copy() {
  local from="$1" to="$2" acct secret
  acct="$(_agy_kc_account)"
  local -a kargs=(); _agy_kc_keychain_argv; kargs=("${_agy_kc_kargs[@]}")
  secret="$(_agy_kc_read "$from")" || return 1
  [ -n "$secret" ] || return 1
  security add-generic-password -s "$to" -a "$acct" -l "$to" -w "$secret" -U "${kargs[@]}" \
    >/dev/null 2>&1 || { secret=""; return 1; }
  secret=""
  return 0
}

# Stash the currently-active agy login (the canonical item) into <tank>'s slot.
_agy_kc_stash() {
  _agy_kc_available || return 0
  _agy_kc_copy "$(_agy_kc_canon_service)" "$(_agy_kc_tank_service "$1")" || return 0
}

# Restore <tank>'s stashed login into the canonical item agy reads. If the tank
# has no stash (never logged in on it), CLEAR the canonical item so agy logs in
# fresh instead of inheriting the previous tank's account.
_agy_kc_restore() {
  _agy_kc_available || return 0
  if ! _agy_kc_copy "$(_agy_kc_tank_service "$1")" "$(_agy_kc_canon_service)"; then
    local acct; acct="$(_agy_kc_account)"
    local -a kargs=(); _agy_kc_keychain_argv; kargs=("${_agy_kc_kargs[@]}")
    security delete-generic-password -s "$(_agy_kc_canon_service)" -a "$acct" "${kargs[@]}" \
      >/dev/null 2>&1 || true
  fi
}

# The actual fix for the 2026-06-30 trust bug: after a restore, if <tank> HAD a
# stash, re-read the canonical item and confirm its secret matches the stash
# byte-for-byte. A tank with NO stash (canonical was cleared, not restored) is
# not checked here — that path is an intentional logout, not a restore. On
# mismatch, refuse to let the caller proceed as if the switch succeeded: this is
# the difference between "silently burn the wrong account's quota" and "clikae
# told you it couldn't verify the switch."
_agy_kc_verify_restore() {
  local tank="$1" stashed canon
  _agy_kc_available || return 0
  stashed="$(_agy_kc_read "$(_agy_kc_tank_service "$tank")")" || return 0   # no stash: logout path, nothing to verify
  canon="$(_agy_kc_read "$(_agy_kc_canon_service)")" || {
    stashed=""; log_fail "agy Keychain restore for tank '$tank' didn't take (canonical login is empty after restore) — refusing to guess which account is active. Run 'clikae agy $tank' again, or check Keychain by hand."
  }
  if [ "$stashed" != "$canon" ]; then
    stashed=""; canon=""
    log_fail "agy Keychain restore for tank '$tank' didn't verify (canonical login doesn't match the stash) — refusing to guess which account is active. Run 'clikae agy $tank' again, or check Keychain by hand."
  fi
  stashed=""; canon=""
  return 0
}

# Forget a tank's stashed login (on remove).
_agy_kc_forget() {
  _agy_kc_available || return 0
  local acct; acct="$(_agy_kc_account)"
  local -a kargs=(); _agy_kc_keychain_argv; kargs=("${_agy_kc_kargs[@]}")
  security delete-generic-password -s "$(_agy_kc_tank_service "$1")" -a "$acct" "${kargs[@]}" \
    >/dev/null 2>&1 || true
}

# Clear the canonical login agy reads (used when force-removing the last tank's
# login, or when a tank switch finds no stash to restore). agy will prompt a
# fresh login next run.
_agy_kc_logout() {
  _agy_kc_available || return 0
  local acct; acct="$(_agy_kc_account)"
  local -a kargs=(); _agy_kc_keychain_argv; kargs=("${_agy_kc_kargs[@]}")
  security delete-generic-password -s "$(_agy_kc_canon_service)" -a "$acct" "${kargs[@]}" \
    >/dev/null 2>&1 || true
}

# Carry a tank's stashed login across a rename (old slot -> new slot).
_agy_kc_rename() {
  _agy_kc_available || return 0
  _agy_kc_copy "$(_agy_kc_tank_service "$1")" "$(_agy_kc_tank_service "$2")" || return 0
  local acct; acct="$(_agy_kc_account)"
  local -a kargs=(); _agy_kc_keychain_argv; kargs=("${_agy_kc_kargs[@]}")
  security delete-generic-password -s "$(_agy_kc_tank_service "$1")" -a "$acct" "${kargs[@]}" \
    >/dev/null 2>&1 || true
}
# ────────────────────────────────────────────────────────────────────────────

# _agy_rename <old> <new> — rename an agy tank: move the slot dir, repoint the
# ~/.gemini symlink if it's the active one, and carry the tank's Keychain login
# slot across (macOS). Refuses if agy is running, the source is missing, or the
# target name is taken.
_agy_rename() {
  local old="$1" new="$2" slots link active
  validate_name profile "$old"; validate_name profile "$new"
  slots="$(_agy_slots)"; link="$(_agy_link)"
  [ -d "$slots/$old" ] || log_fail "No such agy tank: $old"
  [ ! -e "$slots/$new" ] || log_fail "An agy tank named '$new' already exists."
  _agy_assert_not_running
  active="$(_agy_active)"
  mv "$slots/$old" "$slots/$new" || log_fail "Couldn't rename the agy tank directory."
  _agy_kc_rename "$old" "$new"
  soul_rename_member "antigravity" "$old" "$new"   # keep Soul membership in step
  if [ "$active" = "$old" ]; then
    rm -f "$link"; ln -s "$slots/$new" "$link"
    log_ok "Renamed agy tank '$old' → '$new' (and repointed ~/.gemini)."
  else
    log_ok "Renamed agy tank '$old' → '$new'."
  fi
}

# First-time takeover: warn, confirm, back up ~/.gemini, adopt it as a tank, and
# manage it via a symlink. Returns 1 (no takeover) if the user declines.
_agy_takeover() {
  local link slots; link="$(_agy_link)"; slots="$(_agy_slots)"
  log_warn "Setting up agy multi-account is a POWER mode with real tradeoffs:"
  cat >&2 <<EOF
  • It turns your real ~/.gemini into a clikae-managed symlink.
  • On macOS, it carries your Google login PER TANK via your login Keychain:
    agy keeps its OAuth login in one machine-wide Keychain item, so to give each
    tank its own account clikae copies that login between Keychain slots on every
    switch. The token moves Keychain→Keychain and is never written to disk — and
    every restore is VERIFIED (clikae re-reads the login after copying it and
    refuses to proceed if it doesn't match, rather than silently landing you on
    the wrong account). A tank with no prior login logs out cleanly instead, so
    agy asks for a fresh OAuth pick.
  • It is GLOBAL: only one agy tank is active at a time across ALL terminals
    (the login is one global Keychain entry). Don't run two tanks at once.
  • Swapping while agy is running can corrupt that session.
  Reversible: 'clikae agy --release' restores a normal ~/.gemini (your tanks and
  their stashed logins are kept).
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
  # A switch to the tank you're ALREADY on is a no-op: it repoints nothing, so it
  # is safe even while an agy session is live — this is exactly how you drive agy
  # headless on the active account (`clikae agy <active-tank> -- -p …`). Only a
  # REAL switch to a DIFFERENT tank would yank ~/.gemini out from under a running
  # session, so the not-running guard AND the login carry AND the symlink repoint
  # all belong inside that branch. (Before this, the guard + rm/ln ran even for a
  # no-op, so `clikae agy <active> -- …` refused whenever any agy process was up.)
  local active; active="$(_agy_active)"
  if [ "$name" != "$active" ]; then
    _agy_assert_not_running
    # Carry the Google login WITH the tank: stash the outgoing tank's login (if
    # any), restore the incoming tank's (or log out cleanly if it never logged
    # in), VERIFY the restore actually took, then repoint the global symlink.
    [ -n "$active" ] && _agy_kc_stash "$active"
    _agy_kc_restore "$name"
    _agy_kc_verify_restore "$name"
    rm -f "$link"
    ln -s "$slots/$name" "$link"
    log_ok "agy is now on tank: $name"
    log_dim "agy is global — switched all terminals to $name."
  fi
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
        _agy_kc_forget "$name"   # login stays in the canonical Keychain item; drop the stash
        log_ok "Restored ~/.gemini from '$name' and turned agy multi-account off."
        return 0
      fi
      confirm "Remove it anyway? Your agy login in this tank will be lost." \
        || { log_info "Aborted — nothing removed."; return 0; }
    fi
    rm -f "$link"; rm -rf "${slots:?}/$name"; rm -f "$(_agy_consent)"
    rmdir "$slots" 2>/dev/null || true
    _agy_kc_forget "$name"; _agy_kc_logout   # login lost, as warned
    log_ok "Removed agy tank '$name' and turned multi-account off (agy will recreate ~/.gemini)."
    return 0
  fi

  # More than one tank remains.
  if [ "$name" = "$active" ]; then
    local _other; _other="$(_agy_tank_names | grep -vx "$name" | head -1)"
    log_fail "'$name' is the active agy tank. Switch to another first:  clikae agy ${_other:-<other-tank>}"
  fi
  rm -rf "${slots:?}/$name"
  _agy_kc_forget "$name"
  log_ok "Removed agy tank: $name"
}

_agy_help() {
  cat <<'EOF'
Usage: clikae agy [tank] [-- args...]    switch agy to <tank> and run it
       clikae init agy <tank>            create an agy tank (asks before managing
                                         ~/.gemini the first time)
       clikae remove agy <tank>          remove an agy tank
       clikae agy --release              restore a normal ~/.gemini, keep tanks

Antigravity (agy) keeps its login as one global Keychain entry, so clikae can't
switch the account per-shell like other engines. Instead it swaps ~/.gemini between
tank dirs via a symlink AND carries each tank's login with it (macOS Keychain,
verified on every switch — never a silent landing on the wrong account) — a
GLOBAL power mode: one agy tank is active at a time across ALL terminals. The
first `init agy` asks before taking over ~/.gemini; it's reversible with
`clikae agy --release`.

Run agy headless on the active account (route work to your Antigravity quota,
sparing your main claude/codex budget), or hand it to `clikae burn agy <tank>` —
since a tank switch no longer needs an interactive OAuth pick, burn can auto-hop
to the next agy tank when one runs dry (sequential only; agy can't run two tanks
in parallel — see `clikae conduct --help`). Drive it directly like this:

  clikae agy <tank> -- --print-timeout 900s -p "$(cat /tmp/prompt.txt)"

Key rules (full recipe: docs/agy-dispatch.md):
  - Headless is -p, never -i (-i needs a TTY).
  - Prompt via a FILE, not nested quotes.
  - For big output, have agy WRITE a file (its stdout buffers and returns nothing);
    results land in ~/.gemini/antigravity-cli/brain/<session-id>/.
  - Give a fenced task + long --print-timeout, or it wanders and burns the clock.
  - Reading files outside cwd needs --add-dir <abs path>, or feed text via stdin.
  - pkill -9 -f "agy -p" before switching tanks (a live agy blocks the swap).
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
