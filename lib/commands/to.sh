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

_to_help() {
  cat <<'EOF'
Usage: clikae to <target> [tank] [-- args...]

Carry THIS shell's current session onto another tank and keep going — for when
the tank you're on runs dry. The source is auto-detected from this shell.

clikae picks the mechanism and tells you which:
  • same engine, another tank  -> a real resume (your conversation continues)
  • a different engine         -> a written brief (that engine can't resume a
                                  foreign session, so it starts cold from a summary)

  clikae to work             carry onto the 'work' tank of the engine you're on
  clikae to codex            carry onto a different engine (codex) — brief
  clikae to claude personal  explicit engine + tank
  clikae to codex work       cross to codex's 'work' tank

The target resolves engine-name-first: a known engine crosses to it; anything
else is a tank of your current engine. Hidden aliases: relay, continue, handoff.
EOF
}

cmd_to() {
  local -a positionals=() passthru=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) _to_help; return 0 ;;
      --)        shift; passthru=("$@"); break ;;
      -*)        log_fail "Unknown flag: $1" ;;
      *)         positionals+=("$1"); shift ;;
    esac
  done

  [ "${#positionals[@]}" -ge 1 ] || log_fail "Missing target. See: clikae to --help"
  [ "${#positionals[@]}" -le 2 ] || log_fail "Too many arguments. Usage: clikae to <target> [tank]"
  local target="${positionals[0]}" target_tank="${positionals[1]:-}"

  # Auto-detect the source engine + tank from this shell.
  local src srcn
  src="$(_to_detect_source)"
  srcn="$(printf '%s\n' "$src" | grep -c . || true)"
  if [ "$srcn" -eq 0 ]; then
    log_err "Couldn't tell which engine/tank this shell is on (no engine's env var points at a clikae tank)."
    log_dim "Run it from the shell you're burning in, or be explicit:  clikae relay <engine> <from> <to>  /  clikae handoff <engine> <from> --to <target>"
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

  # Normalise the agy long name for the target lookup (canonical engine = agy).
  local tnorm="$target"; [ "$target" = "agy" ] && tnorm="antigravity"

  local -a cmd
  if [ -f "$CLIKAE_LIB/adapters/$tnorm.sh" ] || [ -f "$CLIKAE_LIB/targets/$tnorm.sh" ]; then
    if [ "$tnorm" = "$src_engine" ]; then
      # Same engine named explicitly -> relay to another of its tanks (resume).
      log_info "to: same engine ($src_engine) — carrying your live session (resume)."
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
    log_info "to: carrying your live session onto $src_engine/$target (resume)."
    cmd=("$CLIKAE_BIN" relay "$src_engine" "$src_tank" "$target")
  fi

  [ "${#passthru[@]}" -eq 0 ] || cmd+=(-- "${passthru[@]}")
  exec "${cmd[@]}"
}
