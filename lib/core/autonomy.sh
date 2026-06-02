# shellcheck shell=bash
# lib/core/autonomy.sh — how much clikae may do on its own when a tank runs dry.
#
# A user-chosen spectrum (informed-consent, sudo-style — see memory
# feedback-informed-consent-power), stored in $CLIKAE_HOME/autonomy:
#   ask   (default) — on a dry tank, ASK before carrying onward (the consent
#                     moment; choosing "always" here flips to `safe`).
#   safe            — auto-carry to the next SAME-engine tank (a seamless resume);
#                     PAUSE/ask before crossing engines (a lossy cold-start brief).
#   full            — auto-carry to whatever is next in the burn order, including
#                     across engines. The "just keep going" / SU mode.
#
# Only the supervised launch (lib/commands/switch.sh) consumes this — and that's
# BETA, claude-only for now (see docs/DESIGN-runtime.md). The toggle ships WITH its
# consumer so it's never a phantom switch.

autonomy_file() { printf '%s\n' "$CLIKAE_HOME/autonomy"; }

# autonomy_get -> ask | safe | full  (default ask; unknown content normalises to ask).
autonomy_get() {
  local v=""
  [ -f "$(autonomy_file)" ] && v="$(tr -d '[:space:]' < "$(autonomy_file)" 2>/dev/null)"
  case "$v" in safe|full) printf '%s' "$v" ;; *) printf 'ask' ;; esac
}

# autonomy_set <ask|safe|full> -> persist. Returns 1 on an unknown level.
autonomy_set() {
  case "$1" in
    ask|safe|full) : ;;
    *) return 1 ;;
  esac
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  printf '%s\n' "$1" > "$(autonomy_file)" 2>/dev/null || true
}

# autonomy_label <level> -> a short human description for status/help.
autonomy_label() {
  case "$1" in
    ask)  printf 'ask first' ;;
    safe) printf 'auto same-engine, ask to cross' ;;
    full) printf 'full auto (incl. cross-engine)' ;;
    *)    printf '%s' "$1" ;;
  esac
}
