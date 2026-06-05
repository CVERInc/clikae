# shellcheck shell=bash
# lib/commands/auto.sh — `clikae auto [ask|safe|full]` — show or set how much
# clikae may do on its own when a tank runs dry. See lib/core/autonomy.sh.
#
#   clikae auto          show the current level + the choices
#   clikae auto safe     auto-carry same-engine, ask before crossing engines
#   clikae auto full     auto-carry anything next in the burn order (SU mode)
#   clikae auto ask      back to asking first (the safe default)
#
# Consumed by the BETA supervised launch (claude-only for now). The dashboard's
# autonomy toggle flips the same preference.

cmd_auto() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae auto [ask | safe | full]

Set how much clikae does on its own when the tank you're on runs dry (BETA —
claude only for now; feedback welcome).

  ask    (default) ask before carrying onward — the consent moment
  safe   auto-carry to the next SAME-engine tank (seamless resume); ask before
         crossing engines (a lossy cold-start brief)
  full   auto-carry to whatever is next in your burn order — same-engine is a
         resume, a cross-engine hop is a cold-start brief — the "just keep going" mode

With no argument, prints the current level. Stored in $CLIKAE_HOME/autonomy;
reversible anytime. Only sessions you launch THROUGH clikae are supervised.
EOF
      return 0 ;;
  esac

  if [ -z "${1:-}" ]; then
    local cur; cur="$(autonomy_get)"
    log_info "Autonomy: $cur — $(autonomy_label "$cur")"
    log_dim  "Choices:  ask · safe · full    (set with: clikae auto <level>)"
    log_dim  "BETA: auto-switch is claude-only for now; feedback welcome."
    return 0
  fi

  if autonomy_set "$1"; then
    log_ok "Autonomy: $1 — $(autonomy_label "$1")"
    [ "$1" != "ask" ] && log_dim "clikae will carry your session onward on a dry tank (BETA, claude). Revert: clikae auto ask"
  else
    log_fail "Unknown level: $1  (use: ask | safe | full)"
  fi
}
