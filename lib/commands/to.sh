# shellcheck shell=bash
# lib/commands/to.sh — `clikae to <target> [tank] [-- args]`: carry your CURRENT
# session onto another tank and keep going. The unified "keep burning" verb.
#
# Reads as English — "clikae to codex" = "switch TO codex" — and the source is
# auto-detected from this shell. clikae picks the mechanism and announces it:
#   • target is the SAME engine     -> a real resume        (delegates to relay)
#   • target is a DIFFERENT engine  -> a written brief, cold (delegates to handoff)
# See docs/grammar.md §3.2. `relay`, `handoff`, `continue` are hidden aliases.

# _to_detect_source -> "engine\ttank" for whichever engine this shell is on (its
# env var resolves to a clikae tank). Empty if none; multiple lines if ambiguous.
_to_detect_source() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    (
      load_adapter "$name" >/dev/null 2>&1 || exit 0
      local var strategy value tank
      var="$(adapter_meta_env_var)"
      [ -n "$var" ] || exit 0      # flag-strategy engines aren't detectable from env
      strategy="$(adapter_meta_strategy)"
      value="${!var}"
      tank="$(resolve_active_profile "$name" "$strategy" "$value")"
      [ -n "$tank" ] && printf '%s\t%s\n' "$name" "$tank"
    )
  done <<EOF
$(list_adapters)
EOF
}

# _to_detect_recent  -> "engine\ttank" for the engine+tank with this directory's
# globally newest transcript, or empty. The fallback when no env var is set (the
# switch/alias/.app never export it): "the session I was just in here".
_to_detect_recent() {
  local name r tank mt best_engine="" best_tank="" best_mt=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    r="$(newest_transcript_tank "$name")"        # tab-separated "tank<TAB>mtime", or empty
    [ -n "$r" ] || continue
    tank="$(printf '%s' "$r" | cut -f1)"; mt="$(printf '%s' "$r" | cut -f2)"
    [ -n "$mt" ] || mt=0
    if [ "$mt" -gt "$best_mt" ]; then best_mt="$mt"; best_engine="$name"; best_tank="$tank"; fi
  done <<EOF
$(list_adapters)
EOF
  if [ -n "$best_engine" ]; then printf '%s\t%s\n' "$best_engine" "$best_tank"; fi
}

_to_help() {
  cat <<'EOF'
Usage: clikae to [target] [tank] [-- args...]

Carry THIS shell's current session onto another tank and keep going — for when
the tank you're on runs dry. The source is auto-detected from this shell.

With NO target, falls through to the next tank of the engine you're on (your
tanks ARE the reserve — there's nothing to configure). clikae picks the
mechanism and tells you which:
  • same engine, another tank  -> a real resume (your conversation continues)
  • a different engine         -> a written brief (that engine can't resume a
                                  foreign session, so it starts cold from a summary)

  clikae to                  fall through to the next tank of THIS engine
  clikae to work             carry onto the 'work' tank of the engine you're on
  clikae to codex            carry onto a different engine (codex) — brief
  clikae to claude personal  explicit engine + tank
  clikae to codex work       cross to codex's 'work' tank

The target resolves engine-name-first: a known engine crosses to it; anything
else is a tank of your current engine. Hidden aliases: relay, continue, handoff.

Options (same-engine carries only — forwarded to relay):
  -y, --yes          skip relay's preview/confirm
      --fresh        switch tanks but start a NEW conversation (don't carry)
      --session <id> carry a specific session instead of the newest

Carrying the same task past a usage limit on another account sits in the
vendors' terms gray zone — where the line is, with the actual policy language
and dates: docs/terms-and-your-accounts.md (shown once before your first carry).
EOF
}

# _to_can_carry <engine> -> 0 if the engine's adapter defines adapter_relay (a real
# session carry-over), 1 if not (relay will start fresh). The adapter FILE is ground
# truth — load_adapter installs a default stub, so a runtime declare -F always says
# yes. Lets `to` describe what it'll actually do. (Not the same check as
# `clikae resume`'s cross-tank carry, which uses _resume_carry_session and covers
# codex/antigravity too — `to`/`relay` carry the CURRENT live session, claude-only.)
_to_can_carry() {
  grep -qE '^[[:space:]]*adapter_relay[[:space:]]*\(\)' "$CLIKAE_LIB/adapters/$1.sh" 2>/dev/null
}

cmd_to() {
  local -a positionals=() passthru=() relay_flags=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)    _to_help; return 0 ;;
      # Same-engine carries are relays under the hood — forward relay's control
      # flags so `to` is at least as capable as the hidden `relay` alias.
      -y|--yes)     relay_flags+=("$1"); shift ;;
      --fresh)      relay_flags+=("$1"); shift ;;
      --session)    [ $# -ge 2 ] || log_fail "--session needs a session id"
                    relay_flags+=("$1" "$2"); shift 2 ;;
      --)           shift; passthru=("$@"); break ;;
      -*)           log_fail "Unknown flag: $1" ;;
      *)            positionals+=("$1"); shift ;;
    esac
  done

  [ "${#positionals[@]}" -le 2 ] || log_fail "Too many arguments. Usage: clikae to [target] [tank]"
  # Target is OPTIONAL: bare `clikae to` falls through to the next tank of the
  # engine you're on (resolved below, after we detect the source).
  local target="${positionals[0]:-}" target_tank="${positionals[1]:-}"

  # Auto-detect the source engine + tank. First this shell's live env var; then
  # (the common case — the switch/alias/.app never export it) the engine+tank
  # with this directory's most recent transcript: "the session I was just in".
  local src srcn from_recent=0
  src="$(_to_detect_source || true)"
  srcn="$(printf '%s\n' "$src" | grep -c . || true)"
  if [ "$srcn" -eq 0 ]; then
    src="$(_to_detect_recent || true)"
    srcn="$(printf '%s\n' "$src" | grep -c . || true)"
    [ "$srcn" -ge 1 ] && from_recent=1
  fi
  if [ "$srcn" -eq 0 ]; then
    log_err "Couldn't tell which engine/tank this shell is on, and found no recent session in this directory."
    log_dim "Run it from the directory you were working in, or be explicit:  clikae relay <engine> <from> <to>  /  clikae handoff <engine> <from> --to <target>"
    exit 1
  elif [ "$srcn" -gt 1 ]; then
    log_err "This shell is on more than one engine — can't tell which to carry:"
    printf '%s\n' "$src" | while IFS=$'\t' read -r e t; do [ -n "$e" ] && log_dim "  $e/$t"; done
    log_dim "Be explicit:  clikae relay <engine> <from> <to>  /  clikae handoff <engine> <from> --to <target>"
    exit 1
  fi
  local src_engine src_tank
  IFS=$'\t' read -r src_engine src_tank <<EOF
$src
EOF
  [ "$from_recent" -eq 1 ] && log_dim "source: this directory's most recent session — $src_engine/$src_tank"

  # Bare `clikae to` — no target given: fall through to the next tank in your BURN
  # ORDER (your tanks ARE the reserve; the board order is the order). It may cross
  # engines if that's what your order says — the resolution below then picks resume
  # (same engine) vs a written brief (different engine) and announces which.
  if [ -z "$target" ]; then
    local _next _ne _nt
    _next="$(next_tank "$src_engine" "$src_tank")"
    [ -n "$_next" ] || log_fail "Nothing after $src_engine/$src_tank in your burn order. Add a tank (clikae init …) or pick one explicitly (clikae to <engine|tank>)."
    IFS=$'\t' read -r _ne _nt <<EOF2
$_next
EOF2
    target="$_ne"; target_tank="$_nt"
    log_info "to: next in your burn order — $_ne/$_nt."
  fi

  # Normalise the agy long name for the target lookup (canonical engine = agy).
  local tnorm="$target"; [ "$target" = "agy" ] && tnorm="antigravity"

  local -a cmd; local is_relay=0
  if [ -f "$CLIKAE_LIB/adapters/$tnorm.sh" ] || [ -f "$CLIKAE_LIB/targets/$tnorm.sh" ]; then
    if [ "$tnorm" = "$src_engine" ]; then
      # Same engine named explicitly -> relay to another of its tanks. Only a real
      # resume if the engine can carry a session (adapter_relay) — codex can't, so
      # relay starts fresh there; say so rather than promise a resume we won't give.
      is_relay=1
      if _to_can_carry "$src_engine"; then
        log_info "to: same engine ($src_engine) — carrying your live session (resume)."
      else
        log_info "to: same engine ($src_engine), but $src_engine has no session carry-over — this starts a FRESH session on the target (not a resume)."
      fi
      if [ -n "$target_tank" ]; then
        cmd=("$CLIKAE_BIN" relay "$src_engine" "$src_tank" "$target_tank")
      else
        cmd=("$CLIKAE_BIN" relay "$src_engine")   # relay re-detects from + picks target
      fi
    else
      # Different engine -> brief + cold start (handoff).
      local totgt="$tnorm"; [ -n "$target_tank" ] && totgt="$tnorm/$target_tank"
      log_warn "to: $target can't resume a $src_engine session — handing off a written brief (cold start)."
      cmd=("$CLIKAE_BIN" handoff "$src_engine" "$src_tank" --to "$totgt")
    fi
  else
    # Not an engine -> a tank of the current engine -> relay (resume).
    [ -z "$target_tank" ] || log_fail "'$target' isn't an engine, so a second name ('$target_tank') doesn't apply. Did you mean:  clikae to <engine> $target ?"
    is_relay=1
    if _to_can_carry "$src_engine"; then
      log_info "to: carrying your live session onto $src_engine/$target (resume)."
    else
      log_info "to: switching to $src_engine/$target — $src_engine has no session carry-over, so this is a FRESH start (not a resume)."
    fi
    cmd=("$CLIKAE_BIN" relay "$src_engine" "$src_tank" "$target")
  fi

  # Relay control flags only apply to a same-engine carry. A cross-engine handoff
  # has no live session to resume, so they'd be meaningless there.
  if [ "${#relay_flags[@]}" -gt 0 ]; then
    [ "$is_relay" -eq 1 ] || log_fail "${relay_flags[0]} only applies to a same-engine carry; '$target' is a different engine (a written brief, not a resume)."
    cmd+=("${relay_flags[@]}")
  fi

  [ "${#passthru[@]}" -eq 0 ] || cmd+=(-- "${passthru[@]}")
  # First-ever cross-account carry → the one-time accounts note (docs cover the
  # full picture; this makes sure the headline was seen once).
  carry_notice_once
  # Record the carry in the "what clikae did" log before we hand off (clikae status
  # shows the recent tail). cmd[0] is $CLIKAE_BIN, so log from the verb on.
  history_log "to: ${cmd[*]:1}"
  exec "${cmd[@]}"
}
